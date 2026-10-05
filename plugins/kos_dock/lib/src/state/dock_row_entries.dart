/// KOS Dock 图标行条目推导（纯函数，TASK-04b 方案 A）。
///
/// 单一事实来源：`dock_shell.dart` 用它推导图标行自然宽
/// （`n*(slot+spacing)-spacing`），`dock_icons.dart` 用它渲染行条目——
/// 两侧共享同一份「pinned 段 + 未 pin 运行段」序列，视口宽度不再漏算
/// 运行条目（旧实现只按 `prefs.pinned` 数推导，是我方加运行条目时引入的
/// 布局回归，非 KOS 语义差异）。
///
/// - pinned 段：按 `prefs.pinned` 顺序，窗口经 `windowAppIds` 别名归一化
///   匹配到 pin（PLUGIN_DEVELOPMENT.md:420-424：先精确 appId、后别名，
///   多重匹配不猜）；
/// - 运行段：未 pin 窗口按 canonical appId 聚合「一应用一图标」，顺序取
///   首次出现顺序（KOS `dock/DockModelService.qml:150-200` grouped：
///   已 pin 的窗口 `:161` `continue` 只由 pinned 段渲染）；
/// - 去重：「既 pin 又在跑」只出现一次（pinned 段键 `app:`、运行段键
///   `run:` 不同前缀承载同一判重语义）。
library;

import 'package:denial_flutter_sdk/services.dart';

import '../data/dock_preferences.dart';

/// 归一化并剥掉宿主 launch-id 的已知 scheme 前缀（宿主 catalog 的
/// `LaunchableApplication.id`：desktop 应用形如 `desktop:<desktopFileId>`，
/// denial_desktop `shell_plugin_services.dart:85-96`；本地应用形如
/// `local:<id>`，`application_recents_controller.dart:9-12`）。持久化
/// pin.id 是去掉前缀的 desktopId（迁移态 `_decodeLegacyPin` 只存
/// desktopId），因此把 pin.id 与 catalog `id` 放同一判等系前必须先剥
/// scheme——否则 `desktop:kitty` ≠ `kitty`、`local:myapp` ≠ `myapp`，
/// launch-key 直配恒 miss。显式枚举已知 scheme（不用通用 `xxx:` 规则），
/// 避免把恰好含冒号的合法 id 剥坏。
String _normalizeLaunchId(String id) {
  var v = normalizeApplicationId(id);
  for (final scheme in const ['desktop:', 'local:']) {
    if (v.startsWith(scheme)) {
      v = v.substring(scheme.length);
      break;
    }
  }
  return v;
}

/// pinned 条目键：`app:` + normalize(pin.id)（launch id 是持久化身份，
/// PLUGIN_DEVELOPMENT.md）；窗口组按 appId normalize 聚到 pin。launch-id 段
/// 用 [_normalizeLaunchId] 剥已知 scheme（`desktop:`/`local:`），使迁移态
/// pin（bare id）与宿主 catalog `id`（带前缀）判等一致。
String dockPinEntryKey(String launchId) =>
    'app:${_normalizeLaunchId(launchId)}';

/// 运行中但未 pin 的应用聚合键（KOS grouped 的 window item，
/// `dock/DockModelService.qml:150-200`）：`run:` 前缀与 pin 键 `app:`
/// 区分，保证「既 pin 又在跑」的应用只出现一次。
String dockRunningEntryKey(String appId) =>
    'run:${normalizeApplicationId(appId)}';

/// 目录应用匹配（PLUGIN_DEVELOPMENT.md:420-424）：先精确 appId，后
/// `windowAppIds` 别名；多重匹配取唯一、匹配不到不猜。
LaunchableApplication? dockCatalogFor(
  String normalizedId,
  List<LaunchableApplication> catalog,
) {
  if (normalizedId.isEmpty) return null;
  final exact = catalog.where(
    (app) => normalizeApplicationId(app.appId) == normalizedId,
  );
  if (exact.length == 1) return exact.single;
  final alias = catalog.where(
    (app) => app.windowAppIds.any(
      (id) => normalizeApplicationId(id) == normalizedId,
    ),
  );
  return alias.length == 1 ? alias.single : null;
}

