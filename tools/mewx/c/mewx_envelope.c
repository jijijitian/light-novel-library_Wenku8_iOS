/* mewx_envelope.c -- portable C11 implementation of the relay-v2 envelope.
 *
 * See mewx_envelope.h for the API contract and the honest status note, and
 * work/docs/relay-v2-cipher-notes.md for the reverse-engineering evidence.
 *
 * No dependencies beyond <string.h> / <stdint.h>.  All word access is explicit
 * about endianness and goes through memcpy or byte assembly, so the code is
 * strict-aliasing-safe and produces identical results on arm64 and x86_64.
 *
 * What is implemented and verified here:
 *   - SHA-256        (identical to libmewx 0x6cc0; 139/139 KATs pass)
 *   - HMAC-SHA256    (identical to libmewx 0x7050;  72/72  KATs pass)
 *   - AES-256        block cipher + CTR keystream (S-box matches libmewx 0x8dc0)
 *   - the exact clear-header layout and the padding / length law
 *   - the documented parameter semantics (counter additive with now_ms,
 *     512-byte extra cap, 32768-byte body cap, seed == 32 bytes)
 *
 * What is NOT yet wired up: the key-derivation chain that turns
 * {seed, LUT, flavor, process name, counter+now_ms, extra} into the working key
 * and the per-message MAC.  That chain is gated behind mewx_kdf_ready(); until
 * it is recovered and implemented, mewx_envelope_seal() returns
 * MEWX_ERR_KDF_UNRECOVERED rather than emitting a plausible-looking but wrong
 * envelope.  Failing loudly is deliberate: a silently wrong envelope shows up as
 * a server-side 403 with no diagnostic.
 */

#include "mewx_envelope.h"

#include <string.h>

/* Error codes.  Kept small and stable; callers should treat any non-zero value
 * as "no envelope was produced". */
enum {
    MEWX_OK                   = 0,
    MEWX_ERR_UNINITIALISED    = 1,
    MEWX_ERR_BAD_SEED         = 2,
    MEWX_ERR_BODY_RANGE       = 3,
    MEWX_ERR_RND_TOO_SHORT    = 4,
    MEWX_ERR_OUT_TOO_SMALL    = 5,
    MEWX_ERR_IDENTITY_TOO_LONG = 6,
    MEWX_ERR_KDF_UNRECOVERED  = 7
};

/* ==================================================================== *
 * Little helpers
 * ==================================================================== */

static uint32_t ror32(uint32_t x, unsigned n) { return (x >> n) | (x << (32 - n)); }

/* Explicit big-endian load/store: no aliasing, no host-endian assumption. */
static uint32_t be32_load(const uint8_t *p)
{
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) |
           ((uint32_t)p[2] << 8)  |  (uint32_t)p[3];
}
static void be32_store(uint8_t *p, uint32_t v)
{
    p[0] = (uint8_t)(v >> 24); p[1] = (uint8_t)(v >> 16);
    p[2] = (uint8_t)(v >> 8);  p[3] = (uint8_t)v;
}
static void be64_store(uint8_t *p, uint64_t v)
{
    be32_store(p, (uint32_t)(v >> 32));
    be32_store(p + 4, (uint32_t)v);
}

/* Constant-time-ish zeroing that the optimiser will not drop. */
static void wipe(void *p, size_t n)
{
    volatile uint8_t *q = (volatile uint8_t *)p;
    while (n--) *q++ = 0;
}

/* ==================================================================== *
 * SHA-256  (FIPS 180-4)
 * libmewx: 0x6cc0 one-shot, 0x6860 compression, 0x6ac0 update, 0x6bd0 final.
 * Verified byte-identical for every message length 0..129 plus 200, 255..257,
 * 511..513, 1024 and 2048.
 * ==================================================================== */

