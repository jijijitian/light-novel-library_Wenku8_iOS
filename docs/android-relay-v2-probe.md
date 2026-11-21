# 安卓新中转（v2）实测报告

> 实测时间：2026-11-21 20:16–20:18（UTC+8）
> 对照：旧中转 `wenku8-relay.mewx.org` vs 新中转 `mewx-android.wenku8.app`
> 依据：APK `app-default-release-v2.0.4.104.apk` 拆包 + 线上黑盒探测

---

## 一、结论摘要

1. 新中转是一套**全新的、私有的传输协议**，路径为 `/v2/api`，载荷经过密封处理（APK 内标记 `SealedAttemptPayload(sealedRequest=…)`），并带有协议版本协商与强制升级头。
2. 旧中转**仍然可用**，但已明确宣布即将关闭：官方通知原文见第五节。
3. 旧中转的接入门槛是**魔改 appver**（`1.30-digital-bento-<8位hex>`），普通版本号会被拒。
4. 新中转同时承担了**分享页**（`share.wenku8.app`）与**节点优选**（`_network_cfg.wenku8.app` 的 DNS TXT）两项基础设施。
5. 对本项目最直接的影响：**中转模式依赖的旧 API 有停服风险**，需要提前准备兜底。

---

## 二、端点对照

| 项目 | 旧中转 | 新中转 |
| --- | --- | --- |
| 域名 | `wenku8-relay.mewx.org` | `mewx-android.wenku8.app` |
| API 路径 | `POST /` | `POST /v2/api` |
| 请求格式 | 表单：`request=<base64>&appver=<token>&timetoken=<ms>` | 密封载荷（APK 内为 `sealedRequest`），格式未公开 |
| 响应格式 | XML（`<result>` / `<metadata>`） | 未知（旧格式被拒） |
| 内容类型 | `text/plain;charset=UTF-8` | `application/json`（错误），成功未知 |
| 请求 UA | `okhttp/4.12.0` | `okhttp/4.12.0` |
| TLS 证书 | `CN=mewx.org`（Google Trust Services WE1） | `CN=wenku8.app`（同 CA） |
| 版本协商 | 无响应头 | `X-WK8-Proto`、`X-WK8-Min-Version`、`X-WK8-Update-Hint` |
| 辅助端点 | `/version`、`/args/notice_sc`、`/args/notice_tc` | 无（全部 302） |

---

## 三、实测矩阵

### 旧中转仍然正常

```http
POST https://wenku8-relay.mewx.org/
Content-Type: application/x-www-form-urlencoded
User-Agent: okhttp/4.12.0

request=<base64(action=novellist&sort=lastupdate&page=1&t=0)>
&appver=1.30-digital-bento-d6c6c3ae
&timetoken=1795234567890
```

```
HTTP/2 200
content-type: text/plain;charset=UTF-8

<?xml version="1.0" encoding="utf-8"?>
<result>
<page num='437'/>
<item aid='4537'><data name='Title'><![CDATA[槛神馆双极子杀人事件]]></data>…
```

### appver 是硬门槛

| appver | 结果 |
| --- | --- |
| `1.30-digital-bento-d6c6c3ae` | **200**，正常 XML |
| `1.30` | `400 Bad request.` |
| `1.00` | `400 Bad request.` |

旧中转不校验时间窗口以外的东西，但**必须有 `digital-bento` 后缀**，这与我们现有实现一致。

### 新中转拒绝一切旧格式

| 请求 | 响应 |
| --- | --- |
| `POST /v2/api` + 旧表单 | `400 {"error":"BAD_REQUEST"}` |
| `POST /v2/api` + JSON `{"request":…}` | `400 {"error":"BAD_REQUEST"}` |
| `POST /v2/api` + JSON `{"action":"novellist"}` | `400 {"error":"BAD_REQUEST"}` |
| `POST /v2/api` + `{"proto":1,"nonce":"AAAA","ciphertext":"AAAA"}` | `400 {"error":"BAD_REQUEST"}` |
| `POST /v2/api` + `X-WK8-Proto: 1` | `400 {"error":"BAD_REQUEST"}` |
| `POST /v2/api` + `X-WK8-Proto: 2` | `400 {"error":"BAD_REQUEST"}` |
| `POST /`（根路径） | `404 Not Found` |
| `POST /api`、`POST /v1/api` | `404 Not Found` |
| `GET /v2/api` | `302`（跳转） |

旧中转反向测试：`POST /v2/api`、`/api`、`/v1/api` 均返回 `500 Something went wrong....`，说明**旧服务器不认识新路径**——两套服务是分开部署的。

### 新中转的辅助端点全部 302

```
GET /version        → 302
GET /args/notice_sc → 302
GET /args/notice_tc → 302
```

对照旧中转：`GET /version` → `200`，正文是 `73`。

---

## 四、从 APK 里读出的新协议特征

新协议没有公开文档（`:api` 子模块 `MewX/wenku8-api-core` 是私有仓库），以下均为拆包得到的线索：

**传输层**

```text
https://mewx-android.wenku8.app/v2/api
SealedAttemptPayload(sealedRequest=…)
nonce / ciphertext / sealed / cipherSuite
X-WK8-Proto
X-WK8-Min-Version
X-WK8-Update-Hint
426（强制升级）/ 403（服务器校验失败）
```

**加密组件**：APK 内附带 Google Tink 的序列化器痕迹（`AesGcmProtoSerialization`、`XChaCha20Poly1305ProtoSerialization`、`XAES_256_GCM_192_BIT_NONCE`），另有原生库 `libmewx.so`（仅导出 `JNI_OnLoad`，逻辑混淆）。

