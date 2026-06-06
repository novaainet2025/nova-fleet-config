#!/bin/bash
# NCO AI Status Line — 컬러 + 정확한 세션명 + OS별 백엔드 레이블

# ── ANSI 컬러 ($'...' — bash/zsh/Mac 모두 실제 ESC 문자 저장) ─
R=$'\033[31m'   # 빨강
G=$'\033[32m'   # 초록
Y=$'\033[33m'   # 노랑
B=$'\033[34m'   # 파랑
M=$'\033[35m'   # 마젠타
C=$'\033[36m'   # 시안
W=$'\033[37m'   # 흰색
GR=$'\033[90m'  # 회색
BOLD=$'\033[1m'
DIM=$'\033[2m'
RST=$'\033[0m'

INPUT=$(cat)

# ── 백엔드 감지 ────────────────────────────────────────────────
# 우선순위:
#   1. NCO_STATUSLINE_BACKEND 명시 환경변수
#   2. ANTHROPIC_BASE_URL이 localhost → 로컬 프록시 사용 중
#      - Mac → MLX, WSL/Linux → OLL
#   3. ANTHROPIC_BASE_URL 없음 → Claude API 직접 사용 → 빈 prefix
_detect_backend() {
  [ -n "$NCO_STATUSLINE_BACKEND" ] && { echo "$NCO_STATUSLINE_BACKEND"; return; }
  [ -n "$STATUSLINE_INFERENCE_BACKEND" ] && { echo "$STATUSLINE_INFERENCE_BACKEND"; return; }

  # 로컬 프록시 경유 여부 확인
  local base_url="${ANTHROPIC_BASE_URL:-}"
  if echo "$base_url" | grep -qE "localhost|127\.0\.0\.1"; then
    # 로컬 프록시 사용 중 → OS별 레이블
    if [ "$(uname)" = "Darwin" ]; then echo "MLX"
    else echo "OLL"
    fi
    return
  fi

  # 프록시 없음 = Claude API 직접 → 레이블 없음
  echo ""
}

_detect_ollama_model() {
  # 프록시 /health에서 Ollama URL 조회 → 실제 로드된 모델명 반환
  local ollama_url
  ollama_url=$(curl -s --max-time 1 "http://localhost:4100/health" 2>/dev/null \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('ollama_base_url',''))" 2>/dev/null)
  [ -z "$ollama_url" ] && return
  curl -s --max-time 2 "${ollama_url}/v1/models" 2>/dev/null | python3 -c "
import sys,json,re
try:
  d=json.load(sys.stdin)
  m=d.get('data',[])
  if m:
    mid=m[0].get('id','')
    # gemma4:26b-a4b-it-q4_K_M → gemma4:26b
    mid=re.sub(r'(:[\w]+)-[\w-]+-[\w]+\$', r'\1', mid)
    mid=re.sub(r':[^:]{8,}\$', lambda x: x.group(0)[:6], mid)
    print(mid)
except: pass
" 2>/dev/null
}
_BACKEND=$(_detect_backend)
# "Ollama" (launch.sh 기본값) → 내부 표준 "OLL"로 정규화
[ "$_BACKEND" = "Ollama" ] && _BACKEND="OLL"
# MLX도 "mlx" 소문자로 올 경우 대비
[ "$_BACKEND" = "mlx" ] && _BACKEND="MLX"

