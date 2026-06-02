#!/bin/bash
# Resolve NCO statusline name (claude-N) for inter-session auto-connect
# Looks up /tmp/nco-names/claude-*.pid to find this session's assigned name.
# If no name is registered yet (e.g. after OS restart), assigns the next
# available claude-N slot and writes the PID file — same logic as nco-statusline.sh.

mkdir -p /tmp/nco-names

MY_PID=""
# Walk up to find the topmost claude / node process in the ancestry
_pid=$$
for _i in 1 2 3 4 5 6 7 8; do
  _ppid=$(ps -p "$_pid" -o ppid= 2>/dev/null | tr -d ' ')
  [ -z "$_ppid" ] && break
  _comm=$(ps -p "$_ppid" -o comm= 2>/dev/null | xargs basename 2>/dev/null)
  if [ "$_comm" = "claude" ] || [ "$_comm" = "node" ]; then
    MY_PID="$_ppid"
  fi
  _pid="$_ppid"
done

[ -z "$MY_PID" ] && echo "" && exit 0

NCO_NAME=""

# 1) 이미 이 PID에 이름이 등록돼 있으면 그걸 사용
for pf in /tmp/nco-names/claude-*.pid; do
  [ -f "$pf" ] || continue
  rp=$(cat "$pf" 2>/dev/null | tr -d '[:space:]')
  if [ "$rp" = "$MY_PID" ]; then
    NCO_NAME=$(basename "$pf" .pid)
    break
  fi
done

# 2) 등록돼 있지 않으면 — stale 파일 정리 후 다음 번호 할당
if [ -z "$NCO_NAME" ]; then
  # stale 항목 제거
  for pf in /tmp/nco-names/claude-*.pid; do
    [ -f "$pf" ] || continue
    rp=$(cat "$pf" 2>/dev/null | tr -d '[:space:]')
    [ -n "$rp" ] && ! ps -p "$rp" >/dev/null 2>&1 && rm -f "$pf"
  done
  # 다음 빈 번호 찾기
  _N=1
  while [ -f "/tmp/nco-names/claude-${_N}.pid" ]; do _N=$((_N + 1)); done
  echo "$MY_PID" > "/tmp/nco-names/claude-${_N}.pid"
  NCO_NAME="claude-${_N}"
fi

echo "${NCO_NAME}"
