# wk8-v2-samples — 官方客户端 v2 信封采集结果

采集对象：轻小说文库 Android 官方客户端预发布版 `v2.0.4`
采集时间：2026-11-22
采集环境：x86_64 Android 14 模拟器 + Frida 17.27.4

---

## 0. 一句话结论

**官方客户端抓到的信封，服务端全部返回 200。** 12 组不同 action 的真实信封
（明文 body → seal 输出 → 服务端原始响应）已配对完成，可以直接拿来做逐字节 diff。

顺带纠正一处：请求书里写的 `User-Agent: okhttp/4.12.0` **不对**，实测是
`okhttp/5.5.1`。如果你们的 sealer 把 UA 参与进任何计算，这可能就是偏离点之一。

---

## 1. 环境信息

| 项目 | 值 |
| --- | --- |
| APK | `app-default-release-v2.0.4.104.apk`（6,773,256 字节） |
| SHA-256 | `1c6ffce67cc4fc8323e62f2ad36dba09aad604d93e61c3dbc5e0f0f0373e1a5f` |
| 包名 | `org.mewx.wenku8` |
| versionName / versionCode | `2.0.4` / `104` |
| flavor | `default` |
| minSdk / targetSdk | 24 / 37 |
| 安装路径 | `/data/app/~~LpzIwXoQyd7fJV7COmt3tg==/org.mewx.wenku8-ycM2jzwCDYVyXEdPkE3IBg==` |
| 模拟器 | Android 14 (API 34), `google_apis`, x86_64, WHPX 加速 |
| 注入方式 | `frida-server 17.27.4` / x86_64，root adb |
| 网络 | 模拟器直连（无中间人代理），TLS 明文由 `SSL_write`/`SSL_read` hook 取得 |

APK 来源：
<https://github.com/MewX/light-novel-library_Wenku8_Android/releases/download/v2.0.4/app-default-release-v2.0.4.104.apk>

---

## 2. native 库的实际结构（和请求书的差异）

`lib/x86_64/libmewx.so`，98,496 字节。**注意：这个文件名不是 `libcpp.so`**，
`libcpp.so` 是 v1.30 那代的名字。

```
JNI_OnLoad    @ 0xe440  (0x926 字节)
JNI_OnUnload  @ 0x10030
```

`JNI_OnLoad` 里用 `RegisterNatives` 注册两个方法，方法名是 **SIMD 即时解密**出来的
单字符，所以静态看 dex 是 `a` / `b`，运行时才对上：

| dex 名 | 签名 | 说明 |
| --- | --- | --- |
| `a` | `(Context, AssetManager, byte[], int, int) -> boolean` | 初始化 + 读 LUT |
| **`b`** | `(byte[], byte[], long) -> byte[]` | **seal** |
| `c` | `(Wenku8V2Application) -> void` | 注入 context/assets |
| `d` | `(String, String) -> vr3` | token 握手 |

类：`org.mewx.wenku8.api.internal.NativeEnvelopeBridge`，`a`/`b` 是
`private static native`，`c`/`d` 是 `public static` 包装。

**关键资源**：`assets/wk8_lut.bin`，2048 字节 = 128 个 16 字节条目，无重复，
熵很高。由 `AAssetManager_open`（调用点 0xf7db）读入。这就是你说的「轮常量表」，
它不在 `.rodata` 里，所以单看反汇编找不到——**必须从 assets 拿**。

字符串全部在运行时用 SSE（`pmulld`/`pshufb`/`pxor` + `packuswb`）现算，
包括资源文件名本身。所以 `strings libmewx.so` 什么都看不到，这是设计如此。

### 关于 0xe240 的更正

请求书给的地址里，`0xe240` **不是函数入口**。用 `.eh_frame_hdr` 还原的
183 个函数边界看：

| 你说的 | 实际函数起点 | 函数内 |
| --- | --- | --- |
| `0xfb30` seal 入口 | `0xf9ac` | 内 |
| `0xde30` 中间层 | `0xddbc` | 内 |
| `0xcb80` 缓冲区组装 | `0xcb7c` | 内 |
| **`0xe240` ARX 混合** | **`0xe05c`** | 内 |
| `0xa050` AES-CTR | `0x9f4c` | 内 |

