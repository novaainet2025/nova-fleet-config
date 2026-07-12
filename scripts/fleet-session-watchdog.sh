#!/bin/bash
# fleet-session-watchdog.sh — 전 세션 감시 (2026-07-12)
# 목적: 각 세션의 Stop훅 판정(session-goal-check)을 읽어 (1) 출력 정상성 (2) 자동실행/다음단계 진행
#       (3) 정체/이상을 탐지하고, 이상 세션에 inter-session 넛지를 보낸다. 매 10분(/loop) 실행.
#
# 감시 범위: 로컬(이 디바이스) transcript는 직접 판정. 원격(gentop/kangnote)은 mesh/inter-session status로.
# 출력: human 요약(stdout) + JSONL 로그(~/.claude/fleet-watchdog.log)
# 인수: --nudge (이상 세션에 inter-session 넛지 전송) | 기본은 관찰만.

set +e
SGC="$HOME/.claude/hooks/session-goal-check.sh"
PROJDIR="${WATCHDOG_PROJDIR:-/Users/nova-ai/project}"
PROJSLUG=$(echo "$PROJDIR" | sed 's#/#-#g')
BIN="$HOME/.claude/plugins/cache/inter-session/inter-session/0.1.2/skills/inter-session/bin"
LOG="$HOME/.claude/fleet-watchdog.log"
NOW=$(date +%s)
STALL_MIN="${WATCHDOG_STALL_MIN:-12}"   # INCOMPLETE인데 이 분수 이상 진행 없으면 정체
NUDGE=0; [ "$1" = "--nudge" ] && NUDGE=1
MY_SID="${NCO_SESSION_ID:-}"

echo "━━━ [$(date '+%m-%d %H:%M')] fleet-session-watchdog ━━━"
[ -f "$SGC" ] || { echo "  ✗ session-goal-check 없음 — 중단"; exit 1; }

anomalies=0; checked=0
for tx in $(ls -t "$HOME/.claude/projects/${PROJSLUG}"/*.jsonl 2>/dev/null); do
    mt=$(stat -f %m "$tx" 2>/dev/null || echo "$NOW")
    age=$(( (NOW - mt) / 60 ))
    [ "$age" -gt 40 ] && continue   # 40분+ idle = 비활성 스킵
    sid=$(basename "$tx" .jsonl)
    short=$(echo "$sid" | cut -c1-8)
    [ -n "$MY_SID" ] && echo "$sid" | grep -q "$MY_SID" && short="$short(self)"
    j=$(CLAUDE_PROJECT_DIR="$PROJDIR" bash "$SGC" "$tx" 2>/dev/null | tail -1)
    read -r verdict gap nnext fr <<< "$(printf '%s' "$j" | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    print(d.get('verdict','?'), d.get('gap','?'), len(d.get('next_steps') or []), 1 if d.get('final_receipt') else 0)
except Exception: print('? ? 0 0')" 2>/dev/null)"
    checked=$((checked+1))

    # ── 이상 탐지 ──
    flag=""
    if [ "$verdict" = "INCOMPLETE" ] && [ "$age" -ge "$STALL_MIN" ]; then
        # 진행중인데 STALL_MIN분 이상 transcript 변화 없음 = 정체(멈춤) 의심
        flag="⚠️정체(${age}m 무변화, gap=${gap}%, next=${nnext}, receipt=${fr})"
        anomalies=$((anomalies+1))
    elif [ "$verdict" = "?" ]; then
        flag="⚠️판정불가(transcript 파싱 실패)"
        anomalies=$((anomalies+1))
    fi

    printf "  [%s] verdict=%s gap=%s%% next=%s age=%sm %s\n" "$short" "$verdict" "$gap" "$nnext" "$age" "$flag"

    # ── JSONL 로그 ──
    printf '{"ts":"%s","sid":"%s","verdict":"%s","gap":"%s","next":%s,"final_receipt":%s,"age_min":%s,"anomaly":"%s"}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$short" "$verdict" "$gap" "$nnext" "$fr" "$age" "$flag" >> "$LOG" 2>/dev/null

    # ── 넛지(옵션): 정체 세션에 inter-session 알림 (self 제외) ──
    if [ "$NUDGE" = "1" ] && [ -n "$flag" ] && ! echo "$short" | grep -q self; then
        : # 넛지는 세션명↔sid 매핑이 필요 — v2에서 활성화. 지금은 관찰·로그만.
    fi
done

echo "  ─ 검사 ${checked}세션, 이상 ${anomalies}건 ─"
# 원격 세션(mesh) 요약
_ms=$(curl -s -m 2 http://localhost:6200/api/mesh/sessions 2>/dev/null | python3 -c "import json,sys
try:
 d=json.load(sys.stdin); s=d.get('sessions',d) if isinstance(d,(dict,list)) else []
 print(len(s) if isinstance(s,list) else '?')
except: print('?')" 2>/dev/null)
echo "  ─ mesh 원격 세션: ${_ms} (원격 transcript 직접판정 불가 → self-report 의존) ─"
exit 0
