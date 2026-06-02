#!/bin/bash
# SessionStart Hook — Mesh Auto-Responder 자동 시작
#
# NCO 백엔드(6200)와 Ollama 프록시(4100)가 온라인일 때만 실행.
# 세션별 PID 파일로 중복 실행 방지.
# 비대화형 세션(-p 플래그) 및 에이전트 세션은 자동 스킵.

# ── 비대화형 세션 필터 ────────────────────────────────────────────────
if ps -o args= -p "${PPID:-$$}" 2>/dev/null | grep -qE 'claude[[:space:]]+-p[[:space:]]|claude[[:space:]].*--print'; then
  exit 0
fi

# ── NCO 온라인 확인 ──────────────────────────────────────────────────
NCO_HEALTH=$(curl -s --connect-timeout 1 --max-time 2 "http://localhost:6200/health" 2>/dev/null)
[ -z "$NCO_HEALTH" ] && exit 0

# ── AI 백엔드 확인: 프록시(4100) OR Ollama 직접(11434) 중 하나라도 OK면 진행 ──
# autoresponder.js는 프록시 실패 시 Ollama 직접 호출 fallback이 있음
PROXY_OK=0
OLLAMA_OK=0
curl -s --connect-timeout 1 --max-time 2 "http://localhost:4100/v1/models" >/dev/null 2>&1 && PROXY_OK=1
# WSL: host.docker.internal → 게이트웨이 → 127.0.0.1 순으로 시도
_GW=$(ip route show default 2>/dev/null | awk '{print $3; exit}')
for _h in "host.docker.internal" "$_GW" "127.0.0.1"; do
  [ -z "$_h" ] && continue
  curl -s --connect-timeout 1 --max-time 2 "http://${_h}:11434/api/tags" >/dev/null 2>&1 && { OLLAMA_OK=1; break; }
done
[ "$PROXY_OK" = "0" ] && [ "$OLLAMA_OK" = "0" ] && exit 0  # 두 백엔드 모두 없음

# ── node 실행 가능 확인 ──────────────────────────────────────────────
command -v node >/dev/null 2>&1 || exit 0

RESPONDER_SCRIPT="{{HOME}}/projects/mesh-auto-responder.js"
[ -f "$RESPONDER_SCRIPT" ] || exit 0

# ── 세션 ID 결정 (mesh-register.sh와 동일한 로직) ───────────────────
SESSION_ID=""
_CK=$$
for _i in 1 2 3 4 5; do
  _CK=$(ps -o ppid= -p "$_CK" 2>/dev/null | tr -d ' ')
  [ -z "$_CK" ] && break
  _CM=$(ps -o comm= -p "$_CK" 2>/dev/null)
  if echo "$_CM" | grep -qE '^(claude|node)$'; then
    SESSION_ID="$_CK"
    break
  fi
done
SESSION_ID="${SESSION_ID:-${PPID:-$$}}"

# ── 이미 실행 중인지 확인 ────────────────────────────────────────────
PID_FILE="/tmp/mesh-responder-${SESSION_ID}.pid"
if [ -f "$PID_FILE" ]; then
  EXISTING_PID=$(cat "$PID_FILE" 2>/dev/null | tr -d '[:space:]')
  if [ -n "$EXISTING_PID" ] && [ "$EXISTING_PID" != "0" ] && kill -0 "$EXISTING_PID" 2>/dev/null; then
    # 이미 실행 중 — 종료
    exit 0
  fi
  rm -f "$PID_FILE"
fi

# ── 에이전트 이름 결정 (/tmp/nco-names/ 에서 조회) ──────────────────
AGENT_NAME="${NCO_NAME:-}"
if [ -z "$AGENT_NAME" ]; then
  for _pf in /tmp/nco-names/claude-*.pid; do
    [ -f "$_pf" ] || continue
    _rp=$(cat "$_pf" 2>/dev/null | tr -d '[:space:]')
    if [ "$_rp" = "$SESSION_ID" ]; then
      AGENT_NAME=$(basename "$_pf" .pid)
      break
    fi
  done
fi
AGENT_NAME="${AGENT_NAME:-claude-bot-${SESSION_ID}}"

# ── auto-responder 백그라운드 시작 ───────────────────────────────────
LOG_FILE="/tmp/mesh-responder-${SESSION_ID}.log"
node "$RESPONDER_SCRIPT" "$SESSION_ID" "$AGENT_NAME" >>"$LOG_FILE" 2>&1 &
RESPONDER_PID=$!

echo "$RESPONDER_PID" > "$PID_FILE"
echo "[mesh-autoresponder] 시작 완료: session=$SESSION_ID agent=$AGENT_NAME pid=$RESPONDER_PID" >&2

exit 0