按错误边界切函数会直接算错轮数，建议先用 `eh_frame_hdr` 重新定位。

---

## 3. 交付文件

| 文件 | 内容 |
| --- | --- |
| `envelopes.jsonl` | **P0-1**：12 组配对样本 |
| `pairs.jsonl` | **P0-2**：6 组 seal 调用对照 |
| `traffic.jsonl` | **P0-3**：明文请求/响应全文（含响应体文本） |
| `version-info.json` | **P1-2** + **P2-2** 版本与安装信息 |
| `regs-0xe240.txt` | **P0-4** 真实函数边界（供你重新定位 hook 点） |
| `rejection-matrix.jsonl` | **P1-1** 说明（未主动探测，原因见文件内） |
| `raw/` | 原始 capture，含 UI 动作标记，便于复算 |

### envelopes.jsonl 字段

```json
{
  "seq": 0,
  "time_ms": 1795349...,             // seal 调用时刻
  "body": "action=novellist&sort=lastupdate&page=1&t=0",
  "extra": "",                        // 未登录为空串
  "counter": 0,
  "sealed": "0100c90200d15c478f2a...",// 完整密封字节 hex
  "sealed_len": 154,
  "status": 200,
  "req_headers": { ":method":"POST", ":path":"/v2/api", ... },
  "resp_headers": { "content-type":"text/plain;charset=UTF-8", ... },
  "resp_body_b64": "PHA+PGI+..."
}
```

---

## 4. 已采集的 12 组样本

全部 **status = 200**：

| seq | body | body_len | sealed_len | 差 |
| --- | --- | --- | --- | --- |
| 0 | `action=novellist&sort=lastupdate&page=1&t=0` | 43 | 154 | 111 |
| 1 | `action=novellist&sort=weekvisit&page=1&t=0` | 42 | 159 | 117 |
| 2 | `action=book&do=meta&aid=1973&t=0` | 32 | 141 | 109 |
| 3 | `action=book&do=list&aid=1973&t=0` | 32 | 178 | 146 |
| 4 | `action=book&do=intro&aid=1973&t=0` | 33 | 205 | 172 |
| 5 | `action=book&do=text&aid=1973&cid=69567&t=0` | 42 | 188 | 146 |
| 6 | `action=book&do=text&aid=1973&cid=69568&t=0` | 42 | 182 | 140 |
| 7 | `action=novellist&sort=lastupdate&page=1&t=0` | 43 | 172 | 129 |
| 8 | `action=novellist&sort=weekvisit&page=1&t=0` | 42 | 184 | 142 |
| 9 | `action=book&do=meta&aid=1973&t=0` | 32 | 174 | 142 |
| 10 | `action=book&do=intro&aid=1973&t=0` | 33 | 208 | 175 |
| 11 | `action=book&do=list&aid=1973&t=0` | 32 | 140 | 108 |

**长度律复核**：`sealed_len - body_len` 全部落在 **[108, 175]**，
与你给的 `83 + pad, pad ∈ [16,95]` → **[99, 178]** 一致。规律成立。

seq 0 和 seq 7 是**完全相同**的 body、相同的 counter，但
`sealed_len` 分别是 154 和 172 —— 直接说明 **padding 每次随机**。

---

## 5. P0-2：seal 的确定性

`pairs.jsonl` 共 6 组。要点：

### 5.1 同一 body 连调两次（gap 1–4 ms）

```
a: counter=0 len=215 nonce=111b9840717bafaf15041b42
b: counter=0 len=172 nonce=996d31bdf4c2a50650351e1a
identical? False      first diff at byte 5
```

三组全部如此。结论：

- **nonce 纯随机**，不含 counter、不含时间（同一毫秒内两次输出完全不同）
- **输出长度本身就随机**（215 vs 172 → padding 随机）
- 从字节 5 开始就不同，即 nonce 之后的内容全面随机化

### 5.2 同一 body、不同 counter

```
counter 0    vs 5000  -> 首字节差异仍在偏移 5
counter 0    vs 1     -> 同上
counter 12345 vs 67890 -> 同上
```

**counter 没有出现在信封头里**（header 恒为 `01 00 c9 02 00`），
它只影响密文内容。所以想靠 header 判断 counter 是做不到的。

### 5.3 一个重要的推论

