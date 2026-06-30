#!/usr/bin/env bash
# ============================================================
# provider-run.sh — 모든 AI 프로바이더 유니버설 디스패처
# 사용법:
#   provider-run.sh --ai codex --tool exec --prompt "버그 수정"
#   provider-run.sh --ai gemini --tool prompt --prompt "UI 설계"
#   provider-run.sh --ai hermes --tool oneshot --prompt "웹 검색"
#   provider-run.sh --list          # 전체 프로바이더 목록
#   provider-run.sh --info codex    # 특정 프로바이더 상세
# ============================================================

set -euo pipefail

REGISTRY="$HOME/.claude/provider-tools/registry.json"
NCO_API="http://localhost:6200"

# ── 색상 ──────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

_log()  { echo -e "${CYAN}[provider-run]${NC} $*" >&2; }
_ok()   { echo -e "${GREEN}[OK]${NC} $*" >&2; }
_err()  { echo -e "${RED}[ERR]${NC} $*" >&2; exit 1; }
_warn() { echo -e "${YELLOW}[WARN]${NC} $*" >&2; }

# ── --list ─────────────────────────────────────────────────
cmd_list() {
  echo -e "\n${BLUE}=== AI 프로바이더 목록 ===${NC}"
  python3 - <<'PYEOF'
import json, os
reg = json.load(open(os.path.expanduser("~/.claude/provider-tools/registry.json")))
providers = reg["providers"]
print(f"{'ID':18} {'ROLE':16} {'SCORE':6} {'TYPE':6}  도구")
print("-"*70)
for pid, p in providers.items():
    tools = ", ".join(p.get("tools", {}).keys())
    via = " (via NCO)" if p.get("via_nco") else ""
    print(f"{pid:18} {p.get('role','?'):16} {str(p.get('score','?')):6} {p.get('type','?'):6}  {tools}{via}")
PYEOF
  echo ""
  echo -e "${CYAN}NCO API:${NC} $NCO_API/api/task  {ai, prompt}"
}

# ── --info <provider> ──────────────────────────────────────
cmd_info() {
  local pid="$1"
  python3 - "$pid" <<'PYEOF'
import json, os, sys
pid = sys.argv[1]
reg = json.load(open(os.path.expanduser("~/.claude/provider-tools/registry.json")))
p = reg["providers"].get(pid)
if not p:
    print(f"프로바이더 '{pid}' 없음", file=sys.stderr)
    sys.exit(1)
print(f"\n=== {p['name']} [{pid}] ===")
print(f"  Role: {p.get('role')} | Score: {p.get('score')} | Type: {p.get('type')}")
if p.get("binary"): print(f"  Binary: {p['binary']}")
if p.get("via_nco"): print(f"  ⚡ NCO 경유 실행")
print("\n  도구:")
for tname, t in p.get("tools", {}).items():
    print(f"    [{tname}] {t.get('desc','')}")
    print(f"      예시: {t.get('example','')}")
PYEOF
}

# ── NCO 경유 실행 ──────────────────────────────────────────
run_via_nco() {
  local ai="$1" prompt="$2"
  _log "NCO 경유 실행: ai=$ai"

  # NCO 헬스 체크
  if ! curl -sf "$NCO_API/health" >/dev/null 2>&1; then
    _err "NCO 오프라인 ($NCO_API). /nco-start 로 시작하세요."
  fi

  local result
  result=$(curl -s -X POST "$NCO_API/api/task" \
    -H "Content-Type: application/json" \
    -d "{\"ai\":\"$ai\",\"prompt\":$(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$prompt")}")

  echo "$result"
}

