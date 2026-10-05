/// MPRIS 封面 `artUrl` → `ShellServices.imageBytes` 可消费的本地路径。
///
/// SDK 保证 `artUrl` 只可能是 `file:`/`http:`/`https:` URI
/// （`platform/bridge/mpris_playback_protocol.dart:200-207` `_safeArtworkUrl`），
/// 而 `imageBytes` 是**裸文件路径**加载器（宿主
/// `denial_desktop` `core/shell_plugin_services.dart:247-248` →
/// `notificationStaticImageProvider` → `File(path)`）——直接把 URI 喂进去恒
/// 为 null（封面永远占位）。故 `file:` 剥成路径、http(s)/空/非 file scheme
/// 返回 null（KOS 侧 `Image` 直抓 http，本端不抓，记
/// docs/visual-deltas.md）。
///
/// 音乐卡（`info_carousel.dart`）先有此范式，抽成本件供控制中心媒体卡复用。
library;

/// `artUrl` → 本地路径；`file:` URI 与裸绝对路径透出、其余（http(s)/空/
/// 未知 scheme）→ null。
String? dockLocalArtPath(String artUrl) {
  if (artUrl.isEmpty) return null;
  final uri = Uri.tryParse(artUrl);
  return switch (uri?.scheme) {
    // `file:///x` / `file:/x` → 本地路径（顺带 percent 解码）。
    'file' => uri!.toFilePath(),
    // 裸路径（兼容档；SDK 只保证 file/http/https URI）。
    null || '' => artUrl.startsWith('/') ? artUrl : null,
    // http(s)/其它 scheme：`imageBytes` 无网络通道。
    _ => null,
  };
}
