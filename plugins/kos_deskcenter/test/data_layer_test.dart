// 数据层解析纯 Dart 测试（不触 socket/文件系统）。
//
// 覆盖：KosRequest/KosResponse/KosError 信封 fromJson/toJson
// （services/data-service/main.go:120-139）、widget-snapshot 三模型
// fromJson（PimStore.cpp:362-424、:725-796；schemaVersion 拒绝
// PimWidgetService.qml:50-51）、WeatherSnapshot/KosSystemMetrics
// 投影解析（weather-v1.schema.json、MetricsService.qml:55-69）。
//
// `SocketKosDataClient` 的传输语义（读排队/写失败/事件帧）以
// `KOS_DATA_SOCKET` 指向不存在路径的失连形态做状态机断言——不发包，
// 纯内存行为。

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kos_deskcenter/src/data/kos_data_client.dart';
import 'package:kos_deskcenter/src/data/kos_data_client_io.dart';
import 'package:kos_deskcenter/src/data/widget_snapshot_watcher.dart';
import 'package:kos_deskcenter/src/data/widget_snapshot_watcher_io.dart';
import 'package:kos_deskcenter/src/widgets/system_card.dart';
import 'package:kos_deskcenter/src/widgets/weather_card.dart';

void main() {
  Map<String, Object?> decode(String text) =>
      (jsonDecode(text) as Map).map((k, v) => MapEntry(k.toString(), v));

  group('KosRequest/KosResponse 信封', () {
    test('KosRequest toJson 形状 {version,requestId,operation,payload}', () {
      final request = KosRequest(
        requestId: '7',
        operation: KosDataOperations.metricsSnapshot,
        payload: const {'a': 1},
      );
      expect(request.toJson(), {
        'version': 1,
        'requestId': '7',
        'operation': 'metrics.snapshot',
        'payload': {'a': 1},
      });
    });

    test('KosResponse.fromJson ok 带 result', () {
      final r = KosResponse.fromJson(
        decode(
          '{"version":1,"requestId":"3","ok":true,'
          '"result":{"metrics":{}}}',
        ),
      );
      expect(r.ok, isTrue);
      expect(r.requestId, '3');
      expect((r.result as Map)['metrics'], isA<Map>());
      expect(r.error, isNull);
    });

    test('KosResponse.fromJson ok:false 解析 error{code,message,retryable}', () {
      final r = KosResponse.fromJson(
        decode(
          '{"version":1,"requestId":"9","ok":false,'
          '"error":{"code":"weather-search-failed","message":"x",'
          '"retryable":true}}',
        ),
      );
      expect(r.ok, isFalse);
      expect(r.error?.code, 'weather-search-failed');
      expect(r.error?.retryable, isTrue);
    });

    test('ok:false 且 error 缺失 → 合成 malformed-error 兜底', () {
      final r = KosResponse.fromJson(const {
        'version': 1,
        'requestId': '1',
        'ok': false,
      });
      expect(r.error?.code, 'malformed-error');
      expect(r.error?.retryable, isFalse);
    });
  });

  group('SocketKosDataClient 状态机（不触真实 socket）', () {
    test('断线：写操作立即失败，读操作排队', () async {
      final client = SocketKosDataClient(
        socketPath: '/nonexistent/kos-data.sock',
      );
      await client.connect(); // 连接失败 → available=false，调度重连
      expect(client.available, isFalse);

      // 写操作（非白名单）立即失败。
      await expectLater(
        client.request(KosDataOperations.weatherSetUnits).first,
        throwsA(isA<KosDataClientException>()),
      );
      // 读操作（白名单）不立即失败——挂在队列里等重连；dispose 后终结。
      var readEnded = false;
      client
          .request(KosDataOperations.weatherSnapshot)
          .first
          .then((_) {
            readEnded = true;
          })
          .catchError((Object e) {
            readEnded = true;
            expect(e, isA<KosDataClientException>());
          });
      await Future<void>.delayed(Duration.zero);
      expect(readEnded, isFalse); // 仍在队列中
      client.dispose();
      await Future<void>.delayed(Duration.zero);
      expect(readEnded, isTrue); // dispose 使排队请求失败
    });

    test('事件帧与响应帧在同流区分（event 键）', () {
      // 事件帧形状 {version,event,payload}（main.go:308-348）：本测试只
      // 断言事件流的广播形态存在且 dispose 后可安全结束。
      final client = SocketKosDataClient(
        socketPath: '/nonexistent/kos-data.sock',
      );
      expect(client.events, isA<Stream<Map<String, Object?>>>());
      client.dispose();
    });
  });

  group('widget-snapshot 解析', () {
    test('WidgetSnapshot.fromJson 拒绝 schemaVersion != 1', () {
      expect(
        () =>
            widgetSnapshotFromJson(decode('{"schemaVersion":2,"revision":1}')),
        throwsA(isA<FormatException>()),
      );
    });

    test('todo/event 字段逐项解析（PimStore.cpp:362-424）', () {
      final snapshot = widgetSnapshotFromJson(
        decode(
          '{"schemaVersion":1,"revision":42,"generatedAt":1700000000000,'
          '"today":"2026-09-30",'
          '"events":[{"id":"e1","seriesId":"s1","title":"会议",'
          '"start":"2026-09-30T09:00","end":"2026-09-30T10:00",'
          '"allDay":false,"calendarId":"personal","recurrence":"none",'
          '"reminderMinutes":10,"modifiedAt":"x","linkedTodoId":"t1"}],'
          '"todos":[{"id":"t1","title":"买奶","listId":"inbox","order":1.5,'
          '"due":"2026-10-02","priority":3,"completed":false,'
          '"reminderMinutes":-1,"modifiedAt":"y"}]}',
        ),
      );
      expect(snapshot.revision, 42);
      expect(snapshot.today, '2026-09-30');
      expect(snapshot.events, hasLength(1));
      expect(snapshot.events[0].linkedTodoId, 't1');
      expect(snapshot.events[0].reminderMinutes, 10);
      expect(snapshot.todos, hasLength(1));
      expect(snapshot.todos[0].order, 1.5);
      expect(snapshot.todos[0].priority, 3);
      expect(snapshot.todos[0].completed, isFalse);
      expect(snapshot.todos[0].due, '2026-10-02');
    });

    test('缺字段容错：数字/布尔/string 转换与空串兜底', () {
      final snapshot = widgetSnapshotFromJson(
        decode('{"schemaVersion":1,"revision":"5","todos":[{"id":12}]}'),
      );
      // _int 只认 num：字符串 "5" → 0；数字 id 转字符串。
      expect(snapshot.revision, 0);
      expect(snapshot.todos[0].id, '12');
      expect(snapshot.todos[0].completed, isFalse);
    });

    test('WidgetSnapshotWatcher 接口状态枚举', () {
      // 状态机枚举存在性（watcher 状态三态对齐
      // PimWidgetService.qml:27-30）。
      expect(
        WidgetSnapshotState.values,
        containsAll([
          WidgetSnapshotState.loading,
          WidgetSnapshotState.ready,
          WidgetSnapshotState.unavailable,
        ]),
      );
    });
  });

  group('WeatherSnapshot 解析（weather-v1.schema.json）', () {
    test('current/location/daily 字段逐项', () {
      final snap = WeatherSnapshot.fromJson(
        decode(
          '{"schemaVersion":1,"status":"ready",'
          '"location":{"id":"loc1","name":"上海"},'
          '"current":{"temperature":23.6,'
          '"apparentTemperature":24,"relativeHumidity":60,"isDay":true,'
          '"weatherCode":1,"windSpeed":5,"windDirection":90},'
          '"daily":[{"date":"2026-09-30","weatherCode":0,'
          '"temperatureMaximum":30.4,"temperatureMinimum":21.6,'
          '"precipitationProbability":0}]}',
        ),
      );
      expect(snap.status, 'ready');
      expect(snap.cityName, '上海');
      expect(snap.locationId, 'loc1');
      expect(snap.currentTemp, 23.6);
      expect(snap.weatherCode, 1);
      expect(snap.isDay, isTrue);
      expect(snap.forecast, hasLength(1));
      expect(snap.forecast[0].high, 30); // round(30.4)
      expect(snap.forecast[0].low, 22); // round(21.6)
      expect(snap.forecast[0].code, 0);
    });

    test('WeatherSnapshot schemaVersion 拒绝 + 缺失字段兜底', () {
      expect(
        () => WeatherSnapshot.fromJson(const {'schemaVersion': 0}),
        throwsA(isA<FormatException>()),
      );
      final empty = WeatherSnapshot.fromJson(const {
        'schemaVersion': 1,
        'daily': 'x',
      });
      expect(empty.cityName, '--'); // WeatherService.qml:26 回退
      expect(empty.currentTemp.isNaN, isTrue); // → "--°"
      expect(empty.weatherCode, -1); // WeatherService.qml:36
      expect(empty.isDay, isTrue); // :37
      expect(empty.forecast, isEmpty);
    });

    test('conditionText/conditionSymbol/forecastLabel 逐行对齐', () {
      expect(kosWeatherConditionText(0), '晴');
      expect(kosWeatherConditionText(51), '毛毛雨');
      expect(kosWeatherConditionText(95), '雷暴');
      expect(kosWeatherConditionText(99), '雷暴'); // >=95
      expect(kosWeatherConditionText(-1), '天气未知');
      expect(kosWeatherConditionSymbol(0, isDay: true), '☀');
      expect(kosWeatherConditionSymbol(0, isDay: false), '☾');
      expect(kosWeatherConditionSymbol(45, isDay: true), '≋');
      expect(kosWeatherConditionSymbol(95, isDay: false), 'ϟ');
      expect(kosWeatherForecastLabel('2026-09-30', 0), '今天');
      expect(kosWeatherForecastLabel('2026-09-30', 1), '明天');
      // 2026-10-02 为周五 → "周五"。
      expect(kosWeatherForecastLabel('2026-10-02', 2), '周五');
      expect(kosWeatherForecastLabel('not-a-date', 3), 'not-a-date');
    });
  });

  group('KosSystemMetrics 解析（MetricsService.qml:55-69 读取键）', () {
    test('标量字段 + history 提取', () {
      // at 为 Unix 毫秒（data-service main.go:1013）；>1h 旧样本按
      // MetricsService.qml:82-97 normalized 的窗口规则丢弃。
      final now = DateTime.now().millisecondsSinceEpoch;
      final m = KosSystemMetrics.fromJson(
        decode(
          '{"currentMilliC":46000,"maximum5MinuteMilliC":61000,'
          '"cpu":0.42,"frequencyMhz":3400.5,'
          '"memoryUsedBytes":8000000000,"memoryTotalBytes":16000000000,'
          '"diskUsedBytes":107374182400,"diskTotalBytes":536870912000,'
          '"history":[{"at":${now - 1000},"cpu":0.1,"memory":0.5,'
          '"frequencyMhz":3000},'
          '{"at":$now,"cpu":0.2,"memory":0.6,"frequencyMhz":3100},'
          '{"at":${now - 3700000},"cpu":0.9,"memory":0.9,'
          '"frequencyMhz":9999}]}',
        ),
      );
      expect(m.currentMilliC, 46000);
      expect(m.maximum5MinuteMilliC, 61000);
      expect(m.cpuFrequencyMhz, 3400.5);
      expect(m.memoryUsedBytes / m.memoryTotalBytes, closeTo(0.5, 1e-9));
      expect(m.memoryHistory, [0.5, 0.6]); // 61min 前的样本已过滤
      expect(m.frequencyHistory, [3000, 3100]);
    });
  });
}
