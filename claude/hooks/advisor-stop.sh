#!/bin/bash
# NCO 재귀보호: NCO가 스폰한 서브프로세스 claude에서는 훅 무동작 (2026-07-08, 76s 훅스택+BOOTSTRAP 오염 T1)
[ "${NCO_HOOK_DISABLED:-0}" = "1" ] && exit 0
# Stop hook — 세션 종료 시 결정론적 9섹션 PDCA 리포트 생성 (LLM 비의존)
#
# 설계 원칙 (사용자 지시 2026-07-06):
#   - "매번 같은 내용" 금지 → 모든 소스를 세션-스코프(track birth-time 앵커)로 추출.
#     변화는 구조적으로 보장(우연히 다르길 바라지 않음).
#   - 하드코딩/"AI 오프라인" 폴백 금지 → 실제 작업 데이터(멀티레포 git·track·decision-log
#     ·backlog·PRD)에서 결정론적으로 채운다. 데이터 없으면 "측정불가"로 명시.
#   - Gap(⑤)은 track-stages done/total. 지표 없으면 측정불가. (반복 강제는 end-of-turn-check.sh)
#   - ⑧⑨(자기개선·학습)은 기존 context_note "## 5. 다음 세션 필수 인지" 주입을 확장해 다음 세션 적용.
#
# 저장: ~/.claude/improvements/{project}-{date}-{time}.md
set +e

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
IMPROVEMENTS_DIR="$HOME/.claude/improvements"
mkdir -p "$IMPROVEMENTS_DIR" 2>/dev/null

# ── Stop 훅 stdin(JSON) 캡처 → transcript_path = 세션-스코프 지상진실 (2026-07-10) ──
# 파일명=세션UUID 이므로 transcript 전체가 이 세션. 공유레포 mtime 오귀속을 근본 대체.
_HOOK_STDIN="$(cat 2>/dev/null || true)"
export NCO_TRANSCRIPT="$(printf '%s' "$_HOOK_STDIN" | python3 -c 'import sys,json
try:
    d=json.load(sys.stdin); print(d.get("transcript_path") or "")
except Exception:
    print("")' 2>/dev/null)"

# ── 세션 ID 해석 (SID = track 파일 스코프 앵커) ──────────────────
_SID="${NCO_SESSION_ID:-}"
if [ -z "$_SID" ]; then
  _CK=$$
  for _i in 1 2 3 4 5; do
    _CK=$(ps -o ppid= -p "$_CK" 2>/dev/null | tr -d ' ')
    [ -z "$_CK" ] && break
    ps -o comm= -p "$_CK" 2>/dev/null | grep -qE '^(claude|node)$' && { _SID="$_CK"; break; }
  done
  _SID="${_SID:-$$}"
fi

export NCO_SID="$_SID"
export NCO_PROJECT_DIR="$PROJECT_DIR"
export NCO_IMPROVE_DIR="$IMPROVEMENTS_DIR"

python3 <<'PYEOF'
import os, sys, json, subprocess, time, hashlib, re

SID       = os.environ.get('NCO_SID','')
PROJECT   = os.environ['NCO_PROJECT_DIR']
IMPROVE   = os.environ['NCO_IMPROVE_DIR']
HOME      = os.path.expanduser('~')
TRACK     = f'/tmp/nco-track-{SID}.json'
STAGEP    = f'/tmp/nco-stages-{SID}.json'
PROJNAME  = os.path.basename(PROJECT)
# 커서는 세션 스코프 (2026-07-08 수정): 프로젝트 단위 공유 커서는 같은 cwd의 동시 세션들이
# 서로의 리포트 창을 덮어써 — 다른 세션 Stop 직후 내 창이 1분으로 붕괴하고 모든 실질 섹션이
# "변경 없음" 보일러플레이트로 동일해진다 (사용자 지적: 두 세션 리포트 동일). SID로 분리.
CURSOR    = f'{IMPROVE}/.report-cursor-{PROJNAME}-{SID}' if SID else f'{IMPROVE}/.report-cursor-{PROJNAME}'

def out(msg=None):
    if msg:
        print(json.dumps({'systemMessage': msg}))
    sys.exit(0)

# 세션별 커서 파일 누적 방지 — 14일 지난 커서는 정리
try:
    import glob as _cg
    for _c in _cg.glob(f'{IMPROVE}/.report-cursor-*'):
        if time.time() - os.path.getmtime(_c) > 14*86400:
            os.remove(_c)
except Exception:
    pass

# ── 세션 시작 앵커 = track 파일 birth-time (macOS: stat -f %B) ──────
def birth(p):
    for flag in ('%B','%m'):
        try:
            r = subprocess.run(['stat','-f',flag,p], capture_output=True, text=True, timeout=5)
            if r.returncode == 0 and r.stdout.strip().isdigit():
                return int(r.stdout.strip())
        except Exception:
            pass
    return None

