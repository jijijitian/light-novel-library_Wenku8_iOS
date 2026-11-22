# 接入新中转 API —— 交接文档

> 面向：接手实现「iOS 客户端支持 `mewx-android.wenku8.app/v2/api`」的 agent
> 来源：对 `MewX/light-novel-library_Wenku8_Android` v2.0.4（2026-11-21 预览版）的反编译与线上探测
> 结论先行：**协议外层已完全查清，载荷信封由原生库生成，必须在安卓运行时里取得参考样本才能复现**

---

## 一、背景与目标

### 现状

本仓库（`jijijitian/light-novel-library_Wenku8_iOS`）的 iOS 客户端有三种数据源：

| 模式 | 数据来源 | 实现 |
| --- | --- | --- |
| 中转 | `https://wenku8-relay.mewx.org/` | `Sources/Wenku8Core/RelayClient.swift` |
| 网页 | `www.wenku8.net` | `Sources/Wenku8Core/Network.swift` + 各 Parser |
| 混合 | 中转优先，网页兜底 | `NovelService.isHybrid` |

中转模式的现状：**旧 API**，表单提交 + 魔改 appver。

### 为什么现在要动

旧中转的运营者已经公开表示旧 API 即将关闭（原文见附录 D）。新 API 是：

- 新域名 `mewx-android.wenku8.app`
- 新路径 `/v2/api`
- 载荷用**原生库密封**（`libmewx.so`）
- 带协议版本协商与强制升级（426）

### 目标（交给你的任务）

让 iOS 客户端具备调用新 API 的能力，并且满足：

1. 不破坏现有三种数据源的行为；
2. 新旧协议可切换（配置项 + 运行时回退）；
3. 调用失败时对用户有明确提示，不出现白屏或无限转圈；
4. 有可验证的验收标准（见第七节）。

---

## 二、当前代码结构（你需要改的地方）

```
Sources/Wenku8Core/
├── RelayClient.swift        ← 中转协议实现（URL、表单、header、节流）
├── RelayAppVer.swift        ← appver 生成（旧协议的魔改版本号）
├── RelayCredential.swift    ← 中转开关、混合开关、账号
├── RelayParser.swift        ← 中转返回的 XML 解析
├── NovelService.swift       ← 业务层：relayIsAvailable / isHybrid / 各接口
└── Network.swift            ← 网页端请求

Sources/Wenku8iOS/
└── DataSourceSettingsView.swift   ← 数据源设置界面（开关、说明文案）
```

旧协议的请求形态（`RelayClient` 现状，作为对照）：

```swift
// POST https://wenku8-relay.mewx.org/
// User-Agent: okhttp/4.12.0
// body: request=<base64(action=…&…&t=0)>&appver=<token>&timetoken=<毫秒>
// appver = "1.30-digital-bento-" + hmacSHA256(key:"digital-bento", msg:"1.30|digital-bento|<分钟>")[12..<20]
```

节流：**两次请求最小间隔 1.2 秒**（不是每次开销，是全局限速）。新协议是否保留同样节流未知，**默认沿用**。

---

## 三、新 API 的外层协议（已确认）

### 端点与请求

```
POST https://mewx-android.wenku8.app/v2/api
X-WK8-Proto: 2
<密封后的字节>
```

- 只有这一个自定义请求头（来自 `NativeEnvelopeBridge` 里的 `singletonMap("X-WK8-Proto","2")`）
- `Content-Type` 在反编译代码中未直接可见，建议先按 `application/octet-stream` 试
- 旧的 `request=` / `appver=` / `timetoken=` **一律不要带**，服务端会直接 `400 {"error":"BAD_REQUEST"}`

### 响应与错误

| 情况 | 观察到的响应 |
| --- | --- |
| 旧格式打到 `/v2/api` | `400 {"error":"BAD_REQUEST"}`（`application/json`） |
| 打到 `/` 或 `/api`、`/v1/api` | `404 Not Found`（`text/plain`） |
| 成功 | **未观察到**（需要合法信封） |

服务端通过响应头做版本协商：

```
X-WK8-Proto           客户端声明（当前固定 "2"）
X-WK8-Min-Version     服务端要求的最低版本
X-WK8-Update-Hint     升级提示文案
```

低于门槛时返回 426，客户端应停止调用并提示用户升级。

### 旧的辅助端点在新域名下不可用

`/version`、`/args/notice_sc`、`/args/notice_tc` 在新域名下全部 302 到赞助页；它们在旧域名下仍然可用：

```
GET https://wenku8.mewx.org/version        → 200，正文 "73"
GET https://wenku8.mewx.org/args/notice_sc → 200，855 字节通知
```

