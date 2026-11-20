# 轻小说文库中转服务（Relay）协议说明

本文档说明本 App 使用的第三方中转服务 `https://wenku8-relay.mewx.org/` 的工作原理，
内容依据 [`Sources/Wenku8Core/RelayClient.swift`](../Sources/Wenku8Core/RelayClient.swift)、
[`RelayAppVer.swift`](../Sources/Wenku8Core/RelayAppVer.swift)、
[`RelayParser.swift`](../Sources/Wenku8Core/RelayParser.swift) 的实现，
以及对线上服务的实际探测结果。

> 中转是**第三方公益服务**，不是本项目的服务器。它有独立配额，因此本 App 强制限速。
> 本文档只描述已实现的行为，不涉及绕过或滥用。

---

## 1. 它解决什么问题

轻小说文库的网页版对匿名访客设有限制：

| 场景 | 网页版（匿名） | 中转 |
| --- | --- | --- |
| 首页分类榜单 | 可用 | 可用 |
| 排行榜（本周/本月等） | **需要登录** | 匿名可用 |
| 书籍详情 | 可用 | 可用 |
| 搜索 | 可用 | 可用 |
| 云端书架 | 需要登录 | 需要登录（但会话独立） |
| 登录 | **桌面表单需要图形验证码** | 无验证码，返回数字码 |

中转本质上是：**一台已经以 Android 客户端身份与站点交互的服务器**，把站点的原始响应
（XML / 纯文本）原样转发给我们的 App，并替我们维护登录态。

所以它不是一个 REST API，而是「一个 action 字符串进、一段站点原始内容出」的管道。

---

## 2. 传输层

每一次调用都是：

```
POST https://wenku8-relay.mewx.org/
Content-Type: application/x-www-form-urlencoded
User-Agent: okhttp/4.12.0
```

body 只有三个字段：

| 字段 | 内容 |
| --- | --- |
| `request` | action 字符串的 **base64** |
| `appver` | 每分钟变化的凭证（见第 3 节） |
| `timetoken` | 当前 Unix 毫秒时间戳 |

拼接形式（注意开头那个 `&`，服务端接受、客户端也照此发送）：

```
&appver=<appver>&request=<base64>&timetoken=<毫秒>
```

`User-Agent` 是 `okhttp/4.12.0`——模拟官方 Android 客户端的 OkHttp。中转前置了 Cloudflare，
用默认的 URLSession/python UA 会被拦。

**`request` 只做一次 base64，不再做 URL 编码。** 这是一个容易踩的坑：base64 里的 `+` 和 `=`
如果被二次编码，服务端解出来的 action 就变了。

---

## 3. appver 凭证

这是中转的鉴权方式：没有 API key，只有一个**按分钟窗口计算的令牌**。

```
window  = floor(unixSeconds / 60)
payload = "1.30|digital-bento|<window>"
digest  = HMAC-SHA256(key: "digital-bento", message: payload)  // hex
appver  = "1.30-digital-bento-" + digest[12 ..< 20]            // 取第 12~19 位，共 8 个字符
```

举例：`1.30-digital-bento-3f9a1c07`。

要点：

- **不需要联网获取**，本地即可算出，因此没有「令牌过期要刷新」的问题——它每 60 秒自然变化。
- 算法是从官方 APK 的 `native-lib.cpp` 里通过 DWARF 调试信息还原的。
- 官方客户端还带有 `1.23` / `1.32` 两个版本的变体，但中转只接受 `1.30`，所以只实现这一个。
- 实现放在 `RelayAppVer.swift`，自带 SHA-256/HMAC——不依赖 CryptoKit，以便 Core 模块能在
  Linux 上跑单元测试。

---

## 4. action 字符串

`request` 字段 base64 之前的原文，就是站点 API 的动作串。已实现的全部动作：

### 书籍

| 用途 | action 字符串 |
| --- | --- |
| 详情（简介+元数据） | `action=book&do=info&aid=<aid>&t=0` |
| 元数据 | `action=book&do=meta&aid=<aid>&t=0` |
| 简介 | `action=book&do=intro&aid=<aid>&t=0` |
| 封面 | `action=book&do=cover&aid=<aid>` |
| 目录 | `action=book&do=list&aid=<aid>&t=0` |
| 正文 | `action=book&do=text&aid=<aid>&cid=<cid>&t=0` |

### 列表与检索

| 用途 | action 字符串 |
| --- | --- |
| 首页榜单 | `action=novellist&sort=<sort>&page=<page>&t=0` |
| 分类列表 | `action=articlelist&sort=<sort>&page=<page>` |
| 搜索 | `action=search&searchtype=<articlename\|author>&searchkey=<编码后关键字>&t=0` |
| 分类表 | `action=xml&item=sort&t=0` |