# ── 세션 이름 감지 (PID 파일 기반 — NCO_NAME 오염 방지) ──────
_detect_session_name() {
  local names_dir="/tmp/nco-names"
  local my_pid=""

  # Claude Code 프로세스 PID 탐색 (프로세스 트리 위로)
  local ck=$$
  for _i in 1 2 3 4 5; do
    ck=$(ps -o ppid= -p "$ck" 2>/dev/null | tr -d ' ')
    [ -z "$ck" ] && break
    local cm
    cm=$(ps -o comm= -p "$ck" 2>/dev/null)
    if echo "$cm" | grep -qE '^(claude|node)$'; then
      my_pid="$ck"; break
    fi
  done

  [ -z "$my_pid" ] && { echo "${NCO_NAME:-cli}"; return; }

  # PID 파일에서 내 세션 이름 찾기
  if [ -d "$names_dir" ]; then
    for pf in "$names_dir"/claude-*.pid; do
      [ -f "$pf" ] || continue
      local stored
      stored=$(cat "$pf" 2>/dev/null | tr -d '[:space:]')
      if [ "$stored" = "$my_pid" ]; then
        basename "$pf" .pid
        return
      fi
    done
  fi

  # PID 파일 없으면 NCO_NAME 사용, 그것도 없으면 자동 할당
  if [ -n "$NCO_NAME" ]; then
    # NCO_NAME 교차검증: 다른 세션이 같은 이름을 쓰고 있는지 확인
    local conflict_pf="${names_dir}/${NCO_NAME}.pid"
    if [ -f "$conflict_pf" ]; then
      local conflict_pid
      conflict_pid=$(cat "$conflict_pf" 2>/dev/null | tr -d '[:space:]')
      if [ "$conflict_pid" = "$my_pid" ]; then
        echo "$NCO_NAME"; return
      else
        # 충돌: 내 PID로 새 번호 배정
        local n=1
        while [ -f "${names_dir}/claude-${n}.pid" ]; do n=$((n+1)); done
        echo "$my_pid" > "${names_dir}/claude-${n}.pid" 2>/dev/null
        echo "claude-${n}"; return
      fi
    fi
    echo "$NCO_NAME"; return
  fi

  # PID 파일도 NCO_NAME도 없음 → mesh-register 실행 전 상태
  # 자동으로 번호 할당하고 PID 파일 생성 (mesh-register와 충돌 방지: 이미 존재하면 재사용)
  if [ -n "$my_pid" ] && [ -d "$names_dir" ]; then
    local n=1
    while [ -f "${names_dir}/claude-${n}.pid" ]; do n=$((n+1)); done
    echo "$my_pid" > "${names_dir}/claude-${n}.pid" 2>/dev/null
    echo "claude-${n}"; return
  fi
  echo "cli"
}
MY_NAME=$(_detect_session_name)

# ── inter-session 이름용 hostname slug (fleet 통일 2026-06-06) ──
# inter-session connect 이름 = <hostname-slug>-<claude-N> (mesh/NCO 내부명 NCO_NAME은 claude-N 유지)
# hostname은 부팅 후 불변 → 머신 전역 1회 캐시로 렌더마다 hostname(1) 호출 회피
_HOSTSLUG_CACHE="/tmp/nco-names/.hostslug"
if [ -s "$_HOSTSLUG_CACHE" ]; then
  _HOST_SLUG=$(cat "$_HOSTSLUG_CACHE" 2>/dev/null)
else
  _HOST_SLUG=$(hostname 2>/dev/null | tr '[:upper:]' '[:lower:]' | sed -E 's/\.local$//; s/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')
  [ -n "$_HOST_SLUG" ] && { mkdir -p /tmp/nco-names 2>/dev/null; printf '%s' "$_HOST_SLUG" > "$_HOSTSLUG_CACHE" 2>/dev/null; }
fi

# ── Windows %TEMP%\nco-names 미러링 (WSL→Win Claude inter-session 연동) ──
_mirror_nco_names_to_windows() {
  [ -d /mnt/c/Users ] || return 0
  local src="/tmp/nco-names"
  [ -d "$src" ] || return 0
  local win_user="${WINDOWS_USER:-lovecat}"
  local dst="/mnt/c/Users/${win_user}/AppData/Local/Temp/nco-names"
  mkdir -p "$dst" 2>/dev/null || return 0
  rm -f "$dst"/claude-*.pid 2>/dev/null
  for pf in "$src"/claude-*.pid; do
    [ -f "$pf" ] || continue
    cp "$pf" "$dst/" 2>/dev/null
  done
}
_mirror_nco_names_to_windows

