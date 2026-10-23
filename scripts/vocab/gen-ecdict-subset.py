#!/usr/bin/env python3
# R3.4b 内嵌词典：从 ECDICT 全量 CSV（MIT，skywind3000/ECDICT）裁出
# 我们词表（NGSL 13k + 雅思 5.3k）的子集 → bundle JSON（音标/中文释义/词形）。
# 用法：python3 gen-ecdict-subset.py <ecdict.csv 路径>
# 产物：MemoryPalace/Resources/ngsl/ecdict_subset.json
import csv, json, sys, os

csv.field_size_limit(10_000_000)
script_dir = os.path.dirname(os.path.abspath(__file__))
repo = os.path.dirname(os.path.dirname(script_dir))
res = os.path.join(repo, "MemoryPalace", "Resources", "ngsl")

words = set()
with open(os.path.join(res, "vocab_gap_words.json")) as f:
    for e in json.load(f):
        words.add(e["word"].strip().lower())
        for form in e.get("forms") or []:
            words.add(form.strip().lower())
with open(os.path.join(res, "ielts_wordlist.txt")) as f:
    for line in f:
        w = line.strip().lower()
        if w:
            words.add(w)

src = sys.argv[1]
out = {}
with open(src, newline="", encoding="utf-8") as f:
    for row in csv.DictReader(f):
        w = (row.get("word") or "").strip().lower()
        if w in words and w not in out:
            entry = {}
            if row.get("phonetic"): entry["p"] = row["phonetic"]
            if row.get("translation"): entry["t"] = row["translation"].replace("\\n", "\n")
            if row.get("exchange"): entry["x"] = row["exchange"]
            if entry.get("t"):
                out[w] = entry

dst = os.path.join(res, "ecdict_subset.json")
with open(dst, "w", encoding="utf-8") as f:
    json.dump(out, f, ensure_ascii=False, separators=(",", ":"))
print(f"词表 {len(words)} → 命中 {len(out)}，写 {dst}（{os.path.getsize(dst)//1024}KB）")
