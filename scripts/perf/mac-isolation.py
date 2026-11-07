#!/usr/bin/env python3
"""mac R1 隔离闸；只输出有界 JSON，候选合并输出仅有界写bench根，永不转发偏好值/工具stderr。

preflight --app CANDIDATE.app --root /tmp/mp-macperf-sol/bench-ID --uuid UUID --seed isolation
run       <同上> --window-approved [--observe-seconds 30] [--timeout 60]（各 UUID 重复 --uuid）
self-test（仅自建 /tmp 合成数据与无 UI 命令行 helper）

preflight 不是隔离实证，不创建目录、不扫描生产根、不读生产偏好、不启动 app。
run 必须先有车头开窗并给租约命令；全新 root 不自动复用/删除。stdout 可存到外部证据目录。
R1-0 仅支持新 root 的 --seed isolation；无 seed 在任何副作用前拒绝，不实现复用/复制/A-B。
核验真实启动 report 后继续观察完整 observe 窗，再结束自己的 seed 探针；提前退出/超时均失败。
退出：0 READY/GREEN；78 授权/配置；70 工具/审计/运行落点证据缺失；65 检测到改动/网络；
124 超时；130 中断。任何证据缺失/超限均 RED，不能因截断变成通过。

边界：find 只检验路径/mtime，不证明删除、恢复旧 mtime 或外部进程改动的归因；lsof 是采样，
短连接由继承的内核 deny network* 兜底；写入默认拒绝，仅放行 bench 根与具名设备端点。
这是可信本机候选的安全闸，不是对可并发替换 bundle、恶意逃逸/重置 session 子进程的安全证明。
"""
import argparse
import ctypes
import datetime
import errno
import io
import json
import math
import os
from pathlib import Path
import plistlib
import pwd
import re
import selectors
import signal
import stat
import subprocess
import sys
import tempfile
import threading
import time
import uuid


BUNDLE_ID = "com.susu.MemoryPalace.perfbench"
PRODUCTION_DOMAIN = "com.susu.MemoryPalace"
ROOT_PARENT = Path("/tmp/mp-macperf-sol")
OUTPUT_LIMIT = 768 * 1024
CAPTURE_LIMIT = 256 * 1024
MAX_ITEMS = 256
SAMPLE_LIMIT = 64 * 1024 * 1024
DEFAULT_SWITCHES = dict.fromkeys(("mp.stanch.H1", "mp.stanch.S1", "mp.stanch.P1",
                                  "mp.stanch.K1-dirty", "mp.stanch.R-tab", "mp.stanch.K0-min"), True)
TOOLS = {"sandbox": "/usr/bin/sandbox-exec", "lsof": "/usr/sbin/lsof",
         "ps": "/bin/ps", "find": "/usr/bin/find", "defaults": "/usr/bin/defaults",
         "log": "/usr/bin/log", "logger": "/usr/bin/logger"}
# 没有真实 app 运行证据，不猜测放开任何系统临时/缓存目录；HOME/TMPDIR 已指向 bench 根。
# 例外仅限现存设备的数据写操作，不授予设备创建、删除或元数据修改权限。
SYSTEM_WRITE_EXCEPTIONS = (
    {"operation": "file-write-data", "path": "/dev/null",
     "reason": "标准输入/输出丢弃端点；只允许向该现存空设备写数据，不允许其他 /dev 写入"},
    {"operation": "file-write-data", "path": "/dev/ptmx",
     "reason": "粟粟批准真实PTY主端数据写；不授予create/unlink/mode"},
    {"operation": "file-write-data", "path": "^/dev/ttys[0-9]+$", "filter": "regex",
     "reason": "粟粟批准数字PTY从端数据写；不放开其他设备或元数据操作"},
)
KERNEL_POLICY = "deny network* + 默认 deny file-write*；仅 bench 根写入及具名设备数据写；保留七根读保护"
LIMITATIONS = [
    "find 仅路径/mtime；不覆盖删除、回填旧 mtime，也不把其他进程改动归因于 bench；仅 ~/.claude mtime 噪声不单独 RED",
    "lsof 为进程树 IP socket 采样；短连接由继承的 kernel deny network* 阻止，不声称逐包捕获",
    "生产根不可遍历、偏好不可读取、证据过大或运行落点证据缺失一律 RED",
    "候选 stdout/stderr 合并且最多256KiB写bench根；超限判RED，不向host stdout转发内容",
    "不防可信本机之外的并发 bundle 替换，或在两次采样间恶意脱离 session 的子进程",
    "后代 PID 启动微秒在信号前复核，但 macOS kill(PID) 没有 pidfd 的原子身份接口",
    "kernel 护栏默认拒绝根外写入并阻止网络/七根读取；不放开共享 tmp 或用户 cache 根",
    "SwiftTerm shared tmp unlink、导出与显式数据库路径写入由内核白名单兜底；不承诺拒绝根外读取",
    "系统例外仅 /dev/null 数据写；不凭启动失败猜测添加系统临时/缓存目录",
    "根内候选日志不证明没有拒绝尝试；launchd 管理的代理不在本进程树审计范围",
    "启动 report 后的有限观察窗不证明所有长期/未触发行为，也不是性能基线",
    "Sandbox 日志只报告 violation，不提供 allowed-write 全量审计；根外无允许写依赖实际启动的精确 deny/allow 策略，不由空日志推导",
    "缺本PID canary时按粟粟S25批准的四项隔离证据判定并注记系统日志未记本次拒写；任一证据不全、显式loss或日志不完整仍RED",
]


class Failure(Exception):
    def __init__(self, code, category, message):
        super().__init__(message)
        self.code, self.category, self.message = code, category, message


def require(condition, category, message, code=78):
    if not condition:
        raise Failure(code, category, message)


def record_failure(report, failure):
    report.setdefault("failures", []).append({"category": failure.category,
                                               "message": failure.message,
                                               "exit": failure.code})
    report["status"] = "RED"


def emit(report):
    payload = json.dumps(report, ensure_ascii=False, sort_keys=True).encode("utf-8", "backslashreplace")
    if len(payload) >= OUTPUT_LIMIT:
        report = {"status": "RED", "failures": [{"category": "EVIDENCE_LIMIT",
                   "message": "证据超过输出上限；不输出截断的通过结果", "exit": 70}]}
        payload = json.dumps(report, ensure_ascii=False).encode("utf-8")
    sys.stdout.buffer.write(payload + b"\n")
    return next((f["exit"] for f in report.get("failures", [])), 0)


def capture(argv, *, env=None, timeout=15, limit=CAPTURE_LIMIT):
    """受限内存管道；异常从不携带 argv、stdout、stderr（尤其 defaults 值）。"""
    if env is None:
        env = clean_environment(Path("/var/empty"))
    proc = subprocess.Popen(argv, env=env, stdin=subprocess.DEVNULL,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    output, errors = bytearray(), bytearray()
    deadline = time.monotonic() + timeout
    try:
        with selectors.DefaultSelector() as selector:
            selector.register(proc.stdout, selectors.EVENT_READ, output)
            selector.register(proc.stderr, selectors.EVENT_READ, errors)
            while selector.get_map():
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise Failure(70, "TOOL_TIMEOUT", "辅助命令超时；输出未披露")
                for key, _ in selector.select(min(remaining, 0.1)):
                    chunk = os.read(key.fileobj.fileno(), 65536)
                    if not chunk:
                        selector.unregister(key.fileobj)
                        continue
                    key.data.extend(chunk)
                    if len(output) + len(errors) > limit:
                        raise Failure(70, "EVIDENCE_LIMIT", "辅助命令输出超限；不能判通过")
            remaining = deadline - time.monotonic()
            try:
                code = proc.wait(timeout=max(0.001, remaining))
            except subprocess.TimeoutExpired:
                raise Failure(70, "TOOL_TIMEOUT", "辅助命令超时；输出未披露") from None
        return code, bytes(output), bool(errors)
    finally:
        if proc.poll() is None:
            proc.kill()  # 只回收此 Popen 创建且尚未 reap 的辅助命令。
        proc.wait()
        proc.stdout.close()
        proc.stderr.close()


def checked_capture(argv, **kwargs):
    code, data, had_stderr = capture(argv, **kwargs)
    require(code == 0 and not had_stderr, "TOOL_FAILURE",
            "辅助命令失败或报告 stderr；原始输出未披露", 70)
    return data


def production_paths(home):
    # 这里只拼字符串；preflight 不 stat/遍历这些路径。
    return [home / "Library/Application Support/MemoryPalace",
            home / "Library/Caches/MemoryPalace", home / "Documents",
            home / "Desktop/cc-rp",
            home / "Library/Mobile Documents/iCloud~com~susu~MemoryPalace",
            home / ".claude", home / "Library/LaunchAgents"]


def within(path, root):
    return path == root or root in path.parents


def clean_environment(home, temporary=None):
    # 不继承 DYLD/PYTHONPATH、凭据、代理、测试宿主角色或调用者的 perf 门。
    result = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8",
              "LC_ALL": "C", "HOME": str(home), "CFFIXED_USER_HOME": str(home)}
    if temporary is not None:
        result["TMPDIR"] = str(temporary)
    return result


def private_directory(path, *, parent=False):
    info = path.lstat()
    require(stat.S_ISDIR(info.st_mode) and not path.is_symlink(), "ROOT",
            "隔离目录不是普通目录")
    require(info.st_uid == os.getuid() and info.st_mode & (0o022 if parent else 0o077) == 0,
            "ROOT", "隔离目录必须属于当前用户且权限安全（父目录不可组/其他写；根仅本用户访问）")


def validate_root(text):
    root = Path(text)
    require(root.is_absolute() and root.parent == ROOT_PARENT
            and re.fullmatch(r"bench-[A-Za-z0-9_-]+", root.name) is not None,
            "ROOT", "root 必须是 /tmp/mp-macperf-sol/bench-* 的直接子目录")
    # macOS /tmp -> /private/tmp 是唯一允许的系统别名；用户可控段不能是 symlink。
    temp = Path("/tmp").resolve(strict=True)
    require(str(temp) in ("/tmp", "/private/tmp"), "ROOT", "/tmp 不是预期系统临时目录")
    parent = temp / ROOT_PARENT.name
    if parent.exists() or parent.is_symlink():
        private_directory(parent, parent=True)
    canonical = parent / root.name
    require(not canonical.exists() and not canonical.is_symlink(), "ROOT",
            "root 已存在；必须使用全新 root，不复用或删除旧目录")
    require(root.resolve() == canonical, "ROOT", "root 有符号链接或路径逃逸")
    return canonical


