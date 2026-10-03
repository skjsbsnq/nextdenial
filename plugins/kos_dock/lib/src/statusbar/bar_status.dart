import 'dart:math' as math;

import 'package:denial_flutter_sdk/popups.dart';
import 'package:denial_flutter_sdk/service_backends.dart';
import 'package:denial_flutter_sdk/services.dart';
import 'package:denial_flutter_sdk/state.dart';
import 'package:denial_flutter_sdk/theme.dart';
import 'package:denial_sdk/system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'bar_card.dart';

/// 电池 + 网络指示模块——顶栏右簇状态模块。
///
/// 复刻官方 `denial_top_bar` 的 `_BatteryActionCard`/`_BatteryModule`/
/// `_BatteryLevelPainter`（desktop_system_bar_components.dart:54-166/452-534）
/// 与 `_BatteryStatusCard`（desktop_system_bar_media.dart:31-45），并移植
/// NextKde `NetworkStatus.qml` + `WifiSignalIcon.qml` 的网络指示。私有
/// widget 跨包不可 import，按 TASK-TB-05 约束在本插件复写。
///
/// 与官方/源差异：
/// - `WallpaperAccent.captionColor` → `theme.colors.textSecondary`（胶囊走
///   dock/deskcenter 平填链，不用渐变卡；TASK-TB-05 钉死）；
/// - 网络状态走 `networkConnectivityProvider`（内部 state API），不连
///   NetworkManager daemon；NextKde 的 NetworkService/速率采样砍掉；
/// - 点击开占位弹层（`_showTopBarStatusPanel`），完整网络面板后续卡再填；
/// - 以太网图标未复用 NextKde `status-ethernet` SVG，改手绘
///   `_EthernetIconPainter`（RJ45 插头单色轮廓，上色走 `textPrimary`）。

// ──────────────────────────────── 电池 ────────────────────────────────

/// 电池状态壳：`ref.watch(battery)` + `capacity!=null` 门控 + `TopBarCard`
/// 包装（对应官方 `_BatteryStatusCard` + `_DesktopSystemBarContent` 里
/// `if (batteryVisible)` 装配段，desktop_system_bar.dart:46-50/104-118）。
///
/// `capacity==null` 时返回 `SizedBox.shrink()`——装配层直接内联即可，不
/// 留空胶囊。
class TopBarBatteryStatusModule extends ConsumerWidget {
  const TopBarBatteryStatusModule({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(context.telemetryServices.battery);
    if (status.capacity == null) {
      return const SizedBox.shrink();
    }
    return TopBarBatteryActionCard(
      status: status,
      onPressed: context.desktopServices.openPowerSettings,
    );
  }
}

/// 电池可点胶囊：`Semantics` + `InkWell` + `TopBarCard` 包电池表盘。
///
/// 复刻官方 `_BatteryActionCard`（desktop_system_bar_components.dart:54-110）：
/// `InkWell(borderRadius(999), linkCursor, NoSplash, overlayColor:
/// transparentDark)`，hover/focus 驱动 `TopBarCard.highlighted/focused`。
class TopBarBatteryActionCard extends StatefulWidget {
  const TopBarBatteryActionCard({
    required this.status,
    required this.onPressed,
    super.key,
  });

  final BatteryStatus status;
  final VoidCallback onPressed;

  @override
  State<TopBarBatteryActionCard> createState() =>
      _TopBarBatteryActionCardState();
}

class _TopBarBatteryActionCardState extends State<TopBarBatteryActionCard> {
  var _hovered = false;
  var _focused = false;

