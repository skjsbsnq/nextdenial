# kos_dock 已知视觉/行为偏差（TASK-00 基线）

相对 KOS（NextKde）源端的移植偏差，随任务推进更新。

- **squircle → BorderRadius.circular 退化**：KOS pill 用 squircle 圆角
  （AppearanceTokens.qml radiusRatio 0.50 的超椭圆端帽）；Flutter 无原生
  squircle，TASK-00 用 `BorderRadius.circular(height*0.5)` 半圆端帽近似。
- **不自动隐藏**：KOS 有 `DockAutoHideController`（autohide/dockSpan 等
  触发模式）；Denial 移植不做自动隐藏，dock 常驻。
- **不挤压工作区（TASK-00 原文 → 2026-10-04 用户决定已修正）**：KOS
  `exclusionMode: Normal`（DockWindow.qml:27）为 dock 预留空间；TASK-00
  基线曾约定 Denial 侧 dock 悬浮于 `aboveWindows` 层、`occupiesDesktop:
  false`、不实现 `ShellWorkArea`，最大化窗口可延伸到 dock 后方。
  **该约定已作废**：用户要求最大化窗口整体上浮、不被 dock 压住且不要
  顶栏，故 kos_dock 现提供 `ShellWorkArea`（`PanelEdge.bottom`，
  KOS 依据 `DockWindow.qml:118-127`）——详见文末
  「TASK-04 收口 · 底部工作区预留与 pill 浮空」与 `CONSTRAINTS.md` §2 修正段。
- **未 pin 的运行中应用不显示（TASK-00 原文 → 2026-10-05 用户决定已修正）**：
  原文写「KOS grouped 模型将运行中未 pin 应用合入 dock；当前骨架无图标行，
  后续按需决定是否复刻」。**修正**：用户要求未 pin 的运行应用也进 Dock，故
  已按 KOS `grouped` 语义复刻「一应用一图标」——见文末
  「TASK-04 收口 · 未 pin 运行应用进 Dock」与 `CONSTRAINTS.md` §5 修正段。
- **玻璃材质差异**：KOS pill 玻璃含 liquid refraction；Denial 用
  `transparencyMode == glass` + `ShellBackdropBlur(separateChild: true)`
  的玻璃链近似，折射/色散参数由 ShellTheme 的 glass 配置承载。
- **仅 bottom 位置**：KOS 支持 left/right/bottom 三边
  （`DockWindow.position`）；v1 固定 `PanelEdge.bottom`，surface 厚度按
  横向条带计算。
- **fullscreen launcher 升层**：KOS 在 fullscreen launcher 打开时把 dock
  提升到 `WlrLayer.Overlay`（DockWindow.qml:32-34）；Denial 层模型无
  对应平面，固定在 `aboveWindows`。

## TASK-01 图标行新增偏差

- **无 launch bounce**：KOS 启动应用时图标弹跳动画（DockIcon.qml 的
  launch 弹跳分支）未移植；点击 launch 仅触发 `launchApplication`。
- **无 urgent 红点**：KOS `demandsAttention` 红角标（DockIcon.qml:736-764
  attentionBadge）因 wire 协议缺口砍掉；运行态只有 dot。
- **多窗点击 = MRU 轮循**：KOS 多窗点击弹逐窗口预览列表；移植版按
  DockModelService.qml:317-366 的 MRU 语义轮循激活（预览列表归
  TASK-03），无 minimize 分支。
- **未 pin 运行应用进 Dock（TASK-01 原文「不进 Dock」，2026-10-05 用户决定已修正）**：
  原文写 KOS grouped 把未 pin 运行窗口聚成单图标入列、由 CONSTRAINTS §5 砍掉。
  **修正**：现已复刻 grouped 的「一应用一图标」，见文末
  「TASK-04 收口 · 未 pin 运行应用进 Dock」。
- **magnification 指针用全局 x 坐标系**：KOS 把指针与槽中心都映射进
  DockContainer 本地系；移植版两者统一用全局 x（槽中心经 localToGlobal
  量取），等价、少一次祖先查找。前提：surface 之上无祖先级非平移变换
  （缩放/旋转会让「全局 x」与行内坐标系分叉）；当前 surface 链只含
  平移与淡入，成立。
- **激活底斑颜色 = shellTheme accent**：KOS 为白 0.22/0.34 语义；按
  CONSTRAINTS §3 映射为 `context.shellTheme.accent` @ 0.22（subtle）。
- **hover 高亮 = textPrimary @ 0.12**：KOS 白 0.12（DockIcon.qml:647）；
  SDK 无 hover token，用 `shellColors.textPrimary` 同 alpha 代替。
- **spring 映射 Motion.snappy**：KOS iconSpring s8.0/d0.40/m0.60
  （DockAnimation.qml:37-50）实测 t90≈96ms/settle≈160ms；选 SDK
  弹簧族中同量级「小元素快跟手」标定的 Motion.snappy。
- **单 progress 驱动 scale+lift**：KOS hover 与 magnification 各走独立
  分支；移植版合为一条 [0,∞) 弹簧进度（峰值常量按模式取
  1.19/1.20），模式切换瞬间有微小峰值不连续（~1%）。

## TASK-02 容器布局新增偏差

- **divider 颜色 = shellTheme `hairline`**：KOS 为白 0.46
  （DockContainer.qml:853-854 `lineColor: Qt.rgba(1,1,1,1)` +
  `lineOpacity: 0.46`）；按 CONSTRAINTS §3 映射语义色，明暗主题自动跟随。
- **divider 显隐动画未移植**：KOS `Behavior on width`（DockDivider.qml:38-44，
  musicExpandDuration 展开/收起动画）不实现；可见性由父级 Row 条件插入
  瞬时切换。
- **pill 填充 = `panelGradient(cardFillTop→cardFill)`**：KOS 用单一主题
  玻璃面；移植版借 top_bar `_SystemBarCard` 顶部轻打光渐变 idiom
  （desktop_system_bar_components.dart:284-302）提升到 panel 语义——
  仍是主题驱动，但与 KOS 的纯色衬底略有偏差。
- **输入区为矩形**：`ShellInputRegion` 罩住整个 pill 矩形边界；KOS 的
  更紧非矩形（squircle）输入形状以该矩形近似。
- **图标溢出 → KOS iconSize 反解（方案 C 起，v1 的行内滚动兜底已删）**：
  v1 曾把图标行宽 clamp 到 `maxWidth×0.98 − 固定槽位`、超出走横向滚动；
  方案 C 移植 `AdaptiveMath.computeLayout` 的反解（AdaptiveMath.mjs:
  129-138），宽度不足时 iconSize 收缩到 MIN_ICON_SIZE 下限，内容恒
  ≤ maxWidth，不再需要滚动（见文末「TASK-04b · 方案 C」节）。

## TASK-03 窗口预览 popup + 右键菜单新增偏差

- **popup 是 overlay 内嵌件，不是独立 Wayland surface**：KOS
  `DockWindowPreview`/`ContextMenu` 为 PopupWindow（独立 QWindow）；
  Denial 走 `OverlayPortal.overlayChildLayoutBuilder`。KOS 靠两个
  surface 各自的 `pointerInside` 做 gap 桥接；移植版用覆盖 gap 的同一
  `MouseRegion` 桥带（taskbar `height + 8` 范式）。
- **KWin ScreenShot2 缩略图 → `buildWindowPreview` 实时纹理**：
  KOS 走 `WindowService.requestThumbnail`/`thumbnailUrl` 截图
  （DockWindowPreview.qml:71-82,319-407）；Denial wire 无截图通道，
  用 `services.buildWindowPreview(context, window.id)` 实时纹理
  （CONSTRAINTS §5 确认的等价物），纹理不可用时 SDK 内部回退图标。
- **预览卡「×」关闭钮省略**：KOS 每卡右上 20×20 closeBtn →
  `WindowService.closeWindow`（DockWindowPreview.qml:459-503）；
  CONSTRAINTS §5 closeWindow 协议缺口，整钮不画。
- **右键菜单砍掉 `close_all/minimize/close` 三项**：KOS pinned 分支
  还有「关闭所有窗口」、window 分支有「最小化/关闭窗口」
  （DockIcon.qml:912-924）；CONSTRAINTS §5 协议缺口全部省略，
  菜单只保留 打开/新建窗口/取消固定。
- **emphasizeWindow 联动是 Denial 新增**：KOS 预览卡无 emphasize；
  移植版按 taskbar 惯例加 300ms hover → `emphasizeWindow(id,
  monitorId:)`（`PreviewEmphasis` 逐字搬运），偏离 KOS 但与本 shell
  其他面板一致。
- **预览卡标题 `Text.Outline` → shadow token**：KOS 用黑 0.45 描边
  （DockWindowPreview.qml:449-450）；移植版用 `shellColors.shadow`
  投影近似（不硬编码颜色）。
- **预览面板是 panelGradient 玻璃，非 LiquidGlassPanel**：KOS 用
  `LiquidGlassPanel`(radius 14, surfaceOpacity 0.88, materialDepth 2)
  近似 refraction；移植版 `ShellBackdropBlur(separateChild)` +
  `panelGradient(panelBackground→panelBackgroundBottom)` +
  hairlineSoft 边（与 dock pill 同材质语义；squircle 半径 14 退化为
  circular，同 TASK-00 基线条款）。
- **多窗点击仍 MRU 轮循**：KOS 多窗点击同样 activate（弹预览只靠
  hover）；预览卡点击 = activateWindow + 关 popup，行为一致。
- **`+` 按钮 21px → 16px**：KOS 用 pixelSize 21 的文本「+」
  （DockWindowPreview.qml:265）；34×26 钮内 21px 字在 Flutter 文本
  度量下溢出，取 16px 视觉等价（仍是 textPrimary + Medium）。
