import 'package:denial_flutter_sdk/effects.dart' show ShellBackdropBlur;
import 'package:denial_flutter_sdk/glass_configuration.dart'
    show ShellTransparencyMode;
import 'package:denial_flutter_sdk/shell_theme.dart';
import 'package:flutter/widgets.dart';

/// Dock glass keeps controls out of the backdrop filter's intermediate layer.
/// Pills can clip the backdrop to the same rounded shape as the foreground,
/// so a glass replacement cannot affect rectangular filter-bound corners.
/// Foreground geometry gets its own saveLayer,
/// allowing the renderer to use offscreen MSAA without isolating the backdrop.
class DockBackdropBlur extends StatelessWidget {
  const DockBackdropBlur({
    required this.child,
    required this.blur,
    required this.borderRadius,
    this.opacity,
    this.clipBackdropToRadius = false,
    this.glassBlendMode = BlendMode.src,
    super.key,
  });

  final Widget child;
  final bool blur;
  final BorderRadiusGeometry borderRadius;
  final Animation<double>? opacity;

  /// Constrain small rounded pills without changing other dock surfaces.
  final bool clipBackdropToRadius;

  /// Static glass compositing; fades always composite with srcOver.
  final BlendMode glassBlendMode;

  @override
  Widget build(BuildContext context) {
    final theme = ShellTheme.of(context);
    if (!blur || theme.transparencyMode != ShellTransparencyMode.glass) {
      return ShellBackdropBlur(
        blur: blur,
        separateChild: true,
        borderRadius: borderRadius,
        opacity: opacity,
        child: child,
      );
    }

    final radius = borderRadius.resolve(Directionality.of(context));
    Widget fade(Widget value) => opacity == null
        ? value
        : FadeTransition(opacity: opacity!, child: value);
    final content = Stack(
      fit: StackFit.passthrough,
      children: [
        Positioned.fill(
          child: fade(
            BackdropFilter(
              filterConfig: theme.backdropFilterConfigAt(
                1,
                borderRadius: radius,
              ),
              blendMode: opacity == null ? glassBlendMode : BlendMode.srcOver,
              child: const SizedBox.expand(),
            ),
          ),
        ),
        // The filter above still reads the actual scene. Only controls and
        // their decoration enter this transparent offscreen target.
        fade(
          ClipRRect(
            borderRadius: radius,
            clipBehavior: Clip.antiAliasWithSaveLayer,
            child: child,
          ),
        ),
      ],
    );
    return clipBackdropToRadius
        ? ClipRRect(
            borderRadius: radius,
            clipBehavior: Clip.antiAlias,
            child: content,
          )
        : ClipRect(child: content);
  }
}