# ── NCO 사용 통계 읽기 ────────────────────────────────────────
_get_nco_stats() {
  local sid="$NCO_SESSION_ID"
  if [ -z "$sid" ]; then
    local ck=$$ my_pid=""
    for _i in 1 2 3 4 5; do
      ck=$(ps -o ppid= -p "$ck" 2>/dev/null | tr -d ' ')
      [ -z "$ck" ] && break
      local cm; cm=$(ps -o comm= -p "$ck" 2>/dev/null)
      echo "$cm" | grep -qE '^(claude|node)$' && { my_pid="$ck"; break; }
    done
    sid="${my_pid:-$$}"
  fi
  local tf="/tmp/nco-track-${sid}.json"
  if [ -f "$tf" ]; then
    python3 -c "
import json
try:
    d=json.load(open('$tf'))
    nco=d.get('nco_calls',0); direct=d.get('direct_edits',0)
    total=nco+direct
    pct=int(nco*100/total) if total>0 else 0
    print(f'{pct} {nco} {direct}')
except: print('0 0 0')
" 2>/dev/null
  else
    echo "0 0 0"
  fi
}
read -r _NCO_PCT _NCO_CALLS _DIRECT_EDITS <<< "$(_get_nco_stats)"
_NCO_PCT=${_NCO_PCT:-0}
_NCO_CALLS=${_NCO_CALLS:-0}
_DIRECT_EDITS=${_DIRECT_EDITS:-0}

# ── JSON 파싱 (캐시 지원: 첫 로드에도 정확한 값 표시) ───────────
_SL_CACHE="/tmp/nco-sl-cache-${USER:-$(id -un)}.env"
_PARSED=$(echo "$INPUT" | python3 -c "
import os, sys, json, pathlib, re

CACHE = '${_SL_CACHE}'
backend = '${_BACKEND}'
pwd_dir = os.environ.get('PWD', '.')

def slug_mid(mid):
    if not mid: return '?'
    s = mid.replace(':', '-').replace('_K_M', '-4bit').replace('q4', '4bit')
    if 'gemma4' in s: s = s.replace('gemma4', 'gemma-4')
    s = re.sub(r'-\d{8}$', '', s)
    s = re.sub(r'[\x00-\x1f\x7f\[\]\s]+', '', s)
    return s or '?'

MODEL_ALIAS = {
    'sonnet': 'claude-sonnet-4-6', 'opus': 'claude-opus-4-7',
    'haiku': 'claude-haiku-4-5', 'claude-sonnet': 'claude-sonnet-4-6',
    'claude-opus': 'claude-opus-4-7', 'claude-haiku': 'claude-haiku-4-5',
}

def settings_model():
    for p in [os.path.expanduser('~/.claude/settings.json'),
              os.path.join(pwd_dir, '.claude/settings.json')]:
        try:
            d = json.loads(pathlib.Path(p).read_text())
            m = d.get('model','')
            return MODEL_ALIAS.get(m, m) if m else ''
        except: pass
    return ''

def save_cache(lines):
    try: pathlib.Path(CACHE).write_text('\n'.join(lines))
    except: pass

def load_cache():
    try:
        lines = pathlib.Path(CACHE).read_text().splitlines()
        return dict(l.split('=', 1) for l in lines if '=' in l)
    except: return {}

try:
    d = json.load(sys.stdin)
    m = d.get('model') or {}
    cw = d.get('context_window') or {}
    cost = d.get('cost') or {}
    rl = d.get('rate_limits') or {}
    fh = rl.get('five_hour') or {}
    sd = rl.get('seven_day') or {}
    ws = d.get('workspace') or {}

    mid   = str(m.get('id') or '').strip()
    mname = str(m.get('display_name') or '').strip()
    # 모델 정보가 없으면 settings.json으로 보완
    if not (mid or mname):
        mname = settings_model()
    slug  = slug_mid(mid) if mid else slug_mid(mname)
    bracket = f'[{backend}:{slug}]' if backend else f'[{slug}]'

    ctx_pct  = cw.get('used_percentage', 0)
    cost_usd = cost.get('total_cost_usd', 0.0)

    def pct_val(v):
        try: return int(float(v))
        except: return 0

    day_pct  = pct_val(fh.get('used_percentage', 0))
    week_pct = pct_val(sd.get('used_percentage', 0))

    def get_ts(b):
        return str(b.get('resets_at') or b.get('reset_at') or '')

    proj_dir = ws.get('project_dir') or pwd_dir
    day_reset  = get_ts(fh)
    week_reset = get_ts(sd)

    # 모델 정보가 없으면 캐시에서 보완
    cached = load_cache()
    if not (mid or mname) and cached.get('BRACKET'):
        bracket = cached['BRACKET']
    if not day_reset and cached.get('DAY_RESET'):
        day_reset = cached['DAY_RESET']
    if not week_reset and cached.get('WEEK_RESET'):
        week_reset = cached['WEEK_RESET']

    lines = [
        f'BRACKET={bracket}',
        f'CTX_PCT={int(ctx_pct)}',
        f'COST={cost_usd:.2f}',
        f'RATE_DAY={day_pct}',
        f'RATE_WEEK={week_pct}',
        f'DAY_RESET={day_reset}',
        f'WEEK_RESET={week_reset}',
        f'PERM_MODE={d.get(\"permission_mode\", \"default\")}',
        f'PROJECT_DIR={proj_dir}',
    ]
    # 유효 데이터 있을 때만 캐시 저장
    if mid or mname:
        save_cache(lines)
    print('\n'.join(lines))
except Exception:
    cached = load_cache()
    # 캐시 또는 settings.json에서 모델명 복원
    if cached and cached.get('BRACKET'):
        bracket  = cached['BRACKET']
        proj_dir = cached.get('PROJECT_DIR', pwd_dir)
        day_r    = cached.get('DAY_RESET', '')
        week_r   = cached.get('WEEK_RESET', '')
        perm     = cached.get('PERM_MODE', 'default')
    else:
        sm = settings_model()
        if sm:
            bracket = f'[{backend}:{sm}]' if backend else f'[{sm}]'
        else:
            bracket = f'[{backend}:?]' if backend else '[claude]'
        proj_dir = pwd_dir
        day_r = week_r = ''
        perm = 'default'
    print(f'BRACKET={bracket}')
    print('CTX_PCT=0')
    print('COST=0.00')
    print('RATE_DAY=0')
    print('RATE_WEEK=0')
    print(f'DAY_RESET={day_r}')
    print(f'WEEK_RESET={week_r}')
    print(f'PERM_MODE={perm}')
    print(f'PROJECT_DIR={proj_dir}')
" 2>/dev/null)

while IFS='=' read -r key val; do
  case "$key" in
    BRACKET)    BRACKET="$val" ;;
    CTX_PCT)    CTX_PCT="$val" ;;
    COST)       COST="$val" ;;
    RATE_DAY)   RATE_DAY="$val" ;;
    RATE_WEEK)  RATE_WEEK="$val" ;;
    DAY_RESET)  DAY_RESET="$val" ;;
    WEEK_RESET) WEEK_RESET="$val" ;;
    PERM_MODE)  PERM_MODE="$val" ;;
    PROJECT_DIR) PROJECT_DIR="$val" ;;
  esac
