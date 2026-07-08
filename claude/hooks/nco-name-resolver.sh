#!/bin/bash
# NCO 재귀보호: NCO가 스폰한 서브프로세스 claude에서는 훅 무동작 (2026-07-08, 76s 훅스택+BOOTSTRAP 오염 T1)
[ "${NCO_HOOK_DISABLED:-0}" = "1" ] && exit 0
# ── nco-name-resolver.sh — claude-N 이름 해석 단일 소스 (2026-07-03) ──
# 배경: nco-statusline.sh(가까운 조상 5단계) / inter-session-name.sh(먼 조상 8단계)
#       / user-prompt-nco-context.sh(자체 5단계 + $PPID fallback 기록)가 서로 다른
#       PID를 키로 같은 /tmp/nco-names/*.pid를 읽고·쓰고·지우면서 이름이 계속
#       셔플되는 결함(T1 실측 2026-07-03: 산 세션 pid 파일 삭제 + 번호 재배정 반복).
# 규칙:
#  1) 세션 키 = 조상 8단계 중 "가장 먼(topmost) claude" PID. claude가 없으면
#     topmost node (MCP/monitor 하위 node 오탐 방지 — 가까운 조상 방식 금지).
#  2) 모든 조회→할당→기록은 /tmp/nco-names/.lock에 flock 걸고 원자적으로 수행.
#  3) 산 pid가 등록된 파일은 절대 삭제·재배정 금지. 죽은 pid 파일만 정리.
#  4) claude/node 조상을 못 찾으면 파일에 아무것도 쓰지 않는다 ($PPID fallback
#     기록이 stale-cleanup에 의한 산 세션 등록 삭제의 근원이었음).
# 사용: source 후 nco_resolve_name 호출(이름 stdout) — 또는 직접 실행.

NCO_NAMES_DIR="/tmp/nco-names"

# 세션 키 PID 계산 (stdout: pid 또는 빈 문자열)
nco_session_pid() {
  local pid=$$ ppid comm top_claude="" top_node=""
  local _i
  for _i in 1 2 3 4 5 6 7 8; do
    ppid=$(ps -p "$pid" -o ppid= 2>/dev/null | tr -d ' ')
    [ -z "$ppid" ] || [ "$ppid" = "0" ] && break
    comm=$(ps -p "$ppid" -o comm= 2>/dev/null)
    comm=$(basename "$comm" 2>/dev/null)
    case "$comm" in
      claude) top_claude="$ppid" ;;
      node)   top_node="$ppid" ;;
    esac
    pid="$ppid"
  done
  if [ -n "$top_claude" ]; then echo "$top_claude"
  elif [ -n "$top_node" ]; then echo "$top_node"
  fi
}

# flock 하에 조회/할당 수행하는 내부 함수 (인자: my_pid, env_name)
_nco_resolve_locked() {
  local my_pid="$1" env_name="$2" pf rp
  # 1) 내 pid로 등록된 이름이 있으면 그것이 진실
  for pf in "$NCO_NAMES_DIR"/claude-*.pid; do
    [ -f "$pf" ] || continue
    rp=$(tr -d '[:space:]' < "$pf" 2>/dev/null)
    if [ "$rp" = "$my_pid" ]; then
      basename "$pf" .pid
      return 0
    fi
  done
  # 2) 등록 없음 — 죽은 pid 파일만 정리 (산 세션 등록 불가침)
  for pf in "$NCO_NAMES_DIR"/claude-*.pid; do
    [ -f "$pf" ] || continue
    rp=$(tr -d '[:space:]' < "$pf" 2>/dev/null)
    if [ -n "$rp" ] && ! ps -p "$rp" >/dev/null 2>&1; then
      rm -f "$pf"
    fi
  done
  # 3) env NCO_NAME이 있고 그 슬롯이 비어 있으면 그 이름으로 등록 (연속성 우선)
  if [ -n "$env_name" ] && [ ! -f "$NCO_NAMES_DIR/${env_name}.pid" ]; then
    echo "$my_pid" > "$NCO_NAMES_DIR/${env_name}.pid"
    echo "$env_name"
    return 0
  fi
  # 4) 다음 빈 번호 할당
  local n=1
  while [ -f "$NCO_NAMES_DIR/claude-${n}.pid" ]; do n=$((n + 1)); done
  echo "$my_pid" > "$NCO_NAMES_DIR/claude-${n}.pid"
  echo "claude-${n}" > "$NCO_NAMES_DIR/.last-assigned" 2>/dev/null
  echo "claude-${n}"
}

# 메인: 이름을 stdout으로 출력. 실패 시 env NCO_NAME 또는 빈 문자열.
nco_resolve_name() {
  mkdir -p "$NCO_NAMES_DIR" 2>/dev/null
  local my_pid
  my_pid=$(nco_session_pid)
  if [ -z "$my_pid" ]; then
    # 규칙 4: 키를 못 구하면 기록 금지 — 읽기 전용 fallback
    echo "${NCO_NAME:-}"
    return 0
  fi
  # flock 사용 가능하면 원자적으로, 없으면(구형 macOS 기본엔 flock 없음) 그대로
  if command -v flock >/dev/null 2>&1; then
    (
      flock -w 3 9 || exit 1
      _nco_resolve_locked "$my_pid" "${NCO_NAME:-}"
    ) 9>"$NCO_NAMES_DIR/.lock"
  else
    # mkdir 기반 spinlock (macOS flock 부재 대비, 최대 ~3초 대기)
    local lockdir="$NCO_NAMES_DIR/.lockdir" _t=0
    while ! mkdir "$lockdir" 2>/dev/null; do
      _t=$((_t + 1)); [ "$_t" -ge 30 ] && break
      sleep 0.1
    done
    _nco_resolve_locked "$my_pid" "${NCO_NAME:-}"
    rmdir "$lockdir" 2>/dev/null
  fi
}

# 직접 실행 시 이름 출력
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  nco_resolve_name
fi
