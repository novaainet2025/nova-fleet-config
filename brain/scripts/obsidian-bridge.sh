#!/usr/bin/env bash
# obsidian-bridge.sh — (Mac only) Obsidian vault ↔ brain/ 양방향 동기화
# 방향: brain/ → Obsidian (push) + ~/.claude/memory/ → brain/ (pull-back)
# 실행: 자동 (apply.sh Mac 섹션) 또는 수동
set -euo pipefail

[[ "$(uname)" != "Darwin" ]] && { echo "[obsidian-bridge] Mac 전용 — 스킵"; exit 0; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRAIN_DIR="$(dirname "$SCRIPT_DIR")"
VAULT="$HOME/obsidian/mac-obsidian"
TIMESTAMP=$(date "+%Y-%m-%d %H:%M:%S")

[[ ! -d "$VAULT" ]] && { echo "[obsidian-bridge] Obsidian vault 없음: $VAULT — 스킵"; exit 0; }

echo "[obsidian-bridge] $TIMESTAMP"

# ─── brain/ → Obsidian (06-MEMORY/fleet/) ────────────────────
FLEET_VAULT="$VAULT/06-MEMORY/fleet"
mkdir -p "$FLEET_VAULT"

sync_to_vault() {
  local src="$1" dst="$2"
  [[ -f "$src" ]] && cp "$src" "$dst" && echo "  ✓ → Obsidian: $(basename "$dst")"
}

sync_to_vault "$BRAIN_DIR/memory/shared-feedback.md"  "$FLEET_VAULT/shared-feedback.md"
sync_to_vault "$BRAIN_DIR/errors/patterns.md"         "$FLEET_VAULT/error-patterns.md"
sync_to_vault "$BRAIN_DIR/improvements/log.md"        "$FLEET_VAULT/improvement-log.md"

# ─── ~/.claude/memory/ → brain/memory/ (신규 항목 역방향 수집) ──
MEMORY_DIR="$HOME/.claude/projects/-Users-nova-ai-project/memory"
if [[ -d "$MEMORY_DIR" ]]; then
  # MEMORY.md에서 feedback_ 항목 파싱 → shared-feedback.md에 누락된 것 추가
  SHARED="$BRAIN_DIR/memory/shared-feedback.md"
  NEW_COUNT=0
  while IFS= read -r line; do
    fname=$(echo "$line" | grep -oP '\(feedback_[^)]+\.md\)' | tr -d '()' || true)
    [[ -z "$fname" ]] && continue
    [[ -f "$MEMORY_DIR/$fname" ]] || continue
    # 파일 내용에서 이름 추출
    name=$(grep "^name:" "$MEMORY_DIR/$fname" 2>/dev/null | sed 's/name: //' || echo "$fname")
    # shared-feedback.md에 이미 언급된 파일명이면 스킵
    grep -q "$fname" "$SHARED" 2>/dev/null && continue
    # 신규 피드백: brain/memory/local-feedback/ 에 저장
    mkdir -p "$BRAIN_DIR/memory/local-feedback"
    cp "$MEMORY_DIR/$fname" "$BRAIN_DIR/memory/local-feedback/$fname"
    NEW_COUNT=$((NEW_COUNT + 1))
  done < "$MEMORY_DIR/MEMORY.md" 2>/dev/null || true
  [[ "$NEW_COUNT" -gt 0 ]] && echo "  ✓ 로컬 피드백 $NEW_COUNT개 → brain/memory/local-feedback/"
fi

# ─── Obsidian 06-MEMORY/memory-index.md 갱신 ────────────────
VAULT_INDEX="$VAULT/06-MEMORY/memory-index.md"
if [[ -f "$VAULT_INDEX" ]]; then
  for fname in shared-feedback error-patterns improvement-log; do
    if ! grep -q "$fname" "$VAULT_INDEX" 2>/dev/null; then
      echo "- [[fleet/$fname]] — Fleet 공유 브레인 (brain/ 동기화)" >> "$VAULT_INDEX"
    fi
  done
  echo "  ✓ Obsidian memory-index.md 갱신"
fi

echo "[obsidian-bridge] 완료 (vault: $VAULT)"
