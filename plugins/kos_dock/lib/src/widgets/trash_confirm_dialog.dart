/// KOS Dock 清空回收站确认弹窗（TASK-04）。
///
/// 对齐 NextKde（源根 `/home/wwt/文档/NextKde/shell/desktop/modules/`）：
/// - `dock/DockTrashConfirmPopup.qml:4-9`：`DesktopConfirmDialog` +
///   `confirmEnabled: !DockTrashService.emptying`、`confirmBusy`、
///   `onAccepted: DockTrashService.empty()`；
/// - `common/DesktopConfirmDialog.qml:9-26`：标题「确定要清空回收站吗？」、
///   正文「所有项目都将被永久删除。\n此操作无法撤销。」、确认「清空回收站」、
///   取消「取消」、`dismissOnBackdrop: true`；
/// - `common/DesktopConfirmDialog.qml:37-170`：内容宽 `min(340, w−44)`、
///   58px 圆 icon 底（textPrimary@0.08、边 @0.34、中心 28px trash 图标）
///   → 12 → 标题 17 Bold → 4 → 正文 13 次级色 → 22 → 34 高半宽按钮
///   （radius 17、margin 16、间距 8），busy 文案「正在处理…」+ 禁用；
/// - 确认色 `#ff3b30`（DesktopConfirmDialog.qml:160）按 CONSTRAINTS §3
///   映射语义色 `shellColors.performanceBad`。
///
/// Denial 无独立 PopupWindow：OverlayPortal + fullScene 输入区 + 透明
/// barrier（点外=取消）近似 `modal + backdropMode:"none"`；KOS 顶部
/// 24px help 装饰钮（DesktopConfirmDialog.qml:174-199）省略，记
/// docs/visual-deltas.md。
library;

import 'dart:math' as math;

import 'package:denial_flutter_sdk/effects.dart' show ShellBackdropBlur;
import 'package:denial_flutter_sdk/input.dart';
import 'package:denial_flutter_sdk/shell_theme.dart';
import 'package:denial_flutter_sdk/surfaces.dart'
    show ShellSurfacePresentation;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/dock_tokens.dart';
import 'dock_preview_popup.dart';

/// 清空回收站确认弹窗：`visible` 由持有者经 [TrashConfirmDialogState.open]
/// 触发；[onConfirm] 为真实清空动作（`TrashService.empty()`）。
class TrashConfirmDialog extends StatefulWidget {
  const TrashConfirmDialog({
    required this.onConfirm,
    this.coordinator,
    this.child,
    super.key,
  });

  /// 确认动作；抛错时弹窗复位并 debugPrint（KOS
  /// `DockTrashService.empty()` 失败路径 DockTrashService.qml:36-49）。
  final Future<void> Function() onConfirm;

  /// 布局占位子件（垃圾桶图标槽位；OverlayPortal 本身不占布局）。
  final Widget? child;

  /// 全 pill popup 协调器（KOS `DockModelService.activeDockPopup`；null →
  /// 无协调，独立宿主/单测退化）。确认弹窗同样计入 popup 单例：打开时
  /// 抢占（立即收掉 pinned 预览/菜单、trash 菜单），关闭时释放。
  final DockPopupCoordinator? coordinator;

  @override
  State<TrashConfirmDialog> createState() => TrashConfirmDialogState();
}

