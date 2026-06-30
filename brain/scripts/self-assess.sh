#!/usr/bin/env bash
# self-assess.sh — 자가 개선 평가 (재발율, 영수증 비율, 개선 점수)
# 실행: bash ~/nova-fleet-config/brain/scripts/self-assess.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRAIN_DIR="$(dirname "$SCRIPT_DIR")"
PATTERNS="$BRAIN_DIR/errors/patterns.md"
IMPROVEMENTS="$BRAIN_DIR/improvements/log.md"
TODAY=$(date "+%Y-%m-%d")
SESSION="${NCO_NAME:-$(hostname)}"

echo "=== Nova Fleet 자가 개선 평가 ==="
echo "날짜: $TODAY | 세션: $SESSION"
echo ""

# ─── 1. 오류 패턴 통계 ─────────────────────────────────────
TOTAL_PATTERNS=0; RECUR_PATTERNS=0; NEW_PATTERNS=0
if [[ -f "$PATTERNS" ]]; then
  TOTAL_PATTERNS=$(grep -cE "^\*\*\*|^###" "$PATTERNS" 2>/dev/null | head -1 || echo 0)
  TOTAL_PATTERNS=$(grep -c "^### ERR-" "$PATTERNS" 2>/dev/null || true); TOTAL_PATTERNS=${TOTAL_PATTERNS:-0}
  # 한국어 grep 대신 숫자 패턴 매칭
  RECUR_PATTERNS=$(grep -E "^\- \*\*.*\*\*: [2-9][0-9]*$" "$PATTERNS" 2>/dev/null | wc -l | tr -d ' ' || echo 0)
  NEW_PATTERNS=$(grep -E "^\- \*\*.*\*\*: 1$" "$PATTERNS" 2>/dev/null | wc -l | tr -d ' ' || echo 0)
fi
echo "패턴 라이브러리: ${TOTAL_PATTERNS}개 (신규: ${NEW_PATTERNS} | 재발: ${RECUR_PATTERNS})"

# ─── 2. 검증 영수증 비율 (최근 세션 로그) ──────────────────
RECEIPT_COUNT=0; COMPLETION_COUNT=0; RECEIPT_RATIO=100
SESSION_DIR="$HOME/.claude/projects"
if [[ -d "$SESSION_DIR" ]]; then
  # 최근 수정된 JSONL 파일 찾기
  LATEST_JSONL=$(find "$SESSION_DIR" -name "*.jsonl" -maxdepth 3 2>/dev/null \
    | xargs ls -t 2>/dev/null | head -1 || true)
  if [[ -n "$LATEST_JSONL" && -f "$LATEST_JSONL" ]]; then
    RECEIPT_COUNT=$(grep -c "검증 영수증" "$LATEST_JSONL" 2>/dev/null || echo 0) || RECEIPT_COUNT=0
    COMPLETION_COUNT=$(grep -cE '"text".*\b(완료|done|fixed|성공)\b' "$LATEST_JSONL" 2>/dev/null || echo 0) || COMPLETION_COUNT=0
    [[ "$COMPLETION_COUNT" -gt 0 ]] && RECEIPT_RATIO=$((RECEIPT_COUNT * 100 / COMPLETION_COUNT))
    echo "검증 영수증: ${RECEIPT_RATIO}% (${RECEIPT_COUNT}/${COMPLETION_COUNT} 완료 주장)"
  else
    echo "검증 영수증: 세션 로그 없음 (측정 불가)"
  fi
fi

# ─── 3. 개선 점수 ──────────────────────────────────────────
if [[ "$TOTAL_PATTERNS" -gt 0 ]]; then
  IMPROVE_SCORE=$(( (TOTAL_PATTERNS - RECUR_PATTERNS) * 100 / TOTAL_PATTERNS ))
else
  IMPROVE_SCORE=100
fi

if [[ "$IMPROVE_SCORE" -ge 90 ]]; then
  GRADE="우수 ✓"
elif [[ "$IMPROVE_SCORE" -ge 70 ]]; then
  GRADE="양호"
else
  GRADE="개선 필요 !"
fi

echo ""
echo "개선율: ${IMPROVE_SCORE}% — ${GRADE}"

# ─── 4. 재발 오류 목록 출력 ────────────────────────────────
if [[ "$RECUR_PATTERNS" -gt 0 ]]; then
  echo ""
  echo "재발 오류 목록 (방지책 강화 필요):"
  grep -B5 "발생 횟수: [2-9]" "$PATTERNS" 2>/dev/null \
    | grep "^### ERR-" \
    | sed 's/^### /  - /' || true
fi

# ─── 5. improvements/log.md 업데이트 ────────────────────────
if [[ -f "$IMPROVEMENTS" ]]; then
  LOG_LINE="| $TODAY | ${NEW_PATTERNS} | ${RECUR_PATTERNS} | - | - | ${IMPROVE_SCORE}% |"
  if ! grep -q "^| $TODAY" "$IMPROVEMENTS" 2>/dev/null; then
    # 테이블 헤더 다음 줄에 삽입
    perl -i -pe "
      if (/^\| 날짜 / .. /^\|[-|]+\|$/) {
        \$inserted = 0 unless defined \$inserted;
      }
      if (/^\|[-|]+\|$/ && !\$inserted) {
        \$_ .= \"$LOG_LINE\n\";
        \$inserted = 1;
      }
    " "$IMPROVEMENTS" 2>/dev/null || echo "$LOG_LINE" >> "$IMPROVEMENTS"
    echo ""
    echo "improvements/log.md 업데이트: $TODAY"
  fi
fi

# ─── 최종 요약 ─────────────────────────────────────────────
echo ""
echo "─────────────────────────────────────────"
echo "개선율: ${IMPROVE_SCORE}% | 재발 오류: ${RECUR_PATTERNS}개 | 패턴 라이브러리: ${TOTAL_PATTERNS}개"
