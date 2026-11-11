#!/usr/bin/env bash
(set -o igncr) 2>/dev/null && set -o igncr; # 让 Windows 换行（CRLF）的副本在 Git Bash 下也能跑；本行末尾的注释不能删
# 推送前敏感扫描 — SPDX-License-Identifier: MIT
# 作用：把一个分支推到远端之前，确认“这次推送会让远端新增的全部提交”（文件内容和提交说明）里没有凭据，
#       并且推往的就是核实过的私有仓库。说明见同目录的《推送前扫描.md》。
#
# 用法：
#   bash 推送前扫描.sh                 只扫描，不推送
#   bash 推送前扫描.sh --push          扫描通过、推送地址和配置的仓库一致、远端确认是私有仓库时，才推送
#                                      （推送属于门禁动作：先有用户的授权，再加 --push）
#   --binary-ok=<指纹>                 有二进制文件（内容扫不了）时：用户看过清单、确认可以推，
#                                      才把脚本给出的指纹填进来重跑；可和 --push 一起用
# 退出码：0 = 通过；1 = 有命中，或有没确认的二进制文件，停止；
#         2 = 没跑成或核实不通过（出错、自检失败、没配置、地址对不上、不是私有、扫描后有变化），不算通过。

# ---- 配置：占位符在配置远端时填；没填完，脚本拒绝运行 ----
REPO_PATH="<待扫描仓库路径>"     # 要推送的仓库（治理区或某个源码仓库）的路径
REMOTE="<备份远端名>"            # 远端名，如 origin
BRANCH="<待推送分支名>"          # 要推送的本地分支，如 main（推的是它，不是当前检出的分支）
REPO_FULL_NAME="<仓库全名>"      # 形如 账号/仓库名（默认 github.com）；别的主机写 主机/账号/仓库名

case "$REPO_PATH$REMOTE$BRANCH$REPO_FULL_NAME" in
  *'<'*) echo "没跑成：配置里还有没填的占位符"; exit 2 ;;
esac

DO_PUSH=0; BIN_OK=""
for a in "$@"; do
  case "$a" in
    --push) DO_PUSH=1 ;;
    --binary-ok=*) BIN_OK=${a#--binary-ok=} ;;
    *) echo "没跑成：有不认识的参数（只认 --push、--binary-ok=<指纹>）"; exit 2 ;;
  esac
done

cd "$REPO_PATH" 2>/dev/null || { echo "没跑成：进不了仓库路径"; exit 2; }
TOP=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "没跑成：这里不是 git 仓库（或是裸仓库）"; exit 2; }
cd "$TOP" || { echo "没跑成：进不了仓库根目录"; exit 2; }   # 在子目录里 git grep 只扫子目录，所以回到根目录

redact() { sed -E 's#(://)[^/@[:space:]]*@#\1***@#g'; }     # 地址里的账号口令一律换成 ***，再输出
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
G() { git -c core.quotePath=false grep "$@"; }