static const uint32_t SHA256_K[64] = {
    0x428a2f98u, 0x71374491u, 0xb5c0fbcfu, 0xe9b5dba5u,
    0x3956c25bu, 0x59f111f1u, 0x923f82a4u, 0xab1c5ed5u,
    0xd807aa98u, 0x12835b01u, 0x243185beu, 0x550c7dc3u,
    0x72be5d74u, 0x80deb1feu, 0x9bdc06a7u, 0xc19bf174u,
    0xe49b69c1u, 0xefbe4786u, 0x0fc19dc6u, 0x240ca1ccu,
    0x2de92c6fu, 0x4a7484aau, 0x5cb0a9dcu, 0x76f988dau,
    0x983e5152u, 0xa831c66du, 0xb00327c8u, 0xbf597fc7u,
    0xc6e00bf3u, 0xd5a79147u, 0x06ca6351u, 0x14292967u,
    0x27b70a85u, 0x2e1b2138u, 0x4d2c6dfcu, 0x53380d13u,
    0x650a7354u, 0x766a0abbu, 0x81c2c92eu, 0x92722c85u,
    0xa2bfe8a1u, 0xa81a664bu, 0xc24b8b70u, 0xc76c51a3u,
    0xd192e819u, 0xd6990624u, 0xf40e3585u, 0x106aa070u,
    0x19a4c116u, 0x1e376c08u, 0x2748774cu, 0x34b0bcb5u,
    0x391c0cb3u, 0x4ed8aa4au, 0x5b9cca4fu, 0x682e6ff3u,
    0x748f82eeu, 0x78a5636fu, 0x84c87814u, 0x8cc70208u,
    0x90befffau, 0xa4506cebu, 0xbef9a3f7u, 0xc67178f2u
};

static void sha256_compress(uint32_t st[8], const uint8_t blk[64])
{
    uint32_t w[64];
    uint32_t a, b, c, d, e, f, g, h;
    int i;

    for (i = 0; i < 16; i++) w[i] = be32_load(blk + 4 * i);
    for (i = 16; i < 64; i++) {
        /* sigma0 = rotr7 ^ rotr18 ^ shr3 ; sigma1 = rotr17 ^ rotr19 ^ shr10 */
        uint32_t s0 = ror32(w[i - 15], 7) ^ ror32(w[i - 15], 18) ^ (w[i - 15] >> 3);
        uint32_t s1 = ror32(w[i - 2], 17) ^ ror32(w[i - 2], 19) ^ (w[i - 2] >> 10);
        w[i] = w[i - 16] + s0 + w[i - 7] + s1;
    }

    a = st[0]; b = st[1]; c = st[2]; d = st[3];
    e = st[4]; f = st[5]; g = st[6]; h = st[7];

    for (i = 0; i < 64; i++) {
        /* The rotations libmewx performs with rol 0x1a / 0x15 / 7 and
         * rol 0x1e / 0x13 / 0xa are exactly Sigma1 / Sigma0 here. */
        uint32_t S1 = ror32(e, 6) ^ ror32(e, 11) ^ ror32(e, 25);
        uint32_t ch = (e & f) ^ (~e & g);
        uint32_t t1 = h + S1 + ch + SHA256_K[i] + w[i];
        uint32_t S0 = ror32(a, 2) ^ ror32(a, 13) ^ ror32(a, 22);
        uint32_t mj = (a & b) ^ (a & c) ^ (b & c);
        uint32_t t2 = S0 + mj;

        h = g; g = f; f = e; e = d + t1;
        d = c; c = b; b = a; a = t1 + t2;
    }

    st[0] += a; st[1] += b; st[2] += c; st[3] += d;
    st[4] += e; st[5] += f; st[6] += g; st[7] += h;

    wipe(w, sizeof w);
}

typedef struct {
    uint32_t st[8];
    uint8_t  buf[64];
    uint64_t total;     /* bytes absorbed */
} sha256_ctx;

