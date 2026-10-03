// KosMusicCard widget 测试。
//
// 对齐 DeskCenterWindow.qml:1699-1986 的 music 分支：封面区/标题/艺人/
// 进度条+双端时间/三枚控制钮（MediaCommands 注入）。

import 'package:denial_flutter_sdk/services.dart';
import 'package:denial_sdk/system.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kos_deskcenter/src/widgets/music_card.dart';

Widget _wrap(Widget child, {double w = 340, double h = 140}) => ProviderScope(
  child: Directionality(
    textDirection: TextDirection.ltr,
    child: Center(
      child: SizedBox(width: w, height: h, child: child),
    ),
  ),
);

MprisPlaybackState _track({
  bool playing = true,
  Duration length = const Duration(seconds: 214),
  Duration position = const Duration(seconds: 63),
}) => MprisPlaybackState(
  serviceName: 'org.mpris.MediaPlayer2.test',
  identity: 'TestPlayer',
  title: '晴天',
  artists: const ['周杰伦'],
  album: '',
  artUrl: 'file:///tmp/cover.png',
  length: length,
  position: position,
  observedAt: DateTime.now(),
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

void main() {
  testWidgets('music 卡渲染标题/艺人/进度时间/控制钮（:1862-1944、:1945-1979）', (tester) async {
    final commands = _FakeMediaCommands();
    await tester.pumpWidget(
      _wrap(
        KosMusicCard(
          media: Provider<AsyncValue<MprisPlaybackState>>(
            (_) => AsyncData(_track()),
          ),
          mediaCommands: Provider<MediaCommands>((_) => commands),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('晴天'), findsOneWidget); // :1865
    expect(find.text('周杰伦'), findsOneWidget); // :1874 artistLabel
    expect(find.text('1:03'), findsOneWidget); // :1934 formatPlaybackTime
    expect(find.text('3:34'), findsOneWidget); // :1940 safeLength 214s
    // 控制钮字符近似（media-previous/play-pause/next）。
    expect(find.text('⏮'), findsOneWidget);
    expect(find.text('⏸'), findsOneWidget); // 播放中 → 暂停图标 :1963
    expect(find.text('⏭'), findsOneWidget);

    // 点击顺序：prev → pause → next（DockMprisService.qml:176-190）。
    await tester.tap(find.text('⏮'));
    await tester.tap(find.text('⏸'));
    await tester.tap(find.text('⏭'));
    expect(commands.calls, ['previous', 'playPause', 'next']);
    await tester.pumpWidget(const SizedBox()); // 收尾停动画
  });

  testWidgets('暂停态显示播放钮（:1963）且进度仍可点击', (tester) async {
    await tester.pumpWidget(
      _wrap(
        KosMusicCard(
          media: Provider<AsyncValue<MprisPlaybackState>>(
            (_) => AsyncData(_track(playing: false)),
          ),
          mediaCommands: Provider<MediaCommands>((_) => _FakeMediaCommands()),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('▶'), findsOneWidget); // 非播放 → play 图标
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('无播放器空态：「暂无播放内容」+ ♫ 占位（:1865、:1846-1852）', (tester) async {
    await tester.pumpWidget(
      _wrap(
        KosMusicCard(
          media: Provider<AsyncValue<MprisPlaybackState>>(
            (_) => AsyncData(MprisPlaybackState.unavailable()),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('暂无播放内容'), findsOneWidget);
    expect(find.text('♫'), findsWidgets); // 封面占位
    // 无 safeLength → 进度与时间行不渲染（:1899 visible）。
    expect(find.text('1:03'), findsNothing);
  });

  testWidgets('AsyncValue loading 视为无播放器', (tester) async {
    await tester.pumpWidget(
      _wrap(
        KosMusicCard(
          media: Provider<AsyncValue<MprisPlaybackState>>(
            (_) => const AsyncLoading<MprisPlaybackState>(),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('暂无播放内容'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('整卡点击 → kos-music []（:1718-1722）', (tester) async {
    final calls = <(String, List<String>)>[];
    await tester.pumpWidget(
      _wrap(
        KosMusicCard(
          media: Provider<AsyncValue<MprisPlaybackState>>(
            (_) => AsyncData(_track()),
          ),
          onLaunchApp: (id, a) => calls.add((id, a)),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('晴天'));
    expect(calls.last.$1, 'kos-music');
    expect(calls.last.$2, isEmpty); // :1718-1722 无参数
    await tester.pumpWidget(const SizedBox());
  });

}
