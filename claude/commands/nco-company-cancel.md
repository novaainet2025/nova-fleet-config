---
description: 실행 중인 NCO 회사 오케스트레이션과 활성 하위 태스크를 취소합니다.
argument-hint: '<runId>'
dangerous: true
---
# 사용법: /nco-company-cancel <runId>

export NCO_API=http://localhost:6200
RUN_ID="$1"

if [ -z "$RUN_ID" ]; then
  echo "사용법: /nco-company-cancel <runId>"
  exit 1
fi

curl -sS --max-time 10 -X POST "$NCO_API/api/orchestrate/$RUN_ID/cancel" \
  -H "Content-Type: application/json" \
  --data-binary '{}' \
  | python3 -m json.tool
