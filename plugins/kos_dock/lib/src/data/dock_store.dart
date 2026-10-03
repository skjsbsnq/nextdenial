/// `dock.json` persistence — pure-Dart port of `Common/functions/DockModel.js`
/// (schema 1) plus the XDG trash approximation for the dock's trash entry.
///
/// Line anchors below are into quickshell `Common/functions/DockModel.js`
/// unless another source file is named. Field names, value domains, defaults
/// and the strict "any invalid field → whole document decodes to null"
/// semantics are kept 1:1 with the source; only the storage path, the dropped
/// `file` kind and the Dart-typed representation differ.
///
/// No `package:flutter/*` import: the whole file runs under plain
/// `dart test` and file IO uses the synchronous `dart:io` API so plain
/// `test()` cases never touch the Flutter fake-async zone.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:io' as io show pid;

/// Default dock position (`DockModel.js:5` `position: "bottom"`).
enum DockPosition {
  bottom,
  left,
  right;

  /// Wire name used inside `options.position` (`DockModel.js:34`).
  String get wireName => name;

  static DockPosition? fromWire(Object? value) => switch (value) {
    'bottom' => DockPosition.bottom,
    'left' => DockPosition.left,
    'right' => DockPosition.right,
    _ => null,
  };
}

/// Strips a trailing `.desktop` suffix and trims (`DockMedia.js:3-6`,
/// `DockModel.js:20-23`). Shared by the store and the media-bar matcher.
String dockDesktopId(Object? value) {
  final id = (value is String ? value : '').trim();
  return id.endsWith('.desktop') ? id.substring(0, id.length - 8) : id;
}

/// `validDesktopId` (`DockModel.js:25-28`): non-empty, already trimmed,
/// ≤ 512 chars, no control chars and no `/`/`\`, with a non-empty
/// [dockDesktopId].
bool validDockDesktopId(Object? value) {
  if (value is! String) return false;
  if (value.isEmpty || value.trim() != value) return false;
  if (value.length > 512) return false;
  if (RegExp(r'[\u0000-\u001f/\\]').hasMatch(value)) return false;
  return dockDesktopId(value).isNotEmpty;
}

/// `validFileUrl` (`DockModel.js:92-95`): `file:///` prefix, no `?`/`#`/
/// control characters and no NUL after percent-decoding.
bool validDockFileUrl(Object? value) {
  if (value is! String) return false;
  if (!value.startsWith('file:///')) return false;
  if (RegExp(r'[?#\u0000-\u001f]').hasMatch(value)) return false;
  try {
    return !Uri.decodeComponent(value).contains('\u0000');
  } on Object {
    return false;
  }
}

/// Spacer id pattern (`DockModel.js:67-69`).
final RegExp _spacerIdPattern = RegExp(r'^[A-Za-z0-9_-]{1,80}$');

/// `options` (DockModel.js:3-18), 12 typed fields with the source defaults.
final class DockOptions {
  const DockOptions({
    this.enabled = true,
    this.position = DockPosition.bottom,
    this.iconSize = 48,
    this.magnification = true,
    this.magnificationScale = 1.5,
    this.autoHide = false,
    this.launchBounce = true,
    this.showIndicators = true,
    this.showRecent = true,
    this.showThumbnails = true,
    this.previewSize = 160,
    this.contextPinning = true,
  });

  final bool enabled;
  final DockPosition position;

  /// `iconSize` — integer, clamped to 32–80 (`DockModel.js:37`).
  final int iconSize;
  final bool magnification;

  /// `magnificationScale` — clamped to 1–2 (`DockModel.js:38`).
  final double magnificationScale;
  final bool autoHide;
  final bool launchBounce;
  final bool showIndicators;
  final bool showRecent;
  final bool showThumbnails;

  /// `previewSize` — integer, clamped to 96–240 (`DockModel.js:36`).
  final int previewSize;
  final bool contextPinning;

  /// `defaults()` (DockModel.js:3-18).
  static const DockOptions defaults = DockOptions();

  DockOptions copyWith({
    bool? enabled,
    DockPosition? position,
    int? iconSize,
    bool? magnification,
    double? magnificationScale,
    bool? autoHide,
    bool? launchBounce,
    bool? showIndicators,
    bool? showRecent,
    bool? showThumbnails,
    int? previewSize,
    bool? contextPinning,
  }) => DockOptions(
    enabled: enabled ?? this.enabled,
    position: position ?? this.position,
    iconSize: iconSize ?? this.iconSize,
    magnification: magnification ?? this.magnification,
    magnificationScale: magnificationScale ?? this.magnificationScale,
    autoHide: autoHide ?? this.autoHide,
    launchBounce: launchBounce ?? this.launchBounce,
    showIndicators: showIndicators ?? this.showIndicators,
    showRecent: showRecent ?? this.showRecent,
    showThumbnails: showThumbnails ?? this.showThumbnails,
    previewSize: previewSize ?? this.previewSize,
    contextPinning: contextPinning ?? this.contextPinning,
  );

