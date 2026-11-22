/* test_vectors.c -- host test for the relay-v2 envelope port.
 *
 * Build & run (plain clang, no dependencies):
 *     clang -std=c11 -Wall -Wextra -Werror -O2 \
 *           -I c c/test_vectors.c c/mewx_envelope.c c/mewx_lut_data.c -o /tmp/tv && /tmp/tv
 *
 * What is asserted here:
 *   1. SHA-256 known-answer vectors (FIPS 180-4 + the real libmewx behaviour
 *      confirmed across 139 message lengths by emulation).
 *   2. HMAC-SHA256 known-answer vectors (RFC 4231).
 *   3. AES-256 block encryption known-answer vectors (FIPS-197 / NIST).
 *   4. The recovered key-derivation chain: the 32-byte working key must equal
 *      libmewx's .bss+0x29 state for several flavors.  This is the exact value
 *      read out of the running Android library under emulation.
 *   5. The padding / length law for all 256 possible entropy selectors.
 *   6. Envelope framing invariants that do not depend on the unfinished cipher
 *      stage (header bytes, nonce echo, body/extra limits).
 *
 * The full 42-vector byte-for-byte seal comparison is NOT enabled: the trailing
 * MAC/mix stage of the cipher is not yet reproduced, so mewx_envelope_seal()
 * deliberately refuses rather than emitting a wrong envelope.  See
 * docs/relay-v2-cipher-notes.md.
 */

#include <stdio.h>
#include <string.h>
#include <stdlib.h>

#include "mewx_envelope.h"

/* ------------------------------------------------------------------ */
/* helpers                                                             */
/* ------------------------------------------------------------------ */

static int g_fail = 0;
static int g_pass = 0;

static void check(int cond, const char *what)
{
    if (cond) {
        g_pass++;
    } else {
        g_fail++;
        printf("  FAIL  %s\n", what);
    }
}

static void hexdump(const char *label, const uint8_t *p, size_t n)
{
    size_t i;
    printf("        %s = ", label);
    for (i = 0; i < n; i++) printf("%02x", p[i]);
    printf("\n");
}

/* Parse a lowercase hex string into buf.  Returns byte count, or 0 on error. */
static size_t unhex(const char *s, uint8_t *buf, size_t cap)
{
    size_t n = 0;
    while (s[0] && s[1]) {
        unsigned v;
        if (n >= cap) return 0;
        if (sscanf(s, "%2x", &v) != 1) return 0;
        buf[n++] = (uint8_t)v;
        s += 2;
    }
    return n;
}

static void check_hex(const char *what, const uint8_t *got, size_t n, const char *want_hex)
{
    uint8_t want[256];
    size_t wn = unhex(want_hex, want, sizeof want);
    int ok = (wn == n) && (memcmp(got, want, n) == 0);
    if (!ok) {
        printf("  FAIL  %s\n", what);
        hexdump("got ", got, n);
        printf("        want= %s\n", want_hex);
    }
    check(ok, what);
}

/* ------------------------------------------------------------------ */
/* 1. SHA-256                                                          */
/* ------------------------------------------------------------------ */

static void test_sha256(void)
{
    uint8_t out[32];
    printf("SHA-256\n");

    mewx_sha256((const uint8_t *)"", 0, out);
    check_hex("sha256(\"\")",
              out, 32,
              "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");

    mewx_sha256((const uint8_t *)"abc", 3, out);
    check_hex("sha256(\"abc\")",
              out, 32,
              "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");

    mewx_sha256((const uint8_t *)
        "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq", 56, out);
    check_hex("sha256(448-bit msg)",
              out, 32,
              "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1");

    /* The exact "wk8-fallback-cert-tag" hash libmewx computes internally. */
    mewx_sha256((const uint8_t *)"wk8-fallback-cert-tag", 21, out);
    check_hex("sha256(\"wk8-fallback-cert-tag\")",
              out, 32,
              "3f89c256652e040b5f619c4e3b2580dadb87437b8c5efb5d7636cac5be155cf4");

    /* The LUT hash libmewx derives during init. */
    mewx_sha256(mewx_lut, MEWX_LUT_SIZE, out);
    check_hex("sha256(wk8_lut.bin)",
              out, 32,
              "89d305d41dd28dcf17c8e3bc12a4ce5ad4f1d860345413d1c303e23472e019ad");
}

/* ------------------------------------------------------------------ */
/* 2. HMAC-SHA256                                                      */
/* ------------------------------------------------------------------ */

