// Open-Meteo backed dock weather provider plus file-backed state store.
//
// Trimmed port of plugins/kos_deskcenter/lib/src/data/weather_provider.dart
// which ports kos/system_service/weather.go. Only the dock's data needs are
// kept (current conditions + today's sunrise/sunset); the deskcenter
// locations CRUD, units switching, and geocoding are not ported.
//
// State file: `$XDG_STATE_HOME/denial/kos_dock/weather.json` — the `kos_dock`
// directory keeps it separate from deskcenter's `kos_deskcenter` cache.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'dock_weather.dart';

/// Default location: 长沙 (Changsha).
///
/// Sources:
/// - KOS: kos/system_service/weather.go:118-128 (defaultWeatherState)
/// - Ported from: kos_deskcenter/lib/src/data/weather_provider.dart
const DockWeatherLocation kDockWeatherDefaultLocation = DockWeatherLocation(
  id: 'legacy:changsha',
  name: '长沙',
  admin1: '湖南',
  country: '中国',
  countryCode: 'CN',
  latitude: 28.2282,
  longitude: 112.9388,
  timezone: 'Asia/Shanghai',
);

/// Normal refresh / stale / timeout / backoff constants.
///
/// KOS: kos/system_service/weather.go:26-34.
const Duration kDockWeatherRefreshInterval = Duration(hours: 1); // :26
const Duration kDockWeatherStaleInterval = Duration(hours: 2); // :27
const Duration kDockWeatherRequestTimeout = Duration(seconds: 20); // :28
const Duration kDockWeatherBackoffBase = Duration(minutes: 1); // :33
const Duration kDockWeatherBackoffMax = Duration(minutes: 30); // :34

/// `weatherBackoff` (weather.go:552-565): 1min doubling, shift cap 9,
/// ceiling 30min.
Duration dockWeatherBackoff(int streak) {
  var shift = (streak < 1 ? 1 : streak) - 1;
  if (shift > 9) shift = 9;
  final backoff = kDockWeatherBackoffBase * (1 << shift);
  return backoff > kDockWeatherBackoffMax ? kDockWeatherBackoffMax : backoff;
}

/// Builds the Open-Meteo forecast URL (also used by tests).
///
/// KOS: kos/system_service/weather.go:289-306 — dock projection keeps only
/// `current` fields + `daily` sunrise/sunset/weather_code, forecast_days=1,
/// units fixed to metric.
Uri dockWeatherForecastUrl(DockWeatherLocation location) {
  return Uri.https('api.open-meteo.com', '/v1/forecast', <String, String>{
    'latitude': location.latitude.toStringAsFixed(6),
    'longitude': location.longitude.toStringAsFixed(6),
    'current': <String>[
      'temperature_2m',
      'relative_humidity_2m',
      'apparent_temperature',
      'is_day',
      'weather_code',
      'wind_speed_10m',
      'wind_direction_10m',
    ].join(','), // weather.go:292
    'daily': 'weather_code,sunrise,sunset', // weather.go:294 subset
    'timezone': 'auto',
    'forecast_days': '1', // dock only consumes daily[0] (weather.go:296)
    'temperature_unit': 'celsius', // weather.go:303-305 metric
    'wind_speed_unit': 'kmh',
    'precipitation_unit': 'mm',
  });
}

