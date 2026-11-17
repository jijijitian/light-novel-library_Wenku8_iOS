# 工作交接文档 · 轻小说文库 iOS 版

> 供在 Mac 上继续开发使用。最后更新：2026-11-17（会话第 4 轮）
> 仓库：<https://github.com/jijijitian/light-novel-library_Wenku8_iOS>

---

## 0. 一分钟速览

| 项目 | 状态 |
| --- | --- |
| 工程形态 | 纯 SwiftPM（无 `.xcodeproj`），用 xtool 打包 |
| 部署目标 | iOS 17.0（Liquid Glass 仅在 iOS 26+ 生效，iOS 17/18 回落材质） |
| 构建验证 | GitHub Actions 双 SDK 矩阵，iOS 27.1 + iOS 26.5 **均编译通过** |
| 最近绿构建 | run `44084643601`，commit `a464549` |
| 单元测试 | 35 个，全部通过（`bash tools/test-core-linux.sh`） |
| 联网校验 | 32 项，全部通过（`bash tools/test-live.sh`） |
| 已完成 | SwiftUI 重写、Liquid Glass、登录、加书架、阅读器、搜索、排行榜、书评 |
| **未完成** | **① relay API 接入 ② 首页卡片文字重叠 ③ 底部 dock 样式对齐截图** |

---

## 1. 仓库与分支

```
本地工作副本：D:\wenku8\work        （Windows 上开发时的路径）
上游参考：    D:\wenku8\upstream    （MewX Android 版完整源码，只读参考）
GitHub：      jijijitian/light-novel-library_Wenku8_iOS  默认分支 master
```

最近提交（新的在上）：

```
a464549  Avoid SIGPIPE false failures when verifying the built binary
960a454  Gate the Tab builder behind iOS 18 with a tabItem fallback for iOS 17
6645382  Rename app tab enum to avoid shadowing SwiftUI.Tab
25d9dc2  Add login, remote bookshelf sync, hero banner split layout, hide tab bar in reader, adopt Tab-based dock
af2a08d  Document the dual-SDK build matrix and artifact contents
```

工作区干净，无未提交改动。`LICENSE` 保留原项目 GPL-2.0。

---

## 2. 目录结构

```
work/
├── Package.swift                     两个 library 产品 + 一个测试目标
├── xtool.yml                         bundleID / Info.plist / 图标 / 资源
├── Support/
│   ├── AppIcon.png                   1024×1024，由 tools/make_icon.py 生成
│   ├── Info.plist                    显示名、方向、ATS 明文放行
│   └── PrivacyInfo.xcprivacy         隐私清单（UserDefaults / 文件时间戳）
├── Sources/
│   ├── Wenku8Core/                   ★ 与 UI 无关，可在 Linux 编译和测试
│   │   ├── TextDecoding.swift        自建 GBK 解码表（桌面版是 GBK）
│   │   ├── Markup.swift              手写 HTML tokenizer/parser + 实体解码
│   │   ├── WAPParser.swift           WAP 版解析：首页/详情/目录/正文/书评
│   │   ├── DesktopParser.swift       桌面版解析（含"本站正式关闭"占位页识别）
│   │   ├── SugoiParser.swift         年度榜单解析（2006–2026，兼容旧版大写标签）
│   │   ├── AccountParser.swift       登录错误文案 / 登录拦截 / 书架变更结果
│   │   ├── Network.swift             URLSession 封装、双域名回退、UA 分流、Cookie
│   │   ├── NovelService.swift        业务门面（所有接口都在这里）
│   │   ├── Models.swift              数据模型 + 错误枚举 + CoverURL
│   │   └── Resources/gbk-table.bin   47 KB 查表
│   └── Wenku8iOS/                    SwiftUI 界面层（16 个文件）
│       ├── Wenku8App.swift           @main + AppRouter + AppTheme
│       ├── RootView.swift            TabView（iOS18+ Tab builder / iOS17 tabItem）
│       ├── DesignSystem.swift        ★ 所有 Liquid Glass 修饰符集中于此
│       ├── Components.swift          NovelRow / NovelGrid / CoverCard
│       ├── HomeView.swift            首页（含 HeroBanner，★待改）
│       ├── RankView.swift            排行榜 + LibraryListView
│       ├── SearchView.swift          搜索 + FlowLayout
│       ├── NovelDetailView.swift     详情（书架按钮在这里）
│       ├── ReaderView.swift          阅读器（★ dock 隐藏已修）
│       ├── ReviewView.swift          书评列表/详情
│       ├── ShelfView.swift           我的书架
│       ├── SettingsView.swift        设置（账号区在这里）
│       ├── LoginView.swift           登录页
│       ├── AccountStore.swift        登录态 + 云端书架同步
│       ├── LibraryStore.swift        本地书架/进度/搜索历史持久化
│       └── WebSheet.swift            SFSafariViewController 包装
├── Tests/Wenku8CoreTests/            35 个测试 + 21 个真实页面 fixture
├── tools/
│   ├── test-core-linux.sh            离线测试（复制核心层到临时包再跑）
│   ├── test-live.sh                  联网校验
│   ├── smoke/main.swift              联网校验的检查项
│   ├── gen_gbk_table.py              重新生成 GBK 表
│   └── make_icon.py                  重新生成图标
└── .github/workflows/ios-build.yml   双 SDK 构建矩阵
```

