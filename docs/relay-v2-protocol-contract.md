# 新中转 v2 协议契约（逆向结论）

> 调查对象：`MewX/light-novel-library_Wenku8_Android` v2.0.4 preview（`versionCode=104`，`versionName="2.0.4"`）
> 方法：静态分析。`/tmp/and2/decomp/sources`（jadx 默认输出）+ `jadx --show-bad-code` 单类重跑（`/tmp/and3/`）
> 结论先行：**明文请求体是 legacy 同款的 `action=...&...` 表单串，不是 JSON；响应是明文 XML/文本，不需要解封**。
> 标记约定：`[verified]` = 直接读到代码；`[inferred]` = 由代码结构合理推断，未直接观察；`[unknown]` = 无法确定

---

## 0. 一句话

```
POST https://mewx-android.wenku8.app/v2/api
Content-Type: application/octet-stream
Accept-Encoding: gzip
X-WK8-Proto: 2
Cookie: PHPSESSID=<sid>            (仅已登录时)

<libmewx 密封后的字节>              ← 明文 = "action=novellist&sort=lastupdate&page=1&t=0"
                                    ← extra(同时进 native) = "PHPSESSID=<sid>" 或空

← 200 明文 body（XML / 纯文本 / 单个数字；不解封，Content-Type 未知）
```

---

## 1. 明文请求格式（问题 1）—— `[verified]`

### 1.1 结论

明文 `body` 就是**与旧 API 完全一致的 `action=...&...` 表单串**，UTF-8 编码，无 base64、无 JSON、无 URL 外层包装。

`NativeEnvelopeBridge.d(body, extra)` 的两个 String 参数从 Java 层看：

```java
// /tmp/and2/decomp/sources/org/mewx/wenku8/api/internal/NativeEnvelopeBridge.java:52-77
public static vr3 d(String str /*body*/, String str2 /*extra*/) {
    byte[] bytes  = str.getBytes(UTF_8);                              // action 串
    byte[] bytes2 = (str2 == null || str2.isEmpty()) ? new byte[0] : str2.getBytes(UTF_8);
    byte[] b2 = b(bytes, bytes2, c.get());                            // native seal
    return new vr3(a /* {"X-WK8-Proto":"2"} */, b2);
}
```

唯一调用点：

```java
// /tmp/and2/decomp/sources/defpackage/kn0.java:98-107  (kn0 是 (String,String)->vr3 的函数式接口，case 18)
case 18:
    String str2 = (String) obj;   // body
    String str3 = (String) obj2;  // extra
    return org.mewx.wenku8.api.internal.NativeEnvelopeBridge.d(str2, str3);
```

而 `kn0((byte)18)` 被作为 `ze3.g` 注入：

```java
// /tmp/and2/decomp/sources/defpackage/ze3.java:31
defpackage.kn0 kn0Var = new defpackage.kn0((byte) 18);   // → this.g
// ze3.java:45   this.g = kn0Var;
```

### 1.2 完整构造链（`ze3.i` → `ze3.c`）

```java
// /tmp/and2/decomp/sources/defpackage/ze3.java:270-278
public final ve3 i(String str /* = 明文 action 串 */) {
    String str2 = (String) this.c.o;                                     // 会话 PHPSESSID 存储
    String concat = str2.length() > 0 ? "PHPSESSID=".concat(str2) : null; // ← extra
    vr3 vr3Var = (vr3) this.g.invoke(str, concat);                       // ← NativeEnvelopeBridge.d
    if (vr3Var == null || h54.X("https://mewx-android.wenku8.app/v2/api")) return null;
    return new ve3(vr3Var, concat);                                      // SealedAttemptPayload
}
```

`ve3` 即 `SealedAttemptPayload`：

```java
// /tmp/and2/decomp/sources/defpackage/ve3.java  (toString)
return "SealedAttemptPayload(sealedRequest=" + this.a + ", exactCookieHeader=" + this.b + ")";
//                                vr3(密封字节+头)                            extra(即 Cookie 头原文)
```

`ze3.c(ve3, a5, long, gm0)` —— **jadx 默认输出里是 "Method dump skipped"**

```java
// /tmp/and2/decomp/sources/defpackage/ze3.java:141-147
public final Object c(ve3 r22, a5 r23, long r24, gm0 r26) {
    /* Method dump skipped, instructions count: 839 */
    throw new UnsupportedOperationException("Method not decompiled: defpackage.ze3.c(...)");
}
```

**已用 `jadx --show-bad-code` 完整恢复**（`/tmp/and3/ze3.java`，命令见 §12）：

