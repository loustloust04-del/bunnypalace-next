#!/usr/bin/env python3
"""把 fakefs rootfs 打成 iOS bundle 用的 zip。

用 python3 zipfile 而不是 macOS 的 /usr/bin/zip：后者是 Apple 阉割版 Info-ZIP，
不给非 ASCII 路径设 GP bit 11（UTF-8 flag），iOS 侧 ZIPFoundation 会按 CP437
解码成乱码。zipfile 对非 ASCII 名字自动设 0x800。

产出结构（与 RootfsManager / SandboxT0Probe 的解压逻辑对齐）：
    alpine-rootfs/meta.db
    alpine-rootfs/data/...
"""
import os
import sys
import zipfile

SKIP_SUFFIXES = (".db-shm", ".db-wal")
REQUIRED = ("alpine-rootfs/meta.db", "alpine-rootfs/data/etc/resolv.conf")


def main() -> int:
    src, dst = sys.argv[1], sys.argv[2]
    base = os.path.dirname(src)
    files = 0
    dirs = 0
    links = []

    with zipfile.ZipFile(dst, "w", zipfile.ZIP_DEFLATED) as z:
        for root, subdirs, filenames in os.walk(src):
            subdirs.sort()
            filenames.sort()
            z.write(root, os.path.relpath(root, base) + "/")
            dirs += 1
            for name in filenames:
                if name.endswith(SKIP_SUFFIXES):
                    continue
                path = os.path.join(root, name)
                if os.path.islink(path):
                    # fakefs 把 guest symlink 存成「内容是目标路径的普通文件」，
                    # data/ 里出现真 symlink 说明转换出了问题
                    links.append(path)
                    continue
                z.write(path, os.path.relpath(path, base))
                files += 1

    if links:
        print(f"❌ fakefs data/ 里出现真符号链接（不该有）：{links[:5]}", file=sys.stderr)
        return 1

    with zipfile.ZipFile(dst) as z:
        names = set(z.namelist())
        for required in REQUIRED:
            if required not in names:
                print(f"❌ zip 里缺 {required}", file=sys.stderr)
                return 1
        bad = [
            i.filename
            for i in z.infolist()
            if not (i.flag_bits & 0x800) and any(ord(c) > 127 for c in i.filename)
        ]
        if bad:
            print(f"❌ 非 ASCII 路径没设 UTF-8 flag：{bad[:5]}", file=sys.stderr)
            return 1

    print(f"zip OK: {files} files + {dirs} dirs")
    return 0


if __name__ == "__main__":
    sys.exit(main())
