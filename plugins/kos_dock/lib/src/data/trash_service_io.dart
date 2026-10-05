/// freedesktop Trash 规范（`$XDG_DATA_HOME/Trash`）的 dart:io 实现。
///
/// KOS 的垃圾桶动作走 `kos-platform.sock` 平台请求（NextKde
/// `shell/desktop/modules/dock/DockTrashService.qml`：:16-25 state refresh、
/// :27-34 open、:36-49 empty）；Denial 无该平台通道（CONSTRAINTS §5 砍掉
/// `kos-platform.sock`、§10 接口/IO 分离），本文件是这三段的 dart:io 等价物：
/// - 状态 [TrashState]：`<root>/files` 顶层条目（freedesktop spec，KOS
///   只区分 full/empty）；
/// - [watch]：`Directory.watch` files/ + info/，事件 ~150ms 防抖后重发
///   （KOS 侧由平台推送/`depositReceived` 驱动，Denial 用 inotify 等价）；
/// - [open]：`xdg-open trash://`，失败回退 `xdg-open <root>`；
/// - [empty]：递归清空 files/ + info/ 内容，保留目录本身。
library;

import 'dart:async';
import 'dart:io';

import 'trash_service.dart';

typedef _CommandRunner = Future<ProcessResult> Function(
  String executable,
  List<String> arguments,
);

/// [TrashService] 的 freedesktop dart:io 实现。
final class FileTrashService implements TrashService {
  /// [root] 默认 `$XDG_DATA_HOME/Trash`（仅绝对路径），否则
  /// `$HOME/.local/share/Trash`；两者都不可用时抛 [FileSystemException]
  /// （容错风格对齐 `FileDockPreferencesStore.defaultFile`）。
  ///
  /// [commandRunner] 默认 [Process.run]；测试注入以拦截 `xdg-open`。
  FileTrashService({
    Directory? root,
    Future<ProcessResult> Function(String executable, List<String> arguments)?
    commandRunner,
  }) : root = root ?? _defaultRoot(),
       _run = commandRunner ?? Process.run;

  /// Trash 根目录（freedesktop spec：`<root>/files` + `<root>/info`）。
  final Directory root;
  final _CommandRunner _run;

  /// 事件去抖：一次写入/删除常产生多个 inotify 事件（Denial 新增；KOS
  /// DockTrashService.qml:51-54 `depositReceived` 直接置位，无对应行号）。
  static const Duration _debounce = Duration(milliseconds: 150);

  /// watch 报错后的重臂延时（目录被删/重建、inotify 失效时自愈）。
  static const Duration _rearmDelay = Duration(seconds: 1);

  Directory get _files => Directory('${root.path}/files');
  Directory get _info => Directory('${root.path}/info');

  /// 默认 root 推导（XDG_DATA_HOME 优先，与 `defaultFile` 同款容错：
  /// 只接受绝对路径，否则回退，全部不可用则抛出）。
  static Directory _defaultRoot() {
    final env = Platform.environment;
    final dataHome = env['XDG_DATA_HOME'];
    final home = env['HOME'];
    final path = dataHome != null && dataHome.startsWith('/')
        ? '$dataHome/Trash'
        : home != null && home.startsWith('/')
        ? '$home/.local/share/Trash'
        : null;
    if (path == null) {
      throw const FileSystemException('No trash directory');
    }
    return Directory(path);
  }

  /// files/ 顶层条目数；目录缺失 = 0。
  @override
  Future<int> count() async {
    if (!await _files.exists()) return 0;
    var total = 0;
    await for (final _ in _files.list()) {
      total++;
    }
    return total;
  }

  // KOS: dock/DockTrashService.qml:16-25（state refresh）。
  /// files/ 存在且有顶层条目（`count > 0` 即「存在且非空」；目录缺失 = 0）。
  @override
  Future<bool> hasItems() async => (await count()) > 0;

  // KOS: dock/DockTrashService.qml:27-34（open）。
  /// 确保目录存在；先
  /// `xdg-open trash://`，非 0 退出或异常时回退 `xdg-open <root>`；
  /// 两次都失败才抛。
  @override
  Future<void> open() async {
    await root.create(recursive: true);
    await _files.create(recursive: true);
    await _info.create(recursive: true);
    if (await _tryOpen('trash://')) return;
    final fallback = await _run('xdg-open', [root.path]);
    if (fallback.exitCode != 0) {
      throw ProcessException(
        'xdg-open',
        [root.path],
        'exit code ${fallback.exitCode}',
        fallback.exitCode,
      );
    }
  }

  Future<bool> _tryOpen(String target) async {
    try {
      final result = await _run('xdg-open', [target]);
      return result.exitCode == 0;
    } on Object {
      return false; // 异常与非 0 同等对待：交给 root 回退。
    }
  }