```java
// /tmp/and3/ze3.java:226-256  (恢复的 ze3.c 请求构造段)
te3 te3Var2 = new te3(this.k);
rq2 a2 = ue3Var.c.a();
a2.a(j >= 1 ? j : 1L);                        // per-call timeout = 剩余 deadline(ms)，最小 1
a2.e = new r5(te3Var2, (byte) 7);             // EventListener(测量 didStartSendingRequest)
sq2 sq2Var = new sq2(a2);
vr3 vr3Var = ve3Var.a;
xs xsVar = new xs((byte) 7);
xsVar.z("https://mewx-android.wenku8.app/v2/api");
xsVar.s("Accept-Encoding", "gzip");
byte[] bArr = (byte[]) vr3Var.b.clone();
xsVar.v("POST", ah1.b(bArr, d40.B("application/octet-stream")));   // 原始字节即 body
for (Map.Entry entry : vr3Var.a.entrySet()) {                      // {"X-WK8-Proto":"2"}
    xsVar.s((String) entry.getKey(), (String) entry.getValue());
}
String str7 = ve3Var.b;
if (str7 != null) xsVar.s("Cookie", str7);                         // extra 同时作为 Cookie 头
nc3 nc3Var2 = new nc3(sq2Var, new eg3(xsVar));
```

即：**密封字节直接作为 HTTP body 提交**（`hg3`/`RequestBody`），`X-WK8-Proto` 由 `vr3.a` 的 map 逐条 `header(name,value)` 写入。

### 1.3 action 串的实际拼装（`xu4`）

```java
// /tmp/and2/decomp/sources/defpackage/xu4.java
: 9  action=review&do=show&rid=…&page=…&t=…
:15  action=review&do=list&aid=…&page=…&t=…
:21  action=review&do=post&aid=…&title=…&content=…       // title/content = base64(GBK)
:29  action=review&do=reply&rid=…&content=…              // content = base64(GBK)
:35  action=book&do=text&aid=…&cid=…&t=…
:41  action=book&do=intro&aid=…&t=…
:47  action=book&do=meta&aid=…&t=…
:53  action=book&do=list&aid=…&t=…
:60  action=novellist&sort=<sort>&page=<n>&t=…
:113 action=book&do=bookinfo&aid=…&t=…
:119 action=search&searchtype=author&searchkey=<URLEnc UTF-8>&t=…
:123 action=search&searchtype=articlename&searchkey=<URLEnc UTF-8>&t=…
:127 action=loginemail&username=<URLEnc UTF-8>&password=<URLEnc UTF-8>
:131 action=login&username=<URLEnc UTF-8>&password=<URLEnc UTF-8>
:134 o(vu4) → 0 | 1                                // t 参数：SC=0 / TC=1
```

`vu4` = 站点方言枚举 `SC`/`TC`（`/tmp/and2/decomp/sources/defpackage/vu4.java`），只用于 `t=`。
`q42.M(s,"UTF-8")` = `URLEncoder.encode`（`q42.java:519-528`）；`lv1.i(s)` = `Base64.encodeToString(s.getBytes("UTF-8"),0).trim()`（`lv1.java:2156-2158`）。

> ⚠️ 注意 `review post/reply` 用的是 **GBK** 字节再 base64：`xu4.java:22,24,30` → `q42.M(str,"GBK")`。这是旧站点表单方言，v2 原样保留。

---

## 2. `extra` 携带什么（问题 2）—— `[verified]`

**`extra` = `"PHPSESSID=<sid>"`（已登录时）或 `null`（未登录），即一个 Cookie 头片段。**

证据：
1. `ze3.i` 里 `extra` 与 `Cookie` 头是**同一个字符串变量**（`ze3.java:272-277` → `/tmp/and3/ze3.java:250-251`）；
2. `ve3.b` 字段名即 `exactCookieHeader`（`ve3.java` toString）。

语义推断 `[inferred]`：把会话串进密封信封，使服务端可以把「密文 + Cookie」绑定校验（防重放/防篡改/防把 Cookie 换成别人的）。**不含** request id、不含 action、不含时间戳——时间对齐走的是 `NativeEnvelopeBridge.c` 的计数器（§6）。

---

## 3. 线上 HTTP 细节（问题 3）—— `[verified]`

| 项 | 值 | 证据 |
| --- | --- | --- |
| Method | `POST` | `/tmp/and3/ze3.java:239` |
| URL | `https://mewx-android.wenku8.app/v2/api`（固定常量，无动态拼接） | `/tmp/and3/ze3.java:234` |
| 协议 | `HTTP_2, HTTP_1_1`（h2 优先） | `/tmp/and3/ze3.java:209` |
| `X-WK8-Proto` | `2` | `NativeEnvelopeBridge.java:7` → 经 `vr3.a` 写入 `/tmp/and3/ze3.java:242-248` |
| `Content-Type` | `application/octet-stream` | `/tmp/and3/ze3.java:239`（`d40.B("application/octet-stream")` = `MediaType.parse`） |
| `Accept-Encoding` | `gzip`（显式设置 ⇒ 关闭 OkHttp 透明 gzip，需自己解压） | `/tmp/and3/ze3.java:235` + `ze3.java:59-100` |
| `Cookie` | `PHPSESSID=<sid>`，**仅当有会话**（null 时完全不发） | `/tmp/and3/ze3.java:250-251` |
| `User-Agent` | 未显式设置 ⇒ OkHttp 默认 `okhttp/5.5.1` `[inferred]` | APK 内唯一 UA 字面量 `okhttp/5.5.1`（`dd3.java:105` 用于 Proxy CONNECT；`classes.dex` 中 `okhttp/5.5.1` 仅 1 处） |
| `Accept` | ❌ 未设置 | 全局 grep 无 |
| `Authorization` | ❌ 未设置 | 全局 grep 无 |
| body | **密封字节原样**，无 base64、无 JSON 包裹（不存在 `{"sealed":...}` 之类） | `/tmp/and3/ze3.java:238-239` |
| 请求压缩 | ❌ 无（不 gzip 请求体） | 代码中无任何请求侧压缩 |

