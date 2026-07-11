#!/usr/bin/env bash
# nova-fleet-config apply — 정본 공유설정을 이 머신에 적용 (경로치환 + 백업 + dry-run)
# 사용: apply.sh [--dry-run]    canonical=claude-3. 다른 머신은 pull 후 실행.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$HOME/.claude"
DRY=0; MERGE_SET=0; FORCE=0; EXPECT_HASH=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1;;
    --merge-settings) MERGE_SET=1;;
    --force) FORCE=1;;                            # 미커밋/손편집 보존가드 무시 강제
    --expect-hash) shift; EXPECT_HASH="${1:-}";;  # pull-now 신호가 운반한 기대 commit-hash
    --expect-hash=*) EXPECT_HASH="${1#*=}";;
  esac; shift
done
OS="$(uname -s)"; USR="$(whoami)"; BASHP="$(command -v bash)"
log(){ echo "[fleet-apply] $*"; }
sub(){ sed -e "s|{{HOME}}|$HOME|g" -e "s|{{USER}}|$USR|g" -e "s|{{OS}}|$OS|g" -e "s|{{BASH_PATH}}|$BASHP|g"; }
_ensure_tool_activity_reporter_hooks(){ # settings.json에 reporter Pre/PostToolUse 멱등 등록
  local settings="$DEST/settings.json" tmp backup
  local pre_cmd='CLAUDE_HOOK_EVENT=PreToolUse bash ~/.claude/hooks/tool-activity-reporter.sh'
  local post_cmd='CLAUDE_HOOK_EVENT=PostToolUse bash ~/.claude/hooks/tool-activity-reporter.sh'
  [ $DRY -eq 1 ] && { log "DRY settings hook 보장: tool-activity-reporter"; return 0; }
  mkdir -p "$DEST"
  [ -f "$settings" ] || printf '{}\n' > "$settings"
  if command -v jq >/dev/null 2>&1; then
    if ! jq empty "$settings" >/dev/null 2>&1; then
      echo "[fleet-apply] settings.json 파싱 실패: $settings. 훅 등록 보장 불가. 적용 거부."
      exit 5
    fi
    if jq -e --arg pre "$pre_cmd" --arg post "$post_cmd" '
      def has_cmd($event; $cmd): any((.hooks[$event] // [])[]?.hooks[]?; .command == $cmd);
      has_cmd("PreToolUse"; $pre) and has_cmd("PostToolUse"; $post)
    ' "$settings" >/dev/null 2>&1; then
      log "settings hook 보장: tool-activity-reporter 이미 등록됨(skip)"
      return 0
    fi
    backup="$settings.fleet-hook-bak-$(date +%Y%m%d-%H%M%S)"
    cp "$settings" "$backup"
    tmp="$(mktemp "${TMPDIR:-/tmp}/fleet-settings.XXXXXX")"
    if ! jq --arg pre "$pre_cmd" --arg post "$post_cmd" '
      def has_cmd($event; $cmd): any((.hooks[$event] // [])[]?.hooks[]?; .command == $cmd);
      def ensure_cmd($event; $cmd):
        .hooks = (.hooks // {}) |
        .hooks[$event] = (.hooks[$event] // []) |
        if has_cmd($event; $cmd) then . else .hooks[$event] += [{"hooks":[{"type":"command","command":$cmd,"timeout":2}]}] end;
      ensure_cmd("PreToolUse"; $pre) | ensure_cmd("PostToolUse"; $post)
    ' "$settings" >"$tmp"; then
      rm -f "$tmp"
      echo "[fleet-apply] jq 갱신 실패: $settings. 백업=$backup"
      exit 6
    fi
    mv "$tmp" "$settings"
    log "settings hook 보장: tool-activity-reporter 등록 완료, 백업=$(basename "$backup")"
    return 0
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    echo "[fleet-apply] jq/python3 없음: settings.json 훅 등록 건너뜀."
    return 0
  fi
  if ! python3 -c 'import json, sys; json.load(open(sys.argv[1]))' "$settings" >/dev/null 2>&1; then
    echo "[fleet-apply] settings.json 파싱 실패: $settings. 훅 등록 보장 불가. 적용 거부."
    exit 5
  fi
  if PRE_CMD="$pre_cmd" POST_CMD="$post_cmd" python3 -c '
import json
import os
import sys

with open(sys.argv[1], encoding="utf-8") as f:
    data = json.load(f)

def has_cmd(event, cmd):
    return any(
        hook.get("command") == cmd
        for entry in (data.get("hooks", {}) or {}).get(event, [])
        for hook in (entry.get("hooks", []) if isinstance(entry, dict) else [])
        if isinstance(hook, dict)
    )

sys.exit(0 if has_cmd("PreToolUse", os.environ["PRE_CMD"]) and has_cmd("PostToolUse", os.environ["POST_CMD"]) else 1)
' "$settings"; then
    log "settings hook 보장: tool-activity-reporter 이미 등록됨(skip)"
    return 0
  fi
  backup="$settings.fleet-hook-bak-$(date +%Y%m%d-%H%M%S)"
  cp "$settings" "$backup"
  tmp="$(mktemp "${TMPDIR:-/tmp}/fleet-settings.XXXXXX")"
  if ! SETTINGS_PATH="$settings" TMP_PATH="$tmp" PRE_CMD="$pre_cmd" POST_CMD="$post_cmd" python3 -c '
import json
import os

settings_path = os.environ["SETTINGS_PATH"]
tmp_path = os.environ["TMP_PATH"]
pre_cmd = os.environ["PRE_CMD"]
post_cmd = os.environ["POST_CMD"]

with open(settings_path, encoding="utf-8") as f:
    data = json.load(f)

def has_cmd(event, cmd):
    hooks_root = data.get("hooks")
    if not isinstance(hooks_root, dict):
        return False
    entries = hooks_root.get(event, [])
    if not isinstance(entries, list):
        return False
    for entry in entries:
        if not isinstance(entry, dict):
            continue
        hooks = entry.get("hooks", [])
        if not isinstance(hooks, list):
            continue
        for hook in hooks:
            if isinstance(hook, dict) and hook.get("command") == cmd:
                return True
    return False

hooks_root = data.get("hooks")
if not isinstance(hooks_root, dict):
    hooks_root = {}
    data["hooks"] = hooks_root

for event, cmd in (("PreToolUse", pre_cmd), ("PostToolUse", post_cmd)):
    entries = hooks_root.get(event)
    if not isinstance(entries, list):
        entries = []
        hooks_root[event] = entries
    if not has_cmd(event, cmd):
        entries.append({"hooks": [{"type": "command", "command": cmd, "timeout": 2}]})

with open(tmp_path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")

with open(tmp_path, encoding="utf-8") as f:
    json.load(f)
'; then
    rm -f "$tmp"
    echo "[fleet-apply] python3 갱신 실패: $settings. 백업=$backup"
    exit 6
  fi
  mv "$tmp" "$settings"
  log "settings hook 보장: tool-activity-reporter 등록 완료, 백업=$(basename "$backup")"
}

# ★ 안전가드: SSOT가 아직 안 채워진 빈 골격이면 적용 거부 (실수로 빈설정 적용 방지)
HK=$(ls "$ROOT"/claude/hooks/*.sh 2>/dev/null | wc -l | tr -d " ")
if [ "$HK" -eq 0 ]; then
  echo "[fleet-apply] \u26d4 SSOT 미populated (hooks=0). canonical(claude-3)가 채운 뒤 실행하세요. 적용 거부."
  echo "[fleet-apply] 참고: 이 스크립트는 rm 없이 *존재 파일만 복사*하므로 기존 ~/.claude는 안전합니다."
  exit 2
fi

# ★ commit-hash 게이트 (claude-3/6 합의): pull-now 신호가 운반한 기대 해시를 *이미 git fetch된 ROOT 트리*에만 대조.
#   신호 본문 절대 불신 — 로컬 git HEAD가 그 해시(또는 prefix)일 때만 진행. 불일치=fail-closed(거부). git 아니면 스킵.
if [ -n "$EXPECT_HASH" ]; then
  CUR_HASH="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo none)"
  if [ "$CUR_HASH" != "$EXPECT_HASH" ] && [ "${CUR_HASH#"$EXPECT_HASH"}" = "$CUR_HASH" ]; then
    echo "[fleet-apply] commit-hash 불일치: ROOT HEAD=$CUR_HASH, 기대=$EXPECT_HASH. 'git -C \"$ROOT\" fetch && git checkout' 후 재실행. 적용 거부."
    exit 3
  fi
  log "commit-hash 검증 통과: $CUR_HASH"
fi

# ★ 비파괴 보존가드 헬퍼 (claude-8 합의): 대상 파일이 (a)git 워킹트리 미커밋 변경(심볼릭링크 타깃 포함) 또는
#   (b)직전 fleet-apply 이후 손편집(manifest md5 불일치)이면 0 반환 → 호출부가 보존(skip). --force로만 무시.
MANIFEST="$DEST/.fleet-applied.md5"
_fleet_preserve(){ # 0=preserve(local dirty), 1=safe-to-write
  local dst="$1" real wt cur last
  [ -e "$dst" ] || return 1
  real="$(readlink -f "$dst" 2>/dev/null || echo "$dst")"
  wt="$(git -C "$(dirname "$real")" rev-parse --show-toplevel 2>/dev/null)"
  if [ -n "$wt" ] && [ -n "$(git -C "$wt" status --porcelain -- "$real" 2>/dev/null)" ]; then return 0; fi
  cur="$(md5sum "$dst" 2>/dev/null | cut -d' ' -f1)"
  last="$(awk -v n="$(basename "$dst")" '$2==n{print $1}' "$MANIFEST" 2>/dev/null | tail -1)"
  [ -n "$last" ] && [ "$cur" != "$last" ] && return 0
  return 1
}

# ★ newest-wins 양방향 동기화 (2026-07-08 사용자 규칙화: "최신 문서파일 우선적용"):
#   렌더된 canonical(sub 치환 후)과 로컬 내용이 다르면 mtime으로 방향 결정 —
#   · 로컬이 최신 → 역배포: 로컬 → canonical repo 복사 + 해당 파일만 커밋 + push 시도
#   · canonical이 최신 → 기존대로 정방향 적용 (호출부 진행)
#   canonical에 {{템플릿}} 토큰이 있으면 역배포 시 토큰이 소실되므로 보존(skip)+경고만.
#   --force = 정방향 강제(복구용, newest-wins 무시). NOVA_NW_NO_PUSH=1 → push 생략(테스트용).
_manifest_update(){ # $1=dst — manifest md5 갱신
  { grep -v " $(basename "$1")\$" "$MANIFEST" 2>/dev/null; echo "$(md5sum "$1" 2>/dev/null | cut -d' ' -f1) $(basename "$1")"; } > "$MANIFEST.tmp" 2>/dev/null && mv -f "$MANIFEST.tmp" "$MANIFEST" 2>/dev/null
}
_newest_wins(){ # $1=src(canonical) $2=dst(local) ; 0=역배포 완료(호출부 skip), 1=정방향 적용 진행
  local src="$1" dst="$2" n; n="$(basename "$dst")"
  [ -f "$dst" ] || return 1
  [ $FORCE -eq 1 ] && return 1
  cmp -s <(sub <"$src") "$dst" && return 1   # 내용 동일 → 정방향 write 무해
  [ "$dst" -nt "$src" ] || return 1           # canonical이 최신 → 정방향 적용
  if grep -q '{{' "$src" 2>/dev/null; then
    log "보존(skip): $n — 로컬이 최신이나 canonical에 템플릿 토큰 존재, 역배포 불가(수동 반영 필요)"
    return 0
  fi
  cp "$dst" "$src" 2>/dev/null || { log "역배포 실패(cp): $n — 로컬 보존"; return 0; }
  if git -C "$ROOT" add -- "$src" 2>/dev/null && \
     git -C "$ROOT" commit -q -m "sync(newest-wins): $n — $(hostname -s 2>/dev/null || echo host) 로컬 최신본 역배포" -- "$src" 2>/dev/null; then
    if [ "${NOVA_NW_NO_PUSH:-0}" = "1" ]; then
      log "역배포+커밋: $n (push 생략 NOVA_NW_NO_PUSH=1)"
    elif git -C "$ROOT" push -q origin main 2>/dev/null; then
      log "역배포+push: $n (로컬 최신 → canonical 전파)"
    else
      log "역배포+커밋: $n (push 실패 — 다음 sync/수동 push에서 전파)"
    fi
  else
    log "역배포(미커밋): $n — canonical 파일엔 반영됨, 커밋 실패(수동 확인)"
  fi
  _manifest_update "$dst"
  return 0
}

if [ $DRY -eq 0 ]; then
  BK="$DEST/_fleet-backup-$(date +%Y%m%d-%H%M%S)"; mkdir -p "$BK"
  cp -R "$DEST/hooks" "$BK/" 2>/dev/null; cp -R "$DEST/commands" "$BK/" 2>/dev/null; cp "$DEST/settings.json" "$BK/" 2>/dev/null
  cp "$DEST/CLAUDE.md" "$BK/" 2>/dev/null
  log "백업: $BK"
fi
# bun PATH 자동 주입 — gbrain/bun 도구용 (~/.bun/bin). 이미 있으면 skip (멱등)
if [ $DRY -eq 0 ]; then
  _RCFILE="$HOME/.bashrc"; [ "$(uname -s)" = Darwin ] && _RCFILE="$HOME/.zshrc"
  if [ -f "$_RCFILE" ] && ! grep -q '\.bun/bin' "$_RCFILE" 2>/dev/null; then
    printf '\n# gbrain / bun PATH (nova-fleet-config)\nexport PATH="$HOME/.bun/bin:$PATH"\n' >> "$_RCFILE"
    log "bun PATH 주입: $_RCFILE"
  else
    log "bun PATH: $_RCFILE 이미 설정됨(skip)"
  fi
fi
# CLAUDE.md (정본 글로벌 지침 — GAP 해소 2026-06-06; 템플릿 치환 통과, 백업은 위에서 수행)
if [ -f "$ROOT/claude/CLAUDE.md" ]; then
  if [ $DRY -eq 1 ]; then log "DRY CLAUDE.md"
  elif _newest_wins "$ROOT/claude/CLAUDE.md" "$DEST/CLAUDE.md"; then :
  else sub <"$ROOT/claude/CLAUDE.md" >"$DEST/CLAUDE.md"; log "CLAUDE.md"; fi
fi
# hooks (템플릿 치환) — ★비파괴 보존가드: 미커밋/손편집 보존(skip), 적용후 bash -n 실패시 백업 롤백(fail-closed)
for f in "$ROOT"/claude/hooks/*.sh; do [ -f "$f" ] || continue; n="$(basename "$f")"; dst="$DEST/hooks/$n"
  if [ $DRY -eq 1 ]; then log "DRY hook: $n"; continue; fi
  # newest-wins: 로컬이 최신이면 역배포 후 skip (기존 _fleet_preserve 보존가드 대체 — 2026-07-08)
  if _newest_wins "$f" "$dst"; then continue; fi
  sub <"$f" >"$dst"; chmod +x "$dst"
  if ! bash -n "$dst" 2>/dev/null; then
    if [ -f "$BK/hooks/$n" ]; then cp "$BK/hooks/$n" "$dst"; log "$n 구문오류 → 백업 롤백(fail-closed)"; else log "$n 구문오류·백업없음(주의)"; fi
  else
    { grep -v " $n\$" "$MANIFEST" 2>/dev/null; echo "$(md5sum "$dst" 2>/dev/null | cut -d' ' -f1) $n"; } > "$MANIFEST.tmp" 2>/dev/null && mv -f "$MANIFEST.tmp" "$MANIFEST" 2>/dev/null
    log "hook: $n"
  fi
done
# .py 훅 배포 (plugin-cache 패처 등 — patch-inter-session.py; GAP 해소 2026-06-06)
for f in "$ROOT"/claude/hooks/*.py; do [ -f "$f" ] || continue; n="$(basename "$f")"
  if [ $DRY -eq 1 ]; then log "DRY py-hook: $n"; else sub <"$f" >"$DEST/hooks/$n"; chmod +x "$DEST/hooks/$n"; log "py-hook: $n"; fi; done
_ensure_tool_activity_reporter_hooks
# 패처 실행 — inter-session plugin cache(client.py/shared.py)에 NCO 패치 재적용(멱등)
if [ $DRY -eq 0 ] && [ -f "$DEST/hooks/patch-inter-session.py" ]; then
  python3 "$DEST/hooks/patch-inter-session.py" >/dev/null 2>&1 && log "patch-inter-session.py 실행(plugin cache 패치 적용)" || log "patch-inter-session.py 실행 실패(무시 — 다음 SessionStart 재시도)"
fi
# hook 디렉터리 단일화(§A.3/§D-2): 레거시 ~/projects/.claude/hooks(Linux 잔재) → ~/.claude/hooks 병합 후 폐기표식.
#   canonical=~/.claude/hooks 단일(statusLine 등 전 config 단일참조, gentop-mac-1 e9c6387). Mac엔 레거시dir 없어 no-op.
LEGACY_HOOKS="$HOME/projects/.claude/hooks"
if [ -d "$LEGACY_HOOKS" ] && [ "$LEGACY_HOOKS" != "$DEST/hooks" ]; then
  for lf in "$LEGACY_HOOKS"/*.sh; do
    [ -f "$lf" ] || continue; ln="$(basename "$lf")"
    [ -f "$DEST/hooks/$ln" ] && continue   # canonical 우선(이미 배포된 건 보존)
    if [ $DRY -eq 1 ]; then log "DRY 레거시훅 병합: $ln"; else cp "$lf" "$DEST/hooks/$ln"; chmod +x "$DEST/hooks/$ln"; log "레거시훅 병합(projects→.claude): $ln"; fi
  done
  if [ $DRY -eq 0 ] && [ ! -f "$LEGACY_HOOKS/.deprecated" ]; then
    touch "$LEGACY_HOOKS/.deprecated" 2>/dev/null && log "레거시 hook디렉터리 폐기표식: $LEGACY_HOOKS/.deprecated (단일화 완료; 안전확인 후 rm 가능)"
  fi
fi
# commands (템플릿 치환 — {{HOME}}/{{BASH_PATH}} 등; hooks와 동일하게 sub() 통과. raw cp는 토큰 미치환 버그)
for f in "$ROOT"/claude/commands/*.md; do [ -f "$f" ] || continue; n="$(basename "$f")"
  if [ $DRY -eq 1 ]; then log "DRY command: $n"; continue; fi
  if _newest_wins "$f" "$DEST/commands/$n"; then continue; fi
  sub <"$f" >"$DEST/commands/$n"; log "command: $n"; done
# skills (공유 스킬 — OS전용은 canonical에서 제외됨)
if [ $DRY -eq 0 ] && [ -d "$ROOT/claude/skills" ]; then
  mkdir -p "$DEST/skills"
  for sk in "$ROOT"/claude/skills/*/; do [ -d "$sk" ] && cp -R "${sk%/}" "$DEST/skills/" 2>/dev/null; done
  log "skills 적용: $(ls "$ROOT/claude/skills" 2>/dev/null | tr '\n' ' ')"
fi

# scripts/ 배포 (hooks가 {{HOME}}/projects/scripts/ 참조) — 템플릿 치환
if [ $DRY -eq 0 ] && [ -d "$ROOT/scripts" ]; then
  mkdir -p "$HOME/projects/scripts"
  for sf in "$ROOT"/scripts/*.sh; do [ -f "$sf" ] || continue; sub <"$sf" >"$HOME/projects/scripts/$(basename "$sf")"; chmod +x "$HOME/projects/scripts/$(basename "$sf")"; done
  log "scripts 배포: ~/projects/scripts/"
fi

# settings.json UNION 머지 (hooks: canonical ∪ 머신전용, statusLine: canonical) + 백업
if [ $DRY -eq 0 ] && [ $MERGE_SET -eq 1 ] && [ -f "$ROOT/claude/settings.template.json" ]; then
  python3 - "$ROOT/claude/settings.template.json" "$DEST/settings.json" "$HOME" "$(whoami)" "$(uname -s)" <<'PYEOF'
import json,sys,os,shutil
tmpl_p,set_p,HOME,USR,OSN=sys.argv[1:6]
def sub(o):
    if isinstance(o,str): return o.replace("{{HOME}}",HOME).replace("{{USER}}",USR).replace("{{OS}}",OSN)
    if isinstance(o,list): return [sub(x) for x in o]
    if isinstance(o,dict): return {k:sub(v) for k,v in o.items()}
    return o
tmpl=sub(json.load(open(tmpl_p)))
local=json.load(open(set_p)) if os.path.exists(set_p) else {}
if os.path.exists(set_p): shutil.copy(set_p,set_p+".fleet-bak")
if "statusLine" in tmpl: local["statusLine"]=tmpl["statusLine"]
canon=tmpl.get("hooks",{}); cur=local.get("hooks",{}); merged={}
for ev in set(list(canon)+list(cur)):
    seen=set(); out=[]
    for src in (canon.get(ev,[]), cur.get(ev,[])):
        for grp in src:
            for h in grp.get("hooks",[]):
                c=h.get("command","")
                if c and c not in seen: seen.add(c); out.append(h)
    if out: merged[ev]=[{"hooks":out}]
local["hooks"]=merged
json.dump(local,open(set_p,"w"),ensure_ascii=False,indent=2)
n=sum(len(g["hooks"]) for ev in merged.values() for g in ev)
print("[merge] settings UNION: canonical+머신전용 이벤트별 합집합 dedup, 총 %d 훅"%n)
PYEOF
  log "settings.json UNION 머지 완료(canonical+머신전용 보존), 백업 .fleet-bak"
elif [ $DRY -eq 0 ] && [ $MERGE_SET -eq 0 ]; then
  log "settings 머지 생략(기본 OFF). 파일sync만. 전체 sync는 --merge-settings."
fi

# settings: 안전 위해 자동 덮어쓰기 금지 — 템플릿 머지 안내(비밀/ local 보존)
log "settings.template.json 은 수동검토 머지 권장(비밀 보존). 참고: $ROOT/claude/settings.template.json"
# providers 점검 (설치는 강제 안 함 — 누락만 보고)
log "provider 점검:"; while read -r p ver _; do [ -z "${p:-}" ] && continue; case "$p" in \#*) continue;; esac
  # bun 기반 도구는 ~/.bun/bin도 함께 탐색 (PATH 미등록 대응)
  { command -v "$p" >/dev/null 2>&1 || [ -x "$HOME/.bun/bin/$p" ]; } && echo "  $p ✓" || echo "  $p ✗ 설치필요(${ver:-})"; done < "$ROOT/providers.list"
# NCO ollama 자동감지 → 머신 오버레이(ai-providers.local.json)에 enabled 기록 (§C ②OS분기)
#   Mac(Darwin)+MLX=false, ollama 미응답=false, ollama 응답=true(단 Mac MLX 우선시 false 유지)
#   2026-07-03 변경: 추적 SSOT(ai-providers.json) 직접 write는 매 세션 트리 오염 → pull 충돌
#   유발(subnote UU·snt 사건 계열)이라 git 비추적 오버레이로 이동. SSOT는 읽기도 쓰기도 안 함.
#   NCO 런타임(d812312 loadProviders)이 overrides.<id>를 provider별 shallow merge로 읽는다.
NCO_CFG="$HOME/project/nco/config/ai-providers.json"
NCO_LOCAL_CFG="$HOME/project/nco/config/ai-providers.local.json"
if [ $DRY -eq 0 ] && command -v python3 >/dev/null 2>&1 && [ -f "$NCO_CFG" ]; then
  OLLAMA_UP=0; curl -s -m 3 http://localhost:11434/api/tags >/dev/null 2>&1 && OLLAMA_UP=1
  # 저사양 머신 sentinel: ~/.claude/.nco-no-ollama 존재 시 강제 비활성 (외장GPU 없음·RAM 8GB 미만)
  [ -f "$HOME/.claude/.nco-no-ollama" ] && OLLAMA_UP=0
  IS_MAC=0; [ "$(uname -s)" = Darwin ] && IS_MAC=1
  HAS_MLX=0; python3 -c 'import mlx' >/dev/null 2>&1 && HAS_MLX=1
  python3 - "$NCO_LOCAL_CFG" "$OLLAMA_UP" "$IS_MAC" "$HAS_MLX" "$(date +%Y-%m-%d)" << 'PYEOF'
import json, sys
from pathlib import Path
cfg, ollama_up, is_mac, has_mlx, today = sys.argv[1], sys.argv[2]=="1", sys.argv[3]=="1", sys.argv[4]=="1", sys.argv[5]
path = Path(cfg)
if path.exists():
    try:
        d = json.loads(path.read_text())
    except Exception as e:
        # 오버레이 파손 시 절대 덮어쓰지 않는다 — 수동 복구 대상 (다른 머신 정책 소실 방지)
        print(f"  [apply] 경고: {cfg} 파싱 실패({e}) — ollama 게이팅 skip, 수동 확인 필요"); sys.exit(0)
else:
    d = {"_readme": ["머신 정책 오버레이 (git 비추적) — 공유 ai-providers.json은 중립 SSOT"], "overrides": {}}
ov = d.setdefault("overrides", {})
# Mac+MLX=disabled, 비Mac+ollama없음=disabled, 비Mac+ollama있음=enabled
target = False if (is_mac and has_mlx) else ollama_up
entry = dict(ov.get("ollama") or {})
entry["enabled"] = target
if not target:
    entry["_reason"] = ("Mac — MLX(Apple Silicon) 우선" if (is_mac and has_mlx) else "ollama 미응답(localhost:11434)")
    entry["_disabled_at"] = today
else:
    entry.pop("_reason", None); entry.pop("_disabled_at", None)
if ov.get("ollama") != entry:
    ov["ollama"] = entry  # 다른 overrides 키·_readme는 그대로 보존 (ollama만 갱신)
    path.write_text(json.dumps(d, indent=2, ensure_ascii=False) + "\n")
    print(f"  [apply] overlay ollama enabled={target} (Mac={is_mac},MLX={has_mlx},up={ollama_up}) → {cfg}")
else:
    print(f"  [apply] overlay ollama 변경없음 (enabled={target}, Mac={is_mac},MLX={has_mlx},up={ollama_up})")
PYEOF
fi
log "적용 완료 (dry=$DRY). settings/hooks 변경은 다음 세션부터 반영. 롤백: $DEST/_fleet-backup-*"
