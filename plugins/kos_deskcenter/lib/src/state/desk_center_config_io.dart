/// `desk_center_config` 的 dart:io 持久化实现（`DeskCenterConfigStore`）。
///
/// 对应源端 `Settings location: file://Quickshell.stateDir +
/// "/deskcenter-widgets.ini"`（DeskCenterConfigService.qml:26-32）：
/// Quickshell.stateDir 是 XDG state 目录下的应用私有目录——本端落到
/// `$XDG_STATE_HOME/denial/kos_deskcenter/config.json`（缺失回退
/// `$HOME/.local/state`），不越出 SDK/平台允许的 state 目录。
///
/// 写入语义对齐 `_settings.sync()`（:64、:83）——Qt Settings 内部即
/// 临时文件 + 原子 rename；本端显式 `*.tmp` 写后 `rename` 保证不落半截
/// JSON。读取：缺失/损坏/schemaVersion 不符 → [DeskCenterConfig.defaults]
/// （对应源端 `JSON.parse` catch 回退 `{}`/`[]` 再补全的语义）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'desk_center_config.dart';

/// DeskCenter 配置文件的读写器。
final class DeskCenterConfigStore {
  DeskCenterConfigStore({String? path})
    : _path = path ?? _defaultPath();

  final String _path;

  /// 配置文件路径（测试可读）。
  String get path => _path;

  /// 默认路径：`$XDG_STATE_HOME/denial/kos_deskcenter/config.json`；
  /// XDG_STATE_HOME 缺失时 `$HOME/.local/state/...`（XDG 规范回退）。
  static String _defaultPath() {
    final env = Platform.environment;
    final stateHome = env['XDG_STATE_HOME'] ??
        '${env['HOME'] ?? ''}/.local/state';
    return '$stateHome/denial/kos_deskcenter/config.json';
  }

  /// 读取配置；文件缺失/读失败/JSON 损坏/schemaVersion 不符一律回退
  /// [DeskCenterConfig.defaults]（对应源端 `JSON.parse` catch → `{}`/`[]`
  /// 再经 `orderedIds`/`sizeFor` 归一的兜底链）。
  Future<DeskCenterConfig> load() async {
    String text;
    try {
      text = await File(_path).readAsString();
    } on Object {
      return DeskCenterConfig.defaults();
    }
    try {
      return DeskCenterConfig.fromJson(jsonDecode(text));
    } on Object {
      return DeskCenterConfig.defaults();
    }
  }

  /// 原子写入：写 `config.json.tmp` 后 rename 覆盖目标（`Settings.sync`
  /// 的原子落盘等价物）。目录缺失时先创建。
  Future<void> save(DeskCenterConfig config) async {
    final file = File(_path);
    await file.parent.create(recursive: true);
    final tmp = File('$_path.tmp');
    await tmp.writeAsString(
      const JsonEncoder.withIndent('  ').convert(config.toJson()),
    );
    await tmp.rename(_path);
  }
}
