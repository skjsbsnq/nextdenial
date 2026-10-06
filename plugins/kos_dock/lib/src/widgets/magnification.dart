/// KOS Dock magnification → TASK-11 重构为 quickshell 布局级高斯波。
///
/// 背景：旧实现是 KOS 式「固定槽位 + 每图标独立 spring 收敛到自己的
/// smoothstep influence」（KOS `dock/DockIcon.qml:264-318` +
/// `common/AppearanceTokens.qml:441-446`）。TASK-11 按用户拍板重构为
/// quickshell `Common/functions/DockLayout.js:18-58` 的高斯波模型：
///
/// - 槽宽本身随 scale 变：`span = size·weight·scale + gap`——被指图标把
///   相邻图标**连续推开**，整排形成滚动曲面（macOS 手感核心）；
/// - `scale = 1 + A·(M−1)·exp(−d²/2)`，`d = (pointer−center)/(size+gap)`
///   以槽距归一化（σ=1，拖尾 ~±3 槽，比 smoothstep 圆衰减柔）；
/// - `center` 一律用**未缩放**静止坐标累加（DockLayout.js:16-17 明令：
///   动画后的坐标绝不能回喂 magnification，否则 dock 追鼠标自激）；
/// - 唯一缓动是振幅包络 `A`（220ms easeOutCubic + ~80ms 退出防抖，
///   quickshell `DockSurface.qml:91-110,637-644`），指针 x 与各槽位
///   每帧直算、不逐图标 spring。
///
/// 指针广播仍为 KOS `magnificationRoot`/`magnificationPointer` 模式
/// （dock/DockIcon.qml:102-103 + dock/DockContainer.qml:220-222）：容器单一
/// hover 源把指针 x 发给所有图标；`null` 等价 KOS 的 (-10000,-10000)
/// 「无指针」哨兵。
library;

import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// [dockWaveLayout] 输出的单个槽位（对齐 quickshell `DockLayout.js:52`
/// 的 `{start, span, size}` + 本端额外暴露的静止 `center`）。
@immutable
final class DockWaveSlot {
  const DockWaveSlot({
    required this.start,
    required this.span,
    required this.size,
    required this.center,
  });

  /// 槽位左缘（局部坐标，自 `padding` 起累加**已缩放** span 得到）。
  final double start;

  /// 槽位总宽：`size·weight·scale + gap`（末槽是否含尾随 gap 见
  /// [dockWaveLayout] 的 `trailingGap`）。
  final double span;

  /// 本槽视觉边长：`size·weight·scale`（weight=0 槽位恒 0；`unscaled`
  /// 集合内槽位 scale=1 → `size·weight`）。
  final double size;

  /// **静止**布局的槽中心（baseCursor 累加 `size·weight + gap`，
  /// **绝不使用已缩放 span**，DockLayout.js:16-17）——高斯距离 `d`
  /// 的基准。
  final double center;

  @override
  String toString() =>
      'DockWaveSlot(start: $start, span: $span, size: $size, center: $center)';
}

