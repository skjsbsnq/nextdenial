/// KOS DeskCenter 天气详情面板（TASK-15）：`kos-weather --location <id>`
/// 的 DenialUI 重写，填入 TASK-12 的 `DeskPanelShell` 内容区。
///
/// 源端对照（`apps/weather/qml/Main.qml`，行号锚 NextKde 根）：
/// - 入口 `handleActivation`：`--location <id>` → 直达该地点（本文件
///   [_WeatherPanelState._applyPendingLocation]）；
/// - 左栏（:120-210 邻域）：地点搜索框（debounce 触发 geocoding）+
///   搜索结果列表（名称 + 行政区明细）+ 已存地点列表（选中态 accent）；
/// - 右栏：当前温度/状况符号、体感、指标网格（`WeatherMetric`）、小时
///   预报横向列表、7 日预报列表（日期/状况/高低温）、更新时间戳、
///   单位切换（°C/°F、km/h/mph）；
/// - 数据：源 `WeatherClient.cpp` → kos-data `weather.*` 操作；本端走
///   TASK-10 的 [WeatherProvider]（Open-Meteo forecast + geocoding），
///   单位经 `weather.json` 的 `units` 键持久化（源 `weather.set-units`）。
///
/// DenialUI：面板材质由 `DeskPanelShell` 提供（`ShellBackdropBlur` +
/// `Material(cardColor)`）；本文件所有前景色/描边走
/// `context.shellTheme`/`context.shellColors`，无 `Theme.of` 与硬编码
/// 前景色（表单控件经 `theme.toMaterialTheme()` 局部包裹，同
/// `todo_panel.dart` 范式）。
library;

import 'dart:async';

import 'package:denial_flutter_sdk/shell_color_scheme.dart'
    show ShellColorScheme;
import 'package:denial_flutter_sdk/shell_theme.dart'
    show ShellThemeBuildContext, ShellThemeData;
import 'package:denial_flutter_sdk/tokens.dart' show ShellText;
import 'package:flutter/material.dart'
    show
        DefaultMaterialLocalizations,
        InputDecoration,
        MaterialLocalizations,
        TextEditingController,
        TextField,
        Theme;
import 'package:flutter/widgets.dart';

import '../data/weather_provider.dart';
import 'desk_panel_shell.dart';
import 'weather_card.dart';

/// `DeskPanelBuilder` 形态的天气面板入口。
Widget buildWeatherPanel(DeskPanelRequest request, DeskPanelData data) =>
    WeatherPanel(request: request, data: data);

/// 注册 `kos-weather` 的面板内容构造器（装配层统一调用一次，幂等）。
void registerWeatherPanel() {
  registerDeskPanelBuilder('kos-weather', buildWeatherPanel);
}

/// 天气详情面板：左栏地点管理 + 右栏当前/预报，数据源为注入的
/// [WeatherProvider]（`DeskPanelData.weatherProvider`）。
class WeatherPanel extends StatefulWidget {
  const WeatherPanel({required this.request, required this.data, super.key});

  /// 卡片弹出请求（`--location` 直达）。
  final DeskPanelRequest request;

  /// 当帧数据快照与数据源（`weather`/`weatherProvider`）。
  final DeskPanelData data;

  @override
  State<WeatherPanel> createState() => _WeatherPanelState();
}

class _WeatherPanelState extends State<WeatherPanel> {
  final TextEditingController _searchController = TextEditingController();
  StreamSubscription<WeatherSnapshot>? _sub;
  Timer? _debounce;
  WeatherSnapshot? _snapshot;
  List<KosWeatherLocation> _results = const [];
  bool _searching = false;

  /// 注入的 provider（预览/测试形态可为 null——只读当帧快照）。
  WeatherProvider? get _provider =>
      widget.data.weatherProvider as WeatherProvider?;

