/// MPRIS media bar — the floating prev / play-pause / next control strip
/// rendered at the bottom of a dock window-preview card.
///
/// Ported from quickshell `Modules/Dock/DockWindowCard.qml:124-172`
/// (`mediaControls`, anchors cited inline):
/// - 36px tall, radius 8, `colSurfaceContainer @ 0.94` (`:130-133`);
/// - centred on the card bottom with a 4px bottom margin (`:126-128`), which
///   the host preview card applies;
/// - three `IconButton`s, control size 32, icon sizes 20/22/20
///   (`:144-170`): previous gated by `canControl && canGoPrevious`, play-pause
///   by `canControl && canTogglePlaying` (icon toggles on `isPlaying`), next by
///   `canControl && canGoNext`;
/// - it wraps the bar in an opaque hit region so no media click falls through
///   to the window-preview tap behind it (`:135-140`).
///
/// Player selection follows `Common/functions/DockMedia.js:3-16`:
/// `matchingPlayers` compares `desktopId(player.desktopEntry)` with
/// `desktopId(appId)` and `selectPlayer` keeps the current player while it
/// still matches, otherwise takes the first.
///
/// Denial differences (recorded in `docs/visual-deltas.md`):
/// - the SDK has no `desktopEntry`/`canControl`: matching approximates the
///   source with `desktopId(identity) == appId` or
///   `desktopId(org.mpris.MediaPlayer2.<suffix>) == appId`, and gating
///   approximates `canControl` with `available && can*`;
/// - the bar colour folds `@0.94` into [`ShellThemeData.cardColor`] like the
///   dock glass, so the material follows the shell transparency settings.
library;

import 'package:denial_flutter_sdk/services.dart';
import 'package:denial_flutter_sdk/theme.dart';
import 'package:denial_sdk/system.dart' show MprisPlaybackState;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;

import '../data/dock_media.dart';

// The pure matcher/gating predicates live in `../data/dock_media.dart`
// (no Flutter dependency, plain `dart test`); re-export them so callers can
// keep importing this widget library.
export '../data/dock_media.dart';

/// Play-pause glyph follows `isPlaying` (`DockWindowCard.qml:156`): `pause`
/// while playing, `play_arrow` otherwise.
IconData dockMediaToggleIcon(MprisPlaybackState player) =>
    player.playing ? Icons.pause : Icons.play_arrow;

/// The media bar widget; renders nothing until a player matching [appId]
/// exists (`DockWindowCard.qml:132`).
class DockMediaBar extends ConsumerWidget {
  const DockMediaBar({
    required this.appId,
    super.key,
    this.media,
    this.mediaCommands,
    this.show = true,
  });

  /// Dock entry `appId` the player must match (`DockMedia.js:9-12`).
  final String appId;

  /// Playback state listenable; `null` uses `services.media`
  /// (`services.dart:116`).
  final ProviderListenable<AsyncValue<MprisPlaybackState>>? media;

  /// Command listenable; `null` uses `services.mediaCommands`
  /// (`services.dart:117`).
  final ProviderListenable<MediaCommands>? mediaCommands;

  /// Host gate (e.g. the preview card hides controls while dragging).
  final bool show;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!show) return const SizedBox.shrink();
    final scope = context
        .dependOnInheritedWidgetOfExactType<ShellServicesScope>();
    final mediaListenable = media ?? scope?.services.media;
    final state = mediaListenable == null
        ? null
        : ref.watch(mediaListenable).value;
    final player = (state != null && dockMediaMatches(state, appId))
        ? state
        : null;
    if (player == null) return const SizedBox.shrink(); // :132
    final commandsListenable = mediaCommands ?? scope?.services.mediaCommands;
    final commands = commandsListenable == null
        ? null
        : ref.watch(commandsListenable);
    final strings = scope?.services.strings(context);

    final colors = Theme.of(context).colorScheme;
    final shell = context.shellTheme;
    final canPrevious = dockMediaCanGoPrevious(player);
    final canToggle = dockMediaCanToggle(player);
    final canNext = dockMediaCanGoNext(player);

    // Bottom-centred inside the host's bottom slot (`:126-128`); the opaque
    // ribbon (`:135-140`) shrink-wraps to the bar so it consumes only its own
    // gaps and disabled buttons — a media click never activates the window
    // behind it, while the rest of the card stays tappable.
    return Align(
      alignment: Alignment.bottomCenter,
      child: Listener(
        behavior: HitTestBehavior.opaque,
        child: Material(
          // :133 — colSurfaceContainer @ 0.94; cardColor (@0.95) is the
          // closest shell card opacity, matching the dock glass.
          color: shell.cardColor(colors.surfaceContainer),
          borderRadius: BorderRadius.circular(kDockMediaBarRadius), // :131
          clipBehavior: Clip.antiAlias,
          child: SizedBox(
            height: kDockMediaBarHeight, // :130
            // :129 — width = buttons + 8px, split 4px either side of the row.
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  _MediaButton(
                    icon: Icons.skip_previous,
                    iconSize: 20,
                    tooltip: strings?.mediaPrevious,
                    onPressed: canPrevious ? commands?.previous : null,
                  ),
                  _MediaButton(
                    icon: dockMediaToggleIcon(player), // :156
                    iconSize: 22,
                    tooltip: player.playing
                        ? strings?.mediaPause
                        : strings?.mediaPlay, // :157
                    onPressed: canToggle ? commands?.playPause : null,
                  ),
                  _MediaButton(
                    icon: Icons.skip_next,
                    iconSize: 20,
                    tooltip: strings?.mediaNext,
                    onPressed: canNext ? commands?.next : null,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Bar height (`DockWindowCard.qml:130`).
const double kDockMediaBarHeight = 36;

/// Bar corner radius (`DockWindowCard.qml:131`).
const double kDockMediaBarRadius = 8;

/// Button `controlSize` (`DockWindowCard.qml:145/155/164`).
const double kDockMediaBarControlSize = 32;

/// One 32px control button (`DockWindowCard.qml:144-170`).
class _MediaButton extends StatelessWidget {
  const _MediaButton({
    required this.icon,
    required this.iconSize,
    required this.onPressed,
    this.tooltip,
  });

  final IconData icon;
  final double iconSize;
  final VoidCallback? onPressed;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    // `controlSize: 32` (`DockWindowCard.qml:145/155/164`): an explicit box
    // pins the Material button to exactly 32×32 regardless of M3 density.
    return SizedBox(
      width: kDockMediaBarControlSize,
      height: kDockMediaBarControlSize,
      child: IconButton(
        onPressed: onPressed,
        tooltip: tooltip,
        icon: Icon(icon, size: iconSize),
        iconSize: iconSize, // :145/155/164
        padding: EdgeInsets.zero,
        style: IconButton.styleFrom(
          padding: EdgeInsets.zero,
          minimumSize: const Size.square(kDockMediaBarControlSize),
          maximumSize: const Size.square(kDockMediaBarControlSize),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      ),
    );
  }
}