- **菜单关闭走 140ms 退场（原描述已修正）**：点外/Esc 关闭时菜单播
  140ms InCubic 退场后才收 portal（`dock_menu.dart` 的
  `DockMenuOverlay` 150ms 开 / 140ms 关，`dock_preview_popup.dart`、
  `trash_icon.dart` 同款）；原描述「点外即关、140ms 仅留将来使用」与
  实现不符，已按实际行为更正。

## TASK-04 启动器 / 垃圾桶 / 清空确认弹窗新增偏差

- **垃圾桶图标 = 随包资产（Material 仅兜底）**：KOS 走系统图标主题
  `SystemIconResolver.source("trash", hasItems ? "full" : "empty")`
  （DockContainer.qml:586-588），Denial 无图标主题服务 → 改用旧 kos_dock
  的 `assets/icons/trash_full.png` / `trash.png`（NextKde 源 SVG 栅格化，
  见 `assets/README.md`）。KOS 只切图标、不切透明度，故**作废**旧描述的
  「空态灰度 + 半透」：`kDockTrashEmptyOpacity` 已删除，Material
  `Icons.delete`/`Icons.delete_outline` 只在资产解码失败时兜底。
- **不做 deposit attention 光效**：KOS `onDepositReceived →
  trashIcon.acknowledgeAttention()`（DockContainer.qml:604-609）会播
  115ms scale 1.18 / lift −6 / glow 再 210ms 回弹（DockIcon.qml:
  320-335）。Denial 侧 `TrashState` 变化只切图标，无 attention 脉冲。
- **launcher logo 原色渲染 + 包内 asset 键**：KOS 图标外观 color 模式直接
  绘制位图原作（`dock/DockIcon.qml:710-716`：`layer.enabled:
  IconAppearanceService.mode !== "color"`、`opacityMultiplier: mode ===
  "color" ? 1.0 : opacity`——单色化/降透明只在非 color 模式发生）；移植版
  按同一语义原色渲染，**作废**旧偏差（旧实现用 `textPrimary` +
  `BlendMode.srcIn` 把整张 logo 压成一个主题灰）。宿主把 kos_dock 当 path
  包依赖，故 asset 查询走包内键 `packages/kos_dock/assets/applauncher.svg`
  （`Image.asset(package: 'kos_dock')`）；`Icons.apps` 仅作解码失败回退。
- **启动器右键 display-mode 菜单砍掉**：KOS `appLauncherContextMenu`
  （DockContainer.qml:404-470）提供底部吸附/底部紧凑/屏幕居中/全屏覆盖 +
  启动台设置…；v1 固定形态（macOS 融合模式），LauncherIcon 只有 tap →
  `toggleLauncher()`，无右键菜单。
- **launcher tap 先收 active dock popup（TASK-04 第 2 轮修正）**：KOS
  `onActivate` 先 `setDockPopupVisible(activeDockPopup, false)` 再
  `AppLauncherService.toggle()`（DockContainer.qml:554-564，:601）。第 1 轮
  因 launcher 位于 `DockIconRow` 之外未接入行级协调器，第 2 轮把
  `DockPopupCoordinator` 上提到 `KosDockShell`（整 pill 单例），launcher
  tap 现先 `dismissActive()` 再 `toggleLauncher()`；原「launcher tap 不先
  收 popup」偏差**作废**。
- **垃圾桶菜单文案固定 KOS 中文**：KOS `setItems` 硬编码
  「打开回收站」「清空回收站」（DockContainer.qml:383-386），移植版
  沿用中文原文（未随 locale 切换；TASK-03 app 菜单的 en 回退只覆盖
  DockIcon 菜单）。
- **确认弹窗映射**：KOS `DesktopConfirmDialog` 是 `KosFloatPanel`
  （KWin 玻璃 + `centerOnScreen` + `backdropMode:"none"`）；移植版走
  `OverlayPortal` + fullScene 透明 barrier（点外=取消）+ 居中
  `ShellBackdropBlur(separateChild)` + `panelGradient` + `hairlineSoft`
  + radius 14（squircle 退化 circular）。
- **确认色 = `shellColors.performanceBad`**：KOS 破坏性确认文字
  `#ff3b30`（DesktopConfirmDialog.qml:160），按 CONSTRAINTS §3 映射
  语义 error 色；busy 态 = performanceBad@0.55（对应 KOS
  `Qt.rgba(1,0.23,0.19,0.55)`）+「正在处理…」+ 禁用。
- **顶部 24px help 装饰钮省略**：KOS `DesktopConfirmDialog.qml:174-199`
  右上角 24px 圆底 help 钮纯装饰（无点击行为）；移植版省略，
  内容节奏（20/12/4/22/16）与按钮几何（34 高、radius 17、margin 16、
  间距 8、各半宽）逐值保留。
- **指针广播坐标系修正（TASK-04）**：TASK-01 的 DockIconRow 内
  MouseRegion 用 `event.position.dx` 广播、DockIcon `_slotCenterX` 用
  `localToGlobal`——两者只在行恰好位于全局 x=0 时重合。TASK-04 把广播
  上移到 `KosDockShell` 整个 pill（launcher/trash/pinned 共用，对齐 KOS
  `magnificationRoot: container`，DockContainer.qml:220-228,537-538），
  并经广播端 `RenderBox.localToGlobal(event.localPosition)` 显式换算到
  与槽中心一致的全局系；DockIconRow 无 ambient 时保留自建 fallback
  （单测路径）。
- **菜单浮层抽为公共件**：`dock_menu.dart` 的
  `DockMenuPanel`/`DockMenuItem`/`DockMenuOverlay` 从 TASK-03
  `dock_preview_popup.dart` 等价提取，TASK-03 的数值（150/140ms、
  scale 0.96→1、20px 位移、clamp、gap 6）与行为逐字保留。
- **全屏时 dock 仍显示（修正原「fullscreen 时隐藏」的说法）**：KOS 在全屏
  场景靠 `DockAutoHideController`（autohide/dockSpan 触发）+ exclusiveZone
  让 dock 自动让位；CONSTRAINTS §1 明确 v1 不移植 auto-hide / reveal handle
  / exclusiveZone，**Dock 恒可见**（仅锁屏 / 壁纸选择器时隐藏）。因此全屏
  应用（游戏/视频）打开时 dock 会浮在画面上方——`KosDockPlugin.place()`
  的 `visible` 只取 `!locked && !wallpaperSelectorVisible`，这是接受的范围
  偏差，非缺陷；与之相对，KOS 的 fullscreen 自动隐藏**不再**是预期行为。

## TASK-04 收口 · 底部工作区预留与 pill 浮空（用户决定 2026-10-04）

- **dock 提供 `ShellWorkArea`（用户决定，覆盖 CONSTRAINTS §2 原文）**：
  用户要求「最大化窗口整体上浮、不要压住 dock、不需要顶栏」。本 shell 的
  工作区条带只有这一个扩展点（`denial_flutter_sdk/surfaces.dart:230-236`
  的 `@ExtensionPoint(cardinality: zeroOrOne)`），`denial_desktop` 把预留
  结果交给 `applyShellConfiguration(side:, systemBarThickness:,
  maximizePadding:)`（`denial_desktop/lib/src/core/shell_runtime_bindings.dart:
  131-142`）。`KosDockWorkArea.reserve()` 返回 `PanelEdge.bottom`、厚度 =
  `KosDockPlugin.thickness`（`dockHeight + edgeMargin + workspaceMargin`
  = 74）+ `maximizePadding`，与 `denial_taskbar` 的 `TaskbarWorkArea`
  （denial_taskbar.dart:49-60）同范式。副作用即用户期望的效果：预留把
  `side` 置为 bottom → 顶部 33px 条带不再预留（设置里的
  `layout.systemBarSide=top, thickness=33` 被运行时覆盖），最大化窗口底部
  停在 dock 之上（不再被 dock 覆盖）。
- **与 `TaskbarWorkArea` 的一处有意差异**：对方在
  `settings.systemBarSide == hidden` 时返回 null（不预留）；本插件按
  CONSTRAINTS §1「Dock 恒可见」**无条件预留**，否则一旦 side 被其它来源
  置为 hidden，dock 又会被最大化窗口压住。
- **KOS 依据**：`dock/DockWindow.qml:118-127` — `exclusiveZone =
  dockContainer.height + edgeMargin + workspaceMargin`，且仅
  `visibilityMode === "always"` 时预留；本插件恒可见，故恒预留。
- **pill 浮空边距修正（TASK-02 遗留几何）**：KOS `DockWindow.qml:177`
  `y: root.height - root.edgeMargin - dockContainer.height` —— pill 底边应
  在屏幕底边之上 `edgeMargin`（dockHeight 60 → `max(4, round(60×0.12))`
  = 7px，`kDockEdgeMargin`）。早期实现用 `Align.bottomCenter` 直接贴条带
  底边（= 屏幕底边），glass 与物理边的浮空为 0；现改为
  `Padding(bottom: kDockEdgeMargin)`，回归用例见
  `test/dock_container_test.dart` 的 pill 底边内缩用例。
- **launcher tap 收 popup 为「硬切」而非「播退场」（第 2 轮审查缺陷 4，接受）**：
  KOS `DockContainer.qml:560-562` 走 `setDockPopupVisible(activeDockPopup,
  false)`，对预览是 `DockWindowPreview.qml:93-118` 的 110ms `previewExit`、
  对菜单是 `DockContextMenu.qml:16-25` 的 `menu.close()` 退场动画；移植版
  `launcher_icon.dart` 调 `coordinator.dismissActive()`（=
  `dismissDockPopupImmediately`，KOS `DockModelService.qml:56-63` 的硬切语义），
  无 110/140ms 退场。仅在「tap launcher 时恰有 popup 开着」时可见，属
  接受的低幅度观感偏差；若要逐帧对齐需让 launcher 走播退场的关闭入口。

