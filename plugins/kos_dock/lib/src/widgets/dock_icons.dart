/// KOS Dock 图标行（pinned 段 + 未 pin 运行段 + 段间分割线 + magnification
/// 指针广播 + 重排持久化）。
///
/// - 模型：`services.applications` 目录 + `dockPreferencesProvider` pinned
///   顺序 + `services.windows(monitorId)` 运行态；条目序列由纯函数
///   `dockRowEntries`（state/dock_row_entries.dart）推导：pinned 段按
///   `prefs.pinned` 顺序 + 未 pin 运行段按 canonical appId 聚合（KOS
///   `dock/DockModelService.qml:150-200` grouped，CONSTRAINTS §5 修正
///   2026-10-05）。窗口经 `windowAppIds` 别名归一化匹配到 pin：
///   window.appId normalize 后 ∈ app.windowAppIds.map(normalize) 或 ==
///   pin.appId/pin.id normalize（PLUGIN_DEVELOPMENT.md 语义：存 opaque
///   launch `id`、多重匹配不猜）。`dock_shell.dart` 用同一函数推导图标
///   区自然宽（方案 A：视口宽度按实际条目算，不再只按 pinned 数）。
/// - 段结构（方案 B，对齐 KOS `dock/DockContainer.qml:496-962` 顺序）：
///   `Row[ pinned段 ReorderableListView | divider1(launchers|windows) |
///   运行段 Row ]`：pinned 段可拖拽重排（对应 pinnedRepeater，:612-845）；
///   divider1 仅 pinned+running 同时非空时插入（:847-857，visible :856）；
///   运行段是非重排普通 Row（对应 windowsRepeater，:859-862；未 pin 条目
///   无重排语义，DockIcon.qml:916-927），**不在** ReorderableListView 的
///   `dock.pinned` 槽位）：自然宽合计 = n*(slot+spacing)-spacing +
///   （两段都非空时 divider1 槽位）。方案 C（iconSize 反解，
///   `DockMetrics.fromWidth`）保证内容宽恒 ≤ maxWidth——v1 的「pinned 段
///   内滚动 + 运行段 ClipRect 收缩」兜底已整段移除（ReorderableListView
///   改为 NeverScrollableScrollPhysics 固定不滚）。
/// - magnification：容器单 `MouseRegion` 广播全局指针 x（KOS
///   `magnificationRoot`/`magnificationPointer` 模式，DockContainer.qml:
///   220-228 + DockIcon.qml:102-103），onExit 置 null（=KOS <-9999 哨兵）。
///   TASK-04 起广播统一由 `KosDockShell` 提供（覆盖 launcher/trash/两段
///   图标整行，ambient `MagnificationPointer`）；本行在无 ambient 的独立
///   宿主（单测）里保留自建 fallback，坐标同样经 RenderBox 转全局系。
/// - 重排：pinned 段 `ReorderableListView.builder` 水平 +
///   `buildDefaultDragHandles: false` + `ReorderableDragStartListener` +
///   proxyDecorator 包 `ShellServicesScope`/`ShellTheme`/`IgnorePointer`/
///   `ExcludeFocus`（搬 denial_taskbar `window_buttons.dart:173-235` 范式，
///   含 `_dragging`/`_endDrag`/`Listener` workaround 与 taskbar.dart:48-54
///   的 `ScrollConfiguration` mouse-dragDevices 剥离）；结果经 `DockOrder`
///   → `updatePins` 写回 JSON（DockOrder 只管 pinned 相对顺序）。
/// - 入场：每图标 `_DockEntrance`（denial_top_bar `_SystemBarEntrance`
///   范式：Timer 60ms×index 交错 + `springTo(Motion.snappy)` +
///   `Align(widthFactor:unit(t))` 槽宽展开 + Opacity，水平行用
///   `alignment: centerLeft`；交错 index 跨两段连续编号）。
/// - 空行（无 pinned 且无运行条目）：空 SizedBox（pill 本体仍由
///   dock_shell 画）。
library;

import 'dart:async';