---

## 3. 构建与验证

### 3.1 在 Mac 上构建（推荐）

```bash
# 依赖：Xcode 26/27、Homebrew
brew install xtool-org/tap/xtool
xtool setup                 # 首次：登录 Apple ID + 指定 iOS SDK
xtool dev build --configuration release
# 产物：xtool/Wenku8iOS.app  （可再 `xtool dev` 直接装真机）
```

`xtool.yml` 关键字段：

```yaml
version: 1
bundleID: org.mewx.wenku8.ios
product: Wenku8iOS
infoPath: Support/Info.plist
iconPath: Support/AppIcon.png
resources:
- Support/PrivacyInfo.xcprivacy
```

> 注意：`Wenku8iOS` 是 **library** 产品。真正的 `@main` 入口由 xtool 注入的
> builder target 承载。所以**不要**指望在 Xcode 里直接 Run 这个包——用 xtool，
> 或在 Xcode 里手工建一个 app 壳工程。

### 3.2 CI

`.github/workflows/ios-build.yml` 三个 job：

| Job | Runner | 用途 |
| --- | --- | --- |
| Core tests | ubuntu + `swift:6.1-noble` | 跑 35 个离线测试 |
| xtool build (iOS 27 SDK) | `xcode-27` | Xcode 27.1 / iphoneos27.1 |
| xtool build (iOS 26 SDK) | `macos-26` | Xcode 26.6 / iphoneos26.5 |

每个 build job 会：硬断言 SDK 主版本号 → 编译 → 校验 bundle → 校验 Mach-O
（arm64、`_main`、SwiftUI/UIKit 链接、`platform 2`）→ 打未签名 ipa → 上传 artifact。

产物名：`Wenku8iOS-unsigned-ios27` / `Wenku8iOS-unsigned-ios26`。

### 3.3 本地校验脚本

```bash
bash tools/test-core-linux.sh    # 离线：35 个测试，任意 Swift 6.1 环境
bash tools/test-live.sh          # 联网：32 项真实请求校验
```

---

## 4. 数据源现状（重要，改动前务必读）

站点目前对匿名请求的行为很分裂，代码里的所有回退逻辑都是被逼出来的：

| 数据 | 可用路径 | 备注 |
| --- | --- | --- |
| 首页四栏目 | WAP `/wap/` | UTF-8，匿名可读 |
| 书籍详情 | WAP `/wap/article/articleinfo.php?id=` | 匿名可读 |
| 目录 | WAP `/wap/article/readbook.php?aid=` | **分页**，每页约 18–20 章 |
| 正文 | WAP `/wap/article/readchapter.php?aid=&cid=` | 可用 `psize=50000` 一次取全 |
| 搜索 | WAP POST `/wap/article/search.php` | 必须 POST，GET 无效 |
| 书评 | WAP `/wap/article/reviews.php?aid=` | 匿名可读 |
| 封面 | `https://img.wenku8.com/image/<aid/1000>/<aid>/<aid>s.jpg` | 分组公式已用 4328 本全量校验，0 错 |
| **排行榜** | ❌ WAP 要登录 / ❌ 桌面版返回"本站正式关闭" | 回退到年度榜单 |
| **年度榜单** | 桌面 `/zt/sugoi/<year>.php` | 2006–2026 全部可用 |
| 按文库分类 | ❌ 各镜像均要登录 | 抛 `needLogin` |