def file_identity(path):
    info = path.lstat()
    require(stat.S_ISREG(info.st_mode) and not path.is_symlink(), "BUNDLE",
            "候选 plist/主二进制必须是普通文件")
    return (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns)




def preflight(args):
    require(args.seed == "isolation", "SEED_REQUIRED", "R1-0 仅允许新 root 的 --seed isolation")
    require(sys.platform == "darwin", "PLATFORM", "此命令只适用于 macOS")
    home = Path(pwd.getpwuid(os.getuid()).pw_dir)
    lexical = Path(os.path.abspath(args.app))
    roots = production_paths(home)
    require(lexical.suffix == ".app" and not within(lexical, Path("/Applications"))
            and not any(within(lexical, root) for root in roots),
            "BUNDLE", "候选必须是生产目录以外的独立 .app")
    app = lexical.resolve(strict=True)
    require(not within(app, Path("/Applications"))
            and not any(within(app, root) for root in roots),
            "BUNDLE", "候选解析后指向生产目录")
    require(app.is_dir(), "BUNDLE", "候选 app 不存在")
    root = validate_root(args.root)
    require(not within(app, root), "BUNDLE", "候选不能位于尚未创建的运行根")
    for tool in TOOLS.values():
        require(os.path.isfile(tool) and os.access(tool, os.X_OK), "TOOL_MISSING",
                "所需 macOS 安全工具缺失或不可执行")
    info_path = app / "Contents/Info.plist"
    require(info_path.resolve() == info_path, "BUNDLE", "Info.plist 路径包含符号链接")
    info_stat = info_path.stat()
    require(stat.S_ISREG(info_stat.st_mode) and info_stat.st_size <= 1024 * 1024,
            "BUNDLE", "候选 Info.plist 不是有界普通文件")
    with info_path.open("rb") as handle:
        info = plistlib.loads(handle.read(1024 * 1024 + 1))
    require(isinstance(info, dict) and info.get("CFBundleIdentifier") == BUNDLE_ID
            and info.get("CFBundlePackageType") == "APPL", "BUNDLE",
            "候选 bundle ID/类型不是指定 mac bench app")
    executable = info.get("CFBundleExecutable")
    require(isinstance(executable, str) and executable not in ("", ".", "..")
            and "/" not in executable and "\x00" not in executable,
            "BUNDLE", "CFBundleExecutable 无效")
    binary = app / "Contents/MacOS" / executable
    require(binary.resolve() == binary, "BUNDLE", "主二进制路径包含符号链接")
    binary_info = binary.stat()
    require(stat.S_ISREG(binary_info.st_mode) and os.access(binary, os.X_OK), "BUNDLE", "主二进制不可执行")
    try:
        expected = [str(uuid.UUID(value)).upper() for value in args.uuid]
    except ValueError:
        raise Failure(78, "UUID", "预期 UUID 格式无效") from None
    require(expected and len(expected) == len(set(expected)), "UUID", "已核包 UUID 不能为空或重复")
    env = clean_environment(root / "home", root / "tmp")
    env["MP_PERF_ROOT"] = str(root)
    env["MP_PERF_SEED"] = "isolation"
    return {"app": app, "binary": binary, "plist": info_path, "root": root,
            "expected_uuids": expected, "env": env, "production_home": home, "role": "seed",
            "package_attestation": {"path": str(binary), "size": binary_info.st_size,
                                    "mtime_ns": binary_info.st_mtime_ns}}


def sandbox_profile(root, read_protected_roots):
    """读保护保持原样；写白名单独立于七根，祖先软链按内核实际目标受限。"""
    require(root.is_absolute() and root.resolve() == root and root != Path("/"),
            "ROOT", "内核写白名单必须使用规范的非系统根绝对路径")
    filters = " ".join("(subpath " + json.dumps(str(path), ensure_ascii=False) + ")"
                       for path in sorted(set(read_protected_roots), key=str))
    rules = ["(version 1)", "(allow default)", "(deny network*)", "(deny file-write*)",
             "(allow file-write* (subpath " + json.dumps(str(root), ensure_ascii=False) + "))"]
    for exception in SYSTEM_WRITE_EXCEPTIONS:
        matcher = exception.get("filter", "literal")
        value = ("#" if matcher == "regex" else "") + json.dumps(exception["path"])
        rules.append("(allow " + exception["operation"] + " (" + matcher + " " + value + "))")
    if filters:
        rules.append("(deny file-read* " + filters + ")")
    return "\n".join(rules)


def parse_preferences(data):
    try:
        value = plistlib.loads(data)
    except Exception:
        raise Failure(70, "PREFERENCES", "偏好不是有效 plist；任何值均未披露") from None
    require(isinstance(value, dict) and all(isinstance(key, str) for key in value),
            "PREFERENCES", "偏好域不是字符串 key 字典", 70)
    return value


def preferences(home):
    data = checked_capture([TOOLS["defaults"], "export", PRODUCTION_DOMAIN, "-"],
                           env=clean_environment(home), limit=8 * 1024 * 1024)
    return parse_preferences(data)


def compare_preferences(before, after):
    # 二进制 plist 比较保留 bool/int 等类型差异；序列化只在内存中。
    changed = []
    for key in before.keys() | after.keys():
        equal = key in before and key in after and plistlib.dumps(before[key], fmt=plistlib.FMT_BINARY) == \
            plistlib.dumps(after[key], fmt=plistlib.FMT_BINARY)
        if not equal:
            changed.append(key)
    require(sum(len(key.encode("utf-8")) for key in changed) <= 64 * 1024,
            "EVIDENCE_LIMIT", "变动偏好键名证据超限；不输出任何值", 70)
    return {"status": "changed" if changed else "same", "changed_keys": sorted(changed)}


def metadata_exists(path):
    try:
        path.lstat()
        return True
    except FileNotFoundError:
        return False


def metadata_since(roots, marker, existed):
    records = []
    for lexical, canonical in roots:
        # 一根失败仍扫描其余根；只保存安全分类，不保留工具异常/内容。
        try:
            require(lexical.resolve() == canonical and canonical.resolve() == canonical,
                    "METADATA", "生产根扫描期间符号链接映射改变", 70)
            if not metadata_exists(canonical):
                records.append({"root": str(lexical), "missing": True,
                                "disappeared": existed[str(lexical)], "changes": []})
                continue
            data = checked_capture([TOOLS["find"], "-P", str(canonical), "-newer", str(marker), "-print0"],
                                   timeout=30)
            names = data.split(b"\x00")
            require(names[-1] == b"", "METADATA", "find 路径边界无效", 70)
            names.pop()
            require(sum(len(row["changes"]) for row in records) + len(names) <= MAX_ITEMS,
                    "EVIDENCE_LIMIT", "变动路径证据超限；不得截断为通过", 70)
            changes = []
            for name in names:
                path = Path(os.fsdecode(name))
                require(within(path, canonical), "METADATA", "find 返回根外路径", 70)
                info = path.lstat()  # 只看元数据，不跟随 symlink，不打开内容。
                changes.append({"path": str(path), "mtime_ns": info.st_mtime_ns})
            records.append({"root": str(lexical), "missing": False, "changes": changes})
        except Exception as error:
            records.append({"root": str(lexical), "changes": [],
                            "error": error.category if isinstance(error, Failure) else "METADATA"})
    return records


def metadata_changed(records, noise_root):
    changed = False
    for row in records:
        if row["root"] == str(noise_root):
            row["mtime_ignored_for_verdict"] = True
        changed |= bool(row.get("disappeared") or
                        (row["changes"] and row["root"] != str(noise_root)))
    return changed


class BSDInfo(ctypes.Structure):
    # Darwin <sys/proc_info.h> proc_bsdinfo；start timeval 防止误杀复用 PID。
    _fields_ = [(name, ctypes.c_uint32) for name in
                ("flags", "status", "xstatus", "pid", "ppid", "uid", "gid", "ruid", "rgid",
                 "svuid", "svgid", "rfu")] + [
        ("comm", ctypes.c_char * 16), ("name", ctypes.c_char * 32)] + [
        (name, ctypes.c_uint32) for name in ("nfiles", "pgid", "pjobc", "tdev", "tpgid")] + [
        ("nice", ctypes.c_int32), ("start_sec", ctypes.c_uint64), ("start_usec", ctypes.c_uint64)]


def process_token(pid):
    lib = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    call = lib.proc_pidinfo
    call.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int]
    call.restype = ctypes.c_int
    info = BSDInfo()
    count = call(pid, 3, 0, ctypes.byref(info), ctypes.sizeof(info))  # PROC_PIDTBSDINFO
    if count == 0 and ctypes.get_errno() in (0, errno.ESRCH):
        return None
    require(count == ctypes.sizeof(info) and info.pid == pid and info.uid == os.getuid(),
            "PROCESS_AUDIT", "无法核验自己进程的内核身份", 70)
    return (info.start_sec, info.start_usec)


