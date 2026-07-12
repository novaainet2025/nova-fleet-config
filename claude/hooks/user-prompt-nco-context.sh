#!/bin/bash
# NCO 재귀보호: NCO가 스폰한 서브프로세스 claude에서는 훅 무동작 (2026-07-08, 76s 훅스택+BOOTSTRAP 오염 T1)
[ "${NCO_HOOK_DISABLED:-0}" = "1" ] && exit 0
echo "[$(date +%H:%M:%S)] HOOK_START user-prompt-nco-context.sh" >> /tmp/claude-hook-trace.log
# UserPromptSubmit Hook: NCO context + CLI Mesh heartbeat
# Purpose: Report work, detect conflicts, receive messages from other CLIs
# Rule: Never exit 2

INPUT=$(cat)

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-/Users/nova-ai/project/nco}"
# Resolve NCO_SESSION_ID: env var > topmost claude/node 조상 PID 탐색
# 버그 수정 2026-07-03: 가까운 조상(break) + $PPID/$$ fallback 제거 → topmost no-break로 통일.
# $PPID/$$ fallback이 ephemeral 셸 PID를 pid 파일에 기록 → stale-cleanup이 그 파일 삭제
# → 다음 턴에 이름 재배정 셔플이 반복되던 문제. 진짜 claude 조상을 못 찾으면 기록 안 함.
if [ -z "$NCO_SESSION_ID" ]; then
  _CK=$$
  for _i in 1 2 3 4 5 6 7 8; do
    _CK=$(ps -o ppid= -p "$_CK" 2>/dev/null | tr -d ' ')
    [ -z "$_CK" ] && break
    _CM=$(ps -o comm= -p "$_CK" 2>/dev/null)
    echo "$_CM" | grep -qE '^(claude|node)$' && NCO_SESSION_ID="$_CK"
  done
  # 조상을 못 찾으면 기록 금지 — 이 경우 NCO_NAME은 pid 파일 조회 없이 env 그대로 사용
fi

# 단일 소스 라우팅 (2026-07-03): nco-name-resolver.sh 로 NCO_NAME 위임. 값이 오면
# 아래 레거시 블록(conflict-renumber = 셔플 원인)은 skip. 부재 시에만 fallback.
_rsv="$HOME/.claude/hooks/nco-name-resolver.sh"; _rn=""
[ -f "$_rsv" ] && _rn=$(bash "$_rsv" 2>/dev/null)
if [ -n "$_rn" ]; then
  NCO_NAME="$_rn"
else
# Resolve NCO_NAME: PID 파일 조회 우선 (env 오염 방지)
# NCO_SESSION_ID가 비어있으면 pid 파일 기록 금지 (ephemeral PID 오염 방지)
_found_name=""
if [ -n "$NCO_SESSION_ID" ]; then
  for _pf in /tmp/nco-names/claude-*.pid; do
    [ -f "$_pf" ] || continue
    _rp=$(tr -d '[:space:]' < "$_pf" 2>/dev/null)
    if [ "$_rp" = "$NCO_SESSION_ID" ]; then
      _found_name=$(basename "$_pf" .pid)
      break
    fi
  done
fi
if [ -n "$_found_name" ]; then
  NCO_NAME="$_found_name"  # ground-truth: PID file match wins
elif [ -n "$NCO_SESSION_ID" ] && [ -n "$NCO_NAME" ]; then
  # inherited env — check for conflict
  _cpf="/tmp/nco-names/${NCO_NAME}.pid"
  if [ -f "$_cpf" ]; then
    _cpid=$(tr -d '[:space:]' < "$_cpf" 2>/dev/null)
    if [ "$_cpid" != "$NCO_SESSION_ID" ]; then
      # conflict: find next available slot
      _n=1; while [ -f "/tmp/nco-names/claude-${_n}.pid" ]; do _n=$((_n+1)); done
      echo "$NCO_SESSION_ID" > "/tmp/nco-names/claude-${_n}.pid" 2>/dev/null
      NCO_NAME="claude-${_n}"
    fi
  else
    # inherited name, no file yet — register it
    echo "$NCO_SESSION_ID" > "$_cpf" 2>/dev/null
  fi
