#!/usr/bin/env python3
"""按显式归档索引批量离线符号化；信任归档 UUID，不扫描或核验 dSYM。

CLI: python3 scripts/perf/mac-symbolize.py --archives index.json --frames frames.json
导入: symbolize_frames(frames 列表, 完整索引 JSON 对象) -> 同序结果列表。
地址必须是运行时绝对地址；未知镜像不调用 atos，也不推测源码位置。
"""

import argparse
import json
from pathlib import Path
import re
import subprocess
import sys
import uuid


_HEX_ADDRESS = re.compile(r"0x[0-9a-fA-F]+", re.IGNORECASE)


def _image_uuid(value, label):
    if not isinstance(value, str) or not re.fullmatch(
        r"(?:[0-9a-fA-F]{32}|[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12})",
        value,
    ):
        raise ValueError(f"{label} 必须是镜像 UUID")
    return str(uuid.UUID(value)).upper()


def _address(value, label):
    if not isinstance(value, str) or not _HEX_ADDRESS.fullmatch(value):
        raise ValueError(f"{label} 必须是 0x 开头的十六进制绝对地址")
    return int(value, 16)


def _archive_index(archives):
    if not isinstance(archives, dict) or not isinstance(archives.get("archives"), dict):
        raise ValueError("归档索引必须包含 archives 对象")
    index = {}
    for image_uuid, entry in archives["archives"].items():
        key = _image_uuid(image_uuid, "归档键")
        if key in index:
            raise ValueError(f"归档 UUID 重复：{key}")
        if not isinstance(entry, dict):
            raise ValueError(f"归档 {key} 必须是对象")
        arch = entry.get("arch")
        symbols = entry.get("symbols")
        sha = entry.get("sourceSHA")
        configuration = entry.get("configuration")
        if not isinstance(arch, str) or not re.fullmatch(r"[A-Za-z][A-Za-z0-9_]*", arch):
            raise ValueError(f"归档 {key} 的 arch 无效")
        if not isinstance(symbols, str) or not Path(symbols).is_absolute() or "\0" in symbols:
            raise ValueError(f"归档 {key} 的 symbols 必须是绝对路径")
        if not isinstance(sha, str) or not re.fullmatch(r"[0-9a-fA-F]{40}", sha):
            raise ValueError(f"归档 {key} 的 sourceSHA 必须是 40 位十六进制")
        if not isinstance(configuration, str) or not configuration.strip():
            raise ValueError(f"归档 {key} 缺少 configuration")
        index[key] = entry
    return index


def symbolize_frames(frames, archives):
    """返回保序结果；格式错误抛 ValueError，atos 失败抛 RuntimeError/OSError。

    每个 (UUID, loadAddress) 仅调用一次 atos；不修改传入的帧或索引。
    resolved 只代表 atos 返回了符号，不保证该归档一定含源码行号。
    """
    index = _archive_index(archives)
    if not isinstance(frames, list):
        raise ValueError("frames 必须是数组")
    results = []
    groups = {}
    for position, frame in enumerate(frames):
        label = f"frames[{position}]"
        if not isinstance(frame, dict):
            raise ValueError(f"{label} 必须是对象")
        key = _image_uuid(frame.get("imageUUID"), f"{label}.imageUUID")
        load = _address(frame.get("loadAddress"), f"{label}.loadAddress")
        address = _address(frame.get("address"), f"{label}.address")
        if address < load:
            raise ValueError(f"{label}.address 小于 loadAddress；需要运行时地址而非偏移量")
        entry = index.get(key)
        result = dict(frame, status="unresolved" if entry else "missing-image", symbol=None)
        results.append(result)
        if entry is not None:
            result.update(sourceSHA=entry["sourceSHA"], configuration=entry["configuration"])
            groups.setdefault((key, load), []).append(position)

    for (key, load), positions in groups.items():
        entry = index[key]
        command = ["atos", "-arch", entry["arch"], "-o", entry["symbols"], "-l", hex(load)]
        command.extend(frames[position]["address"] for position in positions)
        completed = subprocess.run(command, capture_output=True, text=True, check=False)
        if completed.returncode:
            detail = completed.stderr.strip() or completed.stdout.strip() or "无错误详情"
            raise RuntimeError(f"atos 失败（{key}，退出码 {completed.returncode}）：{detail}")
        symbols = completed.stdout.splitlines()
        if len(symbols) != len(positions):
            raise RuntimeError(
                f"atos 输出条数不匹配（{key}）：需要 {len(positions)}，得到 {len(symbols)}"
            )
        if completed.stderr.strip():
            print(f"atos 诊断（{key}）：{completed.stderr.strip()}", file=sys.stderr)
        for position, text in zip(positions, symbols):
            symbol = text.strip()
            # atos 对未知地址可回显地址，或返回 ???；两者都不是已解析函数。
            if not symbol or "???" in symbol or re.match(r"^0x[0-9a-f]+(?:\s|$)", symbol, re.IGNORECASE):
                continue
            results[position].update(status="resolved", symbol=symbol)
    return results


class _Parser(argparse.ArgumentParser):
    def error(self, message):
        self.print_usage(sys.stderr)
        self.exit(2, f"参数错误：{message}\n")


def main(argv=None):
    parser = _Parser(description="仅使用显式归档索引，对运行时绝对地址离线符号化")
    parser.add_argument("--archives", required=True, help="归档索引 JSON 路径")
    parser.add_argument("--frames", required=True, help="包含 frames 数组的 JSON 路径")
    args = parser.parse_args(argv)
    try:
        with open(args.archives, encoding="utf-8") as stream:
            archives = json.load(stream)
        with open(args.frames, encoding="utf-8") as stream:
            document = json.load(stream)
        if not isinstance(document, dict) or "frames" not in document:
            raise ValueError("帧输入必须包含 frames 数组")
        frames = symbolize_frames(document["frames"], archives)
        counts = dict.fromkeys(("resolved", "unresolved", "missing-image"), 0)
        for frame in frames:
            counts[frame["status"]] += 1
        print(json.dumps({"frames": frames, "counts": counts}, ensure_ascii=False))
    except (OSError, ValueError, RuntimeError) as error:
        print(f"符号化失败：{error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