## TASK-04 收口 · 未 pin 运行应用进 Dock（用户决定 2026-10-05）

- **行为**：图标行 = pinned 段（pin 顺序）+ 未 pin 运行应用段（**一应用一
  图标**，按首次出现顺序）。KOS 依据 `dock/DockModelService.qml:150-200`
  （grouped：已 pin 的窗口 `continue`，其余按 canonical appId 聚合 +
  `windowCount++`，`isActivated` = 任一窗 active）。
- **仍是接受的范围裁剪**：不做逐窗口条目 / 窗口标题列表，不做 minimize /
  close / urgent（协议缺口，CONSTRAINTS §5）。
- **可拖拽范围**：只有 pinned 段可拖拽重排、可持久化；未 pin 条目不进
  ReorderableListView（方案 B 起移出 item 列表，为独立运行段 Row），
  `_reorder` 也把目标索引钳制在 pinned 段内（KOS 的 window item 同样不
  参与 pinned 重排）。
- **pin 入口**：未 pin 条目的右键菜单第三项 = KOS 的「固定此应用」
  （`DockIcon.qml:916-927` `pinned ? "取消固定" : "固定此应用"`），点击后
  追加进 pinned 尾部并按旧 schema 写回（`{kind:"app", desktopId}`）。
- **段序实现（方案 B 收敛）**：运行段顺序直接取 `dockRowEntries` 的首次
  出现顺序（纯函数单源）；`DockOrder` 已收敛为 pinned-only——
  `update(Iterable<String> pinned)` 单参数只管 pinned 相对顺序，原
  「live 集 = pinned + `run:` 运行键 → rest 合并」分支与对应测试已删。
- **目录命中回退**：窗口 appId 命中应用目录（精确 appId 或 `windowAppIds`
  唯一别名）时用目录的 name / appId / launch id；未命中则退化为窗口自身
  appId（图标仍渲染）+ 窗口标题（KOS `identity.name || title`，
  `DockModelService.qml:168-171`）。

## TASK-04b · D-1 launch id 修复 + 方案 A 行宽推导（2026-10-05）

- **pinned 图标的 launch id = catalog `LaunchableApplication.id`（D-1 修复）**：
  宿主 catalog 的 `id` 形如 `desktop:<desktopFileId>`（denial_desktop
  `shell_plugin_services.dart:85-96` + `application_recents_controller.dart:
  9-12`）；旧 schema 写回的 pin.id 是无前缀 desktopId（`toLegacyJson` 只写
  `{kind:"app", desktopId}`）。点击/「新建窗口」现都经
  `dock_row_entries.dart` 的 `dockRowEntries` 反查 catalog（`app?.id ??
  pin.id`），同旧版 `b04ecaf^:dock_host.dart:198` 的
  `launchId: application?.id ?? desktopId` 语义；catalog 未命中退化为
  `pin.id`（不崩）。未 pin 运行条目本来就用 catalog id，未受影响。
  pin↔catalog 判等由 `dockPinEntryKey` 负责：先 `normalizeApplicationId`
  再剥已知 scheme（`desktop:` 与 `local:`，显式枚举不用通用 `xxx:` 规则
  以免剥坏含冒号的合法 id），使迁移态 pin（bare id）与宿主带前缀 `id`
  落同一判等系（否则 launch-key 恒 miss、D-1 反查失效；`local:` 由
  `application_recents_controller.dart:9-12` 引入，审查修正项 1）。
  且 launch-key 直配与 `dockCatalogFor` 同守「多重匹配不猜」：同 launch
  key 命中 >1 个 catalog 条目时不取 first、落下一层 `pin.appId` 反查，
  都不唯一才退化 `pin.id`（审查修正项 2）。
- **图标行视口宽按实际条目数推导（原「按 pinned 数」作废，我方布局回归
  非 KOS 语义差异）**：`dock_shell.dart` 的 `iconRowNatural` 原只按
  `prefs.pinned.length` 算，但行内渲染 pinned + 未 pin 运行条目
  （CONSTRAINTS §5 修正 2026-10-05 起）→ 未 pin 条目必落视口外。现由纯
  函数 `dockRowEntries`（`lib/src/state/dock_row_entries.dart`）统一推导
  `n*(slot+spacing)-spacing`，`dock_icons.dart` 用同一函数渲染，视口
  不再漏算运行条目（方案 A）。配套修正：`ReorderableListView` 的
  `itemExtent`（固定值）换成 `itemExtentBuilder`——固定 extent 让**每个**
  条目都占 `slot+spacing` 滚动长度，可滚内容宽比视口自然宽多一个
  `spacing`，出现 `maxScrollExtent == spacing` 的假可滚；末位条目改报
  `iconSlotSize`（其外侧 Padding 无 spacing）后，内容宽恰等于
  `n*(slot+spacing)-spacing`（方案 C 起该列表已 `NeverScrollable`，
  此修正只保「不假性可滚」的语义正确）。
- **图标行 RawScrollbar「白条」临时项已随方案 C 删除**：原在行内
  `ScrollConfiguration` 加 `scrollbars: false` 只去白条不改可滚；方案 C
  反解使内容恒 ≤ maxWidth，`ReorderableListView` 改 `NeverScrollable`，
  scrollbars 兜底不再需要（保留 `ScrollConfiguration` 仅剥离 mouse
  dragDevices 作拖拽重排 workaround，与滚动无关）。

## TASK-04b · 方案 B：KOS 分段 + launchers|windows 分割线（D-3 修复）

- **段序对齐 KOS `DockContainer.qml:496-962`**：图标区内部 =
  `pinned 段 ReorderableListView → divider1 → 未 pin 运行段 Row`
  （对应 pinnedRepeater :612-845、divider :847-857、windowsRepeater
  :859-862）。**作废**旧临时描述「未 pin 条目混在同一条可滚 pinned
  行内」：未 pin 条目不再进 ReorderableListView 的 item 列表，重排与
  `DockOrder` 只管 pinned 段（`_reorder` 的 pinnedCount 边界钳制保留作
  防御）。
- **divider1(launchers|windows) 可见性** =
  `pinnedCount > 0 && runningCount > 0`（KOS: DockContainer.qml:847-857，
  `visible:` :856）；实现上插在 `DockIconRow` 图标区内部两段之间
  （`dock.row.pinned` / `dock.row.running` 槽位之间），宽度计入图标区
  自然宽/预算（`iconRowNatural` += divider 槽宽），不进外层
  `fixedSlots`。
- **divider2(windows|info)** = `infoCard != null && entryCount > 0`
  （KOS: DockContainer.qml:907-913，`visible:` :912 `hasInfo &&
  (pinnedCount + windowCount > 0)`——launcher/trash 不计入 window 计数，
  语义从旧「hasIcons && infoCard」收敛）；**divider3(info|tray)** =
  `trayAccessory != null && (hasIcons || infoCard != null)`（:951
  `trailingAccessoryDividerVisible`，沿用旧语义未改）。
- **滚动兜底已随方案 C 整段移除**：方案 B 的「pinned 段自滚 + 运行段
  ClipRect+OverflowBox 收缩吸收溢出」分支删除，`ReorderableListView`
  改 `NeverScrollableScrollPhysics`（重排走 drag listener 不依赖滚动）；
  方案 C 用 `DockMetrics.fromWidth` 反解保证内容恒 ≤ maxWidth。

## TASK-04b · 方案 C：KOS iconSize 反解（`DockMetrics` 运行时尺寸对象）

- **编译期尺寸常量 → 运行时 `DockMetrics`**：原 `kDockIconSlotSize`/
  `kDockItemSpacing`/`kDockDividerMargin`/`kDockEdgeMargin`/
  `kDockInfoSlotWidth` 等常量收敛进 `DockMetrics.fromWidth(availableWidth,
  {pinnedCount, runningCount, showLauncher, showTrash, hasInfo, hasTray,
  infoUnits, maxLengthRatio})`——逐项移植 `AdaptiveMath.computeLayout`
  （AdaptiveMath.mjs:62-166）：`scaleFactor = iconUnits + (appIconCount +
  hasInfo)*2*0.1 + max(0,itemCount-1)*0.09 + 2*dividerCount*0.20 + 2*0.40`
  （:115-120）；`fixedOverhead = dividerCount * dividerWidth`（:122，我方
  dividerWidth 恒 2，KOS 此式用 DEFAULT 1，+dividerCount px 偏差）；
  `iconSize = baseIconSize*scaleFactor + fixedOverhead <= maxWidth ?
  floor(baseIconSize) : floor((maxWidth - fixedOverhead)/scaleFactor)`，
  `clamp(iconSize, 18, 100/1.4≈71.4)`（:129-138）；再由 iconSize 派生
  `dockHeight/itemSpacing/hPadding/vPadding/dividerMargin/pillRadius/
  dockWidth/activeBackgroundGap`（:140-150）。经 `DockMetricsScope`
  （InheritedWidget）下发给 DockIcon/DockControlIcon/divider/整行。
- **槽位映射偏差（如实记录）**：KOS `appIconCount` 只含 pinned+window，
  launcher/trash 是 pinnedRepeater 之外的固定 DockIcon 仍计入 Row 链与
  itemSpacing；我方 launcher/trash 为同规格 `DockControlIcon`，反解里按
  app icon 计入 `iconUnits`。tray 槽 KOS 走 `estimatedAccessoryWidth`
  预扣（`accessoryCount * baseHeight * 0.60`，DockContainer.qml:124-133），
  我方托盘槽固定 1 个 icon slot 按 1 icon unit + 2×gap 计入——两式不同。
  KOS `dividerCount` 只数段内 divider（pinned|windows、windows|info，
  :88-89），我方把 divider3(info|tray) 同样计入（它占 Row 槽位）。
