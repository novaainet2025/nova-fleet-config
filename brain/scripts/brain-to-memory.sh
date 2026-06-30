#!/usr/bin/env bash
# brain-to-memory.sh — brain/ 공유 메모리 → ~/.claude/memory/ 로컬 동기화
#
# 적용 정책: OPT-IN (각 세션 사용자가 직접 활성화)
# ─────────────────────────────────────────────────────────
# fleet-sync.sh는 이 스크립트를 자동 호출하지만,
# 각 세션 사용자가 fleet-sync.sh 실행에 동의한 것 = brain-to-memory 동의.
# brain/ 파일은 ~/.claude/memory/fleet_*.md로 복사될 뿐,
# 기존 로컬 메모리 파일을 덮어쓰거나 삭제하지 않음 (ADD-ONLY).
# ─────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRAIN_DIR="$(dirname "$SCRIPT_DIR")"
TIMESTAMP=$(date "+%Y-%m-%d %H:%M:%S")

# 플랫폼별 메모리 경로 자동 탐지
if [[ "$(uname)" == "Darwin" ]]; then
  # Mac: nova-macstudio, gentop Mac
  PROJECT_SLUG="-Users-$(whoami)-project"
  MEMORY_DIR="$HOME/.claude/projects/$PROJECT_SLUG/memory"
else
  # Linux/WSL: kangnote, subnote, snt
  USER_LOWER=$(whoami | tr '[:upper:]' '[:lower:]')
  # 실제 존재하는 프로젝트 슬러그 찾기
  MEMORY_DIR=""
  for d in "$HOME/.claude/projects/"*/; do
    if [[ -f "$d/MEMORY.md" ]]; then
      MEMORY_DIR="${d%/}/memory"
      break
    fi
  done
  # 없으면 기본 경로
  [[ -z "$MEMORY_DIR" ]] && MEMORY_DIR="$HOME/.claude/projects/-root-project/memory"
fi

mkdir -p "$MEMORY_DIR"

copy_if_exists() {
  local src="$1" dst="$2" label="$3"
  if [[ -f "$src" ]]; then
    cp "$src" "$dst"
    echo "  ✓ $label → $(basename "$dst")"
  else
    echo "  ⚠ $label: 소스 없음 ($src)"
  fi
}

echo "[brain-to-memory] $TIMESTAMP"
echo "  brain: $BRAIN_DIR"
echo "  memory: $MEMORY_DIR"

copy_if_exists "$BRAIN_DIR/memory/shared-feedback.md"  "$MEMORY_DIR/fleet_shared_feedback.md"  "shared-feedback"
copy_if_exists "$BRAIN_DIR/errors/patterns.md"         "$MEMORY_DIR/fleet_error_patterns.md"   "error-patterns"
copy_if_exists "$BRAIN_DIR/improvements/log.md"        "$MEMORY_DIR/fleet_improvement_log.md"  "improvement-log"

echo "$TIMESTAMP" > "$MEMORY_DIR/.brain-sync-ts"

# MEMORY.md 인덱스에 fleet 항목 추가 (없는 경우에만)
MEMORY_INDEX="$MEMORY_DIR/MEMORY.md"
if [[ -f "$MEMORY_INDEX" ]]; then
  declare -A FLEET_ENTRIES
  FLEET_ENTRIES["fleet_shared_feedback.md"]="Fleet 공유 피드백 (크로스 디바이스 규칙)"
  FLEET_ENTRIES["fleet_error_patterns.md"]="Fleet 오류 패턴 라이브러리 (자동 축적)"
  FLEET_ENTRIES["fleet_improvement_log.md"]="Fleet 자가 개선 이력 및 메트릭"

  for fname in "${!FLEET_ENTRIES[@]}"; do
    desc="${FLEET_ENTRIES[$fname]}"
    if ! grep -q "$fname" "$MEMORY_INDEX" 2>/dev/null; then
      echo "- [$desc]($fname) — brain/ 공유 메모리" >> "$MEMORY_INDEX"
      echo "  ✓ MEMORY.md에 $fname 추가"
    fi
  done
fi

echo "[brain-to-memory] 완료"
