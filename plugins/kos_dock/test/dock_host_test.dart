// Tests for the dock integration host (lib/src/widgets/dock_host.dart): the
// row composition (DockService.qml:158-248), pin toggling and the widget-level
// wiring of the launcher / preview / context-menu paths.

import 'dart:io';

import 'package:denial_flutter_sdk/services.dart';
import 'package:denial_flutter_sdk/theme.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:kos_dock/src/data/dock_store.dart';
import 'package:kos_dock/src/widgets/dock_host.dart';
import 'package:kos_dock/src/widgets/dock_item.dart';
import 'package:kos_dock/src/widgets/dock_surface_math.dart';

LaunchableApplication _app(
  String id,
  String appId,
  String name, {
  List<String> windowAppIds = const [],
}) => LaunchableApplication(
  id: id,
  appId: appId,
  name: name,
  windowAppIds: windowAppIds,
);

ApplicationWindow _window(
  int id,
  String appId, {
  bool active = false,
  String title = 'Window',
}) => ApplicationWindow(
  id: id,
  appId: appId,
  title: title,
  active: active,
  minimized: false,
);

final class _FakeServices implements ShellServices {
  _FakeServices({
    List<LaunchableApplication> apps = const [],
    List<ApplicationWindow> windows = const [],
  }) : _apps = Provider((ref) => apps),
       _windows = Provider((ref) => windows);

  final ProviderListenable<List<LaunchableApplication>> _apps;
  final ProviderListenable<List<ApplicationWindow>> _windows;
  int launcherCalls = 0;
  final activated = <int>[];
  final launched = <String>[];

  @override
  ProviderListenable<List<LaunchableApplication>> get applications => _apps;

  @override
  ProviderListenable<List<ApplicationWindow>> windows(int monitorId) => _windows;

  @override
  void toggleLauncher() => launcherCalls++;

  @override
  void activateWindow(int id) => activated.add(id);

  @override
  Future<bool> launchApplication(String id, {int? monitorId}) async {
    launched.add(id);
    return true;
  }

  @override
  Widget buildApplicationIcon(BuildContext context, String appId) =>
      ColoredBox(key: ValueKey('icon:$appId'), color: const Color(0xff445566));

  @override
  Widget buildWindowPreview(BuildContext context, int windowId) =>
      const ColoredBox(color: Color(0xff303030));

  @override
  VoidCallback emphasizeWindow(int windowId, {required int monitorId}) => () {};

  @override
  MouseCursor get normalCursor => SystemMouseCursors.basic;

  @override
  MouseCursor get linkCursor => SystemMouseCursors.click;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} not faked');
}

Future<void> _pumpHost(
  WidgetTester tester, {
  required _FakeServices services,
  DockStore? store,
  int trashCount = 0,
  bool showLauncher = true,
}) => tester.pumpWidget(
  ProviderScope(
    child: ShellTheme(
      data: const ShellThemeData(),
      child: MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: SizedBox(
              width: 800,
              // Surface strip thickness (DockHost defaults to the widget's
              // kDockItemDefaultIconSize); derived so a padding change flows
              // through instead of a stale hard-coded 78.
              height: dockSurfaceThickness(kDockItemDefaultIconSize),
              child: DockHost(
                services: services,
                monitorId: 0,
                store: store,
                trashCount: trashCount,
                showLauncher: showLauncher,
              ),
            ),
          ),
        ),
      ),
    ),
  ),
);