class OwnedTree:
    def __init__(self, process, output=None):
        self.process = process
        self.tokens = {}
        self.samples = 0
        self.expired = threading.Event()
        self.timer = None
        self.cleanup_errors = []
        self.max_processes = 0
        self.observed_seconds = 0.0
        self.output = output
        self.output_bytes = 0
        self.output_overflow = False
        if output is not None:
            os.set_blocking(process.stdout.fileno(), False)

    def drain_output(self):
        if self.output is None or self.output_overflow:
            return
        while True:
            try:
                chunk = os.read(self.process.stdout.fileno(), min(65536, CAPTURE_LIMIT - self.output_bytes + 1))
            except BlockingIOError:
                return
            if not chunk:
                self.output = None
                return
            size = min(len(chunk), CAPTURE_LIMIT - self.output_bytes)
            if size:
                written = self.output.write(chunk[:size])
                require(written == size, "OUTPUT_CAPTURE", "候选输出没有完整落盘；不能判通过", 70)
                self.output_bytes += size
            if size < len(chunk):
                self.output_overflow = True
                return

    def refresh(self):
        data = checked_capture([TOOLS["ps"], "-axo", "pid=,ppid=,pgid="])
        rows = {}
        for line in data.splitlines():
            cells = line.split()
            require(len(cells) == 3 and all(cell.isdigit() for cell in cells),
                    "PROCESS_AUDIT", "进程树元数据格式无效", 70)
            pid, parent, group = map(int, cells)
            rows[pid] = (parent, group)
        live = {pid: token for pid, token in self.tokens.items() if process_token(pid) == token}
        eligible = set(live)
        while True:
            new = {pid for pid, (parent, group) in rows.items()
                   if pid not in eligible and (parent in eligible or group == self.process.pid)}
            if not new:
                break
            eligible.update(new)
        require(len(eligible) <= 128, "PROCESS_AUDIT", "候选子进程数超出审计边界", 70)
        for pid in eligible - live.keys():
            token = process_token(pid)
            if token is not None:
                live[pid] = token
        self.tokens = live
        self.max_processes = max(self.max_processes, len(live))
        return sorted(live)

    def audit(self):
        self.drain_output()
        pids = self.refresh()
        if pids:
            code, data, stderr = capture([TOOLS["lsof"], "-nP", "-a", "-p",
                                         ",".join(map(str, pids)), "-i", "-F", "p"])
            require(code in (0, 1) and not stderr, "NETWORK_AUDIT",
                    "lsof 审计失败；原始输出未披露", 70)
            require(not data, "NETWORK_DETECTED", "自己进程树出现 IP socket", 65)
        self.samples += 1
        return pids

    def signal_owned(self, sig):
        # 快照中的 PID 发信号前复核内核启动微秒；根 PID 由未 reap 的 Popen 所有。
        for pid, token in list(self.tokens.items()):
            if pid == self.process.pid:
                continue
            try:
                if process_token(pid) == token:
                    os.kill(pid, sig)
            except ProcessLookupError:
                pass
            except Exception:
                self.cleanup_errors.append(Failure(70, "PROCESS_CLEANUP", "自己子进程回收失败"))
        try:
            self.process.send_signal(sig)
        except ProcessLookupError:
            pass
        except Exception:
            self.cleanup_errors.append(Failure(70, "PROCESS_CLEANUP", "自己主进程回收失败"))

    def arm(self, timeout):
        def watchdog():
            self.expired.set()
            self.signal_owned(signal.SIGKILL)
        self.timer = threading.Timer(timeout, watchdog)
        self.timer.daemon = True
        self.timer.start()

    def stop(self):
        if self.timer is not None:
            self.timer.cancel()
            self.timer.join()

        def sample():
            try:
                return self.audit()
            except Exception as error:
                self.cleanup_errors.append(error if isinstance(error, Failure) else
                                           Failure(70, "PROCESS_AUDIT", "回收期间审计失败"))
                return list(self.tokens)

        alive = sample()
        for sig in (signal.SIGTERM, signal.SIGKILL):
            self.signal_owned(sig)
            end = time.monotonic() + 1.0
            while time.monotonic() < end:
                self.process.poll()
                alive = sample()
                if not alive:
                    break
                time.sleep(0.05)
            if not alive:
                break
        require(not alive, "PROCESS_CLEANUP", "自己进程树未全部回收", 70)
        if self.cleanup_errors:
            raise self.cleanup_errors[0]


def monitor(tree, timeout, ready=None, observe_seconds=0, *, _clock=time.monotonic):
    deadline = _clock() + timeout
    observed_at = None
    while True:
        if tree.expired.is_set():
            raise Failure(124, "TIMEOUT", "测量超时；看门狗仅回收自己启动的进程树")
        pids = tree.audit()
        require(not tree.output_overflow, "EVIDENCE_LIMIT", "候选输出超256KiB；已保留根内前缀，不能判通过", 70)
        code = tree.process.poll()
        if tree.expired.is_set():
            raise Failure(124, "TIMEOUT", "测量超时；看门狗仅回收自己启动的进程树")
        require(code is None or code == 0, "APP_EXIT", "候选非零退出；app 日志未披露", 70)
        if ready is not None:
            require(code is None, "EARLY_EXIT", "候选在 host 完成完整观察窗前自行退出", 70)
            configured = ready()
            if configured and observed_at is None:
                observed_at = _clock()
            if observed_at is not None:
                tree.observed_seconds = max(0.0, _clock() - observed_at)
            complete = configured and observed_at is not None and tree.observed_seconds >= observe_seconds
            if complete:
                require(not tree.expired.is_set() and _clock() < deadline,
                        "TIMEOUT", "观察完成时窗口已超时", 124)
                require(tree.process.poll() is None, "EARLY_EXIT",
                        "候选未存活到观察完成边界", 70)
                return code
        elif code is not None and not pids:
            return code
        if _clock() >= deadline:
            raise Failure(124, "TIMEOUT", "测量超时；仅回收自己启动的进程树")
        time.sleep(min(0.2, max(0, deadline - _clock())))


def check_configuration(root, pid, role, marker, expected_uuids, switches):
    root = root.resolve(strict=True)
    path = root / "perf/isolation-configuration.json"
    require(path.resolve() == path, "ATTESTATION", "运行落点证据包含符号链接", 70)
    info = path.stat()
    require(info.st_size <= 384 * 1024 and info.st_mtime_ns >= marker.stat().st_mtime_ns,
            "ATTESTATION", "运行落点证据过大或不是本次生成", 70)
    with path.open("rb") as handle:
        data = json.loads(handle.read(384 * 1024 + 1))
    require(isinstance(data, dict), "ATTESTATION", "运行落点证据不是对象", 70)
    require(data.get("protocol") == "macIsolationV1" and data.get("bundleID") == BUNDLE_ID
            and type(data.get("pid")) is int and data["pid"] == pid
            and data.get("role") == role, "ATTESTATION", "运行身份与启动候选不一致", 70)
    require(data.get("profileID") == "perf-bench-profile", "ATTESTATION",
            "实际当前楼层不是独立 bench 楼层", 70)
    for key in ("observerOrders", "callbackOrders"):
        orders = data.get(key)
        require(isinstance(orders, list) and all(type(value) is int for value in orders)
                and orders == [-(2**63), 2**63 - 1], "ATTESTATION",
                "真实 runloop observer 注册/回调 order 缺失或不匹配", 70)
    require(isinstance(data.get("binaryUUID"), str)
            and data["binaryUUID"].upper() in expected_uuids
            and isinstance(data.get("codeUUID"), str), "ATTESTATION", "实际主二进制 UUID 不匹配", 70)
    try:
        uuid.UUID(data["codeUUID"])
    except ValueError:
        raise Failure(70, "ATTESTATION", "实际代码 UUID 格式无效") from None
    require(data.get("switches") == switches
            and all(type(value) is bool for value in data["switches"].values()),
            "ATTESTATION", "实际六个止血开关与请求不一致", 70)
    observer = data.get("observerDescription")
    require(isinstance(observer, str) and observer.strip()
            and len(observer.encode("utf-8")) <= 256 * 1024,
            "ATTESTATION", "实际 runloop observer 描述缺失或超限", 70)
    required = {"root": root, "home": root / "home", "temporary": root / "tmp"}
    for key in ("root", "home", "applicationSupport", "caches", "documents", "temporary"):
        value = data.get(key)
        require(isinstance(value, str) and Path(value).is_absolute(), "ATTESTATION",
                "实际 Foundation 落点缺失", 70)
        lexical = Path(value)
        actual = lexical.resolve()
        require(within(actual, root), "ATTESTATION",
                "实际 Foundation 落点发生根外/符号链接逃逸", 70)
        # 系统祖先别名允许由 realpath 归一；根内用户可控段仍不能通过软链改道。
        reached_root = False
        for component in [*reversed(lexical.parents), lexical]:
            if reached_root:
                require(not component.is_symlink(), "ATTESTATION",
                        "实际 Foundation 落点包含根内符号链接", 70)
            elif component.resolve() == root:
                reached_root = True
        require(reached_root, "ATTESTATION", "实际 Foundation 落点没有规范根边界", 70)
        require(key not in required or actual == required[key].resolve(), "ATTESTATION",
                "实际 HOME/TMP/root 与核验根不一致", 70)
    probe = data.get("kernelWriteProbe")
    require(isinstance(probe, dict) and type(probe.get("pid")) is int and probe["pid"] == pid
            and probe.get("path") == str(marker.resolve(strict=True))
            and type(probe.get("errno")) is int and probe["errno"] in (errno.EPERM, errno.EACCES)
            and probe.get("operation") == "file-write-data",
            "KERNEL_WRITE_PROBE", "本 PID 真实根外拒写证据缺失或不匹配", 70)
    return {key: data[key] for key in ("protocol", "bundleID", "pid", "role", "root", "home",
                                      "applicationSupport", "caches", "documents", "temporary",
                                      "binaryUUID", "codeUUID", "switches", "observerDescription",
                                      "profileID", "observerOrders", "callbackOrders", "kernelWriteProbe")}



def check_self_sample(root, pid, configuration, marker):
    path = root / "perf/forced-self-sample.json"
    require(path.resolve() == path, "SELF_SAMPLE", "自采回执包含符号链接", 70)
    marker_mtime = marker.stat().st_mtime_ns
    info = path.stat()
    require(info.st_size <= 16 * 1024 and info.st_mtime_ns >= marker_mtime,
            "SELF_SAMPLE", "自采回执过大或不是本次生成", 70)
    with path.open("rb") as handle:
        data = json.loads(handle.read(16 * 1024 + 1))
    require(isinstance(data, dict) and data.get("protocol") == "macSelfSampleV1"
            and type(data.get("targetPID")) is int and data["targetPID"] == pid
            and type(data.get("samplerPID")) is int and data["samplerPID"] > 0
            and data["samplerPID"] != pid and type(data.get("status")) is int
            and data["status"] == 0 and data.get("termination") == "exit"
            and data.get("error") is None, "SELF_SAMPLE", "App进程内自采未正常完成", 70)
    require(isinstance(data.get("file"), str) and Path(data["file"]).is_absolute(),
            "SELF_SAMPLE", "自采文件路径缺失", 70)
    sample = Path(data["file"])
    expected = Path(configuration["applicationSupport"]).resolve() / "MemoryPalace/perf"
    require(sample.resolve() == sample and sample.parent == expected and within(sample, root)
            and re.fullmatch(r"sample-[0-9]{8}-[0-9]{6}\.txt", sample.name) is not None,
            "SELF_SAMPLE", "自采文件不在本次探针目录", 70)
    info = sample.stat()
    require(type(data.get("bytes")) is int and 0 < data["bytes"] <= SAMPLE_LIMIT
            and info.st_size == data["bytes"] and info.st_mtime_ns >= marker_mtime,
            "SELF_SAMPLE", "自采文件大小或生成时间不符", 70)
    return {**data, "mtime_ns": info.st_mtime_ns, "validation": "size+mtime"}