**User-Agent 必须分流**（这是实测出来的，不是猜的）：

- `Wenku8Client.wapUserAgent` → Android Chrome（WAP 页面接受）
- `Wenku8Client.desktopUserAgent` → **iPhone Safari**（桌面页面若用 Android UA 会被 Cloudflare 403）

关键词：`AccountParser.isLoginGate`、`DesktopParser.isPlaceholder`、
`Wenku8Error.needLogin`。

---

## 5. 待办一：接入 Android 版的 relay API（最优先）

### 5.1 为什么值得做

Android 版现在所有数据都走 `https://wenku8-relay.mewx.org/`，它绕过了：
- WAP 排行榜要登录的限制
- 桌面版"本站正式关闭"的占位页
- Cloudflare 对桌面列表页的拦截

接入后排行榜、分类列表都能拿到真实数据，不用再回退到年度榜单。

### 5.2 协议（已完整确认）

```
POST https://wenku8-relay.mewx.org/
Content-Type: application/x-www-form-urlencoded

body（裸拼接，request 值不做二次 URL 编码）：
&appver=<version>-<magic>-<sig8>
&request=<base64("action=book&do=info&aid=1305&t=0")>
&timetoken=<毫秒时间戳>
```

响应为 XML（`metadata` / `package` / `result`）、纯文本或 JPEG。

已知 action（从 APK dex 提取，原样）：

```
action=book&do=cover&aid=           封面 JPEG
action=book&do=info&aid=&t=         简要信息 XML
action=book&do=meta&aid=&t=         完整元数据 XML
action=book&do=intro&aid=&t=        完整简介
action=book&do=list&aid=&t=         目录 XML（package/volume/chapter）
action=book&do=text&aid=&cid=&t=    正文
action=novellist&sort=&page=&t=     带信息的列表
action=articlelist&sort=&page=      纯 aid 列表
action=search&searchtype=articlename|author&searchkey=&t=
action=bookcase&do=list&t=          书架
action=bookcase&do=add&aid=
action=bookcase&do=del&aid=
action=login&username=&password=     返回单个整数
action=loginemail&username=&password=
action=logout
action=userinfo
action=review&do=list|show|post|reply&aid=|rid=
action=xml&item=sort&t=0            文库分类列表
```

返回码（纯数字文本）：`1` 成功、`2` 用户名错、`3` 密码错、`4` 未登录、
`5` 已在书架、`6` 书架满、`7` 不在书架、`8` 主题不存在、`9` 签到失败、
`10` 推荐失败、`11` 发帖失败、`22` 引用页为 0。

### 5.3 卡点：`appver` 的签名算法

**这是唯一的阻塞项。** `appver` 不是常量，是 native 层每秒/每分钟动态算出来的：

```
appver = "<version>-<magic>-<sig8>"
```

- `<version>`：形如 `1.30`（APK 里 `APP_VERSION` 常量）
- `<magic>`：来自 `getSecretFor1_23v()`，且会被 `getMagicVersionCpp()` 处理
- `<sig8>`：HMAC-SHA256 输出 hex 的**第 12–20 位共 8 个字符**（已确认截取逻辑）

**已完成的逆向工作**（产物在仓库外，见 5.5）：

1. 反汇编了 `lib/arm64-v8a/libcpp.so`，定位到：
   - `Java_org_mewx_wenku8_api_TokenManager_getMagicVersionCpp` @ `0x57f38`，**1796 字节**（STT_FUNC）
   - `_Z11hmac_sha256RKNSt6__ndk1...` @ `0x58cc0`，1200 字节
   - `_Z16getSecretFor1_23v`：**符号表里没有它**（已用 pyelftools 核实），
     说明它被编译器内联进了 magic 函数，必须从 magic 函数的指令流里还原