  /// Serializes in the source's `defaults()` key order.
  Map<String, Object?> toJson() => <String, Object?>{
    'enabled': enabled,
    'position': position.wireName,
    'iconSize': iconSize,
    'magnification': magnification,
    'magnificationScale': magnificationScale,
    'autoHide': autoHide,
    'launchBounce': launchBounce,
    'showIndicators': showIndicators,
    'showRecent': showRecent,
    'showThumbnails': showThumbnails,
    'previewSize': previewSize,
    'contextPinning': contextPinning,
  };

  /// `option()` + the `decodeConfig` options loop (DockModel.js:30-59).
  ///
  /// Starts from [defaults], then validates every key present in [json]:
  /// unknown names, wrong types and out-of-domain values all return `null`
  /// (the caller then rejects the whole document). The legacy
  /// `separatorSize` key is tolerated only as a finite number and dropped
  /// (`DockModel.js:52-54`).
  static DockOptions? fromJson(Map<Object?, Object?> json) {
    final values = defaults.toJson();
    for (final entry in json.entries) {
      final name = entry.key;
      if (name is! String) return null;
      if (name == 'separatorSize') {
        final value = entry.value;
        if (value is! num || !value.isFinite) return null;
        continue;
      }
      if (!values.containsKey(name)) return null;
      final normalized = _normalizeOption(name, entry.value);
      if (normalized == null) return null;
      values[name] = normalized;
    }
    return DockOptions(
      enabled: values['enabled']! as bool,
      position: DockPosition.fromWire(values['position'])!,
      iconSize: values['iconSize']! as int,
      magnification: values['magnification']! as bool,
      magnificationScale: (values['magnificationScale']! as num).toDouble(),
      autoHide: values['autoHide']! as bool,
      launchBounce: values['launchBounce']! as bool,
      showIndicators: values['showIndicators']! as bool,
      showRecent: values['showRecent']! as bool,
      showThumbnails: values['showThumbnails']! as bool,
      previewSize: values['previewSize']! as int,
      contextPinning: values['contextPinning']! as bool,
    );
  }

  /// `option(name, value)` (DockModel.js:30-40); `null` == `undefined`.
  static Object? _normalizeOption(String name, Object? value) {
    final standard = defaults.toJson()[name];
    if (standard is bool) return value is bool ? value : null;
    if (name == 'position') {
      return DockPosition.fromWire(value) != null ? value : null;
    }
    if (value is! num || !value.isFinite) return null;
    if (name == 'previewSize') {
      return value.round().clamp(96, 240).toInt();
    }
    if (name == 'iconSize') return value.round().clamp(32, 80).toInt();
    if (name == 'magnificationScale') {
      return value.clamp(1.0, 2.0).toDouble();
    }
    return null;
  }
}

/// One `pinned` entry — `app`, `spacer`/`small-spacer` or `folder`.
///
/// The source's `file` kind is out of scope (external file drags were cut),
/// so it is treated as an unknown entry and rejects the whole document.
sealed class DockPin {
  const DockPin();

  /// `pinnedKey` (DockModel.js:98-100).
  String get pinnedKey;

  Map<String, Object?> toJson();
}

/// `{kind: "app", desktopId}` (`DockModel.js:65-66`).
final class DockAppPin extends DockPin {
  const DockAppPin({required this.desktopId});

  final String desktopId;

  @override
  String get pinnedKey => 'app:$desktopId';

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'kind': 'app',
    'desktopId': desktopId,
  };
}

/// `{kind: "spacer"|"small-spacer", id}` (`DockModel.js:67-69`).
final class DockSpacerPin extends DockPin {
  const DockSpacerPin({required this.id, this.small = false});

  final String id;

  /// `true` for `small-spacer` (half slot weight, DockLayout.js:22).
  final bool small;

  /// `spacer:<id>` — `small-spacer` shares the same key space
  /// (`DockModel.js:100`).
  @override
  String get pinnedKey => 'spacer:$id';

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'kind': small ? 'small-spacer' : 'spacer',
    'id': id,
  };
}

/// `{kind: "folder", url, view, sort, display}` (`DockModel.js:70-76`).
final class DockFolderPin extends DockPin {
  const DockFolderPin({
    required this.url,
    this.view = 'fan',
    this.sort = 'name',
    this.display = 'folder',
  });

  final String url;

