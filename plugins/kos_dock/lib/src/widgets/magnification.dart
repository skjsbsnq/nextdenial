/// KOS Dock magnification：纯数学函数 + 容器级指针广播。
///
/// 数值逐项对齐 NextKde（源根
/// `/home/wwt/文档/NextKde/shell/desktop/modules/`）：
/// - 半径 `max(iconSize*2, 140)`（KOS: dock/DockIcon.qml:271-272 ←
///   common/AppearanceTokens.qml:443）；
/// - smoothstep `n*n*(3-2*n)`（KOS: dock/DockIcon.qml:276-278）；
/// - scale/lift（KOS: dock/DockIcon.qml:280-288 ←
///   AppearanceTokens.qml:444-445）。
/// 指针广播为 KOS `magnificationRoot`/`magnificationPointer` 模式
/// （dock/DockIcon.qml:102-103 + dock/DockContainer.qml:220-222）：容器单一
/// hover 源把指针 x 发给所有图标；`null` 等价 KOS 的 (-10000,-10000)
/// 「无指针」哨兵。
library;

import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../theme/dock_tokens.dart';

/// magnification 纯函数集。
abstract final class DockMagnification {
  /// 影响半径：`max(iconSize*2, 140)`。
  ///
  /// KOS: dock/DockIcon.qml:271-272
  /// `Math.max(icon.iconSize * 2.0, AppearanceTokens.dock.magnificationRadius)`；
  /// 140 来自 common/AppearanceTokens.qml:443（macOS 分支）。
  static double radius(double iconSize) =>
      math.max(iconSize * 2.0, kDockMagnificationRadius);

  /// 距离 → 影响权重 [0,1]：smoothstep `n*n*(3-2n)`，`n` 为钳位后的
  /// `1 - |dx|/radius`。
  ///
  /// KOS: dock/DockIcon.qml:276-278。边界：|dx|≥radius → 0；dx=0 → 1。
  static double influence(double dx, double radius) {
    if (radius <= 0 || !dx.isFinite) return 0.0;
    final n = (1.0 - dx.abs() / radius).clamp(0.0, 1.0);
    return n * n * (3.0 - 2.0 * n);
  }

  /// 视觉缩放：`1 + influence*(1.19-1)`。
  ///
  /// KOS: dock/DockIcon.qml:280-282 ← AppearanceTokens.qml:444。
  static double scale(double influence) =>
      1.0 + influence * (kDockMagnificationMaxScale - 1.0);

  /// 抬升量（负 y）：`-iconSize*0.04*influence`（亚像素，不取整）。
  ///
  /// KOS: dock/DockIcon.qml:285-288 ← AppearanceTokens.qml:445。
  static double lift(double iconSize, double influence) =>
      -iconSize * kDockMagnificationLiftRatio * influence;
}

/// 容器级指针广播（KOS `magnificationPointer` 语义）。
///
/// 指针的**全局** x 坐标（与 DockIcon/内建图标的槽中心同系——槽中心经
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