2. 确认 magic 函数内的字符串常量是用 `mov`/`movk` **立即数内联**的
   （如 `#0x6e75`+`#0x6e6b` → `"un"+"kn"` → `"unknown"`；`#0x2e31`+`#0x3332` → `"1.3"+"2"` → `"1.32"`），
   所以字符串不是放在 `.rodata` 里，必须从指令流还原。
3. 确认函数用 `time()` + `mktime()` 做**分钟窗口**（60 秒粒度），
   即同一分钟内的 appver 相同。
4. 确认 `hmac_sha256(key, message)` 的调用点 @ `0x581f0`，
   之后用 `"-"` 拼接三段，最后截取第 12–20 位。
5. 记录的 `.rodata` 引用：`0x40345` = `"-"`，`0x3f728` = `"igital-bento"`（可疑，可能是别的函数串）。

**下一步该做的**：把 magic 函数的 1796 字节 ARM64 指令全部解码成伪代码，
还原出：
- magic 表（可能是版本 → 随机串的映射，含多个历史版本 1.23/1.24/1.30…）
- HMAC 的 key 和 message 到底是什么（候选：`version + magic`、`magic + timetoken`、
  `version + 分钟窗口数`）

### 5.4 合规提醒（务必读）

pywenku8api 作者**刻意不公开**这个算法，理由写在它的 `appver.py` 文档里：

> 该算法是对官方客户端逆向而来 —— 在公开发行版中内置它存在被滥用于大规模抓取的风险，
> 因此本仓库的公开版本不携带真实算法。

本仓库是 **public** 的。如果还原出算法并提交，等于公开了一个可被批量抓取的工具。
建议二选一：

- **A（推荐）**：算法不写进仓库，改为运行时从用户自己的渠道注入（插件式），
  或只在本地分支验证。
- **B**：在 README 明确写出使用限制 + 请求频率限制，自担风险。

**无论哪种，都要先加请求限速**（relay 有它自己的配额，滥刷会被封 IP）。

### 5.5 逆向产物（在 Windows 本地，**未提交**）

```
D:\wenku8\tools\disasm_relay.py        反汇编脚本（capstone + pyelftools）
D:\wenku8\tools\dump_rodata.py          常量提取脚本
D:\wenku8\disasm_out.txt                900 条指令的反汇编结果
D:\wenku8\rodata_out.txt                字符串常量还原
D:\wenku8\apk\extracted\                已解包的 APK（含 libcpp.so 四个架构）
D:\wenku8\apk\app-alpha-release-v1.30.73.apk
```

在 Mac 上复现反汇编：

```bash
pip3 install capstone pyelftools
# 把 disasm_relay.py 里的 LIB 路径改成你的 libcpp.so 路径
python3 disasm_relay.py > disasm_out.txt
```

### 5.6 代码接入点（算法搞定后）

1. `Sources/Wenku8Core/RelayClient.swift`（新建）：封装 POST、拼 appver、限速
2. `Sources/Wenku8Core/WAPParser.swift` 旁边新增 `RelayParser.swift`，
   把 XML 解析成现有 `NovelSummary` / `NovelDetail` / `Volume` / `ChapterContent`
3. `NovelService` 里改成「relay 优先，失败回落现有 WAP/桌面路径」——
   现有路径全部保留，因为 relay 是第三方公益服务，随时可能挂
4. 测试：把真实 XML 响应存成 fixture，加到 `Tests/Wenku8CoreTests/`

---

## 6. 待办二：首页卡片「查看详情」与页码点重叠

### 现象

`HomeView.swift` 的 `HeroBanner` 里，「查看详情」标签和 `TabView` 的
分页指示器（三个小圆点）位置重叠。

### 原因

`TabView` 用 `.page(indexDisplayMode: .always)`，iOS 把页码点画在
**卡片底部居中**，而「查看详情」在 VStack 末尾、`Spacer()` 之后，
正好落在底部同一高度带。卡片只有 190pt 高，右侧内容区被挤压后更容易撞上。