**推测的握手**：客户端以 `X-WK8-Proto` 声明协议版本 → 服务端用 `X-WK8-Min-Version` 要求最低版本、`X-WK8-Update-Hint` 提示升级 → 载荷以密封 JSON 提交，含 `nonce` 与 `ciphertext`。密钥来源未在 APK 中明文出现，提交记录提到「production cert fingerprints」，推测与证书指纹绑定。

**结论**：这套协议的客户端是**为安卓应用定制的**，我们无法在不逆向的前提下复用。

---

## 五、旧 API 的关闭预告（重要）

旧中转 `https://wenku8.mewx.org/args/notice_sc` 返回的官方通知原文：

> 重要通知：小伙伴们，最近滥用API的人太多，**即将关闭旧版本的API**。如果想要app继续运行的话，我需要更完全依赖于中继服务器。目前加入了一个广告用来用来负担服务器支出。如果API继续被滥用的话，可能不得不加入一个额外的登陆服务，用来验证用户为真实用户。目前的捐助通道已经收到了1年左右的中继服务支出，当然还是欢迎大家继续赞助服务器经费~

也就是说：

- 旧 API 是**计划内**要关闭的，不是传闻；
- 后续将只保留新协议（带广告、可能带登录校验）；
- 加剧的原因是「滥用 API」，与我们这类第三方客户端的使用方式直接相关。

---

## 六、新域名附带的基础设施

### 分享页 `share.wenku8.app`

```
GET https://share.wenku8.app/book/1973
→ 200 text/html，含完整 OG 标签
```

```html
<meta property="og:type" content="book">
<meta property="og:title" content="《欢迎来到实力至上主义的教室》 - 衣笠彰梧">
<meta property="og:image" content="https://img.wenku8.com/image/1/1973/1973s.jpg">
```

页面里有指向 Play Store 与 GitHub 的下载入口，是安卓端深链（`wenku8://`）的落地页。

### 节点优选 `_network_cfg.wenku8.app`

DNS TXT 记录（经阿里 DoH 实测）：

```
v=wk8-txt-v1;rev=20261121-0429;en=1;iat=1795235346;exp=1797827346;
c=141.101.123.0/24,162.159.135.0/24,188.114.98.0/24,172.67.150.0/24,
  104.20.40.0/24,…,2606:4700:3030::/48,2606:4700:3031::/48
```

内容是 Cloudflare 的 CIDR 段列表，供客户端在 DNS 被污染时**直接用 IP 连接**。这是「纯 IP 路由」方案的配套，属于新客户端的网络优化能力。

---

## 七、对本项目的影响与建议

### 影响

| 场景 | 现状 | 风险 |
| --- | --- | --- |
| 中转模式 | 依赖旧 API + 魔改 appver | **旧 API 关闭后直接失效** |
| 混合模式 | 中转优先、网页兜底 | 中转失效时自动退化为网页模式 |
| 网页模式 | 独立可用 | 不受影响 |

好消息：我们保留的网页模式与混合模式，正好是这次变动的**天然兜底**。

### 建议

1. **短期（不做改动）**：继续使用旧中转，但把 `/version` 与 `/args/notice_sc` 纳入监控——一旦返回 426 或通知内容提到关闭，立即提示用户切换到网页模式。
2. **中期（小改动）**：在中转失败时给出更明确的引导文案，例如「中转服务可能已停止，可在设置中改用网页模式」，而不是笼统的网络错误。
3. **中期（小改动）**：借鉴分享页能力——`share.wenku8.app/book/<aid>` 的 OG 数据可以作为「分享书籍」的落地页，iOS 端做 URL Scheme 跳转即可，不需要新协议。
4. **不建议**：尝试逆向密封协议、伪造安卓证书指纹，或内置广告去换取新 API 接入——既不可靠，也正是官方公告里点名的滥用行为。
5. **可选**：在 README 或 FAQ 里说明「中转由第三方维护，可能随时变更」，降低用户对中转模式的预期。

---

## 八、附录：原始探测记录

| # | 请求 | 结果 |
| --- | --- | --- |
| 1 | `GET https://mewx-android.wenku8.app/` | 302 → `https://buymeacoffee.com/mewx` |
| 2 | `GET https://wenku8-relay.mewx.org/` | 302 → `https://wenku8.mewx.org/` |
| 3 | `POST https://mewx-android.wenku8.app/` | 404 `Not Found` |
| 4 | `POST https://mewx-android.wenku8.app/v2/api`（旧表单） | 400 `{"error":"BAD_REQUEST"}` |
| 5 | `POST https://wenku8-relay.mewx.org/`（旧表单 + 合法 appver） | 200，5214 字节 XML |
| 6 | `POST https://wenku8-relay.mewx.org/v2/api` | 500 `Something went wrong....` |
| 7 | `GET https://wenku8.mewx.org/version` | 200，正文 `73` |
| 8 | `GET https://wenku8.mewx.org/args/notice_sc` | 200，855 字节通知 |
| 9 | `GET https://mewx-android.wenku8.app/version` | 302 → buymeacoffee |
| 10 | `GET https://share.wenku8.app/book/1973` | 200，9033 字节分享页 |
| 11 | DoH `_network_cfg.wenku8.app TXT` | 429 字节节点配置 |

**未能验证的部分**：新协议的成功响应格式、密封算法细节、证书指纹绑定方式——这些都需要逆向非公开的客户端与私有 SDK，本次不涉及。
