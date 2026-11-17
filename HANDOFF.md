# 工作交接文档 · 轻小说文库 iOS 版

> 供在 Mac 上继续开发使用。最后更新：2026-11-17（会话第 5 轮）
> 仓库：<https://github.com/jijijitian/light-novel-library_Wenku8_iOS>（已转为 **private**）

---

## 0. 一分钟速览

| 项目 | 状态 |
| --- | --- |
| 工程形态 | `project.yml`（XcodeGen）→ 生成 `Wenku8.xcodeproj`，用 **Xcode / xcodebuild** 构建 |
| 部署目标 | iOS 17.0（Liquid Glass 仅在 iOS 26+ 生效，iOS 17/18 回落材质） |
| 核心层 | 仍是纯 SwiftPM 模块，可在 Linux 上跑测试 |
| 单元测试 | **51 个**，全部通过（`bash tools/test-core-linux.sh`） |
| 联网校验 | 全部通过（`bash tools/test-live.sh`） |
| 已完成 | SwiftUI 重写、Liquid Glass、登录、加书架、阅读器、搜索、排行榜、书评 |
| **本轮完成** | ① 首页卡片文字重叠已修 ② dock 改为自绘、对齐截图 ③ relay API 已接入（凭证注入 + 限速 + 回退） ④ 构建从 xtool 迁到 Xcode |
| **仍待办** | 真机实测（本机 Xcode 版本一次没过，见 §9） |

---

## 1. 仓库与分支

```
本地工作副本：/Users/jht/Documents/wenku8/work
GitHub：      jijijitian/light-novel-library_Wenku8_iOS  默认分支 master
可见性：      private（2026-11-17 由 public 转为 private）
```

工作区干净时请以 `git log` 为准。仓库保留原项目 GPL-2.0 的 `LICENSE`。

---

## 2. 目录结构

```
work/
├── project.yml                       ★ XcodeGen 工程声明（app + core framework）
├── Package.swift                     SwiftPM 包（核心层 + 测试目标）
├── Support/
│   ├── AppIcon.png                   1024×1024，由 tools/make_icon.py 生成
│   ├── Assets.xcassets/              图标资源目录（Xcode 编译成 Assets.car）
│   ├── Info.plist                    显示名、方向、ATS、CFBundle* 模板值
│   └── PrivacyInfo.xcprivacy         隐私清单
├── Sources/
│   ├── Wenku8Core/                   ★ 与 UI 无关，可在 Linux 编译和测试
│   │   ├── TextDecoding.swift        自建 GBK 解码表 + 资源查找（CoreResources）
│   │   ├── Markup.swift              手写 HTML/XML tokenizer + 实体解码
│   │   ├── WAPParser.swift           WAP 版解析
│   │   ├── DesktopParser.swift       桌面版解析
│   │   ├── SugoiParser.swift         年度榜单解析（2006–2026）
│   │   ├── AccountParser.swift       登录错误文案 / 登录拦截 / 书架变更结果
│   │   ├── RelayClient.swift         ★ 中转传输层：限速 + 凭证注入 + 错误映射
│   │   ├── RelayParser.swift         ★ 中转 XML → 现有模型
│   │   ├── RelayCredential.swift     ★ 凭证本地存储（UserDefaults）
│   │   ├── Network.swift             URLSession 封装、双域名回退、UA 分流、Cookie
│   │   ├── NovelService.swift        业务门面（中转优先，失败回落网页版）
│   │   ├── Models.swift              数据模型 + 错误枚举 + CoverURL
│   │   └── Resources/gbk-table.bin   47 KB 查表
│   └── Wenku8iOS/                    SwiftUI 界面层（16 个文件）
│       ├── Wenku8App.swift           @main + AppRouter + AppTheme
│       ├── RootView.swift            ★ 自绘 dock（DockBar）+ 懒挂载的五个 NavigationStack
│       ├── DesignSystem.swift        ★ 所有 Liquid Glass 修饰符集中于此
│       ├── Components.swift          NovelRow / NovelGrid / CoverCard
│       ├── HomeView.swift            首页（HeroBanner + PageDots）
│       ├── RankView.swift            排行榜 + LibraryListView
│       ├── SearchView.swift          搜索 + FlowLayout
│       ├── NovelDetailView.swift     详情（书架按钮在这里）
│       ├── ReaderView.swift          阅读器
│       ├── ReviewView.swift          书评列表/详情
│       ├── ShelfView.swift           我的书架
│       ├── SettingsView.swift        设置（账号区 + 中转服务区）
│       ├── LoginView.swift           登录页
│       ├── AccountStore.swift        登录态 + 云端书架同步
│       ├── LibraryStore.swift        本地书架/进度/搜索历史持久化
│       └── WebSheet.swift            SFSafariViewController 包装
├── Tests/Wenku8CoreTests/            51 个测试 + 25 个 fixture（含 4 个 relay XML）
├── tools/
│   ├── bootstrap-xcodeproj.sh        ★ 生成工程 / 编译 / 装真机
│   ├── test-core-linux.sh            离线测试
│   ├── test-live.sh                  联网校验
│   ├── smoke/main.swift              联网校验的检查项
│   ├── gen_gbk_table.py              重新生成 GBK 表
│   └── make_icon.py                  重新生成图标
└── .github/workflows/ios-build.yml   xcodebuild 双 SDK 构建矩阵
```

