/// KOS Dock 垃圾桶图标 + 右键/长按菜单（TASK-04）。
///
/// 对齐 NextKde（源根 `/home/wwt/文档/NextKde/shell/desktop/modules/`）：
/// - 状态面：`dock/DockContainer.qml:586-588` — 系统图标主题
///   `SystemIconResolver.source("trash", DockTrashService.hasItems ? "full"
///   : "empty")`；Denial 无图标主题服务，改用旧 kos_dock 随包资产
///   `assets/icons/trash_full.png`（非空）/`trash.png`（空，NextKde 源 SVG
///   栅格化，见 `assets/README.md`），**原色、不加灰度/半透明层**——KOS
///   只切图标；解码失败才回退 Material `Icons.delete`/
///   `Icons.delete_outline`（记 docs/visual-deltas.md）；**不做角标计数**
///   （KOS 无此行为，DockTrashService.qml:11-25 只有 bool hasItems）；
/// - tap → `DockTrashService.open()`（`dock/DockContainer.qml:594-599`）；
/// - 右键/长按 → 自绘玻璃菜单（`dock/DockContainer.qml:371-399`
///   `trashContextMenu`：`folder-open 打开回收站 → open`、
///   `user-trash 清空回收站 → empty（走确认弹窗）`）；复用 TASK-03
///   菜单范式（OverlayPortal + fullScene + 点外/Esc + 150/140ms +
///   scale 0.96→1 + 20px 位移，见 `dock_menu.dart`）；
/// - 清空确认：`dock/DockTrashConfirmPopup.qml` + `common/
///   DesktopConfirmDialog.qml`（见 `trash_confirm_dialog.dart`）。
library;

import 'dart:async';

import 'package:denial_flutter_sdk/services.dart';
import 'package:denial_flutter_sdk/shell_theme.dart';
import 'package:denial_flutter_sdk/surfaces.dart'
    show ShellSurfacePresentation;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/dock_settings.dart';
import '../theme/dock_tokens.dart';
import 'dock_menu.dart';
import 'dock_preview_popup.dart';
import 'launcher_icon.dart';
import 'trash_confirm_dialog.dart';

/// Dock 垃圾桶按钮（固定槽位 + 与普通 DockIcon 同款 magnification）。
class TrashIcon extends ConsumerStatefulWidget {
  const TrashIcon({
    required this.services,
    required this.monitorId,
    this.coordinator,
    this.slotSize,
    this.iconScale = 1.0,
    super.key,
  });

  final ShellServices services;

  /// 本输出的 monitor id（菜单屏内 clamp 经 `services.monitorBounds`）。
  final int monitorId;

  /// 全 pill popup 协调器（KOS `DockModelService.activeDockPopup`；null →
  /// 无协调，独立宿主/单测退化）。trash 菜单与清空确认弹窗都计入单例。
  final DockPopupCoordinator? coordinator;

  /// 波形下发的槽位宽/scale（TASK-11：trash 槽纳入行级高斯波，与应用
  /// 图标同权重——quickshell `DockLayout.js` kinds 含 trash）。
  final double? slotSize;
  final double iconScale;

  @override
  ConsumerState<TrashIcon> createState() => _TrashIconState();
}

