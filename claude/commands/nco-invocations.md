# 현재 에이전트 호출 현황을 조회합니다.
# 사용법: /nco-invocations [--all]

PORT=6200
ARGS="${ARGUMENTS:-}"

if echo "$ARGS" | grep -q "\-\-all"; then
  echo "=== 전체 호출 이력 ==="
  curl -s "http://localhost:${PORT}/api/invocations?limit=20" | \
    python3 -c "
import sys,json
d=json.load(sys.stdin)
invocs=d.get('invocations',[])
if not invocs:
    print('  (호출 이력 없음)')
else:
    for inv in invocs:
        status_icon={'pending':'⏳','running':'🔄','completed':'✅','failed':'❌','cancelled':'⊘'}.get(inv.get('status','?'),'?')
        print(f'  {status_icon} [{inv[\"mode\"]}] {inv[\"callerAgentId\"]} → {inv[\"targetAgentId\"]}')
        print(f'     작업: {(inv.get(\"prompt\",\"\") or \"\")[:60]}')
        if inv.get('resultSummary'):
            print(f'     결과: {inv[\"resultSummary\"][:60]}')
        print(f'     시간: {inv[\"createdAt\"]}')
" 2>/dev/null || echo "  NCO 서버 응답 없음 (http://localhost:${PORT})"
else
  echo "=== 활성 에이전트 호출 현황 ==="
  curl -s "http://localhost:${PORT}/api/invocations/overview" | \
    python3 -c "
import sys,json
d=json.load(sys.stdin)
active=d.get('active',[])
recent=d.get('recentCompleted',[])
if not active:
    print('  활성 호출 없음')
else:
    print(f'  활성: {len(active)}개')
    for inv in active:
        print(f'  🔄 {inv[\"callerAgentId\"]} → {inv[\"targetAgentId\"]}: {(inv.get(\"prompt\",\"\") or \"\")[:50]}')
print()
print(f'최근 완료: {len(recent)}개')
for inv in recent[:5]:
    icon='✅' if inv.get('status')=='completed' else '❌'
    print(f'  {icon} {inv[\"callerAgentId\"]} → {inv[\"targetAgentId\"]}: {(inv.get(\"resultSummary\",\"\") or \"\")[:50]}')
" 2>/dev/null || echo "  NCO 서버 응답 없음"
fi
