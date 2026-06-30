#!/usr/bin/env bash
# verify-pipeline.sh — 멀티세션 검증 파이프라인
# 역할: 완료된 작업을 다른 세션에게 교차 검증 요청, 결과를 brain/에 기록
#
# 사용법:
#   bash verify-pipeline.sh --task "작업 설명" --artifact "파일경로" [--verifier 세션명]
#   bash verify-pipeline.sh --status   # 대기 중인 검증 요청 목록
#
# 검증 흐름:
#   구현 세션 → verify-pipeline.sh → inter-session DM → 검증 세션 → 결과 보고
#   결과 → brain/sessions/verification-log.md
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRAIN_DIR="$(dirname "$SCRIPT_DIR")"
INTER_BIN="$HOME/.claude/plugins/cache/inter-session/inter-session/0.1.2/skills/inter-session/bin"
MY_SESSION="${NCO_NAME:-$(hostname | tr '[:upper:]' '[:lower:]' | sed 's/\.local$//')}"
TIMESTAMP=$(date "+%Y-%m-%d %H:%M")
VERIFY_LOG="$BRAIN_DIR/sessions/verification-log.md"

mkdir -p "$BRAIN_DIR/sessions"

# 검증 로그 초기화
if [[ ! -f "$VERIFY_LOG" ]]; then
  cat > "$VERIFY_LOG" << 'EOF'
# 검증 파이프라인 로그

| 날짜 | 요청자 | 검증자 | 작업 | 결과 | 증거등급 |
|------|--------|--------|------|------|---------|
EOF
fi

# ─── 인수 파싱 ────────────────────────────────────────────────
TASK=""; ARTIFACT=""; VERIFIER=""; STATUS_MODE=false
while [[ $# -gt 0 ]]; do
  case $1 in
    --task)     TASK="$2"; shift 2 ;;
    --artifact) ARTIFACT="$2"; shift 2 ;;
    --verifier) VERIFIER="$2"; shift 2 ;;
    --status)   STATUS_MODE=true; shift ;;
    *) shift ;;
  esac
done

# ─── 상태 조회 모드 ────────────────────────────────────────────
if [[ "$STATUS_MODE" == true ]]; then
  echo "=== 검증 파이프라인 로그 ==="
  tail -20 "$VERIFY_LOG" 2>/dev/null || echo "(로그 없음)"
  exit 0
fi

[[ -z "$TASK" ]] && { echo "ERROR: --task 필수"; exit 1; }

# ─── 검증자 자동 선택 ─────────────────────────────────────────
if [[ -z "$VERIFIER" ]]; then
  # 연결된 피어 중 자신 제외, nco- 제외, 활성 세션 선택
  if [[ -f "$INTER_BIN/list.py" ]]; then
    VERIFIER=$(python3 "$INTER_BIN/list.py" 2>/dev/null \
      | grep -v "^NAME\|$MY_SESSION\|^nco-" \
      | head -1 | awk '{print $1}' || true)
  fi
  [[ -z "$VERIFIER" ]] && VERIFIER="nova-macstudio-cli"
fi

# ─── 검증 요청 메시지 구성 ────────────────────────────────────
VERIFY_MSG="verify-request from=$MY_SESSION task=\"$TASK\""
[[ -n "$ARTIFACT" ]] && VERIFY_MSG+=" artifact=\"$ARTIFACT\""
VERIFY_MSG+=" | 검증 방법: 1) 파일 존재+내용 확인(T1) 2) 동작 확인(curl/bash) 3) 결과를 done: 또는 error: 로 회신"

# ─── 검증 요청 전송 ───────────────────────────────────────────
if [[ -f "$INTER_BIN/send.py" ]]; then
  python3 "$INTER_BIN/send.py" --to "$VERIFIER" --text "$VERIFY_MSG" 2>/dev/null \
    && echo "verify-request → $VERIFIER" \
    || echo "WARN: 전송 실패 (inter-session 오프라인)"
else
  echo "WARN: inter-session bin 없음"
fi

# ─── 로그 기록 ────────────────────────────────────────────────
LOG_ENTRY="| $TIMESTAMP | $MY_SESSION | $VERIFIER | $TASK | pending | - |"
echo "$LOG_ENTRY" >> "$VERIFY_LOG"
echo "logged: verification-log.md"

echo ""
echo "검증 파이프라인: $MY_SESSION → $VERIFIER"
echo "작업: $TASK"
echo "결과: $VERIFIER의 응답을 inter-session Monitor로 수신 대기"
