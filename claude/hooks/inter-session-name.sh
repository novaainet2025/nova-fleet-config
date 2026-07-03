#!/bin/bash
# Resolve NCO statusline name (claude-N) for inter-session auto-connect
# Looks up /tmp/nco-names/claude-*.pid to find this session's assigned name.
# If no name is registered yet (e.g. after OS restart), assigns the next
# available claude-N slot and writes the PID file — same logic as nco-statusline.sh.
#
# 2026-07-03 lock fix: entire read+cleanup+assign under shared .lockdir mutex
# (standardized with session-start.sh and nco-statusline.sh).
# Also: atomic write (tmp→mv) + empty-file mid-write protection.

NCO_NAMES_DIR="/tmp/nco-names"
mkdir -p "$NCO_NAMES_DIR"

# 단일 소스 라우팅 (2026-07-03): resolver가 claude-N 주면 즉시 반환. 아래 레거시
# walk+cleanup(ps -p 기반 live 파일 삭제 = 셔플 원인)은 resolver 부재 시에만 fallback.
_rsv="$HOME/.claude/hooks/nco-name-resolver.sh"
if [ -f "$_rsv" ]; then
  _rn=$(bash "$_rsv" 2>/dev/null)
  [ -n "$_rn" ] && { echo "$_rn"; exit 0; }
fi

MY_PID=""
# Walk up to find the topmost claude / node process in the ancestry (no-break)
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

# ── Shared mutex (.lockdir — same name used by session-start.sh and nco-statusline.sh) ──
_LOCKDIR="$NCO_NAMES_DIR/.lockdir"
_LOCK_WAIT=0
while ! mkdir "$_LOCKDIR" 2>/dev/null; do
  _LOCK_WAIT=$((_LOCK_WAIT + 1))
  [ "$_LOCK_WAIT" -ge 30 ] && rm -rf "$_LOCKDIR" && break  # 3s timeout, force-clear stale lock
  sleep 0.1
done

NCO_NAME=""

# 1) 이미 이 PID에 이름이 등록돼 있으면 그걸 사용
for pf in "$NCO_NAMES_DIR"/claude-*.pid; do
  [ -f "$pf" ] || continue
  rp=$(cat "$pf" 2>/dev/null | tr -d '[:space:]')
  [ -z "$rp" ] && continue  # skip empty (mid-write protection)
  if [ "$rp" = "$MY_PID" ]; then
    NCO_NAME=$(basename "$pf" .pid)
    break
  fi
done

# 2) 등록돼 있지 않으면 — stale 파일 정리 후 다음 번호 할당
if [ -z "$NCO_NAME" ]; then
  # stale 항목 제거 (빈 파일 = mid-write 중 → 건너뜀)
  for pf in "$NCO_NAMES_DIR"/claude-*.pid; do
    [ -f "$pf" ] || continue
    rp=$(cat "$pf" 2>/dev/null | tr -d '[:space:]')
    [ -z "$rp" ] && continue  # skip empty (mid-write protection)
    ! ps -p "$rp" >/dev/null 2>&1 && rm -f "$pf"
  done
  # 다음 빈 번호 찾기 & 원자적 쓰기 (tmp→mv)
  _N=1
  while [ -f "$NCO_NAMES_DIR/claude-${_N}.pid" ]; do _N=$((_N + 1)); done
  _TMP="$NCO_NAMES_DIR/claude-${_N}.pid.tmp.$$"
  printf '%s\n' "$MY_PID" > "$_TMP" && mv "$_TMP" "$NCO_NAMES_DIR/claude-${_N}.pid"
  NCO_NAME="claude-${_N}"
fi

rmdir "$_LOCKDIR" 2>/dev/null

echo "${NCO_NAME}"