void main() {
  group('groupDockWindows', () {
    test('groups by desktopId, focused first then by id', () {
      final groups = groupDockWindows(<ApplicationWindow>[
        _window(3, 'firefox'),
        _window(1, 'org.other', active: true),
        _window(2, 'firefox.desktop', active: true),
        _window(7, ''),
      ]);
      expect(groups.keys, containsAll(<String>['app:firefox', 'app:org.other', 'window:7']));
      expect(groups['app:firefox']!.map((w) => w.id), <int>[2, 3]); // active 2 first
      expect(groups['app:org.other']!.single.id, 1);
      expect(groups['window:7']!.single.id, 7);
    });
  });

  group('findDockApplication', () {
    test('matches launch id, icon appId and window app-id mapping', () {
      final applications = <LaunchableApplication>[
        _app('org.mozilla.firefox', 'firefox', 'Firefox'),
        _app('code', 'code', 'Code', windowAppIds: const ['vscode']),
      ];
      expect(findDockApplication(applications, 'firefox')?.name, 'Firefox');
      expect(findDockApplication(applications, 'org.mozilla.firefox')?.name, 'Firefox');
      expect(findDockApplication(applications, 'vscode')?.name, 'Code');
      expect(findDockApplication(applications, 'missing'), isNull);
      expect(findDockApplication(applications, ''), isNull);
    });
  });

  group('buildDockEntries', () {
    const config = DockConfig(
      pinned: <DockPin>[
        DockAppPin(desktopId: 'firefox'),
        DockSpacerPin(id: 'sp1', small: true),
      ],
    );

    test('launcher → pinned → running → spacer → trash', () {
      final entries = buildDockEntries(
        config: config,
        applications: <LaunchableApplication>[
          _app('org.mozilla.firefox', 'firefox', 'Firefox'),
          _app('org.other', 'org.other', 'Other'),
        ],
        windows: <ApplicationWindow>[
          _window(5, 'org.other', active: true, title: 'Other window'),
        ],
        trashCount: 2,
      );
      expect(entries.map((e) => e.key), <String>[
        'launcher',
        'app:firefox',
        'spacer:sp1',
        'app:org.other',
        'trash',
      ]);
      // pinned app resolves name / icon / launch id from the catalog and has
      // no windows.
      final firefox = entries[1];
      expect(firefox.kind, 'app');
      expect(firefox.name, 'Firefox');
      expect(firefox.launchId, 'org.mozilla.firefox');
      expect(firefox.pinned, isTrue);
      expect(firefox.windowCount, 0);
      // running group is unpinned and carries its windows.
      final other = entries[3];
      expect(other.pinned, isFalse);
      expect(other.windowCount, 1);
      expect(other.windowId, 5);
      expect(other.focused, isTrue);
      expect(other.windows.single.title, 'Other window');
      // trash row uses the count-derived icon.
      expect(entries.last.kind, 'trash');
      expect(entries.last.appId, 'user-trash-full');
    });

    test('pinned app with running windows absorbs the group', () {
      final entries = buildDockEntries(
        config: config,
        applications: <LaunchableApplication>[
          _app('org.mozilla.firefox', 'firefox', 'Firefox'),
        ],
        windows: <ApplicationWindow>[
          _window(1, 'firefox', active: true),
          _window(2, 'firefox'),
        ],
        trashCount: 0,
      );
      // No duplicate running row for firefox.
      expect(entries.where((e) => e.key == 'app:firefox'), hasLength(1));
      final firefox = entries.firstWhere((e) => e.key == 'app:firefox');
      expect(firefox.pinned, isTrue);
      expect(firefox.windowCount, 2);
      expect(firefox.windows, hasLength(2));
    });

    test('showLauncher=false drops the leading launcher row', () {
      final entries = buildDockEntries(
        config: DockConfig.defaults,
        applications: const [],
        windows: const [],
        trashCount: 0,
        showLauncher: false,
      );
      expect(entries.map((e) => e.key), <String>['trash']);
    });

    test('dockPinnedRowCount counts launcher + leading pins', () {
      final entries = buildDockEntries(
        config: config,
        applications: <LaunchableApplication>[
          _app('org.mozilla.firefox', 'firefox', 'Firefox'),
        ],
        windows: <ApplicationWindow>[_window(9, 'org.other', active: true)],
        trashCount: 0,
      );
      expect(dockPinnedRowCount(entries), 3); // launcher + pin + spacer
    });
  });

  group('toggleDockPin', () {
    test('adds then removes app pins; non-app keys unchanged', () {
      const initial = DockConfig(pinned: <DockPin>[DockSpacerPin(id: 's')]);
      final added = toggleDockPin(initial, 'app:firefox');
      expect(added.pinned.map((p) => p.pinnedKey), <String>['spacer:s', 'app:firefox']);
      final removed = toggleDockPin(added, 'app:firefox');
      expect(removed.pinned.map((p) => p.pinnedKey), <String>['spacer:s']);
      expect(identical(toggleDockPin(initial, 'trash'), initial), isTrue);
      expect(identical(toggleDockPin(initial, 'spacer:s'), initial), isTrue);
    });
  });

  group('reorderDockPins', () {
    const config = DockConfig(
      pinned: <DockPin>[
        DockAppPin(desktopId: 'a'),
        DockSpacerPin(id: 's'),
        DockAppPin(desktopId: 'b'),
      ],
    );

    test('moves an earlier entry forward onto the target index', () {
      final next = reorderDockPins(config, 'app:a', 'app:b');
      expect(next.pinned.map((p) => p.pinnedKey), <String>[
        'spacer:s',
        'app:b',
        'app:a',
      ]);
    });

    test('moves a later entry backward onto the target index', () {
      final next = reorderDockPins(config, 'app:b', 'app:a');
      expect(next.pinned.map((p) => p.pinnedKey), <String>[
        'app:b',
        'app:a',
        'spacer:s',
      ]);
    });

    test('spacers participate like any other pin', () {
      final next = reorderDockPins(config, 'spacer:s', 'app:a');
      expect(next.pinned.map((p) => p.pinnedKey), <String>[
        'spacer:s',
        'app:a',
        'app:b',
      ]);
    });

    test('same / unknown / out-of-range keys return the identical config', () {
      expect(identical(reorderDockPins(config, 'app:a', 'app:a'), config), isTrue);
      expect(
        identical(reorderDockPins(config, 'app:zzz', 'app:a'), config),
        isTrue,
      );
      expect(
        identical(reorderDockPins(config, 'app:a', 'launcher'), config),
        isTrue,
      );
      expect(
        identical(
          reorderDockPins(DockConfig.defaults, 'app:a', 'app:b'),
          DockConfig.defaults,
        ),
        isTrue,
      );
    });
  });

  group('DockHost widget', () {
    late Directory temp;
    setUp(() => temp = Directory.systemTemp.createTempSync('kos_dock_host'));
    tearDown(() {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });

    _FakeServices services() => _FakeServices(
      apps: <LaunchableApplication>[
        _app('org.mozilla.firefox', 'firefox', 'Firefox'),
        _app('org.other', 'org.other', 'Other'),
      ],
      windows: <ApplicationWindow>[_window(5, 'org.other', active: true)],
    );

    testWidgets('renders launcher + pin + running + trash and tappable rows', (
      tester,
    ) async {
      final store = DockStore(path: '${temp.path}/kos_dock.json');
      store.write(
        const DockConfig(
          pinned: <DockPin>[DockAppPin(desktopId: 'firefox')],
        ),
      );
      final fake = services();
      await _pumpHost(tester, services: fake, store: store, trashCount: 0);
      await tester.pump();

      expect(find.byType(DockItem), findsNWidgets(4)); // launcher+pin+running+trash
      expect(find.byKey(const ValueKey('icon:firefox')), findsOneWidget);
      expect(find.byKey(const ValueKey('icon:org.other')), findsOneWidget);
      // Launcher and trash rows resolve bundled SVG glyphs (see
      // DockItem._artwork); the trash picks user-trash vs user-trash-full from
      // the resolved appId (dockTrashIconName).
      final launcher = find.byWidgetPredicate(
        (w) =>
            w is SvgPicture &&
            (w.bytesLoader as SvgAssetLoader).assetName ==
                'assets/icons/launcher.svg',
      );
      final trash = find.byWidgetPredicate(
        (w) =>
            w is SvgPicture &&
            (w.bytesLoader as SvgAssetLoader).assetName ==
                'assets/icons/trash.svg',
      );
      expect(launcher, findsOneWidget);
      expect(trash, findsOneWidget);
      // Bundled SVGs must match the row's icon size (the 64px viewBox made the
      // launcher/trash look oversized next to app icons).
      expect(
        tester.widget<SvgPicture>(launcher).width,
        kDockItemDefaultIconSize,
      );
      expect(
        tester.widget<SvgPicture>(trash).width,
        kDockItemDefaultIconSize,
      );

      // Launcher row opens the Denial launcher.
      await tester.tap(
        find.ancestor(of: launcher, matching: find.byType(DockItem)),
      );
      await tester.pump();
      expect(fake.launcherCalls, 1);
    });

    testWidgets('right click opens the TASK-05 menu for the entry', (
      tester,
    ) async {
      final store = DockStore(path: '${temp.path}/kos_dock.json');
      store.write(
        const DockConfig(pinned: <DockPin>[DockAppPin(desktopId: 'firefox')]),
      );
      final fake = _FakeServices(
        apps: <LaunchableApplication>[
          _app('org.mozilla.firefox', 'firefox', 'Firefox'),
        ],
      );
      await _pumpHost(tester, services: fake, store: store, trashCount: 0);
      await tester.pump();

      await tester.tap(
        find.ancestor(
          of: find.byKey(const ValueKey('icon:firefox')),
          matching: find.byType(DockItem),
        ),
        buttons: kSecondaryButton,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      // windows == 0 → the menu title row shows the entry name (:208-220).
      expect(find.text('Firefox'), findsOneWidget);
    });

    testWidgets('dragging a pinned icon onto another reorders and persists', (
      tester,
    ) async {
      final store = DockStore(path: '${temp.path}/kos_dock.json');
      store.write(
        const DockConfig(
          pinned: <DockPin>[
            DockAppPin(desktopId: 'firefox'),
            DockAppPin(desktopId: 'other'),
          ],
        ),
      );
      final fake = _FakeServices(
        apps: <LaunchableApplication>[
          _app('org.mozilla.firefox', 'firefox', 'Firefox'),
          _app('other', 'other', 'Other'),
        ],
      );
      await _pumpHost(tester, services: fake, store: store, trashCount: 0);
      await tester.pump();

      // Index 0 is the launcher row; pins sit at 1 (firefox) and 2 (other).
      final firefoxRow = find.ancestor(
        of: find.byKey(const ValueKey('icon:firefox')),
        matching: find.byType(DockItem),
      );
      final otherRow = find.ancestor(
        of: find.byKey(const ValueKey('icon:other')),
        matching: find.byType(DockItem),
      );
      // Drop onto the other row's left half so the landing key is `other`.
      final gesture = await tester.startGesture(tester.getCenter(firefoxRow));
      await gesture.moveTo(tester.getCenter(otherRow) - const Offset(10, 0));
      await tester.pump();
      await gesture.up();
      await tester.pump();

      expect(store.read().pinned.map((p) => p.pinnedKey), <String>[
        'app:other',
        'app:firefox',
      ]);
      // The rendered row order follows the persisted config.
      final order = tester
          .widgetList<DockItem>(find.byType(DockItem))
          .map((item) => item.entryKey)
          .toList();
      expect(order, <String>['launcher', 'app:other', 'app:firefox', 'trash']);
    });
  });
}
