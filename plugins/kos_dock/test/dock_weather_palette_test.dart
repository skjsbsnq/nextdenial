import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kos_dock/src/widgets/cards/weather_card.dart';

void main() {
  test('clear weather switches between day and night artwork', () {
    final day = dockWeatherGradient(0, isDay: true);
    final night = dockWeatherGradient(0, isDay: false);
    expect(day.begin, Alignment.centerLeft);
    expect(day.end, Alignment.centerRight);
    expect(day.colors, isNot(night.colors));
    expect(night.colors.first, const Color.fromRGBO(26, 38, 97, 0.66));
  });
  test('weather palette distinguishes cloud, rain, snow and thunder', () {
    final palettes = [0, 2, 3, 45, 61, 75, 95, -1]
        .map((code) => dockWeatherGradient(code, isDay: true).colors.first)
        .toSet();
    expect(palettes, hasLength(8));
  });
}
