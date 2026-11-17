#!/usr/bin/env python3
"""对拍辅助：看一小块区域里新旧两张图到底差在哪。
用法：peek.py 旧.png 新.png x0 y0 x1 y1 [crop前缀]（单位 pt）
打印这一块里不同像素的个数、差值分布、前几个不同像素的新旧颜色；给了前缀就把两块各放大 4 倍存成 PNG。"""
import sys
from collections import Counter
from PIL import Image

SCALE = 3
old = Image.open(sys.argv[1]).convert("RGB")
new = Image.open(sys.argv[2]).convert("RGB")
box = tuple(int(float(value) * SCALE) for value in sys.argv[3:7])
a, b = old.crop(box), new.crop(box)
pa, pb = a.load(), b.load()
deltas, samples, total = Counter(), [], 0
for y in range(a.size[1]):
    for x in range(a.size[0]):
        if pa[x, y] != pb[x, y]:
            total += 1
            delta = max(abs(i - j) for i, j in zip(pa[x, y], pb[x, y]))
            deltas[min(delta // 8 * 8, 64)] += 1
            if len(samples) < 12:
                samples.append(((box[0] + x) / SCALE, (box[1] + y) / SCALE, pa[x, y], pb[x, y]))
print(f"{a.size[0]}x{a.size[1]} 像素里不同 {total} 个；差值分布（按 8 分档）{sorted(deltas.items())}")
for x, y, p, q in samples:
    print(f"  ({x:.2f}, {y:.2f}) 旧 {p} 新 {q}")
if len(sys.argv) > 7:
    for name, image in (("old", a), ("new", b)):
        image.resize((image.size[0] * 4, image.size[1] * 4), Image.NEAREST).save(f"{sys.argv[7]}-{name}.png")
