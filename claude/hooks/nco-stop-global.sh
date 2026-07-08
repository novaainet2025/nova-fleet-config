#!/bin/bash
# NCO 재귀보호: NCO가 스폰한 서브프로세스 claude에서는 훅 무동작 (2026-07-08, 76s 훅스택+BOOTSTRAP 오염 T1)
[ "${NCO_HOOK_DISABLED:-0}" = "1" ] && exit 0
# Global Stop Hook — 세션 종료 시 진행사항 + 다음 작업 표시
# 어느 디렉토리에서나 동작

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"

# NCO 프로젝트의 고급 훅이 있으면 위임
NCO_HOOK="{{HOME}}/projects/neural-cli-orchestrator/.claude/hooks/end-of-turn-check.sh"
if [ -f "$NCO_HOOK" ] && [ "$PROJECT_DIR" = "{{HOME}}/projects/neural-cli-orchestrator" ]; then
    exec bash "$NCO_HOOK"
fi

# ── 세션 ID 해석 ────────────────────────────────────────────────────────
if [ -z "$NCO_SESSION_ID" ]; then
    _CK=$$
    for _i in 1 2 3 4 5; do
        _CK=$(ps -o ppid= -p "$_CK" 2>/dev/null | tr -d ' ')
        [ -z "$_CK" ] && break
        _CM=$(ps -o comm= -p "$_CK" 2>/dev/null)
        echo "$_CM" | grep -qE '^(claude|node)$' && { NCO_SESSION_ID="$_CK"; break; }
    done
    NCO_SESSION_ID="${NCO_SESSION_ID:-$$}"
fi
SESSION_TRACK="/tmp/nco-track-${NCO_SESSION_ID}.json"

# ── 세션 통계 ──────────────────────────────────────────────────────────
DIRECT_EDITS=0; NCO_CALLS=0; AGENT_VIOLATIONS=0
if [ -f "$SESSION_TRACK" ]; then
    _vals=$(python3 -c "
import json
try:
    d=json.load(open('$SESSION_TRACK'))
    print(d.get('direct_edits',0), d.get('nco_calls',0), d.get('agent_violations',0))
except: print('0 0 0')
" 2>/dev/null)
    read -r DIRECT_EDITS NCO_CALLS AGENT_VIOLATIONS <<< "$_vals"
fi
DIRECT_EDITS=$(( ${DIRECT_EDITS:-0} + 0 ))
NCO_CALLS=$(( ${NCO_CALLS:-0} + 0 ))
AGENT_VIOLATIONS=$(( ${AGENT_VIOLATIONS:-0} + 0 ))

# ── Git 상태 ────────────────────────────────────────────────────────────
cd "$PROJECT_DIR" 2>/dev/null || cd {{HOME}}/projects 2>/dev/null
BRANCH=$(git branch --show-current 2>/dev/null || echo "unknown")
LAST_COMMIT=$(git log -1 --pretty=format:"%s" 2>/dev/null | head -c 60 || echo "no commits")
CHANGED_FILES=$(git diff --name-only 2>/dev/null)
STAGED_FILES=$(git diff --cached --name-only 2>/dev/null)
ALL_CHANGED=$(printf "%s\n%s" "$CHANGED_FILES" "$STAGED_FILES" | sort -u | grep -v '^$' || true)

# 안전한 정수 변환 (grep -c || echo 0 패턴 제거)
_raw_count=$(echo "$ALL_CHANGED" | grep -c '.' 2>/dev/null); CHANGED_COUNT=$(( ${_raw_count:-0} + 0 ))
_raw_add=$(git diff --stat 2>/dev/null | grep -oP '\d+(?= insertion)' | head -1); ADDITIONS=$(( ${_raw_add:-0} + 0 ))
_raw_del=$(git diff --stat 2>/dev/null | grep -oP '\d+(?= deletion)' | head -1); DELETIONS=$(( ${_raw_del:-0} + 0 ))

# ── 태스크 파싱 ─────────────────────────────────────────────────────────
TOTAL_TASKS=0; DONE_TASKS=0; NEXT_TASKS=""
for plan_file in docs/plans/*.md .llm/todo.md TASKS.md; do
    [ -f "$plan_file" ] || continue
    while IFS= read -r line; do
        if echo "$line" | grep -qE '^\s*-\s*\[[ xX]\]'; then
            TOTAL_TASKS=$(( TOTAL_TASKS + 1 ))
            if echo "$line" | grep -qE '^\s*-\s*\[[xX]\]'; then
                DONE_TASKS=$(( DONE_TASKS + 1 ))
            else
                text=$(echo "$line" | sed 's/^\s*-\s*\[ \]\s*//')
                NEXT_TASKS="${NEXT_TASKS}  - ${text}\n"
            fi
        fi
    done < "$plan_file"
done

# ── Gap 계산 ────────────────────────────────────────────────────────────
if [ "$TOTAL_TASKS" -gt 0 ]; then
    GAP_RATE=$(( (DONE_TASKS * 100) / TOTAL_TASKS ))
elif [ "$CHANGED_COUNT" -gt 0 ]; then
    GAP_RATE=85
else
    GAP_RATE=100
fi

# ── 에이전트 사용 상태 ──────────────────────────────────────────────────
if [ "$NCO_CALLS" -gt 0 ]; then
    AGENT_STATUS="✓ NCO 에이전트 ${NCO_CALLS}회 사용"
else
    AGENT_STATUS="✗ NCO 에이전트 미사용 (직접 편집 ${DIRECT_EDITS}회)"
fi

if [ "$AGENT_VIOLATIONS" -gt 0 ]; then
    AGENT_STATUS="${AGENT_STATUS} | ⛔ Agent도구 위반 ${AGENT_VIOLATIONS}회"
fi

# ── 위반 여부 판정 ────────────────────────────────────────────────────
TASK_TYPE=$(python3 -c "
import json
try: print(json.load(open('$SESSION_TRACK')).get('task_type','unknown'))
except: print('unknown')
" 2>/dev/null)

VIOLATION=""
if [ "$NCO_CALLS" -eq 0 ]; then
    case "$TASK_TYPE" in
        new_feature)
            [ "$DIRECT_EDITS" -ge 1 ] && VIOLATION="신규 기능을 NCO 위임 없이 직접 편집 ${DIRECT_EDITS}회" ;;
        bug)
            [ "$DIRECT_EDITS" -ge 2 ] && VIOLATION="버그 수정을 NCO 위임 없이 직접 편집 ${DIRECT_EDITS}회" ;;
        *)
            [ "$DIRECT_EDITS" -ge 3 ] && VIOLATION="파일 ${CHANGED_COUNT}개를 NCO 위임 없이 직접 편집 ${DIRECT_EDITS}회" ;;
    esac
