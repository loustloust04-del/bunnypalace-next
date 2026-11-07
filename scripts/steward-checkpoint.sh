#!/bin/bash
# Warden 的 checkpoint 推送（粟粟 10-14「真到 checkpoint 再推」「以后每次真推之前问我」）：合并只落本地 master，
# origin（GitHub MemoryPalace）只在这里推。两段式——管家跑在 Claude 的 Bash 里没 tty，不能交互确认：
#   steward-checkpoint.sh --why "<理由>"    第 1 步：只检查、不推。fetch → 算 origin/master..master → gitleaks + 媒体 / 取证路径兜底
#                                          → 打印给粟粟看的摘要 → 全过才写待确认记录 $LOG/checkpoint-<id>.pending
#   steward-checkpoint.sh --confirm <id>   第 2 步：粟粟本人明确说「推」之后才跑（别人转述的不算；不能自动接在第 1 步后面）。
#                                          记录在、不超过 30 分钟、master 和 origin/master 都跟记录一致 → 重扫一遍 → push → 删记录 → 记 stewards.md。
#                                          对不上 / 过期 / 扫描命中：拒绝并作废记录，从第 1 步重来
# 只许 Warden（MP_STEWARD=1）在主仓 master 上跑。绝不 --force：origin/master 不是 master 的祖先就拒。docs/steward-runbook.md「checkpoint」
# 最后一行：RESULT nothing | RESULT checked <id> n=<N> range=<o>..<m> | RESULT pushed <id> n=<N> range=<o>..<m> | RESULT refused <原因>
# 退出码：0 = nothing / checked / pushed；65 = refused；64 = 用法
# 测试：MP_GITLEAKS（gitleaks 命令）、MP_STEWARDS_MD（管家频道）、MP_STEWARD_LOG / MP_MQ_DIR（日志目录）、MP_CHECKPOINT_TTL（秒，默认 1800）
set -u
Q=${MP_MQ_DIR:-$HOME/.mp-merge-queue}
LOG=${MP_STEWARD_LOG:-$Q/logs}
STEWARDS=${MP_STEWARDS_MD:-$Q/stewards.md}
GITLEAKS=${MP_GITLEAKS:-gitleaks}
TTL=${MP_CHECKPOINT_TTL:-1800}
# 跟 .gitignore 对齐（10-14 移出 git 的过程截图 / 取证 / 日志）：docs/shots/、docs/evidence/、docs/**/*.log、docs/prompts/** 下除 .md 以外的一切
MEDIA_AWK='{ l = tolower($0) } l ~ /^docs\/(shots|evidence)\// || l ~ /^docs\/.*\.log$/ || (l ~ /^docs\/prompts\// && l !~ /\.md$/)'

DROP=   # 设了 = 拒绝时顺手作废这个待确认记录
refuse() { [ -n "$DROP" ] && rm -f "$DROP" && set -- "$1；记录已作废，从第 1 步 steward-checkpoint --why 重来"; echo "RESULT refused $1"; exit 65; }
usage() { echo "用法：steward-checkpoint.sh --why \"<理由>\" | --confirm <id>" >&2; exit 64; }

[ $# = 2 ] && [ -n "$2" ] || usage
case "$1" in
  --why) mode=why; why=$2; case "$why" in *$'\n'*|*$'\t'*) usage ;; esac ;;
  --confirm) mode=confirm; cid=$2; case "$cid" in *[!0-9A-Za-z-]*) usage ;; esac ;;
  *) usage ;;
esac

[ "${MP_STEWARD:-}" = 1 ] || refuse "只有 Warden（MP_STEWARD=1）能推 GitHub，要推请找 Warden"
REPO=$(git rev-parse --show-toplevel 2>/dev/null) || refuse "不在 git 仓库里"
[ "$(git -C "$REPO" rev-parse --absolute-git-dir)" = "$(git -C "$REPO" rev-parse --path-format=absolute --git-common-dir)" ] \
  || refuse "要在主仓跑，不在工位 worktree 里跑"
[ "$(git -C "$REPO" symbolic-ref --short HEAD 2>/dev/null)" = master ] || refuse "主仓不在 master 上"
mkdir -p "$LOG" || refuse "建不了日志目录 $LOG"

# fetch 后设 o（origin/master）/ m（master）/ n（要推几个）；拒 force
refs() {
  git -C "$REPO" fetch -q origin 2>"$LOG/checkpoint-fetch.log" || refuse "git fetch origin 失败：$(tail -1 "$LOG/checkpoint-fetch.log")"
  o=$(git -C "$REPO" rev-parse -q --verify refs/remotes/origin/master) || refuse "没有 origin/master"
  m=$(git -C "$REPO" rev-parse master)
  git -C "$REPO" merge-base --is-ancestor "$o" "$m" \
    || refuse "origin/master ${o:0:8} 不是 master ${m:0:8} 的祖先（远端有本地没有的提交 / 历史分叉），不 --force，先查清楚"
  n=$(git -C "$REPO" rev-list --count "$o..$m")
}