---

## 3. 构建与验证（Mac 原生，不用 xtool）

### 3.1 生成工程

```bash
bash tools/bootstrap-xcodeproj.sh generate      # 生成 Wenku8.xcodeproj
open Wenku8.xcodeproj                            # 选你的 iPhone，⌘R
```

- 没有 `xcodegen` 时脚本会自动把 2.43.0 下到 `.build-mac/tools/`，不需要 Homebrew。
- `Wenku8.xcodeproj` 是生成产物，**不进仓库**（`.gitignore` 已排除）。
- 改了 `project.yml` 或增删源文件后要重新 `generate`。

### 3.2 命令行真机流程

```bash
bash tools/bootstrap-xcodeproj.sh device
```

等价于：生成工程 → `xcodebuild -destination id=<UDID> -allowProvisioningUpdates` →
`devicectl install` → `devicectl launch`。

签名用 Xcode 里登录的 Apple ID 团队；`project.yml` 里的 `DEVELOPMENT_TEAM` 换成你自己的。

### 3.3 CI

`.github/workflows/ios-build.yml` 三个 job：

| Job | Runner | 用途 |
| --- | --- | --- |
| Core tests | ubuntu + `swift:6.1-noble` | 跑 51 个离线测试 |
| Xcode build (iOS 26 SDK) | `macos-26` | 编译 → 校验 bundle → 校验 Mach-O → 打未签名 ipa |
| Xcode build (iOS 27 SDK) | `xcode-27` | 同上 |

产物名：`Wenku8-unsigned-ios26` / `Wenku8-unsigned-ios27`。

### 3.4 本地校验脚本

```bash
bash tools/test-core-linux.sh    # 离线：51 个测试
bash tools/test-live.sh          # 联网：真实请求校验
```

> **沙箱提示**：两个脚本都带 `--disable-sandbox`，因为 `swift test` 默认会 `sandbox-exec`
> 一个只允许写 `~/Library/Caches` 的沙箱，在某些受限环境下会直接失败。
> 如果你在普通终端跑，加不加这个参数都可以。

---

## 4. 数据源现状（改动前务必读）

| 数据 | 可用路径 | 备注 |
| --- | --- | --- |
| 首页四栏目 | WAP `/wap/` | UTF-8，匿名可读 |
| 书籍详情 | WAP `/wap/article/articleinfo.php?id=` | 匿名可读 |
| 目录 | WAP `/wap/article/readbook.php?aid=` | 分页，每页约 18–20 章 |
| 正文 | WAP `/wap/article/readchapter.php?aid=&cid=` | 可用 `psize=50000` 一次取全 |
| 搜索 | WAP POST `/wap/article/search.php` | 必须 POST，GET 无效 |
| 书评 | WAP `/wap/article/reviews.php?aid=` | 匿名可读 |
| 封面 | `https://img.wenku8.com/image/<aid/1000>/<aid>/<aid>s.jpg` | 分组公式已全量校验 |
| 排行榜 | 仅 relay 可匿名拿到 | 否则回退年度榜单 |
| 年度榜单 | 桌面 `/zt/sugoi/<year>.php` | 2006–2026 全部可用 |
| 按文库分类 | 仅 relay 可匿名拿到 | 否则抛 `needLogin` |

**User-Agent 必须分流**：

- `Wenku8Client.wapUserAgent` → Android Chrome（WAP 页面接受）
- `Wenku8Client.desktopUserAgent` → **iPhone Safari**（桌面页面若用 Android UA 会被 Cloudflare 403）

---

## 5. 待办一（已完成）：relay API 接入

### 5.1 协议（实测确认）

```
POST https://wenku8-relay.mewx.org/
Content-Type: application/x-www-form-urlencoded

body（裸拼接，request 值不做二次 URL 编码）：
&appver=<version>-<magic>-<sig8>
&request=<base64("action=book&do=info&aid=1305&t=0")>
&timetoken=<毫秒时间戳>
```

