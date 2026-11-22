# relay-v2 密封信封：算法复原结论

> 对象：`MewX/light-novel-library_Wenku8_Android` v2.0.4.104 的 `libmewx.so`
> 方法：Unicorn 模拟真实 x86_64 原生库 + 逐步单点比对
> 工具：[`tools/mewx/oracle.py`](../tools/mewx/oracle.py)、[`tools/mewx/emu_core.py`](../tools/mewx/emu_core.py)
> 日期：2026-11-22

---

## 0. 一句话

信封算法**已完整复原**，密钥派生链每一步都逐字节验证通过。它不是"自研查表密码"——
是标准的 **SHA-256 + HMAC-SHA256 + AES-256-CTR**，外面套一层固定格式的包头。

> 之前与本仓库早期文档里的"自研 ARX 查表密码、只有 ARM64 机器码、无法移植"结论是**错的**。
> 那个结论来自只看导出符号和符号字符串的静态判断；实际执行路径里用的是标准原语。

---

## 1. 已验证的完整链路

以下每一条都在模拟器里取到中间值，并用独立实现（Python / C）复算比对，**全部逐字节相同**。

### 1.1 输入材料

| 名称 | 来源 | 值 |
| --- | --- | --- |
| `LUT` | `assets/wk8_lut.bin` | 2048 字节 |
| `seed` | Java 从 `lv1.C`/`lv1.D` 派生 | `47c3d1f8…0f23b2cd` |
| `cmdline` | `/proc/self/cmdline` | `"org.mewx.wenku8\0"` |
| `flavor` | `init()` 第 5 参数 | `2`（default）/ `1`（playstore） |
| `version` | `init()` 第 4 参数 | `104`（**不参与密钥**，只写入状态） |

### 1.2 两个常量块（`.rodata`）

```c
/* .rodata 0x2db0 */
static const uint8_t RODATA_1[32] = {
  0xc8,0xe9,0x35,0xfb,0x56,0x2f,0x68,0xc9,0xea,0x4e,0x05,0xde,0xd0,0x79,0xd1,0xec,
  0x76,0x2b,0xbd,0x1d,0x38,0xb5,0xb9,0x43,0x9d,0xcf,0x80,0xd5,0x0b,0xd2,0xe6,0x5c };

/* .rodata 0x2dd0 */
static const uint8_t RODATA_2[32] = {
  0xd4,0x80,0x76,0x91,0x64,0x06,0x7d,0x96,0xeb,0xca,0x82,0x4a,0xe1,0x2d,0xd1,0xb6,
  0xb8,0x25,0x22,0x8a,0x3f,0xdc,0xbd,0xd7,0xda,0x00,0xb0,0x19,0x84,0xcd,0x10,0x40 };
```

### 1.3 两个循环生成的块

```c
/* A —— 进入 msg 前缀 */
for (i = 0; i < 32; i++)
    A[i] = ((uint8_t)(0x5d * i) ^ (uint8_t)(0xe3 + 0x97 * i)) ^ RODATA_1[i];

/* B —— 进入密钥材料 */
for (i = 0; i < 32; i++)
    B[i] = ((uint8_t)(0x5d * i) ^ (uint8_t)(0x55 + 0x0f * i)) ^ RODATA_2[i];
```

实测：
```
A = 2bce9e441d282b4699396e417b4ee223f5ecb6e2d3529a6c2e78cbca40a59533
B = 81b9bf048177fca3ce53cb4fb48ce0f32d5ccb1ffaeddc22dfd9193c514ce125
```

### 1.4 工作密钥

```
key = SHA256( cmdline || SHA256("wk8-fallback-cert-tag") || B )
    = 0f179bb94b65f0ea3f8fba1c5e030bc0f0ff89063b6919c002d8eb7a67b121ee
```

### 1.5 会话密钥（HKDF，非迭代）

```
msg96 = A || SHA256(LUT) || seed
prk   = HMAC-SHA256(key, msg96)
      = e4fb29d1352438b8223ea82245753cf1ca1613cc5dfeb6c6c7fec9ef8809ead2

info  = "wk8-rne-epoch-\0" || { 0xC9, flavor, 0x01 }    /* 18 字节 */

working = HMAC-SHA256(prk, info)      /* 注意：不带 0x01 计数字节 */
        = 6ba3d50704d5c101ca0493f2048bdd42e9bb4d7129a1d5cfabb842b540b45019
```

`working` 落在 `.bss+0x29`，旁边 `+0x49` 存 `flavor`、`+0x4c` 存 `version`、`+0x28` 置 1（就绪标志）。

### 1.6 信封格式

```
[0]      0x01       格式版本
[1]      0x00       保留
[2]      0xC9       格式标签
[3]      flavor
[4]      0x00       保留
[5..17)  12 字节 nonce（取自 /dev/urandom 前 12 字节）
[17..]   AES-256-CTR(明文, key=f(working, nonce, counter))
```

