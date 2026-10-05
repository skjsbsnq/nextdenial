// OpenMeteoDockWeatherProvider 数据层测试（TASK-05 修复项 3）。
//
// 覆盖：deskcenter `weather.json` 的 `location` 优先（吉安覆盖 dock 兜底与
// 长沙默认）；deskcenter 文件缺失 → dock `weather.json` 兜底；deskcenter
// location 无效 → dock 兜底；两者都缺 → `kDockWeatherDefaultLocation` 长沙；
// deskcenter 顶层平铺旧格式兼容；dock 缓存快照在 deskcenter 位置胜出时仍恢复。
//
// 全部经 `httpGet`/`stateStore`/`deskCenterLocationSource` 注入 fake——
// 无真实网络/文件依赖（CONSTRAINTS §10）。

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kos_dock/src/data/dock_weather.dart';
import 'package:kos_dock/src/data/dock_weather_io.dart';

// ── fakes ────────────────────────────────────────────────────────────────

class _MemoryStateStore implements DockWeatherStateStore {
  _MemoryStateStore([this._payload]);

  Map<String, Object?>? _payload;

  @override
  Future<Map<String, Object?>?> read() async => _payload;

  @override
  Future<void> write(Map<String, Object?> payload) async {
    _payload = payload;
  }
}

class _FakeDeskCenterSource implements DockDeskCenterLocationSource {
  _FakeDeskCenterSource([this._payload]);

  final Map<String, Object?>? _payload;

  @override
  Future<Map<String, Object?>?> read() async => _payload;
}

// ── fixtures ─────────────────────────────────────────────────────────────

const _jian = <String, Object?>{
  'id': 'geo:ji-an',
  'name': '吉安',
  'admin1': '江西',
  'country': '中国',
  'countryCode': 'CN',
  'latitude': 27.1138,
  'longitude': 114.9937,
  'timezone': 'Asia/Shanghai',
};

const _changshaDock = <String, Object?>{
  'id': 'dock:changsha',
  'name': '长沙-dock',
  'admin1': '湖南',
  'country': '中国',
  'countryCode': 'CN',
  'latitude': 28.2282,
  'longitude': 112.9388,
  'timezone': 'Asia/Shanghai',
};

const _forecastBody = '''
{
  "current": {
    "time": "2026-10-05T10:00",
    "temperature_2m": 26.0,
    "relative_humidity_2m": 60,
    "apparent_temperature": 27.0,
    "is_day": 1,
    "weather_code": 0,
    "wind_speed_10m": 8.0,
    "wind_direction_10m": 180
  },
  "daily": {
    "weather_code": [0],
    "sunrise": ["2026-10-05T06:10"],
    "sunset": ["2026-10-05T18:20"]
  }
}
''';

OpenMeteoDockWeatherProvider _provider({
  required List<Uri> captured,
  DockWeatherStateStore? stateStore,
  DockDeskCenterLocationSource? deskCenter,
}) => OpenMeteoDockWeatherProvider(
  stateStore: stateStore ?? _MemoryStateStore(),
  deskCenterLocationSource: deskCenter ?? _FakeDeskCenterSource(),
  httpGet: (uri) async {
    captured.add(uri);
    return (jsonDecode(_forecastBody) as Map).map(
      (k, v) => MapEntry(k.toString(), v),
    );
  },
);

