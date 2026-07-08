#!/bin/bash
# NCO 재귀보호: NCO가 스폰한 서브프로세스 claude에서는 훅 무동작 (2026-07-08, 76s 훅스택+BOOTSTRAP 오염 T1)
[ "${NCO_HOOK_DISABLED:-0}" = "1" ] && exit 0
# [사용자 요청] 반복 Stop 훅 완료차단/스팸 영구 제거 (fleet 원본). 복구: 아래 exit 0 삭제.
# 안전 게이트: 수동 off / 상태 dedup / 세션당 재발화 상한
if [ "$NCO_STOP_GATES" = "off" ]; then
    exit 0
fi

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

_NCO_GATE_TRACK_FILE="/tmp/nco-track-${NCO_SESSION_ID}.json"
_NCO_GATE_STAGE_FILE="/tmp/nco-stages-${NCO_SESSION_ID}.json"
_NCO_GATE_STATE_FILE="/tmp/nco-gate-state-${NCO_SESSION_ID}"
_NCO_GATE_FIRED_FILE="/tmp/nco-gate-fired-${NCO_SESSION_ID}"
_NCO_GATE_HASH=$(
    {
        printf 'track\n'
        [ -f "$_NCO_GATE_TRACK_FILE" ] && cat "$_NCO_GATE_TRACK_FILE"
        printf '\nstages\n'
        [ -f "$_NCO_GATE_STAGE_FILE" ] && cat "$_NCO_GATE_STAGE_FILE"
    } | shasum -a 256 | awk '{print $1}'
)
_NCO_GATE_PREV_HASH=$(cat "$_NCO_GATE_STATE_FILE" 2>/dev/null)
if [ "$_NCO_GATE_HASH" = "$_NCO_GATE_PREV_HASH" ]; then
    exit 0
fi
_NCO_GATE_FIRED=$(tr -dc '0-9' < "$_NCO_GATE_FIRED_FILE" 2>/dev/null)
_NCO_GATE_FIRED=${_NCO_GATE_FIRED:-0}
if [ "$_NCO_GATE_FIRED" -ge 2 ]; then
    exit 0
fi
printf '%s\n' "$_NCO_GATE_HASH" > "$_NCO_GATE_STATE_FILE"
printf '%s\n' "$((_NCO_GATE_FIRED + 1))" > "$_NCO_GATE_FIRED_FILE"
# Stop Hook: NCO 품질 게이트 — 완료 전 실제 검증 강제
# exit 0 = 통과 | exit 2 = 차단 (stderr → Claude 주입)
# 목표: 에이전트 자기 보고(self-report) 대신 서버/컴파일러 실제 검증 결과만 신뢰

echo "[$(date +%H:%M:%S)] HOOK_START nco-stop-quality-gate.sh" >> /tmp/claude-hook-trace.log
trap 'echo "[$(date +%H:%M:%S)] HOOK_END   nco-stop-quality-gate.sh exit=$?" >> /tmp/claude-hook-trace.log' EXIT

INPUT=$(cat)

# ── 세션 ID 결정 ────────────────────────────────────────────────────────
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

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-/Users/nova-ai/project/neural-cli-orchestrator}"
NCO_API="http://localhost:6200"

# ── NCO 오프라인이면 게이트 스킵 ────────────────────────────────────────
NCO_HEALTH=$(curl -s --connect-timeout 1 --max-time 2 "$NCO_API/health" 2>/dev/null)
if [ -z "$NCO_HEALTH" ]; then
    exit 0
fi