start = birth(TRACK)
if not start:
    start = int(time.time()) - 3*3600   # 폴백: 3시간 창
try:
    cursor = int(open(CURSOR, encoding='utf-8').read().strip() or '0')
except Exception:
    cursor = 0
if cursor > start:
    start = cursor
now       = int(time.time())
# 최소 리포트 간격 — 매 턴 미니리포트 반복 발화(노이즈) 방지 (사용자 지적 2026-07-06).
# 조용한 스킵은 "출력이 안 된다"로 오인되므로(사용자 지적 2건째) 한 줄 안내를 남긴다.
# NCO_REPORT_FORCE=1 로 우회 가능(테스트·수동 재생성용).
# 기본 0(비활성): 사용자는 매 Stop 풀리포트를 원함 — 반복 문제의 본질은 빈도가 아니라
# 내용 신선도였고 그것은 증분커서가 해결. 원하면 NCO_REPORT_MIN_INTERVAL=초 로 재활성.
REPORT_MIN_INTERVAL = int(os.environ.get('NCO_REPORT_MIN_INTERVAL', '0') or '0')
if REPORT_MIN_INTERVAL > 0 and cursor and (now - cursor) < REPORT_MIN_INTERVAL and os.environ.get('NCO_REPORT_FORCE') != '1':
    ago = (now - cursor) // 60
    ago_txt = '방금' if ago < 1 else f'{ago}분 전'
    remain = (REPORT_MIN_INTERVAL - (now - cursor)) // 60 + 1
    out(f'📋 리포트 생략 — 직전 리포트 {ago_txt} (다음 자동 리포트 ~{remain}분 후 · 즉시 보기: NCO_REPORT_FORCE=1)')
start_str = time.strftime('%Y-%m-%d %H:%M', time.localtime(start))
now_str   = time.strftime('%Y-%m-%dT%H:%M', time.localtime(now))
DATE      = time.strftime('%Y-%m-%d', time.localtime(now))
TIMEHM    = time.strftime('%H%M', time.localtime(now))

def load_json(p):
    try: return json.load(open(p))
    except Exception: return {}

tr        = load_json(TRACK)
stages    = load_json(STAGEP)
nco_calls = int(tr.get('nco_calls_total', 0) or 0) + int(tr.get('nco_calls', 0) or 0)
direct    = int(tr.get('direct_edits_total', 0) or 0) + int(tr.get('direct_edits', 0) or 0)
# task_type: 현재 턴 분류 우선(누적 max는 sticky라 리서치/설정 세션을 new_feature로 오표기 → 가짜 Gap). (2026-07-10 수정)
task_type = tr.get('task_type') or tr.get('task_type_max') or 'unknown'
task_type_max = tr.get('task_type_max') or task_type
viol      = int(tr.get('agent_violations', 0) or 0)
# 거짓보고 게이트 누적 카운터 — 대화형 세션의 실제 신호(교훈 소스). decision-log 미기록 보완용.
try:
    frc = int(open(f'{HOME}/.claude/.false-report-count', encoding='utf-8').read().strip() or '0')
except Exception:
    frc = 0

# ── 세션 transcript 스캔 (지상진실) ──────────────────────────────────
# 파일=세션이므로 교차오염 0. 실제 편집파일·위임·게이트블록·사용자정정을 결정론적 추출.
def scan_transcript(path):
    tx = {'edited': [], 'bash': 0, 'deleg': 0, 'web': 0, 'reads': 0,
          'gate_blocks': 0, 'pushback': [], 'selfcorr': 0, 'unverified': [], 'goal': ''}
    if not path or not os.path.exists(path):
        return None
    try:
        raw = open(path, encoding='utf-8', errors='ignore').read().splitlines()
    except Exception:
        return None
    ed = []
    for ln in raw[-6000:]:                      # 성능 상한
        try: d = json.loads(ln)
        except Exception: continue
        t = d.get('type'); msg = d.get('message') if isinstance(d.get('message'), dict) else {}
        c = msg.get('content')
        if t == 'assistant' and isinstance(c, list):
            for b in c:
                if not isinstance(b, dict): continue
                bt = b.get('type')
                if bt == 'tool_use':
                    n = b.get('name'); inp = b.get('input') or {}
                    if n in ('Edit', 'Write', 'NotebookEdit'):
                        fp = inp.get('file_path') or inp.get('notebook_path')
                        if fp: ed.append(os.path.basename(fp))
                    elif n == 'Bash':
                        tx['bash'] += 1
                        cmd = str(inp.get('command', ''))
                        if any(k in cmd for k in ('/api/task', '/api/parallel', '/api/conductor', 'nco_')): tx['deleg'] += 1
                    elif n in ('WebSearch', 'WebFetch'): tx['web'] += 1
                    elif n == 'Read': tx['reads'] += 1
                    elif n == 'Skill' and 'nco' in str(inp.get('skill', '')): tx['deleg'] += 1
                elif bt == 'text':
                    txt = b.get('text', '')
                    if any(k in txt for k in ('정정합니다', '거짓이었', '오류였', '잘못 보고', '틀렸습니다')): tx['selfcorr'] += 1
                    for u in re.findall(r'\[미검증항목\]\s*([^\n]{4,90})', txt): tx['unverified'].append(u.strip())
        elif t == 'user' and isinstance(c, str):          # 실제 사용자 입력(문자열)만
            if '거짓·미검증 보고 차단' in c or 'no-false-report-gate' in c: tx['gate_blocks'] += 1
            if not tx['goal']: tx['goal'] = c.strip().replace('\n', ' ')[:120]
            if any(k in c for k in ('틀렸', '거짓', '형편없', '실수 투성', '왜 안', '안되', '제대로')):
                tx['pushback'].append(c.strip().replace('\n', ' ')[:70])
        elif t == 'user' and isinstance(c, list):         # tool_result 안의 게이트 피드백
            blob = json.dumps(c, ensure_ascii=False)
            if '거짓·미검증 보고 차단' in blob: tx['gate_blocks'] += 1
    tx['edited'] = sorted(set(ed))
    return tx

