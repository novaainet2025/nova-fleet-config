#!/bin/bash
# Global UserPromptSubmit Hook — NCO CLI Mesh 주기적 갱신
# 매 프롬프트 제출 시 세션을 mesh에서 살아있게 유지 (TTL 갱신)
# NCO 오프라인이면 조용히 스킵 (exit 0 필수 — exit 2 금지)

INPUT=$(cat)
NCO_URL="http://localhost:6200"

# ─── NCO_SESSION_ID 결정 ─────────────────────────────────────────────
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
  # PPID 폴백 금지: 임시 bash 서브프로세스 PID가 유령 세션을 만드는 핵심 원인
  # 탐색 실패 시 등록 자체를 건너뜀 (유령 'cli' 세션 생성 방지)
  [ -z "$NCO_SESSION_ID" ] && exit 0
fi

# ─── NCO_NAME 결정 ────────────────────────────────────────────────────
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
# 이름을 resolve하지 못하면 heartbeat 전송 금지 — 'cli' 유령 세션 방지
[ -z "$NCO_NAME" ] && exit 0
MY_NAME="$NCO_NAME"

# ─── NCO 온라인 확인 ──────────────────────────────────────────────────
NCO_HEALTH=$(curl -s --connect-timeout 1 --max-time 2 "$NCO_URL/health" 2>/dev/null)
[ -z "$NCO_HEALTH" ] && exit 0

# ─── 현재 작업 컨텍스트 수집 ─────────────────────────────────────────
BRANCH=$(git -C "${CLAUDE_PROJECT_DIR:-.}" branch --show-current 2>/dev/null || echo "unknown")

