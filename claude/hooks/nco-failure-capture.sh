#!/usr/bin/env bash
# nco-failure-capture.sh — PostToolUseFailure → loop-lesson 자동 포착 (Fix B)
# 도구 실패를 지문(도구+에러시그니처)으로 캐시에 자동 기록. 동일 지문 반복 시 우회 힌트.
INPUT=$(cat 2>/dev/null)
LL="$HOME/.claude/hooks/loop-lesson.sh"
[ -x "$LL" ] || exit 0
SIG=$(printf '%s' "$INPUT" | python3 -c '
import sys,json,re
try: d=json.load(sys.stdin)
except: sys.exit(0)
tool=d.get("tool_name","tool")
err=""
ti=d.get("tool_response") or d.get("error") or d.get("tool_error") or d.get("message") or ""
if isinstance(ti,dict): err=json.dumps(ti,ensure_ascii=False)
else: err=str(ti)
# 에러 핵심 토큰만 (경로/숫자 제거해 지문 안정화)
head=re.sub(r"[0-9]+","N",err)[:80].strip()
print(f"{tool}::{head}")
' 2>/dev/null)
[ -z "$SIG" ] && exit 0
KEY="toolfail-$(printf '%s' "$SIG" | tr -c 'A-Za-z0-9' '_' | cut -c1-40)"
DD="/tmp/nco-ll-seen-${NCO_SESSION_ID:-$$}-${KEY}"
if [ ! -f "$DD" ]; then
    : > "$DD"
    bash "$LL" add "$KEY" "도구 실패 자동포착: ${SIG}" >/dev/null 2>&1
    # 동일 지문 3회+면 우회 힌트를 stderr로 표면화
    bash "$LL" workaround "$KEY" 2>/dev/null || true
fi
exit 0
