/// KOS Dock 偏好存储的 dart:io 实现。
///
/// 搬自 denial_taskbar `taskbar_preferences.dart:53-104`
/// （`TaskbarPreferencesStore`）：temp+rename 原子写、写前读回整份 JSON
/// 以保留未知 key、文件缺失（ENOENT）按空偏好处理；默认路径改为
/// `$XDG_CONFIG_HOME/denial/plugins/kos_dock.json`。
/// 可见性写路径（`showLauncher`/`showTrash`，schema version 1）对齐 KOS
/// `shell/desktop/modules/dock/DockConfigService.qml:620-623` 的字段语义。
/// 写回沿用旧 kos_dock 文档形状（`pinned: [{kind:"app", desktopId}]` +
/// `schemaVersion: 1`，`b04ecaf^:lib/src/data/dock_store.dart` `DockConfig`），
/// 使 plugin-manager 设置 UI 与插件共享同一文件。
library;

import 'dart:convert';
import 'dart:io';

import 'dock_preferences.dart';

/// 原子、插件自有的偏好存储。保留未知 JSON key；不静默替换损坏文件。
class FileDockPreferencesStore implements DockPreferencesStore {
  FileDockPreferencesStore(this.file);

  final File file;
  int _sequence = 0;

  /// 默认存储路径：`$XDG_CONFIG_HOME/denial/plugins/kos_dock.json`
  /// （搬改 denial_taskbar `taskbar_preferences.dart:58-71`：XDG_CONFIG_HOME
  /// 必须是绝对路径，否则回退 `$HOME/.config`）。
  static File defaultFile() {
    final env = Platform.environment;
    final configured = env['XDG_CONFIG_HOME'];
    final home = env['HOME'];
    final root = configured != null && configured.startsWith('/')
        ? configured
        : home != null && home.startsWith('/')
        ? '$home/.config'
        : null;
    if (root == null) {
      throw const FileSystemException('No configuration directory');
    }
    return File('$root/denial/plugins/kos_dock.json');
  }

  // 搬自 denial_taskbar `taskbar_preferences.dart:73-84`。
  Future<Map<String, dynamic>> _readJson() async {
    try {
      final value = jsonDecode(await file.readAsString());
      if (value is! Map<String, dynamic>) {
        throw const FormatException('Expected a JSON object');
      }
      return value;
    } on FileSystemException catch (error) {
      if (error.osError?.errorCode == 2) return {};
      rethrow;
    }
  }

  /// 读不校验 `version`：缺 version / 未知 version 都按当前 schema 容错解析
  /// （`DockPreferences.fromJson` 忽略 version 与未知 key）。
  @override
  Future<DockPreferences> read() async =>
      DockPreferences.fromJson(await _readJson());

  // 搬改 denial_taskbar `taskbar_preferences.dart:89-103`：读回整份 JSON
  // （保留未知 key、旧文档的 `options` 块与可见性 flag）→ 只替换 pinned
  // 列表 → temp 文件 flush 后 rename 原子落盘。
  //
  // 落盘形状用旧 schemaVersion 1 的 `pinned: [{kind:"app", desktopId}]`
  // （`b04ecaf^:lib/src/data/dock_store.dart` `DockConfig.toJson`），并删除
  // 本移植版早期写的新键 `pinnedApplications`——两键并存时读侧新键优先，
  // 会拿到过期列表。
  @override
  Future<void> writePins(List<PinnedApplication> pins) async {
    final json = await _readJson();
    _writePinsInto(json, pins);
    await _writeJson(json);
  }

  /// 用 [DockPreferences.fromJson] 能读的两种形状里，把 [json] 的 pinned
  /// 列表归一化为旧形状：`pinned: [{kind:"app", desktopId}]`。
  void _writePinsInto(Map<String, dynamic> json, List<PinnedApplication> pins) {
    json.remove('pinnedApplications');
    json['pinned'] = [for (final pin in pins) pin.toLegacyJson()];
  }

  /// 只迁键、不重排、不丢条目：文档已是旧键 `pinned` 时原样保留（里面可能
  /// 有 v1 不渲染的 `spacer`/`folder` kind，重写会丢用户数据）；仅当存在本
  /// 移植版早期的 `pinnedApplications` 键时，把两种形状解析出的 pin 迁到旧键
  /// 并删掉新键。
  void _migratePinsKey(Map<String, dynamic> json) {
    if (!json.containsKey('pinnedApplications')) return;
    _writePinsInto(json, DockPreferences.fromJson(json).pinned);
  }

  /// 只改指定 flag（null = 不改），保留 pinned/另一 flag/未知 key，
  /// 并写 `version: 1`（+ 旧 store 要求的 `schemaVersion`）。
  @override
  Future<void> writeVisibility({bool? showLauncher, bool? showTrash}) async {
    final json = await _readJson();
    if (showLauncher != null) json['showLauncher'] = showLauncher;
    if (showTrash != null) json['showTrash'] = showTrash;
    _migratePinsKey(json);
    await _writeJson(json);
  }
  /// 只改指定信息卡字段（null = 不改），保留 pinned/可见性/未知 key。
  /// `order` 已归一化（未知 id/别名/去重见 [normalizeDockInfoCardOrder]）；
  /// `mode` 透传落盘（读侧 clamp 语义在 [DockPreferences.fromJson]）。
  ///
  /// KOS: dock/DockConfigService.qml:259-273（infoCardOrder/infoCardMode/
  /// infoCardAutoRotate 同文档持久化）。
  @override
  Future<void> writeInfoCards({
    List<String>? order,
    bool? autoRotate,
    String? mode,
  }) async {
    final json = await _readJson();
    if (order != null) json['infoCardOrder'] = List.of(order);
    if (autoRotate != null) json['infoCardAutoRotate'] = autoRotate;
    if (mode != null) json['infoCardMode'] = mode;
    _migratePinsKey(json);
    await _writeJson(json);
  }
  /// writePins/writeVisibility 共用的 temp+rename 原子写；`_sequence`
  /// 保证同进程连续写不重名（搬自 `taskbar_preferences.dart:95-103`）。
  Future<void> _writeJson(Map<String, dynamic> json) async {
    json['version'] = DockPreferences.schemaVersion;
    // 旧 store / plugin-manager 设置 UI 只在 `schemaVersion === 1` 时接受整
    // 份文档（`b04ecaf^:lib/src/data/dock_store.dart` `decodeDockConfig`），
    // 故一并写旧字段；读侧两个字段都不校验。
    json['schemaVersion'] = DockPreferences.schemaVersion;
    await file.parent.create(recursive: true);
    final temp = File('${file.path}.$pid.${_sequence++}.tmp');
    try {
      await temp.writeAsString(
        '${const JsonEncoder.withIndent('  ').convert(json)}\n',
        flush: true,
      );
      await temp.rename(file.path);
    } finally {
      if (await temp.exists()) await temp.delete();
    }
  }
}
