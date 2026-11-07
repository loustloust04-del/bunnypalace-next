#!/bin/bash
# steward-checkpoint.sh 自测：临时主仓 + 临时 bare origin + 临时日志 / 频道文件，真 gitleaks（MP_GITLEAKS 可换），不碰真仓和 ~/.mp-merge-queue。
#   bash scripts/steward-checkpoint.test.sh
set -u
SRC="$(cd "$(dirname "$0")" && pwd)"
CP="$SRC/steward-checkpoint.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export MP_MQ_DIR="$T/mq" MP_STEWARD_LOG="$T/logs" MP_STEWARDS_MD="$T/stewards.md"
unset MP_CHECKPOINT_TTL MP_STEWARD
command -v "${MP_GITLEAKS:-gitleaks}" >/dev/null || { echo "需要 gitleaks（brew install gitleaks）或 MP_GITLEAKS=<命令>"; exit 1; }
fail=0; ok() { echo "✅ $1"; }; bad() { echo "❌ $1"; fail=1; }
g() { git -c user.name=t -c user.email=t@t "$@"; }
W() { MP_STEWARD=1 "$@"; }

git init -q --bare "$T/origin.git"
R="$T/repo"; git init -q -b master "$R"; cd "$R"
echo a > a.txt; g add -A; g commit -qm init; git remote add origin "$T/origin.git"; MP_STEWARD=1 git push -q origin master
for h in pre-commit pre-merge-commit pre-push reference-transaction; do ln -sf "$SRC/git-hooks/$h" .git/hooks/$h; done
origin_master() { git --git-dir="$T/origin.git" rev-parse master; }
cpw() { (cd "$R" && W "$CP" "$@") 2>&1; }   # Warden 跑，全部输出
last() { printf '%s\n' "$1" | tail -1; }
cid() { last "$1" | sed -n 's/^RESULT checked \([^ ]*\) .*/\1/p'; }
commit() { echo "$2" > "$1"; g add -- "$1"; MP_STEWARD=1 g commit -qm "$3"; }

echo "— 身份"
out=$(cd "$R" && "$CP" --why x 2>&1); rc=$?
[ $rc = 65 ] && last "$out" | grep -q "^RESULT refused 只有 Warden" && ok "没 MP_STEWARD=1：拒" || bad "rc=$rc $out"
git worktree add -q "$T/wt" -b side master
out=$(cd "$T/wt" && W "$CP" --why x 2>&1); rc=$?
[ $rc = 65 ] && last "$out" | grep -q "要在主仓跑" && ok "工位 worktree 里跑：拒" || bad "rc=$rc $out"
(cd "$R" && "$CP" 2>/dev/null); [ $? = 64 ] && ok "没参数：用法错 64" || bad "用法错退出码不对"

echo "— 没东西推"
out=$(cpw --why x); rc=$?
[ $rc = 0 ] && last "$out" | grep -qx "RESULT nothing" && printf '%s\n' "$out" | grep -q "没东西推" && ok "master = origin/master：没东西推" || bad "rc=$rc $out"

echo "— 第 1 步只检查、不推"
o0=$(origin_master)
commit b.txt b "加 b"; commit c.txt c "加 c"
out=$(cpw --why "发版前"); rc=$?; id=$(cid "$out")
[ $rc = 0 ] && [ -n "$id" ] && last "$out" | grep -q "^RESULT checked $id n=2 range=${o0:0:8}\.\.$(git rev-parse --short=8 master)$" && ok "checked：n=2、范围对" || bad "rc=$rc $out"
[ "$(origin_master)" = "$o0" ] && ok "第 1 步没推" || bad "第 1 步推了"
printf '%s\n' "$out" | grep -q "加 c" && printf '%s\n' "$out" | grep -q "加 b" && printf '%s\n' "$out" | grep -q "理由：发版前" \
  && printf '%s\n' "$out" | grep -q "扫描：gitleaks 没命中" && printf '%s\n' "$out" | grep -qx "拿到粟粟同意后跑 steward-checkpoint --confirm $id" \
  && ok "摘要：提交列表 / 理由 / 扫描结果 / 怎么确认" || bad "$out"
rec="$T/logs/checkpoint-$id.pending"
[ -f "$rec" ] && grep -qx "master=$(git rev-parse master)" "$rec" && grep -qx "origin=$o0" "$rec" && grep -qx "why=发版前" "$rec" && grep -q "^at=[0-9]*$" "$rec" \
  && ok "待确认记录：id / master / origin / why / 时间" || bad "记录不对：$(cat "$rec" 2>/dev/null)"
