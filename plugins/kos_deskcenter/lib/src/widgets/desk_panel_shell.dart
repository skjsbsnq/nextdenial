/// KOS DeskCenter 卡片详情面板容器（`DeskPanelShell`）与会话路由（TASK-12，
/// 2026-10-02 改为 §9.4 (B) 方案）。
///
/// 面板不再走 `ShellPopupController` / `ShellPopupHost`（画在整个 shell 场景
/// 之上，会盖住被合成进场景内部的输入法候选窗），而是由跨 surface 的会话
/// provider [deskPanelSessionProvider] 驱动一个插件自贡献的 `ShellSurface`
/// （`kos_deskcenter.panel`，`ShellSurfaceLayer.desktopControls` 层，见
/// `lib/kos_deskcenter.dart` 的 `KosDeskCenterPanelSurface`）：该层位于输入法
/// 候选 popup 之下，故候选窗可显示在面板之上。渲染宿主见
/// `desk_panel_surface.dart` 的 `DeskPanelSurfaceHost`。
///
/// `DeskPanelShell` 仍提供统一面板材质——`ShellBackdropBlur(separateChild:
/// true)` + `Material(cardColor)` 圆角 `theme.panelRadius`，带标题栏 + 关闭钮。
///
/// 源端对照：DeskCenterWindow.qml 的 `AppActionService.launchById` 各入口
/// （clock 无参 :612-614 邻域、weather `--location` :1156-1164、calendar
/// `--date` :2193-2199、todo `--view/--item` :2045-2050/:2144-2147、music
/// 无参 :1718-1722）改为弹出对应内嵌面板，参数经 [DeskPanelRequest] 传递，
/// 面板真实内容由 TASK-13~17 填充（本期为占位体）。
library;
import 'dart:async';

import 'package:denial_flutter_sdk/effects.dart' show ShellBackdropBlur;
import 'package:denial_flutter_sdk/motion.dart' show Motion;
import 'package:denial_flutter_sdk/shell_theme.dart'
    show ShellThemeBuildContext;
import 'package:denial_flutter_sdk/tokens.dart' show ShellText;
import 'package:flutter/material.dart' show Material;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'activity_card.dart' show ActivitySnapshot;
import 'system_card.dart' show KosSystemMetrics;
import 'weather_card.dart' show WeatherSnapshot;
import '../data/widget_snapshot_watcher.dart' show WidgetSnapshot;

/// 面板弹出策略（show() 调用方常量；注释锚定卡内 launchById 行号）。
///
/// - `clock`（:612 整卡）→ `kos-clock`，无参；
/// - `weather`（:1156-1164）→ `kos-weather`，argv `--location <id>`；
/// - `calendar`（:2193-2199）→ `kos-calendar`，argv `--date <yyyy-MM-dd>`；
/// - `todo`（:2045-2050 / :2144-2147）→ `kos-todo`，argv
///   `--view today` 或 `--item <id>`；
/// - `system`、`activity`、`music`（:1718-1722）→ 无参各自详情面板。
const Map<String, String> kosDeskPanelAppIds = {
  'clock': 'kos-clock',
  'weather': 'kos-weather',
  'calendar': 'kos-calendar',
  'todo': 'kos-todo',
  'system': 'kos-system',
  'activity': 'kos-activity',
  'music': 'kos-music',
};

/// 卡片点击打开面板的请求参数：目标 appId 与源端 argv 语义的原样转发。
///
/// argv 进面板后按 flag 映射初始 state（TASK-13~17 实面板消费）：
/// `--location`→`pendingLocationId`、`--date`→`selectedDate`/`visibleMonth`、
/// `--view`→`activeFilter`、`--item`→`openItemId`。
final class DeskPanelRequest {
  const DeskPanelRequest({required this.appId, this.argv = const []});

  /// 源端 `launchById` 的应用 id（`'kos-xxx'`）。
  final String appId;

  /// 源端 argv（与卡内 `onLaunchApp` 第二参一致）。
  final List<String> argv;

  /// 卡片短 id（appId 去掉 `kos-` 前缀；找不到回退原串）。
  String get cardId =>
      appId.startsWith('kos-') ? appId.substring(4) : appId;