### 账号与书架

| 用途 | action 字符串 |
| --- | --- |
| 登录 | `action=login&username=<u>&password=<p>` |
| 登出 | `action=logout` |
| 会话查询 | `action=userinfo` |
| 书架列表 | `action=bookcase&do=list&t=0` |
| 加入书架 | `action=bookcase&do=add&aid=<aid>` |
| 移出书架 | `action=bookcase&do=del&aid=<aid>` |

### 参数转义

`searchkey` 与登录账号密码必须**在拼进 action 之前**做一次 form 编码，且允许集比默认更窄：

```swift
var allowed = CharacterSet.urlQueryAllowed
allowed.remove(charactersIn: "&=?+ #%")
```

原因：`&`/`=` 会截断参数，`+` 会被服务端解成空格，密码里含这些字符时若不编码，表现出来的
现象是「密码错误」——极难排查。

`sort` 的取值是站点自己的排序标识：

| 值 | 含义 |
| --- | --- |
| `lastupdate` | 最近更新 |
| `postdate` | 新书 |
| `dayvisit` / `weekvisit` / `monthvisit` / `allvisit` | 日/周/月/总点击榜 |
| `dayvote` / `weekvote` / `monthvote` / `allvote` | 日/周/月/总推荐榜 |
| `goodnum` / `size` / `fullflag` / `anime` | 收藏数 / 字数 / 完结 / 动画化 |

`t=0` 是站点自己的参数（时间/cache-buster），App 原样透传，不做解释。

---

## 5. 响应格式

中转**不解包、不改写**站点的原始响应，因此有四种形态：

### (1) 结构化 XML（书籍信息、列表）

```xml
<result>
  <item aid="3670">
    <data name="Title" value="败北女角太多了！"/>
    <data name="Author" value="雨森焚火"/>
    <data name="Intro"><![CDATA[长文本放在这里]]></data>
  </item>
</result>
```

站点用的是 `<data name="…" value="…"/>` 这种形式，**不是** `<title>…</title>`。
长文本走 CDATA。

### (2) 目录 XML

```xml
<package>
  <volume vid="1" name="第一卷">
    <chapter cid="12345" name="第一章 …"/>
  </volume>
</package>
```

### (3) 正文：纯文本

`action=book&do=text` 返回的是**章节正文的明文**，不是 XML。所以解析正文时不能按 XML 处理。

### (4) 数字返回码

`login`、`logout`、`bookcase` 的写操作只返回一个整数：

| 码 | 含义 | 依据 |
| --- | --- | --- |
| `1` | 成功 | |
| `2` | 账号无效 / 操作失败 | 用随机账号登录实测返回 |
| `3` | 密码错误 | 用真实账号 + 错误密码实测返回 |
| `4` | 未登录 | `action=userinfo` 匿名时返回 |

> 这张表是**实测**得出的：`jijijitian` + 错误密码返回 `3`，随机账号返回 `2`，
> 未登录时 `userinfo` 返回 `4`。App 据此把「账号不存在」和「密码错误」分开提示，
> 而不是笼统报「登录失败」。

---

## 6. 会话管理

中转**自己**维护与站点的登录态，与 App 访问网页版的 Cookie 是两套。

- 登录成功后，中转通过 `Set-Cookie` 下发自己的会话 Cookie。
- 这些 Cookie 存在 `URLSession` 的共享 CookieStorage 里，**并额外镜像到 UserDefaults**
  （`SharedCookieStore`，键 `relay.cookies`）。
  - 只依赖 `HTTPCookieStorage.shared` 时，冷启动后会话会丢，表现是「书架变空、要求重新登录」。
- 每次收到响应都会 `persistRelayCookies()`，因为任何一次调用都可能刷新会话。

会话有效性用 `action=userinfo` 确认：返回 `4` 即未登录。

### 一次登录 + 同步的完整时序

```
App ──POST action=login&username=…&password=…──▶ 中转
                                    └─▶ 以 Android 身份登录站点
   ◀── "1"（成功）或 "3"（密码错误）+ Set-Cookie ──┘
App ──POST action=userinfo──▶ 中转 ──▶ 返回用户名 / "4"
App ──POST action=bookcase&do=list&t=0──▶ 中转 ──▶ 书架 XML
```

每一步之间强制间隔 ≥1.2 秒（第 7 节），所以一次「登录 + 验证 + 拉书架」至少 2.4 秒。

---

## 7. 限速