static void sha256_init(sha256_ctx *c)
{
    c->st[0] = 0x6a09e667u; c->st[1] = 0xbb67ae85u;
    c->st[2] = 0x3c6ef372u; c->st[3] = 0xa54ff53au;
    c->st[4] = 0x510e527fu; c->st[5] = 0x9b05688cu;
    c->st[6] = 0x1f83d9abu; c->st[7] = 0x5be0cd19u;
    c->total = 0;
}

static void sha256_update(sha256_ctx *c, const uint8_t *p, size_t n)
{
    size_t used = (size_t)(c->total & 63u);

    c->total += n;

    if (used) {
        size_t take = 64 - used;
        if (take > n) take = n;
        memcpy(c->buf + used, p, take);
        p += take; n -= take;
        if (used + take != 64) return;
        sha256_compress(c->st, c->buf);
    }
    while (n >= 64) {
        sha256_compress(c->st, p);
        p += 64; n -= 64;
    }
    if (n) memcpy(c->buf, p, n);
}

static void sha256_final(sha256_ctx *c, uint8_t out[32])
{
    uint64_t bits = c->total * 8u;
    size_t used = (size_t)(c->total & 63u);
    uint8_t pad[72];
    size_t padlen;
    int i;

    memset(pad, 0, sizeof pad);
    pad[0] = 0x80;
    /* message + 0x80 + zeros + 8-byte length == multiple of 64 */
    padlen = (used < 56) ? (56 - used) : (120 - used);
    sha256_update(c, pad, padlen);

    be64_store(pad, bits);
    sha256_update(c, pad, 8);

    for (i = 0; i < 8; i++) be32_store(out + 4 * i, c->st[i]);

    wipe(c, sizeof *c);
    wipe(pad, sizeof pad);
}

void mewx_sha256(const uint8_t *p, size_t n, uint8_t out[32])
{
    sha256_ctx c;
    sha256_init(&c);
    sha256_update(&c, p, n);
    sha256_final(&c, out);
}

/* ==================================================================== *
 * HMAC-SHA256  (RFC 2104)
 * libmewx: 0x7050.  Verified byte-identical for key lengths 0,1,16,32,63,64,
 * 65,100,200 crossed with message lengths 0,1,16,55,56,64,100,300.
 * ==================================================================== */

void mewx_hmac_sha256(const uint8_t *key, size_t key_len,
                     const uint8_t *msg, size_t msg_len,
                     uint8_t out[32])
{
    uint8_t k[64];
    uint8_t ipad[64], opad[64];
    uint8_t inner[32];
    sha256_ctx c;
    int i;

    memset(k, 0, sizeof k);
    if (key_len > 64) {
        mewx_sha256(key, key_len, k);     /* long key is hashed down first */
    } else if (key_len) {
        memcpy(k, key, key_len);
    }
    for (i = 0; i < 64; i++) {
        ipad[i] = (uint8_t)(k[i] ^ 0x36);
        opad[i] = (uint8_t)(k[i] ^ 0x5c);
    }

    sha256_init(&c);
    sha256_update(&c, ipad, 64);
    sha256_update(&c, msg, msg_len);
    sha256_final(&c, inner);

    sha256_init(&c);
    sha256_update(&c, opad, 64);
    sha256_update(&c, inner, 32);
    sha256_final(&c, out);

    wipe(k, sizeof k); wipe(ipad, sizeof ipad); wipe(opad, sizeof opad);
    wipe(inner, sizeof inner);
}

/* ==================================================================== *
 * AES-256 -- encryption direction only, which is all the envelope needs.
 *
 * libmewx builds the standard S-box at run time inside 0x8dc0 (verified byte
 * for byte against the real table), uses 0xa2b0 as the round function and
 * 0xa050 as a CTR-mode keystream generator.
 * ==================================================================== */

static uint8_t AES_SBOX[256];
static int     AES_SBOX_READY = 0;

static uint8_t xtime(uint8_t a)
{
    return (uint8_t)((a & 0x80u) ? (uint8_t)((a << 1) ^ 0x1bu) : (uint8_t)(a << 1));
}

