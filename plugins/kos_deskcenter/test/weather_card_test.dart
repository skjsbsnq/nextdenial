// KosWeatherCard widget 测试。
//
// 对齐 DeskCenterWindow.qml:929-1167 的 weather 分支：城市名/温度/条件
// 符号+文本/今日高低温/7 日预报条/空态文案/整卡点击。

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kos_deskcenter/src/widgets/weather_card.dart';

Widget _wrap(Widget child, {double w = 340, double h = 140}) => Directionality(
  textDirection: TextDirection.ltr,
  child: Center(
    child: SizedBox(width: w, height: h, child: child),
  ),
);

WeatherSnapshot _snap({
  String status = 'ready',
  int code = 1,
  bool isDay = true,
  double temp = 23.6,
  List<WeatherDay> forecast = const [],
}) => WeatherSnapshot(
  status: status,
  cityName: '上海',
  locationId: 'loc-1',
  currentTemp: temp,
  weatherCode: code,
  isDay: isDay,
  forecast: forecast,
);

void main() {
  testWidgets('weather 卡渲染城市/温度/条件/高低温（:1084-1115）', (tester) async {
    await tester.pumpWidget(_wrap(KosWeatherCard(snapshot: _snap(code: 2))));
    await tester.pump();
    expect(find.text('上海'), findsOneWidget); // :1086 cityName
    expect(find.text('24°'), findsOneWidget); // :1092 round(23.6)
    expect(find.text('局部多云'), findsOneWidget); // :1104 conditionText(2)
    expect(find.text('⛅'), findsOneWidget); // :1098 conditionSymbol(2,day)
    expect(find.text('正在更新预报'), findsOneWidget); // :1112 空预报
    expect(find.text('暂无 7 日预报'), findsOneWidget); // :1151 !loading
  });

  testWidgets('7 日预报条逐格渲染（:1120-1147）', (tester) async {
    await tester.pumpWidget(
      _wrap(
        KosWeatherCard(
          snapshot: _snap(
            forecast: const [
              WeatherDay(date: '2026-09-30', code: 0, high: 30, low: 22),
              WeatherDay(date: '2026-10-01', code: 3, high: 28, low: 20),
              WeatherDay(date: '2026-10-02', code: 61, high: 24, low: 18),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('最高 30°  最低 22°'), findsOneWidget); // :1110-1112
    expect(find.text('今天'), findsOneWidget); // :1130 forecastLabel(…,0)
    expect(find.text('明天'), findsOneWidget); // index 1
    expect(find.text('周五'), findsOneWidget); // 2026-10-02 weekday
    expect(find.text('30°/22°'), findsOneWidget); // :1142
    expect(find.text('28°/20°'), findsOneWidget);
    expect(find.text('24°/18°'), findsOneWidget);
    expect(find.text('☀'), findsOneWidget); // :1136 symbol(0,day)
    expect(find.text('☔'), findsOneWidget); // symbol(61)
  });

  testWidgets('空态：无快照 → --° 与缺省兜底（WeatherService.qml:30-37）', (tester) async {
    await tester.pumpWidget(_wrap(const KosWeatherCard()));
    await tester.pump();
    expect(find.text('--'), findsOneWidget); // cityName 回退
    expect(find.text('--°'), findsOneWidget); // temperature
    expect(find.text('天气未知'), findsOneWidget); // conditionText(-1)
    expect(find.text('正在更新预报'), findsOneWidget);
  });

  testWidgets('loading + 空预报 → 「正在获取 7 日预报…」（:1150-1153）', (tester) async {
    await tester.pumpWidget(
      _wrap(KosWeatherCard(snapshot: _snap(status: 'loading'))),
    );
    await tester.pump();
    expect(find.text('正在获取 7 日预报…'), findsOneWidget);
    expect(find.text('暂无 7 日预报'), findsNothing);
  });

  testWidgets('整卡点击 → kos-weather [--location id]（:1156-1164）', (tester) async {
    final calls = <(String, List<String>)>[];
    await tester.pumpWidget(
      _wrap(
        KosWeatherCard(
          snapshot: _snap(code: 2), // 局部多云（:_snap 默认 code:1=大部晴朗）
          onLaunchApp: (id, a) => calls.add((id, a)),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('局部多云'));
    // matcher 0.12.20 无 record 深比较——逐字段断言。
    expect(calls.last.$1, 'kos-weather');
    expect(calls.last.$2, ['--location', 'loc-1']);
  });

  testWidgets('locationId 空 → 无参数启动（:1161-1162）', (tester) async {
    final calls = <(String, List<String>)>[];
    await tester.pumpWidget(
      _wrap(
        KosWeatherCard(
          snapshot: WeatherSnapshot(
            status: 'ready',
            cityName: '上海',
            locationId: '', // 空 id
            currentTemp: 20,
            weatherCode: 0,
          ),
          onLaunchApp: (id, a) => calls.add((id, a)),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('晴'));
    expect(calls.last.$1, 'kos-weather');
    expect(calls.last.$2, isEmpty); // locationId 空 → 无参数（:1161-1162）
  });
}
