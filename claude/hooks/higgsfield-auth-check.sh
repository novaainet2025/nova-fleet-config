#!/usr/bin/env bash
# NCO 재귀보호: NCO가 스폰한 서브프로세스 claude에서는 훅 무동작 (2026-07-08, 76s 훅스택+BOOTSTRAP 오염 T1)
[ "${NCO_HOOK_DISABLED:-0}" = "1" ] && exit 0
# Higgsfield 인증 상태 확인 (nco-statusline.sh 용)
# auth token 명령으로 실제 토큰 출력 여부 판별

TOKEN=$(higgsfield auth token 2>/dev/null)

if [ -n "$TOKEN" ] && [[ "$TOKEN" != *"Error"* ]]; then
  echo "online"
else
  echo "auth-expired"
fi