done <<< "$_PARSED"

# ── OLL/MLX 백엔드: 실제 Ollama 모델명 + 로컬 표시 ─────────────
if [ "$_BACKEND" = "OLL" ] || [ "$_BACKEND" = "MLX" ]; then
  _OLLAMA_MODEL=$(_detect_ollama_model)
  [ -n "$_OLLAMA_MODEL" ] && BRACKET="[${_BACKEND}:${_OLLAMA_MODEL}]"
  # 로컬 추론은 Anthropic rate limit 없음 — 하드코딩 폴백값 덮어쓰기
  RATE_DAY=0
  RATE_WEEK=0
  COST=0.00
fi

PROJECT_NAME=$(basename "${PROJECT_DIR:-project}")

# ── 에이전트 라벨 사전 (등록되지 않은 ID는 자동 슬러그 처리) ──
declare -A SHORT=(
  ["claude-code"]="Cla" ["opencode"]="Opn" ["gemini"]="Gem"
  ["codex"]="Cdx" ["cursor-agent"]="Cur"
  ["copilot"]="Cop" ["openrouter"]="ORT" ["nvidia"]="NIM"
  ["ollama"]="OLL" ["higgsfield"]="Hig"
)

# ── NCO 연결 상태 ─────────────────────────────────────────────
API_OK=0; WS_OK=0
(echo > /dev/tcp/localhost/6200) 2>/dev/null && API_OK=1
[ "$API_OK" = "1" ] && (echo > /dev/tcp/localhost/6201) 2>/dev/null && WS_OK=1

