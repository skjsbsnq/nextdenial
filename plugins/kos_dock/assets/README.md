# kos_dock assets

## applauncher.svg

- **来源**：NextKde 仓库 `shell/desktop/assets/applauncher.svg`
  （`/home/wwt/文档/NextKde/shell/desktop/assets/applauncher.svg`），
  逐字节原样拷贝，未做任何转码/压缩。
- **文件实际格式**：内容为 1024×1024 的 PNG（`89 50 4E 47` 头，IHDR
  0x400×0x400，RGBA），扩展名沿用 KOS 的 `.svg`。Flutter `Image.asset`
  按内容解码，可直接加载；**不要**按 SVG 处理（未引入 flutter_svg）。
- **KOS 消费点**：`shell/desktop/modules/dock/DockContainer.qml:545-547`
  —— `appLauncherIcon.iconSource: Qt.resolvedUrl("../../assets/applauncher.svg")`，
  注释说明「启动器 logo 是仓库里的位图原作（1024²），走文件而不是内联
  降采样副本」。
- **移植消费点**：`lib/src/widgets/launcher_icon.dart` 的 `LauncherIcon`
  （`Image.asset('assets/applauncher.svg', ...)`）。

## icons/trash.png · icons/trash_full.png

- **来源**：旧 kos_dock（本仓库上一版实现，删除于 commit `b04ecaf`）的
  `plugins/kos_dock/assets/icons/trash.svg` / `trash_full.svg`
  （`git show b04ecaf^:plugins/kos_dock/assets/icons/trash.svg`）；
  SVG 源文件 md5（前 12 位）：`trash.svg` = `b582c169c45c`、
  `trash_full.svg` = `48fb69b52544`。图案本身源自 NextKde 系统图标主题的
  trash full/empty 两枚图标。
- **栅格化命令**（dev-time，非运行时依赖；Flutter 不能解码 SVG，故转 PNG）：

  ```bash
  cd /home/wwt/文档/nextdenial
  git show b04ecaf^:plugins/kos_dock/assets/icons/trash.svg      > /tmp/trash.svg
  git show b04ecaf^:plugins/kos_dock/assets/icons/trash_full.svg > /tmp/trash_full.svg
  rsvg-convert -w 256 -h 256 -o plugins/kos_dock/assets/icons/trash.png      /tmp/trash.svg
  rsvg-convert -w 256 -h 256 -o plugins/kos_dock/assets/icons/trash_full.png /tmp/trash_full.svg
  ```

- **落盘 md5**：`trash.png` = `a79e6e0a51a54af7d253c239e6194e58`、
  `trash_full.png` = `f23cd117588849907e8ebb51cbb65e79`
  （256×256 RGBA PNG，rsvg-convert 2.62.4）。
- **KOS 消费点**：`shell/desktop/modules/dock/DockContainer.qml:586-588`
  —— `trashIcon.iconSource: SystemIconResolver.source("trash",
  DockTrashService.hasItems ? "full" : "empty")`。
- **移植消费点**：`lib/src/widgets/trash_icon.dart` 的 `TrashIcon`
  （`Image.asset(state.hasItems ? 'assets/icons/trash_full.png' :
  'assets/icons/trash.png', package: 'kos_dock')`）；原色渲染，不 tint、
  不加空态透明度层（KOS 只切图标）。

## icons/control-center.png

- **来源**：NextKde `shell/desktop/modules/common/BundledIcons.qml:93`
  `svg["control-center"]` 内联 SVG（viewBox `0 0 1026 1024`、双胶囊开关
  图形、白色填充 + 下胶囊 `opacity .3` 半透明层）。
- **栅格化**（dev-time）：`rsvg-convert -w 72 -h 72` → 72×72 RGBA PNG
  （2× 于格内 18px 显示尺寸，与 BundledIcon `sourceSize = size*2` 同策略）。
- **运行时着色**：KOS `BundledIcon` 以白色 SVG 作 alpha 遮罩、MultiEffect
  `colorization` 投成 `color`；Flutter 侧 `Image.asset` + `color:` +
  `colorBlendMode: BlendMode.srcIn` 等价。消费点
  `lib/src/widgets/status_cells.dart` 的 `DockControlCenterCell`。
