# 轻小说文库 iOS 版

轻小说文库（[wenku8.net](https://www.wenku8.net)）的 iOS 第三方客户端，用 **SwiftUI** 重写，界面采用 **Liquid Glass**（iOS 26/27 的液态玻璃）设计。

构建以 **Xcode** 为第一路径：`project.yml` 声明工程，`tools/bootstrap-xcodeproj.sh` 生成 `Wenku8.xcodeproj`，随后用 Xcode 或 `xcodebuild` 编译、签名并直接装到 iPhone 上调试。核心层仍是纯 SwiftPM 模块，因此解析与网络代码可以在任意 Swift 6.1 环境（含 Linux）下跑测试。

本项目是 [MewX/light-novel-library_Wenku8_Android](https://github.com/MewX/light-novel-library_Wenku8_Android) 的 iOS 重构版本：功能划分与交互结构参考 Android 版，代码为 SwiftUI 独立实现。

> 所有小说内容均来自文库公开网页，版权归原作者与出版机构所有。本应用非官方、非盈利，仅供学习交流。

---

## 功能

| 模块 | 说明 |
| --- | --- |
| 书架首页 | 今日热榜 / 最近更新 / 新书风云 / 每周书单，横幅推荐 + 继续阅读入口 |
| 排行榜 | 13 个榜单（日/周/月/总点击与推荐、最新入库、字数、动画化等） |
| 搜索 | 按书名或作者搜索，本地保存搜索历史，支持按文库分类浏览 |
| 小说详情 | 封面、作者、文库、状态、字数、更新时间、完整简介、同类推荐 |
| 章节目录 | 按卷分组的 DisclosureGroup 目录，标记当前阅读位置 |
| 阅读器 | 四种配色（纸白/护眼/夜间/跟随系统）、字号与行距实时调节、章节目录跳转、自动记录进度、插图渲染 |
| 书评 | 书评列表与详情页回复 |
| 我的书架 | 本地收藏与每本书的阅读进度 |
| 中转服务（可选） | 接入公益中转服务后，排行榜与文库分类可在未登录时拿到真实数据；未配置时自动使用网页版路径 |

## Liquid Glass 适配

界面统一通过 `DesignSystem.swift` 里的修饰符输出玻璃质感，全部带 `#available` 版本分支：

```swift
Text("目录")
    .padding(.horizontal, 12)
    .padding(.vertical, 7)
    .glassCapsule()          // iOS 26+: .glassEffect(.regular, in: .capsule)
                             // 旧系统: .ultraThinMaterial + 发丝描边
```

- `glassSurface(_:tint:interactive:)` / `glassCapsule` / `glassCard` —— 自定义玻璃面板，iOS 26 起走 `glassEffect(_:in:)`，可选 tint（着色）与 interactive（点按形变）。
- `prominentGlassButtonShape()` / `secondaryGlassButtonShape()` —— 按钮样式，iOS 26 起用 `.buttonStyle(.glassProminent)` 与 `.buttonStyle(.glass)`，并配合 `.buttonBorderShape(.capsule)` 而非自行裁剪形状。
- `GlassContainer` —— iOS 26 起包一层 `GlassEffectContainer`，相邻玻璃控件获得融合动效（排行榜的榜单选择器、搜索页的标签）。
- 滚动内容（列表行、正文）**不使用**玻璃，玻璃只出现在导航、按钮与固定浮层上，避免滚动时的渲染开销与视觉噪点。
- 阅读器的底部控制条属于固定浮层，使用 `.glassCard`；工具栏按钮沿用系统在 iOS 26+ 上自带的玻璃背景。

`MinimumOSVersion` 保持 17.0，因此在 iOS 17/18 上仍可安装运行，只是玻璃控件回落成材质面板；
在 iOS 26/27 设备上才会真正启用 Liquid Glass。

`Glass`、`.glassEffect`、`.glassProminent` 这些符号只存在于 iOS 26 SDK 里，所以除了 `#available`
运行时判断之外，还套了一层 `#if compiler(>=6.2)` 编译期判断（对应 Xcode 26 与更新版本）。
这样用旧版 Xcode（iOS 18 SDK）打开同一份源码也能编译通过，只是固定走材质回退分支。
CI 仍会用 iOS 26 与 iOS 27 两个 SDK 各编译一次，确保两套分支都没有烂掉。

## 构建

### 方式一：Xcode（macOS，推荐）

```bash
# 1. 生成工程（首次或修改 project.yml 后）
bash tools/bootstrap-xcodeproj.sh generate

# 2. 用 Xcode 打开，选择你的 iPhone，⌘R
open Wenku8.xcodeproj
```

`bootstrap` 在找不到系统 `xcodegen` 时会自动把 2.43.0 的二进制下到 `.build-mac/tools/`，
不需要 Homebrew。工程文件是**生成产物**，不进仓库（见 `.gitignore`），避免与 `project.yml` 漂移。

签名使用 Xcode 里已登录的 Apple ID 团队（Personal Team 即可）：`project.yml` 里的
`DEVELOPMENT_TEAM` 是开发者本机的团队 ID，换成你自己的即可。

命令行等价流程（生成 + 编译 + 安装 + 启动，一条命令）：

```bash
bash tools/bootstrap-xcodeproj.sh device     # 需要 iPhone 已连接、解锁并信任此电脑
bash tools/bootstrap-xcodeproj.sh build      # 只编译模拟器版本
```

真机要点：iPhone 需开启 **设置 → 隐私与安全性 → 开发者模式**，并在首次安装后到
**设置 → 通用 → VPN 与设备管理** 信任开发者证书。免费证书签名有效期 7 天。

### 方式二：CI（无需本地环境）

推送代码后，`.github/workflows/ios-build.yml` 会并行跑两个构建，确认代码在 iOS 26 与 iOS 27 SDK 下都能编译：

| 任务 | Runner | Xcode / SDK |
| --- | --- | --- |
| Core tests | `ubuntu-latest` + `swift:6.1-noble` 容器 | Linux Swift 6.1 |
| Xcode build (iOS 26 SDK) | `macos-26` | Xcode 26.x / `iphoneos26.x` |
| Xcode build (iOS 27 SDK) | `xcode-27` | Xcode 27.x / `iphoneos27.x` |

每个构建都会校验产物并上传为独立的 Artifact：

- `Wenku8-unsigned-ios26` —— 用 iOS 26 SDK 编译
- `Wenku8-unsigned-ios27` —— 用 iOS 27 SDK 编译

产物校验覆盖：`CFBundleIdentifier`（`org.mewx.wenku8.ios`）、`MinimumOSVersion`（17.0）、
arm64 Mach-O、`_main` 入口符号、已链接的 `SwiftUI.framework` / `UIKit.framework`、
`PrivacyInfo.xcprivacy`、`gbk-table.bin`、以及 `.ipa` 的 SHA-256。

### 产物结构

```
Wenku8.app/
├── Wenku8                     # 可执行文件
├── Info.plist                 # 来自 Support/Info.plist
├── Assets.car                 # 编译后的图标资源
├── PrivacyInfo.xcprivacy      # 隐私清单
└── gbk-table.bin              # GBK 解码表（由 Wenku8Core 资源阶段复制）
```

## 项目结构

```
.
├── project.yml                       # XcodeGen 工程声明（app + core framework 两个 target）
├── Package.swift                     # SwiftPM 包（核心层 + 测试目标，供 swift test / CI 使用）
├── Support/
│   ├── AppIcon.png                   # 1024×1024 图标
│   ├── Assets.xcassets/              # 图标资源目录（Xcode 编译为 Assets.car）
│   ├── Info.plist                    # 屏幕方向、ATS、显示名等
│   └── PrivacyInfo.xcprivacy         # 隐私清单
├── Sources/
│   ├── Wenku8Core/                   # 与 UI 无关的核心层，可在 Linux 上编译与测试
│   │   ├── TextDecoding.swift        # 内置 GBK 解码（文库桌面版为 GBK）
│   │   ├── Markup.swift              # 轻量 HTML/XML 解析器
│   │   ├── WAPParser.swift           # WAP 版页面解析（首页/详情/目录/正文/书评）
│   │   ├── DesktopParser.swift       # 桌面版页面解析（回退路径）
│   │   ├── SugoiParser.swift         # 年度榜单解析
│   │   ├── AccountParser.swift       # 登录 / 书架变更结果
│   │   ├── RelayClient.swift         # 中转服务传输层（限速 + 凭证注入）
│   │   ├── RelayParser.swift         # 中转服务 XML 解析
│   │   ├── RelayCredential.swift     # 中转凭证的本地存储
│   │   ├── Network.swift             # URLSession 封装、双域名回退、Cookie
│   │   ├── NovelService.swift        # 业务接口（中转优先，失败回落网页版）
│   │   └── Models.swift              # 数据模型
│   └── Wenku8iOS/                    # SwiftUI 界面层
│       ├── Wenku8App.swift           # 入口 + 路由
│       ├── RootView.swift            # 自绘底部 dock + NavigationStack
│       ├── DesignSystem.swift        # Liquid Glass 修饰符
│       ├── HomeView.swift
│       ├── RankView.swift
│       ├── SearchView.swift
│       ├── NovelDetailView.swift
│       ├── ReaderView.swift
│       ├── ReviewView.swift
│       ├── ShelfView.swift
│       ├── SettingsView.swift
│       └── LibraryStore.swift        # 书架 / 进度 / 搜索历史持久化
├── Tests/Wenku8CoreTests/            # 51 个测试（含真实页面样本 + 中转服务 XML 样本）
├── tools/
│   ├── bootstrap-xcodeproj.sh        # 生成工程 / 编译 / 装真机
│   ├── test-core-linux.sh            # 离线单元测试
│   ├── test-live.sh                  # 联网端到端校验
│   ├── smoke/main.swift              # 联网校验的检查项
│   ├── gen_gbk_table.py              # 重新生成 GBK 解码表
│   └── make_icon.py                  # 重新生成 App 图标
└── .github/workflows/ios-build.yml   # CI：Linux 跑测试 + macOS 用 xcodebuild 编译
```

## 数据来源说明

文库桌面版（`/book/*.htm`、`/novel/...`）使用 **GBK** 编码，WAP 版（`/wap/...`）使用 **UTF-8 + WML**。
两者在匿名访问下的可用性不同，因此客户端做了分层：

1. **首选 WAP 版**：首页四个栏目、书籍详情、目录、正文、书评均可在未登录状态解析，且返回 UTF-8。
2. **WAP 受限时回退桌面版**：排行榜/分类列表在 WAP 下会要求登录（返回 `login.php` 卡片），此时自动改用桌面版的列表页解析。
3. **双域名**：`www.wenku8.net` 失败时自动尝试 `www.wenku8.com`。
4. **封面**：统一走 `img.wenku8.com` 的 HTTPS 地址，避免 ATS 拦截 HTTP 图片。

`Wenku8Client` 会把「需要登录」当作一种可识别的状态（`Wenku8Error.needLogin`）抛给界面，
点击「在网页版查看」即可用 `SFSafariViewController` 打开原始页面完成登录后再回来。

### 可选：公益中转服务

Android 版有一个由社区维护的中转端点（`https://wenku8-relay.mewx.org/`），它能匿名提供
WAP 与桌面版都拿不到的排行榜和文库分类列表。本项目的接入方式是「可选、可失效、有上限」：

- **默认关闭**。没有配置凭证时 `RelayClient.isAvailable` 为 `false`，所有接口原样走网页版路径。
- **凭证由用户自己提供**，应用只把它保存在本机 `UserDefaults`，随时可在设置里清除。
  仓库不包含、也不推导该凭证 —— 它是公益服务的防滥用凭据，公开它等于公开一个批量抓取工具。
- **强制限速**。所有请求经过 `RelayThrottle` 串行闸门，默认最小间隔 1.2 秒，下限锁死 0.5 秒。
- **逐接口回退**。中转失败时静默回落到 WAP/桌面路径，不会让界面变成错误页。
- 返回码（`1` 成功 … `22`）在 `RelayParser.message(for:)` 里统一翻译成中文提示。

在 **设置 → 中转服务** 里开启并粘贴凭证即可。

## 测试

核心层不依赖 SwiftUI，可以在任意 Swift 6.1 环境（含 Linux 容器）下跑单元测试：

```bash
bash tools/test-core-linux.sh
```

还会真实访问文库，验证端到端链路（需要联网）：

```bash
bash tools/test-live.sh
```

输出示例：

```
PASS  home: hot=6 latest=6 newcomer=6 weekly=6
PASS  detail: 你们赶紧给我结婚吧！ / 优汰 / 连载中 / intro=253
PASS  volumes: 3 volumes, 24 chapters
PASS  chapter: 序章 “我已经开始写恋爱喜剧了喔。” / 56 blocks / 1890 chars
PASS  search: 7 results, first=《你们赶紧给我结婚吧！》优汰
PASS  sugoi 2026: 2 sections, 13 books
PASS  rank: 13 books, first=玩乐关系
```

离线单元测试覆盖：GBK 解码、首页四栏目、登录拦截识别、搜索结果、详情字段、目录分卷、
章节正文清洗、分页标记、书评列表与详情、文库分类、实体解码、封面 URL 规则、
年度榜单（含 2012 年前的旧版大写标签）。

CI（`.github/workflows/ios-build.yml`）会先跑离线测试，再用 `xcodebuild` 在 iOS 26 与 iOS 27 两个 SDK 下
各真实编译一次、校验产物结构，并分别上传未签名的 `.ipa`。

## 已知限制

- 文库的 WAP 排行榜与分类列表在未登录时只返回登录卡片，因此这两处依赖桌面版页面；如果站方调整反爬策略，日志会显示 `needLogin` 或 `unavailable`，界面会给出提示与网页版入口。
- 发帖、签到等写操作需要登录态，当前版本只读；加入书架与书架同步已支持，但依赖登录态。
- 中转服务是第三方公益服务，随时可能下线；下线后排行榜会回落到年度榜单，分类列表会提示需要登录。
- 中转服务的访问凭证需自行提供，仓库不内置（原因见上文「可选：公益中转服务」）。
- 插图章节在 WAP 版仅返回「本章节是纯图片内容」提示，正文页会如实呈现该提示。

## 许可

GPL-2.0，与原项目一致。原始 Android 版作者：MewX；UI 设计：ZERO。
