/// 预览联动高亮（emphasize）300ms 驻留控制器。
///
/// ported from denial-plugins/denial_taskbar `lib/src/preview_emphasis.dart`
/// （逐字搬运，仅改注释语言）：同一预览卡连续悬停 300ms 才触发
/// `emphasizeWindow`；popup 关闭/释放时必须 `clear()`，`dispose()` 随
/// 宿主 widget 生命周期。
library;

import 'dart:async';

/// A continuous 300ms on the same preview is required. The owner must clear
/// this controller when its popup closes and dispose it with the widget.
class PreviewEmphasis {
  PreviewEmphasis({required this.request});

  final void Function() Function(int) request;
  Timer? _timer;
  void Function()? _release;
  int? _windowId;
  bool _disposed = false;

  int? get windowId => _windowId;

  void enter(int windowId) {
    if (_disposed || _windowId == windowId) return;
    clear();
    _windowId = windowId;
    _timer = Timer(const Duration(milliseconds: 300), () {
      if (!_disposed && _windowId == windowId) {
        _release = request(windowId);
      }
    });
  }

  void leave(int windowId) {
    if (_windowId == windowId) clear();
  }

  void clear() {
    _timer?.cancel();
    _timer = null;
    _windowId = null;
    final release = _release;
    _release = null;
    release?.call();
  }

  void dispose() {
    _disposed = true;
    clear();
  }
}
