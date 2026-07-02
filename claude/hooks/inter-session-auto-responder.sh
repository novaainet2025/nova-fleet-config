#!/bin/bash
# Wraps inter-session client.py: auto-answers machine-style pings (e.g.
# fleet-status-request) with real /api/daemons data via code, without
# invoking the LLM. Everything else passes through unchanged so the
# LLM still sees genuine content via Monitor.
#
# Adopted 2026-07-02 per user-approved "fleet 운영 절대규칙" items 2/3:
# (2) machine requests get a code-level immediate reply, not an LLM turn
# (3) rate-limit repeated identical-purpose replies (60s per sender here,
#     separate from the hook-side 90s broadcast cooldown)

BIN_DIR="/home/nova/.claude/plugins/cache/inter-session/inter-session/0.1.2/skills/inter-session/bin"
STATE_DIR="/tmp/nco-is-autoresponder-${NCO_SESSION_ID:-$$}"
mkdir -p -m 700 "$STATE_DIR" 2>/dev/null
chmod 700 "$STATE_DIR" 2>/dev/null

reply_fleet_status() {
    local from="$1"
    local now last lockfile
    now=$(date +%s 2>/dev/null || echo 0)
    lockfile="${STATE_DIR}/${from}.lock"
    # flock makes the read-check-write atomic even if this script is ever
    # run more than once concurrently for the same sender (code review fix).
    (
        flock -x -w 2 200 || exit 0
        last=$(cat "${STATE_DIR}/${from}.last" 2>/dev/null || echo 0)
        if [ $((now - last)) -lt 60 ]; then
            exit 0  # rate-limited, stay silent
        fi
        printf '%s' "$now" > "${STATE_DIR}/${from}.last" 2>/dev/null
        chmod 600 "${STATE_DIR}/${from}.last" 2>/dev/null
    ) 200>"$lockfile"
    last=$(cat "${STATE_DIR}/${from}.last" 2>/dev/null || echo 0)
    [ "$last" != "$now" ] && return 0  # subshell decided to rate-limit

    local payload
    payload=$(curl -s --max-time 3 http://localhost:6200/api/daemons 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    agents = []
    for x in d.get("daemons", []):
        st = "error" if x.get("health", {}).get("lastError") else ("working" if x.get("currentTask") else "idle")
        agents.append({"id": x["id"], "name": x["name"], "status": st, "currentTask": x.get("currentTask")})
    print(json.dumps({"host": "kangNote", "agents": agents}, ensure_ascii=False))
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

IS_NAME="${1:-kangnote-claude-3}"
python3 "${BIN_DIR}/client.py" --name "$IS_NAME" | while IFS= read -r line; do
    if printf '%s' "$line" | grep -q "fleet-status-request"; then
        sender=$(printf '%s' "$line" | grep -oP 'from="\K[^"]+' | head -1)
        [ -n "$sender" ] && reply_fleet_status "$sender"
        continue  # do not surface this line to the LLM
    fi
    annotate_handoff_line "$line"
done
