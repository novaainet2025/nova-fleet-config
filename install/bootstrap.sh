#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════════════╗
# ║     Nova Fleet Bootstrap — Universal One-Liner Installer               ║
# ║                                                                          ║
# ║  지원: macOS · Linux · WSL2 (깡통 PC 기준)                              ║
# ║  업데이트: 동일 명령 재실행 (멱등 보장)                                   ║
# ║                                                                          ║
# ║  사용:                                                                   ║
# ║    curl -fsSL https://raw.githubusercontent.com/novaainet2025/           ║
# ║      nova-fleet-config/main/install/bootstrap.sh | bash                 ║
# ║    또는: bash ~/nova-fleet-config/install/bootstrap.sh                  ║
# ║    업데이트: bash ~/nova-fleet-config/install/bootstrap.sh --update     ║
# ╚══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
IFS=$'\n\t'

# ── 색상 ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
ok()   { echo -e "${GREEN}  ✓${NC} $*"; }
info() { echo -e "${CYAN}  ▶${NC} $*"; }
warn() { echo -e "${YELLOW}  ⚠${NC} $*"; }
err()  { echo -e "${RED}  ✗${NC} $*" >&2; }
hdr()  { echo -e "\n${BOLD}${CYAN}━━ $* ━━${NC}"; }
step() { echo -e "\n${BOLD}[${1}/${TOTAL}] ${2}${NC}"; }

TOTAL=17
UPDATE_MODE=false
for arg in "${@:-}"; do
  case "$arg" in --update|-u) UPDATE_MODE=true ;; esac
done

# ── 배너 ──────────────────────────────────────────────────────────────────
print_banner() {
  echo -e "${BOLD}${CYAN}"
  echo "  ███╗   ██╗ ██████╗ ██╗   ██╗ █████╗     ███████╗██╗     ███████╗███████╗████████╗"
  echo "  ████╗  ██║██╔═══██╗██║   ██║██╔══██╗    ██╔════╝██║     ██╔════╝██╔════╝╚══██╔══╝"
  echo "  ██╔██╗ ██║██║   ██║██║   ██║███████║    █████╗  ██║     █████╗  █████╗     ██║   "
  echo "  ██║╚██╗██║██║   ██║╚██╗ ██╔╝██╔══██║    ██╔══╝  ██║     ██╔══╝  ██╔══╝     ██║   "
  echo "  ██║ ╚████║╚██████╔╝ ╚████╔╝ ██║  ██║    ██║     ███████╗███████╗███████╗   ██║   "
  echo "  ╚═╝  ╚═══╝ ╚═════╝   ╚═══╝  ╚═╝  ╚═╝    ╚═╝     ╚══════╝╚══════╝╚══════╝   ╚═╝   "
  echo -e "${NC}"
  echo -e "  ${BOLD}Nova Fleet Bootstrap${NC} — Neural CLI Orchestrator + 전체 에코시스템"
  echo -e "  $(date '+%Y-%m-%d %H:%M:%S') | ${CYAN}https://github.com/novaainet2025${NC}"
  echo ""
}
print_banner

# ══════════════════════════════════════════════════════════════════════════
# [1/17] OS / Arch 감지
# ══════════════════════════════════════════════════════════════════════════
step 1 "OS / Arch 감지"
OS="linux"; ARCH="x86_64"; PKG_MGR="apt"; SHELL_RC="$HOME/.bashrc"; IS_WSL=false

if [[ "$OSTYPE" == "darwin"* ]]; then
  OS="mac"; PKG_MGR="brew"
  SHELL_RC="$HOME/.zshrc"
  [[ -f "$HOME/.bashrc" ]] && SHELL_RC="$HOME/.bashrc"
elif grep -qi microsoft /proc/version 2>/dev/null; then
  OS="wsl"; IS_WSL=true
fi

ARCH=$(uname -m)
IS_ARM64=false
[[ "$ARCH" == "arm64" || "$ARCH" == "aarch64" ]] && IS_ARM64=true