  /// `--location` 参数值（weather → pendingLocationId）。
  String? get locationId => _flagValue('--location');

  /// `--date` 参数值（calendar → selectedDate/visibleMonth 的初始 ISO）。
  String? get date => _flagValue('--date');

  /// `--view` 参数值（todo → activeFilter，如 `'today'`）。
  String? get view => _flagValue('--view');

  /// `--item` 参数值（todo → openItemId）。
  String? get itemId => _flagValue('--item');

  String? _flagValue(String flag) {
    final index = argv.indexOf(flag);
    return index >= 0 && index + 1 < argv.length ? argv[index + 1] : null;
  }
}

/// 面板内容构造器：由卡片 id（`kos-xxx` 去前缀）映射到该卡片的
/// `DeskPanelShell` 内容 widget。TASK-13~17 各面板在自己的文件里调用
/// [registerDeskPanelBuilder] 注册（启动时装配一次）。
typedef DeskPanelBuilder =
    Widget Function(DeskPanelRequest request, DeskPanelData data);

/// 卡片 id → 面板内容构造器。未注册的 id 回退 [DeskPanelPlaceholder]。
/// 键为 `kos-xxx` 应用 id（非去前缀 cardId），与 [DeskPanelRequest.appId] 一致。
final Map<String, DeskPanelBuilder> deskPanelBuilderRegistry =
    <String, DeskPanelBuilder>{};

/// 注册某 appId 的面板内容构造器（幂等；后注册覆盖先注册）。
void registerDeskPanelBuilder(String appId, DeskPanelBuilder builder) {
  deskPanelBuilderRegistry[appId] = builder;
}

/// 面板内嵌占位内容路由所需的数据快照集合。
///
/// 由 `KosDeskCenterView` 装配：与卡片同一份数据（面板 builder 捕获
/// `container.read(...)` 的当帧快照，瞬时面板的静态快照语义）。本期
/// 占位体只展示摘要行；TASK-13~17 实面板按需取字段。
final class DeskPanelData {
  const DeskPanelData({
    this.weather,
    this.snapshot,
    this.metrics,
    this.activity,
    this.activityTracker,
    this.media,
    this.pimStore,
    this.weatherProvider,
    this.metricsCollector,
  });

  final WeatherSnapshot? weather;
  final WidgetSnapshot? snapshot;
  final KosSystemMetrics? metrics;

  /// 前台应用时长跟踪器实例（TASK-17）：activity 面板实时榜单的数据源
  /// （`data.activityTracker as ActivityTracker`，`entries`/`uptimeByDay`）。
  /// 为 `Object?` 以避免 panel shell 反向依赖卡片实现；容器在
  /// `_openPanel` 传入同一 tracker（widget 生命周期内有效）。
  final Object? activityTracker;
  final ActivitySnapshot? activity;

  /// MPRIS 播放态（`services.media` 的当帧值；类型为
  /// `denial_sdk/system.dart` 的 `MprisPlaybackState`，面板侧延迟到
  /// TASK-17 引用真实类型——占位期仅以 toString 不消费字段）。
  final Object? media;

  /// 插件内 PIM store（TASK-11）：calendar/todo 面板的读写入口
  /// （`eventsForRange`/`addTodo`/`setTodoCompleted`/`createList`/编辑器写回）。
  /// 为 `Object?` 以避免 panel shell 反向依赖 pim 子库；消费侧按
  /// `data.pimStore as PimStore` 取。
  final Object? pimStore;

  /// 内嵌天气 provider（TASK-10）：weather 面板的 forecast/geocoding/
  /// `setLocation`/`refresh` 入口。
  final Object? weatherProvider;

  /// 内嵌 metrics 采集器（TASK-10）：system 面板的 `cpuSeries`/`cpuUpdates`/
  /// `latest`/`metrics` 源。
  final Object? metricsCollector;
}