  @override
  void initState() {
    super.initState();
    final provider = _provider;
    _snapshot = provider?.latest ?? widget.data.weather;
    final stream = provider?.snapshots;
    if (stream != null) {
      _sub = stream.listen((snapshot) {
        if (mounted) setState(() => _snapshot = snapshot);
      });
    }
    unawaited(_applyPendingLocation());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    unawaited(_sub?.cancel());
    _searchController.dispose();
    super.dispose();
  }

  /// `--location <id>` 直达（`handleActivation` 的 `pendingLocationId`）：
  /// 从已存地点列表按 id 命中即切换；未知 id 静默忽略（保持当前地点）。
  Future<void> _applyPendingLocation() async {
    final provider = _provider;
    final id = widget.request.locationId;
    if (provider == null || id == null || id.isEmpty) return;
    for (final location in provider.locations) {
      if (location.id == id && location.id != provider.location.id) {
        await _select(location);
        return;
      }
    }
  }

  /// 搜索框输入（`searchField.onTextChanged`）：debounce 触发 geocoding。
  void _onSearchChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () {
      unawaited(_runSearch(value));
    });
  }

  Future<void> _runSearch(String query) async {
    final provider = _provider;
    final trimmed = query.trim();
    if (provider == null || trimmed.isEmpty) {
      if (mounted) setState(() => _results = const []);
      return;
    }
    if (mounted) setState(() => _searching = true);
    // 检索语言须在 await 前、mounted 时解析（await 后 context 可能失效）。
    final language = _searchLanguage(trimmed);
    List<KosWeatherLocation> results;
    try {
      results = await provider.searchLocations(
        trimmed,
        language: language,
        count: 8,
      );
    } on Object {
      results = const []; // 断网/校验失败：空结果不崩。
    }
    if (!mounted) return;
    setState(() {
      _results = results;
      _searching = false;
    });
  }

  /// geocoding 检索语言（源 `WeatherClient.cpp:209`：`QLocale().name()`
  /// 语言段，如 `zh_CN` → `zh`）。本端规则（取宿主 locale 的 languageCode）：
  ///
  /// 1. 宿主 `languageCode` ∈ {`zh`,`ja`,`ko`} → 直接用宿主语言（这三语文字
  ///    含 CJK，Open-Meteo 各自维护独立名称集，不应被下面的分支覆盖）；
  /// 2. 否则查询含 CJK → `zh`：Open-Meteo 的中文地名只登记在 zh 名称集，
  ///    用 `language=en` 检索中文一律返回空列表（实测「吉安/上海/长沙」在
  ///    `language=en` 下均 0 条、`language=zh` 下有结果）——正是「搜索中文
  ///    地名搜不到城市」的根因，故宿主为 en 等非 CJK 语言时也不能把中文
  ///    查询交给 en；
  /// 3. 否则用宿主语言；宿主取不到 → 回退 `zh`（面板 UI 为中文）。
  ///
  /// 取舍 / 已知局限：CJK 判定仅覆盖 BMP 的 `U+4E00–U+9FFF`、
  /// 扩展 A `U+3400–U+4DBF`、兼容区 `U+F900–U+FAFF`；**Ext B+ 增补平面
  /// （U+20000 起）未纳入**，其字符的查询会落到步骤 3（宿主语言）分支。
  String _searchLanguage(String query) {
    final code = Localizations.maybeLocaleOf(context)?.languageCode;
    if (code == 'zh' || code == 'ja' || code == 'ko') return code!;
    if (_cjkCharacters.hasMatch(query)) return 'zh';
    if (code != null && code.isNotEmpty) return code;
    return 'zh';
  }

  /// CJK 统一表意文字（含扩展 A / 兼容区）。
  static final RegExp _cjkCharacters = RegExp(
    '[\u3400-\u4DBF\u4E00-\u9FFF\uF900-\uFAFF]',
  );

  /// 选中地点（源 `set-location`）：provider 持久化 + 重取，快照经流回流。
  Future<void> _select(KosWeatherLocation location) async {
    final provider = _provider;
    if (provider == null) return;
    try {
      await provider.setLocation(location);
    } on Object {
      // 非法地点/断网：保留当前地点与快照（降级空态）。
    }
    if (!mounted) return;
    setState(() => _results = const []);
  }

  /// 单位切换（源 `set-units` °C/°F、km/h/mph 同步切换）。
  Future<void> _toggleUnits(KosWeatherUnits units) async {
    final provider = _provider;
    if (provider == null || provider.units == units) return;
    await provider.setUnits(units);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.shellTheme;
    final colors = context.shellColors;
    // 无 provider 流（或流尚未推首帧）时回退当帧注入的 [DeskPanelData.weather]；
    // 同一 State 被复用时（didUpdateWidget 不改 _snapshot）也能拿到新快照。
    final snapshot = _snapshot ?? widget.data.weather;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 640),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 208, child: _buildLocationsColumn(theme, colors)),
          const SizedBox(width: 16),
          Expanded(child: _buildWeatherColumn(theme, colors, snapshot)),
        ],
      ),
    );
  }

  /// 表单控件作用域：`theme.toMaterialTheme()` 局部主题；宿主未提供
  /// `MaterialLocalizations` 时补一份内置（`DefaultMaterialLocalizations`
  /// 仅在 en locale 生效，故缺省用 en——宿主已提供（如壳的 zh）时不覆盖）。
  Widget _formScope(ShellThemeData theme, Widget child) {
    final scoped = Theme(data: theme.toMaterialTheme(), child: child);
    if (Localizations.of<MaterialLocalizations>(
          context,
          MaterialLocalizations,
        ) !=
        null) {
      return scoped;
    }
    return Theme(
      data: theme.toMaterialTheme(),
      child: Localizations(
        locale: const Locale('en'),
        delegates: const [
          DefaultMaterialLocalizations.delegate,
          DefaultWidgetsLocalizations.delegate,
        ],
        child: child,
      ),
    );
  }

  // ---------- 左栏：地点管理 ----------

  Widget _buildLocationsColumn(ShellThemeData theme, ShellColorScheme colors) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _formScope(
          theme,
          TextField(
            key: const ValueKey('weather-search'),
            controller: _searchController,
            enabled: _provider != null,
            decoration: const InputDecoration(
              hintText: '搜索地点…', // :126-134 搜索框
              isDense: true,
            ),
            onChanged: _onSearchChanged,
            onSubmitted: (value) => unawaited(_runSearch(value)),
          ),
        ),
        if (_searching)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              '搜索中…',
              style: ShellText.base.copyWith(
                color: colors.textSecondary,
                fontSize: 11,
                height: 1.3,
              ),
            ),
          ),
        // 搜索结果（:150-190）：名称 + 行政区明细，点击即选中。
        for (var i = 0; i < _results.length; i++)
          _locationRow(
            key: ValueKey('weather-result-$i'),
            theme: theme,
            colors: colors,
            location: _results[i],
            selected: false,
            subtitle: [
              _results[i].admin1,
              _results[i].country,
            ].where((part) => part.isNotEmpty).join(' · '),
            onTap: () => unawaited(_select(_results[i])),
          ),
        const SizedBox(height: 14),
        Text(
          '已存地点', // :192-210 已存列表标题
          style: ShellText.base.copyWith(
            color: colors.textSecondary,
            fontSize: 11,
            fontWeight: FontWeight.w600,
            height: 1.3,
          ),
        ),
        const SizedBox(height: 4),
        ..._savedRows(theme, colors),
      ],
    );
  }

  List<Widget> _savedRows(ShellThemeData theme, ShellColorScheme colors) {
    final provider = _provider;
    final locations = provider?.locations ?? const <KosWeatherLocation>[];
    if (locations.isEmpty) {
      return [
        Text(
          '暂无已存地点', // 降级空态
          style: ShellText.base.copyWith(
            color: colors.textTertiary,
            fontSize: 11,
            height: 1.35,
          ),
        ),
      ];
    }
    return [
      for (final location in locations)
        _locationRow(
          key: ValueKey('weather-saved-${location.id}'),
          theme: theme,
          colors: colors,
          location: location,
          selected: location.id == provider?.location.id,
          subtitle: [
            location.admin1,
            location.country,
          ].where((part) => part.isNotEmpty).join(' · '),
          onTap: () => unawaited(_select(location)),
        ),
    ];
  }

  /// 地点行（结果/已存共用）：hover `surfaceContainerHigh`、选中
  /// `accentPalette.subtle` + accent 边（:170-186 选中态）。
  Widget _locationRow({
    required Key key,
    required ShellThemeData theme,
    required ShellColorScheme colors,
    required KosWeatherLocation location,
    required bool selected,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      key: key,
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 4),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: selected ? theme.accentPalette.subtle : null,
          borderRadius: BorderRadius.circular(10),
          border: selected
              ? Border.all(color: theme.accentPalette.outline)
              : null,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              location.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: ShellText.base.copyWith(
                color: selected ? theme.accent : colors.textPrimary,
                fontSize: 12.5,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                height: 1.25,
              ),
            ),
            if (subtitle.isNotEmpty)
              Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: ShellText.base.copyWith(
                  color: colors.textSecondary,
                  fontSize: 10.5,
                  height: 1.3,
                ),
              ),
          ],
        ),
      ),
    );
  }

  // ---------- 右栏：当前 + 预报 ----------

  Widget _buildWeatherColumn(
    ShellThemeData theme,
    ShellColorScheme colors,
    WeatherSnapshot? snapshot,
  ) {
    if (snapshot == null) {
      return _emptyState(colors, '天气数据不可用', '连接数据源后自动刷新。');
    }
    if (snapshot.status == 'error' && snapshot.currentTemp.isNaN) {
      // 断网且无缓存：降级空态（保留面板可操作：地点管理仍在左栏）。
      return _emptyState(colors, '无法获取天气', '网络不可用，稍后自动重试。');
    }
    final units = _provider?.units ?? KosWeatherUnits.metric;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _currentBlock(theme, colors, snapshot, units),
        const SizedBox(height: 14),
        _metricGrid(theme, colors, snapshot, units),
        if (snapshot.hourly.isNotEmpty) ...[
          const SizedBox(height: 14),
          _sectionLabel(colors, '未来数小时'), // :300-340 小时横向条
          const SizedBox(height: 6),
          _hourlyStrip(theme, colors, snapshot, units),
        ],
        if (snapshot.forecast.isNotEmpty) ...[
          const SizedBox(height: 14),
          _sectionLabel(colors, '7 日预报'), // :350-420 7 日列表
          const SizedBox(height: 6),
          for (var i = 0; i < snapshot.forecast.length; i++)
            _forecastRow(theme, colors, snapshot.forecast[i], i, units),
        ],
        const SizedBox(height: 14),
        _footer(theme, colors, units),
      ],
    );
  }

  Widget _emptyState(
    ShellColorScheme colors,
    String title,
    String description,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(
            title,
            style: ShellText.base.copyWith(
              color: colors.textPrimary,
              fontSize: 14,
              fontWeight: FontWeight.w600,
              height: 1.3,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            description,
            textAlign: TextAlign.center,
            style: ShellText.base.copyWith(
              color: colors.textSecondary,
              fontSize: 11.5,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionLabel(ShellColorScheme colors, String label) => Text(
    label,
    style: ShellText.base.copyWith(
      color: colors.textSecondary,
      fontSize: 11,
      fontWeight: FontWeight.w600,
      height: 1.3,
    ),
  );

  /// 当前块（:230-300）：城市 + 大温度 + 状况符号/文案 + 体感。
  Widget _currentBlock(
    ShellThemeData theme,
    ShellColorScheme colors,
    WeatherSnapshot snapshot,
    KosWeatherUnits units,
  ) {
    final tempText = snapshot.currentTemp.isNaN
        ? '--'
        : '${snapshot.currentTemp.round()}';
    final apparent = snapshot.apparentTemp.isNaN
        ? '体感 --'
        : '体感 ${snapshot.apparentTemp.round()}${units.temperatureSuffix}';
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Text(
          kosWeatherConditionSymbol(
            snapshot.weatherCode,
            isDay: snapshot.isDay,
          ),
          style: TextStyle(
            color: theme.accent, // conditionSymbol 色（卡同源 accent）
            fontSize: 34,
            height: 1,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                snapshot.cityName, // :230-240 城市名
                key: const ValueKey('weather-city'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: ShellText.base.copyWith(
                  color: colors.textPrimary,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  height: 1.25,
                ),
              ),
              Text(
                '${kosWeatherConditionText(snapshot.weatherCode)} · $apparent',
                style: ShellText.base.copyWith(
                  color: colors.textSecondary,
                  fontSize: 11.5,
                  height: 1.35,
                ),
              ),
            ],
          ),
        ),
        Text(
          '$tempText°',
          key: const ValueKey('weather-current-temp'),
          style: ShellText.base.copyWith(
            color: colors.textPrimary,
            fontSize: 38,
            fontWeight: FontWeight.w300,
            height: 1,
          ),
        ),
      ],
    );
  }

  /// 指标网格（:260-330 `WeatherMetric` 卡片格）：体感/湿度/风速/风向/降水。
  Widget _metricGrid(
    ShellThemeData theme,
    ShellColorScheme colors,
    WeatherSnapshot snapshot,
    KosWeatherUnits units,
  ) {
    String number(double value, String suffix) => value.isNaN
        ? '--'
        : '${value.round()}$suffix';
    final todayPrecip = snapshot.forecast.isNotEmpty
        ? '${snapshot.forecast.first.precipitationChance}%'
        : '--';
    final metrics = <(String, String)>[
      ('体感', snapshot.apparentTemp.isNaN
          ? '--'
          : '${snapshot.apparentTemp.round()}${units.temperatureSuffix}'),
      ('湿度', number(snapshot.relativeHumidity, '%')),
      ('风速', number(snapshot.windSpeed, units.windSuffix)),
      ('风向', number(snapshot.windDirection, '°')),
      ('降水', todayPrecip),
    ];
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (var i = 0; i < metrics.length; i++)
          _metricCell(
            key: ValueKey('weather-metric-$i'),
            theme: theme,
            colors: colors,
            label: metrics[i].$1,
            value: metrics[i].$2,
          ),
      ],
    );
  }

  Widget _metricCell({
    required Key key,
    required ShellThemeData theme,
    required ShellColorScheme colors,
    required String label,
    required String value,
  }) {
    return Container(
      key: key,
      width: 104,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        // 指标格 = `Material(cardColor)` 小卡（:270 邻域）。
        color: theme.cardColor(colors.surfaceContainer),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.hairlineSoft),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: ShellText.base.copyWith(
              color: colors.textSecondary,
              fontSize: 10.5,
              height: 1.3,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            value,
            style: ShellText.base.copyWith(
              color: colors.textPrimary,
              fontSize: 15,
              fontWeight: FontWeight.w600,
              height: 1.2,
            ),
          ),
        ],
      ),
    );
  }

  /// 小时横向条（:300-340）：`HH:mm` + 符号 + 温度。
  Widget _hourlyStrip(
    ShellThemeData theme,
    ShellColorScheme colors,
    WeatherSnapshot snapshot,
    KosWeatherUnits units,
  ) {
    return SizedBox(
      height: 78,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: snapshot.hourly.length,
        separatorBuilder: (_, _) => const SizedBox(width: 6),
        itemBuilder: (context, index) {
          final hour = snapshot.hourly[index];
          return Container(
            key: ValueKey('weather-hourly-$index'),
            width: 56,
            padding: const EdgeInsets.symmetric(vertical: 8),
            decoration: BoxDecoration(
              color: theme.cardColor(colors.surfaceContainer),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: colors.hairlineSoft),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  _hourLabel(hour.time),
                  style: ShellText.base.copyWith(
                    color: colors.textSecondary,
                    fontSize: 10,
                    height: 1.2,
                  ),
                ),
                Text(
                  kosWeatherConditionSymbol(hour.code, isDay: hour.isDay),
                  style: TextStyle(
                    color: theme.accent,
                    fontSize: 16,
                    height: 1,
                  ),
                ),
                Text(
                  hour.temperature.isNaN
                      ? '--'
                      : '${hour.temperature.round()}°',
                  style: ShellText.base.copyWith(
                    color: colors.textPrimary,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    height: 1.2,
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// `yyyy-MM-ddTHH:mm` → `HH:mm`（源 `timeLabel`）。
  String _hourLabel(String encoded) {
    final index = encoded.indexOf('T');
    if (index < 0 || encoded.length < index + 6) return encoded;
    return encoded.substring(index + 1, index + 6);
  }

  /// 7 日行（:350-420）：日期标签 + 符号 + 高低温 + 降水概率。
  Widget _forecastRow(
    ShellThemeData theme,
    ShellColorScheme colors,
    WeatherDay day,
    int index,
    KosWeatherUnits units,
  ) {
    return Padding(
      key: ValueKey('weather-day-$index'),
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          SizedBox(
            width: 52,
            child: Text(
              kosWeatherForecastLabel(day.date, index),
              style: ShellText.base.copyWith(
                color: colors.textPrimary,
                fontSize: 12,
                height: 1.3,
              ),
            ),
          ),
          Text(
            kosWeatherConditionSymbol(day.code, isDay: true),
            style: TextStyle(color: theme.accent, fontSize: 14, height: 1),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '${day.precipitationChance}%', // :404 降水概率
              style: ShellText.base.copyWith(
                color: colors.textSecondary,
                fontSize: 11,
                height: 1.3,
              ),
            ),
          ),
          Text(
            '${day.high}° / ${day.low}°', // :410 高低温
            style: ShellText.base.copyWith(
              color: colors.textPrimary,
              fontSize: 12,
              fontWeight: FontWeight.w600,
              height: 1.3,
            ),
          ),
        ],
      ),
    );
  }

  /// 底部：更新时间 + `stale` 提示 + 单位切换（:430-470）。
  Widget _footer(
    ShellThemeData theme,
    ShellColorScheme colors,
    KosWeatherUnits units,
  ) {
    final fetchedAt = _provider?.fetchedAt;
    final stale = _provider?.stale ?? false;
    return Row(
      children: [
        Expanded(
          child: Text(
            fetchedAt == null
                ? '更新时间 --'
                : '更新时间 ${_clockLabel(fetchedAt)}'
                      '${stale ? ' · 数据已过期' : ''}',
            style: ShellText.base.copyWith(
              color: colors.textSecondary,
              fontSize: 10.5,
              height: 1.3,
            ),
          ),
        ),
        _unitChip(
          key: const ValueKey('weather-units-metric'),
          theme: theme,
          colors: colors,
          label: '°C / km·h⁻¹',
          selected: units == KosWeatherUnits.metric,
          onTap: () => unawaited(_toggleUnits(KosWeatherUnits.metric)),
        ),
        const SizedBox(width: 6),
        _unitChip(
          key: const ValueKey('weather-units-imperial'),
          theme: theme,
          colors: colors,
          label: '°F / mph',
          selected: units == KosWeatherUnits.imperial,
          onTap: () => unawaited(_toggleUnits(KosWeatherUnits.imperial)),
        ),
      ],
    );
  }

  String _clockLabel(DateTime time) =>
      '${time.hour.toString().padLeft(2, '0')}:'
      '${time.minute.toString().padLeft(2, '0')}';

  Widget _unitChip({
    required Key key,
    required ShellThemeData theme,
    required ShellColorScheme colors,
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      key: key,
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        height: 24,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: selected ? theme.accentPalette.container : null,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? theme.accentPalette.outline : colors.hairline,
          ),
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: ShellText.base.copyWith(
            color: selected
                ? theme.accentPalette.onContainer
                : colors.textSecondary,
            fontSize: 10.5,
            fontWeight: FontWeight.w600,
            height: 1,
          ),
        ),
      ),
    );
  }
}
