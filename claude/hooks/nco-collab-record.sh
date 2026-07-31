#!/bin/bash
# NCO 재귀보호: NCO가 스폰한 서브프로세스 claude에서는 훅 무동작
[ "${NCO_HOOK_DISABLED:-0}" = "1" ] && exit 0
# PreToolUse Hook — 프로바이더 참여 기록기 (codex+agy 필수 협업 강제의 T1 소스)
#
# 정책 (2026-07-19):
#   - NCO 위임 호출(Skill nco-*, mcp__nco*, Bash curl :6200/api/*)을 감지하면
#     대상 프로바이더를 파싱해 track 파일 providers_used[provider]=현재 task_seq 로 기록.
#   - 이 기록이 nco-collab-inject.sh(UserPromptSubmit)의 "codex/agy 참여 여부" 판정 근거(T1).
#   - 절대 차단 안 함 (exit 0). 소프트 강제 원칙 — 교착 없음.
[ "${NCO_OLLAMA_MODE:-0}" = "1" ] && exit 0

INPUT=$(cat)

# ── 빠른 사전 필터: 위임 관련 도구가 아니면 즉시 종료 (PreToolUse는 매 호출 실행 → 경량 유지) ──
case "$INPUT" in
  *nco-task*|*nco-parallel*|*nco-team*|*nco-conductor*|*nco-commander*|*nco-hive*|*nco-flow*|*nco-do*|*nco-next*|*mcp__nco*|*localhost:6200*|*127.0.0.1:6200*) ;;
  *) exit 0 ;;
esac

# ── 세션 ID ───────────────────────────────────────────────
_SID="${NCO_SESSION_ID:-}"
if [ -z "$_SID" ]; then
  _CK=$$
  for _i in 1 2 3; do
    _CK=$(ps -o ppid= -p "$_CK" 2>/dev/null | tr -d ' ')
    [ -z "$_CK" ] && break
    ps -o comm= -p "$_CK" 2>/dev/null | grep -qE '^(claude|node)$' && { _SID="$_CK"; break; }
  done
  _SID="${_SID:-$$}"
fi
TRACK="/tmp/nco-track-${_SID}.json"

NCO_EV="$INPUT" NCO_TRACK="$TRACK" python3 << 'PYEOF' 2>/dev/null
import os, sys, json, re, time
TRACK = os.environ.get('NCO_TRACK','')
raw = os.environ.get('NCO_EV','')
try:
    ev = json.loads(raw)
except Exception:
    sys.exit(0)

tool = ev.get('tool_name', '') or ''
ti = ev.get('tool_input', {}) or {}

# 알려진 프로바이더 토큰 (별칭 정규화)
KNOWN = {
    'codex':'codex', 'agy':'agy', 'anti-gravity':'agy', 'antigravity':'agy',
    'opencode':'opencode', 'cursor-agent':'cursor-agent', 'cursor':'cursor-agent',
    'copilot':'copilot', 'ollama':'ollama', 'hermes':'hermes',
    'openrouter':'openrouter',
    'claude-code':'claude-code',
}

def scan(text):
    if not text: return set()
    t = str(text).lower()
    found = set()
    for tok, norm in KNOWN.items():
        # 단어 경계 매칭 (부분 오탐 감소)
        if re.search(r'(?<![a-z0-9-])' + re.escape(tok) + r'(?![a-z0-9])', t):
            found.add(norm)
    return found

providers = set()
is_delegation = False

# 1) Skill 도구: nco 위임 스킬 + args 에서 프로바이더 파싱
if tool == 'Skill':
    skill = str(ti.get('skill', '')).lower()
    if skill.startswith('nco-') and any(k in skill for k in
        ('task','parallel','team','conductor','commander','hive','flow','do','next','solve','analyze')):
        is_delegation = True
        providers |= scan(ti.get('args', ''))
# 2) MCP nco 도구
elif tool.startswith('mcp__') and 'nco' in tool.lower():
    is_delegation = True
    providers |= scan(ti.get('ai', ''))
    pv = ti.get('providers')
    if isinstance(pv, list):
        for p in pv: providers |= scan(p)
    providers |= scan(json.dumps(ti, ensure_ascii=False))
# 3) Bash: NCO API 직접 호출
elif tool == 'Bash':
    cmd = str(ti.get('command', ''))
    if re.search(r'(localhost|127\.0\.0\.1):6200/api/(task|conductor|parallel|realtime|commander|team)', cmd):
        is_delegation = True
        # "ai":"codex" / providers:[...] 부근만 스캔 (prompt 본문 오탐 감소)
        m = re.findall(r'"(?:ai|provider|providers|agent|targetAgentId)"\s*:\s*(\[[^\]]*\]|"[^"]*")', cmd)
        for seg in m: providers |= scan(seg)

if not is_delegation or not providers:
    sys.exit(0)

# ── track 로드 + 기록 ─────────────────────────────────────
try:
    d = json.load(open(TRACK))
except Exception:
    d = {}
task_seq = d.get('task_seq', 0)
pu = d.get('providers_used', {})
if not isinstance(pu, dict): pu = {}
now = int(time.time())
for p in providers:
    e = pu.get(p) or {}
    if not isinstance(e, dict): e = {}
    e['last_task_seq'] = task_seq
    e['ts'] = now
    e['count'] = e.get('count', 0) + 1
    pu[p] = e
d['providers_used'] = pu
try:
    json.dump(d, open(TRACK, 'w'), ensure_ascii=False)
except Exception:
    pass
PYEOF
exit 0
