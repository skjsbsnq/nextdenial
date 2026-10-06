/// TASK-06/08/09 状态格（trailing cells）：KOS `BarStatusArea` 托盘区尾部
/// shell 格（`trailingCells = network/battery/settings/controlcenter`，
/// KOS: bar/BarStatusArea.qml:28-33）中**有 SDK 等价物**的格——wifi、
/// battery、controlcenter。
///
/// v1 可见格：wifi（`networkConnectivityProvider.snapshot.wifiDeviceAvailable`）、
/// battery（`services.battery` 有数据时）、controlcenter（`DockControlCenterCell`，
/// TASK-09：Flutter 侧自绘面板 + 状态下发，恒显示、无系统能力门控）。
/// **无独立蓝牙格**（KOS `trailingCells` 不含 bluetooth；蓝牙入口在 Wi-Fi
/// 面板与控制中心里）；settings 在 SDK 无对应面板与开关 → 仍隐藏，不伪造
/// 占位（任务卡「无等价物的格隐藏并记档」，见 docs/visual-deltas.md）。
/// clock 已由融合信息卡承担（KOS 融合态 `clockInInfoCarousel`，不重复）。
///
/// 几何/配色移植 KOS `bar/Battery.qml` + `bar/NetworkStatus.qml` +
/// `bar/WifiSignalIcon.qml`（源根
/// `/home/wwt/文档/NextKde/shell/desktop/modules/`）。颜色字面量按
/// CONSTRAINTS §3 映射 shellTheme 语义色；KOS 的 IconAppearanceService
/// tint 分支不移植（Denial 无图标外观服务，记 deltas）。
library;

import 'dart:math' as math;

import 'package:denial_flutter_sdk/services.dart' show ShellServices;
import 'package:denial_flutter_sdk/shell_color_scheme.dart'
    show ShellColorScheme;
import 'package:denial_flutter_sdk/shell_theme.dart'
    show ShellThemeBuildContext;
import 'package:denial_flutter_sdk/system_services.dart'
    show NetworkConnectivityStatus;
import 'package:denial_sdk/system.dart' show BatteryStatus;
import 'package:flutter/widgets.dart';

import '../theme/dock_tokens.dart';
import 'dock_status_panels.dart';

/// 电量格 fillColor：KOS `Battery.qml:111-118` 分档字面色（**不**映射
/// accent/语义色——用户要求严格对齐 KOS 视觉：>95 绿、≥50 前景、≥15 橙、
/// 否则红）。
Color dockBatteryFillColor(ShellColorScheme colors, int percent) {
  if (percent > kDockBatteryFullThreshold) {
    return const Color(kDockBatteryFullColor);
  }
  if (percent >= kDockBatteryMidThreshold) return colors.textPrimary;
  if (percent >= kDockBatteryLowThreshold) {
    return const Color(kDockBatteryWarnColor);
  }
  return const Color(kDockBatteryCritColor);
}

/// 电量格（KOS `Battery.qml`）：capacity 为 null（unknown）时由调用方整体
/// 隐藏本格——本件自身返回 0 宽 shrink 作防御，不伪造任何数据。
///
/// 点击 → `services.openPowerSettings()`：KOS 本体只有 hover
/// StatusTooltip（Battery.qml:87-101），无点击行为；「电源菜单入口」是
/// 任务卡指定映射（SDK `ShellDesktopServices.openPowerSettings`，
/// services.dart:94），偏差记 deltas。
class DockBatteryCell extends StatelessWidget {
  const DockBatteryCell({
    required this.status,
    required this.services,
    super.key,
  });

  /// 电池快照；`capacity == null` 时本格不应被挂载（调用方判定，此处 0 宽
  /// 收缩只是兜底）。
  final BatteryStatus status;
  final ShellServices services;