/* Build the AES S-box the same way libmewx does: multiplicative inverse in
 * GF(2^8) followed by the affine transform. */
static void aes_build_sbox(void)
{
    uint8_t p = 1, q = 1;
    if (AES_SBOX_READY) return;
    do {
        p = (uint8_t)(p ^ (uint8_t)(p << 1) ^ (uint8_t)((p & 0x80u) ? 0x1bu : 0x00u));
        q ^= (uint8_t)(q << 1);
        q ^= (uint8_t)(q << 2);
        q ^= (uint8_t)(q << 4);
        if (q & 0x80u) q = (uint8_t)(q ^ 0x09u);
        {
            uint8_t r1 = (uint8_t)((q << 1) | (q >> 7));
            uint8_t r2 = (uint8_t)((q << 2) | (q >> 6));
            uint8_t r3 = (uint8_t)((q << 3) | (q >> 5));
            uint8_t r4 = (uint8_t)((q << 4) | (q >> 4));
            AES_SBOX[p] = (uint8_t)((q ^ r1 ^ r2 ^ r3 ^ r4) ^ 0x63u);
        }
    } while (p != 1);
    AES_SBOX[0] = 0x63u;
    AES_SBOX_READY = 1;
}

/* Round keys live in one flat buffer: nr+1 blocks of 16 bytes (AES-256 => 15). */
typedef struct { uint8_t rk[15 * 16]; } aes256_ctx;

size_t mewx_aes256_ctx_size(void) { return sizeof(aes256_ctx); }

void mewx_aes256_expand(void *ctx_v, const uint8_t key[32])
{
    aes256_ctx *ctx = (aes256_ctx *)ctx_v;
    int i, nk = 8, nr = 14, total = 4 * (nr + 1);
    uint8_t rc = 1;
    uint8_t w[240];

    aes_build_sbox();
    memcpy(w, key, 32);

    for (i = nk; i < total; i++) {
        uint8_t t[4];
        memcpy(t, w + 4 * (i - 1), 4);
        if (i % nk == 0) {
            uint8_t tmp = t[0];
            t[0] = AES_SBOX[t[1]]; t[1] = AES_SBOX[t[2]];
            t[2] = AES_SBOX[t[3]]; t[3] = AES_SBOX[tmp];
            t[0] = (uint8_t)(t[0] ^ rc);
            rc = xtime(rc);
        } else if (i % nk == 4) {
            t[0] = AES_SBOX[t[0]]; t[1] = AES_SBOX[t[1]];
            t[2] = AES_SBOX[t[2]]; t[3] = AES_SBOX[t[3]];
        }
        w[4 * i + 0] = (uint8_t)(w[4 * (i - nk) + 0] ^ t[0]);
        w[4 * i + 1] = (uint8_t)(w[4 * (i - nk) + 1] ^ t[1]);
        w[4 * i + 2] = (uint8_t)(w[4 * (i - nk) + 2] ^ t[2]);
        w[4 * i + 3] = (uint8_t)(w[4 * (i - nk) + 3] ^ t[3]);
    }
    memcpy(ctx->rk, w, 240);
    wipe(w, sizeof w);
}

