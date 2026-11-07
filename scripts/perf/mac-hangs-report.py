#!/usr/bin/env python3
"""只读取显式日志及 sample 元数据；样本计数不代表卡顿秒数。"""

import argparse
from collections import Counter
from datetime import datetime
import importlib.util
import json
from pathlib import Path
import re
from statistics import median
import sys


MAX_SAMPLE_BYTES = 64 * 1024 * 1024
STAMP = re.compile(r"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\s+(.*)$")
IDENTITY = re.compile(r"^(?:\[(?P<bracket>pid=[^\]]+)\]|(?P<plain>pid=\S+ bin=\S+ build=\S+ origin=\S+))\s+(?P<body>.*)$")
TOKEN = re.compile(r"^[\w.,:+@-]+$", re.UNICODE)
NUMBER = r"\d+(?:\.\d+)?"
HANG = re.compile(rf"^hang ({NUMBER})s(?:\s+(.*))?$")
BUSY = re.compile(rf"^busy cpu=({NUMBER})% ({NUMBER})s(?:\s+(.*))?$")
TREE = re.compile(r"^([ +!:|`-]*)(\d+)\s+(.+)$")
FRAME = re.compile(r"^(.*?)\s+\(in ([^)]+)\)(.*)$")
IMAGE = re.compile(r"^\s*(0x[0-9a-fA-F]+)\s+-\s+(0x[0-9a-fA-F]+)\s+\+?(.+?)\s+<([0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12})>\s+(.+)$")
TEST = re.compile(r"\b(?:XCTest\w*|xctest\w*)\b", re.IGNORECASE)
CONTEXT_KEYS = ("active", "code", "tool", "tools", "detailLoaded", "toolIds", "terminalBps")


class InputError(ValueError):
    pass


def fail(path, message, line=None):
    location = Path(path).name
    if line is not None:
        location += f":{line}"
    raise InputError(f"{location}：{message}")


def safe_token(value):
    return value if value and TOKEN.fullmatch(value) else "unknown"


def read_lines(path, sample=False):
    """逐文件逐行读取，不保留原始日志/其他线程栈。"""
    try:
        if sample and Path(path).stat().st_size > MAX_SAMPLE_BYTES:
            fail(path, "sample 超过 64MiB")
        size = 0
        with open(path, "rb") as stream:
            for number, raw in enumerate(stream, 1):
                size += len(raw)
                if sample and size > MAX_SAMPLE_BYTES:
                    fail(path, "sample 超过 64MiB")
                try:
                    yield number, raw.decode("utf-8").rstrip("\r\n")
                except UnicodeDecodeError:
                    fail(path, "不是有效 UTF-8", number)
    except OSError:
        fail(path, "无法读取输入文件")


def parse_context(text, path, number):
    context = {key: None for key in CONTEXT_KEYS}
    # 只接受探针的元数据键；不保留其余文本。
    for key, value in re.findall(r"(?:^|\s)(\w+)=([^\s]*)", text):
        if key not in context:
            continue
        if key == "toolIds":
            context[key] = safe_token(value) if value else ""
        elif key == "tool":
            context[key] = safe_token(value)
        elif key == "active":
            if value not in ("0", "1"):
                fail(path, "active 元数据无效", number)
            context[key] = int(value)
        else:
            if not value.isdigit():
                fail(path, f"{key} 元数据无效", number)
            context[key] = int(value)
    context["activity"] = {0: "background", 1: "foreground"}.get(context["active"], "unknown")
    return context


