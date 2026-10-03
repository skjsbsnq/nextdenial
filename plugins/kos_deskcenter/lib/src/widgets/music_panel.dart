/// KOS DeskCenter 音乐「正在播放」面板（TASK-16）：`kos-music` 的 DenialUI
/// 重写，填入 TASK-12 的 `DeskPanelShell` 内容区。
///
/// 源端对照（`apps/music/qml/` `MiniPlayer.qml`/`NowPlayingPage.qml`）：大封面、
/// 曲名/艺人/专辑、进度条 + `m:ss` 双端时间、previous/playPause/next 三枚
/// 圆钮。本期只做 MPRIS 消费端的正在播放面板，不移植 kos-music 播放器本体
/// （本地库/在线源/歌词/转码均后置，见任务卡 §范围）。
///
/// 数据与控制（与 `music_card.dart` 同一套）：
/// - `services.media`（`ProviderListenable<AsyncValue<MprisPlaybackState>>`）
///   实时刷新；无 scope/provider 时回退 `DeskPanelData.media` 当帧快照；
/// - `services.mediaCommands`（previous/playPause/next）——`MediaCommands`
///   无 seek/volume 通道：进度条退化为**只读**（不可拖拽 seek，记 deltas），
///   音量控件本期跳过；歌词仅 KOS 播放器 `kos:*` 扩展键提供，
///   `MprisPlaybackState` 未暴露 → 跳过；多播放器：SDK 只暴露活跃播放器，
///   故无播放器选择行（仅页脚显示 `identity`）。
/// - 封面：`services.imageBytes(path)`；`artUrl` 为 `file:` URI 或裸路径时
///   提取路径，http(s) 无通道 → 占位符（同 music_card `_scopeImageBytes`）。
///
/// DenialUI：全前景/材质走 `context.shellTheme`/`context.shellColors` +
/// `ShellText`（无 `Theme.of`、无硬编码前景）；色板复用 music_card 的
/// `KosMusicCardColors.forShell`；控制钮主钮 `accentPalette.container` +
/// `onContainer`、其余 `accentPalette.subtle` + `textPrimary`，禁用 0.32；
/// 进度条 `accent` 填充 / `hairlineSoft` 轨。播放中以 `Timer.periodic
/// (250ms)` 驱动 `positionAt(now)` 重算（暂停/无播放停表，dispose 取消）。
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:denial_flutter_sdk/services.dart';
import 'package:denial_flutter_sdk/shell_theme.dart'
    show ShellThemeBuildContext;
import 'package:denial_flutter_sdk/tokens.dart' show ShellText;
import 'package:denial_sdk/system.dart' show MprisPlaybackState;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;

import 'desk_panel_shell.dart';
import 'music_card.dart' show KosMusicCardColors;

/// `DeskPanelBuilder` 形态的音乐面板入口。
Widget buildMusicPanel(DeskPanelRequest request, DeskPanelData data) =>
    MusicPanel(request: request, data: data);

/// 注册 `kos-music` 的面板内容构造器（装配层 `desk_panels.dart` 统一调用
/// 一次，幂等；本文件不自调注册）。
void registerMusicPanel() {
  registerDeskPanelBuilder('kos-music', buildMusicPanel);
}

/// 正在播放面板：封面 + 曲目信息 + 只读进度条 + previous/playPause/next。
class MusicPanel extends ConsumerStatefulWidget {
  const MusicPanel({
    required this.request,
    required this.data,
    this.media,
    this.mediaCommands,
    this.coverProviderFor,
    this.coverBytes,
    this.clock,
    super.key,
  });

  /// 卡片弹出请求（music 无参，`request.argv` 当前不消费）。
  final DeskPanelRequest request;

  /// 当帧数据快照（`media` 为打开瞬间的 `MprisPlaybackState`，弱类型
  /// `Object?`——无实时 provider 时回退消费）。
  final DeskPanelData data;