> `Content-Length` / `Host` / `Connection` 由 OkHttp 自动生成 `[inferred]`。

**只有 3 个非标准/应用层头**：`X-WK8-Proto`（必有）、`Cookie`（可选）、`Content-Type`（octet-stream）。

---

## 4. 响应格式（问题 4）—— `[verified]`

### 4.1 结论：明文，不解封

```java
// /tmp/and3/ze3.java:349-382   （jadx 把首个分支渲染成 if (i != 200)，原始控制流见下）
i = ch3Var.q;                                  // statusCode
if (i == 200) {
    String b = ch3.b(ch3Var, "X-WK8-Update-Hint");
    if (mv1.i(b != null ? h54.r0(b).toString() : null, "1")) { ... }   // §5.3
    pe3Var = new pe3(g(ch3Var, Integer.MAX_VALUE));                    // ← 直接读原始 body
}
else if (i == 401) { ... } else if (i == 403) { ... }
else if (i == 426) { ... } else if (i == 429) { ... } else { ne3 }
```

> jadx 1.5.1 在 restructure 模式下把这段渲染成 `if (i != 200) { …200 的代码… } else if (i == 401)`，
> 属渲染反转。原始字节码（`/tmp/and3/ze3fb.java:507-521`）是
> `r0 = r3.q; r4 = 200; if (r0 == r4) goto L2b2` → `L2b2:` 才是 `X-WK8-Update-Hint` + `pe3` 那段。
> 故「200 分支」的判断是 `[verified]`（并有 fallback 反编译交叉验证）。

`g(ch3)` 只做一件事：若 `Content-Encoding` 含 `gzip` 则 `GZIPInputStream` 解压，然后原样返回字节（`/tmp/and3/ze3.java:75-100`；对应 jadx 默认输出 `ze3.java:59-100`）。**没有任何"解密/解封"步骤。**

- `pe3` = `HttpSuccess(bodyBytes=…)`（`/tmp/and3/src/defpackage.pe3.java`）
- `ze3.e(se3)` 把 `pe3` 映射为 `df3`（`Success(bodyBytes=…)`），`df3` 就是最终给业务层的 `ff3`
  （`ze3.java:158-183` → `/tmp/and3/ze3.java` 的 `e(...)`）

### 4.2 业务层如何消费这些字节

| 响应内容 | 消费方式 | 证据 |
| --- | --- | --- |
| XML（书目/目录/书评/书架） | `new String(bytes, UTF_8)` → `XmlPullParser` | `pv4.c` (`/tmp/and3/s2/defpackage.pv4.java:171-190`)、`cw4.java:63-67` |
| 纯文本（章节正文） | `new String(bytes, UTF_8)` → trim → 回调解析 | `pv4.d` (`/tmp/and3/s2/defpackage.pv4.java:262-290`) |
| 数字返回码（1/2/3/4…） | `o54.L(trimmed)` 解析成 `Int`（≤4 字符时） | `pv4.c:186-192`、`aq4.java` 登录 |

**因此响应格式与旧中转一致**：`XML` / 正文纯文本 / 单个数字。

### 4.3 有没有 native "open/unseal"？——🟥 没有

`NativeEnvelopeBridge` 只声明两个 native 方法，且只有一个 Java 侧消费者：

```java
private static native boolean a(Context, AssetManager, byte[], int, int);  // init（Java: c()）
private static native byte[]   b(byte[], byte[], long);                    // seal（Java: d()）
```

`libmewx.so`（arm64-v8a）导出符号仍只有 `JNI_OnLoad` / `JNI_OnUnload`，`RegisterNatives` 在 `JNI_OnLoad`（`0xd50c`）内完成，未出现第 3 个方法名。全局 grep `NativeEnvelopeBridge` 只有 4 处（类定义、`c()` 初始化、`kn0` 的 `d()`、`tu2` 的 `c.set`）。

⇒ **`b()` 是单向密封**，服务端返回明文。这对 iOS 端是重大利好（只要解决密封就能收明文）。

---

## 5. 版本门禁 / 426 / 403（问题 5）—— `[verified]`

### 5.1 状态码分派表（`ze3.c` 恢复段）

```java
// /tmp/and3/ze3.java:346-380
i = ch3Var.q;
if (i == 200) { /* 见 5.2 */ }
else if (i == 401) {
    String s = new String(g(ch3Var, 4096), UTF_8);     // 最多读 4096 字节
    Long D = m97.D(s);                                  // 解析 {"error":"CLOCK_SKEW","serverTimeMs":…}
    pe3Var = D != null ? new me3(D) : le3.a;            // HttpClockSkew / HttpAuthRejected
}
else if (i == 403) pe3Var = le3.a;                      // HttpAuthRejected
else if (i == 426) {
    kw2 E = m97.E(new String(g(ch3Var,4096), UTF_8));    // {"minVersionCode":..,"minVersionName":..}
    pe3Var = new qe3((Integer) E.n, (String) E.o);      // HttpUpgradeRequired
}
else if (i == 429) pe3Var = oe3.a;                      // HttpRateLimited
else pe3Var = new ne3(i);                               // HttpNon200
```