/// quickshell `DockLayout.js:18-58 layout()` 的 Dart 移植（纯函数可单测）。
///
/// 输入：
/// - [weights]：每槽宽度权重——weight=1 槽位的未缩放视觉边长即 [size]
///   （应用图标/launcher/trash 用 `iconSlotSize/iconSize`；divider 等
///   不缩放槽位用「真实槽宽 ÷ size」表达宽度并列入 [unscaled]）；weight≤0
///   或 NaN 的槽位 size=0 只占尾随 gap；
/// - [size]：基准边长（即 quickshell 的 `layout.size`；本端映射
///   `DockMetrics.iconSize`——视觉边长，不是 iconSlotSize）；
/// - [gap]：每槽尾随间距（quickshell `gap=8` 的等价值，本端映射
///   `DockMetrics.itemSpacing`；末槽是否计尾随 gap 由 [trailingGap]
///   控制）；
/// - [padding]：行首内边距（slot 坐标系起点）；
/// - [pointerX]：指针 x（与槽位同一局部坐标系）；null/NaN/±Inf = 无指针
///   → 全槽 scale=1；
/// - [maxScale]：高斯峰值 `M`（quickshell `clamp(magnification,1,2)`，
///   本端常量 `kDockWaveMaxScale`=1.5）；≤1 时全槽 scale=1；
/// - [amplitude]：振幅包络 A∈[0,1]（220ms easeOutCubic 淡入淡出；=0 →
///   全槽 scale=1 → 完全回到静止布局，硬性约束 ④）；
/// - [unscaled]：不参与高斯缩放的槽位下标（divider/信息卡等非应用槽位，
///   硬性约束 ⑥）——它们的 scale 恒 1，但 weight 仍表达槽宽；
/// - [sectionBoundaries]：可选段边界下标——槽位 i 之前若列有边界，先插入
///   [sectionGap] 额外间距（quickshell `sectionBoundary` 的
///   `sectionGap = sectionSpacing + gap`；本端 divider1 以 unscaled 槽位
///   表达宽度，默认不传）；
/// - [trailingGap]：末槽 span 是否含尾随 gap。quickshell 每槽
///   `span=size·w·scale+gap` 恒含 gap；本端对齐旧行自然宽
///   `n·(slot+spacing)−spacing` 需末槽不计 gap，默认 **false**。
///
/// 输出：与 [weights] 等长的 [DockWaveSlot] 列表；`Σspan` 即本帧内容宽
/// （不含 padding——需要总宽时自行 `+ padding`）。
///
/// 公式（逐槽 i）：
/// ```
/// center_i = 静止布局槽中心（baseCursor 累加 `size·weight_i + gap`，
///            **绝不使用已缩放 span**，DockLayout.js:16-17）
/// d_i     = (pointerX − center_i) / (size + gap)
/// scale_i = pointer 无效或 i∈unscaled ? 1
///         : 1 + amplitude·(maxScale−1)·exp(−d_i²/2)
/// span_i  = size·weight_i·scale_i + gap
/// start_i = 已缩放游标累加（padding + Σspan_j<i + 段间距）
/// ```
List<DockWaveSlot> dockWaveLayout({
  required List<double> weights,
  required double size,
  required double gap,
  required double padding,
  required double? pointerX,
  required double maxScale,
  required double amplitude,
  Set<int> unscaled = const <int>{},
  List<int> sectionBoundaries = const <int>[],
  double sectionGap = 0,
  bool trailingGap = false,
}) {
  final count = weights.length;
  final slots = List<DockWaveSlot>.filled(
    count,
    const DockWaveSlot(start: 0, span: 0, size: 0, center: 0),
  );
  if (count == 0) return slots;

  // 边界过滤同 quickshell DockLayout.js:28-29：去重、只留 (0,count)。
  final boundaries = <int>{
    for (final b in sectionBoundaries)
      if (b > 0 && b < count) b,
  };

  // 指针有效性：null/NaN/±Inf 一律视作「无指针」→ scale=1（验收边界；
  // quickshell `!isFinite(pointer)` 同式，DockLayout.js:50）。
  final pointer = pointerX;
  final hasPointer = pointer != null && pointer.isFinite;
  final peak = amplitude.clamp(0.0, 1.0) * (maxScale - 1.0);
  final sigma = size + gap; // d 以槽距归一化（σ=1，DockLayout.js:49）。

  var baseCursor = padding;
  var cursor = padding;
  for (var i = 0; i < count; i++) {
    if (boundaries.contains(i)) {
      baseCursor += sectionGap;
      cursor += sectionGap;
    }
    final weight = weights[i].isFinite ? math.max(0.0, weights[i]) : 0.0;
    // 静止槽中心：baseSpan = size·weight + gap 步进（quickshell
    // `baseCursor + baseSpan/2` 原式；weight≈1.2 时槽心距 = 槽宽+gap，
    // 与实测槽位中心一致 → 指针落在槽中心时 scale 达峰值 M）。
    final baseSpan = size * weight + gap;
    final center = baseCursor + baseSpan / 2;
    double scale = 1.0;
    if (hasPointer && !unscaled.contains(i) && peak > 0 && sigma > 0) {
      final d = (pointer - center) / sigma;
      scale = 1.0 + peak * math.exp(-d * d / 2);
    }
    final span = size * weight * scale + gap;
    slots[i] = DockWaveSlot(
      start: cursor,
      span: i == count - 1 && !trailingGap ? span - gap : span,
      size: size * weight * scale,
      center: center,
    );
    baseCursor += baseSpan;
    cursor += span;
  }
  return slots;
}