class TrashConfirmDialogState extends State<TrashConfirmDialog>
    implements DockPopup {
  final _portal = OverlayPortalController();
  bool _open = false;
  bool _busy = false;

  /// 弹窗当前是否展示（测试/持有者查询）。
  bool get isOpen => _open;

  /// 打开弹窗（事件回调中调用，不在 build 中调用）。
  void open() {
    if (_open) return;
    // KOS: dock/DockModelService.qml:65-72 `openDockPopup` —— 先立即收掉
    // 当前活跃 popup（pinned 预览/菜单、trash 菜单），本弹窗成为唯一
    // activeDockPopup。
    widget.coordinator?.activate(this);
    setState(() {
      _open = true;
      _busy = false;
    });
    _portal.show();
  }
  /// 取消/点外/Esc：关闭并复位。
  void _cancel() => _dismiss();

  void _dismiss() {
    if (!_open) return;
    _portal.hide();
    setState(() {
      _open = false;
      _busy = false;
    });
    // KOS: dock/DockModelService.qml:74-77 `releaseDockPopup`。
    widget.coordinator?.release(this);
  }

  /// [DockPopup] 契约：被其他 popup 抢占时立即收场（KOS
  /// `dismissDockPopupImmediately`，dock/DockModelService.qml:56-63,65-72）。
  @override
  void dismissDockPopupImmediately() => _dismiss();

  @override
  void dispose() {
    widget.coordinator?.release(this);
    super.dispose();
  }

  /// 确认：busy → `await onConfirm()` → 成功关闭；失败 debugPrint + 复位
  /// （KOS `confirmBusy`/`confirmEnabled`，DesktopConfirmDialog.qml:12-17,
  /// :155-167）。
  Future<void> _confirm() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await widget.onConfirm();
      if (!mounted) return;
      _dismiss();
    } catch (error) {
      debugPrint('kos_dock: empty trash failed: $error');
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // surface 不可见（锁屏/壁纸选择器/全屏）→ 立即收起弹窗，避免
    // OverlayPortal 挂在高一层 Overlay 上残留（与 TASK-03 popup 同款）。
    if (_open && !ShellSurfacePresentation.visibleOf(context)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted &&
            _open &&
            !ShellSurfacePresentation.visibleOf(context)) {
          _dismiss();
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return OverlayPortal(
      controller: _portal,
      overlayChildBuilder: (context) => _buildDialog(context),
      child: widget.child ?? const SizedBox.shrink(),
    );
  }

  Widget _buildDialog(BuildContext context) {
    final theme = context.shellTheme;
    final colors = context.shellColors;
    const radius = BorderRadius.all(Radius.circular(kDockConfirmRadius));
    return ShellInputRegion(
      debugLabel: 'Dock trash empty confirm',
      pointerPolicy: ShellPointerPolicy.fullScene,
      keyboardPolicy: ShellKeyboardPolicy.capture,
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): _cancel,
        },
        child: Focus(
          autofocus: true,
          child: Stack(
            children: [
              // 透明 barrier：点外=取消（KOS `dismissOnBackdrop`，
              // DesktopConfirmDialog.qml:22-26）。
              Positioned.fill(
                child: Listener(
                  behavior: HitTestBehavior.opaque,
                  onPointerDown: (_) => _cancel(),
                  child: const ColoredBox(color: Colors.transparent),
                ),
              ),
              // 居中玻璃面板：宽 min(340, overlay−44)
              // （KOS: DesktopConfirmDialog.qml:37-38 `centerOnScreen` +
              // 内容宽公式）。
              Center(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final width = math.min(
                      kDockConfirmWidth,
                      math.max(
                        0.0,
                        constraints.maxWidth - kDockConfirmScreenInset,
                      ),
                    );
                    return SizedBox(
                      width: width,
                      child: ShellBackdropBlur(
                        blur: theme.backdropBlurEnabled,
                        separateChild: true,
                        borderRadius: radius,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            borderRadius: radius,
                            gradient: theme.panelGradient(
                              colors.panelBackground,
                              colors.panelBackgroundBottom,
                            ),
                            border: Border.all(color: colors.hairlineSoft),
                          ),
                          child: ClipRRect(
                            borderRadius: radius,
                            child: Padding(
                              padding: const EdgeInsets.only(
                                top: kDockConfirmTopPadding,
                                bottom: kDockConfirmBottomPadding,
                              ),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  _buildIconCircle(context),
                                  const SizedBox(
                                    height: kDockConfirmGapAfterCircle,
                                  ),
                                  Padding(
                                    // KOS 标题 left/rightPadding =
                                    // sidePadding 24（DesktopConfirmDialog.qml:
                                    // 42,80-87），与正文一致。
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: kDockConfirmSidePadding,
                                    ),
                                    child: Text(
                                      kDockConfirmTitle,
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                        fontSize: kDockConfirmTitleSize,
                                        fontWeight: FontWeight.bold,
                                        color: colors.textPrimary,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(
                                    height: kDockConfirmGapAfterTitle,
                                  ),
                                  Padding(
                                    // KOS sidePadding 24
                                    // （DesktopConfirmDialog.qml:42,94-95）。
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: kDockConfirmSidePadding,
                                    ),
                                    child: Text(
                                      kDockConfirmBody,
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                        fontSize: kDockConfirmBodySize,
                                        height: kDockConfirmBodyLineHeight,
                                        color: colors.textSecondary,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(
                                    height: kDockConfirmGapBeforeButtons,
                                  ),
                                  _buildButtons(context),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 58px 圆 icon 底：textPrimary@0.08 + 边 @0.34 + 中心 28px trash 图标
  /// （KOS: DesktopConfirmDialog.qml:52-77）。
  Widget _buildIconCircle(BuildContext context) {
    final colors = context.shellColors;
    return Container(
      width: kDockConfirmCircleSize,
      height: kDockConfirmCircleSize,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: colors.textPrimary.withValues(
          alpha: kDockConfirmCircleFillAlpha,
        ),
        border: Border.all(
          color: colors.textPrimary.withValues(
            alpha: kDockConfirmCircleBorderAlpha,
          ),
        ),
      ),
      child: Icon(
        Icons.delete_outline,
        size: kDockConfirmIconSize,
        color: colors.textPrimary,
      ),
    );
  }

  /// 按钮行：左右 margin 16、间距 8、各半宽、34 高 radius 17
  /// （KOS: DesktopConfirmDialog.qml:108-175）。
  Widget _buildButtons(BuildContext context) {
    final colors = context.shellColors;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: kDockConfirmButtonMargin,
      ),
      child: Row(
        children: [
          Expanded(
            child: _ConfirmButton(
              label: kDockConfirmCancelLabel,
              color: colors.textPrimary,
              enabled: true,
              onTap: _cancel,
            ),
          ),
          const SizedBox(width: kDockConfirmButtonSpacing),
          Expanded(
            child: _ConfirmButton(
              // busy：文案「正在处理…」+ 禁用
              // （KOS: DesktopConfirmDialog.qml:155-167）。
              label: _busy
                  ? kDockConfirmBusyLabel
                  : kDockConfirmEmptyLabel,
              color: _busy
                  ? colors.performanceBad.withValues(
                      alpha: kDockConfirmBusyAlpha,
                    )
                  : colors.performanceBad,
              enabled: !_busy,
              onTap: _confirm,
            ),
          ),
        ],
      ),
    );
  }
}

/// 弹窗按钮：34 高、radius 17、底 textPrimary@0.08（KOS
/// `contentControlFill`），标签 13 DemiBold；禁用不响应点击。
class _ConfirmButton extends StatelessWidget {
  const _ConfirmButton({
    required this.label,
    required this.color,
    required this.enabled,
    required this.onTap,
  });

  final String label;
  final Color color;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.shellColors;
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: enabled ? onTap : null,
        child: Container(
          height: kDockConfirmButtonHeight,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(
              kDockConfirmButtonHeight / 2,
            ),
            color: colors.textPrimary.withValues(
              alpha: kDockConfirmButtonFillAlpha,
            ),
          ),
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: kDockConfirmButtonFontSize,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ),
      ),
    );
  }
}
