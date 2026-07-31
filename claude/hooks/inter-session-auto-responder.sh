#!/bin/bash
# NCO 재귀보호: NCO가 스폰한 서브프로세스 claude에서는 훅 무동작 (2026-07-08, 76s 훅스택+BOOTSTRAP 오염 T1)
[ "${NCO_HOOK_DISABLED:-0}" = "1" ] && exit 0
# Wraps inter-session client.py: auto-answers machine-style pings (e.g.
# fleet-status-request) with real /api/daemons data via code, without
# invoking the LLM. Everything else passes through unchanged so the
# LLM still sees genuine content via Monitor.
#
# Adopted 2026-07-02 per user-approved "fleet 운영 절대규칙" items 2/3:
# (2) machine requests get a code-level immediate reply, not an LLM turn
# (3) rate-limit repeated identical-purpose replies (60s per sender here,
#     separate from the hook-side 90s broadcast cooldown)

# ── 디바이스 독립 경로 해석 (2026-07-30) ───────────────────────────────────
# 이전에는 BIN_DIR 이 "/home/nova/..." 로 하드코딩돼 있었다. 그 경로는 리눅스
# 전용이라 macOS(/Users/<user>)에서는 존재하지 않고, 아래 client.py 실행이 즉시
# 실패한다 → 기계 프로토콜 요청이 코드에서 즉답되지 못하고 LLM 턴으로 올라온다
# (플릿 절대규칙 2번 상시 위반). 플러그인 버전도 고정돼 있어 업그레이드 시 깨진다.
# 해석 순서: 환경변수 override → $HOME 하위 glob 중 최신 버전 → 실패 시 종료.
if [ -z "${INTER_SESSION_BIN_DIR:-}" ]; then
  for _cand in "$HOME"/.claude/plugins/cache/inter-session/inter-session/*/skills/inter-session/bin; do
    [ -d "$_cand" ] && INTER_SESSION_BIN_DIR="$_cand"   # glob 사전순 = 최신 버전이 마지막
  done
fi
BIN_DIR="${INTER_SESSION_BIN_DIR:-}"
if [ -z "$BIN_DIR" ] || [ ! -f "${BIN_DIR}/client.py" ]; then
  echo "[auto-responder] inter-session bin 을 찾지 못했습니다 (BIN_DIR='${BIN_DIR}')" >&2
  exit 1
fi

# 호스트명도 하드코딩("kangNote")돼 있어 어느 디바이스에서 응답하든 남의 이름으로
# 보고됐다. macOS 는 scutil, 그 외는 hostname -s 로 해석한다.
HOST_NAME="$(scutil --get ComputerName 2>/dev/null || hostname -s 2>/dev/null || echo unknown)"

STATE_DIR="/tmp/nco-is-autoresponder-${NCO_SESSION_ID:-$$}"
mkdir -p -m 700 "$STATE_DIR" 2>/dev/null
chmod 700 "$STATE_DIR" 2>/dev/null

reply_fleet_status() {
    local from="$1"
    local now last lockdir lock_age
    now=$(date +%s 2>/dev/null || echo 0)

    # ── flock 제거 (2026-07-30) ─────────────────────────────────────────────
    # 이전 구현은 flock(1) 에 의존했다. macOS 에는 그 바이너리가 없어
    # "flock: command not found"(exit 127) → `|| exit 0` 으로 서브셸이 즉시
    # 종료 → .last 가 기록되지 않음 → 바깥에서 last(0) != now 이므로 항상
    # "rate-limited" 로 판정 → **맥에서는 영원히 응답하지 않는다**(T1 실측).
    # 경로 결함을 고쳐도 이것 때문에 여전히 침묵한다. mkdir 은 POSIX 에서
    # 원자적이므로 이를 락으로 쓴다 — 리눅스·맥 공통 동작.
    lockdir="${STATE_DIR}/${from}.lockd"

    # 죽은 프로세스가 남긴 stale 락 회수(60초 초과분). 없으면 무시.
    if [ -d "$lockdir" ]; then
        lock_age=$(find "$lockdir" -maxdepth 0 -mmin +1 2>/dev/null)
        [ -n "$lock_age" ] && rmdir "$lockdir" 2>/dev/null
    fi

    mkdir "$lockdir" 2>/dev/null || return 0   # 경쟁자가 처리 중 → 침묵

    last=$(cat "${STATE_DIR}/${from}.last" 2>/dev/null || echo 0)
    if [ $((now - last)) -lt 60 ]; then
        rmdir "$lockdir" 2>/dev/null
        return 0                                # rate-limited, stay silent
    fi
    printf '%s' "$now" > "${STATE_DIR}/${from}.last" 2>/dev/null
    chmod 600 "${STATE_DIR}/${from}.last" 2>/dev/null
    rmdir "$lockdir" 2>/dev/null

    local payload
    # --max-time 3 은 부하 상황에서 너무 짧다. 2026-07-29 load 40~65 구간에서
    # /health 조차 8~27초가 걸렸다(T1). 3초면 상시 빈 응답 → 무응답이 된다.
    # 다만 이 curl 은 client.py 출력 루프를 인라인으로 막으므로 무한정 늘릴 수도
    # 없다. 10초로 두고, 실패 시 조용히 포기한다(빈 응답 전송 금지 규칙 유지).
    payload=$(HOST_NAME="$HOST_NAME" sh -c 'curl -s --max-time 10 http://localhost:6200/api/daemons 2>/dev/null' | HOST_NAME="$HOST_NAME" python3 -c '
import json, os, sys
try:
    d = json.load(sys.stdin)
    agents = []
    for x in d.get("daemons", []):
        st = "error" if x.get("health", {}).get("lastError") else ("working" if x.get("currentTask") else "idle")
        agents.append({"id": x["id"], "name": x["name"], "status": st, "currentTask": x.get("currentTask")})
    print(json.dumps({"host": os.environ.get("HOST_NAME", "unknown"), "agents": agents}, ensure_ascii=False))
except Exception:
    print("")
' 2>/dev/null)
    [ -z "$payload" ] && return 0
    ( python3 "${BIN_DIR}/send.py" --to "$from" --text "status: ${payload}" >/dev/null 2>&1 & )
}

annotate_handoff_line() {
    local line="$1"
    local validator="${HANDOFF_VALIDATE_BIN:-$HOME/nova-fleet-config/scripts/handoff-validate.py}"
    local payload output_file reason

    # Handoff Packet 검증: 절단/청크 라인은 불완전할 수 있으므로 하위호환을 위해 그대로 통과한다.
    if printf '%s' "$line" | grep -Eq 'truncated=[0-9]+|\[[0-9]+/[0-9]+\]'; then
        printf '%s\n' "$line"
        return 0
    fi

    [ -f "$validator" ] || {
        printf '%s\n' "$line"
        return 0
    }

    payload=$(LINE="$line" python3 - <<'PY'
import os
import re
import sys

line = os.environ.get("LINE", "")
match = re.match(r'^\[inter-session msg=[^]]+ from="[^"]+"\]\s+(done|partial|failed|question):\s+(\{.*\})\s*$', line)
if not match:
    sys.exit(1)
print(match.group(2))
PY
    ) || {
        printf '%s\n' "$line"
        return 0
    }

    [ -n "$payload" ] || {
        printf '%s\n' "$line"
        return 0
    }

    output_file=$(mktemp "${STATE_DIR}/handoff-validate.XXXXXX" 2>/dev/null) || {
        printf '%s\n' "$line"
        return 0
    }
    if python3 "$validator" "$payload" >"$output_file" 2>&1; then
        rm -f "$output_file" 2>/dev/null
        printf '[HANDOFF:ACCEPT] %s\n' "$line"
        return 0
    fi
    reason=$(head -n 1 "$output_file" 2>/dev/null | tr '\r' ' ')
    rm -f "$output_file" 2>/dev/null

    case "$reason" in
        "REJECT: invalid JSON:"*|"")
            printf '%s\n' "$line"
            return 0
            ;;
        "REJECT:"*)
            printf '[HANDOFF:REJECT reason=%s] %s\n' "$reason" "$line"
            return 0
            ;;
        *)
            printf '%s\n' "$line"
            return 0
            ;;
    esac
}

# ── 세션 이름 해석 (2026-07-30) ────────────────────────────────────────────
# 이전 기본값은 "kangnote-claude-3" 로 타 디바이스의 특정 세션 이름이었다.
# 인자 없이 실행하면 남의 이름으로 접속을 시도해 충돌하거나 오귀속된다.
# 해석 순서: 인자 → inter-session-name.sh --device-prefix(=<device>-claude-N,
# inter-session 이름 규칙의 정본) → nco-name-resolver.sh(라벨만) 앞에 호스트명
# 결합 → 최후 호스트명 기반. 어느 단계도 하드코딩하지 않는다.
_hooks_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
resolve_is_name() {
    local n
    if [ -x "${_hooks_dir}/inter-session-name.sh" ]; then
        n="$(bash "${_hooks_dir}/inter-session-name.sh" --device-prefix 2>/dev/null | head -1)"
        [ -n "$n" ] && { printf '%s' "$n"; return 0; }
    fi
    if [ -x "${_hooks_dir}/nco-name-resolver.sh" ]; then
        n="$(bash "${_hooks_dir}/nco-name-resolver.sh" 2>/dev/null | head -1)"
        [ -n "$n" ] && { printf '%s-%s' "$(printf '%s' "$HOST_NAME" | tr '[:upper:]' '[:lower:]')" "$n"; return 0; }
    fi
    printf '%s-claude' "$(printf '%s' "$HOST_NAME" | tr '[:upper:]' '[:lower:]')"
}
IS_NAME="${1:-$(resolve_is_name)}"

python3 "${BIN_DIR}/client.py" --name "$IS_NAME" | while IFS= read -r line; do
    if printf '%s' "$line" | grep -q "fleet-status-request"; then
        # grep -oP 는 GNU 전용이다. macOS 기본 grep(BSD)에는 -P 가 없어 조용히
        # 빈 sender 가 되고 응답이 스킵된다. sed 로 대체해 두 플랫폼 모두 동작.
        sender=$(printf '%s' "$line" | sed -n 's/.*from="\([^"]*\)".*/\1/p' | head -1)
        [ -n "$sender" ] && reply_fleet_status "$sender"
        continue  # do not surface this line to the LLM
    fi
    annotate_handoff_line "$line"
done
