/// KOS Dock 单图标 → TASK-11 重构为波形槽位直绑（quickshell
/// `Modules/Dock/DockItem.qml` 语义）。
///
/// 与旧 KOS `dock/DockIcon.qml` 的差异（基准改 quickshell，记
/// docs/visual-deltas.md TASK-11）：
/// - **槽宽随指针变**：布局尺寸由 `dockWaveLayout` 经 [DockIcon.slotSize]
///   下发（`span = slot·scale + gap`），图标视觉边长 = 槽位 `size` 直绑
///   （`DockItem.qml` `iconSize` 直绑槽位），被指图标把邻居连续推开；
///   旧「固定 iconSlotSize 槽内 Transform.scale」路径整段移除；
/// - hover 判定、放大 scale 都由行级 `dockWaveLayout` 统一算——图标
///   不再自测槽中心/自起 spring（DockLayout.js:16-17：动画坐标绝不回喂
///   magnification；硬性约束①唯一缓动是容器振幅包络）；
/// - activeBackground（isRunning && isActivated 的 accent 0.22 圆角槽，
///   KOS DockIcon.qml:128-138,597-621）/ hover 高亮圆斑 135ms
///   （:640-658）/ dot 指示行（:788-833）保留——底斑边长跟随槽位
///   `slotSize` 直变；
/// - 点击：0 窗 launch、1 窗 activate、多窗 MRU 轮循
///   （dock/DockModelService.qml:317-366，无 minimize 分支）；TASK-10 起
///   launch 分支额外播一次弹跳（quickshell `DockItem.qml:86-104`
///   `launchAnimation`：上跳 19px/220ms OutQuad → 340ms OutBounce 落地，
///   单次），`_activate` 的 `windows.isEmpty` 分支内触发；
/// - hover 预览 + 右键菜单：TASK-03，popup 管线在
///   `dock_preview_popup.dart`（`DockPreviewAnchor`），这里只做事件转发。
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:denial_flutter_sdk/services.dart';
import 'package:denial_flutter_sdk/shell_theme.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/material.dart' show ColorScheme;

import '../theme/dock_tokens.dart';
import 'dock_preview_popup.dart';
import 'magnification.dart';

/// 单个 Dock 图标。布局尺寸 = 调用方下发的槽宽 [slotSize]（TASK-11：
/// `dockWaveLayout` 的槽内图标槽宽 `size·weight·scale`，指针在容器时随
/// 高斯 scale 连续变化；未下发时退回 `DockMetricsScope` 的
/// `iconSlotSize`——独立宿主/单测无波形布局时等价旧固定槽位）。
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
    this.slotSize,
    this.iconScale = 1.0,
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

  /// 槽位宽（`dockWaveLayout` 下发的槽内图标槽宽 `size·weight·scale`；
  /// null → `DockMetricsScope.iconSlotSize`）。宽/高布局尺寸取它。
  final double? slotSize;

  /// 槽位高斯 scale（波形下发的 `slot.size / baseSlot`；1 = 静止）。
  /// 美术边长 = `iconSize · iconScale`——直绑不 spring（TASK-11 约束①）。
  final double iconScale;

  @override
  State<DockIcon> createState() => _DockIconState();
}

/// TASK-10 launch bounce 位移曲线（px，≥0）：`0 → kDockLaunchBounceHeight`
///（`kDockLaunchBounceRiseDuration`=220ms，`Curves.easeOutQuad` 上升）→
/// `0`（`kDockLaunchBounceFallDuration`=340ms，`Curves.bounceOut` 落地）。
/// 段权重按毫秒时长给出；驱动它的有界 controller 总时长 =
/// `kDockLaunchBounceRiseDuration + kDockLaunchBounceFallDuration`（560ms）。
///
/// 对齐 quickshell `Modules/Dock/DockItem.qml:86-104` `launchAnimation`
///（`bounce: 0→19`/`duration:220`/`Easing.OutQuad` + `to:0`/`duration:340`/
/// `Easing.OutBounce`），消费端：`DockIcon._bounceLift`（launch 分支）与
/// `DockControlIcon._bounceLift`（launcher/trash tap）。**包级单源**——
/// `test/dock_icon_bounce_test.dart` 直接引用本常量驱动独立 controller
/// 验证曲线，避免测试内复本与实现漂移。
final Animatable<double> kosDockBounceLiftSequence = TweenSequence<double>([
  TweenSequenceItem(
    tween: Tween<double>(
      begin: 0,
      end: kDockLaunchBounceHeight,
    ).chain(CurveTween(curve: Curves.easeOutQuad)),
    weight: kDockLaunchBounceRiseDuration.inMilliseconds.toDouble(),
  ),
  TweenSequenceItem(
    tween: Tween<double>(
      begin: kDockLaunchBounceHeight,
      end: 0,
    ).chain(CurveTween(curve: Curves.bounceOut)),
    weight: kDockLaunchBounceFallDuration.inMilliseconds.toDouble(),
  ),
]);