### 改法（任选）

- **A**：把「查看详情」从 `Spacer()` 之后移出来，紧跟作者行（不再沉底）
- **B**：给 VStack 加 `.padding(.bottom, 24)`，把内容整体抬离页码带
- **C**：页码点改用自定义（`indexDisplayMode: .never` + 自己画的圆点），
  完全掌控位置。**推荐 C**，顺便可以让圆点颜色更贴合渐变背景。

当前相关代码（`Sources/Wenku8iOS/HomeView.swift` 的 `HeroBanner`）：

```swift
Label("查看详情", systemImage: "chevron.right.circle.fill")
    .font(.caption2.weight(.medium))
    .foregroundStyle(.white.opacity(0.9))
```

---

## 7. 待办三：底部 dock 改成截图样式

### 截图描述（用户提供的真机截图，1206×2622）

- 半透明深色毛玻璃底条，**顶部有一条细分割线**
- 5 个等宽 item，每个是「图标在上、文字在下」的**竖排**
- **选中项整个图标+文字变成主题蓝**（未选中是灰白）
- 没有选中态胶囊/背景块，纯靠颜色区分
- 各 item 在底条内水平均分，无额外间距

### 当前实现

`RootView.swift` 已改成 iOS 18+ `Tab` builder + `Tab(role: .search)`，
在 iOS 26/27 上拿到的是**系统原生 Liquid Glass dock**（搜索项被分离到右侧、
点击会 morph 成搜索框）。它和截图**并不一致**：

| 项目 | 系统原生（现在） | 截图（期望） |
| --- | --- | --- |
| 搜索项位置 | 分离到最右，独立圆角 | 与其他项等宽排列 |
| 选中态 | 系统胶囊/着色 | 仅图标文字变蓝 |
| 收起行为 | 可随滚动最小化 | 固定不收起 |

### 决策点（请先确认再动手）

1. **保留系统原生**（符合 iOS 26/27 官方设计，但和截图不同）
2. **完全自定义 dock**（贴图一致，但要自己实现玻璃、选中态、安全区，
   且会失去系统的 morph/收起动效）

如果选 2，做法：`TabView` 改 `.tabViewStyle(.page)` 或直接用 `@State` 切换内容，
底栏用 `HStack` + `glassCard` 自绘，套 `VStack { content; Spacer(); dock }`
或 `.safeAreaBar(.bottom)`。注意这会和「阅读页隐藏 dock」的实现方式联动
（现在是 `.toolbar(.hidden, for: .tabBar)`，自绘后要改成状态控制）。

已确认的 iOS 26 API（若走路线 1 的增强）：
- `.tabBarMinimizeBehavior(.onScrollDown / .never / .automatic)`
- `.tabViewSearchActivation(.searchTabSelection)`
- `Tab(_:systemImage:value:role:content:)` 需要 **iOS 18+**（已做 `#available` 分流）

---

## 8. 已知问题与坑（踩过的，别再踩）

| 问题 | 结论 |
| --- | --- |
| `Tab` 类型重名 | 自己的 `enum Tab` 会和 SwiftUI 的 `Tab` 撞名，导致 `Tab.home` 无法构造。已改名 `AppTab`。 |
| `Tab` builder 的可用性 | 需要 iOS 18+，但部署目标是 17，必须 `#available` 分流。 |
| `strings`/`nm` 管道进 `grep -q` | 会因 SIGPIPE 让 CI 步骤**误报失败**（明明匹配成功）。必须先写文件再检查。 |
| `.glassEffect` 只在 iOS 26+ | 所有玻璃修饰符都集中在 `DesignSystem.swift`，用 `#available` 包好，别在别处直接调。 |
| `strokeBorder` 需要 `InsettableShape` | 泛型约束写成 `S: Shape & InsettableShape`。 |
| 阅读器 dock 遮挡 | 已加 `.toolbar(.hidden, for: .tabBar)`；同时移除了阅读器底部条的 `.ignoresSafeArea(edges: .bottom)`。 |
| 桌面 UA | 必须 iPhone Safari，Android Chrome 会被 403。 |
| GBK | 桌面版是 GBK。Linux 上 `String(data:encoding:.gbk)` 不可用，所以自建了查表。 |
| `Bundle.module` | 资源 bundle 名必须是 `<Product>_<Target>.bundle`，CI 有校验。 |

