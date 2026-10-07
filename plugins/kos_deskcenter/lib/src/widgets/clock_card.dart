/// KOS DeskCenter 时钟小部件（`KosClockCard`）。
///
/// 对齐 NextKde `DeskCenterWindow.qml` 的 clock 分支（Loader :608-706 的
/// clockPage Item，含 Canvas 表盘 :630-706）。源文件中计时器子页
/// （timerPage，:737-895）按任务卡约定后置，不在本卡实现。
///
/// 结构（对齐 :612-735 clockPage）：
/// - `CustomPaint` 表盘占满卡面，四周留 14px 边距（:632-633
///   `anchors.fill: parent; anchors.margins: 14`）；
/// - 表盘几何/颜色逐项复刻 :634-691 的 Canvas onPaint 脚本；
/// - 外卡片为 flowerShaped tonal 表面（DeskCenterWindow.qml:470
///   `flowerShapedSurface: modelData.id === "clock"`，花形仅在 tonal
///   生效——DeskWidgetCard.qml:43-44，见 desk_card.dart `_flowerShapedEffective`）。
///
/// 数据：`services.telemetry.clock`（`AsyncValue<DateTime>`，对齐
/// `denial_top_bar` 的 `ref.watch(context.telemetryServices.clock)`，
/// desktop_system_bar_media.dart:132-134）或构造注入
/// `ProviderListenable<AsyncValue<DateTime>>`；测试注入常数
/// `Provider<AsyncValue<DateTime>>` 即可。AsyncValue 无值时回退
/// `DateTime.now()`（对齐 denial_desktop `ref.watch(clockProvider).value ??
/// DateTime.now()`，lock_screen_pane.dart:100）。
///
/// 源文件行号均指 `/home/wwt/文档/NextKde/shell/desktop/modules/` 相对路径。
library;

import '../theme/backdrop_content.dart';

import 'dart:async';
import 'dart:math' as math;

import 'package:denial_flutter_sdk/services.dart';
import 'package:denial_flutter_sdk/shell_theme.dart'
    show ShellThemeBuildContext, ShellThemeData;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;

import '../layout/widget_layout.dart' show WidgetSize;
import 'desk_card.dart';

/// 打开计时器子页的回调（对应源 :732 `root.timerView = true`）。
/// 本卡不做计时器子页（任务卡约定后置），保留回调位供 TASK-05/后续接线。
typedef KosClockTimerCallback = void Function();

/// 时钟卡片内容色板。对应源 `AppearanceTokens.content.ink/accent` 在该卡上的
/// 解析结果。TASK-09 起卡片统一吃 Denial ShellTheme 材质（不再有
/// tonal/glass 分叉），色板按 [Brightness] 取：dark → 白系 ink/numeral/
/// hands；light → 深色系（源 ownColor 浅板可读值）。faceFill 白底盘与
/// faceRing 外环均不绘制（均仅色艺/非 material 形态使用）。
final class KosClockColors {
  const KosClockColors({
    this.faceFill = const Color(0xFFFAFAFA), // :647 \"#fafafa\"（色艺遗留）
    this.faceRing = const Color(0x6BDEDEDE), // :651 ink(\"#dedede\",0.42)（遗留）
    this.ink = const Color(0xFF171717), // :655 ink(\"#171717\") ownColor
    this.numeral = const Color(0xFF242126), // :669 ink(\"#242126\") ownColor
    this.hourHand = const Color(0xFF6750A4), // :684 colors.primary（基线回退）
    this.minuteHand = const Color(0xFF625B71), // :687 colors.tertiary（基线回退）
    this.secondHand = const Color(0xFFEE7659), // :689 accent(...,\"#ee7659\")
    this.hub = const Color(0xFFEE7659), // :690 accent(primary,\"#ee7659\")→ink
    this.timerIcon = const Color(0xFF171717), // 倒计时图标 ink
  });