  /// 播放状态：`ProviderListenable<AsyncValue<MprisPlaybackState>>`；null 时
  /// 经 `ShellServicesScope` 取 `services.media`。`AsyncValue` 无值回退
  /// [data] 的 `media` 快照。
  final ProviderListenable<AsyncValue<MprisPlaybackState>>? media;

  /// 播放控制：`ProviderListenable<MediaCommands>`；null 时取
  /// `services.mediaCommands`。无 seek 接口（见文件头 deltas）。
  final ProviderListenable<MediaCommands>? mediaCommands;

  /// 封面字节 provider 工厂：`artUrl`（字符串路径）→
  /// `ProviderListenable<AsyncValue<Uint8List?>>`。null 时经 scope 取
  /// `services.imageBytes(path)`。本参数供测试注入固定字节。
  final ProviderListenable<AsyncValue<Uint8List?>> Function(String path)?
  coverProviderFor;

  /// 直接注入的封面字节（优先于 provider 链路）。
  final Uint8List? coverBytes;

  /// 时钟注入（默认 `DateTime.now`）：`positionAt(now)` 的 now。测试用其
  /// 在 fake-async 下推进播放位置——`positionAt` 内部走真实时钟，不注入则
  /// `tester.pump` 推进的虚拟时间对进度无影响。
  final DateTime Function()? clock;

  @override
  ConsumerState<MusicPanel> createState() => _MusicPanelState();
}

class _MusicPanelState extends ConsumerState<MusicPanel> {
  /// 播放中的 250ms 位置重算钟（暂停/无播放为 null）。
  Timer? _ticker;

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  // formatPlaybackTime 同款：floor 后 m:ss（DeskCenterWindow.qml:1727-1730）。
  static String _formatTime(Duration d) {
    final value = math.max(0, d.inMilliseconds) ~/ 1000;
    return '${value ~/ 60}:${(value % 60).toString().padLeft(2, '0')}';
  }

  /// 播放中启动位置钟，暂停/无播放停表（dispose 兜底取消）。
  void _syncTicker(bool playing) {
    if (playing && _ticker == null) {
      _ticker = Timer.periodic(const Duration(milliseconds: 250), (_) {
        if (mounted) setState(() {});
      });
    } else if (!playing && _ticker != null) {
      _ticker!.cancel();
      _ticker = null;
    }
  }

