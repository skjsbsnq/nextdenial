# NextDenial

将 NextKde（KOS）桌面体验移植为 [Denial](https://github.com/denialwm/denial) 插件的集合。

## 插件

| 插件 | 说明 | 提供的 Surface |
| --- | --- | --- |
| `plugins/kos_deskcenter` | KOS DeskCenter 桌面小部件（时钟 / 天气 / 日历 / 待办 / 系统 / 活动 / 音乐），Dart 重写装箱布局与编辑模式 | `ShellSurface` ×2（desktop 容器 + desktopControls 面板宿主） |
| ~~`plugins/kos_dock`~~ | （已移除，待重新移植） | — |

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
