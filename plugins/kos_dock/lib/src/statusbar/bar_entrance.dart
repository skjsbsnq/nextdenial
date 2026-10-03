import 'dart:async';

import 'package:denial_flutter_sdk/theme.dart';
import 'package:flutter/widgets.dart';

/// 挂载一次性弹簧入场——复刻官方 `_SystemBarEntrance`
/// （denial_top_bar `desktop_system_bar_components.dart:325-394`）：
///
/// 胶囊从尾缘滑入 12px，按 [index] 以 60ms 错峰弹入；主轴 extent 经
/// `Align(widthFactor/heightFactor)` 同步展开，让相邻胶囊滑开而非跳变；
/// 弹簧用 `springTo(Motion.gentle)`，落位后零开销。
///
/// 与官方唯一差异：入场调度从 `initState` 挪到 `didChangeDependencies`，
/// 以便读取 `MediaQuery.disableAnimationsOf`——reduceMotion 时直接落位
/// `t = 1` 不播弹簧（CONSTRAINTS.md §5 / TASK-TB-01 约束）。
class TopBarEntrance extends StatefulWidget {
  const TopBarEntrance({
    required this.index,
    required this.horizontal,
    required this.child,
    super.key,
  });

  /// 错峰序号：延迟 = `index * 60ms`。右簇自右缘依次进入时，调用方把
  /// 最右模块的 index 设为 0。
  final int index;

  /// 主轴是否水平（`PanelEdge.top/bottom` → true，`left/right` → false）。
  final bool horizontal;

  final Widget child;

  @override
  State<TopBarEntrance> createState() => _TopBarEntranceState();
}

class _TopBarEntranceState extends State<TopBarEntrance>
    with SingleTickerProviderStateMixin {
  static const double _slideDistance = 12.0;
  static const Duration _stagger = Duration(milliseconds: 60);

  late final AnimationController _controller = AnimationController.unbounded(
    vsync: this,
  );
  Timer? _delay;
  bool _armed = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // MediaQuery 只能在依赖就绪后读取；入场只武装一次。
    if (_armed) {
      return;
    }
    _armed = true;
    if (MediaQuery.disableAnimationsOf(context)) {
      // reduceMotion：跳过弹簧，直接落位。
      _controller.value = 1.0;
      return;
    }
    _delay = Timer(_stagger * widget.index, () {
      if (mounted) {
        springTo(_controller, 1.0, telemetryLabel: 'dock_bar_entrance');
      }
    });
  }

  @override
  void dispose() {
    _delay?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final t = _controller.value;
        final travel = (1.0 - t) * _slideDistance;
        return Align(
          alignment: widget.horizontal
              ? Alignment.centerRight
              : Alignment.bottomCenter,
          widthFactor: widget.horizontal ? unit(t) : null,
          heightFactor: widget.horizontal ? null : unit(t),
          child: Opacity(
            opacity: unit(t),
            child: Transform.translate(
              offset: widget.horizontal
                  ? Offset(travel, 0.0)
                  : Offset(0.0, travel),
              child: child,
            ),
          ),
        );
      },
      child: widget.child,
    );
  }
}