def parse_log(path, selected_date, groups, triggers, dates, warnings):
    timestamped = recognized = selected = 0
    for number, line in read_lines(path):
        match = STAMP.match(line)
        if not match:
            continue
        timestamped += 1
        stamp, body = match.groups()
        identity = {key: "unknown" for key in ("pid", "bin", "build", "origin")}
        identified = IDENTITY.match(body)
        if identified:
            metadata = identified.group("bracket") or identified.group("plain")
            values = dict(re.findall(r"(pid|bin|build|origin)=(\S+)", metadata))
            if set(values) != set(identity) or not values["pid"].isdigit():
                fail(path, "逐行包身份无效", number)
            identity.update({key: safe_token(value) for key, value in values.items()})
            identity["pid"] = int(values["pid"])
            body = identified.group("body")
        elif body.startswith(("pid=", "[pid=")):
            fail(path, "逐行包身份不完整", number)
        kind = body.split(" ", 1)[0]
        if kind not in ("start", "hang", "busy"):
            continue
        try:
            datetime.strptime(stamp, "%Y-%m-%d %H:%M:%S")
        except ValueError:
            fail(path, "时间戳无效", number)
        recognized += 1
        seconds = None
        cpu = None
        if kind == "start":
            if body != "start" and not re.fullmatch(r"start pid=\d+", body):
                fail(path, "start 元数据无效", number)
            duration_kind = "none"
            tail = ""
        elif kind == "hang":
            event = HANG.fullmatch(body)
            if not event:
                fail(path, "hang 元数据无效", number)
            seconds = float(event.group(1))
            tail = event.group(2) or ""
            cpu_match = re.search(rf"(?:^|\s)cpu=({NUMBER})%(?:\s|$)", tail)
            if cpu_match:
                cpu = float(cpu_match.group(1))
                duration_kind = "heartbeat-response"
                if "lowerBound=" in tail or "→" in tail or "(cooldown, no sample)" in tail:
                    fail(path, "应答和下界元数据混杂", number)
            elif re.fullmatch(r"(?:lowerBound=1\s+)?(?:→\s+sample-[\w.-]+\.txt|\(cooldown, no sample\))", tail):
                duration_kind = "trigger-lower-bound"
            else:
                fail(path, "hang 缺少应答或触发元数据", number)
        else:
            event = BUSY.fullmatch(body)
            if not event:
                fail(path, "busy 元数据无效", number)
            cpu, seconds = float(event.group(1)), float(event.group(2))
            tail = event.group(3) or ""
            if not re.fullmatch(r"→\s+sample-[\w.-]+\.txt|\(cooldown, no sample\)", tail):
                fail(path, "busy 缺少触发元数据", number)
            duration_kind = "cpu-window"
        context = parse_context(tail, path, number)
        date = stamp[:10]
        if selected_date and date != selected_date:
            continue
        selected += 1
        dates.add(date)
        key = (date, tuple(identity.items()), kind, duration_kind, tuple(context.items()))
        if key not in groups:
            groups[key] = {"date": date, "identity": identity, "type": kind,
                           "context": context, "durationKind": duration_kind,
                           "count": 0, "maximumSeconds": None, "maximumCPUPercent": None, "_seconds": []}
        group = groups[key]
        group["count"] += 1
        if seconds is not None:
            group["maximumSeconds"] = max(group["maximumSeconds"] or 0, seconds)
            group["_seconds"].append(seconds)
        if cpu is not None:
            group["maximumCPUPercent"] = max(group["maximumCPUPercent"] or 0, cpu)
        sample = re.search(r"→\s+(sample-[\w.-]+\.txt)$", tail)
        if sample:
            triggers.setdefault(sample.group(1), []).append({
                "date": date, "time": stamp, "identity": identity, "type": kind,
                "durationKind": duration_kind, "seconds": seconds, "context": context})
    if not timestamped:
        fail(path, "没有可识别的时间戳日志")
    if not recognized:
        warnings.append(f"{Path(path).name}：没有 start/hang/busy 元数据")
    elif not selected:
        warnings.append(f"{Path(path).name}：指定日期没有事件")


def summarize_days(groups):
    """中位数用中间两项均值；不把后台、未知状态或不同包混成前台数据。"""
    daily = {}
    for group in groups:
        activity = group["context"]["activity"]
        key = (group["date"], tuple(group["identity"].items()), group["type"], group["durationKind"], activity)
        if key not in daily:
            daily[key] = {name: group[name] for name in ("date", "identity", "type", "durationKind")}
            daily[key].update(activity=activity, count=0, maximumSeconds=None, _seconds=[])
        row = daily[key]
        row["count"] += group["count"]
        row["_seconds"].extend(group.pop("_seconds"))
        if group["maximumSeconds"] is not None:
            row["maximumSeconds"] = max(row["maximumSeconds"] or 0, group["maximumSeconds"])
    for row in daily.values():
        seconds = row.pop("_seconds")
        row["medianSeconds"] = median(seconds) if seconds else None
    return list(daily.values())


def unresolved(symbol):
    return symbol in ("???", "unknown", "<unknown>") or bool(re.fullmatch(r"0x[\da-fA-F]+", symbol))


def wrapper(symbol):
    return (symbol in ("main", "start", "_main") or "entry_point" in symbol
            or "$main(" in symbol or re.search(r"\b(?:App|AppEntry)\.main\(", symbol) is not None
            or ".__allocating_init" in symbol or ".__deallocating_deinit" in symbol
            or symbol.startswith(("@nonobjc ", "@objc ", "protocol witness ", "lazy protocol witness ",
                                  "partial apply ", "reabstraction thunk ", "outlined ")))


