# 应用架 | AppShelf

应用架是一个原生 macOS 应用启动器。它从常见应用目录读取 `.app`，用分组和搜索整理列表，点击卡片即可启动应用。

AppShelf is a native macOS app launcher. It reads `.app` bundles from common application folders, organizes them into groups, and opens them from a searchable grid.

当前版本 / Current version: `1.1.0`

## About

如果你经常在“应用程序”文件夹、启动台和聚焦搜索之间来回找应用，应用架提供了一个固定的窗口。它适合把开发工具、沟通软件、日常应用和系统工具放在同一个地方管理。

If you switch between Finder, Launchpad, and Spotlight to find apps, AppShelf gives you one window with a persistent layout. It is intended for keeping development tools, communication apps, everyday apps, and system utilities in one place.

## 功能 / Features

- 自动扫描 `/Applications`、`/System/Applications` 和 `~/Applications`，过滤后台代理和菜单栏辅助程序。
- Scans `/Applications`, `/System/Applications`, and `~/Applications`, while filtering background agents and menu-bar helpers.
- 首次启动按常用、开发、沟通、创作、日常、工具建立分组；分类只是初始建议，可以自行调整。
- Creates starter groups for common, development, communication, creative, everyday, and utility apps. The categories are suggestions and can be changed.
- 支持搜索、仅看正在运行的应用、显示应用图标和实时运行状态。
- Supports search, running-only filtering, app icons, and live running status.
- 可以新建、编辑和删除分组，设置名称、SF Symbol 图标和颜色。
- Lets you create, edit, and delete groups with a name, an SF Symbol, and a color.
- 右键菜单支持加入其他分组、从当前分组移除、在 Finder 中显示。
- The context menu can add an app to another group, remove it from the current group, or reveal it in Finder.
- 可以按住应用图标直接拖到侧边栏分组完成归类，分组会即时更新数量。
- App cards can be dragged onto a sidebar group to file them; the group count updates immediately.
- 搜索支持中文拼音首字母、全拼和英文缩写，并按相关度排序。输入“wx”可找到微信，“vsc”可找到 Visual Studio Code。
- Search understands Chinese pinyin initials, full pinyin, and English acronyms, ranked by relevance. Typing "wx" finds 微信 and "vsc" finds Visual Studio Code.
- 卡片显示磁盘占用（如 `1.2 GB`、`256 MB`）；运行中的应用在图标上加运行标记，并显示实时内存占用（如 `512 M`）。过长的名称自动换行而不是截断。
- Each card shows its disk usage (e.g. `1.2 GB`, `256 MB`); running apps get a badge on the icon plus live memory usage (e.g. `512 M`). Long names wrap instead of being truncated.
- “全部应用”按分区展示每个分组，卡片可以直接拖动调整组内顺序。
- The All Apps view lists one section per group, and cards can be dragged to change their position inside a group.
- 右键菜单可以退出应用，或直接强制结束进程。
- The context menu can quit an app or force-kill its process.
- 快捷工具可自定义：显示、隐藏、调整顺序，也能把任意应用加为快捷工具。
- Quick tools are customizable: show, hide, reorder, and pin any app as a quick tool.
- 在 Dock 图标上右键，可以直接打开聚焦搜索、应用架窗口、任意分组或设置。
- Right-clicking the Dock icon opens focus search, the app window, any group, or the settings panel.
- 支持类似 macOS 聚焦的独立搜索浮层：用快捷键唤出，输入后回车直接打开应用，不显示完整主界面。
- A Spotlight-like floating panel can be summoned with a global shortcut; press Return to launch the app without opening the full window.
- 聚焦搜索的快捷键可以在“设置”中自行录制，也可以关闭或恢复默认（默认 ⌥Space）。
- The focus-search shortcut can be recorded in Settings, disabled, or restored to its default (⌥Space).
- 提供计算器、终端、活动监视器、截图和系统设置快捷入口，也可以手动加入任意 `.app`。
- Includes shortcuts for Calculator, Terminal, Activity Monitor, Screenshot, and System Settings. Any `.app` can also be added manually.

## 安装 / Install

1. 下载 [AppShelf-1.0.0.dmg](release/AppShelf-1.0.0.dmg)，然后打开 DMG。
   Download [AppShelf-1.0.0.dmg](release/AppShelf-1.0.0.dmg) and open the DMG.
2. 把“应用架”拖到“应用程序”文件夹。
   Drag “应用架” to the Applications folder.
3. 首次打开使用 Finder 右键菜单中的“打开”。发布包使用 ad-hoc 签名，未经过 Apple notarization；应用架不会请求额外系统权限。
   On first launch, use Finder's “Open” command if macOS shows a security prompt. The release is ad-hoc signed and is not notarized by Apple; AppShelf does not request extra system privileges.

发布包的 SHA-256 位于 [`release/SHA256SUMS`](release/SHA256SUMS)。

The release checksum is in [`release/SHA256SUMS`](release/SHA256SUMS).

## 开发环境要求 / Development Requirements

- macOS 14.0 或更高版本。
- macOS 14.0 or later.
- Swift 6.0 工具链。可以使用 Xcode 16 或更高版本，也可以使用包含匹配 Swift 工具链的 Xcode Command Line Tools。
- A Swift 6.0 toolchain. Xcode 16 or newer is suitable, as are Xcode Command Line Tools that provide a matching Swift toolchain.
- 构建脚本会使用 macOS 自带的 `swift`、`sips`、`iconutil`、`codesign` 和 `hdiutil`。
- The build scripts use the macOS-provided `swift`, `sips`, `iconutil`, `codesign`, and `hdiutil` tools.
- `1.0.0` 安装包在 Apple Silicon macOS 上构建和验证，当前不是 universal binary。Intel Mac 可以尝试从源码构建，但不在此发布包的验证范围内。
- The `1.0.0` package was built and verified on Apple Silicon macOS and is not a universal binary. Intel Macs may build from source, but are outside the verification scope of this package.

