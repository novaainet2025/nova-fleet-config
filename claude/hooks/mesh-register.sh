#!/bin/bash
# Global SessionStart Hook — NCO CLI Mesh 등록
# 어떤 프로젝트에서 열린 Claude Code 세션이든 무조건 mesh에 등록
# NCO 오프라인이면 조용히 스킵

NCO_URL="http://localhost:6200"

# ─── Claude Code PID 탐색 (프로세스 트리 위로 올라가기) ────────────────
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

# ─── 비대화형(-p) 세션 필터링 — Mesh 등록 불필요 ─────────────────────
# claude -p 로 실행된 세션은 모니터를 오염시키므로 등록 차단
if [ -n "$NCO_SESSION_ID" ]; then
  _SESSION_ARGS=$(ps -o args= -p "$NCO_SESSION_ID" 2>/dev/null || echo "")
  if echo "$_SESSION_ARGS" | grep -qE 'claude[[:space:]]+-p[[:space:]]|claude[[:space:]].*--print'; then
    exit 0  # 비대화형 세션 — 조용히 종료
  fi
fi

# ─── NCO_NAME 원자적 예약 ─────────────────────────────────────────────
NCO_NAMES_DIR="/tmp/nco-names"
mkdir -p "$NCO_NAMES_DIR" 2>/dev/null

if [ -z "$NCO_NAME" ]; then
  # flock 안에서 stdout으로 이름 반환 — .last-assigned 공유 파일 경쟁 조건 제거
  NCO_NAME=$(
    (
      flock -w 5 200 || exit 1

      # 죽은 PID 파일 정리 + NCO 백엔드 좀비 세션 disconnect
      for _pf in "$NCO_NAMES_DIR"/claude-*.pid; do
        [ -f "$_pf" ] || continue
        _rp=$(cat "$_pf" 2>/dev/null | tr -d '[:space:]')
        [ -z "$_rp" ] && { rm -f "$_pf"; continue; }
        # 이식성: /proc 는 Linux 전용(macOS 부재 → 전 live 세션 오판·몰살). kill -0 사용.
        if ! kill -0 "$_rp" 2>/dev/null; then
          _dead_name=$(basename "$_pf" .pid)
          curl -s --connect-timeout 1 --max-time 2 -X POST "$NCO_URL/api/mesh/disconnect" \
            -H "Content-Type: application/json" \
            -d "{\"sessionId\":\"${_rp}\",\"agentId\":\"${_dead_name}\"}" > /dev/null 2>&1
          rm -f "$_pf"
        fi
      done

      # 이미 예약된 이름 확인 (재접속 세션)
      # 첫 매칭만 유지하고 나머지 중복 파일은 삭제
      _FOUND_NAME=""
      for _pf in "$NCO_NAMES_DIR"/claude-*.pid; do
        [ -f "$_pf" ] || continue
        _rp=$(cat "$_pf" 2>/dev/null | tr -d '[:space:]')
        if [ "$_rp" = "$NCO_SESSION_ID" ]; then
          _pf_name=$(basename "$_pf" .pid)
          if [ -z "$_FOUND_NAME" ]; then
            _FOUND_NAME="$_pf_name"
          else
            rm -f "$_pf"
          fi
        fi
      done
      if [ -n "$_FOUND_NAME" ]; then
        echo "$_FOUND_NAME"  # stdout으로 반환 — .last-assigned 불필요
        exit 0
      fi

      # 가장 낮은 번호 배정
      _N=1
      while [ -f "$NCO_NAMES_DIR/claude-${_N}.pid" ]; do
        _N=$((_N + 1))
      done
      echo "$NCO_SESSION_ID" > "$NCO_NAMES_DIR/claude-${_N}.pid"
      echo "claude-${_N}"  # stdout으로 반환
    ) 200>"$NCO_NAMES_DIR/.lock"
  )
  [ -z "$NCO_NAME" ] && NCO_NAME="claude-1"
fi

