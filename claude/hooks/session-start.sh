#!/bin/bash
echo "[$(date +%H:%M:%S)] HOOK_START session-start.sh" >> /tmp/claude-hook-trace.log
# SessionStart Hook - NCO context auto-load + CLI Mesh registration
# Usage: NCO_NAME=nova claude   ← 이름으로 mesh에 자동 등록

CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
MAGENTA='\033[35m'
BOLD='\033[1m'
NC='\033[0m'

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-/Users/nova-ai/project/nco}"
cd "$PROJECT_DIR" 2>/dev/null || exit 0

# ========================================
# Find the actual Claude Code PID — topmost claude/node 조상 탐색 (no-break)
# 버그 수정 2026-07-03: 가장 가까운 조상(break, 5단계)이 아니라 가장 위 조상(no-break, 8단계).
# 근거: 가까운 조상만 쓰면 nco-statusline.sh(8단계 topmost)와 다른 PID 키 → 두 훅이
# 같은 pid 파일을 서로 다른 PID로 갱신 → stale-cleanup이 번갈아 삭제 → 이름 셔플.
# PPID/$$ fallback 제거: ephemeral 셸 PID 기록 → 즉시 stale → 다음 턴 이름 재배정.
# ========================================
_CLAUDE_PID=""
_CHECK_PID=$$
for _i in 1 2 3 4 5 6 7 8; do
    _CHECK_PID=$(ps -o ppid= -p "$_CHECK_PID" 2>/dev/null | tr -d ' ')
    [ -z "$_CHECK_PID" ] && break
    _CMD=$(ps -o comm= -p "$_CHECK_PID" 2>/dev/null)
    echo "$_CMD" | grep -qE '^(claude|node)$' && _CLAUDE_PID="$_CHECK_PID"
done
# 조상을 못 찾으면 빈 문자열 — pid 파일 기록 금지 (이하 if [ -n "$NCO_SESSION_ID" ] 가드)
NCO_SESSION_ID="$_CLAUDE_PID"

# ========================================
# NCO_NAME — CLI Identity (PID-file based reservation)
# ========================================
# Priority: NCO_NAME env var > /tmp/nco-names/ PID-file reservation
NCO_NAMES_DIR="/tmp/nco-names"
mkdir -p "$NCO_NAMES_DIR" 2>/dev/null

if [ -z "$NCO_NAME" ] && [ -n "$NCO_SESSION_ID" ]; then
    # NCO_SESSION_ID가 비어있으면 pid 파일 기록 금지 (ephemeral PID 오염 방지)
    # Atomic name reservation using mkdir lock (macOS-compatible)
    _LOCK_DIR="$NCO_NAMES_DIR/.lockdir"
    _LOCK_WAIT=0
    while ! mkdir "$_LOCK_DIR" 2>/dev/null; do
        sleep 0.1
        _LOCK_WAIT=$((_LOCK_WAIT + 1))
        [ "$_LOCK_WAIT" -gt 50 ] && rm -rf "$_LOCK_DIR" && break  # 5s timeout
    done

    # 1. Clean dead PID files
    for _pidfile in "$NCO_NAMES_DIR"/claude-*.pid; do
        [ -f "$_pidfile" ] || continue
        _rpid=$(cat "$_pidfile" 2>/dev/null | tr -d '[:space:]')
        [ -z "$_rpid" ] && continue  # skip empty (mid-write protection)
        if ! ps -p "$_rpid" >/dev/null 2>&1; then
            rm -f "$_pidfile"
        fi
    done

    # 2. Check if we already have a name (reconnecting session)
    for _pidfile in "$NCO_NAMES_DIR"/claude-*.pid; do
        [ -f "$_pidfile" ] || continue
        _rpid=$(cat "$_pidfile" 2>/dev/null | tr -d '[:space:]')
        if [ "$_rpid" = "$NCO_SESSION_ID" ]; then
            _existing=$(basename "$_pidfile" .pid)
            echo "$_existing" > "$NCO_NAMES_DIR/.last-assigned"
            rmdir "$_LOCK_DIR" 2>/dev/null
            NCO_NAME="$_existing"
            break
        fi
    done

    if [ -z "$NCO_NAME" ]; then
        # 3. Find lowest available number
        _NUM=1
        while [ -f "$NCO_NAMES_DIR/claude-${_NUM}.pid" ]; do
            _NUM=$((_NUM + 1))
        done

        # 4. Reserve it (atomic write: tmp→mv prevents empty-file stale deletion)
        _PID_TMP="$NCO_NAMES_DIR/claude-${_NUM}.pid.tmp.$$"
        printf '%s\n' "$NCO_SESSION_ID" > "$_PID_TMP" && mv "$_PID_TMP" "$NCO_NAMES_DIR/claude-${_NUM}.pid"
        echo "claude-${_NUM}" > "$NCO_NAMES_DIR/.last-assigned"
        NCO_NAME="claude-${_NUM}"
    fi

    rmdir "$_LOCK_DIR" 2>/dev/null
