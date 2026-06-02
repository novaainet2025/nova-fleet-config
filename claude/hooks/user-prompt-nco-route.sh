#!/bin/bash
# L1: UserPromptSubmit hook — NCO 라우팅 안내 주입
# 신규 기능(new_feature) 분류 시, 첫 도구 호출이 nco-flow / nco-task가 되도록
# additionalContext(stdout)에 BLOCKING 안내 주입. 카운터도 0으로 초기화.
# 우회: NCO_DIRECT_BYPASS=1 또는 prompt에 [NCO-DIRECT] 포함.

set -u

INPUT=$(cat 2>/dev/null)
SID="${NCO_SESSION_ID:-$$}"

# prompt 본문 추출 (parse 실패 시 빈 문자열)
PROMPT=$(echo "$INPUT" | python3 -c "
import sys, json
try: print(json.load(sys.stdin).get('prompt',''))
except: pass
" 2>/dev/null)

# 카운터 매 prompt마다 0 초기화 (직접 [NCO-DIRECT] 우회와 무관하게)
echo 0 > "/tmp/nco-task-count-$SID" 2>/dev/null

# 우회 조건
if [ -n "${NCO_DIRECT_BYPASS:-}" ] || echo "$PROMPT" | grep -qE '\[NCO-DIRECT\]'; then
  exit 0
fi

# task_type 캐시 읽기 (nco-task-classifier.sh가 작성한다고 가정,
# 없으면 unknown 으로 보고 skip)
TASK_TYPE_FILE="/tmp/nco-task-type-$SID"
TASK_TYPE="unknown"
[ -f "$TASK_TYPE_FILE" ] && TASK_TYPE=$(cat "$TASK_TYPE_FILE" 2>/dev/null | tr -d '[:space:]')

if [ "$TASK_TYPE" = "new_feature" ]; then
  cat <<'EOF'
[NCO-ROUTE L1] 신규 기능 분류 — 첫 도구 호출은 mcp__nco-commands__nco-flow
또는 mcp__nco-commands__nco-task (ai=codex/opencode/cursor-agent) 필수.
Edit/Write/MultiEdit 직접 호출 시 L3 PreToolUse 게이트가 차단합니다.
우회: 환경변수 NCO_DIRECT_BYPASS=1 또는 prompt에 [NCO-DIRECT] 포함.
EOF
fi

exit 0