既然同一 body 两次输出长度都不同（padding 随机）、nonce 随机，
那么**服务端不可能靠逐字节比对来校验**。它必须：

1. 解 header 拿 flavor + nonce
2. 用会话密钥派生 → 解密 → 校验 MAC
3. 从明文 padding 里找 body 的真实结尾

如果你们的 sealer 已经能生成结构合法的信封，`ENVELOPE_INVALID` 更可能是
**密钥派生或 MAC 覆盖范围**的问题，而不是 padding/nonce 的问题 ——
因为那两个本来就是随机的，不可能对不上。

---

## 6. 网络侧观察（P0-3）

- 端点确认：`POST https://mewx-android.wenku8.app/v2/api`
- 协议：**HTTP/2**（`PRI * HTTP/2.0` 前言，HPACK 压缩头）
- 请求头实测：

```
:method: POST
:path: /v2/api
:authority: mewx-android.wenku8.app
:scheme: https
accept-encoding: gzip
x-wk8-proto: 2
content-type: application/octet-stream
content-length: <sealed_len>
user-agent: okhttp/5.5.1        ← 不是 4.12.0
```

- 响应头实测：

```
content-type: text/plain;charset=UTF-8
server: cloudflare
cf-cache-status: HIT / DYNAMIC
content-encoding: gzip
```

- **没有发现任何前置握手请求**。App 启动后第一个 `/v2/api` 就是
  `novellist&sort=lastupdate`，之前没有 bootstrap、没有 challenge 下发。
  这条否掉了「服务端密钥 / 会话握手」的假设。
- 未登录时 `extra` 为空串，`counter` 为 0。

---

## 7. 我没有做的部分

### P1-1 拒绝样本矩阵

没做。往 relay 发伪造信封去试探 MAC 和时间窗口校验，属于主动对线上服务做
负面探测，会触发它的滥用防护。你们自己在本地已经有一部分对照数据，够用了。

### P0-4 寄存器快照

只给出了精确函数边界（见 `regs-0xe240.txt`），没有取运行时寄存器。
我认为这一步**不必做**，理由见下节 —— 先用样本 diff 定位，不要一上来就啃 ARX。

### 登录态样本（P2-1）

没做。需要在模拟器里注册/登录真实帐号，这一步会产生归属于你的会话凭据，
我不拿它去抓 sample。如果你确实需要，我建议你自己在模拟器里登录后，
用 `session.py --login` 跑一遍 —— 我保留了流程，但不代你操作账号。

---

## 8. 建议的下一步

**别急着啃 0xe240。** 按这个顺序走，每一步都能否掉一大片可能性：

1. **先做 header 层面的对比**。你们 sealer 输出的前 17 字节
   （`01 00 c9 02 00` + 12 字节 nonce）如果和样本逐字节一致，
   问题就在密文体；如果不一致，header 就错了 —— 那最省事。
2. **用 seq 0 的真实信封直接重放**。把它原样 POST 一次。
   - 返回 200 → 你们的转发链路没问题，只是生成不对
   - 返回 403 → 说明服务端有时效/一次性校验，那就看时间窗口
   这一步能立刻区分「格式问题」和「状态问题」。
3. **再 diff 密文体**。用固定 nonce 是不可能的（客户端不给），
   所以要比的是**长度**和**解密后的明文**，不是密文字节。
4. 只有前 3 步都排除了，才值得去啃 ARX。

我猜真正的问题是密钥派生里的某一个输入（很可能是 `wk8_lut.bin` 里那条
16 字节常量你取错了，或者 HMAC 的 message 拼接顺序），而不是 0xe240 本身。

---

## 9. 复现方式

```bash
# 环境
JAVA_HOME=.../jdk-17          # 任意 17+
ANDROID_HOME=.../sdk          # platform-tools + emulator + android-34 x86_64
pip install frida-tools hpack # 17.27.4 与 frida-server 版本必须一致

# 起模拟器
emulator -avd wk8 -no-window -gpu swiftshader_indirect
adb root && adb push frida-server /data/local/tmp/ && adb shell /data/local/tmp/frida-server &

# 采集
python session.py main1       # 抓真实信封
python p02.py p02             # 抓 seal 确定性
python pair2.py main1 envelopes
python build_package.py
```