def clean_symbol(symbol):
    # atos 可携带源文件路径；只留下函数部分，source 元数据仅保存文件名与行号。
    symbol = symbol.split(" (in ", 1)[0].strip()
    symbol = re.sub(r"\s+\([^()]*\.(?:swift|m|mm|c|cc|cpp|h):\d+\)$", "", symbol)
    return symbol if not re.search(r"(?:^|[\s(\"'])/\S", symbol) else "unknown"


def parse_sample(path):
    pid = timestamp = process = executable = load_address = None
    roots = []
    stack = []
    images = []
    evidence = set()
    state = "header"
    main = False
    saw_graph = saw_images = False
    frame_count = 0
    for number, line in read_lines(path, sample=True):
        if TEST.search(line):
            # 不回显命中行，也不收集其他线程栈。
            evidence.add("xctest-injection")
        if line == "Call graph:":
            state = "graph"
            saw_graph = True
            continue
        if line == "Binary Images:":
            state = "images"
            saw_images = True
            stack = []
            continue
        if state == "graph" and line.startswith(("Total number in stack", "Sort by top of stack")):
            state = "summary"
            stack = []
            continue
        if state == "header":
            if line.startswith("Process:"):
                match = re.fullmatch(r"Process:\s+(.+?)\s+\[(\d+)\]", line)
                if not match:
                    fail(path, "Process 元数据无效", number)
                process, pid = match.group(1), int(match.group(2))
            elif line.startswith("Path:"):
                executable = Path(line.split(":", 1)[1].strip()).name
            elif line.startswith("Load Address:"):
                value = line.split(":", 1)[1].strip()
                if not re.fullmatch(r"0x[\da-fA-F]+", value):
                    fail(path, "Load Address 无效", number)
                load_address = int(value, 16)
            elif line.startswith("Date/Time:"):
                value = line.split(":", 1)[1].strip()
                try:
                    datetime.strptime(value[:19], "%Y-%m-%d %H:%M:%S")
                except ValueError:
                    fail(path, "Date/Time 无效", number)
                timestamp = value[:19]
            continue
        if state == "images":
            image = IMAGE.match(line)
            if image:
                low, high, label, uuid, image_path = image.groups()
                if int(high, 16) < int(low, 16):
                    fail(path, "镜像地址范围无效", number)
                leaf = Path(image_path).name
                names = {process, executable}
                names.discard(None)
                own = (int(low, 16) == load_address or leaf in names
                       or leaf in {name + ".debug.dylib" for name in names})
                if own:
                    images.append({"imageUUID": uuid.upper(), "loadAddress": low,
                                   "endAddress": high, "name": leaf,
                                   "label": label.split(" (", 1)[0],
                                   "kind": "debug" if leaf.endswith(".debug.dylib") else "main"})
            elif line.strip().startswith("0x"):
                fail(path, "Binary Images 元数据损坏", number)
            continue
        if state != "graph":
            continue
        match = TREE.match(line)
        if not match:
            if main and line.strip() and re.match(r"^[ +!:|`-]*\d", line):
                fail(path, "主线程树损坏", number)
            continue
        prefix, count, body = match.groups()
        count = int(count)
        if not count:
            fail(path, "采样计数必须大于零", number)
        if body.startswith("Thread_") or body.startswith("Main Thread"):
            main = "com.apple.main-thread" in body or "Main Thread" in body
            stack = []
            if main:
                root = {"count": count, "children": [], "depth": -1,
                        "symbol": None, "image": None, "address": None}
                roots.append(root)
                stack = [root]
            continue
        if not main:
            continue
        frame = FRAME.match(body)
        if not frame:
            fail(path, "主线程帧元数据损坏", number)
        symbol, image, suffix = frame.groups()
        address = re.search(r"\[(0x[\da-fA-F]+)\]", suffix)
        source = re.search(r"(\S+\.(?:swift|m|mm|c|cc|cpp|h)):(\d+)$", suffix)
        depth = len(prefix)
        while len(stack) > 1 and stack[-1]["depth"] >= depth:
            stack.pop()
        node = {"count": count, "children": [], "depth": depth,
                "symbol": clean_symbol(symbol), "image": image,
                "address": address.group(1) if address else None,
                "source": {"file": Path(source.group(1)).name, "line": int(source.group(2))}
                if source else None}
        stack[-1]["children"].append(node)
        stack.append(node)
        frame_count += 1
    if pid is None or timestamp is None or not saw_graph or not roots or not frame_count:
        fail(path, "缺少 Process/Date/Time/主线程采样树")
    for root in roots:
        if not root["children"]:
            fail(path, "主线程树没有帧")
    own_names = {name for name in (process, executable) if name}
    own_names |= {name + ".debug.dylib" for name in tuple(own_names)}
    for image in images:
        own_names.update((image["name"], image["label"]))
    return {"file": Path(path).name, "pid": pid, "time": timestamp,
            "images": images, "testHost": bool(evidence), "testHostEvidence": sorted(evidence),
            "_roots": roots, "_ownNames": own_names, "_hasImages": saw_images}


