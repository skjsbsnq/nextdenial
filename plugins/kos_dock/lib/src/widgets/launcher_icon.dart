/// KOS Dock 内建启动器图标（TASK-04）→ TASK-11 波形槽位直绑。
///
/// 对齐 NextKde（源根 `/home/wwt/文档/NextKde/shell/desktop/modules/`）：
/// - 图标资源：`dock/DockContainer.qml:545-547`
///   `iconSource: Qt.resolvedUrl("../../assets/applauncher.svg")`
///   （仓库内 1024² 位图原作，逐字节拷贝到 `assets/applauncher.svg`；
///   见 `assets/README.md`）。Denial 无 `BundledIcons`，走包内 asset 键
///   `packages/kos_dock/assets/applauncher.svg`（`Image.asset(package:)`），
///   解码失败才回退 `Icons.apps`；
/// - tap → `AppLauncherService.toggle()`（`dock/DockContainer.qml:554-564`
///   `onActivate`：先收掉当前活跃 dock popup 再 toggle；移植版经 shell 级
///   `DockPopupCoordinator` 复刻该顺序，见 `dock_preview_popup.dart`）；
/// - TASK-11：launcher/trash 槽位纳入行级高斯波（quickshell 把内建图标
///   也当普通槽位，`DockLayout.js` kinds 含 launcher/trash）：槽宽由
///   `dockWaveLayout` 经 [DockControlIcon.slotSize] 下发，美术边长
///   = iconSize·iconScale 直绑不 spring；
/// - 不做启动器右键 display-mode 菜单（KOS
///   `DockContainer.qml:404-470` 的底部吸附/紧凑/居中/全屏 + 设置项；
///   v1 固定形态，记 docs/visual-deltas.md）。
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:denial_flutter_sdk/services.dart';
import 'package:denial_flutter_sdk/shell_theme.dart';
import 'package:flutter/material.dart';

import '../theme/dock_tokens.dart';
import 'dock_icon.dart' show kosDockBounceLiftSequence;
import 'dock_preview_popup.dart';
import 'magnification.dart';

/// 内建控件图标（launcher/trash 共用）：槽位宽 = 波形下发的 [slotSize]
///（未下发退回 `DockMetricsScope.iconSlotSize`），美术边长 =
/// `iconSize·iconScale` 直绑。
///
/// 容器指针来自上层 `MagnificationPointer`（KOS
/// `magnificationRoot`/`magnificationPointer`，`dock/DockContainer.qml:
/// 220-228`；指针 x 与槽中心同为全局坐标系，见 `magnification.dart`）。
/// TASK-11：不再自测槽中心算 influence——hover 判定用本槽实测几何，
/// 视觉大小由行级 `dockWaveLayout` 统一给。
class DockControlIcon extends StatefulWidget {
  const DockControlIcon({
    required this.services,
    required this.semanticLabel,
    required this.onTap,
    required this.child,
    this.onSecondaryTap,
    this.onLongPress,
    this.slotSize,
    this.iconScale = 1.0,
    super.key,
  });

  /// 宿主服务束（`linkCursor`；launcher/trash 在 DockIconRow 之外，
  /// 无 `ShellServicesScope` 祖先，显式传参）。
  final ShellServices services;

  /// 无障碍标签（KOS `displayName`：启动器「应用程序」、垃圾桶「回收站」）。
  final String semanticLabel;

  final VoidCallback onTap;

  /// 右键/长按（trash 菜单；launcher 为 null）。
  final VoidCallback? onSecondaryTap;
  final VoidCallback? onLongPress;

  /// 图标美术层（渲染边长 = `DockMetricsScope.of(context).iconSize ×
  /// [iconScale]`——缩放由本件负责下发）。
  final Widget child;

  /// 槽位宽（`dockWaveLayout` 下发的槽内图标槽宽；null →
  /// `DockMetricsScope.iconSlotSize`）。
  final double? slotSize;

