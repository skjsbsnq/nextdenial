import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';

/// Decode artwork to its physical display size, preserving its aspect ratio.
/// Buckets avoid creating a new cached texture for each layout animation frame.
class ArtworkImage extends StatefulWidget {
  const ArtworkImage({required this.bytes, this.extent, super.key});

  final Uint8List bytes;
  final double? extent;

  @override
  State<ArtworkImage> createState() => _ArtworkImageState();
}

class _ArtworkImageState extends State<ArtworkImage> {
  ResizeImage? _provider;

  void _evict(ResizeImage provider) {
    unawaited(
      provider.obtainKey(ImageConfiguration.empty).then((key) {
        if (_provider == provider) return;
        // Only release the cache's keep-alive reference. Another visible card
        // may still use this artwork and must retain its live image stream.
        PaintingBinding.instance.imageCache.evict(key, includeLive: false);
      }),
    );
  }

  @override
  void dispose() {
    final previous = _provider;
    _provider = null;
    if (previous != null) _evict(previous);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final logicalExtent =
          widget.extent ??
          (constraints.maxWidth > constraints.maxHeight
              ? constraints.maxWidth
              : constraints.maxHeight);
      final physicalExtent =
          logicalExtent * MediaQuery.devicePixelRatioOf(context);
      // Cap decoded extent at 1024 physical pixels to bound texture memory.
      final decodeExtent = physicalExtent.isFinite && physicalExtent > 0
          ? ((physicalExtent / 32).ceil() * 32).clamp(32, 1024)
          : 256;
      final provider = ResizeImage(
        MemoryImage(widget.bytes),
        width: decodeExtent,
        height: decodeExtent,
        policy: ResizeImagePolicy.fit,
        allowUpscaling: false,
      );
      if (_provider != provider) {
        final previous = _provider;
        _provider = provider;
        if (previous != null) _evict(previous);
      }
      return Image(
        image: _provider!,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        filterQuality: FilterQuality.medium,
      );
    },
  );
}