  /// scope.presentation.imageBytes 适配：`file:` URI / 裸路径提取路径，
  /// http(s)/其它 scheme 返回 null（无 SDK 通道，记 deltas；同 music_card）。
  ProviderListenable<AsyncValue<Uint8List?>>? _scopeImageBytes(
    ShellServicesScope? scope,
    String artUrl,
  ) {
    if (scope == null) return null;
    final uri = Uri.tryParse(artUrl);
    final path = switch (uri?.scheme) {
      'file' => uri!.toFilePath(),
      '' || null => artUrl,
      _ => null,
    };
    return path == null ? null : scope.services.imageBytes(path);
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.shellTheme;
    final colors = context.shellColors;
    final palette = KosMusicCardColors.forShell(theme);
    final scope = context
        .dependOnInheritedWidgetOfExactType<ShellServicesScope>();

    // media：注入/scope provider 实时值 → 无值回退当帧快照（弱类型 Object?）。
    final mediaListenable = widget.media ?? scope?.services.media;
    final media =
        (mediaListenable != null ? ref.watch(mediaListenable).value : null) ??
        widget.data.media as MprisPlaybackState?;
    final commandsListenable =
        widget.mediaCommands ?? scope?.services.mediaCommands;
    final commands = commandsListenable != null
        ? ref.watch(commandsListenable)
        : null;

    final hasPlayer = media?.available ?? false;
    final playing = media?.playing ?? false;
    _syncTicker(playing);

    final now = (widget.clock ?? DateTime.now)();
    final safeLength = media != null && media.length > Duration.zero
        ? media.length
        : null;
    final position = media?.positionAt(now) ?? Duration.zero;
    final progress = safeLength != null
        ? (position.inMicroseconds / safeLength.inMicroseconds).clamp(0.0, 1.0)
        : 0.0;

    // 封面字节：构造注入 > provider 工厂 > scope imageBytes。
    Uint8List? cover = widget.coverBytes;
    if (cover == null && media != null && media.artUrl.isNotEmpty) {
      final provider =
          widget.coverProviderFor?.call(media.artUrl) ??
          _scopeImageBytes(scope, media.artUrl);
      if (provider != null) cover = ref.watch(provider).value;
    }

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 440),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 大封面（NowPlayingPage 主体）：正方形居中，圆角 tileRadius，
          // 无图/无播放器显 ♫ 占位。
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 240, maxHeight: 240),
              child: AspectRatio(
                aspectRatio: 1,
                child: _PanelCover(
                  key: const ValueKey('music-panel-cover'),
                  bytes: cover,
                  hasPlayer: hasPlayer,
                  radius: theme.tileRadius,
                  palette: palette,
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            hasPlayer && (media?.title.isNotEmpty ?? false)
                ? media!.title
                : '暂无播放内容',
            key: const ValueKey('music-panel-title'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: ShellText.base.copyWith(
              color: colors.textPrimary,
              fontSize: 16,
              fontWeight: FontWeight.w600,
              height: 1.25,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            hasPlayer ? (media?.artistLabel ?? '') : '',
            key: const ValueKey('music-panel-artist'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: ShellText.base.copyWith(
              color: colors.textSecondary,
              fontSize: 12,
              height: 1.3,
            ),
          ),
          if (hasPlayer && (media?.album.isNotEmpty ?? false))
            Text(
              media!.album,
              key: const ValueKey('music-panel-album'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: ShellText.base.copyWith(
                color: colors.textTertiary,
                fontSize: 11,
                height: 1.35,
              ),
            ),
          if (safeLength != null) ...[
            const SizedBox(height: 14),
            // 只读进度条：`MediaCommands` 无 seek 通道（deltas）——渲染
            // `positionAt(now)` 的实时位置，不挂拖拽手势。
            SizedBox(
              height: 5,
              child: _PanelProgress(
                key: const ValueKey('music-panel-progress'),
                progress: progress,
                track: colors.hairlineSoft,
                fill: theme.accent,
              ),
            ),
            const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  _formatTime(position),
                  key: const ValueKey('music-panel-position'),
                  style: ShellText.base.copyWith(
                    color: colors.textSecondary,
                    fontSize: 10.5,
                    height: 1.2,
                  ),
                ),
                Text(
                  _formatTime(safeLength),
                  key: const ValueKey('music-panel-length'),
                  style: ShellText.base.copyWith(
                    color: colors.textSecondary,
                    fontSize: 10.5,
                    height: 1.2,
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 12),
          // 控制行：previous / playPause / next，按 canGo*/canPlay||canPause
          // 逐项 enabled；无播放器整体禁用。
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _PanelMediaButton(
                key: const ValueKey('music-panel-prev'),
                primary: false,
                glyph: '⏮',
                enabled: hasPlayer && (media?.canGoPrevious ?? false),
                ink: palette.controlInk,
                fill: palette.controlFill,
                onTap: () => unawaited(commands?.previous()),
              ),
              const SizedBox(width: 14),
              _PanelMediaButton(
                key: const ValueKey('music-panel-toggle'),
                primary: true,
                glyph: playing ? '⏸' : '▶',
                enabled:
                    hasPlayer &&
                    ((media?.canPlay ?? false) || (media?.canPause ?? false)),
                ink: palette.controlInkPrimary,
                fill: palette.controlFillPrimary,
                onTap: () => unawaited(commands?.playPause()),
              ),
              const SizedBox(width: 14),
              _PanelMediaButton(
                key: const ValueKey('music-panel-next'),
                primary: false,
                glyph: '⏭',
                enabled: hasPlayer && (media?.canGoNext ?? false),
                ink: palette.controlInk,
                fill: palette.controlFill,
                onTap: () => unawaited(commands?.next()),
              ),
            ],
          ),
          // 播放器身份页脚（SDK 只暴露活跃播放器，无选择行）。
          if (hasPlayer && (media?.identity.isNotEmpty ?? false)) ...[
            const SizedBox(height: 10),
            Text(
              media!.identity,
              key: const ValueKey('music-panel-identity'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: ShellText.base.copyWith(
                color: colors.textTertiary,
                fontSize: 10.5,
                height: 1.3,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 大封面块：`tileRadius` 圆角、`coverBase` 底色、PreserveAspectCrop；
/// 无播放器/无字节显 ♫ 占位（`placeholderNote`）。
class _PanelCover extends StatelessWidget {
  const _PanelCover({
    super.key,
    required this.bytes,
    required this.hasPlayer,
    required this.radius,
    required this.palette,
  });

  final Uint8List? bytes;
  final bool hasPlayer;
  final double radius;
  final KosMusicCardColors palette;

  @override
  Widget build(BuildContext context) {
    final borderRadius = BorderRadius.circular(radius);
    return Container(
      decoration: BoxDecoration(
        color: palette.coverBase,
        borderRadius: borderRadius,
      ),
      clipBehavior: Clip.antiAlias,
      child: hasPlayer && bytes != null
          ? Image.memory(
              bytes!,
              fit: BoxFit.cover,
              gaplessPlayback: true,
            )
          : LayoutBuilder(
              builder: (context, constraints) => Center(
                child: Text(
                  '♫',
                  style: TextStyle(
                    color: palette.placeholderNote,
                    fontSize:
                        math.min(
                          constraints.maxWidth,
                          constraints.maxHeight,
                        ) *
                        0.42,
                    height: 1,
                  ),
                ),
              ),
            ),
    );
  }
}

/// 平坦进度条：track 全宽 + fill 按 progress 截断（accent/hairlineSoft）。
class _PanelProgress extends StatelessWidget {
  const _PanelProgress({
    super.key,
    required this.progress,
    required this.track,
    required this.fill,
  });

  final double progress;
  final Color track;
  final Color fill;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return Stack(
          children: [
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(2.5),
                  color: track,
                ),
              ),
            ),
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              width: constraints.maxWidth * progress,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(2.5),
                  color: fill,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// 面板控制钮：主钮 56px 圆盘（accent 容器）、其余 44px；禁用 0.32，
/// 按下缩 0.94（music_card `_MediaButton` 的等价大按钮版）。
class _PanelMediaButton extends StatefulWidget {
  const _PanelMediaButton({
    super.key,
    required this.primary,
    required this.glyph,
    required this.enabled,
    required this.ink,
    required this.fill,
    this.onTap,
  });

  final bool primary;
  final String glyph;
  final bool enabled;
  final Color ink;
  final Color fill;
  final VoidCallback? onTap;

  @override
  State<_PanelMediaButton> createState() => _PanelMediaButtonState();
}

class _PanelMediaButtonState extends State<_PanelMediaButton> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final disc = widget.primary ? 56.0 : 44.0;
    final iconSize = widget.primary ? 24.0 : 18.0;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: widget.enabled ? (_) => setState(() => _down = true) : null,
      onTapUp: widget.enabled
          ? (_) {
              setState(() => _down = false);
              widget.onTap?.call();
            }
          : null,
      onTapCancel: widget.enabled ? () => setState(() => _down = false) : null,
      child: Opacity(
        opacity: widget.enabled ? 1 : 0.32, // MediaControlButton.qml:27
        child: SizedBox(
          width: disc + 8,
          height: disc + 8,
          child: Center(
            child: AnimatedScale(
              scale: _down ? 0.94 : 1,
              duration: const Duration(milliseconds: 100),
              curve: Curves.easeOutCubic,
              child: Container(
                width: disc,
                height: disc,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: widget.fill,
                ),
                alignment: Alignment.center,
                child: Text(
                  widget.glyph,
                  style: TextStyle(
                    color: widget.ink,
                    fontSize: iconSize,
                    height: 1,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
