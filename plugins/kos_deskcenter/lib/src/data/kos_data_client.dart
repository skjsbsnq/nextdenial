/// kos-data.sock JSONL 客户端接口骨架（无 socket 实现）。
///
/// 协议事实来源（NextKde 仓库）：
/// - 信封与错误模型：services/data-service/main.go:120-139
///   （`DataRequest`/`DataResponse`/`DataError`）；
/// - 操作分发：services/data-service/main.go:1057-1145（`handleRequest`）；
/// - 订阅与事件帧：services/data-service/main.go:275-295、308-348
///   （`subscribeDesktop` 连接即注册订阅，`broadcastEvent`:308-337 与
///   `publishDesktop`:339-341/`publishWeather`:346-348 推送事件帧
///   `{version,event,payload{updatedAt}}`）；
/// - socket 路径与权限：main.go:1204-1207（`$XDG_RUNTIME_DIR/kos-data.sock`，
///   可被 `KOS_DATA_SOCKET` 覆盖）、main.go:1154（chmod 0600）；
/// - 读/写操作语义（读操作断线可排队、写操作立即失败）：
///   shell/desktop/modules/platform/DataClient.qml:21-31。
///
/// 完整协议说明与降级语义见仓库 docs/data-channels.md。
/// 传输实现见 `kos_data_client_io.dart`（`SocketKosDataClient`）。
library;

import 'dart:async';

/// kos-data.sock 支持的操作名。
///
/// 清单对齐 services/data-service/main.go:1061-1144 的 `handleRequest`
/// 分发与 docs/ShellDataService.md:41-45。
abstract final class KosDataOperations {
  /// 读：CPU/内存/磁盘/频率/温度/传感器快照；result 键 `metrics`。
  static const metricsSnapshot = 'metrics.snapshot';

  /// 读：开机时长与前台应用时长榜；result 键 `activity`。
  static const activitySnapshot = 'activity.snapshot';

  /// 写：上报当前前台应用 `{appID,name,icon?}`；断线时不排队，立即失败
  /// （DataClient.qml:22-23 的 write 语义）。
  static const activityActiveApp = 'activity.active-app';

  /// 读：桌面目录条目快照；result 键 `desktop`。
  static const desktopSnapshot = 'desktop.snapshot';

  /// 触发一次完整目录扫描并广播 `desktop.changed`；result `{refreshed}`。
  static const desktopRefresh = 'desktop.refresh';

  /// 写：设置逐输出桌面布局（payload 见 main.go `configureDesktopOutputs`）。
  static const desktopOutputs = 'desktop.outputs';

  /// 写：桌面条目落位（payload 见 main.go `placeDesktopEntries`）。
  static const desktopPlace = 'desktop.place';

  /// 读：天气状态（位置/单位/预报/缓存）；result 键 `weather`，
  /// 结构遵循 shared/contracts/weather-v1.schema.json。
  static const weatherSnapshot = 'weather.snapshot';

  /// 只读 RPC：Open-Meteo 位置搜索 `{query,language,limit?}`；limit 默认
  /// 8，服务端不设上限（main.go:1092-1095）。不在只读白名单
  /// （DataClient.qml:24-31），断线即失败。result `{locations}`。
  static const weatherSearch = 'weather.search';

  /// 写：立即刷新预报；result `{accepted}`。
  static const weatherRefresh = 'weather.refresh';

  /// 写：设置天气位置 `{location}`（WeatherLocation 对象）。
  static const weatherSetLocation = 'weather.set-location';

  /// 写：设置单位 `{units}`（metric/imperial 等，见 weather.go）。
  static const weatherSetUnits = 'weather.set-units';
}

/// 事件帧的 `event` 名（services/data-service/main.go:308-348，
/// `broadcastEvent`/`publishDesktop`/`publishWeather`）。
abstract final class KosDataEvents {
  /// 桌面目录扫描持久化后推送；订阅建立时也会立即收到一帧
  /// （main.go:291-294）。
  static const desktopChanged = 'desktop.changed';

  /// 天气状态一次完整迁移完成后推送；客户端随后应发
  /// [KosDataOperations.weatherSnapshot] 取数（ShellDataService.md:47-50）。
  static const weatherChanged = 'weather.changed';
}

/// 请求信封 `{version,requestId,operation,payload}`。
///
/// 对应 Go 端 `DataRequest`（main.go:120-125）。
final class KosRequest {
  const KosRequest({
    required this.requestId,
    required this.operation,
    this.payload = const {},
    this.version = 1,
  });

  /// 协议版本，当前恒为 1（main.go:1058-1060 拒绝非 0/1 版本）。
  final int version;

  /// 客户端生成的关联 id，回包原样 echo。
  final String requestId;
  final String operation;
  final Map<String, Object?> payload;

