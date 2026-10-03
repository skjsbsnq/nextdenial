// TASK-16 music 面板 widget 测试。
//
// 覆盖：
// - 注册函数写入 `deskPanelBuilderRegistry`（`kos-music`，路由收口契约）；
// - 无播放器空态：「暂无播放内容」+ ♫ 占位 + 控制钮禁用（点击不触发）；
// - 有播放器渲染标题/艺人/专辑/进度 m:ss 双端时间、⏸/▶ 状态图标；
// - 点击 previous/playPause/next 触发注入的 `MediaCommands` 对应方法；
// - `data.media` 当帧快照回退（无 media provider/scope 时）；
// - 播放中 250ms 位置钟驱动进度刷新（注入 `clock` 推进 now；
//   `positionAt` 走真实时钟，fake-async 下不注入时钟则进度不变）；
// - `coverBytes` 注入渲染封面。
//
// fake-async 铁律：播放中面板持有 `Timer.periodic`——用例体末尾统一
import 'package:denial_flutter_sdk/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;
import 'package:flutter_test/flutter_test.dart';
import 'package:denial_sdk/system.dart';
import 'package:flutter/foundation.dart' show Uint8List;
import 'package:flutter/material.dart'
    show Color, MaterialApp, Scaffold;
import 'package:flutter/widgets.dart';
import 'package:kos_deskcenter/src/widgets/desk_panel_shell.dart';
import 'package:kos_deskcenter/src/widgets/music_panel.dart';

/// 非空封面字节（内容不解析——`Image.memory` 解码失败仍渲染 widget，
/// 本断言只查 widget 树存在性；实际用 1×1 PNG 避免抛解码错误）。
final Uint8List _coverBytes = Uint8List.fromList(const <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, // PNG magic
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, // IHDR
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
  0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41, // IDAT
  0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
  0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, // IEND
  0x42, 0x60, 0x82,
]);

/// 测试时钟（可变 now，模拟播放推进）。
final class _FakeClock {
  _FakeClock(this.now);
  DateTime now;
  DateTime call() => now;
}

MprisPlaybackState _track({
  bool playing = true,
  DateTime? observedAt,
  Duration length = const Duration(minutes: 3, seconds: 30),
  Duration position = const Duration(minutes: 1),
  String artUrl = '',
}) => MprisPlaybackState(
  serviceName: 'org.mpris.MediaPlayer2.test',
  identity: 'TestPlayer',
  title: '歌名',
  artists: const ['艺人甲', '艺人乙'],
  album: '专辑',
  artUrl: artUrl,
  length: length,
  position: position,
  observedAt: observedAt ?? DateTime.now(),
  status: playing ? MprisPlaybackStatus.playing : MprisPlaybackStatus.paused,
  canGoNext: true,
  canGoPrevious: true,
  canPlay: true,
  canPause: true,
);

class _FakeMediaCommands implements MediaCommands {
  final calls = <String>[];
  @override
  MprisPlaybackState get current => MprisPlaybackState.unavailable();
  @override
  Future<void> previous() async => calls.add('previous');
  @override
  Future<void> playPause() async => calls.add('playPause');
  @override
  Future<void> next() async => calls.add('next');
}

Widget _wrap(Widget child) => ProviderScope(
  child: MaterialApp(
    debugShowCheckedModeBanner: false,
    home: Scaffold(
      backgroundColor: const Color(0x00000000),
      body: Center(
        child: SizedBox(width: 1000, height: 800, child: child),
      ),
    ),
  ),
);

MusicPanel _panel({
  MprisPlaybackState? media,
  ProviderListenable<AsyncValue<MprisPlaybackState>>? mediaProvider,
  MediaCommands? commands,
  Uint8List? coverBytes,
  DateTime Function()? clock,
}) => MusicPanel(
  request: const DeskPanelRequest(appId: 'kos-music'),
  data: DeskPanelData(media: media),
  media: mediaProvider,
  mediaCommands: commands == null
      ? null
      : Provider<MediaCommands>((_) => commands),
  coverBytes: coverBytes,
  clock: clock,
);

Future<void> _pump(WidgetTester tester, Widget child) async {
  await tester.binding.setSurfaceSize(const Size(1000, 800));
  await tester.pumpWidget(_wrap(child));
  await tester.pump();
}

