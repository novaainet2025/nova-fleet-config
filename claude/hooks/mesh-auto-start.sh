#!/bin/bash
# NCO 재귀보호: NCO가 스폰한 서브프로세스 claude에서는 훅 무동작 (2026-07-08, 76s 훅스택+BOOTSTRAP 오염 T1)
[ "${NCO_HOOK_DISABLED:-0}" = "1" ] && exit 0
# mesh-auto-start.sh — mesh-receiver plugin의 monitors.json `when` 필드 관리
# inter-session auto_start.py 대응. SKILL.md 'auto-start' 서브커맨드의 백엔드.
#
# 정책 (CLAUDE.md "Mesh 프롬프트 주입 — 자동화 절대 규칙"):
#   - 'on-skill-invoke:mesh-receiver' (lazy)만 canonical
#   - 'always' 모드 설정 시도는 거부 — mesh-plugin-guard.sh가 SessionStart마다 복원
#
# 사용:
#   mesh-auto-start.sh --status   # 현재 when 값 출력
#   mesh-auto-start.sh --off      # lazy(on-skill-invoke) 강제 (정상 상태 보장)
#   mesh-auto-start.sh --on       # 거부 + 경고 (always는 금지)

set -u

MONITORS_JSON="$HOME/.claude/plugins/cache/mesh-receiver/mesh-receiver/0.1.0/monitors/monitors.json"
CMD="${1:---status}"

[ -f "$MONITORS_JSON" ] || { echo "ERR: monitors.json not found"; exit 1; }

CURRENT=$(python3 -c "
import json
with open('$MONITORS_JSON') as f:
    d=json.load(f)
for m in d:
    if m.get('name')=='mesh-receiver-poller':
        print(m.get('when','?'))
        break
" 2>/dev/null)

case "$CMD" in
    --status)
        echo "when: $CURRENT"
        case "$CURRENT" in
            on-skill-invoke:mesh-receiver) echo "policy: lazy (canonical, OK)" ;;
            always) echo "policy: VIOLATION (always 금지) — mesh-plugin-guard.sh가 다음 SessionStart에 복원" ;;
            *) echo "policy: unknown" ;;
        esac
        ;;
    --off)
        # lazy 모드 강제 (안전한 정상 상태)
        if [ "$CURRENT" = "on-skill-invoke:mesh-receiver" ]; then
            echo "already lazy (no change)"
        else
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
"
            echo "set to lazy (on-skill-invoke:mesh-receiver)"
        fi
        ;;
    --on)
        # always 모드 — 거부
        cat >&2 <<EOF
REJECTED: 'always' 모드는 CLAUDE.md 절대 규칙에 의해 금지.
이유: daemon 모드는 stdout이 queue.log로만 가서 idle 세션에 자동 inject 불가.
정상 모드(lazy)를 유지하려면: mesh-auto-start.sh --off
EOF
        exit 1
        ;;
    *)
        echo "Usage: mesh-auto-start.sh --status|--off"
        echo "  --status  현재 when 값 + 정책 위반 여부"
        echo "  --off     lazy(on-skill-invoke) 강제"
        echo "  --on      거부됨 (always 금지)"
        exit 2
        ;;
esac