  /// 透明桌面材质采用 NextKde 白色 backdrop ink；不透明模式采用壳色板。
  /// 此解析只影响卡片内容，不修改详情面板、菜单或卡片表面材质。
  static KosClockColors forShell(ShellThemeData theme) {
    if (usesBackdropInk(theme) || theme.brightness == Brightness.dark) {
      return const KosClockColors(
        faceRing: Color(0x6BFFFFFF), // :651 glassContentColor(0.42)
        ink: Color(0xFFFFFFFF), // :655 glassContentColor()
        numeral: Color(0xFFFFFFFF), // :669 glassContentColor()
        hourHand: Color(0xFFFFFFFF), // 沿用前一笔 = ink（见 visual-deltas §6）
        minuteHand: Color(0xFFFFFFFF),
        secondHand: Color(0xFFFFFFFF), // :689 accent → ink(\"#ee7659\") → 白
        hub: Color(0xFFFFFFFF), // :690 同上
        timerIcon: Color(0xFFFFFFFF),
      );
    }
    return KosClockColors(
      hourHand: theme.accent, // :684 colors.primary → shell accent
      minuteHand: backdropSecondaryInk(theme), // :687 colors.tertiary 系
      secondHand: theme.accent, // :689 accent(...,\"#ee7659\") → shell accent
      hub: theme.accent, // :690 accent(primary,...) → shell accent
    );
  }

  /// 表盘底盘色 `#fafafa`（:647），仅源端色艺卡（!onBackdrop）绘制；本端
  /// 不再使用，保留字段供外部色板注入兼容。
  final Color faceFill;

  /// 外环描边 `ink(\"#dedede\", 0.42)`（:651-653），仅源端非 material
  /// 形态绘制（:650 `if (!isMaterial)`）；本端不绘制，保留字段供兼容。
  final Color faceRing;

  /// 12 条整点刻度色 `ink(\"#171717\")`（:655）。
  final Color ink;

  /// 表盘数字色 `ink(\"#242126\")`（:669）。
  final Color numeral;

  /// 时针色：material → `colors.primary`（:683-685）；非 material 源端
  /// 不覆盖 strokeStyle（:683 `if` 内才设色），沿用前一笔 = ink（差异记
  /// visual-deltas §6）；本字段以显式色对齐该行为。
  final Color hourHand;

  /// 分针色：material → `colors.tertiary`（:686-688）；非 material 同上
  /// 沿用 ink（:686-688）。
  final Color minuteHand;

  /// 秒针色 `accent(colors.secondary, \"#ee7659\")`（:689）。
  final Color secondHand;

  /// 中心圆点 `accent(colors.primary, \"#ee7659\")`（:690）。
  final Color hub;

  /// 右下角计时器图标色（源用 bundled SVG 图标，:716-726；此处以
  /// ink 色绘沙漏近似，见 `_TimerGlyphPainter` 与 visual-deltas）。
  final Color timerIcon;
}

/// DeskCenter 时钟小部件卡片（对应 `modelData.id === \"clock\"` 的整卡，
/// :608-706 + 卡面 :456-475）。
///
/// 外层为 [DeskCard]：表面吃 Denial ShellTheme 材质；默认 `size` 由调用方
/// 按 `DeskCenterConfigService.sizeFor(\"clock\")` 语义注入。源端
/// `flowerShapedSurface: modelData.id === \"clock\"`（:470）的花形轮廓仅在
/// KOS material 形态生效（DeskWidgetCard.qml:43-44），本端不保留。
class KosClockCard extends ConsumerStatefulWidget {
  const KosClockCard({
    super.key,
    this.clock,
    this.colors,
    this.size = WidgetSize.medium,
    this.editMode = false,
    this.onLaunchTimer,
    this.onRemove,
    this.onCycleSize,
    this.child,
  });

