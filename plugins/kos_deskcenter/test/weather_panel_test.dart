// TASK-15 weather 面板 widget 测试。
//
// 覆盖：
// - 注册函数写入 `deskPanelBuilderRegistry`（路由收口契约）；
// - `--location <id>` 直达：命中已存地点即切换（Main.qml handleActivation
//   的 pendingLocationId 语义）；
// - 搜索 → geocoding 结果 → 选点切换（debounce 后触发）；
// - 当前温度/指标网格/小时横向条/7 日列表渲染；
// - 单位切换 °C↔°F（`set-units` 等价物）：provider.units 变更、state 文件
//   持久化 `units` 键、快照随重取回流刷新 UI；
// - 断网（status:error）与无数据源（provider null）降级空态不崩。
//
// provider：真实 `WeatherProvider` + 注入 `httpGet` 假响应 + 临时
// `statePath`，不触网络与真实 XDG 路径。

import 'package:flutter/material.dart' show Color, MaterialApp, Scaffold;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kos_deskcenter/src/data/weather_provider.dart';
import 'package:kos_deskcenter/src/widgets/desk_panel_shell.dart';
import 'package:kos_deskcenter/src/widgets/weather_card.dart';
import 'package:kos_deskcenter/src/widgets/weather_panel.dart';

/// 假 forecast 响应：温度随 `temperature_unit` 变化（验证单位切换触发重取）。
Map<String, Object?> _forecastPayload(Uri uri) {
  final imperial = uri.queryParameters['temperature_unit'] == 'fahrenheit';
  final current = imperial ? 70.5 : 21.4;
  final hourly = imperial ? [70.0, 68.0] : [21.0, 20.0];
  return {
    'current': {
      'time': '2026-10-02T21:00',
      'temperature_2m': current,
      'apparent_temperature': imperial ? 66.2 : 19.0,
      'relative_humidity_2m': 63,
      'weather_code': 2,
      'is_day': 0,
      'wind_speed_10m': 11.4,
      'wind_direction_10m': 180,
    },
    'hourly': {
      'time': ['2026-10-02T21:00', '2026-10-02T22:00'],
      'temperature_2m': hourly,
      'weather_code': [2, 3],
      'precipitation_probability': [10, 20],
      'is_day': [0, 0],
    },
    'daily': {
      'time': ['2026-10-02', '2026-10-03'],
      'weather_code': [2, 61],
      'temperature_2m_max': [24.0, 22.5],
      'temperature_2m_min': [17.0, 16.1],
      'precipitation_probability_max': [20, 70],
    },
  };
}

/// 假 geocoding 响应（`searchLocations` 读 `results[]`）。
Map<String, Object?> _geocodingPayload() => {
  'results': [
    {
      'id': 1796236,
      'name': '上海',
      'admin1': '上海',
      'country': '中国',
      'country_code': 'CN',
      'latitude': 31.22222,
      'longitude': 121.45806,
      'timezone': 'Asia/Shanghai',
    },
  ],
};

Future<Map<String, Object?>> _fakeGet(Uri uri) async =>
    uri.host.startsWith('geocoding')
    ? _geocodingPayload()
    : _forecastPayload(uri);

/// 内存状态存储：widget 测试的 fake-async 区不驱动真实文件 IO，注入本实现
/// 让 `setLocation`/`setUnits` 的持久化在同一隔离区完成。
final class _MemoryStore implements WeatherStateStore {
  Map<String, Object?>? payload;

  @override
  Future<Map<String, Object?>?> read() async => payload;

  @override
  Future<void> write(Map<String, Object?> next) async => payload = next;
}

/// 构造 provider（内存 state + 假 HTTP，不 start——避免 1min 心跳定时器与
/// 测试时钟缠斗；`setLocation`/`setUnits` 内部自带刷新）。
WeatherProvider _provider(WeatherStateStore store) => WeatherProvider(
  httpGet: _fakeGet,
  stateStore: store,
  environment: const {'HOME': '/nonexistent'},
);

