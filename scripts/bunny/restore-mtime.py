#!/usr/bin/env python3
"""[Bunny] 把工作区文件的 mtime 设成「最后一次改动它的提交时间」。
CI 每次 checkout 都会把 mtime 刷成当前时间，Xcode / Swift 增量编译据此判断文件变了，缓存的 DerivedData 就白存了。
一次 git log 扫完全部历史，不逐文件调用 git。需要 fetch-depth: 0。"""
import os, subprocess
seen = {}
ts = None
out = subprocess.run(["git", "log", "--pretty=format:@%ct", "--name-only", "-z", "--no-renames"],
                     capture_output=True, check=True).stdout.decode("utf-8", "surrogateescape")
for tok in out.split("\0"):
    for line in tok.split("\n"):
        if line.startswith("@"):
            ts = int(line[1:])
        elif line and line not in seen:
            seen[line] = ts
n = 0
for path, t in seen.items():
    if os.path.isfile(path) and not os.path.islink(path):
        os.utime(path, (t, t)); n += 1
print(f"restore-mtime: {n} files")
