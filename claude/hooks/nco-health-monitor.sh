#!/bin/bash
# NCO 헬스 모니터 + 진단(부분 복구)
# 사용:
#   bash nco-health-monitor.sh             # 한 번 체크 + 보고
#   bash nco-health-monitor.sh --diagnose  # 다운된 프로바이더 진단 + 권장 복구 명령 출력
#                                          # (NCO 백엔드의 /api/agents/<id>/reset 등은 미구현이라 자동 실행 한계)
#   bash nco-health-monitor.sh --json      # 결과를 JSON으로 stdout 출력
#
# 데이터:
#   {{HOME}}/.claude/nco-perf/health.json — 마지막 체크 결과
#   {{HOME}}/.claude/nco-perf/health.log  — 시계열 로그
#
# 주의: NCO 백엔드는 현재 reload·reset·restart 엔드포인트가 'pending implementation'.
#       완전 자동 복구는 백엔드 구현 후 가능. 지금은 진단 + 수동 액션 지침만 제공.

PERF_DIR="{{HOME}}/.claude/nco-perf"
HEALTH_FILE="$PERF_DIR/health.json"
HEALTH_LOG="$PERF_DIR/health.log"
mkdir -p "$PERF_DIR" 2>/dev/null

MODE_RECOVER=0
MODE_JSON=0
for arg in "$@"; do
    [ "$arg" = "--diagnose" ] && MODE_RECOVER=1
    [ "$arg" = "--recover" ] && MODE_RECOVER=1   # 하위호환
    [ "$arg" = "--json" ] && MODE_JSON=1
done

NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# 1) NCO 백엔드 자체
API_OK=0; WS_OK=0
curl -s -m 2 http://localhost:6200/health 2>/dev/null | grep -q '"status":"healthy"' && API_OK=1
(echo > /dev/tcp/localhost/6201) 2>/dev/null && WS_OK=1

