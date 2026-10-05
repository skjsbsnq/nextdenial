/// KOS Dock 信息卡——音乐页（TASK-05）。
///
/// 移植 NextKde `shell/desktop/modules/dock/DockMusicPlayer.qml`（行号在各段
/// 标注）：
/// - full（iconSize≥36）：封面（artSize=`min(iconSize, dockHeight-vPadding*2)`
///   vPadding=`round(iconSize*0.25)`，:29-30）+ 标题/歌手 marquee（:224-290，
///   仅 hover+溢出时滚动）+ prev/play/next 三圆钮（:293-309，prev/next 24px、
///   play 27px 起，:392-400）；
/// - compact（iconSize<36，:31）：封面叠播停 overlay + 单行滚动 metadata
///   （:317-381）。
///
/// 数据注入（无 Provider 依赖、便于测试）：[state] = `MprisPlaybackState`，
/// [artwork] = 封面解码字节（carousel 经 `services.imageBytes(artUrl)`
/// 取本地路径；http(s)/空 → null 占位 glyph，记 deltas——KOS 直接 Image
/// url 可抓 http，本端不抓）、[onPrevious]/[onPlayPause]/[onNext] 接
/// `services.mediaCommands`。
///
/// 偏差（记 docs/visual-deltas.md）：
/// - 卡背 artworkPalette 渐变（:129-153，ArtworkColorSource）→
///   `panelGradient(panelBackground, panelBackgroundBottom)`；
/// - marquee 只复刻「overflow + hover 才滚动」语义：full 模式 hover 时
///   横向滚动、放手回弹；compact 模式 pageActive 恒滚（:356-379；pageActive
///   由 carousel 注入）；首尾停顿用 TweenSequence 的 Constant 段近似 KOS
///   的 PauseAnimation（时长与线性段逐值对齐，见 dock_tokens）。
/// - `DockMusicPopup` 不移植——hover/点击统一走 DockInfoPopup（carousel 层）。
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:denial_flutter_sdk/shell_theme.dart'
    show ShellThemeBuildContext;
import 'package:denial_sdk/system.dart' show MprisPlaybackState;
import 'package:flutter/material.dart';

import '../../theme/dock_tokens.dart';

/// 把 marquee 控制器的 0..1 进度映射为「位移系数」：首段停 0 → 线性段
/// 0→1 → 尾段停 1（KOS `PauseAnimation`/`NumberAnimation`/`PauseAnimation`
/// 的循环，DockMusicPlayer.qml:259-282、:356-379）。
/// weight 用各段毫秒值（相对比例，等价于时长占比）。
TweenSequence<double> _marqueeSequence({
  required int pauseStartMs,
  required int scrollMs,
  required int pauseEndMs,
}) {
  final total = pauseStartMs + scrollMs + pauseEndMs;
  return TweenSequence<double>([
    TweenSequenceItem(
      tween: ConstantTween(0.0),
      weight: pauseStartMs / total,
    ),
    TweenSequenceItem(
      tween: Tween(begin: 0.0, end: 1.0),
      weight: scrollMs / total,
    ),
    TweenSequenceItem(
      tween: ConstantTween(1.0),
      weight: pauseEndMs / total,
    ),
  ]);
}

/// KOS `DockMusicPlayer`（carousel 页）。
///
/// Stateless：marquee 状态内聚到 [_FullTrackInfo]/[_CompactTrackInfo] 各自
/// 的 State（自带 `AnimationController` + hover 态），父级只透传
/// [state]/[artwork]/[pageActive] 与三个控制回调。
class DockMusicCard extends StatelessWidget {
  const DockMusicCard({
    required this.state,
    required this.artwork,
    required this.pageActive,
    this.onPrevious,
    this.onPlayPause,
    this.onNext,
    super.key,
  });

  /// MPRIS 播放态（`!available` 时卡仍绘制——可见性由 carousel `cardVisible`
  /// 门控；本卡按占位渲染，`title` 空 → `"No Track"`，KOS :243 同式）。
  final MprisPlaybackState state;

  /// 封面图字节（null → 占位 glyph；http(s) 不抓，记 deltas）。
  final Uint8List? artwork;

  /// KOS `pageActive`（:24-26）：false 时 marquee 停滚（本页不在前台）。
  final bool pageActive;

  final VoidCallback? onPrevious;
  final VoidCallback? onPlayPause;
  final VoidCallback? onNext;

