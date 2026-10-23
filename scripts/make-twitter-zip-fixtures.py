#!/usr/bin/env python3
"""生成推特导出包形态的 zip 测试夹具（fixtures/twitter-zip/）。

推特官方导出包的特征（2026-09 实测粟粟的真存档）：
- 每个条目都走 ZIP64：头里的大小/偏移全填 0xFFFFFFFF，真值放 ZIP64 扩展字段
- 第一个条目 `data/` 的真实偏移是 0
- 通用标志 0x808：数据描述符 + UTF-8 文件名
- Unix 权限位不带文件类型（zipinfo 显示 `?rw-------`）
ZIPFoundation 0.9.20 把 ZIP64 字段里的 0 偏移当成「没填」，退回 0xFFFFFFFF，
于是第一个条目就读不到、整个遍历停掉——读出 0 个文件。

用法：python3 scripts/make-twitter-zip-fixtures.py
"""
import os, struct, zlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "fixtures", "twitter-archive")
OUT = os.path.join(ROOT, "fixtures", "twitter-zip")
FF = 0xFFFFFFFF


def twitter_style_zip(entries):
    """entries: [(name, bytes|None)]，None 表示目录。全部按推特的写法落盘。"""
    out = bytearray()
    central = bytearray()
    for name, data in entries:
        raw = name.encode("utf-8")
        payload = data or b""
        method = 8
        if name.endswith(".stored"):
            method, comp = 0, payload
        else:
            c = zlib.compressobj(9, zlib.DEFLATED, -15)
            comp = c.compress(payload) + c.flush()
        crc = zlib.crc32(payload) & FF
        offset = len(out)
        local_extra = struct.pack("<HHQQ", 1, 16, 0, 0)
        out += struct.pack("<IHHHHHIIIHH", 0x04034B50, 45, 0x808, method, 20260, 23862,
                           0, FF, FF, len(raw), len(local_extra))
        out += raw + local_extra + comp
        out += struct.pack("<IIQQ", 0x08074B50, crc, len(comp), len(payload))
        mode = 0o700 if data is None else 0o600          # 不带 S_IFDIR / S_IFREG
        eattr = (mode << 16) | (0x10 if data is None else 0)
        cd_extra = struct.pack("<HHQQQ", 1, 24, len(payload), len(comp), offset)
        central += struct.pack("<IHHHHHHIIIHHHHHII", 0x02014B50, 0x032D, 45, 0x808, method,
                               20260, 23862, crc, FF, FF, len(raw), len(cd_extra), 0, 0, 0,
                               eattr, FF)
        central += raw + cd_extra
    cd_off = len(out)
    out += central
    z64 = len(out)
    n = len(entries)
    out += struct.pack("<IQHHIIQQQQ", 0x06064B50, 44, 45, 45, 0, 0, n, n, len(central), cd_off)
    out += struct.pack("<IIQI", 0x07064B50, 0, z64, 1)
    out += struct.pack("<IHHHHIIH", 0x06054B50, 0, 0, n, n, len(central), cd_off, 0)
    return bytes(out)


def main():
    os.makedirs(OUT, exist_ok=True)
    entries = [("data/", None), ("Your archive.html", b"<html></html>")]
    for dirpath, dirnames, filenames in sorted(os.walk(SRC)):
        dirnames.sort()
        rel = os.path.relpath(dirpath, SRC)
        if rel != ".":
            entries.append((rel.replace(os.sep, "/") + "/", None))
        for f in sorted(filenames):
            if f.startswith("."):
                continue
            path = os.path.join(dirpath, f)
            name = os.path.relpath(path, SRC).replace(os.sep, "/")
            entries.append((name, open(path, "rb").read()))
    # 导入用不着、也不该解出来的：私信媒体
    entries.append(("data/direct_messages_media/", None))
    entries.append(("data/direct_messages_media/123-secret.jpg", b"not for us"))
    # 一个不压缩（stored）的条目，走另一条解码分支
    entries.append(("data/README.txt.stored", b"stored entry body"))
    with open(os.path.join(OUT, "twitter-style.zip"), "wb") as f:
        f.write(twitter_style_zip(entries))

    # 路径穿越：解压器必须拒绝写到目标目录之外
    with open(os.path.join(OUT, "zip-slip.zip"), "wb") as f:
        f.write(twitter_style_zip([("data/", None), ("data/../../evil.js", b"x"),
                                   ("data/account.js", b"window.YTD.account.part0 = []")]))


def pull_sample():
    """从 X 拉的包：跟 scripts/twitter-pull.py 一样用 zipfile 打——清单 deflate、媒体 stored。
    App 端的解压器是自写的，要保证它认得 Python 打的包。"""
    import json, zipfile
    manifest = {
        "format": "memorypalace.twitter-pull", "version": 1, "pulledAt": "2026-09-24T08:00:00Z",
        "me": {"screenName": "susu_test", "name": "禾禾"},
        "folders": [{"id": "f1", "name": "学习"}],
        "bookmarks": [{"id": "900", "author": "AndrewYNg", "name": "Andrew Ng", "text": "Learn &amp; build",
                       "likes": 5, "retweets": 1, "created_at": "Wed Oct 10 20:19:24 +0000 2018",
                       "url": "https://x.com/AndrewYNg/status/900", "folderIds": ["f1"],
                       "media": [{"file": "900-0.jpg", "kind": "photo"}]}],
        "likes": [], "tweets": [],
    }
    with zipfile.ZipFile(os.path.join(OUT, "pull-sample.zip"), "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("twitter-pull.json", json.dumps(manifest, ensure_ascii=False))
        z.writestr("twitter-pull-media/900-0.jpg", b"\xff\xd8\xff fake jpeg", compress_type=zipfile.ZIP_STORED)


if __name__ == "__main__":
    main()
    pull_sample()
