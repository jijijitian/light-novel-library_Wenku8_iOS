"""Minimal ELF x86_64 user-space emulator on top of Unicorn, tailored to libmewx.so."""
import struct, sys
from unicorn import *
from unicorn.x86_const import *
from elftools.elf.elffile import ELFFile
from elftools.elf.relocation import RelocationSection

# ---- memory map -----------------------------------------------------------
IMAGE_BASE   = 0x00000000    # ELF is mapped at its link-time vaddrs (vaddr 0 based)
IMAGE_SIZE   = 0x00030000
TLS_BASE     = 0x10000000
TLS_SIZE     = 0x00001000
STACK_BASE   = 0x20000000
STACK_SIZE   = 0x00200000
HEAP_BASE    = 0x30000000
HEAP_SIZE    = 0x02000000
STUB_BASE    = 0x50000000
STUB_SIZE    = 0x00010000
HANDLE_BASE  = 0x60000000
HANDLE_SIZE  = 0x00010000
VM_BASE      = 0x70000000
VM_SIZE      = 0x00010000
DATA_BASE    = 0x80000000    # fake libc data (stdio etc.)
DATA_SIZE    = 0x00010000

PAGE = 0x1000
def a2(x): return (x + PAGE - 1) & ~(PAGE - 1)

R_X86_64_64 = 1
R_X86_64_GLOB_DAT = 6
R_X86_64_JUMP_SLOT = 7
R_X86_64_RELATIVE = 8


