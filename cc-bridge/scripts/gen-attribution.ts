// 生成 ATTRIBUTION.md 的第三方 npm 段：bun scripts/gen-attribution.ts（升依赖后手动重跑，不挂进 build）
// 对 hub.ts / mcp-server.ts 跑 Bun.build 取 metafile，只算真被打包的 node_modules 包（external 如 ws 不算）
import { readFileSync, readdirSync, writeFileSync } from "fs";
import { tmpdir } from "os";
import { join, resolve } from "path";

const ROOT = resolve(import.meta.dir, "..");
const OUT = join(ROOT, "ATTRIBUTION.md");
const BEGIN = "<!-- BEGIN GENERATED -->";
const END = "<!-- END GENERATED -->";
const ENTRIES: Record<string, string> = { hub: "hub.ts", "mcp-server": "mcp-server.ts" };

type Pkg = { name: string; version: string; license: string; dir: string; bins: Set<string>; author?: string };
const pkgs = new Map<string, Pkg>();

process.chdir(ROOT);
for (const [bin, entry] of Object.entries(ENTRIES)) {
  const r = await Bun.build({ entrypoints: [join(ROOT, entry)], target: "bun", metafile: true, outdir: join(tmpdir(), `gen-attribution-${bin}`) });
  if (!r.success || !r.metafile) throw new Error(`${entry} build failed:\n${r.logs.join("\n")}`);
  const seen = new Set<string>();
  for (const input of Object.keys(r.metafile.inputs)) {
    const m = input.match(/^(.*node_modules\/(?:@[^/]+\/)?[^/]+)\//);
    if (!m) continue;
    const dir = resolve(ROOT, m[1]);
    const pj = JSON.parse(readFileSync(join(dir, "package.json"), "utf8"));
    const key = `${pj.name}@${pj.version}`;
    seen.add(key);
    const lic = typeof pj.license === "string" ? pj.license : pj.license?.type ?? "UNKNOWN";
    const author = typeof pj.author === "string" ? pj.author : pj.author?.name;
    const p = pkgs.get(key) ?? { name: pj.name, version: pj.version, license: lic, dir, bins: new Set(), author };
    p.bins.add(bin);
    pkgs.set(key, p);
  }
  console.log(`${bin}: ${seen.size} packages`);
}
console.log(`total (dedup): ${pkgs.size} packages`);

const findFile = (dir: string, re: RegExp) => {
  const f = readdirSync(dir).find((n) => re.test(n));
  return f ? readFileSync(join(dir, f), "utf8").trim() : undefined;
};
const licenseText = (p: Pkg) => findFile(p.dir, /^(LICEN[CS]E|COPYING)(\.(md|txt))?$/i);
const noticeText = (p: Pkg) => findFile(p.dir, /^NOTICE(\.(md|txt))?$/i);
const copyrights = (p: Pkg) => {
  const all = (licenseText(p) ?? "").split("\n").map((l) => l.trim());
  const lines: string[] = [];
  all.forEach((l, i) => {
    if (!/^(copyright|©)/i.test(l) || !/\(c\)|©|\d{4}/i.test(l) || /\[yyyy\]/i.test(l)) return;
    let s = l; // "Copyright (c) 2011:" 后面几行才是人名
    if (l.endsWith(":")) for (let j = i + 1; all[j]; j++) s += " " + all[j];
    lines.push(s);
  });
  return lines.length ? lines.join("；") : `（LICENSE 无版权行；package.json author: ${p.author || "未声明"}）`;
};
const bins = (p: Pkg) => [...p.bins].sort().join(", ");
const fence = (t: string) => "```\n" + t + "\n```";

const sorted = [...pkgs.values()].sort((a, b) => a.name.localeCompare(b.name));
const groups = new Map<string, Pkg[]>();
for (const p of sorted) groups.set(p.license, [...(groups.get(p.license) ?? []), p]);

const out: string[] = [
  "## 6. 打包进二进制的 npm 依赖（脚本生成，勿手改）",
  "",
  `由 \`bun scripts/gen-attribution.ts\` 从 hub.ts / mcp-server.ts 的 Bun.build metafile 生成：共 ${pkgs.size} 个包` +
    `（${Object.keys(ENTRIES).map((b) => `${b} ${sorted.filter((p) => p.bins.has(b)).length}`).join("、")}）。` +
    "版本取 node_modules 内 package.json；被 Bun 内置实现替换的 external 依赖（如 ws）不在此列。",
];
for (const [lic, list] of [...groups].sort(([a], [b]) => a.localeCompare(b))) {
  out.push("", `### ${lic}（${list.length}）`);
  if (lic === "Apache-2.0") {
    out.push("", "| 包 | 版本 | 进哪个二进制 | 版权 |", "|---|---|---|---|");
    for (const p of list) out.push(`| ${p.name} | ${p.version} | ${bins(p)} | ${copyrights(p)} |`);
    const src = list.find((p) => /END OF TERMS AND CONDITIONS/.test(licenseText(p) ?? ""));
    if (src) {
      const full = licenseText(src)!;
      const tail = "END OF TERMS AND CONDITIONS";
      out.push("", `Apache License 2.0 条文（各包共用，此处取自 ${src.name} 的 LICENSE）：`, "", fence(full.slice(0, full.indexOf(tail) + tail.length)));
    }
  } else {
    for (const p of list) {
      out.push("", `#### ${p.name} ${p.version}`, "", `- 进哪个二进制：${bins(p)}`);
      const text = licenseText(p);
      if (text) out.push(`- 版权：${copyrights(p)}`, "", fence(text));
      else out.push(`- 包内无 LICENSE 文件，按 package.json 声明：${lic}，author: ${p.author ?? "未声明"}`);
    }
  }
  for (const p of list) {
    const notice = noticeText(p);
    if (notice) out.push("", `${p.name} NOTICE：`, "", fence(notice));
  }
}

const doc = readFileSync(OUT, "utf8");
const [b, e] = [doc.indexOf(BEGIN), doc.indexOf(END)];
if (b < 0 || e < b) throw new Error(`ATTRIBUTION.md 缺少 ${BEGIN} / ${END} 标记`);
writeFileSync(OUT, doc.slice(0, b + BEGIN.length) + "\n" + out.join("\n") + "\n" + doc.slice(e));
console.log([...groups].map(([l, ps]) => `${l}: ${ps.map((p) => p.name).join(", ")}`).join("\n"));
