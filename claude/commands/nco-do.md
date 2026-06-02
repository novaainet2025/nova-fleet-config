# Plan을 실행합니다. 칸반 태스크를 순차/병렬로 에이전트에게 위임합니다.
# $ARGUMENTS를 Plan ID로 사용합니다.
# 형식: /nco-do <planId> [sequential|parallel|auto]

_ARGS="$ARGUMENTS"
PLAN_ID=$(printf '%s' "$_ARGS" | cut -d' ' -f1)
STRATEGY=$(printf '%s' "$_ARGS" | cut -d' ' -f2-)

if [ -z "$PLAN_ID" ]; then
  echo "[nco-do] planId가 필요합니다."
  echo ""
  echo "사용법: /nco-do <planId> [sequential|parallel|auto]"
  echo ""
  echo "현재 플랜 목록:"
  curl -s http://localhost:6200/api/kanban 2>/dev/null | python3 -c "
import sys,json
try:
  d=json.load(sys.stdin)
  plans=d.get('plans',d.get('data',[]))
  if not plans:
    print('  (플랜 없음 — /nco-plan으로 먼저 생성하세요)')
  for p in plans[:10]:
    print(f'  {p.get(\"id\",\"?\")} — {p.get(\"title\",p.get(\"name\",\"?\")):40} [{p.get(\"status\",\"?\")}]')
except:
  print('  (목록 조회 실패)')
" 2>/dev/null
  exit 1
fi

jq -n --arg planId "$PLAN_ID" --arg strategy "${STRATEGY:-auto}" \
  '{"planId":$planId,"strategy":$strategy}' \
  | curl -s -X POST http://localhost:6200/api/plan/execute \
      -H "Content-Type: application/json" \
      --data-binary @- \
  | python3 -m json.tool
