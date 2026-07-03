#!/usr/bin/env bash
# nova-fleet sync-on-connect — SessionStart 시 SSOT 자동 동기화
#
# 동작:
#   1) git pull --rebase (AUTOSYNC=1이면 동기 blocking 15s, 아니면 bg)
#   2) AUTOSYNC=1이면 무조건 apply.sh 실행 (파일 수/내용 변경 모두 반영)
#   3) AUTOSYNC=0이면 파일 수 드리프트만 리포트 (기존 동작)
#
# env:
#   NCO_FLEET_REPO        SSOT 클론 위치 (기본 $HOME/nova-fleet-config)
#   NCO_FLEET_AUTOSYNC=1  pull(동기) + apply.sh 자동 실행
#   --apply               AUTOSYNC=1과 동일
#
# 수정 이력:
#   2026-07-03 — 결함 수정: ①파일 수 비교만으로 내용 변경을 못 잡던 문제
#                ②local>canonical이면 drift 없다고 오판하던 방향 오류
#                ③bg pull이 sync 판단 전에 완료 안 되던 타이밍 문제
#                → AUTOSYNC=1이면 항상 pull(동기)+apply로 내용 변경도 반영
#   2026-07-03 — 추가 수정: ④apply.sh --force 누락으로 _fleet_preserve 보존가드 차단
#                ⑤dirty tree 시 git pull --rebase 즉시 실패(exit 128) 무증상 버그
#                ⑥macOS timeout 명령 없음(gtimeout 폴백 추가)
set -uo pipefail

# macOS timeout 폴백 (GNU coreutils gtimeout 또는 무제한)
_TIMEOUT=""
if command -v timeout >/dev/null 2>&1; then
  _TIMEOUT="timeout 15"
elif command -v gtimeout >/dev/null 2>&1; then
  _TIMEOUT="gtimeout 15"
fi

REPO="${NCO_FLEET_REPO:-$HOME/nova-fleet-config}"
APPLY=0; [ "${NCO_FLEET_AUTOSYNC:-0}" = "1" ] && APPLY=1
for a in "$@"; do [ "$a" = "--apply" ] && APPLY=1; done
log(){ echo "[fleet-sync] $*"; }

[ -d "$REPO/.git" ] || { log "SSOT 클론 없음($REPO). git clone <repo> $REPO 후 사용."; exit 0; }

if [ "$APPLY" -eq 1 ]; then
  # AUTOSYNC 모드: pull 동기 실행 후 apply --force (내용 변경 포함 전부 반영)
  log "AUTOSYNC — git pull 중..."
  # dirty tree 처리: stash → pull → stash pop (git pull --rebase는 dirty tree 거부)
  _stashed=0
  ( cd "$REPO" && git diff --quiet HEAD 2>/dev/null ) || { \
    ( cd "$REPO" && git stash push -q --include-untracked -m "fleet-autosync-$(date +%s)" 2>/dev/null ) && _stashed=1; }
  _pull_out=$(cd "$REPO" && $_TIMEOUT git pull --quiet --rebase origin main 2>&1) && \
    log "pull 완료 ($(cd "$REPO" && git log --oneline -1))" || \
    log "pull 실패(오프라인/dirty?): $_pull_out — 로컬 canonical로 apply 진행"
  if [ "$_stashed" = "1" ]; then
    if ! ( cd "$REPO" && git stash pop -q 2>/dev/null ); then
      log "⚠ stash pop 충돌 — fleet-config 클론에 수동 확인 필요: cd $REPO && git stash show && git stash drop"
    fi
  fi
  log "apply.sh --force 실행 (보존가드 우회, 백업+롤백 내장)"
  bash "$REPO/install/apply.sh" --force 2>&1 | grep -E '^\[fleet-apply\]' | tail -5 || \
    log "apply 실패 — 수동 점검 필요"
  lh=$(ls "$HOME"/.claude/hooks/*.sh 2>/dev/null | wc -l | tr -d ' ')
  lc=$(ls "$HOME"/.claude/commands/*.md 2>/dev/null | wc -l | tr -d ' ')
  ls_=$(ls -d "$HOME"/.claude/skills/*/ 2>/dev/null | wc -l | tr -d ' ')
  log "✓ 완료 (hooks=$lh commands=$lc skills=$ls_)"
else
  # 리포트 전용: pull bg + 파일 수 드리프트만 확인 (기존 동작)
  ( cd "$REPO" && $_TIMEOUT git pull --quiet --rebase origin main >/dev/null 2>&1 </dev/null & ) >/dev/null 2>&1 || true
  lh=$(ls "$HOME"/.claude/hooks/*.sh 2>/dev/null | wc -l | tr -d ' ')
  ch=$(ls "$REPO"/claude/hooks/*.sh 2>/dev/null | wc -l | tr -d ' ')
  lc=$(ls "$HOME"/.claude/commands/*.md 2>/dev/null | wc -l | tr -d ' ')
  cc=$(ls "$REPO"/claude/commands/*.md 2>/dev/null | wc -l | tr -d ' ')
  ls_=$(ls -d "$HOME"/.claude/skills/*/ 2>/dev/null | wc -l | tr -d ' ')
  cs=$(ls -d "$REPO"/claude/skills/*/ 2>/dev/null | wc -l | tr -d ' ')
  drift=""
  [ "${lh:-0}" -lt "${ch:-0}" ] && drift="$drift hooks($lh<$ch)"
  [ "${lc:-0}" -lt "${cc:-0}" ] && drift="$drift commands($lc<$cc)"
  [ "${ls_:-0}" -lt "${cs:-0}" ] && drift="$drift skills($ls_<$cs)"
  if [ -z "$drift" ]; then
    log "✓ canonical 동기화됨 (hooks=$lh commands=$lc skills=$ls_)"
  else
    log "⚠ canonical 드리프트:$drift — 동기화: bash $REPO/install/apply.sh"
  fi
fi
