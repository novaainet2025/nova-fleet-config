#!/usr/bin/env bash
# Higgsfield 인증 상태 확인 (nco-statusline.sh 용)
# auth token 명령으로 실제 토큰 출력 여부 판별

TOKEN=$(higgsfield auth token 2>/dev/null)

if [ -n "$TOKEN" ] && [[ "$TOKEN" != *"Error"* ]]; then
  echo "online"
else
  echo "auth-expired"
fi
