#!/bin/bash
# NCO 재귀보호: NCO가 스폰한 서브프로세스 claude에서는 훅 무동작 (2026-07-08, 76s 훅스택+BOOTSTRAP 오염 T1)
[ "${NCO_HOOK_DISABLED:-0}" = "1" ] && exit 0
# [사용자 요청] 반복 Stop 훅 루프/스팸 영구 제거 (fleet 원본). 복구: 아래 exit 0 삭제.
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
    if echo "$_CM" | grep -qE '^(claude|node)$'; then
      NCO_SESSION_ID="$_CK"
      break
    fi
  done
  NCO_SESSION_ID="${NCO_SESSION_ID:-${PPID:-$$}}"
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
echo "[$(date +%H:%M:%S)] HOOK_START end-of-turn-check.sh" >> /tmp/claude-hook-trace.log
trap 'echo "[$(date +%H:%M:%S)] HOOK_END   end-of-turn-check.sh exit=$?" >> /tmp/claude-hook-trace.log' EXIT
# ═══════════════════════════════════════════════════════════
# NCO Stop Hook v3.0 — Self-Eval + Gap Analysis + Action Menu
# ═══════════════════════════════════════════════════════════
#
# 실행 시점: Claude Code CLI가 응답을 멈출 때 (매 턴 종료)
#
# v3 기능:
#   1. 세션 제목 표시 (현재 브랜치 + 최근 커밋 요약)
#   2. 작업 자가평가 (변경 파일, 에러, 품질 등급)
#   3. Gap 분석 (계획 vs 실제 완료율)
#   4. Gap < 95% → exit 2 (자동 재수정, stderr로 에러 주입)
#   5. Gap >= 95% → exit 0 + 다음 작업 액션 메뉴
#      /nco-next       — 다음 순차 작업
#      /nco-next-parallel — 독립 태스크 병렬 실행
#      /nco-task    — NCO 추천 작업 위임
#      /nco-gap        — 수동 gap 재분석
#
# exit 0 = Claude 정상 종료
# exit 2 = Claude 재실행 (stderr → 프롬프트 주입)
# ═══════════════════════════════════════════════════════════

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-/Users/nova-ai/project/nco}"
cd "$PROJECT_DIR" 2>/dev/null || exit 0

# ═══ Resolve NCO_SESSION_ID: env var > process tree walk ═══
if [ -z "$NCO_SESSION_ID" ]; then
  _CK=$$
  for _i in 1 2 3 4 5; do
    _CK=$(ps -o ppid= -p "$_CK" 2>/dev/null | tr -d ' ')
    [ -z "$_CK" ] && break
    _CM=$(ps -o comm= -p "$_CK" 2>/dev/null)
    if echo "$_CM" | grep -qE '^(claude|node)$'; then
      NCO_SESSION_ID="$_CK"
      break
    fi
  done
  NCO_SESSION_ID="${NCO_SESSION_ID:-${PPID:-$$}}"
fi

# ═══ Resolve NCO_NAME: env var > PID-file reservation ═══
if [ -z "$NCO_NAME" ]; then
  for _pf in /tmp/nco-names/claude-*.pid; do
    [ -f "$_pf" ] || continue
    _rp=$(cat "$_pf" 2>/dev/null | tr -d '[:space:]')
    if [ "$_rp" = "$NCO_SESSION_ID" ]; then
      NCO_NAME=$(basename "$_pf" .pid)
      break
    fi
  done
fi
MY_NAME="${NCO_NAME:-cli}"

# ═══ 유틸 ═══
to_int() { local v; v=$(echo "${1:-0}" | tr -dc '0-9'); echo "${v:-0}"; }

# ═══ 상태 파일 경로 ═══
NCO_SESSION_DIR="/tmp/nco-sessions"
NCO_STATE="$NCO_SESSION_DIR/$NCO_SESSION_ID.json"
NCO_HISTORY="$NCO_SESSION_DIR/$NCO_SESSION_ID-history.log"
mkdir -p "$NCO_SESSION_DIR" 2>/dev/null

# ═══════════════════════════════════════════════════════════
# STEP 1: 세션 컨텍스트 수집
# ═══════════════════════════════════════════════════════════