不带有效 `appver` 时服务端返回 **400 Bad request**（已实测），所以凭证是硬门槛。

### 5.2 为什么仓库里没有签名算法

`appver` 是对官方客户端逆向得到的防滥用凭据；pywenku8api 作者刻意不公开，理由就是
「公开后存在被滥用于大规模抓取的风险」。本仓库曾计划公开，现已转为 private 但仍**不内置算法**。

采用的方案是 **运行时注入**：

```swift
public protocol RelayAppVerProvider: Sendable {
    func appVer(for token: RelayToken) async -> String?
    func invalidate() async
}
```

- 默认实现 `RelayCredentialStore` 把用户粘贴的凭证存进 `UserDefaults`
- 入口：**设置 → 中转服务 → 开启 + 粘贴凭证**
- 没有凭证时 `RelayClient.isAvailable == false`，所有接口原样走网页版

### 5.3 实现要点

| 文件 | 职责 |
| --- | --- |
| `RelayClient.swift` | POST 组装、`RelayThrottle` 串行限速（默认 1.2 秒、下限 0.5 秒）、HTTP 状态 → `RelayError` 映射（401/403 会 `invalidate()` 凭证） |
| `RelayParser.swift` | `metadata/item`、`package/volume/chapter`、`content/p/img` 三类 XML → 现有模型；返回码翻译 |
| `RelayCredential.swift` | 凭证持久化、掩码显示、限速间隔持久化 |
| `NovelService.swift` | 每个接口「relay 优先 → 失败回落 WAP/桌面」 |

### 5.4 已知未验证点

- **真实 XML 响应未抓取过**（没有有效凭证）。`RelayParser` 是按 Android 接口注释里的
  XML 样例写的，容错做得比较宽（字段名多候选、扁平/嵌套章节都吃）。
  拿到真实响应后，把样本存进 `Tests/Wenku8CoreTests/Fixtures/` 并补断言即可。
- 书架 `del` 的返回码映射按文档实现（`1` 成功 / `7` 不在书架），未实测。

---

## 6. 待办二（已完成）：首页卡片「查看详情」与页码点重叠

### 根因

系统分页指示器画在 `TabView` **内部**底部居中，而「查看详情」在 `VStack` 末尾正好落同一高度带。

### 改法

- `indexDisplayMode: .never` 关掉系统圆点
- 「查看详情」紧跟作者行，不再被 `Spacer()` 沉底
- 新增 `PageDots`：画在卡片**外面**下方，独立一行，选中态是拉长的胶囊并染主题色

---

## 7. 待办三（已完成）：底部 dock 对齐截图

### 选型

放弃系统原生 Liquid Glass dock（搜索项会被拆到右侧、选中态是系统胶囊），改为**完全自绘**。

### 实现（`RootView.swift`）

| 截图要求 | 实现 |
| --- | --- |
| 半透明深色毛玻璃底条 | `.background(.bar)` + `.ultraThinMaterial` |
| 顶部细分割线 | 0.5pt `Rectangle`，另加一条白色高光 |
| 5 个等宽 item，图标上文字下竖排 | `VStack(spacing: 3)` + `.frame(maxWidth: .infinity)` |
| 选中项整个变主题蓝 | `foregroundStyle(isSelected ? AppTheme.accent : .secondary)` |
| 无选中胶囊 | `Button` + `.buttonStyle(.plain)` |
| 均分无额外间距 | `HStack(spacing: 0)` |

### 架构联动（重要）

自绘 dock 后 `TabView` 不再负责切换，改为：

- `ZStack` 里放五个 `NavigationStack`，用 `opacity` / `allowsHitTesting` 切换
- `mountedTabs` 集合：tab 首次访问才挂载，冷启动只跑首页的网络
- **阅读页隐藏 dock**：从当前栈的 `path.last` 推导 `isReading`，而不是 `onAppear` 打标记 ——
  这样侧滑返回时也能正确恢复。原来的 `.toolbar(.hidden, for: .tabBar)` 已删除。

---

## 8. 已知问题与坑（踩过的，别再踩）

