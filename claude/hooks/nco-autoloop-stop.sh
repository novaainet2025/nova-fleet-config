#!/bin/bash
# nco-autoloop-stop.sh — Stop 훅: "다음 단계가 있으면 자동 실행(exit 2), 없으면 종료(exit 0)"
# 사용자 지시(2026-07-12): 다음 단계 자동 실행, 더 이상 없을 때까지 진행.
#
# 판정 코어: session-goal-check.sh (transcript=세션 지상진실). 이 훅은 그 결과를 Stop 계속신호로 변환.
#
# 계약(과거 '반복 Stop훅 스팸' 재발 방지):
#   - 작업 보고(검증 영수증)가 있는 턴에서만 자동 계속 → 잡담/조회 턴은 건드리지 않음(final_receipt 게이트)
#   - 영수증의 [Gap] 값이 완료 신호: [Gap]>=98(=COMPLETE) → 종료 / [Gap]<98(=INCOMPLETE) → 계속
#   - 총 횟수 cap + stop_hook_active 인지 → runaway 차단
#   - 토글: NCO_AUTOLOOP=0 (완전 비활성), 재개: rm 상태파일
#
# exit 0 = 종료(완료/다음단계없음/잡담) | exit 2 = 계속(다음 단계 자동 실행 지시 주입)

[ "${NCO_HOOK_DISABLED:-0}" = "1" ] && exit 0
[ "${NCO_AUTOLOOP:-1}" = "0" ] && exit 0

INPUT=$(cat 2>/dev/null)

TX=$(printf '%s' "$INPUT" | python3 -c "import json,sys
try: print(json.load(sys.stdin).get('transcript_path',''))
except: print('')" 2>/dev/null)
# transcript 없으면 판정 불가 → 안전하게 종료
[ -z "$TX" ] && exit 0
[ ! -f "$TX" ] && exit 0

SID=$(basename "$TX" .jsonl)
STATE="/tmp/nco-autoloop-${SID}"
TOTAL_CAP=${NCO_AUTOLOOP_TOTAL_CAP:-10}
GOAL_CHECK="$HOME/.claude/hooks/session-goal-check.sh"
[ -x "$GOAL_CHECK" ] || [ -f "$GOAL_CHECK" ] || { rm -f "$STATE"; exit 0; }

PROJDIR="${CLAUDE_PROJECT_DIR:-/Users/nova-ai/project}"
JSON=$(CLAUDE_PROJECT_DIR="$PROJDIR" bash "$GOAL_CHECK" "$TX" 2>/dev/null)
ec=$?

# stale-read 방지(레이스): Stop 훅이 직전 완료 턴([Gap]100 등)이 transcript에 flush되기 전에
# 읽으면 미완으로 오판해 헛돎. INCOMPLETE면 잠깐 대기 후 1회 재확인 — 완료 턴이 반영되면 종료.
if [ "$ec" = "2" ]; then
    sleep 0.7
    JSON=$(CLAUDE_PROJECT_DIR="$PROJDIR" bash "$GOAL_CHECK" "$TX" 2>/dev/null)
    ec=$?
fi

# 코어가 COMPLETE(0)/NO_GOALS·미확보(3) → 종료, 상태 리셋
if [ "$ec" != "2" ]; then
    rm -f "$STATE"
    exit 0
fi

# INCOMPLETE — final_receipt(작업보고) 게이트: 영수증 없는 턴(잡담/조회)은 자동계속 안 함
FR=$(printf '%s' "$JSON" | python3 -c "import json,sys
try: print('1' if json.load(sys.stdin).get('final_receipt') else '0')
except: print('0')" 2>/dev/null)
if [ "$FR" != "1" ]; then
    # 작업 보고가 아닌 턴 → 자동계속 억제(무한 잡담 루프 방지). 상태는 유지(다음 작업턴에 이어감).
    exit 0
fi

NEXT=$(printf '%s' "$JSON" | python3 -c "import json,sys
try:
 ns=json.load(sys.stdin).get('next_steps',[])
 print(' | '.join(ns[:5]))
except: print('')" 2>/dev/null)

# 총 횟수 cap (COMPLETE 시 리셋됨). runaway 최종 방어선.
TOTAL=$(cat "$STATE" 2>/dev/null | tr -dc '0-9'); TOTAL=$(( ${TOTAL:-0} + 1 ))
if [ "$TOTAL" -gt "$TOTAL_CAP" ]; then
    rm -f "$STATE"
    cat >&2 <<EOF
[AUTO-LOOP 정지] 자동 계속 상한 도달 ($TOTAL_CAP회). 남은 다음 단계: ${NEXT:-불명}
→ 완료면 [Gap] 100% 영수증으로 보고(→종료), 계속하려면 rm $STATE, 끄려면 NCO_AUTOLOOP=0.
EOF
    exit 0
fi
printf '%s\n' "$TOTAL" > "$STATE"

# exit 2 — 다음 단계 자동 실행 지시 주입 (stop_hook_active와 무관하게 cap이 상한 보장)
cat >&2 <<EOF
[AUTO-LOOP] 다음 단계가 남아있습니다 (${TOTAL}/${TOTAL_CAP}). 지금 자동으로 실행하세요:
${NEXT:-(session-goal-check: 미완 목표 진행중)}

완료 기준: 실제 검증 후 '## 검증 영수증'에 [Gap] 100% 로 보고하면 루프가 COMPLETE로 종료됩니다.
미완이면 [Gap] N%(<100)로 보고하고 다음 단계를 계속하세요.
강제 종료: NCO_AUTOLOOP=0  (또는 상한 도달 시 자동 정지)
EOF
exit 2