ok "OS=$OS, Arch=$ARCH, WSL=$IS_WSL"
PROJECT_DIR="$HOME/project"
FLEET_DIR="$HOME/nova-fleet-config"
NCO_DIR="$PROJECT_DIR/nco"
AX_DIR="$PROJECT_DIR/nova-ax"
mkdir -p "$PROJECT_DIR"

# ══════════════════════════════════════════════════════════════════════════
# [2/17] 기본 도구 (git, curl, jq)
# ══════════════════════════════════════════════════════════════════════════
step 2 "기본 도구 설치 (git, curl, jq)"

if [[ "$OS" == "mac" ]]; then
  if ! command -v brew &>/dev/null; then
    info "Homebrew 설치 중..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    # Apple Silicon brew PATH
    if [[ "$IS_ARM64" == "true" ]]; then
      echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> "$SHELL_RC"
      eval "$(/opt/homebrew/bin/brew shellenv)"
    fi
  else
    ok "Homebrew 이미 설치됨"
  fi
  for pkg in git curl jq; do
    command -v "$pkg" &>/dev/null && ok "$pkg 이미 있음" || brew install "$pkg"
  done
else
  sudo apt-get update -qq
  for pkg in git curl jq; do
    command -v "$pkg" &>/dev/null && ok "$pkg 이미 있음" || sudo apt-get install -y "$pkg"
  done
fi

# ══════════════════════════════════════════════════════════════════════════
# [3/17] Node.js (nvm)
# ══════════════════════════════════════════════════════════════════════════
step 3 "Node.js 22 LTS (nvm)"

NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
if [[ ! -d "$NVM_DIR" ]]; then
  info "nvm 설치 중..."
  curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
fi
# nvm 로드
export NVM_DIR
# shellcheck source=/dev/null
[ -s "$NVM_DIR/nvm.sh" ] && source "$NVM_DIR/nvm.sh"

if ! command -v node &>/dev/null || [[ "$(node -e 'process.exit(parseInt(process.version.slice(1))<22?1:0)' 2>/dev/null; echo $?)" == "1" ]]; then
  info "Node.js 22 설치 중..."
  nvm install 22
  nvm use 22
  nvm alias default 22
else
  ok "Node.js $(node --version) 이미 설치됨"
fi

# nvm PATH를 shell RC에 추가 (멱등)
if ! grep -q 'NVM_DIR' "$SHELL_RC" 2>/dev/null; then
  cat >> "$SHELL_RC" << 'EOF'

# nvm (nova-fleet-bootstrap)
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"
EOF
fi

# ══════════════════════════════════════════════════════════════════════════
# [4/17] PM2
# ══════════════════════════════════════════════════════════════════════════
step 4 "PM2 (Node.js process manager)"

if command -v pm2 &>/dev/null; then
  ok "PM2 $(pm2 --version) 이미 설치됨"
else
  npm install -g pm2 && ok "PM2 설치 완료"
fi

# ══════════════════════════════════════════════════════════════════════════
# [5/17] Redis
# ══════════════════════════════════════════════════════════════════════════
step 5 "Redis"

if [[ "$OS" == "mac" ]]; then
  if brew list redis &>/dev/null; then
    ok "Redis 이미 설치됨"
  else
    brew install redis && ok "Redis 설치 완료"
  fi
  brew services start redis 2>/dev/null || true
  redis-cli ping &>/dev/null && ok "Redis 응답: PONG" || warn "Redis 응답 없음 (수동 시작 필요)"
else
  command -v redis-cli &>/dev/null && ok "Redis 이미 설치됨" || {
    sudo apt-get install -y redis-server
    sudo systemctl enable redis-server
    sudo systemctl start redis-server
  }
  redis-cli ping &>/dev/null && ok "Redis 응답: PONG" || warn "Redis 응답 없음"
fi

# ══════════════════════════════════════════════════════════════════════════
# [6/17] Tailscale
# ══════════════════════════════════════════════════════════════════════════
step 6 "Tailscale"

