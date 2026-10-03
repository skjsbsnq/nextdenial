/// 插件内嵌天气提供者（`WeatherProvider`）。
///
/// `kos-data.sock` 在 Denial 会话不存在，本提供者把 NextKde
/// `services/data-service/weather.go` 的 Open-Meteo 采集与降级语义直接移植为
/// Dart，产出 `WeatherSnapshot`（weather_card.dart:69-156 已消费的结构）。
///
/// 逐项语义对应（weather.go 行号锚点）：
/// - 端点与字段集：`OpenMeteoProvider.Forecast`（weather.go:285-381）——
///   `api.open-meteo.com/v1/forecast`，current/hourly/daily 参数集逐字一致；
///   WeatherSnapshot 投影只消费 current.temperature/weatherCode/isDay +
///   daily[≤7].temperatureMaximum/Minimum/weatherCode/date（weather-v1
///   schema，weather_card.dart:113-155）；
/// - 节奏：`weatherRefreshInterval` 1h / `weatherStaleInterval` 2h /
///   `weatherRequestTimeout` 20s（weather.go:26-28）；
/// - 失败退避：`weatherBackoff`（weather.go:549-565）——1min 起逐次翻倍、
///   封顶 30min；
/// - 位置：默认长沙（`defaultWeatherState` weather.go:118-128），持久化到
///   `$XDG_STATE_HOME/denial/kos_deskcenter/weather.json`（
///   `KOS_PIM_STORAGE_DIR`/`XDG_STATE_HOME` env 缺省回退
///   `$HOME/.local/state`，与 DeskCenterConfigStore 同目录约定）；
/// - 位置搜索（Open-Meteo geocoding，weather.go:397-435）为可选方法。
///
/// HTTP 经构造注入的 [WeatherHttpGet] 回调（默认 dart:io `HttpClient`），
/// 单测可喂 mock 不触网络。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../widgets/weather_card.dart'
    show WeatherDay, WeatherHourly, WeatherSnapshot;

/// 状态持久化注入点：读写 `weather.json` 形状的负载（位置字段 + `units`）。
/// 默认实现 [FileWeatherStateStore]（原子 tmp+rename）；单测可注入内存实现
/// （widget 测试的 fake-async 区不驱动真实文件 IO）。
abstract interface class WeatherStateStore {
  /// 读取负载；文件缺失/损坏返回 null。
  Future<Map<String, Object?>?> read();

  /// 写入负载（实现须尽力原子；失败不抛穿）。
  Future<void> write(Map<String, Object?> payload);
}

/// `dart:io` 文件实现（`$path.tmp` → rename）。
final class FileWeatherStateStore implements WeatherStateStore {
  const FileWeatherStateStore(this.path);

  final String path;

  @override
  Future<Map<String, Object?>?> read() async {
    try {
      final text = await File(path).readAsString();
      final decoded = jsonDecode(text);
      if (decoded is Map) {
        return decoded.map((k, v) => MapEntry(k.toString(), v));
      }
    } on Object {
      // 缺失/损坏 → null（调用方回退默认值）。
    }
    return null;
  }

  @override
  Future<void> write(Map<String, Object?> payload) async {
    try {
      final file = File(path);
      await file.parent.create(recursive: true);
      final tmp = File('$path.tmp');
      await tmp.writeAsString(
        const JsonEncoder.withIndent('  ').convert(payload),
      );
      await tmp.rename(path);
    } on Object {
      // 持久化失败不阻断刷新——状态仍在内存生效。
    }
  }
}

/// GET JSON 的注入点：返回解码后的 JSON 对象；HTTP/网络错误自行抛出。
typedef WeatherHttpGet = Future<Map<String, Object?>> Function(Uri uri);

/// 单位档（`weather.set-units` 的本地等价物；源端 `Units` metric/imperial，
/// weather.go 单位参数集）。持久化进 `weather.json` 的 `units` 键（旧文件
/// 无该键 → 回退 metric，向后兼容）。
enum KosWeatherUnits {
  metric('metric'),
  imperial('imperial');

  const KosWeatherUnits(this.wire);

  /// 持久化/协议用的字符串值。
  final String wire;

  /// 宽松解析：未知值回退 metric（对齐源端 normalize 的缺省档）。
  static KosWeatherUnits fromWire(Object? value) =>
      value == 'imperial' ? KosWeatherUnits.imperial : KosWeatherUnits.metric;

