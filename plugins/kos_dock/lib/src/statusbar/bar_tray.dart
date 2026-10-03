import 'package:denial_flutter_sdk/services.dart';
import 'package:denial_flutter_sdk/theme.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'bar_card.dart';

/// 系统托盘模块——顶栏右簇模块之一。
///
/// 复刻官方 `_SystemTrayStatusModule`
/// （denial_top_bar `desktop_system_bar.dart:197-208`）：私有 widget
/// 跨包不可 import，按 TASK-TB-04 约束在本插件复写。
///
/// 托盘条目本体由 denial 宿主渲染（`buildSystemTray`）——SNI host、图标
/// 尺寸/间距、左/中/右键语义全在宿主侧，本插件只给容器与前景色
/// （NextKde `SysTray.qml` 的 782 行 SNI host 实现不移植）。
///
/// 与官方差异：
/// - 官方不传 `foregroundColor`（宿主默认）；本插件传
///   `theme.colors.textPrimary`，与胶囊内其他模块的图标/文本色调一致
///   （TASK-TB-04 约束钉死）。
/// - `trayVisible` 门控 + 卡片包装在本文件的 `TopBarTrayStatusModule`
///   （对应官方装配段）；`TopBarEntrance` 错峰入场由 TASK-TB-07 装配层
///   包——本模块只产出托盘内容，与官方分层一致。
/// - 不实现 Alt+拖拽重排与 `StatusAreaEditor`（SDK 无 item 级 API）。
class TopBarTrayModule extends ConsumerWidget {
  const TopBarTrayModule({required this.horizontal, super.key});

  /// 主轴是否水平（`PanelEdge.top/bottom` → true）。
  final bool horizontal;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return context.trayServices.buildSystemTray(
      context,
      horizontal: horizontal,
      foregroundColor: context.shellTheme.colors.textPrimary,
    );
  }
}

extension _TrayContext on BuildContext {
  ShellTrayServices get trayServices => ShellServicesScope.of(this);
}

/// 托盘状态壳：`ref.watch(trayVisible)` 门控，可见时包 `TopBarCard` 胶囊。
///
/// 对应官方 `_DesktopSystemBarContent` 中 `if (trayVisible)` +
/// `_SystemBarCard` 的装配段（desktop_system_bar.dart:62-87）：官方把托盘
/// 卡放进 `Expanded + SingleChildScrollView` 占位可滚动区，本插件右簇走
/// `mainAxisSize:min` 行排布（TASK-TB-07），滚动由装配层决定；本壳只做
/// 「不可见 → 空」「可见 → 胶囊卡」门控。
///
/// `trayVisible==false` 时返回 `SizedBox.shrink`——装配层 `if` 也可省，
/// 直接内联本壳即可（不留空胶囊）。
class TopBarTrayStatusModule extends ConsumerWidget {
  const TopBarTrayStatusModule({required this.horizontal, super.key});

  /// 主轴是否水平（`PanelEdge.top/bottom` → true）。
  final bool horizontal;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final visible = ref.watch(context.trayServices.trayVisible);
    if (!visible) {
      return const SizedBox.shrink();
    }
    // 整条玻璃裸排：bare 去独立胶囊底板，仅留水平内边距共享整根条带。
    return const TopBarCard(
      bare: true,
      padding: EdgeInsets.symmetric(horizontal: 2),
      child: TopBarTrayModule(horizontal: true),
    );
  }
}
