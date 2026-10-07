/// KOS DeskCenter 音乐小部件（`KosMusicCard`）。
///
/// 对齐 NextKde `DeskCenterWindow.qml` 的 music 分支（Loader
/// :1699-1986）：
/// - 封面取色底色（:1746-1759）：横向渐变 `primary@0.82 → secondary@0.64
///   （0.52）→ primary@0.38`，仅 `hasPlayer && !onBackdrop`（:1748）——
///   TASK-09 起卡片统一吃 Denial ShellTheme 材质（等价 onBackdrop），
///   色艺渐变层与 `kosArtworkPalette`/`paletteFor` 取色链全部删除；
/// - 漂浮音符（:1760-1795）：右 24/顶 17、72×62 裁剪区，`♪♫♪` 三枚、
///   x=[4,34,54]、字号 [14,18,14] DemiBold、material 取 tertiary 角色
///   （:1778）否则白@0.60；动画 `Pause(index·620) + y 2200+index·180ms
///   OutSine / opacity 360ms 淡入 + (1840+index·180)ms InSine 淡出`，
///   仅播放中且卡可见运行（:1767-1768）；
/// - 主体（:1797-1854）：四周 16px，左封面栏 (w-20)·0.3 宽、splitGap 20、
///   右详情栏；封面为 `min(栏宽,栏高)` 正方形、圆角 w·0.1、底
///   rgba(1,1,1,0.10)（:1815）、PreserveAspectCrop；无播放器时中央
///   "♫" w·0.42 白@0.46（:1846-1852）；material/glass 非 color 样式
///   封面去饱和（saturation -1.0，:1836 `widgetStyle==="color" ? 0 : -1`）
///   ——色艺删除后恒去饱和；
/// - 标题 `trackTitle || "暂无播放内容"`（:1865）14px DemiBold 居中、
///   艺人 `trackArtist || ""`（:1874）10px 白@0.68 居中、歌词行
///   （KosLyricLine :1880-1889）任务卡后置；
/// - 进度（:1890-1944）：轨高 5、可见当且仅当 `safeLength>0`
///   （:1713-1715：`lengthSupported && length>0`）；material →
///   `WavyProgress`（amplitude 2.4、wavelength 11、lineWidth 2.5、
///   phase 动画 1100ms 播放中，:1900-1912 + WavyProgress.qml:21-27）；
///   非 material → 白@0.20 轨 + 白@0.82 填充（:1913-1925）；下挂
///   `m:ss` 双端时间 8px 白@0.60（:1927-1944）；
/// - 控制行（:1945-1979）：底边距 2、高 36、间距 10 三枚 36px 圆钮——
///   `DeskMediaButton`（common/MediaControlButton.qml:6-76：icon 16/主
///   18，填充 primary→primaryContainer/白@0.20、其余
///   secondaryContainer/白@0.09，禁用透明度 0.32，按下缩放 0.94）；
///   enabled 由 `canGoPrevious/canTogglePlaying/canGoNext` 逐项门控
///   （:1967-1970），点击经 `MediaCommands`（DockMprisService.qml
///   :176-190 的 previous/togglePlayPause/next）；
/// - 整卡点击 → `launchById("kos-music", [])`（:1718-1722）→
///   `onLaunchApp`；**顺序注意**：源端整卡 MouseArea 在兄弟项之前声明，
///   z 序在后声明的按钮之下，故按钮命中优先（QML 堆叠序规则）——本端
///   GestureDetector 在 Stack 首位，同样让按钮命中优先。
///
/// 数据：`services.media`（`AsyncValue<MprisPlaybackState>`；
/// `available` 等价源 `activePlayer!==null`，mpris_playback.dart:55-58）
/// + `services.mediaCommands`；均 ProviderListenable 注入，测试给
/// `Provider`/`AsyncValue` 常量。封面字节经
/// `services.presentation.imageBytes(artUrl path)` 或构造注入
/// `coverBytes`/`coverProviderFor`（widget 内不直接 File/网络——任务卡
/// 约束；imageBytes 的 path 形参对应 `file:`/裸路径封面，http(s)
/// artUrl 无 SDK 通道，记 deltas §7）。
///
/// 源文件行号均指 `/home/wwt/文档/NextKde/shell/desktop/modules/` 相对根。
library;

