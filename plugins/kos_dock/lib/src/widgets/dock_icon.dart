/// KOS Dock 单图标（固定槽位 + magnification/hover 弹簧 + dot 指示）。
///
/// 对齐 NextKde `dock/DockIcon.qml`（源根
/// `/home/wwt/文档/NextKde/shell/desktop/modules/`）：
/// - 槽位 `width/height = iconSlotSize`（:116,234-235），槽宽绝不随指针变
///   化——视觉缩放只在槽内 Transform（common/AppearanceTokens.qml:441-443
///   「each icon scales visually inside a fixed slot」）；
/// - scale = hover×magnification（:291-293,304），y 平移 = hoverLift +
///   magnificationLift（:309-318），两者统一由一个 [0,∞) 的「放大进度」
///   驱动（等价 influence），`AnimationController.unbounded` + `springTo`
///   跟手（:311-317,386-392 的 SpringAnimation —— KOS 标定
///   dock/DockAnimation.qml:37-50 s8.0/d0.40/m0.60 → t90≈96ms、settle≈
///   160ms、0.1% 过冲；映射 `Motion.snappy`，它是 SDK 弹簧族里以
///   「小元素快速跟手」标定的成员，量级匹配）；
/// - hover：容器无 magnification 指针时按 MouseArea 回退（:363-368），有
///   指针时按静态槽位矩形判定（:369-371，避免跟随自身 transform 抖动，
///   :341-355）；scale 1.20、lift −max(2,round(iconSize×0.08))，且仅
///   `!showActiveBackground` 时抬升（:297-300）；hover 高亮圆斑 135ms
///   （:640-658）；
/// - activeBackground：isRunning && isActivated 时 accent 0.22 圆角槽
///   （:128-138,597-621；subtle≈0.22 语义见 :129-137）；
/// - dot 指示行：min(3,windowCount) 点、4/5px、间距 2、140ms 透明度过渡
///   （:788-833，只用 dot 分支；:736-764 attentionBadge 红角标砍掉）；
/// - 点击：0 窗 launch、1 窗 activate、多窗 MRU 轮循
///   （dock/DockModelService.qml:317-366，无 minimize 分支）；
/// - hover 预览 + 右键菜单：TASK-03，popup 管线在
///   `dock_preview_popup.dart`（`DockPreviewAnchor`），这里只做事件转发。
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:denial_flutter_sdk/motion.dart';
import 'package:denial_flutter_sdk/services.dart';
import 'package:denial_flutter_sdk/shell_theme.dart';
import 'package:flutter/widgets.dart';

import '../theme/dock_tokens.dart';
import 'dock_preview_popup.dart';
import 'magnification.dart';

/// 单个 Dock 图标。布局尺寸恒为 `DockMetricsScope` 反解的 `iconSlotSize`
/// 固定槽位（KOS: dock/DockIcon.qml:116,234-235；方案 C 起不再编译期常量）。
class DockIcon extends StatefulWidget {
  const DockIcon({
    required this.appId,
    required this.name,
    required this.launchId,
    required this.monitorId,
    required this.windows,
    required this.isActivated,
    required this.monitorBounds,
    required this.dragging,
    required this.onTogglePin,
    this.isPinnedEntry = true,
    this.coordinator,
    super.key,
  });

  /// 图标资源 id（`services.buildApplicationIcon` 参数）。
  final String appId;
  final String name;

  /// opaque launch id（`services.launchApplication` 参数）。pinned 条目为
  /// catalog `LaunchableApplication.id`（`desktop:` 前缀，D-1 反查命中）
  /// 或退化 `pin.id`（未命中）；未 pin 条目为 catalog `id` 或 null。
  final String? launchId;
  final int monitorId;

  /// 该应用在本输出的窗口（宿主枚举序 ≈ MRU，KOS
  /// DockModelService.qml:344-365 直接取 `windows[0]` 为 MRU 窗）。
  final List<ApplicationWindow> windows;

  /// 任一窗口 active（KOS `isActivated`，DockIcon.qml:80,138）。
  final bool isActivated;

  /// 本输出的屏内矩形（popup 横向 clamp 用；taskbar `monitorBounds`）。
  final Rect? monitorBounds;