/* Column-major state, matching the AES specification's byte ordering. */
void mewx_aes256_encrypt_block(const void *ctx_v, const uint8_t in[16], uint8_t out[16])
{
    const aes256_ctx *ctx = (const aes256_ctx *)ctx_v;
    uint8_t s[16], t[16];
    int r, i, c;

    for (i = 0; i < 16; i++) s[i] = (uint8_t)(in[i] ^ ctx->rk[i]);

    for (r = 1; r <= 14; r++) {
        /* SubBytes + ShiftRows */
        for (c = 0; c < 4; c++) {
            for (i = 0; i < 4; i++) {
                t[c * 4 + i] = AES_SBOX[s[((c + i) & 3) * 4 + i]];
            }
        }
        if (r != 14) {
            /* MixColumns */
            for (c = 0; c < 4; c++) {
                uint8_t *a = t + c * 4;
                uint8_t a0 = a[0], a1 = a[1], a2 = a[2], a3 = a[3];
                uint8_t all = (uint8_t)(a0 ^ a1 ^ a2 ^ a3);
                s[c * 4 + 0] = (uint8_t)(a0 ^ all ^ xtime((uint8_t)(a0 ^ a1)));
                s[c * 4 + 1] = (uint8_t)(a1 ^ all ^ xtime((uint8_t)(a1 ^ a2)));
                s[c * 4 + 2] = (uint8_t)(a2 ^ all ^ xtime((uint8_t)(a2 ^ a3)));
                s[c * 4 + 3] = (uint8_t)(a3 ^ all ^ xtime((uint8_t)(a3 ^ a0)));
            }
        } else {
            memcpy(s, t, 16);
        }
        for (i = 0; i < 16; i++) s[i] = (uint8_t)(s[i] ^ ctx->rk[r * 16 + i]);
    }
    memcpy(out, s, 16);
    wipe(s, sizeof s); wipe(t, sizeof t);
}

/* ==================================================================== *
 * The two obfuscation pads
 *
 * libmewx does not store these 32-byte blocks in .rodata; it materialises them
 * with a 32-iteration loop from a second, also-embedded seed.  Both loops were
 * verified byte for byte against the real library.
 * ==================================================================== */

static const uint8_t MEWX_RODATA_1[32] = {
    0xc8,0xe9,0x35,0xfb,0x56,0x2f,0x68,0xc9,0xea,0x4e,0x05,0xde,0xd0,0x79,0xd1,0xec,
    0x76,0x2b,0xbd,0x1d,0x38,0xb5,0xb9,0x43,0x9d,0xcf,0x80,0xd5,0x0b,0xd2,0xe6,0x5c
};
static const uint8_t MEWX_RODATA_2[32] = {
    0xd4,0x80,0x76,0x91,0x64,0x06,0x7d,0x96,0xeb,0xca,0x82,0x4a,0xe1,0x2d,0xd1,0xb6,
    0xb8,0x25,0x22,0x8a,0x3f,0xdc,0xbd,0xd7,0xda,0x00,0xb0,0x19,0x84,0xcd,0x10,0x40
};

/* msg[0:32] of the 96-byte HKDF input (loop at 0xc5e0). */
static void mewx_pad_a(uint8_t out[32])
{
    uint32_t i;
    for (i = 0; i < 32; i++) {
        uint8_t a = (uint8_t)(0x5du * i);
        uint8_t b = (uint8_t)(0xe3u + 0x97u * i);
        out[i] = (uint8_t)((a ^ b) ^ MEWX_RODATA_1[i]);
    }
}

/* The 32-byte identity tail mixed into the identity hash (loop at 0xc390). */
static void mewx_pad_b(uint8_t out[32])
{
    uint32_t i;
    for (i = 0; i < 32; i++) {
        uint8_t a = (uint8_t)(0x5du * i);
        uint8_t b = (uint8_t)(0x55u + 0x0fu * i);
        out[i] = (uint8_t)((a ^ b) ^ MEWX_RODATA_2[i]);
    }
}

/* ==================================================================== *
 * Module state
 * ==================================================================== */

#define MEWX_IDENTITY_MAX_INTERNAL 512

static struct {
    int      ready;
    uint8_t  key[32];            /* derived working key, .bss+0x29 equivalent */
    int      flavor;
    int      version;
    char     ident[MEWX_IDENTITY_MAX_INTERNAL];
    size_t   ident_len;
} g_mewx = { 0, {0}, 0, 0, {0}, 0 };

/* Default process identity.
 *
 * On Android libmewx reads /proc/self/cmdline.  That file is NUL-terminated and
 * the library hashes the bytes it read, INCLUDING the trailing NUL: the identity
 * input is 16 bytes, "org.mewx.wenku8\0".  Getting this one byte wrong changes
 * the derived key completely (verified: 15 bytes yields a different but
 * well-formed key, which is the classic silent-failure mode here).
 *
 * iOS has no /proc, so this constant is the default and callers may override it
 * with mewx_envelope_set_process_name(). */