# 2) 프로바이더별 상태 가져오기
DAEMONS_JSON=""
[ "$API_OK" = "1" ] && DAEMONS_JSON=$(curl -s -m 3 http://localhost:6200/api/daemons 2>/dev/null)

# 3) CLI 바이너리 직접 헬스 체크 (status: offline일 때만 실시간 체크)
declare -A CLI_VERSIONS
check_cli() {
    local id="$1" cmd="$2" arg="$3"
    local ver
    ver=$(timeout 4 $cmd $arg 2>&1 | head -1 | tr -d '\n')
    if [ -n "$ver" ]; then
        CLI_VERSIONS[$id]="$ver"
        return 0
    fi
    return 1
}

# 4) 결과 합성 (python3로)
RESULT=$(python3 <<PYEOF
import json, os, time, subprocess
now = '$NOW'
api_ok = '$API_OK' == '1'
ws_ok = '$WS_OK' == '1'
try:
    daemons = json.loads('''$DAEMONS_JSON''') if '''$DAEMONS_JSON''' else {'daemons':[]}
except:
    daemons = {'daemons': []}

# CLI 바이너리 체크 정의
cli_checks = [
    ('claude-code', ['claude', '--version']),
    ('opencode',    ['opencode', '--version']),
    ('gemini',      ['gemini', '--version']),
    ('codex',       ['codex', '--version']),
    ('cursor-agent',['cursor-agent', '--version']),
    ('copilot',     ['copilot', '--version']),
]

cli_status = {}
for pid, cmd in cli_checks:
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=4)
        ver = (r.stdout or r.stderr).strip().splitlines()[0] if (r.stdout or r.stderr) else ''
        cli_status[pid] = {'binary_ok': bool(ver and r.returncode == 0), 'version': ver[:80]}
    except Exception as e:
        cli_status[pid] = {'binary_ok': False, 'version': f'ERR: {e}'[:80]}

# API 프로바이더 체크 (openrouter / nvidia / ollama)
api_checks = {}

# Ollama
try:
    import urllib.request
    r = urllib.request.urlopen('http://host.docker.internal:11434/api/tags', timeout=3)
    api_checks['ollama'] = {'ok': r.status == 200, 'status': r.status}
except Exception as e:
    api_checks['ollama'] = {'ok': False, 'error': str(e)[:80]}

# OpenRouter (인증 키 필요하므로 단순 ping)
try:
    r = urllib.request.urlopen('https://openrouter.ai/api/v1/models', timeout=4)
    api_checks['openrouter'] = {'ok': r.status == 200, 'status': r.status}
except Exception as e:
    api_checks['openrouter'] = {'ok': False, 'error': str(e)[:80]}

# NVIDIA
try:
    r = urllib.request.urlopen('https://integrate.api.nvidia.com/v1/models', timeout=4)
    api_checks['nvidia'] = {'ok': r.status == 200, 'status': r.status}
except Exception as e:
    api_checks['nvidia'] = {'ok': False, 'error': str(e)[:80]}

# 데몬 상태 매핑
daemon_map = {d['id']: d for d in daemons.get('daemons', [])}

providers = {}
for pid in ['claude-code','opencode','gemini','codex','cursor-agent','copilot','openrouter','nvidia','ollama']:
    d = daemon_map.get(pid, {})
    p = {
        'id': pid,
        'role': d.get('role'),
        'score': d.get('score'),
        'enabled': d.get('enabled'),
        'available': d.get('available'),
        'status': d.get('status'),
        'circuit_state': (d.get('health') or {}).get('circuitState'),
        'consecutive_failures': (d.get('health') or {}).get('consecutiveFailures', 0),
        'last_error': (d.get('health') or {}).get('lastError'),
    }
    if pid in cli_status:
        p['binary_ok'] = cli_status[pid]['binary_ok']
        p['version'] = cli_status[pid]['version']
        # 종합 평가: bin OK + enabled + available
        p['healthy'] = p['binary_ok'] and p['enabled'] and p['available'] and (p['circuit_state'] != 'open')
    elif pid in api_checks:
        p['api_ok'] = api_checks[pid].get('ok', False)
        p['api_error'] = api_checks[pid].get('error') or api_checks[pid].get('status')
        p['healthy'] = p['api_ok'] and p['enabled'] and (p['circuit_state'] != 'open')
    else:
        p['healthy'] = False
    providers[pid] = p

# 점수 DB 합성
try:
    perf = json.load(open('$PERF_DIR/scores.json'))
    for pid, pdata in providers.items():
        ps = perf.get('providers', {}).get(pid, {})
        if ps:
            total = ps.get('total_calls', 0)
            succ = ps.get('successes', 0)
            pdata['perf'] = {
                'calls': total,
                'success_rate': round(succ/total, 3) if total else None,
                'last_failure': ps.get('last_failure'),
            }
except:
    pass

result = {
    'updated': now,
    'backend': {'api_ok': api_ok, 'ws_ok': ws_ok},
    'providers': providers,
    'summary': {
        'total': len(providers),
        'healthy': sum(1 for p in providers.values() if p.get('healthy')),
        'circuit_open': sum(1 for p in providers.values() if p.get('circuit_state') == 'open'),
    }
}

# 파일에 저장
import os
tmp = '$HEALTH_FILE' + '.tmp'
json.dump(result, open(tmp, 'w'), ensure_ascii=False, indent=2)
os.replace(tmp, '$HEALTH_FILE')

# 로그에 1줄 추가
healthy = result['summary']['healthy']
total = result['summary']['total']
with open('$HEALTH_LOG', 'a') as fp:
    fp.write(f'{now} healthy={healthy}/{total} api={api_ok} ws={ws_ok}\n')

print(json.dumps(result, ensure_ascii=False, indent=2))
PYEOF
)

# 5) 출력
if [ "$MODE_JSON" = "1" ]; then
    echo "$RESULT"
