/// KOS Dock 信息卡区天气数据接口层（纯接口/模型层，无 dart:io）。
///
/// 接口/IO 分离（CONSTRAINTS §10）：本文件声明 [DockWeatherSnapshot]、
/// [DockWeatherLocation]、抽象 [DockWeatherProvider] 接口与
/// [DockWeatherStateStore]/`DockWeatherHttpGet` 注入点类型；Open-Meteo
/// dart:io 实现在 `dock_weather_io.dart`（`OpenMeteoDockWeatherProvider` +
/// `FileDockWeatherStateStore`）。测试注入假实现时不触网络/文件。
///
/// 模型语义锚定 NextKde `shell/desktop/modules/weather/WeatherService.qml`：
/// `available`/`temperature`/`apparentTemperature`/`humidity`/`windSpeed`/
/// `sunrise`/`sunset`/`conditionText`/`conditionSymbol` 逐行对应（见各字段
/// 注释）；采集语义（Open-Meteo 端点/1h 刷新/退避/超时/默认长沙）在 io
/// 实现内继续标注 `weather.go:行号`。
library;

/// 天气位置（`WeatherLocation`，weather.go:37-46 的精简投影）。
///
/// 拷自 kos_deskcenter `weather_provider.dart:120-179` `KosWeatherLocation`
/// （CONSTRAINTS §12 拷贝并标注来源）。
final class DockWeatherLocation {
  const DockWeatherLocation({
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

  factory DockWeatherLocation.fromJson(Map<String, Object?> json) =>
      DockWeatherLocation(
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

/// Dock 天气卡的快照投影（`WeatherService.qml` `current`/`daily[0]` 的消费
/// 字段子集）。
///
/// - `status`：idle/loading/ready/error（WeatherService.qml:18,29-31；
///   `available == status=='ready'`——KOS 以 `current !== null` 判
///   available（:30），本投影只有 ready 帧携带 current 字段，故等价于
///   status 判定，记 docs/visual-deltas.md）；
/// - `cityName`：`location.name`（WeatherService.qml:26，缺省 `--`）；
/// - `currentTemp/apparentTemp/relativeHumidity/windSpeed`：`current.*`
///   （WeatherService.qml:32-44；缺失 → NaN，显示 `--`/`--°`）；
/// - `weatherCode`：`current.weatherCode`（:36，缺失 → -1）；
/// - `isDay`：`current.isDay`（:37，缺失 → true）；
/// - `sunrise/sunset`：`daily[0].sunrise/sunset` 的 `HH:mm`（:45-46,62-67
///   `dailyTime`——`T(\d{2}:\d{2})` 正则截取，缺失 → `--:--`）。
final class DockWeatherSnapshot {
  const DockWeatherSnapshot({
    this.status = 'idle',
    this.cityName = '--',
    this.currentTemp = double.nan,
    this.apparentTemp = double.nan,
    this.relativeHumidity = double.nan,
    this.windSpeed = double.nan,
    this.weatherCode = -1,
    this.isDay = true,
    this.sunrise = '--:--',
    this.sunset = '--:--',
  });

  final String status;
  final String cityName;
  final double currentTemp;
  final double apparentTemp;
  final double relativeHumidity;
  final double windSpeed;
  final int weatherCode;
  final bool isDay;
  final String sunrise;
  final String sunset;

  /// WeatherService.qml:30 `available`（本投影：ready 即 current 非空）。
  bool get available => status == 'ready';

  /// `temperature`（WeatherService.qml:32-33）。
  String get temperature =>
      available && currentTemp.isFinite ? '${currentTemp.round()}°' : '--°';

  /// `apparentTemperature`（WeatherService.qml:34-35）。
  String get apparentTemperature =>
      available && apparentTemp.isFinite ? '${apparentTemp.round()}°' : '--°';

  /// `humidity`（WeatherService.qml:38-39）。
  String get humidity =>
      available && relativeHumidity.isFinite
          ? '${relativeHumidity.round()}%'
          : '--';

  /// `windSpeed`（WeatherService.qml:40-42；v1 恒 metric `km/h`，无
  /// imperial 档位——deskcenter 的 units 持久化未随精简投影携带，记
  /// docs/visual-deltas.md）。
  String get windSpeedLabel =>
      available && windSpeed.isFinite ? '${windSpeed.round()} km/h' : '--';

  /// 序列化为 `weather.json` 缓存负载（含 `schemaVersion`/`location`/
  /// `current`/`daily`，weather.go:78-95 `WeatherState` 的字段子集）。
  Map<String, Object?> toJson({required DockWeatherLocation location}) {
    double? finite(double v) => v.isFinite ? v : null;
    return {
      'schemaVersion': 1,
      'provider': 'open-meteo',
      'status': status,
      'location': {'id': location.id, 'name': cityName},
      'current': {
        'temperature': finite(currentTemp),
        'apparentTemperature': finite(apparentTemp),
        'relativeHumidity': finite(relativeHumidity),
        'weatherCode': weatherCode,
        'isDay': isDay,
        'windSpeed': finite(windSpeed),
      },
      'daily': [
        {'sunrise': sunrise, 'sunset': sunset},
      ],
    };
  }

  /// 从缓存负载恢复 ready 快照（`_restoreSnapshot` 等价物）：非 ready /
  /// 字段损坏 → null。
  static DockWeatherSnapshot? fromJson(Map<String, Object?> map) {
    if (map['status'] != 'ready' || map['current'] is! Map) return null;
    try {
      final location = switch (map['location']) {
        final Map m => m.map((k, v) => MapEntry(k.toString(), v)),
        _ => const <String, Object?>{},
      };
      final current = (map['current']! as Map)
          .map((k, v) => MapEntry(k.toString(), v));
      final daily = map['daily'];
      final day = daily is List && daily.isNotEmpty && daily.first is Map
          ? (daily.first as Map).map((k, v) => MapEntry(k.toString(), v))
          : const <String, Object?>{};
      double currentNumber(String key) => switch (current[key]) {
        final num v => v.toDouble(),
        _ => double.nan,
      };
      return DockWeatherSnapshot(
        status: 'ready',
        cityName: location['name']?.toString() ?? '--',
        currentTemp: currentNumber('temperature'),
        apparentTemp: currentNumber('apparentTemperature'),
        relativeHumidity: currentNumber('relativeHumidity'),
        windSpeed: currentNumber('windSpeed'),
        weatherCode: switch (current['weatherCode']) {
          final num v => v.toInt(),
          _ => -1,
        },
        isDay: current['isDay'] == true,
        sunrise: day['sunrise']?.toString() ?? '--:--',
        sunset: day['sunset']?.toString() ?? '--:--',
      );
    } on Object {
      return null;
    }
  }
}

/// `WeatherService.conditionText`（WeatherService.qml:69-82）逐行移植。
///
/// 拷自 kos_deskcenter `weather_card.dart:330-343` `kosWeatherConditionText`。
String dockWeatherConditionText(int code) {
  if (code == 0) return '晴';
  if (code == 1) return '大部晴朗';
  if (code == 2) return '局部多云';
  if (code == 3) return '阴';
  if (code == 45 || code == 48) return '雾';
  if (code >= 51 && code <= 57) return '毛毛雨';
  if (code >= 61 && code <= 67) return '雨';
  if (code >= 71 && code <= 77) return '雪';
  if (code >= 80 && code <= 82) return '阵雨';
  if (code >= 85 && code <= 86) return '阵雪';
  if (code >= 95) return '雷暴';
  return '天气未知';
}

/// `WeatherService.conditionSymbol`（WeatherService.qml:84-94）逐行移植。
///
/// 拷自 kos_deskcenter `weather_card.dart:346-356` `kosWeatherConditionSymbol`。
String dockWeatherConditionSymbol(int code, {required bool isDay}) {
  if (code == 0) return isDay ? '☀' : '☾';
  if (code == 1 || code == 2) return isDay ? '⛅' : '☁';
  if (code == 3) return '☁';
  if (code == 45 || code == 48) return '≋';
  if (code >= 51 && code <= 67) return '☔';
  if (code >= 80 && code <= 82) return '☔';
  if ((code >= 71 && code <= 77) || (code >= 85 && code <= 86)) return '❄';
  if (code >= 95) return 'ϟ';
  return '?';
}

/// 天气数据提供者接口（CONSTRAINTS §10：测试注入假实现）。
///
/// 生产实现 `OpenMeteoDockWeatherProvider`（`dock_weather_io.dart`）；
/// `start()` 恢复缓存 → 发 loading → 拉首份预报并按节奏自动刷新（幂等）。
abstract interface class DockWeatherProvider {
  /// 最近一次快照（含 loading/error 态）；尚无任何状态时为 null。
  DockWeatherSnapshot? get latest;

  /// 快照广播流。
  Stream<DockWeatherSnapshot> get snapshots;

  /// 启动（幂等）：恢复持久化状态、拉取首份、按内部节奏自动刷新。
  Future<void> start();

  /// 立即拉取一次预报；实现须保留上一份 ready 快照不丢（weather.go:
  /// 584-587 降级语义）。
  Future<DockWeatherSnapshot?> refresh();

  /// 停止刷新并关闭流；之后对象不可复用。
  void dispose();
}

/// 状态持久化注入点：读写 `weather.json` 形状的负载（位置字段 + 快照缓存）。
///
/// 拷自 kos_deskcenter `weather_provider.dart:37-44` `WeatherStateStore`。
abstract interface class DockWeatherStateStore {
  /// 读取负载；文件缺失/损坏返回 null。
  Future<Map<String, Object?>?> read();

  /// 写入负载（实现须尽力原子；失败不抛穿）。
  Future<void> write(Map<String, Object?> payload);
}

/// GET JSON 的注入点：返回解码后的 JSON 对象；HTTP/网络错误自行抛出。
///
/// 拷自 kos_deskcenter `weather_provider.dart:82` `WeatherHttpGet`。
typedef DockWeatherHttpGet = Future<Map<String, Object?>> Function(Uri uri);