  /// Open-Meteo `temperature_unit`（weather.go:299-305 metric 档）。
  String get temperatureUnit =>
      this == KosWeatherUnits.metric ? 'celsius' : 'fahrenheit';

  /// Open-Meteo `wind_speed_unit`。
  String get windSpeedUnit => this == KosWeatherUnits.metric ? 'kmh' : 'mph';

  /// Open-Meteo `precipitation_unit`。
  String get precipitationUnit =>
      this == KosWeatherUnits.metric ? 'mm' : 'inch';

  /// 温度显示后缀（面板）。
  String get temperatureSuffix =>
      this == KosWeatherUnits.metric ? '°C' : '°F';

  /// 风速显示后缀（面板）。
  String get windSuffix => this == KosWeatherUnits.metric ? 'km/h' : 'mph';
}

/// 天气位置（`WeatherLocation`，weather.go:37-46）。
final class KosWeatherLocation {
  const KosWeatherLocation({
    required this.id,
    required this.name,
    this.admin1 = '',
    this.country = '',
    this.countryCode = '',
    required this.latitude,
    required this.longitude,
    this.timezone = '',
  });

  final String id;
  final String name;
  final String admin1;
  final String country;
  final String countryCode;
  final double latitude;
  final double longitude;
  final String timezone;

  /// `validWeatherLocation`（weather.go:185-191）。
  bool get valid =>
      name.trim().isNotEmpty &&
      latitude.isFinite &&
      longitude.isFinite &&
      latitude >= -90 &&
      latitude <= 90 &&
      longitude >= -180 &&
      longitude <= 180;

  factory KosWeatherLocation.fromJson(Map<String, Object?> json) =>
      KosWeatherLocation(
        id: json['id']?.toString() ?? '',
        name: json['name']?.toString() ?? '',
        admin1: json['admin1']?.toString() ?? '',
        country: json['country']?.toString() ?? '',
        countryCode: json['countryCode']?.toString() ?? '',
        latitude: switch (json['latitude']) {
          final num v => v.toDouble(),
          _ => double.nan,
        },
        longitude: switch (json['longitude']) {
          final num v => v.toDouble(),
          _ => double.nan,
        },
        timezone: json['timezone']?.toString() ?? '',
      );

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'admin1': admin1,
    'country': country,
    'countryCode': countryCode,
    'latitude': latitude,
    'longitude': longitude,
    'timezone': timezone,
  };
}

/// 内嵌 Open-Meteo 天气提供者。
///
/// 用法：`start()` 按当前位置拉取并按 1h/退避节奏自动刷新；
/// `dispose()` 停表。最新快照读 [latest]/[snapshots] 流。
final class WeatherProvider {
  WeatherProvider({
    this.refreshInterval = const Duration(hours: 1), // weather.go:26
    this.staleInterval = const Duration(hours: 2), // weather.go:27
    WeatherHttpGet? httpGet,
    String? statePath,
    WeatherStateStore? stateStore,
    Map<String, String>? environment,
    DateTime Function()? now,
  }) : _httpGet = httpGet ?? _defaultHttpGet,
       _stateStore =
           stateStore ??
           FileWeatherStateStore(statePath ?? _defaultStatePath(environment)),
       _now = now ?? DateTime.now;

  /// 默认 forecast 端点（weather.go:211）。
  static const String forecastUrl = 'https://api.open-meteo.com/v1/forecast';

  /// 默认 geocoding 端点（weather.go:212）。
  static const String geocodingUrl =
      'https://geocoding-api.open-meteo.com/v1/search';

  /// 请求超时（weather.go:28 `weatherRequestTimeout`）。
  static const Duration requestTimeout = Duration(seconds: 20);

  /// 失败退避基数/上限（weather.go:33-34 `weatherBackoffBase/Max`）。
  static const Duration backoffBase = Duration(minutes: 1);
  static const Duration backoffMax = Duration(minutes: 30);

  /// 正常刷新间隔（weather.go:26）。
  final Duration refreshInterval;

  /// 快照过期阈值（weather.go:27 `weatherStaleInterval`）；供容器层判断
  /// 数据陈旧（源端供 UI 置灰/标注 stale，本端快照内不单独标位）。
  final Duration staleInterval;

  final WeatherHttpGet _httpGet;