- **pill 宽 = `metrics.dockWidth`**，取 `max(contentWidth, renderedWidth)`
  再 clamp 到 `maxWidth`：`contentWidth = iconSize*scaleFactor +
  fixedOverhead` 用未取整比例，而布局用 round 过的 spacing/hPad/
  dividerMargin——取整使渲染宽最多比估计宽 ~1px（800 宽 2 pinned 实测
  溢出 0.62px → RenderFlex overflow 硬失败），故按真实渲染几何取 max。
- **spacing 烘焙位置偏差（既有，非方案 C 引入）**：KOS Row 相邻项间统一
  `spacing: itemSpacing`；我方 `itemSpacing` 只烘进 pinned/running 条目
  `EdgeInsets.only(right:)` 与 divider margin，外层 Row 槽位
  （launcher/trash/图标区/info/tray）间无间距 → 真实渲染宽比 KOS 少
  ~(itemCount-1 − 段内间距数)*itemSpacing，pill 由 dockWidth 给出仍会略宽
  （≈1 个 spacing 余量，视觉可忽略）。
- **thickness/ShellWorkArea**：`place()`/`reserve()` 在插件装载契约层拿不到
  `dockPreferencesProvider` 会话态 → `thicknessForWidth(outputWidth)` 按
  基准配置（launcher+trash 默认开、无运行窗/info/tray）对该输出宽反解
  `stripThickness`；`thickness` getter = `thicknessForWidth(1920)`
  （worst-case 预留，≤~34px 过预留）。1920 基准 iconSize=42 → dockHeight=59、
  edgeMargin=7 → 条带 73（原常量 74）。
- **滚动兜底整段移除**：`dock_shell` 超宽分支、`dock_icons` 的 LayoutBuilder
  预算 clamp、pinned 段自滚、运行段 `ClipRect+OverflowBox` 收缩、
  `scrollbars:false` 白条兜底全部删除；`ReorderableListView` 改
  `NeverScrollableScrollPhysics`。
- **MIN_ICON_SIZE 触底 → 摘掉 info 槽（`hideInfoCarousel` 已移植）**：iconSize
  被 clamp 在下限 18、`18*scaleFactor + fixedOverhead > maxWidth` 时（极窄输出 +
  多图标单位），`dockWidth` 被 clamp 到 `maxWidth` 而真实内容宽超出 →
  RenderFlex overflow；且真槽比 `DockMetrics.fromWidth` 的 `renderedWidth` 多出
  `0.2*iconSize`（cardGap 外延未计入反解）。KOS 的兜底是 `hideInfoCarousel`
  （`DockContainer.qml:130-137,141-143`：`_infoProbeLayout` **带上 carousel**
  反解，`iconSize <= MIN_ICON_SIZE` 即摘掉 info 槽及其 divider，把 4 个图标单位
  还给条目、`hasInfo` 随之 false；先探针再摘是为避免「摘掉 → 图标变大 → 又出现」
  的反馈环）。本端 `dock_shell.dart` 同式移植（`hasInfo = hasAvailableInfo &&
  probeMetrics.iconSize > MIN_ICON_SIZE`，摘掉时按 `hasInfo=false` 复解几何），
  原「未移植」条目撤销。**实测**（`test/dock_info_carousel_test.dart` 的
  「iconSize 触底」组）：@1920/500/320 → iconSize 42/42/29，不触发；@190 → 探针
  触底 18，摘除后无 overflow（未移植时实测 `RenderFlex overflowed by 1.8 pixels`）；
  @210 → iconSize=19（下限之上）保留 info 槽且无溢出。

## TASK-05 · 信息卡区（carousel：clock/weather/metrics/music）

- **装饰层省略**：天气卡的云/太阳/雨装饰层（`DockWeatherWidget.qml:69-157`，
  BundledIcons 资产 + 旋转光线/雨滴 Repeater）无对应打包资产 → 整段省略；
  卡背 8 组 weatherCode 字面 RGBA 渐变（`:19-40`）→ 统一
  `panelGradient(panelBackground, panelBackgroundBottom)` 语义渐变。
- **clock 玻璃字形降级**：iOS 玻璃字形/折射层（`DockClockWidget.qml:144-204`
  ambientTexture/FastBlur/glyphSheen OpacityMask）→ `shellColors.textPrimary`
  文本样式；ambient 壁纸渐变（`:96-121`）→ 语义 panelGradient。
- **卡背 squircle → BorderRadius**：carousel 卡背 squircle → `BorderRadius.
  circular(iconSize*0.35)`（`kDockInfoCardRadiusRatio`，CONSTRAINTS §4 允许退化）。
- **详情面板统一**：KOS 只对 clock/weather 页开 `DockInfoPopup`（music 走
  `DockMusicPopup`、metrics 页内嵌 `TemperatureSensorPopups`，
  `DockInfoCarousel.qml:253-277`）；本端四页统一走 `DockInfoPopup` 式键值面板
  （`DockInfoPanel`），music/metrics 的行内容为本端补的投影
  （标题/歌手/专辑/进度、CPU/内存/存储）。`DockMusicPopup` /
  `TemperatureSensorPopups` 不移植。
- **封面不抓网络**：KOS `Image` 可直抓 http(s) `artUrl`；本端仅接受本地绝对
  路径 / `file://`（经 `services.imageBytes`），http(s)/空 → 占位 music glyph
  （记 `info_carousel.dart` `_localArtPath`）。
- **clock 秒 tick 自建驱动**：`services.clock` 无值/不 tick 时由 carousel
  `Timer.periodic(1s)` 刷新 `_clockNow`；有真 tick 时 1Hz setState 幂等重绘。
- **metrics CPU 环来源**：CPU 占用直接消费 `services.cpu`（SDK `LoadSeries`），
  `ProcfsDockMetricsCollector` 不重复 `/proc/stat` 差分；温度/内存/磁盘来自
  自采 `/proc` + `df`。
- **metrics 环色/温度 accent 字面保留**：KOS 三环 `#ff375f`/`#30d158`/`#64d2ff`
  与温度 accent `#64d2ff`/`#ff6b62` 字面色保留（任务卡批准，见
  `dock_tokens.dart` 注释）；温度行 accent 点经语义映射走
  `textSecondary`/`performanceBad`。
- **expanded 模式 v1 不做**：`infoCardMode` 只读、非 `carousel` 值读侧 clamp 为
  carousel（`DockPreferences.fromJson`）；KOS `expanded` 多卡并排布局未移植。
- **歌词/桌面歌词不做**：无 `kos:` MPRIS 歌词扩展键（CONSTRAINTS §5），卡面
  只标准字段（标题/歌手/专辑/进度）。
- **右键编辑不做**：KOS `editRequested` → DockComponentEditor（
  `DockInfoCarousel.qml:237-241`）v1 无编辑器，整段忽略。
- **marquee 停顿近似**：KOS `trackScroll`/`compactTrackScroll` 的
  `PauseAnimation` 段用 `TweenSequence` 的 Constant 段近似（时长逐值对齐：
  1200/`max(900,溢出*35)`/800、900/`max(800,溢出*32)`/650）；滚动动画由
  `AnimationController.repeat()` 驱动。
- **music 信息列高度**：`DockMusicCard` 的封面+信息 Row 取卡高（iconSize）
  而非 `artSize`，使 full 态 marquee + 三圆钮竖向叠放不溢出（半成品修正）。
- **weather available 判定**：KOS 以 `current !== null` 判 available
  （`WeatherService.qml:30`），本端投影只在 `status=='ready'` 帧携带 current
  字段，故等价为 `status=='ready'`。
- **music 控制钮**：`MediaControlButton` 玻璃圆体 → `textPrimary` 低 alpha 实体
  圆钮近似（primary 0.20 / 普通 0.12）。
- **紧凑行 scaleDown 兜底**：`clock/weather/metrics` 的 compact 单行
  （`DockClockWidget.qml:272-306` 等）在 KOS 里落在 carousel `clip` 内、超出
  卡宽时被静默裁切；本端外层套 `FittedBox(fit: scaleDown)`，宽字形（等宽/
  CJK 全角）下按比例缩进卡内而不是触发 debug 溢出横幅。正常字体下
  （数字 `0.5em`）两者渲染一致。**实测**（iconSize=27 紧凑档、flutter_test
  等宽测试字形）：三卡紧凑行自然宽均 > 卡宽 113.4（clock 171 / weather 128 /
  metrics 128），兜底**确实被触发**（缩放比 0.66/0.89/0.89）；E-5 用例
  （`dock_info_carousel_test.dart`）因此断言「紧凑行自然宽 > 卡宽」+
  「缩放后落卡内」+「非恒等缩放」，而不是只断言不抛异常（后者被 FittedBox
  的无界布局架空，对任意 fixture 恒真）。
- **hover 暂停轮换为本端新增（KOS 无）**：KOS `carouselTimer.running` 只有
  `autoRotate && !expanded && availablePageCount > 1`（`DockInfoCarousel.qml:
  205-213`），**没有** hover 项——hover 只驱动 `infoPopupOpenDelay/
  infoPopupCloseDelay`（`:279-312`）。本端按任务卡要求实现「指针在槽内暂停、
  离开即按 `Timer.restart` 语义重计 30s」（`info_carousel.dart` 的 `_hovered`
  + `_syncCarouselTimer`）。
