import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kos_dock/src/widgets/artwork_image.dart';

Future<Object> _decodedKey(Image image) async {
  final key = await image.image.obtainKey(ImageConfiguration.empty);
  final completed = Completer<ImageInfo>();
  final stream = image.image.resolve(ImageConfiguration.empty);
  final listener = ImageStreamListener(
    (info, _) => completed.complete(info),
    onError: (Object error, StackTrace? trace) =>
        completed.completeError(error, trace),
  );
  stream.addListener(listener);
  try {
    final decoded = await completed.future;
    expect(decoded.image.width, 160);
    expect(decoded.image.height, 80);
    decoded.dispose();
  } finally {
    stream.removeListener(listener);
  }
  return key;
}

Future<void> _pumpArtwork(WidgetTester tester, Uint8List bytes) =>
    tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(devicePixelRatio: 2),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: SizedBox(
              width: 80,
              height: 80,
              child: ArtworkImage(bytes: bytes, extent: 80),
            ),
          ),
        ),
      ),
    );

void main() {
  testWidgets(
    'artwork decode follows DPR, preserves aspect ratio and releases old caches',
    (tester) async {
      late Uint8List bytes;
      await tester.runAsync(() async {
        final recorder = ui.PictureRecorder();
        ui.Canvas(recorder)
            .drawColor(const ui.Color(0xFF123456), ui.BlendMode.src);
        final picture = recorder.endRecording();
        final source = await picture.toImage(1024, 512);
        bytes = (await source.toByteData(format: ui.ImageByteFormat.png))!
            .buffer
            .asUint8List();
        source.dispose();
        picture.dispose();
      });
      await _pumpArtwork(tester, bytes);
      late Object oldKey;
      await tester.runAsync(() async {
        oldKey = await _decodedKey(tester.widget<Image>(find.byType(Image)));
      });
      // Same encoded contents, different bytes identity: a new song's artwork.
      await _pumpArtwork(tester, Uint8List.fromList(bytes));
      await tester.pump();
      expect(PaintingBinding.instance.imageCache.containsKey(oldKey), isFalse);
      late Object newKey;
      await tester.runAsync(() async {
        newKey = await _decodedKey(tester.widget<Image>(find.byType(Image)));
      });
      // 1024*512*4 -> 160*80*4: 40.96 times less decoded RGBA storage.
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(PaintingBinding.instance.imageCache.containsKey(newKey), isFalse);
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
    },
  );
}