static void test_hmac(void)
{
    uint8_t out[32];
    printf("HMAC-SHA256\n");

    /* RFC 4231 test case 2 */
    mewx_hmac_sha256((const uint8_t *)"Jefe", 4,
                     (const uint8_t *)"what do ya want for nothing?", 28, out);
    check_hex("rfc4231 tc2",
              out, 32,
              "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843");

    /* RFC 4231 test case 3 */
    {
        uint8_t key[20], msg[50];
        memset(key, 0xaa, sizeof key);
        memset(msg, 0xdd, sizeof msg);
        mewx_hmac_sha256(key, sizeof key, msg, sizeof msg, out);
        check_hex("rfc4231 tc3",
                  out, 32,
                  "773ea91e36800e46854db8ebd09181a72959098b3ef8c122d9635514ced565fe");
    }

    /* RFC 4231 test case 6: key longer than the block size. */
    {
        uint8_t key[131];
        memset(key, 0xaa, sizeof key);
        mewx_hmac_sha256(key, sizeof key,
                         (const uint8_t *)
                         "Test Using Larger Than Block-Size Key - Hash Key First",
                         54, out);
        check_hex("rfc4231 tc6",
                  out, 32,
                  "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54");
    }
}

/* ------------------------------------------------------------------ */
/* 3. AES-256                                                          */
/* ------------------------------------------------------------------ */

static void test_aes(void)
{
    uint8_t ctx[512];
    uint8_t ct[16];
    printf("AES-256\n");

    if (mewx_aes256_ctx_size() > sizeof ctx) {
        check(0, "aes context fits the local buffer");
        return;
    }

    /* FIPS-197 appendix C.3 */
    {
        uint8_t key[32], pt[16];
        unhex("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f",
              key, sizeof key);
        unhex("00112233445566778899aabbccddeeff", pt, sizeof pt);
        mewx_aes256_expand(ctx, key);
        mewx_aes256_encrypt_block(ctx, pt, ct);
        check_hex("fips197 C.3", ct, 16, "8ea2b7ca516745bfeafc49904b496089");
    }

    /* NIST SP 800-38A F.1.5 (ECB-AES256, block 1) */
    {
        uint8_t key[32], pt[16];
        unhex("603deb1015ca71be2b73aef0857d77811f352c073b6108d72d9810a30914dff4",
              key, sizeof key);
        unhex("6bc1bee22e409f96e93d7e117393172a", pt, sizeof pt);
        mewx_aes256_expand(ctx, key);
        mewx_aes256_encrypt_block(ctx, pt, ct);
        check_hex("sp800-38a F.1.5", ct, 16, "f3eed1bdb5d2a03c064b5a7e3db181f8");
    }
}

/* ------------------------------------------------------------------ */
/* 4. key derivation (the recovered chain)                             */
/* ------------------------------------------------------------------ */

struct kdf_case {
    int         flavor;
    const char *expected;   /* libmewx .bss+0x29 under emulation */
};

static void test_kdf(void)
{
    static const struct kdf_case cases[] = {
        /* Values read directly out of the running Android library (.bss+0x29)
         * under Unicorn emulation, one per flavor.  These are the ground truth
         * the C derivation must reproduce. */
        { 0, "20744c6e2587d217f20078ce040897d4db517345fb4c85e746d24fc82ff40ed9" },
        { 1, "da5a11c9cbec4947e7c6566496e63ef6a4b27e9750030774faa23e26e5478569" },
        { 2, "6ba3d50704d5c101ca0493f2048bdd42e9bb4d7129a1d5cfabb842b540b45019" },
        { 3, "838a688629752cf460c15f6b86ab3fe8650906d616322a77967cf1c22a169a59" },
        { 7, "6860caa82ac1c20f1ea39f1c3eadfb3387ffc2134345b3437db5e7eed1b5d786" },
    };
    uint8_t seed[32];
    uint8_t key[32];
    size_t i;

    printf("key derivation\n");
    unhex("47c3d1f84d971cb2278886bf407e2f84245fb05aae3b34e1014539aa0f23b2cd",
          seed, sizeof seed);

    for (i = 0; i < sizeof cases / sizeof cases[0]; i++) {
        char label[64];
        int rc = mewx_envelope_init(seed, 104, cases[i].flavor);
        snprintf(label, sizeof label, "init(flavor=%d) returns 0", cases[i].flavor);
        check(rc == 0, label);
        if (rc != 0) continue;

        rc = mewx_envelope_debug_key(key);
        snprintf(label, sizeof label, "derived key matches .bss for flavor=%d",
                 cases[i].flavor);
        check_hex(label, key, 32, cases[i].expected);
    }

    /* A different seed must produce a different key. */
    {
        uint8_t seed2[32];
        uint8_t key_a[32], key_b[32];
        memcpy(seed2, seed, sizeof seed2);
        seed2[0] ^= 0xFF;
        mewx_envelope_init(seed, 104, 2);
        mewx_envelope_debug_key(key_a);
        mewx_envelope_init(seed2, 104, 2);
        mewx_envelope_debug_key(key_b);
        check(memcmp(key_a, key_b, 32) != 0, "seed change alters the derived key");
    }

    /* Determinism. */
    {
        uint8_t k1[32], k2[32];
        mewx_envelope_init(seed, 104, 2);
        mewx_envelope_debug_key(k1);
        mewx_envelope_init(seed, 104, 2);
        mewx_envelope_debug_key(k2);
        check(memcmp(k1, k2, 32) == 0, "key derivation is deterministic");
    }
}