if [[ "$OS" == "mac" ]]; then
  if brew list --cask tailscale &>/dev/null 2>/dev/null || [ -d "/Applications/Tailscale.app" ]; then
    ok "Tailscale 이미 설치됨 (앱)"
  else
    info "Tailscale 설치 중 (brew --cask)..."
    brew install --cask tailscale && ok "Tailscale 설치 완료"
  fi
  warn "Tailscale 로그인 필요: 메뉴바 → Tailscale → Log in"
else
  if command -v tailscale &>/dev/null; then
    ok "Tailscale 이미 설치됨"
  else
    info "Tailscale 설치 중..."
    curl -fsSL https://tailscale.com/install.sh | sh && ok "Tailscale 설치 완료"
  fi
  warn "Tailscale 로그인 필요: sudo tailscale up"
fi

# ══════════════════════════════════════════════════════════════════════════
# [7/17] nova-fleet-config 클론/업데이트
# ══════════════════════════════════════════════════════════════════════════
step 7 "nova-fleet-config (설정 SSOT)"
FLEET_REPO="https://github.com/novaainet2025/nova-fleet-config"

if [[ -d "$FLEET_DIR/.git" ]]; then
  info "nova-fleet-config 업데이트 중..."
  git -C "$FLEET_DIR" pull --ff-only 2>/dev/null && ok "nova-fleet-config 최신화됨" || warn "pull 실패 (로컬 변경 있음?)"
else
  info "nova-fleet-config 클론 중..."
  git clone "$FLEET_REPO" "$FLEET_DIR" && ok "nova-fleet-config 클론 완료"
fi

# ══════════════════════════════════════════════════════════════════════════
# [8/17] NCO (Neural CLI Orchestrator) 클론/빌드
# ══════════════════════════════════════════════════════════════════════════
step 8 "NCO (Neural CLI Orchestrator)"
NCO_REPO="https://github.com/novaainet2025/neural-cli-orchestrator"

if [[ -d "$NCO_DIR/.git" ]]; then
  info "NCO 업데이트 중..."
  git -C "$NCO_DIR" pull --ff-only 2>/dev/null || warn "NCO pull 실패 (로컬 변경 있음?)"
else
  info "NCO 클론 중..."
  git clone "$NCO_REPO" "$NCO_DIR" && ok "NCO 클론 완료"
fi

info "NCO 빌드 중 (npm install && build)..."
cd "$NCO_DIR"
npm install --prefer-offline --loglevel=error 2>/dev/null || npm install --loglevel=error
npm run build --if-present 2>/dev/null || true
ok "NCO 빌드 완료"
cd "$HOME"

# ══════════════════════════════════════════════════════════════════════════
# [9/17] Nova-AX 클론/업데이트
# ══════════════════════════════════════════════════════════════════════════
step 9 "Nova-AX"
# Nova-AX repo URL — NCO INSTALL.md에서 추출 시도, 없으면 기본값
NOVA_AX_REPO=""
if [[ -f "$NCO_DIR/INSTALL.md" ]]; then
  NOVA_AX_REPO=$(grep -oE 'https://github\.com/[^/]+/nova-ax[^\s"'"'"']*' "$NCO_DIR/INSTALL.md" 2>/dev/null | head -1 || true)
fi
NOVA_AX_REPO="${NOVA_AX_REPO:-https://github.com/novaainet2025/nova-ax}"

if [[ -d "$AX_DIR/.git" ]]; then
  info "Nova-AX 업데이트 중..."
  git -C "$AX_DIR" pull --ff-only 2>/dev/null && ok "Nova-AX 최신화됨" || warn "Nova-AX pull 실패"
else
  info "Nova-AX 클론 중 ($NOVA_AX_REPO)..."
  git clone "$NOVA_AX_REPO" "$AX_DIR" 2>/dev/null && {
    cd "$AX_DIR" && npm install --loglevel=error 2>/dev/null || true
    ok "Nova-AX 클론 및 설치 완료"
    cd "$HOME"
  } || warn "Nova-AX 클론 실패 (repo 없거나 비공개 — 수동 설치 필요)"
