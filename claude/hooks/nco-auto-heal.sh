#!/bin/bash
# NCO 재귀보호: NCO가 스폰한 서브프로세스 claude에서는 훅 무동작
[ "${NCO_HOOK_DISABLED:-0}" = "1" ] && exit 0
#
# nco-auto-heal.sh — 에러 발생 시 즉시 트리거되는 자율 진단·수정 워크플로우 (빠른 감지부)
# (2026-07-09 claude-1, 사용자 명시적 승인 하 "진단부터 수정까지 전적 자율" 범위로 구현)
#
# PostToolUse(Bash) 훅. 이 파일은 exit code/패턴만 빠르게 확인하고(<1s),
# 실제 무거운 처리(진단→codex위임→빌드검증→되돌림/메모리등록)는
# nco-auto-heal-worker.sh 를 백그라운드(nohup+disown)로 넘겨 인터랙티브 턴을 막지 않는다.
#
# 안전장치(worker.sh에도 동일 적용):
#   - 이 스크립트는 읽기전용 판정만 함(exit code, stderr 문자열 매칭). 아무 것도 실행/수정하지 않음.
#   - 시간당 최대 3회, 동일 시그니처 24시간 dedup — worker.sh 트리거 전에 여기서 먼저 걸러짐.
#   - 모르는 에러 패턴은 절대 건드리지 않고 조용히 통과(화이트리스트 방식).

set -u

STATE_DIR="${HOME}/.claude/nco-perf/auto-heal-state"
DEDUP_DIR="${STATE_DIR}/dedup"
RATE_FILE="${STATE_DIR}/rate.log"
AUDIT_LOG="${HOME}/.claude/nco-perf/auto-heal-audit.log"
WORKER="${HOME}/.claude/hooks/nco-auto-heal-worker.sh"
RATE_LIMIT_MAX=3
RATE_LIMIT_WINDOW_SEC=3600

mkdir -p "${STATE_DIR}" "${DEDUP_DIR}" "$(dirname "${AUDIT_LOG}")" 2>/dev/null
log() { printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$1" >> "${AUDIT_LOG}"; }

INPUT=$(cat 2>/dev/null)
[ -z "$INPUT" ] && exit 0

TOOL_NAME=$(printf '%s' "$INPUT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('tool_name',''))" 2>/dev/null)
[ "$TOOL_NAME" != "Bash" ] && exit 0

EXIT_CODE=$(printf '%s' "$INPUT" | python3 -c "
import json,sys
d=json.load(sys.stdin)
tr=d.get('tool_response',{}) or {}
print(tr.get('exitCode', tr.get('exit_code', tr.get('returnCode', 0))) or 0)
" 2>/dev/null)
[ "${EXIT_CODE:-0}" = "0" ] && exit 0

STDERR_TEXT=$(printf '%s' "$INPUT" | python3 -c "
import json,sys
d=json.load(sys.stdin)
tr=d.get('tool_response',{}) or {}
txt = (tr.get('stderr') or '') + '\n' + (tr.get('error') or '') + '\n' + (str(tr.get('output') or '')[:2000])
print(txt[:3000])
" 2>/dev/null)
CMD=$(printf '%s' "$INPUT" | python3 -c "
import json,sys
d=json.load(sys.stdin)
ti=d.get('tool_input',{}) or {}
print(ti.get('command','')[:500])
" 2>/dev/null)
[ -z "$STDERR_TEXT" ] && exit 0

# ── 알려진 힐링 대상 에러 시그니처만 매칭 (화이트리스트) ──────────────
PATTERN=""
case "$STDERR_TEXT" in
  *"Command not in allowlist"*) PATTERN="sandbox-allowlist" ;;
  *"not writable in this session"*) PATTERN="codex-sandbox-cwd" ;;
  *"unknown command"*"Conversation History"*) PATTERN="cli-arg-history-leak" ;;
  *"Cannot find module"*|*"MODULE_NOT_FOUND"*) PATTERN="missing-module" ;;
  *"tsc"*"error TS"*) PATTERN="typescript-compile-error" ;;
  *) exit 0 ;;
esac

# dedup fingerprint 정규화(cursor-agent 리뷰 MEDIUM 대응): 전체 STDERR_TEXT 해시는
# 타임스탬프/경로/숫자 한 글자만 달라도 새 시그니처가 되어 24h dedup을 쉽게 우회한다.
# 첫 줄(핵심 에러 메시지)만 사용 + 숫자/경로 제거로 정규화.
FINGERPRINT=$(printf '%s' "$STDERR_TEXT" | head -1 | sed -E 's#/[a-zA-Z0-9_./-]+#<path>#g; s#[0-9]+#<n>#g')
SIG_HASH=$(printf '%s|%s' "$PATTERN" "$FINGERPRINT" | shasum -a 256 2>/dev/null | cut -c1-16)
[ -z "$SIG_HASH" ] && SIG_HASH=$(printf '%s|%s' "$PATTERN" "$FINGERPRINT" | md5 2>/dev/null | cut -c1-16)
DEDUP_FILE="${DEDUP_DIR}/${SIG_HASH}"

# check-and-append 임계구역을 mkdir 원자적 락으로 보호(cursor-agent 리뷰 MEDIUM: race condition 대응).
# flock 미설치 환경(macOS 기본)이라 mkdir 원자성 활용 — post-edit-nco-review.sh와 동일 패턴.
CRITSEC_LOCK="${STATE_DIR}/.critsec.lock"
LOCK_WAITED=0
while ! mkdir "$CRITSEC_LOCK" 2>/dev/null; do
  sleep 0.2
  LOCK_WAITED=$((LOCK_WAITED + 1))
  # 5초 이상 잡혀있으면 stale lock으로 간주하고 강제 진행(다른 훅 인스턴스 크래시 대비)
  [ "$LOCK_WAITED" -gt 25 ] && { rmdir "$CRITSEC_LOCK" 2>/dev/null; break; }
done
trap 'rmdir "$CRITSEC_LOCK" 2>/dev/null' EXIT

if [ -f "$DEDUP_FILE" ]; then
  last=$(cat "$DEDUP_FILE" 2>/dev/null || echo 0)
  now=$(date +%s)
  if [ $((now - last)) -lt 86400 ]; then
    log "SKIP dedup pattern=$PATTERN sig=$SIG_HASH fp=${FINGERPRINT:0:60}"
    exit 0
  fi
fi

now_ts=$(date +%s)
window_start=$((now_ts - RATE_LIMIT_WINDOW_SEC))
recent_count=$( [ -f "$RATE_FILE" ] && awk -v w="$window_start" '$1 > w' "$RATE_FILE" 2>/dev/null | wc -l | tr -d ' ' || echo 0)
if [ "${recent_count:-0}" -ge "$RATE_LIMIT_MAX" ]; then
  log "SKIP rate-limit pattern=$PATTERN (최근 1h ${recent_count}회)"
  exit 0
fi
echo "$now_ts" >> "$RATE_FILE"
echo "$now_ts" > "$DEDUP_FILE"
rmdir "$CRITSEC_LOCK" 2>/dev/null
trap - EXIT

log "TRIGGER pattern=$PATTERN cmd=${CMD:0:100} sig=$SIG_HASH → worker 백그라운드 실행"

if [ -x "$WORKER" ]; then
  nohup bash "$WORKER" "$PATTERN" "$SIG_HASH" "$CMD" "$STDERR_TEXT" >/dev/null 2>&1 &
  disown
fi

exit 0