import 'package:denial_flutter_sdk/input.dart';
import 'package:denial_flutter_sdk/motion.dart';
import 'package:denial_flutter_sdk/services.dart';
import 'package:denial_flutter_sdk/shell_theme.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/dock_row_entries.dart';
import '../state/dock_settings.dart';
import '../theme/dock_tokens.dart';
import 'dock_divider.dart';
import 'dock_icon.dart';
import 'dock_preview_popup.dart';
import 'magnification.dart';

/// 图标行：内部自建 `ShellServicesScope(services: widget.services)`，调用方
/// 只传 `ShellServices` + `monitorId`。
class DockIconRow extends ConsumerStatefulWidget {
  const DockIconRow({
    required this.monitorId,
    required this.services,
    this.coordinator,
    super.key,
  });

  final int monitorId;
  final ShellServices services;

  /// 全 pill 共享 popup 协调器（KOS dock/DockModelService.qml:32-39,65-72
  /// `activeDockPopup` 单例，由 `KosDockShell` 注入）；null → 本行自建一份
  /// （独立宿主/单测退化为行内协调）。
  final DockPopupCoordinator? coordinator;

  @override
  ConsumerState<DockIconRow> createState() => _DockIconRowState();
}

class _DockIconRowState extends ConsumerState<DockIconRow> {
  /// KOS `magnificationPointer`：指针全局 x；null=离开容器（=<-9999 哨兵，
  /// DockContainer.qml:220-222）。独立宿主 fallback 用；有 ambient
  /// MagnificationPointer（KosDockShell 广播）时不创建。
  final _pointerX = ValueNotifier<double?>(null);

  /// fallback MouseRegion 的 RenderBox（localToGlobal 坐标映射用）。
  final _pointerRegionKey = GlobalKey();
  final _order = DockOrder();

  /// KOS dock/DockModelService.qml:32-39,65-72 `activeDockPopup`/
  /// `activeContextMenu` 单例：任一时刻只有一个 popup（pinned 预览/菜单、
  /// trash 菜单、清空确认弹窗都计入），任一 pinned 菜单开着时全体图标
  /// previewDelay 抑制。shell 注入全 pill 共享的一份；无注入时自建。
  late final DockPopupCoordinator _popups =
      widget.coordinator ?? DockPopupCoordinator();
  List<String> _pinnedKeys = [];
  bool _dragging = false;
  bool _saving = false;

  /// pinned 段键数（=[_pinnedKeys].length；只有 pinned 段可拖拽重排、
  /// 可持久化）。方案 B 起运行段移出 ReorderableListView，本字段只服务
  /// `_reorder` 的防御性边界钳制。
  int get _pinnedCount => _pinnedKeys.length;

  /// 每 pinned 条目占 ReorderableListView 的滚动长度：末位槽宽 +
  /// （非末位）槽宽+spacing，由 build 内按 metrics 计算（不再是编译期常量）。

  /// pin.key 统一为 `app:` + normalize(pin.id)；运行段键 `run:` + normalize
  /// （appId）——定义移入 state/dock_row_entries.dart（`dockPinEntryKey` /
  /// `dockRunningEntryKey`），本行只引用。
  static String _keyFor(String launchId) => dockPinEntryKey(launchId);

  void _reorder(int from, int to) {
    if (_saving) return;
    // 只有 pinned 段可重排：ReorderableListView 只含 pinned 键（方案 B），
    // 未 pin 的运行条目不在列表内，既不能被拖也不能被推入（KOS
    // DockIcon.qml:916-927 的 window item 没有重排语义；`to` 是框架插入
    // 语义，from 之后的目标位会 −1 校正，故界内为 [0,pinnedCount-1]，
    // 钳制仍保留作防御）。
    final pinnedCount = _pinnedCount;
    if (from < 0 || from >= pinnedCount) return;
    final target = to < 0 ? 0 : (to > pinnedCount ? pinnedCount : to);
    final prefs = ref.read(dockPreferencesProvider).value;
    setState(() => _pinnedKeys = _order.reorder(from, target));
    if (prefs == null) return;
    final byKey = {for (final pin in prefs.pinned) _keyFor(pin.id): pin};
    // pinned 键的新相对顺序 → pin id 序列写回（DockOrder 只管 pinned）。
    final order = [
      for (final key in _pinnedKeys)
        if (byKey.containsKey(key)) key,
    ];
    if (order.map((k) => byKey[k]!.id).join('\n') ==
        prefs.pinned.map((p) => p.id).join('\n')) {
      return;
    }
    unawaited(
      _savePins((current) {
        int rank(PinnedApplication pin) {
          final index = order.indexOf(_keyFor(pin.id));
          return index < 0 ? order.length + current.indexOf(pin) : index;
        }

        return List<PinnedApplication>.of(current)
          ..sort((a, b) => rank(a).compareTo(rank(b)));
      }),
    );
  }

