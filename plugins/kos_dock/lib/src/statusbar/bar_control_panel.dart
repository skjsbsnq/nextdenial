import 'dart:math' as math;

import 'package:denial_flutter_sdk/popups.dart';
import 'package:denial_flutter_sdk/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 控制中心占位弹层——NextKde `ControlCenterPanel.qml`（3037 行，daemon 依
/// 赖）的壳；真实 11 张卡片群后续迭代再填（APPROVED-PLAN 已砍模块清单）。
///
/// - `ShellPopupController.show` 托管：`keyName: kos_dock.control_center`
///   幂等（连点不叠层）；`dismissPolicy: outsideTapAndEscape`（点外/Esc
///   关闭，`ShellPopupHost` 内置 scrim + Esc 处理）；`handle.close()` 供
///   面板内按钮自关。
/// - `transitionDuration` 用托管默认 `Motion.cardSettle`(220ms) 淡入 +
///   host 内置 `ScaleTransition`——NextKde PopupMotion 的 150ms OutCubic +
///   scale 0.96→1 + 20px 位移不逐帧复刻，差异记入 visual-deltas.md
///   （TASK-TB-06 钉死「本版用托管 cardSettle」）。
/// - `barrierColor: transparent`：顶栏下拉浮层不需要 overview scrim 压暗
///   （NextKde 面板无遮罩底）。
/// - 锚定（底栏版）：`anchorRect`（按钮 `localToGlobal` 全局 Rect）→
///   `Positioned` `bottom: screenHeight - anchor.top + 4`（面板底边贴按钮
///   顶，从底栏向上弹）、`right: screenWidth - anchor.right`（clamp ≥8）；
///   `anchorRect == null` 退化 `bottom: 64, right: 8`（底栏右缘默认位）。
/// - 尺寸 336×597（NextKde ControlCenterPanel 源值），高 clamp 到屏高。
const String kControlCenterPopupKey = 'kos_dock.control_center';

/// 开控制中心占位弹层；返回 `ShellPopupHandle`（调用方一般忽略——面板内
/// `handle.close` 已接线）。
ShellPopupHandle showControlCenterPanel(
  WidgetRef ref, {
  Rect? anchorRect,
}) {
  return ref.read(shellPopupControllerProvider.notifier).show(
    debugLabel: 'kos_dock.control_center',
    keyName: kControlCenterPopupKey,
    barrierColor: Colors.transparent,
    builder: (popupContext, handle) =>
        TopBarControlCenterPanel(anchorRect: anchorRect, onClose: handle.close),
  );
}

/// 占位面板本体：`Positioned` 锚定 + 336×597 圆角大卡片（非 999 胶囊——
/// 控制中心是 sheet，`16 × cornerRadiusScale` 圆角走主题缩放）。
class TopBarControlCenterPanel extends StatelessWidget {
  const TopBarControlCenterPanel({
    required this.onClose,
    this.anchorRect,
    super.key,
  });

  /// 触发按钮的全局 Rect；`null` 时退化到顶栏右缘固定锚点。
  final Rect? anchorRect;

  /// 面板内关闭回调（`ShellPopupHandle.close`）。
  final VoidCallback onClose;

  static const double _width = 336;
  static const double _height = 597;

  @override
  Widget build(BuildContext context) {
    final theme = context.shellTheme;
    final screen = MediaQuery.sizeOf(context);
    final anchor = anchorRect;
    // 底栏向上弹：面板底边距 = 屏高 - 按钮顶 + 4px 间隙（与 WiFi 面板同式）。
    final bottom = anchor != null ? (screen.height - anchor.top + 4) : 64.0;
    final right = anchor != null
        ? (screen.width - anchor.right).clamp(8.0, screen.width)
        : 8.0;
    return Stack(
      children: [
        Positioned(
          bottom: bottom,
          right: right,
          child: Material(
            type: MaterialType.transparency,
            child: Container(
              width: _width,
              // 屏高不足时收缩（NextKde margins 语义的小屏保护）。
              height: math.min(
                _height,
                // 面板底边距 bottom，向上最多长到距屏顶 8px：可用高 = bottom - 8。
                math.max(0.0, bottom - 8),
              ),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: theme.cardColor(
                  Theme.of(context).colorScheme.surfaceContainer,
                ),
                borderRadius: theme.borderRadius(16),
                border: Border.all(
                  color: Theme.of(
                    context,
                  ).colorScheme.outlineVariant.withValues(alpha: 0.65),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '控制中心',
                    style: theme.text.systemBarValue.copyWith(
                      color: theme.colors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '控制中心占位（后续迭代填充快捷开关卡片群）。',
                    style: theme.text.systemBarCaption.copyWith(
                      color: theme.colors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}
