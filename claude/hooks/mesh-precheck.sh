#!/bin/bash
# NCO 재귀보호: NCO가 스폰한 서브프로세스 claude에서는 훅 무동작 (2026-07-08, 76s 훅스택+BOOTSTRAP 오염 T1)
[ "${NCO_HOOK_DISABLED:-0}" = "1" ] && exit 0
# Global UserPromptSubmit Hook — 작업 전 Mesh + 에이전트 충돌 사전 체크
# 매 프롬프트 제출 시 실행 — NCO 오프라인이면 조용히 종료

INPUT=$(cat)
NCO_URL="http://localhost:6200"

# ─── NCO 온라인 확인 ──────────────────────────────────────────────────
NCO_HEALTH=$(curl -s --connect-timeout 1 --max-time 2 "$NCO_URL/health" 2>/dev/null)
[ -z "$NCO_HEALTH" ] && exit 0

# ─── 세션 ID 결정 ─────────────────────────────────────────────────────
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

# 이름 결정: NCO_NAME 환경변수를 pid 파일로 교차 검증, 불일치 시 pid 파일 우선
_MY_NAME=""
if [ -n "$NCO_NAME" ]; then
  _env_pf="/tmp/nco-names/${NCO_NAME}.pid"
  if [ -f "$_env_pf" ]; then
    _env_pid=$(cat "$_env_pf" 2>/dev/null | tr -d '[:space:]')
    [ "$_env_pid" = "$NCO_SESSION_ID" ] && _MY_NAME="$NCO_NAME"
  fi
fi
if [ -z "$_MY_NAME" ]; then
  for _pf in /tmp/nco-names/claude-*.pid; do
    [ -f "$_pf" ] || continue
    _rp=$(cat "$_pf" 2>/dev/null | tr -d '[:space:]')
    if [ "$_rp" = "$NCO_SESSION_ID" ]; then
      _MY_NAME=$(basename "$_pf" .pid)
      break
    fi
  done
fi
MY_NAME="${_MY_NAME:-cli}"

# ─── 사용자 프롬프트 추출 ──────────────────────────────────────────────
PROMPT_TEXT=$(echo "$INPUT" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('userMessage', '')[:200])
except:
    pass
" 2>/dev/null || echo "")

# 단순 조회성 프롬프트만 스킵 (작업 지시·개선·수정 등은 항상 체크)
# 주의: "확인","상태","check","status" 는 제외 — 작업 전 확인에도 precheck 필요
if echo "$PROMPT_TEXT" | grep -qiE '^(왜|어디|뭐|무엇|어떻게|설명|조회|보여|리스트|목록|what|why|how|show|list|explain)'; then
  exit 0
fi

# ─── 브랜치 ──────────────────────────────────────────────────────────
BRANCH=$(git -C "${CLAUDE_PROJECT_DIR:-.}" branch --show-current 2>/dev/null || echo "unknown")

# ─── 1) 활성 CLI 세션 조회 ────────────────────────────────────────────
SESSIONS_JSON=$(curl -s --connect-timeout 1 --max-time 3 "$NCO_URL/api/mesh/sessions" 2>/dev/null || echo "{}")
SESSION_COUNT=$(echo "$SESSIONS_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('count',0))" 2>/dev/null || echo "0")

# ─── 2) 백엔드 에이전트 상태 조회 ─────────────────────────────────────
AGENTS_JSON=$(curl -s --connect-timeout 1 --max-time 3 "$NCO_URL/api/agents" 2>/dev/null || echo "{}")
WORKING_AGENTS=$(echo "$AGENTS_JSON" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    agents = d.get('agents', d.get('providers', []))
    working = [a for a in agents if a.get('status') in ('working', 'busy', 'running')]
    print(len(working))
except:
    print(0)
" 2>/dev/null || echo "0")

# ─── 3) Mesh conflict check ────────────────────────────────────────────
CHANGED_FILES=$(git -C "${CLAUDE_PROJECT_DIR:-.}" diff --name-only 2>/dev/null | head -10 | tr '\n' ',' | sed 's/,$//')
FILES_JSON=$(echo "$CHANGED_FILES" | python3 -c "
import sys; f=sys.stdin.read().strip()
print('['+','.join(['\"'+x+'\"' for x in f.split(',') if x])+']')
" 2>/dev/null || echo "[]")

CHECK_RESULT=$(python3 - <<PYEOF 2>/dev/null
import json, urllib.request

payload = json.dumps({
    "sessionId": "$NCO_SESSION_ID",
    "agentId": "$MY_NAME",
    "plannedWork": """$PROMPT_TEXT""",
    "plannedFiles": $FILES_JSON,
    "branch": "$BRANCH"
}).encode()

req = urllib.request.Request(
    "$NCO_URL/api/mesh/check",
    data=payload,
    headers={"Content-Type": "application/json"},
    method="POST"
)
try:
    with urllib.request.urlopen(req, timeout=3) as r:
        d = json.loads(r.read())
        print(json.dumps(d))
except:
    print("{}")
PYEOF
)

# ─── 4) 결과 파싱 + additionalContext 구성 ────────────────────────────
python3 - <<PYEOF
import sys, json, os

session_count = int("$SESSION_COUNT")
working_agents = int("$WORKING_AGENTS")
prompt = """$PROMPT_TEXT"""

try:
    check = json.loads("""$CHECK_RESULT""".replace('"""', '"'))
except:
    check = {}

safe      = check.get("safe", True)
conflicts = check.get("conflictReports", [])
recs      = check.get("recommendations", [])

# ─── 이전 턴 Stop 훅 요약: 표시 안 함 (토큰 절약 — 이미 Claude가 본 정보) ──
summary_file = f"/tmp/nco-stop-summary-$NCO_SESSION_ID.json"
if os.path.exists(summary_file):
    try:
        os.remove(summary_file)
    except:
        pass

# ─── 컨텍스트 구성 ────────────────────────────────────────────────────
lines = []

# Mesh precheck 없으면 조기 종료 (요약만 있을 경우 포함해서 출력)
if session_count <= 1 and working_agents == 0 and safe and not lines:
    sys.exit(0)

lines.append("[MESH PRECHECK]")

if session_count > 1:
    lines.append(f"활성 CLI 세션: {session_count}개 (다른 Claude Code / 에이전트가 작업 중일 수 있음)")

if working_agents > 0:
    lines.append(f"백엔드 에이전트 실행 중: {working_agents}개")

if not safe and conflicts:
    lines.append("⚠ 충돌 감지:")
    for c in conflicts:
        sev = {"high": "[위험]", "medium": "[주의]", "low": "[참고]"}.get(c.get("severity",""), "")
        typ = {"file": "파일충돌", "task": "작업중복", "branch": "브랜치근접"}.get(c.get("type",""), c.get("type",""))
        lines.append(f"  {sev} {typ}: {c.get('detail','')}")

if recs:
    lines.append("권장사항: " + " / ".join(recs))

context = "\n".join(lines)

# USER RULE: 충돌이 있으면 Claude는 작업 전에 반드시 사용자에게 알려야 함
if not safe or working_agents > 0 or session_count > 1:
    context += "\n\nRULE: 위 상황을 사용자에게 먼저 알리고, 충돌이 있으면 진행 여부를 확인받은 후 작업을 시작하라."

print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "UserPromptSubmit",
        "additionalContext": context
    }
}))
PYEOF

exit 0