---

## 四、信封是怎么生成的（反编译结论）

### 调用链

```java
// 启动时初始化
NativeEnvelopeBridge.c(application)
  ├─ System.loadLibrary("mewx")                    // libmewx.so
  ├─ byte[32] seed，逐字节计算：
  │    seed[i] = ((lv1.C[i] & 0xFF) - ((i*19 + 7) & 0xFF)) ^ (lv1.D[i] & 0xFF)
  └─ native a(context, assets, seed, 104, flavor)
        flavor: "playstore"=1, "default"=2
        原生侧通过 AAssetManager 读 assets/wk8_lut.bin（2048 字节）

// 每次请求
NativeEnvelopeBridge.d(body, extra)                 // 返回 vr3(headers, bytes)
  ├─ native b(body.getBytes(UTF_8), extra.getBytes(UTF_8), counter.get())
  └─ headers = {"X-WK8-Proto": "2"}

// 时间对齐（抗重放）
counter.set(serverTime - System.currentTimeMillis())
```

### 关键证据

```java
public final class NativeEnvelopeBridge {
    public static final Map a = Collections.singletonMap("X-WK8-Proto", "2");
    private static native boolean a(Context, AssetManager, byte[], int, int); // init
    private static native byte[] b(byte[], byte[], long);                     // seal
}
```

`libmewx.so`（arm64-v8a，93 KB）：

- 导出符号只有 `JNI_OnLoad` / `JNI_OnUnload`
- 导入符号只有 `memcpy`、`memset`、`AAsset_*`、`pthread_*`、`clock_gettime`、`syslog`
- **没有**任何 AES / GCM / ChaCha / OpenSSL / Tink 的符号
- 因此：自研的查表型密码，不是标准算法

`assets/wk8_lut.bin`：2048 字节，随机分布，疑似 512 个 32 位表项。

### 你无法直接照抄的部分

- 信封的字节布局（头、nonce、密文、tag 的排列）
- 响应是否需要解密（客户端只调用了 `b()` 一个原生方法，未见解密入口）
- `d(body, extra)` 里 `body` 与 `extra` 分别放什么（推测 body=请求体，extra=附加信息如 action）

这些必须靠**参考样本**反推，见第五节。

---

## 五、如何拿到参考样本（关键步骤）

> 没有样本，后面的实现无法验证；这是整项工作的前置条件。

### 方案 A：安卓模拟器 + JNI Hook（推荐）

1. 安装 Android SDK（`brew install --cask android-commandlinetools`），创建 ABI 匹配的模拟器
2. 安装 APK：
   ```
   adb install app-default-release-v2.0.4.104.apk
   ```
3. 用 `frida` 或 `objection` hook `NativeEnvelopeBridge.b`，把 `arg0/arg1/arg2`（输入）与返回值（输出）都 dump 出来：
   ```javascript
   Java.perform(() => {
     const B = Java.use('org.mewx.wenku8.api.internal.NativeEnvelopeBridge');
     B.b.implementation = function (body, extra, counter) {
       const out = this.b(body, extra, counter);
       console.log('seed? body=' + bytesToHex(body) + ' extra=' + bytesToHex(extra) + ' counter=' + counter);
       console.log('sealed=' + bytesToHex(out));
       return out;
     };
   });
   ```
4. 同时抓取服务端响应原文（OkHttp interceptor 或 `adb shell tcpdump` + mitmproxy），确认响应是否明文
5. 把「明文请求 → 密封字节」成对保存为测试向量（至少 20 组，覆盖不同 action）

### 方案 B：native Hook（方案 A 出问题时）

用 `frida` 直接 hook `libmewx.so` 的导出偏移（`JNI_OnLoad` 附近），或 `LD_PRELOAD` 一个 shim 替换 `b()`。难度更高，但能绕过 Java 层。

### 方案 C：从零逆算法（不推荐）

反汇编 93 KB ARM64 代码 + 2048 字节 LUT + 种子推导，还原查表密码。工作量以周计，且密钥一换就得重来。

**建议先做 A**：拿到 20 组向量后，很多问题（信封布局、是否需要解密、body/extra 的含义）会直接自明。

---

## 六、在 iOS 仓库里的实现方案

### 6.1 新增文件

```
Sources/Wenku8Core/RelayV2/
├── RelayV2Transport.swift      // 密封/解封的 Swift 封装，调用下面的 C
├── mewx_envelope.c             // 从 Android 原生库移植的算法（或对向量的查表实现）
├── MewxEnvelope.h
└── mewx_lut_data.c             // assets/wk8_lut.bin 转成的 C 数组
```