def all_nodes(roots):
    pending = list(reversed(roots))
    while pending:
        node = pending.pop()
        yield node
        pending.extend(reversed(node["children"]))


def symbolize_sample(sample, symbolize, archives):
    frames, nodes = [], []
    for node in all_nodes(sample["_roots"]):
        if node["image"] not in sample["_ownNames"] or not node["symbol"] or not unresolved(node["symbol"]):
            continue
        node["symbolStatus"] = "unresolved"
        image = next((image for image in sample["images"]
                      if node["address"] and int(image["loadAddress"], 16) <= int(node["address"], 16)
                      <= int(image["endAddress"], 16)), None)
        if image and symbolize:
            frames.append({"imageUUID": image["imageUUID"], "loadAddress": image["loadAddress"],
                           "address": node["address"]})
            nodes.append(node)
        elif not image:
            node["symbolStatus"] = "missing-image"
    if frames:
        for node, result in zip(nodes, symbolize(frames, archives)):
            node["symbolStatus"] = result["status"]
            if result["status"] == "resolved":
                node["symbol"] = clean_symbol(result["symbol"])


def distribution(root, own_names, path):
    counts = Counter()
    pending = [(root, None, False)]
    while pending:
        node, owner, runloop = pending.pop()
        symbol = node["symbol"] or ""
        if node["image"] in own_names and not unresolved(symbol) and not wrapper(symbol):
            owner = symbol
        runloop = runloop or "CFRunLoopServiceMachPort" in symbol
        children = sum(child["count"] for child in node["children"])
        if children > node["count"]:
            fail(path, "主线程子分支计数大于父节点")
        residual = node["count"] - children
        if residual:
            if runloop and symbol.lstrip("_") == "mach_msg2_trap":
                category, operation = "idle", "runloop-mach-wait"
            else:
                category = "owned-work" if owner else "unknown"
                if symbol.lstrip("_") in ("read", "pread", "pread64"):
                    operation = "file-read"
                elif "dispatch" in symbol.lower() and ("wait" in symbol.lower() or "semaphore" in symbol.lower()):
                    operation = "dispatch-wait"
                elif TEST.search(symbol):
                    operation = "test-wait" if "wait" in symbol.lower() else "test-work"
                else:
                    operation = "unknown"
            counts[(category, owner, operation)] += residual
        for child in reversed(node["children"]):
            pending.append((child, owner, runloop))
    return [{"category": category, "ownFrame": owner, "operation": operation, "sampleCount": count}
            for (category, owner, operation), count in sorted(counts.items(), key=lambda item: (-item[1], str(item[0])))]


def finish_sample(sample, triggers, warnings):
    roots = sample.pop("_roots")
    own_names = sample.pop("_ownNames")
    has_images = sample.pop("_hasImages")
    attached = triggers.get(sample["file"], [])
    sample["triggers"] = attached
    activities = {trigger["context"]["activity"] for trigger in attached}
    sample["activity"] = "test-host" if sample["testHost"] else (next(iter(activities)) if len(activities) == 1 else "unknown")
    sample["mainThread"] = {"sampleCount": sum(root["count"] for root in roots), "roots": []}
    for index, root in enumerate(roots, 1):
        sample["mainThread"]["roots"].append({"index": index, "sampleCount": root["count"],
            "distribution": distribution(root, own_names, sample["file"])})
    # 函数汇总取互斥分支的权重，不能再叠加父节点的累计计数。
    own_counts = Counter()
    representatives = {}
    for root in sample["mainThread"]["roots"]:
        for branch in root["distribution"]:
            if branch["category"] == "owned-work":
                own_counts[branch["ownFrame"]] += branch["sampleCount"]
    for node in all_nodes(roots):
        if node["image"] in own_names and node.get("source"):
            representatives.setdefault(node["symbol"], node["source"])
    sample["mainThread"]["ownFrames"] = [
        {"symbol": symbol, "sampleCount": count, "representativeSource": representatives.get(symbol)}
        for symbol, count in sorted(own_counts.items(), key=lambda item: (-item[1], item[0]))]
    statuses = Counter(node.get("symbolStatus", "symbolized") for node in all_nodes(roots)
                       if node["image"] in own_names)
    sample["ownFrameSymbolization"] = dict(sorted(statuses.items()))
    # 镜像名与装载地址仅用于本地解析；报告只暴露归属及 UUID。
    sample["images"] = [{"kind": image["kind"], "imageUUID": image["imageUUID"]} for image in sample["images"]]
    if not has_images or not sample["images"]:
        warnings.append(f"{sample['file']}：缺少自有镜像 UUID，未猜测")
    if not attached:
        warnings.append(f"{sample['file']}：没有精确文件名触发关联，不推断卡顿时长或前后台")
    if any(value == "unknown" for value in activities):
        warnings.append(f"{sample['file']}：触发行缺少 active，前后台未知")
    return sample