  @override
  Widget build(BuildContext context) {
    final strings = context.presentationServices.strings(context);
    final capacity = widget.status.capacity ?? 0;
    final state = widget.status.charging ? 'charging' : 'discharging';
    final statusLabel = strings.batteryLine(state, capacity);
    return Semantics(
      button: true,
      label: '${strings.batteryTitle}, $statusLabel',
      onTap: widget.onPressed,
      child: ExcludeSemantics(
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: context.shellTheme.borderRadius(999),
            mouseCursor: context.presentationServices.linkCursor,
            splashFactory: NoSplash.splashFactory,
            overlayColor: const WidgetStatePropertyAll<Color>(
              ShellMediaColors.transparentDark,
            ),
            onTap: widget.onPressed,
            onHover: (value) => setState(() => _hovered = value),
            onFocusChange: (value) => setState(() => _focused = value),
            child: TopBarCard(
              bare: true,
              highlighted: _hovered || _focused,
              focused: _focused,
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: TopBarBatteryModule(status: widget.status),
            ),
          ),
        ),
      ),
    );
  }
}

/// 电池表盘：NextKde `Battery.qml` 胶囊电芯（无数字百分比）。
///
/// 复刻 `Battery.qml` 的几何与配色（非官方 `_BatteryModule` 的
/// 「电芯+右对齐百分比」——用户要求去掉数字、换 NextKde 图标）：
/// - 18×18 盒内：左圆角矩轮廓 `max(12, size-2) × round(size*0.56)`、右正极柱
///   `max(1.5, size-轮廓宽) × max(3, size*0.20)`，描边/柱色 `textPrimary`；
/// - 电芯 `max(2,(轮廓宽-4)*level) × (轮廓高-4)`，色按 NextKde `fillColor`：
///   `>95` `#30d158` / `>=50` `textPrimary` / `>=15` `#ff9f0a` / `<15` `#ff453a`；
/// - 充电时轮廓中央 `⚡`（NextKde `boltColor`：50-95 档 `#ff9f0a`，余 `textPrimary`）。
/// 电芯宽度随 level 经 `TweenAnimationBuilder` 过渡（沿用官方 `Motion.pill`）。
class TopBarBatteryModule extends StatelessWidget {
  const TopBarBatteryModule({required this.status, super.key});

  final BatteryStatus status;