/// 入场视觉位移广播：图标行 `_DockEntrance`（`dock_icons.dart`）每帧公布
/// 当前水平位移 dx。TASK-11 起图标不再自测槽中心（wave 布局在行级统一
/// 算），本广播仅保留给 `DockPreviewAnchor` 等消费端兼容——无消费者时可
/// 后续清掉。
class DockEntranceOffset extends InheritedWidget {
  const DockEntranceOffset({required this.dx, required super.child, super.key});

  /// 当前水平视觉位移（px，向左为负）。
  final double dx;

  /// 当前入场位移；无 [DockEntranceOffset] 祖先时为 0。
  static double of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<DockEntranceOffset>()?.dx ??
      0.0;

  @override
  bool updateShouldNotify(DockEntranceOffset oldWidget) => oldWidget.dx != dx;
}

class _DockIconState extends State<DockIcon> with TickerProviderStateMixin {
  /// 指针缺席时的独立 hover 进度（0/1 bounded tween，`kDockHoverEaseDuration`
  /// easeOutCubic）：KOS `dock/DockIcon.qml:291-300` 的无 magnification
  /// hover 回退分支（scale 1.20 + lift −max(2,round(iconSize×0.08))）。
  /// 容器内有指针时波形统一接管（[widget.iconScale] 直绑），本 controller
  /// 停在 0。
  late final AnimationController _hover = AnimationController(
    vsync: this,
    duration: kDockHoverEaseDuration,
  );

  /// TASK-10 点击启动单次弹跳（launch bounce）：y 位移 ∈ [0,1] ×
  /// `kDockLaunchBounceHeight`（quickshell `DockItem.qml:86-104`
  /// `bounce: 0→19`），叠加进槽内 `Transform.translate` 的 y。**有界**
  /// controller——TweenSequence 两段（220ms easeOutQuad 上升 /
  /// 340ms bounceOut 落地），单次 forward 不循环。
  late final AnimationController _bounce = AnimationController(
    vsync: this,
    duration: kDockLaunchBounceRiseDuration + kDockLaunchBounceFallDuration,
  );

  /// bounce controller → 上跳位移（px，≥0），曲线定义见
  /// [kosDockBounceLiftSequence]（包级单源，测试直接引用同一常量）。
  late final Animation<double> _bounceLift = _bounce.drive(
    kosDockBounceLiftSequence,
  );

  bool _mouseInside = false;
  bool _hovering = false;
  bool _launched = false;

  /// TASK-03 popup 宿主：hover 预览 + 右键菜单的状态机都在
  /// `DockPreviewAnchorState`，DockIcon 只转发 enter/exit/secondaryTap。
  final _previewKey = GlobalKey<DockPreviewAnchorState>();

  /// 上次广播到的指针 x（`identical` 比较区分 null→0.0 跳变）。
  double? _lastPointerX;