BRANCH=$(git branch --show-current 2>/dev/null || echo "unknown")
LAST_COMMIT=$(git log -1 --pretty=format:"%s" 2>/dev/null | head -c 60 || echo "no commits")
SESSION_TITLE="${BRANCH} — ${LAST_COMMIT}"

# 턴 카운터 (히스토리 파일 라인 수)
TURN_COUNT=0
if [ -f "$NCO_HISTORY" ]; then
    TURN_COUNT=$(wc -l < "$NCO_HISTORY" | tr -d '[:space:]')
fi
TURN_COUNT=$(to_int "$TURN_COUNT")
TURN_COUNT=$((TURN_COUNT + 1))

# ═══════════════════════════════════════════════════════════
# STEP 2: 작업 결과 수집
# ═══════════════════════════════════════════════════════════

CHANGED_FILES_LIST=$(git diff --name-only 2>/dev/null)
STAGED_FILES_LIST=$(git diff --cached --name-only 2>/dev/null)
ALL_CHANGED=$(printf "%s\n%s" "$CHANGED_FILES_LIST" "$STAGED_FILES_LIST" | sort -u | grep -v '^$')

CHANGED_COUNT=$(echo "$ALL_CHANGED" | grep -c '.' 2>/dev/null || echo 0)
CHANGED_COUNT=$(to_int "$CHANGED_COUNT")

# 변경 파일 요약 (확장자별 카운트)
FILE_SUMMARY=""
if [ "$CHANGED_COUNT" -gt 0 ]; then
    FILE_SUMMARY=$(echo "$ALL_CHANGED" | sed 's/.*\.//' | sort | uniq -c | sort -rn | head -5 | awk '{printf "%s(%d) ", $2, $1}')
fi

# 추가/삭제 라인 수
DIFF_STAT=$(git diff --stat 2>/dev/null | tail -1)
ADDITIONS=$(echo "$DIFF_STAT" | grep -oP '\d+(?= insertion)' || echo "0")
DELETIONS=$(echo "$DIFF_STAT" | grep -oP '\d+(?= deletion)' || echo "0")
ADDITIONS=$(to_int "$ADDITIONS")
DELETIONS=$(to_int "$DELETIONS")

# TypeScript 에러 — lock으로 중복 실행 방지
TSC_ERRORS=0
TSC_ERROR_LINES=""
TSC_LOCK="/tmp/nco-tsc.lock"
TSC_CACHE="/tmp/nco-tsc-cache.txt"
_tsc_run=0

if command -v npx &>/dev/null && [ -f "tsconfig.json" ]; then
    # 이미 tsc가 돌고 있으면 캐시 결과 사용 (누적 방지)
    if [ -f "$TSC_LOCK" ]; then
        _LOCK_PID=$(cat "$TSC_LOCK" 2>/dev/null)
        if kill -0 "$_LOCK_PID" 2>/dev/null; then
            # 살아있는 tsc → 캐시된 결과 사용
            if [ -f "$TSC_CACHE" ]; then
                TSC_OUTPUT=$(cat "$TSC_CACHE")
                TSC_ERRORS=$(echo "$TSC_OUTPUT" | grep -c "error TS" 2>/dev/null || echo 0)
                TSC_ERRORS=$(to_int "$TSC_ERRORS")
            fi
        else
            # 죽은 lock → 삭제 후 실행
            rm -f "$TSC_LOCK"
            _tsc_run=1
        fi
    else
        _tsc_run=1
    fi

    if [ "$_tsc_run" = "1" ]; then
        echo $$ > "$TSC_LOCK"
        TSC_OUTPUT=$(npx tsc --noEmit 2>&1)
        echo "$TSC_OUTPUT" > "$TSC_CACHE"
        rm -f "$TSC_LOCK"
        TSC_ERRORS=$(echo "$TSC_OUTPUT" | grep -c "error TS" | tr -d '[:space:]' || true)
        TSC_ERRORS=$(to_int "$TSC_ERRORS")
        if [ "$TSC_ERRORS" -gt 0 ]; then
            TSC_ERROR_LINES=$(echo "$TSC_OUTPUT" | grep "error TS" | head -10)
        fi
    fi
