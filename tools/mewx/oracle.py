#!/usr/bin/env python3
"""
oracle.py - reference oracle for the Wenku8 Android v2.0.4 "sealed envelope".

Emulates the x86_64 build of libmewx.so with Unicorn: runs JNI_OnLoad, calls the
two registered JNI natives (`a` = init, `b` = seal) and exposes

    init(seed: bytes, version: int, flavor: int) -> bool
    seal(body: bytes, extra: bytes, counter: int) -> bytes

Usage:
    python oracle.py                 # self-test with the reference vectors
    python oracle.py --emit          # print vectors.json to stdout

The emulator reproduces the library's own behaviour, so the vectors it emits are
ground truth for whatever the real app would send.
"""
import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from emu_core import Runner, STUB_BASE, STACK_BASE, STACK_SIZE  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_SO = '/tmp/and2/app-default-release-v2.0.4.104/lib/x86_64/libmewx.so'
DEFAULT_LUT = '/tmp/and2/app-default-release-v2.0.4.104/assets/wk8_lut.bin'

# org.mewx.wenku8.api.internal.NativeEnvelopeBridge.c() derives the seed from the
# two static byte arrays in defpackage.lv1 (Java: seed[i] = ((C[i] & 0xFF) -
# ((i*19+7) & 0xFF) & 0xFF) ^ (D[i] & 0xFF)).
LV1_C = [-120, -87, -84, 91, -83, -111, -51, 2, -126, -52, -76, 65, -92, -43,
         -35, 42, 30, 120, 98, -112, 63, -103, -122, -52, 13, 107, -70, -33,
         -53, -28, 25, -95]
LV1_D = [-58, 76, -82, -29, 23, -68, 72, -60, -60, -110, 105, -42, -7, -87,
         -29, -126, -61, 113, -75, 122, 18, 56, -23, -15, 63, -52, -4, 125,
         -65, -107, 106, -128]


def java_seed():
    """Exactly what NativeEnvelopeBridge.c() computes (32 bytes)."""
    return bytes((((LV1_C[i] & 0xFF) - ((i * 19 + 7) & 0xFF)) & 0xFF)
                 ^ (LV1_D[i] & 0xFF) for i in range(32))


# Deterministic surrogate sources, so vectors.json is bit-for-bit reproducible.
ORACLE_CLOCK = 1700000000
URANDOM_STRATEGY = 'bytes(range(256)) * 16'


class Oracle:
    def __init__(self, so_path=DEFAULT_SO, lut_path=DEFAULT_LUT,
                 urandom=None, clock=ORACLE_CLOCK, verbose=False):
        self.runner = Runner(so_path, lut_path, verbose=verbose)
        self.emu = self.runner.emu
        if urandom is not None:
            # deterministic "entropy" so vectors can be reproduced bit-for-bit
            self.emu.urandom = bytes(urandom)
        # deterministic wall clock: the envelope mixes clock_gettime(CLOCK_REALTIME)
        # seconds into the MAC, so it must be pinned for reproducible vectors
        self.clock = clock
        self._install_clock()
        self.onloaded = False
        self.inited = False
        self.init_args = None

    def _install_clock(self):
        import struct as _struct
        from unicorn.x86_const import UC_X86_REG_RSI
        clock = self.clock

        def clock_gettime(emu):
            tp = emu.mu.reg_read(UC_X86_REG_RSI)
            emu.wr(tp, _struct.pack('<qq', clock, 0))
            emu.ret(0)
        self.emu.imports['clock_gettime'] = clock_gettime

    # ---- JNI_OnLoad -------------------------------------------------------
    def onload(self):
        rc = self.runner.onload()
        self.onloaded = True
        self.natives = dict(self.emu.natives)
        return rc

    # ---- native `a`  init(Context, AssetManager, byte[32] seed, int, int) --
    def init(self, seed=None, version=104, flavor=2):
        if not self.onloaded:
            self.onload()
        if seed is None:
            seed = java_seed()
        seed = bytes(seed)
        if len(seed) != 32:
            return False
        emu = self.emu
        h_seed = emu.new_handle(bytearray(seed))
        fn = self.natives.get(b'a', 0xed70)
        rc = self.runner.call(fn, [
            emu.env_obj,          # JNIEnv*
            0x1000,               # fake android.content.Context
            0x2000,               # fake Context.getAssets()
            0xA55E7000,           # fake AssetManager* (AAsset_* are intercepted)
            h_seed, version, flavor,
        ])
        self.inited = bool(rc)
        self.init_args = (seed, version, flavor)
        return self.inited

    # ---- native `b`  seal(byte[] body, byte[] extra, long counter) --------
    def seal(self, body, extra=b'', counter=0):
        if not self.inited:
            if not self.init():
                raise RuntimeError('seal() called before successful init()')
        emu = self.emu
        body = bytes(body)
        extra = bytes(extra)
        h_body = emu.new_handle(bytearray(body))
        h_extra = emu.new_handle(bytearray(extra))
        fn = self.natives.get(b'b', 0xfb30)
        res = self.runner.call(fn, [
            emu.env_obj,
            emu.new_handle(('class', b'NativeEnvelopeBridge')),
            h_body, h_extra, counter,
        ])
        if not res:
            return b''
        h = emu.get_handle(res)
        return bytes(h) if h is not None else b''