本次发布的构建验证环境：macOS 26.5.2 (arm64)、Xcode 26.2、Swift 6.2.3。它们是验证记录，不是应用的最低运行要求。

The verified release build used macOS 26.5.2 (arm64), Xcode 26.2, and Swift 6.2.3. These versions describe the verification record, not the minimum runtime requirement.

检查工具链 / Check the toolchain:

```bash
xcode-select --install
swift --version
```

## 从源码构建 / Build From Source

在仓库根目录执行：

Run these commands from the repository root:

```bash
swift build -c debug -Xswiftc -warnings-as-errors
./Scripts/build-app.sh
open dist/AppShelf.app
```

生成 `1.0.0` 安装包：

Build the `1.0.0` installer:

```bash
./Scripts/build-release.sh 1.0.0
(cd release && shasum -a 256 -c SHA256SUMS)
hdiutil verify release/AppShelf-1.0.0.dmg
```

## 项目结构 / Project Layout

- `Sources/AppShelf/Models.swift`：应用模型、目录扫描、分类、运行状态、搜索排序和分组持久化。
- `Sources/AppShelf/Models.swift`: app models, discovery, categorization, running state, result ranking, and group persistence.
- `Sources/AppShelf/Views.swift`：主窗口、侧边栏、应用卡片、拖拽归组和编辑面板。
- `Sources/AppShelf/Views.swift`: the main window, sidebar, app cards, drag-to-group, and editor sheets.
- `Sources/AppShelf/SearchMatching.swift`：拼音转换、首字母和模糊匹配的打分逻辑。
- `Sources/AppShelf/SearchMatching.swift`: pinyin conversion plus initials and fuzzy-match scoring.
- `Sources/AppShelf/AppMetrics.swift`：磁盘占用测量、缓存和运行中进程的内存读取。
- `Sources/AppShelf/AppMetrics.swift`: disk usage measurement, caching, and memory reads for running processes.
- `Sources/AppShelf/QuickTools.swift`：快捷工具的条目模型与显示、排序、增删的持久化。
- `Sources/AppShelf/QuickTools.swift`: the quick tool model plus persistence for visibility, order, and additions.
- `Sources/AppShelf/HotKey.swift`：全局快捷键的 Carbon 注册与偏好设置存储。
- `Sources/AppShelf/HotKey.swift`: Carbon registration of the global shortcut and its persisted preference.
- `Sources/AppShelf/SpotlightPanel.swift`：聚焦式浮动搜索面板及其 AppKit 窗口。
- `Sources/AppShelf/SpotlightPanel.swift`: the Spotlight-style floating panel and its AppKit window.
- `Sources/AppShelf/SettingsView.swift`：快捷键录制与开关偏好。
- `Sources/AppShelf/SettingsView.swift`: the shortcut recorder and preference toggles.
- `Sources/AppShelf/AppDelegate.swift`：Dock 菜单、菜单栏图标和热键接线。
- `Sources/AppShelf/AppDelegate.swift`: the Dock menu, menu bar icon, and hotkey wiring.
- `Sources/AppShelf/AppShelfApp.swift`：SwiftUI 应用入口和窗口命令。
- `Sources/AppShelf/AppShelfApp.swift`: the SwiftUI entry point and window commands.
- `Scripts/build-app.sh`：构建并 ad-hoc 签名 `.app`。
- `Scripts/build-app.sh`: builds and ad-hoc signs the `.app` bundle.
- `Scripts/build-release.sh`：把 `.app` 和说明文件封装成 DMG，并生成 `SHA256SUMS`。
- `Scripts/build-release.sh`: packages the `.app` and usage notes into a DMG and writes `SHA256SUMS`.

## 数据范围 / Data Scope

应用列表来自本机文件系统和 `NSWorkspace`。分组只写入当前用户的 `UserDefaults`；应用架不会上传应用列表，也不会移动、修改或卸载被发现的应用。点击“添加应用”时，macOS 的文件选择器只允许选择 `.app` 包。

The app list comes from the local file system and `NSWorkspace`. Groups are stored in the current user's `UserDefaults`. AppShelf does not upload the app list and does not move, modify, or uninstall discovered apps. The file picker accepts `.app` bundles when you choose “Add app”.

磁盘占用只在沙箱范围之外读取 bundle 内文件大小，结果缓存在本机 `UserDefaults`；内存占用通过系统进程接口读取常驻内存。全局快捷键由 Carbon 注册，需要应用处于运行状态。

Disk usage is computed by reading file sizes inside each bundle and is cached locally in `UserDefaults`; memory usage is read from the system process interface as resident memory. The global shortcut is registered through Carbon and requires the app to be running.

## 贡献 / Contributing

欢迎提交 Issue 或 Pull Request。提交前请运行带 warnings-as-errors 的构建命令，并说明测试使用的 macOS 和 Swift 版本。

Issues and pull requests are welcome. Before submitting one, run the warnings-as-errors build and include the macOS and Swift versions used for testing.

## 许可 / License

仓库当前没有单独的 LICENSE 文件。再分发或集成代码前，请先联系仓库作者确认许可范围。

This repository does not currently include a separate LICENSE file. Contact the repository owner before redistributing or integrating the code.

更多版本信息见 [`CHANGELOG.md`](CHANGELOG.md)。

See [`CHANGELOG.md`](CHANGELOG.md) for version history.