> 如果第五节拿到的是「可直接查表的映射」而非可移植算法，就退而求其次：把算法实现为**对向量的插值/表驱动**是不现实的，必须真的把算法移植过来。请以向量为准做单元测试。

### 6.2 协议切换

在 `RelayConfiguration` 里加一项，**默认保持旧协议**：

```swift
public enum RelayProtocol: String, Codable, Sendable {
    case legacy   // 旧：POST / + appver
    case sealed   // 新：POST /v2/api + X-WK8-Proto
}
```

`RelayClient.send(_:)` 里按协议分派：

```swift
switch configuration.protocol {
case .legacy:
    let body = legacyForm(action)                 // 现有实现，原样保留
    request.url = legacyURL
    request.httpBody = body
case .sealed:
    let plain = action.data(using: .utf8)!        // 注意：先确认 action 是否需要包一层 JSON
    let sealed = try RelayV2Transport.seal(plain)
    request.url = v2URL
    request.setValue("2", forHTTPHeaderField: "X-WK8-Proto")
    request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
    request.httpBody = sealed
}
```

### 6.3 版本门禁

每次响应都检查：

```swift
if let minVersion = response.value(forHTTPHeaderField: "X-WK8-Min-Version"),
   appVersion < minVersion {
    throw Wenku8Error.upgradeRequired(hint: response.value(forHTTPHeaderField: "X-WK8-Update-Hint"))
}
if statusCode == 426 { throw Wenku8Error.upgradeRequired(...) }
```

`Wenku8Error` 需要新增 `upgradeRequired`，并在 UI 层映射成「该中转要求升级客户端，请更新应用」的提示（参考 `ErrorStateView`）。

### 6.4 失败回退

- `sealed` 失败且用户开启了**混合模式** → 走现有网页兜底（无需改动）
- `sealed` 失败且是**纯中转** → 提示切换到网页模式（新增按钮，跳到 `DataSourceSettingsView`）
- 旧协议返回 `426` 或 `/version` 变化 → 自动提示切换

### 6.5 设置界面

`DataSourceSettingsView` 增加一节：

```
中转协议
[ 自动 ] [ 旧版 ] [ 新版（实验） ]
```

默认「自动」＝先试新版，失败回退旧版（或反之，按实测决定）。

### 6.6 测试

```
Tests/Wenku8CoreTests/RelayV2Tests.swift
├── testSealMatchesAndroidVectors   // 用第五节的 20 组向量逐一比对
├── testUnsealResponse              // 若响应加密
├── testUpgradeHeaderParsing        // 426 / X-WK8-Min-Version
└── testFallbackToLegacy            // sealed 失败 → legacy
```

验收要求：向量测试**逐字节**相等，不接受「结构相似」。

---

## 七、验收标准

1. 纯中转模式（新版协议）下，以下接口全部可用：
   - 首页榜单（`novellist` 各 sort）
   - 书籍详情（`book&do=meta` / `do=info` / `do=bookinfo` / `do=intro`）
   - 目录与正文（`chapterList` / `text`）
   - 书架（`bookcase`）
   - 书评列表与楼层（`review&do=list` / `do=show`）
   - 登录、用户信息
2. 旧协议不受影响，可随时切回
3. 426 / 版本不足时有明确提示，不重试轰炸
4. 单元测试全绿，且**向量测试逐字节一致**
5. 真机（iPhone 17 Pro，见 `docs/` 里的约束）验证通过

---

## 八、风险与约束（请务必读）

1. **节流**：沿用 1.2 秒最小间隔；抓包与验证时不要并发轰炸。
2. **回退优先**：如果实现成本超过两周，或向量始终对不齐，应停止并把资源转回网页/混合模式的健壮性（例如中转失败时的引导文案）。

---

## 九、附录

### A. 探测矩阵（可直接复现）

| 请求 | 结果 |
| --- | --- |
| `GET https://mewx-android.wenku8.app/` | 302 → `buymeacoffee.com/mewx` |
| `GET https://wenku8-relay.mewx.org/` | 302 → `wenku8.mewx.org` |
| `POST /v2/api`（旧表单） | 400 `{"error":"BAD_REQUEST"}` |
| `POST /v2/api`（JSON 各种组合） | 400 `{"error":"BAD_REQUEST"}` |
| `POST /`（新域名） | 404 `Not Found` |
| `POST /v2/api`（旧域名） | 500 `Something went wrong....` |
| `GET /version`（旧域名） | 200，正文 `73` |
| `GET /args/notice_sc`（旧域名） | 200，855 字节 |
| `GET /version`（新域名） | 302 |

### B. 产物位置（本机）

