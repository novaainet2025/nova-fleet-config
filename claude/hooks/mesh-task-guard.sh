#!/bin/bash
# mesh-task-guard.sh — Pre-flight check before a Claude session acts on a
# delegated mesh task. Blocks impersonation, runaway depth, and obvious
# destructive instructions.
#
# Usage:
#   mesh-task-guard.sh <fromAgent> <depth> <content>
#
# Exit codes:
#   0  ok (proceed)
#   1  BLOCK depth>=5 (runaway loop)
#   2  BLOCK dangerous pattern in content
#   3  BLOCK unknown sender (impersonation)
#   4  bad args

set -u

if [ $# -lt 3 ]; then
  echo "usage: mesh-task-guard.sh <fromAgent> <depth> <content>" >&2
  exit 4
fi

FROM="${1#@}"
DEPTH="${2:-0}"
CONTENT="${3:-}"

# 1) sender impersonation check — must be registered in /tmp/nco-names
NAMES_DIR="/tmp/nco-names"
if [ ! -e "${NAMES_DIR}/${FROM}.pid" ]; then
  # nco-system / nco-bot / autoresponder echoes are allowed (system origin)
  case "$FROM" in
    nco|nco-system|nco-bot) : ;;
    *)
      echo "BLOCK: unknown sender '${FROM}' (not in ${NAMES_DIR})" >&2
      exit 3
      ;;
  esac
fi

# 2) runaway depth
if [ "$DEPTH" -ge 5 ] 2>/dev/null; then
  echo "BLOCK: depth=${DEPTH} (max 4) — runaway delegation refused" >&2
  exit 1
fi
if [ "$DEPTH" -ge 3 ] 2>/dev/null; then
  echo "WARN: depth=${DEPTH} — consider terminating the chain" >&2
fi

# 3) dangerous pattern scan (case-insensitive)
if echo "$CONTENT" | grep -qiE 'rm[[:space:]]+-rf[[:space:]]+/|rm[[:space:]]+-rf[[:space:]]+~|git[[:space:]]+push[[:space:]].*--force|drop[[:space:]]+table|kubectl[[:space:]]+delete[[:space:]]+-A|sudo[[:space:]]+rm|mkfs|dd[[:space:]]+if=.*of=/dev/|:\(\)\{[[:space:]]*:|/\*\.\*\.|chmod[[:space:]]+-R[[:space:]]+777[[:space:]]+/'; then
  echo "BLOCK: dangerous pattern in content" >&2
  exit 2
fi

# 4) credential exfiltration markers — block content asking to send secrets
if echo "$CONTENT" | grep -qiE 'cat[[:space:]]+.*\.env|AWS_SECRET|SECRET_KEY|PRIVATE_KEY|/etc/shadow|~/\.ssh/id_'; then
  echo "BLOCK: credential exfiltration pattern" >&2
  exit 2
fi

exit 0