import '../theme/backdrop_content.dart';

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:denial_flutter_sdk/services.dart';
import 'package:denial_sdk/system.dart' show MprisPlaybackState;
import 'package:denial_flutter_sdk/shell_theme.dart'
    show ShellThemeBuildContext, ShellThemeData;
import 'package:flutter/widgets.dart';
import 'package:flutter/material.dart' show Icons;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;

import '../layout/widget_layout.dart' show WidgetSize;
import 'calendar_card.dart' show KosLaunchAppCallback;
import 'desk_card.dart';

/// 音乐卡内容色板（`content.ink`/`colors.*` 角色解析注入）。
/// TASK-09 起 `onBackdrop`/`isMaterial` 分叉改为按 `context.shellTheme`
/// 解析（[KosMusicCardColors.forShell]）：插件表面下没有 MaterialApp/Theme
/// 祖先，Theme.of 恒回退 light 基线，真实亮度/色板走 shell。
final class KosMusicCardColors {
  const KosMusicCardColors({
    required this.isMaterial,
    this.ink = const Color(0xFFFFFFFF), // ink(\"white\") :1868
    this.subInk = const Color(0xADFFFFFF), // ink(白,0.68) :1877
    this.timeInk = const Color(0x99FFFFFF), // ink(白,0.60) :1935/:1941
    this.noteInk = const Color(0x99FFFFFF), // pick(tertiary,白@0.60) :1778
    this.controlInk = const Color(0xE0FFFFFF), // glassInk 白@0.88 :1971-1973
    this.controlInkPrimary = const Color(
      0xFF1D192B,
    ), // primaryContainerForeground baseline（:14-16）
    this.controlFillPrimary = const Color(0x33FFFFFF), // 白@0.20 :20
    this.controlFill = const Color(0x17FFFFFF), // 白@0.09 :20
    this.coverBase = const Color(0x1AFFFFFF), // rgba(1,1,1,0.10) :1815
    this.placeholderNote = const Color(0x75FFFFFF), // rgba(1,1,1,0.46) :1850
    this.progressTrack = const Color(0x33FFFFFF), // rgba(1,1,1,0.20) :1917
    this.progressFill = const Color(0xD1FFFFFF), // rgba(1,1,1,0.82) :1924
    this.wavyActive = const Color(0xFFFFFFFF), // colors.primary 注入 :1907
    this.wavyTrack = const Color(0x3DFFFFFF), // colors.outlineVariant :1908
  });

  /// 透明桌面材质采用 NextKde 白色 backdrop ink；不透明模式采用壳色板。
  /// 此解析只影响卡片内容，不修改详情面板、菜单或卡片表面材质。
  static KosMusicCardColors forShell(ShellThemeData theme) {
    final accent = theme.accentPalette;
    final light =
        !usesBackdropInk(theme) && theme.brightness == Brightness.light;
    return KosMusicCardColors(
      isMaterial: light,
      ink: backdropInk(theme),
      subInk: backdropSecondaryInk(theme),
      timeInk: backdropSecondaryInk(theme),
      noteInk: backdropSecondaryInk(theme),
      controlInk: backdropInk(theme), // 非主钮图标（:1971-1973）
      controlInkPrimary: usesBackdropInk(theme)
          ? backdropInk(theme)
          : accent.onContainer, // 主钮图标压 accent 容器
      controlFillPrimary: usesBackdropInk(theme)
          ? backdropInk(theme).withValues(alpha: 0.20)
          : accent.container, // :20 primaryContainer → accent 容器
      controlFill: usesBackdropInk(theme)
          ? backdropInk(theme).withValues(alpha: 0.09)
          : accent.subtle, // :20 secondaryContainer → accent subtle
      progressTrack: backdropInk(theme).withValues(alpha: 0.20), // :1917
      progressFill: backdropInk(theme).withValues(alpha: 0.82), // :1924
      // :1850 空态「♫」占位符是 live 墨色——暗壳白@0.46 在亮壳不可见；
      // 走 textSecondary 并保留 0.46 alpha（暗壳同样成立）。
      placeholderNote: backdropSecondaryInk(theme).withValues(alpha: 0.46),
      wavyActive: theme.accent, // :1907 colors.primary → shell accent
      wavyTrack: backdropHairline(theme), // :1908 outlineVariant → hairlineSoft
    );
  }

