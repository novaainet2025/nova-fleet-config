#!/bin/bash
# NCO 재귀보호
[ "${NCO_HOOK_DISABLED:-0}" = "1" ] && exit 0
# UserPromptSubmit Hook — codex+agy 필수 협업 강제 (소프트) + 합의 워크플로우 안내
#
# 정책 (2026-07-19, 사용자 결정):
#   - 적용 범위: 구현·신규기능 작업만. 조회/질문/단순수정 제외.
#   - 강도: 소프트 강제 — 미참여 시 강한 배너 주입(차단 아님). 진행은 계속.
#   - 폴백: codex/agy 리밋·오프라인이면 강제 대신 "대체+미참여 플래그"로 표기 (reroute 규칙 준수).
#   - 합의: codex/agy 산출물 상충 시 /nco-collab (discussion→consensus) 유도.
# exit 0 항상.
[ "${NCO_OLLAMA_MODE:-0}" = "1" ] && exit 0

NCO_HEALTH=$(curl -s --connect-timeout 1 --max-time 2 "http://localhost:6200/health" 2>/dev/null)
[ -z "$NCO_HEALTH" ] && exit 0

INPUT=$(cat)
PROMPT=$(echo "$INPUT" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print((d.get('userMessage') or d.get('prompt') or '')[:400])
except: pass
" 2>/dev/null)
[ -z "$PROMPT" ] && exit 0
[ ${#PROMPT} -lt 8 ] && exit 0

# ── 조회성 prompt는 제외 (구현 작업만 강제) ───────────────
echo "$PROMPT" | grep -qiE '^(왜|어디|뭐|무엇|어떻게|설명|보여|확인|상태|보고|몇|얼마|알려|리스트|목록|what|why|how|show|check|status|report|list)' && exit 0

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

# ── task_type: 구현/신규기능 아니면 강제 미적용 ────────────
TASK_TYPE=$(python3 -c "import json; d=json.load(open('$TRACK')); print(d.get('task_type_max', d.get('task_type','unknown')))" 2>/dev/null || echo unknown)
# task_type이 아직 없으면 prompt로 즉석 판정 (구현 키워드)
if [ "$TASK_TYPE" != "new_feature" ]; then
  echo "$PROMPT" | grep -qiE '(만들|구현|추가|생성|개발|작성|리팩|수정|고쳐|배선|훅|기능|implement|create|add|build|refactor|feature|fix)' || exit 0
fi

# ── codex/agy 가용성 판정 (리밋/오프라인이면 폴백) ─────────
AVAIL=$(curl -s --max-time 4 "http://localhost:6200/api/agents" 2>/dev/null | python3 -c "
import sys, json
LIMIT = ('limit','quota','exceeded','429','resourceexhausted','usage limit','circuit breaker')
def state(a):
    h = a.get('health',{}) or {}
    le = (h.get('lastError') or a.get('lastError') or '').lower()
    st = (a.get('status') or h.get('status') or '').lower()
    if any(k in le for k in LIMIT): return 'limited'
    if st in ('offline','error','dead'): return 'down'
    return 'ok'
try:
    d = json.load(sys.stdin)
    ags = d if isinstance(d,list) else d.get('agents', d.get('data', []))
    res = {}
    for a in ags:
        n = (a.get('name') or a.get('id') or '').lower()
        if 'codex' in n: res['codex'] = state(a)
        elif 'agy' in n or 'anti-gravity' in n or 'gravity' in n: res['agy'] = state(a)
    print('codex=%s agy=%s' % (res.get('codex','unknown'), res.get('agy','unknown')))
except Exception:
    print('codex=unknown agy=unknown')
" 2>/dev/null)
CODEX_ST=$(echo "$AVAIL" | sed -n 's/.*codex=\([a-z]*\).*/\1/p')
AGY_ST=$(echo "$AVAIL" | sed -n 's/.*agy=\([a-z]*\).*/\1/p')

# ── 참여 여부 (track providers_used) ──────────────────────
read -r CODEX_IN AGY_IN <<< "$(python3 -c "
import json
try:
    d=json.load(open('$TRACK')); pu=d.get('providers_used',{}) or {}
    print('yes' if 'codex' in pu else 'no', 'yes' if 'agy' in pu else 'no')
except: print('no no')
" 2>/dev/null)"

python3 - << PYEOF
codex_st = "${CODEX_ST:-unknown}"
agy_st   = "${AGY_ST:-unknown}"
codex_in = "$CODEX_IN" == "yes"
agy_in   = "$AGY_IN" == "yes"

def line(name, st, joined):
    if joined:
        return f"  ✅ {name}: 참여함"
    if st == 'limited':
        return f"  🟡 {name}: 리밋/쿼터 소진 → 강제 면제. 대체 워커(hermes/ollama)로 우회 + '[미참여:{name}=limit]' 플래그 명시"
    if st == 'down':
        return f"  🟡 {name}: 오프라인 → 강제 면제. 대체 경로 + '[미참여:{name}=offline]' 플래그 명시"
    return f"  🔴 {name}: 미참여 (가용) → 필수. 지금 위임하세요"

L = ["[NCO 필수 협업 강제 — codex + agy]"]
L.append("이 작업은 구현/신규기능으로 분류됨 → codex·agy 필수 협업 대상.")
L.append(line("codex", codex_st, codex_in))
L.append(line("agy",   agy_st,   agy_in))

need = []
if not codex_in and codex_st not in ('limited','down'): need.append('codex')
if not agy_in and agy_st not in ('limited','down'): need.append('agy')

if need:
    both = ", ".join(need)
    L.append("")
    L.append(f"  ▶ 조치: Skill(nco-parallel) providers=[{both}] 로 지금 위임 (편집 착수 전 권장).")
    L.append("     예) /nco-parallel [codex, agy] \"구현: <이 작업>\"")
elif codex_in and agy_in:
    L.append("  → 필수 협업 충족. 산출물 상충 시 아래 합의 절차 적용.")

L.append("")
L.append("  ⚖️ 의견 상충 시: codex·agy 산출물이 다르면 /nco-collab-force 로 discussion→consensus 자동 합의.")
L.append("  ※ 소프트 강제 — 차단하지 않습니다. 리밋/오프라인은 대체+플래그로 우회(reroute 규칙).")

import json
print(json.dumps({"hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": "\n".join(L)
}}))
PYEOF
exit 0