Widget _wrap(Widget child) => MaterialApp(
  debugShowCheckedModeBanner: false,
  // MaterialApp 提供 Material / Localizations / Overlay / Directionality
  //（面板真实宿主 = `DeskPanelShell`，其 Material + popup host 的 Overlay）。
  home: Scaffold(
    backgroundColor: const Color(0x00000000),
    body: Center(child: SizedBox(width: 1000, height: 700, child: child)),
  ),
);

/// 同 `_wrap`，但在面板外再套一层 `Localizations` 覆写宿主 locale：外层
/// MaterialApp/Scaffold 仍提供 Material 环境，面板 State 的
/// `Localizations.maybeLocaleOf` 读到注入语言（验证 `_searchLanguage`
/// 的宿主 locale 分支）。
Widget _wrapWithLocale(Widget child, Locale locale) => MaterialApp(
  debugShowCheckedModeBanner: false,
  home: Scaffold(
    backgroundColor: const Color(0x00000000),
    body: Center(
      child: SizedBox(
        width: 1000,
        height: 700,
        child: Localizations(
          locale: locale,
          delegates: const [DefaultWidgetsLocalizations.delegate],
          child: child,
        ),
      ),
    ),
  ),
);

WeatherPanel _panel(
  WeatherProvider? provider, {
  WeatherSnapshot? snapshot,
  List<String> argv = const [],
}) => WeatherPanel(
  request: DeskPanelRequest(appId: 'kos-weather', argv: argv),
  data: DeskPanelData(weather: snapshot, weatherProvider: provider),
);

/// 直接构造的快照（渲染断言用；字段与 provider 投影同构）。
WeatherSnapshot _snapshot() => WeatherSnapshot(
  status: 'ready',
  cityName: '长沙',
  locationId: 'legacy:changsha',
  currentTemp: 23.6,
  weatherCode: 2,
  isDay: true,
  apparentTemp: 21.2,
  relativeHumidity: 61,
  windSpeed: 12.3,
  windDirection: 210,
  currentTime: '2026-10-02T21:00',
  forecast: const [
    WeatherDay(
      date: '2026-10-02',
      code: 2,
      high: 25,
      low: 17,
      precipitationChance: 20,
    ),
    WeatherDay(
      date: '2026-10-03',
      code: 61,
      high: 22,
      low: 16,
      precipitationChance: 70,
    ),
  ],
  hourly: const [
    WeatherHourly(
      time: '2026-10-02T21:00',
      temperature: 23.0,
      code: 2,
      isDay: false,
      precipitationChance: 10,
    ),
    WeatherHourly(
      time: '2026-10-02T22:00',
      temperature: 22.5,
      code: 3,
      isDay: false,
      precipitationChance: 20,
    ),
  ],
);

Future<void> _pump(WidgetTester tester, Widget child) async {
  await tester.binding.setSurfaceSize(const Size(1000, 700));
  await tester.pumpWidget(_wrap(child));
  await tester.pump();
}

