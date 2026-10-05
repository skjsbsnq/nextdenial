/// KOS Dock 垃圾桶服务接口（纯 Dart：无 dart:io / flutter 依赖，CONSTRAINTS
/// §10 接口/IO 分离；实现见 `trash_service_io.dart` 的 [FileTrashService]）。
///
/// KOS 对应面：NextKde `shell/desktop/modules/dock/DockTrashService.qml`
/// 走 `kos-platform.sock` 的 `file.trash-state`（:16-25 状态刷新）、
/// `file.open-trash`（:27-34）、`file.empty-trash`（:36-49）；
/// Denial 无此平台通道，按 CONSTRAINTS §5/§10 用 dart:io freedesktop
/// Trash 等价物重写，本文件只保留可注入的抽象。
library;

/// 垃圾桶当前状态投影。
///
/// KOS 仅区分 full/empty（DockTrashService.qml:23 `hasItems = !!...`，
/// :46 清空成功后 `hasItems = false`）；[count] 是 dart:io 侧的精确条目数
/// （接口/测试用，UI 不做角标——KOS 无角标行为）。
class TrashState {
  const TrashState({required this.hasItems, required this.count});

  final bool hasItems;
  final int count;

  static const TrashState empty = TrashState(hasItems: false, count: 0);
}

/// 垃圾桶服务：查询（[hasItems]/[count]）、动作（[open]/[empty]）、变化流
/// （[watch]）。测试注入假实现（CONSTRAINTS §10）。
abstract interface class TrashService {
  /// files/ 存在且有顶层条目（DockTrashService.qml:16-25 状态刷新语义）。
  Future<bool> hasItems();

  /// files/ 顶层条目数（缺失 = 0）。
  Future<int> count();

  /// DockTrashService.qml:27-34 `open()`：打开文件管理器垃圾桶视图。
  Future<void> open();

  /// DockTrashService.qml:36-49 `empty()`：清空垃圾桶内容（破坏性动作，
  /// 确认弹窗由调用方负责）。
  Future<void> empty();

  /// 先 emit 当前状态，随后每次 Trash 变化再 emit。
  Stream<TrashState> watch();
}