tx = scan_transcript(os.environ.get('NCO_TRANSCRIPT', ''))

# ── 런타임/외부 산출물 필터 — NCO 백엔드 벡터DB(*.hnsw)·redis(*.rdb)·로그·바이너리 등은
#    동시 세션/백엔드 프로세스가 쓰므로 "내 작업"이 아니다. mtime만으로 귀속하면 오염(예: codex.hnsw). (2026-07-10)
NOISE_RE = re.compile(
    r'(^|/)(db|\.git|node_modules|__pycache__|checkpoints|filebak|dist|build|coverage|\.report-cursor)(/|$)'
    r'|\.(hnsw|rdb|log|lock|pyc|pyo|sqlite|sqlite3|db|bin|idx|pack|map)$'
    r'|dump\.rdb|queue\.log|\.report-cursor', re.I)
def is_noise(p):
    return bool(NOISE_RE.search(p or ''))

# ── 멀티레포 git: 세션 시작 이후 커밋 + 세션 중 수정된 dirty 파일 ──
REPOS = []
for r in [os.path.join(PROJECT,'nco'), f'{HOME}/nova-fleet-config', f'{HOME}/.claude', PROJECT]:
    if r not in REPOS:
        REPOS.append(r)

def git(repo, *args):
    try:
        r = subprocess.run(['git','-C',repo]+list(args), capture_output=True, text=True, timeout=10)
        return r.stdout if r.returncode == 0 else ''
    except Exception:
        return ''

def is_repo(repo):
    return bool(git(repo,'rev-parse','--git-dir').strip())

commits = []   # (repo, "hash subject")
changed = []   # (repo, path)
for repo in REPOS:
    if not is_repo(repo):
        continue
    rn = os.path.basename(repo) or repo
    for ln in git(repo,'log',f'--since=@{start}','--pretty=format:%h %s').splitlines():
        if ln.strip():
            commits.append((rn, ln.strip()))
    for ln in git(repo,'diff','--name-only').splitlines():
        ln = ln.strip()
        if not ln or is_noise(ln): continue   # 런타임/바이너리 산출물 제외
        fp = os.path.join(repo, ln)
        try:
            if os.path.getmtime(fp) >= start:
                changed.append((rn, ln))
        except Exception:
            pass

# ── 비-git 편집 스캔 (hooks / .nco-supervisor) — mtime >= 세션 시작 ──
touched = []
SKIP_DIRS = {'.git','checkpoints','filebak','node_modules','__pycache__'}
for base in [f'{HOME}/.claude/hooks', os.path.join(PROJECT,'.nco-supervisor')]:
    if not os.path.isdir(base): continue
    for root, dirs, files in os.walk(base):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
        for fn in files:
            fp = os.path.join(root, fn)
            if is_noise(fp) or fn.endswith(('.bak','.tmp','.swp')): continue
            try:
                if os.path.getmtime(fp) >= start and os.path.getsize(fp) > 0:
                    touched.append(os.path.relpath(fp, HOME))
            except Exception:
                pass
touched = sorted(set(touched))[:12]

# ── decision-log 세션-스코프 추출 (③완료 핵심 + ⑧⑨ 교훈) ──────────
DLOG = os.path.join(PROJECT, '.nco-supervisor', 'decision-log.md')
dl_entries = []   # (ts, desc)
if os.path.exists(DLOG):
    try:
        for ln in open(DLOG, encoding='utf-8'):
            # | 시각 | 결정/작업(action) | 근거(reason) | 증거등급 | ...
            m = re.match(r'\|\s*(~)?\s*(\d{4}-\d{2}-\d{2})\s*(?:(\d{1,2}):(\d{2})|(\d{1,2}):([^\s|]+))?\s*\|\s*([^|]+?)\s*\|\s*([^|]*?)\s*\|', ln)
            if not m: continue
            _, date, hh, mm, bad_hh, bad_mm, action, reason = m.groups()
            if hh is not None and mm is not None:
                ts = f'{date} {int(hh):02d}:{mm}'
            else:
                ts = f'{date} 12:00'
            if ts >= start_str:
                clean = lambda s: re.sub(r'\*+','',s or '').strip()
                a, r = clean(action), clean(reason)
                if a.startswith('모니터링'):   # 반복 모니터링 로그 제외 (노이즈)
                    continue
                dl_entries.append((ts, a, r))
    except Exception:
        pass