  /// `AppearanceTokens.isMaterial`：进度条 WavyProgress vs 双色矩形
  /// （:1904/:1915/:1922）、控制钮角色色（:14-20）。按 `context.shellTheme.
  /// brightness` 解析——light→material 分支、dark→onBackdrop 平坦条。
  final bool isMaterial;

  final Color ink;
  final Color subInk;
  final Color timeInk;
  final Color noteInk;

  /// 非主控制钮图标色（:1971-1973）→ shell `textPrimary`。
  final Color controlInk;

  /// 主控制钮（播放）图标色，压 `controlFillPrimary` 容器 →
  /// `accentPalette.onContainer`。
  final Color controlInkPrimary;

  final Color controlFillPrimary;
  final Color controlFill;
  final Color coverBase;
  final Color placeholderNote;
  final Color progressTrack;
  final Color progressFill;
  final Color wavyActive;
  final Color wavyTrack;
}

/// DeskCenter 音乐卡（`modelData.id === "music"`，:1699-1986）。
class KosMusicCard extends ConsumerStatefulWidget {
  const KosMusicCard({
    super.key,
    this.media,
    this.mediaCommands,
    this.coverProviderFor,
    this.coverBytes,
    this.colors,
    this.size = WidgetSize.medium,
    this.editMode = false,
    this.onLaunchApp,
    this.onRemove,
    this.onCycleSize,
  });

  /// 播放状态：`ProviderListenable<AsyncValue<MprisPlaybackState>>`；
  /// null 时经 `ShellServicesScope` 取 `services.media`
  /// （services.dart:116）。`AsyncValue` 无值视为无播放器。
  final ProviderListenable<AsyncValue<MprisPlaybackState>>? media;

  /// 播放控制：`ProviderListenable<MediaCommands>`；null 时取
  /// `services.mediaCommands`（services.dart:117）。只调接口方法
  /// （previous/playPause/next，对齐 DockMprisService.qml:176-190）。
  final ProviderListenable<MediaCommands>? mediaCommands;

  /// 封面字节 provider 工厂：`artUrl`（字符串路径）→
  /// `ProviderListenable<AsyncValue<Uint8List?>>`。null 时经 scope 取
  /// `services.imageBytes(path)`（services.dart:123）。本参数供测试注入
  /// 固定字节；`coverBytes` 为更直接的常量注入。
  final ProviderListenable<AsyncValue<Uint8List?>> Function(String path)?
  coverProviderFor;

  /// 直接注入的封面字节（优先于 provider 链路）。
  final Uint8List? coverBytes;

  /// 内容色板；null 时 build 内按 `context.shellTheme` 取
  /// [KosMusicCardColors.forShell]（亮壳→material/accent 系、暗壳→白系）。
  final KosMusicCardColors? colors;

  /// 尺寸档位。
  final WidgetSize size;

  /// 编辑模式角标。
  final bool editMode;

  /// 整卡点击 `('kos-music', [])`（:1718-1722）。
  final KosLaunchAppCallback? onLaunchApp;

  /// 编辑态角标回调。
  final DeskCardBadgeCallback? onRemove;
  final DeskCardBadgeCallback? onCycleSize;

  @override
  ConsumerState<KosMusicCard> createState() => _KosMusicCardState();
}

