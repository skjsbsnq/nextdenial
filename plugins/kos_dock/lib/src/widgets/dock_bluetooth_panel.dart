/// TASK-08 蓝牙状态格面板（KOS `bar/BluetoothPanel.qml`，300×340 r20）。
///
/// 移植要点（源根 `/home/wwt/文档/NextKde/shell/desktop/modules/`）：
/// - 骨架/动画/锚定走 `dock_status_panels.dart` 共享
///   `DockStatusPanelAnchor`（150/140ms、scale 0.96→1、bottom dock 向上弹
///   6px，KOS BluetoothPanel.qml:23-41 `margins.top: -6`）。
/// - KOS 侧该面板已实例化但无打开入口（蓝牙 UI 在控制中心卡内；spec §6）
///   ——本端给托盘格自写 `onTap → togglePanel`，不依赖控制中心。
/// - 控件树（BluetoothPanel.qml:103-176）：`ListView` margins 8/8/8/0、
///   spacing 2、`model = powered ? devices : []`；行 46px r11 hover
///   textPrimary@0.12 110ms、18×18 BT glyph（left 31，connected→accent
///   点亮是本端近似：KOS glyph 恒前景色，点亮语义取自控制中心蓝牙卡）、
///   ✓18px（仅 connected，left 8）、名称 12px DemiBold（left 58）。
/// - 设备过滤：KOS 设备列表只含 `paired ∥ connected`（ControlCenterService
///   侧语义，spec §6）；SDK `devices` 可能含未配对发现项 → 同式过滤。
/// - 点击行：`controller.toggleConnection(device)`（KOS
///   `setBluetoothDeviceConnected(modelData, !connected)` :142-149 等价——
///   SDK toggleConnection 内部已覆盖 pair/trust/connect 链）。
///   `busyDevices.contains(objectPath)` → 行禁用（KOS
///   `bluetoothDeviceChangeInProgress` 的行级近似）。
/// - 空态三态（:151-176）：`!powered`→「蓝牙已关闭」；`refreshing ||
///   scanning`→「正在刷新…」；否则「未发现已配对设备」。
/// - 行尾电量：SDK `BluetoothDeviceInfo` 无 battery 字段 → 省略记 deltas。
/// - 设置底脚：SDK 无 `settings.open` 等价物 → 禁用态记 deltas。
/// - 打开时 `controller.refresh()`（KOS `open()` →
///   `refreshBluetoothDevices()` :53-58）。
library;

import 'dart:async';

import 'package:denial_flutter_sdk/services.dart' show ShellServices;
import 'package:denial_flutter_sdk/shell_theme.dart';
import 'package:denial_flutter_sdk/state.dart';
import 'package:denial_flutter_sdk/system_services.dart'
    show BluetoothDeviceInfo;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../theme/dock_tokens.dart';
import 'dock_status_panels.dart';
import 'status_cells.dart';

/// 蓝牙面板宿主：26px 格外包一层 anchor（格本体 `DockBluetoothCell` 的
/// `onToggle` 绑 [DockStatusPanelAnchorState.togglePanel]）。
class DockBluetoothPanelAnchor extends DockStatusPanelAnchor {
  const DockBluetoothPanelAnchor({
    required this.services,
    required super.coordinator,
    required super.child,
    super.key,
  });

  final ShellServices services;

  @override
  double get panelWidth => kDockBluetoothPanelWidth;
  @override
  double get panelHeight => kDockBluetoothPanelHeight;
  @override
  double get panelRadius => kDockBluetoothPanelRadius;

  /// KOS: bar/BluetoothPanel.qml:31-34 — dock bottom `margins.top: -6`。
  @override
  double get panelGap => kDockBluetoothPanelGap;

  /// KOS `open()`（BluetoothPanel.qml:53-58）：`refreshBluetoothDevices()` →
  /// SDK `refresh()`。骨架无 `ref`（同 wifi 面板），实际调用由面板子树
  /// 首帧 `build` 内发一次。
  @override
  void onOpened() {}

  @override
  Widget buildPanel(BuildContext context) =>
      DockBluetoothPanel(services: services);

  @override
  State<DockBluetoothPanelAnchor> createState() =>
      _DockBluetoothPanelAnchorState();
}

class _DockBluetoothPanelAnchorState
    extends DockStatusPanelAnchorState<DockBluetoothPanelAnchor> {}

/// 蓝牙面板内容（overlay 子树）。
class DockBluetoothPanel extends ConsumerStatefulWidget {
  const DockBluetoothPanel({required this.services, super.key});

  final ShellServices services;

  @override
  ConsumerState<DockBluetoothPanel> createState() =>
      _DockBluetoothPanelState();
}

