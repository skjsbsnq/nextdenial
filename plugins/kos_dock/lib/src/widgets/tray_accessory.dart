/// TASK-06 托盘区（trailing accessory）：KOS `BarStatusArea{dockHosted:true}`
/// 的 Dock 尾端融合托盘——宿主 `buildSystemTray` 渲染 StatusNotifierItem +
/// 尾部状态格（[DockBatteryCell]，v1 唯一有 SDK 等价物的格）。
///
/// 移植要点（源根 `/home/wwt/文档/NextKde/shell/desktop/modules/`）：
/// - 维稳排序：denial_taskbar `tray.dart:56-77` 的 `_orderedIds` 范式——
///   删掉已消失的 id、新 id 追加尾部，宿主列表重排不搬动既有顺序。v1 只
///   维稳、不持久化排序（KOS `SysTrayOrderService` 的 Alt+拖拽重排与持久序
///   砍掉，记 docs/visual-deltas.md）。
/// - 状态格序（KOS `trailingCells`，BarStatusArea.qml:28-33）：托盘 id 段 →
///   wifi(network) → battery → controlcenter（settings 无 SDK 等价物隐藏）；
/// - 折两行：`itemCount > 1 && availableHeight >= itemSize*2`（KOS
///   bar/SysTray.qml:74-77；itemSize=iconSize+8=26 → 阈值 52）；`itemCount`
///   含托盘 id 与可见状态格（KOS `allKeys` 同式计 shell 格）。
///   两行时 `buildSystemTray(wrap: true)`、列数 `ceil(itemCount/2)`
///   （KOS :182-187 `columnCount = ceil(itemCount/rowCount)`，列宽
///   itemSize+iconSpacing）；单行 `horizontal: true, wrap: false`。
/// - 宽度参与 Dock 自适应（验收 3）：KOS `estimatedAccessoryWidth` 语义的
///   正确移植——`KosDockShell` 按托盘项数 + battery 格算出估算宽经
///   `DockMetrics.fromWidth(trayWidth:)` 回流进 `dockWidth`（KOS
///   dock/DockContainer.qml:111-133 预扣 + :954-959 `Loader.width =
///   item.implicitWidth` 参与 Row 自然宽）。本件按 [trayWidth]（缺省 =
///   内部同式重算）取真实槽宽排内容，不再经 `OverflowBox` 向左外延出槽
///   （审查缺陷 D1：外延会遮 divider3/info 且被 pill `ClipRRect` 裁掉）。
/// - 空态：TASK-09 起控制中心格**恒显示**并计入 `itemCount`/宽度回流 →
///   `itemCount` 恒 ≥ 1，`itemCount == 0` 的 `SizedBox.shrink()` 只剩防御性
///   分支（shell 层 `hasTray = trayEstimateWidth > 0` 与 divider3 也随之恒真）。
/// - 弹层：托盘项的激活/菜单由宿主 `buildSystemTray` 全权渲染
///   （services.dart:134-136 注释），弹出方向不受插件控制；battery 格的
///   自绘 popup v1 不做（任务卡条件句），格点击 = `openPowerSettings`
///   入口，见 deltas。
library;

import 'package:denial_flutter_sdk/services.dart' show ShellServices;
import 'package:denial_flutter_sdk/shell_theme.dart'
    show ShellThemeBuildContext;
import 'package:denial_flutter_sdk/state.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../theme/dock_tokens.dart';
import 'dock_control_center_panel.dart';
import 'dock_preview_popup.dart' show DockPopupCoordinator;
import 'dock_status_panels.dart';
import 'dock_wifi_panel.dart';
import 'status_cells.dart';

/// 折行判定（纯函数，抽给测试）：`dockHosted && itemCount > 1 &&
/// availableHeight >= twoRowThreshold`。
///
/// KOS: bar/SysTray.qml:74-77 — `twoRows: dockHosted && itemCount > 1
/// && availableHeight >= twoRowThreshold`（`twoRowThreshold = itemSize*2`，
/// dockHosted 侧恒 true）。
bool dockTrayTwoRows({
  required int itemCount,
  required double availableHeight,
  double twoRowThreshold = kDockTrayTwoRowThreshold,
}) => itemCount > 1 && availableHeight >= twoRowThreshold;

