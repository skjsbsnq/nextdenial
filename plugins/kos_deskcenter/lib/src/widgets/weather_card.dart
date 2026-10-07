/// KOS DeskCenter 天气小部件（`KosWeatherCard`）。
///
/// 对齐 NextKde `DeskCenterWindow.qml` 的 weather 分支（Loader
/// :929-1167）：
/// - 天气图形层（:955-1083）：整层 `opacity: 0.34`（:959）、`clip: true`
///   （:958），源码注释明确 "Keep the weather artwork static"（:952-954）
///   ——**无动画**，所有子层静态：
///   - 太阳层（:961-981）：仅 `category=="clear" && isDay`（:963），
///     右 20 / 顶 5、70×70；8 条光线 2×12 半径 1、#ffe36a、绕
///     `origin(1,33)` 每 45° 旋转（:967-978），中心 28px 圆同色（:980）；
///   - 云层（:983-1018）：`partlyCloudy || overcast`（:986-987），两片
///     bundled SVG（"weather-cloud" w·0.34/h·0.36 @(-w,2)，
///     "weather-cloud-wide" w·0.30/h·0.29 @(w,h·0.18)）——本端以
///     `_CloudPainter` 手绘近似（无 SVG 资源加载，记 deltas §7）；
///   - 雨层（:1020-1037）：`isRain || isStorm`（:1023-1024），9 条
///     1×12 雨丝（:1029-1031）、色 `ink("#d9f1ff")`（:1032）、
///     x=w·(i+0.4)/9（:1033）、rotation -13°（:1034）；源 `x` 顶左对齐
///     而 rotation 绕自身中心 → 源雨丝实际水平覆盖约 -0.07w…1.06w
///     （见 visual-deltas §7），本端直接绘制等价的世界坐标斜线段；
///   - 雾层（:1039-1055）：3 条横带，宽 w·(0.54+i·0.09)、高 10、半径 5、
///     x=-w·0.15+i·24、y=16+i·26、色 rgba(1,1,1,0.20-i·0.035)；
///   - 雪层（:1057-1073）：14 点，直径 4/2（i%3==0）、色 rgba(1,1,1,0.62)、
///     x=w·((i·37)%100)/100、y=8+(i·19)%max(1,h-12)；
///   - 雷暴符号（:1075-1082）："ϟ" 42px DemiBold、ink("#e0ccff",0.68)、
///     右 26 / 顶 8；
/// - 文字（:1084-1107）：城市名 15px DemiBold 左 16/顶 12；温度
///   `Math.round(t)+"°"`（WeatherService.qml:32-33），字号
///   min(42, h·0.32) 左 15/顶 29（:1090-1095）；条件符号
///   `conditionSymbol(code,isDay)` 色 weatherTheme.accent、字号
///   min(34, h·0.26)、右 18/顶 14（:1096-1101）；条件文本 15px DemiBold
///   右 16/顶 48（:1102-1107）；
/// - 今日高/低温或「正在更新预报」（:1108-1115），预报条上缘上方
///   bottomMargin 3、右 16、11px、白@0.74；
/// - 7 日预报条（:1116-1155）：左/右 10、底 8、高 min(62, h·0.46)；
///   每格 w/7：`forecastLabel(date,i)` 10px DemiBold 白@0.72 居顶、
///   `conditionSymbol(code,true)` 22px accent 居中、`高°/低°` 10px
///   DemiBold 居底；空预报居中 11px 白@0.65，
///   `loading ? "正在获取 7 日预报…" : "暂无 7 日预报"`（:1150-1153）；
/// - 整卡点击 → `launchById("kos-weather", locationId ? ["--location",id]
///   : [])`（:1156-1164）→ `onLaunchApp`。
///
/// TASK-09：源端卡面渐变与内容层渐变冲洗（:939-950 的
/// `weatherTheme.primary→secondary→darker(secondary)`、`configuredWidget`
/// :223 的 startColor/endColor）仅在 `!onBackdrop`（色艺卡）生效；本端卡片
/// 一律吃 Denial ShellTheme 材质（等价 onBackdrop），不再画渐变，weather 配色
/// 仅用于内部图形/符号（conditionSymbol 的 accent 改读 shell 文本色板）。
///
/// 数据：构造注入 `WeatherSnapshot`（`KosDataClient` `weather.snapshot`
/// result.weather 的结构化投影，weather-v1.schema.json）；
/// `snapshot == null` → `--°`/空态，对齐源 `available=false` 分支
/// （WeatherService.qml:30-37、:1108-1115、:1150-1153）。
///
/// 源文件行号均指 `/home/wwt/文档/NextKde/shell/desktop/modules/` 相对根。
library;

