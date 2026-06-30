#!/usr/bin/env bash
# brain-capture.sh — 오류/패턴을 brain/errors/patterns.md에 기록
# 사용법: bash brain-capture.sh --id ERR-XXX --summary "요약" --cause "원인" --fix "방지책"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRAIN_DIR="$(dirname "$SCRIPT_DIR")"
PATTERNS="$BRAIN_DIR/errors/patterns.md"
SESSION="${NCO_NAME:-unknown}"
TIMESTAMP=$(date "+%Y-%m-%d %H:%M")

ID=""; SUMMARY=""; CAUSE=""; FIX=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --id) ID="$2"; shift 2 ;;
    --summary) SUMMARY="$2"; shift 2 ;;
    --cause) CAUSE="$2"; shift 2 ;;
    --fix) FIX="$2"; shift 2 ;;
    --session) SESSION="$2"; shift 2 ;;
    *) shift ;;
  esac
done

[[ -z "$ID" ]] && { echo "ERROR: --id 필수"; exit 1; }

mkdir -p "$(dirname "$PATTERNS")"

# 이미 존재하는 패턴이면 발생 횟수 증가
if grep -q "^### $ID" "$PATTERNS" 2>/dev/null; then
  # perl로 멀티라인 카운터 증가 (macOS/Linux 공통)
  perl -i -0pe "
    s/(### ${ID}[^\n]*\n(?:[^\n]*\n)*?- \*\*발생 횟수\*\*: )(\d+)/
      \$1 . (\$2 + 1)/e
  " "$PATTERNS" 2>/dev/null || true
  echo "updated: $ID 발생 횟수 +1 → $PATTERNS"
  exit 0
fi

# 신규 패턴 추가
cat >> "$PATTERNS" << PATTERN

### $ID | $SUMMARY
- **발생**: $TIMESTAMP ($SESSION)
- **근본 원인**: $CAUSE
- **방지**: $FIX
- **발생 횟수**: 1
PATTERN

echo "captured: $ID → $PATTERNS"

# gbrain 자동 캡처 (있으면)
GBRAIN_BIN=""
for _gb in "$HOME/.bun/bin/gbrain" "$HOME/.local/bin/gbrain" "$(command -v gbrain 2>/dev/null)"; do
  [[ -x "$_gb" ]] && GBRAIN_BIN="$_gb" && break
done
if [[ -n "$GBRAIN_BIN" ]]; then
  "$GBRAIN_BIN" capture "[$ID] $SUMMARY — 원인: $CAUSE — 방지: $FIX" >/dev/null 2>&1 && \
    echo "gbrain: $ID 캡처됨" || true
fi
