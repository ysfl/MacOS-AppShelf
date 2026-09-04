# 应用架

一个轻量的原生 macOS 应用启动器，用分组和搜索替代难以浏览的长应用列表。

当前版本：`1.0.0`

## 功能

- 自动读取 `/Applications`、`~/Applications` 和系统应用目录
- 首次启动按常用、开发、沟通、创作、日常、工具自动分组
- 新建、编辑和删除自定义分组，配置图标与颜色
- 右键把应用加入其他分组，或从当前分组移除
- 搜索、仅看运行中应用、显示实时运行状态
- 点击应用卡片直接启动
- 快速打开计算器、终端、活动监视器、截图和系统设置
- 手动加入任意 `.app`，包括未自动展示的菜单栏应用

分组信息只保存在本机 `UserDefaults` 中，不上传任何数据，也不会移动或卸载原应用。

## 使用

从 [release/AppShelf-1.0.0.dmg](release/AppShelf-1.0.0.dmg) 安装即可。打开 DMG 后，将“应用架”拖入“应用程序”文件夹，再固定到程序坞。

这个首发包使用本地 ad-hoc 签名，没有 Apple notarization。首次打开如果 macOS 显示安全提示，请在 Finder 中对应用点按右键并选择“打开”。

## 从源码构建

需要 macOS 14 或更高版本以及 Xcode Command Line Tools：

```bash
./Scripts/build-app.sh
open dist/AppShelf.app
```

发布包的 SHA-256 位于 [`release/SHA256SUMS`](release/SHA256SUMS)。

如需重新生成安装包：

```bash
./Scripts/build-release.sh 1.0.0
```
