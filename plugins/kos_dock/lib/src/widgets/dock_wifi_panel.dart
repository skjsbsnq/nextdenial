/// TASK-08 Wi-Fi 状态格面板（KOS `bar/NetworkPanel.qml`，310×365 r19）。
///
/// 移植要点（源根 `/home/wwt/文档/NextKde/shell/desktop/modules/`）：
/// - 骨架/动画/锚定走 `dock_status_panels.dart` 的共享
///   `DockStatusPanelAnchor`（PopupMotion 150ms OutCubic 开 / 140ms InCubic
///   关、scale 0.96→1、bottom dock 向上弹 8px，KOS NetworkPanel.qml:43-61 +
///   common/PopupMotion.qml + common/AppearanceTokens.qml:514-516）。
/// - 控件树：KOS 的头行/connectionCard 在源里 `visible:false` 已停用
///   （NetworkPanel.qml:231,297），v1 直接做 `networkListCard`
///   （:390-565）+ 任务卡要求的动态头行（开关球 32×32 r16，glyph 复用
///   `DockWifiSignalIcon` 20px，KOS :260-294）。
/// - 列表行：46px r10、hover textPrimary@0.12 110ms（:421-428）；✓19px
///   （仅 connected）、24×24 行内信号弧（**分档 <25/<50/≥50、半径
///   3.3+ring*2.7、圆心 (12,17.1)、点 (12,16.7) r1.4、lw1.9**——与格图标
///   阈值不同，:451-463）、secured 锁 8×11（:468-493）、SSID 12px
///   DemiBold（:494-510）。
/// - 点击行：KOS `showNetworkDialog`（:516）统一弹「加入」弹层——v1 最小
///   路径（任务卡）：connected 行点击直关弹层、saved/开放直连
///   `connect(net)`、加密无档弹密码框；enterprise/「已保存密码」/「忘记」
///   分支 SDK 无字段，砍掉记 docs/visual-deltas.md。
/// - 设置底脚：SDK 无 `settings.open` 等价物 → 禁用态（`onTap: null`），
///   记 deltas。
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:denial_flutter_sdk/services.dart' show ShellServices;
import 'package:denial_flutter_sdk/shell_theme.dart';
import 'package:denial_flutter_sdk/state.dart';
import 'package:denial_flutter_sdk/system_services.dart'
    show NetworkSnapshot, WifiNetwork, WifiSecurity;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../theme/dock_tokens.dart';
import 'dock_status_panels.dart';
import 'status_cells.dart';

/// 行内信号弧分档（纯函数，可测）：`<25→1`、`<50→2`、`≥50→3`、负值→0。
///
/// KOS: bar/NetworkPanel.qml:454-455 — `signalStrength < 25 ? 1 :
/// (signalStrength < 50 ? 2 : 3)`。**与格图标档（<30/<60）不同**，勿混用
/// `dockWifiSignalLevel`。
int dockWifiRowSignalRings(int strength) {
  if (strength < 0) return 0;
  if (strength < kDockWifiRowLevel1Max) return 1;
  if (strength < kDockWifiRowLevel2Max) return 2;
  return 3;
}

/// Wi-Fi 面板宿主：26px 格外包一层 anchor（格本体由 `DockTrayAccessory`
/// 传入 `DockWifiCell`，`onToggle` 绑 [DockStatusPanelAnchorState.
/// togglePanel]）。
class DockWifiPanelAnchor extends DockStatusPanelAnchor {
  const DockWifiPanelAnchor({
    required this.services,
    required super.coordinator,
    required super.child,
    super.key,
  });

  /// 宿主服务束（linkCursor/strings；面板数据源走全局
  /// `networkConnectivityProvider`）。
  final ShellServices services;

  @override
  double get panelWidth => kDockWifiPanelWidth;
  @override
  double get panelHeight => kDockWifiPanelHeight;
  @override
  double get panelRadius => kDockWifiPanelRadius;

  /// KOS: bar/NetworkPanel.qml:54-55 — dock bottom `margins.top: -8`。
  @override
  double get panelGap => kDockWifiPanelGap;