# ── backlog 미완료(⑥) ────────────────────────────────────────────
# 세션-스코프 게이트(2026-07-08 사용자 지적 "매번 같은 W9/W15/W16 반복"):
# backlog.md는 감독 세션의 공유 정적 파일이라, 이번 세션 중 변경된 경우에만
# 항목을 나열한다. 미변경이면 요약 한 줄로 대체 — 설계 원칙 "모든 소스 세션-스코프" 준수.
BACKLOG = os.path.join(PROJECT, '.nco-supervisor', 'backlog.md')
pending = []
backlog_fresh = False
if os.path.exists(BACKLOG):
    try:
        backlog_fresh = os.path.getmtime(BACKLOG) >= start
        for ln in open(BACKLOG, encoding='utf-8'):
            s = ln.strip()
            if s.startswith('- [ ]') or s.startswith('- [~]'):
                pending.append(s[5:].strip())
    except Exception:
        pass

# ── PRD 목표(⑦) ──────────────────────────────────────────────────
PRD = os.path.join(PROJECT, '.nco-supervisor', 'nco-a-plus-prd.md')
goal_line = ''
if os.path.exists(PRD):
    try:
        txt = open(PRD, encoding='utf-8').read()
        gm = re.search(r'##\s*목표.*?\n(.*?)(?=\n##|\Z)', txt, re.DOTALL)
        if gm:
            for ln in gm.group(1).splitlines():
                ln = ln.strip()
                if ln and not ln.startswith('#'):
                    goal_line = re.sub(r'\*+','',ln).lstrip('- ').strip()
                    break
    except Exception:
        pass

# ── 의미있는 세션 게이트 (멀티소스 + transcript 실측) ──────────────
tx_active = tx is not None and (len(tx['edited']) >= 1 or tx['deleg'] >= 1 or tx['web'] >= 2 or tx['bash'] >= 3)
meaningful = (tx_active or nco_calls >= 1 or direct >= 3 or len(commits) >= 1
              or len(changed) >= 3 or len(dl_entries) >= 1 or len(touched) >= 3)
if not meaningful:
    out()

# ── 중복 방지 키 (세션-스코프 소스 조합) ───────────────────────────
stage_keys = ['discussion','design','implementation','review','gap_analysis','verification']
done_stages = [k for k in stage_keys if stages.get(k)]
key_src = json.dumps([
    SID,                       # 세션 스코프 — 다른 세션 리포트가 내 리포트를 dedup 억제하지 못하게 (2026-07-08)
    nco_calls, direct,         # track 통계 — 위임/편집이 늘면 새 리포트로 인정
    sorted(c[1] for c in commits),
    sorted(f'{r}/{p}' for r,p in changed),
    [t for t,_,_ in dl_entries],
    touched,
    done_stages,
    # transcript 실측 — 편집/위임/게이트블록이 늘면 새 리포트로 인정 (2026-07-10)
    (tx['edited'], tx['deleg'], tx['gate_blocks'], len(tx['unverified'])) if tx is not None else None,
], ensure_ascii=False)
DEDUP_KEY = hashlib.md5(key_src.encode('utf-8')).hexdigest()

# 이전 노트 로드 (dedup + Before 참조)
import glob as _glob
prev_files = sorted([f for f in _glob.glob(f'{IMPROVE}/{PROJNAME}-*.md') if 'INDEX' not in f],
                    key=lambda p: os.path.getmtime(p), reverse=True)
prev_file = prev_files[0] if prev_files else None
prev_date = ''
if prev_file:
    try:
        head = open(prev_file, encoding='utf-8').read(400)
        km = re.search(r'> key:\s*([0-9a-f]{32})', head)
        if km and km.group(1) == DEDUP_KEY:
            out('📋 리포트 생략 — 직전 리포트 이후 변경 없음 (동일 상태)')
        dm = re.search(r'> 생성:\s*(\S+)', head)
        if dm: prev_date = dm.group(1)
    except Exception:
        pass

# ── Gap 분석(⑤) — 세션-스코프 진실 기반 (2026-07-10 재설계) ─────────
#    파이프라인(new_feature+stage) 세션만 %; 그 외는 가짜% 금지 → 측정불가 + 활동/검증 신호.
verif_sig = ''
if tx is not None:
    verif_sig = f'⚠️보고검증 이슈 {tx["gate_blocks"]}회' if tx['gate_blocks'] else '✅보고검증 이슈 없음'
