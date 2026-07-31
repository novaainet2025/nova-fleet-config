#!/bin/bash
# NCO 재귀보호: NCO가 스폰한 서브프로세스 claude에서는 훅 무동작 (2026-07-08, 76s 훅스택+BOOTSTRAP 오염 T1)
[ "${NCO_HOOK_DISABLED:-0}" = "1" ] && exit 0
# SessionStart Hook — Mesh Auto-Responder 자동 시작
#
# 역할:
# - 새 mesh DM poll
# - 작업성 DM 즉시 ack 전송
# - 처리된 msg_id 최근 200개를 ~/.claude/.mesh-processed-ids 에 유지
# - monitor.lock 활성 시 자연어 응답은 양보하되 ack/dedupe 는 유지
# - lock 부재 시 로컬 LLM(Ollama proxy/direct)로 자동 응답

set -u

API="${NCO_API:-http://localhost:6200}"
HOOK_DIR="${HOME}/.claude/hooks"
PROCESSED_FILE="${HOME}/.claude/.mesh-processed-ids"
VALID_PREFIX_RE='^(done|status|question|answer):[[:space:]]'

ensure_processed_file() {
  mkdir -p "$(dirname "$PROCESSED_FILE")" 2>/dev/null || true
  touch "$PROCESSED_FILE" 2>/dev/null || true
}

has_valid_prefix() {
  printf '%s\n' "$1" | grep -Eiq "$VALID_PREFIX_RE"
}

record_processed_id() {
  ensure_processed_file
  MSG_ID="$1" PROCESSED_FILE="$PROCESSED_FILE" python3 <<'PY'
import os

msg_id = os.environ.get("MSG_ID", "").strip()
path = os.environ.get("PROCESSED_FILE", "")
if not msg_id or not path:
    raise SystemExit(0)

seen = []
try:
    with open(path, "r") as fh:
        for line in fh:
            line = line.strip()
            if line:
                seen.append(line)
except Exception:
    pass

fresh = [msg_id]
for item in seen:
    if item != msg_id:
        fresh.append(item)
fresh = fresh[:200]

with open(path, "w") as fh:
    for item in fresh:
        fh.write(item + "\n")
PY
}

is_processed_id() {
  ensure_processed_file
  grep -Fxq "$1" "$PROCESSED_FILE" 2>/dev/null
}

send_mesh_message() {
  local to="$1"
  local text="$2"
  local type="${3:-info}"
  if [ -x "$HOOK_DIR/mesh-send.sh" ]; then
    NCO_SESSION_ID="$SESSION_ID" NCO_NAME="$AGENT_NAME" \
      bash "$HOOK_DIR/mesh-send.sh" "$to" "$text" "$type" >/dev/null 2>&1
    return $?
  fi
  return 1
}

send_ack() {
  local to_sid="$1"
  local msg_id="$2"
  local kind="$3"
  send_mesh_message "$to_sid" "ack: $msg_id $kind" info
}

is_actionable_message() {
  local type="$1"
  local scope="$2"
  local content="$3"
  [ -z "$content" ] && return 1
  printf '%s\n' "$content" | grep -Eiq '^(ack|done|status|question|answer|error):' && return 1
  [ "$type" = "task" ] && return 0
  [ "$scope" = "direct" ] && return 0
  printf '%s\n' "$content" | grep -q '?' && return 0
  return 0
}

normalize_prefix() {
  REPLY_TEXT="$1" python3 <<'PY'
import os
import re

text = os.environ.get("REPLY_TEXT", "")
text = text.strip()
if not text:
    print("answer: ")
    raise SystemExit(0)

if re.match(r'^(done|status|question|answer):\s', text, re.I):
    print(text)
    raise SystemExit(0)

lower = text.lower()
if "?" in text or re.search(r'\b(can|could|should|which|what|when|where|who|why|how)\b', lower):
    prefix = "question:"
elif re.search(r'\b(done|completed|finished|fixed|resolved|implemented|verified)\b', lower):
    prefix = "done:"
elif re.search(r'\b(status|working|progress|investigating|checking|pending|blocked|retry|waiting|running)\b', lower):
    prefix = "status:"
else:
    prefix = "answer:"

print(prefix + " " + text)
PY
}