  /// 行内重排拖拽中（预览/菜单抑制）。
  final bool dragging;

  /// 右键菜单「取消固定」写回（dock_icons.dart `_savePins` 封装）。
  final Future<void> Function() onTogglePin;

  /// 全 pill 共享 popup 协调器（KOS dock/DockModelService.qml:32-39,65-72
  /// 单例 `activeDockPopup`；由 `KosDockShell` → `DockIconRow` 注入，
  /// null → 本图标无协调）。
  final DockPopupCoordinator? coordinator;

  /// 该条目是否属于 pinned 段（KOS `dock/DockIcon.qml:916-927`：window item
  /// 的第三项是 `pinned ? "取消固定" : "固定此应用"`）。
  final bool isPinnedEntry;

  @override
  State<DockIcon> createState() => _DockIconState();
}

/// 入场视觉位移广播：图标行 `_DockEntrance`（`dock_icons.dart`）每帧公布
/// 当前水平位移 dx，供 `DockIcon` 测量槽中心时扣除。
///
/// 槽中心经 `RenderBox.localToGlobal` 量取，会连带祖先 `Transform` 的视觉
/// 位移；KOS 的 `_slotCentreInRoot()`（dock/DockIcon.qml:256-263）映射的是
/// **未变换的槽位**，故扣除入场位移后，入场期间指针停在槽上时放大中心也
/// 与静止后一致。未被入场包裹（launcher/trash/独立宿主）时为 0。
class DockEntranceOffset extends InheritedWidget {
  const DockEntranceOffset({required this.dx, required super.child, super.key});

  /// 当前水平视觉位移（px，向左为负）。
  final double dx;

  /// 当前入场位移；无 [DockEntranceOffset] 祖先时为 0。
  static double of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<DockEntranceOffset>()?.dx ??
      0.0;

  @override
  bool updateShouldNotify(DockEntranceOffset oldWidget) =>
      oldWidget.dx != dx;
}