  @override
  Widget build(BuildContext context) {
    final percent = status.capacity;
    if (percent == null) return const SizedBox.shrink();
    final colors = context.shellColors;
    // KOS: bar/Battery.qml:104-107 — level = clamp(percentage, 0..1)，
    // percent = round(level*100)（SDK 已是整数百分比，clamp 防御越界）。
    final level = percent.clamp(0, 100) / 100.0;
    // KOS: bar/Battery.qml:119-121 — boltColor: 50≤p≤95 → #ff9f0a，否则前景。
    // 语义映射：中段走 performanceWarning，其余 textPrimary。
    // KOS: bar/Battery.qml:119-121 — boltColor: 50≤p≤95 → #ff9f0a，否则前景。
    final boltColor =
        percent >= kDockBatteryMidThreshold &&
            percent <= kDockBatteryFullThreshold
        ? const Color(kDockBatteryWarnColor)
        : colors.textPrimary;
    final strings = services.strings(context);
    final label =
        '${strings.batteryTitle}: '
        '${strings.batteryLine(status.charging ? 'charging' : 'discharging', percent)}';

    final outline = SizedBox(
      // KOS: bar/Battery.qml:37-51 — outline `max(12, iconSize-2)` ×
      // `max(8, round(iconSize*0.56))`（iconSize=21 → 19×12），radius 3、
      // 描边 1.5、描边色 = 前景。
      width: kDockBatteryOutlineWidth,
      height: kDockBatteryOutlineHeight,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(kDockBatteryOutlineRadius),
          border: Border.all(
            color: colors.textPrimary,
            width: kDockBatteryOutlineBorder,
          ),
        ),
        child: Stack(
          children: [
            Positioned(
              left: kDockBatteryFillInset,
              top: kDockBatteryFillInset,
              bottom: kDockBatteryFillInset,
              child: Container(
                // KOS: bar/Battery.qml:64-76 — `max(2, (outline.width-4)*level)`
                // × `outline.height-4`，radius 2；ready && percent>0 才有填充。
                width: percent <= 0
                    ? 0.0
                    : math.max(
                        kDockBatteryFillMinWidth,
                        (kDockBatteryOutlineWidth - 4) * level,
                      ),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(kDockBatteryFillRadius),
                  color: dockBatteryFillColor(colors, percent),
                ),
              ),
            ),
            if (status.charging)
              // KOS: bar/Battery.qml:78-85 — 充电时外框内居中「⚡」，
              // `max(7, iconSize*0.44)` bold。
              Center(
                child: Text(
                  '⚡',
                  style: TextStyle(
                    fontSize: kDockBatteryBoltFontSize,
                    fontWeight: FontWeight.bold,
                    color: boltColor,
                    height: 1.0,
                  ),
                ),
              ),
          ],
        ),
      ),
    );

    return Semantics(
      button: true,
      label: label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: services.openPowerSettings,
        child: MouseRegion(
          cursor: services.linkCursor,
          // KOS: bar/SysTray.qml:503-504 — 格占满 `itemSize`(26) 槽
          // （`width: slotWidth`），命中区 = 槽宽；格内图标 21px
          // （BarStatusArea.qml:115-117 `iconSize: systemTray.iconSize + 3`，
          // `anchors.centerIn` 居中——本端 centerLeft 对齐保持格左缘排布）。
          child: SizedBox.square(
            dimension: kDockTrayItemSize,
            child: Align(
              alignment: Alignment.centerLeft,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  outline,
                  // KOS: bar/Battery.qml:53-62 — 右侧电极
                  // `max(1.5, iconSize-outline.width)` ×
                  // `max(3, iconSize*0.20)`（21−19=2 × 4.2），radius 1，前景色。
                  Container(
                    width: kDockBatteryTipWidth,
                    height: kDockBatteryTipHeight,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(
                        kDockBatteryTipRadius,
                      ),
                      color: colors.textPrimary,
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
}

// ══════════════════════════════════════════════════════════════════
// TASK-08：Wi-Fi / 蓝牙状态格 + StatusTooltip
// ══════════════════════════════════════════════════════════════════

/// WifiSignalIcon 分档（纯函数，可测）：`!enabled || !connected || strength<0`
/// → 0 弧；`<30→1`；`<60→2`；`≥60→3`。**格图标与面板行图标阈值不同**——
/// 行图标档是 `<25/<50/≥50`（见 `_WifiRowGlyph`）。
///
/// KOS: bar/WifiSignalIcon.qml:17-19。
int dockWifiSignalLevel({
  required bool enabled,
  required bool connected,
  required int strength,
}) {
  if (!enabled || !connected || strength < 0) return 0;
  if (strength < kDockWifiLevel1Max) return 1;
  if (strength < kDockWifiLevel2Max) return 2;
  return 3;
}

/// KOS `bar/WifiSignalIcon.qml` 的自绘移植：20×20 逻辑画布、3 弧 + 1 点，
/// `ctx.scale(w/20,h/20)` + `translate(0,-1.1)`。
///
/// 几何（:29-55）：弧圆心 (10,14.2)、半径 `3.0 + ring*2.7`、弧角 π*1.22 →
/// π*1.78；点 (10,13.8) r=1.15；`lineWidth 1.55` round cap/join（:16）。
/// 层级 alpha（:51-71）：底层全弧 `wifiEnabled ? .22 : .16`；顶层
/// `connected ? 1.0 : .52` 重画 signalLevel 弧+点；disabled 画斜线
/// (4,4.2)→(15.6,15.4) alpha .72。
class DockWifiSignalIcon extends StatelessWidget {
  const DockWifiSignalIcon({
    required this.enabled,
    required this.connected,
    required this.strength,
    required this.color,
    this.size = kDockStatusCellIconSize,
    super.key,
  });

  /// KOS `wifiEnabled`（false 画斜杠）。
  final bool enabled;

  /// KOS `connected`（点亮弧 alpha 1.0 vs 0.52 与分档前置条件）。
  final bool connected;

  /// KOS `signalStrength`（0-100；-1/负值 → 0 弧）。
  final int strength;

  /// KOS `glyphColor`（调用方给：状态格=主题前景，开关球=accent）。
  final Color color;

  /// 边长（格内 18；面板开关球 20，见 `dock_wifi_panel.dart`）。
  final double size;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: CustomPaint(
      painter: _WifiSignalPainter(
        level: dockWifiSignalLevel(
          enabled: enabled,
          connected: connected,
          strength: strength,
        ),
        enabled: enabled,
        connected: connected,
        color: color,
      ),
    ),
  );
}

class _WifiSignalPainter extends CustomPainter {
  const _WifiSignalPainter({
    required this.level,
    required this.enabled,
    required this.connected,
    required this.color,
  });

  /// `dockWifiSignalLevel` 的弧数（0-3）。
  final int level;
  final bool enabled;
  final bool connected;
  final Color color;

  // 20×20 逻辑画布常量（KOS bar/WifiSignalIcon.qml:29-71 逐值）。
  static const _center = Offset(10, 14.2);
  static const _dotCenter = Offset(10, 13.8);
  static const double _dotRadius = 1.15;
  static const double _arcStart = math.pi * 1.22;
  static const double _arcSweep = math.pi * 0.56; // 1.78π − 1.22π

  void _drawArcs(Canvas canvas, Paint paint, int count) {
    for (var ring = 0; ring < count; ring++) {
      final radius = 3.0 + ring * 2.7; // KOS :33
      canvas.drawArc(
        Rect.fromCircle(center: _center, radius: radius),
        _arcStart,
        _arcSweep,
        false,
        paint,
      );
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    // KOS: :46-47 — `ctx.scale(width/20, height/20)` + `translate(0,-1.1)`。
    canvas.save();
    canvas.scale(size.width / 20, size.height / 20);
    canvas.translate(0, -1.1);
    final stroke = Paint()
      ..color = color
      ..strokeWidth = kDockWifiGlyphLineWidth
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final fill = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    // KOS: :51-55 — 底层：全 3 弧 + 点，alpha `wifiEnabled ? 0.22 : 0.16`。
    final baseAlpha =
        enabled ? kDockWifiGlyphBaseAlphaOn : kDockWifiGlyphBaseAlphaOff;
    stroke.color = color.withValues(alpha: baseAlpha);
    _drawArcs(canvas, stroke, 3);
    fill.color = color.withValues(alpha: baseAlpha);
    canvas.drawCircle(_dotCenter, _dotRadius, fill);

    if (enabled) {
      // KOS: :57-62 — 顶层 alpha = `connected ? 1.0 : 0.52`，重画
      // signalLevel 弧 + 点。
      final litAlpha = connected
          ? kDockWifiGlyphLitAlpha
          : kDockWifiGlyphTopAlpha;
      stroke.color = color.withValues(alpha: litAlpha);
      _drawArcs(canvas, stroke, level);
      fill.color = color.withValues(alpha: litAlpha);
      canvas.drawCircle(_dotCenter, _dotRadius, fill);
    } else {
      // KOS: :63-71 — 关闭态斜线 (4,4.2)→(15.6,15.4) alpha .72。
      stroke.color = color.withValues(alpha: kDockWifiGlyphSlashAlpha);
      canvas.drawLine(const Offset(4, 4.2), const Offset(15.6, 15.4), stroke);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_WifiSignalPainter old) =>
      old.level != level ||
      old.enabled != enabled ||
      old.connected != connected ||
      old.color != color;
}

/// KOS `bar/StatusTooltip.qml` 的 OverlayPortal 移植：黑底 r7、内边距
/// h9/v6、主行 12px DemiBold + 副行 10px Medium 白字、行距 3、最小宽 150。
///
/// KOS 黑底白字是字面色（StatusTooltip.qml:41-63 `#000000`/`#ffffff`）——
/// 不属 shellTheme 语义色，但 CONSTRAINTS §3 要求走 token：此处用
/// `colors.background` 实心底 + `colors.textPrimary` 字（亮/暗主题各自收敛
/// 黑底白字观感，映射偏差记 docs/visual-deltas.md）。
class DockStatusTooltip extends StatelessWidget {
  const DockStatusTooltip({
    required this.primary,
    this.secondary,
    this.minWidth = kDockStatusTooltipMinWidth,
    super.key,
  });

  /// 主行（KOS `primaryText`，StatusTooltip.qml:15）。
  final String primary;

  /// 副行（KOS `secondaryText`，:16；null/空 → 不渲染副行，:59 `visible`
  /// 条件同式）。
  final String? secondary;

  /// 最小宽（KOS `minimumWidth`；状态格 150，控制中心格 92，见
  /// bar/ControlCenterToggle.qml:51）。
  final double minWidth;

  @override
  Widget build(BuildContext context) {
    final colors = context.shellColors;
    final hasSecondary = secondary != null && secondary!.isNotEmpty;
    return Container(
      // KOS: StatusTooltip.qml:23 — `max(minimumWidth, 内容宽+18)`。
      constraints: BoxConstraints(minWidth: minWidth),
      padding: const EdgeInsets.symmetric(
        horizontal: kDockStatusTooltipPaddingH,
        vertical: kDockStatusTooltipPaddingV,
      ),
      decoration: BoxDecoration(
        // KOS: :41-44 — 黑底 r7（语义映射见类注释）。
        color: colors.background,
        borderRadius: BorderRadius.circular(kDockStatusTooltipRadius),
        border: Border.all(color: colors.hairlineSoft),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            primary,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(
              // KOS: :51-56 — 12px DemiBold 白。
              fontSize: kDockStatusTooltipPrimarySize,
              fontWeight: FontWeight.w600,
              color: colors.textPrimary,
              height: 1.0,
            ),
          ),
          if (hasSecondary) ...[
            // KOS: :49 — `spacing: 3`。
            const SizedBox(height: kDockStatusTooltipRowGap),
            Text(
              secondary!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                // KOS: :57-63 — 10px Medium 白。
                fontSize: kDockStatusTooltipSecondarySize,
                fontWeight: FontWeight.w500,
                color: colors.textPrimary,
                height: 1.0,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Wi-Fi 状态格（KOS `bar/NetworkStatus.qml` wifi 分支）：26px 槽 +
/// 18px `DockWifiSignalIcon` + hover `DockStatusTooltip` + 点击 toggle 面板。
///
/// 状态映射（SDK 缺口逐条记 docs/visual-deltas.md）：
/// - `connectionType`/`connectivity`/`ipv4` SDK 无 → 只画 wifi 弧（以太网
///   `BundledIcon` 分支砍掉），tooltip 副行省略 IP/「需要网页登录认证」；
/// - `hasIssue` 徽标依赖 `connectivity` → 不画；
/// - busy（`scanning || radioChanging`）→ 格降透明度 .55（KOS toggle 中
///   opacity .55，NetworkPanel.qml:269,286 转引）。
class DockWifiCell extends StatefulWidget {
  const DockWifiCell({
    required this.enabled,
    required this.connected,
    required this.connecting,
    required this.strength,
    required this.busy,
    required this.tooltipPrimary,
    this.tooltipSecondary,
    required this.cursor,
    required this.onToggle,
    super.key,
  });

  /// `snapshot.wirelessEnabled`（KOS `wifiEnabled`）。
  final bool enabled;

  /// `snapshot.connectedNetwork != null`（KOS `deviceState==="connected"`）。
  final bool connected;

  /// `snapshot.status == connecting`（tooltip 主行「正在连接网络…」用）。
  final bool connecting;

  /// `snapshot.connectedNetwork?.strength ?? -1`。
  final int strength;

  /// `scanning || radioChanging`（格降透明度，KOS toggle 中 .55 语义）。
  final bool busy;

  /// tooltip 主/副行（调用方按 KOS `StatusTooltip` 文案规则组装；
  /// secondary=null → 省略副行）。
  final String tooltipPrimary;
  final String? tooltipSecondary;

  final MouseCursor cursor;

  /// 点击 → toggle Wi-Fi 面板（KOS `panelToggleRequested`，
  /// NetworkStatus.qml:91-98）。
  final VoidCallback onToggle;

  @override
  State<DockWifiCell> createState() => _DockWifiCellState();
}

class _DockWifiCellState extends State<DockWifiCell> {
  final _tooltip = OverlayPortalController();
  bool _hovered = false;

  void _setHovered(bool value) {
    if (_hovered == value) return;
    setState(() {
      _hovered = value;
      if (_hovered) {
        _tooltip.show();
      } else {
        _tooltip.hide();
      }
    });
  }

  @override
  void dispose() {
    if (_tooltip.isShowing) _tooltip.hide();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.shellColors;
    // KOS: bar/NetworkStatus.qml:65 — `statusIconOpacity × (connected ?
    // 0.96 : 0.68)`；busy 时乘 toggle .55（NetworkPanel.qml:269,286 转引）。
    final alpha =
        (widget.connected
                ? kDockWifiCellConnectedAlpha
                : kDockWifiCellIdleAlpha) *
            (widget.busy ? kDockWifiBusyOpacity : 1.0);
    return Semantics(
      button: true,
      label: widget.tooltipPrimary,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onToggle,
        child: MouseRegion(
          cursor: widget.cursor,
          onEnter: (_) => _setHovered(true),
          onExit: (_) => _setHovered(false),
          child: OverlayPortal.overlayChildLayoutBuilder(
            controller: _tooltip,
            // KOS: bar/StatusTooltip.qml:27-39 — bottom dock → edges/gravity
            // Top、margins.top −6（tooltip 底贴格顶 −6px）。
            overlayChildBuilder: (context, layout) {
              final anchor = MatrixUtils.transformRect(
                layout.childPaintTransform,
                Offset.zero & layout.childSize,
              );
              return Stack(
                children: [
                  Positioned(
                    bottom:
                        layout.overlaySize.height -
                        anchor.top +
                        kDockStatusTooltipGap,
                    left: 0,
                    right: 0,
                    child: Align(
                      alignment: Alignment.bottomCenter,
                      heightFactor: 1,
                      child: Transform.translate(
                        offset: Offset(
                          (anchor.center.dx -
                                  layout.overlaySize.width / 2)
                              .clamp(
                                -anchor.center.dx +
                                    kDockPopupEdgeMargin +
                                    kDockStatusTooltipMinWidth / 2,
                                anchor.center.dx -
                                    kDockPopupEdgeMargin -
                                    kDockStatusTooltipMinWidth / 2,
                              ),
                          0,
                        ),
                        child: DockStatusTooltip(
                          primary: widget.tooltipPrimary,
                          secondary: widget.tooltipSecondary,
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
            child: SizedBox.square(
              // KOS: bar/SysTray.qml:503-504 — 格占满 itemSize(26) 槽。
              dimension: kDockTrayItemSize,
              child: Center(
                child: Opacity(
                  opacity: alpha,
                  child: Transform.translate(
                    // KOS: bar/NetworkStatus.qml:55-56 — WifiSignalIcon
                    // `anchors.verticalCenterOffset: 2`。
                    offset: const Offset(0, kDockWifiCellIconOffsetY),
                    child: DockWifiSignalIcon(
                      enabled: widget.enabled,
                      connected: widget.connected,
                      strength: widget.strength,
                      color: colors.textPrimary,
                      // KOS: bar/NetworkStatus.qml:19 — 格内 iconSize 18。
                      size: kDockStatusCellIconSize,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// KOS `bar/NetworkStatus.qml:106-121` 的 tooltip 文案规则（纯函数，可测）。
///
/// primary：connected → SSID 或「Wi‑Fi」；否则 connecting→「正在连接网络…」
/// /「未连接网络」。secondary：connected→「已连接互联网」；否则省略（KOS 的
/// portal/none/ipv4/速率副行全部依赖 SDK 缺失字段，砍掉记 deltas）。
({String primary, String? secondary}) dockWifiTooltip({
  required bool connected,
  required bool connecting,
  required String? ssid,
}) {
  if (connected) {
    // KOS: :106-110 — 以太网分支砍掉（无 connectionType）；wifi → ssid。
    return (
      primary: (ssid != null && ssid.isNotEmpty) ? ssid : 'Wi-Fi',
      // KOS: :116-118 — `connectivity==="full" → 已连接 · ipv4`；SDK 无
      // ipv4/connectivity → 退化为「已连接互联网」（:119 else 分支）。
      secondary: '已连接互联网',
    );
  }
  return (
    primary: connecting ? '正在连接网络…' : '未连接网络',
    secondary: null,
  );
}


/// 手绘蓝牙 glyph（KOS `BluetoothPanel.qml:116-125` 的折线：`scale(0.67)`
/// 画布内 `M13.5,2.5 L20,9 L13.5,15 L20,21 L13.5,26.5 Z` +
/// `M7,8.5 L13.5,15 L7,21.5`，lineWidth 1.8 round cap/join）。
///
/// KOS 源画布是 18×18 上 `ctx.scale(0.67)` → 逻辑坐标系 ≈26.9px；本端
/// 以 `size/26.9` 等比缩放画同一折线。
class _BluetoothGlyphPainter extends CustomPainter {
  const _BluetoothGlyphPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.width / 26.9;
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.8
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    // KOS: bar/BluetoothPanel.qml:120-124 — 主折线 + 左斜横，同一 path。
    final path = Path()
      ..moveTo(13.5 * scale, 2.5 * scale)
      ..lineTo(20 * scale, 9 * scale)
      ..lineTo(13.5 * scale, 15 * scale)
      ..lineTo(20 * scale, 21 * scale)
      ..lineTo(13.5 * scale, 26.5 * scale)
      ..lineTo(13.5 * scale, 2.5 * scale)
      ..moveTo(7 * scale, 8.5 * scale)
      ..lineTo(13.5 * scale, 15 * scale)
      ..lineTo(7 * scale, 21.5 * scale);
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_BluetoothGlyphPainter old) => old.color != color;
}

/// 蓝牙面板行的共享 glyph 绘制（18×18，connected→accent）。
/// 与 [_BluetoothGlyphPainter] 同一折线；抽公共件给 `dock_bluetooth_panel.dart`
/// 与 TASK-09 控制中心复用。
class DockBluetoothGlyph extends StatelessWidget {
  const DockBluetoothGlyph({
    required this.color,
    this.size = kDockBluetoothRowGlyphSize,
    super.key,
  });

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) => CustomPaint(
    size: Size.square(size),
    painter: _BluetoothGlyphPainter(color: color),
  );
}

/// Wi-Fi 格 tooltip 的连接态判定工具：`NetworkConnectivityStatus.connecting`
/// → 「正在连接」。SDK `status` 比 KOS `deviceState` 粒度细
/// （local/limited/captivePortal/online）——本端只区分 connected
/// （`connectedNetwork != null`）与 connecting，其余档位折叠记 deltas。
bool dockWifiConnecting(NetworkConnectivityStatus status) =>
    status == NetworkConnectivityStatus.connecting;

// ══════════════════════════════════════════════════════════════════
// TASK-09：控制中心格
// ══════════════════════════════════════════════════════════════════

/// 控制中心格（KOS `bar/ControlCenterToggle.qml`）：26px 槽（格宽与其它状态
/// 格一致）+ 24×24 点击面 + 18px 双滑杆 glyph + hover tooltip「控制中心」+
/// 点击 toggle 控制中心面板。
///
/// 移植要点：
/// - 透明度 panelOpen 1.0 / 关 0.88（:31-33）；scale 按下 0.90 / hover 1.06 /
///   常态 1，Behavior `fastDuration`（135ms）OutCubic（:34-35）；
/// - tooltip「控制中心」minimumWidth 92，panelOpen 时不显示（:45-51）——面板
///   开合态经 [DockStatusPanelAnchorState.panelOpenOf] 读；
/// - glyph 是 KOS 工程图形 `BundledIcon("control-center")`（双滑杆 mark）：
///   Icons 无同款 → 本端自绘「两条滑杆 + 圆钮」近似，记
///   docs/visual-deltas.md；
/// - 点击 → `panelToggleRequested()`（:43）→
///   [DockStatusPanelAnchorState.togglePanelOf]。
///
/// clock 之外本格是唯一「恒显示」的状态格（无能力门控：面板是 Flutter 侧
/// 自绘，不依赖任何系统服务可用性）。
class DockControlCenterCell extends StatefulWidget {
  const DockControlCenterCell({
    required this.cursor,
    required this.onToggle,
    super.key,
  });

  final MouseCursor cursor;

  /// 点击 → toggle 控制中心面板（KOS `panelToggleRequested`）。
  final VoidCallback onToggle;

  @override
  State<DockControlCenterCell> createState() => _DockControlCenterCellState();
}

class _DockControlCenterCellState extends State<DockControlCenterCell> {
  final _tooltip = OverlayPortalController();
  bool _hovered = false;
  bool _pressed = false;

  void _setHovered(bool value) {
    if (_hovered == value) return;
    setState(() {
      _hovered = value;
      if (_hovered) {
        _tooltip.show();
      } else {
        _tooltip.hide();
      }
    });
  }

  void _setPressed(bool value) {
    if (_pressed == value) return;
    setState(() => _pressed = value);
  }

  @override
  void dispose() {
    if (_tooltip.isShowing) _tooltip.hide();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.shellColors;
    // KOS: bar/ControlCenterToggle.qml:47 — `panelOpen` 时 tooltip 不显示。
    final panelOpen = DockStatusPanelAnchorState.panelOpenOf(context);
    // KOS: :34 — `pressed ? 0.90 : containsMouse ? 1.06 : 1`。
    final scale = _pressed
        ? kDockControlCenterCellPressedScale
        : (_hovered ? kDockControlCenterCellHoverScale : 1.0);
    // KOS: :32-33 — `panelOpen ? 1.0 : 0.88`。
    final opacity = panelOpen
        ? kDockControlCenterCellOpenOpacity
        : kDockControlCenterCellClosedOpacity;
    return Semantics(
      button: true,
      label: kDockControlCenterTooltip,
      child: MouseRegion(
        cursor: widget.cursor,
        onEnter: (_) => _setHovered(true),
        onExit: (_) => _setHovered(false),
        child: Listener(
          onPointerDown: (_) => _setPressed(true),
          onPointerUp: (_) => _setPressed(false),
          onPointerCancel: (_) => _setPressed(false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onToggle,
            child: OverlayPortal.overlayChildLayoutBuilder(
              controller: _tooltip,
              // KOS: bar/StatusTooltip.qml:27-39 — bottom dock → 底边贴格顶
              // −6px（`kDockStatusTooltipGap`），屏内 clamp。
              overlayChildBuilder: (context, layout) {
                // panelOpen 时整只 tooltip 不渲染（KOS :47）。
                if (panelOpen) return const SizedBox.shrink();
                final anchor = MatrixUtils.transformRect(
                  layout.childPaintTransform,
                  Offset.zero & layout.childSize,
                );
                return Stack(
                  children: [
                    Positioned(
                      bottom:
                          layout.overlaySize.height -
                          anchor.top +
                          kDockStatusTooltipGap,
                      left: 0,
                      right: 0,
                      child: Align(
                        alignment: Alignment.bottomCenter,
                        heightFactor: 1,
                        child: Transform.translate(
                          offset: Offset(
                            (anchor.center.dx - layout.overlaySize.width / 2)
                                .clamp(
                                  -anchor.center.dx +
                                      kDockPopupEdgeMargin +
                                      kDockControlCenterTooltipMinWidth / 2,
                                  anchor.center.dx -
                                      kDockPopupEdgeMargin -
                                      kDockControlCenterTooltipMinWidth / 2,
                                ),
                            0,
                          ),
                          child: const DockStatusTooltip(
                            primary: kDockControlCenterTooltip,
                            minWidth: kDockControlCenterTooltipMinWidth,
                          ),
                        ),
                      ),
                    ),
                  ],
                );
              },
              child: SizedBox.square(
                // KOS: bar/SysTray.qml:503-504 — 格占满 itemSize(26) 槽。
                dimension: kDockTrayItemSize,
                child: Center(
                  child: AnimatedScale(
                    // KOS: :35 — `Behavior on scale` 135ms OutCubic。
                    scale: scale,
                    duration: kDockControlCenterCellDuration,
                    curve: Curves.easeOutCubic,
                    child: AnimatedOpacity(
                      // KOS: :36 — `Behavior on opacity` 135ms（默认线性）。
                      opacity: opacity,
                      duration: kDockControlCenterCellDuration,
                      curve: Curves.linear,
                      child: SizedBox.square(
                        // KOS: :18-19 — 24×24 点击面。
                        dimension: kDockControlCenterCellSize,
                        child: Center(
                          // KOS: :16,23-27 — BundledIcon(\"control-center\")
                          // 工程图形 18px，colorized 投成前景。Denial 无内联
                          // SVG 渲染：白描边 PNG asset + srcIn 投色等价于
                          // KOS MultiEffect colorization（见 assets/README.md）。
                          child: Image.asset(
                            'assets/icons/control-center.png',
                            package: 'kos_dock',
                            width: kDockControlCenterIconSize,
                            height: kDockControlCenterIconSize,
                            fit: BoxFit.contain,
                            filterQuality: FilterQuality.medium,
                            // 72² 白描边原图→18px 工程图形：按物理像素
                            // 预降采样 + medium 过滤，消边缘锯齿。乘满
                            // AnimatedScale hover 峰值，与 launcher/trash
                            // 的 cacheWidth 口径一致。
                            cacheWidth: (kDockControlCenterIconSize *
                                    kDockControlCenterCellHoverScale *
                                    MediaQuery.devicePixelRatioOf(context))
                                .ceil(),
                            color: colors.textPrimary,
                            colorBlendMode: BlendMode.srcIn,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