  /// 右键菜单「取消固定」：从 pinned 中移除该 key（KOS DockIcon.qml:
  /// 424-425 `unpin` → AppActionService.unpin；Denial 侧为 updatePins）。
  Future<void> _unpin(String key) => _savePins(
    (current) => [
      for (final pin in current)
        if (_keyFor(pin.id) != key) pin,
    ],
  );

  /// 运行中未 pin 条目的右键「固定此应用」（KOS DockIcon.qml:921-927
  /// `pinned ? unpin : pin` → `"固定此应用"`）：追加进 pinned 尾部，幂等。
  Future<void> _pinApp(String appId, String name, String? launchId) =>
      _savePins((current) {
        final key = _keyFor(launchId ?? appId);
        if (current.any((pin) => _keyFor(pin.id) == key)) return current;
        return [
          ...current,
          PinnedApplication(id: launchId ?? appId, appId: appId, name: name),
        ];
      });

  Future<void> _savePins(
    List<PinnedApplication> Function(List<PinnedApplication>) update,
  ) async {
    setState(() => _saving = true);
    try {
      await ref.read(dockPreferencesProvider.notifier).updatePins(update);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  // Flutter does not call onReorderEnd when an in-flight drag is cancelled
  // （搬 taskbar window_buttons.dart:286-290 注释）。
  void _endDrag() {
    if (_dragging) setState(() => _dragging = false);
  }

  @override
  void dispose() {
    _pointerX.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final services = widget.services;
    final catalog = ref.watch(services.applications);
    final prefsState = ref.watch(dockPreferencesProvider);
    final prefs = prefsState.value ?? const DockPreferences();
    final windows = ref.watch(services.windows(widget.monitorId));
    // popup 横向 clamp 的屏内矩形（taskbar `monitorBounds` 范式）。
    final monitorBounds = ref.watch(
      services.monitorBounds(widget.monitorId),
    );

    // 行条目序列由纯函数 `dockRowEntries` 推导（state/dock_row_entries.dart，
    // 方案 A 单一事实来源；dock_shell.dart 用同一函数推导行自然宽）：
    // pinned 段按 `prefs.pinned` 顺序，窗口经 `windowAppIds` 别名归一化聚到
    // pin；未 pin 窗口按 canonical appId 聚合「一应用一图标」，顺序取首次
    // 出现顺序（KOS `dock/DockModelService.qml:150-200` grouped：已 pin 的
    // 窗口 `continue` 只由 pinned 段渲染）。CONSTRAINTS §5 修正（用户决定
    // 2026-10-05）：未 pin 的运行应用也进 Dock；仍是「一应用一图标」，
    // 不做逐窗口列表 / minimize / close / urgent。
    final entries = dockRowEntries(
      prefs: prefs,
      catalog: catalog,
      windows: windows,
    );
    final entryByKey = {for (final entry in entries) entry.key: entry};
    // 方案 B（KOS DockContainer.qml:847-862 的两段 Repeater）：pinned 段
    // 与未 pin 运行段分属两个 widget——ReorderableListView 只含 pinned 键，
    // 运行段是其后普通 Row 的兄弟（详见顶部文件头）。DockOrder 已收敛为
    // pinned-only（单参数 update）：只管 pinned 的相对顺序；运行段顺序
    // 直接取 dockRowEntries 的「未 pin 窗口按 canonical appId 聚合、首次
    // 出现顺序」，不经 DockOrder 合并排序。
    _pinnedKeys = _order.update(
      [for (final entry in entries) if (entry.isPinned) entry.key],
    );
    final runningEntries = [
      for (final entry in entries)
        if (!entry.isPinned) entry,
    ];
    final totalCount = _pinnedKeys.length + runningEntries.length;
    // 方案 C：槽位宽/间距/divider 槽位全部由 DockMetrics 反解（读取 scope，
    // 独立宿主退回 DockMetricsScope.fallback 的基准几何）。
    final metrics = DockMetricsScope.of(context);
    final slotSize = metrics.iconSlotSize;
    final itemSpacing = metrics.itemSpacing;
    final itemExtent = slotSize + itemSpacing;

    // pinned 段 = ReorderableListView（可重排、持久化）；KOS 对应
    // pinnedRepeater（DockContainer.qml:612-845 的 DragHandler 重排）。
    final list = ReorderableListView.builder(
      scrollDirection: Axis.horizontal,
      padding: EdgeInsets.zero,
      // 方案 C：iconSize 反解保证内容恒 ≤ maxWidth，pinned 段不再需要横向
      // 自滚——NeverScrollableScrollPhysics 钉死视口（ReorderableListView 的
      // 滚动只服务于旧溢出兜底；拖拽重排走 drag listener，不依赖滚动）。
      physics: const NeverScrollableScrollPhysics(),
      // itemExtentBuilder 而非固定 itemExtent：固定值让**每个**条目（含末位）
      // 都占 slot+spacing，比自然宽 n*(slot+spacing)-spacing 多一个 spacing。
      // 末位条目外侧 Padding 无 spacing，其槽位长度只报 iconSlotSize。
      itemExtentBuilder: (index, _) => index == _pinnedKeys.length - 1
          ? slotSize
          : itemExtent,
      itemCount: _pinnedKeys.length,
      buildDefaultDragHandles: false,
      onReorderItem: _reorder,
      onReorderStart: (_) => setState(() => _dragging = true),
      onReorderEnd: (_) => setState(() => _dragging = false),
      proxyDecorator: (child, _, _) => ShellServicesScope(
        services: services,
        child: ShellTheme(
          data: context.shellTheme,
          child: IgnorePointer(child: ExcludeFocus(child: child)),
        ),
      ),
      itemBuilder: (context, index) {
        final key = _pinnedKeys[index];
        final entry = entryByKey[key];
        if (entry == null) {
          return SizedBox.shrink(key: ValueKey('missing:$key'));
        }
        final spacing = index == _pinnedKeys.length - 1 ? 0.0 : itemSpacing;
        return ReorderableDragStartListener(
          key: ValueKey(key),
          index: index,
          enabled: !_saving,
          child: Padding(
            padding: EdgeInsets.only(right: spacing),
            child: _DockEntrance(
              index: index,
              child: DockIcon(
                appId: entry.appId,
                name: entry.name,
                // D-1：entry.launchId 已是 catalog `LaunchableApplication.id`
                // （命中）或退化 pin.id（未命中），见 dock_row_entries.dart。
                launchId: entry.launchId,
                monitorId: widget.monitorId,
                windows: entry.windows,
                isActivated: entry.windows.any((w) => w.active),
                monitorBounds: monitorBounds,
                dragging: _dragging,
                onTogglePin: () => _unpin(key),
                coordinator: _popups,
              ),
            ),
          ),
        );
      },
    );

    // 运行段 = 非重排普通 Row（KOS windowsRepeater，DockContainer.qml:
    // 859-862；未 pin 条目无重排语义，DockIcon.qml:916-927）。
    // KOS: DockContainer.qml:847-857 — divider1(launchers|windows) 只在
    // pinned 与未 pin 运行段**同时非空**时插入（visible :856）；槽位宽 =
    // dividerWidth + sideMargin*2（DockDivider.qml:20-22）。
    final dividerSlot = metrics.dividerSlotWidth;
    final showDivider = _pinnedKeys.isNotEmpty && runningEntries.isNotEmpty;
    // 运行段 = 自然宽非重排普通 Row（KOS windowsRepeater，DockContainer.qml:
    // 859-862）。方案 C：iconSize 反解保证行自然宽恒 ≤ dock.pinned 槽位
    // 预算——v1 的 ClipRect+OverflowBox 收缩/裁剪兜底已移除，Row 直接以
    // 自然宽排布。
    final runningRow = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
            for (var i = 0; i < runningEntries.length; i++)
              () {
                final entry = runningEntries[i];
                // KOS window item（DockModelService.qml:150-200 grouped
                // 未 pin 段）：不可拖拽、菜单第三项为「固定此应用」
                // （DockIcon.qml:921-927）。
                return Padding(
                  key: ValueKey(entry.key),
                  padding: EdgeInsets.only(
                    right: i == runningEntries.length - 1
                        ? 0.0
                        : itemSpacing,
                  ),
                  child: _DockEntrance(
                    index: _pinnedKeys.length + i,
                    child: DockIcon(
                      appId: entry.appId,
                      name: entry.name,
                      launchId: entry.launchId,
                      monitorId: widget.monitorId,
                      windows: entry.windows,
                      isActivated: entry.windows.any((w) => w.active),
                      monitorBounds: monitorBounds,
                      dragging: _dragging,
                      isPinnedEntry: false,
                      onTogglePin: () => _pinApp(
                        entry.appId,
                        entry.name,
                        entry.launchId,
                      ),
                      coordinator: _popups,
                    ),
                  ),
                );
              }(),
          ],
    );

    // 图标区自然宽 = pinned 段 + divider1 + 运行段（与 dock_shell
    // `_iconRowWidth` 同式；方案 C 起恒 ≤ 槽位宽，不再 clamp/滚动）。
    final pinnedNatural = _pinnedKeys.isEmpty
        ? 0.0
        : _pinnedKeys.length * itemExtent - itemSpacing;
    final runningNatural = runningEntries.isEmpty
        ? 0.0
        : runningEntries.length * itemExtent - itemSpacing;
    final natural = pinnedNatural +
        (showDivider ? dividerSlot : 0.0) +
        runningNatural;

    final body = ShellServicesScope(
      services: services,
      child: Listener(
        onPointerUp: (_) => _endDrag(),
        onPointerCancel: (_) => _endDrag(),
        child: ShellInputRegion(
          debugLabel: 'Dock application reorder capture',
          active: _dragging,
          pointerPolicy: ShellPointerPolicy.fullScene,
          child: ShellInputRegion(
            debugLabel: 'Dock application icons',
            // Desktop mouse drags belong to reordering（taskbar.dart:48-54
            // workaround：shell 全局启用 mouse drag scrolling；图标行自身
            // 方案 C 起不再可滚——ReorderableListView 已 NeverScrollable，
            // scrollbars:false 白条兜底随之删除）。只剥离 mouse 拖拽设备。
            child: ScrollConfiguration(
              behavior: ScrollConfiguration.of(context).copyWith(
                dragDevices: ScrollConfiguration.of(context).dragDevices
                    .where((device) => device != PointerDeviceKind.mouse)
                    .toSet(),
              ),
              child: totalCount == 0
                  ? const SizedBox.shrink()
                  : Center(
                      child: SizedBox(
                        width: natural,
                        child: Row(
                          children: [
                            if (_pinnedKeys.isNotEmpty)
                              SizedBox(
                                key: const ValueKey<String>(
                                  'dock.row.pinned',
                                ),
                                width: pinnedNatural,
                                height: slotSize,
                                child: list,
                              ),
                            if (showDivider)
                              const DockDivider(
                                key: ValueKey<String>(
                                  'dock.divider.launchers',
                                ),
                              ),
                            if (runningEntries.isNotEmpty)
                              SizedBox(
                                key: const ValueKey<String>(
                                  'dock.row.running',
                                ),
                                width: runningNatural,
                                height: slotSize,
                                child: runningRow,
                              ),
                          ],
                        ),
                      ),
                    ),
            ),
          ),
        ),
      ),
    );

    // TASK-04：指针广播上移到 KosDockShell（覆盖 launcher/trash/pinned
    // 整个 pill 内容 Row，KOS DockContainer.qml:220-228 唯一 HoverHandler
    // 给所有图标喂同一坐标）。有 ambient 时直接消费，行内不再重复自建；
    // 无 ambient（独立宿主/单测）保留自建 fallback MouseRegion。
    if (MagnificationPointer.maybeOf(context) != null) return body;
    return MouseRegion(
      key: _pointerRegionKey,
      onHover: _broadcastPointer,
      onExit: (_) => _pointerX.value = null,
      child: MagnificationPointer(pointerX: _pointerX, child: body),
    );
  }