- **滚轮切页方向取反**：本端 `delta > 0`（向下滚）→ 下一页
  （`info_carousel.dart`），与 KOS `switchPage(true, delta >= 0 ? -1 : 1)`
  （`DockInfoCarousel.qml:231`）相反；180ms wheel cooldown 与 KOS 同
  （`:215-235`）。
- **`hasInfo` = `hasAvailableInfo`（空 order 或零可用卡 = 隐藏信息卡区）**：
  KOS `hasInfo = hasAvailableInfo && !hideInfoCarousel`（`DockContainer.qml:143`），
  `hasAvailableInfo = hasPlayingMusic || hasWeather || hasClock || hasTemperature`
  （`:46-58`：music 需播放器可用、weather 需 `WeatherService.available`，
  clock/metrics 恒可用——`:54-56` 注释明确 metrics 首帧未就绪也常驻显 `--`）。
  本端 `KosDockShell` 同式推导：order 里至少一页可用才置 `hasInfo`（clock/metrics
  恒真、music 看 `services.media.available`、weather 看
  `dockWeatherSnapshotProvider`），零可用卡时整区摘除（不留 4.2×iconSize 空槽、
  不留 divider2）；`dockPreferencesProvider` 保留空 order（`fromJson` 读侧三态）。
  与 KOS 一致，**不做**额外降级（如「order 非空但无数据也照显空卡」）。

- **天气订阅按卡片集合收敛（KOS `WeatherService` 是全局常驻服务）**：KOS 侧
  `WeatherService` 是 shell 全局服务、常驻刷新，与「哪几张信息卡被选中」无关
  ——`DockContainer.qml:48-49` 只用 `infoCardSelected("weather") &&
  WeatherService.available` 决定 weather 卡是否**可用**。本端把
  `dockWeatherSnapshotProvider` 的**订阅本身**收敛到卡片集合：门控 =
  `prefsAsync.hasValue && dockInfoCardNeedsWeather(infoCardOrder)`，判据
  「order 含 `weather` **或** 含 `clock`」以单一函数定义在
  `lib/src/data/dock_preferences.dart`（`KosDockShell` 的 `weatherGate` 与
  `DockInfoCarousel` 的 `_weatherGateOpen` 共用，避免两处表达式漂移）。
  理由：该 provider 一经订阅即构造真实 provider 并 `start()` 网络轮询
  （Open-Meteo HttpClient + 状态文件 + 1min Timer，
  `state/dock_settings.dart:63-67`），且是 keepAlive（不 autoDispose，
  `:45-52`）——「order 只剩 music/metrics」的会话若照旧订阅，会白起轮询且
  此后不会自行停。**默认四卡恒订阅**（与 KOS 常驻语义一致）；仅当 order 既无
  `weather` 也无 `clock` 时才不订阅。**clock 页不能被 weather-only 条件
  门控**：`DockClockWidget.qml:63-92` 的 `SolarEventRow` 读
  `WeatherService.sunriseTime/sunsetTime`，本端走同一份
  `DockWeatherSnapshot`，故判据必须含 `clock`；门控关闭时天气快照取 null →
  weather 页不可用、clock 页日出/日落退化为 `--:--`（与 KOS 无数据同）。
  carousel 的三个非 build 读点（`initState` 的 `_syncCarouselTimer`、
  `_ensureValidPage`、`_switchPage`）也走同一门控（`_gatedWeather()`）：
  `ref.read` 对尚未被订阅的 `StreamProvider` **同样会初始化它**，漏掉这几处
  等于门控失效。同类收敛也用于 music：shell 的 `hasAvailableInfo` music 项与
  carousel 的 `hasMusic` 都取 `order.contains('music') && media.available`，
  order 不含 music 时 shell 不再订阅 `services.media`（避免媒体 tick 触发整
  pill 重建）。

## 修复（TASK-05 复审反馈，2026-10）

- **详情 popup 是 hover tooltip 不是 modal 菜单**：`DockInfoOverlay` 初版按
  菜单范式做了 `ShellInputRegion(pointerPolicy: fullScene)` 全屏输入区 +
  `ShellKeyboardPolicy.capture` + `Focus(autofocus)` + `Positioned.fill` 点外
  即关层——这会把整张桌面的指针/键盘事件全拦下，popup 反复弹出/消失（缺陷
  1）。改为对齐 `dock_preview_popup.dart` 的 hover popup 范式：`ShellInputRegion`
  退回默认 `childBounds`（输入区 = 面板矩形），去掉 fullScene / 键盘捕获 /
  `Focus` / 点外即关层。收场完全靠 `onPointerInsideChanged`（KOS
  `pointerInside` HoverHandler，`DockInfoPopup.qml:22,219-221`）+
  `infoPopupCloseDelay`（`DockInfoCarousel.qml:304-312`），popup 本体无 Esc /
  点外通道——与 KOS `DockInfoPopup` 一致（它也没有 dismissal 通道）。
  容器高度加 `kDockInfoPopupGap`（12px）桥带：`Positioned` `top = anchor.top
  - gap - panelHeight`、`height = panelHeight + gap`，`MouseRegion` 整覆含底部
  桥带的整个 Positioned（桥接卡槽→popup 的 12px 真空，等价 KOS `pointerInside`
  跨 surface 桥接），面板 `Align(topCenter)`。150/140ms 显隐动画与
  `ConstrainedBox(maxHeight)` 保留。
- **popup 开着时轮换停表且不跟随切页（偏差：KOS popup 跟随 hoveredPage）**：
  KOS `carouselTimer.running`（`DockInfoCarousel.qml:205-213`）无「popup 开着」
  项，popup 锚定 `hoveredPage`（`:317` `infoPopup.page: carousel.hoveredPage`）
  ——轮播切页会把 popup 内容带走。本端 `hoveredPage`≈`_page`，轮播切 `_page`
  会让详情面板内容跳走（缺陷 2）。改为：`_syncCarouselTimer` 在
  `_portalController.isShowing` 时不建表；`_followPopupPage` 在 popup 开着期间
  冻结 `_popupPage`。指针移到别的卡上由 hover 重触发 `_openPopup` 换内容
  （保持简单，不做 KOS 的实时跟随）。
- **天气城市复用 deskcenter 设置（KOS 是 shell 全局 WeatherService）**：KOS 的
  weather 是 shell 全局 `WeatherService`，城市由 deskcenter 设置页写共享状态
  文件（kos_deskcenter `weather_provider.dart:294-307`）；本端 dock 无法走
  全局服务，改为经 `DockDeskCenterLocationSource`（接口在 `dock_weather.dart`，
  实现 `FileDockDeskCenterLocationSource` 在 `dock_weather_io.dart`）**只读**
  复用 deskcenter 的 `$XDG_STATE_HOME/denial/kos_deskcenter/weather.json`。
  路径序 `KOS_PIM_STORAGE_DIR`→`$XDG_STATE_HOME/denial/kos_deskcenter/`
  `weather.json`→`$HOME/.local/state/...` 与 deskcenter `_defaultStatePath`
  一致。回退链：deskcenter `location`（子对象或顶层平铺旧格式，
  `DockWeatherLocation.fromJson`+`.valid`）→ dock 自己的 `weather.json` →
  `kDockWeatherDefaultLocation`（长沙，`weather.go:151-154`）。吉安等城市设置
  由 deskcenter 接管（缺陷 3）。
- **时钟 `now` 用 1Hz `_clockNow` 而非 `services.clock` 分钟流**：KOS
  `SystemClock precision: Seconds`（`DockInfoPopup.qml:41-44` /
  `DockClockWidget.qml:27-30`）驱动 HH:mm:ss 秒级重绘。本端 `services.clock`
  是分钟级快照流，首版把它当 `now` 主源（`ref.read(services.clock).value ??
  _clockNow`），分钟快照一覆盖 `_clockNow` 秒就停（缺陷 4）。改为时钟卡与
  详情行的 `now` **恒取** 1Hz `_clockTicker` 刷新的 `_clockNow`；
  `services.clock` 对秒字段无价值故不取。`_clockTicker` 的 1Hz setState 重绘
  保留。

## TASK-06 · 托盘区（trailing accessory：托盘项 + battery 状态格）

移植 KOS `BarStatusArea{dockHosted:true}`（bar/BarStatusArea.qml + bar/SysTray.qml
+ bar/Battery.qml）。以下为本任务新增偏差：

- **托盘排序只维稳、不持久化、不支持拖拽改序**：KOS `SysTrayOrderService`
  提供 Alt+拖拽重排与持久序；v1 只实现 denial_taskbar `tray.dart:56-77` 的
  `_orderedIds` 语义（消失 id 移除、新 id 追加尾部、宿主重排不搬动），
  任务卡允许 v1 砍掉持久化/拖拽。
- **宿主 wrap 间距 8 ≠ KOS iconSpacing 6**：折两行时 `buildSystemTray(wrap:true)`
  的宿主 `Wrap` 固定 `spacing/runSpacing: 8`（host `system_tray_module.dart`），
  KOS `SysTray.iconSpacing: 6`（SysTray.qml:13）；列宽约束按 KOS 几何
  `ceil(itemCount/2)` 列给出（SysTray.qml:182-187），实际渲染间距由宿主定。
- **托盘项图标尺寸由宿主决定**：KOS dockHosted 托盘 `iconSize: 18`、
  `itemSize: 26`（SysTray.qml:12,32）；本端宿主 `buildSystemTray` 内部
  `_SystemTrayButton` 为 `SizedBox.square(22)`、非 wrap 间距 4 —— 与 KOS
  18/26 不一致，插件无法指定。
- **托盘项激活/菜单弹出方向不受插件控制**：`buildSystemTray` 的激活与
  菜单由宿主全权渲染（services.dart:134-136 注释），KOS 托盘右键菜单
  自绘弹层不做。