build_prompt() {
  local from_agent="$1"
  local msg_type="$2"
  local content="$3"
  FROM_AGENT="$from_agent" MSG_TYPE="$msg_type" CONTENT="$content" python3 <<'PY'
import json
import os

from_agent = os.environ.get("FROM_AGENT", "")
msg_type = os.environ.get("MSG_TYPE", "info")
content = os.environ.get("CONTENT", "")

task_summary = content
try:
    payload = json.loads(content)
    if isinstance(payload, dict):
        title = payload.get("title")
        instructions = payload.get("instructions")
        depth = payload.get("depth")
        parts = []
        if title:
            parts.append(f"title: {title}")
        if instructions:
            parts.append(f"instructions: {instructions}")
        if depth is not None:
            parts.append(f"depth: {depth}")
        if parts:
            task_summary = "\n".join(parts)
except Exception:
    pass

prompt = f"""You are an NCO mesh auto-responder for agent {os.environ.get('AGENT_NAME', 'unknown')}.
Reply to sender {from_agent}. Keep the message concise and operational.
Use one of these prefixes at the start of the first line: done:, status:, question:, answer:.
Prefer status: when work is still pending, question: when information is missing, done: only for completed work.
Incoming type: {msg_type}
Incoming content:
{task_summary}
"""
print(prompt)
PY
}