elif [ -n "$NCO_SESSION_ID" ]; then
  # no env, no pid file — assign next slot
  _n=1; while [ -f "/tmp/nco-names/claude-${_n}.pid" ]; do _n=$((_n+1)); done
  echo "$NCO_SESSION_ID" > "/tmp/nco-names/claude-${_n}.pid" 2>/dev/null
  NCO_NAME="claude-${_n}"
fi
fi  # end 단일 소스 라우팅 else (레거시 fallback)
MY_NAME="${NCO_NAME:-cli}"

# NCO health check (2s max)
NCO_HEALTH=$(curl -s --connect-timeout 1 --max-time 2 http://localhost:6200/health 2>/dev/null)

if [ -n "$NCO_HEALTH" ]; then
    PROVIDER_COUNT=$(curl -s --connect-timeout 1 --max-time 2 http://localhost:6200/api/ai-providers 2>/dev/null | grep -o '"id"' | wc -l 2>/dev/null || echo "?")

    # Session state
    NCO_SESSION_DIR="/tmp/nco-sessions"
    NCO_SESSION_FILE="$NCO_SESSION_DIR/$NCO_SESSION_ID.json"

    # ─── Mesh Heartbeat ───────────────────────────
    BRANCH=$(cd "$PROJECT_DIR" 2>/dev/null && git branch --show-current 2>/dev/null || echo "unknown")
    CHANGED_LIST=$(cd "$PROJECT_DIR" 2>/dev/null && git diff --name-only 2>/dev/null | head -5 | tr '\n' ',' | sed 's/,$//')
    FILES_JSON=$(echo "$CHANGED_LIST" | python3 -c "import sys; f=sys.stdin.read().strip(); print('['+','.join(['\"'+x+'\"' for x in f.split(',') if x])+']')" 2>/dev/null || echo "[]")
    PROMPT_PREVIEW=$(echo "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('userMessage','')[:80])" 2>/dev/null || echo "")

    MESH_HB=$(curl -s --connect-timeout 1 --max-time 2 -X POST http://localhost:6200/api/mesh/heartbeat \
      -H "Content-Type: application/json" \
      -d "{\"sessionId\":\"$NCO_SESSION_ID\",\"agentId\":\"$MY_NAME\",\"pid\":$NCO_SESSION_ID,\"status\":\"coding\",\"currentWork\":\"$(echo "$PROMPT_PREVIEW" | sed 's/"/\\"/g' | sed "s/'/\\\\'/g")\",\"currentFiles\":$FILES_JSON,\"branch\":\"$BRANCH\"}" 2>/dev/null)

    # cli_sessions 레지스트리 heartbeat (2026-07-12 claude-2): 대시보드 세션 관측 배선(fire-and-forget)
    curl -s --connect-timeout 1 --max-time 2 -X POST http://localhost:6200/api/cli-session \
      -H "Content-Type: application/json" \
      -d "{\"id\":\"$NCO_SESSION_ID\",\"hostname\":\"$(hostname 2>/dev/null || echo unknown)\",\"pid\":\"$NCO_SESSION_ID\",\"projectDir\":\"$PROJECT_DIR\",\"cliVersion\":\"$MY_NAME\",\"status\":\"busy\",\"currentTask\":\"$(echo "$PROMPT_PREVIEW" | sed 's/"/\\"/g' | sed "s/'/\\\\'/g")\"}" >/dev/null 2>&1 || true

    # Extract conflicts
    MESH_CONFLICTS=$(echo "$MESH_HB" | python3 -c "import sys,json; d=json.load(sys.stdin); c=d.get('conflicts',[]); print('; '.join(c)) if c else print('')" 2>/dev/null || echo "")

    # Extract pending messages (full content for Claude to read)
    MESH_MSG_TEXT=$(echo "$MESH_HB" | python3 -c "
import sys,json
d=json.load(sys.stdin)
msgs=d.get('messages',[])
if not msgs:
    print('')
else:
    lines=[]
    for m in msgs:
        t=m.get('type','info').upper()
        f=m.get('fromAgent','?')
        c=m.get('content','')
        lines.append(f'[{t}] {f}: {c}')
    print(' | '.join(lines))
" 2>/dev/null || echo "")

    # ─── Session state (baseline 이후 변경만 카운트) ────
    NCO_USED="false"
    if [ -f "$NCO_SESSION_FILE" ]; then
        NCO_USED=$(grep -o '"nco_used": *[a-z]*' "$NCO_SESSION_FILE" 2>/dev/null | grep -o 'true\|false' || echo "false")
    fi
    BASELINE="/tmp/nco-baseline-${NCO_SESSION_ID}-files"
    if [ -f "$BASELINE" ]; then
        TOTAL_CHANGED=$(cd "$PROJECT_DIR" 2>/dev/null && git diff --name-only 2>/dev/null | sort -u | comm -23 - <(sort -u "$BASELINE") | wc -l || echo "0")
    else
        TOTAL_CHANGED=$(cd "$PROJECT_DIR" 2>/dev/null && git diff --name-only 2>/dev/null | wc -l || echo "0")
    fi
    TOTAL_CHANGED=$(echo "$TOTAL_CHANGED" | tr -d ' ')

    # ─── 에이전트 가용 상태 수집 ──────────────────
    AGENT_STATUS=$(curl -s --connect-timeout 1 --max-time 2 http://localhost:6200/api/daemons 2>/dev/null | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    online=[a['id'] for a in d.get('daemons',[]) if a.get('status')!='offline' or a.get('available')]
    busy=[a['id'] for a in d.get('daemons',[]) if a.get('status')=='working']
    parts=[]
    if online: parts.append('online:'+','.join(online[:5]))
    if busy: parts.append('busy:'+','.join(busy))
    print('|'.join(parts))
except: print('')
" 2>/dev/null || echo "")

    # ─── 프롬프트 기반 자동 오케스트레이션 힌트 ──
    PROMPT_TEXT=$(echo "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('userMessage','').lower()[:200])" 2>/dev/null || echo "")

    # 작업 유형 자동 감지 (task당 1회만 — workflow_inject가 이미 권고했으면 억제)
    ORCH_HINT=""
    if [ "$SUPPRESS_STRONG" -eq 0 ]; then
        if echo "$PROMPT_TEXT" | grep -qE '(구현|만들어|추가|implement|create|add|build)'; then
            if [ "$TOTAL_CHANGED" -ge 5 ]; then
                ORCH_HINT="AUTO_COMMANDER: 대규모 구현 감지 → nco_commander 사용 권장"
            else
                ORCH_HINT="AUTO_PARALLEL: 구현 작업 감지 → nco_parallel([codex,cursor-agent]) 권장"
            fi
        elif echo "$PROMPT_TEXT" | grep -qE '(리뷰|검토|review|check|audit|보안|security)'; then
            ORCH_HINT="AUTO_REVIEW: cursor-agent + ollama 병렬 리뷰 권장"
        elif echo "$PROMPT_TEXT" | grep -qE '(설계|아키텍처|design|architect|구조|structure)'; then
            ORCH_HINT="AUTO_DESIGN: opencode + agy 병렬 설계 검토 권장"
        elif echo "$PROMPT_TEXT" | grep -qE '(테스트|test|검증|verify|validate)'; then
            ORCH_HINT="AUTO_TEST: codex(생성) + ollama(검증) 병렬 권장"
        elif echo "$PROMPT_TEXT" | grep -qE '(리팩토링|refactor|정리|cleanup|최적화|optimize)'; then
            ORCH_HINT="AUTO_REFACTOR: opencode 분석 → codex 적용 파이프라인 권장"
        fi
    fi

    # NCO usage hint — task당 1회만 강한 힌트. 그 외는 NCO_READY.
    # state machine은 nco-workflow-inject.sh가 관리, 여기선 읽기만 함.
    TRACK_F="/tmp/nco-track-${NCO_SESSION_ID}.json"
    TASK_SEQ_V=0; TASK_STARTED_V=-1; TASK_WARNED_V=-1
    if [ -f "$TRACK_F" ]; then
        read -r TASK_SEQ_V TASK_STARTED_V TASK_WARNED_V <<< "$(python3 -c "
import json
try:
    d=json.load(open('$TRACK_F'))
    print(d.get('task_seq',0), d.get('task_started_seq',-1), d.get('task_warned_seq',-1))
except: print('0 -1 -1')
" 2>/dev/null)"
    fi
    # 이미 이번 task에 권고/작업 시작 → 강한 힌트 억제
    SUPPRESS_STRONG=0
    [ "$TASK_WARNED_V" = "$TASK_SEQ_V" ] && SUPPRESS_STRONG=1
    [ "$TASK_STARTED_V" = "$TASK_SEQ_V" ] && SUPPRESS_STRONG=1

    if [ "$NCO_USED" = "true" ]; then
        NCO_HINT="NCO_ACTIVE"
    elif [ "$SUPPRESS_STRONG" -eq 1 ]; then
        NCO_HINT="NCO_READY"
    elif [ "$TOTAL_CHANGED" -ge 5 ]; then
        NCO_HINT="MUST_ORCHESTRATE: baseline 이후 변경 ${TOTAL_CHANGED}개. 작업 시작 전 nco_parallel 위임 고려."
    elif [ "$TOTAL_CHANGED" -ge 3 ]; then
        NCO_HINT="SHOULD_ORCHESTRATE: baseline 이후 변경 ${TOTAL_CHANGED}개. cursor-agent 리뷰 권장."
    else
        NCO_HINT="NCO_READY"
    fi

    # ─── Build context string ─────────────────────
    CONTEXT="[NCO:${MY_NAME}] Commander모드. 에이전트(${PROVIDER_COUNT}개) 대기중. 변경파일:${TOTAL_CHANGED}. ${NCO_HINT}"

    if [ -n "$ORCH_HINT" ]; then
        CONTEXT="${CONTEXT} ${ORCH_HINT}."
    fi
    if [ -n "$AGENT_STATUS" ]; then
        CONTEXT="${CONTEXT} AGENTS:${AGENT_STATUS}."
    fi
    # Append mesh info
    if [ -n "$MESH_CONFLICTS" ]; then
        CONTEXT="${CONTEXT} CONFLICT: ${MESH_CONFLICTS}."
    fi
    if [ -n "$MESH_MSG_TEXT" ]; then
        CONTEXT="${CONTEXT} MESH_MSG: ${MESH_MSG_TEXT}"
    fi

    # ─── Bootstrap: 첫 prompt에 [BOOTSTRAP] 라벨 주입 (CLAUDE.md "Mesh 프롬프트 주입" 절 trigger) ───
    BOOTSTRAP_FLAG="/tmp/nco-bootstrap-${NCO_SESSION_ID}"
    if [ -f "$BOOTSTRAP_FLAG" ]; then
        _BS_NEED=""
        # inter-session 이름 = <디바이스기기명>-<claude-N> (mesh/NCO 이름 NCO_NAME은 claude-N 그대로 유지)
        # hostname 소문자화 + 비-[a-z0-9] → '-' + .local 제거 + 40자 cap(device쪽만 자르고 claude-N 보존)
        _ISDEV=$(hostname 2>/dev/null | tr '[:upper:]' '[:lower:]' | sed -E 's/\.local$//; s/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')
        [ -z "$_ISDEV" ] && _ISDEV="dev"
        _ISSUF="-${MY_NAME}"; _ISDEV="${_ISDEV:0:$((40-${#_ISSUF}))}"; _ISDEV="${_ISDEV%-}"
        _ISNAME="${_ISDEV}${_ISSUF}"
        pgrep -f "client.py.*--name ${_ISNAME}" >/dev/null 2>&1 || _BS_NEED="${_BS_NEED}inter-session "
        [ -f "/tmp/nco-inbox-${NCO_SESSION_ID}/monitor.lock" ] || _BS_NEED="${_BS_NEED}mesh-receiver"
        if [ -n "$_BS_NEED" ]; then
            CONTEXT="${CONTEXT} [BOOTSTRAP] 실시간 채널 미활성(${_BS_NEED}). 본 응답의 어떤 작업보다 먼저 다음을 호출하라: (1) inter-session SKILL invoke(connect, name=${_ISNAME}) — 이름은 반드시 ${_ISNAME}(=<디바이스기기명>-<claude-N>) 사용. 동명 클라이언트가 이미 있으면 flock이 자동 차단; (2) mesh-receiver는 plugin SKILL이 아닌 Monitor 도구로 직접 spawn — Monitor(command='INTER_MODE=monitor NCO_NAME=${MY_NAME} NCO_SESSION_ID=${NCO_SESSION_ID} bash \$HOME/.claude/hooks/mesh-inbox-poller.sh ${NCO_SESSION_ID} ${MY_NAME} 5', description='mesh DM watcher (${MY_NAME})', persistent=true, timeout_ms=3600000). 둘 다 idempotent — 이미 활성이면 자동 skip. Monitor 호출이 없으면 idle 상태에서 mesh DM 자동 inject가 영영 작동 안 한다."
        fi
        rm -f "$BOOTSTRAP_FLAG" 2>/dev/null
    fi

    # ─── Inbox poller queue — drain unread NEW DM lines ───
    # Queue is written by mesh-inbox-poller.sh (session-start daemon).
    # Read-offset tracks where we left off, so each line is shown exactly once.
    # Expansion rule (2026-05-26): task/direct messages get full body; info/broadcast
    # keep 160-char preview. >5건 → newest 3 full + count of remainder.
    INBOX_QUEUE="/tmp/nco-inbox-${NCO_SESSION_ID}/queue.log"
    INBOX_OFFSET="/tmp/nco-inbox-${NCO_SESSION_ID}/read.offset"
    if [ -f "$INBOX_QUEUE" ]; then
        _SIZE=$(stat -c %s "$INBOX_QUEUE" 2>/dev/null || stat -f %z "$INBOX_QUEUE" 2>/dev/null || echo 0)
        _OFFSET=$(cat "$INBOX_OFFSET" 2>/dev/null || echo 0)
        # Guard: empty/garbage offset → 0; if queue shrunk (rotated/cleared), reset
        case "$_OFFSET" in ''|*[!0-9]*) _OFFSET=0 ;; esac
        if [ "$_OFFSET" -gt "$_SIZE" ]; then _OFFSET=0; fi
        if [ "$_SIZE" -gt "$_OFFSET" ]; then
            INBOX_RAW=$(tail -c "+$((_OFFSET + 1))" "$INBOX_QUEUE" 2>/dev/null \
                | grep -E '^\[NEW ' | head -10)
            INBOX_BLOCK=$(INBOX_RAW="$INBOX_RAW" python3 <<'PYEOF'
import os, re, sys
raw = os.environ.get('INBOX_RAW','').rstrip('\n')
if not raw:
    sys.exit(0)
lines = raw.split('\n')
# Parse new format: [NEW <type>:<scope>] <fa>(<fs>) -> <content>
# Legacy format:    [NEW <type>] <fa>(<fs>) -> <content>
pat = re.compile(r'^\[NEW ([^:\]]+)(?::([^\]]*))?\] ([^()]+)\(([^)]+)\) -> (.*)$')
parsed = []
for ln in lines:
    mm = pat.match(ln)
    if not mm:
        continue
    t  = mm.group(1).strip()
    sc = (mm.group(2) or '').strip()
    fa = mm.group(3).strip()
    fs = mm.group(4).strip()
    body = mm.group(5).replace('\\n', '\n')  # un-escape poller newlines
    parsed.append((t, sc, fa, fs, body))
if not parsed:
    sys.exit(0)
BACKTICK = chr(96)
FENCE = BACKTICK * 3
def sanitize(s, cap):
    # Neutralize markers that could confuse LLM into treating data as instructions.
    s = s.replace(FENCE, BACKTICK + ' ' + BACKTICK + ' ' + BACKTICK)
    s = re.sub(r'(?i)<\s*/?\s*(system-reminder|assistant|user|system)\b', r'<&\1', s)
    if len(s) > cap:
        s = s[:cap] + '…(truncated)'
    return s
total = len(parsed)
# Decide which messages get FULL body (task or scope=direct).
full_idx = set()
for i,(t,sc,fa,fs,body) in enumerate(parsed):
    if t == 'task' or sc == 'direct':
        full_idx.add(i)
# Token-explosion guard: if total>5, keep only newest 3 as full.
if total > 5 and len(full_idx) > 3:
    full_idx = set(sorted(full_idx)[-3:])
out_lines = []
for i,(t,sc,fa,fs,body) in enumerate(parsed):
    label = '[' + t + ':' + (sc or '-') + ']'
    if i in full_idx:
        body_clean = sanitize(body, 800)
        out_lines.append('  ' + label + ' ' + fa + '(' + fs + '):')
        for ln in body_clean.split('\n')[:30]:
            out_lines.append('    ' + ln)
    else:
        body_clean = sanitize(body.replace('\n',' '), 160)
        out_lines.append('  · ' + label + ' ' + fa + '(' + fs + ') — ' + body_clean)
print('INBOX:' + str(total) + '건')
print('\n'.join(out_lines))
PYEOF
)
            if [ -n "$INBOX_BLOCK" ]; then
                CONTEXT="${CONTEXT}
${INBOX_BLOCK}"
            fi
            echo "$_SIZE" > "$INBOX_OFFSET"
        fi
    fi

    # ── 부드러운 유도 (2026-07-12 claude-2): 작업유형별 팀/회사 위임 권고 (차단 아님, 키워드 매칭 시에만) ──
    _PL=$(echo "$PROMPT_PREVIEW" | tr '[:upper:]' '[:lower:]')
    _NUDGE=""
    case "$_PL" in
      *구현*|*추가*|*만들*|*개발*|*리팩*|*feature*|*implement*)
        _NUDGE="[유도] 구현성 작업 — nco_task codex 또는 nco_parallel[codex,cursor-agent] 위임 권장(대형이면 nco_commander)." ;;
      *버그*|*고쳐*|*에러*|*오류*|*fix*|*bug*)
        _NUDGE="[유도] 버그수정 — nco_task codex 위임 + nco_task ollama 검증 권장." ;;
      *리뷰*|*검토*|*보안*|*취약*|*review*|*security*)
        _NUDGE="[유도] 리뷰/보안 — nco_task cursor-agent(read-only 명시) 권장." ;;
      *설계*|*아키텍*|*구조*|*design*|*architect*)
        _NUDGE="[유도] 설계 — nco_task opencode 또는 nco_discussion 권장." ;;
    esac
    [ -n "$_NUDGE" ] && CONTEXT="${CONTEXT}
${_NUDGE}"

    cat <<ENDJSON
{
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": "$( echo "$CONTEXT" | sed 's/"/\\"/g' | tr '\n' ' ' )"
  }
}
ENDJSON
else
    cat <<ENDJSON
{
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": "[NCO:${MY_NAME}] Offline. Run /nco-start if needed."
  }
}
ENDJSON
fi

exit 0