DAEMONS=""
[ "$API_OK" = "1" ] && DAEMONS=$(curl -s -m 0.5 http://localhost:6200/api/daemons 2>/dev/null)

# ── ORDER 동적 구성 (NCO 실시간 싱크) ─────────────────────────
# 우선순위:
#   1. 라이브 /api/daemons — enabled=true 만, evicted_providers 제외
#   2. health.json — nco-health-monitor.sh 캐시 (백엔드 다운 시)
#   3. 하드코딩 폴백 (aider 퇴출 반영, 2026-05-14)
_CAPS_FILE="{{HOME}}/.claude/nco-perf/capabilities.json"
_HEALTH_FILE="{{HOME}}/.claude/nco-perf/health.json"
ORDER=()
while IFS= read -r _line; do
  [ -n "$_line" ] && ORDER+=("$_line")
done < <(
  CAPS_FILE="$_CAPS_FILE" HEALTH_FILE="$_HEALTH_FILE" DAEMONS_RAW="$DAEMONS" \
  python3 - <<'PYEOF' 2>/dev/null
import json, os
caps_path = os.environ.get("CAPS_FILE","")
health_path = os.environ.get("HEALTH_FILE","")
daemons_raw = os.environ.get("DAEMONS_RAW","")

evicted = set()
try:
    caps = json.load(open(caps_path))
    evicted = set((caps.get("evicted_providers") or {}).keys())
except Exception:
    pass

ids = []
try:
    if daemons_raw.strip():
        d = json.loads(daemons_raw)
        for it in d.get("daemons", []):
            pid = it.get("id")
            if not pid or pid in evicted:
                continue
            if it.get("enabled") is False:
                continue
            ids.append(pid)
except Exception:
    ids = []

if not ids:
    try:
        h = json.load(open(health_path))
        for pid, p in (h.get("providers") or {}).items():
            if pid in evicted: continue
            if p.get("enabled") is False: continue
            ids.append(pid)
    except Exception:
        pass

if not ids:
    fallback = ["claude-code","opencode","gemini","codex","cursor-agent","copilot","openrouter","nvidia","ollama","higgsfield"]
    ids = [x for x in fallback if x not in evicted]

print("\n".join(ids))
PYEOF
)
if [ "${#ORDER[@]}" -eq 0 ]; then
  ORDER=("claude-code" "opencode" "gemini" "codex" "cursor-agent" "copilot" "openrouter" "nvidia" "ollama" "higgsfield")
fi

# ── 에이전트 상태 표시 ─────────────────────────────────────────
AI_DISPLAY=""
ONLINE=0
for ai in "${ORDER[@]}"; do
  S="${SHORT[$ai]}"
  # 미등록 ID는 첫3글자(첫글자 대문자)로 슬러그 라벨 생성 (bash 3.2 / BSD 호환)
  if [ -z "$S" ]; then
    _raw=$(echo "$ai" | tr -cd 'a-zA-Z0-9' | cut -c1-3)
    if [ -n "$_raw" ]; then
      _first=$(printf '%s' "$_raw" | cut -c1 | tr 'a-z' 'A-Z')
      _rest=$(printf '%s' "$_raw" | cut -c2-)
      S="${_first}${_rest}"
    else
      S="?"
    fi
  fi
  # NCO CLI 프로바이더는 stateless lazy spawn — 위임 시 subprocess spawn → 종료
  # offline = 휴면 상태(정상). enabled && available 이면 "위임 가능"으로 활성 카운트
  INFO=$(echo "$DAEMONS" | jq -r ".daemons[]? | select(.id==\"${ai}\") | \"\(.status) \(.enabled) \(.available)\"" 2>/dev/null)
  read -r STATUS ENABLED AVAILABLE <<< "$INFO"
  case "$STATUS" in
    working|thinking) AI_DISPLAY="${AI_DISPLAY}${G}${S}${RST} "; ((ONLINE++)) ;;
    idle)             AI_DISPLAY="${AI_DISPLAY}${C}${S}${RST} "; ((ONLINE++)) ;;
    offline)
      if [ "$ENABLED" = "true" ] && [ "$AVAILABLE" = "true" ]; then
        AI_DISPLAY="${AI_DISPLAY}${DIM}${C}${S}${RST} "; ((ONLINE++))
      else
        AI_DISPLAY="${AI_DISPLAY}${GR}${S}${RST} "
      fi
      ;;
    *)                AI_DISPLAY="${AI_DISPLAY}${GR}${S}${RST} " ;;
  esac