fi

# ========================================
# Persist NCO_NAME via CLAUDE_ENV_FILE
# ========================================
if [ -n "$CLAUDE_ENV_FILE" ]; then
    echo "export NCO_NAME=\"$NCO_NAME\"" >> "$CLAUDE_ENV_FILE"
    echo "export NCO_SESSION_ID=\"$NCO_SESSION_ID\"" >> "$CLAUDE_ENV_FILE"
    # inter-session plugin: client.py reads INTER_SESSION_NAME env to skip
    # auto_name_from_cwd() fallback (which picks first claude-*.pid or cwd basename)
    echo "export INTER_SESSION_NAME=\"$NCO_NAME\"" >> "$CLAUDE_ENV_FILE"
fi

# ========================================
# Session tracking system
# ========================================
NCO_SESSION_DIR="/tmp/nco-sessions"
mkdir -p "$NCO_SESSION_DIR" 2>/dev/null

# Clean sessions older than 24h
find "$NCO_SESSION_DIR" -name "*.json" -mmin +1440 -delete 2>/dev/null

# NCO_SESSION_ID가 비어있으면 세션 파일 생성 금지 (경로 "/tmp/nco-sessions/.json" + invalid JSON 방지)
if [ -n "$NCO_SESSION_ID" ]; then
    NCO_SESSION_FILE="$NCO_SESSION_DIR/$NCO_SESSION_ID.json"
    cat > "$NCO_SESSION_FILE" <<SESSIONJSON
{
  "session_id": "$NCO_SESSION_ID",
  "nco_name": "$NCO_NAME",
  "pid": $NCO_SESSION_ID,
  "started_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "nco_used": false,
  "nco_commands": [],
  "changed_files": 0,
  "last_activity": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
SESSIONJSON
fi

# ========================================
# Header
# ========================================
echo -e "${CYAN}═══════════════════════════════════════${NC}" >&2
echo -e "${CYAN}  NCO Session — ${BOLD}${YELLOW}${NCO_NAME}${NC}${CYAN}              ${NC}" >&2
echo -e "${CYAN}═══════════════════════════════════════${NC}" >&2

# ========================================
# TIER1 rules
# ========================================
echo "" >&2
echo -e "${GREEN}TIER1 Rules:${NC}" >&2
echo -e "  1. Trust > Competence" >&2
echo -e "  2. No report without source" >&2
echo -e "  3. No completion without verification" >&2
echo -e "  4. No fake workers" >&2
echo -e "  5. VRAM/API verification required" >&2
echo "" >&2

# Git status
echo -e "${YELLOW}Git Status:${NC}" >&2
git status --short 2>/dev/null | head -10 >&2

# Recent commits
echo "" >&2
echo -e "${YELLOW}Recent Commits:${NC}" >&2
git log --oneline -5 2>/dev/null >&2

# @.claude tagged learnings
LEARNINGS=$(git log --oneline -20 --grep="@.claude" 2>/dev/null)
if [ -n "$LEARNINGS" ]; then
    echo "" >&2
    echo -e "${GREEN}Learnings (@.claude):${NC}" >&2
    echo "$LEARNINGS" >&2
fi

# TODO file
if [ -f ".llm/todo.md" ]; then
    echo "" >&2
    echo -e "${YELLOW}Current Tasks:${NC}" >&2
    cat .llm/todo.md >&2
fi

# ========================================
# NCO + MLX status
# ========================================
NCO_HEALTH=$(curl -s --connect-timeout 1 --max-time 2 http://localhost:6200/health 2>/dev/null)
if [ -n "$NCO_HEALTH" ]; then
    echo "" >&2
    echo -e "${GREEN}NCO Engine: Online${NC}" >&2
else
    echo "" >&2
    echo -e "${YELLOW}NCO Engine: Offline${NC}" >&2
fi

MLX_HEALTH=$(curl -s --connect-timeout 1 --max-time 2 http://localhost:8000/health 2>/dev/null)
if [ -n "$MLX_HEALTH" ]; then
    echo -e "${GREEN}MLX: Online${NC}" >&2
else
    echo -e "${YELLOW}MLX: Offline${NC}" >&2
fi

# ========================================
# Advisor 모델 설정 표시
# ========================================
SETTINGS_FILE="$HOME/.claude/settings.json"
ADVISOR_MODEL=""
MAIN_MODEL=""
if [ -f "$SETTINGS_FILE" ]; then
    ADVISOR_MODEL=$(python3 -c "
import json
try:
    d = json.load(open('$SETTINGS_FILE'))
    print(d.get('advisorModel', ''))
except: print('')
" 2>/dev/null)
    MAIN_MODEL=$(python3 -c "
import json
try:
    d = json.load(open('$SETTINGS_FILE'))
    print(d.get('model', 'sonnet'))
except: print('sonnet')
" 2>/dev/null)
fi
echo "" >&2
if [ -n "$ADVISOR_MODEL" ]; then
    echo -e "${MAGENTA}Advisor: ${BOLD}${ADVISOR_MODEL}${NC}${MAGENTA} (메인: ${MAIN_MODEL}) — 복잡·설계 작업 전 /advisor 호출 권장${NC}" >&2
    echo -e "${MAGENTA}  사용: 복잡한 구현 전 | Grade C/D 발생 시 | 아키텍처 결정 시${NC}" >&2
else
    echo -e "${YELLOW}Advisor: 미설정 — settings.json에 advisorModel 추가 권장${NC}" >&2
fi

# ========================================
# CLI Mesh — Register with NCO_NAME
# ========================================
BRANCH=$(git branch --show-current 2>/dev/null || echo "unknown")

if [ -n "$NCO_HEALTH" ]; then
    MESH_RESULT=$(curl -s --connect-timeout 1 --max-time 2 -X POST http://localhost:6200/api/mesh/heartbeat \
      -H "Content-Type: application/json" \
      -d "{\"sessionId\":\"$NCO_SESSION_ID\",\"agentId\":\"$NCO_NAME\",\"pid\":$NCO_SESSION_ID,\"status\":\"idle\",\"currentWork\":\"세션 시작\",\"branch\":\"$BRANCH\"}" 2>/dev/null)

    # Show active mesh sessions
    MESH_SESSIONS=$(curl -s --connect-timeout 1 --max-time 2 http://localhost:6200/api/mesh/sessions 2>/dev/null)
    MESH_COUNT=$(echo "$MESH_SESSIONS" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('count',0))" 2>/dev/null || echo "0")

    echo "" >&2
    echo -e "${MAGENTA}CLI Mesh: ${NCO_NAME} registered (${MESH_COUNT} online)${NC}" >&2

    if [ "$MESH_COUNT" -gt 1 ]; then
        echo "$MESH_SESSIONS" | python3 -c "
import sys,json
d=json.load(sys.stdin)
for s in d.get('sessions',[]):
    name = s.get('agentId','?')
    status = s.get('status','?')
    work = s.get('currentWork','') or 'idle'
    print(f'  • {name} ({status}): {work}')
" 2>/dev/null >&2
    fi
fi

# ========================================
# Mesh Inbox — zombie cleanup + bootstrap
# Daemon spawn은 NCO_DISABLE_MESH_DAEMON=0 일 때만 활성 (기본 비활성).
# canonical 경로: LLM이 [BOOTSTRAP] 라벨을 보고 Monitor 도구로 poller를 spawn하여
# stdout이 conversation notification으로 라우팅되도록 한다 (CLAUDE.md "Mesh
# 프롬프트 주입" 절 참조).
# ========================================
cleanup_dead_pollers() {
    # /tmp/nco-inbox-<sid>/ 디렉터리를 순회하며 좀비 inbox만 정리.
    # 안전 조건 (cursor-agent 리뷰 A — 2026-05-26):
    #   - 현재 세션 NCO_SESSION_ID 대응 디렉터리는 절대 건드리지 않음
    #   - sid 자체가 살아 있는 PID이면 (kill -0 ok) 보존 (CC 프로세스일 가능성)
    #   - poller.pid의 프로세스가 살아 있고 sid도 살아 있으면 보존
    #   - 위 조건 모두 실패한 경우에만 좀비로 판정하여 rm
    # P1-C (2026-05-26): fail-safe — NCO_SESSION_ID가 빈 값이면 가드1이 무력화되어
    # 모든 inbox를 좀비로 오판할 수 있음. 빈 값일 때는 정리 자체를 스킵.
    [ -z "${NCO_SESSION_ID:-}" ] && return 0
    local d pid_file pid sid lock_file lpid
    shopt -s nullglob 2>/dev/null
    for d in /tmp/nco-inbox-*/; do
        [ -d "$d" ] || continue
        sid=$(basename "$d" | sed 's/^nco-inbox-//')
        # 안전 가드 1: 현재 세션은 건드리지 않음
        if [ -n "${NCO_SESSION_ID:-}" ] && [ "$sid" = "$NCO_SESSION_ID" ]; then
            continue
        fi
        # 안전 가드 2: sid 자체가 살아 있는 PID(CC 세션)이면 보존
        if kill -0 "$sid" 2>/dev/null; then
            continue
        fi
        # P1-D (2026-05-26): monitor.lock holder가 살아있으면 보존.
        # claude-4 결함 B: 기존엔 poller.pid만 검증해서 lock holder만 살아있는
        # 모순 상태에서 rm -rf로 lock holder 작동 손상 가능.
        lock_file="$d/monitor.lock"
        if [ -f "$lock_file" ]; then
            lpid=$(cat "$lock_file" 2>/dev/null | tr -d '[:space:]')
            if [ -n "$lpid" ] && kill -0 "$lpid" 2>/dev/null; then
                continue
            fi
        fi
        # 안전 가드 3: poller가 살아 있으면 보존 (외부 관리 가능성)
        pid_file="$d/poller.pid"
        if [ -f "$pid_file" ]; then
            pid=$(cat "$pid_file" 2>/dev/null | tr -d '[:space:]')
            if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
                # sid는 죽었지만 poller는 살아 있는 모순 상태 → 명시적 좀비. kill 후 rm.
                kill "$pid" 2>/dev/null
            fi
        fi
        # 위 3가지 가드 모두 통과 = 진짜 좀비
        rm -rf "$d" 2>/dev/null
    done
    shopt -u nullglob 2>/dev/null
}

if [ -n "$NCO_HEALTH" ]; then
    cleanup_dead_pollers
fi

if [ -n "$NCO_HEALTH" ] && [ "${NCO_DISABLE_MESH_DAEMON:-1}" = "0" ]; then
    POLLER="$HOME/.claude/hooks/mesh-inbox-poller.sh"
    if [ -x "$POLLER" ]; then
        INBOX_DIR="/tmp/nco-inbox-${NCO_SESSION_ID}"
        mkdir -p "$INBOX_DIR" 2>/dev/null
        # Single-instance: only launch if not already running for this PID
        _RUNNING_PID=$(cat "$INBOX_DIR/poller.pid" 2>/dev/null | tr -d '[:space:]')
        if [ -f "$INBOX_DIR/monitor.lock" ]; then
            echo -e "${MAGENTA}Mesh Inbox: monitor active (mesh-receiver plugin) — daemon skipped${NC}" >&2
        elif [ -z "$_RUNNING_PID" ] || ! ps -p "$_RUNNING_PID" >/dev/null 2>&1; then
            # Mode selection: prefer monitor (real-time wake-up) when mesh-receiver
            # plugin is installed; otherwise daemon (next-prompt backfill via
            # user-prompt-nco-context.sh already covers this).
            _MESH_RECV_A="$HOME/.claude/plugins/marketplaces/mesh-receiver"
            _MESH_RECV_B="$HOME/.claude/plugins/cache/inter-session/inter-session"
            if [ -d "$_MESH_RECV_A" ] || [ -d "$_MESH_RECV_B" ]; then
                INTER_MODE=monitor nohup bash "$POLLER" "$NCO_SESSION_ID" "$NCO_NAME" 5 \
                    >> "$INBOX_DIR/queue.log" 2>/dev/null &
                disown 2>/dev/null
                # Bounded wait (≤3s) for the poller to claim monitor.lock.
                for _i in 1 2 3; do
                    [ -f "$INBOX_DIR/monitor.lock" ] && break
                    sleep 1
                done
                if [ -f "$INBOX_DIR/monitor.lock" ]; then
                    echo -e "${MAGENTA}Mesh Inbox: monitor mode active → $INBOX_DIR/queue.log${NC}" >&2
                else
                    # Monitor spawn didn't take the lock — most likely the poller
                    # exited (no NCO_HEALTH inside spawn, redis miss, etc.).
                    # Fall back to daemon so backfill keeps working.
                    _CHK=$(cat "$INBOX_DIR/poller.pid" 2>/dev/null | tr -d '[:space:]')
                    if [ -z "$_CHK" ] || ! ps -p "$_CHK" >/dev/null 2>&1; then
                        INTER_MODE=daemon nohup bash "$POLLER" "$NCO_SESSION_ID" "$NCO_NAME" 5 \
                            >> "$INBOX_DIR/queue.log" 2>/dev/null &
                        disown 2>/dev/null
                        echo -e "${MAGENTA}Mesh Inbox: monitor unavailable → daemon fallback${NC}" >&2
                    else
                        echo -e "${MAGENTA}Mesh Inbox: poller running (pid=$_CHK)${NC}" >&2
                    fi
                fi
            else
                INTER_MODE=daemon nohup bash "$POLLER" "$NCO_SESSION_ID" "$NCO_NAME" 5 \
                    >> "$INBOX_DIR/queue.log" 2>/dev/null &
                disown 2>/dev/null
                echo -e "${MAGENTA}Mesh Inbox: poller daemon launched → $INBOX_DIR/queue.log${NC}" >&2
            fi
        else
            echo -e "${MAGENTA}Mesh Inbox: poller already running (pid=$_RUNNING_PID)${NC}" >&2
        fi
    fi
fi

# Bootstrap marker — daemon 활성/비활성과 무관하게 항상 평가.
# inter-session client 또는 mesh-receiver monitor.lock 중 하나라도 부재하면
# 다음 user-prompt-nco-context.sh가 [BOOTSTRAP] 라벨을 주입해 LLM이 Monitor
# 도구로 자가 기동하도록 유도한다 (CLAUDE.md "Mesh 프롬프트 주입" 절).
if [ -n "$NCO_HEALTH" ]; then
    _BS_INBOX_DIR="/tmp/nco-inbox-${NCO_SESSION_ID:-unknown}"
    _IS_RUNNING=""
    pgrep -f "client.py.*--name ${NCO_NAME:-_unset_}" >/dev/null 2>&1 && _IS_RUNNING="yes"
    _MESH_RUNNING=""
    [ -f "$_BS_INBOX_DIR/monitor.lock" ] && _MESH_RUNNING="yes"
    if [ -z "$_IS_RUNNING" ] || [ -z "$_MESH_RUNNING" ]; then
        touch "/tmp/nco-bootstrap-${NCO_SESSION_ID}" 2>/dev/null
    fi
fi

echo "" >&2
echo -e "${GREEN}Session: ${NCO_NAME} (${NCO_SESSION_FILE})${NC}" >&2
echo -e "${CYAN}═══════════════════════════════════════${NC}" >&2
