# 请求协助：采集 Android 官方客户端的 v2 中转请求样本

> 收件方：具备 Android 调试环境（真机或模拟器 + root/hooking 能力）的 agent
> 委托方：iOS 客户端 `jijijitian/light-novel-library_Wenku8_iOS` 的维护方
> 目标：**用真实运行的官方 App 采集「明文请求 ↔ 密封信封 ↔ 服务端响应」的配对样本**

---

## 0. 为什么需要你

我们已经把 Android v2 客户端的密封算法逆向到「密钥逐字节一致」的程度：

```
会话密钥 = 6ba3d50704d5c101ca0493f2048bdd42e9bb4d7129a1d5cfabb842b540b45019
（与原生库 .bss 中的值完全一致）
```

用这个密钥生成的合法信封请求线上，服务端仍然返回：

```
POST https://mewx-android.wenku8.app/v2/api
X-WK8-Proto: 2
Content-Type: application/octet-stream
→ 403 {"error":"ENVELOPE_INVALID"}
```

客户端二进制里能对上的部分我们都对上了，服务端仍不认。这说明**还有客户端代码之外的输入**（服务端密钥、会话绑定、时间窗口、设备态之一）。

**继续静态分析无法解决。** 需要你那边跑真实客户端，采集真实样本，用「服务端接受的真实信封」反推我们缺哪一环。

---

## 1. 我们已掌握的内容（你不必重复采集）

请在动手前确认这些结论，避免做重复工作：

| 项目 | 结论 | 来源 |
| --- | --- | --- |
| 端点 | `POST https://mewx-android.wenku8.app/v2/api` | 静态确认 |
| 请求头 | `X-WK8-Proto: 2`、`Content-Type: application/octet-stream`、`Accept-Encoding: gzip`、`User-Agent: okhttp/4.12.0` | 静态确认 |
| 明文 body | 与旧 API 相同的 `action=...&...` 表单串，UTF-8，**不是 JSON** | 静态确认 |
| `extra` 参数 | 已登录时是 `PHPSESSID=<sid>`，未登录为空串 | 静态确认 |
| 信封头部 | 17 字节：`0x01 0x00 0xC9 <flavor> 0x00` + 12 字节 nonce | 模拟器确认 |
| 长度律 | `out_len = body_len + 83 + pad`，`pad ∈ [16,95]` | 模拟器确认 |
| 密钥派生 | SHA-256 + HMAC-SHA256 + 一次性 HKDF，**已逐字节复现** | 模拟器 + 独立实现 |
| 响应 | 明文 XML / 纯文本，**无解密逻辑**（原生库只注册了 `init` 和 `seal` 两个函数） | 静态确认 |
| 版本门禁 | `X-WK8-Min-Version`、`X-WK8-Update-Hint`、426 | 静态确认 |

**未知的只有一件事**：`body || padding` 之后的混合层（`0xe240` 附近约 188 条指令 + 尾部 66 字节块）的精确字节布局，以及服务端为何拒绝。

---

## 2. 我们需要你提供的内容（共 6 项）

### 优先级说明

- **P0 = 必须**，没有这些无法推进
- **P1 = 强烈建议**，能大幅缩短定位时间
- **P2 = 有则更好**

---

### P0-1 真实可用的信封样本（核心）

**要什么**：官方 App 在真机/模拟器上实际发出、且**服务端返回 200** 的请求，包含：

1. 明文 body（`action=…` 串）
2. 送入 `seal` 的 `extra` 串
3. `counter` 值（int64）
4. **密封后的完整字节**（十六进制）
5. 请求发生的**精确时间**（毫秒时间戳）
6. 服务端**原始响应**（字节 + 状态码 + 完整响应头）

**数量**：至少 **10 组**，覆盖不同 action：

```
action=novellist&sort=lastupdate&page=1&t=0
action=book&do=meta&aid=1973
action=book&do=bookinfo&aid=1973
action=chapterList&aid=1973
action=text&aid=1973&cid=182865
action=review&do=list&aid=1973&page=1
```

**特别需要**：其中至少 2 组**已登录状态**（带 `PHPSESSID`），因为登录态可能与信封绑定。

**格式**：JSON Lines，一行一组：

```json
{"seq":1,"time_ms":1795234567890,"body":"action=novellist&sort=lastupdate&page=1&t=0","extra":"","counter":0,"sealed":"0100c90200aabbccddeeff...","status":200,"resp_headers":{"content-type":"text/plain;charset=UTF-8"},"resp_body_b64":"PD94bWwg..."}
```

> `resp_body_b64` 用 base64，避免 XML 里的引号破坏 JSON。

---

### P0-2 seal 调用的完整输入输出（含失败重试）

