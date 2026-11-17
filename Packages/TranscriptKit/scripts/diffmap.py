import sys, struct, zlib, collections

# 纯标准库读 8 位 RGB(A) PNG，输出两张图不同像素的分布：按 50pt（150px）一格的网格计数
def read_png(path):
    data = open(path, 'rb').read()
    assert data[:8] == b'\x89PNG\r\n\x1a\n'
    pos, chunks, ihdr = 8, [], None
    while pos < len(data):
        length, kind = struct.unpack('>I4s', data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + length]
        if kind == b'IHDR': ihdr = struct.unpack('>IIBBBBB', body)
        if kind == b'IDAT': chunks.append(body)
        pos += 12 + length
    w, h, depth, ctype, _, _, _ = ihdr
    assert depth in (8, 16), depth
    channels = {2: 3, 6: 4, 0: 1, 4: 2}[ctype]
    bpc = depth // 8
    bpp = channels * bpc
    raw = zlib.decompress(b''.join(chunks))
    stride = w * bpp
    rows, prev = [], bytearray(stride)
    i = 0
    for _ in range(h):
        f = raw[i]; line = bytearray(raw[i + 1:i + 1 + stride]); i += 1 + stride
        if f == 1:
            for x in range(bpp, stride): line[x] = (line[x] + line[x - bpp]) & 255
        elif f == 2:
            for x in range(stride): line[x] = (line[x] + prev[x]) & 255
        elif f == 3:
            for x in range(stride):
                a = line[x - bpp] if x >= bpp else 0
                line[x] = (line[x] + ((a + prev[x]) >> 1)) & 255
        elif f == 4:
            for x in range(stride):
                a = line[x - bpp] if x >= bpp else 0
                b = prev[x]; c = prev[x - bpp] if x >= bpp else 0
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pr = a if pa <= pb and pa <= pc else (b if pb <= pc else c)
                line[x] = (line[x] + pr) & 255
        rows.append(line); prev = line
    return w, h, bpp, bpc, rows

a = read_png(sys.argv[1]); b = read_png(sys.argv[2])
assert a[:4] == b[:4], (a[:4], b[:4])
w, h, bpp, bpc, ra = a; rb = b[4]
grid = collections.Counter(); total = 0; maxd = 0
for y in range(h):
    la, lb = ra[y], rb[y]
    if la == lb: continue
    for x in range(w):
        o = x * bpp
        if la[o:o + bpp] != lb[o:o + bpp]:
            total += 1
            d = max(abs(la[o + k] - lb[o + k]) for k in range(0, bpp, bpc))
            maxd = max(maxd, d)
            grid[(y // 150, x // 150)] += 1
print(f'{w}x{h} bpp={bpp} 不同像素 {total} 最大差 {maxd}')
for (gy, gx), n in sorted(grid.items()):
    print(f'  y {gy*50:>4}–{gy*50+50}pt  x {gx*50:>4}–{gx*50+50}pt : {n}')