  /// 状态持久化（默认 [FileWeatherStateStore]；测试可注入内存实现）。
  final WeatherStateStore _stateStore;
  final DateTime Function() _now;

  /// 上次成功拉取时刻（`FetchedAt`，weather.go:604）；供 stale 判定。
  DateTime? _fetchedAt;

  /// 已存地点列表（`state.Weather.Locations`，weather.go:89/`setWeatherLocation`
  /// :455-473 的等价物）：选择地点时按 id upsert 并把该地点置顶为当前项，
  /// 上限 20 条（:471-472）；随 `weather.json` 持久化（`locations` 键）。
  /// 首元素恒为当前位置（normalizeWeatherState :155-166 同序）。
  List<KosWeatherLocation> _locations = const [defaultLocation];
  KosWeatherLocation _location = defaultLocation;

  /// 单位档（`weather.json` 的 `units` 键；[setUnits] 持久化并重取）。
  KosWeatherUnits _units = KosWeatherUnits.metric;

  WeatherSnapshot? _latest;
  Timer? _timer;
  bool _disposed = false;
  bool _fetching = false;
  int _failStreak = 0;

  final StreamController<WeatherSnapshot> _snapshots =
      StreamController<WeatherSnapshot>.broadcast();

  /// 默认位置长沙（`defaultWeatherState` weather.go:119-128）。
  static const KosWeatherLocation defaultLocation = KosWeatherLocation(
    id: 'legacy:changsha',
    name: '长沙',
    admin1: '湖南',
    country: '中国',
    countryCode: 'CN',
    latitude: 28.2282,
    longitude: 112.9388,
    timezone: 'Asia/Shanghai',
  );

  /// 当前位置。
  KosWeatherLocation get location => _location;

  /// 当前单位档（`units` 键，缺省 metric）。
  KosWeatherUnits get units => _units;

  /// 已存地点列表（只读视图，首元素为当前位置；weather.go:89
  /// `Locations`——Main.qml:344 `backend.locations` 的渲染源）。
  List<KosWeatherLocation> get locations => List.unmodifiable(_locations);

  /// 按 id 查已存地点（`--location <id>` 直达的查表入口，
  /// Main.qml:31-42 `selectPendingLocation` 的等价物）；未命中回 null。
  KosWeatherLocation? locationById(String id) {
    for (final entry in _locations) {
      if (entry.id == id) return entry;
    }
    return null;
  }

  /// 上次成功拉取时刻；供 `staleInterval` 过期判定。
  DateTime? get fetchedAt => _fetchedAt;

  /// 当前快照距上次成功拉取已超过 [staleInterval]（weather.go:27）。
  bool get stale =>
      _fetchedAt != null &&
      _now().difference(_fetchedAt!) > staleInterval;

  /// 最近一次快照（含 loading/error 态）；尚无任何状态时为 null。
  WeatherSnapshot? get latest => _latest;

  /// 快照广播流。
  Stream<WeatherSnapshot> get snapshots => _snapshots.stream;

  /// 状态文件路径：环境 `KOS_PIM_STORAGE_DIR` 覆盖目录，否则
  /// `$XDG_STATE_HOME/denial/kos_deskcenter/weather.json`；XDG_STATE_HOME
  /// 缺失回退 `$HOME/.local/state`（与 DeskCenterConfigStore 同约定，
  /// desk_center_config_io.dart:33-38）。
  static String _defaultStatePath(Map<String, String>? environment) {
    final env = environment ?? Platform.environment;
    final storageDir = env['KOS_PIM_STORAGE_DIR'];
    if (storageDir != null && storageDir.isNotEmpty) {
      return '$storageDir/weather.json';
    }
    final stateHome =
        env['XDG_STATE_HOME'] ?? '${env['HOME'] ?? ''}/.local/state';
    return '$stateHome/denial/kos_deskcenter/weather.json';
  }