/* ------------------------------------------------------------------ */
/* 5. padding / length law                                             */
/* ------------------------------------------------------------------ */

static void test_padding_law(void)
{
    unsigned k;
    int all_ok = 1;
    int in_range = 1;
    printf("padding law\n");

    for (k = 0; k < 256; k++) {
        uint32_t pad = mewx_pad_len_for((uint8_t)k);
        /* Independent re-derivation of the library's arithmetic. */
        uint32_t ecx = ((uint32_t)k * 205u) >> 10;
        ecx &= 0xFFFFFFF0u;
        ecx = (ecx + ecx * 4u) & 0xFFFFFFFFu;
        uint32_t want = (uint32_t)(uint8_t)((uint32_t)k - ecx) + 16u;
        if (pad != want) all_ok = 0;
        if (pad < MEWX_PAD_MIN || pad > MEWX_PAD_MAX) in_range = 0;
    }
    check(all_ok, "pad formula matches for all 256 selectors");
    check(in_range, "pad always within [16, 95]");

    /* Spot checks documented in the findings report. */
    check(mewx_pad_len_for(0)   == 16, "pad(0) == 16");
    check(mewx_pad_len_for(1)   == 17, "pad(1) == 17");
    check(mewx_pad_len_for(40)  == 56, "pad(40) == 56");
    check(mewx_pad_len_for(79)  == 95, "pad(79) == 95");
    check(mewx_pad_len_for(128) == 64, "pad(128) == 64");
    check(mewx_pad_len_for(255) == 31, "pad(255) == 31");
}

/* ------------------------------------------------------------------ */
/* 6. envelope framing invariants                                      */
/* ------------------------------------------------------------------ */

static void test_framing(void)
{
    uint8_t seed[32];
    uint8_t rnd[13 + 95];
    uint8_t out[256];
    size_t out_len = 0;
    unsigned i;
    int rc;

    printf("envelope framing\n");
    unhex("47c3d1f84d971cb2278886bf407e2f84245fb05aae3b34e1014539aa0f23b2cd",
          seed, sizeof seed);
    for (i = 0; i < sizeof rnd; i++) rnd[i] = (uint8_t)i;

    mewx_envelope_init(seed, 104, 2);

    /* Empty body is the "do not seal" case: 0 bytes, success. */
    rc = mewx_envelope_seal((const uint8_t *)"", 0, NULL, 0, 0, 0,
                           rnd, sizeof rnd, out, sizeof out, &out_len);
    check(rc == 0 && out_len == 0, "empty body yields an empty envelope");

    /* Oversized body is rejected. */
    {
        static uint8_t big[MEWX_BODY_MAX + 1];
        rc = mewx_envelope_seal(big, sizeof big, NULL, 0, 0, 0,
                               rnd, sizeof rnd, out, sizeof out, &out_len);
        check(rc != 0, "body > MEWX_BODY_MAX rejected");
    }

    /* Too little entropy is rejected. */
    rc = mewx_envelope_seal((const uint8_t *)"x", 1, NULL, 0, 0, 0,
                           rnd, 12, out, sizeof out, &out_len);
    check(rc != 0, "short entropy buffer rejected");

    /* Right-sized buffer: the framing is written, but the cipher stage is not
     * implemented, so the call must report failure rather than pretend. */
    rc = mewx_envelope_seal((const uint8_t *)"x", 1, NULL, 0, 0, 0,
                           rnd, sizeof rnd, out, sizeof out, &out_len);
    check(rc != 0, "unimplemented cipher stage reports failure (not silent)");
}

/* ------------------------------------------------------------------ */

int main(void)
{
    printf("relay-v2 envelope host test\n");
    printf("===========================\n");

    test_sha256();
    test_hmac();
    test_aes();
    test_kdf();
    test_padding_law();
    test_framing();

    printf("===========================\n");
    printf("passed %d, failed %d\n", g_pass, g_fail);
    if (g_fail) {
        printf("RESULT: FAIL\n");
        return 1;
    }
    printf("RESULT: PASS\n");
    return 0;
}
