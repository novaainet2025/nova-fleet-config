#!/bin/bash
# NCO 재귀보호: NCO가 스폰한 서브프로세스 claude에서는 훅 무동작 (2026-07-08, 76s 훅스택+BOOTSTRAP 오염 T1)
[ "${NCO_HOOK_DISABLED:-0}" = "1" ] && exit 0
# UserPromptSubmit hook — 이전 세션 개선 노트를 세션 첫 프롬프트에만 1회 주입
# 이전: 매 프롬프트 500자 = N×500토큰 낭비 → 수정: 세션당 1회만

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
PROJECT_NAME=$(basename "$PROJECT_DIR")
IMPROVEMENTS_DIR="$HOME/.claude/improvements"

[ -d "$IMPROVEMENTS_DIR" ] || exit 0

# 세션 ID 결정
if [ -z "$NCO_SESSION_ID" ]; then
  _CK=$$
  for _i in 1 2 3 4 5; do
    _CK=$(ps -o ppid= -p "$_CK" 2>/dev/null | tr -d ' ')
    [ -z "$_CK" ] && break
    _CM=$(ps -o comm= -p "$_CK" 2>/dev/null)
    echo "$_CM" | grep -qE '^(claude|node)$' && { NCO_SESSION_ID="$_CK"; break; }
  done
  NCO_SESSION_ID="${NCO_SESSION_ID:-$$}"
fi

# 이미 이번 세션에 주입했으면 스킵 (세션당 1회)
INJECTED_FLAG="/tmp/nco-improvement-injected-${NCO_SESSION_ID}"
[ -f "$INJECTED_FLAG" ] && exit 0

# 가장 최근 개선 노트 찾기
PREV_FILE=$(ls -t "$IMPROVEMENTS_DIR/${PROJECT_NAME}-"*.md 2>/dev/null | head -1)
[ -z "$PREV_FILE" ] && exit 0

# [High] 항목 우선 추출, 없으면 전체 권장사항 섹션 (최대 300자)
HIGH_ITEMS=$(grep -oP '\[High\][^\n]+' "$PREV_FILE" 2>/dev/null | head -3 | sed 's/^/- /')
if [ -n "$HIGH_ITEMS" ]; then
    IMPROVEMENTS="[우선순위 High]"$'\n'"$HIGH_ITEMS"
else
    IMPROVEMENTS=$(awk '/권장 개선사항/{found=1; next} found && /^###/{exit} found{print}' "$PREV_FILE" \
      | sed '/^[[:space:]]*$/d' \
      | head -c 300)
fi
[ -z "$IMPROVEMENTS" ] && exit 0

# 주입 완료 표시 (세션 내 재주입 방지)
touch "$INJECTED_FLAG"

NOTE_DATE=$(basename "$PREV_FILE" | sed "s/${PROJECT_NAME}-//" | sed 's/\.md//')

python3 -c "
import json, sys
print(json.dumps({
    'hookSpecificOutput': {
        'hookEventName': 'UserPromptSubmit',
        'additionalContext': '[이전 세션 개선사항 (' + sys.argv[2] + ')]\n' + sys.argv[1]
    }
}))
" "$IMPROVEMENTS" "$NOTE_DATE"