| 状态 | 内部类型 | 对 Swift 的含义 |
| --- | --- | --- |
| 200 | `pe3` → `df3` | 明文 body |
| 401 | `me3`/`le3` | 时钟偏移（可自动重试） / 认证被拒 |
| 403 | `le3` → `af3` | 服务器校验失败（信封/Cookie 绑定不符）→ 应视为会话失效 |
| 426 | `qe3` → `ef3` | 强制升级 |
| 429 | `oe3` → `cf3` | 限流 |
| 其它 4xx/5xx | `ne3` → `bf3("http_<code>")` | 网络层失败 |
| IO 异常 | `re3` → `bf3(cause.message)` | 可重试一次 |

### 5.2 426 的 body 契约

```java
// /tmp/and2/decomp/sources/defpackage/m97.java:95-118   (m97.E)
JSON: {"minVersionCode": <int>, "minVersionName": "<string>"}
// 解析规则：minVersionCode 必须 > 0，否则置 null；minVersionName trim 后非空
```

`qe3` → `ef3` → `UpgradeRequired(minVersionCode=…, minVersionName=…)`。

### 5.3 `X-WK8-Min-Version` / `X-WK8-Update-Hint`

**注意：这两个头只在 200 分支被检查，且逻辑与直觉相反**

```java
// /tmp/and3/ze3.java:346-352
else if (i == 200) {
    String hint = resp.header("X-WK8-Update-Hint");          // 只取这一个值
    if ("1".equals(hint.trim())) {                            // 必须恰好字符串 "1"
        String mv = resp.header("X-WK8-Min-Version");
        this.j.invoke(mv == null ? null : o54.L(mv.trim()));  // 解析成 Integer，回调 UI
    }
    ...
}
```

- 触发条件：**HTTP 200 + `X-WK8-Update-Hint: 1`**（不是 426！）→ 这是「服务端建议升级」的软提示通道。
- `X-WK8-Min-Version` 的值被 `Integer.parseInt` 解析（`o54.L` = `String.toIntOrNull`，`o54.java:109-119`），即**版本号数字**，不是版本名。
- 回调 `this.j` = `ze3.fn`（构造注入）→ 实际落到 `l93` case 7：

```java
// /tmp/and3/s3/defpackage.l93.java:120-132
Integer num = (Integer) obj;  String name = (String) obj2;
hx0 a = ((tn) this.o).a();
int target = num != null ? num.intValue() : 105;
int clamped = target >= 105 ? target : 105;       // ← 目标版本下限 105
a.h.k(null, Boolean.TRUE);                        // updateAvailable = true
a.d.k(null, new ho(clamped, "https://wenku8.mewx.org/"));
if (!(b44.getMessage() instanceof zn)) a.f.k(null, new zn(clamped, name));  // RequiredUpgradeDialog
```

- `426` 走另一条路：把 `minVersionCode/minVersionName` 直接交给 `qe3`，最终 `ef3` 触发 `zn`（`RequiredUpgradeDialog`）。
- **对比的"当前版本"是硬编码的 104**：

```java
// /tmp/and2/decomp/sources/defpackage/ho.java:30
"UpdateAvailable(currentVersionCode=104, targetVersionCode=" + this.a + ", isPlayStoreManaged=false, downloadPageUrl=" + this.b + ")"
// /tmp/and2/decomp/sources/defpackage/zn.java:36
"RequiredUpgradeDialog(currentVersionCode=104, targetVersionCode=" + this.a + ", minVersionName=" + this.b + ", isPlayStoreChannel=false, downloadPageUrl=https://wenku8.mewx.org/)"
```

所以：**版本比较由服务端决定**（它知道 104 够不够）；客户端只负责展示。客户端唯一的数字约束是「目标版本 < 105 时按 105 显示」。
下载页固定 `https://wenku8.mewx.org/`（`zn.java:36`、`l93.java:128`、`pv4.java`/`s2.java:48-49`）。

### 5.4 独立的旧版检查端点（非 v2）

```java
// /tmp/and2/decomp/sources/defpackage/v20.java:372
byte[] b = ze3.d("https://wenku8.mewx.org/version", this);     // 明文 GET，不走密封
// v20.java:390-400
int v = Integer.parseInt(trim(body));
Object o = v > 104 ? new lo(v) : new ko(v);                    // UpdateAvailable / UpToDate
```

`ze3.d` 是**明文 GET**（`/tmp/and3/s8/defpackage.od3.java:105-150`），只带 `Accept-Encoding: gzip`，仍返回 200 时取 body。这是旧域名的 `/version`（返回纯数字如 `73`）。v2 域名下该路径 302。

---

## 6. 时钟同步（问题 6）—— `[verified]`

**来源：HTTP 401 响应体 JSON，不是响应头、也不是独立端点。**