/// 托盘区横向估算宽（回流给 `DockMetrics.fromWidth(trayWidth:)` 的槽宽，
/// 也是 [DockTrayAccessory] 的内容宽）。
///
/// KOS: bar/SysTray.qml:78-85 — 单行 `itemCount*itemSize +
/// (itemCount-1)*iconSpacing`；:182-187 — 两行 `columnCount*itemSize +
/// (columnCount-1)*iconSpacing`，`columnCount = ceil(itemCount/rowCount)`。
/// 宿主托盘 button 实测 22×22（host `system_tray_module.dart`
/// `_SystemTrayButton` 的 `SizedBox.square(dimension: 22)`）＜26px 格宽、
/// 非 wrap 格距 4 / wrap 格距 8 ≠ KOS 6；自绘状态格占满 26px 格。统一按
/// KOS 几何估算（偏保守偏宽，多余空白留在托盘内容左侧槽内；偏差记
/// docs/visual-deltas.md）。
double dockTrayEstimateWidth({required int itemCount, required bool twoRows}) {
  if (itemCount <= 0) return 0;
  if (!twoRows) {
    return itemCount * kDockTrayItemSize +
        (itemCount - 1) * kDockTrayIconSpacing;
  }
  final columns = (itemCount + 1) ~/ 2;
  return columns * kDockTrayItemSize + (columns - 1) * kDockTrayIconSpacing;
}

/// Dock 尾端托盘挂件：托管给 `KosDockShell` 的 `dock.tray` 槽。
///
/// 槽宽 = `max(metrics.iconSlotSize, trayWidth)`：shell 层把
/// `dockTrayEstimateWidth` 估算宽经 `DockMetrics.fromWidth(trayWidth:)` 回流
/// 进 `dockWidth`（`estimatedAccessoryWidth` 等价），真实槽宽参与 Row
/// 布局——托盘内容右对齐排在槽内，不会溢出遮相邻槽位、也不会被 pill 的
/// `ClipRRect` 裁掉。`trayWidth` 缺省时本件按同一公式自行重算（独立宿主/
/// 测试不经 shell 也能拿到正确尺寸）。
class DockTrayAccessory extends ConsumerStatefulWidget {
  const DockTrayAccessory({
    required this.services,
    this.coordinator,
    this.trayWidth,
    super.key,
  });

  /// 宿主服务束（trayItemIds/battery/accent/buildSystemTray/
  /// openPowerSettings/strings/linkCursor）。
  final ShellServices services;

  /// 全 pill 唯一 popup 协调器（wifi/蓝牙面板与图标预览/菜单互斥，KOS
  /// `DockModelService.activeDockPopup`）；null → 各 anchor 自建实例
  /// （独立宿主/单测退化，同 `DockPreviewAnchor` 缺省语义）。
  final DockPopupCoordinator? coordinator;

  /// shell 层回流的托盘估算宽（KOS `estimatedAccessoryWidth` 等价）；null =
  /// 独立宿主（无 `KosDockShell`），build 内按 trayItemIds/状态格同式重算。
  final double? trayWidth;

  @override
  ConsumerState<DockTrayAccessory> createState() => _DockTrayAccessoryState();
}

class _DockTrayAccessoryState extends ConsumerState<DockTrayAccessory> {
  /// 维稳序列表：trayItemIds 相对序（denial_taskbar `tray.dart:56-77`
  /// `_orderedIds` 范式——状态/可见性变化不得搬动既有顺序）。
  final _orderedIds = <String>[];

  /// 状态格（build 内赋值给 [_flowOrder] 混排；`?` 空值安全进 children）。
  Widget? _wifiCell;
  Widget? _batteryCell;
  late Widget _controlCenterCell;