  /// 恢复位置 → 发 loading → 拉取首份预报并按节奏自动刷新（幂等）。
  /// 首次拉取在返回前完成：调用方 `await start()` 后 [latest] 已含
  /// ready/error 终态（loading 帧仍经 [snapshots] 流先行发出）。
  Future<void> start() async {
    if (_disposed) return;
    if (_latest == null || _latest!.status != 'ready') {
      // _latest 已有 ready 缓存（_loadLocation 恢复）时跳过 loading 帧，
      // 直接后台 refresh 覆盖——重启后先显示旧数据而非「无数据」。
      _location = await _loadLocation();
      if (_latest == null) {
        _emit(
          WeatherSnapshot(
            status: 'loading',
            cityName: _location.name,
            locationId: _location.id,
          ),
        );
      }
      await refresh();
    }
    _timer ??= Timer.periodic(const Duration(minutes: 1), (_) {
      // 源端在主循环扫描 nextRefreshAt；本端用 1min 心跳 + 截止时间等价。
      if (_disposed || _fetching) return;
      if (_nextRefreshAt != null && _now().isBefore(_nextRefreshAt!)) return;
      unawaited(refresh());
    });
  }

  DateTime? _nextRefreshAt;

  /// 立即拉取一次预报；成功更新快照并调度 1h 后，失败保留上一份快照数据
  /// 并按 `weatherBackoff` 退避调度下次（weather.go:580-591）。
  Future<WeatherSnapshot?> refresh() async {
    if (_disposed || _fetching) return _latest;
    _fetching = true;
    try {
      final payload = await _fetchForecast(_location);
      _failStreak = 0;
      _fetchedAt = _now();
      _nextRefreshAt = _now().add(refreshInterval); // weather.go:605
      final snapshot = _projectSnapshot(payload, 'ready');
      _emit(snapshot);
      // 快照落盘（`current`/`daily`/`hourly` + `fetchedAt`）→ 下次启动
      // 先恢复缓存，无网/首拉失败也有旧数据显示（weather.go durable state）。
      unawaited(_persistLocation(_location));
      return snapshot;
    } on Object {
      _failStreak++;
      _nextRefreshAt = _now().add(weatherBackoff(_failStreak)); // :591
      if (_latest != null && _latest!.status == 'ready') {
        // 已有可用数据：保持 ready 快照不动（weather.go:584-587）。
        return _latest;
      }
      _emit(
        WeatherSnapshot(
          status: 'error',
          cityName: _location.name,
          locationId: _location.id,
        ),
      );
      return _latest;
    } finally {
      _fetching = false;
    }
  }

  /// 设置位置（`weather.set-location` 的本地等价物）：持久化 + 立即刷新。
  /// `normalizeWeatherLocation`（weather.go:193-203）：trim + 合法性校验 +
  /// id 缺省 `manual:lat,lon`（:201-202）。
  Future<void> setLocation(KosWeatherLocation location) async {
    var normalized = location;
    if (normalized.id.isEmpty && normalized.valid) {
      normalized = KosWeatherLocation(
        id:
            'manual:${normalized.latitude.toStringAsFixed(5)},'
            '${normalized.longitude.toStringAsFixed(5)}',
        name: normalized.name,
        admin1: normalized.admin1,
        country: normalized.country,
        countryCode: normalized.countryCode,
        latitude: normalized.latitude,
        longitude: normalized.longitude,
        timezone: normalized.timezone,
      );
    }
    if (!normalized.valid) {
      throw const FormatException('invalid weather location');
    }
    _location = normalized;
    _failStreak = 0;
    // setWeatherLocation（weather.go:459-473）：按 id upsert 并把当前位置
    // 保为列表首项（normalizeWeatherState :159-166 的不变量），上限 20 条。
    final rest = [
      for (final entry in _locations)
        if (entry.id != normalized.id) entry,
    ];
    _locations = [normalized, ...rest];
    if (_locations.length > 20) {
      _locations = _locations.sublist(0, 20); // weather.go:471-472
    }
    await _persistLocation(normalized);
    await refresh();
  }

  /// 设置单位档（`weather.set-units` 的本地等价物）：持久化 + 立即重取
  /// （源端 set-units 会重算缓存并要求客户端重拉）。
  Future<void> setUnits(KosWeatherUnits units) async {
    if (_disposed || _units == units) return;
    _units = units;
    await _persistLocation(_location);
    await refresh();
  }

