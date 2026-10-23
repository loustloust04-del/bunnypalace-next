#!/usr/bin/env python3
"""prepare-rootfs.sh 的 meta.db 断言：确认配置文件真的进了 fakefs 的 inode 表。

fakefs 只认 meta.db 里登记过的 inode——转换完成后往 data/ 里新建文件是无效操作
（08-25 探针实证：guest 里 `cat /etc/resolv.conf` → No such file or directory）。
这个断言就是防止那条路悄悄回归。
"""
import sqlite3
import sys

MUST_EXIST = [
    b"/etc/resolv.conf",   # ← Alpine tar 里没有，上游漏的就是它
    b"/etc/apk/repositories",
    b"/etc/profile",
    b"/etc/motd",
    b"/etc/passwd",
    b"/root",
    b"/tmp",
    b"/mnt",
    b"/mnt/library",       # T3a：文件库挂载点，bind mount 要求父目录在 meta.db 里
]


def main() -> int:
    db = sys.argv[1]
    conn = sqlite3.connect(db)
    missing = []
    for path in MUST_EXIST:
        n = conn.execute("select count(*) from paths where path = ?", (path,)).fetchone()[0]
        if n != 1:
            missing.append((path.decode(), n))
    total = conn.execute("select count(*) from paths").fetchone()[0]
    conn.close()

    if missing:
        for path, n in missing:
            print(f"❌ meta.db 里 {path} 的条目数 = {n}（应为 1）", file=sys.stderr)
        return 1
    print(f"meta.db OK: {total} paths, 关键条目 {len(MUST_EXIST)}/{len(MUST_EXIST)} 全在")
    return 0


if __name__ == "__main__":
    sys.exit(main())
