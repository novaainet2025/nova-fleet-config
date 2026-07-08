#!/bin/bash
# NCO 재귀보호: NCO가 스폰한 서브프로세스 claude에서는 훅 무동작 (2026-07-08, 76s 훅스택+BOOTSTRAP 오염 T1)
[ "${NCO_HOOK_DISABLED:-0}" = "1" ] && exit 0
# mesh-receiver-spawn.sh — Monitor 도구가 호출하는 wrapper.
# 자기 Claude Code ancestor pid를 찾아 NCO_NAME/SID를 결정한 뒤 poller exec.
# env 격리: 부모 Claude의 NCO_SESSION_ID/NCO_NAME envvar가 잘못 상속되어
# poller가 엉뚱한 세션 이름으로 동작하는 결함 #3 방지.

set -u

mkdir -p /tmp/nco-names

# 1) 내 ancestor 중 claude/node 프로세스 pid 찾기
my_pid=$$
for _i in 1 2 3 4 5 6 7 8; do
    _pp=$(ps -o ppid= -p "$my_pid" 2>/dev/null | tr -d ' ')
    [ -z "$_pp" ] && break
    _cm=$(ps -o comm= -p "$_pp" 2>/dev/null)
    if [ "$_cm" = "claude" ] || [ "$_cm" = "node" ]; then
        my_pid="$_pp"
    fi
done

# 2) /tmp/nco-names에서 my_pid 매칭 .pid 파일 찾기
SID=""
NAME=""
for pf in /tmp/nco-names/claude-*.pid; do
    [ -f "$pf" ] || continue
    rp=$(cat "$pf" 2>/dev/null | tr -d '[:space:]')
    if [ "$rp" = "$my_pid" ]; then
        NAME=$(basename "$pf" .pid)
        SID="$rp"
        break
    fi
done

# 3) fallback: NCO_NAME env 신뢰하되 NCO_SESSION_ID는 my_pid로 강제
if [ -z "$NAME" ]; then
    NAME="${NCO_NAME:-claude-bot}"
fi
# NAME 화이트리스트 — 경로 조작/파일 lookup 보호 (cursor-agent 리뷰 MED)
if ! printf '%s' "$NAME" | grep -Eq '^[A-Za-z0-9._-]{1,40}$'; then
    NAME="claude-bot"
fi
if [ -z "$SID" ]; then
    # ancestor lookup이 실패해도 NAME으로 정상 SID를 복구 (mesh API와 일치).
    # /tmp/nco-names/<NAME>.pid에 mesh-register가 기록한 canonical SID가 있음.
    _canonical=$(cat "/tmp/nco-names/${NAME}.pid" 2>/dev/null | tr -d '[:space:]')
    if [ -n "$_canonical" ] && kill -0 "$_canonical" 2>/dev/null; then
        SID="$_canonical"
    else
        SID="$my_pid"
    fi
fi

# 4) env 격리 + poller exec (자식이 부모 env를 절대 상속 못 하도록 명시 set)
exec env -u NCO_SESSION_ID -u NCO_NAME \
    INTER_MODE="${INTER_MODE:-monitor}" \
    NCO_SESSION_ID="$SID" \
    NCO_NAME="$NAME" \
    bash "$HOME/.claude/hooks/mesh-inbox-poller.sh" "$SID" "$NAME" 5