if task_type == 'new_feature' and done_stages:
    pct  = int(len(done_stages)/6*100)
    gate = '통과 (≥95%)' if pct >= 95 else '미통과 (<95%) → 반복 필요 [end-of-turn-check 강제]'
    gap_block = f'달성률 **{pct}%** ({len(done_stages)}/6 파이프라인 단계) · 기준 95% → **{gate}**'
    if verif_sig: gap_block += f' · {verif_sig}'
elif tx is not None:
    act = (f'편집 {len(tx["edited"])}파일 · 실행 {tx["bash"]}회 · 위임 {tx["deleg"]}건 · '
           f'조사 {tx["web"]}회 · 검증조회 {tx["reads"]}회')
    gap_block = f'**측정불가** (목표대비 자동측정 불가 — 비파이프라인 세션) · 활동: {act} · {verif_sig}'
elif done_stages:
    gap_block = f'**측정불가** (전체 파이프라인 미적용) · 이번 완료 단계: {", ".join(done_stages)}'
else:
    gap_block = '**측정불가** (파이프라인 스테이지 기록 없음 — 직접수정/조회/모니터링 세션)'

# ── ⑧ 자기개선 · ⑨ 자기학습 — decision-log 교훈 결정론적 추출 ──────
LESSON_KW = ['반성','정정','재발','오탐','회귀','누수','cry-wolf','오독','위반','근본원인','버그','에러','누락','스텁','적발']
# (action, reason) 쌍 — ⑧은 reason(문제/원인), ⑨는 action기반 규칙으로 구분 사용
lesson_pairs = [(a, r) for _, a, r in dl_entries if any(k in (a+' '+r) for k in LESSON_KW)]
# 대화형 세션 보완 신호(decision-log 미기록이어도 실측 가능한 교훈): agent 위반·거짓보고 게이트
gate_signals = []
if viol:
    gate_signals.append(f'Agent 도구 위반 {viol}회 — 다음 세션 NCO 위임 우선')
if frc:
    gate_signals.append(f'거짓보고 게이트 누적 {frc}회 — 보고 전 T1 선검증(pre-claim verify) 강화')

# ── ⑧ 문제 · ⑨ 규칙 — transcript 실측 우선, 결정론적 문제→규칙 매핑 (2026-07-10) ──
problems = []   # ⑧ 이번 세션 실제 발견 문제
rules    = []   # ⑨ 다음 세션 적용 규칙
if tx is not None:
    if tx['gate_blocks']:
        problems.append(f'거짓/미검증 보고 게이트 {tx["gate_blocks"]}회 차단됨')
        rules.append('보고 전 T1 선검증 + 영수증 5필드(변경/검증방법/등급/Gap/미검증) 준수')
    if tx['pushback']:
        problems.append(f'사용자 정정·지적 {len(tx["pushback"])}회 (예: "{tx["pushback"][-1]}")')
        rules.append('T3 ack(started/ok/queued)를 완료로 보고 금지 — 부작용 T1 확인 후 주장')
    if tx['selfcorr']:
        problems.append(f'초기 보고 오류로 자기정정 {tx["selfcorr"]}회 발생')
        rules.append('주장 전 pre-claim verify — 부작용을 같은 turn에서 직접 확인')
    if tx['deleg'] and tx['unverified']:
        problems.append(f'위임 발주 후 미검증 항목 {len(tx["unverified"])}건 잔존')
        rules.append('위임은 결과 수집·T1 대조까지 완료해야 "완료" 보고')
for a, r in lesson_pairs[-3:]:
    problems.append((r or a)[:110]); rules.append(f'{a[:50]} → 재발방지 규칙화')
if not problems:                       # transcript/로그 신호 없을 때만 누적 카운터 폴백
    problems += gate_signals; rules += gate_signals
def _uniq(xs):
    seen=set(); o=[]
    for x in xs:
        if x and x not in seen: seen.add(x); o.append(x)
    return o
problems, rules = _uniq(problems), _uniq(rules)

# ── 반복 교훈 누적 원장 + 자동 memory 승격 (2026-07-10, 사용자 승인: 누적+반복승격) ──
# 훅은 매 턴 Stop마다 실행되므로 SID로 '세션당 1회'만 카운트 → count = 교훈이 반복된 '세션 수'.
# count >= PROMOTE_AT 이면 매 세션 로드되는 memory(feedback_auto_*)로 자동 승격 → 영구화·재발방지.
LEDGER     = f'{IMPROVE}/lessons-ledger.json'
PROMOTE_AT = 3
top_recurring = []
try:
    ledger = json.load(open(LEDGER, encoding='utf-8')) if os.path.exists(LEDGER) else {}
except Exception:
    ledger = {}
def _norm(rule):
    k = re.sub(r'\d+', '', rule or '')
    k = re.sub(r'["“”‘’(){}]|예:.*$', '', k)
    return re.sub(r'\s+', ' ', k).strip()[:70]