  /// Open-Meteo geocoding 位置搜索（`Search`，weather.go:397-435）：
  /// query 2-128 字符、count 夹取 1..20、language 缺省 `en`。
  Future<List<KosWeatherLocation>> searchLocations(
    String query, {
    String language = 'en',
    int count = 8,
  }) async {
    final trimmed = query.trim();
    if (trimmed.length < 2 || trimmed.length > 128) {
      throw const FormatException(
        'weather search query must contain 2 to 128 characters',
      ); // weather.go:399-400
    }
    final clamped = count < 1 ? 1 : (count > 20 ? 20 : count); // :402-405
    final lang = language.trim().isEmpty || language.length > 16
        ? 'en'
        : language.trim(); // :407-409
    final uri = Uri.parse(geocodingUrl).replace(
      queryParameters: {
        'name': trimmed,
        'count': '$clamped',
        'language': lang,
        'format': 'json',
      },
    );
    final payload = await _httpGet(uri).timeout(requestTimeout);
    final results = payload['results'];
    if (results is! List) return const [];
    return [
      for (final entry in results)
        if (entry is Map)
          KosWeatherLocation(
            id: 'open-meteo:${entry['id']}',
            name: entry['name']?.toString().trim() ?? '',
            admin1: entry['admin1']?.toString().trim() ?? '',
            country: entry['country']?.toString().trim() ?? '',
            countryCode:
                entry['country_code']?.toString().trim().toUpperCase() ?? '',
            latitude: switch (entry['latitude']) {
              final num v => v.toDouble(),
              _ => double.nan,
            },
            longitude: switch (entry['longitude']) {
              final num v => v.toDouble(),
              _ => double.nan,
            },
            timezone: entry['timezone']?.toString().trim() ?? '',
          ),
    ].where((l) => l.valid).toList(); // weather.go:422-434 只留合法结果
  }