```java
// /tmp/and2/decomp/sources/defpackage/m97.java:74-93   (m97.D)
String body = trim(str);
if (body.startsWith("{")) {
    JsonObject o = parse(body);
    if ("CLOCK_SKEW".equals(o.get("error").getContent())) {
        Long t = o.get("serverTimeMs").getLongOrNull();
        if (t > 0) return t;
    }
}
return null;
```

```java
// /tmp/and2/decomp/sources/defpackage/tu2.java:217-228   (case 19)
long serverTimeMs = ((Long) obj).longValue();
if (serverTimeMs <= 0) {
    Map m = NativeEnvelopeBridge.a;          // 仅触发类加载，无副作用
} else {
    NativeEnvelopeBridge.c.set(serverTimeMs - System.currentTimeMillis());
}
```

- 字段名：**`serverTimeMs`**（响应体 JSON，`error == "CLOCK_SKEW"`）
- 状态码：**401**
- 补偿：`AtomicLong NativeEnvelopeBridge.c` = `serverTimeMs - now`，作为 native `b(body, extra, counter)` 的第三个参数
- 重试：收到 `me3` 后，若剩余 deadline ≥ 350ms，**立即重封一次并重试**（`/tmp/and3/src/defpackage.ye3.java:150-165`）

> Swift 端：遇到 `401` + `{"error":"CLOCK_SKEW","serverTimeMs":<int64>}` 就更新本地偏移并重试一次；其它 401 视为会话失效。

---

## 7. Action 清单（问题 7）—— `[verified]`

**与 legacy 基本一致**，但有增删。全部字面量来自 `classes.dex` 字符串池 + `xu4.java`/`pv4.java`/`aq4.java`/`t20.java`。

| 用途 | v2 action 串 | 构造位置 | 与 legacy 比 |
| --- | --- | --- | --- |
| 首页/榜单 | `action=novellist&sort=<sort>&page=<n>&t=<0\|1>` | `xu4.java:58-110` | ✅ 同 |
| 书籍元数据 | `action=book&do=meta&aid=<aid>&t=<0\|1>` | `xu4.java:46-50` | ✅ 同 |
| 书籍简介 | `action=book&do=intro&aid=<aid>&t=<0\|1>` | `xu4.java:40-44` | ✅ 同 |
| 书籍详情（详情页合并信息） | `action=book&do=bookinfo&aid=<aid>&t=<0\|1>` | `xu4.java:112-116` | ✅ 同 |
| 目录 | `action=book&do=list&aid=<aid>&t=<0\|1>` | `xu4.java:52-56` | ✅ 同（**没有** `chapterList` 这种新名字） |
| 正文 | `action=book&do=text&aid=<aid>&cid=<cid>&t=<0\|1>` | `xu4.java:34-38` | ✅ 同 |
| 搜索（书名） | `action=search&searchtype=articlename&searchkey=<urlenc>&t=…` | `xu4.java:122-124` | ✅ 同 |
| 搜索（作者） | `action=search&searchtype=author&searchkey=<urlenc>&t=…` | `xu4.java:118-120` | ✅ 同 |
| 登录 | `action=login&username=<urlenc>&password=<urlenc>` | `xu4.java:130-132` | ✅ 同 |
| 登录（邮箱） | `action=loginemail&username=…&password=…` | `xu4.java:126-128` | 🆕 **新增**（`@` 判断，`aq4.java:182`） |
| 登出 | `action=logout` | `t20.java:162` | ✅ 同 |
| 会话/用户 | `action=userinfo` | `aq4.java:436`、`ph2.java:23` | ✅ 同 |
| 书架列表 | `action=bookcase&do=list&t=<0\|1>` | `pv4.java:228` | ✅ 同 |
| 加书架 | `action=bookcase&do=add&aid=<aid>` | `pv4.java:21` | ✅ 同 |
| 移出书架 | `action=bookcase&do=del&aid=<aid>` | `pv4.java:399` | ✅ 同 |
| 书评列表 | `action=review&do=list&aid=<aid>&page=<n>&t=<0\|1>` | `xu4.java:14-18` | ✅ 同 |
| 书评楼层 | `action=review&do=show&rid=<rid>&page=<n>&t=<0\|1>` | `xu4.java:8-12` | ✅ 同 |
| 发书评 | `action=review&do=post&aid=<aid>&title=<b64 GBK>&content=<b64 GBK>` | `xu4.java:20-26` | 🆕 v2 才有 GUI |
| 回复书评 | `action=review&do=reply&rid=<rid>&content=<b64 GBK>` | `xu4.java:28-32` | 🆕 v2 才有 GUI |
| 每日签到 | `action=block&do=sign` | `aq4.java:264` | 🆕 **新增** |

### 被移除的 legacy action

| legacy（`work/docs/relay-api.md`） | v2 状态 |
| --- | --- |
| `action=xml&item=sort`（分类表） | ❌ 不存在（v2 无标签/分类体系） |
| `action=articlelist&sort=…&page=…` | ❌ 不存在 |
| `action=book&do=cover&aid=…` | ❌ 不存在；封面直连 `https://img.wenku8.com/image/<aid/1000>/<aid>s.jpg`（`xu4.java:149-155`） |
| `action=book&do=info&aid=…` | ❌ 不存在（拆成 `meta`+`intro`+`bookinfo`） |
| `sort=anime` | ❌ 枚举里没有 |