class _DockBluetoothPanelState extends ConsumerState<DockBluetoothPanel> {
  @override
  Widget build(BuildContext context) => DockStatusPanelSurface(
    radius: kDockBluetoothPanelRadius,
    child: Padding(
      // KOS: :103-106 — 内容外边距（面板内边距）10。
      padding: const EdgeInsets.all(kDockStatusPanelMargin),
      child: Column(
        children: [
          // 列表/空态/行点击路径抽给 TASK-09 控制中心蓝牙子页复用
          // （同一 `DockBluetoothDeviceListBody`）。
          Expanded(
            child: DockBluetoothDeviceListBody(services: widget.services),
          ),
          // SDK 无 `settings.open` → 禁用底脚（记 deltas）。
          DockStatusPanelFooter(
            label: '蓝牙设置…',
            onTap: null,
            cursor: widget.services.linkCursor,
          ),
        ],
      ),
    ),
  );
}
/// 蓝牙设备行（46px r11）：✓（仅 connected）+ 18px BT glyph + 名称。
///
/// KOS: bar/BluetoothPanel.qml:109-149。抽公共件给 TASK-09 控制中心复用。
class DockBluetoothDeviceRow extends StatefulWidget {
  const DockBluetoothDeviceRow({
    required this.device,
    required this.busy,
    required this.cursor,
    required this.accent,
    required this.onTap,
    this.height = kDockStatusRowHeight,
    super.key,
  });

  final BluetoothDeviceInfo device;

  /// `busyDevices.contains(objectPath)` → 禁用点击（KOS
  /// `bluetoothDeviceChangeInProgress` 行级近似）。
  final bool busy;

  final MouseCursor cursor;

  /// connected → accent 点亮 glyph（KOS 控制中心蓝牙卡点亮语义；面板行内
  /// KOS glyph 恒前景色，点亮近似记 deltas）。
  final Color accent;

  final VoidCallback onTap;

  /// 行高（TASK-08 面板 46，KOS `BluetoothPanel.qml:109-115`；控制中心蓝牙
  /// 子页 42，KOS `ControlCenterPanel.qml:2375`）。
  final double height;

  @override
  State<DockBluetoothDeviceRow> createState() => _DockBluetoothDeviceRowState();
}