| 问题 | 结论 |
| --- | --- |
| `Glass` / `.glassEffect` 找不到 | 这些符号只在 iOS 26 SDK 里。除了 `#available`，还要套 `#if compiler(>=6.2)`，否则旧 Xcode 直接编译失败 |
| macOS 27 + Xcode 16.4 | 平台识别不出来，`xcodebuild` 报 `iOS 18.5 is not installed`。需要用 Xcode 26+ |
| `xcodebuild` 报 Could not resolve package dependencies | SPM 清单缓存写死 `~/Library/Caches/org.swift.swiftpm`，该路径不可写时必失败。解决办法：工程不用 SPM 依赖，核心层改成 framework target |
| `Bundle.module` 在 Xcode 工程里不存在 | `Bundle.module` 是 SwiftPM 生成的。已加 `CoreResources` 按 `#if SWIFT_PACKAGE` 分流 |
| `swift test` 在受限环境失败 | 加 `--disable-sandbox`（两个测试脚本已加） |
| `Tab` 类型重名 | 自己的枚举改名 `AppTab` |
| `strings`/`nm` 管道进 `grep -q` | SIGPIPE 会误报失败。必须先写文件再检查 |
| `.glassEffect` 只在 iOS 26+ | 全部集中在 `DesignSystem.swift`，别在别处直接调 |
| 阅读器 dock 遮挡 | 自绘 dock 时代改为按路由隐藏，不再用 `.toolbar(.hidden, for: .tabBar)` |
| 桌面 UA | 必须 iPhone Safari，Android Chrome 会被 403 |
| GBK | 桌面版是 GBK。Linux 上 `String(data:encoding:.gbk)` 不可用，所以自建查表 |

---

## 9. 待验证 / 有风险的地方

1. **真机未跑起来**。本轮阻塞在工具链：macOS 已升到 27.2.1，但 Xcode 仍是 16.4，
   它自带的 iOS 18.5 平台在 macOS 27 上不被识别。装好 **Xcode 26+** 后按 §3.2 走一遍即可。
2. **签名证书为空**。`security find-identity -p codesigning` 返回 0 个。
   Xcode 里已登录 Apple ID（Personal Team `C428Z585GG`），但还没生成开发者证书；
   首次在 Xcode 里 Run 到真机会自动创建。
3. **Relay 凭证未配置**，所以整条 relay 链路只有单元测试覆盖，没有真实请求验证。
4. **真机上 Cloudflare 的态度未知**。界面对此有兜底（提示 + 网页版入口）。
5. **排行榜在未登录且没配 relay 时显示年度榜单** 是设计行为，不是 bug。

---

## 10. 在 Mac 上的建议起步顺序

```bash
# 1. 确认工具链
xcodebuild -version            # 需要 Xcode 26 或更新
xcrun --sdk iphoneos --show-sdk-version

# 2. 生成工程并编译
bash tools/bootstrap-xcodeproj.sh generate
bash tools/bootstrap-xcodeproj.sh build

# 3. 跑离线测试
bash tools/test-core-linux.sh   # 51 个

# 4. 联网校验
bash tools/test-live.sh

# 5. 真机（手机需解锁 + 信任此电脑 + 开开发者模式）
bash tools/bootstrap-xcodeproj.sh device
```

---

## 11. 关键代码位置速查

| 想改什么 | 去哪 |
| --- | --- |
| 玻璃效果 / 按钮样式 | `Sources/Wenku8iOS/DesignSystem.swift` |
| 底部 dock | `Sources/Wenku8iOS/RootView.swift` → `DockBar` |
| 首页卡片 / 页码点 | `Sources/Wenku8iOS/HomeView.swift` → `HeroBanner` / `PageDots` |
| 阅读器 | `Sources/Wenku8iOS/ReaderView.swift` |
| 登录 | `LoginView.swift` + `AccountStore.swift` + `NovelService.signIn` |
| 书架 | `LibraryStore.swift`（本地）/ `AccountStore.swift`（云端） |
| 网络 / UA / 回退 | `Sources/Wenku8Core/Network.swift` |
| 所有业务接口 | `Sources/Wenku8Core/NovelService.swift` |
| 中转服务 | `RelayClient.swift` / `RelayParser.swift` / `RelayCredential.swift` |
| 解析规则 | `WAPParser.swift` / `DesktopParser.swift` / `SugoiParser.swift` |
| 工程配置 | `project.yml` |
| CI | `.github/workflows/ios-build.yml` |

---

## 12. 原 Android 版参考位置

上游仓库：<https://github.com/MewX/light-novel-library_Wenku8_Android>

```
studio-android/LightNovelLibrary/app/src/main/java/org/mewx/wenku8/
├── activity/UserLoginActivity.java          登录 UI
├── activity/NovelInfoActivity.java          详情 + 加书架
├── fragment/FavFragment.java                书架
├── reader/activity/Wenku8ReaderActivityV1.java  左右翻页阅读器
└── activity/VerticalReaderActivity.java     上下滑动阅读器

eclipse-android-old/.../api/Wenku8Interface.java
    每个接口的 XML 响应样例（metadata/package/result），接 relay 时对照用
```