fi

# ESLint 에러 (변경 파일만)
LINT_ERRORS=0
LINT_ERROR_LINES=""
LINT_TARGET_FILES=""
if command -v npx &>/dev/null; then
    if [ -f ".eslintrc.js" ] || [ -f ".eslintrc.json" ] || [ -f "eslint.config.js" ] || [ -f "eslint.config.mjs" ]; then
        LINT_TARGET_FILES=$(echo "$ALL_CHANGED" | grep -E '\.(ts|tsx|js|jsx)$' | head -20)
        if [ -n "$LINT_TARGET_FILES" ]; then
            LINT_OUTPUT=$(echo "$LINT_TARGET_FILES" | xargs npx eslint --no-warn 2>/dev/null)
            LINT_ERRORS=$(echo "$LINT_OUTPUT" | grep -c "error" | tr -d '[:space:]' || true)
            LINT_ERRORS=$(to_int "$LINT_ERRORS")
            if [ "$LINT_ERRORS" -gt 0 ]; then
                LINT_ERROR_LINES=$(echo "$LINT_OUTPUT" | grep "error" | head -10)
            fi
        fi
    fi
fi

# ═══════════════════════════════════════════════════════════
# STEP 3: 태스크 상태 수집
# ═══════════════════════════════════════════════════════════

TOTAL_TASKS=0
DONE_TASKS=0
PENDING_TASKS=""
PENDING_TASK_LIST=""

parse_tasks_from_file() {
    local file="$1"
    [ ! -f "$file" ] && return
    while IFS= read -r line; do
        if echo "$line" | grep -qE '^\s*-\s*\[[ xX]\]'; then
            TOTAL_TASKS=$((TOTAL_TASKS + 1))
            if echo "$line" | grep -qE '^\s*-\s*\[[xX]\]'; then
                DONE_TASKS=$((DONE_TASKS + 1))
            else
                local text
                text=$(echo "$line" | sed 's/^\s*-\s*\[ \]\s*//')
                PENDING_TASKS="${PENDING_TASKS}  - ${text}\n"
                PENDING_TASK_LIST="${PENDING_TASK_LIST}${text}|"
            fi
        fi
    done < "$file"
}

