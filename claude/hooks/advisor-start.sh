#!/bin/bash
# NCO 재귀보호: NCO가 스폰한 서브프로세스 claude에서는 훅 무동작 (2026-07-08, 76s 훅스택+BOOTSTRAP 오염 T1)
[ "${NCO_HOOK_DISABLED:-0}" = "1" ] && exit 0
# UserPromptSubmit hook — advisor가 작업 시작 전 100단어 이내로 스코핑 조언
# [DISABLED] 매 프롬프트 Haiku 서브프로세스 이중 과금 → 토큰 누수 제거
exit 0

INPUT=$(cat)
PROMPT=$(echo "$INPUT" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    p = d.get('prompt', '')
    print(p[:600])
except:
    pass
" 2>/dev/null)

[ -z "$PROMPT" ] && exit 0

# 짧은 인사/명령어는 스킵 (10자 미만)
[ ${#PROMPT} -lt 10 ] && exit 0

ADVICE=$(timeout 12 claude -p \
  --model claude-haiku-4-5-20251001 \
  --max-turns 1 \
  "당신은 전략적 기술 어드바이저입니다. 아래 작업 요청을 보고 **100단어 이내**로: ①복잡도(파일/에이전트 필요 수준), ②주요 리스크, ③권장 접근법을 조언하세요. 직접적이고 실행 가능하게.

작업: ${PROMPT}" 2>/dev/null)

[ -z "$ADVICE" ] && exit 0

python3 -c "
import json, sys
advice = sys.argv[1]
print(json.dumps({
    'hookSpecificOutput': {
        'hookEventName': 'UserPromptSubmit',
        'additionalContext': '[Advisor 시작 조언]\n' + advice
    }
}))
" "$ADVICE"