  @override
  Widget build(BuildContext context) {
    final metrics = DockMetricsScope.of(context);
    final iconSize = metrics.iconSize;
    final colors = context.shellColors;
    final backgroundGap = iconSize * 0.1; // KOS: DockMusicPlayer.qml:32
    final contentWidth = iconSize * metrics.infoUnits; // :33
    final cardWidth = contentWidth + backgroundGap * 2; // :58
    // KOS: :29-30 `artSize = min(iconSize, dockHeight - vPadding*2)`，
    // `vPadding = round(iconSize*0.25)`。
    final vPadding = (iconSize * kDockMusicVPaddingRatio).roundToDouble();
    final artSize = math.min(iconSize, metrics.dockHeight - vPadding * 2);
    final compact = iconSize < kDockMusicCompactThreshold; // :31
    final playing = state.playing;

    return SizedBox(
      width: cardWidth,
      height: iconSize,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // 卡背：KOS artworkPalette 渐变（DockMusicPlayer.qml:129-153）→
          // 语义 panelGradient（记 deltas）。
          Positioned(
            top: -backgroundGap,
            bottom: -backgroundGap,
            width: cardWidth,
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(
                  iconSize * kDockInfoCardRadiusRatio,
                ),
                gradient: context.shellTheme.panelGradient(
                  colors.panelBackground,
                  colors.panelBackgroundBottom,
                ),
              ),
            ),
          ),
          // KOS 信息列占卡高（iconSize）；此前误绑 artSize，full 态
          // marquee + 三圆钮竖向叠放会 RenderFlex overflow。
          SizedBox(
            height: iconSize,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _AlbumArt(
                  artwork: artwork,
                  size: artSize,
                  compact: compact,
                  playing: playing,
                  onPlayPause: onPlayPause,
                  enabled: state.canPlay || state.canPause,
                ),
                SizedBox(
                  // KOS: :163 `spacing: Math.round(iconSize * 0.09)`。
                  width: (iconSize * 0.09).roundToDouble(),
                ),
                if (compact)
                  _CompactTrackInfo(
                    state: state,
                    width: math.max(
                      0,
                      contentWidth - artSize - (iconSize * 0.09).roundToDouble(),
                    ),
                    artSize: artSize,
                    pageActive: pageActive,
                  )
                else
                  _FullTrackInfo(
                    state: state,
                    contentWidth: contentWidth,
                    artSize: artSize,
                    vPadding: vPadding,
                    spacing: (iconSize * 0.09).roundToDouble(),
                    pageActive: pageActive,
                    onPrevious: state.canGoPrevious ? onPrevious : null,
                    onPlayPause: (state.canPlay || state.canPause)
                        ? onPlayPause
                        : null,
                    onNext: state.canGoNext ? onNext : null,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 封面块：圆角 6（KOS: :170,177 `radius: 6`）+ 占位 `dividerColor` →
/// hairlineSoft（记 deltas）；compact 时叠播停 overlay（:202-212）。
class _AlbumArt extends StatelessWidget {
  const _AlbumArt({
    required this.artwork,
    required this.size,
    required this.compact,
    required this.playing,
    required this.onPlayPause,
    required this.enabled,
  });

  final Uint8List? artwork;
  final double size;
  final bool compact;
  final bool playing;
  final VoidCallback? onPlayPause;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final colors = context.shellColors;
    final art = artwork;
    return ClipRRect(
      borderRadius: BorderRadius.circular(6), // KOS: :170
      child: SizedBox(
        width: size,
        height: size,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (art != null)
              Image.memory(
                art,
                fit: BoxFit.cover, // KOS: :190 PreserveAspectCrop
                gaplessPlayback: true,
                filterQuality: FilterQuality.medium,
              )
            else
              ColoredBox(
                // KOS: :171 `color: ThemeService.dividerColor` → hairlineSoft
                // 语义近似。
                color: colors.hairlineSoft,
                child: Icon(
                  Icons.music_note,
                  size: size * 0.5,
                  color: colors.textTertiary,
                ),
              ),
            if (compact)
              // KOS: :202-212 compact 封面叠播停钮（primary MediaControlButton
              // 满幅）。
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: enabled ? onPlayPause : null,
                child: ColoredBox(
                  color: colors.panelBackground.withValues(alpha: 0.35),
                  child: Center(
                    child: Icon(
                      playing ? Icons.pause : Icons.play_arrow,
                      size: math.max(14, size * 0.36), // KOS: :206
                      color: colors.textPrimary,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// full 轨信息 + 控制钮（DockMusicPlayer.qml:217-309）。Stateful——marquee
/// 控制器与 hover 态内聚在本 State；LayoutBuilder 测得溢出后经 postFrame
/// 启动/停止循环滚动（build 期不得改动画状态）。
class _FullTrackInfo extends StatefulWidget {
  const _FullTrackInfo({
    required this.state,
    required this.contentWidth,
    required this.artSize,
    required this.vPadding,
    required this.spacing,
    required this.pageActive,
    required this.onPrevious,
    required this.onPlayPause,
    required this.onNext,
  });

  final MprisPlaybackState state;
  final double contentWidth;
  final double artSize;
  final double vPadding;
  final double spacing;

  /// KOS `pageActive`（:24-26）：false 时 marquee 停滚。
  final bool pageActive;

  final VoidCallback? onPrevious;
  final VoidCallback? onPlayPause;
  final VoidCallback? onNext;

  @override
  State<_FullTrackInfo> createState() => _FullTrackInfoState();
}

class _FullTrackInfoState extends State<_FullTrackInfo>
    with SingleTickerProviderStateMixin {
  /// marquee 循环控制器（KOS `trackScroll`，DockMusicPlayer.qml:259-282：
  /// PauseAnimation 1200ms → Linear `max(900, 溢出*35)`ms → PauseAnimation
  /// 800ms → 归零）。
  late final AnimationController _marquee = AnimationController(vsync: this);

  /// KOS `trackHover.hovered`（仅 hover 且本页前台时滚动）。
  bool _hovered = false;

  /// 最近一次布局测得：溢出宽 + 线性滚动时长。
  double _overflow = 0;
  int _scrollMs = kDockMusicMarqueeMinDurationMs.round();

  /// 把控制器 0..1 进度映射为位移系数（含首尾停顿）。
  late TweenSequence<double> _sequence = _marqueeSequence(
    pauseStartMs: kDockMusicMarqueePauseStartMs,
    scrollMs: _scrollMs,
    pauseEndMs: kDockMusicMarqueePauseEndMs,
  );

  @override
  void dispose() {
    _marquee.dispose();
    super.dispose();
  }

  /// KOS:259-282 语义：`pageActive && hovered && 文本超宽` 才滚动。
  /// 停止时归零回弹（KOS `PauseAnimation` 尾段后的 reset）。
  void _syncMarquee() {
    final running = widget.pageActive && _hovered && _overflow > 0;
    if (!running) {
      if (_marquee.isAnimating) _marquee.stop();
      if (_marquee.value != 0) _marquee.value = 0;
      return;
    }
    final total =
        kDockMusicMarqueePauseStartMs + _scrollMs + kDockMusicMarqueePauseEndMs;
    if (_marquee.duration?.inMilliseconds != total) {
      _marquee.duration = Duration(milliseconds: total);
      _marquee.value = 0;
    }
    if (!_marquee.isAnimating) unawaited(_marquee.repeat());
  }

  @override
  Widget build(BuildContext context) {
    final metrics = DockMetricsScope.of(context);
    final iconSize = metrics.iconSize;
    final colors = context.shellColors;
    // KOS: :220 列宽 `contentWidth - artSize - spacing - vPadding*2`。
    final columnWidth = math.max(
      0.0,
      widget.contentWidth - widget.artSize - widget.spacing - widget.vPadding * 2,
    );
    final state = widget.state;
    final title = state.title.isEmpty ? 'No Track' : state.title; // KOS: :243
    final artist = state.artistLabel;
    return SizedBox(
      width: columnWidth,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // KOS: :224-290 marquee viewport（overflow + hover → 滚动）。
          MouseRegion(
            onEnter: (_) {
              _hovered = true;
              _syncMarquee();
            },
            onExit: (_) {
              _hovered = false;
              _syncMarquee();
            },
            child: ClipRect(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final viewport = constraints.maxWidth;
                  final textSpan = TextSpan(
                    children: [
                      TextSpan(
                        text: title,
                        style: TextStyle(
                          color: colors.textPrimary,
                          fontSize: math.max(12, iconSize * 0.28), // KOS: :245
                          fontWeight: FontWeight.w700,
                          height: 1.0,
                        ),
                      ),
                      if (artist.isNotEmpty)
                        TextSpan(
                          text: '  ·  $artist', // KOS: :252-254 `"·  "+artist`
                          style: TextStyle(
                            color: colors.textPrimary.withValues(alpha: 0.85),
                            fontSize: math.max(8, iconSize * 0.19), // :256
                            height: 1.0,
                          ),
                        ),
                    ],
                  );
                  final painter = TextPainter(
                    text: textSpan,
                    maxLines: 1,
                    textDirection: TextDirection.ltr,
                  )..layout();
                  final textWidth = painter.width;
                  final overflow = math.max(0.0, textWidth - viewport);
                  _overflow = overflow;
                  _scrollMs = math
                      .max(
                        kDockMusicMarqueeMinDurationMs,
                        overflow * kDockMusicMarqueeSpeed,
                      )
                      .round();
                  _sequence = _marqueeSequence(
                    pauseStartMs: kDockMusicMarqueePauseStartMs,
                    scrollMs: _scrollMs,
                    pauseEndMs: kDockMusicMarqueePauseEndMs,
                  );
                  // build 期不得改动画状态 → postFrame 派发
                  // （KOS `trackScroll` 的 running 绑定）。
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted) _syncMarquee();
                  });
                  return SizedBox(
                    height: painter.height,
                    width: viewport,
                    child: OverflowBox(
                      alignment: Alignment.centerLeft,
                      maxWidth: double.infinity,
                      child: AnimatedBuilder(
                        animation: _marquee,
                        builder: (context, child) {
                          final offset = overflow <= 0
                              ? 0.0
                              : -overflow * _sequence.transform(_marquee.value);
                          return Transform.translate(
                            offset: Offset(offset, 0),
                            child: child,
                          );
                        },
                        child: RichText(
                          text: textSpan,
                          maxLines: 1,
                          overflow: TextOverflow.clip,
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
          const SizedBox(height: 1), // KOS: :221 `spacing: 1`
          // 控制钮行（KOS: :293-294 Row spacing round(iconSize*0.07)）。
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _DockControlButton(
                icon: Icons.skip_previous,
                size: math.max(
                  kDockMusicNavButtonSize,
                  iconSize * 0.54,
                ), // KOS: :393-394
                iconSize: math.max(12, iconSize * 0.28), // :396-397
                onTap: widget.onPrevious,
              ),
              SizedBox(width: (iconSize * 0.07).roundToDouble()),
              _DockControlButton(
                icon: state.playing ? Icons.pause : Icons.play_arrow,
                primary: true,
                size: math.max(
                  kDockMusicPlayButtonSize,
                  iconSize * 0.62,
                ), // KOS: :393-394
                iconSize: math.max(14, iconSize * 0.34), // :396-397
                onTap: widget.onPlayPause,
              ),
              SizedBox(width: (iconSize * 0.07).roundToDouble()),
              _DockControlButton(
                icon: Icons.skip_next,
                size: math.max(kDockMusicNavButtonSize, iconSize * 0.54),
                iconSize: math.max(12, iconSize * 0.28),
                onTap: widget.onNext,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// KOS `DockControlButton`（DockMusicPlayer.qml:392-400）：半透明圆钮 +
/// glassInk=foreground → textPrimary。
class _DockControlButton extends StatelessWidget {
  const _DockControlButton({
    required this.icon,
    required this.size,
    required this.iconSize,
    this.primary = false,
    this.onTap,
  });

  final IconData icon;
  final double size;
  final double iconSize;
  final bool primary;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.shellColors;
    final enabled = onTap != null;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          // KOS `MediaControlButton` 玻璃圆体 → textPrimary 低 alpha 实体
          // 近似（记 deltas）；primary 略深。
          color: colors.textPrimary.withValues(
            alpha: enabled ? (primary ? 0.20 : 0.12) : 0.06,
          ),
          border: Border.all(
            color: colors.textPrimary.withValues(
              alpha: enabled ? 0.25 : 0.10,
            ),
          ),
        ),
        child: Icon(
          icon,
          size: iconSize,
          color: enabled
              ? colors.textPrimary
              : colors.textTertiary, // glassInk → 语义色
        ),
      ),
    );
  }
}

/// compact 单行滚动 metadata（DockMusicPlayer.qml:317-381）：`title · artist
/// · album` 溢出时 pageActive 恒滚（自带 marquee 控制器）。
class _CompactTrackInfo extends StatefulWidget {
  const _CompactTrackInfo({
    required this.state,
    required this.width,
    required this.artSize,
    required this.pageActive,
  });

  final MprisPlaybackState state;
  final double width;
  final double artSize;
  final bool pageActive;

  @override
  State<_CompactTrackInfo> createState() => _CompactTrackInfoState();
}

class _CompactTrackInfoState extends State<_CompactTrackInfo>
    with SingleTickerProviderStateMixin {
  /// marquee 循环控制器（KOS `compactTrackScroll`，DockMusicPlayer.qml:
  /// 356-379：停留 900ms → Linear `max(800, 溢出*32)`ms → 停留 650ms →
  /// 归零）。
  late final AnimationController _marquee = AnimationController(vsync: this);

  double _overflow = 0;
  int _scrollMs = kDockMusicCompactMarqueeMinDurationMs.round();

  late TweenSequence<double> _sequence = _marqueeSequence(
    pauseStartMs: kDockMusicCompactMarqueePauseStartMs,
    scrollMs: _scrollMs,
    pauseEndMs: kDockMusicCompactMarqueePauseEndMs,
  );

  @override
  void dispose() {
    _marquee.dispose();
    super.dispose();
  }

  /// KOS:356-379 语义：compact 模式 `pageActive && 溢出` 即滚（无 hover 门控）。
  void _syncMarquee() {
    final running = widget.pageActive && _overflow > 0;
    if (!running) {
      if (_marquee.isAnimating) _marquee.stop();
      if (_marquee.value != 0) _marquee.value = 0;
      return;
    }
    final total = kDockMusicCompactMarqueePauseStartMs +
        _scrollMs +
        kDockMusicCompactMarqueePauseEndMs;
    if (_marquee.duration?.inMilliseconds != total) {
      _marquee.duration = Duration(milliseconds: total);
      _marquee.value = 0;
    }
    if (!_marquee.isAnimating) unawaited(_marquee.repeat());
  }

  @override
  Widget build(BuildContext context) {
    final iconSize = DockMetricsScope.of(context).iconSize;
    final colors = context.shellColors;
    // KOS: :331-338 `metadata = [title, artist, album].filter(非空).join(" · ")`。
    final metadata = [
      if (widget.state.title.isEmpty) 'No Track' else widget.state.title,
      if (widget.state.artistLabel.isNotEmpty) widget.state.artistLabel,
      if (widget.state.album.isNotEmpty) widget.state.album,
    ].join(' · ');
    return SizedBox(
      width: widget.width,
      height: widget.artSize,
      child: ClipRect(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final viewport = constraints.maxWidth;
            final style = TextStyle(
              color: colors.textPrimary,
              // KOS: :346-348 pixelSize max(8, round(iconSize*0.25)) Bold。
              fontSize: math.max(8, (iconSize * 0.25).roundToDouble()),
              fontWeight: FontWeight.w700,
              height: 1.0,
            );
            final painter = TextPainter(
              text: TextSpan(text: metadata, style: style),
              maxLines: 1,
              textDirection: TextDirection.ltr,
            )..layout();
            final overflow = math.max(0.0, painter.width - viewport);
            _overflow = overflow;
            _scrollMs = math
                .max(
                  kDockMusicCompactMarqueeMinDurationMs,
                  overflow * kDockMusicCompactMarqueeSpeed,
                )
                .round();
            _sequence = _marqueeSequence(
              pauseStartMs: kDockMusicCompactMarqueePauseStartMs,
              scrollMs: _scrollMs,
              pauseEndMs: kDockMusicCompactMarqueePauseEndMs,
            );
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) _syncMarquee();
            });
            return OverflowBox(
              alignment: Alignment.centerLeft,
              maxWidth: double.infinity,
              child: AnimatedBuilder(
                animation: _marquee,
                builder: (context, child) {
                  final offset = overflow <= 0
                      ? 0.0
                      : -overflow * _sequence.transform(_marquee.value);
                  return Transform.translate(
                    offset: Offset(offset, 0),
                    child: child,
                  );
                },
                child: Text(metadata, maxLines: 1, style: style),
              ),
            );
          },
        ),
      ),
    );
  }
}
