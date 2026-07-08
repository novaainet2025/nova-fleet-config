#!/bin/bash
# NCO 재귀보호: NCO가 스폰한 서브프로세스 claude에서는 훅 무동작 (2026-07-08, 76s 훅스택+BOOTSTRAP 오염 T1)
[ "${NCO_HOOK_DISABLED:-0}" = "1" ] && exit 0
# Mesh 백그라운드 하트비트 데몬
# mesh-register.sh 에서 nohup으로 실행됨
# 세션 PID가 살아있는 한 30초마다 heartbeat 전송

SESSION_ID="$1"   # Claude Code PID
AGENT_NAME="$2"   # claude-N
NCO_URL="${3:-http://localhost:6200}"
INTERVAL=30        # 30초마다

DAEMON_PID_FILE="/tmp/mesh-heartbeat-daemon-${SESSION_ID}.pid"
LOG_FILE="/tmp/mesh-heartbeat-daemon-${SESSION_ID}.log"

# PID 파일 등록
echo $$ > "$DAEMON_PID_FILE"

log() {
    echo "[$(date '+%H:%M:%S')] $1" >> "$LOG_FILE" 2>/dev/null
}

log "데몬 시작: session=$SESSION_ID agent=$AGENT_NAME interval=${INTERVAL}s"

send_heartbeat() {
    local branch
    branch=$(git -C "${CLAUDE_PROJECT_DIR:-.}" branch --show-current 2>/dev/null || echo "unknown")
    
    curl -s --connect-timeout 1 --max-time 3 -X POST "$NCO_URL/api/mesh/heartbeat" \
        -H "Content-Type: application/json" \
        -d "{
            \"sessionId\": \"$SESSION_ID\",
            \"agentId\": \"$AGENT_NAME\",
            \"pid\": $SESSION_ID,
            \"workMode\": \"mesh\",
            \"status\": \"idle\",
            \"currentWork\": \"대기중\",
            \"currentFiles\": [],
            \"branch\": \"$branch\"
        }" >/dev/null 2>&1
}

# 메인 루프: 세션 PID 살아있는 한 계속 실행
miss_count=0
while true; do
    sleep "$INTERVAL"
    
    # 1. 세션 프로세스 살아있는지 확인
    if ! kill -0 "$SESSION_ID" 2>/dev/null; then
        log "세션 PID $SESSION_ID 종료 — 데몬 중지"
        break
    fi
    
    # 2. NCO 서버 확인
    if ! curl -s --connect-timeout 1 --max-time 2 "$NCO_URL/health" >/dev/null 2>&1; then
        miss_count=$((miss_count + 1))
        [ "$miss_count" -gt 10 ] && { log "NCO 서버 10회 연속 실패 — 데몬 중지"; break; }
        log "NCO 오프라인 (${miss_count}회) — 스킵"
        continue
    fi
    miss_count=0
    
    # 3. 하트비트 전송
    send_heartbeat
    log "heartbeat 전송: $AGENT_NAME"
done

# 정리
rm -f "$DAEMON_PID_FILE"
log "데몬 종료"
