/* mewx_envelope.h -- portable relay-v2 sealed-envelope API.
 *
 * Reverse-engineered from Android's libmewx.so (Wenku8 v2.0.4.104), x86_64 build,
 * by emulation of the real library.  No external dependencies; compiles for
 * iOS / macOS / any C11 target.
 *
 * STATUS (read this before relying on the code)
 * ---------------------------------------------
 * The crypto primitives are RECOVERED AND EXHAUSTIVELY VERIFIED against the real
 * library (see docs/relay-v2-cipher-notes.md for the evidence):
 *
 *     0x6cc0  ==  standard SHA-256          (139/139 known-answer tests pass)
 *     0x7050  ==  standard HMAC-SHA256      ( 72/72  known-answer tests pass)
 *     table built inside 0x8dc0 == the standard AES S-box (byte-for-byte)
 *     0xa050 / 0xa2b0    ==  AES-CTR keystream / AES round function
 *
 * The earlier description of this envelope as a "custom 32-bit ARX cipher with
 * rol {3,8,24,26}" is WRONG: those rotations are SHA-256's Sigma0/Sigma1
 * (rotr 2/13/22 and 6/11/25) plus Sigma1 of the message schedule, masked behind
 * constants that libmewx recomputes at run time with SSE instructions instead of
 * storing them in .rodata.
 *
 * NOT YET RECOVERED: the exact key-derivation chain that combines
 * {32-byte seed, 2048-byte LUT, flavor, process name, jni-init extras} into the
 * per-seal working key.  The emulator that produced the reference vectors is
 * currently missing JNI stubs for the init path (getApplicationInfo ->
 * sourceDir), so that path is skipped during emulation and the derived key does
 * not match what a real device would compute.  Consequently mewx_envelope_seal()
 * is NOT yet guaranteed to reproduce the reference vectors.
 *
 * This header is therefore the agreed API surface, with every external input
 * made injectable so that the remaining work is a pure function-fitting problem
 * and so that tests are deterministic.
 *
 * Design rule: nothing here reads /proc, the clock, or an OS RNG.  iOS has no
 * /proc, so the process name is an explicit parameter, and time/entropy are
 * supplied by the caller.
 */

#ifndef MEWX_ENVELOPE_H
#define MEWX_ENVELOPE_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Size of the wk8_lut.bin asset, in bytes. */
#define MEWX_LUT_SIZE 2048

/* Required seed length, in bytes.  Java derives it from lv1.C / lv1.D as
 *   seed[i] = ((C[i] & 0xFF) - ((i*19 + 7) & 0xFF) & 0xFF) ^ (D[i] & 0xFF)
 * and init() rejects anything that is not exactly 32 bytes. */
#define MEWX_SEED_SIZE 32

/* Clear (unencrypted) envelope header. */
#define MEWX_HEADER_SIZE 17
#define MEWX_NONCE_SIZE  12

/* `extra` is silently treated as absent beyond this length. */
#define MEWX_EXTRA_MAX 512

/* Longest body the library will seal (guard is `len - 1 <= 0x7FFF`). */
#define MEWX_BODY_MAX 32768

/* Smallest possible / largest possible padding the length law can add. */
#define MEWX_PAD_MIN 16
#define MEWX_PAD_MAX 95

/* Fixed per-message overhead above body_len, excluding padding. */
#define MEWX_OVERHEAD 83

/* Largest buffer mewx_envelope_seal() can ever need. */
#define MEWX_MAX_OUT (MEWX_BODY_MAX + MEWX_OVERHEAD + MEWX_PAD_MAX)

/* The LUT, compiled in from mewx_lut_data.c. */
extern const uint8_t mewx_lut[MEWX_LUT_SIZE];

/* ------------------------------------------------------------------ *
 * Process / application identity
 * ------------------------------------------------------------------ *
 * libmewx does not hardcode the strings it keys on; it builds them at run time
 * and also folds in the running process / application identity (the app reads
 * its own package path during init).  On iOS there is no /proc, so the caller
 * must supply the equivalent string explicitly.
 *
 * Set this BEFORE calling mewx_envelope_init().  Both strings are copied, so the
 * caller's buffers may be released immediately.  Passing NULL for either clears
 * it and restores the built-in default.  Returns 0 on success, non-zero on
 * failure (e.g. string longer than MEWX_IDENTITY_MAX).
 */
#define MEWX_IDENTITY_MAX 512

int mewx_envelope_set_process_name(const char *name, size_t len);
int mewx_envelope_set_app_identity(const char *path, size_t len);

/* ------------------------------------------------------------------ *
 * Initialisation
 * ------------------------------------------------------------------ */

