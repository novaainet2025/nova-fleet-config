#!/bin/bash
# NCO 재귀보호: NCO가 스폰한 서브프로세스 claude에서는 훅 무동작 (2026-07-08, 76s 훅스택+BOOTSTRAP 오염 T1)
[ "${NCO_HOOK_DISABLED:-0}" = "1" ] && exit 0
# PreToolUse Hook: NCO 위임 정책 (작업 진행 중에는 절대 차단 안 함)
#
# 정책 (2026-05-25 재설계):
#   - Edit/Write/MultiEdit/Bash: 차단 없음. task_started_seq만 기록.
#   - Agent 도구 (Claude Code 내장 서브에이전트): 리서치 외 위반 차단 유지.
#   - 위임 권고는 UserPromptSubmit이 작업 시작 전 1회만 수행.
#
# exit 0 = 허용 | exit 2 = 차단(stderr → Claude 주입, Agent 도구만)

INPUT=$(cat)

# ── Ollama 로컬 모드: 차단 비활성 ─────────────────────────
[ "${NCO_OLLAMA_MODE:-0}" = "1" ] && exit 0

TOOL_NAME=$(echo "$INPUT" | python3 -c "
import sys, json
try: print(json.load(sys.stdin).get('tool_name',''))
except: print('')
" 2>/dev/null)

# ── 세션 ID 해석 ─────────────────────────────────────────
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

case "$TOOL_NAME" in
    Agent)
        # Agent 도구 = Claude Code 내장 서브에이전트.
        # 리서치 전용(Explore/Plan/claude-code-guide/statusline-setup)은 허용.
        # 그 외는 NCO MCP 도구로 위임해야 하므로 차단.
        SUBAGENT_TYPE=$(echo "$INPUT" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('tool_input', {}).get('subagent_type', ''))
except: print('')
" 2>/dev/null)
        case "$SUBAGENT_TYPE" in
            Explore|Plan|claude-code-guide|statusline-setup)
                exit 0 ;;
            *)
                # 위반 카운트 기록 (워크플로우 훅에서 사용)
                python3 -c "
import json, os
f='$SESSION_TRACK'; d={}
try: d=json.load(open(f))
except: pass
d['agent_violations'] = d.get('agent_violations', 0) + 1
json.dump(d, open(f,'w'))
" 2>/dev/null
                cat >&2 <<AGENT_BLOCK
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
[NCO 규칙 위반 — Agent 도구 차단]

⛔ Claude Code 내장 Agent로 구현 작업을 직접 실행하려 했습니다.

Opus Commander 규칙: 모든 구현/수정은 NCO 도구로 위임해야 합니다.
  → /nco-task <agent> <prompt>   (단일 에이전트 위임)
  → /nco-team <prompt>           (병렬 에이전트 실행)
  → /nco-mesh send @<id> [TASK]  (열린 세션에 위임)

허용되는 서브에이전트: Explore, Plan, claude-code-guide, statusline-setup (리서치 전용)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
AGENT_BLOCK
                exit 2 ;;
        esac
        ;;
    Edit|Write|MultiEdit|Bash)
        # 차단하지 않음. 단, 첫 편집 시점에 task_started_seq를 기록해
        # UserPromptSubmit 훅이 "이 작업은 이미 진행 중"임을 인지하게 함.
        # (Bash는 차단 안 하므로 굳이 sed/perl 패턴 구분 불필요)
        python3 -c "
import json, os
f='$SESSION_TRACK'; d={}
try: d=json.load(open(f))
except: pass
cur_seq = d.get('task_seq', 0)
if d.get('task_started_seq', -1) != cur_seq:
    d['task_started_seq'] = cur_seq
d['direct_edits'] = d.get('direct_edits', 0) + 1
json.dump(d, open(f,'w'))
" 2>/dev/null
        exit 0 ;;
    *)
        exit 0 ;;
esac
