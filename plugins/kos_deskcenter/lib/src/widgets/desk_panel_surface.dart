/// DeskCenter 详情面板的 surface 宿主 widget（TASK-12 §9.4 方案 (B)）。
///
/// 由 `KosDeskCenterPanelSurface`（`lib/kos_deskcenter.dart`，`@Provides`）
/// 挂在 `ShellSurfaceLayer.desktopControls` 层（输入法候选 popup 之下、普通
/// 应用窗口之下）：面板打开时把 native 输入路由到本 surface
/// （[ShellInputRegion] `fullScene`+`capture`+`normal`），并自管「点遮罩关闭」、
/// Esc 关闭与焦点。渲染复用 [DeskPanelShell] 的材质与入场动画，内容经
/// [buildDeskPanelContent] 命中面板注册表。
///
/// 会话状态来自跨 surface 的 [deskPanelSessionProvider]：容器 surface 在
/// `_openPanel` 写入，本 surface `watch` 读取。两者挂在 shell 的同一个
/// `ProviderScope` 下。
library;

import 'package:denial_flutter_sdk/input.dart'
    show
        ShellCompositorPolicy,
        ShellInputRegion,
        ShellKeyboardPolicy,
        ShellPointerPolicy;
import 'package:denial_flutter_sdk/services.dart'
    show ShellServices, ShellServicesScope;
import 'package:flutter/services.dart'
    show KeyDownEvent, LogicalKeyboardKey;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'desk_panel_shell.dart';

/// 面板会话在 `desktopControls` 层的宿主：`watch` [deskPanelSessionProvider]，
/// 无会话时渲染空 widget（不吸收指针），有会话时渲染 [DeskPanelShell]。
class DeskPanelSurfaceHost extends ConsumerStatefulWidget {
  const DeskPanelSurfaceHost({this.services, super.key});

  /// 宿主 `ShellServices`（`surface.services`）。面板内若需 clock/media 等
  /// 数据源，经 [ShellServicesScope] 下钻（与容器卡片的 scope 一致）。
  final ShellServices? services;

  @override
  ConsumerState<DeskPanelSurfaceHost> createState() =>
      _DeskPanelSurfaceHostState();
}

class _DeskPanelSurfaceHostState extends ConsumerState<DeskPanelSurfaceHost> {
  /// 面板焦点域：打开时移入（承接 Esc），关闭时归还给打开前的焦点。
  final FocusScopeNode _focusScopeNode = FocusScopeNode(
    debugLabel: 'desk-panel-surface',
  );

  /// 打开面板前的焦点，用于关闭时归还（对齐旧 popup 的 `restoreFocus`）。
  FocusNode? _restoreFocus;

  @override
  void dispose() {
    _focusScopeNode.dispose();
    super.dispose();
  }

  void _close() => ref.read(deskPanelSessionProvider.notifier).close();

  @override
  Widget build(BuildContext context) {
    // 会话开合驱动焦点：打开 → 把焦点移入面板；关闭 → 归还。
    ref.listen(deskPanelSessionProvider, (previous, next) {
      if (previous == null && next != null) {
        _restoreFocus = FocusManager.instance.primaryFocus;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _focusScopeNode.requestFocus();
        });
      } else if (previous != null && next == null) {
        final restore = _restoreFocus;
        _restoreFocus = null;
        if (restore != null && restore.canRequestFocus) {
          restore.requestFocus();
        }
      }
    });

    final session = ref.watch(deskPanelSessionProvider);
    final open = session != null;
    // 输入区始终挂载，仅以 `active` 门控 native 路由（对齐 SDK 惯例：
    // popup「fullScene + capture + normal」；此处 `ShellSurfacePlane` 的
    // `ShellInputClip` 会把 fullScene 收敛到本输出矩形）。
    Widget child = open
        ? FocusScope(
            node: _focusScopeNode,
            onKeyEvent: (node, event) {
              if (event is KeyDownEvent &&
                  event.logicalKey == LogicalKeyboardKey.escape) {
                _close();
                return KeyEventResult.handled;
              }
              return KeyEventResult.ignored;
            },
            child: Semantics(
              scopesRoute: true,
              explicitChildNodes: true,
              child: DeskPanelShell(
                title: deskPanelTitle(session.request.cardId),
                onClose: _close,
                onBarrierTap: _close,
                child: buildDeskPanelContent(session.request, session.data),
              ),
            ),
          )
        : const SizedBox.shrink();
    final services = widget.services;
    if (services != null) {
      child = ShellServicesScope(services: services, child: child);
    }
    return ShellInputRegion(
      debugLabel: 'DeskCenter panel',
      active: open,
      pointerPolicy: ShellPointerPolicy.fullScene,
      keyboardPolicy: ShellKeyboardPolicy.capture,
      compositorPolicy: ShellCompositorPolicy.normal,
      child: child,
    );
  }
}