```
/tmp/and2/app-default-release-v2.0.4.104.apk     # 新预览版
/tmp/and2/app-alpha-release-v1.30.73.apk         # 公开版（对照）
/tmp/and2/decomp/                                # jadx 反编译输出
/tmp/and2/decomp/sources/org/mewx/wenku8/api/internal/NativeEnvelopeBridge.java
/tmp/and2/decomp/sources/defpackage/kn0.java     # 调用点
/tmp/and2/decomp/sources/defpackage/ze3.java     # 网络引擎
/tmp/and2/app-default-release-v2.0.4.104/assets/wk8_lut.bin
/tmp/and2/app-default-release-v2.0.4.104/lib/arm64-v8a/libmewx.so
```

### C. 复现命令

```bash
# 下载
gh release download v2.0.4 -R MewX/light-novel-library_Wenku8_Android

# 解包
unzip app-default-release-v2.0.4.104.apk -d apk

# 反编译
jadx --no-res -d decomp app-default-release-v2.0.4.104.apk

# 关键类
grep -rn "NativeEnvelopeBridge" decomp/sources | head
```

---

## 十、一句话总结

**外层协议已经清楚（`/v2/api` + `X-WK8-Proto: 2` + 密封体），密封体由 `libmewx.so` 生成；先用安卓模拟器 + Frida 抓 20 组明文/密封向量，再决定是实现还是放弃。**

---

## 十一、实施结果（2026-11-22）

> 本节记录这次工作的实际产出，供后续接手的人直接对照。

### 已完成

| 项 | 状态 | 位置 |
| --- | --- | --- |
| 外层协议契约 | ✅ 完整逆向 | [`relay-v2-protocol-contract.md`](relay-v2-protocol-contract.md) |
| 信封算法 | ✅ 完整复原并逐字节验证 | [`relay-v2-envelope-findings.md`](relay-v2-envelope-findings.md) |
| 密钥派生（Swift） | ✅ 与原生库 `.bss` 状态一致 | `Sources/Wenku8Core/RelayV2/RelayV2KeySchedule.swift` |
| 协议切换（自动/旧/新） | ✅ 默认旧版 | `RelayProtocolPreference` |
| 426 / 版本门禁 | ✅ 含不重试处理 | `Wenku8Error.upgradeRequired`、`RelayClient` |
| 时钟偏移（401 CLOCK_SKEW） | ✅ 解析并回填 counter | `RelayClient.clockSkew` |
| 设置界面协议选择 | ✅ | `DataSourceSettingsView` |
| 单元测试 | ✅ 148 项全绿（新增 14） | `Tests/Wenku8CoreTests/RelayV2Tests.swift` |

### 关键修正

早期文档（含本文件第三节）称信封是「自研查表型密码、只有 ARM64 机器码、无法移植」。
**这个结论是错的。** 实际执行路径用的是标准原语：

- `0x6cc0` = **SHA-256**
- `0x7050` = **HMAC-SHA256**
- `0x8dc0` = **AES S-box**，`0xa050` = **AES-256-CTR**
- `0x7d40` = 一次性 **HKDF**（Extract + 单次 Expand），不是「迭代扩展」

所以算法本身**是可以在 iOS 上原生实现的**，不需要嵌入任何安卓二进制。

### 未完成（诚实记录）

**`seal` 阶段未实现。** 缺的是 `body‖padding` 之后的混合层（`0xe240` 附近约 188 条指令 + 尾部 66 字节 MAC 块）。

原因不是工作量，而是**验证不了**：即使密钥派生与原生库完全一致，用该信封请求线上仍返回

```
POST https://mewx-android.wenku8.app/v2/api  → 403 {"error":"ENVELOPE_INVALID"}
```

已排除的原因见 `relay-v2-envelope-findings.md` 第 3 节（时钟偏移、flavor、sourceDir、熵源、密钥派生均非原因）。
**服务端依赖客户端二进制之外的输入**，这不是继续逆向客户端能解决的。

因此 `RelayV2Transport.seal` 明确抛出 `sealUnavailable`，而不是产出一个「格式正确但服务端不认」的信封——
后者只会让失败表现为无诊断的 403。

### 因此对验收标准的影响

- 第 1 条（新版协议下各接口可用）：**未达成**，被服务端拒绝阻断。
- 第 2 条（旧协议不受影响）：**达成**，实测旧协议仍返回 `200`。
- 第 3 条（426 有明确提示、不重试）：**达成**。
- 第 4 条（单测全绿）：**达成**，148/148。
- 第 5 条（真机验证）：未进行——需要签名与连接设备；Core framework 已确认可编译。