# ─── CLAUDE_ENV_FILE에 이름 저장 (이후 훅에서 재사용) ───────────────
if [ -n "$CLAUDE_ENV_FILE" ]; then
  echo "export NCO_NAME=\"$NCO_NAME\"" >> "$CLAUDE_ENV_FILE"
  echo "export NCO_SESSION_ID=\"$NCO_SESSION_ID\"" >> "$CLAUDE_ENV_FILE"
fi

# ─── NCO 온라인 확인 ──────────────────────────────────────────────────
NCO_HEALTH=$(curl -s --connect-timeout 1 --max-time 2 "$NCO_URL/health" 2>/dev/null)
[ -z "$NCO_HEALTH" ] && exit 0   # NCO 오프라인 — 조용히 종료

# ─── 브랜치 감지 ─────────────────────────────────────────────────────
BRANCH=$(git -C "${CLAUDE_PROJECT_DIR:-.}" branch --show-current 2>/dev/null || echo "unknown")

# ─── 동일 agentId 좀비 세션 백엔드 정리 ──────────────────────────────
# NCO 백엔드에서 같은 이름이지만 다른 PID를 가진 좀비 세션 disconnect
_ZOMBIE_SIDS=$(curl -s --connect-timeout 1 --max-time 2 "$NCO_URL/api/mesh/sessions" 2>/dev/null \
  | python3 -c "
import sys, json
try:
  d = json.load(sys.stdin)
  my_sid, my_name = '$NCO_SESSION_ID', '$NCO_NAME'
  for s in d.get('sessions', []):
    if s.get('agentId') == my_name and str(s.get('sessionId')) != my_sid:
      print(s['sessionId'])
except: pass
" 2>/dev/null)
for _zsid in $_ZOMBIE_SIDS; do
  curl -s --connect-timeout 1 --max-time 2 -X POST "$NCO_URL/api/mesh/disconnect" \
    -H "Content-Type: application/json" \
    -d "{\"sessionId\":\"${_zsid}\",\"agentId\":\"${NCO_NAME}\"}" > /dev/null 2>&1
done

# ─── Mesh 등록 heartbeat ─────────────────────────────────────────────
curl -s --connect-timeout 1 --max-time 3 -X POST "$NCO_URL/api/mesh/heartbeat" \
  -H "Content-Type: application/json" \
  -d "{
    \"sessionId\": \"$NCO_SESSION_ID\",
    \"agentId\": \"$NCO_NAME\",
    \"pid\": $NCO_SESSION_ID,
    \"workMode\": \"solo\",
    \"status\": \"idle\",
    \"currentWork\": \"세션 시작\",
    \"currentFiles\": [],
    \"branch\": \"$BRANCH\"
  }" >/dev/null 2>&1

# ─── 백그라운드 하트비트 데몬 시작 ──────────────────────────────────
# mesh agentId 고유화 (2026-07-03): frozen env 대신 nco-name-resolver 로 세션
# 고유 이름 사용 → 여러 세션 all claude-1 축출 thrashing 방지.
_MRN=$(bash "$HOME/.claude/hooks/nco-name-resolver.sh" 2>/dev/null)
[ -n "$_MRN" ] && NCO_NAME="$_MRN"
# 기존 데몬이 있으면 중복 실행 방지
DAEMON_PID_FILE="/tmp/mesh-heartbeat-daemon-${NCO_SESSION_ID}.pid"
if [ -f "$DAEMON_PID_FILE" ]; then
    _EXISTING_PID=$(cat "$DAEMON_PID_FILE" 2>/dev/null | tr -d '[:space:]')
    if [ -n "$_EXISTING_PID" ] && kill -0 "$_EXISTING_PID" 2>/dev/null; then
        exit 0  # 이미 실행 중
    fi
fi

DAEMON_SCRIPT="${HOME}/.claude/hooks/mesh-heartbeat-daemon.sh"
if [ -x "$DAEMON_SCRIPT" ]; then
    nohup bash "$DAEMON_SCRIPT" "$NCO_SESSION_ID" "$NCO_NAME" "$NCO_URL"         >> "/tmp/mesh-heartbeat-daemon-${NCO_SESSION_ID}.log" 2>&1 &
    disown $!
fi

exit 0