# ---------------------------------------------------------------- test vectors
BODIES = [
    # --- realistic request bodies, counter 0 ---
    (b'action=novellist&sort=lastupdate&page=1&t=0', b'', 0),
    (b'action=book&do=info&aid=3670&t=0', b'', 0),
    (b'action=chapterList&aid=1&t=0', b'', 0),
    # --- counter variations ---
    (b'action=novellist&sort=lastupdate&page=1&t=0', b'', 1),
    (b'action=novellist&sort=lastupdate&page=1&t=0', b'', 1234567890),
    (b'action=novellist&sort=lastupdate&page=1&t=0', b'', 4294967296),
    (b'action=novellist&sort=lastupdate&page=1&t=0', b'', 18446744073709551615),
    (b'action=book&do=info&aid=3670&t=0', b'', 1),
    (b'action=book&do=info&aid=3670&t=0', b'', 1234567890),
    (b'action=chapterList&aid=1&t=0', b'', 1),
    (b'action=chapterList&aid=1&t=0', b'', 1234567890),
    (b'action=chapterList&aid=1&t=0', b'', 4294967296),
    # --- extra (cookie / header) variations ---
    (b'action=book&do=info&aid=3670&t=0', b'X-WK8-Proto: 2', 0),
    (b'action=book&do=info&aid=3670&t=0', b'Cookie: PHPSESSID=deadbeef', 7),
    (b'action=novellist&sort=lastupdate&page=1&t=0',
     b'Mozilla/5.0 (Linux; Android 13)', 42),
    (b'action=novellist&sort=lastupdate&page=1&t=0', b'a', 0),
    (b'action=novellist&sort=lastupdate&page=1&t=0', b'0123456789abcdef' * 32, 0),
    # --- tiny bodies ---
    (b'x', b'', 0),
    (b'xy', b'', 0),
    (b'action=fullflag&aid=1&t=0', b'', 0),
    # --- other endpoints seen in the app ---
    (b'action=search&keyword=test&t=0', b'', 0),
    (b'action=search&keyword=%E6%96%97%E7%A0%B4&t=0', b'', 0),
    (b'action=book&do=info&aid=1&t=0', b'', 5),
    (b'action=book&do=info&aid=999999&t=0', b'', 0),
    (b'action=novellist&sort=allvisit&page=2&t=0', b'', 0),
    (b'action=novellist&sort=allvote&page=3&t=0', b'', 0),
    (b'action=novellist&sort=postdate&page=4&t=0', b'', 0),
    (b'action=novellist&sort=lastupdate&page=1&t=0&type=0', b'', 0),
    (b'action=book&do=chapter&aid=1&cid=1&t=0', b'', 0),
    # --- long bodies (forces multi-block handling) ---
    (b'action=novellist&sort=lastupdate&page=1&t=0' + b'&pad=' + b'z' * 200, b'', 0),
    (b'action=novellist&sort=lastupdate&page=1&t=0' + b'&pad=' + b'q' * 1000, b'', 1),
    (b'P' * 4096, b'', 0),
    # --- binary / non-UTF8 bodies ---
    (b'\x00\x01\x02\x03\xff\xfe\xfd', b'', 0),
    (b'action=book&do=info&aid=3670&t=0', b'\x00\xff\x00\xff', 9),
    (bytes(range(256)), b'', 0),
    # --- more realistic app traffic ---
    (b'action=book&do=info&aid=3670&t=0&top=0', b'', 0),
    (b'action=chapterList&aid=3670&t=0', b'', 1234567890),
    (b'action=novellist&sort=lastupdate&page=1&t=0&cid=0&type=0', b'', 0),
    (b'action=book&do=info&aid=1&t=0', b'X-WK8-Proto: 2', 1),
    (b'action=novellist&sort=lastupdate&page=1&t=0',
     b'Cookie: PHPSESSID=' + b'f' * 200, 8),
    (b'action=search&keyword=' + b'%41' * 100 + b'&t=0', b'', 0),
    # --- degenerate ---
    (b'', b'', 0),
]


def build_vectors(oracle, dump_hex=True):
    out = []
    meta = {
        'oracle_clock_seconds': ORACLE_CLOCK,
        'urandom_strategy': URANDOM_STRATEGY,
    }
    for body, extra, counter in BODIES:
        sealed = oracle.seal(body, extra, counter)
        rec = {
            'body': body.decode('utf-8', 'surrogateescape') if _is_utf8(body) else body.hex(),
            'body_hex': body.hex(),
            'extra': extra.decode('utf-8', 'surrogateescape') if _is_utf8(extra) else extra.hex(),
            'extra_hex': extra.hex(),
            'counter': counter,
            'sealed': sealed.hex(),
            'sealed_len': len(sealed),
            'body_len': len(body),
            'init': {'seed': oracle.init_args[0].hex(),
                     'version': oracle.init_args[1],
                     'flavor': oracle.init_args[2]},
            'clock_seconds': ORACLE_CLOCK,
            'urandom_strategy': URANDOM_STRATEGY,
        }
        out.append(rec)
    return out


