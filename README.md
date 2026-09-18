# 应用架 | AppShelf

应用架是一个原生 macOS 应用启动器。它从常见应用目录读取 `.app`，用分组和搜索整理列表，点击卡片即可启动应用。卡片采用启动台式排版，支持拖拽归组、磁盘与内存占用显示、拼音搜索、全局搜索浮层，以及中文 / 英文界面。

AppShelf is a native macOS app launcher. It reads `.app` bundles from common application folders, organizes them into groups, and opens them from a searchable grid. It features a Launchpad-style tile layout, drag-to-group, disk and memory usage, pinyin search, a global search panel, and a Chinese / English interface.

当前版本 / Current version: `1.3.0`

## 1.3.0 的新变化 / What's new in 1.3.0

- 主窗口键盘导航：↑↓ 选卡片，回车打开，`esc` 退出，⌘F 聚焦搜索，⌘1 至 ⌘9 切换分组，⌘Z 撤销。
  Keyboard navigation in the main window: ↑↓ to pick a tile, Return to open, `esc` to back out, ⌘F to search, ⌘1–⌘9 for groups, ⌘Z to undo.
- 可以隐藏应用：隐藏后不出现在列表和搜索结果里，侧栏“已隐藏”页负责找回。
  Hide apps: they leave the list and the search results, and the Hidden view brings them back.
- 支持从访达把 `.app` 直接拖进分组、分区或快捷工具区。
  Drop `.app` bundles straight from Finder onto a group, a section, or the quick tool row.
- 分组设置可导出为 JSON 备份，换一台 Mac 可以导入还原。
  Group settings export to JSON and import back, so a new Mac can start from your arrangement.
- 刷新不再冻结界面：应用扫描移到后台，“正在读取应用…”也终于能显示出来。
  Refreshing no longer freezes the interface: discovery moved off the main thread, and the loading state now actually appears.
- 深色模式描边、落位动画、磁盘占用取整、拼音结果顺序等一批修正，外加 80 个单元测试。
  A round of fixes — dark-mode strokes, landing animations, byte rounding, pinyin result order — plus 80 unit tests.

## About

如果你经常在“应用程序”文件夹、启动台和聚焦搜索之间来回找应用，应用架提供了一个固定的窗口。它适合把开发工具、沟通软件、日常应用和系统工具放在同一个地方管理。

If you switch between Finder, Launchpad, and Spotlight to find apps, AppShelf gives you one window with a persistent layout. It is intended for keeping development tools, communication apps, everyday apps, and system utilities in one place.

## 功能 / Features