done

[ "$API_OK" = "1" ] && API_C="${G}api✓${RST}" || API_C="${R}api✗${RST}"
[ "$WS_OK"  = "1" ] && WS_C="${G}ws✓${RST}"  || WS_C="${R}ws✗${RST}"

# ── NCO 사용률 바 (높을수록 좋음 — 색 반전) ─────────────────
nco_bar() {
  local pct=${1:-0}
  local filled=$(( pct * 8 / 100 ))
  local bar_color
  if   [ "$pct" -ge 80 ]; then bar_color="$G"
  elif [ "$pct" -ge 50 ]; then bar_color="$Y"
  else                          bar_color="$R"
  fi
  local bar=""
  for ((i=0; i<8; i++)); do
    [ $i -lt $filled ] && bar="${bar}${bar_color}█${RST}" || bar="${bar}${GR}░${RST}"
  done
  echo "$bar"
}

nco_pct_color() {
  local p=${1:-0}
  if   [ "$p" -ge 80 ]; then echo "${G}${p}%${RST}"
  elif [ "$p" -ge 50 ]; then echo "${Y}${p}%${RST}"
  else                        echo "${R}${p}%${RST}"
  fi
}

# ── 진행 바 ───────────────────────────────────────────────────
make_bar() {
  local pct=${1:-0}
  # 반올림: 9% → (9*8+50)/100=1개, 0% → 0개 (정확한 빈 상태만 0)
  local filled
  if [ "$pct" -gt 0 ]; then
    filled=$(( (pct * 8 + 50) / 100 ))
    [ "$filled" -lt 1 ] && filled=1
  else
    filled=0
  fi
  local bar_color
  # 80%+ 빨강, 50%+ 노랑, 이하 초록
  if   [ "$pct" -ge 80 ]; then bar_color="$R"
  elif [ "$pct" -ge 50 ]; then bar_color="$Y"
  else                          bar_color="$G"
  fi
  local bar=""
  for ((i=0; i<8; i++)); do
    if [ "$i" -lt "$filled" ]; then
      bar="${bar}${bar_color}█${RST}"
    else
      bar="${bar}${GR}░${RST}"
    fi
  done
  echo "$bar"
}

# ── 비율 컬러 ─────────────────────────────────────────────────
pct_color() {
  local p=${1:-0}
  if   [ "$p" -ge 80 ]; then echo "${R}${p}%${RST}"
  elif [ "$p" -ge 50 ]; then echo "${Y}${p}%${RST}"
  else                        echo "${G}${p}%${RST}"
  fi
}

cost_color() {
  local c="$1"
  local ci
  ci=$(echo "$c" | python3 -c "import sys; print(int(float(sys.stdin.read().strip() or 0)))" 2>/dev/null || echo 0)
  if   [ "$ci" -ge 5 ]; then echo "${R}\$${c}${RST}"
  elif [ "$ci" -ge 2 ]; then echo "${Y}\$${c}${RST}"
  else                        echo "${G}\$${c}${RST}"
  fi
}

fmt_reset() {
  local ts="$1"
  [ -z "$ts" ] && echo "${GR}--/-- --:--${RST}" && return
  local result
  if [[ "$ts" =~ ^[0-9]+$ ]]; then
    # epoch → GNU: date -d, Mac BSD: date -r
    result=$(date -d "@${ts}" "+%m/%d %H:%M" 2>/dev/null \
          || date -r "${ts}"  "+%m/%d %H:%M" 2>/dev/null)
  else
    # ISO 8601: GNU: date -d, Mac: python3 폴백
    result=$(date -d "$ts" "+%m/%d %H:%M" 2>/dev/null \
          || python3 -c "from datetime import datetime; print(datetime.fromisoformat('${ts}'.replace('Z','+00:00')).strftime('%m/%d %H:%M'))" 2>/dev/null)
  fi
  [ -n "$result" ] && echo "$result" || echo "${GR}${ts:0:16}${RST}"
}

