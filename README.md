# NextDenial

将 NextKde（KOS）桌面体验移植为 [Denial](https://github.com/denialwm/denial) 插件的集合。

## 插件

| 插件 | 说明 | 提供的 Surface |
| --- | --- | --- |
| `plugins/kos_deskcenter` | KOS DeskCenter 桌面小部件（时钟 / 天气 / 日历 / 待办 / 系统 / 活动 / 音乐），Dart 重写装箱布局与编辑模式 | `ShellSurface` ×2（desktop 容器 + desktopControls 面板宿主） |
| `plugins/kos_dock` | KOS macOS-style 融合模式悬浮 Dock（pinned/运行图标行、启动器、垃圾桶、窗口预览与菜单、信息卡 carousel）；TASK-06 托盘区待补 | `ShellSurface`（`kos_dock.dock`）+ `ShellWorkArea`（底部条带） |

## 设计原则

- **视觉对齐 NextKde/KOS**：卡片材质、圆角、配色、字体层级与交互均以 KOS 源码为准；KWin 专属效果以 Denial/Flutter 等价物近似。
- **遵循 Denial 插件契约**：使用 `denial_plugin` 元数据与 `ShellSurface` / `ShellWorkArea` / `ShellServices` 契约，编译期组合，不引入运行时注册表。

## 构建

每个插件都是标准 Flutter/Dart package，依赖 Denial SDK（`denial_sdk`、`denial_flutter_sdk`）：

```bash
cd plugins/kos_deskcenter
flutter test
```

## 致谢

- **NextKde** — 本项目的小部件、Dock 与顶栏设计均移植自 NextKde（KOS）桌面，视觉与交互以其源码为准。

控制中心已恢复截图、深色模式、电源、勿扰和夜灯五个快捷按钮。截图在弹层关闭后捕获桌面；深色模式写入 Denial 颜色方案偏好；勿扰切换通知策略。电源页提供锁定、注销、睡眠、休眠、重启和关机，按宿主权限和系统阻止器启用，注销、重启和关机需要二次确认。夜灯目前没有公开 SDK 接口，因此保留禁用按钮及原因提示。通知历史与切换用户尚未移植。
