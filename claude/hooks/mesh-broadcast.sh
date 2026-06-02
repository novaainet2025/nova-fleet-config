#!/bin/bash
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
