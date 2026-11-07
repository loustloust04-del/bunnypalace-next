#!/usr/bin/env python3
"""S7：原始3x截图与真实窗口PNG对拍；图片和测量输出只放媒体目录。

运行：python3 -I scripts/compare-imessage.py --root ~/MemoryPalace-docs-media/docs/imessage-ref
依赖Pillow、numpy。OCR仅定位采样区域，框和轮廓重新从原始像素量取。
"""
import argparse
import hashlib
import json
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw


def bounds(mask):
    yy, xx = np.nonzero(mask)
    if not len(xx):
        raise ValueError("采样区域没有可辨轮廓，不能用预期值代替测量")
    return [int(xx.min()), int(yy.min()), int(xx.max()) + 1, int(yy.max()) + 1]


def silhouette(image, roi, background, fill, seed=None):
    x, y, X, Y = roi
    crop = image[y:Y, x:X]
    direction = background - fill
    coverage = ((background - crop) * direction).sum(axis=2) / (direction * direction).sum(axis=-1)
    mask = coverage >= 0.5
    if seed is not None:
        sx, sy = seed[0] - x, seed[1] - y
        if not mask[sy, sx]:
            raise ValueError(f"种子{seed}不在实测填充内")
        component = Image.fromarray(mask.astype(np.uint8)).copy()
        ImageDraw.floodfill(component, (sx, sy), 2)
        mask = np.asarray(component) == 2
    L, T, R, B = bounds(mask)
    center = (L + R) // 2
    body_bottom = int(np.flatnonzero(np.any(mask[:, center - 3:center + 3], axis=1))[-1]) + 1
    mid = np.flatnonzero(mask[(T + body_bottom) // 2])
    body_left, body_right = int(mid[0]), int(mid[-1]) + 1
    body = [body_left + x, T + y, body_right + x, body_bottom + y]
    contour = []
    for row in range(T, B):
        xs = np.flatnonzero(mask[row])
        if len(xs):
            contour.append([row + y, int(xs[0]) + x, int(xs[-1]) + 1 + x])
    edges = [(row + 0.5 - T, np.flatnonzero(mask[row])[0] - body_left)
             for row in range(T + 2, min(T + 75, (T + body_bottom) // 2 - 2))]
    fits = []
    for radius in np.arange(40, 76.01, 0.1):
        errors = [(radius - np.sqrt(max(0, radius * radius - (dy - radius) ** 2))
                   if dy < radius else 0) - observed for dy, observed in edges]
        fits.append((float(np.mean(np.square(errors))), float(radius)))
    mse, radius = min(fits)
    return {"body": body, "silhouette": [L + x, T + y, R + x, B + y],
            "radius_px": radius, "radius_fit_rms_px": mse ** 0.5,
            "tail_down_px": B - body_bottom,
            "tail_outside_px": max(0, body_left - L, R - body_right),
            "fill": np.asarray(fill).tolist(), "contour": contour}


def own_bubble(image, text, full_height=False):
    (x, y), (w, h) = text["frame"]
    px, py = int(x * 3), int(y * 3)
    top = 0 if full_height else max(0, py - 65)
    bottom = image.shape[0] if full_height else min(image.shape[0], int((y + h) * 3) + 85)
    fill = np.median(image[py - 16:py - 13, int((x + w / 2) * 3) - 2:int((x + w / 2) * 3) + 3], axis=(0, 1))
    background = np.median(image[top:bottom, :30], axis=1)[:, None, :]
    return silhouette(image, (0, top, image.shape[1], bottom), background, fill,
                      (px - 15, int((y + h / 2) * 3)))


def edge(image, axis, fixed, lo, hi):
    pixels = (np.median(image[fixed - 1:fixed + 2, lo:hi], axis=0) if axis == "x"
              else np.median(image[lo:hi, fixed - 1:fixed + 2], axis=1))
    return lo + int(np.argmax(np.linalg.norm(np.diff(pixels, axis=0), axis=1))) + 1


def control(image, cx, cy, bands):
    L, T, R, B = bands
    return [edge(image, "x", cy, *L), edge(image, "y", cx, *T),
            edge(image, "x", cy, *R), edge(image, "y", cx, *B)]


def ink(image, roi, dark):
    x, y, X, Y = roi
    crop = image[y:Y, x:X]
    luminance = crop.mean(axis=2)
    background = np.median(crop.reshape(-1, 3), axis=0)
    q = np.quantile(luminance, 0.99 if dark else 0.01)
    foreground = np.median(crop[luminance >= q if dark else luminance <= q], axis=0)
    direction = foreground - background
    mask = ((crop - background) * direction).sum(axis=2) / (direction * direction).sum() >= 0.5
    b = bounds(mask)
    return [b[0] + x, b[1] + y, b[2] + x, b[3] + y]


def text_roi(text):
    (x, y), (w, h) = text["frame"]
    return (int(x * 3) - 6, int(y * 3) - 6, int((x + w) * 3) + 6, int((y + h) * 3) + 6)


def tail_errors(reference, actual, is_user):
    def normalize(sample):
        L, _, R, B = sample["body"]
        return {y - B: (R - right, R - left) if is_user else (left - L, right - L)
                for y, left, right in sample["contour"]}
    r, a = normalize(reference), normalize(actual)
    errors = []
    for dy in range(-16, 20):
        if dy not in r or dy not in a:
            raise ValueError(f"尾巴截面缺行dy={dy}")
        errors.append(a[dy][0] - r[dy][0])
        if dy >= 0:
            errors.append(a[dy][1] - r[dy][1])
    return {"max_px": int(max(abs(e) for e in errors)), "rms_px": float(np.mean(np.square(errors)) ** 0.5)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path.home() / "MemoryPalace-docs-media/docs/imessage-ref")
    args = parser.parse_args()
    root, ours = args.root.expanduser(), args.root.expanduser() / "ours"
    inputs = {}

    def load(path):
        data = path.read_bytes()
        inputs[str(path.relative_to(root))] = hashlib.sha256(data).hexdigest()
        return np.asarray(Image.open(path).convert("RGB"), dtype=float)

    refs = {n: load(root / f"imessage-{n}.png") for n in (25, 42, 51)}
    actual = load(ours / "preview-dark.png")
    if actual.shape[:2] != (2556, 1179):
        raise ValueError("必须使用393×852pt、3x实屏，不能拉伸截图")
    text = json.loads((ours / "preview-dark-text.json").read_text())
    samples = [
        ("Come over at 12", "Comeoverat12", 51, "gray", (30, 1280, 520, 1445)),
        ("Which flavor do you want?", "Whichflavordoyouwant", 42, "blue", (420, 1490, 1150, 1660)),
        ("I love chocolate chip!!!", "Ilovechocolatechip", 42, "gray", (30, 1655, 740, 1790)),
        ("Thank you!", "Thankyou", 42, "gray", (30, 1790, 400, 1940)),
    ]
    measured, metrics = {}, []

    def metric(label, reference, value, note=""):
        delta = float(value - reference)
        metrics.append({"项目": label, "参考_px": float(reference), "我们_px": float(value),
                        "差_pt": delta / 3, "通过": abs(delta) <= 3.000001, "口径": note})

    for label, key, n, color, roi in samples:
        crop = refs[n][roi[1]:roi[3], roi[0]:roi[2]]
        background = np.array([255, 253, 255], dtype=float)
        fill = np.array([236, 233, 236], dtype=float)
        if color == "blue":
            background = np.median(np.concatenate((crop[0], crop[-1], crop[:, 0], crop[:, -1])), axis=0)
            fill = np.median(crop[(crop[:, :, 2] - crop[:, :, 0] > 120) & (crop[:, :, 1] > 80)], axis=0)
        reference = silhouette(refs[n], roi, background, fill)
        current = own_bubble(actual, next(t for t in text if t["key"] == key))
        measured[key] = {"reference": reference, "actual": current}
        r, a = reference["body"], current["body"]
        metric(label + "：贴边", 1180 - r[2] if color == "blue" else r[0],
               1179 - a[2] if color == "blue" else a[0], "左右屏边归一，原图多1px不拉伸")
        metric(label + "：宽", r[2] - r[0], a[2] - a[0])
        metric(label + "：高", r[3] - r[1], a[3] - a[1], "主体不含尾巴")
        metric(label + "：圆角拟合", reference["radius_px"], current["radius_px"], "50%轮廓圆拟合，不冒充内部参数")
        metric(label + "：尾巴下伸", reference["tail_down_px"], current["tail_down_px"])
        metric(label + "：尾巴横向外突", reference["tail_outside_px"], current["tail_outside_px"])
        if reference["tail_down_px"]:
            comparison = tail_errors(reference, current, color == "blue")
            measured[key]["tail_error"] = comparison
            metric(label + "：接缝最大误差", 0, comparison["max_px"], "底边前16px至底边后20px、左右镜像归一")
        if key != "Ilovechocolatechip":
            ri = ink(refs[n], (r[0] + 25, r[1] + 20, r[2] - 25, r[3] - 20), color == "blue")
            ai = ink(actual, (a[0] + 25, a[1] + 20, a[2] - 25, a[3] - 20), True)
            measured[key]["ink"] = {"reference": ri, "actual": ai}
            for label_side, index, sign in [("左", 0, 1), ("上", 1, 1), ("右", 2, -1), ("下", 3, -1)]:
                metric(label + "：墨迹" + label_side + "留白", sign * (ri[index] - r[index]),
                       sign * (ai[index] - a[index]), "可见墨迹留白，不冒充14/10布局padding；不混比彩色emoji")

    anchor = measured["Whichflavordoyouwant"]
    for key in ("Ilovechocolatechip", "Thankyou"):
        item = measured[key]
        metric(key + "：段内y", item["reference"]["body"][1] - anchor["reference"]["body"][1],
               item["actual"]["body"][1] - anchor["actual"]["body"][1], "同42图，以Which顶为0；不拼接51图绝对y")
    for previous, following, expected in [("Comeoverat12", "Whichflavordoyouwant", 30),
                                          ("Whichflavordoyouwant", "Ilovechocolatechip", 30),
                                          ("Ilovechocolatechip", "Thankyou", 12)]:
        metric(f"{previous}→{following}：间距", expected,
               measured[following]["actual"]["body"][1] - measured[previous]["actual"]["body"][3], "主体之间，不重复计算尾巴")

    controls = {}
    for label, n, rcx, ocx, cy, rbands, obands, alignment in [
        ("返回圆钮", 42, 114, 114, 244, ((42, 55), (171, 185), (174, 187), (302, 317)), ((30, 75), (155, 200), (155, 205), (290, 335)), "left"),
        ("右侧圆钮", 42, 1066, 1065, 244, ((994, 1007), (171, 185), (1126, 1139), (302, 317)), ((975, 1020), (155, 200), (1105, 1150), (290, 335)), "right"),
        ("名字胶囊", 25, 480, 500, 391, ((418, 431), (336, 351), (750, 763), (431, 445)), ((380, 450), (320, 370), (735, 800), (420, 465)), "center"),
        ("输入加号圆钮", 25, 144, 144, 2412, ((78, 92), (2345, 2360), (198, 212), (2465, 2480)), ((60, 110), (2325, 2370), (185, 225), (2455, 2495)), "left"),
        ("输入胶囊", 25, 600, 600, 2412, ((234, 248), (2345, 2360), (1090, 1104), (2465, 2480)), ((215, 270), (2325, 2370), (1070, 1120), (2455, 2495)), "left"),
    ]:
        r, a = control(refs[n], rcx, cy, rbands), control(actual, ocx, cy, obands)
        controls[label] = {"reference": r, "actual": a}
        def horizontal(b, width):
            return width - b[2] if alignment == "right" else ((b[0] + b[2] - width) / 2 if alignment == "center" else b[0])
        metric(label + "：x锚点", horizontal(r, 1180), horizontal(a, 1179), alignment)
        for suffix, ref_value, value in [("y", r[1], a[1]), ("宽", r[2] - r[0], a[2] - a[0]), ("高", r[3] - r[1], a[3] - a[1])]:
            metric(label + "：" + suffix, ref_value, value)
        metric(label + "：等效圆角", (r[3] - r[1]) / 2, (a[3] - a[1]) / 2, "圆/胶囊的高÷2；非曲线拟合")
    avatar_crop = actual[160:365, 480:700]
    b = bounds(avatar_crop.max(axis=2) > 100)
    avatar = [b[0] + 480, b[1] + 160, b[2] + 480, b[3] + 160]
    controls["合成头像"] = {"actual": avatar, "reference": [500, 177, 680, 357]}
    for label, r, a in [("头像中心偏移", 0, (avatar[0] + avatar[2] - 1179) / 2),
                        ("头像y", 177, avatar[1]), ("头像宽", 180, avatar[2] - avatar[0]),
                        ("头像高", 180, avatar[3] - avatar[1])]:
        metric(label, r, a, "只比圆形几何，不比不同头像内容")

    glyphs = {}
    for label, roi in [("返回箭头", (90, 205, 135, 285)), ("Jane Doe", (440, 365, 700, 430)),
                       ("名字右箭头", (700, 367, 730, 416)), ("输入加号", (110, 2380, 178, 2445)),
                       ("输入波形", (995, 2380, 1070, 2447))]:
        r, a = ink(refs[42], roi, False), ink(actual, roi, True)
        glyphs[label] = {"reference": r, "actual": a}
        metric(label + "：中心x", (r[0] + r[2] - 1180) / 2, (a[0] + a[2] - 1179) / 2)
        metric(label + "：中心y", (r[1] + r[3]) / 2, (a[1] + a[3]) / 2)
        metric(label + "：墨迹宽", r[2] - r[0], a[2] - a[0], "各自主题前景/背景50%覆盖阈值")
        metric(label + "：墨迹高", r[3] - r[1], a[3] - a[1], "不用相同RGB阈值混比浅深主题")
    timestamp = ink(actual, text_roi(next(t for t in text if t["key"].startswith("2025"))), True)
    metric("时间居中", -0.5, (timestamp[0] + timestamp[2] - 1179) / 2)
    metric("时间墨迹高度", 29, timestamp[3] - timestamp[1], "中文日期与英文Today文案不同，不比较固有宽度")
    metric("时间到下一泡可见空白", 24, measured["Comeoverat12"]["actual"]["body"][1] - timestamp[3])
    metric("输入胶囊右屏边", 84, 1179 - controls["输入胶囊"]["actual"][2])
    metric("输入胶囊距屏底", 84, 2556 - controls["输入胶囊"]["actual"][3])

    fade = load(ours / "fade-and-divider-dark.png")
    fade_text = json.loads((ours / "fade-and-divider-dark-text.json").read_text())
    second_time = ink(fade, text_roi(next(t for t in fade_text if t["key"].startswith("2025"))), True)
    full_fill = np.median([np.median(fade[y, 300:400], axis=0) for y in (600, 700, 800)], axis=0)
    background = (fade[:, 5] + fade[:, 900]) / 2
    direction = full_fill - background
    contrast = ((np.median(fade[:, 300:400], axis=1) - background) * direction).sum(axis=1) / (direction * direction).sum(axis=1)
    previous_bottom = int(np.flatnonzero(contrast[:second_time[1]] >= 0.5)[-1]) + 1
    following_top = second_time[3] + int(np.flatnonzero(contrast[second_time[3]:] >= 0.5)[0])
    metric("第二时间分隔：上可见空白", 54, second_time[1] - previous_bottom,
           "采用核准18pt候选；参考上方是系统通知，本方是普通气泡主体，不冒充同内容")
    metric("第二时间分隔：下可见空白", 24, following_top - second_time[3])
    fade_samples = []
    for y, reference in [(260, .1387), (305, .1909), (350, .2854), (400, .7068),
                         (430, .7763), (490, .9483), (505, .9483), (540, 1.0)]:
        gap = contrast[y] < .1 and y > 450 and np.max(contrast[y-12:y+13]) > .7
        fade_samples.append({"y_px": y, "reference_contrast": reference,
                             "actual_contrast": None if gap else float(contrast[y]),
                             "reason": "落在消息间距，不能当泡内样本" if gap else "",
                             "fill_rgb": np.median(fade[y, 300:400], axis=0).tolist(),
                             "background_rgb": background[y].tolist()})

    keyboard = json.loads((ours / "keyboard-evidence.json").read_text())
    keyboard["visible_capsules"] = {}
    for name in ("keyboard-dark", "keyboard-multiline-dark"):
        image = load(ours / f"{name}.png")
        expected_bottom = round(keyboard["keyboardTop"] * 3) - 15
        bottom = edge(image, "y", 600, expected_bottom - 12, expected_bottom + 12)
        gap_pt = keyboard["keyboardTop"] - bottom / 3
        keyboard["visible_capsules"][name] = {"bottom_px": bottom, "keyboard_gap_pt": gap_pt}
        if abs(gap_pt - 5) > 1:
            raise ValueError(f"{name}实际胶囊压住键盘或脱离锚点：{gap_pt}pt；不拿内部UITextView底边代替")

    long_image = load(ours / "pop-reveal-disabled-dark.png")
    long_text = json.loads((ours / "pop-reveal-disabled-dark-text.json").read_text())
    long_bubble = own_bubble(long_image, long_text[0], full_height=True)
    L, T, R, B = long_bubble["body"]
    patch = long_image[T+20:B-20, L+25:R-25]
    rows = np.flatnonzero(np.count_nonzero(patch.mean(axis=2) > 120, axis=1) > 8)
    runs = np.split(rows, np.flatnonzero(np.diff(rows) > 1) + 1)
    bands = [[int(r[0] + T + 20), int(r[-1] + T + 21)] for r in runs]
    pitch = float(np.median(np.diff([band[0] for band in bands])))
    reference_path = root / "long-measurements.json"
    reference_data = reference_path.read_bytes()
    inputs[reference_path.name] = hashlib.sha256(reference_data).hexdigest()
    long_reference = json.loads(reference_data)
    reference_pitch = long_reference["line_pitch"]["pitch_pt"]
    reference_padding = (long_reference["samples"][0]["body_wh_pt"][1] - 3 * reference_pitch) / 2
    metric("多行自然行距", reference_pitch * 3, pitch, "Apple26缩图同词模板；本方六行ASCII墨迹升部的中位步长，约1px量化误差")
    metric("多行上下平均内距（反推）", reference_padding * 3, (B - T - len(bands) * pitch) / 2,
           "[INFERENCE]主体高度减去行数×行高后平分；不是直接量出的布局padding")
    long_bubble["ink_bands_px"] = bands
    long_bubble["line_pitch_px"] = pitch
    long_bubble["reference"] = long_reference

    result = {"scale": 3, "inputs_sha256": inputs, "bubble_measurements": measured, "controls": controls,
              "glyphs": glyphs, "timestamp_ink": timestamp, "metrics": metrics, "keyboard": keyboard,
              "second_timestamp": {"ink": second_time, "previous_bottom": previous_bottom, "following_top": following_top},
              "fade_samples": fade_samples, "fade_full_fill_rgb": full_fill.tolist(), "long_bubble": long_bubble,
              "limits": ["浅色AI填充接近背景；轮廓量化使用真实深色PNG，浅色另行目检。",
                         "最大撑满宽度仍无可靠iMessage上限，保留299pt推算值，不计为≤1pt达标。",
                         "不同对话上下文的绝对消息y不可直减；JSON保留原始框，表内只比较相同连发段。",
                         "渐隐颜色投影不是alpha；主题不同及约1/20的灰阶量化不足以判定曲线位置误差≤1pt，采样单列。",
                         "键盘仅检查真实胶囊锚定与复位，不冒充没有参考图的键盘态iMessage对拍。",
                         "多行圆角按Apple缩图的19.18–21.02pt范围报告，不选单个半径凑≤1pt。",
                         "系统状态栏/Home条/键盘属于其它窗口，应用key-window截图不补画它们。"]}
    (ours / "s7-comparison.json").write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    lines = ["| 项目 | 参考pt | 我们pt | 差值pt | 结论 |", "|---|---:|---:|---:|---|"]
    for m in metrics:
        lines.append(f"| {m['项目']} | {m['参考_px']/3:.3f} | {m['我们_px']/3:.3f} | {m['差_pt']:+.3f} | {'≤1pt' if m['通过'] else '超差'} |")
    (ours / "s7-difference-table.md").write_text("\n".join(lines) + "\n")
    print("\n".join(lines))
    failures = [m for m in metrics if not m["通过"]]
    print(f"\n实测{len(metrics)}项，超差{len(failures)}项。限制：" + "；".join(result["limits"]))
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