class Emu:
    def __init__(self, so_path, log=None):
        self.so_path = so_path
        self.log = log or (lambda *a: None)
        self.mu = Uc(UC_ARCH_X86, UC_MODE_64)
        self.stubs = {}       # addr -> name
        self.stub_by_name = {}
        self.imports = {}     # name -> python callable(emu) -> int
        self.heap_ptr = HEAP_BASE
        self.heap_alloc = {}  # addr -> size
        self.load()
        self.setup_memory()
        self.setup_tls()
        self.stubs[STUB_BASE + 0x7800] = '<ret>'
        self.setup_hooks()

    # ---------------- ELF loading ----------------
    def load(self):
        self.f = open(self.so_path, 'rb')
        self.elf = ELFFile(self.f)
        self.image = bytearray()
        self.segments = []
        for seg in self.elf.iter_segments():
            if seg['p_type'] != 'PT_LOAD':
                continue
            self.segments.append(seg)
        self.dynsym = self.elf.get_section_by_name('.dynsym')

    def setup_memory(self):
        mu = self.mu
        mu.mem_map(IMAGE_BASE, a2(IMAGE_SIZE), UC_PROT_ALL)
        # write PT_LOAD contents
        for seg in self.segments:
            off, vaddr = seg['p_offset'], seg['p_vaddr']
            filesz, memsz = seg['p_filesz'], seg['p_memsz']
            self.f.seek(off)
            data = self.f.read(filesz)
            mu.mem_write(vaddr, data)
            if memsz > filesz:
                mu.mem_write(vaddr + filesz, b'\x00' * (memsz - filesz))
        mu.mem_map(TLS_BASE, TLS_SIZE, UC_PROT_ALL)
        mu.mem_map(STACK_BASE, STACK_SIZE, UC_PROT_ALL)
        mu.mem_map(HEAP_BASE, HEAP_SIZE, UC_PROT_ALL)
        mu.mem_map(STUB_BASE, STUB_SIZE, UC_PROT_ALL)
        mu.mem_map(HANDLE_BASE, HANDLE_SIZE, UC_PROT_ALL)
        mu.mem_map(VM_BASE, VM_SIZE, UC_PROT_ALL)
        mu.mem_map(DATA_BASE, DATA_SIZE, UC_PROT_ALL)
        self.apply_relocations()

    def apply_relocations(self):
        mu = self.mu
        # .rela.dyn
        sec = self.elf.get_section_by_name('.rela.dyn')
        for r in sec.iter_relocations():
            t = r['r_info_type']
            off = r['r_offset']; add = r['r_addend']
            if t == R_X86_64_RELATIVE:
                mu.mem_write(off, struct.pack('<Q', add))
            elif t == R_X86_64_GLOB_DAT:
                name = self.dynsym.get_symbol(r['r_info_sym']).name
                addr = self.symbol_addr(name)
                mu.mem_write(off, struct.pack('<Q', addr))
            else:
                raise RuntimeError('unhandled rela.dyn type %d for %s' % (t, r['r_offset']))
        # .rela.plt -> GOT slots patched to our stub trampolines
        sec = self.elf.get_section_by_name('.rela.plt')
        self.plt_names = {}
        for i, r in enumerate(sec.iter_relocations()):
            name = self.dynsym.get_symbol(r['r_info_sym']).name
            self.plt_names[i] = name
            addr = self.stub_addr(name)
            mu.mem_write(r['r_offset'], struct.pack('<Q', addr))
            self.log('reloc %-28s got=0x%x -> 0x%x' % (name, r['r_offset'], addr))

    def symbol_addr(self, name):
        # data symbols we must fabricate
        if name == '__sF':
            return DATA_BASE + 0x1000
        raise RuntimeError('unknown data symbol %s' % name)

    def stub_addr(self, name):
        if name in self.stub_by_name:
            return self.stub_by_name[name]
        idx = len(self.stub_by_name)
        addr = STUB_BASE + idx * 16
        self.stub_by_name[name] = addr
        self.stubs[addr] = name
        return addr

    # ---------------- TLS ----------------
    def setup_tls(self):
        # stack canary lives at fs:0x28
        self.canary = 0x00000badc0ffee00
        self.mu.mem_write(TLS_BASE + 0x28, struct.pack('<Q', self.canary))
        self.mu.reg_write(UC_X86_REG_FS_BASE, TLS_BASE)
        ok = self._fs_read_ok()
        self.log('TLS via FS_BASE: %s' % ('ok' if ok else 'UNSUPPORTED'))
        if not ok:
            self.patch_fs_accesses()

    def _fs_read_ok(self):
        """verify `mov rax, qword ptr fs:[0x28]` works under this Unicorn build"""
        scratch = DATA_BASE + 0x2000
        code = bytes.fromhex('64488b042528000000')   # no `ret`: avoid a bogus jump
        self.mu.mem_write(scratch, code)
        saved_rsp = self.mu.reg_read(UC_X86_REG_RSP)
        self.mu.reg_write(UC_X86_REG_RSP, STACK_BASE + STACK_SIZE // 2)
        try:
            self.mu.emu_start(scratch, scratch + len(code))
        except UcError:
            self.mu.reg_write(UC_X86_REG_RSP, saved_rsp)
            return False
        self.mu.reg_write(UC_X86_REG_RSP, saved_rsp)
        return self.mu.reg_read(UC_X86_REG_RAX) == self.canary

    def _unused_patch_fs_accesses(self):
        """Rewrite  fs:[0x28]  accesses to absolute [CANARY_ABS] so we never need FS.
        Patterns (9 bytes):
          64 48 8b <modrm> 25 28 00 00 00     mov r64, qword ptr fs:[0x28]
          64 48 89 04 25 28 00 00 00          mov qword ptr fs:[0x28], rax
        We cannot change the length (9 bytes) without shifting code, so relocating is
        out of scope: instead we make sure FS works (verified above) and bail out if not.
        """
        raise RuntimeError('Unicorn build does not support FS segment base; cannot emulate safely')

    # ---------------- hooks ----------------
    def setup_hooks(self):
        self.mu.hook_add(UC_HOOK_CODE, self._hook_code)
        self.mu.hook_add(UC_HOOK_MEM_UNMAPPED, self._hook_unmapped)

    def _hook_unmapped(self, uc, access, addr, size, value, ud):
        self.log('!! unmapped %s at 0x%x size %d (rip=0x%x)' % (access, addr, size, uc.reg_read(UC_X86_REG_RIP)))
        return False

    def _unimpl_idx(self, addr):
        tbl, obj = self.env_tbl, self.env_obj
        for i in range(250):
            if self.rd8(tbl + i * 8) == addr:
                if obj == self.env_obj:
                    return 'env[%d]' % i
        for i in range(8):
            if self.rd8(self.vm_tbl + i * 8) == addr:
                return 'vm[%d]' % i
        return '?'

    def _hook_code(self, uc, addr, size, ud):
        if STUB_BASE <= addr < STUB_BASE + STUB_SIZE:
            name = self.stubs.get(addr)
            if name is None:
                raise RuntimeError('execution wandered into uninstrumented stub page at 0x%x '
                                   '(caller rip=0x%x, rsp=0x%x)' %
                                   (addr, self.rd8(self.mu.reg_read(UC_X86_REG_RSP)),
                                    self.mu.reg_read(UC_X86_REG_RSP)))
            self.dispatch(addr)

    def dispatch(self, addr):
        name = self.stubs[addr]
        if name.startswith('<jni:'):
            return self._jni[int(name[5:-1])](self)
        if name.startswith('<jnivm:'):
            return self._jni_vm[int(name[7:-1])](self)
        if name == '<ret>':
            raise _ReturnSentinel()
        if name.startswith('<jni-unimpl'):
            raise RuntimeError('JNI env[%s] not implemented (caller rip=0x%x)' %
                               (name.split(':')[1][:-1],
                                self.rd8(self.mu.reg_read(UC_X86_REG_RSP))))
        if name.startswith('<jnivm-unimpl'):
            raise RuntimeError('JNI vm[%s] not implemented (caller rip=0x%x)' %
                               (name.split(':')[1][:-1],
                                self.rd8(self.mu.reg_read(UC_X86_REG_RSP))))
        fn = getattr(self, 'imp_' + name.replace('__', 'x_').replace('.', '_'), None)
        if fn is None:
            fn = self.imports.get(name)
        if fn is None:
            raise RuntimeError('no implementation for import %s (called from rip=0x%x)' %
                               (name, self.mu.reg_read(UC_X86_REG_RIP)))
        fn(self)

    # ---- helpers ----
    def rd(self, a, n):  return bytes(self.mu.mem_read(a, n))
    def rd8(self, a):    return struct.unpack('<Q', self.rd(a, 8))[0]
    def rd4(self, a):    return struct.unpack('<I', self.rd(a, 4))[0]
    def wr(self, a, b):  self.mu.mem_write(a, bytes(b))
    def wr8(self, a, v): self.wr(a, struct.pack('<Q', v & 0xFFFFFFFFFFFFFFFF))
    def ret(self, v):
        """pop return address and resume with rax = v"""
        mu = self.mu
        sp = mu.reg_read(UC_X86_REG_RSP)
        ra = struct.unpack('<Q', bytes(mu.mem_read(sp, 8)))[0]
        mu.reg_write(UC_X86_REG_RSP, sp + 8)
        mu.reg_write(UC_X86_REG_RIP, ra)
        if v is not None:
            mu.reg_write(UC_X86_REG_RAX, v & 0xFFFFFFFFFFFFFFFF)
    def alloc(self, n, align=16):
        n = max(n, 1)
        p = (self.heap_ptr + align - 1) & ~(align - 1)
        need = a2(p + n)
        if need - HEAP_BASE > HEAP_SIZE:
            raise RuntimeError('heap exhausted')
        self.heap_ptr = p + n
        self.heap_alloc[p] = n
        return p

    # ================= JNI scaffolding =================
    # Real JNI function table (JNINativeInterface_ / JNIInvokeInterface_) indices.
    # Android ART uses the standard layout; the code calls through (*(env))[idx].
    def build_jni(self):
        self.jni_handles = {}      # handle id -> python object
        self.jni_next = 1
        self.class_name = b'org/mewx/wenku8/api/internal/NativeEnvelopeBridge\x00'
        self.class_name_addr = self.alloc(len(self.class_name))
        self.wr(self.class_name_addr, self.class_name)

        # JNIEnv table: 250 slots, all pointing at a `jni_unimpl` trap
        self.env_tbl = VM_BASE + 0x1000
        self.vm_tbl  = VM_BASE + 0x3000
        self.env_obj = VM_BASE + 0x5000
        self.vm_obj  = VM_BASE + 0x5010
        self.wr8(self.env_obj, self.env_tbl)    # *env  == table ptr
        self.wr8(self.vm_obj,  self.vm_tbl)
        for i in range(250):
            a = STUB_BASE + 0x0800 + i * 8
            self.stubs[a] = '<jni-unimpl:%d>' % i
            self.wr8(self.env_tbl + i * 8, a)
        for i in range(8):
            a = STUB_BASE + 0x1800 + i * 8
            self.stubs[a] = '<jnivm-unimpl:%d>' % i
            self.wr8(self.vm_tbl + i * 8, a)
        self._jni = {}
        self._jni_vm = {}
        self.install_jni()
        for idx, fn in self._jni.items():
            self.wr8(self.env_tbl + idx * 8, self.jni_stub(idx))
        for idx, fn in self._jni_vm.items():
            self.wr8(self.vm_tbl + idx * 8, self.jni_vm_stub(idx))

    def jni_stub(self, idx):
        a = STUB_BASE + 0x2000 + idx * 8
        if a not in self.stubs:
            self.stubs[a] = '<jni:%d>' % idx
        return a

    def jni_vm_stub(self, idx):
        a = STUB_BASE + 0x4000 + idx * 8
        if a not in self.stubs:
            self.stubs[a] = '<jnivm:%d>' % idx
        return a

    def new_handle(self, obj):
        h = self.jni_next
        self.jni_next += 1
        self.jni_handles[h] = obj
        return HANDLE_BASE + h

    def get_handle(self, h):
        return self.jni_handles.get(h - HANDLE_BASE)

    def install_jni(self):
        """Standard JNINativeInterface_ / JNIInvokeInterface_ table.

        Verified call sites in libmewx.so:
          env[17]  (+0x88)  ExceptionClear          (return ignored)
          env[171] (+0x558) GetArrayLength
          env[176] (+0x580) NewByteArray
          env[200] (+0x640) GetByteArrayRegion(env,arr,start,len,buf)
          env[208] (+0x680) SetByteArrayRegion(env,arr,start,len,buf)
          env[215] (+0x6b8) RegisterNatives
          env[228] (+0x720) ExceptionCheck          (boolean)
          vm[6]    (+0x30)  GetEnv(JavaVM*, void**penv, jint version)
        """
        def cstr_arg(emu, reg):
            return cstr(emu, emu.mu.reg_read(reg))

        # ---------------- JavaVM ----------------
        def vm_GetEnv(emu):
            envp = emu.mu.reg_read(UC_X86_REG_RSI)
            emu.wr8(envp, emu.env_obj)
            emu.ret(0)                      # JNI_OK
        def vm_Attach(emu):
            envp = emu.mu.reg_read(UC_X86_REG_RSI)
            emu.wr8(envp, emu.env_obj)
            emu.ret(0)

        # ---------------- JNIEnv ----------------
        def env_GetVersion(emu):        emu.ret(0x00010006)
        def env_FindClass(emu):
            nm = cstr_arg(emu, UC_X86_REG_RSI)
            emu.log('FindClass(%r)' % nm)
            emu.ret(emu.new_handle(('class', nm)))
        def env_ExceptionOccurred(emu): emu.ret(0)
        def env_ExceptionClear(emu):    emu.ret(None)
        def env_ExceptionDescribe(emu): emu.ret(None)
        def env_ExceptionCheck(emu):    emu.ret(0)
        def env_GetJavaVM(emu):
            emu.wr8(emu.mu.reg_read(UC_X86_REG_RSI), emu.vm_obj)
            emu.ret(0)
        def env_RegisterNatives(emu):
            cls = emu.mu.reg_read(UC_X86_REG_RSI)
            methods = emu.mu.reg_read(UC_X86_REG_RDX)
            n = emu.mu.reg_read(UC_X86_REG_RCX)
            emu.log('RegisterNatives class=%r count=%d' % (emu.get_handle(cls), n))
            reg = {}
            for i in range(n):
                base = methods + i * 24
                nm = cstr(emu, emu.rd8(base))
                sg = cstr(emu, emu.rd8(base + 8))
                fn = emu.rd8(base + 16)
                emu.log('  native[%d] %-3r %-52r -> 0x%x' % (i, nm, sg, fn))
                reg[nm] = fn
            emu.natives = reg
            emu.ret(0)
        def env_GetArrayLength(emu):
            h = emu.get_handle(emu.mu.reg_read(UC_X86_REG_RSI))
            emu.ret(len(h) if isinstance(h, bytearray) else 0)
        def env_NewByteArray(emu):
            n = emu.mu.reg_read(UC_X86_REG_RSI)
            emu.ret(emu.new_handle(bytearray(n)))
        def env_GetByteArrayRegion(emu):
            arr = emu.mu.reg_read(UC_X86_REG_RSI)
            start = emu.mu.reg_read(UC_X86_REG_RDX)
            ln = emu.mu.reg_read(UC_X86_REG_RCX)
            dst = emu.mu.reg_read(UC_X86_REG_R8)
            h = emu.get_handle(arr) or b''
            emu.wr(dst, bytes(h[start:start + ln]))
            emu.ret(None)
        def env_SetByteArrayRegion(emu):
            arr = emu.mu.reg_read(UC_X86_REG_RSI)
            start = emu.mu.reg_read(UC_X86_REG_RDX)
            ln = emu.mu.reg_read(UC_X86_REG_RCX)
            src = emu.mu.reg_read(UC_X86_REG_R8)
            h = emu.get_handle(arr)
            if isinstance(h, bytearray):
                h[start:start + ln] = emu.rd(src, ln)
            emu.log('  SetByteArrayRegion(len=%d) first=%s' %
                    (ln, emu.rd(src, min(ln, 16)).hex()))
            emu.ret(None)
        def env_NewStringUTF(emu):
            emu.ret(emu.new_handle(('str', cstr_arg(emu, UC_X86_REG_RSI))))
        def env_GetStringUTFChars(emu):
            s = emu.get_handle(emu.mu.reg_read(UC_X86_REG_RSI))
            txt = (s[1] if isinstance(s, tuple) else b'') + b'\0'
            p = emu.alloc(len(txt)); emu.wr(p, txt); emu.ret(p)
        def env_CallObjectMethodV(emu):
            cls = emu.mu.reg_read(UC_X86_REG_RSI)
            mid = emu.mu.reg_read(UC_X86_REG_RDX)
            emu.log('CallObjectMethod(%r)' % (emu.get_handle(mid),))
            emu.ret(0)
        def env_GetMethodID(emu):
            cls = emu.mu.reg_read(UC_X86_REG_RSI)
            nm = cstr_arg(emu, UC_X86_REG_RDX)
            sg = cstr_arg(emu, UC_X86_REG_RCX)
            emu.log('GetMethodID(%r, %r)' % (nm, sg))
            emu.ret(emu.new_handle(('method', nm, sg)))
        def env_GetObjectClass(emu):
            emu.ret(emu.mu.reg_read(UC_X86_REG_RSI))
        def env_NewGlobalRef(emu):
            emu.ret(emu.mu.reg_read(UC_X86_REG_RSI))
        def env_NewLocalRef(emu):
            emu.ret(emu.mu.reg_read(UC_X86_REG_RSI))
        def env_IsSameObject(emu):
            emu.ret(int(emu.mu.reg_read(UC_X86_REG_RSI) == emu.mu.reg_read(UC_X86_REG_RDX)))
        def env_noop_int(emu):   emu.ret(0)
        def env_noop(emu):       emu.ret(None)
        def env_ThrowNew(emu):
            nm = emu.mu.reg_read(UC_X86_REG_RDX)
            emu.log('ThrowNew(%s)' % (cstr(emu, nm) if nm else b'<null>'))
            emu.ret(0)

        for idx, fn in {
            4: env_GetVersion,
            6: env_FindClass,
            15: env_ExceptionOccurred,
            17: env_ExceptionClear,
            16: env_ExceptionDescribe,
            171: env_GetArrayLength,   # +0x558  GetArrayLength
            176: env_NewByteArray,     # +0x580  NewByteArray
            167: env_NewStringUTF,
            169: env_GetStringUTFChars,
            170: env_noop,            # +0x550  ReleaseStringUTFChars
            200: env_GetByteArrayRegion,
            208: env_SetByteArrayRegion,
            215: env_RegisterNatives,
            219: env_GetJavaVM,       # +0x6d8  GetJavaVM
            228: env_ExceptionCheck,  # +0x720  ExceptionCheck
            14: env_ThrowNew,
            19: env_noop_int,     # PushLocalFrame
            20: env_noop,         # PopLocalFrame
            21: env_NewGlobalRef,
            22: env_noop,         # DeleteGlobalRef
            23: env_noop,         # DeleteLocalRef
            24: env_IsSameObject,
            25: env_NewLocalRef,
            26: env_noop_int,     # EnsureLocalCapacity
            31: env_GetObjectClass,   # +0xf8   GetObjectClass
            35: env_CallObjectMethodV,  # +0x118 CallObjectMethodV
            34: env_CallObjectMethodV,  # +0x110 CallObjectMethod
            38: env_CallObjectMethodV,  # +0x130 CallVoidMethodV
            33: env_GetMethodID,      # +0x108  GetMethodID
            163: env_noop_int,    # GetStringLength
            164: env_noop,        # GetStringChars
            165: env_noop,        # ReleaseStringChars
            168: env_noop_int,    # GetStringUTFLength
        }.items():
            self._jni[idx] = fn
        for idx, fn in {4: vm_Attach, 6: vm_GetEnv, 7: vm_Attach}.items():
            self._jni_vm[idx] = fn

    # ================= libc / libandroid imports =================
    def install_libc(self, lut_path):
        self.lut = open(lut_path, 'rb').read()
        I = self.imports
        def imp(name):
            def deco(f):
                I[name] = f
                return f
            return deco
        # --- memory ---
        @imp('malloc')
        def _(emu):
            n = emu.mu.reg_read(UC_X86_REG_RDI)
            emu.ret(emu.alloc(n))
        @imp('free')
        def _(emu): emu.ret(None)
        @imp('realloc')
        def _(emu):
            p = emu.mu.reg_read(UC_X86_REG_RDI); n = emu.mu.reg_read(UC_X86_REG_RSI)
            old = emu.heap_alloc.get(p, 0)
            q = emu.alloc(n)
            if p and old:
                emu.wr(q, emu.rd(p, min(old, n)))
            emu.ret(q)
        @imp('posix_memalign')
        def _(emu):
            pp = emu.mu.reg_read(UC_X86_REG_RDI)
            al = emu.mu.reg_read(UC_X86_REG_RSI)
            n = emu.mu.reg_read(UC_X86_REG_RDX)
            emu.wr8(pp, emu.alloc(n, align=max(al, 16)))
            emu.ret(0)
        @imp('memcpy')
        def _(emu):
            d, s, n = (emu.mu.reg_read(r) for r in (UC_X86_REG_RDI, UC_X86_REG_RSI, UC_X86_REG_RDX))
            if n: emu.wr(d, emu.rd(s, n))
            emu.ret(d)
        @imp('__memcpy_chk')
        def _(emu):
            d, s, n = (emu.mu.reg_read(r) for r in (UC_X86_REG_RDI, UC_X86_REG_RSI, UC_X86_REG_RDX))
            if n: emu.wr(d, emu.rd(s, n))
            emu.ret(d)
        @imp('memmove')
        def _(emu):
            d, s, n = (emu.mu.reg_read(r) for r in (UC_X86_REG_RDI, UC_X86_REG_RSI, UC_X86_REG_RDX))
            b = emu.rd(s, n) if n else b''
            if n: emu.wr(d, b)
            emu.ret(d)
        @imp('memset')
        def _(emu):
            d = emu.mu.reg_read(UC_X86_REG_RDI); c = emu.mu.reg_read(UC_X86_REG_RSI) & 0xff
            n = emu.mu.reg_read(UC_X86_REG_RDX)
            if n: emu.wr(d, bytes([c]) * n)
            emu.ret(d)
        @imp('memcmp')
        def _(emu):
            a, b, n = (emu.mu.reg_read(r) for r in (UC_X86_REG_RDI, UC_X86_REG_RSI, UC_X86_REG_RDX))
            x, y = emu.rd(a, n), emu.rd(b, n)
            emu.ret(0 if x == y else (1 if x > y else -1))
        @imp('memchr')
        def _(emu):
            p = emu.mu.reg_read(UC_X86_REG_RDI); c = emu.mu.reg_read(UC_X86_REG_RSI) & 0xff
            n = emu.mu.reg_read(UC_X86_REG_RDX)
            i = emu.rd(p, n).find(bytes([c]))
            emu.ret(p + i if i >= 0 else 0)
        @imp('strlen')
        def _(emu):
            emu.ret(len(cstr(emu, emu.mu.reg_read(UC_X86_REG_RDI))))
        @imp('strcmp')
        def _(emu):
            a = cstr(emu, emu.mu.reg_read(UC_X86_REG_RDI)); b = cstr(emu, emu.mu.reg_read(UC_X86_REG_RSI))
            emu.ret(0 if a == b else (1 if a > b else -1))
        @imp('__stack_chk_fail')
        def _(emu):
            emu.log('!!! __stack_chk_fail')
            raise RuntimeError('stack canary check failed')
        @imp('abort')
        def _(emu):
            raise RuntimeError('abort() called from rip=0x%x' % emu.mu.reg_read(UC_X86_REG_RIP))
        @imp('__cxa_atexit')
        def _(emu): emu.ret(0)
        @imp('__cxa_finalize')
        def _(emu): emu.ret(None)
        @imp('android_set_abort_message')
        def _(emu): emu.ret(None)
        @imp('__errno')
        def _(emu): emu.ret(DATA_BASE + 0x100)
        @imp('strerror_r')
        def _(emu):
            buf = emu.mu.reg_read(UC_X86_REG_RDI); n = emu.mu.reg_read(UC_X86_REG_RSI)
            msg = b'error\0'
            emu.wr(buf, msg[:max(n, 1)])
            emu.ret(0)
        @imp('snprintf')
        def _(emu):
            buf = emu.mu.reg_read(UC_X86_REG_RDI); n = emu.mu.reg_read(UC_X86_REG_RSI)
            fmt = cstr(emu, emu.mu.reg_read(UC_X86_REG_RDX))
            out = b'fmt:' + fmt
            emu.wr(buf, out[:max(n - 1, 0)] + b'\0')
            emu.ret(len(out))
        @imp('clock_gettime')
        def _(emu):
            tp = emu.mu.reg_read(UC_X86_REG_RSI)
            emu.wr(tp, struct.pack('<qq', 1700000000, 0))
            emu.ret(0)
        @imp('getauxval')
        def _(emu): emu.ret(0)
        @imp('__system_property_get')
        def _(emu):
            emu.wr(emu.mu.reg_read(UC_X86_REG_RSI), b'\0')
            emu.ret(0)
        @imp('syscall')
        def _(emu): emu.ret(-1)
        # --- real-ish file I/O (the code opens /dev/urandom, /proc/self/*) ---
        self.fds = {}
        self.fd_next = 3
        self.urandom = bytearray(bytes(range(256)) * 8)   # deterministic source

        @imp('__open_2')
        def _(emu):
            p = cstr(emu, emu.mu.reg_read(UC_X86_REG_RDI))
            fd = emu.fd_next
            emu.fd_next += 1
            emu.fds[fd] = (p, emu.file_bytes(p))
            emu.log('open(%r) -> %d' % (p, fd))
            emu.ret(fd)

        @imp('read')
        def _(emu):
            fd = emu.mu.reg_read(UC_X86_REG_RDI)
            buf = emu.mu.reg_read(UC_X86_REG_RSI)
            n = emu.mu.reg_read(UC_X86_REG_RDX)
            st = emu.fds.get(fd)
            if st is None:
                emu.ret(-1); return
            path, remaining = st
            chunk = remaining[:n]
            emu.fds[fd] = (path, remaining[n:])
            if chunk:
                emu.wr(buf, chunk)
            emu.ret(len(chunk))

        @imp('close')
        def _(emu):
            emu.fds.pop(emu.mu.reg_read(UC_X86_REG_RDI), None)
            emu.ret(0)

        for nm in ('fstat', 'pread', 'lseek', 'mmap', 'munmap', 'openat'):
            I[nm] = (lambda e, _n=nm: e.ret(-1))
        I['__pread_chk'] = lambda e: e.ret(-1)
        I['__read_chk'] = I['read']
        # --- stdio ---
        for nm in ('fprintf', 'vfprintf', 'printf', 'fwrite', 'fputc', 'fflush',
                   'fclose', 'vasprintf', 'openlog', 'syslog', 'closelog',
                   'pthread_mutex_destroy', 'pthread_mutex_lock', 'pthread_mutex_unlock',
                   'pthread_rwlock_rdlock', 'pthread_rwlock_wrlock', 'pthread_rwlock_unlock',
                   'pthread_key_delete', 'pthread_setspecific', 'pthread_once',
                   'dl_iterate_phdr', 'pthread_mutex_init', 'pthread_mutexattr_init',
                   'pthread_mutexattr_settype', 'pthread_mutexattr_destroy',
                   'pthread_cond_wait', 'pthread_cond_broadcast', 'pthread_cond_init',
                   'pthread_cond_destroy', 'pthread_cond_signal'):
            I[nm] = (lambda e, _n=nm: e.ret(0))
        @imp('pthread_getspecific')
        def _(emu): emu.ret(0)
        @imp('pthread_key_create')
        def _(emu):
            emu.wr4(emu.mu.reg_read(UC_X86_REG_RDI), 1)
            emu.ret(0)
        # --- Android assets ---
        @imp('AAssetManager_fromJava')
        def _(emu): emu.ret(0xA55E7000)
        @imp('AAssetManager_open')
        def _(emu):
            path = cstr(emu, emu.mu.reg_read(UC_X86_REG_RSI))
            emu.log('AAssetManager_open(%r)' % path)
            emu.ret(0xA55E7001)
        @imp('AAsset_getLength')
        def _(emu): emu.ret(len(emu.lut))
        @imp('AAsset_read')
        def _(emu):
            buf = emu.mu.reg_read(UC_X86_REG_RSI)
            ln = emu.mu.reg_read(UC_X86_REG_RDX)
            off = emu.mu.reg_read(UC_X86_REG_RCX)
            off = 0 if off > 0x7FFFFFFF else off
            chunk = emu.lut[off:off + ln]
            if chunk:
                emu.wr(buf, chunk)
            emu.ret(len(chunk))
        @imp('AAsset_close')
        def _(emu): emu.ret(None)

    def file_bytes(self, path):
        if path == b'/dev/urandom':
            return bytes(self.urandom)
        if path == b'/proc/self/cmdline':
            return b'org.mewx.wenku8\0'
        if path == b'/proc/self/maps':
            return b'\n'
        return b''

    def wr4(self, a, v): self.wr(a, struct.pack('<I', v & 0xFFFFFFFF))

    def jni_call(self, fn_addr, *args, name='jni'):
        """invoke a raw function pointer with given integer/pointer args until it returns"""
        mu = self.mu
        sp = STACK_BASE + STACK_SIZE // 2
        sp -= 8
        mu.mem_write(sp, struct.pack('<Q', 0))  # return to 0? use sentinel instead
        raise RuntimeError('unused')


def cstr(emu, a, maxn=4096):
    if not a: return b''
    out = bytearray()
    for i in range(maxn):
        b = emu.rd(a + i, 1)
        if b == b'\0': break
        out += b
    return bytes(out)


class _ReturnSentinel(Exception):
    pass


class Runner:
    """Drives JNI_OnLoad and the registered natives."""
    def __init__(self, so_path, lut_path, log=None, verbose=False):
        self.verbose = verbose
        self.log_lines = []
        def _log(msg):
            self.log_lines.append(str(msg))
            if verbose: print(msg, file=sys.stderr)
        self.emu = Emu(so_path, log=_log)
        self.emu.build_jni()
        self.emu.install_libc(lut_path)
        self.emu.natives = {}
        self._stack_depth = []
        self.env = self.emu.env_obj
        self.vm = self.emu.vm_obj

    def call(self, fn_addr, args, timeout=0):
        """Call a native function with SysV args; returns eax/rax."""
        emu = self.emu
        mu = emu.mu
        base = STACK_BASE + STACK_SIZE - 0x20000
        # fresh stack each call, keep locals away from the callee's frame
        sp = base - 0x40 * (len(self._stack_depth) + 1)
        self._stack_depth.append(1)
        try:
            sp -= 8
            mu.mem_write(sp, struct.pack('<Q', STUB_BASE + 0x7800))
            ARG_REGS = (UC_X86_REG_RDI, UC_X86_REG_RSI, UC_X86_REG_RDX,
                        UC_X86_REG_RCX, UC_X86_REG_R8, UC_X86_REG_R9)
            for i, a in enumerate(args[:6]):
                mu.reg_write(ARG_REGS[i], a)
            for i, a in enumerate(args[6:]):     # extra args go on the stack
                mu.mem_write(sp + 8 + i * 8, struct.pack('<Q', a & 0xFFFFFFFFFFFFFFFF))
            mu.reg_write(UC_X86_REG_RSP, sp)
            mu.reg_write(UC_X86_REG_RBP, 0)
            try:
                mu.emu_start(fn_addr, 0, count=timeout)
            except _ReturnSentinel:
                pass
            except UcError as e:
                raise RuntimeError('emulation failed at rip=0x%x: %s' %
                                   (mu.reg_read(UC_X86_REG_RIP), e))
            return mu.reg_read(UC_X86_REG_RAX)
        finally:
            self._stack_depth.pop()

    def onload(self):
        emu = self.emu
        try:
            r = self.call(0xe440, [emu.vm_obj, 0])
        except RuntimeError as e:
            raise
        return r
