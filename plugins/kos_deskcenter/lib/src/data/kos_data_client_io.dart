/// kos-data.sock JSONL 客户端的 dart:io 实现（`SocketKosDataClient`）。
///
/// 协议与降级语义事实来源（NextKde 仓库）：
/// - 信封 `DataRequest`/`DataResponse`/`DataError`：
///   services/data-service/main.go:120-139；
/// - 事件帧 `{version,event,payload{updatedAt}}`：main.go:291-294、308-348；
/// - socket 路径 `$XDG_RUNTIME_DIR/kos-data.sock`，`KOS_DATA_SOCKET` 覆盖：
///   main.go:1204-1207；
/// - 只读白名单六个操作、断线读排队（去重、上限 200）、写立即失败：
///   DataClient.qml:21-31、JsonlClient.qml:36-42；
/// - 已发未答 30s 过期（5s 扫描周期）、断连 failAll、~2s 周期重建连接：
///   JsonlClient.qml:43、124-129、170-171、199-204。
///
/// 本文档行号均指上述仓库内相对路径。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'kos_data_client.dart';

/// 断线/超时/关停/服务端错误时结束在途或排队请求的错误。
final class KosDataClientException implements Exception {
  const KosDataClientException(this.message);

  /// 服务端 `error.code` 前缀（若有）；本地错误为 `transport:`/`timeout:`/
  /// `disposed:` 前缀。
  final String message;

  @override
  String toString() => 'KosDataClientException: $message';
}

/// `kos-data.sock` 的 [KosDataClient] dart:io 实现。
///
/// 单连接长驻，请求/响应与事件帧在同一连接上交错（data-channels.md §1.1）；
/// 断线时只读操作按 operation 去重排队（上限 200），写操作立即失败；
/// 连接由客户端以 2s 周期重建（JsonlClient.qml:199-204）。socket 打开即
/// 视为 connected（对齐 JsonlClient.qml:114-118 直接 flush，服务端无
/// 握手帧）。
final class SocketKosDataClient implements KosDataClient {
  SocketKosDataClient({String? socketPath})
    : _socketPath = socketPath ?? _defaultSocketPath();

  /// 只读白名单（与 DataClient.qml:24-31 逐字一致的六个操作）。
  static const Set<String> _readOnlyOperations = {
    'activity.snapshot',
    'desktop.refresh',
    'desktop.snapshot',
    'metrics.snapshot',
    'weather.refresh',
    'weather.snapshot',
  };

  /// 断线读队列上限（JsonlClient.qml:36-42；data-channels.md §1.5）。
  static const int _queueLimit = 200;

  /// 已发未答请求超时（JsonlClient.qml:43 `30000ms`）。
  static const Duration _requestTimeout = Duration(seconds: 30);

  /// 过期扫描周期（JsonlClient.qml:124-129 `Timer interval: 5000`）。
  static const Duration _expiryScanInterval = Duration(seconds: 5);

  /// 重连间隔（JsonlClient.qml:199-204 ~2s 周期重建）。
  static const Duration _reconnectDelay = Duration(seconds: 2);

  final String _socketPath;

  Socket? _socket;
  StreamSubscription<String>? _lines;
  bool _available = false;
  bool _connecting = false;
  bool _disposed = false;
  Timer? _reconnectTimer;
  Timer? _expiryTimer;
  int _nextRequestId = 0;

  /// 在途请求：requestId → 控制器与到期时刻。
  final Map<String, _PendingRequest> _inFlight = {};

  /// 断线排队的只读请求；按 operation 去重——快照类读重放最新一次即可
  /// （对齐 JsonlClient.qml:36-42 的去重语义）。
  final Map<String, _QueuedRequest> _readQueue = {};

  final StreamController<Map<String, Object?>> _events =
      StreamController<Map<String, Object?>>.broadcast();

  /// 解析 socket 路径：`KOS_DATA_SOCKET` 优先（main.go:1204-1207），其次
  /// `$XDG_RUNTIME_DIR/kos-data.sock`；XDG_RUNTIME_DIR 缺失时回退
  /// `/run/user/$UID`（dart:io 无 getuid，读 `UID` 环境，再缺省 1000）。
  static String _defaultSocketPath() {
    final env = Platform.environment;
    final override = env['KOS_DATA_SOCKET'];
    if (override != null && override.isNotEmpty) return override;
    final runtimeDir =
        env['XDG_RUNTIME_DIR'] ?? '/run/user/${env['UID'] ?? '1000'}';
    return '$runtimeDir/kos-data.sock';
  }

  @override
  bool get available => _available;

  @override
  Stream<Map<String, Object?>> get events => _events.stream;

  @override
  Future<void> connect() async {
    if (_disposed || _available) return;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    await _openSocket();
    if (!_available && !_disposed) _scheduleReconnect();
  }

  Future<void> _openSocket() async {
    if (_connecting || _disposed) return;
    _connecting = true;
    try {
      final socket = await Socket.connect(
        InternetAddress(_socketPath, type: InternetAddressType.unix),
        0,
      );
      if (_disposed) {
        socket.destroy();
        return;
      }
      _attach(socket);
    } on Object {
      _available = false;
    } finally {
      _connecting = false;
    }
  }