_mem_dir = ''
_trp = os.environ.get('NCO_TRANSCRIPT', '')
if _trp:
    _cand = os.path.join(os.path.dirname(_trp), 'memory')
    if os.path.isdir(_cand): _mem_dir = _cand
for rule in rules:
    k = _norm(rule)
    if not k: continue
    e = ledger.get(k) or {'rule': rule, 'count': 0, 'sids': [], 'first': now_str, 'promoted': False}
    if SID not in e.get('sids', []):          # 세션당 1회만 증가
        e['sids'] = (e.get('sids', []) + [SID])[-50:]
        e['count'] = e.get('count', 0) + 1
    e['last'] = now_str; e['rule'] = rule
    if e['count'] >= PROMOTE_AT and not e.get('promoted') and _mem_dir:
        # 해시 기반 안정 slug — 한글 규칙도 충돌 없이 고유(가독 정보는 description/body에 보존)
        slug = 'feedback_auto_' + hashlib.md5(k.encode('utf-8')).hexdigest()[:10]
        mf = os.path.join(_mem_dir, slug + '.md')
        try:
            existing = [f for f in os.listdir(_mem_dir) if f.startswith('feedback_auto_')]
            if not os.path.exists(mf) and len(existing) < 40:
                body = ('---\n'
                        f'name: {slug}\n'
                        f'description: 반복교훈 자동승격({e["count"]}세션) — {rule[:66]}\n'
                        'metadata:\n  type: feedback\n---\n\n'
                        f'{rule}\n\n'
                        f'**Why:** advisor-stop이 {e["count"]}개 세션에서 동일 교훈 반복 감지({e["first"]}~{now_str}). '
                        '반복 실수 → 영구 규칙 승격.\n'
                        '**How to apply:** 매 작업 보고·위임 시 이 규칙 선적용. '
                        '관련 [[feedback_no_false_reports]] [[project_advisor_stop_session_truth]]\n')
                open(mf, 'w', encoding='utf-8').write(body)
                idx = os.path.join(_mem_dir, 'MEMORY.md')
                cur = open(idx, encoding='utf-8').read() if os.path.exists(idx) else '# Memory Index\n'
                if slug not in cur:
                    open(idx, 'a', encoding='utf-8').write(
                        f'- [자동승격: {rule[:46]}]({slug}.md) — {e["count"]}세션 반복 교훈 (advisor-stop {DATE})\n')
                e['promoted'] = True
                problems.append(f'♻️교훈 자동승격: "{rule[:40]}" ({e["count"]}세션 반복→memory)')
        except Exception:
            pass
    ledger[k] = e
top_recurring = [v['rule'] for _, v in sorted(ledger.items(), key=lambda kv: -kv[1].get('count', 0))
                 if v.get('count', 0) >= 2][:3]
try:
    open(LEDGER, 'w', encoding='utf-8').write(json.dumps(ledger, ensure_ascii=False, indent=1))
except Exception:
    pass

# ── 9섹션 리포트 조립 ─────────────────────────────────────────────
def bullets(items, empty='(없음)', n=8):
    items = list(items)[:n]
    return '\n'.join(f'- {x}' for x in items) if items else f'- {empty}'

L = []
L.append(f'# 작업 종료 리포트 — {PROJNAME}')
L.append(f'> 생성: {now_str} · 세션창: {start_str} → {time.strftime("%H:%M", time.localtime(now))}')
L.append(f'> 이전 노트: {prev_date or "없음"}')
L.append(f'> key: {DEDUP_KEY}')
L.append('')

# ① 요약
did = []
if tx is not None:                     # transcript = 실제 세션 행위(교차오염 0) 우선
    if tx['edited']: did.append(f'편집 {len(tx["edited"])}파일')
    if tx['deleg']:  did.append(f'NCO위임 {tx["deleg"]}건')
    if tx['web']:    did.append(f'웹조사 {tx["web"]}회')
    if tx['bash']:   did.append(f'실행/검증 {tx["bash"]}회')
else:                                  # 폴백(감독관/transcript 부재): 커밋은 주체미상 명시
    if commits:      did.append(f'레포커밋 {len(commits)}건(주체미상)')
    if changed:      did.append(f'수정파일 {len(changed)}건')
    if touched:      did.append(f'훅/스크립트 {len(touched)}건')
    if nco_calls:    did.append(f'NCO위임 {nco_calls}회')
if dl_entries:   did.append(f'결정로그 {len(dl_entries)}건')
summary = ' · '.join(did) if did else '경미한 활동'
L.append('## ① 요약')
L.append(f'이번 세션 실수행: {summary}. (task_type={task_type})')
if tx is not None and tx['edited']:
    edited = tx['edited'][:10]
else:
    edited = sorted(set([os.path.basename(p) for _,p in changed] +
                        [os.path.basename(t) for t in touched]))[:10]
