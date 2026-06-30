#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════════════╗
# ║  Nova Fleet Sync — 자동 동기화 스크립트                                  ║
# ║                                                                          ║
# ║  역할: 1시간 간격으로 실행 (시스템 crontab 등록)                           ║
# ║    1. nova-fleet-config git pull → 최신 설정 반영                        ║
# ║    2. apply.sh → Claude Code 훅/명령/스킬 동기화                          ║
# ║    3. 프로바이더 상태 체크 → 미설치 자동 재설치                            ║
# ║    4. NCO 헬스 체크                                                       ║
# ║    5. inter-session으로 감독(nova-macstudio-cli)에게 보고                 ║
# ║                                                                          ║
# ║  사용:                                                                   ║
# ║    직접: bash ~/nova-fleet-config/install/fleet-sync.sh                  ║
# ║    Cron: 자동 (bootstrap.sh이 등록)                                       ║
# ║    강제 재설치: bash ... --reinstall                                      ║
# ╚══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
IFS=$'\n\t'

# ── 경로 설정 ──────────────────────────────────────────────────────────────
FLEET_DIR="$HOME/nova-fleet-config"
NCO_DIR="$HOME/project/nco"
LOG_DIR="$HOME/.claude/logs"
INTER_BIN_CANDIDATES=(
  "$HOME/.claude/plugins/cache/inter-session/inter-session/0.1.2/skills/inter-session/bin"
  "$HOME/.claude/plugins/cache/inter-session/inter-session/0.1.1/skills/inter-session/bin"
  "$HOME/.claude/plugins/cache/inter-session/inter-session/0.1.0/skills/inter-session/bin"
  "$HOME/.claude/skills/inter-session/bin"
)
# 동적 탐지: 버전 디렉터리를 glob으로 검색
for _d in "$HOME/.claude/plugins/cache/inter-session/inter-session"/*/skills/inter-session/bin; do
  [[ -f "$_d/send.py" ]] && INTER_BIN_CANDIDATES=("$_d" "${INTER_BIN_CANDIDATES[@]}")
done
COORDINATOR="nova-macstudio-claude-1"
REINSTALL=false
for arg in "${@:-}"; do [[ "$arg" == "--reinstall" ]] && REINSTALL=true; done

mkdir -p "$LOG_DIR"

# ── 색상 ───────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'
BOLD='\033[1m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[FLEET]${NC} ✓ $*"; }
warn() { echo -e "${YELLOW}[FLEET]${NC} ⚠ $*"; }
err()  { echo -e "${RED}[FLEET]${NC} ✗ $*"; }
info() { echo -e "${CYAN}[FLEET]${NC} ▶ $*"; }

# ── OS 감지 ────────────────────────────────────────────────────────────────
OS="linux"; IS_WSL=false
[[ "$OSTYPE" == "darwin"* ]] && OS="mac"
grep -qi microsoft /proc/version 2>/dev/null && IS_WSL=true

TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
HOSTNAME_SHORT=$(hostname -s 2>/dev/null | tr '[:upper:]' '[:lower:]' | sed 's/\.local$//' || echo "unknown")

echo ""
echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}  Nova Fleet Sync  │  $TIMESTAMP${NC}"
echo -e "${BOLD}  Host: $HOSTNAME_SHORT  │  OS: $OS  │  WSL: $IS_WSL${NC}"
echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

REPORT=()  # 보고서 배열

# ══════════════════════════════════════════════════════════════════════════
# [1] nova-fleet-config git pull
# ══════════════════════════════════════════════════════════════════════════
info "[1/5] nova-fleet-config 최신화..."
if [[ -d "$FLEET_DIR/.git" ]]; then
  # dirty-tree 대응: 로컬 변경이 있으면 stash → pull → pop
  STASHED=false
  if ! git -C "$FLEET_DIR" diff --quiet 2>/dev/null || \
     ! git -C "$FLEET_DIR" diff --cached --quiet 2>/dev/null; then
    git -C "$FLEET_DIR" stash push -m "fleet-sync auto-stash $(date +%Y%m%d-%H%M%S)" \
      --include-untracked 2>/dev/null && STASHED=true \
      || warn "stash 실패 — pull 시도 계속"
  fi

  PULL=$(git -C "$FLEET_DIR" pull --ff-only 2>&1 || echo "pull-failed")

  # stash pop (충돌 시 theirs 채택으로 자동 해결)
  if [[ "$STASHED" == true ]]; then
    if ! git -C "$FLEET_DIR" stash pop 2>/dev/null; then
      warn "stash pop 충돌 — upstream 우선 채택으로 자동 해결"
      git -C "$FLEET_DIR" checkout --theirs . 2>/dev/null || true
      git -C "$FLEET_DIR" add -A 2>/dev/null || true
      git -C "$FLEET_DIR" stash drop 2>/dev/null || true
    fi
  fi

  if echo "$PULL" | grep -qiE "Already up to date|up-to-date|최신"; then
    ok "설정 최신 (변경 없음)"
    REPORT+=("config=up-to-date")
  elif echo "$PULL" | grep -q "pull-failed"; then
    warn "git pull 실패 (네트워크 오류 또는 fast-forward 불가)"
    REPORT+=("config=pull-failed")
  else
    ok "설정 업데이트됨 ↑"
    REPORT+=("config=updated")
  fi
else
  warn "nova-fleet-config 미설치 — bootstrap.sh 재실행 필요"
  REPORT+=("config=missing")
fi

# ══════════════════════════════════════════════════════════════════════════
# [2] apply.sh — Claude 설정 동기화 (훅/명령/스킬)
# ══════════════════════════════════════════════════════════════════════════
info "[2/5] Claude 설정 동기화 (apply.sh)..."
if [[ -f "$FLEET_DIR/install/apply.sh" ]]; then
  if bash "$FLEET_DIR/install/apply.sh" --merge-settings 2>/dev/null; then
    ok "Claude 훅/명령/스킬 동기화 완료"
    REPORT+=("apply=ok")
  else
    warn "apply.sh 실패 — 수동 확인 필요"
    REPORT+=("apply=failed")
  fi
else
  warn "apply.sh 없음"
  REPORT+=("apply=missing")
fi

# ══════════════════════════════════════════════════════════════════════════
# [2b] Brain 공유 메모리 동기화 — brain/ → ~/.claude/memory/
# ══════════════════════════════════════════════════════════════════════════
BRAIN_SYNC="$FLEET_DIR/brain/scripts/brain-to-memory.sh"
if [[ -f "$BRAIN_SYNC" ]]; then
  if bash "$BRAIN_SYNC" 2>/dev/null; then
    ok "brain/ 공유 메모리 동기화 완료"
    REPORT+=("brain=ok")
  else
    warn "brain-to-memory.sh 실패"
    REPORT+=("brain=failed")
  fi
else
  REPORT+=("brain=skipped")
fi

# ══════════════════════════════════════════════════════════════════════════
# [2c] gbrain — brain/ 인덱싱 (있으면 자동 import, 없으면 스킵)
# ══════════════════════════════════════════════════════════════════════════
GBRAIN_BIN=""
for _gb in "$HOME/.bun/bin/gbrain" "$HOME/.local/bin/gbrain" "$(command -v gbrain 2>/dev/null)"; do
  [[ -x "$_gb" ]] && GBRAIN_BIN="$_gb" && break
done
if [[ -n "$GBRAIN_BIN" ]]; then
  if "$GBRAIN_BIN" import "$FLEET_DIR/brain/" --no-embed >/dev/null 2>&1; then
    ok "gbrain: brain/ 인덱싱 완료"
  else
    warn "gbrain import 실패 (무시)"
  fi
fi

# ══════════════════════════════════════════════════════════════════════════
# [3] 프로바이더 상태 체크 + 미설치 자동 재설치
# ══════════════════════════════════════════════════════════════════════════
info "[3/5] 프로바이더 체크..."

_check_cmd() {
  local cmd="$1"
  command -v "$cmd" &>/dev/null \
    || [[ -x "$HOME/.local/bin/$cmd" ]] \
    || [[ -x "$HOME/.bun/bin/$cmd" ]] \
    || [[ -x "/usr/bin/$cmd" ]] \
    || [[ -x "/usr/local/bin/$cmd" ]] \
    || [[ -x "/opt/homebrew/bin/$cmd" ]]
}

MISSING_PROVIDERS=()
PRESENT_PROVIDERS=()

# ── 저사양 머신 로컬 LLM 제외 가드 ────────────────────────────────────────
# 외장 GPU 없음 + 가용 RAM < 8GB 환경에서는 Ollama/MLX를 설치하지 않는다.
# CPU-only 추론은 성능 저하를 유발하므로 제외 (정책: 2026-06-30 사용자 지시)
# 해당 머신: snt (Intel UHD, 5.7GB), subnote (Intel UHD 600, 7.8GB)
_has_gpu() {
  command -v nvidia-smi &>/dev/null && nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | grep -qv "^$"
}
_ram_gb() {
  # Linux: free -b, macOS: vm_stat 기반
  if command -v free &>/dev/null; then
    free -b 2>/dev/null | awk '/^Mem:/{printf "%.0f", $2/1073741824}'
  else
    sysctl -n hw.memsize 2>/dev/null | awk '{printf "%.0f", $1/1073741824}'
  fi
}
LOW_SPEC=false
if ! _has_gpu && [[ "$(_ram_gb)" -lt 8 ]] 2>/dev/null; then
  LOW_SPEC=true
  warn "저사양 감지 (GPU없음 + RAM<8GB) — Ollama/MLX 설치 제외"
fi

# 공통 프로바이더 (로컬 AI 제외 — MLX/Ollama는 하드웨어 조건부)
# set -u와 declare -A 충돌 방지 (bash 일부 버전에서 key를 변수로 해석)
set +u
declare -A PROVIDERS=(
  ["claude"]="npm install -g @anthropic-ai/claude-code"
  ["codex"]="npm install -g @openai/codex"
  ["opencode"]="npm install -g opencode-ai"
  ["gh"]="__SKIP__"  # 별도 apt/brew 설치
  ["copilot"]="npm install -g @github/copilot"
  ["agy"]="curl -fsSL https://antigravity.google/cli/install.sh | bash"
  ["cursor-agent"]="curl -fsSL https://cursor.com/install | bash"
  ["hermes"]="pipx install hermes-agent"
  ["openclaw"]="npm install -g openclaw"
  ["higgsfield"]="npm install -g @higgsfield/cli@latest"
  ["node"]="__SKIP__"  # nvm으로 관리
  ["pm2"]="npm install -g pm2"
  ["bun"]="curl -fsSL https://bun.sh/install | bash"
  ["pipx"]="__SKIP__"  # apt/brew로 관리
)
set -u  # declare -A 완료 후 재활성

for provider in "${!PROVIDERS[@]}"; do
  if _check_cmd "$provider"; then
    PRESENT_PROVIDERS+=("$provider")
  else
    MISSING_PROVIDERS+=("$provider")
  fi
done

# gbrain 별도 체크 (bun 경로)
if _check_cmd "gbrain" || [[ -x "$HOME/.bun/bin/gbrain" ]]; then
  PRESENT_PROVIDERS+=("gbrain")
else
  MISSING_PROVIDERS+=("gbrain")
fi

ok "설치됨 (${#PRESENT_PROVIDERS[@]}): ${PRESENT_PROVIDERS[*]:-없음}"

if [[ ${#MISSING_PROVIDERS[@]} -gt 0 ]]; then
  warn "미설치 (${#MISSING_PROVIDERS[@]}): ${MISSING_PROVIDERS[*]}"
  REPORT+=("missing=${MISSING_PROVIDERS[*]// /,}")

  # 자동 재설치 시도 (--reinstall 또는 설치 커맨드가 있는 경우)
  if [[ "$REINSTALL" == "true" ]]; then
    info "미설치 프로바이더 자동 재설치 중..."
    for p in "${MISSING_PROVIDERS[@]}"; do
      cmd="${PROVIDERS[$p]:-}"
      [[ "$cmd" == "__SKIP__" || -z "$cmd" ]] && continue
      info "  재설치: $p"
      eval "$cmd" 2>/dev/null && ok "  $p 재설치 완료" || warn "  $p 재설치 실패"
    done
  else
    info "자동 재설치: --reinstall 플래그 추가하거나 bootstrap.sh 재실행"
  fi
else
  ok "모든 프로바이더 정상 설치됨"
  REPORT+=("providers=all-ok")
fi

# ══════════════════════════════════════════════════════════════════════════
# [4] NCO + PM2 헬스 체크
# ══════════════════════════════════════════════════════════════════════════
info "[4/5] NCO/PM2 헬스 체크..."

# NCO API
if curl -sf --max-time 3 http://localhost:6200/health 2>/dev/null | grep -q '"status":"healthy"'; then
  ok "NCO API: healthy (localhost:6200)"
  REPORT+=("nco=healthy")
else
  warn "NCO API: 응답 없음 — pm2 start 필요"
  REPORT+=("nco=down")
  # PM2가 있으면 자동 재시작 시도
  if command -v pm2 &>/dev/null && [[ -f "$NCO_DIR/ecosystem.config.cjs" ]]; then
    pm2 start "$NCO_DIR/ecosystem.config.cjs" --update-env 2>/dev/null || true
    info "PM2 재시작 시도됨"
  fi
fi

# inter-session deps 체크
INTER_VENV="$HOME/.claude/data/inter-session/venv"
if [[ -d "$INTER_VENV" ]]; then
  ok "inter-session venv: 정상"
  REPORT+=("inter-session=ok")
else
  warn "inter-session venv 없음"
  REPORT+=("inter-session=missing")
fi

# ══════════════════════════════════════════════════════════════════════════
# [5] inter-session으로 감독에게 보고
# ══════════════════════════════════════════════════════════════════════════
info "[5/5] 감독에게 보고..."

# inter-session bin 경로 탐지
INTER_BIN=""
for candidate in "${INTER_BIN_CANDIDATES[@]}"; do
  [[ -f "$candidate/send.py" ]] && { INTER_BIN="$candidate"; break; }
done

REPORT_STR=$(printf '%s|' "${REPORT[@]}" | sed 's/|$//')
STATUS_MSG="status: host=$HOSTNAME_SHORT ts=$TIMESTAMP $REPORT_STR"

if [[ -n "$INTER_BIN" ]]; then
  # 자신이 감독인지 확인
  MY_NAME=$(python3 "$INTER_BIN/list.py" --self 2>/dev/null \
    | grep 'name=' | sed 's/name=//' | cut -d' ' -f1 2>/dev/null || echo "")

  if [[ "$MY_NAME" == "$COORDINATOR" ]]; then
    # 감독 역할: 전체 브로드캐스트
    python3 "$INTER_BIN/send.py" --all \
      --text "fleet-sync: 감독 체크 완료. 각 세션은 'bash ~/nova-fleet-config/install/fleet-sync.sh' 실행 후 status 보고 바람." \
      2>/dev/null && ok "감독: 전체 sync-check 브로드캐스트 발송" || warn "브로드캐스트 실패"
  else
    # 워커: 감독에게 보고
    python3 "$INTER_BIN/send.py" --to "$COORDINATOR" \
      --text "$STATUS_MSG" 2>/dev/null \
      && ok "감독에게 상태 보고 완료" \
      || warn "감독($COORDINATOR) 오프라인 — 로그에만 기록"
  fi
else
  warn "inter-session bin 없음 — 보고 스킵 (Claude 로그인 후 plugin install inter-session)"
fi

# ── 최종 요약 ──────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${CYAN}  ── Fleet Sync 완료: $TIMESTAMP ──${NC}"
echo -e "  보고서: $REPORT_STR"
echo ""

# 로그 파일에 기록
echo "$TIMESTAMP | $HOSTNAME_SHORT | $REPORT_STR" >> "$LOG_DIR/fleet-sync.log"
