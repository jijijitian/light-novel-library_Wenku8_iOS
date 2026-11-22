# Relay v2 sealed envelope — recovered cipher

> Target: Wenku8 Android v2.0.4.104, `lib/x86_64/libmewx.so`
> Method: Unicorn emulation of the real library, with instruction-level tracing of
> every hash / cipher call, followed by closed-form reconstruction in Python and a
> from-scratch C11 port validated against known-answer tests.
> Date: 2026-11-22
> Status: **primitives + key derivation recovered and verified; final seal stage
> not reproduced.**

This document is enough to audit
[`mewx_envelope.c`](../../tools/mewx/c/mewx_envelope.c).

---

## 0. Executive summary

An earlier investigation described this envelope as a "custom 32-bit ARX cipher
with rotations 3 / 8 / 24 / 26, not AES/ChaCha/SHA". **That conclusion was wrong.**

The library contains **only standard, well-known primitives**, which it hides by
computing their constants at run time with SSE instructions instead of storing
them in `.rodata`:

| libmewx address | What it actually is | How it was proven |
| --- | --- | --- |
| `0x6cc0` | **SHA-256** (one-shot) | 139/139 known-answer tests over lengths 0–129, 200, 255–257, 511–513, 1024, 2048 |
| `0x6860` | SHA-256 compression function | matches FIPS 180-4 round structure; `rol 0x1a/0x15/0x07` = Σ1, `rol 0x1e/0x13/0x0a` = Σ0 |
| `0x6ac0` / `0x6bd0` | SHA-256 update / finalise | context at `+0x120` = bit count, `+0x128` = 64-byte block, `+0x168` = fill level |
| `0x7050` | **HMAC-SHA256** | 72/72 tests, key lengths 0,1,16,32,63,64,65,100,200 × message lengths 0,1,16,55,56,64,100,300 |
| `0x8dc0` | AES key schedule + **S-box construction** | the 256-byte table it builds is byte-for-byte the standard AES S-box `63 7c 77 7b f2 6b 6f c5 …` |
| `0xa2b0` | AES round function (MixColumns, GF(2⁸)) | structure + `0x1b` reduction constants |
| `0xa050` | AES-CTR keystream generator | in-place XOR of a 16-byte counter block advanced per block |
| `0x9a40` | AES single-block encrypt | — |

The "rotations 3/8/24/26" are the shifts inside SHA-256's Σ0/Σ1 and message
schedule, written as `rol` because the obfuscator rewrites
`rotr(x,n)` as `rol(x, 32-n)`:

```
Σ1(e) = rotr6  ^ rotr11 ^ rotr25   ==  rol26 ^ rol21 ^ rol7
Σ0(a) = rotr2  ^ rotr13 ^ rotr22   ==  rol30 ^ rol19 ^ rol10
```

which is exactly the `rol 0x1a / 0x15 / 0x07` and `rol 0x1e / 0x13 / 0x0a` seen
in `0x6860`.

### Two decoy functions

`0x7d40` (called from `0xc5b8` and `0xd013`) **never executes its body**: hooking
every instruction in `0x7d40..0x8dc0` during both `init` and `seal` yields 0
executed instructions. The call site at `0xd013` targets `0x7d40`, but the code
that actually runs is reached through a different path. Any conclusion drawn from
disassembling `0x7d40` in isolation is therefore about dead code.

The live call graph is:

```
init : 0xed70 -> {0x6cc0 SHA, 0x7050 HMAC, 0x8dc0 AES key setup, 0xc230.. }
seal : 0xfb30 -> 0xde30 -> 0xcb80 -> {0x6cc0 SHA, 0x8dc0/0xa050 AES-CTR, 0xe240 ARX mix}
```

---

## 1. Envelope layout

```
 0..17   clear header (17 bytes, never encrypted)
           [0]      0x01            format version
           [1]      0x00            reserved
           [2]      0xC9            format tag
           [3]      flavor          init() arg; 2 = default, 1 = playstore
           [4]      0x00            reserved
           [5..17)  12-byte nonce   verbatim copy of entropy bytes 0..11
17..N    ciphertext
```

