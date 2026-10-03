import 'dart:async';

import 'package:denial_flutter_sdk/services.dart';
import 'package:denial_flutter_sdk/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'bar_card.dart';

/// 工作区胶囊——顶栏左端模块。
///
/// 全套复刻官方 `denial_top_bar/lib/src/desktop_workspace_indicator.dart`
/// （`_WorkspaceIndicator` + `_WorkspaceRail` + `_WorkspaceActiveLens` +
/// `_WorkspaceIndicatorButton`）：私有 widget 跨包不可 import，按
/// TASK-TB-02 约束在本插件复写。
///
/// 与官方唯一差异：本插件胶囊卡走 dock/deskcenter 平填链（`TopBarCard`，
/// 不用 `WallpaperAccent` 渐变），因此 caption 色固定 `textSecondary`——
/// TASK-TB-02-card 钉死「无 WallpaperAccent——caption 用 textSecondary」。
/// `WallpaperAccent` 参数仍透传保留（胶囊未来若回渐变链可直接启用），
/// 但按钮 caption 不读它。

/// 工作区指示器模块：`workspace(monitorId)` 投影 → `TopBarCard` 胶囊
/// 包 `_WorkspaceRail`；`RepaintBoundary` 隔一层（照官方 :20）。
///
/// `workspacesEnabled==false` 时整个胶囊不渲染——由调用方（TASK-TB-07
/// 装配层）`if (workspacesEnabled)` 门控，本模块不自己判断。
class WorkspaceIndicator extends ConsumerWidget {
  const WorkspaceIndicator({
    required this.monitorId,
    required this.horizontal,
    required this.accent,
    super.key,
  });

  final int monitorId;
  final bool horizontal;
  final WallpaperAccent accent;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final workspace = ref.watch(
      context.workspaceServices.workspace(monitorId),
    );
    final count = workspace.count;
    final active = workspace.active;
    final occupied = workspace.occupied;
    return RepaintBoundary(
      // 整条玻璃裸排：去 TopBarCard 底板（bare），仅留水平内边距。
      child: TopBarCard(
        bare: true,
        padding: horizontal
            ? const EdgeInsets.symmetric(horizontal: 2)
            : const EdgeInsets.all(2),
        child: WorkspaceRail(
          count: count,
          active: active,
          occupied: occupied,
          horizontal: horizontal,
          accent: accent,
          onPressed: (workspace) => context.workspaceServices.switchWorkspace(
            monitorId: monitorId,
            workspaceId: workspace,
          ),
        ),
      ),
    );
  }
}

/// 工作区轨道：`Stack` 叠 `AnimatedAlign` 激活 lens + `Flex` 格钮。
///
/// 复刻官方 `_WorkspaceRail`：`_itemExtent=20`/`_crossExtent=18`；
/// `clipBehavior: Clip.none`（lens 滑出格位时不裁切）。
class WorkspaceRail extends StatelessWidget {
  const WorkspaceRail({
    required this.count,
    required this.active,
    required this.occupied,
    required this.horizontal,
    required this.accent,
    required this.onPressed,
    super.key,
  });

  static const double _itemExtent = 20;
  static const double _crossExtent = 18;

  final int count;
  final int active;
  final Set<int> occupied;
  final bool horizontal;
  final WallpaperAccent accent;
  final ValueChanged<int> onPressed;