  // KOS: dock/DockTrashService.qml:36-49（empty）。
  /// 递归清空 files/ + info/ 的内容，保留目录本身；目录缺失跳过；
  /// 删除失败向上冒（不静默吞）。
  @override
  Future<void> empty() async {
    await _clearContents(_files);
    await _clearContents(_info);
  }

  static Future<void> _clearContents(Directory directory) async {
    if (!await directory.exists()) return;
    final entries = await directory.list().toList();
    for (final entry in entries) {
      await entry.delete(recursive: true);
    }
  }

  /// 订阅开始 emit 当前状态，随后每次 Trash 变化再 emit。
  ///
  /// 同时监听 files/ 与 info/（Directory.watch 默认顶层）；事件去抖
  /// ~150ms 后重算并 emit；watch 报错后短延时重臂；stream cancel 时清理
  /// 订阅与 Timer。
  @override
  Stream<TrashState> watch() {
    late final StreamController<TrashState> controller;
    StreamSubscription<FileSystemEvent>? filesWatch;
    StreamSubscription<FileSystemEvent>? infoWatch;
    Timer? debounce;
    Timer? rearm;
    var closed = false;

    /// emit 代次：只有最新一次求值可以落盘。两次 `count()` 可能并发完成
    /// （去抖窗口外的连续事件），完成顺序不保证——过期结果必须丢弃，
    /// 否则旧状态会覆盖新状态。
    var generation = 0;

    Future<void> emit() async {
      if (closed) return;
      final current = ++generation;
      final int value;
      try {
        value = await count();
      } on Object catch (error, stackTrace) {
        // 读取失败（权限/inotify 竞态）不产生未捕获异步错误：作为流错误
        // 上报，订阅者（StreamProvider）自行决定降级展示。
        if (!closed && current == generation) {
          controller.addError(error, stackTrace);
        }
        return;
      }
      // 已被更新的一次 emit 取代 / stream 已取消 → 丢弃过期结果。
      if (closed || current != generation) return;
      controller.add(TrashState(hasItems: value > 0, count: value));
    }

    void scheduleEmit() {
      debounce?.cancel();
      debounce = Timer(_debounce, () {
        debounce = null;
        unawaited(emit());
      });
    }

    /// 取消现有订阅：best effort，单个取消失败不影响另一个、也不中断
    /// 重臂（残留订阅只会产生多余事件，去抖 + 代次保证状态正确）。
    Future<void> cancelWatches() async {
      final files = filesWatch;
      final info = infoWatch;
      filesWatch = null;
      infoWatch = null;
      try {
        await files?.cancel();
      } on Object {
        // 忽略：inotify 竞态下的取消失败不应冒泡。
      }
      try {
        await info?.cancel();
      } on Object {
        // 同上。
      }
    }

    // `armWatches`/`scheduleRearm`/`armSafely` 互相引用：用 late 变量
    // 前向声明。
    late final Future<void> Function() armWatches;
    late final void Function() scheduleRearm;

    /// 重臂/启动用的安全调用：`cancelWatches`/`watch()` 抛错（inotify
    /// 竞态）不得变成未捕获异步错误，安排下一次重臂即可。
    Future<void> armSafely() async {
      try {
        await armWatches();
      } on Object {
        scheduleRearm();
      }
    }

    scheduleRearm = () {
      if (closed || rearm != null) return;
      rearm = Timer(_rearmDelay, () {
        rearm = null;
        unawaited(armSafely());
      });
    };

    armWatches = () async {
      if (closed) return;
      await cancelWatches();
      if (closed) return;
      // freedesktop Trash 目录可能尚未存在：先建出再监听；创建失败不抛，
      // 交给重臂循环再试。
      for (final directory in [_files, _info]) {
        try {
          await directory.create(recursive: true);
        } on FileSystemException {
          // 忽略：watch 会报错并触发重臂。
        }
      }
      if (closed) return;
      try {
        filesWatch = _files.watch().listen(
          (_) => scheduleEmit(),
          onError: (Object _) => scheduleRearm(),
          cancelOnError: true,
        );
        infoWatch = _info.watch().listen(
          (_) => scheduleEmit(),
          onError: (Object _) => scheduleRearm(),
          cancelOnError: true,
        );
      } on Object {
        scheduleRearm();
      }
    };

    Future<void> start() async {
      // 先 arm 再 emit：监听就绪后算出的「当前状态」不会漏掉 arm 窗口内的
      // 变化（若有事件，防抖后的重发会合并）。
      await armSafely();
      await emit();
    }

    controller = StreamController<TrashState>(
      onListen: () => unawaited(start()),
      onCancel: () async {
        closed = true;
        // 作废 in-flight emit：`count()` 完成时不再 add。
        generation++;
        debounce?.cancel();
        debounce = null;
        rearm?.cancel();
        rearm = null;
        await cancelWatches();
      },
    );
    return controller.stream;
  }
}