  /// 时钟数据源：`AsyncValue<DateTime>` provider。null 时经
  /// `ShellServicesScope` 取 `services.telemetry.clock`（对齐
  /// desktop_system_bar_media.dart:132-134 的用法）；测试注入
  /// `Provider((_) => AsyncData(fixedTime))` 或常量 provider。
  final ProviderListenable<AsyncValue<DateTime>>? clock;

  /// 表盘/内容色板覆盖；null 时按 `context.shellTheme` 取
  /// [KosClockColors.forShell]（亮壳→ownColor/accent 系、暗壳→白系）。
  final KosClockColors? colors;

  /// 尺寸档位，透传给 [DeskCard] 驱动角标标签；表盘几何自适应卡面。
  final WidgetSize size;

  /// 编辑模式角标（:551-591），透传 [DeskCard.editMode]。
  final bool editMode;

  /// 计时器子页入口（:727-733 倒计时按钮点击回调）；null 时按钮不响应。
  final KosClockTimerCallback? onLaunchTimer;

  /// 编辑态移除/尺寸循环回调，透传 [DeskCard]。
  final DeskCardBadgeCallback? onRemove;
  final DeskCardBadgeCallback? onCycleSize;

  /// 预留附加内容层（计时器子页等），叠在表盘之上；正常为 null。
  final Widget? child;

  @override
  ConsumerState<KosClockCard> createState() => _KosClockCardState();
}

class _KosClockCardState extends ConsumerState<KosClockCard> {
  /// 秒级滴答：SDK `telemetry.clock` 是分钟级流（system_status.dart:30-45，
  /// 「Emits immediately and then exactly at minute boundaries」），而源
  /// `SystemClock precision: Seconds`（DeskCenterWindow.qml:291）每秒
  /// 驱动秒针。此 Timer 每秒 setState 让秒针走时，是对 SDK 限制的补足。
  Timer? _secondTicker;

  /// 数据流最近一次给出的时刻与其抵达墙钟；秒针走时叠加
  /// `now - _streamValueAt` 在分钟流上恢复秒级精度（源 SystemClock 语义）。
  DateTime? _streamValueAt;

  @override
  void initState() {
    super.initState();
    _secondTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _secondTicker?.cancel();
    super.dispose();
  }

  /// AsyncValue 值 → 显示时刻：记录流值抵达时刻，显示值 = 流值 + 实耗，
  /// 秒针在两次分钟更新之间继续走时。
  DateTime _effectiveNow(DateTime? value) {
    if (value == null) {
      _streamValueAt = null;
      return DateTime.now();
    }
    _streamValueAt ??= DateTime.now();
    return value.add(DateTime.now().difference(_streamValueAt!));
  }

  @override
  Widget build(BuildContext context) {
    // AsyncValue<DateTime> → DateTime；无值（loading/error）回退 now()，
    // 对齐 denial_desktop 的 `.value ?? DateTime.now()` 语义。
    // D4：clock 为 null 且 ShellServicesScope 缺失时不再抛 StateError——
    // 回退 DateTime.now() 渲染（无容器层的预览/测试形态），保留
    // `services.telemetry.clock` 在 scope 存在时的优先级。
    final scope = context
        .dependOnInheritedWidgetOfExactType<ShellServicesScope>();
    // ShellServices implements ShellTelemetryServices（services.dart:148-159）：
    // services.clock 即 telemetry.clock。
    final listenable = widget.clock ?? scope?.services.clock;
    final now = _effectiveNow(
      listenable != null ? ref.watch(listenable).value : null,
    );
    // 色板：显式注入优先，否则按 ShellTheme 取（亮壳→ownColor/accent 系、
    // 暗壳→白系）。无 MaterialApp/Theme 祖先时 Theme.of 恒回退 light——
    // 亮度必须读 `context.shellTheme`。
    final colors = widget.colors ?? KosClockColors.forShell(context.shellTheme);
    return DeskCard(
      // clock 卡无标题（configuredWidget title:\"\"，:208-212）。
      size: widget.size,
      editMode: widget.editMode,
      onRemove: widget.onRemove,
      onCycleSize: widget.onCycleSize,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // 表盘：Canvas anchors.fill+margins:14（:632-633）→ Padding 14。
          Positioned.fill(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: CustomPaint(
                painter: KosClockPainter(now: now, colors: colors),
              ),
            ),
          ),
          // 右下角计时器入口（:708-734，21px 圆钮、右/下各 12 边距）。
          Positioned(
            right: 12,
            bottom: 12,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: widget.onLaunchTimer,
              child: SizedBox(
                width: 21, // :710
                height: 21, // :711
                child: Center(
                  child: CustomPaint(
                    size: const Size(17, 17), // :719-720 图标 17px
                    painter: _TimerGlyphPainter(color: colors.timerIcon),
                  ),
                ),
              ),
            ),
          ),
          if (widget.child != null) Positioned.fill(child: widget.child!),
        ],
      ),
    );
  }
}