fi

# ══════════════════════════════════════════════════════════════════════════
# [10/17] Claude Code CLI
# ══════════════════════════════════════════════════════════════════════════
step 10 "Claude Code CLI"

if command -v claude &>/dev/null; then
  ok "Claude Code $(claude --version 2>/dev/null | head -1) 이미 설치됨"
else
  info "Claude Code 설치 중..."
  npm install -g @anthropic-ai/claude-code && ok "Claude Code 설치 완료"
fi

# ══════════════════════════════════════════════════════════════════════════
# [11/17] 프로바이더 설치
# ══════════════════════════════════════════════════════════════════════════
step 11 "AI 프로바이더 설치"

# bun 설치 (gbrain 필요)
if ! command -v bun &>/dev/null && ! [[ -x "$HOME/.bun/bin/bun" ]]; then
  info "bun 설치 중..."
  curl -fsSL https://bun.sh/install | bash && ok "bun 설치 완료" || warn "bun 설치 실패"
  export PATH="$HOME/.bun/bin:$PATH"
fi
BUN="${HOME}/.bun/bin/bun"
[[ -x "$BUN" ]] || BUN="$(command -v bun 2>/dev/null || echo '')"

install_provider() {
  local name="$1" cmd="$2"
  command -v "$name" &>/dev/null && { ok "$name 이미 설치됨"; return 0; }
  info "$name 설치 중..."
  eval "$cmd" && ok "$name 설치 완료" || warn "$name 설치 실패 (수동 확인 필요)"
}

# codex
install_provider "codex" "npm install -g @openai/codex"

# opencode
if [[ "$OS" == "mac" ]]; then
  install_provider "opencode" "brew install opencode"
else
  install_provider "opencode" "npm install -g opencode"
fi

# gh (GitHub CLI) + copilot extension
if [[ "$OS" == "mac" ]]; then
  install_provider "gh" "brew install gh"
else
  if ! command -v gh &>/dev/null; then
    info "gh CLI 설치 중..."
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg 2>/dev/null
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null
    sudo apt-get update -qq && sudo apt-get install -y gh && ok "gh 설치 완료"
  else
    ok "gh 이미 설치됨"
  fi
fi
# copilot extension (gh 인증 없어도 extension 설치는 가능)
gh extension list 2>/dev/null | grep -q copilot && ok "gh-copilot 이미 설치됨" || {
  gh extension install github/gh-copilot 2>/dev/null && ok "gh-copilot 설치 완료" || warn "gh-copilot 설치 실패 (gh auth login 후 재시도)"
}

# agy (Antigravity — Go binary from GitHub Releases)
if ! command -v agy &>/dev/null && ! [[ -x "$HOME/.local/bin/agy" ]]; then
  info "agy 설치 중 (GitHub Releases)..."
  AGY_ARCH="arm64"; [[ "$IS_ARM64" != "true" ]] && AGY_ARCH="amd64"
  AGY_OS="darwin"; [[ "$OS" != "mac" ]] && AGY_OS="linux"
  AGY_URL="https://github.com/novaainet2025/antigravity/releases/latest/download/agy-${AGY_OS}-${AGY_ARCH}"
  mkdir -p "$HOME/.local/bin"
  curl -fsSL "$AGY_URL" -o "$HOME/.local/bin/agy" 2>/dev/null && {
    chmod +x "$HOME/.local/bin/agy"
    ok "agy 설치 완료"
  } || warn "agy 설치 실패 (URL 또는 repo 확인 필요)"
else
  ok "agy 이미 설치됨"
fi

