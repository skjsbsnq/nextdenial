/// KOS Dock 图标行（pinned 段 + 未 pin 运行段 + 段间分割线 + magnification
/// 指针广播 + 重排持久化）→ TASK-11 重构为 quickshell 高斯波可变槽位。
///
/// - 模型：`services.applications` 目录 + `dockPreferencesProvider` pinned
///   顺序 + `services.windows(monitorId)` 运行态；条目序列由纯函数
///   `dockRowEntries`（state/dock_row_entries.dart）推导：pinned 段按
///   `prefs.pinned` 顺序 + 未 pin 运行段按 canonical appId 聚合（KOS
///   `dock/DockModelService.qml:150-200` grouped，CONSTRAINTS §5 修正
///   2026-10-05）。窗口经 `windowAppIds` 别名归一化匹配到 pin。
/// - 布局（TASK-11 核心改动）：**弃 ReorderableListView**——其固定
///   itemExtent 模型无法表达「槽宽随指针连续变化」。改为对所有槽位
///   （[leading] 内建件 + pinned + divider1 + running）每帧调纯函数
///   `dockWaveLayout`（magnification.dart，quickshell
///   `Common/functions/DockLayout.js:18-58 layout()` 移植）得
///   `{start, span, size}`，用 `Stack` + `Positioned` 摆放。槽宽
///   `span = size·weight·scale + gap` 随高斯 scale 变——被指图标把邻居
///   连续推开（旧「固定 iconSlotSize 槽 + 槽内 Transform.scale」做不到）。
///   高斯 `center` 一律用**未缩放**静止坐标（DockLayout.js:16-17 明令：
///   动画坐标绝不回喂 magnification）。指针 x 每帧直取不动画；唯一缓动
///   是振幅包络 [_amplitude]（220ms easeOutCubic 进出 + 80ms 退出防抖，
///   quickshell `DockSurface.qml:91-110,637-644`）。**无指针 / amplitude=0
///   → 全槽 scale=1 → 静止布局**（与 pill 反解自然宽同源，硬性约束④）。
///   无 ambient `MagnificationPointer`（独立宿主/单测）时本行自建 fallback
///   MouseRegion + 包络（列在 `_ownPointerX`/`_envelope` 字段注释）。
/// - 手写重排（ReorderableListView 移除后的等价手写，对齐 quickshell
///   `DockItem.qml` MouseArea 拖拽 + `DockLayout.js insertionIndex/
///   previewOrder` + `DockSurface.qml:414-433,513-540`）：pinned 槽位上的
///   `Listener` 收指针事件——按下后水平位移超 `kDockReorderDragThreshold`
///   即进 reorder 态（`!_saving` 才可发起，对应原 `enabled: !_saving`）；
///   拖动中指针 x 经 `dockWaveInsertionIndex` 求**移除前**序列的插入位
///   （判定用**未缩放**槽位中线，`DockSurface.qml:414-415` 注释：hit test
///   留在不变模型的坐标系，动画中的邻居不回移自己的阈值；含 6px 跨中线
///   迟滞 :425-432），`dockWavePreviewOrder` 给预览置换序重排槽位、被拖
///   图标成跟随指针的 `_dragProxy` 浮层；松手/取消落位经
///   `dockWaveDropTarget` 转移除后下标 → `_reorder` → `DockOrder` →
///   `_savePins` 持久化（pinned-only，同原 `onReorderItem` 语义）。拖出
///   pill（|dy|>dockHeight）仅取消预览不 unpin（KOS/unpin 走右键菜单）。
/// - 入场：每槽位 `_DockEntrance`（denial_top_bar `_SystemBarEntrance`
///   范式：Timer 60ms×index 交错 + `springTo(Motion.snappy)` +
///   `Align(widthFactor:unit(t))` 展开 + Opacity），交错 index 跨
///   leading/pinned/running 连续编号。
/// - 空行（无 leading、无 pinned、无运行条目）：空 SizedBox（pill 本体
///   仍由 dock_shell 画；showLauncher/showTrash 关掉后可能只剩托盘）。
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
import 'launcher_icon.dart';
import 'magnification.dart';
import 'trash_icon.dart';

/// 手写重排的拖拽预览（quickshell `DockItem.qml` + `DockLayout.js:84-98`
/// `previewOrder`）：`source`/`gap` 均为 **pinned 段相对**下标（移除前
/// 序列的插入位 ∈[0,pinnedCount]，`gap==source` 或 `gap==source+1` 等价
/// 原地）。预览置换只作用在 pinned 子序列上（`_displayOrder`）。
typedef _DragPreview = ({int source, int gap});

/// 图标行：内部自建 `ShellServicesScope(services: widget.services)`，调用方
/// 只传 `ShellServices` + `monitorId`。
class DockIconRow extends ConsumerStatefulWidget {
  const DockIconRow({
    required this.monitorId,
    required this.services,
    this.leading = const <Widget>[],
    this.coordinator,
    this.layoutWidth,
    super.key,
  });

  final int monitorId;
  final ShellServices services;

  /// pinned 段之前的**内建件**槽位（shell 传 launcher/trash；TASK-11：
  /// 纳入同一 `dockWaveLayout` 权重 1 的波形，quickshell 把 launcher/trash
  /// 也当普通槽位一起缩放）。每项内部自带 `DockControlIcon`（接受外层
  /// 下发的 `slotSize`/`iconScale` —— 经 `_waveSlot` 包一层传入）。
  final List<Widget> leading;

  /// 全 pill 共享 popup 协调器（KOS dock/DockModelService.qml:32-39,65-72
  /// `activeDockPopup` 单例，由 `KosDockShell` 注入）；null → 本行自建一份
  /// （独立宿主/单测退化为行内协调）。
  final DockPopupCoordinator? coordinator;

  /// TASK-12 当帧波形布局宽（Σspan）输出：非 null 时波形 `AnimatedBuilder`
  /// 内每帧 postFrame 写回 `frameSlots.last.start + last.span`；**空行
  /// （totalCount==0）写回 0**（postFrame + mounted/notifier 存活守卫，见
  /// `_reportLayoutWidth`）。值不变不写，避免通知风暴；postFrame 写入保证
  /// shell 侧的 AnimatedBuilder 不在本行 build 中途被脏标记 → 无 build 中
  /// 标记脏异常、无 layout 反馈环。
  /// `KosDockShell` 用它让 pill 本体/底层占位/带层 `dock.pinned` 宽跟随当
  /// 帧放大后的布局长（quickshell `DockSurface.qml:119-120` `bandLength =
  /// min(availableLength, max(96, layout.length))`：pill 两端对称外扩，放大
  /// 图标始终留在 pill 内不遮 divider/info/tray）。
  final ValueNotifier<double>? layoutWidth;