  /// 槽位高斯 scale（1 = 静止）；美术边长 = iconSize·iconScale 直绑不
  /// spring（TASK-11 约束①）。
  final double iconScale;

  @override
  State<DockControlIcon> createState() => _DockControlIconState();
}

class _DockControlIconState extends State<DockControlIcon>
    with TickerProviderStateMixin {
  /// 指针缺席时的独立 hover 进度（0/1 bounded tween，
  /// `kDockHoverEaseDuration` easeOutCubic）：KOS `dock/DockIcon.qml:
  /// 291-300` 的无 magnification hover 回退（scale 1.20 + lift）。
  /// 容器内有指针时波形接管（[widget.iconScale] 直绑），本 controller
  /// 停在 0。
  late final AnimationController _hover = AnimationController(
    vsync: this,
    duration: kDockHoverEaseDuration,
  );

  /// TASK-10 tap 单次弹跳（launcher/trash 共用 `DockControlIcon`，在其内部
  /// onTap 包装触发，调用点零改动）：y 位移 ∈ [0,1] ×
  /// `kDockLaunchBounceHeight`（quickshell `DockItem.qml:86-104` 同参数），
  /// 叠加进槽内 `Transform.translate` 的 y。有界 controller + 两段
  /// TweenSequence（220ms easeOutQuad 上升 / 340ms bounceOut 落地）。
  late final AnimationController _bounce = AnimationController(
    vsync: this,
    duration: kDockLaunchBounceRiseDuration + kDockLaunchBounceFallDuration,
  );

  /// bounce controller → 上跳位移（px，≥0）：曲线定义见
  /// `dock_icon.dart` 的 `kosDockBounceLiftSequence`（包级单源，
  /// quickshell DockItem.qml:89-102 的两段时长/曲线）。
  late final Animation<double> _bounceLift = _bounce.drive(
    kosDockBounceLiftSequence,
  );

  bool _mouseInside = false;
  bool _hovering = false;
  double? _lastPointerX;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _updateHover();
    });
  }

  /// hover 判定 + 独立 hover 进度目标。有容器指针时 hover 以本槽实测矩形
  /// 判定（`localToGlobal` 全局 x，与 [MagnificationPointer] 广播同系）；
  /// 无指针时回退 MouseArea（KOS `dock/DockIcon.qml:363-371`）。
  void _updateHover() {
    final pointerX = MagnificationPointer.of(context);
    final metrics = DockMetricsScope.of(context);
    final bool hovering;
    if (pointerX == null) {
      hovering = _mouseInside;
    } else {
      final box = context.findRenderObject();
      final half = (widget.slotSize ?? metrics.iconSlotSize) / 2;
      if (box is RenderBox && box.hasSize && box.attached) {
        final centerX = box.localToGlobal(Offset(box.size.width / 2, 0)).dx;
        hovering = (pointerX - centerX).abs() <= half;
      } else {
        hovering = _mouseInside;
      }
    }
    if (hovering != _hovering) {
      setState(() => _hovering = hovering);
    }
    // `_hover` 跟 `_hovering` 走作 lift 缓动（与 DockIcon 同义：有指针时
    // scale 由 iconScale 接管、hover scale 分量归 1，lift 仍是 hover 反馈）。
    final target = _hovering ? 1.0 : 0.0;
    if (MediaQuery.disableAnimationsOf(context)) {
      _hover.value = target;
    } else {
      _hover.animateTo(target, curve: Curves.easeOutCubic);
    }
  }

  /// TASK-10 tap 单次弹跳：`widget.onTap` 的统一包装——launcher/trash 的
  /// tap 回调是外部传入的，本图标内统一触发（调用点零改动）。
  /// `MediaQuery.disableAnimations` 下不 `forward`（有界 controller 直接
  /// 钉 0，与 `_updateHover` 直写终值兜底同理，否则测试环境留下永不推进
  /// 的 ticker）。
  void _onTapBounce() {
    if (!MediaQuery.disableAnimationsOf(context)) {
      unawaited(_bounce.forward(from: 0));
    } else {
      _bounce.value = 0;
    }
    widget.onTap();
  }

  @override
  void dispose() {
    _bounce.dispose();
    _hover.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 依赖容器指针广播：值变化触发 build → 帧后重算 hover 判定。
    final pointerX = MagnificationPointer.of(context);
    if (!identical(pointerX, _lastPointerX)) {
      _lastPointerX = pointerX;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _updateHover();
      });
    }
    final colors = context.shellColors;
    final metrics = DockMetricsScope.of(context);
    final slotSize = widget.slotSize ?? metrics.iconSlotSize;
    final iconSize = metrics.iconSize;
    final radius = iconSize * kDockActiveRadiusRatio;
    return SizedBox(
      // 槽位宽 = 波形下发值（含 scale；无波形宿主退回 iconSlotSize）。
      width: slotSize,
      height: slotSize,
      child: MouseRegion(
        cursor: widget.services.linkCursor,
        onEnter: (_) {
          _mouseInside = true;
          _updateHover();
        },
        onExit: (_) {
          _mouseInside = false;
          _updateHover();
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _onTapBounce,
          onSecondaryTap: widget.onSecondaryTap,
          onLongPress: widget.onLongPress,
          child: Semantics(
            label: widget.semanticLabel,
            button: true,
            child: Stack(
              clipBehavior: Clip.none,
              // TASK-12：槽位列底锚（美术盒贴带底向上长；quickshell
              // DockItem.qml:112 artwork.y = 带底 − height − 12 − bounce）。
              alignment: Alignment.bottomCenter,
              children: [
                // hover 高亮圆斑（iconSize 方块）：KOS 白 0.12 → shellTheme
                // 前景同 alpha，135ms OutCubic（DockIcon.qml:640-658）。
                // TASK-12：钉在 pill 区（列底上 dockHeight 高）内底对齐，
                // 不跟放大美术盒上探。
                Positioned(
                  bottom: 0,
                  height: metrics.dockHeight,
                  child: IgnorePointer(
                    child: AnimatedOpacity(
                      opacity: _hovering ? 1.0 : 0.0,
                      duration: kDockHoverHighlightDuration,
                      curve: Curves.easeOutCubic,
                      // TASK-12 复审缺陷3：Positioned 给子树 tight dockHeight
                      // 高 → Align+SizedBox 恢复 iconSize 方块并底对 pill 区
                      // （同 DockIcon dot 行的 Align 模式），不高拉成条。
                      child: Align(
                        alignment: Alignment.bottomCenter,
                        child: SizedBox(
                          width: iconSize,
                          height: iconSize,
                          child: Container(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(radius),
                              color: colors.textPrimary.withValues(
                                alpha: kDockHoverHighlightAlpha,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                // 视觉层：美术边长 = iconSize·iconScale 直绑（底部锚定向
                // 上生长）；TASK-10 tap 弹跳位移叠加进同一 translate 的 y。
                // 独立 hover 回退（无容器指针）走 _hover 0/1 tween →
                // scale 1.20 + lift（KOS :291-300）。
                // TASK-12 缺陷2：美术盒视觉底边距 pill 底保持常量 margin =
                // 静止居中布局的自然下边距 (dockHeight−iconSize)/2
                // （quickshell `DockItem.qml:112` 的 12px 常量底边距等价）；
                // hover highlight 仍钉 pill 区内（本 Padding 只包美术盒）。
                Padding(
                  padding: EdgeInsets.only(
                    bottom: math.max(
                      0.0,
                      (metrics.dockHeight - iconSize) / 2,
                    ),
                  ),
                  child: Align(
                    alignment: Alignment.bottomCenter,
                    child: AnimatedBuilder(
                      animation: Listenable.merge([_hover, _bounce]),
                      builder: (context, child) {
                        // 有容器指针时 iconScale 接管视觉大小 → hover scale 归
                        // 1 不双放大；lift 仍随 `_hovering` 缓动（同 DockIcon）。
                        final hasPointer =
                            MagnificationPointer.of(context) != null;
                        final hoverP = _hover.value;
                        final hoverScale = hasPointer
                            ? 1.0
                            : 1.0 + (kDockHoverScale - 1.0) * hoverP;
                        final hoverLift = _hovering
                            ? -math.max(
                                2.0,
                                (iconSize * kDockHoverLiftRatio)
                                    .roundToDouble(),
                              ) *
                                hoverP
                            : 0.0;
                        return Transform.translate(
                          offset: Offset(0, hoverLift - _bounceLift.value),
                          child: Transform.scale(
                            scale: hoverScale,
                            alignment: Alignment.bottomCenter,
                            child: child,
                          ),
                        );
                      },
                      child: ExcludeSemantics(
                        child: SizedBox(
                          width: iconSize * widget.iconScale,
                          height: iconSize * widget.iconScale,
                          child: widget.child,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Dock 最左的启动器按钮。
///
/// KOS: `dock/DockContainer.qml:532-565`（`appLauncherIcon`）；
/// tap → `AppLauncherService.toggle()`（:554-564）。
class LauncherIcon extends StatelessWidget {
  const LauncherIcon({
    required this.services,
    this.coordinator,
    this.slotSize,
    this.iconScale = 1.0,
    super.key,
  });

  final ShellServices services;

  /// 全 pill popup 协调器（KOS `DockModelService.activeDockPopup`；
  /// null → 无协调，独立宿主/单测退化）。
  final DockPopupCoordinator? coordinator;

  /// 波形下发的槽位宽/scale（TASK-11：launcher 槽纳入行级高斯波）。
  final double? slotSize;
  final double iconScale;

  @override
  Widget build(BuildContext context) {
    final colors = context.shellColors;
    return DockControlIcon(
      services: services,
      semanticLabel: '应用程序',
      slotSize: slotSize,
      iconScale: iconScale,
      onTap: () {
        // KOS: dock/DockContainer.qml:560-563 —— `onActivate` 先
        // `setDockPopupVisible(activeDockPopup, false)` 再
        // `AppLauncherService.toggle()`。
        coordinator?.dismissActive();
        services.toggleLauncher();
      },
      child: Image.asset(
        // KOS: dock/DockContainer.qml:545-547 —— 仓库内 1024² 位图原作。
        // `package`：Denial 宿主以 path 包依赖 kos_dock，包内 asset 的
        // bundle 键是 `packages/kos_dock/assets/applauncher.svg`；不写
        // package 会查未加前缀的键、稳定落入下面的 errorBuilder。
        'assets/applauncher.svg',
        package: 'kos_dock',
        fit: BoxFit.contain,
        // 原色渲染：KOS 图标外观 color 模式直接绘制原图
        // （KOS: dock/DockIcon.qml:710-716 ——
        // `layer.enabled: IconAppearanceService.mode !== "color"`、
        // `opacityMultiplier: mode === "color" ? 1.0 : opacity`：单色化与
        // 降透明只在非 color 模式发生）。logo 自带白 `#f0f0f0` 与蓝
        // `#90b0f0`/`#80a0f0`/`#c0b0f0` 像素，故不给 `color`/
        // `colorBlendMode`——旧实现用 `BlendMode.srcIn` 把整张图压成一个
        // 主题灰（alpha 当遮罩），是用户看到的「单色图标」缺陷。
        errorBuilder: (context, error, stackTrace) => Icon(
          Icons.apps,
          size: DockMetricsScope.of(context).iconSize,
          color: colors.textPrimary,
        ),
      ),
    );
  }
}