- 自动扫描 `/Applications`、`/System/Applications` 和 `~/Applications`，过滤后台代理和菜单栏辅助程序。
- Scans `/Applications`, `/System/Applications`, and `~/Applications`, while filtering background agents and menu-bar helpers.
- 首次启动按常用、开发、沟通、创作、日常、工具建立分组；分类只是初始建议，可以自行调整。
- Creates starter groups for common, development, communication, creative, everyday, and utility apps. The categories are suggestions and can be changed.
- 支持搜索、仅看正在运行的应用、隐藏不想看到的应用、显示应用图标和实时运行状态。
- Supports search, running-only filtering, hiding apps you do not want, app icons, and live running status.
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
- 卡片采用启动台式的排版：大图标、居中名称，占用信息压缩成一行小字。
- Tiles are laid out like Launchpad: a large icon, a centred name, and one quiet line of usage details.
- “全部应用”按分区展示每个分组，卡片可以拖动调整组内顺序，分区标题和侧边栏分组行都可以拖动调整分组顺序。
- The All Apps view lists one section per group. Cards can be dragged to change their position inside a group, and both the section headings and the sidebar rows can be dragged to reorder the groups themselves.
- 右键菜单可以退出应用、强制结束进程，或取消应用的分组设置。
- The context menu can quit an app, force-kill its process, or undo its group membership.
- 拖动应用时，每个分组下方会出现红色区域，拖进去即从该分组移除；落入分组时目标位置会播放图标缩小的动画。
- While dragging an app, each group shows a red strip at its foot: drop there to remove the app from that group. Dropping into a group plays a shrinking icon animation at the destination.
- 快捷工具可自定义：显示、隐藏、调整顺序，也可以在“全部应用”里把应用直接拖进快捷工具区域添加、拖出到内容区移除。
- Quick tools are customizable: show, hide, and reorder them in Settings, or drag an app into the quick tool area to pin it and drag a tile out onto the content area to remove it.
- 搜索栏位于标题下方独立一行，进入页面或切换分组后会自动获得键盘焦点。
- The search field sits on its own row under the title and takes keyboard focus whenever a page is shown.
- 在 Dock 图标上右键，可以直接打开聚焦搜索、应用架窗口、任意分组或设置。
- Right-clicking the Dock icon opens focus search, the app window, any group, or the settings panel.
- 支持类似 macOS 聚焦的独立搜索浮层：用快捷键唤出，输入后回车直接打开应用，不显示完整主界面。
- A Spotlight-like floating panel can be summoned with a global shortcut; press Return to launch the app without opening the full window.
- 聚焦搜索的快捷键可以在“设置”中自行录制，也可以关闭或恢复默认（默认 ⌥Space）。
- The focus-search shortcut can be recorded in Settings, disabled, or restored to its default (⌥Space).
- 提供计算器、终端、活动监视器、截图和系统设置快捷入口，也可以手动加入任意 `.app`。
- Includes shortcuts for Calculator, Terminal, Activity Monitor, Screenshot, and System Settings. Any `.app` can also be added manually.
- 界面支持中文与英文，标题栏可随时切换；外观可跟随系统或固定为浅色 / 深色。
- The interface speaks Chinese and English and switches from the toolbar; the appearance can follow the system or be pinned to light / dark.
- 拖动应用时整张卡片跟随光标，路径上的图标按启动台方式让位，分组整块常亮显示落点区域。
- While dragging, the whole card follows the cursor, icons on the path slide aside like Launchpad, and the hovered block stays lit to show the destination.
- 拖动时每个分组下方（卡片之外的位置）出现红色区域，拖进去即从该分组移除。
- While dragging, a red strip appears below each group's tiles (outside the grid); dropping there removes the app from that group.
- 磁盘占用在卡片出现在屏幕上时才测量，进程内存扫描在后台进行，列表滚动更顺滑。
- Disk usage is measured only once a tile appears on screen and the process scan runs in the background, keeping scrolling smooth.
- 搜索时按 `esc` 可退出搜索；刷新会重新扫描磁盘，执行前有确认提示。
- Press `esc` while searching to exit search; refreshing rescans the disk and asks for confirmation first.

## 多语言 / Localization

每个语种一个 JSON 文件，内置于应用包内：`Resources/Localization/zh-Hans.json`、`en.json`。

Each language is a single JSON file bundled with the app: `Resources/Localization/zh-Hans.json` and `en.json`.

不需要重新编译即可新增或覆盖语种：把 `<语言代码>.json`（例如 `ja.json`）放到下面的目录，重新启动应用即可在语言菜单中看到它。

You can add or override a language without recompiling: drop a `<language-code>.json` (for example `ja.json`) into the folder below and restart the app to see it in the language menu.

```
~/Library/Application Support/AppShelf/Localization/
```

该路径也会显示在“设置”面板中。外部文件按语种覆盖内置文件；缺少的条目会回退到内置英文，再回退到界面原文。

The same path is shown in the Settings panel. External files override the bundled ones per language; missing entries fall back to the bundled English, then to the original string.

## 安装 / Install

