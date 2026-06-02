#!/bin/bash
# UserPromptSubmit Hook — NCO 워크플로우 통합 가이드 (task-aware)
#
# 정책 (2026-05-25 재설계):
#   - 위임 결정은 매 task(=새 user prompt) 시작 시 1회만.
#   - 이미 시작된 작업은 끝까지 진행. 도구 차단 없음.
#   - baseline 기준 변경 파일 카운트 (dirty tree 잡음 제거).
#
# exit 0 항상.

# ── Ollama 로컬 모드: 스킵 ─────────────────────────────────
[ "${NCO_OLLAMA_MODE:-0}" = "1" ] && exit 0

# ── NCO 온라인 확인 ────────────────────────────────────────
NCO_HEALTH=$(curl -s --connect-timeout 1 --max-time 2 "http://localhost:6200/health" 2>/dev/null)
[ -z "$NCO_HEALTH" ] && exit 0

INPUT=$(cat)
PROMPT=$(echo "$INPUT" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print((d.get('userMessage') or d.get('prompt') or '')[:400])
except: pass
" 2>/dev/null)
[ -z "$PROMPT" ] && exit 0
[ ${#PROMPT} -lt 10 ] && exit 0

IS_QUERY=0
echo "$PROMPT" | grep -qiE '^(왜|어디|뭐|무엇|어떻게|설명|보여|확인|상태|보고|몇|얼마|what|why|how|show|check|status|report)' && IS_QUERY=1

# ── 세션 ID ───────────────────────────────────────────────
_SID="${NCO_SESSION_ID:-}"
if [ -z "$_SID" ]; then
  _CK=$$
  for _i in 1 2 3; do
    _CK=$(ps -o ppid= -p "$_CK" 2>/dev/null | tr -d ' ')
    [ -z "$_CK" ] && break
    ps -o comm= -p "$_CK" 2>/dev/null | grep -qE '^(claude|node)$' && { _SID="$_CK"; break; }
  done
  _SID="${_SID:-$$}"
fi
TRACK="/tmp/nco-track-${_SID}.json"
STAGE="/tmp/nco-stages-${_SID}.json"
BASELINE="/tmp/nco-baseline-${_SID}-files"

# ── 통계 + state machine 로드 ─────────────────────────────
NCO_CALLS=0; DIRECT=0; AGENT_VIOL=0; TASK_TYPE="unknown"
TASK_SEQ=0; TASK_STARTED=-1; TASK_WARNED=-1; TASK_DECISION="pending"
if [ -f "$TRACK" ]; then
  read -r NCO_CALLS DIRECT AGENT_VIOL TASK_SEQ TASK_STARTED TASK_WARNED <<< "$(python3 -c "
import json
try:
    d=json.load(open('$TRACK'))
    print(d.get('nco_calls',0), d.get('direct_edits',0),
          d.get('agent_violations',0), d.get('task_seq',0),
          d.get('task_started_seq',-1), d.get('task_warned_seq',-1))
except: print('0 0 0 0 -1 -1')
" 2>/dev/null)"
  TASK_TYPE=$(python3 -c "import json; print(json.load(open('$TRACK')).get('task_type','unknown'))" 2>/dev/null || echo "unknown")
  TASK_DECISION=$(python3 -c "import json; print(json.load(open('$TRACK')).get('task_decision','pending'))" 2>/dev/null || echo "pending")
fi
TOTAL=$((NCO_CALLS + DIRECT))
PCT=0; [ "$TOTAL" -gt 0 ] && PCT=$((NCO_CALLS * 100 / TOTAL))

# ── stage 로드 ────────────────────────────────────────────
STAGES_JSON="{}"
[ -f "$STAGE" ] && STAGES_JSON=$(cat "$STAGE" 2>/dev/null || echo "{}")

# ── 변경 파일 수 (baseline 이후만) ───────────────────────
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-.}"
if [ -f "$BASELINE" ]; then
    CHANGED_COUNT=$(git -C "$PROJECT_DIR" diff --name-only 2>/dev/null | sort -u | comm -23 - <(sort -u "$BASELINE") | wc -l | tr -d ' ')
else
    CHANGED_COUNT=$(git -C "$PROJECT_DIR" diff --name-only 2>/dev/null | wc -l | tr -d ' ')
fi

# ── task_decision 평가 (이번 task에 아직 결정 안 났을 때만) ─
# 기준: baseline 이후 변경 ≥3 AND nco_calls=0 AND 조회성 prompt 아님 → delegate 권고
if [ "$TASK_DECISION" = "pending" ]; then
    if [ "$IS_QUERY" -eq 1 ]; then
        TASK_DECISION="direct"
    elif [ "$CHANGED_COUNT" -ge 5 ] && [ "$NCO_CALLS" -eq 0 ]; then
        TASK_DECISION="delegate"
    elif [ "$CHANGED_COUNT" -ge 3 ] && [ "$NCO_CALLS" -eq 0 ] && [ "$TASK_TYPE" = "new_feature" ]; then
        TASK_DECISION="delegate"
    else
        TASK_DECISION="direct"
    fi
    # 저장
    python3 -c "
import json
f='$TRACK'; d={}
try: d=json.load(open(f))
except: pass
d['task_decision']='$TASK_DECISION'
json.dump(d, open(f,'w'))
" 2>/dev/null
fi

# ── 주입 가드: 이미 이번 task에 권고했거나 작업이 시작된 경우 ──
# (작업 진행 중 추가 prompt가 오더라도 같은 task로 간주되진 않음 —
#  task_classifier가 매 prompt마다 task_seq++ 하므로. 그래도 안전망)
ALREADY_WARNED=0
[ "$TASK_WARNED" = "$TASK_SEQ" ] && ALREADY_WARNED=1
ALREADY_STARTED=0
[ "$TASK_STARTED" = "$TASK_SEQ" ] && ALREADY_STARTED=1

python3 - << PYEOF
import json, sys

nco = $NCO_CALLS
direct = $DIRECT
total = $TOTAL
pct = $PCT
agent_viol = $AGENT_VIOL
changed = int("$CHANGED_COUNT" or 0)
task_type = "$TASK_TYPE"
task_decision = "$TASK_DECISION"
already_warned = $ALREADY_WARNED
already_started = $ALREADY_STARTED
is_query = $IS_QUERY

try: stages = json.loads("""$STAGES_JSON""")
except: stages = {}

bar = "█" * (pct // 10) + "░" * (10 - pct // 10)
rate_line = f"NCO 사용률: {bar} {pct}%  (NCO:{nco}회 / 직접:{direct}회)"

lines = ["[NCO Commander 워크플로우]"]
lines.append(rate_line)

# ── 단계 체크리스트 (항상 표시 — 작업 진행에 유용) ────────
stage_info = [
    ("discussion",     "토론/설계",   "/nco-discussion | /nco-task opencode"),
    ("implementation", "구현 위임",   "/nco-task codex | /nco-team | /nco-parallel"),
    ("review",         "코드 리뷰",   "/nco-task cursor-agent '리뷰: ...'"),
    ("gap_analysis",   "Gap 분석",    "/nco-gap | /nco-analyze"),
    ("verification",   "검증",        "/nco-task ollama '검증: ...'"),
]

lines.append("")
lines.append("── 워크플로우 체크리스트 ──────────────────────────")
for key, label, cmd in stage_info:
    done = stages.get(key, False)
    icon = "✅" if done else "⬜"
    lines.append(f"  {icon} {label:<10}  {cmd}")

# ── 권고는 이번 task에 1회만 ─────────────────────────────
if already_warned or already_started:
    # 이미 권고했거나 작업 시작됨 → 추가 권고 없음, 체크리스트만
    pass
elif task_decision == "delegate":
    lines.append("")
    lines.append("── 위임 권고 (이번 작업 시작 전 1회만) ────────────")
    if task_type == "new_feature":
        lines.append(f"  → 신규 기능 + baseline 이후 변경 {changed}개 감지")
        lines.append("  → opencode 설계 → codex 구현 → cursor-agent 리뷰 권장")
        lines.append("  → Skill(nco-task) opencode  또는  Skill(nco-parallel) [codex, cursor-agent]")
    else:
        lines.append(f"  → baseline 이후 변경 {changed}개, NCO 사용 0회")
        lines.append("  → Skill(nco-task) codex  또는  Skill(nco-parallel) [codex, cursor-agent]")
    lines.append("  ※ 이 권고는 이번 task에 1회만 표시됩니다. 이미 직접 진행 중이면 그대로 완료하세요.")

if agent_viol > 0:
    lines.append("")
    lines.append(f"⛔ Agent 도구 위반 {agent_viol}회 — NCO MCP 도구만 사용!")

lines.append("──────────────────────────────────────────────────")

print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "UserPromptSubmit",
        "additionalContext": "\n".join(lines)
    }
}))
PYEOF

# ── task_warned_seq 갱신 (delegate를 실제 주입한 경우) ──
if [ "$TASK_DECISION" = "delegate" ] && [ "$ALREADY_WARNED" -eq 0 ] && [ "$ALREADY_STARTED" -eq 0 ]; then
    python3 -c "
import json
f='$TRACK'; d={}
try: d=json.load(open(f))
except: pass
d['task_warned_seq']=$TASK_SEQ
json.dump(d, open(f,'w'))
" 2>/dev/null
fi

exit 0