### `novellist` 的 sort 取值（`xu4.java:61-103`，`wu4` 枚举 13 项）

```
allvisit  allvote  monthvisit  monthvote  weekvisit  weekvote
dayvisit  dayvote  postdate    lastupdate  goodnum   size   fullflag
```

### `t=` 参数（`xu4.o`，`xu4.java:134-143`）

`SC → 0`，`TC → 1`（站点简体/繁体方言）。所有带 `t=` 的 action 都会带。

---

## 8. 会话 / Cookie（问题 8）—— `[verified]`

### 8.1 完全不使用 OkHttp CookieJar

```java
// /tmp/and2/decomp/sources/defpackage/rq2.java:58
this.u = defpackage.l90.c;                       // l90.c = new l90(emptySet, null)
// /tmp/and2/decomp/sources/defpackage/l90.java:7
public static final l90 c = new l90(te0.D0(new ArrayList()), null);
```

`CookieJar` 是**空实现**（`l90.a` 为空 Set，`b` 为 null）⇒ OkHttp 不会自动存/发任何 Cookie。

### 8.2 手工提取 `PHPSESSID`

```java
// /tmp/and3/ze3.java:316-340  /  /tmp/and3/ze3fb.java:446-490（拿到响应后、分派状态码前）
// 顺序：响应到手 → 遍历响应头抽 PHPSESSID → pf3Var.k(...) → statusCode 分派
for (String hv : ch3Var.s.c()) {                       // fm1 = 响应头 name/value 列表
    int V = h54.V(hv, "PHPSESSID=", 0, false, 6);      // indexOf
    if (V >= 0) {
        int i4 = V + 10;
        int U = h54.U(hv, ';', i4, 4);                 // indexOf(';', from)
        str = h54.r0(U >= 0 ? hv.substring(i4, U) : hv.substring(i4)).toString();
        if (str.length() > 0) break;
    }
}
if (str != null) {
    vl0 vl0Var = this.c;                               // ze3.c = new vl0((byte)1)
    synchronized (vl0Var.n) { vl0Var.o = str; }        // 单例字符串槽
}
```

> 注意 jadx 把这段的循环条件反编译反了（`if (it.hasNext()) { str=null; break; }`），实际语义是「遍历响应头，第一个包含 `PHPSESSID=` 的值；取 `=` 之后到 `;` 之前，trim；非空即停止」。`[verified]`（`h54.V/U` 语义已核对）

- 存储：`ze3.c`（`vl0`，`volatile Object o` 单例字符串槽），**只存 `PHPSESSID` 的值**，不带名字、不带属性。
- 发送：`"PHPSESSID=" + value`，同时用于 `extra`（进密封）与 `Cookie` 头（`/tmp/and3/ze3.java:251`）。
- 提取发生在**状态码分派之前**（`/tmp/and3/ze3fb.java:446-490` 在 `L1cb`（响应到手）之后、`L23e` 的 `ch3Var.q` 分派之前），⇒ **任何状态码**（200/401/403/426/429）的响应头都会被扫描，只要含 `PHPSESSID=` 就采纳。
- **其它 Set-Cookie 一律丢弃**（无 CookieJar、无属性解析、无过期时间）。会话失效靠服务端 401/403 反映。

### 8.3 对 Swift 的启示

`SealedAttemptPayload.exactCookieHeader` 这个名字说明设计意图：**必须把「与密封时一模一样的 Cookie 串」发出去**。因此 Swift 侧：

- 只持久化一个 `String?`（`PHPSESSID` 值），不要复用 `SharedCookieStore` 的 cookie 数组；
- 密封与发送必须使用**同一个** `"PHPSESSID=<v>"` 字符串（服务端很可能把它当作信封的 AAD/绑定值）；
- 未登录时传 `""`/`nil`，且**不要**发 `Cookie` 头。

---

## 9. 重试、超时、限速

### 9.1 超时

```java
// /tmp/and2/decomp/sources/defpackage/ze3.java:50-52, 67-69
this.l = (short) 3000;    // builder.b(3000ms)
this.m = (short) 5000;    // builder.y = 5000, builder.z = 5000
this.n = (short) 10000;   // 整体 deadline
```

| 项 | 值 | 依据 |
| --- | --- | --- |
| connect timeout | 3000 ms | `rq2.b(3000)` `[verified 数值]`；字段映射 `[inferred]` |
| read timeout | 5000 ms | `rq2.y=5000` `[verified 数值]` |
| write timeout | 5000 ms | `rq2.z=5000` `[verified 数值]` |
| 单次 call timeout | `h(deadline) = max(0, 10000 - elapsed)`，且 `max(…, 1)` | `/tmp/and3/ze3.java:228`、`ze3.java:262-268` |
| 整体 deadline | 10000 ms | `ze3.java:52` |
| 剩余 < 350 ms | 放弃，`bf3("deadline_exhausted")` | `/tmp/and3/src/defpackage.ye3.java:233-234` |

### 9.2 重试（最多 1 次）