1. 下载 [AppShelf-1.3.0.dmg](release/AppShelf-1.3.0.dmg)，然后打开 DMG。
   Download [AppShelf-1.3.0.dmg](release/AppShelf-1.3.0.dmg) and open the DMG.
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
- `1.3.0` 安装包在 Apple Silicon macOS 上构建和验证，当前不是 universal binary。Intel Mac 可以尝试从源码构建，但不在此发布包的验证范围内。
- The `1.3.0` package was built and verified on Apple Silicon macOS and is not a universal binary. Intel Macs may build from source, but are outside the verification scope of this package.

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
swift test
./Scripts/build-app.sh
open dist/AppShelf.app
```

生成 `1.3.0` 安装包（版本号会写入包内 `Info.plist`，与 `CHANGELOG.md` 不一致时直接拒绝打包）：

Build the `1.3.0` installer. The version is written into the bundle's `Info.plist`, and the script refuses when it disagrees with `CHANGELOG.md`:

```bash
./Scripts/build-release.sh 1.3.0
(cd release && shasum -a 256 -c SHA256SUMS)
hdiutil verify release/AppShelf-1.3.0.dmg
```

推送 `v1.3.0` 标签会由 GitHub Actions 完成同样的校验并上传到 Release。

Pushing a `v1.3.0` tag runs the same checks in GitHub Actions and publishes the result to Releases.

## 项目结构 / Project Layout

- `Sources/AppShelfCore/`：不含界面代码的可测试内核——搜索打分、排序与栅格的索引数学、路径归一、快捷键与备份编解码、翻译回退。
- `Sources/AppShelfCore/`: the UI-free, unit-tested core — search scoring, ordering and grid index math, path normalization, shortcut and backup codecs, and translation fallback.
- `Tests/AppShelfCoreTests/`：内核的单元测试。
- `Tests/AppShelfCoreTests/`: unit tests for the core.
- `Sources/AppShelf/Models.swift`：应用模型、目录扫描、运行状态、分组持久化与撤销。
- `Sources/AppShelf/Models.swift`: app models, discovery, running state, group persistence, and undo.
- `Sources/AppShelf/Theme.swift`：颜色与栅格常量的唯一来源。
- `Sources/AppShelf/Theme.swift`: the single source of colour and grid constants.
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
- `Sources/AppShelf/L10n.swift`：多语言管理，按语种加载内置与外部 JSON 翻译文件。
- `Sources/AppShelf/L10n.swift`: localization, loading bundled and external per-language JSON files.
- `Sources/AppShelf/Appearance.swift`：明暗模式（跟随系统 / 浅色 / 深色）的偏好与应用。
- `Sources/AppShelf/Appearance.swift`: the light/dark appearance preference and how it is applied.
- `Sources/AppShelf/AppDelegate.swift`：Dock 菜单、菜单栏图标、热键接线，以及拖拽状态的兜底监听。
- `Sources/AppShelf/AppDelegate.swift`: the Dock menu, menu bar icon, hotkey wiring, and the drag-state safety monitors.
- `Sources/AppShelf/AppShelfApp.swift`：SwiftUI 应用入口和窗口命令。
- `Sources/AppShelf/AppShelfApp.swift`: the SwiftUI entry point and window commands.
- `Scripts/build-app.sh`：构建并 ad-hoc 签名 `.app`。
- `Scripts/build-app.sh`: builds and ad-hoc signs the `.app` bundle.
- `Scripts/build-release.sh`：把 `.app` 和说明文件封装成 DMG，并生成 `SHA256SUMS`。
- `Scripts/build-release.sh`: packages the `.app` and usage notes into a DMG and writes `SHA256SUMS`.

## 数据范围 / Data Scope

应用列表来自本机文件系统和 `NSWorkspace`。分组只写入当前用户的 `UserDefaults`；应用架不会上传应用列表，也不会移动、修改或卸载被发现的应用。点击“添加应用”时，macOS 的文件选择器只允许选择 `.app` 包。

The app list comes from the local file system and `NSWorkspace`. Groups are stored in the current user's `UserDefaults`. AppShelf does not upload the app list and does not move, modify, or uninstall discovered apps. The file picker accepts `.app` bundles when you choose “Add app”.

磁盘占用 = 应用本体（`.app` 内文件大小）+ 该应用在本用户 `Library` 中的数据（`Application Support`、`Containers`、`Group Containers`、缓存、保存状态）。结果缓存在本机 `UserDefaults`，bundle 发生修改时会重新测量。

Disk usage covers the `.app` bundle plus the app's data under the user's `Library` (application support, sandbox and group containers, caches, saved state). Results are cached locally in `UserDefaults` and re-measured whenever the bundle changes.

内存占用通过系统进程接口读取常驻内存，并把 bundle 内的 helper 与 XPC 进程一并计入，在后台定期刷新，不阻塞界面。全局快捷键由 Carbon 注册，需要应用处于运行状态。

Memory usage is read from the system process interface as resident memory, summed over every process inside the bundle, and refreshed periodically on a background queue so it never blocks the UI. The global shortcut is registered through Carbon and requires the app to be running.

磁盘占用只在卡片滚动到屏幕上时才开始测量，未查看的应用不会产生磁盘读取。

Disk usage is only measured once a tile scrolls onto the screen, so apps you never look at cost no disk I/O.

## 贡献 / Contributing

欢迎提交 Issue 或 Pull Request。提交前请运行带 warnings-as-errors 的构建命令，并说明测试使用的 macOS 和 Swift 版本。

Issues and pull requests are welcome. Before submitting one, run the warnings-as-errors build and include the macOS and Swift versions used for testing.

## 许可 / License

仓库当前没有单独的 LICENSE 文件。再分发或集成代码前，请先联系仓库作者确认许可范围。

This repository does not currently include a separate LICENSE file. Contact the repository owner before redistributing or integrating the code.

更多版本信息见 [`CHANGELOG.md`](CHANGELOG.md)。

See [`CHANGELOG.md`](CHANGELOG.md) for version history.