  /// 广播指针 x 到与槽中心同系的全局坐标系：MouseRegion 事件给的是局部
  /// 坐标，经自身 RenderBox.localToGlobal 映射（DockIcon `_slotCenterX`
  /// 同为 localToGlobal 全局系；修复仅当行位于全局 x=0 才偶然正确的问题）。
  void _broadcastPointer(PointerHoverEvent event) {
    final box = _pointerRegionKey.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.attached) return;
    _pointerX.value = box.localToGlobal(event.localPosition).dx;
  }
}

/// 每图标入场交错：Timer 60ms×index + `springTo(Motion.snappy)` +
/// `Align(widthFactor:unit(t))` 槽宽展开 + Opacity（denial_top_bar
/// `desktop_system_bar_components.dart:322-390` `_SystemBarEntrance` 范式；
/// dock 水平行用 `alignment: centerLeft` + widthFactor）。
///
/// 无障碍「减弱动效」（`MediaQuery.disableAnimationsOf`）下直接落到终态，
/// 与 `_DockIconState._springTo` / `_DockControlIconState._springTo` 的既有
/// 处理一致（SDK 契约：动效可整体关闭）。否则会留下一个永不推进的弹簧
/// ticker：flutter_test 里 `disableAnimations` 恒为 true 且测试内多为
/// 零时长 `pump()`（帧时间戳不前进 → 弹簧 tick 的 elapsed 恒为 0），任何
/// 断言失败都会让整个 `flutter test` 运行挂住（该用例不再走框架的收尾
/// pump，活动 ticker 使 test runner 停在收尾阶段）。
class _DockEntrance extends StatefulWidget {
  const _DockEntrance({required this.index, required this.child});

