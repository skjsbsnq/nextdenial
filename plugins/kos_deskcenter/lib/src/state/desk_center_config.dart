/// DeskCenter 部件配置持久化（`DeskCenterConfig` + `DeskCenterConfigStore`）。
///
/// 对齐 NextKde `DeskCenterConfigService.qml`（98 行）：
/// - `schemaVersion`：源 INI `schemaVersion: 2`（:29）；本文件以 JSON 顶层
///   `schemaVersion` 字段承载同一语义，非 2 一律回退默认（旧 schema 不留
///   迁移路径，与源端「schemaVersion 只是 Settings 属性、无迁移函数」一致）；
/// - `sizesJson`/`orderJson`（:30-31）：源把两份 JSON 字符串内嵌进 INI，
///   本端直接存结构化 JSON 字段 `sizes`/`order`（语义等价）；
/// - 隐藏列表（`hidden`）：源端存 `AppearanceConfigService.
///   hiddenDeskCenterWidgets`（DeskCenterWindow.qml:220、564-566），
///   本端并入同一配置文件（差异记 docs/visual-deltas.md §8）。
///
/// 字段解析语义逐项对齐：
/// - `orderedIds()`（:38-54）：存储序过滤未知 id 与重复，再按
///   `defaultOrder`（:22-24）补齐缺项——存储序优先、缺省项补尾；
/// - `sizeFor`（:69-73）：`sizes[id] ?? defaultSizes[id] ?? "medium"`，
///   经 `normalizedSize`（WidgetLayout.mjs:13-15）归一；
/// - `moveWidget`（:56-67）：剔除 id 后 clamp 插入，写回；
/// - `cycleSize`（:88-93）：`sizeOrder` 循环 small→medium→large→small；
/// - `setSize`（:75-86）：非法档位拒绝。
///
/// 本文件为纯 Dart 模型（`DeskCenterConfig`），不写盘；IO 在
/// `desk_center_config_io.dart`（dart:io，写临时文件 + rename 原子落盘）。
///
/// 源文件行号均指 `/home/wwt/文档/NextKde/shell/desktop/modules/` 相对根。
library;

import '../layout/widget_layout.dart' show WidgetSize, normalizedSize;

/// `schemaVersion 2`（DeskCenterConfigService.qml:29）。
const int kosDeskCenterConfigSchemaVersion = 2;

/// 七种部件的默认排序（DeskCenterConfigService.qml:22-24 `defaultOrder`；
/// 与 DeskCenterWindow.qml:221-228 `widgetDefinitions` 的优先级序一致：
/// clock 100 > weather 90 > calendar 80 > todo 75 > system 70 >
/// activity 60 > music 50）。
const List<String> kosDeskCenterDefaultOrder = [
  'clock',
  'weather',
  'calendar',
  'todo',
  'system',
  'activity',
  'music',
];

/// 默认尺寸表（DeskCenterConfigService.qml:12-20 `defaultSizes`）：
/// 仅 clock 默认 small，其余 medium。
/// TASK-08：Denial 侧 clock 改默认 medium（2×1 长宽条），对齐用户
/// 要求的横条形态；源端 small 仅为 KOS 出厂默认。
const Map<String, WidgetSize> kosDeskCenterDefaultSizes = {
  'clock': WidgetSize.medium,
  'weather': WidgetSize.medium,
  'calendar': WidgetSize.medium,
  'todo': WidgetSize.medium,
  'system': WidgetSize.medium,
  'activity': WidgetSize.medium,
  'music': WidgetSize.medium,
};

/// 部件目录项：标签/符号逐项对应 `widgetLabels`/`widgetSymbols`
/// （DeskCenterWindow.qml:95-102）；部件库面板按此渲染。
final class KosWidgetCatalogEntry {
  const KosWidgetCatalogEntry({
    required this.id,
    required this.label,
    required this.symbol,
    required this.priority,
  });

  final String id;

  /// 中文标签（widgetLabels，:96-98）。
  final String label;

  /// 库条目符号（widgetSymbols，:99-102）。
  final String symbol;

  /// 装箱优先级（widgetDefinitions :222-228 `configuredWidget` 第二参）。
  final int priority;
}