# 把远端地址拆成主机 U_HOST 和路径 U_PATH（账号/仓库名，去掉 .git）；本地路径、file:// 拆不出主机，算失败
parse_url() {
  local u=$1 hp rest
  U_HOST=""; U_PATH=""
  case "$u" in
    *://*) rest=${u#*://}; hp=${rest%%/*}
           case "$rest" in */*) U_PATH=${rest#*/} ;; esac
           hp=${hp##*@}; U_HOST=${hp%%:*} ;;
    *:*)   hp=${u%%:*}
           case "$hp" in */*|'') return 1 ;; esac
           U_HOST=${hp##*@}; U_PATH=${u#*:} ;;
    *)     return 1 ;;
  esac
  U_PATH=${U_PATH#/}; U_PATH=${U_PATH%/}; U_PATH=${U_PATH%.git}
  [ -n "$U_HOST" ] && [ -n "$U_PATH" ]
}

# ---- 1. 锁定要推的对象：本地分支 BRANCH 此刻的提交号（OID），之后只认它，不看 HEAD ----
git check-ref-format --branch "$BRANCH" >/dev/null 2>&1 || { echo "没跑成：分支名不合法"; exit 2; }
OID=$(git rev-parse --verify -q "refs/heads/$BRANCH^{commit}") || { echo "没跑成：本地没有分支 $BRANCH"; exit 2; }

# ---- 2. 绑定实际推送地址：远端 REMOTE 的推送地址必须正好指向 REPO_FULL_NAME ----
IFS=/ read -r P1 P2 P3 P4 <<< "$REPO_FULL_NAME"
if [ -n "$P4" ] || [ -z "$P2" ]; then echo "没跑成：仓库全名要写成 账号/仓库名 或 主机/账号/仓库名"; exit 2
elif [ -n "$P3" ]; then EXP_HOST=$P1; EXP_PATH="$P2/$P3"
else EXP_HOST=github.com; EXP_PATH="$P1/$P2"; fi
EXP_PATH=${EXP_PATH%.git}

PUSH_URL=$(git remote get-url --push --all "$REMOTE" 2>/dev/null)   # 已展开 insteadOf / pushInsteadOf，就是 git push 实际用的地址
if [ -n "$PUSH_URL" ]; then
  case "$PUSH_URL" in *$'\n'*) echo "没跑成：远端 $REMOTE 配了多个推送地址，脚本只支持一个"; exit 2 ;; esac
  SHOW_URL=$(printf '%s' "$PUSH_URL" | redact)
  if ! parse_url "$PUSH_URL" || [ "$(lower "$U_HOST")" != "$(lower "$EXP_HOST")" ] \
     || [ "$(lower "$U_PATH")" != "$(lower "$EXP_PATH")" ]; then
    echo "停止：远端 $REMOTE 的推送地址（$SHOW_URL）和配置的仓库（$EXP_HOST/$EXP_PATH）对不上；先改对配置或远端，再重跑。"
    exit 2
  fi
elif [ $DO_PUSH = 1 ]; then
  echo "没跑成：没有远端 $REMOTE（或它没有推送地址）"; exit 2
fi

# ---- 3. 确定要扫的提交：从 OID 能到达、而远端任何分支和标签都还没有的提交 ----
#         远端现状直接问推送地址（git ls-remote），不靠本地可能过期的远端跟踪分支；
#         远端还没有这个分支（含首次接入远端、推空主线）时，就是该分支的全部历史减去远端已有的。
remote_refs() { git ls-remote "$PUSH_URL" 2>/dev/null | LC_ALL=C sort; return "${PIPESTATUS[0]}"; }
REFS=""; RB_OID=""; EXCL=""
if [ -n "$PUSH_URL" ] && REFS=$(remote_refs); then
  RB_OID=$(printf '%s\n' "$REFS" | awk -v r="refs/heads/$BRANCH" '$2 == r { print $1 }')
  EXCL=$(printf '%s\n' "$REFS" | awk 'NF { print $1 }' | LC_ALL=C sort -u | while read -r o; do
           git cat-file -e "$o^{commit}" 2>/dev/null && printf '^%s\n' "$o"; done)
  if [ -n "$RB_OID" ]; then SCOPE="远端 $BRANCH 还没有的提交"
  else SCOPE="首次推送 $BRANCH：该分支全部历史中远端还没有的提交"; fi
elif [ $DO_PUSH = 1 ]; then
  echo "没跑成：读不到远端现状（$SHOW_URL），没法算出这次要推哪些提交"; exit 2
else
  SCOPE="该分支的全部历史（没配远端或读不到远端，按首次推送扫，只会多扫不会少扫）"
fi
R=$(git rev-list "$OID" $EXCL) || { echo "没跑成：列提交失败"; exit 2; }
if [ -z "$R" ] && [ "$RB_OID" = "$OID" ]; then
  echo "远端 $BRANCH 已经是这个提交（$OID），没有要推的。"; exit 0
fi
N=$(printf '%s\n' "$R" | grep -c .)
echo "要推的对象：分支 $BRANCH = $OID；要扫 $N 个提交（$SCOPE）。"

# ---- 4. 凭据的格式特征（每类单独跑；不要按“密码”“Key”这类普通词扫，会满屏误报）----
PATTERNS=(
  '-----BEGIN [A-Z ]*PRIVATE KEY-----'
  'sk-[A-Za-z0-9_-]{20,}'
  'gh[pousr]_[A-Za-z0-9]{30,}'
  'AKIA[0-9A-Z]{16}'
  'xox[baprs]-[A-Za-z0-9-]{10,}'
  '[a-z]+://[^/[:space:]:@]+:[^/[:space:]@]+@'
)
# 自检样例：每个样例用分段拼接生成，避免本文件里出现完整的特征串而被扫到
mk() { printf '%s' "$@"; }
SAMPLES=(
  "$(mk 'x -----BEGIN RSA PRIVATE ' 'KEY----- y')"
  "$(mk 'sk' '-' 'aaaaaaaaaaaaaaaaaaaaaaaaa')"
  "$(mk 'ghp' '_' 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa')"
  "$(mk 'AKI' 'A' 'ABCDEFGHIJKLMNOP')"
  "$(mk 'xox' 'b' '-' '1234567890abc')"
  "$(mk 'https://user' ':' 'pw@host')"
)

# ---- 5. 先自检：每条规则都要能识别自己的样例，否则按“没跑成”处理 ----
i=0
while [ $i -lt ${#PATTERNS[@]} ]; do
  printf '%s\n' "${SAMPLES[$i]}" | grep -qE -e "${PATTERNS[$i]}" \
    || { echo "没跑成：第 $((i+1)) 类特征的自检失败"; exit 2; }
  i=$((i+1))
done

RESULT=0; BIN_LIST=""; FP=""
if [ -n "$R" ]; then
  # ---- 6. 逐类扫描文本文件，只输出文件名，不输出命中的内容 ----
  i=0
  while [ $i -lt ${#PATTERNS[@]} ]; do
    OUT=$(G -lIE -e "${PATTERNS[$i]}" $R 2>/dev/null); RC=$?   # 模式前一定要加 -e
    if [ $RC = 0 ]; then
      echo "命中（第 $((i+1)) 类特征），文件：$(printf '%s\n' "$OUT" | sed 's/^[0-9a-f]*://' | sort -u | tr '\n' ' ')"
      [ $RESULT = 2 ] || RESULT=1
    elif [ $RC -gt 1 ]; then
      echo "没跑成：第 $((i+1)) 类特征扫描出错"
      RESULT=2
    fi
    i=$((i+1))
  done

  # ---- 6b. 逐类扫提交说明（每个要推的提交的说明全文），命中只输出提交号，不输出内容 ----
  #          每行前面加上所属提交号再扫；有人在说明里伪造标记行，也只会让命中算到别的提交上，照样拦
  MSGS=$(printf '%s\n' "$R" | git log --stdin --no-walk=unsorted --format='@@COMMIT@@ %H%n%B' 2>/dev/null) \
    || { echo "没跑成：读提交说明出错"; RESULT=2; MSGS=""; }
  MSG_LINES=$(printf '%s\n' "$MSGS" | awk '/^@@COMMIT@@ [0-9a-f]+$/ { h = $2; next } { print h "\t" $0 }')
  i=0
  while [ $RESULT != 2 ] && [ $i -lt ${#PATTERNS[@]} ]; do
    OUT=$(printf '%s\n' "$MSG_LINES" | grep -E -e "${PATTERNS[$i]}"); RC=$?   # 同样要加 -e
    if [ $RC = 0 ]; then
      echo "命中（第 $((i+1)) 类特征），提交说明：$(printf '%s\n' "$OUT" | cut -f1 | sort -u | tr '\n' ' ')"
      RESULT=1
    elif [ $RC -gt 1 ]; then
      echo "没跑成：第 $((i+1)) 类特征扫提交说明出错"
      RESULT=2
    fi
    i=$((i+1))
  done

  # ---- 7. 找出扫不了内容的二进制文件：git 自己判为二进制、上面 -I 跳过的那些 ----
  ALL=$(G -l -e '' $R 2>/dev/null); RA=$?
  TXT=$(G -lI -e '' $R 2>/dev/null); RT=$?
  if [ $RA -gt 1 ] || [ $RT -gt 1 ]; then
    echo "没跑成：列二进制文件出错"; RESULT=2
  else
    BIN_LIST=$(LC_ALL=C comm -23 <(printf '%s\n' "$ALL" | LC_ALL=C sort -u) <(printf '%s\n' "$TXT" | LC_ALL=C sort -u) \
      | while IFS= read -r e; do
          [ -n "$e" ] || continue
          b=$(git rev-parse --verify -q "$e" 2>/dev/null) || b="?"
          printf '%s %s\n' "$b" "${e#*:}"
        done | LC_ALL=C sort -u)
  fi
fi

if [ -n "$BIN_LIST" ]; then
  FP=$(printf '%s\n' "$BIN_LIST" | git hash-object --stdin)   # 指纹＝这批二进制文件的确切内容，内容一变指纹就变
  echo "未扫描（二进制文件，内容扫不了）：$(printf '%s\n' "$BIN_LIST" | cut -d' ' -f2- | sort -u | tr '\n' ' ')"
fi

if [ $RESULT != 0 ]; then
  [ $RESULT = 1 ] && echo "结果：有命中，停止推送；由用户处理并确认后重扫。"
  [ $RESULT = 2 ] && echo "结果：没跑成，不算通过；先解决扫描本身的问题。"
  exit $RESULT
fi
BIN_NOTE=""
if [ -n "$BIN_LIST" ]; then
  if [ "$BIN_OK" != "$FP" ]; then
    [ -n "$BIN_OK" ] && echo "给的指纹和当前这批二进制文件对不上（文件有变化，或指纹抄错）。"
    echo "结果：有未扫描的二进制文件，停止。请用户逐个确认这些文件不含凭据（或把它们移出这次推送）；"
    echo "      用户确认可以推之后，加 --binary-ok=$FP 重跑。"
    exit 1
  fi
  BIN_NOTE="；另有 $(printf '%s\n' "$BIN_LIST" | grep -c .) 个二进制文件没扫内容，已由用户按指纹确认"
fi
echo "结果：扫描通过——范围：$SCOPE；文本文件和提交说明 ${#PATTERNS[@]} 类特征 0 命中$BIN_NOTE。"

# ---- 8. 推送（只在 --push 时）：先核实私有，再复核扫描后什么都没变，最后推同一个 OID ----
if [ $DO_PUSH != 1 ]; then
  echo "没有推送。要推送：先取得用户授权，再加 --push 重跑（会核实远端是私有仓库）。"
  exit 0
fi
VIS=$(gh repo view "$EXP_HOST/$EXP_PATH" --json visibility,nameWithOwner --jq '.visibility + " " + .nameWithOwner' 2>/dev/null) \
  || { echo "没跑成：核实不了远端可见性（没装 gh 或没登录？）"; exit 2; }
GOT_VIS=${VIS%% *}; GOT_NAME=${VIS#* }
[ "$(lower "$GOT_NAME")" = "$(lower "$EXP_PATH")" ] \
  || { echo "停止：查到的仓库是 $GOT_NAME，和配置的 $EXP_PATH 不一致（可能改过名或跳转），先改对配置"; exit 2; }
[ "$GOT_VIS" = PRIVATE ] || { echo "停止：远端不是私有仓库（$GOT_VIS）"; exit 2; }

NOW_OID=$(git rev-parse --verify -q "refs/heads/$BRANCH^{commit}")
[ "$NOW_OID" = "$OID" ] || { echo "停止：扫描后分支 $BRANCH 变了，重跑扫描"; exit 2; }
[ "$(git remote get-url --push --all "$REMOTE" 2>/dev/null)" = "$PUSH_URL" ] \
  || { echo "停止：扫描后远端 $REMOTE 的推送地址变了，重跑扫描"; exit 2; }
NOW_REFS=$(remote_refs) && [ "$NOW_REFS" = "$REFS" ] \
  || { echo "停止：扫描后远端有变化（或读不到了），重跑扫描"; exit 2; }

git push "$PUSH_URL" "$OID:refs/heads/$BRANCH" 2>&1 | redact
[ "${PIPESTATUS[0]}" = 0 ] || { echo "没跑成：推送失败"; exit 2; }
AFTER=$(remote_refs | awk -v r="refs/heads/$BRANCH" '$2 == r { print $1 }')
[ "$AFTER" = "$OID" ] || { echo "没跑成：推送后核对，远端 $BRANCH 不是 $OID"; exit 2; }
echo "已推送：远端 $BRANCH = $OID（$SHOW_URL）。"