  final int index;
  final Widget child;

  @override
  State<_DockEntrance> createState() => _DockEntranceState();
}

class _DockEntranceState extends State<_DockEntrance>
    with SingleTickerProviderStateMixin {
  static const double _slideDistance = 12.0;

  late final AnimationController _controller = AnimationController.unbounded(
    vsync: this,
  );
  Timer? _delay;

  @override
  void initState() {
    super.initState();
    _delay = Timer(kDockEntranceStagger * widget.index, () {
      if (!mounted) return;
      // 减弱动效 → 直接终态（同 dock_icon.dart / launcher_icon.dart 的
      // `_springTo` 处理）。
      if (MediaQuery.disableAnimationsOf(context)) {
        _controller.value = 1.0;
        return;
      }
      unawaited(
        springTo(
          _controller,
          1.0,
          spring: Motion.snappy,
          telemetryLabel: 'dock_icon_entrance',
        ),
      );
    });
  }

  @override
  void dispose() {
    _delay?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final t = _controller.value;
        final slide = (1.0 - t) * -_slideDistance;
        return Align(
          alignment: Alignment.centerLeft,
          widthFactor: unit(t),
          child: Opacity(
            opacity: unit(t),
            child: Transform.translate(
              offset: Offset(slide, 0),
              // 把入场位移公布给子树：图标测量槽中心时扣除它，等价 KOS
              // 「每次求值都映射未变换槽位」（DockIcon.qml:256-263）。
              child: DockEntranceOffset(dx: slide, child: child!),
            ),
          ),
        );
      },
      child: widget.child,
    );
  }
}