# ── 세션명 컬러 (claude-1=청록, claude-2=파랑, 기타=회색) ─────
name_color() {
  local n="$1"
  case "$n" in
    claude-1) echo "${C}${BOLD}${n}${RST}" ;;
    claude-2) echo "${B}${BOLD}${n}${RST}" ;;
    claude-3) echo "${M}${BOLD}${n}${RST}" ;;
    claude-4) echo "${Y}${BOLD}${n}${RST}" ;;
    *)        echo "${GR}${BOLD}${n}${RST}" ;;
  esac
}

# ── 브라켓 컬러 ───────────────────────────────────────────────
bracket_color() {
  echo "${DIM}${1}${RST}"
}

# ── 출력 ──────────────────────────────────────────────────────
# 줄1: inter-session명(<hostname>-claude-N: host=dim, claude-N=컬러) + 브라켓(dim) + 📁 프로젝트
if [ -n "$_HOST_SLUG" ] && [ "$MY_NAME" != "cli" ]; then
  _NAME_DISP="${DIM}${_HOST_SLUG}-${RST}$(name_color "$MY_NAME")"
else
  _NAME_DISP="$(name_color "$MY_NAME")"
fi
echo -e "$_NAME_DISP $(bracket_color "$BRACKET") ${GR}📁${RST} ${W}${PROJECT_NAME}${RST}"

# 줄2: API/WS + 에이전트 목록
TOTAL_AGENTS=${#ORDER[@]}
echo -e "  ${API_C} ${WS_C} ${GR}[${RST} ${AI_DISPLAY}${GR}]${RST}${ONLINE}/${TOTAL_AGENTS}"

# 줄3: NCO 사용률 바
echo -e "  ${GR}NCO${RST} $(nco_bar $_NCO_PCT) $(nco_pct_color $_NCO_PCT) ${GR}(NCO:${RST}${_NCO_CALLS}${GR}↑ 직접:${RST}${_DIRECT_EDITS}${GR}↓)${RST}"

# 줄5: 사용량 바 (OLL/MLX: 로컬 표시 / Claude API: rate limit 바)
if [ "$_BACKEND" = "OLL" ] || [ "$_BACKEND" = "MLX" ]; then
  echo -e "  ${G}local · free · ∞${RST} ${GR}|${RST} ${GR}Ctx:${RST}$(pct_color $CTX_PCT) ${GR}|${RST} ${G}\$0.00${RST}"
else
  echo -e "  ${GR}1일${RST} $(make_bar $RATE_DAY) $(pct_color $RATE_DAY) ${GR}·${RST} ${GR}주별${RST} $(make_bar $RATE_WEEK) $(pct_color $RATE_WEEK) ${GR}|${RST} ${GR}Ctx:${RST}$(pct_color $CTX_PCT) ${GR}|${RST} $(cost_color $COST)"
fi

# 줄6: 리셋 시각 (OLL/MLX: Ollama 연결 정보 / Claude API: reset 시각)
if [ "$_BACKEND" = "OLL" ] || [ "$_BACKEND" = "MLX" ]; then
  # Ollama URL 동적 감지 (WSL: 172.28.x.x / Mac: localhost)
  _OLLAMA_DISPLAY_URL=$(curl -s --max-time 1 "http://localhost:4100/health" 2>/dev/null \
    | python3 -c "
import sys,json,re
try:
  d=json.load(sys.stdin)
  u=d.get('ollama_base_url','')
  # 포트만 추출해서 표시
  m=re.search(r'(?:https?://)?([^/]+)', u)
  print(m.group(1) if m else u)
except: print('')
" 2>/dev/null)
  # GPU 정보 감지 (Mac: Apple Silicon / WSL: NVIDIA)
  if [ "$(uname)" = "Darwin" ]; then
    _GPU_LABEL="Apple Silicon"
  else
    _GPU_LABEL=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 | sed 's/NVIDIA GeForce //' | cut -c1-12 || echo "GPU")
  fi
  _PROXY_PORT="4100"
  if [ -n "$_OLLAMA_DISPLAY_URL" ]; then
    echo -e "  ${GR}${_BACKEND} · ${_GPU_LABEL} · ${_OLLAMA_DISPLAY_URL} · proxy:${_PROXY_PORT}${RST}"
  else
    echo -e "  ${GR}${_BACKEND} · ${_GPU_LABEL} · proxy:${_PROXY_PORT}${RST}"
  fi
else
  echo -e "  ${GR}↻ 1일${RST} ${DIM}$(fmt_reset $DAY_RESET)${RST} ${GR}·${RST} ${GR}주별${RST} ${DIM}$(fmt_reset $WEEK_RESET)${RST}"
fi

# Higgsfield 상태 (설치 여부 + auth + 잔여 크레딧/당일 사용량)
_HF_STATUS=$(bash "$HOME/projects/scripts/higgsfield-auth-check.sh" 2>/dev/null; echo $?)
# 잔여 크레딧 + 당일 사용량 (캐시 기반·비블로킹) — "credits|plan|today_spend"
_HF_CRED=$(bash "$HOME/projects/scripts/higgsfield-credits.sh" 2>/dev/null)
IFS='|' read -r _HF_C _HF_PLAN _HF_SPEND <<< "$_HF_CRED"
if [ -n "$_HF_C" ]; then
  _HF_EXTRA=" · ${C}${_HF_C} cr${RST}${GR} · 오늘 -${_HF_SPEND}"
else
  _HF_EXTRA=" · ${DIM}credits…${RST}${GR}"
fi
case "$_HF_STATUS" in
  *$'\n'0|0) echo -e "  ${G}Hig${RST} ${GR}v0.1.40 · online${_HF_EXTRA}${RST}" ;;
  *$'\n'1|1) echo -e "  ${Y}Hig${RST} ${Y}auth-expired — run: higgsfield auth login${RST}" ;;
  *$'\n'2|2) echo -e "  ${GR}Hig${RST} ${GR}not installed${RST}" ;;
  *)          echo -e "  ${GR}Hig${RST} ${GR}unknown${RST}" ;;
