# 활성 토론 세션 목록을 조회합니다.
# 사용법: /nco-sessions

echo "=== NCO 세션 목록 ==="

curl -s http://localhost:6200/api/realtime-sessions \
  | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    sessions = data if isinstance(data, list) else data.get('sessions', [])
    if not sessions:
        print('  (활성 세션 없음)')
    else:
        for s in sessions:
            sid = s.get('id', '?')[:12]
            status = s.get('status', '?')
            topic = s.get('topic') or s.get('prompt', '')[:60]
            providers = ', '.join(s.get('providers', []))
            print(f'  [{sid}] {status} | {providers}')
            print(f'    주제: {topic}')
except:
    print('  (NCO 오프라인 또는 응답 없음)')
" 2>/dev/null || echo "[오류] NCO 서버 응답 없음 — /nco-start 로 NCO를 먼저 시작하세요."