  /// `fan` | `grid` | `list` (default `fan`).
  final String view;

  /// `name` | `modified` | `created` | `kind` | `size` (default `name`).
  final String sort;

  /// `stack` | `folder` (default `folder`).
  final String display;

  /// File-ish pins key on `file:<url>` and sort last (`DockModel.js:96,99`).
  @override
  String get pinnedKey => 'file:$url';

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'kind': 'folder',
    'url': url,
    'view': view,
    'sort': sort,
    'display': display,
  };
}

/// Decoded `dock.json` document (`DockModel.js:83`).
final class DockConfig {
  const DockConfig({
    this.options = DockOptions.defaults,
    this.pinned = const <DockPin>[],
  });

  final DockOptions options;
  final List<DockPin> pinned;

  /// `{schemaVersion: 1, options: defaults, pinned: []}`.
  static const DockConfig defaults = DockConfig();

  Map<String, Object?> toJson() => <String, Object?>{
    'schemaVersion': kDockSchemaVersion,
    'options': options.toJson(),
    'pinned': <Object?>[for (final pin in pinned) pin.toJson()],
  };
}

/// Pinned-entry cap (`DockModel.js:45-47`).
const int kDockMaxPinned = 128;

/// Only schema version accepted (`DockModel.js:45`).
const int kDockSchemaVersion = 1;

/// Valid `folder.view` values (`DockModel.js:73`).
const List<String> kDockFolderViews = <String>['fan', 'grid', 'list'];

/// Valid `folder.sort` values (`DockModel.js:74`).
const List<String> kDockFolderSorts = <String>[
  'name',
  'modified',
  'created',
  'kind',
  'size',
];

/// Valid `folder.display` values (`DockModel.js:75`).
const List<String> kDockFolderDisplays = <String>['stack', 'folder'];

/// `groupPins` (DockModel.js:96): non-file pins first, folder pins last.
List<DockPin> groupDockPins(List<DockPin> pins) => <DockPin>[
  ...pins.where((pin) => pin is! DockFolderPin),
  ...pins.whereType<DockFolderPin>(),
];

/// `decodeConfig` (DockModel.js:42-87).
///
/// Returns `null` when the text is not JSON, `schemaVersion !== 1`, `pinned`
/// is not an array / exceeds [kDockMaxPinned], `options` is not an object, any
/// option or pin is invalid or an option name is unknown. The reader then
/// falls back to [DockConfig.defaults] without rewriting the user's file.
DockConfig? decodeDockConfig(String text) {
  Object? value;
  try {
    value = jsonDecode(text);
  } on Object {
    return null;
  }
  if (value is! Map) return null;
  if (value['schemaVersion'] != kDockSchemaVersion) return null;
  final pinnedRaw = value['pinned'];
  if (pinnedRaw is! List || pinnedRaw.length > kDockMaxPinned) return null;
  final optionsRaw = value['options'];
  if (optionsRaw is! Map) return null;
  final options = DockOptions.fromJson(optionsRaw.cast<Object?, Object?>());
  if (options == null) return null;
  final pins = <DockPin>[];
  final keys = <String>{};
  for (final entry in pinnedRaw) {
    final pin = _decodeDockPin(entry);
    if (pin == null) return null;
    if (!keys.add(pin.pinnedKey)) return null; // duplicate pinnedKey :79-80
    pins.add(pin);
  }
  return DockConfig(options: options, pinned: groupDockPins(pins));
}

/// One `pinned` entry (`DockModel.js:62-81`); `null` rejects the document.
DockPin? _decodeDockPin(Object? entry) {
  if (entry is! Map) return null;
  final kind = entry['kind'];
  if (kind == 'app') {
    final value = entry['desktopId'];
    if (!validDockDesktopId(value)) return null;
    return DockAppPin(desktopId: dockDesktopId(value));
  }
  // The legacy `separator` kind normalizes to a full spacer (`:69`).
  if (kind == 'spacer' || kind == 'small-spacer' || kind == 'separator') {
    final id = entry['id'];
    if (id is! String || !_spacerIdPattern.hasMatch(id)) return null;
    return DockSpacerPin(id: id, small: kind == 'small-spacer');
  }
  if (kind == 'folder') {
    final url = entry['url'];
    if (!validDockFileUrl(url)) return null;
    return DockFolderPin(
      url: url! as String,
      view: _oneOf(entry['view'], kDockFolderViews, 'fan'),
      sort: _oneOf(entry['sort'], kDockFolderSorts, 'name'),
      display: _oneOf(entry['display'], kDockFolderDisplays, 'folder'),
    );
  }
  return null; // unknown kind — including the out-of-scope `file`
}