/// 模拟表盘 CustomPainter：逐行复刻 DeskCenterWindow.qml:634-691 的
/// Canvas onPaint 脚本。
///
/// 坐标系约定：源 `ctx.translate(cx, cy)` 后以 12 点钟为 0 弧度、顺时针
/// 为正；绘图调用统一形如 `(sin(angle)·r, -cos(angle)·r)`（:661-662、
/// :676-678、:685-689），即屏幕坐标 y 向下为正时 -cos 指向上方。
/// Flutter `Canvas` 同名坐标系，平移到此中心后直接套同一公式。
class KosClockPainter extends CustomPainter {
  const KosClockPainter({required this.now, required this.colors});

  /// 整点刻度数（:657 `for mark < 12`）；供几何断言。
  static const tickCount = 12;

  /// 半径内缩量（:638 `radius = size/2 - 3`）。
  static const radiusInset = 3.0;

  /// 当前时刻（秒针按秒精度，对齐 `SystemClock precision: Seconds`，:291）。
  final DateTime now;
  final KosClockColors colors;

  @override
  void paint(Canvas canvas, Size size) {
    // :636-639：size=min(w,h)、半径=size/2-3，半径<=0 直接返回。
    final face = math.min(size.width, size.height);
    final radius = math.max(0.0, face / 2 - radiusInset); // :638 -3
    if (radius <= 0) return;
    final center = Offset(
      (size.width - face) / 2 + face / 2,
      (size.height - face) / 2 + face / 2,
    ); // :643 translate((w-size)/2+center, (h-size)/2+center)
    canvas.save();
    canvas.translate(center.dx, center.dy);

    // :646-649：仅非 onBackdrop（glass 色艺卡）画 #fafafa 底盘；磨砂背板
    // 形态下卡面即表盘，不再画第二块白盘（:644-645 注释）。:650-654 的
    // 非 material 外环同理不画。TASK-09 起本端统一 Denial 材质（等价
    // material 档 onBackdrop），两处均为源端色艺/非 material 死路径，
    // faceFill/faceRing 字段仅保留供外部色板注入兼容。

    // :657-664：12 条整点刻度。angle=mark·π/6；3 的倍数刻度粗 1.8/长至
    // radius-10，其余 0.8/radius-7；统一起自 radius-4，圆头线帽。
    final tickPaint = Paint()
      ..color = colors.ink
      ..strokeCap = StrokeCap.round; // :656 lineCap="round"
    for (var mark = 0; mark < tickCount; mark++) {
      final angle = mark * math.pi / 6; // :658
      final major = mark % 3 == 0;
      tickPaint.strokeWidth = major ? 1.8 : 0.8; // :659
      final outer = radius - 4; // :661
      final inner = radius - (major ? 10 : 7); // :662
      canvas.drawLine(
        Offset(math.sin(angle) * outer, -math.cos(angle) * outer),
        Offset(math.sin(angle) * inner, -math.cos(angle) * inner),
        tickPaint,
      );
    }

    // :673-679：1-12 数字盘，半径 radius·0.68，字号 max(7, r·0.18) 粗体，
    // 居中/中线对齐。TextPainter 等效 fillText。
    final fontSize = math.max(7, (radius * 0.18).round()).toDouble(); // :670
    for (var number = 1; number <= 12; number++) {
      final angle = number * math.pi / 6; // :674
      final nr = radius * 0.68; // :675
      final painter = TextPainter(
        text: TextSpan(
          text: '$number',
          style: TextStyle(
            color: colors.numeral,
            fontSize: fontSize,
            fontWeight: FontWeight.bold, // :670 bold
            height: 1,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final at = Offset(
        math.sin(angle) * nr, // :676-677 x=sin·r
        -math.cos(angle) * nr, // y=-cos·r（屏幕 y 向下，负值向上）
      );
      painter.paint(
        canvas,
        at - Offset(painter.width / 2, painter.height / 2), // 居中
      );
    }

    // :680-682：三根指针角度（弧度）——时针对分针连续进位。
    final hourAngle = (now.hour % 12 + now.minute / 60) * math.pi / 6; // :680
    final minuteAngle = now.minute * math.pi / 30; // :681
    final secondAngle = now.second * math.pi / 30; // :682

    // :683-685：时针——material 用 colors.primary，2.5px，长度 r·0.48。
    _hand(
      canvas,
      angle: hourAngle,
      length: radius * 0.48,
      width: 2.5,
      color: colors.hourHand,
    );
    // :686-688：分针——material 用 colors.tertiary，1.8px，长度 r·0.70。
    _hand(
      canvas,
      angle: minuteAngle,
      length: radius * 0.70,
      width: 1.8,
      color: colors.minuteHand,
    );
    // :689：秒针——accent(secondary,"#ee7659")，1px，长度 r·0.76。
    _hand(
      canvas,
      angle: secondAngle,
      length: radius * 0.76,
      width: 1,
      color: colors.secondHand,
    );
    // :690：中心圆点——accent(primary,"#ee7659")，半径 2.2 实心圆。
    canvas.drawCircle(Offset.zero, 2.2, Paint()..color = colors.hub);

    canvas.restore();
  }

  /// 从中心向 `angle` 方向画一根圆头针（源 moveTo(0,0)→lineTo 同构）。
  void _hand(
    Canvas canvas, {
    required double angle,
    required double length,
    required double width,
    required Color color,
  }) {
    canvas.drawLine(
      Offset.zero,
      Offset(math.sin(angle) * length, -math.cos(angle) * length),
      Paint()
        ..color = color
        ..strokeWidth = width
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(covariant KosClockPainter oldDelegate) =>
      oldDelegate.now != now || oldDelegate.colors != colors;
}

/// 计时器图标近似：源为 bundled SVG "countdown" 图标（:716-726），此处用
/// 1.2px 圆头描边画简笔沙漏（上下两三角），颜色取卡面 ink。
/// 差异记入 docs/visual-deltas.md。
class _TimerGlyphPainter extends CustomPainter {
  const _TimerGlyphPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..strokeCap = StrokeCap.round;
    final w = size.width;
    final h = size.height;
    final path = Path()
      // 上三角：左上→中→右上→闭合
      ..moveTo(w * 0.18, h * 0.12)
      ..lineTo(w * 0.82, h * 0.12)
      ..lineTo(w * 0.5, h * 0.52)
      ..close()
      // 下三角：中→右下→左下→闭合
      ..moveTo(w * 0.5, h * 0.52)
      ..lineTo(w * 0.82, h * 0.88)
      ..lineTo(w * 0.18, h * 0.88)
      ..close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _TimerGlyphPainter oldDelegate) =>
      oldDelegate.color != color;
}
