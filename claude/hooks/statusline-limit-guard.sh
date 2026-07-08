#!/bin/bash
# NCO 재귀보호: NCO가 스폰한 서브프로세스 claude에서는 훅 무동작 (2026-07-08, 76s 훅스택+BOOTSTRAP 오염 T1)
[ "${NCO_HOOK_DISABLED:-0}" = "1" ] && exit 0
# statusline-limit-guard.sh — nco-statusline.sh 리밋 추출 회귀 방지 (2026-07-06)
#
# 버그(ERR): 상태바 리밋 판정이 /api/agents 의 gate.available=false 만 필터하면
# 서킷오픈의 모든 사유(quota / 일시오류 / empty completion / connection / generic
# cooldown)를 포괄해, reason:"generic"(오류성 오픈)까지 "리밋"으로 오표시한다.
# 정답: 진짜 리밋은 gate.reason in (quota,rate_limit,usage_limit) 로만 판정.
#   실측(2026-07-06): cursor-agent/copilot=quota(진짜), claude-code/openrouter/nvidia
#   =generic(오탐). 상태바 5개 오표시 → 2개로 수정.
#
# 본 가드는 SessionStart 훅 체인에 포함되어 매 세션 시작 시 canonical + 배포본
# nco-statusline.sh 의 리밋 추출 라인을 검사하고, reason 필터가 유실된 회귀
# (`is False: print`)를 감지하면 올바른 라인으로 자동 재패치한다.
# 관련 메모리: feedback_check_provider_limits

set -u
LOG="/tmp/nco-statusline-guard.log"
TS=$(date '+%Y-%m-%d %H:%M:%S')

for F in \
  "$HOME/nova-fleet-config/claude/hooks/nco-statusline.sh" \
  "$HOME/.claude/hooks/nco-statusline.sh"; do
  [ -f "$F" ] || continue
  # 회귀 감지: gate.available is False 로 바로 print (reason 조건 없음)
  if grep -qE "g\.get\('available'\) is False: print" "$F"; then
    python3 - "$F" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
bad  = "if g.get('available') is False: print(x.get('id'))"
good = "if g.get('available') is False and g.get('reason') in ('quota','rate_limit','usage_limit'): print(x.get('id'))"
if bad in s:
    open(p, 'w', encoding='utf-8').write(s.replace(bad, good))
    print("PATCHED")
PY
    echo "$TS [PATCH] $F — reason 필터(quota/rate_limit/usage_limit) 재적용" >> "$LOG"
  fi
done
exit 0