/// dart:io `HttpClient` GET. Returns the decoded JSON object.
///
/// Accept/User-Agent + 2MiB body cap per weather.go:216-218,29.
Future<Map<String, Object?>> _defaultHttpGet(Uri uri) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(uri);
    request.headers.set('Accept', 'application/json');
    request.headers.set(
      'User-Agent',
      'Denial/kos_dock (+https://open-meteo.com)',
    );
    final response = await request.close();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      await response.drain<void>();
      throw HttpException(
        'weather provider returned HTTP ${response.statusCode}',
        uri: uri,
      );
    }
    final body = await response.fold<List<int>>(<int>[], (buffer, chunk) {
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

/// JSON-backed weather state store for the dock (tmp+rename atomic write).
///
/// Ported from kos_deskcenter `weather_provider.dart` `FileWeatherStateStore`
/// (CONSTRAINTS §12); state path moved to `denial/kos_dock/weather.json` so
/// it never collides with deskcenter's cache.
final class FileDockWeatherStateStore implements DockWeatherStateStore {
  FileDockWeatherStateStore({String? path, Map<String, String>? environment})
      : path = path ?? _defaultPath(environment ?? Platform.environment);

  final String path;

  /// `$XDG_STATE_HOME/denial/kos_dock/weather.json`; falls back to
  /// `$HOME/.local/state` when XDG_STATE_HOME is unset.
  static String _defaultPath(Map<String, String> env) {
    final stateHome = (env['XDG_STATE_HOME']?.isNotEmpty ?? false)
        ? env['XDG_STATE_HOME']!
        : '${env['HOME'] ?? Directory.current.path}/.local/state';
    return '$stateHome/denial/kos_dock/weather.json';
  }

  @override
  Future<Map<String, Object?>?> read() async {
    try {
      final file = File(path);
      if (!await file.exists()) return null;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is Map) {
        return decoded.map((k, v) => MapEntry(k.toString(), v));
      }
    } on Object {
      // Missing/corrupt → null (caller falls back to defaults).
    }
    return null;
  }

  @override
  Future<void> write(Map<String, Object?> payload) async {
    try {
      final file = File(path);
      await file.parent.create(recursive: true);
      final tmp = File('$path.tmp');
      await tmp.writeAsString(jsonEncode(payload));
      await tmp.rename(path);
    } on Object {
      // Persistence failure must not break refresh.
    }
  }
}

/// Dock weather provider backed by Open-Meteo.
///
/// Ported (trimmed) from kos_deskcenter `weather_provider.dart`
/// `KosWeatherProvider` — start/refresh/backoff/persist structure mirrors
/// weather.go:580-605; differences: single location (no locations list),
/// metric units fixed, single snapshot stream, no dbus surface.
final class OpenMeteoDockWeatherProvider implements DockWeatherProvider {
  OpenMeteoDockWeatherProvider({
    DockWeatherHttpGet? httpGet,
    DockWeatherStateStore? stateStore,
    DateTime Function()? now,
    this.refreshInterval = kDockWeatherRefreshInterval,
    this.staleInterval = kDockWeatherStaleInterval,
    this.requestTimeout = kDockWeatherRequestTimeout,
  })  : _httpGet = httpGet ?? _defaultHttpGet,
        _stateStore = stateStore ?? FileDockWeatherStateStore(),
        _now = now ?? DateTime.now;

  final DockWeatherHttpGet _httpGet;
  final DockWeatherStateStore _stateStore;
  final DateTime Function() _now;

  /// weather.go:26-28.
  final Duration refreshInterval;
  final Duration staleInterval;
  final Duration requestTimeout;

  final StreamController<DockWeatherSnapshot> _snapshots =
      StreamController<DockWeatherSnapshot>.broadcast();
  Timer? _timer;

  DockWeatherLocation _location = kDockWeatherDefaultLocation;
  DockWeatherSnapshot? _latest;
  DateTime? _fetchedAt;
  DateTime? _nextRefreshAt;
  bool _disposed = false;
  bool _fetching = false;
  int _failStreak = 0;

  /// Current location (last persisted or the 长沙 default).
  DockWeatherLocation get location => _location;

  /// Last successful fetch wall-clock.
  DateTime? get fetchedAt => _fetchedAt;

  @override
  DockWeatherSnapshot? get latest => _latest;

  @override
  Stream<DockWeatherSnapshot> get snapshots => _snapshots.stream;

  /// Restores persisted location + cached snapshot, emits loading, fetches
  /// the first forecast, and starts the 1-minute heartbeat that drives the
  /// refresh/backoff schedule (weather.go main-loop equivalent). Idempotent.
  @override
  Future<void> start() async {
    if (_disposed) return;
    if (_latest == null || _latest!.status != 'ready') {
      _location = await _loadLocation();
      if (_latest == null) {
        _emit(DockWeatherSnapshot(status: 'loading', cityName: _location.name));
      }
      await refresh();
    }
    _timer ??= Timer.periodic(const Duration(minutes: 1), (_) {
      if (_disposed || _fetching) return;
      if (_nextRefreshAt != null && _now().isBefore(_nextRefreshAt!)) return;
      unawaited(refresh());
    });
  }

  /// Fetches one forecast immediately. On success emits `ready` and
  /// schedules the next refresh 1h out (weather.go:605); on failure keeps a
  /// previous ready snapshot (weather.go:584-587) or emits `error`, then
  /// schedules the retry via `dockWeatherBackoff` (weather.go:591).
  @override
  Future<DockWeatherSnapshot?> refresh() async {
    if (_disposed || _fetching) return _latest;
    _fetching = true;
    try {
      final payload = await _httpGet(dockWeatherForecastUrl(_location))
          .timeout(requestTimeout);
      _failStreak = 0;
      _fetchedAt = _now();
      _nextRefreshAt = _now().add(refreshInterval); // weather.go:605
      final snapshot = _projectSnapshot(payload, 'ready');
      _emit(snapshot);
      unawaited(_persist());
      return snapshot;
    } on Object {
      _failStreak += 1;
      _nextRefreshAt = _now().add(dockWeatherBackoff(_failStreak)); // :591
      if (_latest != null && _latest!.status == 'ready') {
        return _latest; // keep last good snapshot (weather.go:584-587)
      }
      _emit(DockWeatherSnapshot(status: 'error', cityName: _location.name));
      return _latest;
    } finally {
      _fetching = false;
    }
  }

  /// Sets the location (trimmed `weather.set-location` equivalent):
  /// normalizes, persists, refreshes.
  ///
  /// `normalizeWeatherLocation` (weather.go:193-203): trim + validity check +
  /// `manual:lat,lon` id fallback.
  Future<void> setLocation(DockWeatherLocation location) async {
    var normalized = location;
    if (normalized.id.isEmpty && normalized.valid) {
      normalized = DockWeatherLocation(
        id: 'manual:${normalized.latitude.toStringAsFixed(5)},'
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
    await _persist();
    await refresh();
  }

  /// Stops refresh and closes the stream; the object is not reusable.
  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    unawaited(_snapshots.close());
  }

  void _emit(DockWeatherSnapshot snapshot) {
    _latest = snapshot;
    if (!_snapshots.isClosed) _snapshots.add(snapshot);
  }

  /// Open-Meteo response → [DockWeatherSnapshot] projection.
  ///
  /// Field map ports weather.go:312-340 + `dailyTime`
  /// (WeatherService.qml:62-67 — `T(\d{2}:\d{2})` regex on daily[0]).
  DockWeatherSnapshot _projectSnapshot(
    Map<String, Object?> payload,
    String status,
  ) {
    final current = switch (payload['current']) {
      final Map m => m.map((k, v) => MapEntry(k.toString(), v)),
      _ => const <String, Object?>{},
    };
    final daily = switch (payload['daily']) {
      final Map m => m.map((k, v) => MapEntry(k.toString(), v)),
      _ => const <String, Object?>{},
    };
    if (status == 'ready' && current['time'] == null) {
      throw const FormatException(
        'weather response has no current conditions',
      ); // weather.go:312-314
    }

    String dailyTime(String field) {
      final values = daily[field];
      final raw = values is List && values.isNotEmpty ? values.first : values;
      final match = RegExp(r'T(\d{2}:\d{2})').firstMatch('$raw');
      return match?.group(1) ?? '--:--';
    }

    double currentNumber(String key) => switch (current[key]) {
          final num v => v.toDouble(),
          _ => double.nan,
        };

    return DockWeatherSnapshot(
      status: status,
      cityName: _location.name,
      currentTemp: currentNumber('temperature_2m'),
      apparentTemp: currentNumber('apparent_temperature'),
      relativeHumidity: currentNumber('relative_humidity_2m'),
      windSpeed: currentNumber('wind_speed_10m'),
      weatherCode: switch (current['weather_code']) {
        final num v => v.toInt(),
        _ => -1,
      },
      isDay: current['is_day'] == 1, // weather.go:323 `IsDay == 1`
      sunrise: dailyTime('sunrise'),
      sunset: dailyTime('sunset'),
    );
  }

  /// Restores persisted state (`weather.json`): `location` sub-object (or
  /// flat top-level fields) + a ready snapshot cache; corrupt → 长沙 default.
  Future<DockWeatherLocation> _loadLocation() async {
    final map = await _stateStore.read();
    if (map != null) {
      final locationJson = switch (map['location']) {
        final Map m => m.map((k, v) => MapEntry(k.toString(), v)),
        _ => map,
      };
      var location = DockWeatherLocation.fromJson(locationJson);
      if (!location.valid) location = kDockWeatherDefaultLocation;
      // Cached snapshot restore (weather.go durable-state equivalent).
      final restored = DockWeatherSnapshot.fromJson(map);
      if (restored != null) {
        _latest = restored;
        final fetchedAt = switch (map['fetchedAt']) {
          final num v => v.toInt(),
          _ => 0,
        };
        if (fetchedAt > 0) {
          _fetchedAt = DateTime.fromMillisecondsSinceEpoch(fetchedAt);
        }
      }
      return location;
    }
    return kDockWeatherDefaultLocation; // weather.go:151-154 fallback
  }

  /// Persists the `WeatherState` subset: location + fetchedAt + snapshot.
  Future<void> _persist() async {
    final latest = _latest;
    await _stateStore.write(<String, Object?>{
      if (latest != null) ...latest.toJson(location: _location),
      'location': _location.toJson(),
      if (_fetchedAt != null)
        'fetchedAt': _fetchedAt!.millisecondsSinceEpoch,
    });
  }
}
