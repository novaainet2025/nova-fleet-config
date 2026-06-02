#!/bin/bash
# L3: PreToolUse hook — 신규 기능 첫 코드 편집 차단 (안전망)
# task_type=new_feature + 코드 파일(.js/.ts/.py/.sh) + 같은 prompt 내
# mcp__nco-commands__nco-task 호출 0회면 exit 2로 차단.
# nco-task 호출은 카운터(/tmp/nco-task-count-$SID)를 +1.
# 우회: NCO_DIRECT_BYPASS=1.

set -u

# fail-secure: python3 미설치 시 게이트가 silent 우회되지 않도록 가시화.
# 운영 환경상 python3 항상 존재 가정하지만, 누락 시 stderr 경고 + 통과.
if ! command -v python3 >/dev/null 2>&1; then
  echo "[NCO-GATE L3 WARN] python3 missing — gate fails open (관리자 확인 필요)" >&2
  exit 0
fi

SID="${NCO_SESSION_ID:-$$}"
COUNTER_FILE="/tmp/nco-task-count-$SID"
TASK_TYPE_FILE="/tmp/nco-task-type-$SID"

INPUT=$(cat 2>/dev/null)
TOOL_NAME=$(echo "$INPUT" | python3 -c "
import sys, json
try: print(json.load(sys.stdin).get('tool_name',''))
except: pass
" 2>/dev/null)

# nco-task 호출 → 카운터 +1 (차단 안 함)
# R1-C (2026-05-27): flock으로 read-modify-write atomic 보강 (race 방지).
if [ "$TOOL_NAME" = "mcp__nco-commands__nco-task" ] \
   || [ "$TOOL_NAME" = "mcp__nco-commands__nco-team" ] \
   || [ "$TOOL_NAME" = "mcp__nco-commands__nco-parallel" ] \
   || [ "$TOOL_NAME" = "mcp__nco-commands__nco-flow" ] \
   || [ "$TOOL_NAME" = "mcp__nco-commands__nco-commander" ] \
   || [ "$TOOL_NAME" = "mcp__nco-commands__nco-conductor" ]; then
  LOCK_FD_FILE="$COUNTER_FILE.lock"
  : > "$LOCK_FD_FILE" 2>/dev/null  # ensure lock file exists
  if command -v flock >/dev/null 2>&1; then
    # R2-A (2026-05-27): flock 타임아웃 시에도 카운터 +1 fallback —
    # cursor-agent 지적: || exit 0 이면 lock 못 잡았을 때 카운터 미갱신
    # → 다음 Edit에서 허위 차단. RMW race 위험 < 허위 차단 위험.
    # subshell exit 1 = lock fail. 외부에서 캐치 후 unlocked RMW.
    if ! (
      flock -x -w 2 9 || exit 1
      _C=$(cat "$COUNTER_FILE" 2>/dev/null || echo 0)
      echo $((_C + 1)) > "$COUNTER_FILE"
    ) 9>"$LOCK_FD_FILE"; then
      echo "[NCO-GATE WARN] flock timeout — counter incremented without lock" >&2
      _C=$(cat "$COUNTER_FILE" 2>/dev/null || echo 0)
      echo $((_C + 1)) > "$COUNTER_FILE" 2>/dev/null
    fi
  else
    # flock 미설치 fallback (race 가능, 경고만)
    echo "[NCO-GATE WARN] flock missing — counter race possible" >&2
    _C=$(cat "$COUNTER_FILE" 2>/dev/null || echo 0)
    echo $((_C + 1)) > "$COUNTER_FILE" 2>/dev/null
  fi
  exit 0
fi

# Edit/Write/MultiEdit 아닌 도구는 통과
case "$TOOL_NAME" in
  Edit|Write|MultiEdit|NotebookEdit) ;;
  *) exit 0 ;;
esac

# 우회
[ -n "${NCO_DIRECT_BYPASS:-}" ] && exit 0

# task_type 캐시 검사
TASK_TYPE="unknown"
[ -f "$TASK_TYPE_FILE" ] && TASK_TYPE=$(cat "$TASK_TYPE_FILE" 2>/dev/null | tr -d '[:space:]')
[ "$TASK_TYPE" != "new_feature" ] && exit 0

# file_path 확장자 검사 — 코드 파일만 차단 대상
FILE=$(echo "$INPUT" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    ti = d.get('tool_input', {})
    print(ti.get('file_path') or ti.get('notebook_path') or '')
except: pass
" 2>/dev/null)

case "$FILE" in
  *.js|*.ts|*.tsx|*.jsx|*.py|*.sh|*.mjs|*.cjs) ;;
  *) exit 0 ;;
esac

# 카운터 검사
COUNT=$(cat "$COUNTER_FILE" 2>/dev/null || echo 0)
if [ "$COUNT" -eq 0 ]; then
  cat >&2 <<EOF

[NCO-GATE L3] 신규 기능의 첫 코드 편집은 NCO 위임 필수입니다.
  - 파일: $FILE
  - 권장: mcp__nco-commands__nco-task ai=codex '...'
          또는 mcp__nco-commands__nco-flow / nco-team
  - 우회: 환경변수 NCO_DIRECT_BYPASS=1 설정 후 재호출
EOF
  exit 2
fi

exit 0