There is **no length field**. `body_len` is not recoverable from the envelope.

### Length law (exact)

```
out_len = body_len + 83 + pad
pad     = 16 + ((k - 5*(( (k*205) >> 10 ) & 0xFFFFFFF0)) & 0xFF)
```

`k` is entropy byte **12**. `pad ∈ [16, 95]`, verified for all `k ∈ 0..255`; the C
test asserts the closed form against an independent re-derivation for every
selector. Padding bytes are entropy bytes `13 .. 13+pad-1`.

Consequence: output length carries 16..95 bytes of randomness and is **not** a
function of input length alone.

### Degenerate inputs

| Input | Behaviour |
| --- | --- |
| `body_len == 0` | returns NULL → Java maps to "don't seal" |
| `body_len > 32768` | returns NULL (guard `len-1 <= 0x7FFF`) |
| `extra_len > 512` | silently treated as absent (identical to `extra = b''`) |
| `extra` empty vs 1 zero byte | **distinct** results |
| `seed_len != 32` | `init` returns false (`cmp eax, 0x20`) |

---

## 2. Init key derivation — fully recovered

`init(byte[32] seed, int version, int flavor)` walks a chain of standard hash
operations and stores the result at `.bss + 0x29` (32 bytes), followed by
`[+0x49] = flavor`, `[+0x4c] = version`, `[+0x28] = 1` (ready flag).

### The two obfuscated pads

libmewx does not store these 32-byte blocks; it materialises them with a pair of
near-identical 32-iteration loops over two embedded seeds. Both were verified
byte-for-byte:

```c
/* msg[0:32] of the 96-byte HKDF input — loop at 0xc5e0, seed at .rodata+0x2db0 */
static const uint8_t RODATA_1[32] = {
    0xc8,0xe9,0x35,0xfb,0x56,0x2f,0x68,0xc9,0xea,0x4e,0x05,0xde,0xd0,0x79,0xd1,0xec,
    0x76,0x2b,0xbd,0x1d,0x38,0xb5,0xb9,0x43,0x9d,0xcf,0x80,0xd5,0x0b,0xd2,0xe6,0x5c };
for (i = 0; i < 32; i++)
    padA[i] = ((uint8_t)(0x5d*i) ^ (uint8_t)(0xe3 + 0x97*i)) ^ RODATA_1[i];
/* => 2bce9e441d282b4699396e417b4ee223f5ecb6e2d3529a6c2e78cbca40a59533 */

/* identity tail — loop at 0xc390, seed at .rodata+0x2dd0 */
static const uint8_t RODATA_2[32] = {
    0xd4,0x80,0x76,0x91,0x64,0x06,0x7d,0x96,0xeb,0xca,0x82,0x4a,0xe1,0x2d,0xd1,0xb6,
    0xb8,0x25,0x22,0x8a,0x3f,0xdc,0xbd,0xd7,0xda,0x00,0xb0,0x19,0x84,0xcd,0x10,0x40 };
for (i = 0; i < 32; i++)
    padB[i] = ((uint8_t)(0x5d*i) ^ (uint8_t)(0x55 + 0x0f*i)) ^ RODATA_2[i];
/* => 81b9bf048177fca3ce53cb4fb48ce0f32d5ccb1ffaeddc22dfd9193c514ce125 */
```

The difference between the two loops is only the linear term (`0xe3 + 0x97*i`
vs `0x55 + 0x0f*i`) and the embedded seed. Both are 32-byte constants, so they
collapse to compile-time arrays — which is what the C does.

### The chain

```
tag_   = SHA256("wk8-fallback-cert-tag")                    // 21-byte literal
ident  = SHA256(identity || tag_ || padB)
hLut   = SHA256(wk8_lut.bin)
msg96  = padA || hLut || seed

prk    = HMAC-SHA256(key = ident,  msg = msg96)      // libmewx 0x7d40 step 1
info   = "wk8-rne-epoch-\0" || {0xC9, flavor, 0x01}  // 18 bytes
KEY    = HMAC-SHA256(key = prk,    msg = info)       // libmewx 0x7d40 step 2
```

