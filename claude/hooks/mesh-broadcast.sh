#!/bin/bash
# NCO 재귀보호: NCO가 스폰한 서브프로세스 claude에서는 훅 무동작 (2026-07-08, 76s 훅스택+BOOTSTRAP 오염 T1)
[ "${NCO_HOOK_DISABLED:-0}" = "1" ] && exit 0
# mesh-broadcast.sh — Broadcast to all active mesh sessions.
# Mirrors inter-session's send.py --all.
#
# Usage:
#   mesh-broadcast.sh '<text>'
#
# Implementation: delegates to mesh-send.sh with toAgent='*'.

set -euo pipefail

if [ $# -lt 1 ]; then
  echo "usage: mesh-broadcast.sh '<text>'" >&2
  exit 2
fi

exec bash "$(dirname "$0")/mesh-send.sh" '*' "$1" "${2:-info}"
