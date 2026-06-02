#!/usr/bin/env bash
# nova-fleet-config apply — 정본 공유설정을 이 머신에 적용 (경로치환 + 백업 + dry-run)
# 사용: apply.sh [--dry-run]    canonical=claude-3. 다른 머신은 pull 후 실행.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$HOME/.claude"
DRY=0; [ "${1:-}" = "--dry-run" ] && DRY=1
OS="$(uname -s)"; USR="$(whoami)"
log(){ echo "[fleet-apply] $*"; }
sub(){ sed -e "s|{{HOME}}|$HOME|g" -e "s|{{USER}}|$USR|g" -e "s|{{OS}}|$OS|g"; }

# ★ 안전가드: SSOT가 아직 안 채워진 빈 골격이면 적용 거부 (실수로 빈설정 적용 방지)
HK=$(ls "$ROOT"/claude/hooks/*.sh 2>/dev/null | wc -l | tr -d " ")
if [ "$HK" -eq 0 ]; then
  echo "[fleet-apply] \u26d4 SSOT 미populated (hooks=0). canonical(claude-3)가 채운 뒤 실행하세요. 적용 거부."
  echo "[fleet-apply] 참고: 이 스크립트는 rm 없이 *존재 파일만 복사*하므로 기존 ~/.claude는 안전합니다."
  exit 2
fi

if [ $DRY -eq 0 ]; then
  BK="$DEST/_fleet-backup-$(date +%Y%m%d-%H%M%S)"; mkdir -p "$BK"
  cp -R "$DEST/hooks" "$BK/" 2>/dev/null; cp -R "$DEST/commands" "$BK/" 2>/dev/null; cp "$DEST/settings.json" "$BK/" 2>/dev/null
  log "백업: $BK"
fi
# hooks (템플릿 치환)
for f in "$ROOT"/claude/hooks/*.sh; do [ -f "$f" ] || continue; n="$(basename "$f")"
  if [ $DRY -eq 1 ]; then log "DRY hook: $n"; else sub <"$f" >"$DEST/hooks/$n"; chmod +x "$DEST/hooks/$n"; log "hook: $n"; fi; done
# commands
[ $DRY -eq 0 ] && cp "$ROOT"/claude/commands/*.md "$DEST/commands/" 2>/dev/null && log "commands 적용"
# skills (공유 스킬 — OS전용은 canonical에서 제외됨)
if [ $DRY -eq 0 ] && [ -d "$ROOT/claude/skills" ]; then
  mkdir -p "$DEST/skills"
  for sk in "$ROOT"/claude/skills/*/; do [ -d "$sk" ] && cp -R "${sk%/}" "$DEST/skills/" 2>/dev/null; done
  log "skills 적용: $(ls "$ROOT/claude/skills" 2>/dev/null | tr '\n' ' ')"
fi
# settings: 안전 위해 자동 덮어쓰기 금지 — 템플릿 머지 안내(비밀/ local 보존)
log "settings.template.json 은 수동검토 머지 권장(비밀 보존). 참고: $ROOT/claude/settings.template.json"
# providers 점검 (설치는 강제 안 함 — 누락만 보고)
log "provider 점검:"; while read -r p ver _; do [ -z "${p:-}" ] && continue; case "$p" in \#*) continue;; esac
  command -v "$p" >/dev/null 2>&1 && echo "  $p ✓" || echo "  $p ✗ 설치필요(${ver:-})"; done < "$ROOT/providers.list"
log "적용 완료 (dry=$DRY). settings/hooks 변경은 다음 세션부터 반영. 롤백: $DEST/_fleet-backup-*"