/// 窗口 → pin/目录应用的匹配（PLUGIN_DEVELOPMENT.md:420-424：先精确
/// appId，后 windowAppIds 别名；多重匹配取唯一、匹配不到不猜）。
/// pin 存 opaque launch `id`（id 可不等于 appId），顺序：① pin.appId
/// 直配 ② pin.id（launch id）直配 ③ catalog appId/别名唯一命中回查 pin。
PinnedApplication? dockPinFor(
  ApplicationWindow window,
  List<PinnedApplication> pins,
  List<LaunchableApplication> catalog,
) {
  final id = normalizeApplicationId(window.appId);
  for (final pin in pins) {
    if (normalizeApplicationId(pin.appId) == id) return pin;
  }
  // ② launch-id 直配：window.appId 恰等于 pin.id（opaque launch id），
  // 即使它不在任何 catalog appId/windowAppIds 别名集内也关联。
  for (final pin in pins) {
    if (normalizeApplicationId(pin.id) == id) return pin;
  }
  final byAppId = catalog.where(
    (app) => normalizeApplicationId(app.appId) == id,
  );
  final app = byAppId.length == 1
      ? byAppId.single
      : catalog
                .where(
                  (app) => app.windowAppIds.any(
                    (alias) => normalizeApplicationId(alias) == id,
                  ),
                )
                .length ==
            1
      ? catalog
            .where(
              (app) => app.windowAppIds.any(
                (alias) => normalizeApplicationId(alias) == id,
              ),
            )
            .single
      : null;
  if (app == null) return null;
  final launchKey = dockPinEntryKey(app.id);
  for (final pin in pins) {
    if (dockPinEntryKey(pin.id) == launchKey) return pin;
  }
  return null;
}

/// 图标行的一个条目（pinned 段或运行段）。
class DockRowEntry {
  const DockRowEntry({
    required this.key,
    required this.isPinned,
    required this.appId,
    required this.name,
    required this.launchId,
    required this.windows,
    this.pin,
  });

  /// 行内稳定键：`app:<normalized pin.id>`（pinned 段）或
  /// `run:<normalized appId>`（运行段）。
  final String key;

  /// pinned 段条目（可拖拽重排、菜单为「取消固定」）；false = 未 pin 的
  /// 运行聚合条目（不可重排、菜单为「固定此应用」，KOS
  /// `dock/DockIcon.qml:921-927`）。
  final bool isPinned;

  /// 图标资源 id（`services.buildApplicationIcon` 参数）。
  final String appId;
  final String name;

  /// launch id（`services.launchApplication` 参数）。
  ///
  /// pinned 条目：反查 catalog 的 `LaunchableApplication.id`（宿主 catalog
  /// id 形如 `desktop:<desktopFileId>`，denial_desktop
  /// `shell_plugin_services.dart:85-96` + `application_recents_controller
  /// .dart:9-12`）；持久化 pin.id 可能是无前缀 desktop id（旧 schema 写回
  /// 丢 `desktop:` 前缀），不能直接当 launch id——catalog 未命中才退化
  /// 为 pin.id（D-1 修复；旧版 `b04ecaf^:dock_host.dart:198` 同语义
  /// `launchId: application?.id ?? desktopId`）。
  /// 未 pin 条目：catalog 命中时为其 `id`，未命中为 null（只 activate
  /// 不 launch）。
  final String? launchId;

  /// 该条目在本输出的窗口（宿主枚举序 ≈ MRU，KOS
  /// `dock/DockModelService.qml:344-365` 取 `windows[0]` 为 MRU 窗）。
  final List<ApplicationWindow> windows;

  /// pinned 条目的持久化 pin（未 pin 条目为 null）。
  final PinnedApplication? pin;
}

