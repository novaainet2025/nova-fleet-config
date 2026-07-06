#!/bin/bash
# UserPromptSubmit Hook: 태스크 유형 분류 + 세션 상태 기록
# 신규기능/버그/단순수정을 구분해 enforce 훅이 올바르게 작동하도록 함
# exit 0 (항상 허용 — 분류만 수행)

INPUT=$(cat)

# ── Ollama 로컬 모드: 태스크 분류 주입 스킵 ─────────────────
[ "${NCO_OLLAMA_MODE:-0}" = "1" ] && exit 0

# 프롬프트 추출
PROMPT=$(echo "$INPUT" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('userMessage', '') or d.get('prompt', '') or d.get('user_prompt', ''))
except:
    print('')
" 2>/dev/null)

[ -z "$PROMPT" ] && exit 0

# 세션 ID
if [ -z "$NCO_SESSION_ID" ]; then
    _CK=$$
    for _i in 1 2 3 4 5; do
        _CK=$(ps -o ppid= -p "$_CK" 2>/dev/null | tr -d ' ')
        [ -z "$_CK" ] && break
        _CM=$(ps -o comm= -p "$_CK" 2>/dev/null)
        echo "$_CM" | grep -qE '^(claude|node)$' && { NCO_SESSION_ID="$_CK"; break; }
    done
    NCO_SESSION_ID="${NCO_SESSION_ID:-$$}"
fi

SESSION_TRACK="/tmp/nco-track-${NCO_SESSION_ID}.json"

# 태스크 유형 분류
TASK_TYPE=$(python3 -c "
import re, sys

prompt = '''$PROMPT'''.lower()

# 신규 기능 키워드
new_feat = bool(re.search(r'(만들어|구현|추가|생성|개발|작성|새로|신규|기능|feature|implement|create|add|build|new)', prompt))

# 버그/테스트 키워드
bug_fix  = bool(re.search(r'(버그|오류|에러|수정|고쳐|테스트|test|fix|bug|error|broken|않는|안됨|안돼)', prompt))

# 설명/질문 키워드
explain  = bool(re.search(r'(설명|뭐야|왜|어떻게|확인|조회|보여|알려|explain|what|why|how|show|check|확인)', prompt))

# 설정/단순 키워드
config   = bool(re.search(r'(설정|설치|config|setting|규칙|훅|hook)', prompt))

# R1-E (2026-05-27): mesh peer DM/eval task 인식 — Stop 게이트 오분류 방지.
# mesh-receiver Monitor가 inject한 task notification 또는 [TASK]/[EVAL]/[P*-VOTE] 등
# peer 위임 task는 일반 사용자 prompt와 다르게 워크플로우 단계 적용을 약하게.
# 주의: prompt는 lower() 되어있으므로 정규식도 lowercase 패턴이어야 함.
mesh_task = bool(re.search(r'\[task[^]]*\]|\[eval[^]]*\]|\[p\d+-(vote|audit)|\[new (response|reply|info|broadcas)|mesh:msg_', prompt))

if mesh_task:
    print('mesh_delegated')
elif bug_fix and not new_feat:
    print('bug')
elif new_feat and not explain:
    print('new_feature')
elif explain and not new_feat:
    print('simple')
elif config:
    print('config')
else:
    print('unknown')
" 2>/dev/null)

# 세션 파일에 분류 결과 기록 + task_seq 증가 (state machine 진입점)
python3 -c "
import json, os
f = '$SESSION_TRACK'
d = {}
if os.path.exists(f):
    try: d = json.load(open(f))
    except: pass
order = {'unknown': 0, 'simple': 1, 'config': 2, 'bug': 3, 'new_feature': 4}
task_type = '$TASK_TYPE'
current_max = d.get('task_type_max', d.get('task_type', 'unknown'))
if order.get(task_type, 0) >= order.get(current_max, 0):
    d['task_type_max'] = task_type
else:
    d['task_type_max'] = current_max
# 새 user prompt마다 task_seq 증가 → 위임 결정/권고 1회만 발화하도록
d['task_seq'] = d.get('task_seq', 0) + 1
d['task_type'] = task_type
d['task_decision'] = 'pending'   # UserPromptSubmit 워크플로우 훅이 결정
d['task_warned_seq'] = d.get('task_warned_seq', -1)
d['direct_edits'] = 0
d['warned'] = 0
# nco_calls / task_started_seq / agent_violations는 유지 (세션 전체 통계)
json.dump(d, open(f,'w'))
" 2>/dev/null

# 새 task → Stop cycle 카운터 + blocked sentinel 리셋 (nco-stop-quality-gate.sh GATE 0 용)
rm -f "/tmp/nco-stop-cycle-${NCO_SESSION_ID}" "/tmp/nco-stop-cycle-${NCO_SESSION_ID}.lock" "/tmp/nco-stop-blocked-${NCO_SESSION_ID}" 2>/dev/null

# TASK_TYPE을 stdout으로 주입 (Claude에게 컨텍스트 제공)
if [ "$TASK_TYPE" = "new_feature" ]; then
    python3 -c "import json; print(json.dumps({'hookSpecificOutput': {'hookEventName': 'UserPromptSubmit', 'additionalContext': '[NCO 분류] 태스크 유형: 신규 기능 → opencode 설계 후 codex 구현 + cursor-agent 리뷰 권장'}}))"
elif [ "$TASK_TYPE" = "bug" ]; then
    python3 -c "import json; print(json.dumps({'hookSpecificOutput': {'hookEventName': 'UserPromptSubmit', 'additionalContext': '[NCO 분류] 태스크 유형: 버그/수정 → codex 수정 후 ollama 검증 권장'}}))"
fi

exit 0