PROMPT_PREVIEW=$(echo "$INPUT" | python3 -c "
import sys, json
try:
  d = json.load(sys.stdin)
  print(d.get('userMessage','')[:80])
except:
  pass
" 2>/dev/null || echo "")

# currentFiles: git 변경분 + 프롬프트에서 파일 경로 패턴 추출 (충돌 감지 정확도 향상)
FILES_JSON=$(python3 -c "
import sys, subprocess, re, os, json

proj = os.environ.get('CLAUDE_PROJECT_DIR', '.')
# 1) git diff (unstaged) + git diff --cached (staged)
try:
    unstaged = subprocess.check_output(['git','-C',proj,'diff','--name-only'], text=True, stderr=subprocess.DEVNULL)
    staged   = subprocess.check_output(['git','-C',proj,'diff','--cached','--name-only'], text=True, stderr=subprocess.DEVNULL)
    git_files = [f for f in (unstaged+staged).splitlines() if f.strip()]
except:
    git_files = []

# 2) 프롬프트에서 파일 경로 패턴 추출 (확장자 있는 경로)
prompt = '''$PROMPT_PREVIEW'''
prompt_files = re.findall(r'[\w./\-]+\.(?:ts|js|py|sh|json|md|tsx|jsx|go|rs|yaml|yml|toml)(?![a-zA-Z0-9_.])', prompt)

# 합치기, 중복 제거, 최대 8개
all_files = list(dict.fromkeys(git_files + prompt_files))[:8]
print(json.dumps(all_files))
" 2>/dev/null || echo "[]")

# ─── 다른 세션이 있으면 mesh 모드, 혼자면 solo ────────────────────────
SESSION_COUNT=$(curl -s --connect-timeout 1 --max-time 2 "$NCO_URL/api/mesh/sessions" 2>/dev/null \
  | python3 -c "import sys,json; print(json.load(sys.stdin).get('count',0))" 2>/dev/null || echo "0")
if [ "$SESSION_COUNT" -gt 1 ] 2>/dev/null; then
  WORK_MODE="mesh"
else
  WORK_MODE="solo"
fi

# ─── 좀비 세션 자동 정리 (죽은 PID의 백엔드 세션 disconnect) ─────────
_ALL_SESSIONS=$(curl -s --connect-timeout 1 --max-time 2 "$NCO_URL/api/mesh/sessions" 2>/dev/null)
if [ -n "$_ALL_SESSIONS" ]; then
  _DEAD_SIDS=$(echo "$_ALL_SESSIONS" | python3 -c "
import sys, json, os
try:
  d = json.load(sys.stdin)
  for s in d.get('sessions', []):
    sid = str(s.get('sessionId', ''))
    aid = s.get('agentId', '')
    if sid and sid.isdigit() and not os.path.isdir('/proc/' + sid):
      print(sid + ' ' + aid)
except: pass
" 2>/dev/null)
  while IFS=' ' read -r _dsid _daid; do
    [ -z "$_dsid" ] && continue
    curl -s --connect-timeout 1 --max-time 2 -X POST "$NCO_URL/api/mesh/disconnect" \
      -H "Content-Type: application/json" \
      -d "{\"sessionId\":\"${_dsid}\",\"agentId\":\"${_daid}\"}" > /dev/null 2>&1
    # PID 파일도 정리
    for _pf in /tmp/nco-names/claude-*.pid; do
      [ -f "$_pf" ] || continue
      [ "$(cat "$_pf" 2>/dev/null | tr -d '[:space:]')" = "$_dsid" ] && rm -f "$_pf"
    done
  done <<< "$_DEAD_SIDS"
fi

# ─── 고아 auto-responder 정리 (죽은 세션의 responder kill + PID 파일 삭제) ─
for _rf in /tmp/mesh-responder-*.pid; do
  [ -f "$_rf" ] || continue
  _rsid=$(basename "$_rf" .pid | sed 's/mesh-responder-//')
  [ -z "$_rsid" ] && continue
  # 세션 프로세스가 살아있으면 스킵
  [ -d "/proc/$_rsid" ] && continue
  # 고아 responder kill
  _rpid=$(cat "$_rf" 2>/dev/null | tr -d '[:space:]')
  if [ -n "$_rpid" ] && [ -d "/proc/$_rpid" ]; then
    kill "$_rpid" 2>/dev/null
  fi
  rm -f "$_rf" "/tmp/mesh-responder-${_rsid}.log"
done

# ─── 데몬 자가 복구: 이 세션에 데몬이 없으면 시작 ─────────────────────
# mesh agentId 고유화 (2026-07-03): frozen env 대신 nco-name-resolver 로 세션
# 고유 이름 사용 → 여러 세션 all claude-1 축출 thrashing 방지.
_MRN=$(bash "$HOME/.claude/hooks/nco-name-resolver.sh" 2>/dev/null)
[ -n "$_MRN" ] && MY_NAME="$_MRN"
# (세션 시작 전에 daemon 코드가 추가된 경우 포함)
if [ -n "$NCO_SESSION_ID" ] && [ -n "$MY_NAME" ]; then
    DAEMON_PID_FILE="/tmp/mesh-heartbeat-daemon-${NCO_SESSION_ID}.pid"
    DAEMON_SCRIPT="${HOME}/.claude/hooks/mesh-heartbeat-daemon.sh"
    _NEED_DAEMON=0
    if [ ! -f "$DAEMON_PID_FILE" ]; then
        _NEED_DAEMON=1
    else
        _DPID=$(cat "$DAEMON_PID_FILE" 2>/dev/null | tr -d '[:space:]')
        [ -n "$_DPID" ] && kill -0 "$_DPID" 2>/dev/null || _NEED_DAEMON=1
    fi
    if [ "$_NEED_DAEMON" = "1" ] && [ -x "$DAEMON_SCRIPT" ]; then
        nohup bash "$DAEMON_SCRIPT" "$NCO_SESSION_ID" "$MY_NAME" "$NCO_URL"             >> "/tmp/mesh-heartbeat-daemon-${NCO_SESSION_ID}.log" 2>&1 &
        disown $!
    fi
fi

# ─── Heartbeat 전송 ────────────────────────────────────────────────────
curl -s --connect-timeout 1 --max-time 3 -X POST "$NCO_URL/api/mesh/heartbeat" \
  -H "Content-Type: application/json" \
  -d "{
    \"sessionId\": \"$NCO_SESSION_ID\",
    \"agentId\": \"$MY_NAME\",
    \"pid\": $NCO_SESSION_ID,
    \"workMode\": \"$WORK_MODE\",
    \"status\": \"coding\",
    \"currentWork\": \"$(echo "$PROMPT_PREVIEW" | sed 's/"/\\"/g')\",
    \"currentFiles\": $FILES_JSON,
    \"branch\": \"$BRANCH\"
  }" >/dev/null 2>&1

# ─── 오케스트레이션 힌트 — 세션당 1회, 명확한 키워드 매칭만 ──────────
CHANGED_COUNT=$(git -C "${CLAUDE_PROJECT_DIR:-.}" diff --name-only 2>/dev/null | wc -l | tr -d '[:space:]' || echo "0")

# 세션당 1회 제한 (중복 주입 방지)
ORCH_FLAG="/tmp/nco-orch-hint-${NCO_SESSION_ID}"
if [ ! -f "$ORCH_FLAG" ]; then
    ORCH_HINT=""
    if echo "$PROMPT_PREVIEW" | grep -qiE '(구현|만들어|추가|implement|create|add|build)' && [ "${CHANGED_COUNT:-0}" -ge 5 ]; then
        ORCH_HINT="AUTO_PARALLEL: nco_parallel 사용 고려"
    elif echo "$PROMPT_PREVIEW" | grep -qiE '(리뷰|검토|review|audit|보안|security)'; then
        ORCH_HINT="AUTO_REVIEW: cursor-agent+ollama 병렬 사용 고려"
    fi
    # CHANGED_COUNT≥5만의 generic 힌트 제거 — nco-rules-inject와 중복

    if [ -n "$ORCH_HINT" ]; then
        touch "$ORCH_FLAG"
        cat <<ENDJSON
{
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": "[NCO:${MY_NAME}] ${ORCH_HINT}"
  }
}
ENDJSON
    fi
fi

exit 0