/// 一次面板打开会话：请求参数 + 打开时的当帧数据快照/读写实例。
///
/// 由容器 surface（`KosDeskCenterView._openPanel`）写入、面板 surface
/// （`DeskPanelSurfaceHost`）读取；两者挂在 shell 的**同一个** `ProviderScope`
/// 下，因此同一实例跨 surface 可见——这正是把 `pimStore`/`weatherProvider`/
/// `metricsCollector`（均由 `_KosDeskCenterSurfaceState` 创建）共享给面板
/// surface 的通道。
@immutable
final class DeskPanelSession {
  const DeskPanelSession({required this.request, required this.data});

  /// 目标面板与源端 argv。
  final DeskPanelRequest request;

  /// 打开时的当帧快照与读写实例（`pimStore`/`weatherProvider`/
  /// `metricsCollector` 即容器 surface 持有的同一对象）。
  final DeskPanelData data;
}

/// 当前打开的面板会话；`null` = 无面板。
///
/// 跨 surface 的共享状态：容器 surface 打开、面板 surface 渲染，二者无需彼此
/// 直接引用。重复 [DeskPanelSessionNotifier.open] = 覆盖同一会话（不堆叠，
/// 对应旧 `keyName` 单例语义）。
final deskPanelSessionProvider =
    NotifierProvider<DeskPanelSessionNotifier, DeskPanelSession?>(
      DeskPanelSessionNotifier.new,
    );

/// [deskPanelSessionProvider] 的写入侧。
class DeskPanelSessionNotifier extends Notifier<DeskPanelSession?> {
  @override
  DeskPanelSession? build() => null;

  /// 打开（或替换）面板会话：同 `appId` 重复打开即覆盖，不堆叠。
  void open(DeskPanelRequest request, DeskPanelData data) {
    state = DeskPanelSession(request: request, data: data);
  }

  /// 关闭当前会话（无会话时 no-op）。
  void close() {
    if (state == null) return;
    state = null;
  }
}

/// 打开一张卡片的详情面板（改造自 TASK-12 的 SDK popup 弹出）。
///
/// 相比旧实现的 `ShellPopupController.show`：这里只写入 [deskPanelSessionProvider]，
/// 由面板 surface（`desktopControls` 层）渲染，从而让输入法候选窗显示在其上。
/// [container] 为 null（无 `ProviderScope` 的预览/测试形态）时静默 no-op。
void showDeskPanel(
  ProviderContainer? container, {
  required DeskPanelRequest request,
  required DeskPanelData data,
}) {
  container?.read(deskPanelSessionProvider.notifier).open(request, data);
}

/// 按注册表构造面板内容：命中 `deskPanelBuilderRegistry` 的实面板
/// （TASK-13~17），未注册回退 [DeskPanelPlaceholder]。
Widget buildDeskPanelContent(DeskPanelRequest request, DeskPanelData data) =>
    deskPanelBuilderRegistry[request.appId]?.call(request, data) ??
    DeskPanelPlaceholder(request: request, data: data);

/// 卡片 id → 面板标题（部件库同一份中文标签，
/// DeskCenterWindow.qml widgetLabels :96-98）。
String deskPanelTitle(String cardId) => switch (cardId) {
  'clock' => '时钟',
  'weather' => '天气',
  'calendar' => '日历',
  'todo' => '待办',
  'system' => '系统',
  'activity' => '活动',
  'music' => '音乐',
  _ => cardId,
};

/// DeskCenter 详情面板容器：SDK 面板材质（`ShellBackdropBlur` +
/// `Material(cardColor)`、`theme.panelRadius` 圆角），标题栏 + 关闭钮。
///
/// 入场动画由本容器自管：背板模糊（`ShellBackdropBlur` 的 `separateChild`
/// 兄弟节点）不进 opacity 层，首帧即正确采样背景；淡入/缩放只作用于卡片
/// 与内容（避免 SDK 旧 popup 层 `FadeTransition` 把子树画进 Flutter
/// 中间缓冲导致 `BackdropFilter` 淡入期间采样不到背景的「先透明、后模糊」）。
/// 面板在 `desktopControls` 层位于应用窗口之下，背景不画暗色遮罩（铺满的
/// scrim 会成为盖住桌面的灰层）；「点面板外关闭」由透明的命中层承担。
///
/// 尺寸自适应 [child]，上限屏幕 70%（对齐 wifi_detail_surface 的
/// `ConstrainedBox` 540×720 上限范式——本面板随内容走，无固定底尺寸）。
class DeskPanelShell extends StatefulWidget {
  const DeskPanelShell({
    required this.title,
    required this.onClose,
    required this.child,
    this.onBarrierTap,
    super.key,
  });