# ═══════════════════════════════════════════════════════════════════════
# GATE -1: 이 turn에 코드 수정 없으면 워크플로우 게이트 면제
# peer 답신·조회·skill 호출·진단 등 정보-only turn은 워크플로우 무관.
# transcript JSONL에서 마지막 real user prompt 이후 Edit/Write/MultiEdit/NotebookEdit tool_use 카운트.
# tsc/lint(GATE 1/2)는 프로젝트 상태 검증이라 유지.
# ═══════════════════════════════════════════════════════════════════════
TRANSCRIPT_PATH=$(echo "$INPUT" | python3 -c "
import sys, json
try: print(json.load(sys.stdin).get('transcript_path',''))
except: pass
" 2>/dev/null)

if [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ]; then
    EDITS_THIS_TURN=$(python3 -c "
import json
EDIT_TOOLS = {'Edit','Write','MultiEdit','NotebookEdit'}
try:
    lines = open('$TRANSCRIPT_PATH').readlines()
except: lines = []
last_user = -1
for i in range(len(lines)-1, -1, -1):
    try:
        d = json.loads(lines[i])
        if d.get('type') != 'user': continue
        if 'toolUseResult' in d: continue
        last_user = i
        break
    except: pass
n = 0
for i in range(last_user+1, len(lines)):
    try:
        d = json.loads(lines[i])
        if d.get('type') != 'assistant': continue
        content = (d.get('message') or {}).get('content', [])
        if not isinstance(content, list): continue
        for c in content:
            if isinstance(c, dict) and c.get('type') == 'tool_use' and c.get('name') in EDIT_TOOLS:
                n += 1
    except: pass
print(n)
" 2>/dev/null)
    if [ "${EDITS_THIS_TURN:-0}" = "0" ]; then
        echo "[$(date +%H:%M:%S)] STOP_GATE skip — no code edits this turn (edits=0)" >> /tmp/claude-hook-trace.log
        exit 0
    fi
fi

# ═══════════════════════════════════════════════════════════════════════
# GATE 0: 워크플로우 단계 누락 (task_type별 필수 단계)
# cycle counter로 최대 5회까지 exit 2 강제, 그 이후 cap (Phase 2 백그라운드 큐잉 예정)
# ═══════════════════════════════════════════════════════════════════════
# BYPASS: NCO_WORKFLOW_BYPASS=1 환경변수 OR per-session sentinel 파일 존재 시 GATE 0 면제
# (GATE 1/2 = tsc/lint은 그대로 유효)
if [ "$NCO_WORKFLOW_BYPASS" = "1" ] || [ -f "/tmp/nco-bypass-${NCO_SESSION_ID}" ]; then
    echo "[$(date +%H:%M:%S)] WORKFLOW_GATE bypassed (env=$NCO_WORKFLOW_BYPASS sentinel=$([ -f /tmp/nco-bypass-${NCO_SESSION_ID} ] && echo yes || echo no))" >> /tmp/claude-hook-trace.log
else
. /Users/nova-ai/.claude/hooks/nco-workflow-rules.sh 2>/dev/null

STAGE_FILE="/tmp/nco-stages-${NCO_SESSION_ID}.json"
TRACK_FILE="/tmp/nco-track-${NCO_SESSION_ID}.json"
CYCLE_FILE="/tmp/nco-stop-cycle-${NCO_SESSION_ID}"
CYCLE_LOCK="/tmp/nco-stop-cycle-${NCO_SESSION_ID}.lock"
BLOCKED_SENTINEL="/tmp/nco-stop-blocked-${NCO_SESSION_ID}"
CYCLE_CAP=5

# (d) task_type을 신뢰하지 않고 enum 화이트리스트로 재검증
WF_TASK_TYPE_RAW=$(python3 -c "
import json
try: print(json.load(open('$TRACK_FILE')).get('task_type','unknown'))
except: print('unknown')
" 2>/dev/null)
case "$WF_TASK_TYPE_RAW" in
    bug|new_feature|config|simple|query|unknown|mesh_delegated) WF_TASK_TYPE="$WF_TASK_TYPE_RAW" ;;
    *) WF_TASK_TYPE="unknown" ;;
esac

MISSED=$(missed_required_stages "$STAGE_FILE" "$WF_TASK_TYPE" 2>/dev/null)
# MISSED도 enum 단어만 — 라이브러리는 안전하지만 방어
MISSED=$(echo "$MISSED" | tr -dc 'a-z_ ')

if [ -n "$MISSED" ]; then
    # (a) flock으로 read-modify-write 전체를 보호
    exec 9>"$CYCLE_LOCK"
    if command -v flock >/dev/null 2>&1; then
        flock -w 5 9 2>/dev/null || true
    fi

    CYCLE=$(cat "$CYCLE_FILE" 2>/dev/null | tr -dc '0-9')
    CYCLE=$(( ${CYCLE:-0} + 0 ))
    NEW_CYCLE=$((CYCLE + 1))

    # atomic write (lock 안에서만)
    _tmp=$(mktemp "${CYCLE_FILE}.XXXXXX" 2>/dev/null || echo "${CYCLE_FILE}.tmp")
    echo "$NEW_CYCLE" > "$_tmp" 2>/dev/null && mv -f "$_tmp" "$CYCLE_FILE" 2>/dev/null

    exec 9>&-
    rm -f "$CYCLE_LOCK" 2>/dev/null

    if [ "$NEW_CYCLE" -le "$CYCLE_CAP" ]; then
        echo "[$(date +%H:%M:%S)] WORKFLOW_GATE cycle=$NEW_CYCLE/$CYCLE_CAP task_type=$WF_TASK_TYPE missed=[$MISSED]" >> /tmp/claude-hook-trace.log

        # (b) sentinel: end-of-turn-check.sh가 같은 Stop에서 추가 exit 2 안 던지도록
        echo "workflow-gate-blocked cycle=$NEW_CYCLE" > "$BLOCKED_SENTINEL" 2>/dev/null

        cat >&2 <<WFGATE
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
[NCO 워크플로우 단계 누락 — Stop 차단 ${NEW_CYCLE}/${CYCLE_CAP}]

세션: ${NCO_SESSION_ID} | 태스크 유형: ${WF_TASK_TYPE}
누락된 필수 단계: ${MISSED}

즉시 다음 호출을 실행하세요:
WFGATE
        for _s in $MISSED; do
            _cmd=$(nco_command_for_stage "$_s")
            echo "  - $_s → $_cmd" >&2
        done
        cat >&2 <<WFGATE2

규칙: CLAUDE.md "작업 유형별 최소 필수 단계" (task_type=${WF_TASK_TYPE})
우회: 정당한 예외라면 NCO_WORKFLOW_BYPASS=1 환경변수 설정 후 재시도
       (워크플로우 게이트만 우회, tsc/lint 게이트는 유효)
다음 user prompt 시 카운터 자동 리셋됩니다.
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
WFGATE2
        exit 2
    else
        echo "[$(date +%H:%M:%S)] WORKFLOW_GATE CAP_REACHED cycle=$NEW_CYCLE task_type=$WF_TASK_TYPE missed=[$MISSED]" >> /tmp/claude-hook-trace.log
        # cap 도달 후에도 sentinel 유지 — end-of-turn-check.sh가 무한 차단 루프 시작 방지
        echo "workflow-cap-reached cycle=$NEW_CYCLE" > "$BLOCKED_SENTINEL" 2>/dev/null
        cat >&2 <<WFCAP
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
[NCO 워크플로우 cap 도달 — ${CYCLE_CAP}회 재시도 실패]

태스크 유형: ${WF_TASK_TYPE} | 미실행: ${MISSED}
Phase 2 배포 후 자동 백그라운드 큐잉으로 이연됩니다.
지금은 다음 세션에서 위 단계를 수동 보완하세요.
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
WFCAP
        # cap 통과 → 기존 GATE 1/2 계속
    fi
fi
fi   # BYPASS else 종료

# ═══════════════════════════════════════════════════════════════════════
# GATE 1: TypeScript 컴파일 오류 검사 (자기 보고 불신 — 컴파일러만 신뢰)
# ═══════════════════════════════════════════════════════════════════════
TSC_ERRORS=""
if [ -f "$PROJECT_DIR/tsconfig.json" ]; then
    TSC_OUTPUT=$(cd "$PROJECT_DIR" && ./node_modules/.bin/tsc --noEmit 2>&1 || npx tsc --noEmit 2>&1)
    TSC_EXIT=$?
    if [ "$TSC_EXIT" -ne 0 ]; then
        # 오류 수 카운트
        TSC_ERROR_COUNT=$(echo "$TSC_OUTPUT" | grep -c "error TS" 2>/dev/null || echo "?")
        TSC_ERRORS="TypeScript 컴파일 오류 ${TSC_ERROR_COUNT}개 존재"
    fi
fi

# ═══════════════════════════════════════════════════════════════════════
# GATE 2: 서버 측 NCO 호출 검증 (파일 조작 불가 — SQLite 기반)
# 전략: spawned_by_cli="claude-code" 태스크를 최근 30분 기준으로 검색
# (세션 ID는 MCP 서버 PID vs Claude Code PID 불일치로 신뢰 불가)
# ═══════════════════════════════════════════════════════════════════════
NCO_REAL_CALLS=0
NCO_FEATURES_USED=""

# 현재 시간 기준 30분 이내 생성된 claude-code 태스크 검색
TASK_DATA=$(curl -s --connect-timeout 2 --max-time 4 \
    "$NCO_API/api/tasks?limit=50" 2>/dev/null)

if [ -n "$TASK_DATA" ]; then
    # 세션 데이터도 수집 (discussion/consensus/hive)
    _GATE_TASK_FILE="/tmp/nco-gate-tasks-$$.json"
    _GATE_SESS_FILE="/tmp/nco-gate-sessions-$$.json"
    printf '%s' "$TASK_DATA" > "$_GATE_TASK_FILE"
    curl -s --connect-timeout 2 --max-time 4 "$NCO_API/api/realtime-sessions" \
        > "$_GATE_SESS_FILE" 2>/dev/null

    _result=$(python3 -c "
import json, datetime, sys

TASK_MODES = {
    'task': 'task', 'parallel': 'parallel', 'commander': 'commander',
    'conductor': 'commander', 'harness': 'harness', 'broadcast': 'broadcast',
    'agent': 'agent',
}
SESSION_MODES = {
    'discussion': 'discussion', 'consensus': 'consensus', 'hive': 'discussion',
    'parallel': 'parallel',
}

TASK_FILE = sys.argv[1]
SESS_FILE = sys.argv[2]

now = datetime.datetime.utcnow()
cutoff = now - datetime.timedelta(minutes=30)
count = 0
cats = set()

def in_window(ts_str):
    try:
        ts = datetime.datetime.strptime(ts_str[:19], '%Y-%m-%d %H:%M:%S')
        return ts >= cutoff
    except:
        return False

def is_cc_origin(val):
    # claude-code 또는 cli-<PID> (MCP 경유 등록) 둘 다 인정.
    # 2026-05-25 fix: spawned_by_cli가 cli-<PID> 형식으로 들어가는 케이스 대응.
    if not val: return False
    return val == 'claude-code' or str(val).startswith('cli-')

try:
    with open(TASK_FILE) as f:
        d = json.load(f)
    tasks = d.get('tasks', d) if isinstance(d, dict) else d
    for t in tasks:
        if not is_cc_origin(t.get('spawned_by_cli')): continue
        if in_window(t.get('created_at', '')):
            count += 1
            cat = TASK_MODES.get(t.get('mode', ''))
            if cat: cats.add(cat)
except: pass

try:
    with open(SESS_FILE) as f:
        sessions = json.load(f)
    if isinstance(sessions, dict): sessions = sessions.get('sessions', [])
    for s in sessions:
        if not is_cc_origin(s.get('initiator')): continue
        if in_window(s.get('created_at', '')):
            count += 1
            cat = SESSION_MODES.get(s.get('mode', ''))
            if cat: cats.add(cat)
except: pass

cats_str = ','.join(sorted(cats)) if cats else 'none'
print(count, cats_str)
" "$_GATE_TASK_FILE" "$_GATE_SESS_FILE" 2>/dev/null || echo "0 none")

    # 임시 파일 정리
    rm -f "$_GATE_TASK_FILE" "$_GATE_SESS_FILE"

    [ -z "$_result" ] && _result="0 none"
    NCO_REAL_CALLS=$(echo "$_result" | awk '{print $1}')
    NCO_FEATURES_USED=$(echo "$_result" | awk '{print $2}')
    NCO_REAL_CALLS=${NCO_REAL_CALLS:-0}
    NCO_FEATURES_USED=${NCO_FEATURES_USED:-none}
fi

# ── feature breadth 카운트 ──────────────────────────────────────────────
FEATURE_COUNT=0
if [ "$NCO_FEATURES_USED" != "none" ] && [ -n "$NCO_FEATURES_USED" ]; then
    FEATURE_COUNT=$(echo "$NCO_FEATURES_USED" | tr ',' '\n' | grep -c .)
fi

# ═══════════════════════════════════════════════════════════════════════
# GATE 3: 변경 파일이 있는 경우만 품질 게이트 적용
# 세션 기준선 파일을 이용해 이 세션 중 변경된 파일만 계산
# ═══════════════════════════════════════════════════════════════════════
BASELINE_FILE="/tmp/nco-gate-baseline-${NCO_SESSION_ID}.txt"

# 기준선이 없으면 최초 실행 → 현재 상태를 기준선으로 저장하고 변경 없음으로 처리
if [ ! -f "$BASELINE_FILE" ]; then
    git -C "$PROJECT_DIR" diff --name-only 2>/dev/null > "$BASELINE_FILE"
    git -C "$PROJECT_DIR" diff --cached --name-only 2>/dev/null >> "$BASELINE_FILE"
    TOTAL_CHANGES=0
else
    # 현재 변경 파일 목록
    CURRENT_CHANGED=$(git -C "$PROJECT_DIR" diff --name-only 2>/dev/null)
    CURRENT_STAGED=$(git -C "$PROJECT_DIR" diff --cached --name-only 2>/dev/null)
    ALL_CURRENT=$(printf '%s\n%s' "$CURRENT_CHANGED" "$CURRENT_STAGED" | sort -u | grep -v '^$')

    # 기준선에 없는 파일만 집계 (이 세션에서 새로 변경된 파일)
    TOTAL_CHANGES=0
    if [ -n "$ALL_CURRENT" ]; then
        TOTAL_CHANGES=$(echo "$ALL_CURRENT" | while IFS= read -r f; do
            grep -qxF "$f" "$BASELINE_FILE" || echo "$f"
        done | wc -l | tr -d ' ')
    fi
    TOTAL_CHANGES=${TOTAL_CHANGES:-0}
fi

# 변경 없으면 게이트 스킵 (읽기/분석 작업)
if [ "$TOTAL_CHANGES" -eq 0 ] && [ "$NCO_REAL_CALLS" -eq 0 ]; then
    exit 0
fi

# ═══════════════════════════════════════════════════════════════════════
# 판정 — 하나라도 실패하면 차단
# ═══════════════════════════════════════════════════════════════════════
GATE_FAILURES=()

# Gate 1: TypeScript 오류
if [ -n "$TSC_ERRORS" ]; then
    GATE_FAILURES+=("❌ GATE 1 (컴파일): $TSC_ERRORS")
fi

# Gate 2a: NCO 최소 호출 수 (변경이 있을 때)
if [ "$TOTAL_CHANGES" -gt 0 ] && [ "$NCO_REAL_CALLS" -eq 0 ]; then
    GATE_FAILURES+=("❌ GATE 2a (NCO 미사용): 파일 ${TOTAL_CHANGES}개 변경했으나 NCO 에이전트 사용 기록 없음")
fi

# Gate 2b: feature breadth (변경이 많을 때 다양한 NCO 기능 사용 필요)
if [ "$TOTAL_CHANGES" -ge 5 ] && [ "$FEATURE_COUNT" -lt 2 ]; then
    GATE_FAILURES+=("❌ GATE 2b (기능 다양성): 대형 변경(${TOTAL_CHANGES}파일)은 최소 2개 NCO 기능 필요 (현재: ${FEATURE_COUNT}개 — ${NCO_FEATURES_USED})")
fi

# ── 통과 ────────────────────────────────────────────────────────────────
if [ ${#GATE_FAILURES[@]} -eq 0 ]; then
    # 품질 통과 로그
    echo "[$(date +%H:%M:%S)] NCO QUALITY GATE PASSED: calls=${NCO_REAL_CALLS}, features=${NCO_FEATURES_USED}, changes=${TOTAL_CHANGES}" >> /tmp/claude-hook-trace.log
    exit 0
fi

# ── 차단 ────────────────────────────────────────────────────────────────
FAILURE_MSG=$(printf '%s\n' "${GATE_FAILURES[@]}")

cat >&2 <<GATE_FAIL
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
[NCO 품질 게이트 — 완료 차단]

세션: ${NCO_SESSION_ID}
변경 파일: ${TOTAL_CHANGES}개
NCO 실제 호출 (서버 검증): ${NCO_REAL_CALLS}회
사용된 NCO 기능: ${NCO_FEATURES_USED}

실패한 게이트:
${FAILURE_MSG}

━━━ 해결 방법 ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
GATE 1 실패 → tsc 오류를 수정하거나 NCO 에이전트에 위임:
  curl -s -X POST localhost:6200/api/task -H 'Content-Type: application/json' \
    -d '{"ai":"codex","prompt":"Fix TypeScript errors in this project"}'

GATE 2 실패 → NCO 에이전트 사용 후 재완료:
  nco_task / nco_parallel / nco_commander / nco_discussion / nco_harness

진실만 보고: 이 결과는 서버 DB(SQLite)와 tsc 컴파일러의 실제 검증입니다.
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
GATE_FAIL

exit 2