# ── CLI 직접 실행 ───────────────────────────────────────────
run_cli() {
  local ai="$1" tool="$2" prompt="$3"
  shift 3
  local extra_args=("$@")

  case "$ai:$tool" in
    # ── Codex ──────────────────────────────────────────────
    codex:exec)
      _log "Codex exec: $prompt"
      codex exec "$prompt" "${extra_args[@]}"
      ;;
    codex:review)
      _log "Codex review"
      codex review "${prompt:-}" "${extra_args[@]}"
      ;;
    codex:apply)
      _log "Codex apply"
      codex apply
      ;;

    # ── OpenCode ───────────────────────────────────────────
    opencode:run)
      _log "OpenCode run: $prompt"
      opencode run "$prompt" "${extra_args[@]}"
      ;;
    opencode:models)
      opencode models
      ;;

    # ── Gemini ─────────────────────────────────────────────
    gemini:prompt)
      _log "Gemini prompt"
      gemini -p "$prompt" "${extra_args[@]}"
      ;;
    gemini:skills_list)
      gemini skills list
      ;;

    # ── Cursor Agent ───────────────────────────────────────
    cursor-agent:prompt)
      _log "Cursor Agent (print mode)"
      cursor-agent --print "$prompt" "${extra_args[@]}"
      ;;
    cursor-agent:plan)
      _log "Cursor Agent (plan mode)"
      cursor-agent --print --mode plan "$prompt" "${extra_args[@]}"
      ;;
    cursor-agent:ask)
      _log "Cursor Agent (ask mode)"
      cursor-agent --print --mode ask "$prompt" "${extra_args[@]}"
      ;;
    cursor-agent:models)
      cursor-agent --list-models
      ;;

    # ── Hermes ─────────────────────────────────────────────
    hermes:oneshot)
      _log "Hermes oneshot: $prompt"
      hermes -z "$prompt" "${extra_args[@]}"
      ;;
    hermes:tools_list)
      hermes tools list
      ;;
    hermes:memory_list)
      hermes memory list
      ;;
    hermes:kanban)
      hermes kanban
      ;;
    hermes:mcp_list)
      hermes mcp list
      ;;
    hermes:skills_list)
      hermes skills list
      ;;

    # ── Copilot ────────────────────────────────────────────
    copilot:prompt)
      _log "Copilot prompt"
      copilot -p "$prompt" --allow-all "${extra_args[@]}"
      ;;
    copilot:plan)
      _log "Copilot plan mode"
      copilot --plan -p "$prompt" --allow-all "${extra_args[@]}"
      ;;

    # ── MLX ────────────────────────────────────────────────
    mlx:generate)
      local model="${MLX_MODEL:-/Users/nova-ai/project/LM-models/mlx/gemma-4-26b-a4b-it-4bit}"
      _log "MLX generate: model=$model"
      mlx_lm.generate --model "$model" --prompt "$prompt" --max-tokens 2048 "${extra_args[@]}"
      ;;
    mlx:server_start)
      local model="${MLX_MODEL:-/Users/nova-ai/project/LM-models/mlx/gemma-4-26b-a4b-it-4bit}"
      local port="${MLX_PORT:-8080}"
      _log "MLX server start: port=$port"
      mlx_lm.server --model "$model" --port "$port" "${extra_args[@]}" &
      _ok "MLX server started (PID=$!) on port $port"
      ;;
    mlx:server_stop)
      pkill -f "mlx_lm.server" && _ok "MLX server stopped" || _warn "No MLX server running"
      ;;

    # ── NCO API via이 providers ────────────────────────────
    nvidia:task|gemini-deep:task|openrouter:task|higgsfield:task|openclaw:task)
      run_via_nco "$ai" "$prompt"
      ;;

    *)
      _err "알 수 없는 조합: ai=$ai, tool=$tool\n  provider-run.sh --list 로 목록 확인"
      ;;
  esac
}

# ── 메인 파서 ───────────────────────────────────────────────
AI=""
TOOL=""
PROMPT=""
EXTRA=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --list|-l)       cmd_list; exit 0 ;;
    --info|-i)       cmd_info "$2"; exit 0 ;;
    --ai|-a)         AI="$2"; shift 2 ;;
    --tool|-t)       TOOL="$2"; shift 2 ;;
    --prompt|-p)     PROMPT="$2"; shift 2 ;;
    --model|-m)      export MLX_MODEL="$2"; shift 2 ;;
    --port)          export MLX_PORT="$2"; shift 2 ;;
    --*)             EXTRA+=("$1" "${2:-}"); shift 2 2>/dev/null || shift ;;
    *)
      if [[ -z "$PROMPT" ]]; then PROMPT="$1"
      else EXTRA+=("$1"); fi
      shift ;;
  esac
done

[[ -z "$AI" ]]   && _err "필수: --ai <provider>"
[[ -z "$TOOL" ]] && _err "필수: --tool <tool>\n  provider-run.sh --info $AI 로 도구 확인"

# NCO API 경유 프로바이더 자동 처리
case "$AI" in
  nvidia|gemini-deep|openrouter|higgsfield|openclaw)
    if [[ "$TOOL" != "task" ]]; then
      _warn "$AI 는 NCO 경유 실행만 지원. tool=task 로 변환"
      TOOL="task"
    fi
    run_via_nco "$AI" "$PROMPT"
    ;;
  *)
    run_cli "$AI" "$TOOL" "$PROMPT" "${EXTRA[@]}"
    ;;
esac