def parse_sandbox_writes(data, pid, start, end, canary):
    """只消费系统 Sandbox 消息的 subject；emitter 的 processID 不表示受测进程。"""
    events, system_lines, count, finished = [], 0, 0, False
    for index, raw in enumerate(io.BytesIO(data)):
        try:
            line = raw.decode("utf-8", "strict")
            if not line.strip() or (index == 0 and line.startswith("Filtering the log data using ")):
                continue
            row = json.loads(line)
        except (UnicodeError, ValueError):
            raise Failure(70, "KERNEL_LOG", "内核日志不是完整 NDJSON；原文未披露") from None
        require(isinstance(row, dict) and not finished, "KERNEL_LOG",
                "log stream 事件非对象或成功结束后仍有事件；不能判通过", 70)
        if "finished" in row:
            require(type(row["finished"]) is int and row["finished"] == 1
                    and type(row.get("count")) is int and row["count"] == count,
                    "KERNEL_LOG", "log stream 成功结束记录或事件计数不符；不能判通过", 70)
            finished = True
            continue
        count += 1
        require(row.get("eventType") != "lossEvent", "KERNEL_LOG_LOSS",
                "查询窗口报告日志丢失；无法确认拒写证据完整", 70)
        message = row.get("eventMessage")
        require(isinstance(message, str), "KERNEL_LOG", "内核事件缺少消息字段", 70)
        try:
            timestamp = datetime.datetime.fromisoformat(row["timestamp"].replace("Z", "+00:00"))
            require(timestamp.tzinfo is not None, "KERNEL_LOG", "内核事件时间戳缺时区", 70)
        except (KeyError, TypeError, ValueError):
            raise Failure(70, "KERNEL_LOG", "拒写事件时间戳缺失或无效") from None
        in_window = start <= timestamp <= end
        if in_window and message.startswith("Sandbox:"):
            system_lines += 1
        subject = re.match(r"Sandbox: [^\r\n]+?\(([0-9]+)\) deny\(", message)
        if subject is None or int(subject[1]) != pid:
            continue  # 全机日志只计数；不输出其他进程的消息、路径或字段。
        match = re.fullmatch(
            r"Sandbox: [^\r\n]+\(([0-9]+)\) deny\([0-9]+\) ([a-z][a-z0-9-]*)(?: ([^\r\n]*))?",
            message)
        require(match is not None and int(match[1]) == pid, "KERNEL_LOG",
                "Sandbox subject PID/拒写路径不可完整核验（可能隐私遮蔽或格式变化）", 70)
        require(row.get("eventType") == "logEvent" and (
            (row.get("processImagePath") == "/kernel" and row.get("senderImagePath") ==
             "/System/Library/Extensions/Sandbox.kext/Contents/MacOS/Sandbox")
            or row.get("processImagePath") == "/usr/libexec/sandboxd"),
            "KERNEL_LOG", "拒写消息缺少系统 Sandbox emitter 来源；不能接受 app 自报日志", 70)
        require(in_window, "KERNEL_LOG", "拒写事件不在本次候选存活窗口", 70)
        if not match[2].startswith("file-write"):
            continue
        require(len(events) < MAX_ITEMS, "EVIDENCE_LIMIT", "本PID内核写事件超限；不能截断为通过", 70)
        events.append({"subject_pid": pid, "timestamp": timestamp.isoformat(),
                       "operation": match[2], "path": match[3],
                       "emitter_pid": row.get("processID"), "emitter_image": row["processImagePath"],
                       "sender_image": row.get("senderImagePath"),
                       "controlled_probe": match[2] == "file-write-data" and match[3] == str(canary)})
    require(finished, "KERNEL_LOG", "log stream 缺少成功结束记录；不能以截断/空日志判通过", 70)
    visible = any(event["controlled_probe"] for event in events)
    return {"source": "/usr/bin/log stream --style ndjson --level debug",
            "subject_pid": pid, "start": start.isoformat(), "end": end.isoformat(),
            "query_complete": True, "system_sandbox_line_count": system_lines,
            "channel_status": "系统拒写日志通道静默" if system_lines == 0 else "active",
            "controlled_probe_visible": visible, "events": events,
            "allowed_write_event_audit": "unavailable; sandboxd(8) only documents violations",
            "lossless_system_delivery_proven": False}


def missing_canary_evidence(report):
    require(report.get("kernel_write_audit", {}).get("controlled_probe_visible") is False,
            "ISOLATION_FOUR_EVIDENCE", "缺失本PID canary尚未确认，不能替代日志判定", 70)
    probe = report.get("configuration", {}).get("kernelWriteProbe", {})
    state = report.get("marker_state", {})
    before, after = state.get("before"), state.get("after")
    metadata = report.get("metadata", [])
    noise_root = str(Path(pwd.getpwuid(os.getuid()).pw_dir) / ".claude")
    evidence = {
        "app_kernel_eperm": type(probe.get("errno")) is int and probe["errno"] == errno.EPERM
        and probe.get("pid") == report.get("pid") and probe.get("path") == report.get("marker")
        and probe.get("operation") == "file-write-data",
        "marker_inode_size_mtime_unchanged": isinstance(before, list) and len(before) == 4
        and before == after and all(type(value) is int for value in before),
        "seven_roots_updates_zero": len(metadata) == 7
        and len({row.get("root") for row in metadata}) == 7
        and all(not row.get("error") and not row.get("disappeared")
                and (row.get("changes") == [] or
                     (isinstance(row.get("changes"), list) and row.get("root") == noise_root
                      and row.get("mtime_ignored_for_verdict") is True))
                for row in metadata),
        "preferences_same": report.get("preferences") == {"status": "same", "changed_keys": []}}
    require(all(evidence.values()), "ISOLATION_FOUR_EVIDENCE",
            "缺本PID canary时四项隔离证据未全部通过", 65)
    return {"note": "系统日志未记本次拒写", **evidence}


class SandboxWriteStream:
    def __init__(self):
        self.output, self.errors = bytearray(), bytearray()
        self.selector = selectors.DefaultSelector()
        self.process = None
        self.stopping = False
        ready_started = time.monotonic()
        ready_deadline = ready_started + 15.0
        self.readiness_marker = "mp-macperf-ready-" + uuid.uuid4().hex
        predicate = ('eventMessage BEGINSWITH "Sandbox:" OR eventType == "lossEvent" OR eventMessage CONTAINS ' +
                     json.dumps(self.readiness_marker))
        self.command = [TOOLS["log"], "stream", "--style", "ndjson", "--level", "debug",
                        "--predicate", predicate]
        try:
            self.process = subprocess.Popen(self.command, env=clean_environment(Path("/var/empty")),
                                            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                            stderr=subprocess.PIPE)
            self.started_at = datetime.datetime.now(datetime.timezone.utc)
            self.selector.register(self.process.stdout, selectors.EVENT_READ, self.output)
            self.selector.register(self.process.stderr, selectors.EVENT_READ, self.errors)
            self.drain(0.25)
            remaining = ready_deadline - time.monotonic()
            require(remaining > 0, "KERNEL_LOG_READY", "日志订阅就绪等待超过15秒；未启动候选", 70)
            checked_capture([TOOLS["logger"], self.readiness_marker], timeout=remaining)
            cursor = 0
            while time.monotonic() < ready_deadline:
                self.drain(min(0.1, max(0.0, ready_deadline - time.monotonic())))
                while True:
                    newline = self.output.find(b"\n", cursor)
                    if newline < 0:
                        break
                    line = self.output[cursor:newline]
                    cursor = newline + 1
                    if not line.strip() or line.startswith(b"Filtering the log data using "):
                        continue
                    try:
                        event = json.loads(line)
                    except (UnicodeError, ValueError):
                        raise Failure(70, "KERNEL_LOG_READY", "就绪等待中收到无效日志行；未启动候选") from None
                    if isinstance(event, dict) and isinstance(event.get("eventMessage"), str) and self.readiness_marker in event["eventMessage"]:
                        self.readiness = {"confirmed": True, "marker": self.readiness_marker,
                                          "wait_seconds": time.monotonic() - ready_started}
                        return
            raise Failure(70, "KERNEL_LOG_READY", "15秒内未见本轮logger串；未启动候选")
        except BaseException:
            self.close()
            raise

    def drain(self, duration=0):
        deadline = time.monotonic() + duration
        while self.selector.get_map():
            remaining = max(0.0, deadline - time.monotonic())
            ready = self.selector.select(min(remaining, 0.1))
            for key, _ in ready:
                chunk = os.read(key.fileobj.fileno(), 65536)
                if not chunk:
                    self.selector.unregister(key.fileobj)
                    continue
                key.data.extend(chunk)
                require(len(self.output) + len(self.errors) <= CAPTURE_LIMIT, "EVIDENCE_LIMIT",
                        "实时内核日志超限；不能截断为通过", 70)
            require(not self.errors, "KERNEL_LOG", "实时内核日志报告 stderr；原文未披露", 70)
            if time.monotonic() >= deadline:
                break
        if not self.stopping:
            require(self.process.poll() is None, "KERNEL_LOG",
                    "实时内核日志在候选核验结束前退出", 70)

    def finish(self, pid, start, end, canary):
        try:
            self.drain(10.0)
            self.stopping = True
            self.process.send_signal(signal.SIGINT)
            self.drain(2.0)
            require(not self.selector.get_map(), "KERNEL_LOG", "实时内核日志未完整结束", 70)
            code = self.process.wait(timeout=1)
            require(code == 0, "KERNEL_LOG", "实时内核日志非正常结束", 70)
            audit = parse_sandbox_writes(bytes(self.output), pid, start, end, canary)
            return {**audit, "stream_started_at": self.started_at.isoformat(),
                    "stream_command": self.command, "stream_exit": code,
                    "readiness": self.readiness}
        finally:
            self.close()

    def close(self):
        if self.process is not None:
            if self.process.poll() is None:
                self.process.kill()
            self.process.wait()
            self.process.stdout.close()
            self.process.stderr.close()
        self.selector.close()
        self.output.clear()
        self.errors.clear()


