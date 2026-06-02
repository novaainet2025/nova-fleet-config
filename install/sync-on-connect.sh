#!/usr/bin/env bash
# nova-fleet sync-on-connect — inter-session 연결/세션시작 시 SSOT와 자동 동기화 점검.
#
# 동작(안전 기본 = read-only 드리프트 리포트):
#   1) SSOT repo 비차단 git pull (timeout)
#   2) 로컬 ~/.claude vs SSOT canonical 카운트 비교 → 드리프트 surface
#   3) NCO_FLEET_AUTOSYNC=1 일 때만 apply.sh 자동 실행 (기본 OFF — 작업 중 clobber 방지)
#
# SessionStart 훅에서 호출 권장(비차단). 수동: bash install/sync-on-connect.sh [--apply]
#
# env:
#   NCO_FLEET_REPO   SSOT 클론 위치 (기본 $HOME/nova-fleet-config)
#   NCO_FLEET_AUTOSYNC=1  드리프트 시 apply.sh 자동 실행 (기본 0)
#   --apply 인자도 자동적용 강제
set -uo pipefail

REPO="${NCO_FLEET_REPO:-$HOME/nova-fleet-config}"
APPLY=0; [ "${NCO_FLEET_AUTOSYNC:-0}" = "1" ] && APPLY=1
for a in "$@"; do [ "$a" = "--apply" ] && APPLY=1; done
log(){ echo "[fleet-sync] $*"; }

[ -d "$REPO/.git" ] || { log "SSOT 클론 없음($REPO). git clone <repo> $REPO 후 사용."; exit 0; }

# 1) SSOT pull — 백그라운드 detach (세션시작 절대 비차단; 결과는 다음 세션에 반영).
#    드리프트 리포트는 아래에서 *현재 로컬 클론* 기준 즉시 출력하므로 pull을 기다리지 않는다.
( cd "$REPO" && timeout 15 git pull --quiet --rebase origin main >/dev/null 2>&1 </dev/null & ) >/dev/null 2>&1 || true

# 2) 드리프트 비교 (canonical = SSOT repo 자체). glob은 비따옴표로 확장.
lh=$(ls "$HOME"/.claude/hooks/*.sh 2>/dev/null | wc -l | tr -d ' ')
ch=$(ls "$REPO"/claude/hooks/*.sh 2>/dev/null | wc -l | tr -d ' ')
lc=$(ls "$HOME"/.claude/commands/*.md 2>/dev/null | wc -l | tr -d ' ')
cc=$(ls "$REPO"/claude/commands/*.md 2>/dev/null | wc -l | tr -d ' ')
ls_=$(ls -d "$HOME"/.claude/skills/*/ 2>/dev/null | wc -l | tr -d ' ')
cs=$(ls -d "$REPO"/claude/skills/*/ 2>/dev/null | wc -l | tr -d ' ')

drift=""
[ "${lh:-0}" -lt "${ch:-0}" ] && drift="$drift hooks($lh/$ch)"
[ "${lc:-0}" -lt "${cc:-0}" ] && drift="$drift commands($lc/$cc)"
[ "${ls_:-0}" -lt "${cs:-0}" ] && drift="$drift skills($ls_/$cs)"

if [ -z "$drift" ]; then
  log "✓ canonical 동기화됨 (hooks=$lh commands=$lc skills=$ls_)"
  exit 0
fi

log "⚠ canonical 드리프트:$drift"
if [ "$APPLY" -eq 1 ]; then
  log "AUTOSYNC → apply.sh 실행 (백업+롤백 내장)"
  bash "$REPO/install/apply.sh" || log "apply 실패 — 수동 점검 필요"
else
  log "동기화하려면: bash $REPO/install/apply.sh   (또는 NCO_FLEET_AUTOSYNC=1)"
fi
