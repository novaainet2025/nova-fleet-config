#!/bin/bash
# NCO redis 자동기동 (sudo-free) — SessionStart 훅
# 배경(2026-07-10, kangnote-claude-2): 로컬 redis 다운 시 NCO의 /health·/api/daemons·
# /api/agents가 모두 getAllAgentStates(redis)를 await하며 행 → 상태바 Offline 오표기 +
# fleet push payload 생성 실패(중앙 stale). redis 하나로 두 증상이 동시에 남.
# 근본원인·검증법 메모리: nco-redis-down-root-cause
# NCO보다 먼저 실행되도록 SessionStart 목록 맨 앞에 등록할 것.

# NCO 재귀보호: NCO가 스폰한 서브프로세스 claude에서는 훅 무동작
[ "${NCO_HOOK_DISABLED:-0}" = "1" ] && exit 0

REDIS_CLI="$(command -v redis-cli 2>/dev/null || echo "$HOME/.local/bin/redis-cli")"

# 이미 응답하면 즉시 종료 (빠른 경로 — 정상 세션에서 오버헤드 최소)
"$REDIS_CLI" -p 6379 ping 2>/dev/null | grep -q PONG && exit 0

REDIS_DIR="$HOME/.local/share/nco-redis"
mkdir -p "$REDIS_DIR" 2>/dev/null

if [ "$(uname)" = "Darwin" ]; then
  # Mac: brew 관리 redis
  command -v brew >/dev/null 2>&1 && brew services start redis >/dev/null 2>&1
else
  # WSL/Linux: sudo-free 로컬 바이너리 daemonize (persistence off — 순수 캐시/state 용도)
  REDIS_SERVER="$(command -v redis-server 2>/dev/null || echo "$HOME/.local/bin/redis-server")"
  [ -x "$REDIS_SERVER" ] && "$REDIS_SERVER" --port 6379 --daemonize yes \
    --dir "$REDIS_DIR" --save '' --appendonly no >/dev/null 2>&1
fi

# 기동 확인 (최대 ~2초)
for _i in 1 2 3 4; do
  "$REDIS_CLI" -p 6379 ping 2>/dev/null | grep -q PONG && exit 0
  sleep 0.5
done

# 끝내 실패 시에도 세션은 진행 (다른 훅 블로킹 금지)
exit 0