  /// 停止刷新并关闭流；之后对象不可复用。
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    unawaited(_snapshots.close());
  }

  void _emit(WeatherSnapshot snapshot) {
    _latest = snapshot;
    if (!_snapshots.isClosed) _snapshots.add(snapshot);
  }

  /// `Forecast` 的请求参数集（weather.go:289-306 逐字一致，metric 单位档）。
  Future<Map<String, Object?>> _fetchForecast(KosWeatherLocation loc) async {
    final uri = Uri.parse(forecastUrl).replace(
      queryParameters: {
        'latitude': loc.latitude.toStringAsFixed(6),
        'longitude': loc.longitude.toStringAsFixed(6),
        'current':
            'temperature_2m,relative_humidity_2m,apparent_temperature,'
            'is_day,weather_code,wind_speed_10m,wind_direction_10m', // :292
        'hourly':
            'temperature_2m,apparent_temperature,relative_humidity_2m,'
            'precipitation_probability,weather_code,is_day,wind_speed_10m',
        'daily':
            'weather_code,temperature_2m_max,temperature_2m_min,'
            'precipitation_probability_max,sunrise,sunset', // :294
        'timezone': 'auto',
        'forecast_days': '7', // :296
        'temperature_unit': _units.temperatureUnit,
        'wind_speed_unit': _units.windSpeedUnit,
        'precipitation_unit': _units.precipitationUnit, // :303-305
      },
    );
    final payload = await _httpGet(uri).timeout(requestTimeout);
    final current = payload['current'];
    if (current is! Map || current['time'] == null) {
      throw const FormatException(
        'weather response has no current conditions',
      ); // weather.go:312-314
    }
    return payload;
  }

  /// Open-Meteo 响应 → `WeatherSnapshot`（字段名 snake_case → schema 驼峰；
  /// daily 截断 ≤7，weather.go:367-369 / WeatherService.qml:50；hourly 截断
  /// ≤48，weather.go:330-347 `hourlyCount>48`）。
  WeatherSnapshot _projectSnapshot(Map<String, Object?> payload, String status) {
    final current = switch (payload['current']) {
      final Map m => m.map((k, v) => MapEntry(k.toString(), v)),
      _ => const <String, Object?>{},
    };
    final daily = switch (payload['daily']) {
      final Map m => m.map((k, v) => MapEntry(k.toString(), v)),
      _ => const <String, Object?>{},
    };
    final hourly = switch (payload['hourly']) {
      final Map m => m.map((k, v) => MapEntry(k.toString(), v)),
      _ => const <String, Object?>{},
    };
    final times = daily['time'];
    final codes = daily['weather_code'];
    final maxima = daily['temperature_2m_max'];
    final minima = daily['temperature_2m_min'];
    final dailyPrecip = daily['precipitation_probability_max'];
    final days = [
      if (times is List && codes is List && maxima is List && minima is List)
        for (var i = 0; i < times.length && i < 7; i++)
          WeatherDay(
            date: times[i]?.toString() ?? '',
            code: switch (i < codes.length ? codes[i] : null) {
              final num v => v.toInt(),
              _ => -1,
            },
            high: switch (i < maxima.length ? maxima[i] : null) {
              final num v => v.round(),
              _ => 0,
            },
            low: switch (i < minima.length ? minima[i] : null) {
              final num v => v.round(),
              _ => 0,
            },
            precipitationChance: switch (
              dailyPrecip is List && i < dailyPrecip.length
                  ? dailyPrecip[i]
                  : null) {
              final num v => v.round(),
              _ => 0,
            },
          ),
    ];
    final hourTimes = hourly['time'];
    final hourTemps = hourly['temperature_2m'];
    final hourCodes = hourly['weather_code'];
    final hourPrecip = hourly['precipitation_probability'];
    final hourIsDay = hourly['is_day'];
    final hours = [
      if (hourTimes is List && hourTemps is List)
        for (var i = 0; i < hourTimes.length && i < 48; i++)
          WeatherHourly(
            time: hourTimes[i]?.toString() ?? '',
            temperature: switch (i < hourTemps.length ? hourTemps[i] : null) {
              final num v => v.toDouble(),
              _ => double.nan,
            },
            code: switch (
              hourCodes is List && i < hourCodes.length ? hourCodes[i] : null) {
              final num v => v.toInt(),
              _ => -1,
            },
            isDay: hourIsDay is List && i < hourIsDay.length
                ? hourIsDay[i] == 1
                : true, // weather.go:343 `IsDay[index] == 1`
            precipitationChance: switch (
              hourPrecip is List && i < hourPrecip.length
                  ? hourPrecip[i]
                  : null) {
              final num v => v.round(),
              _ => 0,
            },
          ),
    ];
    return WeatherSnapshot(
      status: status,
      cityName: _location.name,
      locationId: _location.id,
      currentTemp: switch (current['temperature_2m']) {
        final num v => v.toDouble(),
        _ => double.nan,
      },
      weatherCode: switch (current['weather_code']) {
        final num v => v.toInt(),
        _ => -1,
      },
      isDay: current['is_day'] == 1, // weather.go:323 `IsDay == 1`
      forecast: days,
      // current 扩展字段（weather.go:316-325 `WeatherCurrent` 全量投影；
      // 卡片投影原丢弃，TASK-15 面板指标格消费）。
      apparentTemp: switch (current['apparent_temperature']) {
        final num v => v.toDouble(),
        _ => double.nan,
      },
      relativeHumidity: switch (current['relative_humidity_2m']) {
        final num v => v.toDouble(),
        _ => double.nan,
      },
      windSpeed: switch (current['wind_speed_10m']) {
        final num v => v.toDouble(),
        _ => double.nan,
      },
      windDirection: switch (current['wind_direction_10m']) {
        final num v => v.toDouble(),
        _ => double.nan,
      },
      currentTime: current['time']?.toString() ?? '',
      hourly: hours,
    );
  }

  /// 恢复持久化状态（`weather.json`）：新格式是 `WeatherState` 形状
  /// （`location`/`locations`/`units`/`fetchedAt` + 快照字段）；旧格式是
  /// 「位置字段平铺 + `units`」——读到 `locations` 缺失时按旧式解析。
  ///
  /// 同时恢复上一份 `ready` 快照到 [latest]（`current`/`daily`/`hourly`
  /// 缓存），重启后无需等首次网络拉取即可显示数据；`fetchedAt` 一并还原
  /// 供 stale 判定（对齐 weather.go `WeatherState`「durable state」语义）。
  Future<KosWeatherLocation> _loadLocation() async {
    final map = await _stateStore.read();
    if (map != null) {
      _units = KosWeatherUnits.fromWire(map['units']);
      // 已存地点列表（weather.go:155-166 normalize：`Locations` 缺失/为空
      // → 以当前 location 兜底；当前位置恒为首项）。
      final rawLocations = map['locations'];
      final parsed = [
        if (rawLocations is List)
          for (final entry in rawLocations)
            if (entry is Map)
              KosWeatherLocation.fromJson(
                entry.map((k, v) => MapEntry(k.toString(), v)),
              ),
      ].where((l) => l.valid).toList();
      // 当前位置：新格式在 `location` 子对象；旧格式在顶层平铺。
      final locationJson = switch (map['location']) {
        final Map m => m.map((k, v) => MapEntry(k.toString(), v)),
        _ => map,
      };
      var location = KosWeatherLocation.fromJson(locationJson);
      if (!location.valid) location = defaultLocation;
      _locations = [
        location,
        for (final entry in parsed)
          if (entry.id != location.id) entry,
      ];
      if (_locations.length > 20) _locations = _locations.sublist(0, 20);
      // 缓存快照恢复（`current`/`daily`/`hourly` + `fetchedAt`）。
      _restoreSnapshot(map);
      return location;
    }
    // 缺失/损坏 → 默认长沙（normalizeWeatherState 的 fallback，
    // weather.go:151-154）。
    return defaultLocation;
  }

  /// 从 `WeatherState` 负载恢复缓存快照：`status=='ready'` 且 current/daily
  /// 任一存在才还原；还原后的 `_latest`/`_fetchedAt` 让首帧直接显示旧数据
  /// （随后 `refresh()` 拉新覆盖）。损坏/非 ready → 跳过。
  void _restoreSnapshot(Map<String, Object?> map) {
    if (map['status'] != 'ready' || map['current'] is! Map) return;
    try {
      final snapshot = WeatherSnapshot.fromJson(map);
      _latest = snapshot;
      final fetchedAt = switch (map['fetchedAt']) {
        final num v => v.toInt(),
        _ => 0,
      };
      if (fetchedAt > 0) {
        _fetchedAt = DateTime.fromMillisecondsSinceEpoch(fetchedAt);
      }
    } on Object {
      // 快照字段损坏 → 不落 `_latest`，等价无缓存。
    }
  }

  /// 持久化负载 = `WeatherState` 形状（weather.go:78-95 的字段子集）：
  /// `schemaVersion`/`provider`/`status`/`units`/`location`/`locations`/
  /// `fetchedAt` + 缓存快照（`current`/`daily`/`hourly` 取 [_latest] 的
  /// `toJson` 投影）。旧读取路径忽略未知键，向后兼容。
  Future<void> _persistLocation(KosWeatherLocation location) async {
    final snapshotJson = _latest?.status == 'ready' ? _latest!.toJson() : null;
    await _stateStore.write({
      'schemaVersion': 1,
      'provider': 'open-meteo',
      'status': _latest?.status ?? 'idle',
      'units': _units.wire,
      'location': location.toJson(),
      'locations': [for (final entry in _locations) entry.toJson()],
      if (_fetchedAt != null)
        'fetchedAt': _fetchedAt!.millisecondsSinceEpoch,
      // 快照字段平铺（`current`/`daily`/`hourly`），与 WeatherState 同层。
      if (snapshotJson != null) ...{
        'current': snapshotJson['current'],
        'daily': snapshotJson['daily'],
        'hourly': snapshotJson['hourly'],
      },
    });
  }

  /// 默认 HTTP GET：dart:io `HttpClient`，Accept/User-Agent 对齐
  /// weather.go:216-218，2MiB 体上限（:29）。
  static Future<Map<String, Object?>> _defaultHttpGet(Uri uri) async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(uri);
      request.headers.set('Accept', 'application/json');
      request.headers.set(
        'User-Agent',
        'Denial/kos_deskcenter (+https://open-meteo.com)',
      );
      final response = await request.close();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        await response.drain<void>();
        throw HttpException(
          'weather provider returned HTTP ${response.statusCode}',
          uri: uri,
        );
      }
      final body = await response
          .fold<List<int>>(<int>[], (buffer, chunk) {
            buffer.addAll(chunk);
            if (buffer.length > 2 << 20) {
              throw const HttpException('weather response too large');
            }
            return buffer;
          });
      final decoded = jsonDecode(utf8.decode(body));
      if (decoded is Map) {
        return decoded.map((k, v) => MapEntry(k.toString(), v));
      }
      throw const FormatException('weather response is not a JSON object');
    } finally {
      client.close();
    }
  }
}

/// `weatherBackoff`（weather.go:552-565）逐行移植：1min 起逐次翻倍，
/// shift 封顶 9、上限 30min。
Duration weatherBackoff(int streak) {
  var shift = (streak < 1 ? 1 : streak) - 1;
  if (shift > 9) shift = 9;
  final backoff = WeatherProvider.backoffBase * (1 << shift);
  return backoff > WeatherProvider.backoffMax
      ? WeatherProvider.backoffMax
      : backoff;
}