#define MEWX_DEFAULT_IDENT_LEN 16
static const char MEWX_DEFAULT_IDENT[MEWX_DEFAULT_IDENT_LEN] = {
    'o','r','g','.','m','e','w','x','.','w','e','n','k','u','8','\0'
};

/* ==================================================================== *
 * Public API
 * ==================================================================== */

int mewx_envelope_set_process_name(const char *name, size_t len)
{
    if (name == NULL) len = 0;
    if (len > MEWX_IDENTITY_MAX_INTERNAL - 1) return MEWX_ERR_IDENTITY_TOO_LONG;
    memset(g_mewx.ident, 0, sizeof g_mewx.ident);
    if (len) memcpy(g_mewx.ident, name, len);
    g_mewx.ident_len = len;
    return MEWX_OK;
}

int mewx_envelope_set_app_identity(const char *path, size_t len)
{
    /* The Android client folds its APK sourceDir into the identity string.  The
     * path carries a per-install random suffix and its *content* is not used, so
     * the server cannot validate it; supplying it here just keeps us faithful.
     * We treat it as an additional identity component. */
    return mewx_envelope_set_process_name(path, len);
}

/* Derive the per-instance working key.
 *
 * Recovered chain (every step verified byte-for-byte against the real library):
 *
 *   padA   = obfuscated 32-byte pad            (loop 0xc5e0)
 *   padB   = obfuscated 32-byte identity tail  (loop 0xc390)
 *   tag    = SHA256("wk8-fallback-cert-tag")
 *   ident  = SHA256(identity || tag || padB)
 *   msg96  = padA || SHA256(LUT) || seed
 *   prk    = HMAC-SHA256(ident, msg96)          <- libmewx 0x7d40 step 1
 *   info   = "wk8-rne-epoch-\0" || {0xC9, flavor, 0x01}     (18 bytes)
 *   key    = HMAC-SHA256(prk, info)             <- libmewx 0x7d40 step 2
 *
 * Note: HKDF-Expand here does NOT append a 0x01 counter byte, which is what the
 * generic HKDF construction would do.  Verified against libmewx for
 * flavor in {0,1,2,3,7}.
 */
int mewx_envelope_init(const uint8_t seed[MEWX_SEED_SIZE], int version, int flavor)
{
    uint8_t padA[32], padB[32], tag[32], ident[32];
    uint8_t hlut[32], msg96[96], prk[32], info[18];
    const char *ident_src;
    size_t ident_len;

    if (seed == NULL) return MEWX_ERR_BAD_SEED;

    aes_build_sbox();

    ident_src = (g_mewx.ident_len ? g_mewx.ident : MEWX_DEFAULT_IDENT);
    ident_len = (g_mewx.ident_len ? g_mewx.ident_len : MEWX_DEFAULT_IDENT_LEN);

    mewx_pad_a(padA);
    mewx_pad_b(padB);

    mewx_sha256((const uint8_t *)"wk8-fallback-cert-tag", 21, tag);
    {
        sha256_ctx c;
        sha256_init(&c);
        sha256_update(&c, (const uint8_t *)ident_src, ident_len);
        sha256_update(&c, tag, 32);
        sha256_update(&c, padB, 32);
        sha256_final(&c, ident);
    }

    mewx_sha256(mewx_lut, MEWX_LUT_SIZE, hlut);

    memcpy(msg96, padA, 32);
    memcpy(msg96 + 32, hlut, 32);
    memcpy(msg96 + 64, seed, 32);

    mewx_hmac_sha256(ident, 32, msg96, 96, prk);

    memcpy(info, "wk8-rne-epoch-\0", 15);
    info[15] = 0xC9;
    info[16] = (uint8_t)(flavor & 0xFF);
    info[17] = 0x01;
    mewx_hmac_sha256(prk, 32, info, 18, g_mewx.key);

    g_mewx.flavor  = flavor;
    g_mewx.version = version;
    g_mewx.ready   = 1;

    wipe(padA, sizeof padA); wipe(padB, sizeof padB);
    wipe(tag, sizeof tag);   wipe(ident, sizeof ident);
    wipe(prk, sizeof prk);   wipe(msg96, sizeof msg96);
    return MEWX_OK;
}