import '../theme/backdrop_content.dart';

import 'dart:math' as math;

import 'package:denial_flutter_sdk/shell_theme.dart'
    show ShellThemeBuildContext, ShellThemeData;
import 'package:flutter/widgets.dart';

import '../layout/widget_layout.dart' show WidgetSize;
import 'calendar_card.dart' show KosLaunchAppCallback;
import 'desk_card.dart';

/// `weather.snapshot` result.weather 的轻量投影
/// （weather-v1.schema.json；WeatherService.qml:117-132 `applyWeather`
/// 的读取字段子集，加上 :47-60 `forecastDays` 的投影形状）。
final class WeatherSnapshot {
  const WeatherSnapshot({
    this.status = 'idle',
    this.cityName = '--',
    this.locationId = '',
    this.currentTemp = double.nan,
    this.weatherCode = -1,
    this.isDay = true,
    this.forecast = const [],
    this.apparentTemp = double.nan,
    this.relativeHumidity = double.nan,
    this.windSpeed = double.nan,
    this.windDirection = double.nan,
    this.currentTime = '',
    this.hourly = const [],
  });

  /// `status`（schema 行 19，idle/loading/ready/error）；`loading`
  /// 驱动空态文案（DeskCenterWindow.qml:1151）。
  final String status;

  /// `location.name`（schema 行 50；cityName 回退 `"--"`，
  /// WeatherService.qml:26）。
  final String cityName;

  /// `location.id`（schema 行 48），整卡点击 `--location` 参数
  /// （DeskCenterWindow.qml:1160-1162）。
  final String locationId;

  /// `current.temperature`（schema 行 75）；NaN/缺失 → `"--°"`
  /// （WeatherService.qml:32-33 available 分支）。
  final double currentTemp;

  /// `current.weatherCode`（schema 行 79）；缺失 → -1
  /// （WeatherService.qml:36）。
  final int weatherCode;

  /// `current.isDay`（schema 行 78）；缺失 → true
  /// （WeatherService.qml:37）。
  final bool isDay;

  /// `forecastDays` 投影（WeatherService.qml:47-60）：截断 7 项、
  /// high=round(temperatureMaximum)、low=round(temperatureMinimum)。
  final List<WeatherDay> forecast;

  /// `current.apparentTemperature`（schema `$defs.current`）：体感温度；
  /// 缺失/非有限 → NaN（面板指标格显示 `--`）。TASK-15 面板新增，
  /// 卡片投影不消费。
  final double apparentTemp;

  /// `current.relativeHumidity`（schema `$defs.current`，0-100）。
  final double relativeHumidity;

  /// `current.windSpeed`（schema `$defs.current`，km/h metric 档）/
  /// `windDirection`（0-360 度）。
  final double windSpeed;
  final double windDirection;

  /// `current.time` 原始编码时间串（面板「更新时间」展示用）。
  final String currentTime;

  /// `hourly` 投影（schema `$defs.hourlyPoint`；截断 48 小时）：
  /// 面板小时预报横向条消费；卡片不消费。
  final List<WeatherHourly> hourly;

  bool get loading => status == 'loading'; // WeatherService.qml:29

  /// `weather.snapshot` result 的 `weather` 对象（schema v1；
  /// `schemaVersion != 1` 抛 FormatException，对齐
  /// WeatherService.qml:118-119 的丢弃语义）。
  factory WeatherSnapshot.fromJson(Map<String, Object?> weather) {
    final schemaVersion = switch (weather['schemaVersion']) {
      final num v => v.toInt(),
      _ => 0,
    };
    if (schemaVersion != 1) {
      throw FormatException('weather schemaVersion != 1: $schemaVersion');
    }
    final location = switch (weather['location']) {
      final Map m => m.map((k, v) => MapEntry(k.toString(), v)),
      _ => const <String, Object?>{},
    };
    final current = switch (weather['current']) {
      final Map m => m.map((k, v) => MapEntry(k.toString(), v)),
      _ => const <String, Object?>{},
    };
    final daily = weather['daily'];
    final hourlyJson = weather['hourly'];
    double currentNumber(String key) => switch (current[key]) {
      final num v => v.toDouble(),
      _ => double.nan,
    };
    return WeatherSnapshot(
      status: weather['status']?.toString() ?? 'idle',
      cityName: location['name']?.toString() ?? '--',
      locationId: location['id']?.toString() ?? '',
      currentTemp: switch (current['temperature']) {
        final num v => v.toDouble(),
        _ => double.nan,
      },
      weatherCode: switch (current['weatherCode']) {
        final num v => v.toInt(),
        _ => -1,
      },
      // WeatherService.qml:37 `available ? Boolean(current.isDay) : true`
      // —— current 缺席（→!available）时兜底 true。
      isDay: weather['current'] is! Map || current['isDay'] == true,
      forecast: [
        // WeatherService.qml:50 `Math.min(7, source.length)`。
        if (daily is List)
          for (var i = 0; i < daily.length && i < 7; i++)
            if (daily[i] is Map)
              WeatherDay.fromJson(
                (daily[i] as Map).map((k, v) => MapEntry(k.toString(), v)),
              ),
      ],
      // current 扩展字段（schema `$defs.current`；TASK-15 面板指标格）。
      apparentTemp: currentNumber('apparentTemperature'),
      relativeHumidity: currentNumber('relativeHumidity'),
      windSpeed: currentNumber('windSpeed'),
      windDirection: currentNumber('windDirection'),
      currentTime: current['time']?.toString() ?? '',
      hourly: [
        if (hourlyJson is List)
          for (var i = 0; i < hourlyJson.length && i < 48; i++)
            if (hourlyJson[i] is Map)
              WeatherHourly.fromJson(
                (hourlyJson[i] as Map).map((k, v) => MapEntry(k.toString(), v)),
              ),
      ],
    );
  }