[ ! -e "$T/stewards.md" ] && ok "第 1 步不写 stewards.md" || bad "第 1 步写了 stewards.md"

echo "— confirm：master 变了 → 拒、作废记录"
commit d.txt d "加 d"
out=$(cpw --confirm "$id"); rc=$?
[ $rc = 65 ] && last "$out" | grep -q "^RESULT refused master 变了.*记录已作废，从第 1 步" && [ ! -e "$rec" ] && [ "$(origin_master)" = "$o0" ] && ok "master 变了：拒、记录删了、没推" || bad "rc=$rc $out"
out=$(cpw --confirm "$id"); last "$out" | grep -q "^RESULT refused 没有待确认记录" && ok "作废的记录不能再 confirm" || bad "$out"

echo "— confirm：origin/master 变了 → 拒"
out=$(cpw --why 再来); id=$(cid "$out"); rec="$T/logs/checkpoint-$id.pending"
git push -q "$T/origin.git" "$(git rev-parse master~2):refs/heads/master" 2>/dev/null || MP_STEWARD=1 git push -q "$T/origin.git" "$(git rev-parse master~2):refs/heads/master"   # 别人先推了一部分
out=$(cpw --confirm "$id"); rc=$?
[ $rc = 65 ] && last "$out" | grep -q "^RESULT refused origin/master 变了.*记录已作废" && [ ! -e "$rec" ] && ok "origin/master 变了：拒、记录删了" || bad "rc=$rc $out"
git --git-dir="$T/origin.git" update-ref refs/heads/master "$o0"; git fetch -q origin

echo "— confirm：记录过期 → 拒"
out=$(cpw --why 过期); id=$(cid "$out"); rec="$T/logs/checkpoint-$id.pending"
sed -i '' "s/^at=.*/at=$(( $(date +%s) - 1801 ))/" "$rec"
out=$(cpw --confirm "$id"); rc=$?
[ $rc = 65 ] && last "$out" | grep -q "refused 待确认记录过期" && [ ! -e "$rec" ] && [ "$(origin_master)" = "$o0" ] && ok "超过 30 分钟：拒、没推" || bad "rc=$rc $out"

echo "— confirm 在 Warden 以外：拒"
out=$(cpw --why 身份); id=$(cid "$out")
out=$(cd "$R" && "$CP" --confirm "$id" 2>&1); rc=$?
[ $rc = 65 ] && last "$out" | grep -q "只有 Warden" && [ "$(origin_master)" = "$o0" ] && ok "非 Warden confirm：拒" || bad "rc=$rc $out"

echo "— 正常 confirm：推、删记录、写 stewards.md"
out=$(cpw --confirm "$id"); rc=$?
n=$(git rev-list --count "$o0..master")
[ $rc = 0 ] && last "$out" | grep -q "^RESULT pushed $id n=$n " && [ "$(origin_master)" = "$(git rev-parse master)" ] && [ ! -e "$T/logs/checkpoint-$id.pending" ] \
  && ok "推上了（n=${n}），记录删了" || bad "rc=$rc $out"
tail -1 "$T/stewards.md" | grep -q "^[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9] Warden: checkpoint 推 GitHub origin/master：$n 个提交 ${o0:0:8}\.\.$(git rev-parse --short=8 master)，理由：身份（粟粟本人同意，记录 ${id}）$" \
  && ok "stewards.md 追加一行：时间 / 几个提交 / 范围 / 理由" || bad "stewards.md：$(cat "$T/stewards.md")"
out=$(cpw --confirm "$id"); last "$out" | grep -q "refused 没有待确认记录" && ok "同一个记录不能推第二次" || bad "$out"

