#!/bin/bash
# PostToolUse: NCO 위임 결과를 점수 DB에 기록
# 매 nco-task / nco-team / nco-discussion 호출 후:
#   - 어떤 AI인가 / 응답 길이 / 에러 여부 / 소요 시간 / 작업 유형
# → {{HOME}}/.claude/nco-perf/scores.json 누적
# 다음 호출 라우팅에 사용 (nco-route.sh)

INPUT=$(cat)
PERF_DIR="{{HOME}}/.claude/nco-perf"
SCORES_FILE="$PERF_DIR/scores.json"
mkdir -p "$PERF_DIR" 2>/dev/null

# 디버그 추적 — 호출 및 흐름 기록
TS=$(date -u +%H:%M:%S)
TOOL_DBG=$(echo "$INPUT" | python3 -c "
import sys, json
try: print(json.load(sys.stdin).get('tool_name',''))
except: print('PARSE-ERR')
" 2>/dev/null)
echo "$TS START pid=$$ tool=$TOOL_DBG" >> /tmp/perf-trace.log 2>/dev/null

TOOL_NAME=$(echo "$INPUT" | python3 -c "
import sys, json
try: print(json.load(sys.stdin).get('tool_name',''))
except: print('')
" 2>/dev/null)

# NCO 관련만 처리
case "$TOOL_NAME" in
    mcp__nco-commands__nco-task|mcp__nco-commands__nco-team|mcp__nco-commands__nco-discussion|\
    mcp__nco-commands__nco-consensus|mcp__nco-commands__nco-parallel|mcp__nco-commands__nco-commander|\
    mcp__nco-commands__nco-conductor|mcp__nco-commands__nco-hive|mcp__nco-commands__nco-collab|\
    mcp__nco-commands__nco-next|mcp__nco-commands__nco-next-parallel|\
    nco_task|nco_team|nco_parallel|nco_discussion|nco_consensus|nco_commander|nco_conductor|nco_hive) ;;
    *) exit 0 ;;
esac

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

# 작업 유형 (nco-task-classifier.sh가 기록)
SESSION_TRACK="/tmp/nco-track-${NCO_SESSION_ID}.json"
TASK_TYPE="unknown"
[ -f "$SESSION_TRACK" ] && TASK_TYPE=$(python3 -c "
import json
try: print(json.load(open('$SESSION_TRACK')).get('task_type','unknown'))
except: print('unknown')
" 2>/dev/null)

echo "$TS MATCHED tool=$TOOL_NAME ttype=$TASK_TYPE" >> /tmp/perf-trace.log 2>/dev/null

# 점수 산정 + 누적 갱신 (flock으로 lost-update 방지)
LOCK_FILE="$SCORES_FILE.lock"
exec 9>"$LOCK_FILE"
if ! flock -x -w 3 9; then
    echo "$TS FLOCK-FAIL" >> /tmp/perf-trace.log 2>/dev/null
    exec 9>&-
    exit 0
fi
echo "$TS FLOCK-OK" >> /tmp/perf-trace.log 2>/dev/null
# 입력 JSON과 보조 변수를 환경변수로 전달 (bash heredoc 이스케이프 회피)
export _PERF_INPUT="$INPUT"
export _PERF_SF="$SCORES_FILE"
export _PERF_TASK_TYPE="$TASK_TYPE"
export _PERF_TOOL_NAME="$TOOL_NAME"
python3 <<'PYEOF'
import json, os, sys, time, re
INPUT = os.environ.get('_PERF_INPUT', '')
SF = os.environ.get('_PERF_SF', '')
TASK_TYPE = os.environ.get('_PERF_TASK_TYPE', 'unknown')
TOOL_NAME = os.environ.get('_PERF_TOOL_NAME', '')

try:
    inp = json.loads(INPUT)
except Exception as e:
    sys.exit(0)

ti = inp.get('tool_input', {}) or {}
tr = inp.get('tool_response', {}) or {}

# AI 이름 추출 — nco-task: 첫 토큰, nco-team/discussion: 응답 JSON의 providers
ai_list = []
args_str = ti.get('arguments', '') or ti.get('args', '') or ''
if 'nco-task' in TOOL_NAME or TOOL_NAME == 'nco_task':
    tok = args_str.strip().split()[0] if args_str.strip() else ''
    if re.fullmatch(r'[A-Za-z0-9_-]{1,40}', tok or ''):
        ai_list = [tok]

# 응답에서 ai/providers/assigned_to 추출
resp_str = json.dumps(tr) if isinstance(tr, dict) else str(tr)
try:
    if isinstance(tr, dict):
        if 'ai' in tr: ai_list = [tr['ai']]
        elif 'providers' in tr: ai_list = list(tr['providers'])
        elif 'assigned_to' in tr: ai_list = [tr['assigned_to']]
except: pass

if not ai_list:
    ai_list = ['unknown']

# 성공/실패 판정
resp_text = ''
if isinstance(tr, dict):
    resp_text = tr.get('response') or tr.get('output') or json.dumps(tr)[:500]
else:
    resp_text = str(tr)[:500]

failed = False
if not resp_text or not resp_text.strip():
    failed = True
for marker in ('응답 없음', 'AuthenticationError', 'Missing Authentication', '410 Gone', 'timed out', '5xx Server Error'):
    if marker in resp_text[:500]:
        failed = True
        break

resp_len = len(resp_text)

# DB 로드
try:
    db = json.load(open(SF))
except:
    db = {'version': 1, 'updated': '', 'providers': {}, 'history': []}

# 갱신
now = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())
db['updated'] = now

for ai in ai_list:
    p = db['providers'].setdefault(ai, {
        'total_calls': 0, 'successes': 0, 'failures': 0,
        'total_response_chars': 0, 'last_call': None, 'last_failure': None,
        'task_types': {}
    })
    p['total_calls'] += 1
    p['last_call'] = now
    if failed:
        p['failures'] += 1
        p['last_failure'] = now
        p['last_failure_reason'] = resp_text[:200]
    else:
        p['successes'] += 1
        p['total_response_chars'] += resp_len

    t = p['task_types'].setdefault(TASK_TYPE, {'calls': 0, 'successes': 0, 'failures': 0})
    t['calls'] += 1
    if failed: t['failures'] += 1
    else: t['successes'] += 1

# 히스토리 마지막 100건만 유지
db['history'].append({
    'ts': now, 'tool': TOOL_NAME, 'ai': ai_list, 'task_type': TASK_TYPE,
    'failed': failed, 'resp_len': resp_len
})
db['history'] = db['history'][-100:]

# 원자 쓰기
tmp = SF + '.tmp'
json.dump(db, open(tmp, 'w'), ensure_ascii=False, indent=2)
os.replace(tmp, SF)
PYEOF

PYRC=$?
echo "$TS PYEND rc=$PYRC" >> /tmp/perf-trace.log 2>/dev/null
exec 9>&-   # 락 해제
exit 0