void main() {
  testWidgets('注册函数写入 deskPanelBuilderRegistry', (tester) async {
    registerMusicPanel();
    expect(deskPanelBuilderRegistry['kos-music'], isNotNull);
    final widget = deskPanelBuilderRegistry['kos-music']!(
      const DeskPanelRequest(appId: 'kos-music'),
      const DeskPanelData(),
    );
    expect(widget, isA<MusicPanel>());
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('无播放器空态：暂无播放内容 + ♫ 占位，控制钮禁用', (tester) async {
    final commands = _FakeMediaCommands();
    await _pump(
      tester,
      _panel(
        mediaProvider: Provider<AsyncValue<MprisPlaybackState>>(
          (_) => AsyncData(MprisPlaybackState.unavailable()),
        ),
        commands: commands,
      ),
    );
    expect(find.text('暂无播放内容'), findsOneWidget);
    expect(find.text('♫'), findsOneWidget);
    // 禁用钮点击不触发命令（enabled=false 时 GestureDetector 无回调）。
    await tester.tap(find.byKey(const ValueKey('music-panel-toggle')));
    await tester.tap(find.byKey(const ValueKey('music-panel-prev')));
    await tester.tap(find.byKey(const ValueKey('music-panel-next')));
    expect(commands.calls, isEmpty);
    // 禁用透明度 0.32。
    expect(
      find.byWidgetPredicate(
        (w) => w is Opacity && w.opacity == 0.32,
      ),
      findsNWidgets(3),
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('播放中渲染标题/艺人/专辑/进度 m:ss + 暂停图标', (tester) async {
    final base = DateTime(2026, 10, 2, 12);
    final clock = _FakeClock(base);
    final state = _track(playing: true, observedAt: base);
    await _pump(
      tester,
      _panel(
        mediaProvider: Provider<AsyncValue<MprisPlaybackState>>(
          (_) => AsyncData(state),
        ),
        commands: _FakeMediaCommands(),
        clock: clock.call,
      ),
    );
    expect(find.text('歌名'), findsOneWidget);
    expect(find.text('艺人甲, 艺人乙'), findsOneWidget);
    expect(find.text('专辑'), findsOneWidget);
    expect(find.text('1:00'), findsOneWidget); // position 1min
    expect(find.text('3:30'), findsOneWidget); // length 3:30
    expect(find.text('⏸'), findsOneWidget); // 播放中 → 暂停
    expect(find.text('TestPlayer'), findsOneWidget); // identity 页脚
    await tester.pumpWidget(const SizedBox()); // 停 250ms 位置钟
  });

  testWidgets('控制钮点击触发 MediaCommands previous/playPause/next', (tester) async {
    final commands = _FakeMediaCommands();
    final base = DateTime(2026, 10, 2, 12);
    await _pump(
      tester,
      _panel(
        mediaProvider: Provider<AsyncValue<MprisPlaybackState>>(
          (_) => AsyncData(_track(playing: true, observedAt: base)),
        ),
        commands: commands,
        clock: () => base,
      ),
    );
    await tester.tap(find.byKey(const ValueKey('music-panel-prev')));
    await tester.tap(find.byKey(const ValueKey('music-panel-toggle')));
    await tester.tap(find.byKey(const ValueKey('music-panel-next')));
    expect(commands.calls, ['previous', 'playPause', 'next']);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('暂停态显示 ▶ 且进度文本为快照值', (tester) async {
    final base = DateTime(2026, 10, 2, 12);
    await _pump(
      tester,
      _panel(
        mediaProvider: Provider<AsyncValue<MprisPlaybackState>>(
          (_) => AsyncData(_track(playing: false, observedAt: base)),
        ),
        commands: _FakeMediaCommands(),
        clock: () => base,
      ),
    );
    expect(find.text('▶'), findsOneWidget);
    expect(find.text('1:00'), findsOneWidget);
    // 暂停不启位置钟：推进真实 pump 后文本不变。
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('1:00'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('播放中位置钟驱动进度刷新（注入 clock 推进 now）', (tester) async {
    final base = DateTime(2026, 10, 2, 12);
    final clock = _FakeClock(base);
    await _pump(
      tester,
      _panel(
        mediaProvider: Provider<AsyncValue<MprisPlaybackState>>(
          (_) => AsyncData(_track(playing: true, observedAt: base)),
        ),
        commands: _FakeMediaCommands(),
        clock: clock.call,
      ),
    );
    expect(find.text('1:00'), findsOneWidget);
    // now +40s，越过 250ms tick → 位置文本推进到 1:40。
    clock.now = base.add(const Duration(seconds: 40));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('1:40'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('无 media provider/scope 时回退 data.media 当帧快照', (tester) async {
    await _pump(tester, _panel(media: _track(playing: false)));
    expect(find.text('歌名'), findsOneWidget);
    expect(find.text('1:00'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('coverBytes 注入渲染封面 Image', (tester) async {
    final base = DateTime(2026, 10, 2, 12);
    await _pump(
      tester,
      _panel(
        mediaProvider: Provider<AsyncValue<MprisPlaybackState>>(
          (_) => AsyncData(_track(playing: false, observedAt: base)),
        ),
        coverBytes: _coverBytes,
        clock: () => base,
      ),
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('music-panel-cover')),
        matching: find.byType(Image),
      ),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox());
  });
}