  @override
  Widget build(BuildContext context) {
    final mainExtent = _itemExtent * count;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return SizedBox(
      width: horizontal ? mainExtent : _crossExtent,
      height: horizontal ? _crossExtent : mainExtent,
      child: Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          Positioned.fill(
            child: AnimatedAlign(
              duration: reduceMotion ? Duration.zero : Motion.workspaceSwitch,
              curve: Motion.md3Emphasized,
              alignment: _activeAlignment(active, count, horizontal),
              child: WorkspaceActiveLens(
                workspace: active,
                horizontal: horizontal,
                reduceMotion: reduceMotion,
              ),
            ),
          ),
          Flex(
            direction: horizontal ? Axis.horizontal : Axis.vertical,
            children: <Widget>[
              for (var workspace = 1; workspace <= count; workspace++)
                WorkspaceIndicatorButton(
                  workspace: workspace,
                  active: workspace == active,
                  occupied: occupied.contains(workspace),
                  horizontal: horizontal,
                  accent: accent,
                  onPressed: () => onPressed(workspace),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

Alignment _activeAlignment(int active, int count, bool horizontal) {
  final position = count <= 1 ? 0.0 : -1.0 + (2.0 * (active - 1) / (count - 1));
  return horizontal ? Alignment(position, 0) : Alignment(0, position);
}

/// 激活 lens：液体形变三段（takeoff/travel/settle），复刻官方
/// `_WorkspaceActiveLens`。
///
/// `AnimationController.unbounded`（`shape`），`didUpdateWidget` 里
/// workspace 变 → `animateTo(1.34, Motion.workspaceIndicatorTakeoff,
/// md3EmphasizedAccelerate)` → `(0.94, Travel, standard)` → `(1.0, Settle,
/// md3EmphasizedDecelerate)`；`Transform.scale` 主轴 `shape.value`，
/// 横轴 `delta>=0 ? 1-delta*0.34 : 1-delta*0.72`（官方公式照抄）。
/// reduceMotion 时 `shape.value=1` 不播形变。
class WorkspaceActiveLens extends StatefulWidget {
  const WorkspaceActiveLens({
    required this.workspace,
    required this.horizontal,
    required this.reduceMotion,
    super.key,
  });

  final int workspace;
  final bool horizontal;
  final bool reduceMotion;

  @override
  State<WorkspaceActiveLens> createState() => _WorkspaceActiveLensState();
}

class _WorkspaceActiveLensState extends State<WorkspaceActiveLens>
    with SingleTickerProviderStateMixin {
  late final AnimationController _shape = AnimationController.unbounded(
    vsync: this,
    value: 1,
  );
  var _generation = 0;

  @override
  void didUpdateWidget(WorkspaceActiveLens oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.reduceMotion) {
      _generation++;
      _shape.stop();
      _shape.value = 1;
    } else if (widget.workspace != oldWidget.workspace) {
      _generation++;
      unawaited(_animateLiquid(_generation));
    }
  }

  Future<void> _animateLiquid(int generation) async {
    _shape.stop();
    try {
      await _shape
          .animateTo(
            1.34,
            duration: Motion.workspaceIndicatorTakeoff,
            curve: Motion.md3EmphasizedAccelerate,
          )
          .orCancel;
      if (generation != _generation) return;
      await _shape
          .animateTo(
            0.94,
            duration: Motion.workspaceIndicatorTravel,
            curve: Motion.standard,
          )
          .orCancel;
      if (generation != _generation) return;
      await _shape
          .animateTo(
            1,
            duration: Motion.workspaceIndicatorSettle,
            curve: Motion.md3EmphasizedDecelerate,
          )
          .orCancel;
    } on TickerCanceled {
      // A newer workspace target continues from the current deformation.
    }
  }

  @override
  void dispose() {
    _generation++;
    _shape.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _shape,
      builder: (context, child) {
        final mainScale = _shape.value;
        final delta = mainScale - 1;
        final crossScale = delta >= 0 ? 1 - (delta * 0.34) : 1 - (delta * 0.72);
        return Transform.scale(
          scaleX: widget.horizontal ? mainScale : crossScale,
          scaleY: widget.horizontal ? crossScale : mainScale,
          child: child,
        );
      },
      child: SizedBox(
        width: widget.horizontal
            ? WorkspaceRail._itemExtent
            : WorkspaceRail._crossExtent,
        height: widget.horizontal
            ? WorkspaceRail._crossExtent
            : WorkspaceRail._itemExtent,
        child: Center(
          child: SizedBox.square(
            dimension: 17,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: ShellMediaColors.darkness.withValues(alpha: 0.36),
                shape: BoxShape.circle,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 单格工作区按钮：`Material(transparent)` + `InkWell` + tooltip/语义
/// + `AnimatedDefaultTextStyle` 样式切换。复刻官方 `_WorkspaceIndicatorButton`。
class WorkspaceIndicatorButton extends StatelessWidget {
  const WorkspaceIndicatorButton({
    required this.workspace,
    required this.active,
    required this.occupied,
    required this.horizontal,
    required this.accent,
    required this.onPressed,
    super.key,
  });

  final int workspace;
  final bool active;
  final bool occupied;
  final bool horizontal;
  final WallpaperAccent accent;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = context.shellTheme;
    final l10n = context.pluginStrings;
    final description = occupied ? l10n.workspaceOccupied : l10n.workspaceEmpty;
    final label =
        '${l10n.workspaceLabel(workspace)}, $description'
        '${active ? ', ${l10n.workspaceActive}' : ''}';
    // 本插件胶囊卡平填链，不用 WallpaperAccent.captionColor——caption 统一
    // textSecondary（TASK-TB-02-card 钉死）。
    final textStyle = active
        ? theme.text.systemBarValue.copyWith(
            color: theme.accent,
            fontSize: theme.text.systemBarValue.fontSize! + 1,
          )
        : theme.text.systemBarCaption.copyWith(
            color: theme.colors.textSecondary,
            fontSize: theme.text.systemBarCaption.fontSize! + 2,
          );
    final itemSize = horizontal
        ? const Size(WorkspaceRail._itemExtent, WorkspaceRail._crossExtent)
        : const Size(WorkspaceRail._crossExtent, WorkspaceRail._itemExtent);
    return Tooltip(
      message: label,
      child: Semantics(
        button: true,
        selected: active,
        label: label,
        onTap: onPressed,
        child: ExcludeSemantics(
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: theme.borderRadius(999),
              mouseCursor: context.presentationServices.linkCursor,
              splashFactory: NoSplash.splashFactory,
              overlayColor: WidgetStateProperty.resolveWith((states) {
                if (states.contains(WidgetState.focused)) {
                  return theme.accent.withValues(alpha: 0.12);
                }
                if (states.contains(WidgetState.hovered) ||
                    states.contains(WidgetState.pressed)) {
                  return theme.accent.withValues(alpha: 0.08);
                }
                return Colors.transparent;
              }),
              onTap: onPressed,
              child: SizedBox(
                width: itemSize.width,
                height: itemSize.height,
                child: Center(
                  child: AnimatedDefaultTextStyle(
                    duration: Motion.pill,
                    curve: Motion.standard,
                    style: textStyle,
                    child: Text('$workspace', maxLines: 1),
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

extension _WorkspaceContext on BuildContext {
  ShellWorkspaceServices get workspaceServices => ShellServicesScope.of(this);
  ShellPresentationServices get presentationServices =>
      ShellServicesScope.of(this);
  ShellStrings get pluginStrings => presentationServices.strings(this);
}