/// 部件库目录（DeskCenterWindow.qml:95-102 + :221-229 的合并视图；
/// 顺序即 `defaultOrder`）。
const List<KosWidgetCatalogEntry> kosWidgetCatalog = [
  KosWidgetCatalogEntry(id: 'clock', label: '时钟', symbol: '◷', priority: 100),
  KosWidgetCatalogEntry(
    id: 'weather',
    label: '天气',
    symbol: '☀',
    priority: 90,
  ),
  KosWidgetCatalogEntry(
    id: 'calendar',
    label: '日历',
    symbol: '▦',
    priority: 80,
  ),
  KosWidgetCatalogEntry(id: 'todo', label: '待办', symbol: '✓', priority: 75),
  KosWidgetCatalogEntry(id: 'system', label: '系统', symbol: '⌁', priority: 70),
  KosWidgetCatalogEntry(
    id: 'activity',
    label: '活动',
    symbol: '◌',
    priority: 60,
  ),
  KosWidgetCatalogEntry(id: 'music', label: '音乐', symbol: '♫', priority: 50),
];

/// `sizeOrder`（WidgetLayout.mjs:1）的循环序。
const List<WidgetSize> _sizeOrder = [
  WidgetSize.small,
  WidgetSize.medium,
  WidgetSize.large,
];

String _sizeName(WidgetSize size) => switch (size) {
  WidgetSize.small => 'small',
  WidgetSize.medium => 'medium',
  WidgetSize.large => 'large',
};

/// DeskCenter 部件配置（不可变；每次变更产出新实例）。
///
/// 对应源端三个持久化来源的合并视图：`orderJson`（:63）→ [order]、
/// `sizesJson`（:82）→ [sizes]、`hiddenDeskCenterWidgets` → [hidden]。
final class DeskCenterConfig {
  const DeskCenterConfig({required this.order, required this.sizes})
    : hidden = const <String>{};

  const DeskCenterConfig._({
    required this.order,
    required this.sizes,
    required this.hidden,
  });

  /// 默认配置：defaultOrder 全量、默认尺寸表、无隐藏。
  factory DeskCenterConfig.defaults() => const DeskCenterConfig(
    order: kosDeskCenterDefaultOrder,
    sizes: kosDeskCenterDefaultSizes,
  );

  /// 部件显示序（已按 `orderedIds()` 语义过滤/补全，必含全部 7 个 id）。
  final List<String> order;

  /// 各部件尺寸档位；缺项按 [kosDeskCenterDefaultSizes]/medium 归一。
  final Map<String, WidgetSize> sizes;

  /// 隐藏部件集合（源 `hiddenDeskCenterWidgets`）。
  final Set<String> hidden;

  /// `orderedIds()`（DeskCenterConfigService.qml:38-54）：本类的
  /// [order] 字段恒为该函数结果（构造/解析时已过滤+补全）。
  List<String> orderedIds() => List.unmodifiable(order);

  /// `sizeFor`（:69-73）：存储值 → 默认表 → medium，经 normalizedSize。
  WidgetSize sizeFor(String widgetId) =>
      sizes[widgetId] ?? kosDeskCenterDefaultSizes[widgetId] ?? WidgetSize.medium;

  /// `cycleSize`（:88-93）：返回循环后的新配置（sizeOrder 循环）。
  DeskCenterConfig cycleSize(String widgetId) {
    final current = sizeFor(widgetId);
    final next =
        _sizeOrder[(_sizeOrder.indexOf(current) + 1) % _sizeOrder.length];
    return setSize(widgetId, next);
  }

  /// `setSize`（:75-86）：非 sizeOrder 值不可达（强类型），写回 sizes。
  DeskCenterConfig setSize(String widgetId, WidgetSize size) =>
      _copy(sizes: {...sizes, widgetId: size});

  /// `moveWidget`（:56-67）：把 [widgetId] 移到索引 [rawIndex]
  /// （clamp 到 [0, len-1]），其余保持相对序。
  DeskCenterConfig moveWidget(String widgetId, int rawIndex) {
    final next = order.where((id) => id != widgetId).toList();
    if (next.length == order.length) return this; // :59-60 未知 id 不动
    final index = rawIndex.clamp(0, next.length); // :61
    next.insert(index, widgetId);
    return _copy(order: next);
  }