fi

# Agent 도구 오용도 위반
if [ "$AGENT_VIOLATIONS" -gt 0 ]; then
    if [ -n "$VIOLATION" ]; then
        VIOLATION="${VIOLATION} + Agent도구 ${AGENT_VIOLATIONS}회 오용"
    else
        VIOLATION="Agent도구 ${AGENT_VIOLATIONS}회 오용 (NCO 도구 대신 내장 Agent 사용)"
    fi
fi

# ── stderr 출력 (사용자 표시용) ───────────────────────────────────────
cat >&2 <<EOF
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
[턴 종료 리포트] ${BRANCH} — ${LAST_COMMIT}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

[현재 진행사항]
  변경 파일: ${CHANGED_COUNT}개 (+${ADDITIONS}/-${DELETIONS})
  태스크:   ${DONE_TASKS}/${TOTAL_TASKS} 완료 (Gap ${GAP_RATE}%)
  에이전트: ${AGENT_STATUS}

EOF

if [ "$CHANGED_COUNT" -gt 0 ]; then
    echo "[변경된 파일]" >&2
    echo "$ALL_CHANGED" | head -10 | sed 's/^/  /' >&2
    echo "" >&2
fi

echo "[다음 작업]" >&2
if [ -n "$NEXT_TASKS" ]; then
    echo -e "$NEXT_TASKS" | head -5 >&2
else
    echo "  (plan 파일에 미완료 태스크 없음)" >&2
fi

if [ -n "$VIOLATION" ]; then
    cat >&2 <<EOF

⛔ [규칙 위반 발생]
   ${VIOLATION}
   → 다음 턴 시작 시 강제 경고가 주입됩니다.
EOF
fi

cat >&2 <<EOF

[다음 액션]
  /nco-next            — 다음 순차 작업
  /nco-next-parallel   — 독립 태스크 병렬 실행
  /nco-task <설명>     — NCO에 작업 위임
  /nco-gap             — gap 재분석
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF

