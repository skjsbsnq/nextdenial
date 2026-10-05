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
/// Dock 信息卡 id 归一化：`temperature` → `metrics`（KOS `normalizedInfoCardOrder`
/// 的别名规则），其它原样返回（不做 trim/lowercase——id 集合是封闭枚举）。
///
/// KOS: dock/DockConfigService.qml:283-352（normalizedInfoCardOrder）。
String normalizeDockInfoCardId(String id) =>
    id == 'temperature' ? 'metrics' : id;

/// 已知信息卡 id 集合（KOS `infoCardOrder` 合法值）。
const Set<String> kDockInfoCardIds = {'music', 'weather', 'clock', 'metrics'};

/// `normalizedInfoCardOrder` 语义：逐条 `temperature`→`metrics` 别名替换、
/// 未知 id 丢弃、去重，保持入参相对顺序。
///
/// KOS: dock/DockConfigService.qml:283-352（未知 id 丢弃 + 去重 + 别名）。
List<String> normalizeDockInfoCardOrder(Iterable<dynamic> order) {
  final seen = <String>{};
  final normalized = <String>[];
  for (final raw in order) {
    if (raw is! String) continue;
    final id = normalizeDockInfoCardId(raw);
    if (!kDockInfoCardIds.contains(id) || !seen.add(id)) continue;
    normalized.add(id);
  }
  return List.unmodifiable(normalized);
}
/// 天气快照订阅门控（`KosDockShell` 与 `DockInfoCarousel` **共用同一判据**，
/// 避免两处表达式漂移）：order 里**含 `weather` 或含 `clock`** 时才需要天气
/// 数据——weather 页直接用快照，而 clock 页的日出/日落行走**同一份**快照
/// （`DockClockWidget.qml:63-92` `SolarEventRow` ← `WeatherService.
/// sunriseTime/sunsetTime`），因此**不能**只按 `contains('weather')` 门控
/// （否则「clock 在 order 里、weather 不在」时会退化成日出/日落恒 `--:--`）。
/// 判据为假（或偏好尚未读到）时不订阅 `dockWeatherSnapshotProvider`，
/// 其默认实现是真实网络轮询（`state/dock_settings.dart:63-67`）。
///
/// **KOS 语义差**（记 docs/visual-deltas.md TASK-05 节）：KOS 侧
/// `WeatherService` 是 shell 全局常驻服务，与「哪几张信息卡被选中」无关
/// （`DockContainer.qml:48-49` 只据它决定 weather 卡是否**可用**）；本端把
/// 订阅本身收敛到卡片集合，属移植期收敛。
bool dockInfoCardNeedsWeather(List<String> infoCardOrder) =>
    infoCardOrder.contains('weather') || infoCardOrder.contains('clock');

/// Dock 偏好：pinned 列表 + 启动器/垃圾桶可见性开关 + 信息卡配置。
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
/// 信息卡字段（TASK-05）：`infoCardOrder` 默认
/// `[music,weather,clock,metrics]`（DockConfigService.qml:259-273）；
/// `infoCardAutoRotate` 默认 true（`!== false` 同式）；`infoCardMode` 只读，
/// 默认 `"carousel"`、非 carousel 值按 carousel 处理（记 visual-deltas）。
class DockPreferences {
  const DockPreferences({
    this.pinned = const [],
    this.showLauncher = true,
    this.showTrash = true,
    this.infoCardOrder = kDockInfoCardOrderDefault,
    this.infoCardAutoRotate = true,
    this.infoCardMode = 'carousel',
  });

  /// 信息卡默认顺序（KOS: dock/DockInfoCarousel.qml:21
  /// `cardOrder: ["music","weather","clock","metrics"]`）。
  static const List<String> kDockInfoCardOrderDefault = [
    'music',
    'weather',
    'clock',
    'metrics',
  ];

  /// 落盘 schema 版本：store 的每条写路径都写此值（读侧不校验版本，缺
  /// version/未知 version 不影响解析）。
  static const int schemaVersion = 1;

  final List<PinnedApplication> pinned;
  final bool showLauncher;
  final bool showTrash;

  /// 信息卡顺序（已归一化：`temperature`→`metrics`、未知 id 丢弃、去重）。
  ///
  /// 空列表 = info 区整体隐藏（KOS `hasInfo = hasAvailableInfo &&
  /// !hideInfoCarousel`，dock/DockContainer.qml:57,141-143）：`fromJson` 对
  /// 键存在且可解析的 order **原样保留（含空）**，`KosDockShell` 据此把
  /// `hasInfo` 转 false（撤销 info 槽与 divider2）；写路径
  /// （`DockPreferencesController.updateInfoCardOrder`）同样允许空。
  final List<String> infoCardOrder;

  /// 自动轮播（`!== false`：仅显式 false 关闭；缺失/非 bool 保留 true）。
  final bool infoCardAutoRotate;

  /// 信息卡模式（只读；非 `"carousel"` 值按 carousel 处理，记 deltas）。
  final String infoCardMode;

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
    // 信息卡字段（TASK-05）：`infoCardOrder` 接受 List 或单 String；
    // `infoCardAutoRotate` 用 `!== false`；`infoCardMode` 只读、非 carousel
    // 值按 carousel 处理（记 docs/visual-deltas.md）。
    //
    // **空 order 语义（KOS「零项 = 隐藏信息卡区」）**：键缺失（或值形状
    // 不是 List/String 这类可解析序）→ 默认四卡；键存在且可解析时**原样
    // 保留归一化结果（含空）**——用户删光信息卡后重启不得复活四卡
    // （KOS `normalizedInfoCardOrder([])` 保持 `[]`，
    // dock/DockConfigService.qml:266-269,307-317；`hasInfo` 随之 false）。
    final hasOrderKey = json.containsKey('infoCardOrder');
    final rawOrder = json['infoCardOrder'];
    final parsedOrder = normalizeDockInfoCardOrder(
      rawOrder is List
          ? rawOrder
          : rawOrder is String
          ? [rawOrder]
          : const [],
    );
    return DockPreferences(
      pinned: List.unmodifiable(pins),
      // KOS DockConfigService.qml:622-623 `!== false` 语义：只有 JSON 里
      // 显式写了 false 才隐藏；缺失/null/非 bool 一律保留 true。
      showLauncher: json['showLauncher'] != false,
      showTrash: json['showTrash'] != false,
      infoCardOrder:
          !hasOrderKey || (rawOrder is! List && rawOrder is! String)
          ? DockPreferences.kDockInfoCardOrderDefault
          : parsedOrder,
      infoCardAutoRotate: json['infoCardAutoRotate'] != false,
      infoCardMode:
          json['infoCardMode'] is String ? json['infoCardMode']! as String : 'carousel',
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

  /// 只改指定的信息卡字段（`null` = 不改）；pinned/可见性/未知 key 由
  /// 实现层保留。`order` 写入前已经 [normalizeDockInfoCardOrder] 归一化；
  /// `mode` 只读透传（实现层原样落盘，读侧 clamp 见 [DockPreferences]）。
  ///
  /// KOS: dock/DockConfigService.qml:283-352（addInfoCard/removeInfoCard/
  /// moveInfoCard 写回同一 JSON 文档）。
  Future<void> writeInfoCards({
    List<String>? order,
    bool? autoRotate,
    String? mode,
  });
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