/// 波形槽位的插入下标（手写重排的目标位判定）：指针 x 落在第 i 槽
/// 「中线」之前则返回 i，全在右侧则返回 `slots.length`。
///
/// quickshell `DockLayout.js:74-80 insertionIndex`：判定用**已缩放**槽位
/// 的中线（`start + span/2`）——拖动预览跟视觉槽位走。[x] 与槽位 start
/// 同一局部坐标系。
int dockWaveInsertionIndex(List<DockWaveSlot> slots, double x) {
  for (var i = 0; i < slots.length; i++) {
    if (x < slots[i].start + slots[i].span / 2) return i;
  }
  return slots.length;
}

/// 拖拽预览序（手写重排）：把 [sourceIndex] 槽位移到 [gapIndex] 插入位，
/// 返回长度 = count 的下标列表——`result[i]` 是渲染在第 i 槽位的原条目
/// 下标（quickshell `DockLayout.js:84-98 previewOrder` 的语义等价；
/// quickshell 用 −1 幻影槽承载外部拖入，本端只重排既有条目，故直接返回
/// 置换序）。
///
/// [gapIndex] 是**移除前**序列的插入位（∈[0,count]，即
/// [dockWaveInsertionIndex] 的返回值域）：`gap == source` 或
/// `gap == source+1` 时回到原序（插回自己前/后）；越界钳制。
List<int> dockWavePreviewOrder(int count, int sourceIndex, int gapIndex) {
  final order = List<int>.generate(count, (i) => i);
  if (sourceIndex < 0 || sourceIndex >= count) return order;
  order.removeAt(sourceIndex);
  final gap = gapIndex.clamp(0, count);
  // 移除 source 后，位于其后的插入位前移 1（quickshell gapIndex 作用于
  // 原序列；本端直接在移除后的列表上 insert）。
  final insert = (gap > sourceIndex ? gap - 1 : gap).clamp(0, order.length);
  order.insert(insert, sourceIndex);
  return order;
}

/// 容器级指针广播（KOS `magnificationPointer` 语义）。
///
/// 指针的**全局** x 坐标（与槽中心同系——槽中心经
/// `RenderBox.localToGlobal` 量取；宿主广播端同样经 localToGlobal 换算，
/// TASK-04 坐标修正）；`null` 表示指针离开容器，等价 KOS
/// `Qt.point(-10000, -10000)` 哨兵（dock/DockIcon.qml:103、
/// dock/DockContainer.qml:220-222：hovered=false → 哨兵值）。
class MagnificationPointer extends InheritedNotifier<ValueNotifier<double?>> {
  const MagnificationPointer({
    required ValueNotifier<double?> pointerX,
    required super.child,
    super.key,
  }) : super(notifier: pointerX);

  /// 当前指针 x；无 [MagnificationPointer] 祖先或无指针时返回 null。
  static double? of(BuildContext context) => maybeOf(context)?.notifier?.value;

  /// 最近的 [MagnificationPointer]；无祖先时返回 null。
  ///
  /// 供宿主（DockIconRow）区分「容器已广播指针」与「独立宿主需自建
  /// fallback MouseRegion」（TASK-04 指针广播上移到 KosDockShell 后，
  /// 行内不再重复自建）。
  static MagnificationPointer? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<MagnificationPointer>();
}