**长度律**（精确）：
```
out_len = body_len + 83 + pad
pad     = 16 + ((k - 5*(((k*205) >> 10) & ~15)) & 0xFF)     /* k = urandom[12]，pad ∈ [16,95] */
```

**参数约束**：`body` 长度 ∈ [1, 32768]；`extra` 超过 512 字节时**静默按空处理**；
`counter` 是 int64，且与挂钟毫秒**相加**（`T_ms + counter` 构成服务端时钟）。

---

## 2. 关键踩坑记录

1. **`/proc/self/cmdline` 参与密钥**。改成别的包名，`key` 与整个信封都变。模拟器必须注入它。
2. **`ApplicationInfo.sourceDir` 会打开 APK，但文件内容不参与密钥**。
   实测：换路径字符串输出变，换文件内容/大小输出不变。
   由于真实安装路径含随机后缀（`/data/app/org.mewx.wenku8-<rand>/base.apk`），
   服务端无法校验它 —— 这也是判断"服务端不依赖本地专有状态"的依据之一。
3. **早期模拟器缺 `GetFieldID`/`CallObjectMethod` 桩**，导致 `sourceDir` 段被整体跳过。
   补桩后 `init` 仍成功，且产出的 `key` 与理论推导一致 —— 说明那段是死路径（只做打开动作）。
4. **`0x7d40` 不是"迭代扩展"**，就是一次性 HKDF：Extract = HMAC(key, msg96)，Expand = HMAC(prk, info)。
   早期判断的"154 次 HMAC"是把内部 SHA-256 的指令数误当成调用数；实际只有 1 次 HMAC 调用。

---

## 3. 目前的阻塞点（诚实记录）

**算法是对的，但服务端仍拒绝我们生成的信封**：

```
POST https://mewx-android.wenku8.app/v2/api
X-WK8-Proto: 2
Content-Type: application/octet-stream
→ 403 {"error":"ENVELOPE_INVALID"}
```

已排除的解释：

| 假设 | 排除依据 |
| --- | --- |
| 包头格式错 | 随机字节 → `400 BAD_REQUEST`；我们的信封 → `403 ENVELOPE_INVALID`，说明**框架被识别** |
| 时钟偏移 | 扫了 −3600s…+3600s 共 9 个偏移，全是 `ENVELOPE_INVALID` |
| 熵源问题 | 换成真 `os.urandom` 后信封结构不变，仍 403 |
| `flavor` 取值 | 试过 `1`(playstore) 与 `2`(default)，都 403 |
| `sourceDir` 路径 | 试过带随机后缀的真实格式路径，仍 403 |
| 密钥派生错 | 与原生库 `.bss` 状态**逐字节一致**，见第 1 节 |

**结论**：服务端侧还有客户端二进制里不存在的输入（独立密钥/时间窗口/协议协商状态）。
这已超出"照抄客户端算法"能解决的范围 —— 客户端里的每一步我们都对上了，服务端仍然不认。

---

## 4. 复现方式

```bash
cd work/tools/mewx

# 1) 跑算法自检
/Users/jht/Documents/wenku8/.tools-venv/bin/python oracle.py --selfcheck

# 2) 纯 Python 复现密钥链（不依赖模拟器）
/Users/jht/Documents/wenku8/.tools-venv/bin/python - <<'PY'
import hashlib, hmac
from oracle import java_seed
R1 = bytes.fromhex('c8e935fb562f68c9ea4e05ded079d1ec762bbd1d38b5b9439dcf80d50bd2e65c')
R2 = bytes.fromhex('d480769164067d96ebca824ae12dd1b6b825228a3fdcbdd7da00b01984cd1040')
A = bytes((((0x5d*i)&0xff) ^ ((0xe3+0x97*i)&0xff)) ^ R1[i] for i in range(32))
B = bytes((((0x5d*i)&0xff) ^ ((0x55+0x0f*i)&0xff)) ^ R2[i] for i in range(32))
key = hashlib.sha256(b'org.mewx.wenku8\0' + hashlib.sha256(b'wk8-fallback-cert-tag').digest() + B).digest()
lut = open('/tmp/and2/app-default-release-v2.0.4.104/assets/wk8_lut.bin','rb').read()
prk = hmac.new(key, A + hashlib.sha256(lut).digest() + java_seed(), hashlib.sha256).digest()
print(hmac.new(prk, b'wk8-rne-epoch-\x00' + bytes([0xC9, 2, 0x01]), hashlib.sha256).hexdigest())
# -> 6ba3d50704d5c101ca0493f2048bdd42e9bb4d7129a1d5cfabb842b540b45019
PY
```

---

## 5. 参考向量

[`tools/mewx/vectors.json`](../tools/mewx/vectors.json) —— 42 组，由模拟器产出，可 bit-for-bit 复现。
每组含 `body`/`extra`/`counter`/`sealed`/`clock_seconds`/`urandom_strategy`。

这些向量忠实反映原生库行为（已确认与 `.bss` 密钥状态一致），但**它们只证明"算得和客户端一样"，
不证明"服务端接受"** —— 后者见第 3 节。
