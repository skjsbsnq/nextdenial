// Tests for the dock.json store (lib/src/data/dock_store.dart) — the TASK-07
// port of quickshell Common/functions/DockModel.js plus the XDG trash probe.
//
// Plain `test()` cases (no widget binding): the store uses synchronous
// dart:io, so nothing here touches the Flutter fake-async zone.

import 'dart:convert';
import 'dart:io';

import 'package:kos_dock/src/data/dock_store.dart';
import 'package:test/test.dart';

/// Decodes [json] text and asserts it fails strict validation.
DockConfig? _decode(String json) => decodeDockConfig(json);

Map<String, Object?> _wrap({
  Object? schemaVersion = 1,
  Object? options = const <String, Object?>{},
  Object? pinned = const <Object?>[],
}) => <String, Object?>{
  'schemaVersion': schemaVersion,
  'options': options,
  'pinned': pinned,
};

void main() {
  group('DockOptions defaults', () {
    test('match DockModel.js:3-18 exactly', () {
      const options = DockOptions.defaults;
      expect(options.enabled, isTrue);
      expect(options.position, DockPosition.bottom);
      expect(options.iconSize, 48);
      expect(options.magnification, isTrue);
      expect(options.magnificationScale, 1.5);
      expect(options.autoHide, isFalse);
      expect(options.launchBounce, isTrue);
      expect(options.showIndicators, isTrue);
      expect(options.showRecent, isTrue);
      expect(options.showThumbnails, isTrue);
      expect(options.previewSize, 160);
      expect(options.contextPinning, isTrue);
      expect(options.toJson().keys, <String>[
        'enabled',
        'position',
        'iconSize',
        'magnification',
        'magnificationScale',
        'autoHide',
        'launchBounce',
        'showIndicators',
        'showRecent',
        'showThumbnails',
        'previewSize',
        'contextPinning',
      ]);
    });

    test('numeric domains clamp (DockModel.js:36-38)', () {
      final options = DockOptions.fromJson(<Object?, Object?>{
        'iconSize': 999,
        'previewSize': 1,
        'magnificationScale': 3,
      })!;
      expect(options.iconSize, 80);
      expect(options.previewSize, 96);
      expect(options.magnificationScale, 2.0);

      final low = DockOptions.fromJson(<Object?, Object?>{
        'iconSize': 1,
        'previewSize': 9999,
        'magnificationScale': 0.5,
      })!;
      expect(low.iconSize, 32);
      expect(low.previewSize, 240);
      expect(low.magnificationScale, 1.0);
    });

    test('rounds fractional sizes (Math.round, DockModel.js:36-37)', () {
      final options = DockOptions.fromJson(<Object?, Object?>{
        'iconSize': 47.6,
        'previewSize': 160.4,
      })!;
      expect(options.iconSize, 48);
      expect(options.previewSize, 160);
    });

    test('rejects wrong types, unknown names and non-finite numbers', () {
      expect(DockOptions.fromJson(<Object?, Object?>{'enabled': 'yes'}), isNull);
      expect(DockOptions.fromJson(<Object?, Object?>{'position': 'top'}), isNull);
      expect(DockOptions.fromJson(<Object?, Object?>{'iconSize': '48'}), isNull);
      expect(DockOptions.fromJson(<Object?, Object?>{'iconSize': double.infinity}), isNull);
      expect(DockOptions.fromJson(<Object?, Object?>{'iconSize': double.nan}), isNull);
      expect(DockOptions.fromJson(<Object?, Object?>{'nope': 1}), isNull);
      expect(DockOptions.fromJson(<Object?, Object?>{'magnification': 1}), isNull);
    });

    test('legacy separatorSize: finite number tolerated, else whole doc null', () {
      final tolerated = DockOptions.fromJson(<Object?, Object?>{
        'separatorSize': 12.5,
      })!;
      expect(tolerated.toJson().containsKey('separatorSize'), isFalse);
      expect(DockOptions.fromJson(<Object?, Object?>{'separatorSize': 'x'}), isNull);
      expect(DockOptions.fromJson(<Object?, Object?>{'separatorSize': double.nan}), isNull);
    });
  });

  group('decodeDockConfig strict validation (DockModel.js:42-87)', () {
    test('accepts a minimal document and returns defaults', () {
      final config = _decode(jsonEncode(_wrap()))!;
      expect(config.options, isNotNull);
      expect(config.options.iconSize, 48);
      expect(config.pinned, isEmpty);
      expect(config.toJson()['schemaVersion'], 1);
    });

    test('rejects malformed documents wholesale', () {
      expect(_decode('not json'), isNull);
      expect(_decode('[]'), isNull);
      expect(_decode(jsonEncode(_wrap(schemaVersion: 2))), isNull);
      expect(_decode(jsonEncode(_wrap(schemaVersion: '1'))), isNull);
      expect(_decode(jsonEncode(_wrap(options: <Object?>[]))), isNull);
      expect(_decode(jsonEncode(_wrap(options: null))), isNull);
      expect(_decode(jsonEncode(_wrap(options: <String, Object?>{'nope': 1}))), isNull);
      expect(
        _decode(jsonEncode(_wrap(pinned: <Object?>[null]))),
        isNull,
      );
    });

    test('rejects pinned longer than 128 (DockModel.js:45-47)', () {
      final pins = <Object?>[
        for (var i = 0; i < 129; i++) <String, Object?>{'kind': 'app', 'desktopId': 'app$i'},
      ];
      expect(_decode(jsonEncode(_wrap(pinned: pins))), isNull);
      final ok = <Object?>[
        for (var i = 0; i < 128; i++) <String, Object?>{'kind': 'app', 'desktopId': 'app$i'},
      ];
      expect(_decode(jsonEncode(_wrap(pinned: ok)))!.pinned, hasLength(128));
    });

    test('rejects invalid / duplicate pins', () {
      expect(
        _decode(jsonEncode(_wrap(pinned: <Object?>[
          <String, Object?>{'kind': 'app', 'desktopId': '  spaced '},
        ]))),
        isNull,
      );
      expect(
        _decode(jsonEncode(_wrap(pinned: <Object?>[
          <String, Object?>{'kind': 'app', 'desktopId': 'a/b'},
        ]))),
        isNull,
      );
      expect(
        _decode(jsonEncode(_wrap(pinned: <Object?>[
          <String, Object?>{'kind': 'spacer', 'id': 'bad id'},
        ]))),
        isNull,
      );
      expect(
        _decode(jsonEncode(_wrap(pinned: <Object?>[
          <String, Object?>{'kind': 'folder', 'url': 'https://example.com'},
        ]))),
        isNull,
      );
      // `file` kind is out of scope → treated as unknown.
      expect(
        _decode(jsonEncode(_wrap(pinned: <Object?>[
          <String, Object?>{'kind': 'file', 'url': 'file:///tmp/x'},
        ]))),
        isNull,
      );
      // duplicate pinnedKey
      expect(
        _decode(jsonEncode(_wrap(pinned: <Object?>[
          <String, Object?>{'kind': 'app', 'desktopId': 'org.a'},
          <String, Object?>{'kind': 'app', 'desktopId': 'org.a.desktop'},
        ]))),
        isNull,
      );
      // small-spacer and spacer share a key space (DockModel.js:100)
      expect(
        _decode(jsonEncode(_wrap(pinned: <Object?>[
          <String, Object?>{'kind': 'spacer', 'id': 's1'},
          <String, Object?>{'kind': 'small-spacer', 'id': 's1'},
        ]))),
        isNull,
      );
    });

    test('normalizes pins and groups folders last (DockModel.js:65-83,96)', () {
      final config = _decode(jsonEncode(_wrap(pinned: <Object?>[
        <String, Object?>{'kind': 'folder', 'url': 'file:///home/u/Docs'},
        <String, Object?>{'kind': 'app', 'desktopId': 'firefox.desktop'},
        <String, Object?>{'kind': 'separator', 'id': 'sep_1'},
        <String, Object?>{'kind': 'small-spacer', 'id': 'sm'},
      ])))!;
      expect(config.pinned, hasLength(4));
      expect(config.pinned[0], isA<DockAppPin>());
      expect((config.pinned[0] as DockAppPin).desktopId, 'firefox');
      expect(config.pinned[1], isA<DockSpacerPin>());
      expect((config.pinned[1] as DockSpacerPin).small, isFalse); // separator → spacer
      expect((config.pinned[2] as DockSpacerPin).small, isTrue);
      // folder is grouped to the end
      final folder = config.pinned.last as DockFolderPin;
      expect(folder.url, 'file:///home/u/Docs');
      expect(folder.view, 'fan');
      expect(folder.sort, 'name');
      expect(folder.display, 'folder');
    });

    test('folder view/sort/display validated with fallbacks', () {
      final config = _decode(jsonEncode(_wrap(pinned: <Object?>[
        <String, Object?>{
          'kind': 'folder',
          'url': 'file:///x',
          'view': 'list',
          'sort': 'bogus',
          'display': 'stack',
        },
      ])))!;
      final folder = config.pinned.single as DockFolderPin;
      expect(folder.view, 'list');
      expect(folder.sort, 'name'); // invalid → default
      expect(folder.display, 'stack');
    });
  });

  group('DockStore round-trip and atomic write', () {
    late Directory temp;

    setUp(() => temp = Directory.systemTemp.createTempSync('kos_dock_store'));
    tearDown(() {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });

    DockStore store(String name) => DockStore(path: '${temp.path}/$name.json');

    test('missing file reads defaults and is not created', () {
      final s = store('missing');
      expect(s.read().toJson(), DockConfig.defaults.toJson());
      expect(File(s.path).existsSync(), isFalse);
    });

    test('corrupt file reads defaults without rewriting it', () {
      final s = store('corrupt');
      File(s.path).writeAsStringSync('{ not json');
      expect(s.read().toJson(), DockConfig.defaults.toJson());
      expect(File(s.path).readAsStringSync(), '{ not json');
    });

    test('write → read round-trips pinned order and folder fields', () {
      final s = store('roundtrip');
      const config = DockConfig(
        options: DockOptions(iconSize: 64, position: DockPosition.left),
        pinned: <DockPin>[
          DockAppPin(desktopId: 'org.a'),
          DockSpacerPin(id: 'sp1', small: true),
          DockFolderPin(url: 'file:///d', view: 'grid', sort: 'size', display: 'stack'),
        ],
      );
      s.write(config);
      final read = s.read();
      expect(read.options.iconSize, 64);
      expect(read.options.position, DockPosition.left);
      expect(read.pinned.map((p) => p.pinnedKey), <String>[
        'app:org.a',
        'spacer:sp1',
        'file:file:///d',
      ]);
      final folder = read.pinned.last as DockFolderPin;
      expect(folder.view, 'grid');
      expect(folder.sort, 'size');
      expect(folder.display, 'stack');
    });

    test('write groups folder pins last (groupPins on save)', () {
      final s = store('grouped');
      s.write(
        const DockConfig(
          pinned: <DockPin>[
            DockFolderPin(url: 'file:///d'),
            DockAppPin(desktopId: 'org.a'),
          ],
        ),
      );
      final raw = jsonDecode(File(s.path).readAsStringSync()) as Map;
      final pinned = raw['pinned'] as List;
      expect((pinned.first as Map)['kind'], 'app');
      expect((pinned.last as Map)['kind'], 'folder');
      // write → read is order-stable regardless of the caller's input order.
      expect(s.read().pinned.map((p) => p.pinnedKey), <String>[
        'app:org.a',
        'file:file:///d',
      ]);
    });

    test('write preserves unknown top-level keys', () {
      final s = store('unknown');
      File(s.path).writeAsStringSync(
        jsonEncode(<String, Object?>{'futureKey': 42, 'notes': 'keep me'}),
      );
      s.write(DockConfig.defaults);
      final raw = jsonDecode(File(s.path).readAsStringSync()) as Map;
      expect(raw['futureKey'], 42);
      expect(raw['notes'], 'keep me');
      expect(raw['schemaVersion'], 1);
      expect(raw['options'], isA<Map>());
      expect(raw['pinned'], isEmpty);
    });

    test('atomic write leaves no tmp file and the file is valid JSON', () {
      final s = store('atomic');
      s.write(DockConfig.defaults);
      final leftovers = temp
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.tmp'))
          .toList();
      expect(leftovers, isEmpty);
      expect(decodeDockConfig(File(s.path).readAsStringSync()), isNotNull);
    });

    test('write creates missing parent directories', () {
      final s = DockStore(path: '${temp.path}/nested/deep/kos_dock.json');
      s.write(DockConfig.defaults);
      expect(File(s.path).existsSync(), isTrue);
    });

    test('defaultPath honors XDG_CONFIG_HOME then HOME', () {
      expect(
        DockStore.defaultPath(
          environment: <String, String>{'XDG_CONFIG_HOME': '/cfg'},
        ),
        '/cfg/denial/plugins/kos_dock.json',
      );
      expect(
        DockStore.defaultPath(environment: <String, String>{'HOME': '/home/u'}),
        '/home/u/.config/denial/plugins/kos_dock.json',
      );
      expect(
        () => DockStore.defaultPath(environment: const <String, String>{}),
        throwsA(isA<FileSystemException>()),
      );
    });
  });

  group('shared helpers', () {
    test('dockDesktopId strips a trailing .desktop and trims', () {
      expect(dockDesktopId(' firefox.desktop '), 'firefox');
      expect(dockDesktopId('org.gnome.Nautilus.desktop'), 'org.gnome.Nautilus');
      expect(dockDesktopId('firefox'), 'firefox');
      expect(dockDesktopId(null), '');
    });

    test('validDockDesktopId matches DockModel.js:25-28', () {
      expect(validDockDesktopId('firefox'), isTrue);
      expect(validDockDesktopId('firefox.desktop'), isTrue);
      expect(validDockDesktopId(' x'), isFalse);
      expect(validDockDesktopId('a/b'), isFalse);
      expect(validDockDesktopId('a\\b'), isFalse);
      expect(validDockDesktopId('a\u0000b'), isFalse);
      expect(validDockDesktopId('.desktop'), isFalse); // desktopId empty
      expect(validDockDesktopId(''), isFalse);
      expect(validDockDesktopId(5), isFalse);
    });

    test('validDockFileUrl matches DockModel.js:92-95', () {
      expect(validDockFileUrl('file:///home/u/x'), isTrue);
      expect(validDockFileUrl('file://host/x'), isFalse);
      expect(validDockFileUrl('file:///x?y'), isFalse);
      expect(validDockFileUrl('file:///x#y'), isFalse);
      expect(validDockFileUrl('/home/u/x'), isFalse);
    });
  });

  group('dockTrashCount (DockService.qml:237 approximation)', () {
    late Directory temp;
    setUp(() => temp = Directory.systemTemp.createTempSync('kos_dock_trash'));
    tearDown(() {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });

    test('counts entries and falls back to 0 when missing/unreadable', () {
      final files = Directory('${temp.path}/files')..createSync();
      expect(dockTrashCount(filesDirectory: files.path), 0);
      File('${files.path}/a').writeAsStringSync('a');
      File('${files.path}/b').writeAsStringSync('b');
      Directory('${files.path}/c').createSync();
      expect(dockTrashCount(filesDirectory: files.path), 3);
      expect(
        dockTrashCount(filesDirectory: '${temp.path}/does-not-exist'),
        0,
      );
      expect(dockTrashCount(filesDirectory: null), isNonNegative);
    });
  });
}