echo "— gitleaks 命中 → 拒（第 1 步不写记录）"
o1=$(origin_master)
printf 'aws_access_key_id = AKIAQX4ZJ7RTW2PLMN5K\naws_secret_access_key = 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\n' > cfg.ini; g add cfg.ini; MP_STEWARD=1 g commit -qm "假 key"
out=$(cpw --why 有key); rc=$?
rep=$(last "$out" | sed -n 's/.*报告 \(.*-gitleaks\.json\)$/\1/p')
[ $rc = 65 ] && last "$out" | grep -q "^RESULT refused gitleaks 命中 [0-9]* 处" && [ -f "$rep" ] && ok "命中：拒，报告在仓库外 $rep" || bad "rc=$rc $out"
printf '%s\n' "$out" | grep -q "cfg.ini" && ! printf '%s\n' "$out" | grep -q "wJ8rXq3L" && ! grep -q "wJ8rXq3L" "$rep" && ok "列了文件，密钥打码（输出 / 报告都没明文）" || bad "$out"
[ -z "$(ls "$T/logs"/*.pending 2>/dev/null)" ] && [ "$(origin_master)" = "$o1" ] && ok "没写待确认记录、没推" || bad "有记录 / 推了"
case "$rep" in "$R"/*) bad "报告写进了仓库" ;; *) ok "报告不在仓库里" ;; esac
MP_STEWARD=1 g reset -q --hard HEAD^

echo "— 第 1 步之后才混进 key：confirm 重扫拦住"
commit e.txt e "加 e"
out=$(cpw --why 重扫); id=$(cid "$out"); rec="$T/logs/checkpoint-$id.pending"
printf 'aws_access_key_id = AKIAQX4ZJ7RTW2PLMN5K\naws_secret_access_key = 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\n' > cfg.ini; g add cfg.ini; MP_STEWARD=1 g commit -q --amend -m "加 e（混了 key）"
m2=$(git rev-parse master); sed -i '' "s/^master=.*/master=$m2/" "$rec"   # 假装记录就是这个 sha：只剩重扫这一道
out=$(cpw --confirm "$id"); rc=$?
[ $rc = 65 ] && last "$out" | grep -q "refused gitleaks 命中.*记录已作废" && [ ! -e "$rec" ] && [ "$(origin_master)" = "$o1" ] && ok "confirm 重扫命中：拒、作废" || bad "rc=$rc $out"
MP_STEWARD=1 g reset -q --hard "$o1"

echo "— 媒体 / 取证路径 → 拒"
for p in docs/shots/a.png docs/evidence/x.txt docs/notes/run.log docs/prompts/p1/shot.JPG docs/prompts/p1/data.json; do
  MP_STEWARD=1 g reset -q --hard "$o1"
  mkdir -p "$(dirname "$p")"; commit "$p" m "加 $p"
  out=$(cpw --why media); rc=$?
  [ $rc = 65 ] && last "$out" | grep -q "^RESULT refused 范围里有 1 个媒体 / 取证路径" && printf '%s\n' "$out" | grep -qx "  $p" && ok "拒：$p" || bad "${p}：rc=$rc $out"
done
MP_STEWARD=1 g reset -q --hard "$o1"
mkdir -p docs/shots; commit docs/shots/a.png m "加截图"; MP_STEWARD=1 g rm -q docs/shots/a.png; MP_STEWARD=1 g commit -qm "又删了"
out=$(cpw --why media2); last "$out" | grep -q "refused 范围里有 1 个媒体" && ok "加了又删的也拦（历史里推得上去）" || bad "$out"
MP_STEWARD=1 g reset -q --hard "$o1"
mkdir -p docs/prompts/p1; commit docs/prompts/p1/task.md m "任务书"
out=$(cpw --why ok); last "$out" | grep -q "^RESULT checked" && ok "docs/prompts 下的 .md 不误拦" || bad "$out"

echo "— gitleaks 跑不起来 → 拒"
printf '#!/bin/sh\necho boom >&2\nexit 2\n' > "$T/fakeleaks"; chmod +x "$T/fakeleaks"
out=$(cd "$R" && MP_GITLEAKS="$T/fakeleaks" W "$CP" --why x 2>&1); rc=$?
[ $rc = 65 ] && last "$out" | grep -q "refused gitleaks 跑失败（退出码 2）" && ok "gitleaks 坏了：拒" || bad "rc=$rc $out"
out=$(cd "$R" && MP_GITLEAKS="$T/nope" W "$CP" --why x 2>&1); last "$out" | grep -q "refused 找不到 gitleaks" && ok "没装 gitleaks：拒" || bad "$out"

echo "— 远端领先（要 force 才推得上）→ 拒"
MP_STEWARD=1 g reset -q --hard "$o1"; git clone -q "$T/origin.git" "$T/other"; (cd "$T/other" && echo y > y.txt && g add y.txt && g commit -qm 远端新 && git push -q origin HEAD:master)
commit z.txt z "本地新"
out=$(cpw --why x); rc=$?
[ $rc = 65 ] && last "$out" | grep -q "不是 master .* 的祖先.*不 --force" && ok "origin 不是祖先：拒，不 force" || bad "rc=$rc $out"

[ $fail = 0 ] && echo "ALL PASS" || { echo FAILED; exit 1; }