  void _attach(Socket socket) {
    _socket = socket;
    _available = true;
    _lines = socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          _handleLine,
          onError: (_) => _dropConnection(),
          onDone: _dropConnection,
          cancelOnError: true,
        );
    _flushReadQueue();
  }

  void _dropConnection() {
    unawaited(_lines?.cancel());
    _socket?.destroy();
    _socket = null;
    _lines = null;
    _available = false;
    // 断连使全部在途请求失败（failAll，JsonlClient.qml:170-171）。
    final pending = _inFlight.values.toList();
    _inFlight.clear();
    for (final request in pending) {
      request.fail(
        const KosDataClientException('transport: kos-data.sock 已断开'),
      );
    }
    if (!_disposed) _scheduleReconnect();
  }

  void _scheduleReconnect() {
    _reconnectTimer ??= Timer(_reconnectDelay, () {
      _reconnectTimer = null;
      if (_disposed || _available) return;
      unawaited(connect());
    });
  }

  void _handleLine(String line) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) return;
    Object? decoded;
    try {
      decoded = jsonDecode(trimmed);
    } on FormatException {
      return; // 服务端不产非法行；防御性丢弃。
    }
    if (decoded is! Map) return;
    final frame = decoded.map((key, value) => MapEntry(key.toString(), value));
    // 事件帧以 `event` 键区分，不带 requestId（main.go:291-311）。
    if (frame['event'] is String) {
      if (!_events.isClosed) _events.add(frame);
      return;
    }
    final response = KosResponse.fromJson(frame);
    final pending = _inFlight.remove(response.requestId);
    if (pending == null) return; // 未知/已过期 requestId，丢弃。
    pending.complete(response);
  }

  void _flushReadQueue() {
    if (!_available) return;
    final queued = _readQueue.values.toList();
    _readQueue.clear();
    for (final request in queued) {
      _send(request.operation, request.payload, request.controller);
    }
  }

  @override
  Stream<Map<String, Object?>> request(
    String operation, [
    Map<String, Object?> payload = const {},
  ]) {
    final controller = StreamController<Map<String, Object?>>();
    if (_disposed) {
      controller
        ..addError(const KosDataClientException('disposed: 客户端已关闭'))
        ..close();
      return controller.stream;
    }
    _ensureExpiryTimer();
    if (!_available) {
      // 读排队、写失败（DataClient.qml:21-31）。
      if (_readOnlyOperations.contains(operation)) {
        _enqueue(operation, payload, controller);
      } else {
        controller
          ..addError(
            KosDataClientException('transport: 断线，写操作 $operation 立即失败'),
          )
          ..close();
      }
      return controller.stream;
    }
    _send(operation, payload, controller);
    return controller.stream;
  }

  void _enqueue(
    String operation,
    Map<String, Object?> payload,
    StreamController<Map<String, Object?>> controller,
  ) {
    // 去重：同 operation 的旧排队请求以最新取代（旧请求以断线错误结束）。
    _readQueue.remove(operation)?.controller
      ?..addError(const KosDataClientException('transport: 读请求被同操作更新取代'))
      ..close();
    if (_readQueue.length >= _queueLimit) {
      // 队列满：丢弃最旧一条。
      _readQueue.remove(_readQueue.keys.first)!.controller
        ..addError(const KosDataClientException('transport: 读队列已满（200）'))
        ..close();
    }
    _readQueue[operation] = _QueuedRequest(operation, payload, controller);
  }

  void _send(
    String operation,
    Map<String, Object?> payload,
    StreamController<Map<String, Object?>> controller,
  ) {
    final requestId = '${++_nextRequestId}';
    final request = KosRequest(
      requestId: requestId,
      operation: operation,
      payload: payload,
    );
    try {
      _socket!.write('${jsonEncode(request.toJson())}\n');
    } on Object {
      controller
        ..addError(const KosDataClientException('transport: 写入失败'))
        ..close();
      return;
    }
    _inFlight[requestId] = _PendingRequest(
      controller,
      DateTime.now().add(_requestTimeout),
    );
  }

  /// 过期扫描：30s 未答的请求以超时错误结束（JsonlClient.qml:43、124-129）。
  void _pruneExpired() {
    if (_inFlight.isEmpty) {
      _expiryTimer?.cancel();
      _expiryTimer = null;
      return;
    }
    final now = DateTime.now();
    final expired = _inFlight.entries
        .where((entry) => now.isAfter(entry.value.deadline))
        .map((entry) => entry.key)
        .toList();
    for (final requestId in expired) {
      _inFlight
          .remove(requestId)!
          .fail(const KosDataClientException('timeout: 30s 未收到响应'));
    }
  }

  /// 惰性启动的 5s 过期扫描（JsonlClient.qml:124-129）。
  void _ensureExpiryTimer() {
    _expiryTimer ??= Timer.periodic(
      _expiryScanInterval,
      (_) => _pruneExpired(),
    );
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _reconnectTimer?.cancel();
    _expiryTimer?.cancel();
    final queued = _readQueue.values.toList();
    _readQueue.clear();
    for (final request in queued) {
      request.controller
        ..addError(const KosDataClientException('disposed: 客户端已关闭'))
        ..close();
    }
    _dropConnection();
    unawaited(_events.close());
  }
}

/// 在途请求：把响应信封单元素泵入请求方持有的流。
final class _PendingRequest {
  const _PendingRequest(this.controller, this.deadline);

  final StreamController<Map<String, Object?>> controller;
  final DateTime deadline;

  void complete(KosResponse response) {
    if (response.ok) {
      final result = response.result;
      controller.add(
        result is Map
            ? result.map((key, value) => MapEntry(key.toString(), value))
            : <String, Object?>{'result': result},
      );
      unawaited(controller.close());
    } else {
      fail(
        KosDataClientException(
          response.error != null
              ? '${response.error!.code}: ${response.error!.message}'
              : 'unknown: 响应失败',
        ),
      );
    }
  }

  void fail(Object error) {
    controller
      ..addError(error)
      ..close();
  }
}

/// 断线排队的只读请求。
final class _QueuedRequest {
  const _QueuedRequest(this.operation, this.payload, this.controller);

  final String operation;
  final Map<String, Object?> payload;
  final StreamController<Map<String, Object?>> controller;
}