if edited:
    L.append(f'편집 파일: {", ".join(edited)}')
if dl_entries:
    L.append(f'핵심: {dl_entries[-1][1][:120]}')
L.append('')

# ② Before → After (decision-log 근거=이전 문제, 결정=이번 조치)
L.append('## ② Before → After (변화)')
if dl_entries or commits:
    L.append('| 이전 문제 | 이번 조치 | 근거 |')
    L.append('|---|---|---|')
    for ts, a, r in dl_entries[-6:]:
        before = (r.replace('|','/')[:55]) or '—'
        after  = a.replace('|','/')[:60]
        L.append(f'| {before} | {after} | {ts} |')
    for rn, c in commits[:3]:
        L.append(f'| — | {c.split(" ",1)[-1][:60].replace("|","/")} | {rn} {c.split()[0]} |')
else:
    L.append('변화 없음 (조회/분석 세션)')
L.append('')

# ③ 완료 (검증됨)
L.append('## ③ ✅ 완료 (검증됨)')
done_items = []
for ts, a, r in dl_entries:
    tm = re.search(r'\bT([1-4])\b', a+' '+r)
    tier = 'T'+tm.group(1) if tm else 'T?'
    done_items.append(f'{a[:100]}  _[{ts} · {tier}]_')
if not done_items and commits:
    done_items = [f'{c}  _[{rn}]_' for rn, c in commits[:6]]
L.append(bullets(done_items, '검증된 완료 항목 없음', n=10))
L.append('')

# ④ 미완료·미작업 — backlog 미변경 세션은 반복 나열 대신 요약 한 줄
L.append('## ④ 🚧 미완료·미작업')
if pending and backlog_fresh:
    L.append(bullets(pending, '추적된 미완료 항목 없음', n=8))
elif pending:
    L.append(f'- 백로그 {len(pending)}건 유지 — 이번 세션 변경 없음 (전문: .nco-supervisor/backlog.md)')
else:
    L.append('- 추적된 미완료 항목 없음')
L.append('')

# ⑤ Gap 분석
L.append('## ⑤ 📊 Gap 분석 (Check)')
L.append(gap_block)
L.append('')

# ⑥ 다음 단계 가이드 — ①감독관 backlog(fresh) ②이번 세션 미검증/미수집(transcript) ③신규대기
L.append('## ⑥ ➡️ 다음 단계 가이드')
_next = []
if pending and backlog_fresh:
    for i, p in enumerate(pending[:5]):
        pri = 'High' if i < 2 else 'Med'
        safe = '🟡확인필요' if any(k in p for k in ['배포','재시작','push','deploy','활성화']) else '🟢자동가능'
        _next.append(f'- [{pri}] {p[:100]}  ({safe})')
elif tx is not None and (tx['unverified'] or (tx['deleg'] and tx['gate_blocks'])):
    for u in tx['unverified'][-4:]:
        _next.append(f'- [High] 미검증 항목 종결: {u[:90]}  (🟡확인필요)')
    if tx['deleg']:
        _next.append(f'- [Med] 위임 {tx["deleg"]}건 결과 수집·T1 대조 (🟢자동가능)')
elif pending:
    _next.append(f'- [Med] 백로그 미변경 — 직전과 동일 {len(pending)}건 (전문: .nco-supervisor/backlog.md)')
else:
    _next.append('- [Med] 추적된 후속 작업 없음 — 신규 지시 대기')
L.extend(_next)
L.append('')

# ⑦ 목표 대비 위치
L.append('## ⑦ 🎯 목표 대비 위치')
if goal_line:
    L.append(f'최종 목표: {goal_line[:160]}')
L.append(f'이번 세션 기여: 완료성 항목 {len(done_items)}건 / 미완료 {len(pending)}건 남음')
L.append('')

# ⑧ 자기 개선 (이번 세션 실측 문제 — transcript 우선)
L.append('## ⑧ 🔧 자기 개선 (이번 발견한 문제·원인)')
if problems:
    L.append(bullets(problems[-6:], n=6))
else:
    L.append('- 이번 세션 실측 문제신호 없음(게이트 블록·사용자정정·위반 0). 미묘한 개선점은 대화 맥락 참조.')
L.append('')

# ⑨ 자기 학습 (다음 세션 적용 규칙 — 문제→규칙 결정론 매핑)
L.append('## ⑨ 📚 자기 학습 (다음 세션 적용 규칙)')
learn = rules if rules else ['반복 적용할 신규 규칙 없음 — 기존 규칙 유지']
L.append(bullets(learn, n=4))
L.append('')
L.append('---')
_src = 'transcript(세션진실)' if tx is not None else f'git×{len([r for r in REPOS if is_repo(r)])}repo(폴백)'
L.append(f'_결정론적 생성 (LLM 비의존) · 소스: {_src} · track · decision-log · backlog · PRD_')

REVIEW = '\n'.join(L)