else
    echo "$RESULT" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(f\"\n=== NCO Health @ {d['updated']} ===\")
print(f\"Backend: api={'OK' if d['backend']['api_ok'] else 'DOWN'} ws={'OK' if d['backend']['ws_ok'] else 'DOWN'}\")
print(f\"Providers: {d['summary']['healthy']}/{d['summary']['total']} healthy, {d['summary']['circuit_open']} circuit-open\")
print()
print(f\"{'ID':<14} {'role':<12} {'enabled':<8} {'status':<10} {'healthy':<8} note\")
print('-'*90)
for pid, p in d['providers'].items():
    note = ''
    if not p.get('binary_ok', True) and p.get('version'): note = (p.get('version') or '')[:30]
    if 'api_ok' in p and not p['api_ok']: note = f\"API: {p.get('api_error','?')}\"[:50]
    if p.get('circuit_state') == 'open': note = f\"CIRCUIT OPEN ({p.get('consecutive_failures',0)} fails)\"
    perf = p.get('perf', {})
    if perf.get('success_rate') is not None:
        note += f\" | succ={perf['success_rate']*100:.0f}% ({perf['calls']})\"
    print(f\"{pid:<14} {(p.get('role') or '?')[:12]:<12} {str(p.get('enabled')):<8} {(p.get('status') or '?')[:10]:<10} {'✓' if p.get('healthy') else '✗':<8} {note}\")
"
fi

# 6) 진단 모드 (--diagnose / --recover)
if [ "$MODE_RECOVER" = "1" ]; then
    echo ""
    echo "=== 진단 + 권장 복구 액션 ==="
    echo "주의: NCO /api/*/reset 류는 미구현. 자동 실행은 제한적이며, 대부분 수동 명령 출력."
    echo ""
    echo "$RESULT" | python3 -c "
import json, sys, subprocess
d = json.load(sys.stdin)

# 1) NCO 백엔드 자체
if not d['backend']['api_ok']:
    print('[CRIT] NCO backend DOWN')
    print('  수동: cd {{HOME}}/projects/neural-cli-orchestrator && npm start')
    print('  또는: pm2 restart nco-backend 또는 systemctl restart nco')

# 2) 프로바이더별
for pid, p in d['providers'].items():
    actions = []
    if p.get('circuit_state') == 'open':
        # NCO reset endpoint 시도 (미구현이지만 시도)
        try:
            r = subprocess.run(['curl','-s','-o','/dev/null','-w','%{http_code}','-X','POST',
                f'http://localhost:6200/api/agents/{pid}/reset','-m','3'], capture_output=True, text=True, timeout=5)
            actions.append(f'circuit reset HTTP {r.stdout}')
        except: actions.append('reset endpoint timed out')

    if 'binary_ok' in p and not p['binary_ok']:
        actions.append(f'CLI 실패 ({p.get(\"version\",\"?\")[:50]}) — 수동 점검 필요')

    if 'api_ok' in p and not p['api_ok']:
        if pid == 'ollama':
            actions.append('Windows ollama 서비스 확인 (포트 11434, host.docker.internal)')
        elif pid == 'openrouter':
            actions.append('OPENROUTER_API_KEYS 환경변수 + 네트워크 확인')
        elif pid == 'nvidia':
            actions.append('NVIDIA_API_KEY 환경변수 + 네트워크 확인')

    # NCO 알려진 패턴 (capabilities.json known_issues)
    known = {
        'opencode': 'NCO 백엔드 재시작 후 적용 (ai-providers.json args 변경됨: -m opencode/nemotron-3-super-free)',
        'claude-code': 'NCO 위임 대상에서 제외 권장 (재귀 호출 위험)',
        'cursor-agent': 'discussion 모드 미지원 — 단일 nco-task만 사용',
        'ollama': '큐 정체 시 NCO 백엔드 재시작',
    }
    if not p.get('healthy') and pid in known:
        actions.append(f'알려진 이슈: {known[pid]}')

    if actions:
        print(f'[{pid}]')
        for a in actions: print(f'  → {a}')
"
fi
