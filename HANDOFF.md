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
| 单元测试 | **80 个**，全部通过（`bash tools/test-core-linux.sh`） |
| 联网校验 | 全部通过（`bash tools/test-live.sh`） |
| 已完成 | SwiftUI 重写、Liquid Glass、登录、加书架、阅读器、搜索、排行榜、书评 |
| **本轮完成** | ① 首页卡片重叠已修 ② dock 改用 iOS 27 原生 Liquid Glass ③ relay API 完整接入（算法已还原） ④ 构建从 xtool 迁到 Xcode ⑤ 真机跑通 ⑥ 左右翻页/首行缩进/图片支持 |
| 真机 | iPhone 17 Pro，Xcode 27.2 自动签名，已安装并运行 |

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
│   │   ├── RelayClient.swift         ★ 中转传输层：限速 + 错误映射
│   │   ├── RelayAppVer.swift         ★ appver 推导 + 自建 SHA-256/HMAC
│   │   ├── RelayParser.swift         ★ 中转 XML → 现有模型
│   │   ├── RelayCredential.swift     ★ 凭证本地存储（UserDefaults）
│   │   ├── Network.swift             URLSession 封装、双域名回退、UA 分流、Cookie
│   │   ├── NovelService.swift        业务门面（中转优先，失败回落网页版）
│   │   ├── Models.swift              数据模型 + 错误枚举 + CoverURL
│   │   └── Resources/gbk-table.bin   47 KB 查表
│   └── Wenku8iOS/                    SwiftUI 界面层（16 个文件）
│       ├── Wenku8App.swift           @main + AppRouter + AppTheme
│       ├── RootView.swift            系统 TabView（iOS 27 原生 Liquid Glass 底栏）
│       ├── DesignSystem.swift        ★ 所有 Liquid Glass 修饰符集中于此
│       ├── Components.swift          NovelRow / NovelGrid / CoverCard
│       ├── HomeView.swift            首页（HeroBanner + PageDots）
│       ├── RankView.swift            排行榜 + LibraryListView
│       ├── SearchView.swift          搜索 + FlowLayout
│       ├── NovelDetailView.swift     详情（书架按钮在这里）
│       ├── ReaderView.swift          阅读器（上下/左右翻页、首行缩进、插图、全屏查看）
│       ├── ReaderPreferences.swift   阅读偏好（翻页方式 / 首行缩进）
│       ├── ReviewView.swift          书评列表/详情
│       ├── ShelfView.swift           我的书架
│       ├── SettingsView.swift        设置（账号区 + 中转服务区）
│       ├── LoginView.swift           登录页
│       ├── AccountStore.swift        登录态 + 云端书架同步
│       ├── LibraryStore.swift        本地书架/进度/搜索历史持久化
│       └── WebSheet.swift            SFSafariViewController 包装
├── Tests/Wenku8CoreTests/            80 个测试 + 30 个 fixture（含 relay 真实响应）
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
User-Agent: okhttp/4.12.0      ← 必须，否则 Cloudflare 403 (error code 1010)

