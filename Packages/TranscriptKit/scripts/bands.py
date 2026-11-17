#!/usr/bin/env python3
"""对拍辅助：列出两张截图里「有内容的横带」，一眼看出哪一行高度 / 位置对不上。
用法：bands.py 旧.png 新.png [起始pt 结束pt]（默认只看 200–734pt，避开顶栏和输入条）
每条横带打印：y 起止（pt）、高、内容的 x 起止（pt）。两张图并排，差值在最右。"""
import sys
from PIL import Image

SCALE = 3


def bands(path, top, bottom):
    image = Image.open(path).convert("RGB")
    width, _ = image.size
    pixels = image.load()
    result, start, left, right = [], None, width, 0
    for y in range(int(top * SCALE), int(bottom * SCALE)):
        background = pixels[2, y]
        xs = [x for x in range(width) if max(abs(a - b) for a, b in zip(pixels[x, y], background)) > 3]
        if xs:
            if start is None:
                start, left, right = y, width, 0
            left, right = min(left, xs[0]), max(right, xs[-1])
        elif start is not None:
            result.append((start, y, left, right + 1))
            start = None
    if start is not None:
        result.append((start, int(bottom * SCALE), left, right + 1))
    return result


def show(band):
    y0, y1, x0, x1 = (value / SCALE for value in band)
    return f"y {y0:7.2f}–{y1:7.2f} 高 {y1 - y0:6.2f}  x {x0:6.2f}–{x1:6.2f}"


old_path, new_path = sys.argv[1], sys.argv[2]
top = float(sys.argv[3]) if len(sys.argv) > 3 else 200
bottom = float(sys.argv[4]) if len(sys.argv) > 4 else 734
old, new = bands(old_path, top, bottom), bands(new_path, top, bottom)
for index in range(max(len(old), len(new))):
    a = old[index] if index < len(old) else None
    b = new[index] if index < len(new) else None
    delta = ""
    if a and b:
        delta = "  Δy %+.2f Δ高 %+.2f Δx %+.2f/%+.2f" % tuple((b[i] - a[i]) / SCALE for i in (0, 1, 2, 3))
        delta = "  Δy %+.2f  Δ底 %+.2f  Δ左 %+.2f  Δ右 %+.2f" % (
            (b[0] - a[0]) / SCALE, (b[1] - a[1]) / SCALE, (b[2] - a[2]) / SCALE, (b[3] - a[3]) / SCALE)
    print(f"旧 {show(a) if a else '—':<52} | 新 {show(b) if b else '—':<52}{delta}")
