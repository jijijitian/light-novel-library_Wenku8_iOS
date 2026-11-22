#!/usr/bin/env python3
"""gen_vectors_header.py -- turn vectors.json into a C header for test_vectors.c.

Usage
-----
    python3 gen_vectors_header.py                       # vectors.json -> vectors_c.h
    python3 gen_vectors_header.py --in v.json --out x.h
    python3 gen_vectors_header.py --max-body 512        # skip the huge ones

The header exposes, for every vector:

    typedef struct {
        const char     *name;
        const uint8_t  *seed;      uint32_t seed_len;
        int32_t         version;
        int32_t         flavor;
        const uint8_t  *body;      uint32_t body_len;
        const uint8_t  *extra;     uint32_t extra_len;
        int64_t         counter;
        int64_t         now_ms;        /* = clock_seconds * 1000 */
        const uint8_t  *rnd;       uint32_t rnd_len;
        const uint8_t  *sealed;    uint32_t sealed_len;
    } mewx_test_vector;

    extern const mewx_test_vector mewx_test_vectors[];
    extern const uint32_t         mewx_test_vector_count;

Notes
-----
* `rnd` is materialised to 13 + MEWX_PAD_MAX = 108 bytes per vector, because that
  is exactly how many entropy bytes one seal can consume (12 nonce + 1 selector +
  up to 95 padding).  The oracle's `urandom_strategy` is evaluated here, so the C
  side never has to understand Python expressions.
* `now_ms` is `clock_seconds * 1000`; the oracle pins clock_gettime to whole
  seconds, so nanoseconds are always 0.

How the Swift test consumes the same data
-----------------------------------------
The Swift test does NOT use this header.  It decodes `vectors.json` directly:

    struct TestVector: Decodable {
        let bodyHex, extraHex, sealed, seed: String
        let bodyLen, sealedLen, counter: Int
        let version, flavor: Int
        let clockSeconds: Int
        enum CodingKeys: String, CodingKey {
            case bodyHex = "body_hex", extraHex = "extra_hex", sealed
            case bodyLen = "body_len", sealedLen = "sealed_len", counter
            case init, clockSeconds = "clock_seconds"
        }
        struct Init: Decodable { let seed: String; let version: Int; let flavor: Int }
    }

    let vectors = try JSONDecoder().decode([TestVector].self, from: data)

then rebuilds the entropy buffer with the same rule spelled out below
(`bytes(range(256)) * 16`), which is trivial in Swift:

    var rnd = [UInt8](); while rnd.count < 108 { rnd += (0...255).map(UInt8.init) }

so both languages consume one authoritative artifact (vectors.json) and the
header is only a convenience for the plain-C host test.
"""

import argparse
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
RND_NEEDED = 13 + 95          # 12 nonce + 1 selector + max 95 pad bytes


def eval_urandom(strategy):
    """Evaluate the oracle's deterministic entropy expression in a sandbox."""
    if not isinstance(strategy, str):
        raise ValueError('urandom_strategy must be a string')
    # The only form the oracle emits is "bytes(range(256)) * N".
    s = strategy.replace(' ', '')
    if s.startswith('bytes(range(256))*'):
        n = int(s[len('bytes(range(256))*'):])
        return bytes(range(256)) * n
    if s.startswith('bytes(') and s.endswith(')'):
        return bytes(eval(s[6:-1], {'__builtins__': {}}, {}))
    raise ValueError('unsupported urandom_strategy: %r' % strategy)


def c_array(data, per_line=12):
    if not data:
        return '0'
    out = []
    for i in range(0, len(data), per_line):
        out.append('    ' + ' '.join('0x%02x,' % b for b in data[i:i + per_line]))
    return '\n'.join(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--in', dest='inp', default=os.path.join(HERE, 'vectors.json'))
    ap.add_argument('--out', dest='outp', default=os.path.join(HERE, 'vectors_c.h'))
    ap.add_argument('--max-body', type=int, default=None,
                    help='omit vectors whose body exceeds this many bytes')
    args = ap.parse_args()

    vecs = json.load(open(args.inp))
    if args.max_body is not None:
        vecs = [v for v in vecs if v['body_len'] <= args.max_body]

    blocks = []
    index = []
    for i, v in enumerate(vecs):
        seed = bytes.fromhex(v['init']['seed'])
        body = bytes.fromhex(v['body_hex'])
        extra = bytes.fromhex(v['extra_hex'])
        sealed = bytes.fromhex(v['sealed'])
        rnd = eval_urandom(v['urandom_strategy'])[:RND_NEEDED]
        name = 'v%02d_body%d_ctr%d' % (i, v['body_len'], v['counter'])
        now_ms = v['clock_seconds'] * 1000

        blocks.append('/* ---- vector %d: body=%d extra=%d counter=%d seed=%s ---- */'
                      % (i, v['body_len'], len(extra), v['counter'],
                         v['init']['seed'][:16] + '...'))
        blocks.append('static const uint8_t vec%d_seed[]   = {\n%s\n};' % (i, c_array(seed)))
        blocks.append('static const uint8_t vec%d_body[]   = {\n%s\n};'
                      % (i, c_array(body) if body else '    0x00,'))
        blocks.append('static const uint8_t vec%d_extra[]  = {\n%s\n};'
                      % (i, c_array(extra) if extra else '    0x00,'))
        blocks.append('static const uint8_t vec%d_rnd[]    = {\n%s\n};' % (i, c_array(rnd)))
        blocks.append('static const uint8_t vec%d_sealed[] = {\n%s\n};' % (i, c_array(sealed)))
        blocks.append('')
        index.append(
            '    { "%s", vec%d_seed, %d, %d, %d,\n'
            '      vec%d_body, %d, vec%d_extra, %d,\n'
            '      %dLL, %dLL,\n'
            '      vec%d_rnd, %d, vec%d_sealed, %d },'
            % (name,
               i, len(seed), v['init']['version'], v['init']['flavor'],
               i, len(body), i, len(extra),
               v['counter'], now_ms,
               i, len(rnd), i, len(sealed)))

    header = '''/* vectors_c.h -- GENERATED by gen_vectors_header.py.  Do not edit.
 *
 * Source: %s
 * Vectors: %d
 *
 * Each vector carries every input the seal needs plus the oracle's exact output,
 * so a host test can assert byte-for-byte equality with no file I/O at run time.
 */
#ifndef MEWX_VECTORS_C_H
#define MEWX_VECTORS_C_H

#include <stdint.h>

typedef struct {
    const char     *name;
    const uint8_t  *seed;
    uint32_t        seed_len;
    int32_t         version;
    int32_t         flavor;
    const uint8_t  *body;
    uint32_t        body_len;
    const uint8_t  *extra;
    uint32_t        extra_len;
    int64_t         counter;
    int64_t         now_ms;
    const uint8_t  *rnd;
    uint32_t        rnd_len;
    const uint8_t  *sealed;
    uint32_t        sealed_len;
} mewx_test_vector;

''' % (os.path.basename(args.inp), len(vecs))
    header += '\n'.join(blocks)
    header += 'const mewx_test_vector mewx_test_vectors[] = {\n'
    header += '\n'.join(index) + '\n};\n\n'
    header += 'const uint32_t mewx_test_vector_count = %d;\n\n' % len(vecs)
    header += '#endif /* MEWX_VECTORS_C_H */\n'

    with open(args.outp, 'w') as f:
        f.write(header)
    print('wrote %s (%d vectors)' % (args.outp, len(vecs)))
    return 0


if __name__ == '__main__':
    sys.exit(main())