  /// NextKde `fillColor`（非 tint 模式）。
  static Color fillColor(int percent, Color foreground) {
    if (percent > 95) return const Color(0xff30d158);
    if (percent >= 50) return foreground;
    if (percent >= 15) return const Color(0xffff9f0a);
    return const Color(0xffff453a);
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.shellTheme;
    final capacity = status.capacity ?? 0;
    final level = (capacity / 100).clamp(0.0, 1.0).toDouble();
    final foreground = theme.colors.textPrimary;
    const size = 18.0;
    final outlineW = math.max(12.0, size - 2);
    final outlineH = math.max(8.0, (size * 0.56).roundToDouble());
    final nubW = math.max(1.5, size - outlineW);
    final nubH = math.max(3.0, size * 0.20);
    final boltColor = (capacity >= 50 && capacity <= 95)
        ? const Color(0xffff9f0a)
        : foreground;
    return SizedBox(
      width: size,
      height: size,
      child: TweenAnimationBuilder<double>(
        tween: Tween<double>(begin: 0.0, end: level),
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : Motion.pill,
        curve: Motion.standard,
        builder: (context, value, _) => Stack(
          alignment: Alignment.centerLeft,
          children: [
            // 电芯填充（在轮廓下层，垂直居中）。
            Positioned(
              left: 2,
              top: 0,
              bottom: 0,
              child: Center(
                child: Container(
                  width: value > 0
                      ? math.max(2.0, (outlineW - 4) * value)
                      : 0,
                  height: outlineH - 4,
                  decoration: BoxDecoration(
                    color: fillColor(capacity, foreground),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            ),
            // 轮廓（描边）。
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              child: Center(
                child: Container(
                  width: outlineW,
                  height: outlineH,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(3),
                    border: Border.all(color: foreground, width: 1.5),
                  ),
                ),
              ),
            ),
            // 正极柱。
            Positioned(
              left: outlineW,
              top: 0,
              bottom: 0,
              child: Center(
                child: Container(
                  width: nubW,
                  height: nubH,
                  decoration: BoxDecoration(
                    color: foreground,
                    borderRadius: BorderRadius.circular(1),
                  ),
                ),
              ),
            ),
            // 充电 ⚡（轮廓中央）。
            if (status.charging)
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                width: outlineW,
                child: Center(
                  child: Text(
                    '⚡',
                    style: TextStyle(
                      color: boltColor,
                      fontSize: math.max(7.0, size * 0.44),
                      fontWeight: FontWeight.bold,
                      height: 1.0,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ──────────────────────────────── 网络 ────────────────────────────────

/// 网络指示状态壳：`ref.watch(networkConnectivityProvider)` →
/// `NetworkSnapshot`；服务与 Wi-Fi 设备均不可用时返回 `SizedBox.shrink()`
/// （NextKde `visible: NetworkService.available` 语义；门控钉死见
/// TASK-TB-05「serviceAvailable==false && wifiDeviceAvailable==false 不渲
/// 染」）。
class TopBarNetworkStatusModule extends ConsumerWidget {
  const TopBarNetworkStatusModule({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final snapshot = ref.watch(networkConnectivityProvider).snapshot;
    if (!snapshot.serviceAvailable && !snapshot.wifiDeviceAvailable) {
      return const SizedBox.shrink();
    }
    return const TopBarNetworkActionCard();
  }
}

/// 网络可点胶囊：`Tooltip` + `InkWell` + `TopBarCard` 包 Wi-Fi/以太网
/// 图标。点击开占位弹层（`keyName` 去重，连点不叠层）。
class TopBarNetworkActionCard extends ConsumerStatefulWidget {
  const TopBarNetworkActionCard({super.key});

  @override
  ConsumerState<TopBarNetworkActionCard> createState() =>
      _TopBarNetworkActionCardState();
}

class _TopBarNetworkActionCardState
    extends ConsumerState<TopBarNetworkActionCard> {
  var _hovered = false;
  var _focused = false;

  void _openPanel() {
    // 底栏弹出：按钮全局 Rect 作锚点（同控制中心），面板从钮上方弹出；
    // barrierColor transparent——无 overview scrim 压暗（用户反馈灰屏）。
    final renderObject = context.findRenderObject();
    final anchor = renderObject is RenderBox && renderObject.hasSize
        ? renderObject.localToGlobal(Offset.zero) & renderObject.size
        : null;
    ref.read(shellPopupControllerProvider.notifier).show(
      debugLabel: 'kos_dock.network_panel',
      keyName: 'kos_dock.network_panel',
      barrierColor: Colors.transparent,
      builder: (popupContext, handle) => _TopBarNetworkPlaceholderPanel(
        onClose: handle.close,
        anchorRect: anchor,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = ref.watch(networkConnectivityProvider).snapshot;
    final strings = context.presentationServices.strings(context);
    final horizontal = context.isHorizontal;
    return Semantics(
      button: true,
      label: _networkTooltip(snapshot),
      onTap: _openPanel,
      child: ExcludeSemantics(
        child: Tooltip(
          message: _networkTooltip(snapshot),
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              borderRadius: context.shellTheme.borderRadius(999),
              mouseCursor: context.presentationServices.linkCursor,
              splashFactory: NoSplash.splashFactory,
              overlayColor: const WidgetStatePropertyAll<Color>(
                ShellMediaColors.transparentDark,
              ),
              onTap: _openPanel,
              onHover: (value) => setState(() => _hovered = value),
              onFocusChange: (value) => setState(() => _focused = value),
              // 整条玻璃裸排：bare 去独立胶囊底板，InkWell 圆角 hover 保留；
              // 网络图标盒子收窄水平内边距让条目更紧凑（NextKde 观感）。
              child: TopBarCard(
                bare: true,
                highlighted: _hovered || _focused,
                focused: _focused,
                padding: horizontal
                    ? const EdgeInsets.symmetric(horizontal: 4)
                    : const EdgeInsets.symmetric(vertical: 4),
                child: TopBarNetworkModule(snapshot: snapshot, strings: strings),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// NextKde `StatusTooltip` 单行等价物：已连接显示 SSID/有线，否则按
  /// `status` 给出连接中/未连接。SDK `ShellStrings` 无网络词条（TASK-TB-05
  /// 约束），caption 直接硬编码中文（插件 scope 内，conform CONSTRAINTS）。
  String _networkTooltip(NetworkSnapshot snapshot) {
    final connected = snapshot.connectedNetwork != null;
    if (connected) {
      final isEthernet = !snapshot.wirelessEnabled ||
          snapshot.connectedNetwork!.ssid.isEmpty;
      return isEthernet ? '有线网络' : snapshot.connectedNetwork!.ssid;
    }
    return switch (snapshot.status) {
      NetworkConnectivityStatus.connecting => '正在连接网络…',
      _ => '未连接网络',
    };
  }
}

/// 网络指示本体：`Size(23,20)` 盒内按介质渲染图标 + 受限黄点徽标。
///
/// 移植 NextKde `NetworkStatus.qml`：
/// - Wi-Fi → `WifiSignalIconPainter`（3 弧 + 底点，`strength` 0-100→0-3 格）；
/// - 有线（`connectedNetwork!=null` 且非无线链路）→ `_EthernetIconPainter`；
/// - `status ∈ {limited, captivePortal}` → 右下 6×6 `#ffb340` 圆点（NextKde
///   源值 `#ffb340`，保留作状态色并记入 visual-deltas）。
class TopBarNetworkModule extends StatelessWidget {
  const TopBarNetworkModule({
    required this.snapshot,
    required this.strings,
    super.key,
  });

  final NetworkSnapshot snapshot;
  final ShellStrings strings;
  bool get _isEthernet {
    final connected = snapshot.connectedNetwork;
    if (connected == null) {
      return false;
    }
    // `NetworkSnapshot` 无 wifi/ethernet 显式布尔：无线关闭时的已连接、或
    // 连接网络无 SSID（iwd 不给以太网 ssid）视为有线。
    return !snapshot.wirelessEnabled || connected.ssid.isEmpty;
  }
  /// NextKde `hasIssue` 双色：`connectivity==="none"`（受限）用 `#ff9f0a`、
  /// portal 用 `#ffb340`（NetworkStatus.qml:86）。`limited` 对应受限档。
  Color? get _warningColor => switch (snapshot.status) {
    NetworkConnectivityStatus.limited => const Color(0xffff9f0a),
    NetworkConnectivityStatus.captivePortal => const Color(0xffffb340),
    _ => null,
  };

  bool get _hasIssue => _warningColor != null;

  @override
  Widget build(BuildContext context) {
    final foreground = context.shellTheme.colors.textPrimary;
    return SizedBox(
      width: 23,
      height: 20,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            child: _isEthernet
                ? Center(
                    child: CustomPaint(
                      size: const Size(18, 18),
                      painter: EthernetIconPainter(
                        color: foreground,
                        opacity: 0.96,
                      ),
                    ),
                  )
                : Align(
                    // NextKde `anchors.verticalCenterOffset: 2`：glyph 在
                    // 20 高盒内下移 2px；水平居中于 23 宽盒。
                    alignment: const Alignment(0, 0.2),
                    child: CustomPaint(
                      size: const Size(18, 18),
                      painter: WifiSignalIconPainter(
                        wifiEnabled: snapshot.wirelessEnabled,
                        connected: snapshot.connectedNetwork != null,
                        signalStrength:
                            snapshot.connectedNetwork?.strength ?? -1,
                        glyphColor: foreground,
                      ),
                    ),
                  ),
          ),
          if (_hasIssue)
            Positioned(
              right: 0,
              bottom: 0,
              child: _WarningDot(color: _warningColor!),
            ),
        ],
      ),
    );
  }
}

/// 黄点徽标：6×6 圆 + 1px 深色描边（NextKde `border.color` 0.35 黑）。
class _WarningDot extends StatelessWidget {
  const _WarningDot({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 6,
      height: 6,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: const Color(0x59000000)),
      ),
    );
  }
}

/// Wi-Fi 信号 painter——移植 NextKde `WifiSignalIcon.qml`（QML Canvas →
/// `CustomPaint`）：3 条同心弧 + 底点；`wifiEnabled==false` 画斜线；
/// `connected` 决定实/空亮度；`signalStrength`（0-100）<30→1 / <60→2 /
/// ≥60→3 格。
@visibleForTesting
class WifiSignalIconPainter extends CustomPainter {
  const WifiSignalIconPainter({
    required this.wifiEnabled,
    required this.connected,
    required this.signalStrength,
    required this.glyphColor,
    this.lineWidth = 1.55,
  });

  final bool wifiEnabled;
  final bool connected;

  /// NextKde `signalStrength`（-1 = 无信号，0-100）。
  final int signalStrength;
  final Color glyphColor;
  final double lineWidth;

  /// 格数：0 = 关/未连接/无信号；1-3 = 信号强度档。
  int get signalLevel => !wifiEnabled || !connected || signalStrength < 0
      ? 0
      : (signalStrength < 30 ? 1 : (signalStrength < 60 ? 2 : 3));

  @override
  void paint(Canvas canvas, Size size) {
    // NextKde 几何基于 20×20 设计稿，居中顶部 +1.1 上移（`translate(0,-1.1)`
    // 在 scale 之后——x/y 均乘 size/20 后画笔落位）。
    final scale = math.min(size.width, size.height) / 20.0;
    canvas.save();
    canvas.scale(scale);
    canvas.translate(0, -1.1);


    void drawArcs(int count, double alpha) {
      final paint = Paint()
        ..color = glyphColor.withValues(alpha: alpha)
        ..style = PaintingStyle.stroke
        ..strokeWidth = lineWidth
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      for (var ring = 0; ring < count; ring += 1) {
        final radius = 3.0 + ring * 2.7;
        canvas.drawArc(
          Rect.fromCircle(center: const Offset(10, 14.2), radius: radius),
          math.pi * 1.22,
          math.pi * (1.78 - 1.22),
          false,
          paint,
        );
      }
    }

    void drawBaseDot(double alpha) {
      canvas.drawCircle(
        const Offset(10, 13.8),
        1.15,
        Paint()
          ..color = glyphColor.withValues(alpha: alpha)
          ..style = PaintingStyle.fill,
      );
    }

    // 底稿：全弧低亮度（开 0.22 / 关 0.16）+ 底点。
    drawArcs(3, wifiEnabled ? 0.22 : 0.16);
    drawBaseDot(wifiEnabled ? 0.22 : 0.16);

    if (wifiEnabled) {
      final alpha = connected ? 1.0 : 0.52;
      drawArcs(signalLevel, alpha);
      drawBaseDot(alpha);
    } else {
      // 斜线贯穿 glyph（开 0.72 alpha，NextKde 源值）。
      canvas.drawLine(
        const Offset(4.0, 4.2),
        const Offset(15.6, 15.4),
        Paint()
          ..color = glyphColor.withValues(alpha: 0.72)
          ..style = PaintingStyle.stroke
          ..strokeWidth = lineWidth
          ..strokeCap = StrokeCap.round,
      );
    }
    canvas.restore();

  }

  @override
  bool shouldRepaint(covariant WifiSignalIconPainter oldDelegate) {
    return oldDelegate.wifiEnabled != wifiEnabled ||
        oldDelegate.connected != connected ||
        oldDelegate.signalStrength != signalStrength ||
        oldDelegate.glyphColor != glyphColor ||
        oldDelegate.lineWidth != lineWidth;
  }
}

/// 以太网 painter——手绘 RJ45 插头单色轮廓（NextKde `status-ethernet`
/// BundledIcon 的等价物；SVG 资产留给 TASK-TB-06 的控制中心钮）。
@visibleForTesting
class EthernetIconPainter extends CustomPainter {
  const EthernetIconPainter({required this.color, required this.opacity});

  final Color color;

  /// 已连接 0.96 / 未连接 0.68（NextKde `opacity` 源值）。
  final double opacity;

  @override
  void paint(Canvas canvas, Size size) {
    final scale = math.min(size.width, size.height) / 20.0;
    final stroke = Paint()
      ..color = color.withValues(alpha: opacity)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final fill = Paint()
      ..color = color.withValues(alpha: opacity)
      ..style = PaintingStyle.fill;
    canvas.save();
    canvas.scale(scale);

    // 插头体（圆角矩 4.5..15.5 × 4..15）。
    final body = RRect.fromRectAndRadius(
      const Rect.fromLTRB(4.5, 4, 15.5, 15),
      const Radius.circular(2),
    );
    canvas.drawRRect(body, stroke);
    // 顶部卡扣凹槽。
    canvas.drawLine(const Offset(8, 4), const Offset(8, 6.5), stroke);
    canvas.drawLine(const Offset(10, 4), const Offset(10, 6.5), stroke);
    canvas.drawLine(const Offset(12, 4), const Offset(12, 6.5), stroke);
    // 底部线脚两点。
    canvas.drawCircle(const Offset(8, 13), 0.9, fill);
    canvas.drawCircle(const Offset(12, 13), 0.9, fill);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant EthernetIconPainter oldDelegate) {
    return oldDelegate.color != color || oldDelegate.opacity != opacity;
  }
}

/// 网络占位弹层：336 宽卡 + 「网络占位」标题——NextKde `NetworkPanel.qml`
/// 的壳，真实列表后续任务卡填充（TASK-TB-05 注意事项）。
///
/// 锚定（底栏版）：`anchorRect`（按钮全局 Rect）→ `Positioned`
/// `bottom: screenHeight - anchor.top + 4`（面板底边贴按钮顶，从底栏向上弹）、
/// `right: screenWidth - anchor.right`（clamp ≥8）；`anchorRect == null` 退化
/// `bottom: 64, right: 8`（底栏高度附近的右缘默认位）。
class _TopBarNetworkPlaceholderPanel extends StatelessWidget {
  const _TopBarNetworkPlaceholderPanel({
    required this.onClose,
    this.anchorRect,
  });

  final VoidCallback onClose;

  /// 触发按钮的全局 Rect；`null` 时退化到底栏右缘默认锚点。
  final Rect? anchorRect;

  @override
  Widget build(BuildContext context) {
    final theme = context.shellTheme;
    final screen = MediaQuery.sizeOf(context);
    final anchor = anchorRect;
    // 底栏向上弹：面板底边距 = 屏高 - 按钮顶 + 4px 间隙。
    final bottom = anchor != null ? (screen.height - anchor.top + 4) : 64.0;
    final right = anchor != null
        ? (screen.width - anchor.right).clamp(8.0, screen.width)
        : 8.0;
    return Stack(
      children: [
        Positioned(
          bottom: bottom,
          right: right,
          child: Material(
            type: MaterialType.transparency,
            child: Container(
              width: 336,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: theme.cardColor(
                  Theme.of(context).colorScheme.surfaceContainer,
                ),
                borderRadius: theme.borderRadius(20),
                border: Border.all(
                  color: Theme.of(
                    context,
                  ).colorScheme.outlineVariant.withValues(alpha: 0.65),
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '网络',
                    style: theme.text.systemBarValue.copyWith(
                      color: theme.colors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '网络设置面板占位（后续迭代填充 Wi-Fi 列表与开关）。',
                    style: theme.text.systemBarCaption.copyWith(
                      color: theme.colors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

extension _TopBarStatusContext on BuildContext {
  ShellTelemetryServices get telemetryServices => ShellServicesScope.of(this);
  ShellPresentationServices get presentationServices =>
      ShellServicesScope.of(this);
  ShellDesktopServices get desktopServices => ShellServicesScope.of(this);

  /// 顶栏主轴是否水平（PanelEdge.top/bottom → true）。`side` 由
  /// `KosTopBar` 经 `ShellServicesScope` 暴露不可行——从 `MediaQuery`
  /// 宽高比推断不可靠，这里用 `Panels`/surface 侧不可得时默认 true
  /// （顶栏场景 `PanelEdge.top` 钉死，见 CONSTRAINTS 布局钉死项）。
  bool get isHorizontal => true;
}