def load_symbolizer(index_path):
    if not index_path:
        return None, None
    try:
        with open(index_path, encoding="utf-8") as stream:
            archives = json.load(stream)
    except (OSError, UnicodeDecodeError, json.JSONDecodeError):
        fail(index_path, "归档索引无法读取或 JSON 损坏")
    if not isinstance(archives, dict) or not isinstance(archives.get("archives"), dict):
        fail(index_path, "归档索引缺少 archives 对象")
    spec = importlib.util.spec_from_file_location("mac_offline_symbolize", Path(__file__).with_name("mac-symbolize.py"))
    if spec is None or spec.loader is None:
        raise InputError("无法加载 mac-symbolize.py")
    module = importlib.util.module_from_spec(spec)
    try:
        spec.loader.exec_module(module)
        # 空批次也由共享函数验证索引，避免没有未知帧时绕过输入校验。
        module.symbolize_frames([], archives)
    except (OSError, ValueError, RuntimeError) as error:
        raise InputError("符号化模块或归档索引无效") from error
    return module.symbolize_frames, archives


def main():
    parser = argparse.ArgumentParser(description="离线卡顿元数据日报；不读取默认目录，不将 sample 计数换算成秒。")
    parser.add_argument("--log", action="append", default=[], metavar="hangs.log", help="明确日志路径，可重复")
    parser.add_argument("--samples", action="append", nargs="+", default=[], metavar="sample.txt", help="明确 sample 路径，可重复")
    parser.add_argument("--date", help="仅报告 YYYY-MM-DD")
    parser.add_argument("--archives", metavar="index.json", help="可选的可信归档索引")
    args = parser.parse_args()
    if not args.log and not args.samples:
        parser.error("至少提供 --log 或 --samples")
    if args.date:
        try:
            if datetime.strptime(args.date, "%Y-%m-%d").strftime("%Y-%m-%d") != args.date:
                raise ValueError
        except ValueError:
            parser.error("--date 必须是 YYYY-MM-DD")
    try:
        symbolize, archives = load_symbolizer(args.archives)
        groups, triggers, dates, warnings = {}, {}, set(), []
        for path in args.log:
            parse_log(path, args.date, groups, triggers, dates, warnings)
        samples = []
        for paths in args.samples:
            for path in paths:
                sample = parse_sample(path)
                if args.date and sample["time"][:10] != args.date:
                    warnings.append(f"{sample['file']}：采样日期不匹配，已排除")
                    continue
                symbolize_sample(sample, symbolize, archives)
                dates.add(sample["time"][:10])
                samples.append(finish_sample(sample, triggers, warnings))
        if any(group["identity"]["pid"] == "unknown" for group in groups.values()):
            warnings.append("旧日志没有逐行包身份，保持 unknown；未借最近 start 推断进程")
        report = {"schemaVersion": 1, "dates": sorted(dates),
                  "daily": summarize_days(groups.values()),
                  "logGroups": list(groups.values()), "samples": samples,
                  "warnings": warnings}
        json.dump(report, sys.stdout, ensure_ascii=False, indent=2, allow_nan=False)
        sys.stdout.write("\n")
        return 0
    except InputError as error:
        print(f"错误：{error}", file=sys.stderr)
    except (OSError, ValueError, RuntimeError):
        # atos / 导入异常可能包含归档绝对路径，错误不直接透传。
        print("错误：离线符号化失败，请检查归档索引和 atos 可用性", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