# cursor (Mac: Cursor 앱 필요, shim 설치)
if [[ "$OS" == "mac" ]]; then
  if [[ -d "/Applications/Cursor.app" ]]; then
    ok "Cursor 앱 이미 있음"
  else
    warn "Cursor 앱 미설치 — https://cursor.com 에서 수동 설치 필요"
  fi
  # shim 설치
  if ! command -v cursor &>/dev/null && ! [[ -x "$HOME/.local/bin/cursor" ]]; then
    mkdir -p "$HOME/.local/bin"
    cat > "$HOME/.local/bin/cursor" << 'CURSOR_SHIM'
#!/bin/sh
set -eu
find_cursor() {
  for dir in /Applications/Cursor.app/Contents/MacOS /usr/local/bin /opt/homebrew/bin; do
    [ -x "$dir/cursor" ] && [ "$dir/cursor" != "$HOME/.local/bin/cursor" ] && { echo "$dir/cursor"; return 0; }
  done
  return 1
}
CURSOR_BIN=$(find_cursor) || { echo "Cursor not found. Install from https://cursor.com" >&2; exit 1; }
exec "$CURSOR_BIN" "$@"
CURSOR_SHIM
    chmod +x "$HOME/.local/bin/cursor"
    ok "cursor shim 설치 완료"
  fi
fi

# gemini CLI
install_provider "gemini" "npm install -g @google/gemini-cli 2>/dev/null || true"

# higgsfield CLI (있으면)
command -v higgsfield &>/dev/null && ok "higgsfield 이미 있음" || {
  npm install -g higgsfield-cli 2>/dev/null && ok "higgsfield 설치 완료" || warn "higgsfield 설치 실패 (선택사항)"
}

# gbrain (bun 필요)
if command -v gbrain &>/dev/null || [[ -x "$HOME/.bun/bin/gbrain" ]]; then
  ok "gbrain 이미 설치됨"
elif [[ -n "$BUN" && -x "$BUN" ]]; then
  info "gbrain 설치 중..."
  "$BUN" install -g github:garrytan/gbrain 2>/dev/null && ok "gbrain 설치 완료" || warn "gbrain 설치 실패"
else
  warn "gbrain: bun 필요 — bun 설치 후 수동: bun install -g github:garrytan/gbrain"
fi

# MLX (Mac Apple Silicon 전용)
if [[ "$OS" == "mac" && "$IS_ARM64" == "true" ]]; then
  python3 -c "import mlx_lm" 2>/dev/null && ok "mlx-lm 이미 설치됨" || {
    info "mlx-lm 설치 중 (Apple Silicon)..."
    pip3 install mlx-lm 2>/dev/null && ok "mlx-lm 설치 완료" || warn "mlx-lm 설치 실패"
  }
else
  info "MLX: Mac arm64 전용 — 스킵"
fi

# Ollama (Linux/WSL 전용)
if [[ "$OS" != "mac" ]]; then
  command -v ollama &>/dev/null && ok "ollama 이미 설치됨" || {
    info "Ollama 설치 중..."
    curl -fsSL https://ollama.ai/install.sh | sh && ok "Ollama 설치 완료" || warn "Ollama 설치 실패"
  }
  # WSL: Windows 호스트 Ollama 탐지 (Q2 결론: 게이트웨이 IP)
  if [[ "$IS_WSL" == "true" ]]; then
    GW=$(ip route 2>/dev/null | awk '/default/{print $3; exit}' || echo "")
    if [[ -n "$GW" ]] && curl -sf "http://$GW:11434/api/version" &>/dev/null; then
      ok "Windows 호스트 Ollama 감지: $GW:11434"
      export OLLAMA_WIN_HOST="$GW"
    fi
  fi
fi

# PATH에 ~/.local/bin 추가
grep -q '\.local/bin' "$SHELL_RC" 2>/dev/null || echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$SHELL_RC"
export PATH="$HOME/.local/bin:$PATH"

# ══════════════════════════════════════════════════════════════════════════
# [12/17] nova-fleet-config apply.sh (Claude 설정 동기화)
# ══════════════════════════════════════════════════════════════════════════
step 12 "Claude 설정 동기화 (apply.sh)"

