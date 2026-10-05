/// KOS Dock 内建启动器图标（TASK-04）。
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
/// - 固定槽位 + magnification/hover 与普通 DockIcon 同款
///   （`dock/DockContainer.qml:537-538` 所有图标共用 `magnificationRoot:
///   container`；`dock/DockIcon.qml:116,234-235` 固定槽位，
///   :264-318 距离放大 scale/lift，:640-658 hover 高亮）；
/// - 不做启动器右键 display-mode 菜单（KOS
///   `DockContainer.qml:404-470` 的底部吸附/紧凑/居中/全屏 + 设置项；
///   v1 固定形态，记 docs/visual-deltas.md）。
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:denial_flutter_sdk/motion.dart';
import 'package:denial_flutter_sdk/services.dart';
import 'package:denial_flutter_sdk/shell_theme.dart';
import 'package:flutter/material.dart';

import '../theme/dock_tokens.dart';
import 'dock_preview_popup.dart';
import 'magnification.dart';

/// 内建控件图标（launcher/trash 共用）：固定 `metrics.iconSlotSize` 槽位 +
/// 与 [DockIcon] 同款的 magnification/hover 弹簧。
///
/// 容器指针来自上层 `MagnificationPointer`（KOS
/// `magnificationRoot`/`magnificationPointer`，`dock/DockContainer.qml:
/// 220-228`；指针 x 与槽中心同为全局坐标系，见 `magnification.dart`）。
class DockControlIcon extends StatefulWidget {
  const DockControlIcon({
    required this.services,
    required this.semanticLabel,
    required this.onTap,
    required this.child,
    this.onSecondaryTap,
    this.onLongPress,
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

  /// 图标美术层（渲染边长 = `DockMetricsScope.of(context).iconSize`，
  /// 由 [DockMetrics] 运行时反解——非编译期常量；缩放由本件负责）。
  final Widget child;

  @override
  State<DockControlIcon> createState() => _DockControlIconState();
}

class _DockControlIconState extends State<DockControlIcon>
    with SingleTickerProviderStateMixin {
  /// 「放大进度」∈ [0,∞)：0=静止，1=满 influence（hover 亦映射为 1）。
  /// （同 `dock_icon.dart` 的 `_progress` 语义。）
  late final AnimationController _progress = AnimationController.unbounded(
    vsync: this,
  );

  bool _mouseInside = false;
  bool _hovering = false;
  double? _lastPointerX;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _updateHoverAndSpring();
    });
  }

  /// 本槽中心的全局 x（与 MagnificationPointer 广播同坐标系）：实时读取
  /// 布局几何——KOS `_slotCentreInRoot()` 每次 influence/hover 求值都重新
  /// map（dock/DockIcon.qml:256-263）；内建图标会随 launcher/trash 可见性
  /// 或行布局变化移动，缓存值会过期。
  double get _slotCenterX {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize || !box.attached) return 0;
    return box.localToGlobal(Offset(box.size.width / 2, 0)).dx;
  }

  void _updateHoverAndSpring() {
    final pointerX = MagnificationPointer.of(context);
    // 槽位尺寸/图标边长由 DockMetricsScope 反解（方案 C）。
    final metrics = DockMetricsScope.of(context);
    final bool hovering;
    if (pointerX == null) {
      // KOS: dock/DockIcon.qml:363-368 — 无容器指针时回退 MouseArea。
      hovering = _mouseInside;
    } else {
      // KOS: dock/DockIcon.qml:369-371 — 以未变换槽位矩形判定 hover。
      hovering = (pointerX - _slotCenterX).abs() <= metrics.iconSlotSize / 2;
    }
    if (hovering != _hovering) {
      setState(() => _hovering = hovering);
    }

    final double target;
    if (pointerX != null) {
      // KOS: dock/DockIcon.qml:264-279 — smoothstep 影响（半径
      // max(iconSize*2,140)）。
      target = DockMagnification.influence(
        pointerX - _slotCenterX,
        DockMagnification.radius(metrics.iconSize),
      );
    } else {
      // KOS: dock/DockIcon.qml:291-293 — 独立 hover scale 1.20。
      target = _hovering ? 1.0 : 0.0;
    }
    _springTo(target);
  }

  void _springTo(double target) {
    if (MediaQuery.disableAnimationsOf(context)) {
      _progress.value = target;
      return;
    }
    // KOS: dock/DockAnimation.qml:37-50 — iconSpring 映射 Motion.snappy
    // （与 dock_icon.dart 同一标定）。
    unawaited(
      springTo(
        _progress,
        target,
        spring: Motion.snappy,
        telemetryLabel: 'dock_control_icon_magnification',
      ),
    );
  }

  /// 进度 → 视觉 scale：有指针 1.19（DockIcon.qml:280-282），无指针
  /// hover 1.20（:291-293,304）。
  double _scaleFor(double p) {
    final peak = MagnificationPointer.of(context) != null
        ? kDockMagnificationMaxScale
        : kDockHoverScale;
    return 1.0 + (peak - 1.0) * p;
  }

  /// 进度 → y 抬升（负）：magnification −iconSize×0.04（DockIcon.qml:
  /// 285-288）；独立 hover −max(2,round(iconSize×0.08))（:297-300）。
  double _liftFor(double p) {
    final pointerActive = MagnificationPointer.of(context) != null;
    final iconSize = DockMetricsScope.of(context).iconSize;
    final lift = pointerActive
        ? -iconSize * kDockMagnificationLiftRatio
        : (_hovering
              ? -math.max(
                  2.0,
                  (iconSize * kDockHoverLiftRatio).roundToDouble(),
                )
              : 0.0);
    return lift * p;
  }

  @override
  void dispose() {
    _progress.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 依赖容器指针广播：值变化触发 build → 帧后重算弹簧目标。
    final pointerX = MagnificationPointer.of(context);
    if (!identical(pointerX, _lastPointerX)) {
      _lastPointerX = pointerX;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _updateHoverAndSpring();
      });
    }
    final colors = context.shellColors;
    // 方案 C：槽位/图标边长/圆角全部由 DockMetrics 反解。
    final metrics = DockMetricsScope.of(context);
    final slotSize = metrics.iconSlotSize;
    final iconSize = metrics.iconSize;
    final radius = iconSize * kDockActiveRadiusRatio;
    return SizedBox(
      // 固定槽位：宽/高 = iconSlotSize，绝不随 pointer 变化
      // （KOS: dock/DockIcon.qml:116,234-235 + AppearanceTokens.qml:441-443）。
      width: slotSize,
      height: slotSize,
      child: MouseRegion(
        cursor: widget.services.linkCursor,
        onEnter: (_) {
          _mouseInside = true;
          _updateHoverAndSpring();
        },
        onExit: (_) {
          _mouseInside = false;
          _updateHoverAndSpring();
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          onSecondaryTap: widget.onSecondaryTap,
          onLongPress: widget.onLongPress,
          child: Semantics(
            label: widget.semanticLabel,
            button: true,
            child: Stack(
              clipBehavior: Clip.none,
              alignment: Alignment.center,
              children: [
                // hover 高亮圆斑（iconSize 方块）：KOS 白 0.12 → shellTheme
                // 前景同 alpha，135ms OutCubic（DockIcon.qml:640-658）。
                IgnorePointer(
                  child: AnimatedOpacity(
                    opacity: _hovering ? 1.0 : 0.0,
                    duration: kDockHoverHighlightDuration,
                    curve: Curves.easeOutCubic,
                    child: Container(
                      width: iconSize,
                      height: iconSize,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(radius),
                        color: colors.textPrimary.withValues(
                          alpha: kDockHoverHighlightAlpha,
                        ),
                      ),
                    ),
                  ),
                ),
                // 视觉层：槽内 Transform.scale(bottomCenter) + translate
                // （KOS: dock/DockIcon.qml:304 scale + :309-318 Translate.y）。
                AnimatedBuilder(
                  animation: _progress,
                  builder: (context, child) {
                    final p = _progress.value;
                    return Transform.translate(
                      offset: Offset(0, _liftFor(p)),
                      child: Transform.scale(
                        scale: _scaleFor(p),
                        alignment: Alignment.bottomCenter,
                        child: child,
                      ),
                    );
                  },
                  child: ExcludeSemantics(
                    child: SizedBox(
                      width: iconSize,
                      height: iconSize,
                      child: widget.child,
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
    super.key,
  });

  final ShellServices services;

  /// 全 pill popup 协调器（KOS `DockModelService.activeDockPopup`；
  /// null → 无协调，独立宿主/单测退化）。
  final DockPopupCoordinator? coordinator;

  @override
  Widget build(BuildContext context) {
    final colors = context.shellColors;
    return DockControlIcon(
      services: services,
      semanticLabel: '应用程序',
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
