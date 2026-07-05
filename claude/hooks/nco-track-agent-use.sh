#!/bin/bash
# PostToolUse Hook: NCO 에이전트 사용 추적
# nco_task, nco_parallel, nco_commander 등 MCP 도구 호출 시 카운터 증가
# nco-agent-enforce.sh 가 이 카운터를 보고 강제 여부 판단

INPUT=$(cat)

# MCP 도구 이름 추출
TOOL_NAME=$(echo "$INPUT" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('tool_name', ''))
except:
    print('')
" 2>/dev/null || echo "")

# ── 세션 ID 해석 (Agent case에서 SESSION_TRACK 필요하므로 먼저 실행) ──
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

# NCO 관련 도구 감지
# 1) MCP 도구명 직접 매칭 (언더스코어 형식 + mcp__ 접두사 형식 모두 지원)
case "$TOOL_NAME" in
    nco_task|nco_parallel|nco_commander|nco_conductor|nco_consensus)
        : ;;  # 해당 — 아래 NCO 카운트 증가
    mcp__nco-commands__*)
        : ;;  # MCP prefix 형식 (mcp__nco-commands__nco-task 등)

    # 2) Skill 도구로 nco-* 스킬 호출한 경우
    Skill)
        SKILL_NAME=$(echo "$INPUT" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('tool_input', {}).get('skill', ''))
except: print('')
" 2>/dev/null)
        echo "$SKILL_NAME" | grep -qE '^nco-' || exit 0
        ;;

    # 3) Bash 도구로 NCO API 직접 호출한 경우
    Bash)
        CMD=$(echo "$INPUT" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('tool_input', {}).get('command', ''))
except: print('')
" 2>/dev/null)
        # localhost:6200/api/* 직접 호출 OR delegate.py 래퍼(내부에서 /api/task 위임) OR nco-supervisor 위임
        echo "$CMD" | grep -qE 'localhost:6200/api/(task|parallel|commander|conductor|mesh/send|agent)|delegate\.py' || exit 0
        ;;

    # 4) Agent 도구 — NCO가 아님! Explore/Plan만 허용, 나머지는 위반 기록
    Agent)
        SUBAGENT_TYPE=$(echo "$INPUT" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('tool_input', {}).get('subagent_type', ''))
except: print('')
" 2>/dev/null)
        case "$SUBAGENT_TYPE" in
            Explore|Plan|claude-code-guide|statusline-setup)
                exit 0 ;;  # 리서치 에이전트는 카운트하지 않음
            *)
                # 구현용 Agent 사용 = NCO 위반 기록
                python3 -c "
import json, os
f = '$SESSION_TRACK'
d = {}
if os.path.exists(f):
    try: d = json.load(open(f))
    except: pass
d['agent_violations'] = d.get('agent_violations', 0) + 1
json.dump(d, open(f,'w'))
" 2>/dev/null
                exit 0 ;;  # NCO 카운트 증가하지 않음
        esac
        ;;

    *) exit 0 ;;
esac

# nco-task / Skill(nco-task) 호출 시 에이전트 이름 추출 (review/verification 단계 마킹용)
# 주의: env 변수로만 Python에 전달 — bash $-interpolation injection 방지
export NCO_TASK_AGENT=""
case "$TOOL_NAME" in
    mcp__nco-commands__nco-task|nco_task)
        export NCO_TASK_AGENT=$(echo "$INPUT" | python3 -c "
import sys, json, re
try:
    d = json.load(sys.stdin)
    args = d.get('tool_input', {}).get('arguments', '') or ''
    tok = args.strip().split()[0] if args.strip() else ''
    # 안전한 식별자만 허용 (영문자·숫자·- 만)
    print(tok if re.fullmatch(r'[A-Za-z0-9_-]{1,40}', tok) else '')
except: print('')
" 2>/dev/null) ;;
    Skill)
        if [ "$SKILL_NAME" = "nco-task" ]; then
            _sa=$(echo "$INPUT" | python3 -c "
import sys, json
try: print(json.load(sys.stdin).get('tool_input',{}).get('args',''))
except: print('')
" 2>/dev/null)
            _tok=$(echo "$_sa" | awk '{print $1}')
            echo "$_tok" | grep -qE '^[A-Za-z0-9_-]{1,40}$' && export NCO_TASK_AGENT="$_tok"
        fi ;;
esac

# NCO 사용 카운터 증가 + warned 초기화 + stage 마킹
python3 -c "
import json, os

# track 파일 업데이트
f = '$SESSION_TRACK'
d = {}
if os.path.exists(f):
    try: d = json.load(open(f))
    except: pass
d['nco_calls'] = d.get('nco_calls', 0) + 1
d['warned'] = 0
d['last_nco_tool'] = '$TOOL_NAME'
json.dump(d, open(f, 'w'))

# stage 파일 업데이트
sid = '$SESSION_TRACK'.replace('/tmp/nco-track-', '').replace('.json', '')
sf = f'/tmp/nco-stages-{sid}.json'
stages = {}
if os.path.exists(sf):
    try: stages = json.load(open(sf))
    except: pass

tool = '$TOOL_NAME'
skill = '$SKILL_NAME' if '$SKILL_NAME' else ''
cmd = ''

# 단계 매핑
discussion_tools = {'mcp__nco-commands__nco-discussion', 'mcp__nco-commands__nco-collab',
                    'mcp__nco-commands__nco-consensus', 'nco_consensus'}
design_tools     = {'mcp__nco-commands__nco-plan', 'mcp__nco-commands__nco-solve',
                    'mcp__nco-commands__nco-conductor', 'nco_conductor'}
impl_tools       = {'mcp__nco-commands__nco-task', 'mcp__nco-commands__nco-team',
                    'mcp__nco-commands__nco-do', 'mcp__nco-commands__nco-next',
                    'mcp__nco-commands__nco-next-parallel', 'mcp__nco-commands__nco-commander',
                    'mcp__nco-commands__nco-hive', 'mcp__nco-commands__nco-delegate',
                    'nco_task', 'nco_parallel', 'nco_commander'}
gap_tools        = {'mcp__nco-commands__nco-gap', 'mcp__nco-commands__nco-analyze', 'nco_analyze'}

# Skill 이름 기반 매핑
if skill:
    if skill in ('nco-discussion', 'nco-consensus', 'nco-collab'): stages['discussion'] = True
    elif skill in ('nco-plan', 'nco-conductor', 'nco-solve'):       stages['design'] = True
    elif skill in ('nco-task', 'nco-team', 'nco-do', 'nco-parallel',
                   'nco-next', 'nco-next-parallel', 'nco-commander',
                   'nco-hive', 'nco-delegate'):                      stages['implementation'] = True
    elif skill in ('nco-gap', 'nco-analyze'):                        stages['gap_analysis'] = True

if tool in discussion_tools: stages['discussion'] = True
if tool in design_tools:     stages['design'] = True
if tool in impl_tools:       stages['implementation'] = True
if tool in gap_tools:        stages['gap_analysis'] = True

# nco-task 에이전트 기반 review/verification 단계 마킹 (env 변수 사용)
task_agent = os.environ.get('NCO_TASK_AGENT', '').lower().replace('-', '_')
review_agents  = {'cursor_agent', 'cursor', 'review'}
verify_agents  = {'ollama', 'vllm', 'gemma', 'qwen', 'openrouter', 'verify'}
if task_agent in review_agents:
    stages['review'] = True
elif task_agent in verify_agents:
    stages['verification'] = True

json.dump(stages, open(sf, 'w'))
" 2>/dev/null

exit 0
