import 'package:denial_flutter_sdk/services.dart';
import 'package:denial_flutter_sdk/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'bar_card.dart';
import 'bar_control_panel.dart';

/// 控制中心按钮 + 占位弹层——顶栏右簇第一个模块。
///
/// 移植 NextKde `ControlCenterToggle.qml`（bar/ControlCenterToggle.qml）：
/// - `BundledIcon "control-center"`（双横滑轨 + 两圆钮）→ 自绘
///   `assets/icons/control_center.svg`（`currentColor` 单色遮罩，`flutter_svg`
///   着色走 `ColorFilter`，色取 `theme.colors.textPrimary`——NextKde
///   `IconAppearanceService` 的 `foregroundColor` 语义）；
/// - 24×24 盒，图标 18×18（`iconSize` 源值）；
/// - `scale: pressed ? 0.90 : hovered ? 1.06 : 1`，`AnimatedScale`
///   `Motion.pill`(90ms, NextKde `fastDuration`≈135ms 的最近档) +
///   `Curves.easeOutCubic`（NextKde `Easing.OutCubic`）；
/// - opacity `pressed ? 0.88 : hovered ? 0.96 : 0.88`——NextKde 原式
///   `mode != color ? iconOpacity * (panelOpen ? 1 : 0.88)` 简化（无
///   `panelOpen` 回读、`IconAppearanceService` 砍掉，差异记入
///   visual-deltas.md）；
/// - `Tooltip('控制中心')`（`minimumWidth: 92` 不强制）；
/// - `onTap` → `showControlCenterPanel` 开占位面板（`ShellPopupController`
///   托管，`keyName` 幂等连点不叠层）。
///
/// 按钮外观与其他状态模块一致：`InkWell` + `TopBarCard` 胶囊
/// （NextKde 无胶囊底——denial 侧每个模块是悬浮卡片，差异见
/// CONSTRAINTS/ROADMAP 决策 6）。
class TopBarControlCenterModule extends ConsumerStatefulWidget {
  const TopBarControlCenterModule({super.key});

  @override
  ConsumerState<TopBarControlCenterModule> createState() =>
      _TopBarControlCenterModuleState();
}

class _TopBarControlCenterModuleState
    extends ConsumerState<TopBarControlCenterModule> {
  var _hovered = false;
  var _focused = false;
  var _pressed = false;

  void _openPanel() {
    // 按钮全局 Rect 作弹层锚点（RenderBox.localToGlobal + size），面板从钮
    // 下方弹出——NextKde `edges/gravity=Bottom, margins.bottom -4` 的等价。
    final renderObject = context.findRenderObject();
    final anchor = renderObject is RenderBox && renderObject.hasSize
        ? renderObject.localToGlobal(Offset.zero) & renderObject.size
        : null;
    showControlCenterPanel(ref, anchorRect: anchor);
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.shellTheme;
    return Semantics(
      button: true,
      // SDK ShellStrings 无控制中心词条（同网络模块，插件 scope 硬编码中文）。
      label: '控制中心',
      onTap: _openPanel,
      child: ExcludeSemantics(
        child: Tooltip(
          message: '控制中心',
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              borderRadius: theme.borderRadius(999),
              mouseCursor: context.presentationServices.linkCursor,
              splashFactory: NoSplash.splashFactory,
              overlayColor: const WidgetStatePropertyAll<Color>(
                ShellMediaColors.transparentDark,
              ),
              onTap: _openPanel,
              onHover: (value) => setState(() => _hovered = value),
              onFocusChange: (value) => setState(() => _focused = value),
              onHighlightChanged: (value) =>
                  setState(() => _pressed = value),
              child: TopBarCard(
                bare: true,
                highlighted: _hovered || _focused,
                focused: _focused,
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: SizedBox(
                  width: 24,
                  height: 24,
                  child: Center(
                    child: AnimatedScale(
                      scale: _pressed ? 0.90 : (_hovered ? 1.06 : 1.0),
                      duration: MediaQuery.disableAnimationsOf(context)
                          ? Duration.zero
                          : Motion.pill,
                      curve: Curves.easeOutCubic,
                      child: AnimatedOpacity(
                        opacity: _pressed
                            ? 0.88
                            : (_hovered ? 0.96 : 0.88),
                        duration: MediaQuery.disableAnimationsOf(context)
                            ? Duration.zero
                            : Motion.pill,
                        child: SvgPicture.asset(
                          'assets/icons/control_center.svg',
                          package: 'kos_dock',
                          width: 18,
                          height: 18,
                          colorFilter: ColorFilter.mode(
                            theme.colors.textPrimary,
                            BlendMode.srcIn,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

extension on BuildContext {
  ShellPresentationServices get presentationServices =>
      ShellServicesScope.of(this);
}