- **状态格只剩 battery 一格**：KOS `trailingCells`（BarStatusArea.qml:26-34）
  的 network / controlcenter / settings 在 Denial SDK 无对应面板与开关 →
  隐藏，不伪造占位；clock 已由融合信息卡承担（clockInInfoCarousel）。
- **battery 格点击 = `openPowerSettings()`**：KOS `Battery.qml` 本体无点击
  行为、只有 hover `StatusTooltip`（Battery.qml:87-101）；「电源菜单入口」
  是任务卡指定映射，非 KOS 行为。自绘 tooltip popup 不做（任务卡条件句）。
- **battery 配色字面 → 语义映射**：KOS `fillColor` 字面
  `#30d158`/`#ff9f0a`/`#ff453a`（Battery.qml:111-118）→ `theme.accent` /
  `colors.performanceWarning` / `colors.performanceBad`；`ShellColorScheme`
  无 success 绿语义，>95 档用 accent（最接近的语义角色）。描边/电极 =
  `textPrimary`；bolt 中段走 `performanceWarning`、其余 `textPrimary`。
- **tray 槽宽回流 `dockWidth`（`estimatedAccessoryWidth` 等价）**：KOS 用
  `estimatedAccessoryWidth` 从可用宽预扣（DockContainer.qml:111-133）且
  `trailingAccessory` Loader 的 `width: item.implicitWidth` 参与 Row 自然宽
  （DockContainer.qml:954-959）。本端 `KosDockShell` 按托盘项数 + battery 格
  算 `dockTrayEstimateWidth` 估算宽，经 `DockMetrics.fromWidth(trayWidth:)`
  回流——槽位按 1 个 icon unit 保底计 iconSlotSize，估算宽超出槽宽的部分以
  固定 px 计入 `contentWidth`/`renderedWidth`/`dockWidth`；渲染时 tray 槽 =
  `max(iconSlotSize, trayWidth)`，内容右对齐排在槽内，不外延、不遮
  divider3/info、不被 pill `ClipRRect` 裁掉（原 `OverflowBox` 左外延方案会
  遮相邻槽位并被裁切，审查缺陷 D1 修复）。估算宽按 KOS 几何（itemSize 26 +
  iconSpacing 6）偏保守偏宽，多余空白留在托盘内容左侧槽内。与 KOS 的口径
  差异：KOS 从 `availableLength` 预扣配件宽（配件不挤压 iconSize 上限），
  本端把托盘宽计入 dockWidth 内部分——方向不同、视觉等价。另：KOS
  `trailingAccessoryReserveWidth = layoutMaximumWidth`（单行宽）只喂高度
  求解器、最终 dock 宽用折行后实宽（DockContainer.qml:107-120）；本端
  反解与槽宽恒用单行估算，两行时 pill 比 KOS 宽出（单行宽 − ceil 列宽），
  方向保守、记档（第 2 轮审查观察）。
- **空托盘区时 tray 槽与 divider3 整段不渲染**：`hasTray =
  trayEstimateWidth > 0`（shell 层 watch `services.trayItemIds`/`services.
  battery` 推导，与挂件内 itemCount 同式）——托盘 0 项且无 battery 时
  tray 槽、divider3 都不出现（KOS `trailingAccessoryDividerVisible`
  DockContainer.qml:951 同语义）。`services.trayVisible`（宿主
  `items.isNotEmpty`）未消费：它只看托盘项不含状态格，与 hasTray 口径
  （托盘项 + battery 格）不等价，故用估算宽推导。
- **battery `IconAppearanceService` tint 分支不移植**：KOS Battery.qml 有
  icon tint 服务分支（彩色/单色图标外观）；Denial 无图标外观服务，电量格
  恒用自绘 outline+fill+battery tip。
- **两行时 shell 格排在宿主 Wrap 之外**：KOS `SysTray` 把 shell cell 混排进
  同一网格（`allKeys` 计入 itemCount/列数）；本端 `buildSystemTray` 的
  Wrap 只含托盘项，battery 格是托盘 Row 的尾随兄弟（宿主 Wrap 无法注入
  自绘格）。
- **状态格隐藏配置未移植（能力缺口）**：KOS
  `AppearanceConfigService.hiddenStatusCells`/`isStatusCellHidden` 允许按设置
  隐藏单个状态格（BarStatusArea.qml:34-35 `visibleTrailingCells`）；v1 无格
  可见性配置，battery 格恒按 `capacity != null` 判定，记为能力缺口。
- **充电判定 PendingCharge 折叠**：KOS `isCharging = Charging ||
  PendingCharge`（Battery.qml:108-110）；SDK `BatteryStatus` 只有
  `charging` bool——PendingCharge 是否折叠进 charging 由宿主/SDK 侧决定，
  插件不可见，记档。
- **battery 格命中区 = 26px 槽**：KOS 格占满 `itemSize` 槽（SysTray.qml:
  503-504 `width: slotWidth`）；本端格体 `SizedBox.square(kDockTrayItemSize)`
  = 26×26，图标本体 21px（`systemTray.iconSize + 3`，BarStatusArea.qml:115）
  在槽内左对齐——KOS 是 `anchors.centerIn` 居中，本端 centerLeft 保持格
  左缘与托盘项排布对齐（微小视觉偏差）。

## TASK-08 · 托盘 Wi-Fi / 蓝牙状态格 + 弹层面板

移植 KOS `bar/NetworkStatus.qml` + `bar/WifiSignalIcon.qml` +
`bar/NetworkPanel.qml` + `bar/BluetoothPanel.qml` + `bar/StatusTooltip.qml` +
`common/PopupMotion.qml`。以下为本任务新增偏差与 SDK 缺口：

- **状态格点击穿屏障语义降级**：KOS 面板是独立 Wayland PopupWindow，点击
  其他托盘格由 compositor 转交主 surface——「关 A 面板 + 开 B 面板」一次
  点击完成。Denial `OverlayPortal` 单树模型下 fullScene 屏障（opaque）
  吃掉这次点击：第一次点其他格只关当前面板，需再点一次才开新面板
  （`DockMenuOverlay` 同范式；translucent 穿透过热区实测被 Overlay 的
  吸收层截获，不可行）。
- **SDK 缺口 · Wi-Fi 详情字段**：KOS `NetworkService` 暴露
  `connectionType`（连接速率/频段类型）、`connectivity`（连通性分级：
  完全/受限/无门户）、`ipv4`（当前地址）、`savedProfileUuid`（已存档配置
  uuid）；SDK `NetworkSnapshot`/`WifiNetwork` 均无对应字段 → 面板副文案
  只画 SSID + 安全类型，速率/连通性/IP 行不做（不伪造假数据）。
- **SDK 缺口 · enterprise/802.1x**：KOS 面板能弹 enterprise 认证（用户名+
  密码域）；SDK `WifiSecurity` 有 `enterprise` 枚举但 `connect()` 签名只收
  `String? password`、无 username/域 → enterprise 网络按加密无档处理（弹
  密码框，字段不足以真连企业认证），密码框只喂 `password`。
- **SDK 缺口 · settings.open**：KOS 面板底脚「无线局域网设置…」/
  「蓝牙设置…」开系统设置页（NetworkPanel.qml:548-560 /
  BluetoothPanel.qml:186-198）；`ShellServices` 无 settings.open 等价物 →
  底脚渲染但 `onTap: null` 禁用态（文本降透明度、无 hover），记档待 SDK
  补能力。
- **SDK 缺口 · 蓝牙设备电量**：KOS `BluetoothPanel` 设备行右侧画电量
  百分比（BluetoothPanel.qml:120-148，`battery` 字段）；SDK
  `BluetoothDeviceInfo` 无电量字段 → 行尾只画连接 ✓/信号，电量槽不做。
- **Wi-Fi 格图标分档口径**：KOS `WifiSignalIcon` 四弧档（`strength` 分档
  阈值见规格），格图标映射 `dockWifiSignalLevel`（<30/<60/≥60 → 1/2/3 弧，
  disabled/未连接 → 0 弧）；列表面行用 `dockWifiRowSignalRings`
  （<25/<50/≥50 → 1/2/3 环，KOS 列表行分档阈值不同，已按行口径实现）。
- **面板动画常数走 dock menu 令牌**：KOS `PopupMotion`/`AppearanceTokens`
  `popupOpenDuration:150`/`popupCloseDuration:140`/`popupStartScale:0.96`
  复用 `kDockMenuOpenDuration`/`kDockMenuCloseDuration`/`kDockMenuEnterScale`
  （同值同语义，不再开新令牌）。
- **squircle → circular**：面板圆角 Wi-Fi r19 / 蓝牙 r20 用
  `BorderRadius.circular`（KOS `LiquidGlassPanel` squircle 退化，同
  TASK-00 基线条款）。
- **`requestScan`/`refresh` 推迟到帧后**：KOS `open()` 同步调
  `refreshWifiNetworks()`/`refreshBluetoothDevices()`；riverpod 禁止 build
  内改 provider → 面板首帧 `build` 标记后置 `addPostFrameCallback` 发一次
  （`_scanRequested`/`_refreshRequested` 去重；overlay 首帧之后执行，语义
  等价）。
- **格 tooltip 为自绘 `OverlayPortal`**：KOS `StatusTooltip` 黑底 r7 向上
  弹 6px（bottom dock）；本端同式 OverlayPortal + `overlayChildLayout
  Builder` 锚定，屏内 clamp `kDockPopupEdgeMargin`。battery 格沿用语义
  label（不自绘 tooltip，沿用 TASK-06 记档）。

## TASK-09 · 控制中心格 + 弹层面板

移植 KOS `bar/ControlCenterToggle.qml` + `bar/ControlCenterPanel.qml`（3037 行）
+ `bar/ControlCenterSlider.qml`（→ `shared/qml/controls/LiquidSlider.qml`）+
`common/PageMotion.qml` + `common/PopupMotion.qml`。以下为本任务新增偏差与
SDK 缺口：