/// 图标行有序条目：pinned 段（`prefs.pinned` 顺序）+ 未 pin 运行段
/// （canonical appId 聚合、首次出现顺序）。
///
/// KOS: `dock/DockModelService.qml:150-200` — `_refreshWindowItems`
/// grouped 分支：已 pin 的窗口 `continue`（:161，只由 pinned 段渲染不
/// 重复），其余按 canonical desktopId 聚成一个 `unpinnedGroups` 条目
/// （:163-181），`groupOrder` 记首次出现顺序（:181,197-198）。
List<DockRowEntry> dockRowEntries({
  required DockPreferences prefs,
  required List<LaunchableApplication> catalog,
  required List<ApplicationWindow> windows,
}) {
  // 窗口 → pin / 运行应用分组。CONSTRAINTS §5 修正（用户决定
  // 2026-10-05）：未 pin 的运行应用也进 Dock；仍是「一应用一图标」，
  // 不做逐窗口列表 / minimize / close / urgent。
  final windowsByPinKey = <String, List<ApplicationWindow>>{};
  final runningByKey = <String, List<ApplicationWindow>>{};
  final runningAppIdByKey = <String, String>{};
  final runningNameByKey = <String, String>{};
  final runningLaunchIdByKey = <String, String?>{};
  for (final window in windows) {
    final pin = dockPinFor(window, prefs.pinned, catalog);
    if (pin != null) {
      (windowsByPinKey[dockPinEntryKey(pin.id)] ??= []).add(window);
      continue;
    }
    final key = dockRunningEntryKey(window.appId);
    (runningByKey[key] ??= []).add(window);
    runningAppIdByKey.putIfAbsent(key, () => window.appId);
    // KOS: dock/DockModelService.qml:168 — `title: identity.name || title`：
    // catalog 命中时用目录名（下方回填），否则退化为窗口标题。
    runningNameByKey.putIfAbsent(key, () => window.title);
    // launch id：catalog 命中时回填（否则保持缺省 null → 只 activate）。
    runningLaunchIdByKey.putIfAbsent(key, () => null);
  }
  for (final key in runningByKey.keys) {
    final app = dockCatalogFor(
      normalizeApplicationId(runningAppIdByKey[key]!),
      catalog,
    );
    if (app == null) continue;
    runningAppIdByKey[key] = app.appId;
    runningNameByKey[key] = app.name;
    runningLaunchIdByKey[key] = app.id;
  }
  // normalize 同键去重（pinByKey 键序 = 首个 pin 出现顺序，值 = 最后同键
  // pin；prefs 读侧已按 normalize(id) 去重，这里是防御口径一致）。
  final pinByKey = <String, PinnedApplication>{
    for (final pin in prefs.pinned) dockPinEntryKey(pin.id): pin,
  };
  return List.unmodifiable([
    for (final MapEntry(key: key, value: pin) in pinByKey.entries)
      () {
        // D-1：pin.id 是 opaque launch id，宿主 catalog 的
        // `LaunchableApplication.id` 形如 `desktop:<desktopFileId>` 或
        // `local:<id>`（迁移态 pin 只存去掉前缀的 id）。`dockPinEntryKey`
        // 已剥已知 scheme，故 launch-key 直配即可命中大多数情况；与
        // `dockCatalogFor` 的「多重匹配不猜」对称，同 launch key 命中
        // >1 个 catalog 条目时不取 first、落下一层反查（pin.appId/别名
        // 唯一命中，兜 launch id 与 appId 不同系的情形）；都不唯一才
        // 退化 pin.id。命中后用 catalog 的 `id`（带前缀）作 launchId。
        final launchKeyHits = catalog
            .where((entry) => dockPinEntryKey(entry.id) == key)
            .toList();
        final app = (launchKeyHits.length == 1 ? launchKeyHits.single : null) ??
            dockCatalogFor(normalizeApplicationId(pin.appId), catalog) ??
            dockCatalogFor(normalizeApplicationId(pin.id), catalog);
        return DockRowEntry(
          key: key,
          isPinned: true,
          appId: app?.appId ?? pin.appId,
          name: app?.name ?? pin.name,
          // D-1：用 catalog `LaunchableApplication.id` 作 launch id；未命中
          // 才退化为 pin.id。
          launchId: app?.id ?? pin.id,
          windows:
              windowsByPinKey[key] ?? const <ApplicationWindow>[],
          pin: pin,
        );
      }(),
    for (final key in runningByKey.keys)
      DockRowEntry(
        key: key,
        isPinned: false,
        appId: runningAppIdByKey[key]!,
        name: runningNameByKey[key]!,
        launchId: runningLaunchIdByKey[key],
        windows: runningByKey[key]!,
      ),
  ]);
}