body（裸拼接，request 值不做二次 URL 编码）：
&appver=<version>-<codeName>-<sig8>
&request=<base64("action=book&do=info&aid=1305&t=0")>
&timetoken=<毫秒时间戳>
```

### 5.2 appver 算法（已还原，已内置）

APK 里 `libcpp.so` 带着完整 DWARF 调试信息（`.debug_info` 1.2MB），
直接把 `native-lib.cpp` 的源码行号和变量名都暴露了：

```
now       = time()                      // 秒
window    = now / 60                    // 分钟窗口
payload   = "1.30" | "digital-bento" | window      // 竖线拼接
digest    = HMAC-SHA256(key: "digital-bento", message: payload).hex
appver    = "1.30-digital-bento-" + digest[12..<20]
sig8      = 十六进制字符串的第 12–20 位
```

关键点（都是踩过的坑）：

- `hmac_sha256(x0, x1)` 的 **x0 是 key、x1 是 message**，别搞反
- **key 是 codeName（`digital-bento`），不是 payload**
- payload 里 **不包含 secret**，`getSecretFor1_30` 的返回值只作为 key
- `time()` 返回**秒**，窗口 = 秒 / 60（不是毫秒 / 60000）
- 只有 `1.30-digital-bento` 能过；`1.23`/`1.32` 变体一律 400

实现：`Sources/Wenku8Core/RelayAppVer.swift`（含自建 SHA-256 / HMAC，
因为核心层要能在 Linux 上编译，不能用 CryptoKit）。

### 5.3 真实响应格式（和 Android 注释里的 XML 不一样！）

| 接口 | 真实格式 |
| --- | --- |
| `book&do=meta` | `<data name="Title" aid="1614"><![CDATA[…]></data>`、`<data name="Author" value="鸭志田一"/>` |
| `book&do=intro` | 纯文本 |
| `book&do=list` | `<package><volume vid="54755"><![CDATA[第一卷]]><chapter cid="54756"><![CDATA[主要人物]]></chapter>…` |
| `book&do=text` | **纯文本**（非 XML），标题在首行，空行分段 |
| `book&do=cover` | JPEG 二进制 |
| `novellist` | `<result><item aid='3519'><data name='Title'><![CDATA[…]></data>…` |
| `articlelist` | 只有 `<item aid='3519'/>`，**没有标题**，单独不可用 |
| `xml&item=sort` | `<item sort="1">电击文库</item>` |
| `login` / `bookcase` | 裸整数 |

### 5.4 接入效果

`NovelService` 里 relay 优先、失败回落网页版：

| 能力 | relay 前 | relay 后 |
| --- | --- | --- |
| 排行榜 | 年度榜单兜底 | 真实榜单（13 本/页，带标题作者） |
| 按文库分类 | `needLogin` | 真实列表 |
| 搜索 | WAP POST | 更快（1 次请求） |
| 书籍详情 | WAP 或桌面 | meta + intro 合并，字段更全（字数/标签/最近章节） |
| 目录/正文 | WAP，部分书「文章不存在」 | **版权下架的书也能读到**（见下） |

**验证过的书**：`aid=1614`（青春猪头少年）。网页版 WAP 目录返回
「对不起，该文章不存在！」，桌面正文返回「因版权问题，文库不再提供该小说的阅读！」；
走 relay 后 17 卷 130 章全部可读，正文 874 段 / 22485 字。

### 5.5 合规说明

算法现已内置在仓库中，前提是**仓库已转为 private**。若将来改回 public，
需要重新评估：这是公益服务的防滥用凭据，公开等于公开一个批量抓取工具。
无论哪种情况都保持了强制限速（默认 1.2 秒/请求，下限 0.5 秒）。

### 5.6 设置项

**设置 → 中转服务** 只有一个开关（默认开启）。关掉就完全回到网页版路径。

## 6. 待办二（已完成）：首页卡片「查看详情」与页码点重叠

### 根因

系统分页指示器画在 `TabView` **内部**底部居中，而「查看详情」在 `VStack` 末尾正好落同一高度带。

### 改法

- `indexDisplayMode: .never` 关掉系统圆点
- 「查看详情」紧跟作者行，不再被 `Spacer()` 沉底
- 新增 `PageDots`：画在卡片**外面**下方，独立一行，选中态是拉长的胶囊并染主题色

---

## 7. 待办三（已完成）：底部 dock 改用 iOS 27 原生 Liquid Glass

### 结论：用系统 `TabView`，不要自绘

第一版按截图自绘过 `DockBar`（等宽竖排、选中变蓝、顶部细线），真机上验收时被否掉了：
用户要的是 **iOS 27 音乐 App 那种浮动玻璃胶囊栏**。那是系统在 iOS 26/27 上给
`TabView` 渲染的原生外观 —— 玻璃胶囊、选中项高亮、边缘渐隐、滚动最小化 —— 自绘无法复刻。

现在 `RootView` 回到系统 `TabView` + `Tab` builder（iOS 18+），iOS 17 走 `tabItem` 回退。
真机截图确认是原生浮动胶囊栏。

### 自绘方案还带来过一个崩溃

自绘版本为了保留每个 tab 的导航历史，把 5 个 `NavigationStack` 同时塞进一个 `ZStack`，
用 `opacity(0)` + `allowsHitTesting(false)` 隐藏未选中的 4 个。这种"隐藏但仍挂载"的
导航栈在被压入页面时行为不可靠（真机上表现为点进书籍详情页偶发崩溃）。
回到系统 `TabView` 后导航由系统管理，这个隐患消失。

顺带恢复阅读器隐藏标签栏：`.toolbar(.hidden, for: .tabBar)`。

## 7.5 阅读器增强（本轮新增）

### 7.5.1 左右翻页 / 上下滑动

- `ReaderPreferences.swift` 定义 `ReaderLayout { vertical, horizontal }`，
  存于 `@AppStorage("reader.layout")`。
- 入口两处：**设置 → 阅读 → 翻页方式**（分段控件），以及阅读器控制条左下角的
  布局切换按钮（图标形态，快速切换）。
- 实现：`horizontal` 模式用分页 `TabView`（`indexDisplayMode: .never`）承载章节，
  左右滑动由 `DragGesture` 判定（>40pt 触发），章节内容垂直方向锁定不可滚，
  滑到边界自动切到上一章 / 下一章。
- 相邻章节会 `prefetch`，避免滑动后看到空白页。

### 7.5.2 首行缩进

- `@AppStorage("reader.indentFirstLine")`，默认关闭。
- 开启后每段 `.padding(.leading, fontSize * 2)`，即两个全角字符宽，
  随字号自适应（18pt → 36pt，28pt → 56pt）。
- 封面/插图块不受影响。

### 7.5.3 图片支持

这里有个**真实的知识点**：relay 返回的插图不是 `<img>`，而是内联标记

```
<!--image-->https://pic.777743.xyz/1/1614/54785/67547.jpg<!--image-->
```

之前的解析器把这个标记当普通文本，于是在正文里排出一屏幕 URL。
现在 `RelayParser.splitImages(in:)` 把它拆成 `.image` 块，并且：

- 只有 `http(s)` / `//` 开头的才当图片，否则回退成文本（`CoverURL.normalize`
  会接受任意字符串，不校验会产生空图片块）
- 同一行里文字 + 图片混排也能正确处理
- 图片源是 `pic.777743.xyz`，实测 5392×3542 原始扫描，可直接访问，不需要特殊 UA

界面部分：

- `ReaderImage` 行内渲染，失败显示占位，加载中显示骨架
- 点击图片进入 `ImageViewer`：全屏、双指缩放（1–5x）、双击放大/还原
- 控制条是浮层，章节内容底部预留 260pt，避免图片被压在面板下面

## 7.6 登录修复（重要）

### 根因：确认会话时读错了页面

`signIn` 走的是**桌面版** `login.php?do=submit`，但成功后却用 **WAP 首页**的
`您好!xxx,` 来确认会话。两者是不同的会话域，桌面登录成功后 WAP 首页仍然是
`您好!游客,`，于是 `accountName()` 返回 nil，抛出「登录未生效，请稍后重试」——
**登录其实成功了，只是确认逻辑读错了地方**。

修复：新增 `AccountParser.desktopAccountName(_:)`，解析桌面版头部

```
轻小说文库欢迎您，<用户名>！            ← 已登录
轻小说文库欢迎您，您可以选择[登录]…      ← 未登录
```

`NovelService.desktopAccountName()` 抓的是**书籍页**（`/book/<aid>.htm`）而不是
`/index.php` 或 `/login.php`：前者的匿名访问会 302 到登录页，后者本身就是登录表单，
都不稳定带这个头部；书籍页对匿名和已登录用户都渲染它。

### 顺带修掉的两个坑

1. `isDesktopLoginPage` 原先匹配 `login.php?jumpurl=`，但**所有页面的头部都含这个链接**，
   导致每个匿名页面都被判定成登录页。现在只认 `<form name="frmlogin">`。
2. 网页登录场景（在 SFSafariViewController 里登录）不共享 App 的 cookie，
   这是系统限制；界面已提供账号密码直接登录作为主路径。

## 7.7 站点域名切换

- `SiteDomain { net, cc }`，对应 `https://www.wenku8.net` 与 `https://www.wenku8.cc`。
- **设置 → 数据来源 → 站点域名**，存于 `@AppStorage("site.domain")`，启动时
  `Wenku8App.restoreDomain()` 应用。
- `SiteEndpoints(domain:)` 把选中域名放第一位，另一个作为回退，所以某个域名
  不通时会自动试另一个。
- 匿名抓取路径不变（首页仍走原来的 WAP 抓取 + 回退），这个开关只决定基准域名。

## 7.8 阅读器控制面板改为覆盖式

原先正文底部内边距随 `showChrome` 变化（260 ↔ 46），点一下就把整章文本重排一次。
现在：

- `ReaderMetrics.bottomInset` 固定 40，正文位置**不受面板显示与否影响**
- `ReaderMetrics.chromeOpacity = 0.82`，面板半透明浮在正文上方，底下文字仍可辨认
- 左右翻页模式同样用固定 inset，不会因为弹出面板而重新分页

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
| 阅读器 dock 遮挡 | 回到系统 TabView 后重新使用 `.toolbar(.hidden, for: .tabBar)` |
| 自绘 dock + 多 NavigationStack | 不要把多个 `NavigationStack` 用 `opacity(0)` 隐藏后仍挂载，压栈时行为不可靠。用系统 TabView |
| `ForEach` 重复 id | SwiftUI 遇到重复 id 是致命错误。数据来自多路拼接（relay/WAP/桌面/年度榜），已统一用 `uniquedByID()` 兜底，`mergeVolumes` 也按章节 id 去重 |
| 桌面 UA | 必须 iPhone Safari，Android Chrome 会被 403 |
| GBK | 桌面版是 GBK。Linux 上 `String(data:encoding:.gbk)` 不可用，所以自建查表 |

---

## 9. 待验证 / 有风险的地方

1. **真机已跑通**：iPhone 17 Pro（`00008150-000A61460247401C`），Xcode 27.2 自动签名，
   证书 `Apple Development: 2294959606@qq.com (CBPF4U5DJK)`（Team `C428Z585GG`，有效期到 2027-11）。
   安装与启动命令见 §3.2。
2. **签名注意**：不要同时传 `CODE_SIGN_IDENTITY` 和自动签名，Xcode 会报
   "conflicting provisioning settings"。只传 `DEVELOPMENT_TEAM` 让它自己选。
3. **目录为空的小说**：如 `aid=1614`（青春猪头少年），站点对匿名请求返回
   "对不起，该文章不存在！"，导致 0 卷 0 章。这是站点行为，不是客户端 bug；
   界面此时只显示书籍信息、不显示章节目录。
4. **Relay 凭证未配置**，relay 链路只有单元测试覆盖，没有真实请求验证。
5. **真机上 Cloudflare 的态度**：目前首页、搜索、详情都能正常加载，未触发人机校验。
6. **排行榜在未登录且没配 relay 时显示年度榜单** 是设计行为，不是 bug。

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
| 底部 dock | `Sources/Wenku8iOS/RootView.swift`（系统 TabView，别改回自绘）|
| 首页卡片 / 页码点 | `Sources/Wenku8iOS/HomeView.swift` → `HeroBanner` / `PageDots` |
| 阅读器 | `Sources/Wenku8iOS/ReaderView.swift` |
| 登录 | `LoginView.swift` + `AccountStore.swift` + `NovelService.signIn` |
| 书架 | `LibraryStore.swift`（本地）/ `AccountStore.swift`（云端） |
| 网络 / UA / 回退 | `Sources/Wenku8Core/Network.swift` |
| 所有业务接口 | `Sources/Wenku8Core/NovelService.swift` |
| 中转服务 | `RelayClient.swift` / `RelayParser.swift` / `RelayAppVer.swift` |
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
