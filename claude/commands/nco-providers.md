# 등록된 AI 프로바이더 목록을 확인합니다.
curl -s http://localhost:6200/api/ai-providers | python3 -c "
import sys,json
d=json.load(sys.stdin)
for p in d['providers']:
    status='●' if p.get('enabled') else '○'
    print(f'  {status} {p[\"id\"]:16s} {p[\"role\"]:12s} {p[\"score\"]}점 ({p[\"cost\"]})')
"
