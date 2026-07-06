#!/bin/bash
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
CURSOR    = f'{IMPROVE}/.report-cursor-{PROJNAME}'

def out(msg=None):
    if msg:
        print(json.dumps({'systemMessage': msg}))
    sys.exit(0)

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
REPORT_MIN_INTERVAL = 900  # 15분
if cursor and (now - cursor) < REPORT_MIN_INTERVAL and os.environ.get('NCO_REPORT_FORCE') != '1':
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
nco_calls = int(tr.get('nco_calls', 0) or 0)
direct    = int(tr.get('direct_edits', 0) or 0)
task_type = tr.get('task_type_max') or tr.get('task_type') or 'unknown'
viol      = int(tr.get('agent_violations', 0) or 0)

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
        if not ln: continue
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
BACKLOG = os.path.join(PROJECT, '.nco-supervisor', 'backlog.md')
pending = []
if os.path.exists(BACKLOG):
    try:
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

# ── 의미있는 세션 게이트 (멀티소스) ────────────────────────────────
meaningful = (nco_calls >= 1 or direct >= 3 or len(commits) >= 1
              or len(changed) >= 3 or len(dl_entries) >= 1 or len(touched) >= 3)
if not meaningful:
    out()

# ── 중복 방지 키 (세션-스코프 소스 조합) ───────────────────────────
stage_keys = ['discussion','design','implementation','review','gap_analysis','verification']
done_stages = [k for k in stage_keys if stages.get(k)]
key_src = json.dumps([
    sorted(c[1] for c in commits),
    sorted(f'{r}/{p}' for r,p in changed),
    [t for t,_,_ in dl_entries],
    touched,
    done_stages,
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
            out()   # 동일 세션-상태 → 재생성 안 함
        dm = re.search(r'> 생성:\s*(\S+)', head)
        if dm: prev_date = dm.group(1)
    except Exception:
        pass

# ── Gap 분석(⑤) — track-stages done/total, 없으면 측정불가 ─────────
if task_type == 'new_feature':
    pct  = int(len(done_stages)/6*100)
    gate = '통과 (≥95%)' if pct >= 95 else '미통과 (<95%) → 반복 필요 [end-of-turn-check 강제]'
    gap_block = f'달성률 **{pct}%** ({len(done_stages)}/6 파이프라인 단계) · 기준 95% → **{gate}**'
elif done_stages:
    gap_block = f'**측정불가** (전체 파이프라인 미적용) · 이번 완료 단계: {", ".join(done_stages)}'
else:
    gap_block = '**측정불가** (파이프라인 스테이지 기록 없음 — 직접수정/조회/모니터링 세션)'

# ── ⑧ 자기개선 · ⑨ 자기학습 — decision-log 교훈 결정론적 추출 ──────
LESSON_KW = ['반성','정정','재발','오탐','회귀','누수','cry-wolf','오독','위반','근본원인','버그','에러','누락','스텁','적발']
# (action, reason) 쌍 — ⑧은 reason(문제/원인), ⑨는 action기반 규칙으로 구분 사용
lesson_pairs = [(a, r) for _, a, r in dl_entries if any(k in (a+' '+r) for k in LESSON_KW)]

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
if commits:      did.append(f'커밋 {len(commits)}건')
if changed:      did.append(f'수정파일 {len(changed)}건')
if touched:      did.append(f'훅/스크립트 {len(touched)}건')
if nco_calls:    did.append(f'NCO위임 {nco_calls}회')
if dl_entries:   did.append(f'결정로그 {len(dl_entries)}건')
summary = ' · '.join(did) if did else '경미한 활동'
L.append('## ① 요약')
L.append(f'이번 세션 실수행: {summary}. (task_type={task_type})')
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

# ④ 미완료·미작업
L.append('## ④ 🚧 미완료·미작업')
L.append(bullets(pending, '추적된 미완료 항목 없음', n=8))
L.append('')

# ⑤ Gap 분석
L.append('## ⑤ 📊 Gap 분석 (Check)')
L.append(gap_block)
L.append('')

# ⑥ 다음 단계 가이드
L.append('## ⑥ ➡️ 다음 단계 가이드')
if pending:
    for i, p in enumerate(pending[:5]):
        pri = 'High' if i < 2 else 'Med'
        safe = '🟡확인필요' if any(k in p for k in ['배포','재시작','push','deploy','활성화']) else '🟢자동가능'
        L.append(f'- [{pri}] {p[:100]}  ({safe})')
else:
    L.append('- [Med] 추적된 후속 작업 없음 — 신규 지시 대기')
L.append('')

# ⑦ 목표 대비 위치
L.append('## ⑦ 🎯 목표 대비 위치')
if goal_line:
    L.append(f'최종 목표: {goal_line[:160]}')
L.append(f'이번 세션 기여: 완료성 항목 {len(done_items)}건 / 미완료 {len(pending)}건 남음')
L.append('')

# ⑧ 자기 개선 (이번 발견한 문제/원인 = reason 컬럼)
L.append('## ⑧ 🔧 자기 개선 (이번 발견한 문제·원인)')
if lesson_pairs:
    L.append(bullets([f'{(r or a)[:120]}  _(조치: {a[:50]})_' for a, r in lesson_pairs[-5:]], n=5))
else:
    L.append('- 이번 구간(커서 이후) 신규 교훈 없음')
L.append('')

# ⑨ 자기 학습 (다음 세션 적용할 규칙 = action 기반, ⑧과 구분)
L.append('## ⑨ 📚 자기 학습 (다음 세션 적용 규칙)')
learn = []
for a, r in lesson_pairs[-3:]:
    learn.append(f'{a[:52]} → 재발방지 규칙화')
if not learn:
    if viol:
        learn.append(f'Agent 도구 위반 {viol}회 — 다음 세션 NCO 위임 우선')
    else:
        learn.append('반복 적용할 신규 교훈 없음 — 기존 규칙 유지')
L.append(bullets(learn, n=3))
L.append('')
L.append('---')
L.append(f'_결정론적 생성 (LLM 비의존) · 소스: git×{len([r for r in REPOS if is_repo(r)])}repo · track · decision-log · backlog · PRD_')

REVIEW = '\n'.join(L)

# ── 저장 ──────────────────────────────────────────────────────────
note_file = f'{IMPROVE}/{PROJNAME}-{DATE}-{TIMEHM}.md'
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
for a, r in lesson_pairs[-2:]:
    carry.append(f'- [학습] {a[:110]}')
for p in pending[:2]:
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
for a, r in (lesson_pairs[-3:] or [('', '이번 구간(커서 이후) 신규 교훈 없음')]):
    D.append(f'   · {_clip(r or a, 64)}')
D.append('')
D.append('▶ 자기학습 — 다음 세션 규칙')
for x in learn[:3]:
    D.append(f'   · {_clip(x, 70)}')
D.append('')
D.append('▶ 다음 단계')
if pending:
    for p in pending[:3]:
        D.append(f'   · [High] {_clip(p,58)}')
else:
    D.append('   · [High] 신규 지시 대기')
D.append('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━')
D.append(f'📄 전문: {note_file}')
out('\n'.join(D))
PYEOF
exit 0