  /// KOS `open()`（NetworkPanel.qml:84-91）：`refreshWifiNetworks()` →
  /// SDK `scan()`（自身带 serviceAvailable/wirelessEnabled 门控与
  /// scanning busy 标记）。骨架无 `ref`，实际扫描由面板子树首帧在
  /// `ConsumerState.build` 内发一次（`_scanRequested` 去重）——
  /// `onOpened` 在 `portal.show()` 同步阶段回调、早于 overlay 首帧，
  /// 语义等价于 KOS open() 内联调用。
  @override
  void onOpened() {}

  @override
  Widget buildPanel(BuildContext context) => DockWifiPanel(services: services);

  @override
  State<DockWifiPanelAnchor> createState() => _DockWifiPanelAnchorState();
}

class _DockWifiPanelAnchorState
    extends DockStatusPanelAnchorState<DockWifiPanelAnchor> {}

/// Wi-Fi 面板内容（overlay 子树，`DockStatusPanelSurface` 玻璃卡片内）。
class DockWifiPanel extends ConsumerStatefulWidget {
  const DockWifiPanel({required this.services, super.key});

  final ShellServices services;

  @override
  ConsumerState<DockWifiPanel> createState() => _DockWifiPanelState();
}

class _DockWifiPanelState extends ConsumerState<DockWifiPanel> {
  @override
  Widget build(BuildContext context) {
    final net = ref.watch(networkConnectivityProvider);
    final snapshot = net.snapshot;
    final colors = context.shellColors;
    final theme = context.shellTheme;
    final enabled = snapshot.wirelessEnabled;
    final busy = net.scanning || net.radioChanging;

    return DockStatusPanelSurface(
      radius: kDockWifiPanelRadius,
      child: Padding(
        // KOS: NetworkPanel.qml:226-229 — Column `anchors.margins: 10`。
        padding: const EdgeInsets.all(kDockStatusPanelMargin),
        child: Column(
          children: [
            // 任务卡要求的动态头行（KOS 源头行 visible:false 停用；开关球
            // 几何复用 KOS :260-294 规格）。行高按开关球 32 + 上下间距。
            SizedBox(
              height: kDockWifiToggleSize + 8,
              child: Row(
                children: [
                  Text(
                    // KOS :236-247 停用头行的标题语义；关态换文案
                    // 「Wi‑Fi 已关闭」（:317 connectionCard 文案借用）。
                    enabled ? 'Wi-Fi' : 'Wi-Fi 已关闭',
                    maxLines: 1,
                    style: TextStyle(
                      // KOS: :243 — 16px Bold。
                      fontSize: kDockWifiPanelTitleSize,
                      fontWeight: FontWeight.w700,
                      color: colors.textPrimary,
                      height: 1.0,
                    ),
                  ),
                  const Spacer(),
                  _WifiToggleBall(
                    enabled: enabled,
                    busy: busy,
                    snapshot: snapshot,
                    cursor: widget.services.linkCursor,
                    accent: theme.accent,
                    onToggle: () => unawaited(
                      ref
                          .read(networkConnectivityProvider.notifier)
                          .setWirelessEnabled(!enabled),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 6),
            // networkListCard（KOS :390-399）：r19、填 textPrimary@0.08、
            // 1px 边（KOS rgba(0.74,0.95,1,.28) → hairlineSoft 语义映射）。
            Expanded(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(kDockWifiPanelRadius),
                  color: colors.textPrimary.withValues(
                    alpha: kDockStatusCardFillAlpha,
                  ),
                  border: Border.all(color: colors.hairlineSoft),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(kDockWifiPanelRadius),
                  child: Column(
                    children: [
                      // 列表/空态/行点击路径抽给 TASK-09 控制中心 wifi 子页
                      // 复用（同一 `DockWifiNetworkListBody`）。
                      Expanded(
                        child: DockWifiNetworkListBody(
                          services: widget.services,
                        ),
                      ),
                      // SDK 无 `settings.open` → 禁用底脚（记 deltas）。
                      DockStatusPanelFooter(
                        label: '无线局域网设置…',
                        onTap: null,
                        cursor: widget.services.linkCursor,
                      ),
                    ],
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

/// 头行开关球（KOS NetworkPanel.qml:260-294）：32×32 r16，开→亮底+accent
/// glyph、关→暗底+前景 glyph，toggle 中 opacity .55。
class _WifiToggleBall extends StatelessWidget {
  const _WifiToggleBall({
    required this.enabled,
    required this.busy,
    required this.snapshot,
    required this.cursor,
    required this.accent,
    required this.onToggle,
  });

  final bool enabled;
  final bool busy;
  final NetworkSnapshot snapshot;
  final MouseCursor cursor;
  final Color accent;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final colors = context.shellColors;
    final connected = snapshot.connectedNetwork != null;
    final strength = snapshot.connectedNetwork?.strength ?? -1;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: busy ? null : onToggle,
      child: MouseRegion(
        cursor: busy ? SystemMouseCursors.basic : cursor,
        child: Opacity(
          // KOS: :269,286 — `wifiToggleInProgress → opacity .55`。
          opacity: busy ? kDockWifiBusyOpacity : 1.0,
          child: Container(
            width: kDockWifiToggleSize,
            height: kDockWifiToggleSize,
            decoration: BoxDecoration(
              // KOS: :271-274 — 开 `#f7fbff`/rgba(0,0,0,.08)；关
              // rgba(1,1,1,.22)/rgba(0,0,0,.05) → 语义映射（亮态底用
              // surfaceContainerHighest 近似亮盘、暗态 tileOff；记 deltas）。
              color: enabled ? colors.surfaceContainerHighest : colors.tileOff,
              borderRadius: BorderRadius.circular(kDockWifiToggleSize / 2),
              // KOS: :276-277 — 1px 边 rgba(1,1,1,.28)/rgba(0,0,0,.10)
              // → hairlineSoft。
              border: Border.all(color: colors.hairlineSoft),
            ),
            child: Center(
              child: DockWifiSignalIcon(
                enabled: enabled,
                connected: connected,
                strength: strength,
                size: 20,
                // KOS: :288-290 — 开 `#0a84ff` → theme.accent；关玻璃
                // 墨色 → textPrimary。
                color: enabled ? accent : colors.textPrimary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Wi-Fi 列表行（46px r10）：✓ + 24px 信号弧 + 锁 + SSID。
///
/// KOS: bar/NetworkPanel.qml:421-516。抽公共件给 TASK-09 控制中心复用。
class DockWifiNetworkRow extends StatefulWidget {
  const DockWifiNetworkRow({
    required this.network,
    required this.busy,
    required this.cursor,
    required this.onTap,
    this.height = kDockStatusRowHeight,
    super.key,
  });

  final WifiNetwork network;

  /// `busyNetworks.contains(identity)`（连接中禁用点击，KOS
  /// `wifiConnectInProgress` 行级近似）。
  final bool busy;

  final MouseCursor cursor;
  final VoidCallback onTap;

  /// 行高（TASK-08 面板 46，KOS `NetworkPanel.qml:421`；控制中心 wifi 子页
  /// 42，KOS `ControlCenterPanel.qml:2109`）。
  final double height;

  @override
  State<DockWifiNetworkRow> createState() => _DockWifiNetworkRowState();
}

class _DockWifiNetworkRowState extends State<DockWifiNetworkRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.shellColors;
    final network = widget.network;
    final secured = switch (network.security) {
      WifiSecurity.open || WifiSecurity.owe => false,
      _ => true,
    };
    return MouseRegion(
      cursor: widget.busy ? SystemMouseCursors.basic : widget.cursor,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.busy ? null : widget.onTap,
        child: AnimatedContainer(
          // KOS: :424-428 — hover 填 rgba(1,1,1,.12) 110ms ColorAnimation。
          duration: kDockStatusRowHoverDuration,
          height: widget.height,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(kDockStatusRowRadius),
            color: _hovered
                ? colors.textPrimary.withValues(
                    alpha: kDockStatusRowHoverAlpha,
                  )
                : const Color(0x00000000),
          ),
          child: Stack(
            children: [
              if (network.connected)
                const Positioned(
                  // KOS: :430-438 — ✓ 19px DemiBold、left 8 居中。
                  left: 8,
                  top: 0,
                  bottom: 0,
                  width: kDockWifiRowCheckSize,
                  child: Center(
                    child: _RowCheck(),
                  ),
                ),
              Positioned(
                // KOS: :449-451 — 24×24 弧图标、left 32 居中。
                left: kDockWifiRowGlyphLeft,
                top: 0,
                bottom: 0,
                child: Center(
                  child: CustomPaint(
                    size: const Size.square(kDockWifiRowGlyphSize),
                    painter: _WifiRowGlyphPainter(
                      rings: dockWifiRowSignalRings(network.strength),
                      color: colors.textPrimary,
                    ),
                  ),
                ),
              ),
              if (secured)
                Positioned(
                  // KOS: :471-474 — 8×11 锁、紧随弧右 +1 居中。
                  left:
                      kDockWifiRowGlyphLeft +
                      kDockWifiRowGlyphSize +
                      kDockWifiRowLockGap,
                  top: 0,
                  bottom: 0,
                  child: Center(
                    child: CustomPaint(
                      size: const Size(
                        kDockWifiRowLockWidth,
                        kDockWifiRowLockHeight,
                      ),
                      painter: _WifiLockPainter(color: colors.textPrimary),
                    ),
                  ),
                ),
              Positioned(
                // KOS: :497-504 — SSID 12px DemiBold elide；leftMargin
                // secured?73:64、rightMargin 12。
                left: secured
                    ? kDockWifiRowLabelLeftLocked
                    : kDockWifiRowLabelLeft,
                right: kDockWifiRowLabelRight,
                top: 0,
                bottom: 0,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    network.ssid.isEmpty ? 'Wi-Fi' : network.ssid,
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

class _RowCheck extends StatelessWidget {
  const _RowCheck();

  @override
  Widget build(BuildContext context) => Text(
    '✓',
    style: TextStyle(
      // KOS: :434-437 — 19px DemiBold 前景。
      fontSize: kDockWifiRowCheckSize,
      fontWeight: FontWeight.w600,
      color: context.shellColors.textPrimary,
      height: 1.0,
    ),
  );
}

/// 行内 24×24 信号弧（**阈值 <25/<50/≥50**，与格图标不同）。
///
/// KOS: bar/NetworkPanel.qml:451-463 — 圆心 (12,17.1)、半径 3.3+ring*2.7、
/// 弧角 π*1.22→π*1.78、点 (12,16.7) r1.4、lw1.9、alpha .92。
class _WifiRowGlyphPainter extends CustomPainter {
  const _WifiRowGlyphPainter({required this.rings, required this.color});

  final int rings;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color.withValues(alpha: 0.92)
      ..strokeWidth = 1.9
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    for (var ring = 0; ring < rings; ring++) {
      canvas.drawArc(
        Rect.fromCircle(
          center: const Offset(12, 17.1),
          radius: 3.3 + ring * 2.7,
        ),
        math.pi * 1.22,
        math.pi * 0.56,
        false,
        paint,
      );
    }
    canvas.drawCircle(
      const Offset(12, 16.7),
      1.4,
      Paint()
        ..color = color.withValues(alpha: 0.92)
        ..style = PaintingStyle.fill,
    );
  }

  @override
  bool shouldRepaint(_WifiRowGlyphPainter old) =>
      old.rings != rings || old.color != color;
}

/// 行内 8×11 锁形（KOS 手绘锁，:474-493——CJK 字体缺锁 glyph 故自绘）。
class _WifiLockPainter extends CustomPainter {
  const _WifiLockPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final sx = size.width / 8;
    final sy = size.height / 11;
    canvas.scale(sx, sy);
    final stroke = Paint()
      ..color = color.withValues(alpha: 0.82)
      ..strokeWidth = 1.2 / math.min(sx, sy)
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    // KOS: :482-484 — 锁梁弧 `arc(4,4.7,2.35, 1.12π,1.88π)`。
    canvas.drawArc(
      Rect.fromCircle(center: const Offset(4, 4.7), radius: 2.35),
      math.pi * 1.12,
      math.pi * 0.76,
      false,
      stroke,
    );
    // KOS: :485 — 锁体 `fillRect(0.7,4.8,6.6,5.5)`。
    canvas.drawRect(
      const Rect.fromLTWH(0.7, 4.8, 6.6, 5.5),
      Paint()
        ..color = color.withValues(alpha: 0.82)
        ..style = PaintingStyle.fill,
    );
    // KOS: :486-489 — 钥匙孔 `rgba(0,0,0,0.28)`（KOS 字面量，非 shellTheme
    // 角色：它是打在浅色锁体上的镂空点，取黑色同 alpha 而非前景色）。
    canvas.drawCircle(
      const Offset(4, 7.3),
      0.75,
      Paint()
        ..color = Colors.black.withValues(
          alpha: kDockWifiLockKeyholeAlpha,
        )
        ..style = PaintingStyle.fill,
    );
  }

  @override
  bool shouldRepaint(_WifiLockPainter old) => old.color != color;
}

/// 「加入 SSID」密码/确认弹层（KOS `KosFloatPanel` :571-882 的 v1 最小
/// 路径）：宽 `min(420, w-44)`、高 `min(292, h-40)`、取消/确认环 30×30、
/// 58×48 蓝色三弧 logo、标题 18px Bold + 说明 14px、密码框 r14 高 42、
/// 错误行 12px；回车提交（:776）。
///
/// v1 只做：active 网络说明态、加密无档密码输入；enterprise/「已保存
/// 密码」/「忘记」分支 SDK 无字段 → 砍掉记 deltas。
class DockWifiPasswordDialog extends StatefulWidget {
  const DockWifiPasswordDialog({
    required this.network,
    required this.requiresPassword,
    required this.cursor,
    required this.onConnect,
    super.key,
  });

  final WifiNetwork network;

  /// 加密无档 → 显示密码框（KOS `secured && !useSavedCredentials` 分支）。
  final bool requiresPassword;

  final MouseCursor cursor;

  /// 确认回调（`controller.connect(network, password:)`）。
  final void Function(String? password) onConnect;

  @override
  State<DockWifiPasswordDialog> createState() =>
      _DockWifiPasswordDialogState();
}

class _DockWifiPasswordDialogState extends State<DockWifiPasswordDialog> {
  final _password = TextEditingController();
  final _passwordFocus = FocusNode();
  String? _error;

  @override
  void initState() {
    super.initState();
    // KOS: :884-898 — `passwordFocusTimer` 16ms 后聚焦密码框（secured &&
    // !active && !useSavedCredentials 分支）。
    if (widget.requiresPassword && !widget.network.connected) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _passwordFocus.requestFocus();
      });
    }
  }

  @override
  void dispose() {
    _password.dispose();
    _passwordFocus.dispose();
    super.dispose();
  }

  void _confirm() {
    if (widget.network.connected) {
      // KOS `confirmConnection` :184-188 — active 网络确认=关弹层。
      Navigator.of(context).maybePop();
      return;
    }
    if (widget.requiresPassword && _password.text.isEmpty) {
      // KOS: :193-196 — `请输入 Wi‑Fi 密码`。
      setState(() => _error = '请输入 Wi-Fi 密码');
      _passwordFocus.requestFocus();
      return;
    }
    setState(() => _error = null);
    widget.onConnect(widget.requiresPassword ? _password.text : null);
    Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.shellColors;
    final theme = context.shellTheme;
    final network = widget.network;
    final size = MediaQuery.sizeOf(context);
    final width = math.min(
      kDockWifiDialogWidth,
      size.width - kDockWifiDialogScreenInset,
    );
    final height = math.min(
      kDockWifiDialogHeight,
      size.height - kDockWifiDialogHeightInset,
    );
    // KOS: :653-666 — 说明文案分态（v1 无 enterprise/useSavedCredentials）。
    final body = network.connected
        ? '当前已连接此无线局域网。'
        : (widget.requiresPassword ? '输入密码加入此无线局域网。' : '加入此无线局域网。');
    return Center(
      child: DockStatusPanelSurface(
        radius: kDockWifiPanelRadius,
        child: SizedBox(
          width: width,
          height: height,
          child: Stack(
            children: [
              // 取消环（KOS :606-611 — 30×30 left/top 13/12、「×」22px
              // Light）。
              Positioned(
                left: kDockWifiDialogRingMarginH,
                top: kDockWifiDialogRingMarginTop,
                child: _DialogRing(
                  glyph: '×',
                  glyphSize: 22,
                  cursor: widget.cursor,
                  onTap: () => Navigator.of(context).maybePop(),
                ),
              ),
              // 确认环（KOS :616-625 — ✓ 18px Light，busy 时「…」+禁用）。
              Positioned(
                right: kDockWifiDialogRingMarginH,
                top: kDockWifiDialogRingMarginTop,
                child: _DialogRing(
                  glyph: '✓',
                  glyphSize: 18,
                  cursor: widget.cursor,
                  onTap: _confirm,
                ),
              ),
              // 蓝色三弧 logo（KOS :627-641 — 58×48、`#0a84ff` lw6.5）。
              Positioned(
                top: kDockWifiDialogGlyphTop,
                left: 0,
                right: 0,
                child: Center(
                  child: CustomPaint(
                    size: const Size(
                      kDockWifiDialogGlyphWidth,
                      kDockWifiDialogGlyphHeight,
                    ),
                    painter: _JoinWifiGlyphPainter(color: theme.accent),
                  ),
                ),
              ),
              Positioned(
                // KOS: :648 — `top: joinWifiGlyph.bottom + 10` = 43+48+10；
                // 左右 margin 22。
                top:
                    kDockWifiDialogGlyphTop +
                    kDockWifiDialogGlyphHeight +
                    10,
                left: kDockWifiDialogSidePadding,
                right: kDockWifiDialogSidePadding,
                bottom: kDockWifiDialogSidePadding,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '加入 “${network.ssid.isEmpty ? 'Wi-Fi' : network.ssid}”',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        // KOS: :653-658 — 18px Bold。
                        fontSize: kDockWifiDialogTitleSize,
                        fontWeight: FontWeight.w700,
                        color: colors.textPrimary,
                        height: 1.0,
                      ),
                    ),
                    const SizedBox(height: 9),
                    Text(
                      body,
                      style: TextStyle(
                        // KOS: :663-666 — 14px 次级前景。
                        fontSize: kDockWifiDialogBodySize,
                        color: colors.textSecondary,
                        height: 1.3,
                      ),
                    ),
                    if (widget.requiresPassword && !network.connected) ...[
                      const SizedBox(height: 9),
                      // 凭证框（KOS :724-804 — r14、42px、聚焦 1px 蓝边
                      // rgba(0.15,0.52,1,.80) → accent@0.80）。
                      AnimatedContainer(
                        duration: kDockStatusRowHoverDuration,
                        height: kDockWifiDialogFieldHeight,
                        decoration: BoxDecoration(
                          color: colors.tileOff,
                          borderRadius: BorderRadius.circular(
                            kDockWifiDialogFieldRadius,
                          ),
                          border: Border.all(
                            color: _passwordFocus.hasFocus
                                ? theme.accent.withValues(
                                    alpha: kDockWifiDialogFocusAlpha,
                                  )
                                : colors.hairlineSoft,
                          ),
                        ),
                        padding: const EdgeInsets.symmetric(horizontal: 14),
                        child: Focus(
                          onFocusChange: (_) => setState(() {}),
                          child: EditableText(
                            controller: _password,
                            focusNode: _passwordFocus,
                            // KOS: :759 — `echoMode: Password`。
                            obscureText: true,
                            style: TextStyle(
                              fontSize: kDockWifiDialogBodySize,
                              color: colors.textPrimary,
                              height: 1.3,
                            ),
                            cursorColor: theme.accent,
                            backgroundCursorColor: colors.hairline,
                            selectionColor: theme.accentPalette.selection,
                            // KOS: :776 — 回车提交。
                            onSubmitted: (_) => _confirm(),
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        // KOS: :864-870 — 「密码将由 NetworkManager 安全
                        // 保存。」13px 三级前景。
                        '密码将由 NetworkManager 安全保存。',
                        style: TextStyle(
                          fontSize: 13,
                          color: colors.textTertiary,
                          height: 1.3,
                        ),
                      ),
                    ],
                    if (_error != null) ...[
                      const SizedBox(height: 6),
                      Text(
                        _error!,
                        style: TextStyle(
                          // KOS: :872-879 — 12px `#ff6b61` →
                          // performanceBad 语义映射（记 deltas）。
                          fontSize: kDockWifiDialogErrorSize,
                          color: colors.performanceBad,
                          height: 1.3,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 弹层角落圆环钮（取消/确认共用）：30×30 圆 + 1px 边 + 字。
class _DialogRing extends StatelessWidget {
  const _DialogRing({
    required this.glyph,
    required this.glyphSize,
    required this.cursor,
    required this.onTap,
  });

  final String glyph;
  final double glyphSize;
  final MouseCursor cursor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.shellColors;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: MouseRegion(
        cursor: cursor,
        child: Container(
          // KOS: NetworkPanel.qml:606-611 — 30×30 r15、contentControlFill
          // → tileOff、边 hairlineSoft。
          width: kDockWifiDialogRingSize,
          height: kDockWifiDialogRingSize,
          decoration: BoxDecoration(
            color: colors.tileOff,
            shape: BoxShape.circle,
            border: Border.all(color: colors.hairlineSoft),
          ),
          child: Center(
            child: Text(
              glyph,
              style: TextStyle(
                fontSize: glyphSize,
                fontWeight: FontWeight.w300,
                color: colors.textPrimary,
                height: 1.0,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 「加入」弹层顶部 58×48 蓝色三弧 logo。
///
/// KOS: NetworkPanel.qml:627-641 — `strokeStyle #0a84ff`、lw6.5；三弧圆心
/// (w/2, 28/33/38)、半径 21/12/3、弧角 1.18π→1.82π / 1.20π→1.80π /
/// 1.23π→1.77π。色 → theme.accent（记 deltas）。
class _JoinWifiGlyphPainter extends CustomPainter {
  const _JoinWifiGlyphPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final sx = size.width / 58;
    final sy = size.height / 48;
    final paint = Paint()
      ..color = color
      ..strokeWidth = 6.5 * math.min(sx, sy)
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    void arc(double cy, double r, double start, double sweep) {
      canvas.drawArc(
        Rect.fromCircle(center: Offset(size.width / 2, cy * sy), radius: r * sx),
        start,
        sweep,
        false,
        paint,
      );
    }

    arc(28, 21, math.pi * 1.18, math.pi * 0.64);
    arc(33, 12, math.pi * 1.20, math.pi * 0.60);
    arc(38, 3, math.pi * 1.23, math.pi * 0.54);
  }

  @override
  bool shouldRepaint(_JoinWifiGlyphPainter old) => old.color != color;
}

/// Wi-Fi 网络列表体（KOS `bar/NetworkPanel.qml` 的 `networkListCard` v1 路径）：
/// TASK-08 面板与 TASK-09 控制中心 wifi 子页共用同一份列表/空态/行点击路径。
///
/// - 首帧对当前会话发一次 `scan()`（KOS `open()` → `refreshWifiNetworks()`，
///   NetworkPanel.qml:84-91；控制中心 `openSubmenu("wifi")` 同语义，
///   ControlCenterPanel.qml:96-98）；
/// - 空态（KOS :519-536「正在扫描…」/「未发现可用 Wi-Fi」；关态复用）；
/// - 行点击路径（KOS `showNetworkDialog` :516 的 v1 最小分支）：connected →
///   说明弹层；saved/开放 → `connect` 直连；加密无档 → 密码框；
///   enterprise → SDK 无 username 域，按 connect 直投（由 SDK 报错，记
///   docs/visual-deltas.md）。
class DockWifiNetworkListBody extends ConsumerStatefulWidget {
  const DockWifiNetworkListBody({
    required this.services,
    this.rowHeight = kDockStatusRowHeight,
    this.padding = const EdgeInsets.fromLTRB(
      kDockStatusListMargin,
      kDockStatusListMargin,
      kDockStatusListMargin,
      0,
    ),
    super.key,
  });

  final ShellServices services;

  /// 行高（TASK-08 面板 46；控制中心 wifi 子页 42，KOS
  /// bar/ControlCenterPanel.qml:2109）。
  final double rowHeight;

  /// 列表内边距（KOS NetworkPanel.qml:412-417 `8/8/8/0`；控制中心子页
  /// `8/2/8/0`，ControlCenterPanel.qml:2088-2100）。
  final EdgeInsets padding;

  @override
  ConsumerState<DockWifiNetworkListBody> createState() =>
      _DockWifiNetworkListBodyState();
}

class _DockWifiNetworkListBodyState
    extends ConsumerState<DockWifiNetworkListBody> {
  bool _scanRequested = false;

  /// KOS `open()` 内的 `NetworkService.refreshWifiNetworks()`
  /// （NetworkPanel.qml:88-91）——列表首帧对当前会话发一次 scan；SDK
  /// `scan()` 自身做 wifiEnabled/权限/scanning 门控，重复调用安全。
  void _requestScanOnce() {
    if (_scanRequested) return;
    _scanRequested = true;
    // build 内不得改 provider（riverpod assert）——推迟到帧后；KOS `open()`
    // 的同步 refresh 语义在 overlay 首帧之后执行等价。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(networkConnectivityProvider.notifier).scan();
    });
  }

  @override
  Widget build(BuildContext context) {
    _requestScanOnce();
    final net = ref.watch(networkConnectivityProvider);
    final snapshot = net.snapshot;
    final enabled = snapshot.wirelessEnabled;
    // KOS: NetworkPanel.qml:420 — `model: wifiEnabled ? nearbyWifi : []`；
    // 关态列表清空（空态文案见下）。
    final networks = enabled ? snapshot.networks : const <WifiNetwork>[];
    if (!enabled || networks.isEmpty) {
      // KOS :519-536 — 扫描中「正在扫描…」/ 否则「未发现可用 Wi‑Fi」；
      // 关态时 KOS 列表 model 为空且无专属空态（connectionCard 停用后
      // 无提示），本端复用「未发现」档并记 deltas。
      return DockStatusPanelEmptyLabel(
        !enabled
            ? 'Wi-Fi 已关闭'
            : (net.scanning ? '正在扫描…' : '未发现可用 Wi-Fi'),
      );
    }
    // KOS: :412-420 — ListView margins、spacing 2。
    return ListView.separated(
      padding: widget.padding,
      itemCount: networks.length,
      separatorBuilder: (_, _) =>
          const SizedBox(height: kDockStatusRowSpacing),
      itemBuilder: (context, index) {
        final network = networks[index];
        return DockWifiNetworkRow(
          network: network,
          busy: net.busyNetworks.contains(network.identity),
          cursor: widget.services.linkCursor,
          height: widget.rowHeight,
          onTap: () => _onNetworkTapped(network),
        );
      },
    );
  }

  /// KOS `showNetworkDialog`（NetworkPanel.qml:120-135,516）的 v1 最小
  /// 路径：connected → 仅弹层确认（直连关）；saved/开放 → `connect` 直连；
  /// 加密无档 → 密码弹层。enterprise/忘记分支 SDK 无字段，砍掉记 deltas。
  void _onNetworkTapped(WifiNetwork network) {
    final controller = ref.read(networkConnectivityProvider.notifier);
    if (network.connected) {
      // KOS 弹层对 active 网络显示「当前已连接此无线局域网。」（:659-660）
      // ——v1 弹同一弹层的「已连接」说明态，确认=关闭。
      _showPasswordDialog(network, requiresPassword: false);
      return;
    }
    if (!network.security.requiresPassword || network.saved) {
      // 开放/OWE/已保存档直连（KOS `connectWifi(ssid, "", uuid)` :208）。
      unawaited(controller.connect(network));
      return;
    }
    if (network.security == WifiSecurity.enterprise ||
        !network.connectable) {
      // 802.1X / 不可建档：SDK 无 enterprise 连接入口 → 不弹密码框，
      // connect 会直接被拒；记 deltas，仍走 connect 让 SDK 报 error。
      unawaited(controller.connect(network));
      return;
    }
    _showPasswordDialog(network, requiresPassword: true);
  }

  void _showPasswordDialog(
    WifiNetwork network, {
    required bool requiresPassword,
  }) {
    unawaited(
      showGeneralDialog<void>(
        context: context,
        barrierDismissible: true,
        barrierLabel: 'Wi-Fi',
        // KOS: KosFloatPanel modal 居中 + `backdropMode:"none"`
        // （NetworkPanel.qml:574-577）——modal 但背板透明、点击不关
        // （`dismissOnBackdrop:false`）；Flutter 侧 barrierDismissible
        // 语义偏差记 deltas。
        barrierColor: Colors.transparent,
        transitionDuration: kDockMenuOpenDuration,
        pageBuilder: (context, _, _) => DockWifiPasswordDialog(
          network: network,
          requiresPassword: requiresPassword,
          cursor: widget.services.linkCursor,
          onConnect: (password) => unawaited(
            ref
                .read(networkConnectivityProvider.notifier)
                .connect(network, password: password),
          ),
        ),
      ),
    );
  }
}