  /// `weather-v1` schema 的序列化（`WeatherState` 持久化/缓存形状；
  /// weather.go:78-95）。字段名与 [WeatherSnapshot.fromJson] 互为往返。
  Map<String, Object?> toJson() {
    // 非有限 double（NaN）不可 JSON 化 → 写 null（fromJson 对非 num 回退
    // NaN，往返语义保持）。
    double? finite(double v) => v.isFinite ? v : null;
    return {
      'schemaVersion': 1,
      'status': status,
      'location': {'id': locationId, 'name': cityName},
      'current': {
        'time': currentTime,
        'temperature': finite(currentTemp),
        'apparentTemperature': finite(apparentTemp),
        'relativeHumidity': finite(relativeHumidity),
        'weatherCode': weatherCode,
        'isDay': isDay,
        'windSpeed': finite(windSpeed),
        'windDirection': finite(windDirection),
      },
      'daily': [for (final d in forecast) d.toJson()],
      'hourly': [for (final h in hourly) h.toJson()],
    };
  }
}

/// `forecastDays` 单项（WeatherService.qml:52-57）：date/code/high/low。
final class WeatherDay {
  const WeatherDay({
    required this.date,
    required this.code,
    required this.high,
    required this.low,
    this.precipitationChance = 0,
  });

  /// `yyyy-MM-dd`（schema `$defs.day.date`，行 119）。
  final String date;
  final int code;

  /// `Math.round(temperatureMaximum/Minimum)`（WeatherService.qml:55-56）。
  final int high;
  final int low;

  /// `precipitationProbability`（schema `$defs.day`，0-100）；缺失 → 0。
  /// TASK-15 面板 7 日列表消费；卡片投影不消费。
  final int precipitationChance;

  factory WeatherDay.fromJson(Map<String, Object?> json) => WeatherDay(
    date: json['date']?.toString() ?? '',
    code: switch (json['weatherCode']) {
      final num v => v.toInt(),
      _ => -1,
    },
    high: switch (json['temperatureMaximum']) {
      final num v => v.round(),
      _ => 0,
    },
    low: switch (json['temperatureMinimum']) {
      final num v => v.round(),
      _ => 0,
    },
    precipitationChance: switch (json['precipitationProbability']) {
      final num v => v.round(),
      _ => 0,
    },
  );

  /// `weather-v1` schema `$defs.day` 序列化（weather.go:69-76）。
  Map<String, Object?> toJson() => {
    'date': date,
    'weatherCode': code,
    'temperatureMaximum': high,
    'temperatureMinimum': low,
    'precipitationProbability': precipitationChance,
  };
}

/// `hourly[]` 单项（schema `$defs.hourlyPoint`）：面板小时预报横向条消费
/// （TASK-15）；卡片投影不消费。
final class WeatherHourly {
  const WeatherHourly({
    required this.time,
    this.temperature = double.nan,
    this.code = -1,
    this.isDay = true,
    this.precipitationChance = 0,
  });

  /// 编码时间串（`yyyy-MM-ddTHH:mm`，Open-Meteo 原样）。
  final String time;

  /// `temperature`（℃，metric 档）；缺失 → NaN。
  final double temperature;
  final int code;
  final bool isDay;

  /// `precipitationProbability`（0-100）；缺失 → 0。
  final int precipitationChance;