for plan_file in docs/plans/*.md .llm/todo.md; do
    parse_tasks_from_file "$plan_file"
done

TOTAL_TASKS=$(to_int "$TOTAL_TASKS")
DONE_TASKS=$(to_int "$DONE_TASKS")

# ═══════════════════════════════════════════════════════════
# STEP 4: 자가평가 (품질 등급 산정)
# ═══════════════════════════════════════════════════════════

# Gap Rate 계산
if [ "$TOTAL_TASKS" -gt 0 ]; then
    GAP_RATE=$(( (DONE_TASKS * 100) / TOTAL_TASKS ))
else
    if [ "$CHANGED_COUNT" -gt 0 ] && [ "$TSC_ERRORS" -eq 0 ] && [ "$LINT_ERRORS" -eq 0 ]; then
        GAP_RATE=100
    elif [ "$CHANGED_COUNT" -eq 0 ]; then
        GAP_RATE=100
    else
        GAP_RATE=70
    fi
fi

# 에러 감점
if [ "$TSC_ERRORS" -gt 0 ]; then
    PENALTY=$(( TSC_ERRORS * 5 ))
    [ "$PENALTY" -gt 30 ] && PENALTY=30
    GAP_RATE=$(( GAP_RATE - PENALTY ))
    [ "$GAP_RATE" -lt 0 ] && GAP_RATE=0
fi
if [ "$LINT_ERRORS" -gt 0 ]; then
    PENALTY=$(( LINT_ERRORS * 2 ))
    [ "$PENALTY" -gt 15 ] && PENALTY=15
    GAP_RATE=$(( GAP_RATE - PENALTY ))
    [ "$GAP_RATE" -lt 0 ] && GAP_RATE=0
fi

# 품질 등급
if [ "$GAP_RATE" -ge 95 ]; then
    GRADE="A"
    GRADE_ICON="★"
    GRADE_DESC="완료"
elif [ "$GAP_RATE" -ge 80 ]; then
    GRADE="B"
    GRADE_ICON="●"
    GRADE_DESC="양호 — 마무리 필요"
elif [ "$GAP_RATE" -ge 60 ]; then
    GRADE="C"
    GRADE_ICON="▲"
    GRADE_DESC="미흡 — 에러/미완료 다수"
else
    GRADE="D"
    GRADE_ICON="✗"
    GRADE_DESC="위험 — 즉시 수정 필요"
fi

# 자가평가 요약 (한 줄)
EVAL_SUMMARY=""
if [ "$TSC_ERRORS" -gt 0 ] && [ "$LINT_ERRORS" -gt 0 ]; then
    EVAL_SUMMARY="tsc ${TSC_ERRORS}err + lint ${LINT_ERRORS}err → 수정 필요"
elif [ "$TSC_ERRORS" -gt 0 ]; then
    EVAL_SUMMARY="tsc ${TSC_ERRORS}err → 타입 에러 수정 필요"
elif [ "$LINT_ERRORS" -gt 0 ]; then
    EVAL_SUMMARY="lint ${LINT_ERRORS}err → 코드 스타일 수정 필요"
elif [ "$CHANGED_COUNT" -eq 0 ]; then
    EVAL_SUMMARY="변경 없음"
else
    EVAL_SUMMARY="깨끗함 — 에러 없음"
fi

# ═══════════════════════════════════════════════════════════
# STEP 5: 히스토리 기록
# ═══════════════════════════════════════════════════════════

echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) turn=${TURN_COUNT} gap=${GAP_RATE}% grade=${GRADE} files=${CHANGED_COUNT} +${ADDITIONS}/-${DELETIONS} tsc=${TSC_ERRORS} lint=${LINT_ERRORS}" >> "$NCO_HISTORY"

cat > "$NCO_STATE" <<STATEEOF
{
  "session_id": "$NCO_SESSION_ID",
  "session_title": "$(echo "$SESSION_TITLE" | sed 's/"/\\"/g')",
  "turn": $TURN_COUNT,
  "changed_files": $CHANGED_COUNT,
  "additions": $ADDITIONS,
  "deletions": $DELETIONS,
  "tsc_errors": $TSC_ERRORS,
  "lint_errors": $LINT_ERRORS,
  "total_tasks": $TOTAL_TASKS,
  "done_tasks": $DONE_TASKS,
  "gap_rate": $GAP_RATE,
  "grade": "$GRADE",
  "eval": "$(echo "$EVAL_SUMMARY" | sed 's/"/\\"/g')",
  "last_check": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
STATEEOF

# ═══════════════════════════════════════════════════════════
# STEP 6: 판정 — 통과 or 재실행
# ═══════════════════════════════════════════════════════════

THRESHOLD=95

# ── 공통 헤더 ──
HEADER=$(cat <<HDREOF
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
[NCO:${MY_NAME}] ${SESSION_TITLE}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
턴 #${TURN_COUNT} | Gap ${GAP_RATE}% | ${GRADE_ICON} ${GRADE} — ${GRADE_DESC}
HDREOF
)

# ── 공통 자가평가 블록 ──
EVAL_BLOCK=$(cat <<EVALEOF

[자가평가]
  파일: ${CHANGED_COUNT}개 변경 (+${ADDITIONS}/-${DELETIONS}) ${FILE_SUMMARY}
  tsc:  ${TSC_ERRORS}err | lint: ${LINT_ERRORS}err
  태스크: ${DONE_TASKS}/${TOTAL_TASKS} 완료
  평가: ${EVAL_SUMMARY}
EVALEOF
)

if [ "$GAP_RATE" -ge "$THRESHOLD" ]; then
    # ═══ PASS ═══

    # 다음 작업 후보 (최대 5개)
    NEXT_TASKS=""
    for plan_file in docs/plans/*.md .llm/todo.md; do
        if [ -f "$plan_file" ]; then
            NEXT=$(grep -m 5 '^\s*-\s*\[ \]' "$plan_file" 2>/dev/null | sed 's/^\s*-\s*\[ \]\s*//' | head -5)
            if [ -n "$NEXT" ]; then
                NEXT_TASKS="${NEXT_TASKS}${NEXT}\n"
            fi
        fi
    done

    # NCO 추천 작업 (API 가능 시)
    NCO_RECOMMEND=""
    if (echo > /dev/tcp/localhost/6200) 2>/dev/null; then
        NCO_RECOMMEND=$(curl -s -m 2 http://localhost:6200/api/tasks/recommend 2>/dev/null | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    if d.get('task'):
        print(d['task'].get('description','')[:80])
except: pass
" 2>/dev/null)
    fi

    cat >&2 <<PASSEOF
${HEADER}
${EVAL_BLOCK}

[다음 작업]
PASSEOF

    if [ -n "$NEXT_TASKS" ]; then
        echo -e "$NEXT_TASKS" | head -5 | nl -ba >&2
    else
        echo "  (Plan 파일에 미완료 태스크 없음)" >&2
    fi

    if [ -n "$NCO_RECOMMEND" ]; then
        echo "" >&2
        echo "  NCO 추천: ${NCO_RECOMMEND}" >&2
    fi

    # ─── Check for mesh messages (all types) ───
    MESH_MSGS=""
    MESH_HB_RESULT=$(curl -s --connect-timeout 1 --max-time 2 -X POST http://localhost:6200/api/mesh/heartbeat \
      -H "Content-Type: application/json" \
      -d "{\"sessionId\":\"$NCO_SESSION_ID\",\"agentId\":\"$MY_NAME\",\"pid\":$NCO_SESSION_ID,\"status\":\"idle\"}" 2>/dev/null)

    if [ -n "$MESH_HB_RESULT" ]; then
        MESH_MSGS=$(echo "$MESH_HB_RESULT" | python3 -c "
import sys,json
d=json.load(sys.stdin)
msgs=d.get('messages',[])
if msgs:
    for m in msgs:
        t=m.get('type','info').upper()
        f=m.get('fromAgent','?')
        c=m.get('content','')
        print(f'  [{t}] {f}: {c}')
" 2>/dev/null)
    fi

    # ─── Advisor 권장 여부 판단 ───
    ADVISOR_SUGGEST=""
    # 복잡도 신호: 변경 파일 5+, 추가 라인 100+, tsc 오류 직전 수정 있음
    if [ "$CHANGED_COUNT" -ge 5 ] || [ "$ADDITIONS" -ge 100 ]; then
        ADVISOR_SUGGEST="large-change"
    fi

    cat >&2 <<MENUEOF

[액션]
  /nco-next          — 다음 순차 작업
  /nco-next-parallel  — 독립 태스크 병렬 실행
  /nco-task <설명>   — NCO에 작업 위임
  /nco-mesh          — CLI Mesh 상태
  /nco-gap           — gap 재분석
  /advisor           — Opus 심층 리뷰 (설계·아키텍처·복잡 디버깅)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
MENUEOF

    if [ -n "$ADVISOR_SUGGEST" ]; then
        cat >&2 <<ADVEOF
[ADVISOR 권장] 변경 파일 ${CHANGED_COUNT}개 / +${ADDITIONS}줄 — 복잡도 높음
  → /advisor 로 Opus 심층 리뷰 후 다음 작업 진행 권장
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
ADVEOF
    fi

    # Auto-reply to mesh messages (with loop prevention: max 5 consecutive)
    if [ -n "$MESH_MSGS" ]; then
        MESH_COUNTER_FILE="/tmp/nco-mesh-auto-${NCO_SESSION_ID}.count"
        MESH_COUNT=$(cat "$MESH_COUNTER_FILE" 2>/dev/null || echo "0")
        MESH_COUNT=$((MESH_COUNT + 1))

        if [ "$MESH_COUNT" -le 5 ]; then
            echo "$MESH_COUNT" > "$MESH_COUNTER_FILE"
            echo "" >&2
            echo "[MESH 메시지 수신 — 자동 응답 ${MESH_COUNT}/5]" >&2
            echo "$MESH_MSGS" >&2
            echo "" >&2
            echo "위 메시지에 /nco-mesh send 로 답장하세요. 대화가 끝나면 '대화 종료'라고 말하세요." >&2
            exit 0  # Auto-respond disabled (was exit 2)
        else
            echo "" >&2
            echo "[MESH 메시지 수신 — 자동 응답 한도 초과 (5/5)]" >&2
            echo "$MESH_MSGS" >&2
            echo "" >&2
            echo "수동으로 /nco-mesh send 로 응답하거나, 한도 리셋: rm $MESH_COUNTER_FILE" >&2
            rm -f "$MESH_COUNTER_FILE"
        fi
    else
        # No messages — reset counter (conversation paused)
        rm -f "/tmp/nco-mesh-auto-${NCO_SESSION_ID}.count" 2>/dev/null
    fi

    exit 0

else
    # ═══ FAIL: 자동 재수정 ═══

    cat >&2 <<FAILEOF
${HEADER}
${EVAL_BLOCK}

[자동 수정 모드] Gap ${GAP_RATE}% < ${THRESHOLD}% — 계속 진행합니다.
FAILEOF

    # 미완료 태스크
    if [ -n "$PENDING_TASKS" ]; then
        echo "" >&2
        echo "미완료 항목:" >&2
        echo -e "$PENDING_TASKS" >&2
    fi

    # tsc 에러 상세
    if [ "$TSC_ERRORS" -gt 0 ]; then
        echo "" >&2
        echo "TypeScript 에러 (수정 필요):" >&2
        echo "$TSC_ERROR_LINES" >&2
    fi

    # lint 에러 상세
    if [ "$LINT_ERRORS" -gt 0 ]; then
        echo "" >&2
        echo "ESLint 에러 (수정 필요):" >&2
        echo "$LINT_ERROR_LINES" >&2
    fi

    echo "" >&2
    echo "위 항목을 수정하여 gap ${THRESHOLD}% 이상을 달성하세요." >&2

    # ─── Grade C/D: advisor 강력 권장 ───
    if [ "$GRADE" = "C" ] || [ "$GRADE" = "D" ]; then
        cat >&2 <<ADVFAILEOF

[ADVISOR 강력 권장] Grade ${GRADE} — ${GRADE_DESC}
  → /advisor 를 먼저 호출하여 Opus가 문제를 심층 분석하게 하세요.
  → 원인: 복잡한 버그 / 설계 오류 / 타입 에러 다수 시 Opus가 더 정확합니다.
ADVFAILEOF
    fi

    # ─── Check for mesh messages even in fail path ───
    MESH_HB_FAIL=$(curl -s --connect-timeout 1 --max-time 2 -X POST http://localhost:6200/api/mesh/heartbeat \
      -H "Content-Type: application/json" \
      -d "{\"sessionId\":\"$NCO_SESSION_ID\",\"agentId\":\"$MY_NAME\",\"pid\":$NCO_SESSION_ID,\"status\":\"coding\"}" 2>/dev/null)

    if [ -n "$MESH_HB_FAIL" ]; then
        MESH_MSGS_FAIL=$(echo "$MESH_HB_FAIL" | python3 -c "
import sys,json
d=json.load(sys.stdin)
msgs=d.get('messages',[])
if msgs:
    for m in msgs:
        t=m.get('type','info').upper()
        f=m.get('fromAgent','?')
        c=m.get('content','')
        print(f'  [{t}] {f}: {c}')
" 2>/dev/null)

        if [ -n "$MESH_MSGS_FAIL" ]; then
            echo "" >&2
            echo "[MESH 메시지 수신]" >&2
            echo "$MESH_MSGS_FAIL" >&2
        fi
    fi

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2

    # Gap < THRESHOLD% → exit 2 로 자동 재실행 (헤더 L14-15 의도 부활)
    # (b) 회귀 방지: nco-stop-quality-gate.sh가 이미 exit 2로 차단했다면
    #     중복 차단 + stderr 경합을 피하기 위해 통과. 다음 user prompt 시 sentinel은 task-classifier가 정리.
    _BLOCKED_SENT="/tmp/nco-stop-blocked-${NCO_SESSION_ID}"
    if [ -f "$_BLOCKED_SENT" ]; then
        echo "[end-of-turn-check] workflow-gate가 이미 차단함 ($_BLOCKED_SENT) — 중복 차단 회피, exit 0" >&2
        exit 0
    fi
    exit 2
fi