  /// `setDeskCenterWidgetVisible`（DeskCenterWindow.qml:564-566、443-445）。
  DeskCenterConfig setVisible(String widgetId, bool visible) {
    if (!kosDeskCenterDefaultOrder.contains(widgetId)) return this;
    final next = {...hidden};
    if (visible) {
      next.remove(widgetId);
    } else {
      next.add(widgetId);
    }
    return _copy(hidden: next);
  }

  bool isVisible(String widgetId) => !hidden.contains(widgetId);

  DeskCenterConfig _copy({
    List<String>? order,
    Map<String, WidgetSize>? sizes,
    Set<String>? hidden,
  }) => DeskCenterConfig._(
    order: order ?? this.order,
    sizes: sizes ?? this.sizes,
    hidden: hidden ?? this.hidden,
  );

  /// 持久化 JSON：`{schemaVersion:2, order:[id...], sizes:{id:size},
  /// hidden:[id...]}`（sizesJson/orderJson 语义的结构化形态，:30-31）。
  Map<String, Object?> toJson() => {
    'schemaVersion': kosDeskCenterConfigSchemaVersion,
    'order': order,
    'sizes': {
      for (final entry in sizes.entries)
        entry.key: _sizeName(entry.value),
    },
    'hidden': [
      for (final id in kosDeskCenterDefaultOrder)
        if (hidden.contains(id)) id,
    ],
  };

  /// 容错解析：任何字段缺失/非法都按源语义归一，不抛异常。
  /// `schemaVersion != 2`、非 Map 入参 → [DeskCenterConfig.defaults]。
  factory DeskCenterConfig.fromJson(Object? json) {
    if (json is! Map) return DeskCenterConfig.defaults();
    final version = switch (json['schemaVersion']) {
      final num v => v.toInt(),
      _ => 0,
    };
    if (version != kosDeskCenterConfigSchemaVersion) {
      return DeskCenterConfig.defaults();
    }
    // orderJson 语义（:38-54）：存储序滤未知/重复 → defaultOrder 补尾。
    final stored = <String>[
      if (json['order'] is List)
        for (final raw in json['order'] as List)
          if (raw is String) raw,
    ];
    final order = <String>[];
    for (final id in stored) {
      if (kosDeskCenterDefaultOrder.contains(id) && !order.contains(id)) {
        order.add(id);
      }
    }
    for (final id in kosDeskCenterDefaultOrder) {
      if (!order.contains(id)) order.add(id);
    }
    final sizes = <String, WidgetSize>{
      if (json['sizes'] is Map)
        for (final entry in (json['sizes'] as Map).entries)
          if (kosDeskCenterDefaultOrder.contains(entry.key))
            entry.key.toString(): _parseSize(entry.value),
    };
    final hidden = <String>{
      if (json['hidden'] is List)
        for (final raw in json['hidden'] as List)
          if (raw is String && kosDeskCenterDefaultOrder.contains(raw)) raw,
    };
    return DeskCenterConfig._(order: order, sizes: sizes, hidden: hidden);
  }

  /// `normalizedSize` 委托（WidgetLayout.mjs:13-15）：非法值 → medium。
  static WidgetSize _parseSize(Object? value) =>
      normalizedSize(value?.toString());

  @override
  bool operator ==(Object other) =>
      other is DeskCenterConfig &&
      _listEquals(order, other.order) &&
      _mapEquals(sizes, other.sizes) &&
      hidden.length == other.hidden.length &&
      hidden.containsAll(other.hidden);

  @override
  int get hashCode => Object.hash(
    Object.hashAll(order),
    Object.hashAll(sizes.entries.map((e) => Object.hash(e.key, e.value))),
    Object.hashAll(hidden),
  );

  static bool _listEquals(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static bool _mapEquals(Map<String, WidgetSize> a, Map<String, WidgetSize> b) {
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (b[entry.key] != entry.value) return false;
    }
    return true;
  }
}