String _oneOf(Object? value, List<String> allowed, String fallback) =>
    value is String && allowed.contains(value) ? value : fallback;

/// Atomic `dock.json` reader/writer.
///
/// Default path: `$XDG_CONFIG_HOME/denial/plugins/kos_dock.json` with the XDG
/// fallback `$HOME/.config/...`; when neither variable is set the constructor
/// throws a [FileSystemException].
///
/// Writes keep unknown top-level keys (so other tools can share the file),
/// write `path.<pid>.<seq>.tmp` and atomically `rename` it over the target,
/// cleaning up the temp file on any failure. Reads never write: a missing or
/// corrupt file yields [DockConfig.defaults].
final class DockStore {
  DockStore({String? path, int? pid})
    : path = path ?? defaultPath(),
      _pid = pid ?? io.pid;

  /// Resolved config file path (readable for tests / diagnostics).
  final String path;

  final int _pid;
  static int _sequence = 0;

  /// `$XDG_CONFIG_HOME/denial/plugins/kos_dock.json` (fallback
  /// `$HOME/.config`) — throws [FileSystemException] when no config home can
  /// be resolved.
  static String defaultPath({Map<String, String>? environment}) {
    final env = environment ?? Platform.environment;
    final configHome = env['XDG_CONFIG_HOME'];
    final home = env['HOME'];
    final String? base;
    if (configHome != null && configHome.isNotEmpty) {
      base = configHome;
    } else if (home != null && home.isNotEmpty) {
      base = '$home/.config';
    } else {
      base = null;
    }
    if (base == null) {
      throw const FileSystemException(
        'Cannot resolve the dock config directory: neither XDG_CONFIG_HOME '
        'nor HOME is set.',
      );
    }
    return '$base/denial/plugins/kos_dock.json';
  }

  /// Reads and validates the config; missing/corrupt files fall back to
  /// [DockConfig.defaults] and are left untouched.
  DockConfig read() {
    final String text;
    try {
      text = File(path).readAsStringSync();
    } on Object {
      return DockConfig.defaults;
    }
    return decodeDockConfig(text) ?? DockConfig.defaults;
  }

  /// Async wrapper over [read].
  Future<DockConfig> load() async => read();

  /// Atomically persists [config], preserving unknown top-level keys.
  void write(DockConfig config) {
    final file = File(path);
    file.parent.createSync(recursive: true);
    final output = <String, Object?>{};
    try {
      final existing = jsonDecode(file.readAsStringSync());
      if (existing is Map) {
        for (final entry in existing.entries) {
          final key = entry.key;
          if (key is String) output[key] = entry.value;
        }
      }
    } on Object {
      // Missing or corrupt file: no keys to preserve.
    }
    output['schemaVersion'] = kDockSchemaVersion;
    output['options'] = config.options.toJson();
    // Source `save()` persists the committed list, which always went through
    // `groupPins` (`DockModel.js:96`, DockService.qml:335); grouping here keeps
    // write → read order-stable regardless of the caller's input order.
    output['pinned'] = <Object?>[
      for (final pin in groupDockPins(config.pinned)) pin.toJson(),
    ];

    final tmp = File('$path.$_pid.${_sequence++}.tmp');
    try {
      tmp.writeAsStringSync(
        '${const JsonEncoder.withIndent('  ').convert(output)}\n',
        flush: true,
      );
      tmp.renameSync(path);
    } finally {
      if (tmp.existsSync()) tmp.deleteSync();
    }
  }

  /// Async wrapper over [write].
  Future<void> save(DockConfig config) async => write(config);
}

/// Approximation of `DesktopFiles.trashCount` (DockService.qml:237,
/// desktop_files.cpp `trash::item-count`): counts entries under the XDG trash
/// `files/` directory. Denial exposes no GIO trash channel, so a missing,
/// unreadable or unlistable directory reports `0` (→ `user-trash`).
///
/// Pure Dart and injectable: pass [filesDirectory] in tests.
int dockTrashCount({String? filesDirectory}) {
  final directory = filesDirectory ?? _defaultTrashFiles();
  if (directory == null) return 0;
  try {
    final dir = Directory(directory);
    if (!dir.existsSync()) return 0;
    return dir.listSync(followLinks: false).length;
  } on Object {
    return 0;
  }
}

String? _defaultTrashFiles() {
  final env = Platform.environment;
  final dataHome = env['XDG_DATA_HOME'];
  final home = env['HOME'];
  final String? base;
  if (dataHome != null && dataHome.isNotEmpty) {
    base = dataHome;
  } else if (home != null && home.isNotEmpty) {
    base = '$home/.local/share';
  } else {
    base = null;
  }
  return base == null ? null : '$base/Trash/files';
}