- **布局紧凑重排（任务卡决议）**：通知历史卡（Panel:1293-1443，无 SDK 数据
  源）与 5 张 52px 胶囊卡（截图/深色模式/电源/勿扰/夜灯，:909-1129）v1 整段
  隐藏 → 亮度/音量条由 KOS 的 `offsetTop 217/282` 上移至 **155/220**，主页面
  内容高 297（KOS `controlCenterHeight: 597`）；面板容器高 460
  （= 最高子页 sound 420 + 上下 20），主页面与子页卡都**底对齐**容器（KOS
  dockHosted 子页 `offsetTop = height - 20 - cardHeight`，:1838-1840 同语义）。
- **无面板级玻璃底板**：KOS 窗口 blur region = 各可见卡 `blurRegion` 的并集
  （Panel:268-290）——本端沿用：面板本身透明，每张卡各自
  `ShellBackdropBlur`（`DockStatusPanelSurface`）。容器 460 高时主页面区上方
  留 163px 空白，点击该空白落回 anchor 屏障 → 点外即关（KOS 独立 popup 窗口
  整窗收输入，`mask: interactive ? null : emptyRegion`，:39）；卡间隙同
  （本端在内容区加了一层透明 opaque `Listener` 吸收）。
- **「坍缩回源胶囊 morph」砍掉**：KOS `submenuMorph`/`morphRect` 把子页卡
  rect + 圆角双插值到源胶囊（:1845-1852,:1880-1892）——v1 用 crossfade
  （displayed 0→1 / outgoing 1→0）+ `scale 0.96↔1` + 入场内容 `+8px` 位移
  近似（KOS :347-371）；源胶囊半径插值不做。
- **滑条（`DockControlCenterSlider`）简化**：LiquidSlider 的 thumb 展开
  （hover 0.35 / press 1.0，270ms OutBack overshoot1.36 / 460ms OutQuint）+
  wobble squash-stretch（0.175/-0.08/0.04/0，100/150/120/100ms）+ 玻璃透镜
  色散/折射/高光不做；thumb 恒 36×18 r9。**颜色走语义 role**：轨
  `brightnessTrack`/`volumeTrack`、进度 `theme.accent`、thumb
  `colors.sliderThumb`（KOS glass 为 `rgba(1,1,1,0.17)`/`0.42` + `#ffffff`
  字面色，CONSTRAINTS §3 要求映射）。两阶段
  `previewChanged`/`commitRequested` 语义保留（无 `canceled` 的服务端回写
  400ms 屏蔽窗口）。
- **控制中心格 glyph 自绘**：KOS 是 BundledIcon `control-center` 工程图形
  （双滑杆 mark，ControlCenterToggle.qml:7-8）；Icons 无同款 → 本端自绘
  两条滑杆 + 圆钮（18px 画布）。透明度（panelOpen 1.0 / 关 0.88）、scale
  （press 0.90 / hover 1.06 / 常态 1，135ms OutCubic）、tooltip
  「控制中心」（minWidth 92、panelOpen 时隐藏）逐值对齐。面板开合态经
  `DockStatusPanelOpenScope`（anchor 下发）——KOS 直接绑 `panelOpen`。
- **panel 与格的间距**：KOS dockHosted `margins.bottom: 0`（面板底边贴格顶，
  Panel:49-50）；任务卡要求「同 Wi-Fi 面板 8px」→ 取 `8`
  （`kDockControlCenterPanelGap`）。
- **SDK 缺口 · mute 通道**：KOS 音量卡/声音子页喇叭 glyph 点击
  `setMuted(!audioMuted)`、音量 commit 时先 unmute（:1274,:2752,:2771-2772）——
  `AudioService` 只有 `apply(percent,{requestSerial})`，无 mute 写入入口 →
  glyph 只读展示 `AudioLevelState.muted`（muted 画斜杠）、不可点；「先
  unmute」分支砍掉。
- **SDK 缺口 · 每应用音量**：KOS 有 `setApplicationMuted` 与 0-150% 量程
  （:2920-2923,:2963-2978）——SDK `applyAppStream(id, percent)` 只收 percent，
  且 `platform/bridge/audio_client.dart:128-131` 内部 `clamp(0,100)` → 28px
  静音钮砍掉、量程 0-100%（滑条右侧 4px 留白保留）。输出设备为**增强**：
  KOS 是静态「默认音频输出设备」占位行（:2811-2834），SDK
  `outputDeviceStates` 有真列表 → 有数据渲染真设备（点行
  `selectOutputDevice`）、无数据回落 KOS 占位行。
- **SDK 缺口 · 亮度显示器副行**：KOS 每显示器行画「内置屏幕/外接显示器」
  （`isInternal`，:2568）——`DisplayOutput` 无该字段 → 副行省略（行高仍 82）。
- **SDK 缺口 · 设置入口/会话/截图/主题/勿扰/夜灯/通知历史**：`settings.open
  kcm_*` 无等价物 → 各子页「…设置…」底脚渲染为禁用态（11 DemiBold
  `textTertiary`，KOS :2598-2624 同规格）；`screenshot.capture`/`theme.toggle`/
  `session.*`/`nightlight.toggle`/通知历史数据源均无 → 对应卡与「会话页 +
  居中确认框」整段不做（不造假占位）。
- **音量回显抑制**：KOS 用 `volumeChangeInProgress` 抑制服务端回写；SDK 无该
  标记 → 本端自增 `requestSerial`，命中最近一次 `apply` 的 serial 即视为自身
  回显并跳过（拖动不被拉回）。亮度拖动走 `setLevel`（90ms 去抖档）、松手走
  `commitLevel`（立即提交）——KOS 只有 `setBrightness` 一档。
- **蓝牙 pill 副标题**：KOS `ControlCenterService.connectedDeviceName`
  （:775-777）无 SDK 等价物 → 取首个 `connected` 设备名（匿名设备回退地址）。
- **wifi/bt 子页复用 TASK-08 行件**：`DockWifiNetworkListBody`/
  `DockBluetoothDeviceListBody`（本次从两面板抽出），行高参数化
  **46 → 42**（KOS 控制中心列表行 42，Panel:2109,2375），行内槽位（弧图标
  24@32 / SSID left 64 / ✓ 19@8）仍是 TASK-08 面板规格（KOS 控制中心行是
  16@26 + left 48 + 右侧「断开」钮，记 TASK-08 节同类偏差）；不可用能力
  （enterprise/savedProfileUuid/设备电量/% 过滤）同 TASK-08 记档。
- **页 crossfade 由 `AnimatedBuilder(_pageMotion)` 驱动**：KOS `pageFactor`
  是绑定表达式；本端以 200ms 控制器（`normalDuration` OutCubic）重建整块内容
  ——入场页 `scale 0.96→1`、出场页 `1→0.96`、入场内容 `+8px`；子页卡高度切
  换不做 Behavior（KOS `Behavior on cardHeight` 只在子页↔子页切换用，本端
  无子页↔子页路径）。
- **tray 空态语义变化（测试同步改）**：控制中心格**恒显示**并计入
  `itemCount`/宽度回流（`+1`，KOS `allKeys` 同式）→ `dock_tray_test.dart` 的
  「无托盘项且无 battery → 0 宽 shrink」/「空托盘时 tray 槽与 divider3 不渲染」
  / 「单项不折行」三例按新组成改写（空 tray 仍有 26+6 宽的控制中心格）。

## TASK-08 / TASK-09 · 审查缺陷修复新增偏差

修复轮次补记（TASK-09/09 复审缺陷清单；已修的 bug 与仍存在的偏差一并列出）：

TASK-08 节补：

- **蓝牙托盘格是新增件**：KOS 无独立托盘蓝牙格（蓝牙 UI 只在控制中心卡内，
  spec §6）——本端格为新增最小件：glyph 取 `bar/BluetoothPanel.qml:120-124`
  行内折线同式绘制（`status_cells.dart` `_BluetoothGlyphPainter`），点亮 =
  `theme.accent`（KOS glyph 恒前景色，点亮语义取自控制中心蓝牙盘），tooltip
  文案（「蓝牙」/「蓝牙已关闭」）无 KOS 对应、自拟且复用 `DockStatusTooltip`
  规格。
- **Wi-Fi 面板头行被重新启用**：KOS `bar/NetworkPanel.qml:231-295` 的头行
  Item 在源里 `visible: false`（连同 connectionCard 已停用）——本端面板顶部
  那行动态（「Wi-Fi」+ 右侧开关球 / 关态「Wi-Fi 已关闭」）是按任务卡要求
  实现的新增行，「Wi-Fi 已关闭」文案借用已停用的 connectionCard
  （NetworkPanel.qml:317 附近）措辞。开关球 toggle 中 opacity .55 与色角色
  走 `theme.accent`/`tileOff` 近似 KOS `tileActiveFill`。
- **wifi 格整体 busy 降透明度为新增乘子**：`status_cells.dart`
  `_DockWifiCellState.build` 的 `connected ? 0.96 : 0.68` 再乘 `.55`
  （`kDockWifiBusyOpacity`）作用于**整格图标**；KOS 的 .55 只作用于面板内的
  开关球（`NetworkPanel.qml:272`）与 toggle 盘（`ControlCenterPanel.qml:549`），
  `NetworkStatus.qml` 格本身只有 `statusIconOpacity × (connected ? 0.96 : 0.68)`。
  本端保留该乘子表示「切换进行中」（视觉偏差已记）。