**要什么**：同一个 body **连续调用两次**的记录。

理由：信封里含 nonce 与 counter。连续两次的差异能直接告诉我们：

- nonce 是纯随机，还是掺了 counter/时间
- 尾部 66 字节块是否依赖 nonce
- 是否存在与服务端的握手状态

```json
{"pair":"same-body-twice","a":{"counter":0,"sealed":"..."},"b":{"counter":0,"sealed":"..."},"time_gap_ms":1200}
```

**再追加**：同一 body、**不同 counter** 的两组（`counter=0` 与 `counter=5000`），用于确认 counter 如何进入信封。

---

### P0-3 抓包全文（含握手与前置请求）

**要什么**：App 启动到发出第一个 `/v2/api` 请求之间的**全部 HTTP 流量**：

1. 是否有**前置请求**？（我们的静态分析没找到 bootstrap 端点，但可能存在）
2. 是否有**服务端下发**的 nonce / session token / challenge？
3. Cookie 在这些请求之间如何变化？

**格式**：HAR 文件，或 mitmproxy 的 `.flow` / `flows` 导出，或按时间排序的 HTTP 明文日志（含 method、URL、请求头、请求体、状态码、响应头、响应体）。

> **重要**：如果发现任何我们不知道的端点（非 `/v2/api`、非 `/version`、非 `/args/notice_*`），请**单独高亮**——这可能是解开一切的关键。

---

### P0-4 seal 的完整调用栈与寄存器快照

**要什么**：在 `libmewx.so` 的 `seal` 路径上，对以下地址各取一次**输入/输出寄存器快照**：

| 地址 | 说明 | 需要什么 |
| --- | --- | --- |
| `0xfb30` | seal 入口 | 参数寄存器 |
| `0xde30` | 中间层 | 入参与出参 |
| `0xcb80` | 缓冲区组装 | 组装后的 `body‖padding` 完整字节 + 长度 |
| `0xe240` | ARX 混合（**最关键**） | 每次调用的：32 字节输入、32 字节密钥块、16 字节 state、flavor、16 字节输出 |
| `0xa050` | AES-CTR | 调用前后的缓冲区（首尾各 64 字节即可） |

**为什么关键**：`0xe240` 是唯一没复原的部分。有了它的真实输入输出对，我可以直接比对出轮常量与字节序，不必再猜。

**格式**：文本，每条：

```
addr=0xe240  call#=1  in=0011...  keyblock=aabb...  state=ccdd...  flavor=2  out=eeff...
```

**取几次**：同一信封内 `0xe240` 的**前 3 次**与**后 3 次**调用。

> 地址是 x86_64 模拟器上的偏移。如果你用 **arm64 真机**，请以 `libmewx.so` 导出符号 + 相对 `JNI_OnLoad` 的偏移重新定位；若定位困难，改用 **x86_64 模拟器**最省事（我们已有的偏移就是在 x86_64 上测的）。

---

### P1-1 服务端拒绝样本的对照

**要什么**：故意构造几种**非法**信封发给服务端，记录错误码：

| 构造 | 目的 |
| --- | --- |
| 空 body | 已知 → 400，用作对照 |
| 随机 100 字节 | 已知 → 400，用作对照 |
| 合法头 + 全零密文 | 看是否 403 还是 400 |
| 合法信封但**篡改 1 字节**密文 | 区分「格式校验」与「MAC 校验」 |
| 合法信封但**篡改 1 字节 nonce** | 同上 |
| 合法信封但 **counter 偏 1 小时** | 验证时间窗口 |

> 我们已有部分数据，但你那边**用官方客户端生成**的样本更可信（我们的 sealer 未完成）。

---

### P1-2 App 版本与服务端接受范围

**要什么**：

1. 你测试所用 APK 的 `versionCode` / `versionName` / `flavor`（`default` 还是 `playstore`）
2. 服务端响应头里的 `X-WK8-Min-Version` 当前值
3. 如果方便，用**旧版本** APK（如 v2.0.0）试一次，看是否被 426 拒绝

**理由**：版本可能参与信封（我们确认 `version` 不参与密钥，但可能进入信封头或 MAC）。

---

### P2-1 登录态差异

**要什么**：同一 action，分别取「未登录」与「已登录」两组，对比：

- `extra` 的差异（预期是 `PHPSESSID` 有无）
- 信封长度与头部差异
- 服务端响应是否不同

---

### P2-2 设备与安装信息

**要什么**：`/data/app/org.mewx.wenku8-<rand>/base.apk` 的完整真实路径。

**理由**：静态分析显示 `sourceDir` 被打开但内容不参与密钥。**如果真实路径确实影响信封**，这一条就是关键。

---

## 3. 采集方法建议

