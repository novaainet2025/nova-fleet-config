#!/bin/bash
# NCO 재귀보호: NCO가 스폰한 서브프로세스 claude에서는 훅 무동작 (2026-07-08, 76s 훅스택+BOOTSTRAP 오염 T1)
[ "${NCO_HOOK_DISABLED:-0}" = "1" ] && exit 0
# mesh-plugin-guard.sh — mesh-receiver plugin의 monitors.json 회귀 방지
#
# SKILL.md는 명시적으로 `when: "on-skill-invoke:mesh-receiver"` (lazy)가
# canonical임을 선언한다. 그러나 plugin update / cache rebuild 시 `always`로
# 회귀하는 사례가 관측됐다(2026-05-26). 회귀 발생 시 stdout이 conversation으로
# 라우팅되지 않아 idle 세션에 mesh DM 자동 inject가 영영 작동 안 함.
#
# 본 가드는 SessionStart 훅 체인에 포함되어 매 세션 시작 시
# monitors.json의 `when` 필드를 검사하고, 'always'면 'on-skill-invoke:mesh-receiver'로
# 자동 교체한다. 교체 시 /tmp/nco-plugin-guard.log에 timestamp + 이전값을 기록.

set -u

MONITORS_JSON="$HOME/.claude/plugins/cache/mesh-receiver/mesh-receiver/0.1.0/monitors/monitors.json"
LOG_FILE="/tmp/nco-plugin-guard.log"
TS=$(date '+%Y-%m-%d %H:%M:%S')

# 파일 없으면 silent skip (plugin 미설치)
[ -f "$MONITORS_JSON" ] || exit 0

CURRENT=$(python3 -c "
import json,sys
try:
    with open('$MONITORS_JSON') as f:
        d=json.load(f)
    for m in d:
        if m.get('name')=='mesh-receiver-poller':
            print(m.get('when','?'))
            break
except Exception as e:
    print(f'ERR:{e}')
" 2>/dev/null)

case "$CURRENT" in
    on-skill-invoke:mesh-receiver)
        # 정상 — silent exit
        exit 0
        ;;
    always)
        # 회귀 발견 → 교체
        python3 -c "
import json
with open('$MONITORS_JSON') as f:
    d=json.load(f)
for m in d:
    if m.get('name')=='mesh-receiver-poller':
        m['when']='on-skill-invoke:mesh-receiver'
with open('$MONITORS_JSON','w') as f:
    json.dump(d,f,indent=2)
    f.write('\n')
" 2>/dev/null
        echo "[$TS] regression detected: when=always → on-skill-invoke:mesh-receiver" >> "$LOG_FILE"
        ;;
    *)
        # 알 수 없는 값 또는 에러 → 로그만 남기고 건드리지 않음
        echo "[$TS] unexpected when value: '$CURRENT' (untouched)" >> "$LOG_FILE"
        ;;
esac

exit 0