  factory WeatherHourly.fromJson(Map<String, Object?> json) => WeatherHourly(
    time: json['time']?.toString() ?? '',
    temperature: switch (json['temperature']) {
      final num v => v.toDouble(),
      _ => double.nan,
    },
    code: switch (json['weatherCode']) {
      final num v => v.toInt(),
      _ => -1,
    },
    isDay: json['isDay'] == true,
    precipitationChance: switch (json['precipitationProbability']) {
      final num v => v.round(),
      _ => 0,
    },
  );

  /// `weather-v1` schema `$defs.hourlyPoint` 序列化（weather.go:60-68）。
  Map<String, Object?> toJson() => {
    'time': time,
    'temperature': temperature.isFinite ? temperature : null,
    'weatherCode': code,
    'isDay': isDay,
    'precipitationProbability': precipitationChance,
  };
}

/// `WeatherService.conditionText`（WeatherService.qml:69-82）逐行移植。
String kosWeatherConditionText(int code) {
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
String kosWeatherConditionSymbol(int code, {required bool isDay}) {
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

/// `WeatherService.forecastLabel`（WeatherService.qml:96-104）逐行移植：
/// 0→今天、1→明天、其余按 `yyyy-MM-dd`（本地时区）取星期名，解析失败回
/// 原字符串。源 `new Date(isoDate + "T12:00:00")` 为本地时区解析；
/// `DateTime.parse` 与 `isUtc=false` 等价。
String kosWeatherForecastLabel(String isoDate, int index) {
  if (index == 0) return '今天';
  if (index == 1) return '明天';
  const weekdays = ['周日', '周一', '周二', '周三', '周四', '周五', '周六'];
  final parsed = DateTime.tryParse('${isoDate}T12:00:00');
  // tryParse 失败回 null；源 Number.isNaN → String(isoDate)。
  return parsed == null ? isoDate : weekdays[parsed.weekday % 7];
}

/// 天气类别（源 `weatherCategory(weatherCode)` 的分组，DeskCenterWindow.qml
/// 内联判断 :963/:986/:1023/:1042/:1060/:1077 的等价抽取）。
String _weatherCategory(int code) {
  if (code == 0 || code == 1) return 'clear';
  if (code == 2) return 'partlyCloudy';
  if (code == 3) return 'overcast';
  if (code == 45 || code == 48) return 'fog';
  if (code >= 51 && code <= 67) return 'rain';
  if ((code >= 71 && code <= 77) || (code >= 85 && code <= 86)) return 'snow';
  if (code >= 80 && code <= 82) return 'rain';
  if (code >= 95) return 'storm';
  return 'clear';
}

/// 天气卡内容色板（`content.ink` 解析结果的注入形式）。
///
/// 源端所有文字/图形色都经 `AppearanceTokens.content.ink(own,α)`：TASK-09 起
/// 卡片统一吃 Denial ShellTheme 材质（等价 onBackdrop），ink() 走
/// glassContentColor 白系（暗玻璃白，IconAppearanceService.qml:67-78 静态
final class KosWeatherCardColors {
  const KosWeatherCardColors({
    this.ink = const Color(
      0xFFFFFFFF,
    ), // ink(\"white\") :1087/:1092/:1105/:1143
    this.faintInk = const Color(0xBDFFFFFF), // 白@0.74 :1113
    this.subduedInk = const Color(0xB8FFFFFF), // 白@0.72 :1131
    this.forecastEmptyInk = const Color(0xA6FFFFFF), // 白@0.65 :1152
    this.sunRay = const Color(0xFFFFFFFF), // ink(\"#ffe36a\")→glassContentColor
    this.raindrop = const Color(0xFFFFFFFF), // ink(\"#d9f1ff\")→白
    this.stormBolt = const Color(0xADFFFFFF), // ink(\"#e0ccff\",0.68)→白@0.68
    this.fogBand = const Color(0xFFFFFFFF), // rgba(1,1,1,α) :1052 基色
    this.snowFlake = const Color(0x9EFFFFFF), // rgba(1,1,1,0.62) :1070
    this.cloudBack = const Color(0x99FFFFFF), // 云图近似底（去饱和白）
    this.cloudFront = const Color(0xCCFFFFFF),
  });

  /// 透明桌面材质采用 NextKde 白色 backdrop ink；不透明模式采用壳色板。
  /// 此解析只影响卡片内容，不修改详情面板、菜单或卡片表面材质。
  static KosWeatherCardColors forShell(ShellThemeData theme) {
    final light =
        !usesBackdropInk(theme) && theme.brightness == Brightness.light;
    // 图形基色：暗壳白系、亮壳深墨（textSecondary）——保留各字段相对 alpha。
    Color graph(double alpha) => light
        ? backdropSecondaryInk(theme).withValues(alpha: alpha)
        : Color(0xFFFFFFFF).withValues(alpha: alpha);
    return KosWeatherCardColors(
      ink: backdropInk(theme), // 白 → textPrimary
      faintInk: backdropSecondaryInk(theme).withValues(alpha: 0.74), // :1113
      subduedInk: backdropSecondaryInk(theme).withValues(alpha: 0.72), // :1131
      forecastEmptyInk: backdropSecondaryInk(theme)
          .withValues(alpha: 0.65), // :1152
      sunRay: graph(1.0), // :974/:980
      raindrop: graph(1.0), // :1032
      stormBolt: graph(0.68), // :1079-1080
      fogBand: graph(1.0), // :1052 基色（逐条 alpha 由 _FogPainter 施加）
      snowFlake: graph(0.62), // :1070
      cloudBack: graph(0.6), // 云近似底
      cloudFront: graph(0.8), // 云近似前
    );
  }

  /// 城市名/温度/条件文本/日高低温 `ink(\\\"white\\\")`（:1087/:1092/:1105/:1143）
  /// → shell `textPrimary`。
  final Color ink;

  /// 「最高/最低」与正在更新文案 `ink(rgba(1,1,1,0.74),0.74)`（:1113）
  /// → `textSecondary`@0.74。
  final Color faintInk;

  /// 预报日期标签 `ink(rgba(1,1,1,0.72),0.72)`（:1131）→ `textSecondary`@0.72。
  final Color subduedInk;

  /// 空预报文案 `ink(rgba(1,1,1,0.65),0.65)`（:1152）→ `textSecondary`@0.65。
  final Color forecastEmptyInk;

  /// 太阳光线与圆盘 `ink(\\\"#ffe36a\\\")`（:974、:980）→明暗壳随图形基色。
  final Color sunRay;

  /// 雨丝 `ink(\\\"#d9f1ff\\\")`（:1032）→明暗壳随图形基色。
  final Color raindrop;

  /// 雷暴符号 `ink(\\\"#e0ccff\\\",0.68)`（:1079-1080）→图形基色@0.68。
  final Color stormBolt;

  /// 雾带基色；每条透明度 0.20-i·0.035（:1052）由 `_FogPainter` 施加。
  final Color fogBand;

  /// 雪点 rgba(1,1,1,0.62)（:1070）→图形基色@0.62。
  final Color snowFlake;

  /// 云近似：源为 bundled SVG + glass 形态去饱和（MultiEffect
  /// saturation:-1.0，:997-1001/:1012-1015）；无 SVG 资源，以多层圆团近似，
  /// 记 deltas §7。明暗壳随图形基色。
  final Color cloudBack;
  final Color cloudFront;
}

/// DeskCenter 天气小部件卡片（`modelData.id === "weather"`，:929-1167）。
class KosWeatherCard extends StatelessWidget {
  const KosWeatherCard({
    super.key,
    this.snapshot,
    this.colors,
    this.size = WidgetSize.medium,
    this.editMode = false,
    this.onLaunchApp,
    this.onRemove,
    this.onCycleSize,
  });

  /// 天气快照；null → `available=false` 空态（WeatherService.qml:30-37：
  /// temperature `"--°"`、weatherCode -1、isDay true、forecastDays []）。
  final WeatherSnapshot? snapshot;

  /// 内容色板；null → build 时按 `context.shellTheme` 解析
  /// （[KosWeatherCardColors.forShell]——亮壳图形改深基调、暗壳白系）。
  final KosWeatherCardColors? colors;

  /// 尺寸档位（透传 [DeskCard.size]）。
  final WidgetSize size;

  /// 编辑模式角标（透传 [DeskCard.editMode]）。
  final bool editMode;

  /// 整卡点击回调：`('kos-weather', locationId 非空 ? ['--location',id]
  /// : [])`（:1156-1164）。
  final KosLaunchAppCallback? onLaunchApp;

  /// 编辑态角标回调。
  final DeskCardBadgeCallback? onRemove;
  final DeskCardBadgeCallback? onCycleSize;

  @override
  Widget build(BuildContext context) {
    final snap = snapshot;
    final code = snap?.weatherCode ?? -1; // WeatherService.qml:36
    final isDay = snap?.isDay ?? true; // :37
    final category = _weatherCategory(code);
    final colors =
        this.colors ?? KosWeatherCardColors.forShell(context.shellTheme);
    // 天气符号与正文共享内容色板（显式注入也保持一致）。
    final accent = colors.ink;
    // 温度文案（WeatherService.qml:32-33）：round + \"°\"，缺失 \"--°\"。
    final temperature = snap == null || snap.currentTemp.isNaN
        ? '--°'
        : '${snap.currentTemp.round()}°';

    return DeskCard(
      size: size,
      editMode: editMode,
      onRemove: onRemove,
      onCycleSize: onCycleSize,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final h = constraints.maxHeight;
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            // :1156-1164 整卡点击 → kos-weather [--location id]。
            onTap: onLaunchApp == null
                ? null
                : () => onLaunchApp!(
                    'kos-weather',
                    snap != null && snap.locationId.isNotEmpty
                        ? ['--location', snap.locationId]
                        : const [],
                  ),
            child: Stack(
              fit: StackFit.expand,
              children: [
                // 天气图形层：整体 opacity 0.34（:959）、clip（:958）。
                // 源注释要求 artwork 静止（:952-954）——无动画。
                Positioned.fill(
                  child: Opacity(
                    opacity: 0.34, // :959
                    child: ClipRect(
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          if (category == 'clear' && isDay) // :963
                            Positioned(
                              right: 20, // :966 rightMargin
                              top: 5, // :966 topMargin
                              width: 70, // :964
                              height: 70, // :965
                              child: CustomPaint(
                                painter: _SunPainter(color: colors.sunRay),
                              ),
                            ),
                          if (category == 'partlyCloudy' ||
                              category == 'overcast') // :986-987
                            Positioned.fill(
                              child: CustomPaint(
                                painter: _CloudPainter(
                                  back: colors.cloudBack,
                                  front: colors.cloudFront,
                                ),
                              ),
                            ),
                          if (category == 'rain' || category == 'storm')
                            // :1023-1024 isRain||isStorm
                            Positioned.fill(
                              child: CustomPaint(
                                painter: _RainPainter(color: colors.raindrop),
                              ),
                            ),
                          if (category == 'fog') // :1042
                            Positioned.fill(
                              child: CustomPaint(
                                painter: _FogPainter(color: colors.fogBand),
                              ),
                            ),
                          if (category == 'snow') // :1060
                            Positioned.fill(
                              child: CustomPaint(
                                painter: _SnowPainter(color: colors.snowFlake),
                              ),
                            ),
                          if (category == 'storm') // :1077
                            Positioned(
                              right: 26, // :1076
                              top: 8, // :1076
                              child: Text(
                                'ϟ', // :1078
                                style: TextStyle(
                                  color: colors.stormBolt,
                                  fontSize: 42, // :1081
                                  fontWeight: FontWeight.w600, // DemiBold
                                  height: 1,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
                // 城市名（:1084-1089）：左 16/顶 12、15px DemiBold。
                Positioned(
                  left: 16,
                  top: 12,
                  child: Text(
                    snap?.cityName ?? '--', // WeatherService.qml:26
                    style: TextStyle(
                      color: colors.ink,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      height: 1.2,
                    ),
                  ),
                ),
                // 当前温度（:1090-1095）：左 15/顶 29、
                // 字号 min(42, 卡高*0.32)。
                Positioned(
                  left: 15,
                  top: 29,
                  child: Text(
                    temperature,
                    style: TextStyle(
                      color: colors.ink,
                      fontSize: math.min(42.0, h * 0.32), // :1094
                      height: 1.1,
                    ),
                  ),
                ),
                // 条件符号（:1096-1101）：右 18/顶 14、accent 色、
                // 字号 min(34, 卡高*0.26)。
                Positioned(
                  right: 18,
                  top: 14,
                  child: Text(
                    kosWeatherConditionSymbol(code, isDay: isDay), // :1098
                    style: TextStyle(
                      color: accent, // :1099 ink(theme.accent) → shell 次色
                      fontSize: math.min(34.0, h * 0.26), // :1100
                      height: 1,
                    ),
                  ),
                ),
                // 条件文本（:1102-1107）：右 16/顶 48、15px DemiBold。
                Positioned(
                  right: 16,
                  top: 48,
                  child: Text(
                    kosWeatherConditionText(code), // :1104
                    style: TextStyle(
                      color: colors.ink,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      height: 1,
                    ),
                  ),
                ),
                // 今日高低温 / 「正在更新预报」（:1108-1115）：右 16、
                // 底边对齐预报条顶 -3、11px、白@0.74。
                Positioned(
                  right: 16,
                  bottom: _forecastHeight(h) + 8 + 3, // :1109 bottomMargin:3
                  child: Text(
                    snap != null && snap.forecast.isNotEmpty
                        ? '最高 ${snap.forecast[0].high}°  最低 ${snap.forecast[0].low}°' // :1110-1112
                        : '正在更新预报', // :1112
                    style: TextStyle(
                      color: colors.faintInk,
                      fontSize: 11, // :1114
                      height: 1,
                    ),
                  ),
                ),
                // 7 日预报条（:1116-1155）。
                Positioned(
                  left: 10, // :1118
                  right: 10,
                  bottom: 8, // :1118
                  height: _forecastHeight(h), // :1119 min(62,h*0.46)
                  child: _ForecastStrip(
                    snapshot: snap,
                    accent: accent,
                    colors: colors,
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// 预报条高 `min(62, h*0.46)`（:1119）。
  static double _forecastHeight(double h) => math.min(62.0, h * 0.46);
}

/// 7 日预报条（:1120-1155）：每格 w/7，日期标签居顶、条件符号居中、
/// 高低温居底；空时居中提示。
class _ForecastStrip extends StatelessWidget {
  const _ForecastStrip({
    required this.snapshot,
    required this.accent,
    required this.colors,
  });

  final WeatherSnapshot? snapshot;

  /// 条件符号色（:1137 `ink(theme.accent)` → shell 次色）。
  final Color accent;
  final KosWeatherCardColors colors;

  @override
  Widget build(BuildContext context) {
    final days = snapshot?.forecast ?? const <WeatherDay>[];
    if (days.isEmpty) {
      return Center(
        child: Text(
          // :1150-1153 空态两态文案。
          snapshot != null && snapshot!.loading ? '正在获取 7 日预报…' : '暂无 7 日预报',
          style: TextStyle(
            color: colors.forecastEmptyInk,
            fontSize: 11, // :1153
            height: 1,
          ),
        ),
      );
    }
    return Row(
      children: [
        for (var i = 0; i < days.length; i++) // Repeater :1120-1121
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                // 日期标签（:1128-1133）：顶 10px DemiBold 白@0.72。
                Text(
                  kosWeatherForecastLabel(days[i].date, i), // :1130
                  maxLines: 1,
                  style: TextStyle(
                    color: colors.subduedInk,
                    fontSize: 10, // :1132
                    fontWeight: FontWeight.w600,
                    height: 1,
                  ),
                ),
                // 条件符号（:1134-1139）：居中 22px、accent 色、isDay=true。
                Text(
                  kosWeatherConditionSymbol(days[i].code, isDay: true), // :1136
                  style: TextStyle(
                    color: accent, // :1137
                    fontSize: 22, // :1138
                    height: 1,
                  ),
                ),
                // 高/低温（:1140-1145）：底 10px DemiBold 白。
                Text(
                  '${days[i].high}°/${days[i].low}°', // :1142
                  style: TextStyle(
                    color: colors.ink,
                    fontSize: 10, // :1144
                    fontWeight: FontWeight.w600,
                    height: 1,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// 太阳层（:961-981）：8 条 2×12 光线。源委托 `x=w/2-1=34、y=2`
/// （矩形纵跨局部 2..14），`Rotation{origin.x:1; origin.y:33}`（:977）
/// 即绕层内点 (34+1, 2+33)=(35,35)=层中心 旋转 index·45°——等价于
/// 以中心为原点画 Rect(-1,-33,2,12)。中心 28px 圆（:980）半径 14。
class _SunPainter extends CustomPainter {
  const _SunPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final paint = Paint()..color = color;
    canvas.save();
    canvas.translate(center.dx, center.dy);
    for (var i = 0; i < 8; i++) {
      canvas.save();
      canvas.rotate(i * math.pi / 4); // :977 index*45°
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          const Rect.fromLTWH(-1, -33, 2, 12), // :970-976 局部坐标
          const Radius.circular(1), // :973
        ),
        paint,
      );
      canvas.restore();
    }
    canvas.restore();
    // :980 中心 28px 圆。
    canvas.drawCircle(center, 14, paint);
  }

  @override
  bool shouldRepaint(covariant _SunPainter oldDelegate) =>
      oldDelegate.color != color;
}

/// 云层近似（:983-1018）：源为两片 bundled SVG（`weather-cloud`/
/// `weather-cloud-wide`），glass 形态经 MultiEffect 去饱和。本端以圆团
/// 组合近似轮廓（无 SVG 资源，记 visual-deltas §7）。
/// 几何锚点：back w·0.34/h·0.36 @(-w·0.34,2)（:990-993，x=-width 全在
/// 屏外——源端 back 云完全不可见！其 x:-width 把整片推出左缘，只保留
/// front 云；本端如实保留该死位几何）；front w·0.30/h·0.29
/// @(w, h·0.18)（:1005-1008）——x=parent.width 同样在屏外，两片云在源
/// 端均不显示（保持静态 artwork 注释 :952-954 意图：云动画已被移除但
/// 初始位置未复位）。本端按源如实绘制（屏外，等同不可见），差异记入
/// deltas §7——**不擅自把云拉回屏内**。
class _CloudPainter extends CustomPainter {
  const _CloudPainter({required this.back, required this.front});

  final Color back;
  final Color front;

  @override
  void paint(Canvas canvas, Size size) {
    // back 云：(:990-993) w=pw*0.34、h=ph*0.36、x=-w、y=2 → 完全屏外。
    _cloud(
      canvas,
      Offset(-size.width * 0.34, 2),
      Size(size.width * 0.34, size.height * 0.36),
      back,
    );
    // front 云：(:1005-1008) w=pw*0.30、h=ph*0.29、x=pw、y=ph*0.18 → 屏外。
    _cloud(
      canvas,
      Offset(size.width, size.height * 0.18),
      Size(size.width * 0.30, size.height * 0.29),
      front,
    );
  }

  /// 在 `rect` 内画近似云形（三个圆 + 底梁）。
  void _cloud(Canvas canvas, Offset at, Size rect, Color color) {
    if (rect.width <= 0 || rect.height <= 0) return;
    final paint = Paint()..color = color;
    final base = Rect.fromLTWH(
      at.dx,
      at.dy + rect.height * 0.45,
      rect.width,
      rect.height * 0.55,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(base, Radius.circular(rect.height * 0.27)),
      paint,
    );
    canvas.drawCircle(
      Offset(at.dx + rect.width * 0.32, at.dy + rect.height * 0.45),
      rect.height * 0.30,
      paint,
    );
    canvas.drawCircle(
      Offset(at.dx + rect.width * 0.62, at.dy + rect.height * 0.34),
      rect.height * 0.36,
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant _CloudPainter oldDelegate) =>
      oldDelegate.back != back || oldDelegate.front != front;
}

/// 雨层（:1020-1037）：9 条 1×12 雨丝、x=w·(i+0.4)/9、rotation:-13°。
/// 源 `Rectangle{ rotation: -13 }` 绕自身中心（transformOrigin 默认
/// Item.Center）；把委托矩形中心 world=(w·(i+0.4)/9+0.5, h/2) 旋转 -13°
/// 的线段即等价。本端直接画旋转后的世界坐标线段（12 长、1 宽、圆头 0.5）。
class _RainPainter extends CustomPainter {
  const _RainPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth =
          1 // :1029
      ..strokeCap = StrokeCap.round; // radius:1 的近似
    const rad = -13 * math.pi / 180; // :1034 rotation:-13
    final dir = Offset(math.sin(rad), math.cos(rad)); // 旋转后下方向
    for (var i = 0; i < 9; i++) {
      // :1033 委托 x=w·(i+0.4)/9（顶左）；矩形 1×12，y 隐式 0。
      final center = Offset(size.width * (i + 0.4) / 9 + 0.5, size.height / 2);
      canvas.drawLine(center - dir * 6, center + dir * 6, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _RainPainter oldDelegate) =>
      oldDelegate.color != color;
}

/// 雾层（:1039-1055）：3 条横带，逐条参数见构造内注释。
class _FogPainter extends CustomPainter {
  const _FogPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    for (var i = 0; i < 3; i++) {
      final width = size.width * (0.54 + i * 0.09); // :1047
      final opacity = 0.20 - i * 0.035; // :1052
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(
            -width * 0.15 + i * 24, // :1050
            16 + i * 26, // :1051
            width,
            10, // :1048
          ),
          const Radius.circular(5), // :1049 radius:height/2
        ),
        Paint()..color = color.withValues(alpha: opacity),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _FogPainter oldDelegate) =>
      oldDelegate.color != color;
}

/// 雪层（:1057-1073）：14 点，直径 i%3==0→4 否则 2，
/// x=w·((i·37)%100)/100、y=8+(i·19)%max(1,h-12)、rgba(1,1,1,0.62)。
class _SnowPainter extends CustomPainter {
  const _SnowPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    for (var i = 0; i < 14; i++) {
      final d = i % 3 == 0 ? 4.0 : 2.0; // :1065
      final x = size.width * ((i * 37) % 100) / 100; // :1068
      final y = (8 + (i * 19) % math.max(1.0, size.height - 12))
          .toDouble(); // :1069
      canvas.drawCircle(Offset(x, y), d / 2, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _SnowPainter oldDelegate) =>
      oldDelegate.color != color;
}