  factory KosRequest.fromJson(Map<String, Object?> json) => KosRequest(
    requestId: json['requestId']?.toString() ?? '',
    operation: json['operation']?.toString() ?? '',
    payload: switch (json['payload']) {
      final Map<String, Object?> payload => payload,
      final Map payload => payload.map(
        (key, value) => MapEntry(key.toString(), value),
      ),
      _ => const {},
    },
    version: switch (json['version']) {
      final int v => v,
      final num v => v.toInt(),
      _ => 1,
    },
  );

  Map<String, Object?> toJson() => {
    'version': version,
    'requestId': requestId,
    'operation': operation,
    'payload': payload,
  };
}

/// 响应信封 `{version,requestId,ok,result|error{code,message,retryable}}`。
///
/// 对应 Go 端 `DataResponse`/`DataError`（main.go:127-139）；事件帧
/// （`{version,event,payload}`）不走本类型，见 [KosDataClient.events]。
final class KosResponse {
  const KosResponse({
    required this.requestId,
    required this.ok,
    this.result,
    this.error,
    this.version = 1,
  });

  final int version;
  final String requestId;
  final bool ok;
  final Object? result;
  final KosError? error;

  /// `ok:true` 带 `result`，否则带 `error`（main.go:127-139）；两者互斥，
  /// error 结构非法时合成兜底错误码 `malformed-error`。
  factory KosResponse.fromJson(Map<String, Object?> json) {
    final ok = json['ok'] == true;
    final errorJson = json['error'];
    return KosResponse(
      requestId: json['requestId']?.toString() ?? '',
      ok: ok,
      result: json['result'],
      error: switch (errorJson) {
        final Map<String, Object?> error => KosError.fromJson(error),
        final Map error => KosError.fromJson(
          error.map((key, value) => MapEntry(key.toString(), value)),
        ),
        // ok:false 但缺少合法 error 对象时合成兜底错误，保持互斥。
        _ when !ok => const KosError(
          code: 'malformed-error',
          message: '响应失败但缺少 error 对象',
          retryable: false,
        ),
        _ => null,
      },
      version: switch (json['version']) {
        final int v => v,
        final num v => v.toInt(),
        _ => 1,
      },
    );
  }

  Map<String, Object?> toJson() => {
    'version': version,
    'requestId': requestId,
    'ok': ok,
    if (result != null) 'result': result,
    if (error != null) 'error': error!.toJson(),
  };
}

/// `error` 对象 `{code,message,retryable}`（main.go:135-139）。
final class KosError {
  const KosError({
    required this.code,
    required this.message,
    required this.retryable,
  });

  /// 稳定的机器可读错误码（如 `unknown-operation`、`invalid-json`、
  /// `unsupported-version`、`weather-search-failed`）。
  final String code;
  final String message;

  /// 是否可在稍后重试（服务端判定，main.go:1031-1034）。
  final bool retryable;

  factory KosError.fromJson(Map<String, Object?> json) => KosError(
    code: json['code']?.toString() ?? '',
    message: json['message']?.toString() ?? '',
    retryable: json['retryable'] == true,
  );

  Map<String, Object?> toJson() => {
    'code': code,
    'message': message,
    'retryable': retryable,
  };
}

/// kos-data.sock 客户端接口。
///
/// 传输语义（对齐 JsonlClient.qml:36-60 与 DataClient.qml:21-31）：
/// - 单连接长驻：同一连接上复用请求/响应与事件帧；
/// - 只读白名单恰为六个操作（与 DataClient.qml:24-31 逐字一致）：
///   `activity.snapshot`、`desktop.refresh`、`desktop.snapshot`、
///   `metrics.snapshot`、`weather.refresh`、`weather.snapshot`；断线时
///   可做有界去重排队（上限 200），重连后 flush 一次；
/// - 其余一律视为写操作（`activity.active-app`、`weather.search`、
///   `weather.set-location`、`weather.set-units`、`desktop.outputs`、
///   `desktop.place`），断线立即失败，不允许陈旧重放；
/// - 已发未答请求按 30s 超时过期（JsonlClient.qml:43），断连使全部在途
///   请求失败；
/// - 重连由客户端驱动（JsonlClient.qml:190-204，2s 间隔重建 socket）。
abstract interface class KosDataClient {
  /// 发一条请求并返回其响应流（单元素后关闭；超时/断连以错误结束）。
  ///
  /// [payload] 缺省 `{}`。
  Stream<Map<String, Object?>> request(
    String operation, [
    Map<String, Object?> payload = const {},
  ]);

  /// 服务推送的事件帧流 `{version,event,payload}`；当前事件名见
  /// [KosDataEvents]。事件与响应在同一连接上交错到达，由
  /// `event` 键区分（main.go:291-311）。
  Stream<Map<String, Object?>> get events;

  /// 建立（或重建）到 `$XDG_RUNTIME_DIR/kos-data.sock` 的连接；
  /// `KOS_DATA_SOCKET` 环境变量可覆盖路径（main.go:1204-1207）。
  Future<void> connect();

  /// 当前 socket 是否可用（已连接且未处于重连间隙）。
  bool get available;

  /// 关闭连接并使全部在途请求失败；之后对象不可复用。
  void dispose();
}
