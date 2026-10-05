/// TASK-06 托盘区（trailing accessory）：KOS `BarStatusArea{dockHosted:true}`
/// 的 Dock 尾端融合托盘——宿主 `buildSystemTray` 渲染 StatusNotifierItem +
/// 尾部状态格（[DockBatteryCell]，v1 唯一有 SDK 等价物的格）。
///
/// 移植要点（源根 `/home/wwt/文档/NextKde/shell/desktop/modules/`）：
/// - 维稳排序：denial_taskbar `tray.dart:56-77` 的 `_orderedIds` 范式——
///   删掉已消失的 id、新 id 追加尾部，宿主列表重排不搬动既有顺序。v1 只
///   维稳、不持久化排序（KOS `SysTrayOrderService` 的 Alt+拖拽重排与持久序
///   砍掉，记 docs/visual-deltas.md）。
/// - 状态格序（TASK-09/09）：托盘 id 段 → wifi → bluetooth → controlcenter →
///   battery；控制中心格**恒显示**（无能力门控，TASK-09）。
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
import 'dock_bluetooth_panel.dart';
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
    final colors = context.shellColors;
    final battery = ref.watch(services.battery);
    final hasBattery = battery.capacity != null;
    // TASK-08 状态格能力门控（能力缺失隐藏，不伪造占位——CONSTRAINTS
    // 「无等价物的格隐藏并记档」）：
    // wifi ← `snapshot.wifiDeviceAvailable`（KOS `NetworkService.available`，
    // NetworkStatus.qml:28 `visible`）；bt ← `BluetoothState.available`。
    final netState = ref.watch(networkConnectivityProvider);
    final btState = ref.watch(bluetoothProvider);
    final hasWifi = netState.snapshot.wifiDeviceAvailable;
    final hasBluetooth = btState.available;

    // KOS `allKeys` = 托盘 id + 可见状态格（SysTray.qml:69-73 itemCount 计
    // 全部格）；可见格 = battery + wifi + bluetooth + controlcenter（TASK-09
    // 控制中心格**恒显示**——面板是 Flutter 侧自绘，不依赖系统能力门控）。
    final statusCells =
        (hasWifi ? 1 : 0) +
        (hasBluetooth ? 1 : 0) +
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
    // 宽度拆两段估算：托盘段只按托盘 id 数估（宿主 wrap 受同宽约束），状态格
    // 段按 KOS 格几何 iconSpacing+itemSize 逐格追加——两段相加 ≤ 单条
    // dockTrayEstimateWidth(itemCount: 总数) 的上界，且永远 ≥ 宿主实测宽
    // （宿主 22px 钮 + 4/8px 间距 < KOS 26px 格 + 6px 间距），保证内容不溢出
    // 内层 Row。与 `KosDockShell` 传给 fromWidth 的估算式同式（widget.
    // trayWidth 非 null 时用 shell 传入值，两者同源不会漂移）。
    final trayWidth = dockTrayEstimateWidth(
      itemCount: _orderedIds.length,
      twoRows: twoRows,
    );
    final contentWidth =
        trayWidth + statusCells * (kDockTrayIconSpacing + kDockTrayItemSize);
    // 槽宽 = max(iconSlotSize, trayWidth)：回流后 dockWidth 恒能包住槽宽；
    // shell 传入值与本地同式重算一致，独立宿主（trayWidth=null）取本地值。
    final slotWidth = widget.trayWidth ?? contentWidth;
    // 格顺序：托盘 id 段 → wifi → bluetooth → battery（任务卡「在 battery
    // 格之前追加」；KOS `BarStatusArea.trailingCells` 序 network→battery）。
    // 每只格挂固定 key：能力位翻转（wifi/bt/battery 出现或消失）时 Flutter
    // 按下标复用 Element 会 unmount 另一只 anchor（已开面板被销毁、hover/press
    // 态重置）——对照 `dock_shell.dart` 槽位 ValueKey（`dock.launcher`/`dock.tray`
    // 等）范式。
    final wifiCell = hasWifi
        ? Padding(
            key: const ValueKey<String>('dock.cell.wifi'),
            // KOS: bar/SysTray.qml:13 — 格间 iconSpacing 6。
            padding: const EdgeInsets.only(left: kDockTrayIconSpacing),
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

    final bluetoothCell = hasBluetooth
        ? Padding(
            key: const ValueKey<String>('dock.cell.bluetooth'),
            padding: const EdgeInsets.only(left: kDockTrayIconSpacing),
            child: DockBluetoothPanelAnchor(
              services: services,
              coordinator: widget.coordinator,
              child: Builder(
                builder: (context) => DockBluetoothCell(
                  powered: btState.powered,
                  busy: btState.powerChanging || btState.refreshing,
                  tooltip: btState.powered ? '蓝牙' : '蓝牙已关闭',
                  cursor: services.linkCursor,
                  accent: ref.watch(services.accent),
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
    final controlCenterCell = Padding(
      key: const ValueKey<String>('dock.cell.controlcenter'),
      padding: const EdgeInsets.only(left: kDockTrayIconSpacing),
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

    final Widget? batteryCell = hasBattery
        ? Padding(
            key: const ValueKey<String>('dock.cell.battery'),
            // KOS: bar/SysTray.qml:13 — 格间 iconSpacing 6。
            padding: const EdgeInsets.only(left: kDockTrayIconSpacing),
            child: DockBatteryCell(
              status: battery,
              services: services,
              accent: ref.watch(services.accent),
            ),
          )
        : null;

    return SizedBox(
      width: slotWidth,
      height: metrics.dockHeight,
      child: Align(
        alignment: Alignment.centerRight,
        child: SizedBox(
          width: contentWidth,
          height: metrics.dockHeight,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              if (_orderedIds.isNotEmpty)
                twoRows
                    // 两行：宿主 `Wrap` 按 ceil(托盘项数/rowCount) 列约束总宽
                    // （KOS: bar/SysTray.qml:182-187 `columnCount`、列宽
                    // itemSize+iconSpacing）。宿主 wrap 的格距恒 8≠KOS 6、
                    // 且 shell 格在宿主 wrap 之外（KOS 把格混排进同一网格），
                    // 两处偏差记 docs/visual-deltas.md。
                    ? Align(
                        alignment: Alignment.centerRight,
                        child: ConstrainedBox(
                          constraints: BoxConstraints(maxWidth: trayWidth),
                          child: services.buildSystemTray(
                            context,
                            horizontal: true,
                            wrap: true,
                            foregroundColor: colors.textPrimary,
                            itemIds: List<String>.unmodifiable(_orderedIds),
                          ),
                        ),
                      )
                    : services.buildSystemTray(
                        context,
                        horizontal: true,
                        // KOS: bar/SysTray.qml:184-189 — 单行自然宽排。
                        wrap: false,
                        foregroundColor: colors.textPrimary,
                        itemIds: List<String>.unmodifiable(_orderedIds),
                      ),
              ?wifiCell,
              ?bluetoothCell,
              controlCenterCell,
              ?batteryCell,
            ],
          ),
        ),
      ),
    );
  }
}
