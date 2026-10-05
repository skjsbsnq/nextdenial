// FileTrashService（freedesktop Trash，dart:io）测试（TASK-04）。
//
// 注入真 root（`Directory.systemTemp`）+ 注入 commandRunner，不触真实
// `~/.local/share/Trash` 或 `xdg-open`；watch 走真实 inotify（kos_deskcenter
// `zz_io_probe_test.dart` 已证测试区内真 IO 可用），等待带 timeout。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kos_dock/src/data/trash_service.dart';
import 'package:kos_dock/src/data/trash_service_io.dart';

ProcessResult _result(int exitCode, [String stdout = '']) =>
    ProcessResult(0, exitCode, stdout, '');

Future<void> _waitFor(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 10),
  String reason = 'timed out waiting for condition',
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail(reason);
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('kos_dock_trash_');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  group('count/hasItems', () {
    test('目录缺失 = 0/false；顶层条目增删后跟随变化', () async {
      final service = FileTrashService(root: root);
      expect(await service.count(), 0);
      expect(await service.hasItems(), isFalse);

      // files/ 存在但空 → 仍为 0/false。
      await Directory('${root.path}/files').create(recursive: true);
      expect(await service.count(), 0);
      expect(await service.hasItems(), isFalse);

      await File('${root.path}/files/a.txt').writeAsString('a');
      await File('${root.path}/files/b.txt').writeAsString('b');
      expect(await service.count(), 2);
      expect(await service.hasItems(), isTrue);

      await File('${root.path}/files/a.txt').delete();
      expect(await service.count(), 1);
      await File('${root.path}/files/b.txt').delete();
      expect(await service.count(), 0);
      expect(await service.hasItems(), isFalse);
    });

    test('只数顶层条目（子目录记 1）', () async {
      final service = FileTrashService(root: root);
      await Directory('${root.path}/files/nested').create(recursive: true);
      await File('${root.path}/files/nested/deep.txt').writeAsString('x');
      await File('${root.path}/files/top.txt').writeAsString('x');
      expect(await service.count(), 2);
    });
  });

  group('empty', () {
    test('递归清空 files+info 内容并保留目录本身', () async {
      final service = FileTrashService(root: root);
      final files = Directory('${root.path}/files');
      final info = Directory('${root.path}/info');
      await Directory('${files.path}/nested').create(recursive: true);
      await File('${files.path}/nested/deep.txt').writeAsString('x');
      await File('${files.path}/top.txt').writeAsString('x');
      // info/ 先建出：否则写 top.trashinfo 会 PathNotFound（本轮修复）。
      await info.create(recursive: true);
      await File('${info.path}/top.trashinfo').writeAsString('x');
      await Directory('${info.path}/sub').create(recursive: true);
      await File('${info.path}/sub/deep.trashinfo').writeAsString('x');
      expect(await service.count(), 2);

      await service.empty();

      expect(await files.exists(), isTrue);
      expect(await info.exists(), isTrue);
      expect(await files.list().toList(), isEmpty);
      expect(await info.list().toList(), isEmpty);
      expect(await service.count(), 0);
      expect(await service.hasItems(), isFalse);
    });

    test('目录缺失时跳过（不抛）', () async {
      final service = FileTrashService(root: root);
      await service.empty();
      expect(await service.count(), 0);
    });
  });

  group('open', () {
    test('trash:// 成功 → 只调一次且不回调退；目录被建出', () async {
      final calls = <List<String>>[];
      final service = FileTrashService(
        root: root,
        commandRunner: (executable, arguments) async {
          calls.add([executable, ...arguments]);
          return _result(0);
        },
      );

      await service.open();

      expect(calls, [
        ['xdg-open', 'trash://'],
      ]);
      expect(await root.exists(), isTrue);
      expect(await Directory('${root.path}/files').exists(), isTrue);
      expect(await Directory('${root.path}/info').exists(), isTrue);
    });

    test('trash:// 非 0 退出 → 回退 xdg-open root', () async {
      final calls = <List<String>>[];
      final service = FileTrashService(
        root: root,
        commandRunner: (executable, arguments) async {
          calls.add([executable, ...arguments]);
          return arguments.first == 'trash://' ? _result(4) : _result(0);
        },
      );

      await service.open();

      expect(calls, [
        ['xdg-open', 'trash://'],
        ['xdg-open', root.path],
      ]);
    });

    test('trash:// 抛异常 → 回退 root', () async {
      final calls = <List<String>>[];
      final service = FileTrashService(
        root: root,
        commandRunner: (executable, arguments) async {
          calls.add([executable, ...arguments]);
          if (arguments.first == 'trash://') {
            throw ProcessException(executable, arguments);
          }
          return _result(0);
        },
      );

      await service.open();

      expect(calls, [
        ['xdg-open', 'trash://'],
        ['xdg-open', root.path],
      ]);
    });

    test('两次都失败才抛 ProcessException', () async {
      final service = FileTrashService(
        root: root,
        commandRunner: (executable, arguments) async => _result(1),
      );
      await expectLater(service.open(), throwsA(isA<ProcessException>()));
    });
  });

  group('watch', () {
    test('初始 emit 当前状态；新增/删除文件后再 emit', () async {
      final service = FileTrashService(root: root);
      final states = <TrashState>[];
      final subscription = service.watch().listen(states.add);
      addTearDown(subscription.cancel);

      await _waitFor(() => states.isNotEmpty, reason: 'watch 未发出初始状态');
      expect(states.first.hasItems, isFalse);
      expect(states.first.count, 0);

      await File('${root.path}/files/new.txt').writeAsString('x');
      await _waitFor(
        () => states.any((state) => state.hasItems && state.count == 1),
        reason: '新增文件后没有 emit 非空状态',
      );

      await File('${root.path}/files/new.txt').delete();
      await _waitFor(
        () => states.last.hasItems == false && states.last.count == 0,
        reason: '删除文件后没有 emit 空状态',
      );

      await subscription.cancel();
    });

    test('cancel 后不再 emit（Timer/订阅清理）', () async {
      final service = FileTrashService(root: root);
      final states = <TrashState>[];
      final subscription = service.watch().listen(states.add);
      await _waitFor(() => states.isNotEmpty, reason: 'watch 未发出初始状态');

      await subscription.cancel();
      final emitted = states.length;
      await File('${root.path}/files/after-cancel.txt').writeAsString('x');
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(states.length, emitted);
    });

    test('info/ 单独变化也能 emit（同时监听 files+info）', () async {
      final service = FileTrashService(root: root);
      final states = <TrashState>[];
      final subscription = service.watch().listen(states.add);
      addTearDown(subscription.cancel);
      await _waitFor(() => states.isNotEmpty, reason: 'watch 未发出初始状态');

      final before = states.length;
      await File('${root.path}/info/only.trashinfo').writeAsString('x');
      await _waitFor(
        () => states.length > before,
        reason: 'info/ 变化未触发 emit',
      );
      // files/ 仍为空 → 仍是空态。
      expect(states.last.hasItems, isFalse);
      expect(states.last.count, 0);
    });

    test('150ms 去抖：突发写入合并为一次 emit', () async {
      final service = FileTrashService(root: root);
      final states = <TrashState>[];
      final subscription = service.watch().listen(states.add);
      addTearDown(subscription.cancel);
      await _waitFor(() => states.isNotEmpty, reason: 'watch 未发出初始状态');
      final before = states.length;

      await Future.wait([
        for (var i = 0; i < 5; i++)
          File('${root.path}/files/burst-$i.txt').writeAsString('x'),
      ]);
      await _waitFor(
        () => states.last.count == 5,
        reason: '突发写入后没有 emit 最终计数',
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));
      // 5 个写入（每个产生多个 inotify 事件）被 150ms 去抖合并成极少次 emit。
      expect(states.length - before, lessThanOrEqualTo(2));
    });

    test('watch 报错（Trash 目录建不出来）→ 重臂后仍能 emit', () async {
      // 错误注入：root 的父路径是一个普通文件 → files/info 无法创建、
      // Directory.watch 抛 FileSystemException → 走 rearm 分支。
      final blocker = File('${root.path}/blocker');
      await blocker.writeAsString('x');
      final blocked = Directory('${blocker.path}/trash');
      final service = FileTrashService(root: blocked);
      final states = <TrashState>[];
      final subscription = service.watch().listen(states.add);
      addTearDown(subscription.cancel);

      // 初始 emit 仍给出空态（读不到目录 = 0），且无未捕获异步错误。
      await _waitFor(() => states.isNotEmpty, reason: 'watch 未发出初始状态');
      expect(states.first.count, 0);

      // 解除阻塞：真实目录树建出；重臂（1s 延时）后才重新 arm 监听，故
      // 重臂前写入的事件不会补发——循环追加写入直到收到非空 emit。
      await blocker.delete();
      final files = Directory('${blocked.path}/files');
      await files.create(recursive: true);
      await Directory('${blocked.path}/info').create(recursive: true);

      final deadline = DateTime.now().add(const Duration(seconds: 10));
      var attempt = 0;
      while (!states.any((state) => state.hasItems)) {
        if (DateTime.now().isAfter(deadline)) {
          fail('重臂后 watch 未恢复 emit');
        }
        await Future<void>.delayed(const Duration(milliseconds: 200));
        await File('${files.path}/after-rearm-${attempt++}.txt')
            .writeAsString('x');
      }
      expect(states.last.count, greaterThan(0));
    });

    test('count() 抛错（files/ 不可读）→ 流错误上报，权限恢复后继续 emit',
        () async {
      final service = FileTrashService(root: root);
      final files = Directory('${root.path}/files');
      await files.create(recursive: true);
      await File('${files.path}/a.txt').writeAsString('x');
      final states = <TrashState>[];
      final errors = <Object>[];
      final subscription = service.watch().listen(
        states.add,
        onError: errors.add,
      );
      addTearDown(subscription.cancel);
      await _waitFor(() => states.isNotEmpty, reason: 'watch 未发出初始状态');
      expect(states.first.count, 1);

      // 去掉读权限 → count() 的 Directory.list() 抛 FileSystemException。
      await Process.run('chmod', ['000', files.path]);
      addTearDown(() => Process.run('chmod', ['755', files.path]));
      if (!await _listThrows(files)) {
        // 以 root 运行时 chmod 不生效：错误注入不可用（环境限制）。
        return;
      }

      // info/ 事件触发一次 emit → count() 抛错 → 作为流错误上报。
      await File('${root.path}/info/err.trashinfo').writeAsString('x');
      await _waitFor(
        () => errors.isNotEmpty,
        reason: 'count() 抛错未上报为流错误',
      );
      expect(errors.first, isA<FileSystemException>());

      // 权限恢复 → 后续事件照常 emit（watch 未被错误毒化）。
      await Process.run('chmod', ['755', files.path]);
      final errorCount = errors.length;
      final before = states.length;
      await File('${files.path}/b.txt').writeAsString('x');
      await _waitFor(
        () => states.length > before && states.last.count == 2,
        reason: '错误恢复后 watch 未继续 emit',
      );
      expect(errors.length, errorCount);
    });
  });
}

/// `dir.list()` 是否抛 `FileSystemException`（chmod 注入是否生效的探针）。
Future<bool> _listThrows(Directory dir) async {
  try {
    await dir.list().toList();
    return false;
  } on FileSystemException {
    return true;
  }
}
