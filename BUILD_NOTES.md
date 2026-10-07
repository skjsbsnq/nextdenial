# 本机构建与激活说明

## Denial 版本区别

本机 `/home/wwt/文档/denial` 是 **Denial 测试版源码仓库**；本机实际安装、运行的是 **最新正式版 Denial**（以系统安装版本为准）。二者的源码标识、SDK、引擎或构建工具包可能不一致。

构建 NextDenial 插件时，不要默认使用测试版仓库中的 `tools/denial-pc plugin-manager` 或 `tools/denial-plugins`。这些命令可能把插件管理器配置切换到测试版构建工具包，导致构建失败，或构建成功但被正式版 Denial 拒绝激活。

本次实际遇到的激活错误：

```text
plugin bundle source does not match installed Denial;
prepare the matching build tools and rebuild
```

## 正确流程

针对本机已安装的正式版，使用系统安装的插件管理器，让它准备匹配的构建工具包。保留现有插件选择，不必重新添加插件。

```bash
/usr/bin/denial-plugins prepare
/usr/bin/denial-plugins plan
/usr/bin/denial-plugins build <plan 返回的候选 ID>
/usr/bin/denial-plugins activate <同一个候选 ID>
```

如果此前运行过测试版仓库工具，先重新执行上述 `prepare`，再生成新候选并重新构建；不要继续激活旧工具包生成的候选。

激活后确认输出包含 `plugin_healthy: true`，且 `plugin_bundle` 指向新候选。需要进一步核实时，检查运行中 `deniald` 的 `/proc/<PID>/maps` 是否加载该候选的 `libapp.so`。插件激活无需退出本机图形会话。

只有明确要针对测试版 Denial 开发，并确认运行中的 Denial 与测试版构建工具包匹配时，才使用 `/home/wwt/文档/denial/tools/` 下的构建命令。