def perform_run(args, report):
    # 必须保持第一条操作：未授权时不做 preflight、mkdir、prefs、敏感根 metadata 或 Popen。
    require(args.window_approved, "WINDOW_REQUIRED", "BLOCKED：等车头开窗")
    require(args.seed == "isolation", "SEED_REQUIRED", "R1-0 仅允许新 root 的 --seed isolation")
    report["window_approved_at"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
    config = preflight(args)
    root, env = config["root"], config["env"]
    root.parent.mkdir(mode=0o700, exist_ok=True)
    private_directory(root.parent, parent=True)
    root.mkdir(mode=0o700)  # 独占创建；绝不复用已有 root。
    for child in ("home", "tmp"):
        (root / child).mkdir(mode=0o700)
    roots = [(path, path.resolve()) for path in production_paths(config["production_home"])]
    require(not any(within(root, resolved) or within(config["app"], resolved)
                    for _, resolved in roots), "ROOT", "候选/隔离根与生产根重叠")
    existed = {str(path): metadata_exists(resolved) for path, resolved in roots}
    profile = sandbox_profile(root, [path for pair in roots for path in pair])
    checked_capture([TOOLS["sandbox"], "-p", profile, "/usr/bin/true"], env=env)
    before = preferences(config["production_home"])
    marker_fd, marker_name = tempfile.mkstemp(prefix="marker-", dir=root.parent)
    os.close(marker_fd)
    marker = Path(marker_name)
    marker_identity = list(file_identity(marker)[:4])
    report.update({"root": str(root), "marker": str(marker), "expected_uuids": config["expected_uuids"],
                   "role": config["role"], "kernel_policy": KERNEL_POLICY,
                   "kernel_write_exceptions": list(SYSTEM_WRITE_EXCEPTIONS)})
    report.update({"app_path": str(config["app"]), "package_uuid": config["expected_uuids"][0],
                   "package_uuid_source": "caller-verified-once",
                   "package_attestation": config["package_attestation"]})
    host_path = Path(__file__).resolve()
    host_info = host_path.stat()
    report["host_attestation"] = {"path": str(host_path), "size": host_info.st_size,
                                  "mtime_ns": host_info.st_mtime_ns}
    tree, proc = None, None
    bench_output = None
    kernel_stream = None
    output_path = root / "perf/bench-output.log"
    env["MP_PERF_WINDOW_APPROVED"] = "1"  # 只在显式授权且所有静态门通过后设给子进程。
    env["MP_PERF_WRITE_DENY_PROBE_PATH"] = str(marker)
    if args.force_self_sample:
        env["MP_PERF_FORCE_SAMPLE"] = "1"
    report["force_self_sample"] = args.force_self_sample
    started_at = None
    try:
        output_path.parent.mkdir(mode=0o700)
        bench_output = output_path.open("xb", buffering=0)
        os.fchmod(bench_output.fileno(), 0o600)
        kernel_stream = SandboxWriteStream()
        started_at = datetime.datetime.now(datetime.timezone.utc)
        proc = subprocess.Popen([TOOLS["sandbox"], "-p", profile, str(config["binary"])],
                                cwd=root, env=env, stdin=subprocess.DEVNULL,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                start_new_session=True)
        report["pid"] = proc.pid
        report["kernel_policy_evidence"] = {
            "launcher": TOOLS["sandbox"], "argument": "-p", "profile": profile,
            "write_root": str(root), "system_write_exceptions": list(SYSTEM_WRITE_EXCEPTIONS),
            "basis": "sandbox-exec(1): enters the supplied profile then executes this PID",
            "allowed_write_event_audit": False,
            "claim": "undeclared root-external writes prohibited by the supplied kernel policy; not an allow-event trace"}
        tree = OwnedTree(proc, bench_output)
        tree.arm(args.timeout)

        def probe_ready():
            kernel_stream.drain()
            if "configuration" not in report:
                if not metadata_exists(root / "perf/isolation-configuration.json"):
                    return False
                report["configuration"] = check_configuration(
                    root, proc.pid, config["role"], marker,
                    set(config["expected_uuids"]), DEFAULT_SWITCHES)
            if args.force_self_sample and "self_sample" not in report:
                if not metadata_exists(root / "perf/forced-self-sample.json"):
                    return False
                report["self_sample"] = check_self_sample(root, proc.pid, report["configuration"], marker)
            return True

        report["app_exit"] = monitor(tree, args.timeout, probe_ready, args.observe_seconds)
        report["completion"] = "validated-startup-probe"
        require(tree.max_processes > 0, "PROCESS_AUDIT", "没有采到候选 PID；不能判通过", 70)
    except Failure as failure:
        record_failure(report, failure)
    except (Exception, KeyboardInterrupt):
        record_failure(report, Failure(70, "RUN_FAILURE", "启动/审计失败；敏感原始异常未披露"))
    finally:
        # 清理和测后实证即使在超时/审计失败时仍执行；不让二次中断跳过回收。
        old_signals = {sig: signal.signal(sig, signal.SIG_IGN) for sig in (signal.SIGINT, signal.SIGTERM)}
        try:
            if tree is not None:
                try:
                    tree.stop()
                except Exception as error:
                    record_failure(report, error if isinstance(error, Failure) else
                                   Failure(70, "PROCESS_CLEANUP", "自己进程回收失败"))
                report["network_audit_samples"] = tree.samples
                report["max_owned_processes"] = tree.max_processes
                report["observation_requested_seconds"] = args.observe_seconds
                report["observation_completed_seconds"] = tree.observed_seconds
                if tree.expired.is_set() and not any(
                        item["category"] == "TIMEOUT" for item in report.get("failures", [])):
                    record_failure(report, Failure(124, "TIMEOUT", "独立看门狗已触发；不能判通过"))
            elif proc is not None and proc.poll() is None:
                proc.kill()
                proc.wait(timeout=5)
            if proc is not None:
                report["app_exit"] = proc.poll()
                if report.get("completion") == "validated-startup-probe" and \
                        proc.returncode not in (0, -signal.SIGTERM, -signal.SIGKILL):
                    record_failure(report, Failure(70, "APP_EXIT", "探针完成边界出现非预期候选退出"))
                ended_at = datetime.datetime.now(datetime.timezone.utc)
                try:
                    report["kernel_write_audit"] = kernel_stream.finish(proc.pid, started_at, ended_at, marker)
                except Exception as error:
                    record_failure(report, error if isinstance(error, Failure) else
                                   Failure(70, "KERNEL_LOG", "内核写审计不可读取或不完整；不能判通过"))
            elif kernel_stream is not None:
                kernel_stream.close()
            try:
                if tree is not None:
                    tree.drain_output()
                    if tree.output_overflow:
                        record_failure(report, Failure(70, "EVIDENCE_LIMIT", "候选输出超256KiB；不能判通过"))
                if proc is not None and proc.stdout is not None:
                    proc.stdout.close()
            except Exception:
                record_failure(report, Failure(70, "OUTPUT_CAPTURE", "根内候选输出记录失败"))
            finally:
                if bench_output is not None:
                    report["bench_output"] = {"path": str(output_path), "bytes": bench_output.tell(),
                                              "limit": CAPTURE_LIMIT}
                    bench_output.close()
            try:
                comparison = compare_preferences(before, preferences(config["production_home"]))
                report["preferences"] = comparison
                if comparison["changed_keys"]:
                    record_failure(report, Failure(65, "PREFERENCES_CHANGED", "生产偏好键发生变化"))
            except Exception as error:
                record_failure(report, error if isinstance(error, Failure) else
                               Failure(70, "PREFERENCES", "偏好逐 key 实证不完整；任何值均未披露"))
            try:
                report["metadata"] = metadata_since(roots, marker, existed)
                for row in report["metadata"]:
                    if row.get("error"):
                        record_failure(report, Failure(70, row["error"], "一根 metadata 实证失败；其余根仍已尝试"))
                if metadata_changed(report["metadata"], config["production_home"] / ".claude"):
                    record_failure(report, Failure(65, "METADATA_CHANGED", "非噪声根出现更新路径或任一根消失"))
            except Exception as error:
                record_failure(report, error if isinstance(error, Failure) else
                               Failure(70, "METADATA", "七根 metadata 实证不完整；不能判通过"))
            try:
                report["marker_state"] = {"before": marker_identity,
                                          "after": list(file_identity(marker)[:4])}
                if report.get("kernel_write_audit", {}).get("controlled_probe_visible") is False:
                    report["missing_canary_evidence"] = missing_canary_evidence(report)
            except Exception as error:
                record_failure(report, error if isinstance(error, Failure) else
                               Failure(70, "MARKER_STATE", "marker状态无法完整核验"))
        finally:
            for sig, previous in old_signals.items():
                signal.signal(sig, previous)
    if not report.get("failures"):
        report["status"] = "GREEN"


def self_test(report):
    """同文件小自测；从不调用 preflight/真实 defaults/生产根/app。"""
    from types import SimpleNamespace
    checks = []

    def expect_failure(category, action):
        try:
            action()
        except Failure as failure:
            require(failure.category == category, "SELF_TEST", "拒绝分类不符合预期", 70)
            return
        raise Failure(70, "SELF_TEST", "应拒绝的合成案例错误通过")

    expect_failure("WINDOW_REQUIRED", lambda: perform_run(SimpleNamespace(window_approved=False), {}))
    checks.append("unauthorized-before-side-effects")
    expect_failure("SEED_REQUIRED", lambda: perform_run(
        SimpleNamespace(window_approved=True, seed=None), {}))
    checks.append("seed-required-before-side-effects")
    expect_failure("ROOT", lambda: validate_root("bench-relative"))
    expect_failure("ROOT", lambda: validate_root("/tmp/mp-macperf-sol/bench-parent/escape"))
    checks.append("strict-isolated-root-synthetic-rejections")
    secret = "SYNTHETIC-VALUE-MUST-NOT-LEAK"
    before = parse_preferences(plistlib.dumps({"same": secret, "changed": secret, "removed": secret}))
    after = parse_preferences(plistlib.dumps({"same": secret, "changed": 1, "added": False}))
    comparison = compare_preferences(before, after)
    require(comparison == {"status": "changed", "changed_keys": ["added", "changed", "removed"]}
            and secret not in json.dumps(comparison), "SELF_TEST", "偏好逐 key 比较泄漏或错误", 70)
    require(compare_preferences({"typed": True}, {"typed": 1})["changed_keys"] == ["typed"],
            "SELF_TEST", "偏好类型差异未检出", 70)
    expect_failure("PREFERENCES", lambda: parse_preferences(secret.encode()))
    unchanged = {str(i): 0 for i in range(257)}
    require(compare_preferences(unchanged, unchanged) == {"status": "same", "changed_keys": []},
            "SELF_TEST", "相同偏好域不应因键数多而被拒绝", 70)
    expect_failure("EVIDENCE_LIMIT", lambda: compare_preferences({"x" * (64 * 1024 + 1): 0}, {}))
    checks.append("memory-only-preferences-and-no-values")
    ROOT_PARENT.mkdir(mode=0o700, parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="isolation-selftest-", dir=ROOT_PARENT) as name:
        base = Path(name).resolve()
        protected, allowed = base / "synthetic-protected", base / "allowed"
        protected.mkdir(mode=0o700)
        allowed.mkdir(mode=0o700)
        marker = base / "marker"
        marker.touch()
        changed = protected / "line\nbreak"
        changed.write_text(secret, encoding="utf-8")
        future = marker.stat().st_mtime_ns + 2_000_000_000
        os.utime(changed, ns=(future, future))
        rows = metadata_since([(protected, protected), (base / "missing", base / "missing")], marker,
                              {str(protected): True, str(base / "missing"): False})
        require(rows[0]["changes"] and rows[1]["missing"]
                and secret not in json.dumps(rows), "SELF_TEST", "metadata 边界/缺根证据错误", 70)
        synthetic = {"status": "GREEN"}
        record_failure(synthetic, Failure(65, "METADATA_CHANGED", "合成改动"))
        require(synthetic["status"] == "RED", "SELF_TEST", "变动未标红", 70)
        checks.append("nul-metadata-boundaries-missing-roots-and-red")
        noise = [{"root": str(base / ".claude"), "changes": [{"path": "synthetic"}]}]
        require(not metadata_changed(noise, base / ".claude") and noise[0]["changes"],
                "SELF_TEST", "claude mtime 噪声丢失或单独判改动", 70)
        noise[0]["disappeared"] = True
        require(metadata_changed(noise, base / ".claude"), "SELF_TEST", "claude 消失被错误忽略", 70)
        require(metadata_changed([{"root": str(protected), "changes": [{"path": "synthetic"}]}],
                                 base / ".claude"), "SELF_TEST", "其他根改动被当作噪声", 70)
        checks.append("only-claude-mtime-noise-not-disappearance")
        fixture_id = "12345678-1234-1234-1234-123456789ABC"
        for child in ("home", "tmp", "perf"):
            (allowed / child).mkdir()
        fixture = {"protocol": "macIsolationV1", "bundleID": BUNDLE_ID, "pid": 12345,
                   "role": "seed", "profileID": "perf-bench-profile",
                   "binaryUUID": fixture_id, "codeUUID": fixture_id, "switches": DEFAULT_SWITCHES,
                   "observerDescription": "synthetic main runloop",
                   "observerOrders": [-(2**63), 2**63 - 1], "callbackOrders": [-(2**63), 2**63 - 1]}
        fixture["kernelWriteProbe"] = {"pid": 12345, "path": str(marker),
                                       "errno": errno.EPERM, "operation": "file-write-data"}
        for key, value in {"root": allowed, "home": allowed / "home", "temporary": allowed / "tmp",
                           "applicationSupport": allowed / "home/Library/Application Support",
                           "caches": allowed / "home/Library/Caches",
                           "documents": allowed / "home/Documents"}.items():
            fixture[key] = str(value)
        fixture_path = allowed / "perf/isolation-configuration.json"

        def check_fixture(data, host_root=allowed):
            fixture_path.write_text(json.dumps(data), encoding="utf-8")
            return check_configuration(host_root, 12345, "seed", marker, {fixture_id}, DEFAULT_SWITCHES)

        check_fixture(fixture)
        sample_dir = Path(fixture["applicationSupport"]) / "MemoryPalace/perf"
        sample_dir.mkdir(parents=True)
        sample_file = sample_dir / "sample-20261020-000000.txt"
        sample_payload = b"Process: synthetic [12345]\nCall graph:\n  10 Thread_1: Main Thread DispatchQueue_<multiple>\n"
        sample_file.write_bytes(sample_payload)
        sample_result = {"protocol": "macSelfSampleV1", "targetPID": 12345, "samplerPID": 12346,
                         "status": 0, "termination": "exit", "file": str(sample_file), "bytes": len(sample_payload)}

        def check_sample(data):
            (allowed / "perf/forced-self-sample.json").write_text(json.dumps(data), encoding="utf-8")
            return check_self_sample(allowed, 12345, fixture, marker)

        observed = check_sample(sample_result)
        require(observed["mtime_ns"] == sample_file.stat().st_mtime_ns, "SELF_TEST", "样本mtime不是实际值", 70)
        for key, value in (("targetPID", 12346), ("status", 1), ("file", str(base / "outside")),
                           ("bytes", 0), ("bytes", len(sample_payload) + 1), ("samplerPID", 12345)):
            expect_failure("SELF_SAMPLE", lambda key=key, value=value: check_sample({**sample_result, key: value}))
        with sample_file.open("wb") as handle:
            handle.truncate(SAMPLE_LIMIT + 1)
        expect_failure("SELF_SAMPLE", lambda: check_sample({**sample_result, "bytes": SAMPLE_LIMIT + 1}))
        with sample_file.open("wb") as handle:
            handle.truncate(SAMPLE_LIMIT)
        require(check_sample({**sample_result, "bytes": SAMPLE_LIMIT})["bytes"] == SAMPLE_LIMIT,
                "SELF_TEST", "样本大小上界被错误拒绝", 70)
        sample_file.write_bytes(sample_payload)
        previous = sample_file.stat()
        os.utime(sample_file, ns=(previous.st_atime_ns, marker.stat().st_mtime_ns - 1))
        expect_failure("SELF_SAMPLE", lambda: check_sample(sample_result))
        os.utime(sample_file, ns=(previous.st_atime_ns, previous.st_mtime_ns))
        checks.append("sample-size-and-mtime-boundaries-without-content-scan")
        for key, value in (("protocol", "wrong"), ("profileID", "production"),
                           ("binaryUUID", str(uuid.uuid4())), ("documents", str(base)),
                           ("observerOrders", [0, 1]), ("callbackOrders", []),
                           ("observerDescription", ""), ("switches", {})):
            expect_failure("ATTESTATION", lambda key=key, value=value: check_fixture({**fixture, key: value}))
        (allowed / "escape").symlink_to(base, target_is_directory=True)
        expect_failure("ATTESTATION", lambda: check_fixture({**fixture, "documents": str(allowed / "escape")}))
        checks.append("synthetic-runtime-attestation-all-fields-and-symlink-escape")
        alias = base / "root-alias"
        alias.symlink_to(allowed, target_is_directory=True)
        equivalent = {**fixture, "root": str(alias), "home": str(alias / "home"),
                      "temporary": str(alias / "tmp"), "documents": str(alias / "home/Documents")}
        check_fixture(equivalent, alias)
        system_alias = ROOT_PARENT / base.relative_to(ROOT_PARENT.resolve()) / "allowed"
        check_fixture({**fixture, "root": str(system_alias), "home": str(system_alias / "home"),
                       "temporary": str(system_alias / "tmp")}, system_alias)
        (allowed / "home-alias").symlink_to(allowed / "home", target_is_directory=True)
        expect_failure("ATTESTATION", lambda: check_fixture(
            {**fixture, "documents": str(allowed / "home-alias/Documents")}))
        (allowed / "root-loop").symlink_to(allowed, target_is_directory=True)
        expect_failure("ATTESTATION", lambda: check_fixture(
            {**fixture, "documents": str(allowed / "root-loop")}))
        expect_failure("KERNEL_WRITE_PROBE", lambda: check_fixture({**fixture, "kernelWriteProbe": {}}))
        expect_failure("KERNEL_WRITE_PROBE", lambda: check_fixture(
            {**fixture, "kernelWriteProbe": {**fixture["kernelWriteProbe"], "pid": 1}}))
        checks.append("realpath-equivalence-retains-inner-symlink-and-kernel-probe-boundaries")
        start = datetime.datetime(2026, 1, 1, tzinfo=datetime.timezone.utc)
        end = start + datetime.timedelta(seconds=2)
        event = {"timestamp": (start + datetime.timedelta(seconds=1)).isoformat(),
                 "eventType": "logEvent", "processID": 0, "processImagePath": "/kernel",
                 "senderImagePath": "/System/Library/Extensions/Sandbox.kext/Contents/MacOS/Sandbox",
                 "eventMessage": "Sandbox: synthetic-bench(12345) deny(1) file-write-data " + str(marker),
                 "private_payload": secret}

        def log_fixture(events, finished=True):
            return ("\n".join(json.dumps(row) for row in events +
                              ([{"finished": 1, "count": len(events)}] if finished else []))
                    + "\n").encode()

        audit = parse_sandbox_writes(b'Filtering the log data using "synthetic"\n\n' +
                                     log_fixture([event]), 12345, start, end, marker)
        require(audit["events"][0]["subject_pid"] == 12345 and audit["events"][0]["emitter_pid"] == 0
                and secret not in json.dumps(audit) and not audit["lossless_system_delivery_proven"],
                "SELF_TEST", "subject/emitter归属或事件元数据边界错误", 70)
        expect_failure("KERNEL_LOG", lambda: parse_sandbox_writes(
            log_fixture([event], False), 12345, start, end, marker))
        expect_failure("KERNEL_LOG", lambda: parse_sandbox_writes(
            log_fixture([event]).replace(b'"count": 1', b'"count": 2'), 12345, start, end, marker))
        silent = parse_sandbox_writes(log_fixture([]), 12345, start, end, marker)
        require(silent["system_sandbox_line_count"] == 0 and not silent["controlled_probe_visible"]
                and silent["channel_status"] == "系统拒写日志通道静默",
                "SELF_TEST", "零行通道没有明确记静默", 70)
        other = {**event, "eventMessage": "Sandbox: synthetic-other(54321) deny(1) file-read-data /SYNTHETIC-PRIVATE"}
        mixed = parse_sandbox_writes(log_fixture([event, other]), 12345, start, end, marker)
        require(mixed["system_sandbox_line_count"] == 2 and len(mixed["events"]) == 1
                and "SYNTHETIC-PRIVATE" not in json.dumps(mixed),
                "SELF_TEST", "全机计数不全或泄漏其他进程路径", 70)
        outside = {**other, "timestamp": (end + datetime.timedelta(seconds=1)).isoformat()}
        require(parse_sandbox_writes(log_fixture([outside]), 12345, start, end, marker)
                ["system_sandbox_line_count"] == 0, "SELF_TEST", "将窗外事件混入同窗计数", 70)
        expect_failure("KERNEL_LOG_LOSS", lambda: parse_sandbox_writes(
            log_fixture([event, {"eventType": "lossEvent"}]), 12345, start, end, marker))
        for update in ({"processImagePath": "/synthetic/app"},
                       {"timestamp": (end + datetime.timedelta(seconds=1)).isoformat()}):
            expect_failure("KERNEL_LOG", lambda update=update: parse_sandbox_writes(
                log_fixture([{**event, **update}]), 12345, start, end, marker))
        extra = {**event, "eventMessage": "Sandbox: synthetic-bench(12345) deny(1) file-write-create /synthetic/outside"}
        require(any(not row["controlled_probe"] for row in parse_sandbox_writes(
            log_fixture([event, extra]), 12345, start, end, marker)["events"]),
            "SELF_TEST", "真实非canary拒写被过滤", 70)
        checks.append("bounded-kernel-subject-provenance-completion-loss-visibility-and-unexpected-denial")
        read_event = {**event, "eventMessage": "Sandbox: synthetic-bench(12345) deny(1) file-read-data /synthetic/read"}
        with_read = parse_sandbox_writes(log_fixture([event, read_event]), 12345, start, end, marker)
        require(with_read["system_sandbox_line_count"] == 2 and len(with_read["events"]) == 1,
                "SELF_TEST", "扩大到全机流后把正常读取拒绝误判成写事件格式错误", 70)
        from copy import deepcopy
        marker_state = list(file_identity(marker)[:4])
        silent_report = {"pid": 12345, "marker": str(marker), "kernel_write_audit": silent,
                         "configuration": fixture, "preferences": {"status": "same", "changed_keys": []},
                         "marker_state": {"before": marker_state, "after": marker_state.copy()},
                         "metadata": [{"root": str(base / str(i)), "changes": []} for i in range(7)]}
        accepted = missing_canary_evidence(silent_report)
        require(all(accepted[key] is True for key in ("app_kernel_eperm", "marker_inode_size_mtime_unchanged",
                    "seven_roots_updates_zero", "preferences_same")), "SELF_TEST", "静默成功路径未报告四证全真", 70)
        bad = deepcopy(silent_report)
        bad["configuration"]["kernelWriteProbe"]["errno"] = errno.EACCES
        expect_failure("ISOLATION_FOUR_EVIDENCE", lambda: missing_canary_evidence(bad))
        for position in (1, 2, 3):
            bad = deepcopy(silent_report)
            bad["marker_state"]["after"][position] += 1
            expect_failure("ISOLATION_FOUR_EVIDENCE", lambda: missing_canary_evidence(bad))
        bad = deepcopy(silent_report)
        bad["metadata"][-1]["changes"] = [{"path": "synthetic-change", "mtime_ns": 1}]
        expect_failure("ISOLATION_FOUR_EVIDENCE", lambda: missing_canary_evidence(bad))
        bad = deepcopy(silent_report)
        bad["metadata"].pop()
        expect_failure("ISOLATION_FOUR_EVIDENCE", lambda: missing_canary_evidence(bad))
        bad = deepcopy(silent_report)
        bad["preferences"] = {"status": "changed", "changed_keys": ["synthetic"]}
        expect_failure("ISOLATION_FOUR_EVIDENCE", lambda: missing_canary_evidence(bad))
        checks.append("missing-canary-four-independent-proofs")
        metadata_error = metadata_since(
            [(allowed / "escape", allowed / "escape"), (base / "missing", base / "missing")],
            marker, {str(allowed / "escape"): True, str(base / "missing"): False})
        require(metadata_error[0].get("error") == "METADATA" and metadata_error[1]["missing"],
                "SELF_TEST", "一根核验失败后没有继续记录其余根", 70)
        checks.append("metadata-failure-red-with-other-roots-still-scanned")
        expect_failure("EVIDENCE_LIMIT", lambda: capture(
            [sys.executable, "-I", "-c", "print('x'*8192)"], limit=128))
        checks.append("bounded-helper-output")
        require(sys.platform == "darwin", "SELF_TEST", "内核护栏自测需要 macOS", 70)
        # 不在七根读保护中的合成目录也必须不可写，避免把写黑名单误当白名单。
        unlisted = base / "synthetic-unlisted"
        unlisted.mkdir(mode=0o700)
        outside_existing = unlisted / "absolute-existing"
        outside_existing.write_text(secret, encoding="utf-8")
        escaped = allowed / "escape/synthetic-unlisted"
        helper = (
            "import errno,json,os,socket,sys\n"
            "root,protected,unlisted,escaped,shared=sys.argv[1:6]\n"
            "def denied(operation):\n"
            " try:\n  operation(); raise SystemExit(9)\n"
            " except OSError as e:\n"
            "  if e.errno not in (errno.EPERM,errno.EACCES): raise SystemExit(10)\n"
            "def write(path):\n"
            " with open(path,'wb') as handle: handle.write(b'synthetic')\n"
            "def network():\n"
            " s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)\n"
            " try: s.connect(('127.0.0.1',9))\n"
            " finally: s.close()\n"
            "directory=os.path.join(root,'kernel-allowed')\n"
            "os.mkdir(directory)\n"
            "created=os.path.join(directory,'created')\n"
            "renamed=os.path.join(directory,'renamed')\n"
            "write(created); os.rename(created,renamed); os.unlink(renamed); os.rmdir(directory)\n"
            "for path in (protected,os.path.join(unlisted,'absolute-existing'),\n"
            "             os.path.join(unlisted,'absolute-new'),\n"
            "             os.path.join(os.path.dirname(unlisted),'absolute-outside-root'),\n"
            "             os.path.join(escaped,'absolute-existing'),\n"
            "             os.path.join(escaped,'new-via-ancestor-symlink'),shared):\n"
            " denied(lambda path=path: write(path))\n"
            "denied(lambda: os.mkdir(os.path.join(unlisted,'new-directory')))\n"
            "denied(lambda: os.unlink(shared))\n"
            "denied(lambda: open(protected,'rb'))\n"
            "denied(network)\n"
            "with open(os.path.join(unlisted,'absolute-existing'),'rb') as handle:\n"
            " if not handle.read(): raise SystemExit(11)\n"
            "with open(shared,'rb') as handle:\n"
            " if not handle.read(): raise SystemExit(12)\n"
            "for exception in json.loads(sys.argv[6]):\n"
            " fd=os.open(exception['path'],os.O_WRONLY)\n"
            " try:\n"
            "  if os.write(fd,b'synthetic')!=9: raise SystemExit(13)\n"
            " finally: os.close(fd)\n")
        # getconf 只查询原生共享 temporaryDirectory 的路径；不枚举、不读取其他人的样本。
        native_tmp_text = os.fsdecode(checked_capture(
            ["/usr/bin/getconf", "DARWIN_USER_TEMP_DIR"], limit=4096)).rstrip("\n")
        native_tmp = Path(native_tmp_text)
        require(native_tmp.is_absolute() and "\n" not in native_tmp_text,
                "SELF_TEST", "无法确定原生共享临时目录", 70)
        native_tmp = native_tmp.resolve(strict=True)
        require(not within(native_tmp, allowed), "SELF_TEST", "共享临时样本必须位于白名单根外", 70)
        with tempfile.NamedTemporaryFile(prefix="tty-graphics-protocol-mp-isolation-",
                                         dir=native_tmp) as shared_sample:
            shared_sample.write(secret.encode("utf-8"))
            shared_sample.flush()
            checked_capture(
                [TOOLS["sandbox"], "-p", sandbox_profile(allowed, [protected]), sys.executable,
                 "-I", "-c", helper, str(allowed), str(changed), str(unlisted), str(escaped),
                 shared_sample.name, json.dumps(SYSTEM_WRITE_EXCEPTIONS[:1])],
                env=clean_environment(allowed / "home", allowed / "tmp"))
            require(Path(shared_sample.name).read_text(encoding="utf-8") == secret
                    and outside_existing.read_text(encoding="utf-8") == secret,
                    "SELF_TEST", "根外合成样本被修改或删除", 70)
        checks.extend(("kernel-allows-bench-root-create-write-rename-unlink",
                       "kernel-denies-unlisted-absolute-existing-and-new-writes",
                       "kernel-denies-ancestor-symlink-write-escape",
                       "kernel-denies-native-shared-tmp-tty-graphics-protocol-write-and-unlink",
                       "kernel-preserves-read-policy-and-denies-socket",
                       "kernel-allows-only-documented-system-device-data-writes"))
        child_helper = ("import subprocess,sys,time; "
                        "subprocess.Popen([sys.executable,'-I','-c','import time;time.sleep(30)']);"
                        "time.sleep(30)")
        proc = subprocess.Popen([sys.executable, "-I", "-c", child_helper],
                                cwd=allowed, env=clean_environment(allowed, allowed),
                                stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                stderr=subprocess.DEVNULL, start_new_session=True)
        tree = None
        try:
            tree = OwnedTree(proc)
            deadline = time.monotonic() + 5
            while tree.max_processes < 2 and time.monotonic() < deadline:
                tree.audit()
                time.sleep(0.05)
            require(tree.max_processes >= 2, "SELF_TEST", "合成子进程没有进入审计树", 70)
            tree.arm(0.1)
            expect_failure("TIMEOUT", lambda: monitor(tree, 0.1))
        finally:
            if tree is not None:
                tree.stop()
            elif proc.poll() is None:
                proc.kill()
            proc.wait(timeout=5)
        require(proc.poll() is not None, "SELF_TEST", "合成 helper 未回收", 70)
        checks.append("lifecycle-lsof-timeout-owned-pid-cleanup")
        check_fixture(fixture)
        proc = subprocess.Popen([sys.executable, "-I", "-c", "import time;time.sleep(30)"],
                                cwd=allowed, env=clean_environment(allowed, allowed),
                                stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                stderr=subprocess.DEVNULL, start_new_session=True)
        tree = OwnedTree(proc)
        try:
            tree.arm(5)
            import itertools
            ticks = itertools.count(0, 0.1)
            result = monitor(tree, 5, lambda: bool(check_configuration(
                allowed, 12345, "seed", marker, {fixture_id}, DEFAULT_SWITCHES)),
                observe_seconds=0.2, _clock=lambda: next(ticks))
            require(result is None and tree.observed_seconds >= 0.2 and not tree.expired.is_set(),
                    "SELF_TEST", "合成启动 report 未经过完整受控观察窗", 70)
        finally:
            tree.stop()
            proc.wait(timeout=5)
        checks.append("verified-report-completes-probe-before-timeout")
        proc = subprocess.Popen(["/usr/bin/true"], stdin=subprocess.DEVNULL,
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                start_new_session=True, env=clean_environment(allowed, allowed))
        tree = OwnedTree(proc)
        try:
            tree.arm(5)
            ticks = itertools.count(0, 0.1)
            expect_failure("EARLY_EXIT", lambda: monitor(
                tree, 5, lambda: True, observe_seconds=1, _clock=lambda: next(ticks)))
        finally:
            tree.stop()
            proc.wait(timeout=5)
        checks.append("early-helper-exit-before-controlled-observation-is-red")
    report.update({"status": "GREEN", "checks": checks, "synthetic_only": True,
                   "kernel_policy": KERNEL_POLICY,
                   "kernel_write_exceptions": list(SYSTEM_WRITE_EXCEPTIONS)})
    self_test_pty(report)


def self_test_pty(report):
    with tempfile.TemporaryDirectory(prefix="pty-selftest-", dir=ROOT_PARENT) as name:
        root = Path(name).resolve()
        checked_capture([TOOLS["sandbox"], "-p", sandbox_profile(root, []), sys.executable, "-I", "-c",
                         "import os; m,s=os.openpty(); os.write(s,b'PTY'); assert os.read(m,3)==b'PTY'"],
                        env=clean_environment(root / "home", root / "tmp"))
    report.setdefault("checks", []).append("kernel-real-pty-master-slave-data")
    report.update(status="GREEN", synthetic_only=True)


def self_test_missing_canary(report):
    sample = {"pid": 123, "marker": "/synthetic/marker",
              "kernel_write_audit": {"system_sandbox_line_count": 147, "controlled_probe_visible": False},
              "configuration": {"kernelWriteProbe": {"pid": 123, "path": "/synthetic/marker",
                                "errno": errno.EPERM, "operation": "file-write-data"}},
              "marker_state": {"before": [1, 2, 0, 3], "after": [1, 2, 0, 3]},
              "metadata": [{"root": "/synthetic/" + str(i), "changes": []} for i in range(7)],
              "preferences": {"status": "same", "changed_keys": []}}
    accepted = missing_canary_evidence(sample)
    require(all(accepted[key] is True for key in ("app_kernel_eperm", "marker_inode_size_mtime_unchanged",
                "seven_roots_updates_zero", "preferences_same")), "SELF_TEST", "活跃通道四证未收下", 70)
    sample["preferences"] = {"status": "changed", "changed_keys": ["synthetic"]}
    try:
        missing_canary_evidence(sample)
    except Failure as failure:
        require(failure.category == "ISOLATION_FOUR_EVIDENCE", "SELF_TEST", "四证拒绝分类错误", 70)
    else:
        raise Failure(70, "SELF_TEST", "活跃通道缺一项证据仍错误通过")
    report.update({"status": "GREEN", "checks": ["active-channel-missing-canary-four-evidence"],
                   "only_new_case": True, "synthetic_only": True})

def self_test_claude_noise(report):
    from copy import deepcopy
    sample = {"pid": 123, "marker": "/synthetic/marker",
              "kernel_write_audit": {"controlled_probe_visible": False},
              "configuration": {"kernelWriteProbe": {"pid": 123, "path": "/synthetic/marker",
                                "errno": errno.EPERM, "operation": "file-write-data"}},
              "marker_state": {"before": [1, 2, 0, 3], "after": [1, 2, 0, 3]},
              "metadata": [{"root": "/synthetic/" + str(i), "changes": []} for i in range(7)],
              "preferences": {"status": "same", "changed_keys": []}}
    sample["metadata"][0] = {"root": str(Path(pwd.getpwuid(os.getuid()).pw_dir) / ".claude"),
                             "changes": [{"path": "synthetic-noise", "mtime_ns": 1}],
                             "mtime_ignored_for_verdict": True}
    require(missing_canary_evidence(sample)["seven_roots_updates_zero"], "SELF_TEST", "已裁决噪声被误拒", 70)
    for key, value in (("root", "/synthetic/other"), ("disappeared", True),
                       ("mtime_ignored_for_verdict", False), ("changes", None)):
        bad = deepcopy(sample)
        bad["metadata"][0][key] = value
        try:
            missing_canary_evidence(bad)
        except Failure as failure:
            require(failure.category == "ISOLATION_FOUR_EVIDENCE", "SELF_TEST", "根变化拒绝分类错误", 70)
        else:
            raise Failure(70, "SELF_TEST", "豁免错误扩到其它根/消失/未裁决变化")
    report.update({"status": "GREEN", "checks": ["four-evidence-respects-only-authorized-claude-mtime-noise"],
                   "only_new_case": True, "synthetic_only": True})


def self_test_log_counts(report):
    start = datetime.datetime(2026, 1, 1, tzinfo=datetime.timezone.utc)
    end = start + datetime.timedelta(seconds=2)
    marker = Path("/synthetic/marker")
    event = {"timestamp": (start + datetime.timedelta(seconds=1)).isoformat(), "eventType": "logEvent",
             "processID": 0, "processImagePath": "/kernel",
             "senderImagePath": "/System/Library/Extensions/Sandbox.kext/Contents/MacOS/Sandbox",
             "eventMessage": "Sandbox: bench(12345) deny(1) file-write-data " + str(marker)}
    foreign = [{**event, "eventMessage": "Sandbox: other(54321) deny(1) file-read-data /FOREIGN_PRIVATE/" + str(i)}
               for i in range(MAX_ITEMS + 1)]
    own = [event] + [{**event, "eventMessage": "Sandbox: bench(12345) deny(1) file-write-data /synthetic/" + str(i)}
                     for i in range(MAX_ITEMS)]
    def fixture(rows):
        return ("\n".join(json.dumps(row) for row in rows + [{"finished": 1, "count": len(rows)}]) + "\n").encode()
    accepted = parse_sandbox_writes(fixture(foreign + own[:MAX_ITEMS]), 12345, start, end, marker)
    require(accepted["system_sandbox_line_count"] == 2 * MAX_ITEMS + 1
            and len(accepted["events"]) == MAX_ITEMS and accepted["controlled_probe_visible"]
            and "FOREIGN_PRIVATE" not in json.dumps(accepted),
            "SELF_TEST", "全机多行应仅计数，本PID恰好上限证据必须完整且不泄漏其他PID", 70)
    for rows, category in ((foreign + own, "EVIDENCE_LIMIT"),
                           (foreign + [{"eventType": "lossEvent"}], "KERNEL_LOG_LOSS"),
                           (foreign + [{**event, "timestamp": "bad"}], "KERNEL_LOG")):
        try:
            parse_sandbox_writes(fixture(rows), 12345, start, end, marker)
        except Failure as failure:
            require(failure.category == category, "SELF_TEST", "本PID超限/丢失/格式错未保持RED", 70)
        else:
            raise Failure(70, "SELF_TEST", "本PID超限/丢失/格式错错误通过")
    report.update({"status": "GREEN", "checks": ["global-count-only-subject-limit"],
                   "only_new_case": True, "synthetic_only": True})



def self_test_stream_ready(report):
    stream = SandboxWriteStream()
    try:
        complete = bytes(stream.output).rsplit(b"\n", 1)[0].splitlines()
        events = [json.loads(line) for line in complete
                  if line.strip() and not line.startswith(b"Filtering the log data using ")]
        require(any(isinstance(row, dict) and isinstance(row.get("eventMessage"), str)
                    and stream.readiness_marker in row["eventMessage"] for row in events),
                "SELF_TEST", "未在真实日志事件中见到本轮logger串；不能用过滤声明冒充就绪", 70)
        require(0 <= stream.readiness["wait_seconds"] <= 15.0, "SELF_TEST", "订阅握手超过15秒", 70)
        report.update({"status": "GREEN", "checks": ["logger-stream-roundtrip-before-app"],
                       "only_new_case": True, "bench_app_started": False, "readiness": stream.readiness})
    finally:
        stream.close()


def parser():
    result = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = result.add_subparsers(dest="command", required=True)
    for name in ("preflight", "run"):
        command = commands.add_parser(name)
        command.add_argument("--app", required=True)
        command.add_argument("--root", required=True)
        command.add_argument("--uuid", action="append", required=True, help="每个架构的预期 UUID，各重复一次")
        command.add_argument("--seed", help="R1-0 必须显式为 isolation；不支持旧 root 复用")
        if name == "run":
            command.add_argument("--window-approved", action="store_true", help="只可在车头开窗并给租约命令后使用")
            command.add_argument("--force-self-sample", action="store_true", help="要求PERF_BENCH包进程内真实自采完成才开始观察")
            command.add_argument("--timeout", type=float, default=60, help="1..900 秒，默认 60")
            command.add_argument("--observe-seconds", type=float, default=30,
                                 help="report 严格核验后的完整观察窗，1..300 秒，默认 30")
    commands.add_parser("self-test")
    commands.add_parser("pty-self-test")
    commands.add_parser("stream-ready-self-test")
    commands.add_parser("missing-canary-self-test")
    commands.add_parser("log-count-self-test")
    commands.add_parser("claude-noise-self-test")
    return result


def main(argv=None):
    args = parser().parse_args(argv)
    report = {"command": args.command, "status": "RED", "limitations": LIMITATIONS}
    previous = {}
    try:
        if args.command == "run":
            require(args.window_approved, "WINDOW_REQUIRED", "BLOCKED：等粟粟说现在测")
            require(math.isfinite(args.timeout) and 1 <= args.timeout <= 900,
                    "CONFIG", "timeout 必须是 1..900 秒")
            require(math.isfinite(args.observe_seconds) and 1 <= args.observe_seconds <= 300
                    and args.timeout > args.observe_seconds, "CONFIG",
                    "observe-seconds 必须是 1..300 秒且 timeout 必须更长")
            def interrupted(signum, frame):
                raise Failure(130, "INTERRUPTED", "收到中断；仅回收自己启动的进程树")
            previous = {sig: signal.signal(sig, interrupted) for sig in (signal.SIGINT, signal.SIGTERM)}
            perform_run(args, report)
        elif args.command == "preflight":
            config = preflight(args)
            report.update({"status": "READY", "app": str(config["app"]),
                           "root": str(config["root"]), "expected_uuids": config["expected_uuids"],
                           "role": config["role"], "not_runtime_proof": True})
        elif args.command == "pty-self-test":
            self_test_pty(report)
            report["only_new_case"] = True
        elif args.command == "stream-ready-self-test":
            self_test_stream_ready(report)
        elif args.command == "missing-canary-self-test":
            self_test_missing_canary(report)
        elif args.command == "log-count-self-test":
            self_test_log_counts(report)
        elif args.command == "claude-noise-self-test":
            self_test_claude_noise(report)
        else:
            self_test(report)
    except Failure as failure:
        record_failure(report, failure)
    except (Exception, KeyboardInterrupt):
        record_failure(report, Failure(70, "INPUT_OR_TOOL_FAILURE", "输入/工具失败；原始异常未披露"))
    finally:
        for sig, handler in previous.items():
            signal.signal(sig, handler)
    return emit(report)


if __name__ == "__main__":
    sys.exit(main())
