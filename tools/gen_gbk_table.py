import os, struct, sys

def build(output):
    rows = 0xFE - 0x81 + 1
    cols = 190
    table = [0] * (rows * cols)
    for lead in range(0x81, 0xFF):
        for trail in range(0x40, 0xFF):
            if trail == 0x7F:
                continue
            idx = (lead - 0x81) * cols + (trail - 0x40 if trail < 0x7F else trail - 0x41)
            try:
                ch = bytes([lead, trail]).decode('gbk')
            except Exception:
                continue
            if len(ch) != 1:
                continue
            cp = ord(ch)
            if cp > 0xFFFF:
                continue
            table[idx] = cp
    os.makedirs(os.path.dirname(output) or ".", exist_ok=True)
    with open(output, 'wb') as f:
        f.write(struct.pack('<%dH' % len(table), *table))
    print(f"{output}: total={len(table)} mapped={sum(1 for v in table if v)}")

if __name__ == "__main__":
    build(sys.argv[1])
