#!/bin/bash
# NCO AI Status Line — 컬러 + 정확한 세션명 + OS별 백엔드 레이블
# v2 — fast-path + background refresh (v2.1.109 timeout 대응)
#
# 아키텍처:
#   - 모든 네트워크 호출은 캐시에서 읽는다 (< 50ms)
#   - 백그라운드 워커가 캐시를 비동기 갱신한다 (스크립트와 독립)
#   - 스크립트 자체는 항상 200ms 이내에 완료되어야 한다

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

# ── 캐시 디렉터리 ─────────────────────────────────────────────
_CACHE_DIR="/tmp/nco-sl-cache-${USER:-$(id -un)}"
mkdir -p "$_CACHE_DIR" 2>/dev/null

# ── 백그라운드 네트워크 갱신 워커 (비동기, 스크립트와 무관) ────
# 락 파일로 중복 실행 방지 (TTL 8초)
_BG_LOCK="${_CACHE_DIR}/bg.lock"
_now_ts=$(date +%s 2>/dev/null || echo 0)
_lock_ts=0
[ -f "$_BG_LOCK" ] && _lock_ts=$(cat "$_BG_LOCK" 2>/dev/null || echo 0)
_lock_age=$(( _now_ts - _lock_ts ))

if [ "$_lock_age" -gt 8 ]; then
  printf '%s' "$_now_ts" > "$_BG_LOCK" 2>/dev/null
  (
    # NCO API/WS
    _api=0; _ws=0
    (echo > /dev/tcp/localhost/6200) 2>/dev/null && _api=1
    [ "$_api" = "1" ] && (echo > /dev/tcp/localhost/6201) 2>/dev/null && _ws=1
    printf '%s %s' "$_api" "$_ws" > "${_CACHE_DIR}/nco-conn" 2>/dev/null

    # NCO daemons
    if [ "$_api" = "1" ]; then
      _d=$(curl -s -m 1 http://localhost:6200/api/daemons 2>/dev/null)
      [ -n "$_d" ] && printf '%s' "$_d" > "${_CACHE_DIR}/daemons.json" 2>/dev/null
    fi

    # Provider usage (tasks 테이블 — 오늘 KST 기준 태스크 수)
    # DB 경로: 환경변수 > 플랫폼별 기본 경로
    _NCO_DB="${NCO_DB_PATH:-}"
    if [ -z "$_NCO_DB" ] || [ ! -f "$_NCO_DB" ]; then
      for _db_candidate in \
        "$HOME/project/nco/db/nco.db" \
        "$HOME/projects/nco/db/nco.db" \
        "$HOME/nco/db/nco.db"; do
        [ -f "$_db_candidate" ] && { _NCO_DB="$_db_candidate"; break; }
      done
    fi
    if [ -f "$_NCO_DB" ]; then
      sqlite3 "$_NCO_DB" "
        SELECT assigned_to,
               COUNT(*) as total,
               SUM(CASE WHEN status='completed' THEN 1 ELSE 0 END) as ok,
               SUM(CASE WHEN status='failed' THEN 1 ELSE 0 END) as fail
        FROM tasks
        WHERE assigned_to IS NOT NULL AND assigned_to != ''
          AND created_at >= datetime(strftime('%Y-%m-%d', 'now', '+9 hours') || ' 00:00:00', '-9 hours')
        GROUP BY assigned_to
        ORDER BY total DESC;
      " 2>/dev/null > "${_CACHE_DIR}/provider-usage.txt" 2>/dev/null
    fi

    # 프로바이더 리밋 감지 (최근 실패 — 확실한 리밋 패턴만)
    if [ -f "$_NCO_DB" ]; then
      sqlite3 "$_NCO_DB" "
        SELECT DISTINCT assigned_to
        FROM tasks
        WHERE status='failed'
          AND (response LIKE '%hit your usage limit%'
               OR response LIKE '%exceeded your monthly quota%'
               OR response LIKE '%ActionRequiredError%usage limit%'
               OR response LIKE '%set a Spend Limit%')
          AND created_at > datetime('now', '-6 hours')
        ORDER BY created_at DESC;
      " 2>/dev/null > "${_CACHE_DIR}/provider-limits.txt" 2>/dev/null
    fi

    # API 키 개수 캐시 (멀티키 프로바이더) — NCO DB와 같은 디렉터리의 ../.env
    _key_info=""
    _NCO_ENV=""
    if [ -n "$_NCO_DB" ]; then
      _NCO_ENV="$(dirname "$(dirname "$_NCO_DB")")/.env"
    fi
    [ -z "$_NCO_ENV" ] || [ ! -f "$_NCO_ENV" ] && _NCO_ENV="$HOME/project/nco/.env"
    [ ! -f "$_NCO_ENV" ] && _NCO_ENV="$HOME/projects/nco/.env"
    [ ! -f "$_NCO_ENV" ] && _NCO_ENV=""
    _or_keys=$(grep '^OPENROUTER_API_KEYS=' "$_NCO_ENV" 2>/dev/null | cut -d= -f2 | tr ',' '\n' | grep -c .)
    _nv_keys=$(grep '^NVIDIA_API_KEY=' "$_NCO_ENV" 2>/dev/null | cut -d= -f2 | tr ',' '\n' | grep -c .)
    echo "OR:${_or_keys:-0}|NV:${_nv_keys:-0}" > "${_CACHE_DIR}/api-keys.txt" 2>/dev/null

    # nova-ax statusline (캐시만 — 빠른 경로에서 읽음)
    _AX_BASE="${NCO_AX_URL:-}"
    [ -z "$_AX_BASE" ] && [ -s "$HOME/.claude/.ax-url" ] && _AX_BASE="$(tr -d '[:space:]' < "$HOME/.claude/.ax-url" 2>/dev/null)"
    [ -z "$_AX_BASE" ] && _AX_BASE="http://127.0.0.1:6300"
    _ax_resp=$(curl -s -m 1 "${_AX_BASE}/api/statusline" 2>/dev/null)
    if [ -n "$_ax_resp" ]; then
      _ax_text=$(printf '%s' "$_ax_resp" | python3 -c "
import sys,json
try: print(json.load(sys.stdin).get('text','') or '')
except: pass" 2>/dev/null)
      [ -n "$_ax_text" ] && printf '%s' "$_ax_text" > "${_CACHE_DIR}/ax-text" 2>/dev/null
    fi

    # Higgsfield (결과를 캐시에 저장)
    _hf_status=2
    if command -v higgsfield &>/dev/null; then
      bash "$HOME/projects/scripts/higgsfield-auth-check.sh" > /dev/null 2>&1 && _hf_status=0 || _hf_status=1
    fi
    printf '%s' "$_hf_status" > "${_CACHE_DIR}/hf-status" 2>/dev/null
    _hf_cred=$(bash "$HOME/projects/scripts/higgsfield-credits.sh" 2>/dev/null)
    [ -n "$_hf_cred" ] && printf '%s' "$_hf_cred" > "${_CACHE_DIR}/hf-cred" 2>/dev/null

    # Ollama 모델 (proxy /health 경유)
    _oll_url=$(curl -s -m 1 "http://localhost:4100/health" 2>/dev/null \
      | python3 -c "import sys,json
try: print(json.load(sys.stdin).get('ollama_base_url','') or '')
except: pass" 2>/dev/null)
    if [ -n "$_oll_url" ]; then
      _oll_model=$(curl -s -m 2 "${_oll_url}/v1/models" 2>/dev/null | python3 -c "
import sys,json,re
try:
  d=json.load(sys.stdin); m=d.get('data',[])
  if m:
    mid=m[0].get('id','')
    mid=re.sub(r'(:[\w]+)-[\w-]+-[\w]+\$', r'\1', mid)
    mid=re.sub(r':[^:]{8,}\$', lambda x: x.group(0)[:6], mid)
    print(mid)
except: pass" 2>/dev/null)
      [ -n "$_oll_model" ] && printf '%s' "$_oll_model" > "${_CACHE_DIR}/oll-model" 2>/dev/null
      # Ollama display URL
      _oll_disp=$(printf '%s' "$_oll_url" | python3 -c "import sys,re; u=sys.stdin.read().strip(); m=re.search(r'(?:https?://)?([^/]+)',u); print(m.group(1) if m else u)" 2>/dev/null)
      [ -n "$_oll_disp" ] && printf '%s' "$_oll_disp" > "${_CACHE_DIR}/oll-url" 2>/dev/null
    fi

    # 락 해제
    rm -f "$_BG_LOCK" 2>/dev/null
  ) </dev/null >/dev/null 2>&1 &
  disown 2>/dev/null || true
fi

# ── 백엔드 감지 (순수 env 기반 — 네트워크 호출 없음) ──────────
_detect_backend() {
  [ -n "$NCO_STATUSLINE_BACKEND" ] && { echo "$NCO_STATUSLINE_BACKEND"; return; }
  [ -n "$STATUSLINE_INFERENCE_BACKEND" ] && { echo "$STATUSLINE_INFERENCE_BACKEND"; return; }
  local base_url="${ANTHROPIC_BASE_URL:-}"
  if echo "$base_url" | grep -qE "localhost|127\.0\.0\.1"; then
    if [ "$(uname)" = "Darwin" ]; then echo "MLX"
    else echo "OLL"
    fi
    return
  fi
  echo ""
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

# ── OLL/MLX 백엔드: 실제 Ollama 모델명 (캐시에서 읽기) ─────────
if [ "$_BACKEND" = "OLL" ] || [ "$_BACKEND" = "MLX" ]; then
  _OLLAMA_MODEL=$(cat "${_CACHE_DIR}/oll-model" 2>/dev/null)
  [ -n "$_OLLAMA_MODEL" ] && BRACKET="[${_BACKEND}:${_OLLAMA_MODEL}]"
  # 로컬 추론은 Anthropic rate limit 없음 — 하드코딩 폴백값 덮어쓰기
  RATE_DAY=0
  RATE_WEEK=0
  COST=0.00
fi

PROJECT_NAME=$(basename "${PROJECT_DIR:-project}")

# ── 에이전트 라벨 사전 (등록되지 않은 ID는 자동 슬러그 처리) ──
declare -A SHORT=(
  ["claude-code"]="Cla" ["opencode"]="Opn" ["agy"]="Agy"
  ["codex"]="Cdx" ["cursor-agent"]="Cur"
  ["copilot"]="Cop" ["openrouter"]="ORT" ["nvidia"]="NIM"
  ["ollama"]="OLL" ["higgsfield"]="Hig"
)

# ── NCO 연결 상태 (캐시에서 읽기) ────────────────────────────
API_OK=0; WS_OK=0
if [ -f "${_CACHE_DIR}/nco-conn" ]; then
  read -r API_OK WS_OK < "${_CACHE_DIR}/nco-conn" 2>/dev/null || true
fi
API_OK=${API_OK:-0}; WS_OK=${WS_OK:-0}

DAEMONS=""
[ -f "${_CACHE_DIR}/daemons.json" ] && DAEMONS=$(cat "${_CACHE_DIR}/daemons.json" 2>/dev/null)

# ── ORDER 동적 구성 (NCO 실시간 싱크) ─────────────────────────
# 우선순위:
#   1. 라이브 /api/daemons — enabled=true 만, evicted_providers 제외
#   2. health.json — nco-health-monitor.sh 캐시 (백엔드 다운 시)
#   3. 하드코딩 폴백
_CAPS_FILE="/Users/nova-ai/.claude/nco-perf/capabilities.json"
_HEALTH_FILE="/Users/nova-ai/.claude/nco-perf/health.json"
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
    fallback = ["claude-code","opencode","agy","codex","cursor-agent","copilot","openrouter","nvidia","ollama","higgsfield"]
    ids = [x for x in fallback if x not in evicted]

print("\n".join(ids))
PYEOF
)
if [ "${#ORDER[@]}" -eq 0 ]; then
  ORDER=("claude-code" "opencode" "agy" "codex" "cursor-agent" "copilot" "openrouter" "nvidia" "ollama" "higgsfield")
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
# 줄1: <hostname>-<claude-N> [model] 📁 프로젝트
if [ -n "$_HOST_SLUG" ] && [ "$MY_NAME" != "cli" ]; then
  _NAME_DISP="${DIM}${_HOST_SLUG}-${RST}$(name_color "$MY_NAME")"
else
  _NAME_DISP="$(name_color "$MY_NAME")"
fi
TOTAL_AGENTS=${#ORDER[@]}
echo -e "$_NAME_DISP $(bracket_color "$BRACKET") ${GR}📁${RST} ${W}${PROJECT_NAME}${RST}"

# 줄2: api/ws + [ 에이전트 라벨 ]N/N
echo -e "  ${API_C} ${WS_C} ${GR}[${RST} ${AI_DISPLAY}${GR}]${RST}${G}${ONLINE}${RST}/${GR}${TOTAL_AGENTS}${RST}"

# 줄3: NCO 사용률 바 + 화살표
echo -e "  ${GR}NCO${RST} $(nco_bar $_NCO_PCT) $(nco_pct_color $_NCO_PCT) ${GR}(NCO:${RST}${_NCO_CALLS}${G}↑${RST} ${GR}직접:${RST}${_DIRECT_EDITS}${Y}↓${RST}${GR})${RST}"

# 줄4-5: 사용량 + 리셋 시간 + 리밋 프로바이더
if [ "$_BACKEND" = "OLL" ] || [ "$_BACKEND" = "MLX" ]; then
  echo -e "  ${G}local${RST} ${GR}Ctx:${RST}$(pct_color $CTX_PCT)"
else
  # 리밋 프로바이더 라벨 수집
  _LIMIT_DISP=""
  _PLIMIT_FILE="${_CACHE_DIR}/provider-limits.txt"
  if [ -f "$_PLIMIT_FILE" ] && [ -s "$_PLIMIT_FILE" ]; then
    while IFS= read -r _lim_id; do
      [ -z "$_lim_id" ] && continue
      _lim_label="${SHORT[$_lim_id]}"
      if [ -z "$_lim_label" ]; then
        _raw=$(echo "$_lim_id" | tr -cd 'a-zA-Z0-9' | cut -c1-3)
        _first=$(printf '%s' "$_raw" | cut -c1 | tr 'a-z' 'A-Z')
        _rest=$(printf '%s' "$_raw" | cut -c2-)
        _lim_label="${_first}${_rest}"
      fi
      _LIMIT_DISP="${_LIMIT_DISP} ${R}${_lim_label}${RST}${R}⛔${RST}"
    done < "$_PLIMIT_FILE"
  fi
  echo -e "  ${GR}1일${RST} $(make_bar $RATE_DAY) $(pct_color $RATE_DAY) ${GR}·${RST} ${GR}주별${RST} $(make_bar $RATE_WEEK) $(pct_color $RATE_WEEK) ${GR}|${RST} ${GR}Ctx:${RST}$(pct_color $CTX_PCT) ${GR}|${RST} $(cost_color $COST)${_LIMIT_DISP}"
  echo -e "  ${GR}↻${RST} ${GR}1일${RST} ${DIM}$(fmt_reset $DAY_RESET)${RST} ${GR}·${RST} ${GR}주별${RST} ${DIM}$(fmt_reset $WEEK_RESET)${RST}"
fi

# 줄6: Higgsfield + AX
_HF_STATUS=$(cat "${_CACHE_DIR}/hf-status" 2>/dev/null); _HF_STATUS=${_HF_STATUS:-2}
_HF_CRED=$(cat "${_CACHE_DIR}/hf-cred" 2>/dev/null)
IFS='|' read -r _HF_C _HF_PLAN _HF_SPEND <<< "$_HF_CRED"
_HF_DISP=""
_HF_VER=""
command -v higgsfield &>/dev/null && _HF_VER=$(higgsfield --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
case "$_HF_STATUS" in
  *$'\n'0|0)
    _hf_parts="${G}Hig${RST}"
    [ -n "$_HF_VER" ] && _hf_parts="${_hf_parts} ${DIM}v${_HF_VER}${RST}"
    _hf_parts="${_hf_parts} ${GR}·${RST} ${G}online${RST}"
    [ -n "$_HF_C" ] && _hf_parts="${_hf_parts} ${GR}·${RST} ${C}${_HF_C}${RST} ${GR}cr${RST}"
    [ -n "$_HF_SPEND" ] && _hf_parts="${_hf_parts} ${GR}·${RST} ${GR}오늘${RST} ${Y}${_HF_SPEND}${RST}"
    _HF_DISP="$_hf_parts"
    ;;
  *$'\n'1|1)
    _hf_parts="${Y}Hig${RST}"
    [ -n "$_HF_VER" ] && _hf_parts="${_hf_parts} ${DIM}v${_HF_VER}${RST}"
    _hf_parts="${_hf_parts} ${GR}·${RST} ${R}expired${RST}"
    _HF_DISP="$_hf_parts"
    ;;
esac
_AX_TEXT=$(cat "${_CACHE_DIR}/ax-text" 2>/dev/null)
_AX_LINE1=$(echo "$_AX_TEXT" | head -1)
[ -n "$_HF_DISP" ] && echo -e "  ${_HF_DISP}"
[ -n "$_AX_LINE1" ] && echo -e "  ${_AX_LINE1}"
exit 0
