/// KOS Dock pinned 应用偏好模型（纯接口/模型层，无 dart:io）。
///
/// 移植自 denial_taskbar `lib/src/taskbar_preferences.dart`（逐行搬改，
/// 源文件逐块标注行号）：去掉 taskbar 的 `leftAligned`/IO 实现——IO 分离到
/// `dock_preferences_io.dart`（CONSTRAINTS §10）；`DockOrder` 保留
/// `TaskbarOrder` 的 pinned 相对顺序持久化 + reorder 语义，并收敛为
/// pinned-only：kos_dock 行渲染喂给 `update` 的集合恒为 pinned 键
/// （未 pin 运行应用不进 DockOrder 合并，CONSTRAINTS §5）。
library;

/// 应用/窗口 id 归一化：trim → lowercase → 去 `.desktop` 后缀。
///
/// 搬自 denial_taskbar `taskbar_preferences.dart:4-5`。
String normalizeApplicationId(String id) =>
    id.trim().toLowerCase().replaceFirst(RegExp(r'\.desktop$'), '');

/// 一个 pinned 应用条目。
///
/// `id` 是持久化的 opaque launch id（`LaunchableApplication.id`，
/// PLUGIN_DEVELOPMENT.md 语义：launch 用 id、icon 用 appId、窗口匹配走
/// `windowAppIds` 别名）。结构搬自 denial_taskbar
/// `taskbar_preferences.dart:7-17`。
class PinnedApplication {
  const PinnedApplication({
    required this.id,
    required this.appId,
    required this.name,
  });

  final String id;
  final String appId;
  final String name;

  Map<String, String> toJson() => {'id': id, 'appId': appId, 'name': name};

  /// 旧格式（schemaVersion 1 的 `pinned` 数组）条目形状：
  /// `{kind: "app", desktopId}`。`desktopId` 取 launch 用的 [appId]，
  /// 缺失时回退 [id]。写入恒用此形状：`~/.config/denial/plugins/
  /// kos_dock.json` 由旧 kos_dock / plugin-manager 设置 UI 消费
  /// （旧 `DockAppPin.toJson` @ `b04ecaf^:lib/src/data/dock_store.dart`
  /// `DockAppPin` 段：`{'kind': 'app', 'desktopId': desktopId}`）。
  Map<String, String> toLegacyJson() => {
    'kind': 'app',
    'desktopId': appId.isEmpty ? id : appId,
  };
}

/// Dock 偏好：pinned 列表 + 启动器/垃圾桶可见性开关。
///
/// 容错解析搬自 denial_taskbar `taskbar_preferences.dart:24-48`：非法条目
/// 跳过、按 `normalizeApplicationId(id)` 去重、未知 JSON key 由 store 层
/// 写回时保留。
/// 读取同时接受两种落盘形状（见 [DockPreferences.fromJson]）：旧
/// `schemaVersion 1` 文档的 `pinned: [{kind:"app", desktopId}]` 与新格式
/// `pinnedApplications: [{id, appId, name}]`。
/// `showLauncher`/`showTrash` 对齐 KOS
/// `shell/desktop/modules/dock/DockConfigService.qml:620-623`
/// （`obj.showLauncher !== false`：仅显式 `false` 隐藏；缺失/非 bool
/// 保留默认可见）。
class DockPreferences {
  const DockPreferences({
    this.pinned = const [],
    this.showLauncher = true,
    this.showTrash = true,
  });

  /// 落盘 schema 版本：store 的每条写路径都写此值（读侧不校验版本，缺
  /// version/未知 version 不影响解析）。
  static const int schemaVersion = 1;

  final List<PinnedApplication> pinned;
  final bool showLauncher;
  final bool showTrash;

  factory DockPreferences.fromJson(Map<String, dynamic> json) {
    final seen = <String>{};
    final pins = <PinnedApplication>[];
    // 两种落盘形状都读，按文件顺序合并（新键在前，旧键在后）：
    // - `pinnedApplications`：本移植版早期写出的 `{id, appId, name}`
    //   （denial_taskbar `taskbar_preferences.dart:24-48`）；
    // - `pinned`：schemaVersion 1 的旧 kos_dock / plugin-manager 设置 UI
    //   形状 `{kind: "app", desktopId}`（`b04ecaf^:lib/src/data/
    //   dock_store.dart` `_decodeDockPin`：非 `app` kind 静默跳过）。
    for (final key in const ['pinnedApplications', 'pinned']) {
      if (json[key] case final List entries) {
        for (final entry in entries) {
          final pin =
              _decodeLegacyPin(entry) ?? _decodeApplicationPin(entry);
          if (pin == null) continue;
          final dedupKey = normalizeApplicationId(pin.id);
          if (dedupKey.isEmpty || !seen.add(dedupKey)) continue;
          pins.add(pin);
        }
      }
    }
    return DockPreferences(
      pinned: List.unmodifiable(pins),
      // KOS DockConfigService.qml:622-623 `!== false` 语义：只有 JSON 里
      // 显式写了 false 才隐藏；缺失/null/非 bool 一律保留 true。
      showLauncher: json['showLauncher'] != false,
      showTrash: json['showTrash'] != false,
    );
  }
}

