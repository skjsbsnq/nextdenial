/// DeskCenter 详情面板的统一装配点（TASK-12~17 收口）。
///
/// 各面板文件只导出自己的 `registerXxxPanel()`，由本文件集中调用，避免
/// 面板实现反向依赖装配层；`KosDeskCenterView` 的 surface 在首帧前调用
/// 一次 [registerDeskPanels]（幂等，重复调用无副作用）。
///
/// 注册表语义见 [registerDeskPanelBuilder]：面板 surface
/// （`DeskPanelSurfaceHost` 经 [buildDeskPanelContent]）按 appId 命中注册项，
/// 未注册的卡片回退 `DeskPanelPlaceholder`。
library;

import 'activity_panel.dart' show registerActivityPanel;
import 'calendar_panel.dart' show registerCalendarPanel;
import 'desk_panel_shell.dart' show registerDeskPanelBuilder;
import 'music_panel.dart' show registerMusicPanel;
import 'system_panel.dart' show registerSystemPanel;
import 'todo_panel.dart' show registerTodoPanel;
import 'weather_panel.dart' show registerWeatherPanel;

/// 注册全部已实现的面板（幂等）。
void registerDeskPanels() {
  registerCalendarPanel(); // TASK-13（kos-calendar）
  registerTodoPanel(); // TASK-14（kos-todo）
  registerWeatherPanel(); // TASK-15（kos-weather）
  registerMusicPanel(); // TASK-16（kos-music）
  registerSystemPanel(); // TASK-17（kos-system）
  registerActivityPanel(); // TASK-17（kos-activity）
}