```java
// /tmp/and3/src/defpackage.ye3.java:210-240
z2 = !re3Var.a || this.y;             // re3.a = "didStartSendingRequest"，y = allowRetry
if (!z2) return new bf3(cause.message);
long h2 = ze3Var.h(j2);
if (h2 < 350) return new bf3("deadline_exhausted");
// 记录坏节点 → 换节点 → 重新密封 → 重试
f = pf3Var.f(str6, j5);               // 标记 pinnedCandidate 失败
ve3 i3 = ze3Var.i(str3);              // 重新密封（counter 已变）
c2 = ze3Var.c(i3, f, h2, this);
```

- 触发条件：`TransportFailure`（IO 异常）且 (未开始发送 || 允许重试)；
- 有 `pinnedCandidate`（纯 IP 路由的候选节点）时，会标记该候选失败并换一个（`pf3` 的节点优选逻辑）；
- 每次重试都**重新密封**（因为 counter/deadline 变了）。
- **429/403/426 不重试**。401+CLOCK_SKEW 重试一次。

### 9.3 限速

v2 代码里**没有找到** legacy 的 1.2 秒全局节流（`RelayThrottle` 的等价物）。`[verified: 未找到]` 但服务端有 429，建议 Swift 侧保守沿用 1.2 s。

---

## 10. 错误表（Swift 可直接实现）

| HTTP | 响应体 / 头 | 客户端动作 |
| --- | --- | --- |
| 200 | 任意（XML/文本/数字） | 正常；若 `X-WK8-Update-Hint: 1` → 读 `X-WK8-Min-Version` 提示升级 |
| 200 | 同上 | 响应头里含 `PHPSESSID=` 则更新本地会话 |
| 401 | `{"error":"CLOCK_SKEW","serverTimeMs":<int64>}` | 更新时钟偏移 → 重封 → 重试 1 次 |
| 401 | 其它 | 会话失效（`HttpAuthRejected`）→ 清会话 |
| 403 | 任意 | 服务器校验失败（`HttpAuthRejected`）→ 清会话，不要重试 |
| 426 | `{"minVersionCode":<int>,"minVersionName":"<str>"}` | 强制升级 |
| 429 | 任意 | 限流，退避 |
| 其它 | 任意 | `networkFailure("http_<code>")` |
| — (IO) | — | 可重试 1 次；否则 `networkFailure(reason)` |

`{"error":"BAD_REQUEST"}` 是**旧格式打新端点**的表现（黑盒探测得到，见 `work/docs/android-relay-v2-probe.md`）；本 APK 代码里没有这个字面量。

---

## 11. 一次性对象图（便于对照 Swift 建模）

```
ze3 (RelayEngine)
├─ a: sq2      OkHttpClient 工厂（每次请求 build 一个新 client）
├─ b: pf3      NetRouter：节点优选 / 候选 pinning / 重试策略
├─ c: vl0      SessionStore（只存 "PHPSESSID" 的值）
├─ d: wz0      Dns
├─ e: di1      () -> Bool    "中转可用"（`r16.A() instanceof zv0`，即网络路由已就绪）
├─ f: di1      () -> Set<String> 允许 pinning 的父域集合 = {"mewx-android.wenku8.app","wenku8-relay.mewx.org", "wenku8.app"}
├─ g: si1      (String,String) -> vr3   = NativeEnvelopeBridge.d  ← 密封入口
├─ h: oi1      (Long) -> Unit           = 时钟偏移回调
├─ i: si1      (Integer,String) -> Unit = 升级提示回调
├─ k: di1      () -> Long   = SystemClock.elapsedRealtime
├─ l/m/n       short 3000 / 5000 / 10000
├─ q: ue3?     当前 in-flight session（按 generationId 复用连接池）
└─ r: Map<Long, ue3>  活着的 session
```

（`e`/`f` 取自 `ze3.java:28-46` 构造函数 + `xc3.java:29-31`（case 1、2）+ `m97.java:665-691`（`m97.q`）+ `m97.java:838-844`（`m97.y` 白名单）。）

### 11.1 节点 pinning（影响 Swift 是否要选路）

```java
// /tmp/and3/src/defpackage.ye3.java:105-108
z  = !m97.y(host) && ((Set) ze3Var.f.invoke()).contains(host);   // host = 端点父域
a5 = z ? pf3Var.b(host) : new a5(0L, null);                     // z ⇒ 走候选节点选路
```

`m97.y(host)` 对 `wenku8.com/net/cn`、`wenku8.mewx.org` 返回 true（`m97.java:843`）⇒ 这些域名**不 pinning**。
`mewx-android.wenku8.app` 的父域是 `wenku8.app` ⇒ 走 `pf3.b(host)`，可能被替换成候选节点的 `relayHost`/`rawIpBytes`（`wz2` = `PinnedRelayCandidate(candidateId, relayHost, rawIpBytes, …)`）。

对 Swift 的影响 `[inferred]`：APK 里有 DNS TXT 优选节点 + 纯 IP 路由。**这不是协议契约的一部分** —— 直连域名即可；只有域名被污染时才需要它。

对应 Swift 命名：`ze3`→`RelayV2Client`，`i()`→`seal(action) -> SealedAttempt`，`c()`→`perform(sealed, route, deadline)`，`ye3`→`performWithRetry`，`pf3`→`RelayRoutePlanner`。