class _DockBluetoothDeviceRowState extends State<DockBluetoothDeviceRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.shellColors;
    final device = widget.device;
    return MouseRegion(
      cursor: widget.busy ? SystemMouseCursors.basic : widget.cursor,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.busy ? null : widget.onTap,
        child: AnimatedContainer(
          // KOS: :112-115 — hover 填 rgba(1,1,1,.12) 110ms。
          duration: kDockStatusRowHoverDuration,
          height: widget.height,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(kDockBluetoothRowRadius),
            color: _hovered
                ? colors.textPrimary.withValues(
                    alpha: kDockStatusRowHoverAlpha,
                  )
                : const Color(0x00000000),
          ),
          child: Stack(
            children: [
              if (device.connected)
                Positioned(
                  // KOS: :126-133 — ✓ 18px DemiBold、left 8 居中。
                  left: 8,
                  top: 0,
                  bottom: 0,
                  width: kDockBluetoothRowCheckSize,
                  child: Center(
                    child: Text(
                      '✓',
                      style: TextStyle(
                        fontSize: kDockBluetoothRowCheckSize,
                        fontWeight: FontWeight.w600,
                        color: colors.textPrimary,
                        height: 1.0,
                      ),
                    ),
                  ),
                ),
              Positioned(
                // KOS: :116-125 — 18×18 BT glyph、left 31 居中。
                left: kDockBluetoothRowGlyphLeft,
                top: 0,
                bottom: 0,
                child: Center(
                  child: DockBluetoothGlyph(
                    color: device.connected
                        ? widget.accent
                        : colors.textPrimary,
                    size: kDockBluetoothRowGlyphSize,
                  ),
                ),
              ),
              Positioned(
                // KOS: :134-141 — 名称 12px DemiBold elide、left 58
                // right 12。
                left: kDockBluetoothRowLabelLeft,
                right: 12,
                top: 0,
                bottom: 0,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    device.name.isEmpty ? device.address : device.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: kDockStatusRowFontSize,
                      fontWeight: FontWeight.w600,
                      color: colors.textPrimary,
                      height: 1.0,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 蓝牙设备列表体（KOS `bar/BluetoothPanel.qml:103-176`）：TASK-08 面板与
/// TASK-09 控制中心蓝牙子页共用同一份列表/空态/行点击路径。
///
/// - 首帧对当前会话发一次 `refresh()`（KOS `open()` →
///   `refreshBluetoothDevices()`，BluetoothPanel.qml:53-58；控制中心
///   `openSubmenu("bluetooth")` 同语义，ControlCenterPanel.qml:98-100）；
/// - 列表只含 `paired ∥ connected`（KOS ControlCenterService 侧语义，
///   spec §6）；
/// - **空态只在列表为空时占据整块**：KOS 的「正在刷新…」是叠在列表上的
///   label（BluetoothPanel.qml:151-168，列表恒渲染），控制中心 bt 子页的
///   指示在小节头（ControlCenterPanel.qml:2344-2370）——冷开的 `refresh()`
///   期间已配对设备列表不得消失。故：`!powered` → 「蓝牙已关闭」；列表空 →
///   refreshing/scanning 时「正在刷新…」（该文案已在小节头时由
///   [refreshLabelInHeader] 抑制，KOS CC 同：`count === 0 &&
///   !refreshInProgress` 才画「未发现已配对设备」）、否则「未发现已配对设备」；
/// - 行点击 → `controller.toggleConnection(device)`（KOS
///   `setBluetoothDeviceConnected(modelData, !connected)` :142-149 等价）。
class DockBluetoothDeviceListBody extends ConsumerStatefulWidget {
  const DockBluetoothDeviceListBody({
    required this.services,
    this.rowHeight = kDockStatusRowHeight,
    this.refreshLabelInHeader = false,
    this.padding = const EdgeInsets.fromLTRB(
      kDockStatusListMargin,
      kDockStatusListMargin,
      kDockStatusListMargin,
      0,
    ),
    super.key,
  });

  final ShellServices services;

  /// 行高（TASK-08 面板 46；控制中心蓝牙子页 42，KOS
  /// `ControlCenterPanel.qml:2375`）。
  final double rowHeight;

  /// 宿主是否已在小节头画「正在刷新…」（控制中心 bt 子页，
  /// `ControlCenterPanel.qml:2344-2370`）——true 时列表体不再重复该文案。
  final bool refreshLabelInHeader;

  /// 列表内边距（KOS BluetoothPanel.qml:103-108 `8/8/8/0`；控制中心子页
  /// `8/2/8/0`，ControlCenterPanel.qml:2364-2372）。
  final EdgeInsets padding;

  @override
  ConsumerState<DockBluetoothDeviceListBody> createState() =>
      _DockBluetoothDeviceListBodyState();
}

class _DockBluetoothDeviceListBodyState
    extends ConsumerState<DockBluetoothDeviceListBody> {
  bool _refreshRequested = false;

  /// KOS `open()` 内 `ControlCenterService.refreshBluetoothDevices()`
  /// （BluetoothPanel.qml:56-57）→ SDK `refresh()`（自带 refreshing
  /// 去重）。首帧 build 发一次。
  void _requestRefreshOnce() {
    if (_refreshRequested) return;
    _refreshRequested = true;
    // build 内不得改 provider（riverpod assert）——推迟到帧后（KOS 的
    // `open()` 同步刷新语义在 overlay 首帧之后执行等价）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(bluetoothProvider.notifier).refresh();
    });
  }

  @override
  Widget build(BuildContext context) {
    _requestRefreshOnce();
    final bt = ref.watch(bluetoothProvider);
    // KOS: BluetoothPanel.qml:107 — `model: bluetoothPowered ?
    // bluetoothDevices : []`；列表只含 paired∥connected（spec §6 → 同式
    // 过滤 SDK devices）。
    final devices = bt.powered
        ? bt.devices
              .where((device) => device.paired || device.connected)
              .toList(growable: false)
        : const <BluetoothDeviceInfo>[];
    // KOS: BluetoothPanel.qml:151-176 — 空态只在列表为空时占据整块：
    // `!powered` → 「蓝牙已关闭」；空列表 + refreshing/scanning →「正在刷新…」
    // （宿主小节头已画该文案时抑制，见 [DockBluetoothDeviceListBody.
    // refreshLabelInHeader]）；空列表 → 「未发现已配对设备」。**非空列表
    // 恒渲染**（KOS 的刷新指示是叠加 label，不替换列表）。
    if (!bt.powered) {
      return const DockStatusPanelEmptyLabel('蓝牙已关闭');
    }
    if (devices.isEmpty) {
      if (bt.refreshing || bt.scanning) {
        // SDK `scanning` 并入刷新档。
        return widget.refreshLabelInHeader
            ? const SizedBox.shrink()
            : const DockStatusPanelEmptyLabel('正在刷新…');
      }
      return const DockStatusPanelEmptyLabel('未发现已配对设备');
    }
    // KOS: :103-108 — ListView margins、spacing 2。
    return ListView.separated(
      padding: widget.padding,
      itemCount: devices.length,
      separatorBuilder: (_, _) =>
          const SizedBox(height: kDockStatusRowSpacing),
      itemBuilder: (context, index) {
        final device = devices[index];
        return DockBluetoothDeviceRow(
          device: device,
          busy: bt.busyDevices.contains(device.objectPath),
          cursor: widget.services.linkCursor,
          accent: context.shellTheme.accent,
          height: widget.rowHeight,
          onTap: () => unawaited(
            ref.read(bluetoothProvider.notifier).toggleConnection(device),
          ),
        );
      },
    );
  }
}