scan() {  # 起 止 报告前缀：gitleaks（打码）+ 媒体路径；命中就拒
  local a=$1 b=$2 rep=$3 rc hits media
  command -v "$GITLEAKS" >/dev/null 2>&1 || refuse "找不到 gitleaks（${GITLEAKS}），没扫就不推"
  "$GITLEAKS" git --redact --no-banner --log-opts="$a..$b" --report-format json --report-path "$rep-gitleaks.json" "$REPO" >"$rep-gitleaks.log" 2>&1; rc=$?
  if [ $rc != 0 ]; then
    hits=$(grep -c '"RuleID"' "$rep-gitleaks.json" 2>/dev/null) || hits=0
    [ "$hits" -gt 0 ] || refuse "gitleaks 跑失败（退出码 ${rc}）：$(tail -1 "$rep-gitleaks.log")"
    echo "gitleaks 命中（已打码，规则 / 文件 / 提交）："
    python3 -I -c 'import json,sys
for f in json.load(open(sys.argv[1]))[:20]: print("  %s  %s:%s  %s" % (f["RuleID"], f["File"], f["StartLine"], f["Commit"][:8]))' "$rep-gitleaks.json" 2>/dev/null
    refuse "gitleaks 命中 $hits 处，没推；报告 $rep-gitleaks.json"
  fi
  media=$(git -C "$REPO" -c core.quotepath=false log --format= --name-only --diff-filter=AMRC --diff-merges=first-parent "$a..$b" | sort -u | awk "$MEDIA_AWK")
  if [ -n "$media" ]; then
    echo "媒体 / 取证路径（.gitignore 拦的那几类，可能带粟粟私人数据）："
    printf '%s\n' "$media" | head -20 | sed 's/^/  /'
    refuse "范围里有 $(printf '%s\n' "$media" | wc -l | tr -d ' ') 个媒体 / 取证路径，没推"
  fi
  echo "扫描：gitleaks 没命中（报告 $rep-gitleaks.json）；媒体 / 取证路径没命中"
}

if [ "$mode" = why ]; then
  refs
  [ "$n" -gt 0 ] || { echo "没东西推：master 跟 origin/master 一样（${m:0:8}）"; echo "RESULT nothing"; exit 0; }
  id=$(date +%Y%m%d-%H%M%S)-$$
  echo "== checkpoint 检查（只检查，没推）=="
  echo "要推：$n 个提交，origin/master ${o:0:8} → master ${m:0:8}（范围 ${o:0:8}..${m:0:8}）"
  echo "理由：$why"
  echo "提交（git log --oneline 前 20 行）："
  git -C "$REPO" log --oneline -20 "$o..$m" | sed 's/^/  /'
  [ "$n" -gt 20 ] && echo "  …还有 $((n - 20)) 个"
  scan "$o" "$m" "$LOG/checkpoint-$id"
  rec="$LOG/checkpoint-$id.pending"
  printf 'id=%s\nmaster=%s\norigin=%s\nwhy=%s\nat=%s\ntime=%s\n' "$id" "$m" "$o" "$why" "$(date +%s)" "$(date '+%m-%d %H:%M:%S')" > "$rec.tmp" \
    && mv "$rec.tmp" "$rec" || refuse "写不了待确认记录 $rec"
  echo "待确认记录：${rec}（$((TTL / 60)) 分钟内有效）"
  echo "拿到粟粟同意后跑 steward-checkpoint --confirm $id"
  echo "RESULT checked $id n=$n range=${o:0:8}..${m:0:8}"
  exit 0
fi

rec="$LOG/checkpoint-$cid.pending"
[ -f "$rec" ] || refuse "没有待确认记录 ${cid}（已推过 / 已作废 / 拼错），从第 1 步 steward-checkpoint --why 重来"
DROP=$rec
field() { sed -n "s/^$1=//p" "$rec" | head -1; }
rid=$(field id); rm_=$(field master); ro=$(field origin); why=$(field why); at=$(field at)
[ "$rid" = "$cid" ] && [ -n "$rm_" ] && [ -n "$ro" ] && case "$at" in ''|*[!0-9]*) false ;; esac || refuse "待确认记录坏了"
age=$(( $(date +%s) - at ))
[ "$age" -ge 0 ] && [ "$age" -le "$TTL" ] || refuse "待确认记录过期（${age} 秒前写的，上限 ${TTL} 秒）"
refs
[ "$m" = "$rm_" ] || refuse "master 变了（记录 ${rm_:0:8}，现在 ${m:0:8}）"
[ "$o" = "$ro" ] || refuse "origin/master 变了（记录 ${ro:0:8}，现在 ${o:0:8}）"
[ "$n" -gt 0 ] || refuse "没东西推"
scan "$o" "$m" "$LOG/checkpoint-$cid-confirm"
DROP=   # 推失败（多半网络）记录留着，30 分钟内修好可重跑 --confirm
git -C "$REPO" push -q origin "$m:refs/heads/master" 2>"$LOG/checkpoint-$cid-push.log" \
  || refuse "push 失败（记录留着，有效期内修好可重跑 --confirm ${cid}）：$(tail -1 "$LOG/checkpoint-$cid-push.log")"
rm -f "$rec"
printf '%s Warden: checkpoint 推 GitHub origin/master：%s 个提交 %s..%s，理由：%s（粟粟本人同意，记录 %s）\n' \
  "$(date '+%m-%d %H:%M')" "$n" "${o:0:8}" "${m:0:8}" "$why" "$cid" >> "$STEWARDS" || echo "WARN 推上了，但 stewards.md 没写进去：$STEWARDS"
echo "推上了：$n 个提交 ${o:0:8}..${m:0:8}"
echo "RESULT pushed $cid n=$n range=${o:0:8}..${m:0:8}"