中转是公益服务，有独立配额，所以 App **不会并发发请求**：

```swift
actor RelayThrottle {           // 最小间隔默认 1.2 秒
    func acquire() async { … }
}
```

- 是用 `actor` 实现的串行闸门，多个视图同时请求也只会排队。
- 只有中转请求受限；网页版请求不受影响。
- 注意这是**两次请求之间的最小间隔**，不是单次耗时：第一次调用不等待，连续调用时才会排队。
  所以「连接检测」里中转偶尔显示 0.8 秒、偶尔 1.3 秒——差的那部分才是排队时间。

正因为限速，App 侧的缓存（书目录、封面、元数据）意义重大：重复请求等于白白挤占配额。

---

## 8. 错误处理

| HTTP 状态 | App 处理 |
| --- | --- |
| 2xx | 正常返回 body |
| 400 | `badRequest`（参数被拒） |
| 401 / 403 | 判定凭证失效，`invalidate()` 并提示 |
| 429 | `rateLimited`（请求过于频繁） |
| 其它 | `server(code)` |

超时：单次请求 20 秒，整体资源 45 秒。响应缓存策略是 `reloadIgnoringLocalCacheData`。

---

## 9. 与网页版的关系

这是本 App 的一条硬规则：**两个数据源互斥，不混用**。

```
中转开启 → 所有数据走中转；中转失败就报错，不偷偷改用网页版
中转关闭 → 所有数据走网页版；不碰中转
```

理由：混用会产生同一本书两种来源的元数据、书架状态不一致、以及读者无法理解的结果
（「为什么这个页面有排名、那个页面说需要登录」）。

具体体现在：

- `sessionState()` 只查询**当前在用的**那个源
- 登录时只向当前源认证（中转登录 / 网站登录二选一）
- 首页、排行、书籍详情、搜索都以 `relayIsAvailable` 为分支条件

### 验证码问题

网页版的**桌面登录表单**要求图形验证码（`checkcode.php`），中转没有这个环节。
所以：

- 中转开启时，登录只走中转（无验证码）
- 中转关闭时，App 显示验证码图片供用户输入

---

## 10. 调试

App 内置了请求日志（仅 DEBUG）：

```bash
xcrun devicectl device process launch --terminate-existing --console \
  --device <UDID> \
  --environment-variables '{"WENKU8_NET_LOG":"1"}' \
  org.jijijitian.wenku8.ios
```

输出形如：

```
[net] RELAY action=novellist
[net] RELAY action=book
```

想手动验证某个 action，可以直接用命令行：

```bash
AV=$(python3 -c "
import hmac,hashlib,time
k=b'digital-bento'
msg=('1.30|digital-bento|%d' % (int(time.time())//60)).encode()
print('1.30-digital-bento-'+hmac.new(k,msg,hashlib.sha256).hexdigest()[12:20])
")

REQ=$(python3 -c "
import base64
print(base64.b64encode(b'action=userinfo').decode())
")

curl -s -X POST https://wenku8-relay.mewx.org/ \
  -H 'User-Agent: okhttp/4.12.0' \
  --data "request=$REQ&appver=$AV&timetoken=$(( $(date +%s) * 1000 ))"
```

未登录时返回 `4`。

---

## 11. 已知限制

- **不是我们维护的服务**：可用性、配额、排序算法都可能随时变化，App 只能做容错和限速。
- **appver 是逆向结果**：若官方更换客户端版本或算法，中转可能整体失效，需要重新逆向。
- **无文档**：动作串、返回码、XML 结构全部来自实际抓包与探测，服务端可能在不通知的情况下调整。
- **登录态与网页版不通用**：中转的会话只在走中转时有效；关闭中转后需要重新在网站登录。

---

## 12. 代码位置

| 文件 | 职责 |
| --- | --- |
| [`RelayClient.swift`](../Sources/Wenku8Core/RelayClient.swift) | 传输、限速、状态码映射、action 构造 |
| [`RelayAppVer.swift`](../Sources/Wenku8Core/RelayAppVer.swift) | `appver` 推导 + 自带 SHA-256/HMAC |
| [`RelayParser.swift`](../Sources/Wenku8Core/RelayParser.swift) | XML / 列表 / 正文 / 返回码解析 |
| [`RelayCredential.swift`](../Sources/Wenku8Core/RelayCredential.swift) | 开关与凭证存储 |
| [`SharedCookieStore.swift`](../Sources/Wenku8Core/SharedCookieStore.swift) | 会话 Cookie 的持久化 |
| [`NovelService.swift`](../Sources/Wenku8Core/NovelService.swift) | 何时走中转、何时走网页版 |