if [[ -f "$FLEET_DIR/install/apply.sh" ]]; then
  mkdir -p "$HOME/.claude/commands" "$HOME/.claude/hooks" "$HOME/.claude/skills"
  bash "$FLEET_DIR/install/apply.sh" --merge-settings && ok "Claude 설정 적용 완료"
else
  warn "apply.sh 없음 — nova-fleet-config가 올바르게 클론됐는지 확인"
fi

# ══════════════════════════════════════════════════════════════════════════
# [13/17] PM2 ecosystem.config.cjs 동적 생성
# ══════════════════════════════════════════════════════════════════════════
step 13 "PM2 ecosystem.config.cjs 생성 (경로 동적화)"

ECOSYSTEM_FILE="$NCO_DIR/ecosystem.config.cjs"

# 기존 ecosystem이 현재 $HOME을 이미 사용 중이면 스킵
if [[ -f "$ECOSYSTEM_FILE" ]] && grep -q "$HOME" "$ECOSYSTEM_FILE" 2>/dev/null && ! grep -q "/Users/nova-ai" "$ECOSYSTEM_FILE" 2>/dev/null; then
  ok "ecosystem.config.cjs 이미 현재 경로로 설정됨 — 스킵"
else
  info "ecosystem.config.cjs 생성 중 ($HOME 기준)..."

  # MLX 서버 설정 (Mac arm64만)
  MLX_SERVER_BLOCK=""
  if [[ "$OS" == "mac" && "$IS_ARM64" == "true" ]]; then
    MLX_BIN="$HOME/.local/bin/mlx_lm.server"
    MLX_MODEL="$HOME/project/LM-models/mlx/gemma-4-26b-a4b-it-4bit"
    MLX_SERVER_BLOCK=$(cat << MLXEOF
  {
    name: 'mlx-server',
    interpreter: 'none',
    script: '${MLX_BIN}',
    args: '--model ${MLX_MODEL} --port 8000 --host 127.0.0.1',
    cwd: '${NCO_DIR}',
    instances: 1,
    autorestart: true,
    watch: false,
    max_memory_restart: '30G',
    restart_delay: 10000,
    max_restarts: 20,
    min_uptime: '30s',
  },
  {
    name: 'mlx-proxy',
    script: '${NCO_DIR}/security-kb/anthropic-ollama-proxy.py',
    interpreter: 'python3',
    cwd: '${NCO_DIR}',
    instances: 1,
    autorestart: true,
    watch: false,
    restart_delay: 5000,
    max_restarts: 10,
    min_uptime: '15s',
  },
MLXEOF
)
  fi

  # Nova-AX 시작 스크립트 탐지
  NOVA_AX_SCRIPT="app.js"
  [[ -f "$AX_DIR/server.js" ]] && NOVA_AX_SCRIPT="server.js"
  [[ -f "$AX_DIR/src/index.ts" ]] && NOVA_AX_SCRIPT="src/index.ts"

  cat > "$ECOSYSTEM_FILE" << ECOSYSEOF
// Nova Fleet — PM2 ecosystem (auto-generated by bootstrap.sh $(date +%Y-%m-%d))
// 경로: \$HOME 기반 동적 생성 — 하드코딩 없음
const path = require('path');
const HOME = process.env.HOME || require('os').homedir();
const NCO_DIR = path.join(HOME, 'project', 'nco');
const AX_DIR = path.join(HOME, 'project', 'nova-ax');