  bool get _showActiveBackground =>
      widget.windows.isNotEmpty && widget.isActivated;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _updateHover();
    });
  }

  /// hover 判定 + 独立 hover 进度目标（无指针时的回退路径）。
  ///
  /// 有容器指针时：波形把放大交给槽位 scale（[widget.iconScale]），
  /// `_hovering` 以「指针是否落在本槽」判定——槽中心不再自测，由
  /// [MagnificationPointer] 广播与本槽实测几何对算（TASK-11：图标
  /// 仍可用 `localToGlobal` 实测当前视觉中心，只做 hover 判定不做
  /// influence——hover 亮斑是布尔态，不回喂波形，无自激风险）。
  void _updateHover() {
    final pointerX = MagnificationPointer.of(context);
    final metrics = DockMetricsScope.of(context);
    final bool hovering;
    if (pointerX == null) {
      // KOS: dock/DockIcon.qml:363-368 — 容器无指针时回退 MouseArea 答案。
      hovering = _mouseInside;
    } else {
      // KOS: dock/DockIcon.qml:369-371 — 以槽位矩形判定 hover。
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
    // 独立 hover 进度驱动 lift/scale 缓动；有容器指针时 `_hovering` 由
    // 槽位命中判定（`_updateHover` 上半），scale 视觉被 `iconScale` 接管
    // ——`_hover` 仍跟 `_hovering` 走作为 lift 缓动（指针悬停→lift 负值，
    // bounce 测试的 lift 基线依赖它），scale 分量在 builder 内有指针时归 1。
    final target = _hovering ? 1.0 : 0.0;
    if (MediaQuery.disableAnimationsOf(context)) {
      _hover.value = target;
    } else {
      _hover.animateTo(target, curve: Curves.easeOutCubic);
    }
  }

  void _activate() {
    final services = ShellServicesScope.of(context);
    if (widget.windows.isEmpty) {
      final id = widget.launchId;
      if (id == null || _launched) return;
      _launched = true;
      // TASK-10：launch 分支触发单次弹跳（quickshell DockItem.qml:86-104
      // `launchAnimation`——只对 launch 起跳；activate/多窗轮循不弹）。
      // `MediaQuery.disableAnimations` 下直接钉 0（与 `_updateHover`
      // 「直写终值」兜底同理：forward 会留一个测试环境永不推进的 ticker）。
      if (!MediaQuery.disableAnimationsOf(context)) {
        unawaited(_bounce.forward(from: 0));
      } else {
        _bounce.value = 0;
      }
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
    _bounce.dispose();
    _hover.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final services = ShellServicesScope.of(context);
    // 依赖容器指针广播：值变化触发本 build → 帧后重算 hover 判定。
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
        // 槽位宽 = 波形下发值（含 scale；无波形宿主退回 iconSlotSize）。
        // TASK-11：槽宽本身随指针变——邻居被连续推开，不再是固定槽内缩放。
        width: slotSize,
        height: slotSize,
        child: MouseRegion(
          cursor: services.linkCursor,
          onEnter: (_) {
            _mouseInside = true;
            _updateHover();
            // TASK-03：转发给 popup 宿主 arm 300ms 预览 dwell
            // （KOS DockIcon.qml:939-941 onEntered → previewDelay.restart）。
            _previewKey.currentState?.onIconEnter();
          },
          onExit: (_) {
            _mouseInside = false;
            _updateHover();
            // TASK-03：取消 dwell + 130ms closeDelay
            // （KOS DockIcon.qml:942-944 onExited → previewCloseDelay）。
            _previewKey.currentState?.onIconExit();
          },
          child: GestureDetector(
            // 槽位整体可点：Stack 子节点都不自报 hit（IgnorePointer/
            // SizedBox），deferToChild 会让 GD 对 hit test 透明（KOS:
            // DockIcon.qml 的整个 MouseArea anchors.fill 槽位）。
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
                // TASK-12：槽位列底锚（美术盒贴带底向上长；quickshell
                // DockItem.qml:112 artwork.y = 带底 − height − 12 − bounce）。
                alignment: Alignment.bottomCenter,
                children: [
                  // 激活底斑：iconSlotSize 圆角方块，accent 0.22（subtle
                  // 语义，KOS: dock/DockIcon.qml:128-138,597-621）；边长随
                  // 槽位直变（槽内图标槽宽）。TASK-12：钉在 pill 区（列底
                  // 上 dockHeight 高）内**底对齐**——放大槽位（slotSize >
                  // dockHeight）时底斑不跟美术盒一起探出 pill 顶缘。
                  Positioned(
                    bottom: 0,
                    height: metrics.dockHeight,
                    child: IgnorePointer(
                      child: AnimatedOpacity(
                        opacity: _showActiveBackground ? 1.0 : 0.0,
                        duration: const Duration(milliseconds: 150),
                        curve: Curves.easeOutCubic,
                        // TASK-12 复审缺陷3：Positioned 给子树 tight
                        // dockHeight 高 → 必须用 Align+SizedBox 恢复
                        // slotSize 方块并底对 pill 区（同 dot 行 :483-499
                        // 的 Align 模式）；否则底斑被拉成贴满 pill 顶底缘
                        // 的长条。
                        child: Align(
                          alignment: Alignment.bottomCenter,
                          child: SizedBox(
                            width: slotSize,
                            height: slotSize,
                            child: Container(
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(radius),
                                color: context.shellTheme.accent.withValues(
                                  alpha: kDockActiveBackgroundAlpha,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  // hover 高亮圆斑（iconSize 方块）：12% 白 → shellTheme 前
                  // 景同 alpha（无 hover 色 token；KOS: DockIcon.qml:640-658，
                  // 135ms OutCubic）。激活底斑存在时不叠加。TASK-12：与激活
                  // 底斑同钉 pill 区内底对齐（不跟放大美术盒上探）。
                  Positioned(
                    bottom: 0,
                    height: metrics.dockHeight,
                    child: IgnorePointer(
                      child: AnimatedOpacity(
                        opacity: _hovering && !_showActiveBackground
                            ? 1.0
                            : 0.0,
                        duration: kDockHoverHighlightDuration,
                        curve: Curves.easeOutCubic,
                        // TASK-12 复审缺陷3：同底斑——Align+SizedBox 恢复
                        // iconSize 方块并底对 pill 区，不高拉成条。
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
                  // 视觉层：美术边长 = iconSize·iconScale 直绑（波形跟手，
                  // 无逐图标 spring）；底部对齐随槽位放大向上生长（macOS
                  // 的 lift 效果由「放大 + 底部锚定」自然产生，不再是独立
                  // lift 位移）。TASK-10 的 launch bounce 位移叠加进同一
                  // 槽内 Transform.translate 的 y（不动布局尺寸）。
                  // TASK-12 缺陷2：美术盒视觉底边距 pill 底保持常量 margin =
                  // 静止居中布局的自然下边距 (dockHeight−iconSize)/2
                  // （quickshell `DockItem.qml:112` `artwork.y = 带底 −
                  // height − 12 − bounce` 的 12px 常量底边距等价）——美术盒
                  // 底钉在该 margin 向上长，静止时图标位与 TASK-11 前居中
                  // 布局一致。dot/activeBackground/hover highlight 仍钉
                  // pill 区内（本 Padding 只包美术盒锚链）。
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
                          // 独立 hover 回退：无容器指针时 scale 1→1.20 +
                          // lift −max(2,round(iconSize×0.08))（KOS :291-300）。
                          // 有指针时视觉大小由 `iconScale` 直给、scale 分量归 1
                          // （不双重放大）；lift 仍随 `_hovering` 缓动——hover 的
                          // 负 y 反馈不被波形替代（bounce 测试的 lift 基线）。
                          // TASK-12 复审缺陷4：「放大路径激活」对齐包络
                          // （quickshell `directMagnification = requested ||
                          // progress > 0`，DockSurface.qml:104）——行级
                          // `WaveEnvelope` 在 amplitude>0 的 220ms 退出塌回期
                          // 仍广播 true，hoverScale 继续走波形路径（=1.0）；
                          // 无 scope 的独立宿主/单测退回原式（只看
                          // MagnificationPointer 非 null）。
                          final hasPointer =
                              MagnificationPointer.of(context) != null ||
                              WaveEnvelope.activeOf(context);
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
                            child: services.buildApplicationIcon(
                              context,
                              widget.appId,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  // Official taskbar underline, anchored inside the Dock body.
                  // It stays in place when the application icon magnifies.
                  Positioned(
                    bottom: 0,
                    height: metrics.dockHeight,
                    child: Align(
                      alignment: Alignment.bottomCenter,
                      child: Padding(
                        padding: EdgeInsets.only(
                          bottom: _runningIndicatorGapFor(iconSize),
                        ),
                        child: IgnorePointer(
                          child: _DockRunningIndicator(
                            running: widget.windows.isNotEmpty,
                            active: widget.isActivated,
                            windowCount: widget.windows.length,
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

/// Matches denial_taskbar: active primary underline, short inactive underline,
/// and one translucent rear copy for multiple windows.
class _DockRunningIndicator extends StatelessWidget {
  const _DockRunningIndicator({
    required this.running,
    required this.active,
    required this.windowCount,
  });

  final bool running;
  final bool active;
  final int windowCount;

  @override
  Widget build(BuildContext context) {
    final shell = context.shellTheme;
    final scheme = ColorScheme.fromSeed(
      seedColor: shell.accent,
      brightness: shell.brightness,
    );
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return AnimatedOpacity(
      opacity: running ? 1.0 : 0.0,
      duration: reduceMotion ? Duration.zero : kDockDotFadeDuration,
      curve: Curves.easeOutCubic,
      child: AnimatedContainer(
        key: const ValueKey('dock.runningIndicator'),
        duration: reduceMotion ? Duration.zero : const Duration(milliseconds: 160),
        width: active ? 22 : 6,
        height: 6,
        child: CustomPaint(
          painter: _DockInstanceStackPainter(
            count: math.min(2, windowCount),
            color: active ? scheme.primary : scheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

class _DockInstanceStackPainter extends CustomPainter {
  const _DockInstanceStackPainter({required this.count, required this.color});
  final int count;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    for (var i = count - 1; i >= 0; i--) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(i * 4, 0, size.width, 3),
          const Radius.circular(1.5),
        ),
        Paint()..color = color.withValues(alpha: color.a * (i == 0 ? 1 : 0.65)),
      );
    }
  }

  @override
  bool shouldRepaint(_DockInstanceStackPainter oldDelegate) =>
      count != oldDelegate.count || color != oldDelegate.color;
}