class _TrashIconState extends ConsumerState<TrashIcon>
    with SingleTickerProviderStateMixin
    implements DockPopup {
  final _portal = OverlayPortalController();

  /// 确认弹窗宿主（菜单「清空回收站」经事件回调 `open()`）。
  final _confirmKey = GlobalKey<TrashConfirmDialogState>();

  /// 菜单显隐进度（0=隐藏，1=完全展开）：150ms OutCubic 开 /
  /// 140ms InCubic 关（ACCEPTANCE 菜单条款）。
  late final AnimationController _reveal = AnimationController(
    vsync: this,
    duration: kDockMenuOpenDuration,
    reverseDuration: kDockMenuCloseDuration,
  )..addStatusListener((status) {
    // 关闭播完才收 portal（140ms InCubic，与 TASK-03 菜单同一时序）。
    if (status == AnimationStatus.dismissed && mounted && _closing) {
      _dismissMenuNow();
    }
  });

  bool _menuOpen = false;
  bool _closing = false;

  bool get _reduceMotion => MediaQuery.disableAnimationsOf(context);

  // ── 菜单状态机（KOS trashContextMenu show/hide + DockModelService
  //    activeDockPopup 单例语义的 trash 侧等价）────────────────────────────

  /// 右键/长按打开菜单；关闭动画中重入 → 以 150ms 回弹（不重建 portal）。
  void _openMenu() {
    if (_menuOpen) {
      if (_closing) {
        _closing = false;
        _reveal.animateTo(
          1,
          duration: kDockMenuOpenDuration,
          curve: Curves.easeOutCubic,
        );
      }
      return;
    }
    // KOS: dock/DockModelService.qml:65-72 `openDockPopup` —— 打开前先立即
    // 收掉当前活跃 popup（pinned 预览/菜单、确认弹窗），本菜单成为唯一
    // activeDockPopup。
    widget.coordinator?.activate(this);
    _menuOpen = true;
    _portal.show();
    if (_reduceMotion) {
      _reveal.value = 1;
    } else {
      _reveal.animateTo(
        1,
        duration: kDockMenuOpenDuration,
        curve: Curves.easeOutCubic,
      );
    }
  }

  /// 关闭菜单：140ms InCubic 退场（ACCEPTANCE 菜单条款），播完收 portal；
  /// reduceMotion 退化即关。
  void _closeMenu() {
    if (!_menuOpen || _closing) return;
    if (_reduceMotion) {
      _dismissMenuNow();
      return;
    }
    _closing = true;
    _reveal.animateBack(
      0,
      duration: kDockMenuCloseDuration,
      curve: Curves.easeInCubic,
    );
  }

  void _dismissMenuNow() {
    _closing = false;
    _menuOpen = false;
    _reveal.value = 0;
    _portal.hide();
    // KOS: dock/DockModelService.qml:74-77 `releaseDockPopup`。
    widget.coordinator?.release(this);
  }

  /// [DockPopup] 契约：被其他 popup（pinned 预览/菜单、清空确认弹窗）
  /// 抢占时立即收场，不播 140ms 退场（KOS `dismissDockPopupImmediately`，
  /// dock/DockModelService.qml:56-63）。
  @override
  void dismissDockPopupImmediately() {
    if (_menuOpen) _dismissMenuNow();
  }

  // ── 动作 ───────────────────────────────────────────────────────────────

  /// KOS: `dock/DockContainer.qml:594-599` `DockTrashService.open()`。
  Future<void> _openTrash() async {
    _closeMenu();
    try {
      await ref.read(trashServiceProvider).open();
    } catch (error) {
      debugPrint('kos_dock: open trash failed: $error');
    }
  }

  /// KOS: `dock/DockContainer.qml:397-401` 菜单 `onAction` ——
  /// `cmd=="empty"` → `DockModelService.openDockPopup(trashConfirmPopup)`
  /// （实际动作在 :400-401）。
  void _emptyTrash() {
    _closeMenu();
    _confirmKey.currentState?.open();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 与 TASK-03 DockPreviewAnchor 同款：surface 不可见 → 立即收菜单
    // （OverlayPortal 挂在更高层 Overlay，不随 surface 子树隐藏）。
    if (_menuOpen && !ShellSurfacePresentation.visibleOf(context)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted &&
            _menuOpen &&
            !ShellSurfacePresentation.visibleOf(context)) {
          _dismissMenuNow();
        }
      });
    }
  }

  @override
  void dispose() {
    widget.coordinator?.release(this);
    _reveal.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // loading/error 视作空态（KOS 未收到状态响应前 hasItems=false，
    // DockTrashService.qml:11-25）。
    final state = ref.watch(trashStateProvider).value ?? TrashState.empty;
    final colors = context.shellColors;
    final monitorBounds = ref.watch(
      widget.services.monitorBounds(widget.monitorId),
    );
    return OverlayPortal.overlayChildLayoutBuilder(
      controller: _portal,
      overlayChildBuilder: (context, layout) =>
          _buildMenu(context, layout, monitorBounds),
      child: TrashConfirmDialog(
        key: _confirmKey,
        coordinator: widget.coordinator,
        onConfirm: ref.read(trashServiceProvider).empty,
        child: DockControlIcon(
          services: widget.services,
          // KOS displayName（DockContainer.qml:587）。
          semanticLabel: '回收站',
          slotSize: widget.slotSize,
          iconScale: widget.iconScale,
          onTap: () => unawaited(_openTrash()),
          onSecondaryTap: _openMenu,
          onLongPress: _openMenu,
          child: Image.asset(
            // KOS: dock/DockContainer.qml:586-588 —— 只按 hasItems 在
            // full/empty 两枚图标间切换，不加灰度/透明度层。
            // 资产来自旧 kos_dock（NextKde 源 SVG 栅格化，见
            // `assets/README.md`），原色绘制：不给 `color`/`colorBlendMode`。
            state.hasItems
                ? 'assets/icons/trash_full.png'
                : 'assets/icons/trash.png',
            package: 'kos_dock',
            fit: BoxFit.contain,
            filterQuality: FilterQuality.medium,
            // 256² 原图常驻解码成 ~200px（iconSize·dpr·maxScale·hover，
            // 同 launcher_icon.dart Image.asset 的 cacheWidth 式）；超
            // 出仍走 FilterQuality.medium 降采样，不近邻。
            cacheWidth: (DockMetricsScope.of(context).iconSize *
                    MediaQuery.devicePixelRatioOf(context) *
                    kDockWaveMaxScale *
                    kDockHoverScale)
                .ceil(),
            // 解码/资产缺失时才退回 Material 字形（沿用旧实现的
            // full/empty 字形对）。
            errorBuilder: (context, error, stackTrace) => Icon(
              state.hasItems ? Icons.delete : Icons.delete_outline,
              size: DockMetricsScope.of(context).iconSize,
              color: colors.textPrimary,
            ),
          ),
        ),
      ),
    );
  }

  /// 菜单浮层：锚点/屏内矩形几何与 TASK-03 `DockPreviewAnchor._geometry`
  /// 同式；面板本体复用 [DockMenuOverlay]。
  Widget _buildMenu(
    BuildContext context,
    OverlayChildLayoutInfo layout,
    Rect? monitorBounds,
  ) {
    final anchor = MatrixUtils.transformRect(
      layout.childPaintTransform,
      Offset.zero & layout.childSize,
    );
    final output = (monitorBounds ?? (Offset.zero & layout.overlaySize))
        .intersect(Offset.zero & layout.overlaySize);
    return DockMenuOverlay(
      debugLabel: 'Dock trash context menu',
      anchor: anchor,
      output: output,
      overlaySize: layout.overlaySize,
      progress: _reveal,
      // KOS: dock/DockContainer.qml:383-386 setItems 两条目（zh 原文）。
      items: [
        DockMenuItem(
          label: kDockTrashMenuOpenLabel,
          icon: Icons.folder_open_outlined,
          onTap: () => unawaited(_openTrash()),
        ),
        DockMenuItem(
          label: kDockTrashMenuEmptyLabel,
          icon: Icons.delete_outline,
          onTap: _emptyTrash,
        ),
      ],
      onDismiss: _closeMenu,
    );
  }
}
