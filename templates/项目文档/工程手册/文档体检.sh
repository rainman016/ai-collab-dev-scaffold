#!/usr/bin/env bash
(set -o igncr) 2>/dev/null && set -o igncr; # 兼容 CRLF；注释不能删
# 文档体检 — MIT。挂在治理区提交关口（见《文档规则》）。
# 用法：bash 文档体检.sh [治理区路径]（默认＝治理区，本脚本往上两层）
# 退出码：0 通过（可能有提醒）｜1 拦截｜2 没跑成，不算通过
R=${1:-$(cd "$(dirname "$0")/../.." 2>/dev/null && pwd)}
W="$R/项目文档/工程手册/文档上限.json"; T="$R/项目文档/任务记录"
die(){ echo "没跑成：$1"; exit 2; }
[ -f "$R/AGENTS.md" ] && [ -f "$W" ] || die "缺 AGENTS.md 或文档上限.json"
if [ "$(printf '中文' | LC_ALL=C.UTF-8 wc -m 2>/dev/null | tr -d ' \r')" = 2 ]; then
  cnt(){ LC_ALL=C.UTF-8 wc -m <"$1" | tr -d ' \r'; }
else
  PY=""; for p in python3 python; do [ "$("$p" -I -c 'print(len("中文"))' 2>/dev/null | tr -d '\r')" = 2 ] && PY=$p && break; done
  [ -n "$PY" ] || die "数不了字符数"
  cnt(){ "$PY" -X utf8 -I -c 'import sys;print(len(open(sys.argv[1],encoding="utf-8").read()))' "$1"; }
fi
lim(){ sed -n "s/.*\"$1\": *\([0-9]*\).*/\1/p" "$W" | head -1; }
B=0; M=0
chk(){ # 文件 键 级别（拦／提醒）
  [ -f "$1" ] || return 0
  local c l; c=$(cnt "$1"); l=$(lim "$2")
  case "$c$l" in ''|*[!0-9]*) die "读不到字数或上限：$2";; esac
  [ "$c" -le "$l" ] && return 0
  echo "$3：${1#$R/} $c 字，超上限 $l"; if [ "$3" = 拦 ]; then B=$((B+1)); else M=$((M+1)); fi
}
chk "$R/AGENTS.md" agents_max 拦
chk "$T/当前任务总览.md" overview_max 拦
for d in "$T"/任务*/; do
  [ -d "$d" ] || continue
  chk "${d}当前状态.md" task_progress_max 拦
  chk "${d}施工指令.md" task_package_max 提醒; chk "${d}施工回报.md" report_max 提醒
  chk "${d}复核结论.md" conclusion_max 提醒; chk "${d}交付回执.md" receipt_max 提醒
  [ -f "${d}方案.md" ] && [ "$(grep -c . "${d}方案.md")" -gt "$(lim plan_max_lines)" ] && { echo "提醒：${d#$R/}方案.md 超 $(lim plan_max_lines) 行"; M=$((M+1)); }
  for f in "$d"*; do case "${f##*/}" in 任务说明.md|当前状态.md|方案.md|施工指令.md|施工回报.md|复核结论.md|交付回执.md|架构梳理.md) ;; *) echo "提醒：清单外文件 ${f#$R/}"; M=$((M+1));; esac; done
done
S=0; for f in "$R/AGENTS.md" "$R/项目文档/交付规则.md" "$R/项目文档/文档规则.md"; do [ -f "$f" ] && S=$((S+$(cnt "$f"))); done
[ "$S" -gt "$(lim rules_budget)" ] && { echo "提醒：规则三件合计 $S 字，超软上限 $(lim rules_budget)"; M=$((M+1)); }
# 硬规则关键句：编号｜文件｜句（缺就拦）
while IFS='|' read -r n f p; do
  grep -qF -- "$p" "$R/$f" 2>/dev/null || { echo "拦：硬规则 $n 缺关键句“$p”（$f）"; B=$((B+1)); }
done <<'EOF'
1|AGENTS.md|“可以／继续／好的／审核通过”都不算
2|AGENTS.md|门禁只由总控执行
2|AGENTS.md|团队模式 AI 不合并、不推主线
3|AGENTS.md|花钱、碰生产、对外发布、不可逆的动作，要用户明确授权
4|AGENTS.md|误读到了不复述、不写进任何文件，立即告诉用户去轮换
5|项目文档/交付规则.md|不读、不记、不生成
6|项目文档/交付规则.md|退出码 0 才推
6|项目文档/交付规则.md|首次空提交也要扫
6|项目文档/交付规则.md|指纹只由用户看过清单后填
7|AGENTS.md|不改源码仓库里被版本管理的文件
8|AGENTS.md|确认规则生效
8|项目文档/任务记录/协作治理/当前状态.md|确认规则生效
9|AGENTS.md|没在《当前任务总览》登记的施工区不施工
10|AGENTS.md|不改写主线历史、不强推、不删远端分支
10|AGENTS.md|同步主线用合并，不用变基
11|AGENTS.md|没亲眼看过的写“未验证”
12|项目文档/交付规则.md|复核者不能是实施者
12|项目文档/交付规则.md|复核通过不能代替用户的门禁口令
13|AGENTS.md|必须由非实施者复核
14|AGENTS.md|每份施工指令第一行都写“先读
14|项目文档/任务记录/模板/施工指令.md|先读
EOF
while IFS= read -r p; do [ -e "$R/$p" ] || { echo "拦：AGENTS.md 指到的文件不存在：$p"; B=$((B+1)); }
done < <(grep -o '`项目文档/[^`<>]*`' "$R/AGENTS.md" | tr -d '`' | sed 's/[[:space:]]*$//')
if [ "$B" -gt 0 ]; then echo "体检：拦截 $B 项，提醒 $M 项"; exit 1; fi
echo "体检：通过，提醒 $M 项"; exit 0