  @override
  Widget build(BuildContext context) {
    final services = widget.services;
    final ids = ref.watch(services.trayItemIds);
    // 维稳：消失 id 移除、新 id 追加尾部；host 列表自身重排不改变既有顺序
    // （KOS `arrangedKeys` 的 v1 近似——不持久化、不支持拖拽改序）。
    final live = ids.toSet();
    _orderedIds.removeWhere((id) => !live.contains(id));
    for (final id in ids) {
      if (!_orderedIds.contains(id)) _orderedIds.add(id);
    }
    final metrics = DockMetricsScope.of(context);
    final battery = ref.watch(services.battery);
    final hasBattery = battery.capacity != null;
    // TASK-08 状态格能力门控（能力缺失隐藏，不伪造占位——CONSTRAINTS
    // 「无等价物的格隐藏并记档」）：
    // wifi ← `snapshot.wifiDeviceAvailable`（KOS `NetworkService.available`，
    // NetworkStatus.qml:28 `visible`）。
    final netState = ref.watch(networkConnectivityProvider);
    final hasWifi = netState.snapshot.wifiDeviceAvailable;

    // KOS `allKeys` = 托盘 id + 可见状态格（SysTray.qml:69-73 itemCount 计
    // 全部格）；可见格 = wifi + battery + controlcenter——**无独立蓝牙格**
    // （KOS `trailingCells` 只有 network/battery/settings/controlcenter，
    // BarStatusArea.qml:28-33；蓝牙在 Wi-Fi 面板与控制中心里）。controlcenter
    // （TASK-09）**恒显示**（Flutter 侧自绘面板，无系统能力门控）。
    final statusCells =
        (hasWifi ? 1 : 0) +
        (hasBattery ? 1 : 0) +
        1;
    final itemCount = _orderedIds.length + statusCells;
    // 防御性分支：控制中心格恒显示 → `itemCount` 恒 ≥ 1（见类注释「空态」）。
    if (itemCount == 0) return const SizedBox.shrink();
    final twoRows = dockTrayTwoRows(
      itemCount: itemCount,
      // KOS `availableHeight` = BarStatusArea 高（dockHosted 时 =
      // computedDockHeight；BarStatusArea.qml:227 `root.height`）。
      availableHeight: metrics.dockHeight,
    );
    // 宽度 = KOS 格几何一次性估算（托盘 id + 状态格同格同距，KOS
    // `allKeys` 语义）；宿主托盘 button 实测 22×22＜26px 格、单渲项无内嵌
    // 间距 → 实际内容宽 ≤ 此估算（偏保守偏宽，偏差记 deltas）。与
    // `KosDockShell` 传给 fromWidth 的估算式同式（widget.trayWidth 非 null
    // 时用 shell 传入值，两者同源不会漂移）。
    final contentWidth = dockTrayEstimateWidth(
      itemCount: itemCount,
      twoRows: twoRows,
    );
    // 槽宽 = max(iconSlotSize, trayWidth)：回流后 dockWidth 恒能包住槽宽；
    // shell 传入值与本地同式重算一致，独立宿主（trayWidth=null）取本地值。
    final slotWidth = widget.trayWidth ?? contentWidth;
    // 格顺序：托盘 id 段 → wifi(network) → battery → controlcenter——对齐
    // KOS `BarStatusArea.trailingCells` 序（BarStatusArea.qml:28-33：
    // network → battery → settings → controlcenter；settings 无 SDK 等价物
    // 隐藏）。**无独立蓝牙格**（KOS 无此格）。每只格挂固定 key：能力位
    // 翻转（wifi/battery 出现或消失）时 Flutter 按下标复用 Element 会
    // unmount 另一只 anchor（已开面板被销毁、hover/press 态重置）——对照
    // `dock_shell.dart` 槽位 ValueKey（`dock.launcher`/`dock.tray` 等）范式。
    // 格本体不带左 padding——两行 `Wrap(spacing:)`/单行 Row 显式间距统一管
    // （KOS `SysTray` 的 iconSpacing 由网格列距承担，不属格内几何）。key 仍
    // 挂格外层：能力位翻转时按下标复用 Element 不卸其它 anchor。
    _wifiCell = hasWifi
        ? SizedBox(
            key: const ValueKey<String>('dock.cell.wifi'),
            child: DockWifiPanelAnchor(
              services: services,
              coordinator: widget.coordinator,
              child: Builder(
                builder: (context) => DockWifiCell(
                  enabled: netState.snapshot.wirelessEnabled,
                  connected: netState.snapshot.connectedNetwork != null,
                  connecting: dockWifiConnecting(netState.snapshot.status),
                  strength:
                      netState.snapshot.connectedNetwork?.strength ?? -1,
                  busy: netState.scanning || netState.radioChanging,
                  tooltipPrimary: dockWifiTooltip(
                    connected: netState.snapshot.connectedNetwork != null,
                    connecting: dockWifiConnecting(netState.snapshot.status),
                    ssid: netState.snapshot.connectedNetwork?.ssid,
                  ).primary,
                  tooltipSecondary: dockWifiTooltip(
                    connected: netState.snapshot.connectedNetwork != null,
                    connecting: dockWifiConnecting(netState.snapshot.status),
                    ssid: netState.snapshot.connectedNetwork?.ssid,
                  ).secondary,
                  cursor: services.linkCursor,
                  onToggle: () =>
                      DockStatusPanelAnchorState.togglePanelOf(context),
                ),
              ),
            ),
          )
        : null;

    // 控制中心格（TASK-09，KOS `ControlCenterToggle.qml`）：恒显示，点击
    // toggle `DockControlCenterPanel`（与 wifi/bt 面板、图标预览/菜单共享
    // 同一 `DockPopupCoordinator`）。
    _controlCenterCell = SizedBox(
      key: const ValueKey<String>('dock.cell.controlcenter'),
      child: DockControlCenterPanelAnchor(
        services: services,
        coordinator: widget.coordinator,
        child: Builder(
          builder: (context) => DockControlCenterCell(
            cursor: services.linkCursor,
            onToggle: () => DockStatusPanelAnchorState.togglePanelOf(context),
          ),
        ),
      ),
    );

    _batteryCell = hasBattery
        ? SizedBox(
            key: const ValueKey<String>('dock.cell.battery'),
            child: DockBatteryCell(
              status: battery,
              services: services,
            ),
          )
        : null;
    return SizedBox(
      width: slotWidth,
      height: metrics.dockHeight,
      child: Align(
        alignment: Alignment.centerRight,
          // KOS: bar/SysTray.qml:193-196 — 内容块 `anchors.centerIn`、
          // `implicitHeight = rowCount * itemSize`（两行=52 在 dockHeight 内
          // 居中，上下各留 (dockHeight-52)/2）。Flutter `Wrap` 会取自身
          // cross 轴最大高（=约束高）顶头排 → 用 SizedBox 收高度让 Align
          // 垂直居中。
          child: Align(
            child: SizedBox(
              width: contentWidth,
              // KOS: :188 — implicitHeight = rowCount * itemSize。
              height: (twoRows ? 2 : 1) * kDockTrayItemSize,
              // KOS: bar/SysTray.qml —— 托盘项与 shell 状态格混排同一网格
              // （`allKeys = nativeKeys + trailingCellKeys`）。两行时 KOS
              // `slotOriginIn` 按列填：row=index%rows、
              // column=floor(index/rows)（:119-136）；Flutter `Wrap` 按行
              // 填 → 子项统一包成 itemSize(26)×26 格保证换行点=列边界
              // （宿主托盘钮 22px 居中进槽），再按 `r, r+2, r+4…`（行主序）
              // 重排喂给 Wrap，等价 KOS 列主序交错。单行是同式 rows=1
              // 横排，天然序即可。
              child: Wrap(
                // KOS: SysTray.qml:13 — 格间 iconSpacing 6（行距同，
                // 两行各 26px 恰好贴满 52 无额外 runSpacing）。
                spacing: kDockTrayIconSpacing,
                runSpacing: 0,
                alignment: WrapAlignment.start,
                children: [
                  for (final cell in _flowOrder(twoRows: twoRows))
                    SizedBox.square(
                      dimension: kDockTrayItemSize,
                      child: Center(child: cell),
                    ),
                ],
              ),
            ),
          ),
        ),
    );
  }

  /// 按 KOS `allKeys` 序组装格子（托盘 id 段 → wifi → battery →
  /// controlcenter）；`twoRows` 时重排为 Wrap 行主序输入以还原 KOS
  /// 列主序交错（见 build 内注释）。
  List<Widget> _flowOrder({required bool twoRows}) {
    final cells = <Widget>[
      for (final id in _orderedIds)
        widget.services.buildSystemTray(
          context,
          horizontal: true,
          wrap: false,
          foregroundColor: context.shellColors.textPrimary,
          itemIds: List<String>.unmodifiable([id]),
        ),
      ?_wifiCell,
      ?_batteryCell,
      _controlCenterCell,
    ];
    if (!twoRows) return cells;
    return [
      for (var i = 0; i < cells.length; i += 2) cells[i],
      for (var i = 1; i < cells.length; i += 2) cells[i],
    ];
  }
}