---

## 12. 证据与复现

### 12.1 关键文件

```
/tmp/and2/decomp/sources/org/mewx/wenku8/api/internal/NativeEnvelopeBridge.java   # native 声明
/tmp/and2/decomp/sources/defpackage/kn0.java:98-107                               # d() 唯一调用点
/tmp/and2/decomp/sources/defpackage/ze3.java:270-278                              # 密封 + extra 组装
/tmp/and2/decomp/sources/defpackage/ze3.java:141-147                              # c() 未反编译
/tmp/and2/decomp/sources/defpackage/xu4.java                                      # 全部 action 拼装
/tmp/and2/decomp/sources/defpackage/pv4.java                                      # 业务层 → action → 解析
/tmp/and2/decomp/sources/defpackage/aq4.java                                      # 登录 / userinfo / 签到 / 公告
/tmp/and2/decomp/sources/defpackage/m97.java:74-118                               # CLOCK_SKEW / UpgradeRequired JSON
/tmp/and2/decomp/sources/defpackage/tu2.java:217-228                              # 时钟偏移写入
/tmp/and2/decomp/sources/defpackage/ve3.java                                      # SealedAttemptPayload
/tmp/and2/decomp/sources/defpackage/{pe3,qe3,ne3,oe3,me3,le3,re3}.java            # se3 响应模型
/tmp/and2/decomp/sources/defpackage/{df3,ef3,af3,bf3,cf3}.java                    # ff3 业务模型
```

### 12.2 重跑未反编译方法

```bash
# jadx 1.5.1（/tmp/jadx/bin/jadx；brew 未安装，已解压现成包）
/tmp/jadx/bin/jadx --show-bad-code \
  --single-class defpackage.ze3 \
  --single-class-output /tmp/and3/ze3.java \
  /tmp/and2/app-default-release-v2.0.4.104.apk

# 其它需要 --show-bad-code 的关键类
for c in defpackage.ye3 defpackage.pv4 defpackage.od3 defpackage.l93 defpackage.nu3 \
         defpackage.aq4 defpackage.ch3 defpackage.m97 defpackage.pe3 defpackage.qe3; do
  /tmp/jadx/bin/jadx --show-bad-code --single-class $c \
    --single-class-output /tmp/and3/src/$c.java \
    /tmp/and2/app-default-release-v2.0.4.104.apk
done
```

`-m fallback` 可拿到更接近 smali 的分支结构（`/tmp/and3/ze3fb.java`），用于核对 `ze3.c` 的 status 分派顺序。

### 12.3 版本号

```bash
/tmp/jadx/bin/jadx -d /tmp/and3/res --no-src /tmp/and2/app-default-release-v2.0.4.104.apk
grep -o 'android:version[CN][a-z]*="[^"]*"' /tmp/and3/res/resources/AndroidManifest.xml
# android:versionCode="104"
# android:versionName="2.0.4"
```

---

## 13. 待解决问题（Open questions）

1. **`libmewx.b()` 的字节布局** —— 属另一 agent 的封印算法任务。本报告只确认「输入是 UTF-8 明文 body + UTF-8 extra + int64 counter」和「输出直接当 body」。
2. **`b()` 第三个参数 counter 的精确语义** `[unknown]`：Java 侧是 `AtomicLong`，初值 0，只在 CLOCK_SKEW 时被写成 `serverTimeMs - now`（毫秒偏移）。是「时间偏移」还是「单调序号 + 偏移」无法从 Java 层区分。
3. **`vr3.a` 的 map 是否只有 `X-WK8-Proto`** `[verified: 是的]`，但 `vr3` 是通用 `Map`，未来版本可能加头。
4. **`X-WK8-Proto` 的取值是否有别的合法值** `[unknown]`：Java 层硬编码 `"2"`。
5. **成功响应是否可能带 `Content-Encoding: br`** `[unknown]`：客户端只处理 `gzip`（`ze3.java:72`），其它编码会把压缩字节原样交给 XML 解析器。Swift 侧只需声明 `Accept-Encoding: gzip`。
6. **`extra` 是否被服务端用作 AAD 做绑定校验** `[inferred]`：403 的语义（"服务器校验失败"）强烈暗示是。
7. **`action=review&do=post/reply` 的 GBK+base64 是否被新服务端仍然接受** `[unknown]`：v2 沿用旧拼法，但服务端可能已换成 UTF-8；只有实测能确定。
8. **是否有服务端节流（非 429 的软限速）** `[unknown]`：客户端已无限速代码。
9. **`X-WK8-Min-Version` 的语义是 "versionCode" 还是 "versionName 主版本"** `[inferred: versionCode]`：客户端按 `Integer.parseInt` 解析，且与 105 比较。
10. **`Z`：`ze3.d()` 明文 GET 是否也走 v2 域名** `[verified: 不]`，仍打 `https://wenku8.mewx.org/version`（旧域名）。

---

## 14. 变更记录

| 日期 | 内容 |
| --- | --- |
| 2026-11-22 | 首版。基于 v2.0.4.104 APK 静态分析；`ze3.c` / `ze3.f` / `pv4.c` / `pv4.d` / `od3` 用 `jadx --show-bad-code` 恢复 |
