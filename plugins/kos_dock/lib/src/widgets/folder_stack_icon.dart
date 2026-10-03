/// DockFolderStackIcon — the dock-side `display == "stack"` artwork for a
/// folder entry (`DockFileArtwork.qml:33-62`): the first `min(3, count)`
/// app icons stacked with a 9° fan.
///
/// Per layer (`Repeater` :47-59): width `parent × 0.85`, centred then
/// `x += index·2`, `y −= index·3`, `rotation = (index−1)·9°`, `z = 3−index`
/// (painter order — index 0 paints last/on top). `count == 0` falls back
/// to a single folder icon (:33 — the plain `DockFileIcon` branch).
library;

import 'dart:math' as math;

import 'package:denial_flutter_sdk/services.dart';
import 'package:flutter/material.dart';

/// Stacked-app artwork for a `display == "stack"` folder dock entry.
class DockFolderStackIcon extends StatelessWidget {
  const DockFolderStackIcon({required this.appIds, super.key});

  /// App icon identities, dock order — the first `min(3, count)` stack
  /// (:48 `Math.min(3, folder.count)`).
  final List<String> appIds;

  /// `Math.min(3, folder.count)` (:48).
  static int stackLayers(int count) => math.min(3, count);

  @override
  Widget build(BuildContext context) {
    final services = ShellServicesScope.of(context);
    final layers = stackLayers(appIds.length);
    return LayoutBuilder(
      builder: (context, constraints) {
        if (layers == 0) {
          // :33 — count==0 falls back to the plain folder icon.
          return Icon(
            Icons.folder,
            size: constraints.biggest.shortestSide,
            color: Theme.of(context).colorScheme.onSurface,
          );
        }
        // :53 — each layer is 85% of the parent edge.
        final side = constraints.biggest.shortestSide * 0.85;
        return Stack(
          clipBehavior: Clip.none,
          children: [
            // z = 3 − index (:58): index 0 paints last (on top).
            for (var index = layers - 1; index >= 0; --index)
              Positioned(
                // :55-56 — centred, then index*2 right / index*3 up.
                left:
                    (constraints.maxWidth - side) / 2 +
                    index * 2 -
                    (constraints.maxWidth - constraints.biggest.shortestSide) /
                        2,
                top:
                    (constraints.biggest.shortestSide - side) / 2 -
                    index * 3 +
                    (constraints.maxHeight - constraints.biggest.shortestSide) /
                        2,
                width: side,
                height: side,
                child: Transform.rotate(
                  // :57 — (index−1)·9°.
                  angle: (index - 1) * 9 * math.pi / 180,
                  child: services.buildApplicationIcon(
                    context,
                    appIds[index],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}