  /// 标题栏文本（部件中文标签）。
  final String title;

  /// 关闭钮回调：接到会话的 `close()`（旧实现接 `ShellPopupHandle.close`）。
  final VoidCallback onClose;

  /// 面板内容（TASK-13~17 实面板）。
  final Widget child;

  /// 点面板外（透明命中层）关闭回调；非 null 时命中层铺满 surface 可点，
  /// null 时不铺命中层（由外部承担点外关闭，或不允许点外关闭）。
  final VoidCallback? onBarrierTap;

  @override
  State<DeskPanelShell> createState() => _DeskPanelShellState();
}

class _DeskPanelShellState extends State<DeskPanelShell>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _fade;
  late final Animation<double> _scale;
  @override
  void initState() {
    super.initState();
    final reduceMotion = WidgetsBinding
        .instance
        .platformDispatcher
        .accessibilityFeatures
        .disableAnimations;
    _controller = AnimationController(
      vsync: this,
      duration: reduceMotion ? Duration.zero : Motion.cardSettle,
    );
    _fade = _controller.drive(
      CurveTween(curve: Motion.md3EmphasizedDecelerate),
    );
    _scale = Tween<double>(begin: 0.985, end: 1).animate(_fade);
    unawaited(_controller.forward());
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.shellTheme;
    final colors = context.shellColors;
    final borderRadius = BorderRadius.circular(theme.panelRadius);
    // 上限屏幕 70%：`MediaQuery.sizeOf` 返回本 widget 所在 Flutter 视图（整
    // 窗口/输出）的逻辑尺寸，与 surface 的 bounds（workArea 子矩形）无关；这里
    // 需要的是「面板不超过窗口 70%」的语义，故取整窗口尺寸正确。
    final viewport = MediaQuery.sizeOf(context);
    // 点外关闭由铺满的透明命中层承担（`onBarrierTap` 非 null 时）；
    // 不再自绘暗色遮罩——面板在 `desktopControls` 层位于应用窗口之下，
    // 铺满 scrim 会变成一层盖在桌面的灰色蒙版（用户目检缺陷）。null 时
    // 保持旧的 IgnorePointer 语义（由外部 barrier 承担点外关闭）。
    return Stack(
      fit: StackFit.expand,
      children: [
        if (widget.onBarrierTap case final onBarrierTap?)
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onBarrierTap,
            child: const SizedBox.expand(),
          )
        else
          const SizedBox.shrink(),
        SafeArea(
          minimum: const EdgeInsets.all(16),
          child: Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: viewport.width * 0.7,
                maxHeight: viewport.height * 0.7,
              ),
              child: ShellBackdropBlur(
                // 与 wifi_detail_surface :139-148 同一材质链：前景不进
                // filter 层；off 模式不模糊（内部 backdropBlurEnabled 门）。
                separateChild: true,
                blur: theme.effectivePanelOpacity < 1.0,
                borderRadius: borderRadius,
                // 模糊背板是 child 的兄弟节点，不参与下方 opacity/scale，
                // 因此淡入期间也能正确采样背景。
                child: FadeTransition(
                  opacity: _fade,
                  child: ScaleTransition(
                    scale: _scale,
                    child: Material(
                      // 卡片同款 `cardColor(surfaceContainer)`（TASK-09 材质
                      // 范式，desk_card.dart:91-107 的 Material 支路）。
                      color: theme.cardColor(colors.surfaceContainer),
                      borderRadius: borderRadius,
                      clipBehavior: Clip.antiAlias,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _DeskPanelHeader(
                            title: widget.title,
                            onClose: widget.onClose,
                          ),
                          // 内容区限高（Scrollable 防溢出）；占位体自适应。
                          Flexible(
                            child: SingleChildScrollView(
                              primary: false,
                              padding: const EdgeInsets.fromLTRB(
                                18,
                                4,
                                18,
                                16,
                              ),
                              child: widget.child,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 标题栏（左标签 + 右关闭钮 32×32 圆形），对齐 wifi_detail_surface 的
/// header 行范式（:155-213）的简化版——DeskCenter 面板无刷新/开关钮。
class _DeskPanelHeader extends StatelessWidget {
  const _DeskPanelHeader({required this.title, required this.onClose});

  final String title;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final colors = context.shellColors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 14, 10, 10),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: ShellText.base.copyWith(
                color: colors.textPrimary,
                fontSize: 16,
                fontWeight: FontWeight.w600,
                height: 1,
              ),
            ),
          ),
          GestureDetector(
            key: const ValueKey('desk-panel-close'),
            behavior: HitTestBehavior.opaque,
            onTap: onClose,
            child: Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: colors.surfaceContainerHigh,
                border: Border.all(color: colors.hairline),
              ),
              alignment: Alignment.center,
              child: Text(
                '×',
                style: TextStyle(
                  color: colors.textSecondary,
                  fontSize: 16,
                  height: 1,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// TASK-12 占位内容体：源端 argv 原样映射 + 已有数据快照摘要，
/// 标注「详情待 TASK-1x」。TASK-13~17 以真面板替换本 widget（路由入口
/// 与 [DeskPanelRequest]/[DeskPanelData] 不变）。
class DeskPanelPlaceholder extends StatelessWidget {
  const DeskPanelPlaceholder({
    required this.request,
    required this.data,
    super.key,
  });

  final DeskPanelRequest request;
  final DeskPanelData data;

  String _pendingTaskFor(String cardId) => switch (cardId) {
    // TASK 编号对照 docs/TASK-12-popup-panels.md §改动范围。
    'weather' => 'TASK-14',
    'calendar' => 'TASK-15',
    'todo' => 'TASK-16',
    'system' || 'activity' || 'music' => 'TASK-17',
    _ => 'TASK-13', // clock 与其余
  };

  /// 占位摘要行：argv 语义 + 当帧快照的一行数据（供面板接线自检）。
  List<String> _summaryLines() {
    final request = this.request;
    final data = this.data;
    return switch (request.cardId) {
      'weather' => [
        'pendingLocationId = ${request.locationId ?? '（无）'}',
        '快照：${data.weather?.cityName ?? '无'} '
            '${data.weather?.currentTemp.isNaN ?? true ? '' : '${data.weather!.currentTemp.round()}°'}',
      ],
      'calendar' => [
        'selectedDate = ${request.date ?? '今日'}',
        '快照：事件 ${data.snapshot?.events.length ?? 0} 条',
      ],
      'todo' => [
        'activeFilter = ${request.view ?? '（无）'}',
        'openItemId = ${request.itemId ?? '（无）'}',
        '快照：待办 ${data.snapshot?.todos.length ?? 0} 条',
      ],
      'system' => [
        if (data.metrics != null)
          '内存 '
              '${(data.metrics!.memoryUsedBytes / (1024 * 1024 * 1024)).toStringAsFixed(1)}'
              ' / ${(data.metrics!.memoryTotalBytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GiB'
          else
          '快照：无',
      ],
      'activity' => [
        '快照：开机热力图 ${data.activity?.uptimeByDay.length ?? 0} 天，'
            '今日应用 ${data.activity?.todayApps.length ?? 0} 个',
      ],
      'music' => ['播放：${data.media ?? '无'}'],
      _ => const <String>[], // clock 无参
    };
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.shellColors;
    final summary = _summaryLines();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '${deskPanelTitle(request.cardId)}详情待 ${_pendingTaskFor(request.cardId)}',
          style: TextStyle(
            color: colors.textPrimary,
            fontSize: 13,
            fontWeight: FontWeight.w600,
            height: 1.4,
          ),
        ),
        if (summary.isNotEmpty) ...[
          const SizedBox(height: 8),
          for (final line in summary)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                line,
                style: TextStyle(
                  color: colors.textSecondary,
                  fontSize: 11.5,
                  height: 1.35,
                ),
              ),
            ),
        ],
      ],
    );
  }
}