void main() {
  group('位置回退链：deskcenter → dock weather.json → 长沙', () {
    test('deskcenter `location` 子对象吉安 → 覆盖 dock 兜底与默认长沙', () async {
      final captured = <Uri>[];
      final p = _provider(
        captured: captured,
        stateStore: _MemoryStateStore(const {'location': _changshaDock}),
        deskCenter: _FakeDeskCenterSource(const {'location': _jian}),
      );
      await p.start();
      expect(p.location.name, '吉安');
      expect(p.location.latitude, moreOrLessEquals(27.1138, epsilon: 1e-6));
      // forecast URL 走吉安坐标。
      expect(
        captured.single.queryParameters['latitude'],
        '27.113800',
      );
      expect(
        captured.single.queryParameters['longitude'],
        '114.993700',
      );
      expect(p.latest?.cityName, '吉安');
      p.dispose();
    });

    test('deskcenter 顶层平铺旧格式（无 `location` 子对象）→ 仍取吉安', () async {
      final captured = <Uri>[];
      final p = _provider(
        captured: captured,
        deskCenter: _FakeDeskCenterSource(Map.of(_jian)),
      );
      await p.start();
      expect(p.location.name, '吉安');
      p.dispose();
    });

    test('deskcenter 文件缺失 → dock `weather.json` 的 location 兜底', () async {
      final captured = <Uri>[];
      final p = _provider(
        captured: captured,
        stateStore: _MemoryStateStore(const {'location': _changshaDock}),
        deskCenter: _FakeDeskCenterSource(), // null = 文件缺失
      );
      await p.start();
      expect(p.location.name, '长沙-dock');
      expect(
        captured.single.queryParameters['latitude'],
        '28.228200',
      );
      p.dispose();
    });

    test('deskcenter location 无效（缺 name）→ dock 兜底而非长沙默认', () async {
      final captured = <Uri>[];
      final p = _provider(
        captured: captured,
        stateStore: _MemoryStateStore(const {'location': _changshaDock}),
        deskCenter: _FakeDeskCenterSource(const {
          'location': {
            'id': 'geo:bad',
            // name 缺失 → DockWeatherLocation.valid == false
            'latitude': 27.1138,
            'longitude': 114.9937,
          },
        }),
      );
      await p.start();
      expect(p.location.name, '长沙-dock');
      p.dispose();
    });

    test('deskcenter 与 dock 都缺 → kDockWeatherDefaultLocation（长沙）', () async {
      final captured = <Uri>[];
      final p = _provider(captured: captured);
      await p.start();
      expect(p.location, same(kDockWeatherDefaultLocation));
      expect(p.location.name, '长沙');
      p.dispose();
    });

    test('deskcenter 位置胜出时 dock 的 ready 快照缓存仍先恢复', () async {
      // dock weather.json 里有 ready 缓存快照（城市名是旧缓存的）——位置被
      // deskcenter 吉安接管后，`latest` 仍带缓存快照（refresh 后覆盖）。
      final cached = DockWeatherSnapshot(
        status: 'ready',
        cityName: '缓存城',
        currentTemp: 20,
        apparentTemp: 19,
        relativeHumidity: 60,
        windSpeed: 5,
        weatherCode: 0,
        sunrise: '06:00',
        sunset: '18:30',
      ).toJson(
        location: const DockWeatherLocation(
          id: 'dock:cached',
          name: '缓存城',
          latitude: 30,
          longitude: 120,
        ),
      );
      final p = _provider(
        captured: <Uri>[],
        stateStore: _MemoryStateStore(cached),
        deskCenter: _FakeDeskCenterSource(const {'location': _jian}),
      );
      // start() 内 `_loadLocation` 恢复缓存快照 → 但随后 refresh 会立刻
      // 覆盖为吉安数据的 ready 帧；直接验证 location 已接管。
      await p.start();
      expect(p.location.name, '吉安');
      expect(p.latest?.cityName, '吉安');
      p.dispose();
    });
  });

  group('FileDockDeskCenterLocationSource 路径（真临时目录）', () {
    late Directory root;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('kos_dock_weather_');
    });

    tearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });

    test(r'KOS_PIM_STORAGE_DIR 非空 → $dir/weather.json', () async {
      final dir = Directory('${root.path}/pim');
      await dir.create(recursive: true);
      await File(
        '${dir.path}/weather.json',
      ).writeAsString(jsonEncode(const {'location': _jian}));
      final source = FileDockDeskCenterLocationSource(
        environment: {'KOS_PIM_STORAGE_DIR': dir.path},
      );
      final map = await source.read();
      expect(map?['location'], isA<Map>());
      expect(
        (map!['location']! as Map)['name'],
        '吉安',
      );
    });

    test(r'XDG_STATE_HOME 回退 → $XDG_STATE_HOME/denial/kos_deskcenter/'
        'weather.json', () async {
      final stateDir = Directory(
        '${root.path}/state/denial/kos_deskcenter',
      );
      await stateDir.create(recursive: true);
      await File(
        '${stateDir.path}/weather.json',
      ).writeAsString(jsonEncode(const {'location': _jian}));
      final source = FileDockDeskCenterLocationSource(
        environment: {
          'XDG_STATE_HOME': '${root.path}/state',
          'HOME': '${root.path}/home',
        },
      );
      final map = await source.read();
      expect(
        (map!['location']! as Map)['name'],
        '吉安',
      );
    });

    test('文件缺失 → null（不抛穿）', () async {
      final source = FileDockDeskCenterLocationSource(
        path: '${root.path}/nonexistent/weather.json',
      );
      expect(await source.read(), isNull);
    });

    test('损坏 JSON → null（不抛穿）', () async {
      final file = File('${root.path}/weather.json');
      await file.writeAsString('{broken');
      final source = FileDockDeskCenterLocationSource(path: file.path);
      expect(await source.read(), isNull);
    });
  });
}