esac

# ── 줄6~8: nova-ax (AI-only company) 상태 — 서버 다운 시 무음 ──
# 세션별 사용량: 이 Claude 세션 시작시각(ISO)을 한 번만 마커에 기록 → since로 전달.
# 누적이 아닌 "이 세션에서의 사용량"만 표시(서버가 since 윈도우로 스코프). session_id는 stdin INPUT 기준.
_AX_SID=$(printf '%s' "$INPUT" | python3 -c "
import sys, json
try: print(json.load(sys.stdin).get('session_id','') or '')
except: pass" 2>/dev/null)
_AX_Q=""
if [ -n "$_AX_SID" ]; then
  _axm="/tmp/nco-names/.axstart-${_AX_SID}"
  [ -f "$_axm" ] || date -u +%Y-%m-%dT%H:%M:%S.000Z > "$_axm" 2>/dev/null
  _ax_since=$(cat "$_axm" 2>/dev/null)
  [ -n "$_ax_since" ] && _AX_Q="?since=${_ax_since}&session=${MY_NAME}"
fi
# nova-ax 베이스 URL: NCO_AX_URL env > ~/.claude/.ax-url 파일 > 로컬 기본. (노트북 등 무 nova-ax 노드는 중앙노드 tailnet URL로 원격참조)
_AX_BASE="${NCO_AX_URL:-}"
[ -z "$_AX_BASE" ] && [ -s "$HOME/.claude/.ax-url" ] && _AX_BASE="$(tr -d '[:space:]' < "$HOME/.claude/.ax-url" 2>/dev/null)"
[ -z "$_AX_BASE" ] && _AX_BASE="http://127.0.0.1:6300"
_AX_TEXT=$(curl -s --max-time 0.6 "${_AX_BASE}/api/statusline${_AX_Q}" 2>/dev/null \
  | python3 -c "
import sys, json
try: print(json.load(sys.stdin).get('text','') or '')
except: pass
" 2>/dev/null)
if [ -n "$_AX_TEXT" ]; then
  echo -e "$_AX_TEXT"
fi