  @override
  ConsumerState<DockIconRow> createState() => _DockIconRowState();
}

class _DockIconRowState extends ConsumerState<DockIconRow>
    with SingleTickerProviderStateMixin {
  /// KOS `magnificationPointer`：指针全局 x；null=离开容器（=<-9999 哨兵，
  /// DockContainer.qml:220-222）。独立宿主 fallback 用；有 ambient
  /// MagnificationPointer（KosDockShell 广播）时不创建。
  final _pointerX = ValueNotifier<double?>(null);

  /// fallback MouseRegion 的 RenderBox（localToGlobal 坐标映射用）。
  final _pointerRegionKey = GlobalKey();

  /// 波形布局带的 RenderBox key：把全局指针 x 换算成本地槽位坐标系喂
  /// `dockWaveLayout`（槽位 start/center 都在带的局部系内，padding=0 起）。
  /// ambient 与 fallback 两条指针路径共用同一换算（KOS 各 DockIcon
  /// `magnificationRoot: container` 同系，DockContainer.qml:537-538）。
  final _waveBandKey = GlobalKey();

  /// 波形振幅包络（quickshell `magnificationProgress`，DockSurface.qml:
  /// 91-110）：**唯一允许的缓动**——指针在容器 → 目标 1、离开 → 0，
  /// 220ms easeOutCubic。指针 x 与各槽 scale/位置每帧直算不 spring
  /// （硬性约束①②）。`MediaQuery.disableAnimations` 下直写终值不留
  /// ticker（约束③；flutter_test 恒 true）。
  late final AnimationController _amplitude = AnimationController(
    vsync: this,
    duration: kDockWaveAmplitudeDuration,
  );

  /// 指针离开容器的 ~80ms 防抖（quickshell `magnificationExit` Timer，
  /// DockSurface.qml:637-644）：吸收 region 抖动，防抖期内指针回来 →
  /// 不把包络打到 0。
  Timer? _exitDebounce;

  /// 「放大路径激活中」布尔广播给槽内图标（`WaveEnvelope` scope，对齐
  /// quickshell `directMagnification = requested || progress > 0`，
  /// DockSurface.qml:104）：指针在容器 / 拖拽中 / `amplitude>0` 塌回期
  /// 均为 true——图标的 `hasPointer`（`hoverScale` 分支）在包络未归零
  /// 前不能瞬时回落到「无指针独立 hover 兜底」，否则退出塌回期间美术盒
  /// scale 叠 ~1.2× Transform.scale（TASK-12 复审缺陷4）。
  ///
  /// 驱动：`_setEnvelopeActive` 只在 `_amplitudeTo`（postFrame 回调内）
  /// 与 `_amplitude` 监听器（tick，均在 build 外）里调用，值不变不写——
  /// **不在 build 中途写 notifier**（InheritedNotifier 依赖者会被脏标
  /// 记，同 `_reportLayoutWidth` 必须 postFrame 的原因）。
  final _waveActive = ValueNotifier<bool>(false);

  /// 振幅包络的目标值（build 侧只读决策字段；`_amplitudeTo` 唯一写）。
  double _amplitudeTarget = 0;

  /// 更新 `_waveActive`：目标为 1（指针在容器/拖拽中）或 `amplitude>0`
  /// （塌回中）→ 激活；`amplitude` 触底（塌回/入场结束）时由
  /// `_onAmplitudeChange` 惰性归零（无 build 内写）。值不变不写。
  void _setEnvelopeActive() {
    _waveActive.value = _amplitudeTarget > 0 || _amplitude.value > 0;
  }

  /// `_amplitude` 监听器：tick 后同步包络布尔（在 build 外，安全写
  /// notifier）；`amplitude` 真正触底（`==0`）时把 `_waveActive` 归 false。
  void _onAmplitudeChange() => _setEnvelopeActive();

  /// 拖拽预览态：null = 非拖拽。`setState` 变化即改槽位序（
  /// `dockWavePreviewOrder`），不重播入场——槽位 key 绑**条目**不绑槽位
  /// 下标（`_DockEntrance` 的 index 是首次挂载序号，预览换位不触发重播）。
  _DragPreview? _dragPreview;

  /// 拖拽浮层的当前指针位置（局部坐标系）：被拖图标的视觉副本跟随指针
  /// （quickshell `DockDragVisual`/`dragGhost.follow`，DockSurface.qml:
  /// 522-530）；非拖拽时为 null。
  Offset? _dragPointer;

  /// 拖拽浮层 Overlay 入口：预览副本跟随指针（IgnorePointer 不吃 hit）。
  final _dragProxy = OverlayPortalController();

  /// 拖拽起点（按下未过阈值时非 null）：`pointer` 是事件 pointer id，
  /// `x`/`y` 是按下点的带内局部坐标，`source` 是命中 pinned 槽位的
  /// **pinned 段相对**移除前下标。进入 reorder 态（`_dragPreview` 非
  /// null）后仍保留用于 pointer 匹配，PointerUp/Cancel 清空。
  _DragStart? _dragStart;

  final _order = DockOrder();

  /// KOS dock/DockModelService.qml:32-39,65-72 `activeDockPopup`/
  /// `activeContextMenu` 单例：任一时刻只有一个 popup（pinned 预览/菜单、
  /// trash 菜单、清空确认弹窗都计入），任一 pinned 菜单开着时全体图标
  /// previewDelay 抑制。shell 注入全 pill 共享的一份；无注入时自建。
  late final DockPopupCoordinator _popups =
      widget.coordinator ?? DockPopupCoordinator();
  List<String> _pinnedKeys = [];
  bool _saving = false;

  /// pinned 段键数（=[_pinnedKeys].length；只有 pinned 段可拖拽重排、
  /// 可持久化）。运行段/leading 不进入 reorder（KOS
  /// DockIcon.qml:916-927：window item 无重排语义；launcher/trash 固定）。
  int get _pinnedCount => _pinnedKeys.length;

  /// TASK-11 波形几何缓存：`weights`/`unscaled`/`iconSize`/`itemSpacing`/
  /// `_dividerIndex` 在 build 中写入（条目数/ metrics 每帧可能变化），
  /// `_baseSlots()` 供给 `_updateDrag` 的未缩放 hit-test 路径。
  List<double> _weights = const [];
  Set<int> _unscaled = const <int>{};
  double _iconSize = 0;
  double _itemSpacing = 0;
  int _dividerIndex = -1;

  /// 未缩放静止布局（`amplitude=0`、无指针）：hit-test/拖拽重排的几何
  /// 基准——quickshell `insertionAt` 用 `baseLayout.slots`
  /// （`DockSurface.qml:414-415`，动画中的邻居不回移自己的阈值）。
  List<DockWaveSlot> _baseSlots() => dockWaveLayout(
        weights: _weights,
        size: _iconSize,
        gap: _itemSpacing,
        padding: 0,
        pointerX: null,
        maxScale: kDockWaveMaxScale,
        amplitude: 0,
        unscaled: _unscaled,
      );

  /// pin.key 统一为 `app:` + normalize(pin.id)；运行段键 `run:` + normalize
  /// （appId）——定义移入 state/dock_row_entries.dart（`dockPinEntryKey` /
  /// `dockRunningEntryKey`），本行只引用。
  static String _keyFor(String launchId) => dockPinEntryKey(launchId);

  void _reorder(int from, int to) {
    if (_saving) return;
    // 只有 pinned 段可重排：未 pin 运行条目与 leading 不在重排域（KOS
    // DockIcon.qml:916-927 的 window item 没有重排语义；`to` 是移除后
    // 目标位，界内 [0,pinnedCount-1]，钳制仍保留作防御）。

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

  /// quickshell `DockSurface.qml:513-528 updateDrag`：拖动中每次指针移动
  /// 更新 `_dragPointer`（浮层跟随）与 `_insertionGap`（中线判定，含迟滞）。
  ///
  /// [localX]/[localY] 是带内局部坐标（`dockWaveLayout` 槽位系）；
  /// 中线判定用**未缩放**坐标（`amplitude=0` 的 base 布局，
  /// `DockSurface.qml:414-415`：hit test 留在不变模型的坐标系内，
  /// 动画中的邻居不回移自己的阈值）。
  void _updateDrag({required double localX, required double localY}) {
    final preview = _dragPreview;
    if (preview == null) return;
    // 未缩放槽位（amplitude=0、无指针）：中线序列在移除前的原始序上取
    // ——`previewOrder` 只改「谁画在哪个槽」，槽位几何本身由原始权重序
    // 决定（quickshell `insertionAt` 用 `baseLayout.slots`，:422-423）。
    final slots = _baseSlots();
    final leadingCount = widget.leading.length;
    // raw（整带槽位坐标系）→ pinned 段相对插入位：pinned 槽位区间是
    // [leadingCount, leadingCount+pinnedCount)，故减 leadingCount 后钳到
    // [0, pinnedCount]（quickshell `insertionAt` 同式钳到 pinnedAppCount，
    // DockSurface.qml:422-423）。
    final raw = dockWaveInsertionIndex(slots, localX);
    var candidate = (raw - leadingCount).clamp(0, _pinnedCount);
    // 6px 跨中线迟滞（quickshell `insertionAt` :425-432）：candidate 与
    // 当前 gap 只差 1 且没跨过被越槽中心 6px → 保持原 gap（消抖动）。
    final current = preview.gap;
    if ((candidate - current).abs() == 1) {
      // crossedIndex 是 pinned 相对下标；映射回整带槽位取中线。
      final crossedIndex = candidate < current ? candidate : current;
      final bandIndex = leadingCount + crossedIndex;
      if (bandIndex < slots.length) {
        final crossed = slots[bandIndex];
        if ((localX - crossed.center).abs() < 6) {
          candidate = current;
        }
      }
    }
    if (candidate != current || _dragPointer == null) {
      setState(() {
        _dragPointer = Offset(localX, localY);
        _dragPreview = (source: preview.source, gap: candidate);
      });
    } else {
      setState(() => _dragPointer = Offset(localX, localY));
    }
  }

  /// 拖拽落位（PointerUp/Cancel → `finishDrag`，quickshell :526-540）：
  /// gap（移除前下标）→ 移除后目标下标 `to`，经 `_reorder` 持久化；
  /// 拖出 pill（|dy| > dockHeight）只取消不 unpin（KOS unpin 走右键菜单）。
  void _finishDrag({required bool dropOutside}) {
    final preview = _dragPreview;
    _dragPointer = null;
    if (preview != null) {
      setState(() => _dragPreview = null);
      if (!dropOutside) {
        // preview.source/gap 已是 pinned 相对下标，`dockWaveDropTarget`
        // 返回的 `to` 即 `_reorder`/`DockOrder` 的移除后目标下标。
        final to = dockWaveDropTarget(preview.source, preview.gap);
        if (to != preview.source) _reorder(preview.source, to);
      }
    }
  }

  /// 振幅包络目标切换（指针进/出容器）：只在「容器有 ambient 广播」或
  /// 自建 fallback 时驱动；`disableAnimations` 直写终值不留 ticker
  /// （约束③——flutter_test 恒 true，_exitDebounce 也只在动画开启时跑）。
  void _amplitudeTo(double target) {
    _amplitudeTarget = target;
    _setEnvelopeActive();
    if (MediaQuery.disableAnimationsOf(context)) {
      _exitDebounce?.cancel();
      _exitDebounce = null;
      _amplitude.value = target;
      // 缺陷1 配套：直写终值 0 时包络已到底，`_lastLocalX` 同步丢弃
      // （不留给下一次 build 的惰性清空——值 0 后该缓存无意义）。
      if (target <= 0) _lastLocalX = null;
      return;
    }
    if (target <= 0) {
      // 80ms 退出防抖（quickshell `magnificationExit`）：防抖期内不立即
      // 把包络打到 0，吸收 region 抖动。
      _exitDebounce?.cancel();
      _exitDebounce = Timer(kDockWaveExitDebounce, () {
        if (!mounted) return;
        // minor①：fire 时若拖拽仍活跃或当前目标已变回 1（防抖期内
        // pointer 回归/进拖拽 → `_amplitudeTo(1)` 已重定目标），跳过
        // animateTo(0)——否则 PointerUp 落在防抖窗内会闪一帧 1×。
        if (_dragPreview != null || _amplitudeTarget > 0) return;
        unawaited(
          _amplitude.animateTo(0, curve: Curves.easeOutCubic),
        );
      });
    } else {
      _exitDebounce?.cancel();
      _exitDebounce = null;
      unawaited(_amplitude.animateTo(1, curve: Curves.easeOutCubic));
    }
  }

  @override
  @override
  void dispose() {
    _exitDebounce?.cancel();
    _amplitude.dispose();
    _waveActive.dispose();
    _pointerX.dispose();
    super.dispose();
  }

  /// 广播指针 x 到与槽中心同系的全局坐标系：MouseRegion 事件给的是局部
  /// 坐标，经自身 RenderBox.localToGlobal 映射（fallback 路径；
  /// ambient 路径由 KosDockShell 的 `_broadcastPointer` 同式喂
  /// `_pointerX`——本行只消费 `MagnificationPointer.of`，不区分来源）。
  void _broadcastPointer(PointerHoverEvent event) {
    final box = _pointerRegionKey.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.attached) return;
    _pointerX.value = box.localToGlobal(event.localPosition).dx;
  }

  /// 最后已知的带内局部指针 x：指针离开容器后保留，让退出动画仍有一个
  /// 有效的 `pointerX` 喂 `dockWaveLayout`——scale 从放大值平滑塌回 1
  /// （TASK-12 复审缺陷1：onExit 把 `_pointerX` 瞬时置 null → `hasPointer
  /// =false` → scale 短路 1，220ms 振幅包络跑在一个无消费者的值上）。
  /// 包络触底（`_amplitude==0`）后在 build 内惰性清空。
  double? _lastLocalX;

  /// 指针 x（全局）→ 带内局部 x：`dockWaveLayout` 的槽坐标系以带的左缘
  /// 为原点（padding=0 起累加），全局 x 减去带左缘的全局 x。
  ///
  /// TASK-12 复审缺陷3(c)：换算只锚带盒**左缘**（`Offset(0, height)`），不
  /// 用 `Offset.zero` 的左上原点——带盒宽 = 当帧 Σspan 随指针/振幅每帧变，
  /// 而外壳 `Align.centerLeft` 让左缘钉在 pill 内容左缘（静止系不变量）；
  /// `Offset.zero` 的 y 分量能触发 RenderAligningShiftedBox 的 y 对齐偏移，
  /// 在带盒换宽的当帧把原点带偏（动画几何回喂 magnification，DockLayout.
  /// js:16-17 明令禁止）。
  ///
  /// 非 null 的局部 x 顺手记入 [_lastLocalX]（quickshell
  /// `magnificationProgress` 单包络语义，DockSurface.qml:95-103）：指针
  /// 离开时 `pointerGlobalX` 瞬时变 null，scale 塌回只经 `amplitude` 包络
  /// 220ms 衰减，局部 x 保持最后已知值直到包络触底（build 内
  /// `_amplitude.value == 0` 时惰性清空）。
  double? _localPointerX(double? globalX) {
    if (globalX == null) return null;
    final box = _waveBandKey.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.attached) return null;
    return _lastLocalX =
        globalX - box.localToGlobal(Offset(0, box.size.height)).dx;
  }

  /// 槽位 displayIndex → 移除前 sourceIndex 的置换表。拖拽预览只置换
  /// pinned 段（`dockWavePreviewOrder` 作用在 pinned 子序列上，
  /// `_dragPreview.source/gap` 均为 **pinned 相对**下标）；leading /
  /// divider / running 槽位原位不动（KOS：window item 无重排语义、
  /// launcher/trash 固定槽位）。
  List<int> _displayOrder(int totalCount) {
    final order = List<int>.generate(totalCount, (i) => i);
    final preview = _dragPreview;
    if (preview == null) return order;
    final leading = widget.leading.length;
    final perm = dockWavePreviewOrder(
      _pinnedKeys.length,
      preview.source,
      preview.gap,
    );
    for (var i = 0; i < perm.length; i++) {
      order[leading + i] = leading + perm[i];
    }
    return order;
  }

  @override
  @override
  void initState() {
    super.initState();
    // fallback 路径（无 ambient MagnificationPointer 的独立宿主/单测）：
    // 自建 `_pointerX` 的变化要触发重建以驱动波形与包络。有 ambient 时
    //  InheritedNotifier 依赖已在 build 建立，本监听恒为 no-op。
    _pointerX.addListener(_onFallbackPointer);
    // 包络布尔广播（`WaveEnvelope`）的触底归零通道：塌回/入场每 tick
    // 后同步 `_waveActive`（`amplitude` 真触底才归 false；build 外写
    // notifier 安全）。
    _amplitude.addListener(_onAmplitudeChange);
  }

  void _onFallbackPointer() {
    if (mounted) setState(() {});
  }

  /// TASK-12 当帧 Σspan 上报（postFrame 写入，避免在 build 中途通知 shell
  /// 的 AnimatedBuilder；值不变不写，避免空转通知与 layout 反馈环——见
  /// `DockIconRow.layoutWidth` 参数注释）。
  ///
  /// 守卫（TASK-12 复审缺陷1）：postFrame 回调在 widget unmount 后仍会到
  /// 达 → `mounted` 检查；notifier 是外部传入的可选注入（`KosDockShell`
  /// 持有并 dispose），shell 先行 dispose 的场景下写入会抛 → try/catch
  /// 兜底丢弃。
  void _reportLayoutWidth(double width) {
    final layoutWidth = widget.layoutWidth;
    if (layoutWidth == null || layoutWidth.value == width) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      try {
        layoutWidth.value = width;
      } on Object {
        // notifier 已被外部所有者 dispose：丢弃本次上报。
      }
    });
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
    // 方案 A 单一事实来源；dock_shell.dart 用同一函数推导行自然宽）。
    final entries = dockRowEntries(
      prefs: prefs,
      catalog: catalog,
      windows: windows,
    );
    final entryByKey = {for (final entry in entries) entry.key: entry};
    _pinnedKeys = _order.update(
      [for (final entry in entries) if (entry.isPinned) entry.key],
    );
    final runningEntries = [
      for (final entry in entries)
        if (!entry.isPinned) entry,
    ];
    // 方案 C：槽位宽/间距/divider 槽位全部由 DockMetrics 反解（读取 scope，
    // 独立宿主退回 DockMetricsScope.fallback 的基准几何）。
    final metrics = DockMetricsScope.of(context);
    final slotSize = metrics.iconSlotSize;
    final itemSpacing = metrics.itemSpacing;
    final iconSize = metrics.iconSize;
    final dividerSlotWidth = metrics.dividerSlotWidth;
    final showDivider =
        _pinnedKeys.isNotEmpty && runningEntries.isNotEmpty;

    // ── TASK-11 波形槽位序列（weights + 槽内 widget 工厂）────────────────
    // 槽位序 = [leading 内建件（launcher/trash，权重 1）] +
    //          [pinned × n（权重 1）] +
    //          [divider1?（unscaled，权重 = dividerSlotWidth/iconSize）] +
    //          [running × m（权重 1）]。
    // weight = iconSlotSize/iconSize：KOS 槽宽含 activeBackgroundGap×2
    // （DockIcon.qml:116 `iconSize + gap*2`，方案 C 起 iconSlotSize 即该
    // 值）；美术盒视觉边长 = iconSize·scale——`iconScale` 是纯高斯 scale
    // （`slot.size / iconSlotSize`，TASK-12 修正：不把 weight 折进美术盒）。
    // weights/unscaled/iconSize/itemSpacing 提升为状态字段：`_baseSlots()`
    // 供给 `_updateDrag` 的未缩放 hit-test 路径（振幅 0、无指针 → 静止几何，
    // quickshell `insertionAt` 用 `baseLayout.slots`，DockSurface.qml:
    // 414-415）。每帧重建 weights（列表元数据每帧随条目数变化，开销忽略）。
    final leadingCount = widget.leading.length;
    final entryCount = _pinnedKeys.length + runningEntries.length;
    final totalCount = leadingCount + entryCount + (showDivider ? 1 : 0);
    _weights = List<double>.filled(totalCount, slotSize / iconSize);
    _unscaled = <int>{};
    _dividerIndex =
        showDivider ? leadingCount + _pinnedKeys.length : -1;
    if (showDivider) {
      _weights[_dividerIndex] = dividerSlotWidth / iconSize;
      _unscaled.add(_dividerIndex); // divider 不随波形缩放（约束⑥）。
    }
    _iconSize = iconSize;
    _itemSpacing = itemSpacing;
    final order = _displayOrder(totalCount);

    /// 本帧 `dockWaveLayout` 调用参数（指针/振幅在每帧回调内现取；
    /// hit-test 路径（`_updateDrag`/PointerDown）用 amplitude=0 的未缩放
    /// 布局——quickshell `insertionAt` 用 `baseLayout.slots`，
    /// DockSurface.qml:414-415）。
    List<DockWaveSlot> layoutSlots({double? pointerX, double amplitude = 0}) =>
        dockWaveLayout(
          weights: _weights,
          size: iconSize,
          gap: itemSpacing,
          padding: 0,
          pointerX: pointerX,
          maxScale: kDockWaveMaxScale,
          amplitude: amplitude,
          unscaled: _unscaled,
        );

    // 振幅包络：有 ambient `MagnificationPointer`（KosDockShell）时行内不
    // 自建 MouseRegion——指针 x 来自上层广播，本行只把它的「有/无」映射到
    // 包络目标；无 ambient（独立宿主/单测）时自建 fallback MouseRegion +
    // 包络（`MagnificationPointer.maybeOf` 判定）。
    final ambient = MagnificationPointer.maybeOf(context) != null;
    // fallback 路径下 `MagnificationPointer.of(context)` 查的是本 widget 的
    // 祖先——自建的那份在 build 返回树内（后代），此处取不到；故 fallback
    // 直接读 `_pointerX.value`（`_onFallbackPointer` 监听已建立依赖）。
    final pointerGlobalX =
        ambient ? MagnificationPointer.of(context) : _pointerX.value;
    // TASK-12 复审缺陷1：指针瞬时 null 时保留 `_lastLocalX` 直到包络触底——
    // scale 塌回由 `amplitude` 唯一驱动（220ms easeOutCubic），`localX` 不
    // 参与衰减只定位高斯峰。`_localPointerX` 在值非 null 时顺手刷新缓存。
    final localX =
        _localPointerX(pointerGlobalX) ??
        (_amplitude.value > 0 ? _lastLocalX : null);

    // 指针在容器 → amplitude 1；离开 → 0（80ms 防抖内不重置，`_amplitudeTo`
    // 内部处理）。拖拽中保持包络（quickshell `magnificationRequested` 含
    // dragInside）。帧后驱动：build 内不 animateTo（依赖 InheritedNotifier
    // 的重建会脏标记自身）；disableAnimations 下 `_amplitudeTo` 直写终值。
    final targetAmplitude =
        pointerGlobalX != null || _dragPreview != null ? 1.0 : 0.0;
    // TASK-12 复审缺陷1：空行（totalCount==0）分支连 AnimatedBuilder 一起
    // 卸载时，`_iconRowLayoutWidth` 会停在最后一个非零 Σspan → 主动把
    // 上报值清零（`_reportLayoutWidth` 内部 postFrame + mounted/notifier
    // 守卫）。不能放进 AnimatedBuilder：那只在「builder 被构建」时执行，
    // 树被 `SizedBox.shrink()` 换掉的当帧 builder 根本跑不到。
    if (totalCount == 0) _reportLayoutWidth(0);

    // 判等用「目标」而非「当前值」：`_amplitude.value` 在动画进行中每帧都
    // ≠ target（这是预期），用它会每帧排 postFrame 反复重启 `animateTo`
    // ——`AnimationController.animateTo` 断言禁止未 finish 重启 → panic +
    // 动画被打断成抽搐。只在「意图翻转」时才驱动一次。
    if (_amplitudeTarget != targetAmplitude) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _amplitudeTarget != targetAmplitude) {
          _amplitudeTo(targetAmplitude);
        }
      });
    }

    // 槽位 → widget：`order[displayIndex]` 是该槽当前渲染条目的移除前下标
    // （预览置换只发生在 pinned 槽位区间内，leading/divider/running 的相对
    // 顺序不变，见 `_displayOrder`）。`slot` 是本帧 `dockWaveLayout` 结果。
    Widget slotChild(int displayIndex, DockWaveSlot slot) {
      final sourceIndex = order[displayIndex];
      final slotWidth = slot.size; // 槽内图标槽宽（=size·weight·scale）
      // TASK-12 修正：iconScale 是纯高斯 scale（除以 iconSlotSize =
      // iconSize·weight），美术盒 = iconSize·scale（静止 = iconSize ≈42，
      // 峰值 = iconSize·1.5）。旧式 `slot.size / iconSize` 把 weight≈1.2
      // 折进美术盒 → 静止 50.4px/峰值 75.6px，比设计大 20%（用户实测缺陷）。
      final iconScale = slotWidth / slotSize;
      if (sourceIndex < leadingCount) {
        // leading 内建件（launcher/trash）：包装一层把波形槽位几何下发到
        // 内部 DockControlIcon（`slotSize`/`iconScale` 参数在 TASK-11
        // 加在 LauncherIcon/TrashIcon 与 DockControlIcon 上）。内建件
        // 不参与重排（KOS 固定槽位）。
        return _WaveSlotAdapter(
          slotSize: slotWidth,
          iconScale: iconScale,
          child: widget.leading[sourceIndex],
        );
      }
      if (sourceIndex == _dividerIndex) {
        return const DockDivider();
      }
      // pinned 段移除前下标 ∈ [leadingCount, leadingCount+pinnedCount)；
      // running 段在 divider 之后。entryIndex 是 pinned/running 合并序下标；
      // divider 槽只在 sourceIndex 越过它时才减 1（pinned 段在 divider 前，
      // 不该减）。
      final entryIndex = sourceIndex -
          leadingCount -
          (showDivider && sourceIndex > _dividerIndex ? 1 : 0);
      if (entryIndex >= 0 && entryIndex < _pinnedKeys.length) {
        final key = _pinnedKeys[entryIndex];
        final entry = entryByKey[key];
        if (entry == null) {
          return SizedBox.shrink(key: ValueKey('missing:$key'));
        }
        final draggingThis =
            _dragPreview != null && _dragPreview!.source == entryIndex;
        // 拖拽源槽位渲染成半透明占位（quickshell 被拖项的残影等价——
        // DockItem.qml drag 中源槽位保留但视觉移到 dragGhost）；pointer 事件
        // 仍由外层行级 Listener 统一收。
        return Opacity(
          opacity: draggingThis ? 0.35 : 1.0,
          child: _DockEntrance(
            index: displayIndex,
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
              dragging: _dragPreview != null,
              onTogglePin: () => _unpin(key),
              coordinator: _popups,
              slotSize: slotWidth,
              iconScale: iconScale,
            ),
          ),
        );
      }
      final running =
          runningEntries[(entryIndex - _pinnedKeys.length).clamp(
        0,
        runningEntries.length - 1,
      )];
      return _DockEntrance(
        index: displayIndex,
        child: DockIcon(
          appId: running.appId,
          name: running.name,
          launchId: running.launchId,
          monitorId: widget.monitorId,
          windows: running.windows,
          isActivated: running.windows.any((w) => w.active),
          monitorBounds: monitorBounds,
          dragging: _dragPreview != null,
          isPinnedEntry: false,
          onTogglePin: () => _pinApp(
            running.appId,
            running.name,
            running.launchId,
          ),
          coordinator: _popups,
          slotSize: slotWidth,
          iconScale: iconScale,
        ),
      );
    }

    // 手写重排的行级手势层（对齐 quickshell `DockItem.qml` MouseArea +
    // `DockSurface.qml updateDrag/finishDrag`）：覆盖整个槽位带。
    // - PointerDown 落在 pinned 槽位 → 记 `_dragStart`（`!_saving` 等价原
    //   `ReorderableDragStartListener.enabled`）；
    // - 水平位移超 `kDockReorderDragThreshold` 进 reorder 态；
    // - 拖动中 `_updateDrag` 更新插入位预览（hit test 在**未缩放**坐标
    //   系，`DockSurface.qml:412-415`：动画中的邻居不回移自己的阈值）；
    // - PointerUp/Cancel → `_finishDrag`（落位/取消 + 持久化）。
    // 用 Listener 而不是 GestureDetector：要拿原始 PointerEvent 流且不与
    // tap/secondaryTap/长按竞技场竞争（ReorderableListView 用长按触发拖
    // 拽，本端用「位移阈值」更轻，单击不受影响）。
    //
    // event.localPosition 即带内局部坐标：Listener 与 `_waveBandKey` 所标
    // SizedBox 同盒（Stack 之外无额外内边距），无需再换算。
    Widget gestureLayer(Widget child) => Listener(
          onPointerDown: (event) {
            if (_saving || _dragStart != null) return;
            final local = event.localPosition;
            final baseSlots = layoutSlots();
            final hitDisplay = dockWaveInsertionIndex(baseSlots, local.dx)
                .clamp(0, totalCount - 1)
                .toInt();
            final source = order[hitDisplay];
            if (source == _dividerIndex) return;
            // pinned 段相对移除前下标；divider 已排除，不用减 divider。
            final entryIndex = source - leadingCount;
            if (source < leadingCount ||
                entryIndex < 0 ||
                entryIndex >= _pinnedKeys.length) {
              return; // leading/divider/running 槽位不可拖。
            }
            _dragStart = (
              pointer: event.pointer,
              x: local.dx,
              y: local.dy,
              source: entryIndex,
            );
          },
          onPointerMove: (event) {
            final start = _dragStart;
            if (start == null || event.pointer != start.pointer) return;
            final local = event.localPosition;
            if (_dragPreview == null) {
              if ((local.dx - start.x).abs() < kDockReorderDragThreshold &&
                  (local.dy - start.y).abs() < kDockReorderDragThreshold) {
                return; // 未过阈值，仍是普通 hover/点击。
              }
              // 进 reorder 态：初始 gap = 源槽的移除前下标（预览序不变），
              // 浮层出现。`source` 记的是移除前下标；gap 域同为移除前。
              setState(() {
                _dragPreview = (source: start.source, gap: start.source);
                _dragPointer = local;
              });
              _dragProxy.show();
            }
            _updateDrag(localX: local.dx, localY: local.dy);
          },
          onPointerUp: (event) {
            final start = _dragStart;
            if (start == null || event.pointer != start.pointer) return;
            _dragStart = null;
            // 拖出 pill（|dy| > dockHeight，对照 quickshell
            // `insideDropBand` 的 removalDistance ≤ bandThickness+24 语义
            // 收窄为「离行」）只取消预览，不落位不 unpin。
            final local = event.localPosition;
            final outside =
                local.dy.abs() > metrics.dockHeight;
            _finishDrag(dropOutside: outside);
          },
          onPointerCancel: (event) {
            final start = _dragStart;
            if (start == null || event.pointer != start.pointer) return;
            _dragStart = null;
            _finishDrag(dropOutside: true);
          },
          child: child,
        );

    final content = AnimatedBuilder(
      animation: _amplitude,
      builder: (context, child) {
        // 缺陷1：包络真正触底（amplitude==0）后惰性丢弃缓存的局部指针 x——
        // 触底前的退出动画帧仍需要它定位高斯峰；触底后全槽 scale=1 已回
        // 静止布局，缓存无意义（避免长期持有过期指针位影响后续进场帧）。
        final framePointerX =
            _dragPreview != null && _dragPointer != null
                ? _dragPointer!.dx
                : localX;
        if (_amplitude.value == 0 && pointerGlobalX == null) {
          _lastLocalX = null;
        }
        final frameSlots = layoutSlots(
          pointerX: framePointerX,
          amplitude: _amplitude.value,
        );
        final width = frameSlots.isEmpty
            ? 0.0
            : frameSlots.last.start + frameSlots.last.span;
        // TASK-12 缺陷3：把当帧 Σspan 报给 shell（pill 宽/占位/带层宽随
        // 放大外扩，quickshell `bandLength` 语义）。postFrame 写入：不能在
        // build 中途通知 shell 的 AnimatedBuilder（会把祖先在同帧 build
        // 阶段脏标记）；值不变不写避免空转通知与 layout 反馈环。空行路径
        // 的清零在 build 主流程（`totalCount==0` 分支，见上）——此处只到
        // 非空行。
        _reportLayoutWidth(width);
        return SizedBox(
          key: _waveBandKey,
          width: width,
          height: metrics.dockHeight,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              for (var i = 0; i < totalCount; i++)
                // TASK-12（quickshell DockItem.qml:112 `artwork.y =
                // root.height − height − 12 − bounce`）：槽位列底锚带底——
                // 美术盒贴 pill 底、放大向上「长」出 pill 顶缘（抬起 =
                // 纯几何 dy/dsize=−1，无独立垂直缓动；唯一缓动仍是行级
                // 振幅包络，约束②）。`OverflowBox(maxHeight: infinity)`
                // 给槽位盒一个「向上可溢出带盒」的通路：`Positioned` 行
                // 高 = dockHeight，放大后的槽位盒（高 > dockHeight）经
                // bottomCenter 对齐向上探出带顶缘；外层 Stack/OverflowBox
                // 链已不裁（dock_shell.dart TASK-12）。divider 槽不随波形
                // 缩放（unscaled），但槽位列高仍取槽位 size（=divider 槽宽，
                // 不是 dockHeight）——DockDivider 内部 Center 自带
                // dockHeight 线高，直接给 slotSize² 盒会把它压扁。
                Positioned(
                  left: frameSlots[i].start,
                  width: frameSlots[i].span,
                  top: 0,
                  bottom: 0,
                  child: OverflowBox(
                    minHeight: 0,
                    maxHeight: double.infinity,
                    alignment: Alignment.bottomCenter,
                    // key 绑条目（非槽位下标）：预览换位时 Flutter 按 key
                    // 匹配 element → _DockEntrance/DockIcon 状态跟随条目
                    // 移动，不重播入场、不丢 hover/菜单态。
                    child: SizedBox(
                      key: ValueKey(_slotKeyFor(order[i])),
                      width: frameSlots[i].size,
                      height: order[i] == _dividerIndex
                          ? metrics.dockHeight
                          : frameSlots[i].size,
                      child: slotChild(i, frameSlots[i]),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );

    final body = ShellServicesScope(
      services: services,
      child: ShellInputRegion(
        debugLabel: 'Dock application reorder capture',
        active: _dragPreview != null,
        pointerPolicy: ShellPointerPolicy.fullScene,
        child: ShellInputRegion(
          debugLabel: 'Dock application icons',
          // Desktop mouse drags belong to reordering（taskbar.dart:48-54
          // workaround：shell 全局启用 mouse drag scrolling；图标行自身
          // 方案 C 起不再可滚——scrollbars:false 白条兜底随之删除）。只剥离
          // mouse 拖拽设备。
          child: ScrollConfiguration(
            behavior: ScrollConfiguration.of(context).copyWith(
              dragDevices: ScrollConfiguration.of(context).dragDevices
                  .where((device) => device != PointerDeviceKind.mouse)
                  .toSet(),
            ),
            // 空行（无 leading、无 pinned、无运行条目）：空 SizedBox（pill
            // 本体仍由 dock_shell 画）。Σspan 清零上报在 build 主流程
            // （`totalCount==0` 处，见上）——AnimatedBuilder 整棵卸载后
            // `_iconRowLayoutWidth` 不能停在旧值。
            child: totalCount == 0
                ? const SizedBox.shrink()
                : Align(
                    // TASK-12：波形带底锚分配到的竖直空间底部——dock_shell
                    // 给图标区分了 dockHeight+headroom 高，带盒（dockHeight）
                    // 贴底，槽位列经 OverflowBox 向上溢出 pill 顶缘。
                    alignment: Alignment.bottomCenter,
                    // 拖中浮层：跟随指针的被拖图标副本（IgnorePointer 不吃
                    // hit；行级 Listener 收全局事件）。
                    child: OverlayPortal(
                      controller: _dragProxy,
                      overlayChildBuilder: (context) => _buildDragProxy(),
                      child: gestureLayer(content),
                    ),
                  ),
          ),
        ),
      ),
    );

    // TASK-04：指针广播上移到 KosDockShell（覆盖 launcher/trash/pinned
    // 整个 pill 内容 Row）。有 ambient 时直接消费，行内不再重复自建；
    // 无 ambient（独立宿主/单测）保留自建 fallback MouseRegion + 包络。
    if (ambient) {
      return WaveEnvelope(active: _waveActive, child: body);
    }
    return MouseRegion(
      key: _pointerRegionKey,
      onHover: _broadcastPointer,
      onExit: (_) {
        _pointerX.value = null;
        _amplitudeTo(0); // fallback 路径自带退出包络。
      },
      child: MagnificationPointer(
        pointerX: _pointerX,
        child: WaveEnvelope(active: _waveActive, child: body),
      ),
    );
  }

  /// 拖拽浮层：跟随 `_dragPointer` 的被拖图标视觉副本。
  ///
  /// quickshell `DockDragVisual`/`dragGhost.follow`（DockSurface.qml:
  /// 522-530）的等价——源条目拿到 `Opacity(0.35)` 占位、浮层画真实图标；
  /// 落位后浮层消失，条目回到目标槽位（key 绑条目保证状态跟随）。
  Widget _buildDragProxy() {
    final preview = _dragPreview;
    final pointer = _dragPointer;
    if (preview == null || pointer == null) {
      return const SizedBox.shrink();
    }
    final services = widget.services;
    final catalog = ref.read(services.applications);
    final prefs = ref.read(dockPreferencesProvider).value ??
        const DockPreferences();
    final windows = ref.read(services.windows(widget.monitorId));
    final monitorBounds =
        ref.read(services.monitorBounds(widget.monitorId));
    final entries = dockRowEntries(
      prefs: prefs,
      catalog: catalog,
      windows: windows,
    );
    final entryByKey = {for (final e in entries) e.key: e};
    if (preview.source < 0 || preview.source >= _pinnedKeys.length) {
      return const SizedBox.shrink();
    }
    final key = _pinnedKeys[preview.source];
    final entry = entryByKey[key];
    if (entry == null) return const SizedBox.shrink();
    final metrics = DockMetricsScope.of(context);
    final size = metrics.iconSlotSize;
    // `_dragPointer` 是带内局部坐标；浮层画在根 Overlay，需换算回全局
    // （Overlay Stack 的坐标系即全局系）。
    final bandBox = _waveBandKey.currentContext?.findRenderObject();
    final origin = bandBox is RenderBox && bandBox.attached
        ? bandBox.localToGlobal(Offset.zero)
        : Offset.zero;
    return IgnorePointer(
      child: Stack(
        children: [
          Positioned(
            left: origin.dx + pointer.dx - size / 2,
            top: origin.dy + pointer.dy - size / 2,
            width: size,
            height: size,
            child: ShellServicesScope(
              services: services,
              child: ShellTheme(
                data: context.shellTheme,
                child: ExcludeFocus(
                  child: DockIcon(
                    appId: entry.appId,
                    name: entry.name,
                    launchId: entry.launchId,
                    monitorId: widget.monitorId,
                    windows: entry.windows,
                    isActivated: entry.windows.any((w) => w.active),
                    monitorBounds: monitorBounds,
                    dragging: true,
                    onTogglePin: () async {},
                    coordinator: _popups,
                    slotSize: size,
                    // 与槽内同一语义：iconScale = slot.size / iconSlotSize
                    // （静止槽 → 1.0，美术盒 = iconSize；TASK-12 修正后不再
                    // 把 weight 折进美术盒）。
                    iconScale: size / metrics.iconSlotSize,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 预览序下槽位 `sourceIndex`（移除前下标）对应的稳定 key：key 绑条目
  /// 保证拖拽预览换位时 `_DockEntrance`/`DockIcon`/`DockPreviewAnchor`
  /// 状态跟随条目移动（previewOrder 只改「谁画在哪个槽」，元素按 key
  /// 匹配不重建）。
  String _slotKeyFor(int sourceIndex) {
    final leadingCount = widget.leading.length;
    if (sourceIndex < leadingCount) return 'leading:$sourceIndex';
    return 'slot:$sourceIndex';
  }
}

/// 波形槽位的 wrapper：把「槽内图标槽宽/scale」下发给 [child]。
///
/// TASK-11：应用图标槽位的「尺寸」由 `DockIcon.slotSize`/`iconScale`
/// 参数直接表达（槽宽 = `size·weight·scale`）；launcher/trash 等内建件
/// 的 `DockControlIcon` 同名参数经外层包装 `LauncherIcon`/`TrashIcon`
/// 传入——本类只在两者之间做参数适配（leading 项的构造在 `dock_shell`
/// 不知道槽位几何，故参数经 wrapper 下发而非构造点传）。
class _WaveSlotAdapter extends StatelessWidget {
  const _WaveSlotAdapter({
    required this.slotSize,
    required this.iconScale,
    required this.child,
  });

  final double slotSize;
  final double iconScale;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    // LauncherIcon/TrashIcon 在 TASK-11 加了 slotSize/iconScale 参数；
    // 这里把它们「按类型」注入——leading 列表的 widget 类型在 shell 侧
    // 固定（LauncherIcon / TrashIcon），故走 if 级联而非反射。类型不
    // 匹配时退回原样（独立宿主传任意 widget 也不崩）。
    if (child is LauncherIcon) {
      final icon = child as LauncherIcon;
      return LauncherIcon(
        key: icon.key,
        services: icon.services,
        coordinator: icon.coordinator,
        slotSize: slotSize,
        iconScale: iconScale,
      );
    }
    if (child is TrashIcon) {
      final icon = child as TrashIcon;
      return TrashIcon(
        key: icon.key,
        services: icon.services,
        monitorId: icon.monitorId,
        coordinator: icon.coordinator,
        slotSize: slotSize,
        iconScale: iconScale,
      );
    }
    return child;
  }
}

/// 拖拽落位目标换算：移除前 gap 下标 → 移除后 `to`（`_reorder`/`DockOrder`
/// 语义）。
///
/// `dockWavePreviewOrder` 返回的是「槽位 i → 原条目 sourceIndex」的置换；
/// `_reorder(from, to)` 的 `to` 是**移除后**序列目标位（`DockOrder.
/// reorder` 先 removeAt 再 insert）——故 `gap > source` 时目标位要 −1
/// （预览里 `gap` 之后的内容前移一格）。
int dockWaveDropTarget(int sourceIndex, int gapIndex) =>
    gapIndex > sourceIndex ? gapIndex - 1 : gapIndex;

/// 拖拽起点状态（按下未过阈值时创建）：`pointer` 是事件 pointer id，
/// `x`/`y` 是按下点带内局部坐标，`source` 是命中 pinned 槽位的
/// **pinned 段相对**移除前下标。
typedef _DragStart = ({int pointer, double x, double y, int source});

/// 每图标入场交错：Timer 60ms×index + `springTo(Motion.snappy)` +
/// `Align(widthFactor:unit(t))` 槽宽展开 + Opacity（denial_top_bar
/// `desktop_system_bar_components.dart:322-390` `_SystemBarEntrance` 范式；
/// dock 水平行用 `alignment: centerLeft` + widthFactor）。
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