class _DockIconState extends State<DockIcon>
    with SingleTickerProviderStateMixin {
  /// 「放大进度」∈ [0,∞)：0=静止，1=满 influence（hover 亦映射为 1）。
  /// scale/lift 由它算出（见 [_scaleFor]/[_liftFor]）。
  late final AnimationController _progress = AnimationController.unbounded(
    vsync: this,
  );

  /// 本槽中心的全局 x（MagnificationPointer 广播同为全局 x——指针位置与
  /// 槽中心同坐标系才可比；KOS 侧两者都映射进 DockContainer 本地系，
  /// DockIcon.qml:100-102,256-263，这里用全局系承担同一角色）。
  /// **每次求值都重新量取**（[_measureSlotCenter]），不做一次性缓存：入场
  /// 位移、`showLauncher`/`showTrash` 切换、行内重排都会移动槽位。
  double _slotCenterX = 0;

  /// 上次求值时的槽中心（判断布局是否移动过；只有指针或中心变化才重启
  /// 弹簧——`springTo` 会清零速度）。NaN = 尚未求值。
  double _evaluatedCenterX = double.nan;

  /// 入场视觉位移（[DockEntranceOffset] 广播；未被入场包裹时为 0）。
  double _entranceDx = 0;
  bool _mouseInside = false;
  bool _hovering = false;
  bool _launched = false;

  /// TASK-03 popup 宿主：hover 预览 + 右键菜单的状态机都在
  /// `DockPreviewAnchorState`，DockIcon 只转发 enter/exit/secondaryTap。
  final _previewKey = GlobalKey<DockPreviewAnchorState>();

  /// 上次广播到的指针 x（`identical` 比较区分 null→0.0 跳变）。每次
  /// build 读到新值则帧后重算 hover/弹簧目标。
  double? _lastPointerX;

  bool get _showActiveBackground =>
      widget.windows.isNotEmpty && widget.isActivated;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _measureSlotCenter();
      _evaluatedCenterX = _slotCenterX;
      _updateHoverAndSpring();
    });
  }

  /// 槽中心量取：`localToGlobal` 得视觉位置，再扣除祖先入场 `Transform`
  /// 的水平位移（[DockEntranceOffset]），即 KOS `_slotCentreInRoot` 映射的
  /// 「未变换槽位」中心（dock/DockIcon.qml:256-263）。布局 rect 本身不受
  /// 本图标自身的放大 Transform 影响（它在槽位子树内部）。
  void _measureSlotCenter() {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize || !box.attached) return;
    _slotCenterX =
        box.localToGlobal(Offset(box.size.width / 2, 0)).dx - _entranceDx;
  }

  /// 帧后刷新：先按当帧几何重测槽中心，再决定是否重算 hover / 弹簧目标。
  ///
  /// KOS 的 influence/hover 绑定每次求值都重新映射槽中心
  /// （dock/DockIcon.qml:256-263），所以指针未动但布局移动（show*/
  /// 重排/入场位移）时也必须跟着更新；`springTo` 会清零速度，故只在指针或
  /// 槽中心确实变化时才调用。
  void _refresh(double? pointerX, double entranceDx) {
    _entranceDx = entranceDx;
    _measureSlotCenter();
    final moved = _evaluatedCenterX.isNaN ||
        (_slotCenterX - _evaluatedCenterX).abs() > 0.01;
    if (!moved && identical(pointerX, _lastPointerX)) return;
    _lastPointerX = pointerX;
    _evaluatedCenterX = _slotCenterX;
    _updateHoverAndSpring();
  }

  /// 容器 pointerX 变化 → 重算 hover，并把新目标 influence 交给弹簧
  /// 指针/几何变化 → 重测槽中心后重算 hover，并把新目标 influence 交给
  /// 弹簧（连续跟手：springTo 目标更新，不逐帧 setState 直写）。
  void _updateHoverAndSpring() {
    // 每次求值都从当前布局几何量取（KOS: dock/DockIcon.qml:256-263 的
    // 绑定求值语义），不做一次性缓存。
    _measureSlotCenter();
    _evaluatedCenterX = _slotCenterX;
    final pointerX = MagnificationPointer.of(context);
    // 槽位尺寸/图标边长由 DockMetricsScope 反解（方案 C）：读取当前
    // metrics，不再用编译期常量（hover 判定与 influence 半径都随 iconSize 变）。
    final metrics = DockMetricsScope.of(context);
    final bool hovering;
    if (pointerX == null) {
      // KOS: dock/DockIcon.qml:363-368 — 容器无指针时回退 MouseArea 答案。
      hovering = _mouseInside;
    } else {
      // KOS: dock/DockIcon.qml:369-371 — 以「未变换槽位」矩形判定 hover。
      hovering = (pointerX - _slotCenterX).abs() <= metrics.iconSlotSize / 2;
    }
    if (hovering != _hovering) {
      setState(() => _hovering = hovering);
    }

    final double target;
    if (pointerX != null) {
      // magnification 生效：目标 = 本槽到指针的 smoothstep 影响
      // （KOS: dock/DockIcon.qml:264-279）。
      target = DockMagnification.influence(
        pointerX - _slotCenterX,
        DockMagnification.radius(metrics.iconSize),
      );
    } else {
      // 独立 hover（无 magnification 指针）：进度 1 → scale 1.20
      // （KOS: dock/DockIcon.qml:291-293）。
      target = _hovering ? 1.0 : 0.0;
    }
    _springTo(target);
  }

  void _springTo(double target) {
    if (MediaQuery.disableAnimationsOf(context)) {
      _progress.value = target;
      return;
    }
    // KOS: dock/DockAnimation.qml:37-50 — iconSpring s8.0/d0.40/m0.60，
    // 离屏探针实测 t90≈96ms、settle≈160ms、0.1% 过冲；SDK 弹簧族中
    // Motion.snappy（m1.0/k520/c44）为同量级「小元素快跟手」标定，映射之。
    unawaited(
      springTo(
        _progress,
        target,
        spring: Motion.snappy,
        telemetryLabel: 'dock_icon_magnification',
      ),
    );
  }

  /// 进度 → 视觉 scale：magnification 分支走 1+0.19·p（:280-282），hover
  /// 分支终点 1.20（:291-293,:304）；两分支在弹簧过冲区只差峰值常量。
  double _scaleFor(double p) {
    final peak = MagnificationPointer.of(context) != null
        ? kDockMagnificationMaxScale
        : kDockHoverScale;
    return 1.0 + (peak - 1.0) * p;
  }

  /// 进度 → y 抬升（负）：magnification −iconSize×0.04·p（:285-288）；hover
  /// −max(2,round(iconSize×0.08))·p 且 `!showActiveBackground`（:297-300）。
  double _liftFor(double p) {
    final pointerActive = MagnificationPointer.of(context) != null;
    final iconSize = DockMetricsScope.of(context).iconSize;
    final lift = pointerActive
        ? -iconSize * kDockMagnificationLiftRatio
        : (_hovering && !_showActiveBackground
              ? -math.max(
                  2.0,
                  (iconSize * kDockHoverLiftRatio).roundToDouble(),
                )
              : 0.0);
    return lift * p;
  }

  void _activate() {
    final services = ShellServicesScope.of(context);
    if (widget.windows.isEmpty) {
      final id = widget.launchId;
      if (id == null || _launched) return;
      _launched = true;
      // KOS: dock/DockModelService.qml:319-328 — 无窗 → launch。
      services
          .launchApplication(id, monitorId: widget.monitorId)
          .whenComplete(() => _launched = false);
      return;
    }
    // KOS: dock/DockModelService.qml:330-365 — 1 窗 activate；多窗 MRU
    // 轮循：有 active 窗 → 激活其下一个；无 → 激活第一个（无 minimize 分支，
    // CONSTRAINTS §5 协议缺口）。
    if (widget.windows.length == 1) {
      services.activateWindow(widget.windows.single.id);
      return;
    }
    final activeIndex = widget.windows.indexWhere((w) => w.active);
    final next = activeIndex < 0
        ? widget.windows.first
        : widget.windows[(activeIndex + 1) % widget.windows.length];
    services.activateWindow(next.id);
  }

  void _openContextMenu() {
    // KOS: dock/DockIcon.qml:894-932 — 右键收掉预览 dwell 后开菜单
    // （菜单独占 popup 协调器，等价 activeContextMenu 抑制预览）。
    _previewKey.currentState?.openContextMenu();
  }

  @override
  void dispose() {
    _progress.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final services = ShellServicesScope.of(context);
    // 依赖容器指针广播（值变化触发本 build）与入场位移广播（入场期间每帧
    // 通知）：两者都只在帧后重算 hover/弹簧目标，避免 build 中启动动画。
    final pointerX = MagnificationPointer.of(context);
    final entranceDx = DockEntranceOffset.of(context);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _refresh(pointerX, entranceDx);
    });
    final colors = context.shellColors;
    // 方案 C：槽位/图标边长/底斑半径/激活圆角全部由 DockMetrics 反解。
    final metrics = DockMetricsScope.of(context);
    final slotSize = metrics.iconSlotSize;
    final iconSize = metrics.iconSize;
    final radius = iconSize * kDockActiveRadiusRatio;
    return DockPreviewAnchor(
      key: _previewKey,
      name: widget.name,
      launchId: widget.launchId,
      monitorId: widget.monitorId,
      windows: widget.windows,
      monitorBounds: widget.monitorBounds,
      dragging: widget.dragging,
      onTogglePin: widget.onTogglePin,
      isPinnedEntry: widget.isPinnedEntry,
      coordinator: widget.coordinator,
      child: SizedBox(
      // 固定槽位：宽/高 = iconSlotSize，绝不随 pointer 变化
      // （KOS: dock/DockIcon.qml:116,234-235 + AppearanceTokens.qml:441-443）。
      width: slotSize,
      height: slotSize,
      child: MouseRegion(
        cursor: services.linkCursor,
        onEnter: (_) {
          _mouseInside = true;
          _updateHoverAndSpring();
          // TASK-03：转发给 popup 宿主 arm 300ms 预览 dwell
          // （KOS DockIcon.qml:939-941 onEntered → previewDelay.restart）。
          _previewKey.currentState?.onIconEnter();
        },
        onExit: (_) {
          _mouseInside = false;
          _updateHoverAndSpring();
          // TASK-03：取消 dwell + 130ms closeDelay
          // （KOS DockIcon.qml:942-944 onExited → previewCloseDelay）。
          _previewKey.currentState?.onIconExit();
        },
        child: GestureDetector(
          // 槽位整体可点：Stack 子节点都不自报 hit（IgnorePointer/SizedBox），
          // deferToChild 会让 GD 对 hit test 透明（KOS: DockIcon.qml 的整个
          // MouseArea anchors.fill 槽位）。
          behavior: HitTestBehavior.opaque,
          onTap: _activate,
          onSecondaryTap: _openContextMenu,
          child: Semantics(
            label: widget.name,
            value: '${widget.windows.length}',
            selected: widget.isActivated,
            button: true,
            child: Stack(
              clipBehavior: Clip.none,
              alignment: Alignment.center,
              children: [
                // 激活底斑：iconSlotSize 圆角方块，accent 0.22（subtle 语义，
                // KOS: dock/DockIcon.qml:128-138,597-621）。
                IgnorePointer(
                  child: AnimatedOpacity(
                    opacity: _showActiveBackground ? 1.0 : 0.0,
                    duration: const Duration(milliseconds: 150),
                    curve: Curves.easeOutCubic,
                    child: Container(
                      width: slotSize,
                      height: slotSize,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(radius),
                        color: context.shellTheme.accent.withValues(
                          alpha: kDockActiveBackgroundAlpha,
                        ),
                      ),
                    ),
                  ),
                ),
                // hover 高亮圆斑（iconSize 方块）：12% 白 → shellTheme 前景
                // 同 alpha（无 hover 色 token；KOS: DockIcon.qml:640-658，
                // 135ms OutCubic）。激活底斑存在时不叠加。
                IgnorePointer(
                  child: AnimatedOpacity(
                    opacity: _hovering && !_showActiveBackground ? 1.0 : 0.0,
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
                // 视觉层：槽内 Transform.scale(bottomCenter) + translate 合成
                // （KOS: DockIcon.qml:304 scale + :309-318 Translate.y）。
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
                      child: services.buildApplicationIcon(
                        context,
                        widget.appId,
                      ),
                    ),
                  ),
                ),
                // dot 指示行：图标正下方 runningIndicatorGap 处
                // （KOS: DockIcon.qml:788-833——仅 dot 分支）。
                Positioned(
                  bottom: _runningIndicatorGapFor(iconSize),
                  child: IgnorePointer(
                    child: _DockDots(
                      running: widget.windows.isNotEmpty,
                      windowCount: widget.windows.length,
                      color: colors.textPrimary.withValues(
                        alpha: kDockDotAlpha,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      ),
    );
  }

  /// runningIndicatorGap = max(1, (iconSize·vpad − dotSize)/2)
  /// （KOS: dock/DockIcon.qml:126-128；dot 5 → 槽底与图标底的半间距）。
  /// 方案 C：iconSize 随反解变化 → 由静态 final 改为按当前 iconSize 计算。
  static double _runningIndicatorGapFor(double iconSize) => math.max(
    1.0,
    (iconSize * kDockVerticalPaddingRatio - kDockDotSizeWide) / 2,
  );
}

/// dot 行：`dotCount=min(3,max(1,windowCount))`、size 4(count≥3)/5、
/// 间距 2、行宽 `count*size+(count-1)*2`、运行中才显示、140ms 透明度过渡
/// （KOS: dock/DockIcon.qml:790-811,813-833）。
class _DockDots extends StatelessWidget {
  const _DockDots({
    required this.running,
    required this.windowCount,
    required this.color,
  });

  final bool running;
  final int windowCount;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final count = math.min(kDockDotMaxCount, math.max(1, windowCount));
    final size = count >= 3 ? kDockDotSizeCompact : kDockDotSizeWide;
    final width = count * size + (count - 1) * kDockDotSpacing;
    return AnimatedOpacity(
      opacity: running ? 1.0 : 0.0,
      duration: kDockDotFadeDuration,
      curve: Curves.easeOutCubic,
      child: SizedBox(
        width: width,
        height: size,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            for (var i = 0; i < count; i++)
              Container(
                width: size,
                height: size,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
          ],
        ),
      ),
    );
  }
}