- **Wi-Fi 格图标 2px 下移按 KOS 补上**（KOS `NetworkStatus.qml:55-56`
  `verticalCenterOffset: 2`）——原实现注释声称「Center+2px 偏移近似」但代码
  无偏移，现按 token `kDockWifiCellIconOffsetY` 实施。
- **Wi-Fi 行锁形钥匙孔色进 token**：KOS 字面量 `rgba(0,0,0,0.28)`
  （NetworkPanel.qml:486-489）不是 shellTheme 角色（它是打在浅色锁体上的
  镂空点），本端以 `kDockWifiLockKeyholeAlpha` + `Colors.black` 同 alpha 表达，
  不再硬编码 `0x47000000`。
- **蓝牙面板刷新指示口径**：KOS `BluetoothPanel.qml:151-168` 的「正在刷新…」
  是叠在**always-rendered** 列表上的居中 label（有设备时也显示）；本端改为
  「列表恒渲染，空列表才出空态」，即刷新窗口内已有设备列表不消失（修审查
  N2），代价是「有设备 + 刷新中」时没有叠加 label（KOS 有）——控制中心 bt
  子页的指示在小节头（`ControlCenterPanel.qml:2344-2370`）有对应实现。

TASK-09 节补：

- **页 crossfade 改道续播已按 KOS 实现**：`_openPage` 不再恒
  `forward(from: 0)`——progress < 1 时从当前进度续播并按剩余量缩短时长
  （`kDockControlCenterPageDuration × (1 − progress)`），对齐
  `shared/qml/foundation/KosPageMotion.qml:34-56` crossfade 档的
  「no snap, no empty frame」。仍存偏差：入场页的 `scale`/`+8px` 位移按
  progress 线性重算（KOS 同），但**子页卡高度**切换无 Behavior（原记录保留）。
- **声音子页数据按 KOS 周期刷新**：KOS `ControlCenterService` 面板开着时
  `audioApplicationsTimer` 1.8s + `refreshTimer` 3s（service:428-440）自动
  重灌；SDK 侧无对应 push tick → 本端在面板挂载期用 `Timer.periodic`
  显式重发 `requestAppStreams()`（1.8s）/`readLevel()` +
  `requestOutputDevices()`（3s），并在应用流回灌时清除非拖动行的本地预览
  （KOS 靠 1.8s 刷新重建 delegate 复位行内 `volumePreview`，等价）。
  偏差：亮度不重发（SDK `displayBrightnessProvider` 由 native push 驱动，
  KOS 的 3s refresh 覆盖该项）。
- **pill busy 档旋转弧已实现**：21px 画布 / `r = w/2 − 1.5` / lineWidth 2 /
  扫 1.5π / 900ms 一圈 / 140ms 交叉淡入，glyph 在 busy 时 opacity 0
  （KOS `ControlCenterPanel.qml:549-617`）。偏差：本端 busy 弧常驻树内以
  `AnimatedOpacity` 淡出（KOS 另有 `visible: opacity > 0.01` 裁剪）。
- **Esc 分步已实现子页档**：子页开着 → 退回主页面（消费），已在主页面 →
  anchor 关整面板（KOS `ControlCenterPanel.qml:512-524`）。偏差：KOS 的第一
  级是「居中确认框」（`pendingConfirmAction`）——v1 会话页砍掉后无该层，故
  本端只有「子页 → 整面板」两级；Wi-Fi/蓝牙单面板无子页、Esc 恒直关
  （KOS 同）。
- **亮度条「☀」glyph 仍是字形近似**：KOS `ControlCenterPanel.qml:1192-1196`
  是 Canvas 自绘太阳（半径/光线逐条绘制），本端用 `Text('☀')` +
  `kDockControlCenterSunGlyphSize`（13px）、@0.65 近似——字体缺该 glyph 的
  环境下会退化（记档，不做自绘）。
- **应用音量行 hover 底与 pill 按下 scale 接线**：KOS 应用音量行 hover 底
  r8（`ControlCenterPanel.qml:2898-2903`）与 pill 卡 `press 0.97`
  （:531）原为未接线 token，现分别接上 `kDockControlCenterAppRowRadius` 与
  `kDockControlCenterPillCardPressedScale`（按下区 = 盘的**外**整卡区，
  同 KOS `wifiPagePointer` 的 `leftMargin: 49` 起）。
- **滑条缺省色改为 KOS glass 档**：`DockControlCenterSlider` 未传
  `trackColor/accentColor` 时取 `textPrimary@0.17 / @0.42`
  （`ControlCenterSlider.qml:18-21` glass 档字面量），传参处仍走
  `brightnessTrack`/`volumeTrack`/`theme.accent` 语义 role；禁用滑条
  opacity 0.5 → **0.45**（`LiquidSlider.qml:97`）。
- **控制中心面板的周期表只在面板挂载期存在**：面板内容是 `OverlayPortal`
  overlay child（关闭即 unmount）→ 1.8s/3s 表随面板关闭自动停，无需额外
  可见性判断（KOS 用 `anyPanelOpen` 门控，语义等价）。

## 弹层 backdrop 模糊不再吃入场淡入（TASK-08/09 追加修复）

- **现象**：右键菜单 / Wi-Fi·蓝牙面板 / 控制中心面板 / 窗口预览卡的
  backdrop 模糊在弹出瞬间「先透明、模糊后知后觉跟上」——`Opacity(v)` 套
  在**整个面板**（含 `ShellBackdropBlur` 的 backdrop 层）上，模糊采样
  的是半透明桌面，有效模糊半径随 v 弱化。
- **修法**：`Opacity` 从外层移到面板内部、只套前景（渐变+边框+内容），
  backdrop 层从第一帧就满强度：
  - `DockMenuPanel`/`_DockPreviewPanel` 加 `progress`（0..1，默认 1），
    调用方（`DockMenuOverlay`/`DockPreviewAnchor._buildPreview`）把
    `progress`/`_reveal.value` 传入；
  - `DockStatusPanelSurface` 不改签名——经新 `DockStatusPanelOpenScope.
    reveal`（`AnimatedPopupWindow.revealProgress` 等价）读，由
    `DockStatusPanelAnchorState._buildOverlay` 的 `AnimatedBuilder`
    下发；独立挂载/测试无祖先 → 默认 1 不淡入。
- **与 KOS 的关系**：KOS `AnimatedPopupWindow.qml:16` `opacity =
  revealProgress` 是把整个 popup surface 透明化——backdrop 是
  compositor 层的 Wayland surface，模糊不吃 QML opacity；Denial 的
  `ShellBackdropBlur` 在同一 widget 树内，opacity 会传染到 blur 层，故
  本端把淡入收窄到前景是**对齐 KOS 观感**（模糊即时满强度），非新偏差。

## 状态格对齐 KOS `trailingCells`（用户反馈修复）

- **删除独立蓝牙托盘格**：KOS `BarStatusArea.qml:28-33` `trailingCells`
  只含 `network/battery/settings/controlcenter`，**无 bluetooth**——蓝牙入口
  在 Wi-Fi 面板与控制中心里。`DockBluetoothCell` 与 `_BluetoothGlyphPainter`
  托盘用例删除；`DockBluetoothGlyph`（面板行/控制中心蓝牙盘 glyph）保留——
  那是 KOS `BluetoothPanel.qml:116-125`/`ControlCenterPanel.qml` Canvas
  折线的同式移植，不是托盘格。
- **电池格去 accent 染色**：`dockBatteryFillColor` 删 `accent` 参数，改回
  KOS `Battery.qml:111-118` 字面状态色（>95 绿 `#30d158`、≥50 前景、
  ≥15 橙 `#ff9f0a`、<15 红 `#ff453a`）；`boltColor` 同。新增
  `kDockBattery{Full,Warn,Crit}Color` token。用户要求严格对齐 KOS 视觉，
  故不走 §3 语义映射（记档）。
- **控制中心格 glyph 换 KOS 工程图形**：`BundledIcons.qml:93`
  `control-center`（双胶囊开关 SVG）栅格化为 `assets/icons/control-center.png`
  （白描边 72×72，2× 于 18px 显示）；`DockControlCenterCell` 用
  `Image.asset` + `colorBlendMode: srcIn` 投色——等价 KOS `BundledIcon`
  的 MultiEffect `colorization`（白色 alpha 遮罩投前景）。原自绘
  `_ControlCenterGlyphPainter`（双滑杆近似）删除，token
  `kDockControlCenterGlyph*` 一并移除。
- **托盘格序 + 混排网格**：托盘 id 段 → wifi(network) → battery →
  controlcenter（KOS `trailingCells` 序；settings 无 SDK 等价物隐藏）。
  格与托盘项**混排在同一 `Wrap`**（KOS `SysTray.qml:69-73` `allKeys =
  nativeKeys + trailingCellKeys` → 同一网格逐格定位）。实现：每个托盘
  id 经 `buildSystemTray(itemIds:[id])` 单渲成 22px 钮（宿主
  `SystemTrayModule` 非 wrap 间距 4px、wrap:true 8px，均 ≠ KOS
  `iconSpacing:6` → 不用宿主排版；`wrap:false` 单渲项无内嵌间距）。
  **两行交错**：KOS `slotOriginIn` 按列填（`row=index%rows`、
  `column=floor(index/rows)`，SysTray.qml:119-136），而 Flutter `Wrap`
  按行填 → 把所有子项统一包成 `itemSize`(26)×26 格（保证换行点=列
  边界，宿主 22px 钮居中进槽），并按 `r, r+2, r+4…`（行主序）重排喂
  给 Wrap，等价 KOS 列主序交错；单行（rows=1）天然序即可。格本体不
  带左 padding（KOS iconSpacing 属网格列距、不属格内几何）。
  `dockTrayEstimateWidth` 的 `itemCount` 计全部格（KOS `allKeys` 同式）。
