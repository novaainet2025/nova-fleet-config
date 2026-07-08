#!/bin/bash
# NCO 재귀보호: NCO가 스폰한 서브프로세스 claude에서는 훅 무동작 (2026-07-08, 76s 훅스택+BOOTSTRAP 오염 T1)
[ "${NCO_HOOK_DISABLED:-0}" = "1" ] && exit 0
# NCO 라우팅 추천: 작업 유형에 맞는 최적 AI 추천
# 사용:
#   bash nco-route.sh <task_type>          # 추천 AI 출력
#   bash nco-route.sh <task_type> --json   # JSON 출력
#   bash nco-route.sh --list               # 작업유형 + 매핑 전체
#
# 데이터:
#   {{HOME}}/.claude/nco-perf/capabilities.json — 작업유형별 매핑
#   {{HOME}}/.claude/nco-perf/scores.json       — 실측 성공률
#   {{HOME}}/.claude/nco-perf/health.json       — 현재 헬스

PERF_DIR="{{HOME}}/.claude/nco-perf"
CAPS="$PERF_DIR/capabilities.json"
SCORES="$PERF_DIR/scores.json"
HEALTH="$PERF_DIR/health.json"

if [ "$1" = "--list" ]; then
    python3 -c "
import json
caps = json.load(open('$CAPS'))
print('== 작업 유형 ==')
for k, v in caps['task_types'].items():
    p = v.get('primary') or '/'.join(v.get('team', []))
    print(f'{k:<15} → primary: {p}')
print()
print('== 알려진 문제 ==')
for k, v in caps['known_issues'].items():
    print(f'{k}: {v[\"issue\"]}')
"
    exit 0
fi

TASK_TYPE="${1:-unknown}"
JSON_OUT=0
[ "$2" = "--json" ] && JSON_OUT=1

python3 <<PYEOF
import json, os, sys

TASK = '$TASK_TYPE'
JSON_OUT = $JSON_OUT == 1

# 데이터 로드
try: caps = json.load(open('$CAPS'))
except: caps = {'task_types':{}, 'known_issues':{}}
try: scores = json.load(open('$SCORES'))
except: scores = {'providers':{}}
try: health = json.load(open('$HEALTH'))
except: health = {'providers':{}}

tt = caps['task_types'].get(TASK)
if not tt:
    print(f"[알 수 없는 작업 유형: {TASK}]")
    print("사용 가능:", ', '.join(caps['task_types'].keys()))
    sys.exit(1)

# 후보 AI 모으기
candidates = []
for k in ('primary','secondary','review','validation'):
    v = tt.get(k)
    if isinstance(v, str): candidates.append((k, v))
for v in tt.get('implementation', []): candidates.append(('implementation', v))
for v in tt.get('team', []): candidates.append(('team', v))
for v in tt.get('fallback_chain', []): candidates.append(('fallback', v))

# 중복 제거 (순서 유지)
seen = set()
ranked = []
for role, ai in candidates:
    if ai in seen: continue
    seen.add(ai)
    p = health.get('providers', {}).get(ai, {})
    s = scores.get('providers', {}).get(ai, {})
    total = s.get('total_calls', 0)
    succ = s.get('successes', 0)
    rate = (succ/total) if total else None
    issue = caps['known_issues'].get(ai)
    ranked.append({
        'ai': ai,
        'role_for_this_task': role,
        'healthy': p.get('healthy', False),
        'circuit_state': p.get('circuit_state'),
        'enabled': p.get('enabled'),
        'success_rate': round(rate, 3) if rate is not None else None,
        'sample_size': total,
        'known_issue': issue['issue'] if issue else None,
        'last_failure': s.get('last_failure'),
    })

# 정렬: healthy 먼저 → 알려진 이슈 없는 순 → 신뢰도 보정된 성공률 → 표본 크기
# 미측정(success_rate=None)은 effective=0.0으로 강하게 강등하되, confidence가 0이므로 adjusted=0이 됨
# 표본 ≥20부터 confidence=1, 그 미만은 비례 (베이지안 신뢰구간 단순화)
def sort_key(x):
    rate = x['success_rate']
    sample = x['sample_size'] or 0
    effective = rate if rate is not None else 0.0
    confidence = min(sample, 20) / 20
    adjusted = effective * confidence
    return (
        not x['healthy'],
        bool(x['known_issue']),
        -adjusted,
        -sample,
    )
ranked.sort(key=sort_key)

result = {
    'task_type': TASK,
    'description': tt.get('description'),
    'recommended': ranked[0]['ai'] if ranked else None,
    'candidates': ranked,
}

if JSON_OUT:
    print(json.dumps(result, ensure_ascii=False, indent=2))
else:
    print(f"\n=== {TASK} 추천 ===")
    print(f"설명: {tt.get('description','')}")
    print()
    print(f"{'rank':<5} {'AI':<14} {'role':<14} {'healthy':<8} {'success':<10} {'issue':<40}")
    print('-'*90)
    for i, r in enumerate(ranked, 1):
        hr = '✓' if r['healthy'] else '✗'
        sr = f"{r['success_rate']*100:.0f}% ({r['sample_size']})" if r['success_rate'] is not None else 'n/a'
        iss = (r['known_issue'] or '')[:38]
        print(f"{i:<5} {r['ai']:<14} {r['role_for_this_task']:<14} {hr:<8} {sr:<10} {iss}")
    print()
    print(f"→ 권장: nco-task {result['recommended']} '...'")
PYEOF