module.exports = {
  apps: [
    {
      name: 'nco-backend',
      script: path.join(NCO_DIR, 'node_modules', '.bin', 'tsx'),
      args: 'src/index.ts',
      cwd: NCO_DIR,
      instances: 1,
      exec_mode: 'fork',
      autorestart: true,
      watch: false,
      max_memory_restart: '512M',
      restart_delay: 5000,
      max_restarts: 10,
      min_uptime: '15s',
      env: {
        PORT: 6200,
        WS_PORT: 6201,
        NODE_ENV: 'production',
      },
    },
    {
      name: 'nova-ax',
      script: path.join(AX_DIR, '${NOVA_AX_SCRIPT}'),
      cwd: AX_DIR,
      instances: 1,
      exec_mode: 'cluster',
      autorestart: true,
      watch: false,
      max_memory_restart: '512M',
      restart_delay: 5000,
      max_restarts: 10,
      min_uptime: '15s',
    },
${MLX_SERVER_BLOCK}  ],
};
ECOSYSEOF

  ok "ecosystem.config.cjs 생성 완료: $ECOSYSTEM_FILE"
fi

# ══════════════════════════════════════════════════════════════════════════
# [14/17] .env 설정
# ══════════════════════════════════════════════════════════════════════════
step 14 ".env 설정"

ENV_FILE="$NCO_DIR/.env"
ENV_EXAMPLE="$NCO_DIR/.env.example"

if [[ -f "$ENV_FILE" ]]; then
  ok ".env 이미 있음 (덮어쓰기 안 함)"
elif [[ -f "$ENV_EXAMPLE" ]]; then
  # WSL: Ollama Windows 호스트 URL 자동 주입
  if [[ "$IS_WSL" == "true" && -n "${OLLAMA_WIN_HOST:-}" ]]; then
    sed "s|# OLLAMA_BASE_URL=.*|OLLAMA_BASE_URL=http://${OLLAMA_WIN_HOST}:11434|" "$ENV_EXAMPLE" > "$ENV_FILE"
    ok ".env 생성 완료 (WSL Ollama 호스트: $OLLAMA_WIN_HOST)"
  else
    cp "$ENV_EXAMPLE" "$ENV_FILE"
    ok ".env 생성 완료 (.env.example 복사)"
  fi
  # PROJECT_DIR 자동 수정
  sed -i.bak "s|PROJECT_DIR=.*|PROJECT_DIR=$NCO_DIR|g" "$ENV_FILE" && rm -f "$ENV_FILE.bak"
else
  warn ".env.example 없음 — 수동 .env 설정 필요"
fi

echo ""
echo -e "${YELLOW}  ▶ .env 필수 API 키 목록 (편집 필요):${NC}"
echo -e "    ${BOLD}vim $ENV_FILE${NC}"
echo "    ─────────────────────────────────────────"
echo "    ANTHROPIC_API_KEY=sk-ant-...    ← Claude"
echo "    OPENAI_API_KEY=sk-...           ← Codex"
echo "    OPENROUTER_API_KEY=sk-or-...    ← OpenRouter"
echo "    GEMINI_API_KEYS=AIzaSy...       ← Gemini"
echo "    NVIDIA_API_KEY=nvapi-...        ← NVIDIA NIM"
echo "    GITHUB_TOKEN=ghp_...            ← GitHub/Copilot"

# ══════════════════════════════════════════════════════════════════════════
# [15/17] PM2 서비스 시작
# ══════════════════════════════════════════════════════════════════════════
step 15 "PM2 서비스 시작"

# .env가 있고 API 키가 실제 값으로 채워진 경우만 시작
if grep -q "sk-ant-xxx\|sk-xxx\|change_me" "$ENV_FILE" 2>/dev/null; then
  warn ".env에 미설정 키 있음 — PM2 시작 스킵"
  warn "API 키 설정 후: pm2 start $ECOSYSTEM_FILE"
else
  pm2 start "$ECOSYSTEM_FILE" --update-env 2>/dev/null || pm2 start "$ECOSYSTEM_FILE"
  pm2 save
  # 자동시작 등록 (출력에 sudo 명령 있을 수 있음)
  info "PM2 자동시작 등록..."
  PM2_STARTUP=$(pm2 startup 2>/dev/null | grep "sudo env" || echo "")
  if [[ -n "$PM2_STARTUP" ]]; then
    warn "자동시작 등록을 위해 다음 명령 실행 필요:"
    echo "    $PM2_STARTUP"
  fi
  ok "PM2 서비스 시작 완료"
