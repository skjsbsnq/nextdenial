import 'package:denial_flutter_sdk/services.dart';
import 'package:denial_flutter_sdk/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 时钟 + 日期模块——顶栏右端最外侧模块。
///
/// 复刻官方 `denial_top_bar/lib/src/desktop_system_bar_components.dart:5-48`
/// 的 `_ClockModule`（日期 caption + 分钟 crossfade 时钟）与
/// `desktop_system_bar_media.dart:123-135` 的 `_ClockStatusModule`
/// （`clock` provider 分钟边界刷新）：私有 widget 跨包不可 import，按
/// TASK-TB-03 约束在本插件复写。
///
/// 与官方唯一差异：官方日期 caption 用 `accent.captionColor`（配合其
/// WallpaperAccent 渐变卡）；本插件胶囊走 dock/deskcenter 平填链
/// （`TopBarCard`，不用 WallpaperAccent），因此 caption 统一
/// `theme.colors.textSecondary`（TASK-TB-03 钉死）。
///
/// 卡片外壳（`TopBarCard` + 入场弹簧）由 TASK-TB-07 装配层包装——本模块
/// 只产出内容行，与官方 `_ClockModule`/`_ClockStatusModule` 分层一致。

/// 时钟模块本体：日期 caption + 分钟切换的时钟文本。
///
/// 复刻官方 `_ClockModule`：`Row(spacing:8)`；日期
/// `AnimatedDefaultTextStyle(Motion.wallpaperReveal, Motion.standard)`
/// 换肤过渡；时间 `AnimatedSwitcher(Motion.cardSettle, standard)` 分钟
/// crossfade + `SlideTransition(Offset(0,0.25)→0)` 上滑，`key:
/// ValueKey(time)` 钉在 `Text` 上触发切换。
class TopBarClockModule extends StatelessWidget {
  const TopBarClockModule({required this.now, super.key});

  /// 当前时间（由父级从 `clock` provider 投影并传入）。
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final theme = context.shellTheme;
    final strings = context.presentationServices.strings(context);
    final time = strings.time(now);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        AnimatedDefaultTextStyle(
          duration: Motion.wallpaperReveal,
          curve: Motion.standard,
          style: ShellText.systemBarCaption.copyWith(
            color: theme.colors.textSecondary,
          ),
          child: Text(strings.shortDate(now)),
        ),
        const SizedBox(width: 8),
        AnimatedSwitcher(
          duration: Motion.cardSettle,
          switchInCurve: Motion.standard,
          switchOutCurve: Motion.standard,
          transitionBuilder: (child, animation) => FadeTransition(
            opacity: animation,
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0.0, 0.25),
                end: Offset.zero,
              ).animate(animation),
              child: child,
            ),
          ),
          child: Text(
            time,
            key: ValueKey<String>(time),
            style: ShellText.systemBarValue,
          ),
        ),
      ],
    );
  }
}

/// 时钟状态壳：`ref.watch(telemetryServices.clock)` 分钟边界刷新，
/// 值未到（AsyncValue 无 data）时用 `DateTime.now()` 占位——照官方
/// `_ClockStatusModule`（`desktop_system_bar_media.dart:124-135`）。
class TopBarClockStatusModule extends ConsumerWidget {
  const TopBarClockStatusModule({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final now =
        ref.watch(context.telemetryServices.clock).value ?? DateTime.now();
    return TopBarClockModule(now: now);
  }
}

extension _ClockContext on BuildContext {
  ShellTelemetryServices get telemetryServices => ShellServicesScope.of(this);
  ShellPresentationServices get presentationServices =>
      ShellServicesScope.of(this);
}