void main() {
  testWidgets('注册函数写入 deskPanelBuilderRegistry', (tester) async {
    registerWeatherPanel();
    expect(deskPanelBuilderRegistry['kos-weather'], isNotNull);
    final widget = deskPanelBuilderRegistry['kos-weather']!(
      const DeskPanelRequest(appId: 'kos-weather'),
      const DeskPanelData(),
    );
    expect(widget, isA<WeatherPanel>());
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('当前温度/指标网格/小时条/7 日列表渲染快照数据', (tester) async {
    await _pump(tester, _panel(null, snapshot: _snapshot()));
    // 当前块：城市 + 大温度（round）——城市名用 key 定位（左侧已存地点
    // 列表也会出现同一名字）。
    expect(tester.widget<Text>(find.byKey(const ValueKey('weather-city'))).data, '长沙');
    expect(find.text('24°'), findsOneWidget);
    // 指标网格：体感/湿度/风速/风向/降水（今日 max）。
    expect(find.text('体感'), findsOneWidget);
    expect(find.text('21°C'), findsOneWidget);
    expect(find.text('61%'), findsOneWidget);
    expect(find.text('12km/h'), findsOneWidget);
    expect(find.text('210°'), findsOneWidget);
    // 降水概率 20%：指标格「降水」与 7 日列表首日各一处（同日同源）。
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('weather-metric-4')),
        matching: find.text('20%'),
      ),
      findsOneWidget,
    );
    // 小时横向条：`HH:mm` 标签。
    expect(find.text('21:00'), findsOneWidget);
    expect(find.text('22:00'), findsOneWidget);
    expect(find.byKey(const ValueKey('weather-hourly-1')), findsOneWidget);
    // 7 日列表：今天/明天 + 高低温。
    expect(find.text('今天'), findsOneWidget);
    expect(find.text('明天'), findsOneWidget);
    expect(find.text('25° / 17°'), findsOneWidget);
    expect(find.text('22° / 16°'), findsOneWidget);
  });

  testWidgets('无数据源且无快照 → 空态；status:error → 断网空态', (tester) async {
    await _pump(tester, _panel(null));
    expect(find.text('天气数据不可用'), findsOneWidget);

    await _pump(
      tester,
      _panel(null, snapshot: const WeatherSnapshot(status: 'error')),
    );
    expect(find.text('无法获取天气'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('--location 直达：命中已存地点即切回', (tester) async {
    final provider = _provider(_MemoryStore());
    // 先切到上海（进入已存地点列表，当前位置=上海）。
    await provider.setLocation(
      const KosWeatherLocation(
        id: 'open-meteo:1796236',
        name: '上海',
        admin1: '上海',
        country: '中国',
        countryCode: 'CN',
        latitude: 31.22222,
        longitude: 121.45806,
        timezone: 'Asia/Shanghai',
      ),
    );
    expect(provider.location.id, 'open-meteo:1796236');

    // `--location legacy:changsha`（长沙仍在已存列表）→ 直达切回。
    await _pump(
      tester,
      _panel(
        provider,
        snapshot: provider.latest,
        argv: const ['--location', 'legacy:changsha'],
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(provider.location.id, 'legacy:changsha');
    provider.dispose();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('搜索 → 结果行 → 选点切换到搜索结果', (tester) async {
    final provider = _provider(_MemoryStore());
    await _pump(tester, _panel(provider, snapshot: provider.latest));

    await tester.enterText(
      find.byKey(const ValueKey('weather-search')),
      '上海',
    );
    // 越过 350ms debounce 触发 geocoding。
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(find.byKey(const ValueKey('weather-result-0')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('weather-result-0')),
        matching: find.text('上海'),
      ),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('weather-result-0')));
    await tester.pump();
    await tester.pump();
    expect(provider.location.id, 'open-meteo:1796236');
    // 选中后搜索结果清空（`_select` 收起结果列表）。
    expect(find.byKey(const ValueKey('weather-result-0')), findsNothing);
    provider.dispose();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('中文地名以 zh 语言检索（回归：language=en 会返回空）', (tester) async {
    final geocodingUris = <Uri>[];
    final provider = WeatherProvider(
      stateStore: _MemoryStore(),
      environment: const {'HOME': '/nonexistent'},
      httpGet: (uri) async {
        if (uri.host.startsWith('geocoding')) {
          geocodingUris.add(uri);
          // 复现实测行为：Open-Meteo 的中文地名只在 zh 名称集，en 检索返回空。
          if (uri.queryParameters['language'] != 'zh') {
            return <String, Object?>{};
          }
          return {
            'results': [
              {
                'id': 1806445,
                'name': '吉安',
                'admin1': '江西',
                'country': '中国',
                'country_code': 'CN',
                'latitude': 27.11716,
                'longitude': 114.97927,
                'timezone': 'Asia/Shanghai',
              },
            ],
          };
        }
        return _forecastPayload(uri);
      },
    );
    await _pump(tester, _panel(provider, snapshot: provider.latest));

    await tester.enterText(
      find.byKey(const ValueKey('weather-search')),
      '吉安',
    );
    // 越过 350ms debounce 触发 geocoding。
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();

    expect(geocodingUris, hasLength(1));
    expect(geocodingUris.single.queryParameters['name'], '吉安');
    expect(geocodingUris.single.queryParameters['language'], 'zh');
    expect(find.byKey(const ValueKey('weather-result-0')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('weather-result-0')),
        matching: find.text('吉安'),
      ),
      findsOneWidget,
    );
    provider.dispose();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('非 CJK 查询的检索语言跟随宿主 locale（else 分支）', (tester) async {
    final geocodingUris = <Uri>[];
    final provider = WeatherProvider(
      stateStore: _MemoryStore(),
      environment: const {'HOME': '/nonexistent'},
      httpGet: (uri) async {
        if (uri.host.startsWith('geocoding')) {
          geocodingUris.add(uri);
          return <String, Object?>{};
        }
        return _forecastPayload(uri);
      },
    );
    await tester.binding.setSurfaceSize(const Size(1000, 700));
    await tester.pumpWidget(
      _wrapWithLocale(
        _panel(provider, snapshot: provider.latest),
        const Locale('fr'),
      ),
    );
    await tester.pump();

    await tester.enterText(
      find.byKey(const ValueKey('weather-search')),
      'Paris',
    );
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();

    expect(geocodingUris, hasLength(1));
    expect(geocodingUris.single.queryParameters['name'], 'Paris');
    expect(geocodingUris.single.queryParameters['language'], 'fr');
    provider.dispose();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('CJK 宿主语言（ja）不被强制为 zh', (tester) async {
    final geocodingUris = <Uri>[];
    final provider = WeatherProvider(
      stateStore: _MemoryStore(),
      environment: const {'HOME': '/nonexistent'},
      httpGet: (uri) async {
        if (uri.host.startsWith('geocoding')) {
          geocodingUris.add(uri);
          return <String, Object?>{};
        }
        return _forecastPayload(uri);
      },
    );
    await tester.binding.setSurfaceSize(const Size(1000, 700));
    await tester.pumpWidget(
      _wrapWithLocale(
        _panel(provider, snapshot: provider.latest),
        const Locale('ja'),
      ),
    );
    await tester.pump();

    await tester.enterText(
      find.byKey(const ValueKey('weather-search')),
      '東京',
    );
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();

    expect(geocodingUris, hasLength(1));
    expect(geocodingUris.single.queryParameters['name'], '東京');
    expect(geocodingUris.single.queryParameters['language'], 'ja');
    provider.dispose();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('单位切换：provider.units 变更 + 持久化 + 快照刷新', (tester) async {
    final store = _MemoryStore();
    final provider = _provider(store);
    // 首拉 metric 快照（21.4 → 21°）。
    await provider.refresh();
    await _pump(tester, _panel(provider, snapshot: provider.latest));
    // 当前大温度（`weather-current-temp`）21.4 → 21°（小时条另有 21°）。
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('weather-current-temp')))
          .data,
      '21°',
    );

    await tester.tap(find.byKey(const ValueKey('weather-units-imperial')));
    await tester.pump();
    await tester.pump();

    expect(provider.units, KosWeatherUnits.imperial);
    // 快照经流回流：imperial 档温度 70.5 → 71°。
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('weather-current-temp')))
          .data,
      '71°',
    );
    // 持久化：状态负载含 `units` 键。
    expect(store.payload?['units'], 'imperial');
    provider.dispose();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('provider 快照流更新面板（setUnits 重取后 UI 更新）', (tester) async {
    final provider = _provider(_MemoryStore());
    await provider.refresh();
    await _pump(tester, _panel(provider, snapshot: provider.latest));
    expect(tester.widget<Text>(find.byKey(const ValueKey('weather-city'))).data, '长沙'); // 默认位置名（未 start 不读盘）
    // 切 imperial 后 stream 推新快照（内存 state 无真实 IO）。
    await provider.setUnits(KosWeatherUnits.imperial);
    await tester.pump();
    await tester.pump();
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('weather-current-temp')))
          .data,
      '71°',
    );
    provider.dispose();
    await tester.pumpWidget(const SizedBox());
  });
}