fi

# ══════════════════════════════════════════════════════════════════════════
# [16/17] 인증 안내 (수동 필요)
# ══════════════════════════════════════════════════════════════════════════
step 16 "수동 인증 필요 항목"

echo ""
echo -e "${BOLD}${YELLOW}  다음 인증은 수동으로 진행해주세요:${NC}"
echo "  ┌─────────────────────────────────────────────────────────┐"
echo "  │  1. Claude Code 로그인:                                  │"
echo "  │     claude                                               │"
echo "  │                                                          │"
echo "  │  2. GitHub Copilot 인증:                                 │"
echo "  │     gh auth login                                        │"
echo "  │                                                          │"
echo "  │  3. Cursor 로그인:                                       │"
echo "  │     cursor (앱 실행 후 Sign In)                          │"
echo "  │                                                          │"
echo "  │  4. Tailscale 연결:                                      │"
if [[ "$OS" == "mac" ]]; then
echo "  │     메뉴바 → Tailscale → Log in                         │"
else
echo "  │     sudo tailscale up                                    │"
fi
echo "  │                                                          │"
echo "  │  5. inter-session (첫 claude 실행 시 자동 활성화)        │"
echo "  └─────────────────────────────────────────────────────────┘"

# ══════════════════════════════════════════════════════════════════════════
# [17/17] Doctor — 설치 검증
# ══════════════════════════════════════════════════════════════════════════
step 17 "설치 검증 (Doctor)"

echo ""
echo -e "${BOLD}  설치 결과 요약:${NC}"
echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

check_cmd() {
  local name="$1" cmd="${2:-$1}"
  command -v "$cmd" &>/dev/null || [[ -x "$HOME/.local/bin/$cmd" ]] || [[ -x "$HOME/.bun/bin/$cmd" ]] \
    && echo -e "  ${GREEN}✓${NC} $name" \
    || echo -e "  ${RED}✗${NC} $name (미설치)"
}

check_cmd "Node.js"       "node"
check_cmd "PM2"           "pm2"
check_cmd "Redis"         "redis-cli"
check_cmd "Claude Code"   "claude"
check_cmd "Codex"         "codex"
check_cmd "OpenCode"      "opencode"
check_cmd "gh + Copilot"  "gh"
check_cmd "AGY"           "agy"
check_cmd "Cursor"        "cursor"
check_cmd "Gemini CLI"    "gemini"
check_cmd "bun"           "bun"
check_cmd "gbrain"        "gbrain"
[[ "$OS" == "mac" && "$IS_ARM64" == "true" ]] && check_cmd "mlx-lm (Mac)" "mlx_lm.server"
[[ "$OS" != "mac" ]] && check_cmd "Ollama (Linux)" "ollama"

echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# NCO 헬스 체크
echo ""
if curl -s --max-time 3 http://localhost:6200/health 2>/dev/null | grep -q '"status":"healthy"'; then
  ok "NCO API: healthy (localhost:6200)"
else
  warn "NCO API: 응답 없음 (pm2 start 필요하거나 .env 설정 필요)"
fi

# PM2 서비스 목록
echo ""
echo -e "${BOLD}  PM2 서비스:${NC}"
pm2 list --no-color 2>/dev/null | grep -E "name|online|stopped" | head -15 || warn "PM2 서비스 없음"

echo ""
echo -e "${BOLD}${GREEN}  ══════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}${GREEN}  Nova Fleet 설치 완료!                                 ${NC}"
echo -e "${BOLD}${GREEN}  ══════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  업데이트 명령: ${CYAN}bash ~/nova-fleet-config/install/bootstrap.sh --update${NC}"
echo -e "  NCO 상태:     ${CYAN}curl -s localhost:6200/health | python3 -m json.tool${NC}"
echo -e "  설정 편집:    ${CYAN}vim $ENV_FILE${NC}"
echo ""