---

## 9. 待验证 / 有风险的地方

1. **书架删除接口 `bookcase.php?delid=<aid>` 未实测成功**。
   站点对未登录请求一律返回登录卡片，200 无法区分真伪。
   该路径来自 pywenku8api 的文档记载。**登录后请实测一次**。
2. **登录流程只用假账号验证过失败分支**（返回"该用户不存在"）。
   成功分支靠回读 WAP 首页 `您好!xxx,` 确认会话，逻辑正确但**没用真账号跑过**。
3. **Relay API 完全未接入**（见第 5 节）。
4. **真机上 Cloudflare 的态度未知**。我的联网校验是 Linux Swift 客户端，
   iOS URLSession 的 TLS/HTTP2 指纹不同，可能触发人机校验。
   界面对此有兜底（显示提示 + "在网页版查看"）。
5. **排行榜在未登录时显示年度榜单**是设计行为，不是 bug。

---

## 10. 在 Mac 上的建议起步顺序

```bash
# 1. 克隆
git clone https://github.com/jijijitian/light-novel-library_Wenku8_iOS.git
cd light-novel-library_Wenku8_iOS

# 2. 先确认能构建（这一步很重要，先建立基线）
brew install xtool-org/tap/xtool
xtool setup
xtool dev build --configuration release

# 3. 跑离线测试确认代码健康
bash tools/test-core-linux.sh        # 需要 Swift 6.1（macOS 上直接有）

# 4. 联网校验（确认站点接口仍可用）
bash tools/test-live.sh

# 5. 按优先级做三件事
#    ① 首页文字重叠（最简单，先做，改 HomeView.swift 的 HeroBanner）
#    ② dock 样式（先和用户确认走哪条路线）
#    ③ relay API（最难，先解决 appver 算法）
```

---

## 11. 关键代码位置速查

| 想改什么 | 去哪 |
| --- | --- |
| 玻璃效果 / 按钮样式 | `Sources/Wenku8iOS/DesignSystem.swift` |
| 底部 dock | `Sources/Wenku8iOS/RootView.swift` |
| 首页卡片 | `Sources/Wenku8iOS/HomeView.swift` → `HeroBanner` |
| 阅读器 | `Sources/Wenku8iOS/ReaderView.swift` |
| 登录 | `LoginView.swift` + `AccountStore.swift` + `NovelService.signIn` |
| 书架 | `LibraryStore.swift`（本地）/ `AccountStore.swift`（云端） |
| 网络 / UA / 回退 | `Sources/Wenku8Core/Network.swift` |
| 所有业务接口 | `Sources/Wenku8Core/NovelService.swift` |
| 解析规则 | `WAPParser.swift` / `DesktopParser.swift` / `SugoiParser.swift` |
| CI | `.github/workflows/ios-build.yml` |

---

## 12. 原 Android 版参考位置

```
D:\wenku8\upstream\                                          完整上游源码
├── studio-android/LightNovelLibrary/
│   ├── app/src/main/java/org/mewx/wenku8/
│   │   ├── activity/UserLoginActivity.java          登录 UI
│   │   ├── activity/NovelInfoActivity.java          详情 + 加书架
│   │   ├── fragment/FavFragment.java                书架
│   │   ├── reader/activity/Wenku8ReaderActivityV1.java  左右翻页阅读器
│   │   └── activity/VerticalReaderActivity.java     上下滑动阅读器
│   └── api-stub/                                    公开的 API 桩（无真实实现）
└── eclipse-android-old/                             更老的版本，含 API 协议注释（XML 示例很全）
```

`eclipse-android-old/.../api/Wenku8Interface.java` 里的注释保留了
**每个接口的 XML 响应样例**（metadata/package/result），接 relay 时对着看很有用。
