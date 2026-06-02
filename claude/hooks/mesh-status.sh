#!/bin/bash
# mesh-status.sh — 본 세션의 mesh-receiver 연결 상태 점검
# inter-session list.py --self 대응. SKILL.md 'status' 서브커맨드의 백엔드.

set -u

SID="${NCO_SESSION_ID:-unknown}"
NAME="${NCO_NAME:-unknown}"
INBOX="/tmp/nco-inbox-${SID}"

echo "name=${NAME}"
echo "session_id=${SID}"

# Monitor 모드 vs daemon 모드 구분 — stdout fd1을 검사한다:
#   - Monitor 도구 spawn → fd1=socket/pipe (Notification 채널)
#   - daemon nohup spawn → fd1=regular file (queue.log)
# Linux: /proc/<pid>/fd/1 readlink
# macOS: lsof -p <pid> -d 1 (fallback)
if [ -f "$INBOX/monitor.lock" ]; then
    LOCK_PID=$(cat "$INBOX/monitor.lock" 2>/dev/null | tr -d '[:space:]')
    if [ -n "$LOCK_PID" ] && kill -0 "$LOCK_PID" 2>/dev/null; then
        STDOUT_TARGET=$(readlink "/proc/${LOCK_PID}/fd/1" 2>/dev/null)
        if [ -z "$STDOUT_TARGET" ] && command -v lsof >/dev/null 2>&1; then
            # macOS fallback: TYPE 컬럼이 PIPE/IPv4/IPv6/unix이면 socket-like
            _LSOF_LINE=$(lsof -p "$LOCK_PID" -d 1 -Fn -Ft 2>/dev/null | tail -2)
            _TYPE=$(echo "$_LSOF_LINE" | grep '^t' | sed 's/^t//')
            _NAME=$(echo "$_LSOF_LINE" | grep '^n' | sed 's/^n//')
            case "$_TYPE" in
                PIPE|FIFO|unix|IPv4|IPv6|systm) STDOUT_TARGET="socket:${_NAME}" ;;
                REG|VREG) STDOUT_TARGET="$_NAME" ;;
                *) STDOUT_TARGET="${_TYPE}:${_NAME}" ;;
            esac
        fi
        case "$STDOUT_TARGET" in
            socket:*|pipe:*)
                echo "mode=monitor (real-time Notification 채널 활성)"
                ;;
            *queue.log)
                echo "mode=daemon-with-lock (lock 존재하나 stdout이 queue.log — idle wake-up 불가)"
                ;;
            *)
                echo "mode=unknown (stdout=${STDOUT_TARGET:-?})"
                ;;
        esac
        PPID_INFO=$(ps -o ppid= -p "$LOCK_PID" 2>/dev/null | tr -d ' ')
        echo "poller_pid=${LOCK_PID}"
        echo "poller_ppid=${PPID_INFO:-?}"
        echo "stdout_fd=${STDOUT_TARGET:-?}"
    else
        echo "mode=stale (lock orphaned, pid=${LOCK_PID:-?} dead)"
    fi
else
    # poller.pid는 있는데 monitor.lock 없으면 daemon 모드 (INTER_MODE=daemon)
    if [ -f "$INBOX/poller.pid" ]; then
        POLLER_PID=$(cat "$INBOX/poller.pid" 2>/dev/null | tr -d '[:space:]')
        if [ -n "$POLLER_PID" ] && kill -0 "$POLLER_PID" 2>/dev/null; then
            echo "mode=daemon (next-prompt drain only — idle wake-up 불가)"
            echo "poller_pid=${POLLER_PID}"
        else
            echo "mode=offline"
        fi
    else
        echo "mode=offline"
    fi
fi

# queue.log 통계
if [ -f "$INBOX/queue.log" ]; then
    QUEUE_SIZE=$(stat -c %s "$INBOX/queue.log" 2>/dev/null || echo 0)
    QUEUE_LINES=$(wc -l < "$INBOX/queue.log" 2>/dev/null || echo 0)
    READ_OFFSET=$(cat "$INBOX/read.offset" 2>/dev/null || echo 0)
    case "$READ_OFFSET" in ''|*[!0-9]*) READ_OFFSET=0 ;; esac
    UNREAD=$((QUEUE_SIZE - READ_OFFSET))
    [ "$UNREAD" -lt 0 ] && UNREAD=0
    echo "queue_size=${QUEUE_SIZE}B"
    echo "queue_lines=${QUEUE_LINES}"
    echo "read_offset=${READ_OFFSET}"
    echo "unread_bytes=${UNREAD}"
fi

# mesh API 등록 상태
MESH_REGISTERED=$(curl -s --max-time 2 http://localhost:6200/api/mesh/sessions 2>/dev/null \
    | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    for s in d.get('sessions',[]):
        if s.get('agentId')=='${NAME}' and str(s.get('sessionId',''))=='${SID}':
            print('yes', s.get('status','?'))
            break
    else:
        print('no')
except: print('error')
" 2>/dev/null)
echo "mesh_registered=${MESH_REGISTERED}"
