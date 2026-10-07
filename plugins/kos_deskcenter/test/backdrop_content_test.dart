import 'package:denial_flutter_sdk/theme.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kos_deskcenter/src/widgets/activity_card.dart';
import 'package:kos_deskcenter/src/widgets/calendar_card.dart';
import 'package:kos_deskcenter/src/widgets/clock_card.dart';
import 'package:kos_deskcenter/src/widgets/music_card.dart';
import 'package:kos_deskcenter/src/widgets/system_card.dart';
import 'package:kos_deskcenter/src/widgets/todo_card.dart';
import 'package:kos_deskcenter/src/widgets/weather_card.dart';

void main() {
  test('light glass desktop uses white ink and monochrome metrics', () {
    const theme = ShellThemeData(
      colors: ShellColorScheme.light,
      transparencyMode: ShellTransparencyMode.glass,
    );
    const white = Color(0xFFFFFFFF);
    final system = KosSystemCardColors.forShell(theme);
    expect([
      system.ringCpu,
      system.ringMemory,
      system.ringStorage,
      system.memoryLine,
      system.cpuLine,
      system.frequencyLine,
    ], everyElement(white));
    expect(KosClockColors.forShell(theme).numeral, white);
    expect(KosWeatherCardColors.forShell(theme).ink, white);
    expect(KosCalendarColors.forShell(theme).gridInk, white);
    expect(KosTodoColors.forShell(theme).titleInk, white);
    expect(KosActivityCardColors.forShell(theme).cellFill, white);
    expect(KosMusicCardColors.forShell(theme).controlInkPrimary, white);
    expect(KosMusicCardColors.forShell(theme).isMaterial, isFalse);
  });

  test('opaque blur cards retain shell foreground', () {
    const theme = ShellThemeData(
      colors: ShellColorScheme.light,
      transparencyMode: ShellTransparencyMode.blur,
      cardOpacity: 1,
    );
    expect(KosWeatherCardColors.forShell(theme).ink, theme.colors.textPrimary);
    expect(
      KosSystemCardColors.forShell(theme).detailInk,
      theme.colors.textSecondary,
    );
  });

  test('opaque light cards retain dark ink and colored metrics', () {
    const theme = ShellThemeData(
      colors: ShellColorScheme.light,
      transparencyMode: ShellTransparencyMode.off,
    );
    expect(KosWeatherCardColors.forShell(theme).ink, theme.colors.textPrimary);
    expect(KosCalendarColors.forShell(theme).gridInk, theme.colors.textPrimary);
    expect(
      KosSystemCardColors.forShell(theme).memoryLine,
      isNot(KosSystemCardColors.forShell(theme).cpuLine),
    );
    expect(KosMusicCardColors.forShell(theme).isMaterial, isTrue);
  });
}
