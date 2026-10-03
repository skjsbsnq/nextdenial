/// MPRIS player matching and control gating — the pure-Dart half of the dock
/// media bar, ported from `Common/functions/DockMedia.js:3-16` and the gating
/// expressions of `Modules/Dock/DockWindowCard.qml:144-170`.
///
/// Split out from `media_bar.dart` so the predicates stay free of any
/// `package:flutter/*` import and can be unit tested with plain `dart test`;
/// the widget layer imports and re-exports them.
library;

import 'package:denial_sdk/system.dart' show MprisPlaybackState;

import 'dock_store.dart' show dockDesktopId;

/// `.desktop` section of an MPRIS bus name — `org.mpris.MediaPlayer2.<suffix>`
/// (card §B).
String dockMediaServiceSuffix(String serviceName) {
  const prefix = 'org.mpris.MediaPlayer2.';
  return serviceName.startsWith(prefix)
      ? serviceName.substring(prefix.length)
      : serviceName;
}

/// `matchingPlayers(...)` predicate (`DockMedia.js:9-12`).
///
/// The source compares the player's `desktopEntry` with the dock entry's
/// `appId` after [dockDesktopId]; Denial has no `desktopEntry`, so the identity
/// and the MPRIS bus-name suffix are checked instead. Matching is exact — no
/// case folding or fuzzy comparison (source has none); an empty [appId] never
/// matches (`DockMedia.js:11`).
bool dockMediaMatches(MprisPlaybackState player, String appId) {
  final id = dockDesktopId(appId);
  if (id.isEmpty) return false;
  final identity = dockDesktopId(player.identity);
  if (identity.isNotEmpty && identity == id) return true;
  final service = dockDesktopId(dockMediaServiceSuffix(player.serviceName));
  return service.isNotEmpty && service == id;
}

/// `selectPlayer(matches, current)` (`DockMedia.js:14-16`): keep the current
/// player while it is still a member of [matches], otherwise take the first —
/// `null` when there are no matches.
MprisPlaybackState? dockSelectPlayer(
  List<MprisPlaybackState> matches,
  MprisPlaybackState? current,
) {
  if (current != null && matches.contains(current)) return current;
  return matches.isEmpty ? null : matches.first;
}

/// `canControl && canGoPrevious` (`DockWindowCard.qml:149-150`); `canControl`
/// approximated by [MprisPlaybackState.available].
bool dockMediaCanGoPrevious(MprisPlaybackState? player) =>
    player != null && player.available && player.canGoPrevious;

/// `canControl && canTogglePlaying` (`:158-159`): the SDK splits playback into
/// `canPlay`/`canPause`, so toggling is possible when either is set.
bool dockMediaCanToggle(MprisPlaybackState? player) =>
    player != null && player.available && (player.canPlay || player.canPause);

/// `canControl && canGoNext` (`:167-168`).
bool dockMediaCanGoNext(MprisPlaybackState? player) =>
    player != null && player.available && player.canGoNext;