class _KosMusicCardState extends ConsumerState<KosMusicCard>
    with TickerProviderStateMixin {
  /// WavyProgress 相位驱动（WavyProgress.qml:21-27：1100ms 0→2π 循环，
  /// 播放中运行）。
  late final AnimationController _wavyPhase = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100), // WavyProgress.qml:24
  );

  /// 音符漂浮动图时钟：周期取最长支线 pause+rise+fade
  /// （:1783-1791 index=2 → 1240+2560+2200=6000ms；每支线独立循环，故
  /// 用公共周期长钟 + 支线本地取模）。
  late final AnimationController _notesClock = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 6000),
  );

  @override
  void dispose() {
    _wavyPhase.dispose();
    _notesClock.dispose();
    super.dispose();
  }

  // :1727-1730 formatPlaybackTime：floor 后 m:ss。
  static String _formatTime(Duration d) {
    final value = math.max(0, d.inMilliseconds) ~/ 1000;
    return '${value ~/ 60}:${(value % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<ShellServicesScope>();
    final mediaListenable = widget.media ?? scope?.services.media;
    final media = mediaListenable != null
        ? ref.watch(mediaListenable).value
        : null;
    final commandsListenable =
        widget.mediaCommands ?? scope?.services.mediaCommands;
    final commands = commandsListenable != null
        ? ref.watch(commandsListenable)
        : null;

    final colors =
        widget.colors ?? KosMusicCardColors.forShell(context.shellTheme);

    final hasPlayer = media?.available ?? false; // :1707 hasPlayer
    // :1713-1716 safeLength/progress：lengthSupported && length>0。
    final safeLength = media != null && media.length > Duration.zero
        ? media.length
        : null;
    final position =
        media?.positionAt(DateTime.now()) ?? Duration.zero; // :1738-1740 语义
    final progress = safeLength != null && safeLength > Duration.zero
        ? (position.inMicroseconds / safeLength.inMicroseconds).clamp(0.0, 1.0)
        : 0.0;
    final playing = media?.playing ?? false; // :1767 isPlaying

    // 封面字节：构造注入 > provider 工厂 > scope imageBytes。
    Uint8List? cover = widget.coverBytes;
    if (cover == null && media != null && media.artUrl.isNotEmpty) {
      final provider =
          widget.coverProviderFor?.call(media.artUrl) ??
          _scopeImageBytes(scope, media.artUrl);
      if (provider != null) cover = ref.watch(provider).value;
    }

    // WavyProgress 相位与播放位置刷新：播放中运行双动画（:1735-1740 的
    // 250ms 位置轮询由帧驱动的 AnimatedBuilder 覆盖，更平滑且省电
    // 近似——停止时停走）。
    if (playing) {
      if (!_wavyPhase.isAnimating) _wavyPhase.repeat();
      if (!_notesClock.isAnimating) _notesClock.repeat();
    } else {
      if (_wavyPhase.isAnimating) _wavyPhase.stop();
      if (_notesClock.isAnimating) _notesClock.stop();
    }
    return DeskCard(
      size: widget.size,
      editMode: widget.editMode,
      onRemove: widget.onRemove,
      onCycleSize: widget.onCycleSize,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        // :1718-1722 整卡点击 → launchById("kos-music", [])。Detector 包在
        // 内容之外（同 todo/weather 卡结构）：按钮的 detector 在命中路径上
        // 更深、tap 竞技由内层赢得，故按钮区仍归按钮，其余区域走整卡回调。
        // 原 Stack 内兄弟垫底方案在 Flutter 语义下不成立——Positioned.fill
        // 的后声明兄弟（主体）先吃掉命中，整卡回调永远不可达。
        onTap: widget.onLaunchApp == null
            ? null
            : () => widget.onLaunchApp!('kos-music', const []),
        child: Stack(
          fit: StackFit.expand,
          children: [
            // 封面取色横向渐变（:1746-1759）仅 !onBackdrop——TASK-09 统一
            // onBackdrop 材质后整层删除。
            // 漂浮音符（:1760-1795），仅播放中（:1767-1769 visible:running）。
            if (playing)
              Positioned(
                right: 24, // :1762
                top: 17, // :1762
                width: 72, // :1763
                height: 62, // :1764
                child: ClipRect(
                  child: _MusicNotes(
                    controller: _notesClock,
                    color: colors.noteInk,
                  ),
                ),
              ),
            // 主体（:1797-1983）：四周 16px。
            Positioned.fill(
              child: Padding(
                padding: const EdgeInsets.all(16), // :1799 margins:16
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    const splitGap = 20.0; // :1800
                    final coverPaneW =
                        (constraints.maxWidth - splitGap) * 0.3; // :1807
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(
                          width: coverPaneW,
                          // 封面（:1809-1853）：居中正方形
                          // min(栏宽,栏高)、圆角 w·0.1。
                          child: Center(
                            child: AspectRatio(
                              aspectRatio: 1,
                              child: _Cover(
                                bytes: cover,
                                hasPlayer: hasPlayer,
                                colors: colors,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: splitGap), // :1800
                        Expanded(
                          child: _DetailsPane(
                            media: media,
                            hasPlayer: hasPlayer,
                            safeLength: safeLength,
                            progress: progress,
                            position: position,
                            colors: colors,
                            commands: commands,
                            phase: _wavyPhase,
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// scope.presentation.imageBytes 适配：artUrl 为 `file:` URI 或裸路径
  /// 时提取路径；http(s)/其它 scheme 返回 null（无 SDK 通道，deltas §7）。
  ProviderListenable<AsyncValue<Uint8List?>>? _scopeImageBytes(
    ShellServicesScope? scope,
    String artUrl,
  ) {
    if (scope == null) return null;
    final uri = Uri.tryParse(artUrl);
    final path = switch (uri?.scheme) {
      'file' => uri!.toFilePath(),
      '' || null => artUrl,
      _ => null, // http/https 封面无 imageBytes 通道
    };
    return path == null ? null : scope.services.imageBytes(path);
  }
}

/// 漂浮音符（:1760-1795）：`♪♫♪` 三枚；动画参数逐项抄源
/// （Pause index·620ms；y 从 height-14 到 -20 用 2200+index·180ms
/// OutSine；opacity 0→0.64 360ms；0.64→0 用 1840+index·180ms InSine）。
/// 源 y/opacity 两条独立 SequentialAnimation 各自循环（周期不同），
/// 本端以公共 6000ms 钟驱动，每条支线按自己的周期取模（等效无限循环）。
class _MusicNotes extends StatelessWidget {
  const _MusicNotes({required this.controller, required this.color});

  /// 公共相位钟（任意周期 ms 驱动 [0,1) 循环）。
  final AnimationController controller;
  final Color color;

  static const _offsets = [4.0, 34.0, 54.0]; // :1775
  static const _glyphs = ['♪', '♫', '♪']; // :1771

  /// 每条支线：pause（:1783）+ y 时长（:1784）+ opacity 结构（:1790-1791）。
  static ({double pause, double rise, double fade}) _branch(int i) => (
    pause: i * 620.0, // :1783 PauseAnimation index*620
    rise: 2200.0 + i * 180, // :1784 2200+index*180 OutSine
    fade: 1840.0 + i * 180, // :1791 1840+index*180 InSine
  );

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, child) {
        final ms = controller.value * controller.duration!.inMilliseconds;
        return Stack(
          children: [
            for (var i = 0; i < 3; i++)
              Positioned(
                left: _offsets[i], // :1775-1776
                top: _noteY(i, ms),
                child: Opacity(
                  opacity: _noteOpacity(i, ms),
                  child: Text(
                    _glyphs[i],
                    style: TextStyle(
                      color: color,
                      fontSize: i == 1 ? 18 : 14, // :1779
                      fontWeight: FontWeight.w600, // DemiBold
                      height: 1,
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  /// y 支线（:1780-1785）：pause 后 rise 段由 height-14 → -20 OutSine，
  /// 到达 -20 保持至周期末（源 SequentialAnimation 单次循环末尾即 -20）。
  double _noteY(int i, double ms) {
    const height = 62.0; // musicNotes.height（:1764）
    final b = _branch(i);
    final cycle = b.pause + b.rise;
    final local = ms % cycle;
    if (local <= b.pause) return height - 14; // 起点 from 值
    final t = ((local - b.pause) / b.rise).clamp(0.0, 1.0);
    final p = math.sin(t * math.pi / 2); // OutSine
    return (height - 14) + (-20 - (height - 14)) * p;
  }

  /// opacity 支线（:1786-1792）：pause → 360ms 0→0.64 → fade 段 InSine
  /// 0.64→0，保持 0 至周期末。
  double _noteOpacity(int i, double ms) {
    final b = _branch(i);
    const fadeIn = 360.0; // :1790
    final cycle = b.pause + fadeIn + b.fade;
    final local = ms % cycle;
    if (local <= b.pause) return 0;
    final after = local - b.pause;
    if (after <= fadeIn) return 0.64 * (after / fadeIn);
    final t = ((after - fadeIn) / b.fade).clamp(0.0, 1.0);
    final p = 1 - math.cos(t * math.pi / 2); // InSine
    return 0.64 * (1 - p);
  }
}

/// 封面块（:1809-1853）：圆角 w·0.1、底 rgba(1,1,1,0.10)、
/// PreserveAspectCrop；无播放器显 "♫" w·0.42 白@0.46。色艺删除后封面
/// 恒去饱和（:1836 `widgetStyle==="color" ? 0 : -1` 的非 color 分支）。
class _Cover extends StatelessWidget {
  const _Cover({
    required this.bytes,
    required this.hasPlayer,
    required this.colors,
  });

  final Uint8List? bytes;
  final bool hasPlayer;
  final KosMusicCardColors colors;

  /// 灰度矩阵（ saturation -1.0 近似；:1836 MultiEffect saturation）。
  static const _grayscale = ColorFilter.matrix(<double>[
    0.2126,
    0.7152,
    0.0722,
    0,
    0,
    0.2126,
    0.7152,
    0.0722,
    0,
    0,
    0.2126,
    0.7152,
    0.0722,
    0,
    0,
    0,
    0,
    0,
    1,
    0,
  ]);

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final side = math.min(
          constraints.maxWidth,
          constraints.maxHeight,
        ); // :1812-1813
        final radius = side * 0.1; // :1814/:1842
        Widget content;
        if (hasPlayer && bytes != null) {
          // :1821-1837 Image PreserveAspectCrop + 蒙版圆角；非 color 样式
          // 去饱和（:1836）——色艺删除后恒执行。
          final Widget image = ColorFiltered(
            colorFilter: _grayscale,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(radius),
              child: Image.memory(
                bytes!,
                fit: BoxFit.cover,
                width: side,
                height: side,
                gaplessPlayback: true,
                // MPRIS 封面原图远大于卡内缩略框：medium 双线性降采样。
                filterQuality: FilterQuality.medium,
              ),
            ),
          );
          content = image;
        } else {
          content = Center(
            child: Text(
              '♫', // :1849
              style: TextStyle(
                color: colors.placeholderNote,
                fontSize: side * 0.42, // :1851
                height: 1,
              ),
            ),
          );
        }
        return Container(
          width: side,
          height: side,
          decoration: BoxDecoration(
            color: colors.coverBase, // :1815 rgba(1,1,1,0.10)
            borderRadius: BorderRadius.circular(radius),
          ),
          clipBehavior: Clip.antiAlias,
          child: content,
        );
      },
    );
  }
}

/// 右侧详情栏（:1856-1982）：标题/艺人/（歌词后置）/进度/控制行。
class _DetailsPane extends StatelessWidget {
  const _DetailsPane({
    required this.media,
    required this.hasPlayer,
    required this.safeLength,
    required this.progress,
    required this.position,
    required this.colors,
    required this.commands,
    required this.phase,
  });

  final MprisPlaybackState? media;
  final bool hasPlayer;
  final Duration? safeLength;
  final double progress;
  final Duration position;
  final KosMusicCardColors colors;
  final MediaCommands? commands;
  final AnimationController phase;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final h = constraints.maxHeight;
        // :1864 verticalCenterOffset:-22 —— 标题块中点相对栏中心上移 22。
        return Stack(
          fit: StackFit.expand,
          children: [
            // 标题（:1862-1870）：14px DemiBold 居中截断。
            Positioned(
              left: 0,
              right: 0,
              top: h / 2 - 22 - 8, // verticalCenterOffset:-22 标题中心-8 半高
              child: Text(
                hasPlayer && (media?.title.isNotEmpty ?? false)
                    ? media!.title
                    : '暂无播放内容', // :1865
                maxLines: 1,
                overflow: TextOverflow.ellipsis, // :1866
                textAlign: TextAlign.center, // :1867
                style: TextStyle(
                  color: colors.ink,
                  fontSize: 14, // :1869
                  fontWeight: FontWeight.w600,
                  height: 1.2,
                ),
              ),
            ),
            // 艺人（:1871-1879）：标题下 3、10px 白@0.68。
            Positioned(
              left: 0,
              right: 0,
              top: h / 2 - 22 - 8 + 14 * 1.2 + 3, // :1873 topMargin:3
              child: Text(
                hasPlayer ? (media?.artistLabel ?? '') : '', // :1874
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: colors.subInk,
                  fontSize: 10, // :1878
                  height: 1.2,
                ),
              ),
            ),
            // 进度轨（:1890-1926）：艺人行下 12（歌词行后置，:1896 另一档
            // 7 在有歌词时生效，本卡不含歌词层——记 deltas）。
            if (safeLength != null && safeLength! > Duration.zero)
              Positioned(
                left: 0,
                right: 0,
                top: h / 2 - 22 - 8 + 14 * 1.2 + 3 + 10 * 1.2 + 12,
                height: 5, // :1898
                child: colors.isMaterial
                    // WavyProgress（:1900-1912）：外放 3px 振幅区
                    // （:1902-1903 topMargin:-3/bottomMargin:-3）。负边距
                    // 在 Flutter 非法——用 OverflowBox 把 5 高轨道扩成
                    // 11 高画布，振幅区超出不裁剪。
                    ? OverflowBox(
                        minHeight: 5 + 6,
                        maxHeight: 5 + 6,
                        child: SizedBox(
                          height: 5 + 6,
                          child: Center(
                            child: SizedBox(
                              height: 5,
                              child: _WavyProgress(
                                value: progress,
                                phase: phase,
                                activeColor: colors.wavyActive, // :1907
                                trackColor: colors.wavyTrack, // :1908
                                amplitude: 2.4, // :1909
                                wavelength: 11, // :1910
                                lineWidth: 2.5, // :1911
                              ),
                            ),
                          ),
                        ),
                      )
                    : _FlatProgress(
                        progress: progress,
                        track: colors.progressTrack, // :1917 白@0.20
                        fill: colors.progressFill, // :1924 白@0.82
                      ),
              ),
            // 时间双端（:1927-1944）：轨下 4、高 11、8px 白@0.60。
            if (safeLength != null && safeLength! > Duration.zero)
              Positioned(
                left: 0,
                right: 0,
                top: h / 2 - 22 - 8 + 14 * 1.2 + 3 + 10 * 1.2 + 12 + 5 + 4,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      _KosMusicCardState._formatTime(position), // :1934
                      style: TextStyle(
                        color: colors.timeInk,
                        fontSize: 8, // :1936
                        height: 1,
                      ),
                    ),
                    Text(
                      _KosMusicCardState._formatTime(safeLength!), // :1940
                      style: TextStyle(
                        color: colors.timeInk,
                        fontSize: 8,
                        height: 1,
                      ),
                    ),
                  ],
                ),
              ),
            // 控制行（:1945-1979）：底 2、高 36、间距 10。
            Positioned(
              left: 0,
              right: 0,
              bottom: 2, // :1950
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _MediaButton(
                    primary: false,
                    glyph: Icons.skip_previous, // media-previous
                    enabled: hasPlayer && (media?.canGoPrevious ?? false),
                    ink: colors.controlInk,
                    fill: colors.controlFill,
                    onTap: () => commands?.previous(), // :1975
                  ),
                  const SizedBox(width: 10), // :1953 spacing
                  _MediaButton(
                    primary: true, // :1959 index===1
                    // :1963 isPlaying→pause else play。
                    glyph: (media?.playing ?? false)
                        ? Icons.pause
                        : Icons.play_arrow,
                    enabled:
                        hasPlayer &&
                        ((media?.canPlay ?? false) ||
                            (media?.canPause ?? false)), // :1970
                    ink: colors.controlInkPrimary, // :14-16 主钮图标压容器
                    fill: colors.controlFillPrimary,
                    onTap: () => commands?.playPause(), // :1976
                  ),
                  const SizedBox(width: 10),
                  _MediaButton(
                    primary: false,
                    glyph: Icons.skip_next, // media-next
                    enabled: hasPlayer && (media?.canGoNext ?? false),
                    ink: colors.controlInk,
                    fill: colors.controlFill,
                    onTap: () => commands?.next(), // :1977
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

/// `MediaControlButton`（common/MediaControlButton.qml:6-76）近似：
/// 36px 热区、内圆 `max(16, 36-(primary?2:6))`、primary→深色填充/
/// 其余浅填充、禁用透明度 0.32、按下缩 0.94（本端用比例动画近似）。
class _MediaButton extends StatefulWidget {
  const _MediaButton({
    required this.primary,
    required this.glyph,
    required this.enabled,
    required this.ink,
    required this.fill,
    this.onTap,
  });

  final bool primary;
  final IconData glyph;
  final bool enabled;
  final Color ink;
  final Color fill;
  final VoidCallback? onTap;

  @override
  State<_MediaButton> createState() => _MediaButtonState();
}

class _MediaButtonState extends State<_MediaButton> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    // MediaControlButton.qml:12 iconSize 16/18；:36 圆盘尺寸。
    final disc = math.max(16.0, 36.0 - (widget.primary ? 2 : 6));
    final iconSize = widget.primary ? 18.0 : 16.0;
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
        opacity: widget.enabled ? 1 : 0.32, // :27
        child: SizedBox(
          width: 36, // :22 implicitWidth
          height: 36, // :23
          child: Center(
            child: AnimatedScale(
              scale: _down ? 0.94 : 1, // :38 down→0.94
              duration: const Duration(milliseconds: 100), // :40
              curve: Curves.easeOutCubic,
              child: Container(
                width: disc,
                height: disc,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: widget.fill, // :45 fill
                ),
                alignment: Alignment.center,
                child: Icon(widget.glyph, color: widget.ink, size: iconSize),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 非 material 进度：白@0.20 轨 + 白@0.82 填充圆角条（:1913-1925）。
class _FlatProgress extends StatelessWidget {
  const _FlatProgress({
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
                  borderRadius: BorderRadius.circular(2.5), // :1916 h/2
                  color: track,
                ),
              ),
            ),
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              width: constraints.maxWidth * progress, // :1920
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(2.5), // :1923
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

/// `WavyProgress.qml`（common/WavyProgress.qml:29-58）逐行移植：
/// track 直段自 progressX 到右缘；active 波形 y=centerY+
/// sin(x/λ·2π+phase)·amplitude·envelope(x/5 与 (progressX-x)/5 斜坡)，
/// 末端圆点 r=lineWidth·0.9。phase 由外部 AnimationController 驱动
/// （1100ms 循环）。
class _WavyProgress extends StatelessWidget {
  const _WavyProgress({
    required this.value,
    required this.phase,
    required this.activeColor,
    required this.trackColor,
    required this.amplitude,
    required this.wavelength,
    required this.lineWidth,
  });

  final double value;
  final AnimationController phase;
  final Color activeColor;
  final Color trackColor;
  final double amplitude;
  final double wavelength;
  final double lineWidth;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: phase,
      builder: (context, child) => CustomPaint(
        painter: _WavyProgressPainter(
          value: value,
          phase: phase.value * math.pi * 2, // WavyProgress.qml:24 0→2π
          activeColor: activeColor,
          trackColor: trackColor,
          amplitude: amplitude,
          wavelength: wavelength,
          lineWidth: lineWidth,
        ),
      ),
    );
  }
}

class _WavyProgressPainter extends CustomPainter {
  const _WavyProgressPainter({
    required this.value,
    required this.phase,
    required this.activeColor,
    required this.trackColor,
    required this.amplitude,
    required this.wavelength,
    required this.lineWidth,
  });

  final double value;
  final double phase;
  final Color activeColor;
  final Color trackColor;
  final double amplitude;
  final double wavelength;
  final double lineWidth;

  @override
  void paint(Canvas canvas, Size size) {
    // WavyProgress.qml:32-40 轨段。
    final centerY = size.height / 2;
    final progressX = (size.width * value)
        .clamp(0.0, size.width)
        .toDouble(); // :33
    final trackPaint = Paint()
      ..color = trackColor
      ..strokeWidth = lineWidth
      ..strokeCap = StrokeCap.round; // :34
    canvas.drawLine(
      Offset(progressX, centerY),
      Offset(size.width, centerY),
      trackPaint,
    );
    if (progressX <= 0) return; // :42-43
    // :45-53 active 波形。
    final wave = Path();
    for (var x = 0.0; x <= progressX; x += 1) {
      final envelope = math.min(1, math.min(x / 5, (progressX - x) / 5)); // :47
      final y =
          centerY +
          math.sin(x / wavelength * math.pi * 2 + phase) *
              amplitude *
              math.max(0, envelope); // :48-49
      if (x == 0) {
        wave.moveTo(x, y);
      } else {
        wave.lineTo(x, y);
      }
    }
    canvas.drawPath(
      wave,
      Paint()
        ..color = activeColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = lineWidth
        ..strokeCap = StrokeCap.round,
    );
    // :54-57 末端圆点。
    canvas.drawCircle(
      Offset(progressX, centerY),
      lineWidth * 0.9,
      Paint()..color = activeColor,
    );
  }

  @override
  bool shouldRepaint(covariant _WavyProgressPainter oldDelegate) =>
      oldDelegate.value != value ||
      oldDelegate.phase != phase ||
      oldDelegate.activeColor != activeColor ||
      oldDelegate.trackColor != trackColor ||
      oldDelegate.amplitude != amplitude ||
      oldDelegate.wavelength != wavelength ||
      oldDelegate.lineWidth != lineWidth;
}