### 推荐组合：x86_64 模拟器 + Frida

```bash
# 1. 创建 x86_64 模拟器（与我们已有偏移一致）
avdmanager create avd -n wk8 -k "system-images;android-34;google_apis;x86_64"

# 2. 安装
adb install app-default-release-v2.0.4.104.apk

# 3. Frida 附加并 hook
frida -U -f org.mewx.wenku8 --no-pause -l hook.js
```

`hook.js` 骨架（可直接改）：

```javascript
Java.perform(function () {
  var B = Java.use('org.mewx.wenku8.api.internal.NativeEnvelopeBridge');
  B.b.implementation = function (body, extra, counter) {
    var out = this.b(body, extra, counter);
    console.log(JSON.stringify({
      seq: SEQ++,
      time_ms: Date.now(),
      body: bytesToString(body),
      extra: bytesToString(extra),
      counter: counter.toString(),
      sealed: bytesToHex(out)
    }));
    return out;
  };
});
```

**网络侧**：mitmproxy 需要安装系统证书（Android 7+ 需 root + Magisk 模块），或者直接在 App 里也 hook OkHttp 的 `Interceptor` 拿到明文响应。

### 如果模拟器跑不起来

真机 + Magisk + `frida-server` 也可，但注意：**arm64 偏移与我们的 x86_64 偏移不同**，需要重新用 IDA/Ghidra 定位一次。

### 不需要做的

- 不需要你逆算法（我们已做完密钥派生）
- 不需要你实现 sealer
- 不需要你压测或批量请求（**注意保持 1.2 秒以上间隔**，避免加剧服务端对第三方客户端的限制）

---

## 4. 交付方式

- 打包为单个 `.zip`，内部结构建议：

```
wk8-v2-samples/
├── README.md            ← 你的环境信息、APK 版本、采集时间
├── envelopes.jsonl      ← P0-1
├── pairs.jsonl          ← P0-2
├── traffic.har          ← P0-3
├── regs-0xe240.txt      ← P0-4
├── rejection-matrix.jsonl ← P1-1
├── version-info.json    ← P1-2
└── login-diff.jsonl     ← P2-1（可选）
```

- 或直接发给我文件路径 / Git 仓库地址。

---

## 5. 拿到样本后我们会做什么

1. 用你提供的**真实信封**与我们的 sealer 输出做逐字节 diff，定位差异起始偏移
2. 用 `0xe240` 的输入输出对，反推 ARX 混合的轮常量与字节序
3. 若发现前置握手，按你的抓包实现握手流程
4. 全部对齐后，在 iOS 端实现并**用你的样本做回归测试**（逐字节一致才算通过）
5. 把结论回写到 `docs/relay-v2-envelope-findings.md`

---

## 6. 风险提示（请务必阅读）

1. **运营者明确不欢迎第三方客户端。** 官方公告：旧 API「即将关闭」，原因写明是「滥用 API 的人太多」，并已加入广告、（可能）登录校验。采集时请保持克制的请求频率。
2. **不要**：伪造证书指纹、绕过广告、批量压测、把新协议用于公开分发。
3. 本次采集的**唯一目的**是让 iOS 客户端的**中转模式**在旧 API 关闭后仍可用作可选项；**网页模式始终可用**，所以即使这条路走不通，产品也不会失效。
4. 如果你判断风险过高或技术上不可行，请**直接说明**，不要勉强——我们会关闭这个话题，把资源转回网页/混合模式的健壮性。

---

## 7. 最小可交付集（如果时间有限）

如果只能做一件事，**请做 P0-1 的前 3 组**（含 1 组登录态）。

只要给我「明文 → 密封字节 → 服务端 200 响应」的配对，我就能：

- 确认我们的信封在哪一步开始偏离
- 判断服务端是否真的在意我们缺失的环节

---

## 附录：我们仓库里的相关文档

| 文档 | 内容 |
| --- | --- |
| [`docs/relay-v2-protocol-contract.md`](relay-v2-protocol-contract.md) | 外层协议全貌（640 行，含逐条证据） |
| [`docs/relay-v2-envelope-findings.md`](relay-v2-envelope-findings.md) | 密钥派生复原过程与阻塞点 |
| [`docs/relay-v2-cipher-notes.md`](relay-v2-cipher-notes.md) | 密码学层面的分析（含 `0xe240` 未复原说明） |
| [`docs/relay-v2-handoff.md`](relay-v2-handoff.md) | 早期交接文档（部分结论已被修正） |
| `tools/mewx/` | Unicorn 模拟器、42 组参考向量、C 实现 |

官方 APK 可从 `MewX/light-novel-library_Wenku8_Android` 的 `v2.0.4` pre-release 获取。