# ── NCO 추천 (온라인 시) ───────────────────────────────────────────────
NCO_HEALTH=$(curl -s --connect-timeout 1 --max-time 2 "http://localhost:6200/health" 2>/dev/null)
if [ -n "$NCO_HEALTH" ]; then
    NCO_REC=$(curl -s -m 2 "http://localhost:6200/api/tasks/recommend" 2>/dev/null | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    if d.get('task'): print(d['task'].get('description','')[:80])
except: pass
" 2>/dev/null)
fi

# ── stdout → Claude 컨텍스트 주입 ────────────────────────────────────
# (Stop 훅의 stdout은 Claude가 다음 응답 생성 시 참조)
if [ -n "$VIOLATION" ]; then
    cat <<EOF
[STOP HOOK — 규칙 위반 경고]
이번 턴에 NCO 위임 규칙을 위반했습니다: ${VIOLATION}
태스크 유형: ${TASK_TYPE} | NCO 사용: ${NCO_CALLS}회 | 직접 편집: ${DIRECT_EDITS}회

다음 응답에서 반드시:
1. 적합한 NCO 에이전트에 위임 (nco_task / nco_parallel / nco_commander)
2. 직접 편집은 에이전트 결과 통합 시에만 수행
EOF
else
    cat <<EOF
[STOP HOOK — 턴 요약]
변경 파일: ${CHANGED_COUNT}개 | NCO 사용: ${NCO_CALLS}회 | 태스크: ${DONE_TASKS}/${TOTAL_TASKS}
${NCO_REC:+NCO 추천: ${NCO_REC}}
EOF
fi

# ── 다음 턴 주입용 요약 파일 저장 ───────────────────────────────────
# mesh-precheck.sh 가 이 파일을 읽어 대화창 system-reminder에 표시함
SUMMARY_FILE="/tmp/nco-stop-summary-${NCO_SESSION_ID}.json"
python3 -c "
import json, os

changed_files = '''$ALL_CHANGED'''.strip().splitlines()
next_tasks_raw = '''$NEXT_TASKS'''.strip()
next_tasks = [l.strip() for l in next_tasks_raw.splitlines() if l.strip() and l.strip() != '-']

summary = {
    'branch': '$BRANCH',
    'last_commit': '$LAST_COMMIT',
    'changed_count': int('$CHANGED_COUNT' or 0),
    'changed_files': [f for f in changed_files if f][:5],
    'done_tasks': int('$DONE_TASKS' or 0),
    'total_tasks': int('$TOTAL_TASKS' or 0),
    'gap_rate': int('$GAP_RATE' or 100),
    'next_tasks': next_tasks[:3],
    'nco_rec': '$NCO_REC',
    'violation': '$VIOLATION',
    'agent_status': '$AGENT_STATUS',
}
json.dump(summary, open('$SUMMARY_FILE', 'w'), ensure_ascii=False)
" 2>/dev/null

# ── 세션 파일: 위반 기록 유지, 카운터 리셋 ──────────────────────────
python3 -c "
import json, os
f = '$SESSION_TRACK'
d = {}
if os.path.exists(f):
    try: d = json.load(open(f))
    except: pass
d['nco_calls_total'] = d.get('nco_calls_total', 0) + d.get('nco_calls', 0)
d['direct_edits_total'] = d.get('direct_edits_total', 0) + d.get('direct_edits', 0)
d['direct_edits'] = 0
d['nco_calls'] = 0
d['warned'] = 0
d['agent_violations'] = 0
d['prev_violation'] = '$VIOLATION'
json.dump(d, open(f,'w'))
" 2>/dev/null

exit 0

# ── NCO 사용률 평가 (Stop 시 출력) ────────────────────────────────
_NCO_PCT=0
if [ $((NCO_CALLS + DIRECT_EDITS)) -gt 0 ]; then
  _NCO_PCT=$(( NCO_CALLS * 100 / (NCO_CALLS + DIRECT_EDITS) ))
fi

_BAR=$(python3 -c "p=$_NCO_PCT; print('█'*(p//10)+'░'*(10-p//10))" 2>/dev/null || echo "░░░░░░░░░░")

cat >&2 << EVALEOF
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
[NCO 사용률 평가]
  ${_BAR} ${_NCO_PCT}%  (목표: 80%+)
  NCO 위임: ${NCO_CALLS}회 | 직접 처리: ${DIRECT_EDITS}회
$([ $_NCO_PCT -ge 80 ] && echo "  ✅ 목표 달성" || echo "  ❌ 목표 미달 — 다음 세션에서 NCO 위임 우선")
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EVALEOF