# ── 저장 ──────────────────────────────────────────────────────────
# 파일명에 세션 꼬리표 — 같은 분에 두 세션이 Stop하면 서로 덮어쓰는 충돌 방지 (2026-07-08)
_sid_tag = re.sub(r'[^A-Za-z0-9]', '', SID)[-4:] if SID else 'nosid'
note_file = f'{IMPROVE}/{PROJNAME}-{DATE}-{TIMEHM}-{_sid_tag}.md'
try:
    open(note_file, 'w', encoding='utf-8').write(REVIEW + '\n')
    open(CURSOR, 'w', encoding='utf-8').write(str(now) + '\n')
except Exception as e:
    out(f'[개선노트 저장실패: {e}]')

# docs/improvements 사본
docs = os.path.join(PROJECT, 'docs')
if os.path.isdir(docs) and os.access(docs, os.W_OK):
    try:
        os.makedirs(os.path.join(docs,'improvements'), exist_ok=True)
        open(os.path.join(docs,'improvements',os.path.basename(note_file)),'w',encoding='utf-8').write(REVIEW+'\n')
    except Exception:
        pass

# 인덱스
idx = f'{IMPROVE}/IMPROVEMENTS-INDEX.md'
try:
    line = f'- [{now_str}] **{PROJNAME}** — {summary} → `{os.path.basename(note_file)}`\n'
    open(idx,'a',encoding='utf-8').write(line)
    ls = open(idx,encoding='utf-8').read().splitlines()
    if len(ls) > 30:
        open(idx,'w',encoding='utf-8').write('\n'.join(ls[-30:])+'\n')
except Exception:
    pass

# ── ⑧⑨ + ⑥High → context_note.md "## 5. 다음 세션 필수 인지" 주입 ──
ctx = ''
for cand in [os.path.join(PROJECT,'context_note.md'), f'{HOME}/projects/context_note.md']:
    if os.path.exists(cand):
        ctx = cand; break
carry = []
for rl in top_recurring[:2]:              # 반복 상위 교훈 = 영구(휘발 방지)
    carry.append(f'- [반복학습] {rl[:110]}')
for rl in rules[:2]:
    if not any(rl[:40] in c for c in carry):
        carry.append(f'- [학습] {rl[:110]}')
if tx is not None:
    for u in tx['unverified'][-2:]:
        carry.append(f'- [다음] 미검증 종결: {u[:100]}')
for p in pending[:1]:
    carry.append(f'- [다음] {p[:110]}')
if ctx and carry:
    try:
        text = open(ctx, encoding='utf-8').read()
        section = '## 5. 다음 세션 필수 인지\n' + '\n'.join(carry) + '\n'
        if re.search(r'## 5\. 다음 세션 필수 인지', text):
            text = re.sub(r'## 5\. 다음 세션 필수 인지.*?(?=\n## |\Z)', section, text, flags=re.DOTALL)
        else:
            text = text.rstrip() + '\n\n' + section
        open(ctx,'w',encoding='utf-8').write(text)
    except Exception:
        pass

# ── systemMessage (가독성 digest — 요약/Gap/개선/학습/다음단계만) ──
def _clip(s, n):
    return s.replace('\n',' ').strip()[:n]
D = []
D.append(f'📋 세션 종료 리포트 — {PROJNAME} · {DATE} {time.strftime("%H:%M", time.localtime(now))}')
D.append('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━')
D.append('▶ 요약')
D.append(f'   {summary} · {task_type}')
if edited:
    D.append(f'   편집: {", ".join(edited[:6])}')
D.append('')
D.append('▶ Gap')
D.append(f'   {gap_block.replace("**","")}')
D.append('')
D.append('▶ 자기개선 — 발견한 문제')
if problems:
    for p in problems[-3:]:
        D.append(f'   · {_clip(p, 70)}')
else:
    D.append('   · 실측 문제신호 없음(게이트/정정/위반 0) — 대화 맥락 참조')
D.append('')
D.append('▶ 자기학습 — 다음 세션 규칙')
for x in learn[:3]:
    D.append(f'   · {_clip(x, 70)}')
D.append('')
D.append('▶ 다음 단계')
if pending and backlog_fresh:
    for p in pending[:3]:
        D.append(f'   · [High] {_clip(p,58)}')
elif tx is not None and (tx['unverified'] or (tx['deleg'] and tx['gate_blocks'])):
    for u in tx['unverified'][-2:]:
        D.append(f'   · [High] 미검증 종결: {_clip(u,54)}')
    if tx['deleg']:
        D.append(f'   · [Med] 위임 {tx["deleg"]}건 결과 수집·T1 대조')
elif pending:
    D.append(f'   · 백로그 미변경 — 직전과 동일 {len(pending)}건 (backlog.md 참조)')
else:
    D.append('   · [High] 신규 지시 대기')
D.append('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━')
D.append(f'📄 전문: {note_file}')
out('\n'.join(D))
PYEOF
exit 0