/// 新格式条目（`pinnedApplications` 数组）：`{id, appId, name}` 三者都
/// 必须是非空 String，否则跳过（同 denial_taskbar
/// `taskbar_preferences.dart:24-48` 的容错）。
PinnedApplication? _decodeApplicationPin(Object? entry) {
  if (entry is! Map) return null;
  final id = entry['id'];
  final appId = entry['appId'];
  final name = entry['name'];
  if (id is! String ||
      id.isEmpty ||
      appId is! String ||
      appId.isEmpty ||
      name is! String) {
    return null;
  }
  return PinnedApplication(id: id, appId: appId, name: name);
}

/// 旧格式条目（`pinned` 数组，schemaVersion 1）：
/// `{kind: "app", desktopId[, name]}` → pin（`desktopId` 同时作 launch id
/// 与 icon appId；`name` 缺失/非 String 记为 `''`，由图标行按 desktopId
/// 反查显示名）。
///
/// 其它 kind（`spacer` / `small-spacer` / `folder` / `file` /
/// `separator`：旧 `DockModel.js:67-81`）以及非法条目**静默跳过**，不使
/// 整份文档失效——v1 没有这些槽位类型，但也不能因此丢掉用户的 app pin。
PinnedApplication? _decodeLegacyPin(Object? entry) {
  if (entry is! Map) return null;
  if (entry['kind'] != 'app') return null;
  final desktopId = entry['desktopId'];
  if (desktopId is! String || desktopId.isEmpty) return null;
  final name = entry['name'];
  return PinnedApplication(
    id: desktopId,
    appId: desktopId,
    name: name is String ? name : '',
  );
}

/// 偏好存储接口（CONSTRAINTS §10 接口/IO 分离：dart:io 实现见
/// `FileDockPreferencesStore`）。语义对齐 denial_taskbar
/// `taskbar_preferences.dart:51-52`：原子、插件自有；写 pins/可见性时保留
/// 文件里未知 JSON key（含旧文档的 `options` 块）与 `showLauncher`/
/// `showTrash`；损坏/不可读文件不得静默覆盖。
/// 落盘恒用旧 schemaVersion 1 形状（`pinned: [{kind:"app", desktopId}]`，
/// 见 [PinnedApplication.toLegacyJson]），使 plugin-manager 设置 UI 继续
/// 可读可写同一文件。
abstract interface class DockPreferencesStore {
  Future<DockPreferences> read();
  Future<void> writePins(List<PinnedApplication> pins);

  /// 只改指定的可见性 flag（`null` = 不改）；pinned/另一 flag/未知 key
  /// 由实现层保留（见 `dock_preferences_io.dart`）。
  Future<void> writeVisibility({bool? showLauncher, bool? showTrash});
}

/// pinned 顺序模型。
///
/// 搬自 denial_taskbar `taskbar_preferences.dart:106-151`（`TaskbarOrder`），
/// 收敛为 pinned-only（方案 B，2026-10-05）：kos_dock 行渲染只让
/// `update` 管 pinned 键的相对顺序，未 pin 运行键由 `dockRowEntries`
/// 的首次出现顺序直接给（dock_icons.dart），原「live 集 = pinned +
/// `run:` 运行键 → rest 合并」分支已删。`reorder` 写回语义不变（只动
/// pinned 段，见 dock_icons.dart 的边界钳制）。
class DockOrder {
  final _keys = <String>[];
  List<String> _pins = [];

  /// 返回稳定顺序的 pinned 键列表：pinned 相对顺序稳定，新 pin 追加
  /// 尾部，消失的键丢弃。
  ///
  /// `pinned` 参数与上一次不同（重排写回 / 增删 pin）时以参数为准；
  /// 相同时保持本地顺序，这样 `reorder` 的乐观顺序不会在写回落地前
  /// 回弹。
  List<String> update(Iterable<String> pinned) {
    final nextPins = pinned.toList();
    _keys.removeWhere((key) => !nextPins.contains(key));
    final pinOrder = _same(_pins, nextPins)
        ? List<String>.of(_keys)
        : List<String>.of(nextPins);
    for (final key in nextPins) {
      if (!pinOrder.contains(key)) pinOrder.add(key);
    }
    _pins = List.of(nextPins);
    _keys
      ..clear()
      ..addAll(pinOrder);
    return List.unmodifiable(_keys);
  }

  /// 把 `from` 处的键移到 `to`；越界调用原样返回当前顺序。
  List<String> reorder(int from, int to) {
    if (from < 0 || from >= _keys.length || to < 0 || to >= _keys.length) {
      return List.unmodifiable(_keys);
    }
    final key = _keys.removeAt(from);
    _keys.insert(to, key);
    return List.unmodifiable(_keys);
  }

  static bool _same(List<String> a, List<String> b) =>
      a.length == b.length &&
      List.generate(a.length, (i) => a[i] == b[i]).every((v) => v);
}