def selfcheck(o):
    """Invariants of the real library, checked against the emulator."""
    body = b'A' * 16
    checks = []
    # 1) determinism with a fixed entropy+clock source
    a = o.seal(body, b'', 0)
    checks.append(('deterministic', a == o.seal(body, b'', 0)))

    # 2) clear header: 01 00 c9 <flavor> 00 | 12-byte nonce | ...
    checks.append(('magic 01 00 c9', a[:3] == b'\x01\x00\xc9'))
    checks.append(('flavor byte == 2', a[3] == 2))
    checks.append(('reserved 0 at [4]', a[4] == 0))
    ur = o.emu.urandom
    checks.append(('nonce echoed verbatim', a[5:17] == ur[0:12]))

    # 3) length law: out = body + 83 + pad, pad in [16, 95], pad depends only on nonce[12]
    def padlen(k):
        ecx = ((k * 205) >> 10) & 0xFFFFFFF0
        ecx = (ecx + ecx * 4) & 0xFFFFFFFF
        return ((k - ecx) & 0xFF) + 16
    checks.append(('length law', len(a) == 16 + 83 + padlen(ur[12])))

    # 4) empty body -> empty result
    checks.append(('empty body -> empty', o.seal(b'', b'', 0) == b''))

    # 5) counter is 64-bit and changes the MAC only (no length change)
    b1 = o.seal(body, b'', 1)
    c1 = o.seal(body, b'', 1 + (1 << 32))
    checks.append(('counter 64-bit', len(b1) == len(a) and b1 != a and c1 != b1))

    # 6) extra > 512 bytes is ignored (treated as absent)
    checks.append(('extra cap 512',
                   o.seal(body, b'Q' * 513, 0) == o.seal(body, b'', 0)))

    # 7) the LUT is mixed into the key (AAsset-served bytes matter)
    import tempfile, os
    orig_lut = open(o.emu.lut_src_path if hasattr(o.emu, 'lut_src_path') else DEFAULT_LUT,
                    'rb').read()
    p = tempfile.mktemp()
    open(p, 'wb').write(bytes(2048))
    o2 = Oracle(urandom=bytes(range(256)) * 16, lut_path=p)
    o2.onload(); o2.init()
    zero_lut_out = o2.seal(body, b'', 0)
    os.unlink(p)
    o3 = Oracle(urandom=bytes(range(256)) * 16)
    o3.onload(); o3.init()
    real_lut_out = o3.seal(body, b'', 0)
    checks.append(('LUT affects key', zero_lut_out != real_lut_out))

    # 8) init rejects non-32-byte seeds
    o2 = Oracle(urandom=bytes(range(256)) * 16)
    o2.onload()
    checks.append(('seed must be 32B', o2.init(seed=bytes(31)) is False))
    ok = True
    for name, res in checks:
        print('  [%s] %s' % ('OK ' if res else 'BAD', name), file=sys.stderr)
        ok = ok and res
    return ok


def _is_utf8(b):
    try:
        b.decode('utf-8')
        return True
    except UnicodeDecodeError:
        return False


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--emit', action='store_true', help='print vectors JSON')
    ap.add_argument('--verbose', action='store_true')
    ap.add_argument('--selfcheck', action='store_true',
                    help='verify the emulator against known-good invariants')
    ap.add_argument('--out', default=None, help='write vectors JSON to this path')
    ap.add_argument('--so', default=DEFAULT_SO)
    ap.add_argument('--lut', default=DEFAULT_LUT)
    args = ap.parse_args()

    o = Oracle(args.so, args.lut, urandom=bytes(range(256)) * 16, verbose=args.verbose)
    print('JNI_OnLoad -> 0x%x' % o.onload(), file=sys.stderr)
    for k, v in o.natives.items():
        print('  native %-3r -> 0x%x' % (k, v), file=sys.stderr)
    print('init(java_seed, 104, 2) ->', o.init(), file=sys.stderr)
    print('seed =', java_seed().hex(), file=sys.stderr)

    if args.selfcheck:
        ok = selfcheck(o)
        print('SELF-CHECK:', 'PASS' if ok else 'FAIL', file=sys.stderr)
        if not ok:
            sys.exit(1)

    vecs = build_vectors(o)
    if args.out:
        with open(args.out, 'w') as f:
            json.dump(vecs, f, indent=2)
        print('wrote %s (%d vectors)' % (args.out, len(vecs)), file=sys.stderr)
    if args.emit:
        print(json.dumps(vecs, indent=2))
        return
    print('\n%-4s %-8s %-8s %-6s %s' % ('#', 'body', 'out', 'ctr', 'sealed[0:48]'))
    for i, v in enumerate(vecs):
        print('%-4d %-8d %-8d %-6d %s%s' % (i, v['body_len'], v['sealed_len'],
                                            v['counter'],
                                            v['sealed'][:48],
                                            '...' if v['sealed_len'] > 24 else ''))


if __name__ == '__main__':
    main()