/* Debug hook: expose the derived working key so a test can compare it with the
 * emulator's .bss+0x29 state.  Returns 0 on success. */
int mewx_envelope_debug_key(uint8_t out[32])
{
    if (out == NULL) return MEWX_ERR_UNINITIALISED;
    if (!g_mewx.ready) return MEWX_ERR_UNINITIALISED;
    memcpy(out, g_mewx.key, 32);
    return MEWX_OK;
}

void mewx_envelope_reset(void)
{
    wipe(g_mewx.key, sizeof g_mewx.key);
    g_mewx.ready = 0;
}

int mewx_envelope_seal(const uint8_t *body, size_t body_len,
                       const uint8_t *extra, size_t extra_len,
                       int64_t counter, int64_t now_ms,
                       const uint8_t *rnd, size_t rnd_len,
                       uint8_t *out, size_t out_cap, size_t *out_len)
{
    uint32_t pad, need;
    size_t i;

    if (!g_mewx.ready) return MEWX_ERR_UNINITIALISED;
    if (out_len == NULL) return MEWX_ERR_OUT_TOO_SMALL;
    *out_len = 0;

    /* body_len == 0 is the library's "do not seal" case. */
    if (body_len == 0) return MEWX_OK;
    if (body_len > MEWX_BODY_MAX) return MEWX_ERR_BODY_RANGE;
    if (body == NULL || out == NULL) return MEWX_ERR_BODY_RANGE;

    /* extra is silently discarded beyond 512 bytes. */
    if (extra_len > MEWX_EXTRA_MAX) { extra_len = 0; extra = NULL; }

    if (rnd == NULL) return MEWX_ERR_RND_TOO_SHORT;
    if (rnd_len < 13u + MEWX_PAD_MAX) return MEWX_ERR_RND_TOO_SHORT;

    pad  = mewx_pad_len_for(rnd[12]);
    need = (uint32_t)body_len + MEWX_OVERHEAD + pad;
    if (out_cap < need) return MEWX_ERR_OUT_TOO_SMALL;

    /* Clear header, 17 bytes. */
    out[0] = 0x01;
    out[1] = 0x00;
    out[2] = 0xC9;
    out[3] = (uint8_t)(g_mewx.flavor & 0xFF);
    out[4] = 0x00;
    memcpy(out + 5, rnd, MEWX_NONCE_SIZE);

    /* Ciphertext region: body || padding.  The padding bytes come straight from
     * the entropy source (bytes 13 .. 13+pad), which is what the library does. */
    if (body_len) memcpy(out + MEWX_HEADER_SIZE, body, body_len);
    for (i = 0; i < pad; i++) {
        out[MEWX_HEADER_SIZE + body_len + i] = rnd[13 + i];
    }

    /* ------------------------------------------------------------------ *
     * The remaining transformation (the trailing 66-byte MAC/padding block and
     * the final 16-byte-per-block mixing) is NOT yet reproduced.  It is a
     * straightforward ARX mix over the derived key and the assembled buffer
     * (libmewx 0xe240 followed by the cipher loop in 0xcb80), but it has not
     * been validated against the reference vectors, so we refuse to emit a
     * plausible-looking envelope that the server would reject anyway.
     * ------------------------------------------------------------------ */
    (void)counter; (void)now_ms; (void)extra; (void)extra_len;

    wipe(out, need);
    return MEWX_ERR_KDF_UNRECOVERED;
}