call_proxy_model() {
  local prompt="$1"
  local model payload resp
  model=$(curl -s --connect-timeout 1 --max-time 2 "http://localhost:4100/v1/models" 2>/dev/null \
    | python3 -c 'import json,sys
try:
  d=json.load(sys.stdin); rows=d.get("data", []); print(rows[0]["id"] if rows else "")
except Exception: print("")' 2>/dev/null)
  [ -z "$model" ] && return 1
  payload=$(PROMPT="$prompt" MODEL="$model" python3 -c 'import json,os
print(json.dumps({
  "model": os.environ["MODEL"],
  "messages": [
    {"role": "system", "content": "Return only the final agent message."},
    {"role": "user", "content": os.environ["PROMPT"]}
  ],
  "temperature": 0.2
}, ensure_ascii=False))')
  resp=$(curl -s --connect-timeout 2 --max-time 25 -X POST "http://localhost:4100/v1/chat/completions" \
    -H 'Content-Type: application/json' \
    -d "$payload" 2>/dev/null || true)
  [ -z "$resp" ] && return 1
  printf '%s' "$resp" | python3 -c 'import json,sys
try:
  d=json.load(sys.stdin)
  print(((d.get("choices") or [{}])[0].get("message") or {}).get("content",""))
except Exception:
  print("")' 2>/dev/null
}

call_ollama_model() {
  local prompt="$1"
  local host model payload resp
  for host in "host.docker.internal" "127.0.0.1"; do
    model=$(curl -s --connect-timeout 1 --max-time 2 "http://${host}:11434/api/tags" 2>/dev/null \
      | python3 -c 'import json,sys
try:
  d=json.load(sys.stdin); rows=d.get("models", []); print(rows[0]["name"] if rows else "")
except Exception: print("")' 2>/dev/null)
    [ -z "$model" ] && continue
    payload=$(PROMPT="$prompt" MODEL="$model" python3 -c 'import json,os
print(json.dumps({
  "model": os.environ["MODEL"],
  "prompt": os.environ["PROMPT"],
  "stream": False
}, ensure_ascii=False))')
    resp=$(curl -s --connect-timeout 2 --max-time 25 -X POST "http://${host}:11434/api/generate" \
      -H 'Content-Type: application/json' \
      -d "$payload" 2>/dev/null || true)
    [ -z "$resp" ] && continue
    printf '%s' "$resp" | python3 -c 'import json,sys
try:
  d=json.load(sys.stdin); print(d.get("response",""))
except Exception: print("")' 2>/dev/null
    return 0
  done
  return 1
}

generate_reply() {
  local from_agent="$1"
  local msg_type="$2"
  local content="$3"
  local prompt reply
  prompt=$(AGENT_NAME="$AGENT_NAME" build_prompt "$from_agent" "$msg_type" "$content")
  reply=$(call_proxy_model "$prompt" 2>/dev/null || true)
  if [ -z "$reply" ]; then
    reply=$(call_ollama_model "$prompt" 2>/dev/null || true)
  fi
  if [ -z "$reply" ]; then
    reply="status: auto-responder could not reach a local model; manual follow-up required."
  fi
  normalize_prefix "$reply"
}

should_yield_to_monitor() {
  local lock_file="/tmp/nco-inbox-${SESSION_ID}/monitor.lock"
  [ -f "$lock_file" ]
}

poll_once() {
  local resp last
  last=$(cat "$LAST_FILE" 2>/dev/null || echo "")
  resp=$(curl -s --max-time 4 "${API}/api/mesh/messages?limit=30" 2>/dev/null || true)
  [ -z "$resp" ] && return 0
  RESP="$resp" LAST="$last" PID="$SESSION_ID" AGENT="$AGENT_NAME" python3 <<'PY'
import json
import os

resp = os.environ.get("RESP", "")
last = os.environ.get("LAST", "")
me_pid = os.environ.get("PID", "")
me_agent = os.environ.get("AGENT", "")

try:
    data = json.loads(resp)
except Exception:
    raise SystemExit(0)

msgs = data.get("messages", [])
if not msgs:
    raise SystemExit(0)

fresh = []
for item in msgs:
    if item.get("id") == last:
        break
    fresh.append(item)

for item in reversed(fresh):
    to_session = str(item.get("to_session", ""))
    if to_session == me_pid or to_session == me_agent:
        out = {
            "id": item.get("id", ""),
            "from_agent": item.get("from_agent", ""),
            "from_session": str(item.get("from_session", "")),
            "type": item.get("type", "info") or "info",
            "scope": item.get("scope", "") or "",
            "content": item.get("content", "") or "",
        }
        print(json.dumps(out, ensure_ascii=False))

print(msgs[0].get("id", ""))
PY
}

run_daemon() {
  SESSION_ID="$1"
  AGENT_NAME="$2"
  STATE_DIR="/tmp/mesh-autoresponder-${SESSION_ID}"
  LAST_FILE="${STATE_DIR}/last_id"
  PID_FILE="/tmp/mesh-responder-${SESSION_ID}.pid"
  LOG_FILE="/tmp/mesh-responder-${SESSION_ID}.log"
  mkdir -p "$STATE_DIR" 2>/dev/null || exit 0
  ensure_processed_file

  trap 'rm -f "$PID_FILE"' EXIT
  echo "$$" > "$PID_FILE"

  if [ ! -f "$LAST_FILE" ]; then
    PRIME=$(curl -s --max-time 4 "${API}/api/mesh/messages?limit=1" 2>/dev/null \
      | python3 -c 'import json,sys
try:
  d=json.load(sys.stdin); rows=d.get("messages", []); print(rows[0]["id"] if rows else "")
except Exception: print("")' 2>/dev/null)
    printf '%s' "$PRIME" > "$LAST_FILE"
  fi

  while true; do
    batch=$(poll_once)
    newest=$(printf '%s\n' "$batch" | tail -n 1)
    if [ -n "$newest" ]; then
      printf '%s' "$newest" > "$LAST_FILE"
      printf '%s\n' "$batch" | sed '$d' | while IFS= read -r row; do
        [ -z "$row" ] && continue
        eval "$(
          ROW="$row" python3 <<'PY'
import json
import os
import shlex

row = json.loads(os.environ["ROW"])
for key in ["id", "from_agent", "from_session", "type", "scope", "content"]:
    print(f'{key.upper()}={shlex.quote(str(row.get(key, "")))}')
PY
        )"

        [ -z "${ID:-}" ] && continue
        [ "${FROM_SESSION:-}" = "$SESSION_ID" ] && continue
        is_actionable_message "${TYPE:-info}" "${SCOPE:-}" "${CONTENT:-}" || continue

        if is_processed_id "$ID"; then
          send_ack "$FROM_SESSION" "$ID" "duplicate" || true
          continue
        fi

        send_ack "$FROM_SESSION" "$ID" "received" || true
        record_processed_id "$ID"

        if should_yield_to_monitor; then
          printf '[mesh-autoresponder] yielded msg=%s monitor.lock active\n' "$ID" >>"$LOG_FILE"
          continue
        fi

        reply=$(generate_reply "${FROM_AGENT:-unknown}" "${TYPE:-info}" "${CONTENT:-}")
        [ -z "$reply" ] && reply="answer: "
        send_mesh_message "$FROM_SESSION" "$reply" info || true
      done
    fi

    [ "${MESH_AUTORESPONDER_ONCE:-0}" = "1" ] && break
    sleep "${MESH_AUTORESPONDER_INTERVAL:-5}"
  done
}

if [ "${1:-}" = "--run" ]; then
  SESSION_ID="${2:?missing session id}"
  AGENT_NAME="${3:?missing agent name}"
  run_daemon "$SESSION_ID" "$AGENT_NAME"
  exit 0
fi

# ── 비대화형 세션 필터 ────────────────────────────────────────────────
if ps -o args= -p "${PPID:-$$}" 2>/dev/null | grep -qE 'claude[[:space:]]+-p[[:space:]]|claude[[:space:]].*--print'; then
  exit 0
fi

# ── NCO 온라인 확인 ──────────────────────────────────────────────────
NCO_HEALTH=$(curl -s --connect-timeout 1 --max-time 2 "${API}/health" 2>/dev/null)
[ -z "$NCO_HEALTH" ] && exit 0

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
bash "$0" --run "$SESSION_ID" "$AGENT_NAME" >>"$LOG_FILE" 2>&1 &
RESPONDER_PID=$!

echo "$RESPONDER_PID" > "$PID_FILE"
echo "[mesh-autoresponder] 시작 완료: session=$SESSION_ID agent=$AGENT_NAME pid=$RESPONDER_PID" >&2

exit 0