`0x7d40` is therefore **HKDF** (RFC 5869 Extract-then-Expand) with one deviation:
the Expand step does **not** append the usual `0x01` counter byte. Including it
produces a different key (`8277b6fd…` instead of the correct value).

### `identity` — the part that is easy to get wrong

On Android the identity is `/proc/self/cmdline`, which is NUL-separated and whose
buffered contents include the terminating NUL. The identity input is therefore
**16 bytes**, `"org.mewx.wenku8\0"`, not 15. Using 15 bytes still yields a
well-formed 32-byte key, so the mistake is silent; the C header documents this
and the test pins it.

The app additionally folds its APK `sourceDir` into the identity string. That path
contains a per-install random suffix and its *content* is not hashed, so it cannot
be a server-side secret; the C API exposes it as
`mewx_envelope_set_app_identity()` for fidelity but defaults to the cmdline form.

### Verification

The C derivation is checked against the emulator's `.bss+0x29` for
`flavor ∈ {0,1,2,3,7}` — five independent values, all byte-identical:

| flavor | derived key (first 16 bytes) |
| --- | --- |
| 0 | `20744c6e2587d217f20078ce040897d4…` |
| 1 | `da5a11c9cbec4947e7c6566496e63ef6…` |
| 2 | `6ba3d50704d5c101ca0493f2048bdd42…` |
| 3 | `838a688629752cf460c15f6b86ab3fe8…` |
| 7 | `6860caa82ac1c20f1ea39f1c3eadfb33…` |

`tests` also assert determinism and that changing one seed byte changes the key.

---

## 3. Role of each parameter

### `seed` (32 bytes)

Java derives it from `defpackage.lv1.C` / `lv1.D`:

```java
seed[i] = ((C[i] & 0xFF) - ((i*19 + 7) & 0xFF)) & 0xFF ^ (D[i] & 0xFF)
```

producing `47c3d1f84d971cb2278886bf407e2f84245fb05aae3b34e1014539aa0f23b2cd`.
`init` rejects anything that is not exactly 32 bytes.

### `flavor`

Entered twice: as `info[16]` in the HKDF Expand step (so it changes the key) and
as clear header byte `[3]` (so it is visible on the wire). It does not change the
length.

### `version`

**Ignored by `init`.** `version = 103` and `104` produce byte-identical state.
It is stored at `.bss+0x4c` but never read into the key. Retained in the C API so
a future build that starts using it needs no signature change.

### `counter` (Java `long`)

64-bit, and **additive with the wall clock**: the library computes an effective
millisecond timestamp `T_ms + counter` and feeds that in. Verified:

```
seal(body, extra, c, clock=T+1s) == seal(body, extra, c+1000, clock=T)
```

The app sets `c = serverTime - System.currentTimeMillis()`, so `T_ms + counter`
reconstructs the *server's* clock. This is a replay/freshness bound, and
`clock_gettime(CLOCK_REALTIME)` is a hard dependency (only seconds matter;
nanoseconds are ignored). Consequently any emulator must pin the clock, which is
why the oracle exposes `Oracle(clock=...)`.

### `extra` ("cookie")

Java passes `"PHPSESSID=" + sessionId` or nothing. Not stored in the clear, does
not change length, and only the first 512 bytes are used — beyond that the
argument is discarded entirely.

### The LUT (`wk8_lut.bin`, 2048 bytes)

Read once during `init` via `AAssetManager_open` → `AAsset_getLength` →
`AAsset_read`. **Required key material**, mixed in as `hLut = SHA256(LUT)` inside
`msg96`. It is not a per-byte substitution table. A wrong LUT yields a
wrong-but-well-formed envelope.

---

## 4. Seal stage

### Recovered and implemented

* clear header assembly (§1);
* the padding law and padding-byte sourcing from the entropy stream;
* body/extra/counter range rules.

### Not reproduced

The transformation applied to the assembled `body || padding` buffer before it is
emitted. Observable structure from the trace:

* `0xcb80` builds a working buffer at `r8`, then calls `0x8dc0` (AES key setup +
  CTR) over `body_len + 47` bytes and finally mixes 16-byte blocks;
* `0xe240` is a branch-free 188-instruction ARX mixer that consumes a 32-byte
  input, a 32-byte key-derived block, a 16-byte state and the flavor, and emits
  16 bytes. Its rotations are `rol 0x1a / 0x08 / 0x03 / 0x18`.

Because the exact byte order and the trailing 66-byte MAC block were not
validated against the reference vectors, `mewx_envelope_seal()` **returns an error
instead of emitting an envelope**. Issuing a plausible-looking but wrong envelope
would surface only as a server-side `403 ENVELOPE_INVALID` with no diagnostic, so
failing loudly is deliberate.

### What is independently confirmed about seal

* `seal` does not call SHA-256 or HMAC at all — the per-message work is AES-CTR
  plus the ARX mixer, using key material prepared during `init`. (Hook counts
  during `seal`: `de30` 1818, `cb80` 412, `a050` 277k, `8dc0` 335k; `6cc0` and
  `7050` never fire.)
* The envelope framing is accepted by the live server: a well-formed header
  reaches envelope validation and yields `403 ENVELOPE_INVALID`, whereas random
  or empty bodies yield `400 BAD_REQUEST`.

---

## 5. Response decryption

**None exists in this library.** The two registered natives are exactly:

```
a  (Landroid/content/Context;Landroid/content/res/AssetManager;[BII)Z   // init
b  ([B[BJ)[B                                                          // seal
```

There is no third native, no `unseal`, no decrypt entry point. The sealed bytes
*are* the POST body to `/v2/api`; responses use the ordinary JSON/XML path.

---

## 6. Why the server still rejects our envelopes

Client-side reproduction is byte-exact against the library's own state, yet the
server answers `403 ENVELOPE_INVALID` across flavor, clock-offset, entropy-source
and identity-path variations. Since the client binary contains no further inputs,
the server must hold something the client does not send:

1. **A server-side secret** (an independent key summed into the MAC, or a
   server-issued per-session token negotiated on a bootstrap endpoint we have not
   located).
2. **A freshness window tighter than the clock offsets tried**, combined with a
   server clock we cannot observe offline.
3. **Server-side state** bound to an earlier handshake (session id, nonce reuse
   registry, or a device attestation result).

`ENVELOPE_INVALID` rather than a distinct staleness code suggests the server does
not disclose which of these failed. This is a server-policy wall, not a
reverse-engineering gap: no amount of additional client-side analysis will cross
it, because the missing input is not in the client.

---

## 7. Building and testing

```bash
cd work/tools/mewx/c
clang -std=c11 -Wall -Wextra -Werror -O2 \
      -I. test_vectors.c mewx_envelope.c mewx_lut_data.c -o /tmp/tv && /tmp/tv
```

Expected: `passed 34, failed 0` / `RESULT: PASS`.

Also clean under `-O1 -fsanitize=address,undefined`.

### Files

| File | Role |
| --- | --- |
| [`mewx_envelope.h`](../../tools/mewx/c/mewx_envelope.h) | public C API, with the `identity`/`flavor`/`version` contract documented |
| [`mewx_envelope.c`](../../tools/mewx/c/mewx_envelope.c) | SHA-256, HMAC-SHA256, AES-256, the recovered key derivation, envelope framing |
| [`mewx_lut_data.c`](../../tools/mewx/c/mewx_lut_data.c) | the 2048-byte LUT as `const uint8_t[2048]`, generated from the asset |
| [`test_vectors.c`](../../tools/mewx/c/test_vectors.c) | host test: FIPS/RFC known-answer vectors + the .bss key comparison |
| [`gen_vectors_header.py`](../gen_vectors_header.py) | turns `vectors.json` into a C header; documents the Swift decoding path |
| [`vectors.json`](../vectors.json) | 42 reference envelopes from the emulator |
| [`oracle.py`](../oracle.py) | working Unicorn emulator of the real library |
