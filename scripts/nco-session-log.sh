#!/usr/bin/env bash
# NCO 세션 단계 로거
#
# nco-analyze / nco-opus / nco-solve 가 각 단계 경계마다 호출한다(총 56곳).
# 2026-07-29 이전에는 이 스크립트가 어느 머신에도 존재하지 않아
# 세 커맨드 모두 첫 줄에서 "No such file or directory" 로 실패했다.
#
# 사용법:
#   nco-session-log.sh <command> <phase> <name> <status> [detail]
# 예:
#   nco-session-log.sh "nco-analyze" "2" "병렬분석" "start" "선정 AI에게 동시 분석 요청"
#
# 출력: $NCO_SESSION_LOG_DIR (기본 ~/.claude/nco-session-logs) 아래
#       <command>-<YYYYMMDD>.log 에 TSV 한 줄 추가 + stderr 로 사람이 읽을 한 줄.
# 로그 실패가 호출자를 죽이면 안 되므로 어떤 경우에도 exit 0 이다.

set -u

CMD="${1:-unknown}"
PHASE="${2:-}"
NAME="${3:-}"
STATUS="${4:-}"
DETAIL="${5:-}"

LOG_DIR="${NCO_SESSION_LOG_DIR:-$HOME/.claude/nco-session-logs}"
mkdir -p "$LOG_DIR" 2>/dev/null || exit 0

TS="$(date '+%Y-%m-%dT%H:%M:%S%z')"
DAY="$(date '+%Y%m%d')"
LOG_FILE="$LOG_DIR/${CMD}-${DAY}.log"

# 탭/개행이 섞여도 TSV 가 깨지지 않도록 평탄화
flatten() { printf '%s' "${1:-}" | tr '\t\n\r' '   '; }

printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
  "$TS" \
  "$(flatten "$CMD")" \
  "$(flatten "$PHASE")" \
  "$(flatten "$NAME")" \
  "$(flatten "$STATUS")" \
  "$(flatten "$DETAIL")" \
  >> "$LOG_FILE" 2>/dev/null || exit 0

case "$STATUS" in
  start) MARK="▶" ;;
  done)  MARK="✓" ;;
  error|fail) MARK="✗" ;;
  *)     MARK="·" ;;
esac

printf '  %s [%s P%s] %s%s\n' \
  "$MARK" "$CMD" "$PHASE" "$NAME" \
  "$([ -n "$DETAIL" ] && printf ' — %s' "$(flatten "$DETAIL")")" >&2

exit 0
