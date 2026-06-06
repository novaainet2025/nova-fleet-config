#!/usr/bin/env bash
# nova-fleet-config apply — 정본 공유설정을 이 머신에 적용 (경로치환 + 백업 + dry-run)
# 사용: apply.sh [--dry-run]    canonical=claude-3. 다른 머신은 pull 후 실행.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$HOME/.claude"
DRY=0; MERGE_SET=0
for a in "$@"; do [ "$a" = "--dry-run" ] && DRY=1; [ "$a" = "--merge-settings" ] && MERGE_SET=1; done
OS="$(uname -s)"; USR="$(whoami)"; BASHP="$(command -v bash)"
log(){ echo "[fleet-apply] $*"; }
sub(){ sed -e "s|{{HOME}}|$HOME|g" -e "s|{{USER}}|$USR|g" -e "s|{{OS}}|$OS|g" -e "s|{{BASH_PATH}}|$BASHP|g"; }

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
  cp "$DEST/CLAUDE.md" "$BK/" 2>/dev/null
  log "백업: $BK"
fi
# CLAUDE.md (정본 글로벌 지침 — GAP 해소 2026-06-06; 템플릿 치환 통과, 백업은 위에서 수행)
if [ -f "$ROOT/claude/CLAUDE.md" ]; then
  if [ $DRY -eq 1 ]; then log "DRY CLAUDE.md"; else sub <"$ROOT/claude/CLAUDE.md" >"$DEST/CLAUDE.md"; log "CLAUDE.md"; fi
fi
# hooks (템플릿 치환)
for f in "$ROOT"/claude/hooks/*.sh; do [ -f "$f" ] || continue; n="$(basename "$f")"
  if [ $DRY -eq 1 ]; then log "DRY hook: $n"; else sub <"$f" >"$DEST/hooks/$n"; chmod +x "$DEST/hooks/$n"; log "hook: $n"; fi; done
# .py 훅 배포 (plugin-cache 패처 등 — patch-inter-session.py; GAP 해소 2026-06-06)
for f in "$ROOT"/claude/hooks/*.py; do [ -f "$f" ] || continue; n="$(basename "$f")"
  if [ $DRY -eq 1 ]; then log "DRY py-hook: $n"; else sub <"$f" >"$DEST/hooks/$n"; chmod +x "$DEST/hooks/$n"; log "py-hook: $n"; fi; done
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
  if [ $DRY -eq 1 ]; then log "DRY command: $n"; else sub <"$f" >"$DEST/commands/$n"; log "command: $n"; fi; done
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
  command -v "$p" >/dev/null 2>&1 && echo "  $p ✓" || echo "  $p ✗ 설치필요(${ver:-})"; done < "$ROOT/providers.list"
# NCO ai-providers.json: ollama 자동감지 → enabled 자동설정 (§C ②OS분기, claude-6/win-2 정책)
#   Mac(Darwin)+MLX=false, ollama 미응답=false, ollama 응답=true(단 Mac MLX 우선시 false 유지)
NCO_CFG="$HOME/project/nco/config/ai-providers.json"
if [ $DRY -eq 0 ] && command -v python3 >/dev/null 2>&1 && [ -f "$NCO_CFG" ]; then
  OLLAMA_UP=0; curl -s -m 3 http://localhost:11434/api/tags >/dev/null 2>&1 && OLLAMA_UP=1
  IS_MAC=0; [ "$(uname -s)" = Darwin ] && IS_MAC=1
  HAS_MLX=0; python3 -c 'import mlx' >/dev/null 2>&1 && HAS_MLX=1
  python3 - "$NCO_CFG" "$OLLAMA_UP" "$IS_MAC" "$HAS_MLX" "$(date +%Y-%m-%d)" << 'PYEOF'
import json, sys
from pathlib import Path
cfg, ollama_up, is_mac, has_mlx, today = sys.argv[1], sys.argv[2]=="1", sys.argv[3]=="1", sys.argv[4]=="1", sys.argv[5]
d = json.loads(Path(cfg).read_text())
changed = False
for p in d.get("providers", []):
    if p["id"] != "ollama": continue
    # Mac+MLX=disabled, 비Mac+ollama없음=disabled, 비Mac+ollama있음=enabled
    target = False if (is_mac and has_mlx) else ollama_up
    if p.get("enabled") != target:
        p["enabled"] = target
        if not target:
            p["_disabled_reason"] = ("Mac — MLX(Apple Silicon) 우선" if (is_mac and has_mlx) else "ollama 미응답(localhost:11434)")
            p["_disabled_at"] = today
        else:
            p.pop("_disabled_reason", None); p.pop("_disabled_at", None)
        p["updated"] = today; d["updated"] = today; changed = True
    break
if changed: Path(cfg).write_text(json.dumps(d, indent=2, ensure_ascii=False)); print(f"  [apply] ollama enabled={target} (Mac={is_mac},MLX={has_mlx},up={ollama_up})")
else: print(f"  [apply] ollama 변경없음 (enabled={p.get('enabled')}, Mac={is_mac},MLX={has_mlx},up={ollama_up})")
PYEOF
fi
log "적용 완료 (dry=$DRY). settings/hooks 변경은 다음 세션부터 반영. 롤백: $DEST/_fleet-backup-*"
