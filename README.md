# 轻小说文库 iOS 版

轻小说文库（[wenku8.net](https://www.wenku8.net)）的 iOS 第三方客户端，用 **SwiftUI** 重写，界面采用 **Liquid Glass**（iOS 26/27 的液态玻璃）设计，并通过 **[xtool](https://github.com/xtool-org/xtool)** 以 SwiftPM 的方式构建 —— 不需要 Xcode 工程文件，也不需要 macOS 才能编译。

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
- 阅读器的底部控制条属于固定浮层，使用 `.glassCard`；工具栏按钮沿用系统在 iOS 26 上自带的玻璃背景。

## 构建

### 方式一：xtool（Linux / Windows / macOS，无需 Xcode 工程）

```bash
# 1. 安装 xtool（详见 https://xtool.sh）
brew install xtool-org/tap/xtool        # macOS
# 或从 https://github.com/xtool-org/xtool/releases 下载对应平台的二进制

# 2. 首次配置：登录 Apple ID 并准备 iOS SDK
xtool setup

# 3. 编译（产出 xtool/Wenku8iOS.app）
xtool dev build --configuration release

# 4. 连接真机后直接安装并启动
xtool dev
```

`xtool dev` 会自动完成设备注册、证书与描述文件生成、签名与安装。首次安装后需要在 iOS 的
**设置 → 通用 → VPN 与设备管理** 里信任开发者证书。

### 方式二：Xcode（可选）

```bash
open Package.swift      # Xcode 会把 SwiftPM 包当作项目打开
```

选择 iOS 真机或模拟器运行即可。注意：`Wenku8iOS` 是 library 产品，需要在 Scheme 里指定
`Wenku8iOSApp` 可执行目标（由 xtool 生成的 builder 目标），或直接用方式一。

### 产物结构

```
xtool/Wenku8iOS.app/
├── Wenku8iOS                  # 可执行文件
├── Info.plist                 # 由 xtool 合并 Support/Info.plist 生成
├── AppIcon.png                # 来自 xtool.yml 的 iconPath
├── PrivacyInfo.xcprivacy      # 隐私清单
└── Wenku8Core_Wenku8Core.bundle/   # GBK 解码表等资源
```

## 项目结构

```
.
├── Package.swift                     # SwiftPM 包定义（库产品 + 测试目标）
├── xtool.yml                         # xtool 打包配置：bundleID / Info.plist / 图标 / 资源
├── Support/
│   ├── AppIcon.png                   # 1024×1024 图标
│   ├── Info.plist                    # 屏幕方向、ATS、显示名等
│   └── PrivacyInfo.xcprivacy         # 隐私清单
├── Sources/
│   ├── Wenku8Core/                   # 与 UI 无关的核心层，可在 Linux 上编译与测试
│   │   ├── TextDecoding.swift        # 内置 GBK 解码（文库桌面版为 GBK）
│   │   ├── Markup.swift              # 轻量 HTML 解析器
│   │   ├── WAPParser.swift           # WAP 版页面解析（首页/详情/目录/正文/书评）
│   │   ├── DesktopParser.swift       # 桌面版页面解析（回退路径）
│   │   ├── Network.swift             # URLSession 封装、双域名回退、Cookie
│   │   ├── NovelService.swift        # 业务接口
│   │   └── Models.swift              # 数据模型
│   └── Wenku8iOS/                    # SwiftUI 界面层
│       ├── Wenku8App.swift           # 入口 + 路由
│       ├── RootView.swift            # TabView + NavigationStack
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
├── Tests/Wenku8CoreTests/            # 解析器测试（含真实页面样本）
├── tools/
│   ├── test-core-linux.sh            # 在 Linux Swift 下跑核心层测试
│   ├── gen_gbk_table.py              # 重新生成 GBK 解码表
│   └── make_icon.py                  # 重新生成 App 图标
└── .github/workflows/ios-build.yml   # CI：Linux 跑测试 + macOS 用 xtool 编译
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

## 测试

核心层不依赖 SwiftUI，可以在任意 Swift 6.1 环境（含 Linux 容器）下跑单元测试：

```bash
bash tools/test-core-linux.sh
```

覆盖内容：GBK 解码、首页四栏目、登录拦截识别、搜索结果、详情字段、目录分卷、章节正文清洗、
分页标记、书评列表与详情、文库分类、实体解码、封面 URL 规则。

CI（`.github/workflows/ios-build.yml`）会先跑这套测试，再在 macOS runner 上用 xtool 真实编译、
校验产物结构，并上传未签名的 `.ipa`。

## 已知限制

- 文库的 WAP 排行榜与分类列表在未登录时只返回登录卡片，因此这两处依赖桌面版页面；如果站方调整反爬策略，日志会显示 `needLogin` 或 `unavailable`，界面会给出提示与网页版入口。
- 发帖、加入云端书架、签到等写操作需要登录态，当前版本只读。
- 插图章节在 WAP 版仅返回「本章节是纯图片内容」提示，正文页会如实呈现该提示。

## 许可

GPL-2.0，与原项目一致。原始 Android 版作者：MewX；UI 设计：ZERO。