/* One-time init.
 *
 *   seed     the 32-byte Java-derived seed (see MEWX_SEED_SIZE)
 *   version  build version, as passed to the native init (104 in v2.0.4.104).
 *            Confirmed behaviour of the real library: `version` is IGNORED by
 *            init; 103 and 104 produce byte-identical state.  Kept in the API
 *            for fidelity and so a future build that does use it needs no
 *            signature change.
 *   flavor   flavour selector (2 = default, 1 = playstore).  It is copied into
 *            the clear header byte [3] and is also folded into the key.
 *
 * Returns 0 on success, non-zero on failure.
 *
 * The LUT is compiled in from mewx_lut_data.c and is required key material: it
 * is mixed into the per-instance key during init, so a wrong or missing LUT
 * yields a wrong-but-well-formed envelope.
 */
int mewx_envelope_init(const uint8_t seed[MEWX_SEED_SIZE], int version, int flavor);

/* ------------------------------------------------------------------ *
 * Sealing
 * ------------------------------------------------------------------ */

/* Seal one request.
 *
 *   body       plaintext payload; 1 <= body_len <= MEWX_BODY_MAX.
 *              body_len == 0 is the "do not seal" case and returns 0 bytes.
 *   extra      optional cookie / header bytes; > MEWX_EXTRA_MAX is ignored.
 *              Empty is distinct from one zero byte.
 *   counter    Java `long`.  It is ADDITIVE with the wall clock: the library
 *              feeds (now_ms + counter) into the message as a freshness bound,
 *              which is how the app reconstructs the server clock from
 *              `c.set(serverTime - System.currentTimeMillis())`.  Signed 64-bit;
 *              negative values are legal.
 *   now_ms     wall-clock milliseconds, supplied by the caller so tests are
 *              deterministic.  Production code should pass real wall time.
 *   rnd, rnd_len
 *              entropy source bytes.  The caller passes /dev/urandom on macOS or
 *              arc4random_buf() on iOS.  The library consumes:
 *                rnd[0..12)            -> clear header nonce (out[5..17))
 *                rnd[12]               -> selects the padding length
 *                rnd[13..13+pad)       -> the padding bytes themselves
 *              so rnd_len must be at least 13 + MEWX_PAD_MAX bytes.
 *   out, out_cap, out_len
 *              destination buffer and its capacity; *out_len receives the
 *              number of bytes written.
 *
 * Output layout:
 *   out[0]      0x01    format version
 *   out[1]      0x00    reserved
 *   out[2]      0xC9    format tag
 *   out[3]      flavor
 *   out[4]      0x00    reserved
 *   out[5..17)  12-byte nonce, copied verbatim from rnd[0..12)
 *   out[17..)   ciphertext
 *
 * Length law (exact, verified for k in 0..255):
 *   out_len = body_len + MEWX_OVERHEAD + pad
 *   pad     = 16 + ((k - 5*(( (k*205) >> 10 ) & 0xFFFFFFF0)) & 0xFF)
 * where k = rnd[12].  pad is therefore always in [16, 95], so out_len carries
 * 16..95 bytes of random padding and is NOT a function of input length alone.
 *
 * Returns 0 on success.  Non-zero on failure, including: not initialised,
 * body longer than MEWX_BODY_MAX, rnd_len too small, or out_cap too small.
 */
int mewx_envelope_seal(const uint8_t *body, size_t body_len,
                       const uint8_t *extra, size_t extra_len,
                       int64_t counter, int64_t now_ms,
                       const uint8_t *rnd, size_t rnd_len,
                       uint8_t *out, size_t out_cap, size_t *out_len);

/* The padding length selected by entropy byte `k`.  Exposed because it is part
 * of the observable framing and is useful on its own. */
static inline uint32_t mewx_pad_len_for(uint8_t k)
{
    uint32_t ecx = ((uint32_t)k * 205u) >> 10;
    ecx &= 0xFFFFFFF0u;
    ecx = (ecx + ecx * 4u) & 0xFFFFFFFFu;
    return (uint32_t)(uint8_t)((uint32_t)k - ecx) + 16u;
}

/* Drop any derived key material.  Optional; sealing is unavailable afterwards
 * until mewx_envelope_init() is called again. */
void mewx_envelope_reset(void);

#ifdef __cplusplus
}
#endif

#endif /* MEWX_ENVELOPE_H */

/* ------------------------------------------------------------------ *
 * Internal test hooks
 * ------------------------------------------------------------------ *
 * These exist so the host test can validate each recovered primitive against
 * known-answer vectors independently of the envelope as a whole.  Production
 * callers should ignore them.
 *
 * The AES round-key context is opaque here; use mewx_aes256_ctx_size() to
 * allocate it.
 */
size_t mewx_aes256_ctx_size(void);
void   mewx_sha256(const uint8_t *data, size_t len, uint8_t out[32]);
void   mewx_hmac_sha256(const uint8_t *key, size_t key_len,
                        const uint8_t *msg, size_t msg_len,
                        uint8_t out[32]);
void   mewx_aes256_expand(void *ctx, const uint8_t key[32]);
void   mewx_aes256_encrypt_block(const void *ctx, const uint8_t in[16], uint8_t out[16]);

/* Expose the derived working key so a test can compare it against the
 * emulator's .bss+0x29.  Returns 0 on success. */
int    mewx_envelope_debug_key(uint8_t out[32]);
