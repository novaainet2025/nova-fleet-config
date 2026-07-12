#!/bin/bash
# session-goal-check.sh — 현재 세션의 목표 완성도를 결정론적으로 체크·표시
#
# 용도: /loop 1분 체크의 코어. transcript(세션 지상진실)에서 목표별 상태(✅/🔄)를
#       추출하고, Gap(목표기반+T1 grounding)을 계산해 COMPLETE/INCOMPLETE 판정.
#       다음 연결작업(backlog fresh / docs/plans / NCO recommend)을 함께 출력.
#
# 인수:  $1 = transcript_path (없으면 이 프로젝트 최신 세션 jsonl 자동탐색)
# 출력:  human 요약(stderr) + JSON 1줄(stdout)
# exit:  0 = COMPLETE (모든 목표 ✅해결 또는 Gap>=THRESHOLD)
#        2 = INCOMPLETE (진행중/미완 목표 존재 → 루프 계속)
#        3 = 목표없음(heartbeat) 또는 transcript 미확보 (루프 무의미 → 중단)
#
# 종료조건 설계 주의: Gap이 게이트차단 상한(≤60)에 걸린 세션은 추가작업으로 98%
#   도달 불가(구조적). 따라서 1차 종료조건은 "모든 목표 ✅해결"(달성가능)이고,
#   Gap>=THRESHOLD는 보조조건. capped=true면 human 출력에 명시.

set +e
THRESHOLD="${GOAL_CHECK_THRESHOLD:-98}"
TX="${1:-}"
PROJDIR="${CLAUDE_PROJECT_DIR:-/Users/nova-ai/project}"

if [ -z "$TX" ]; then
  # 이 세션 transcript 자동탐색 (프로젝트 디렉터리 최신 jsonl)
  PROJSLUG=$(echo "$PROJDIR" | sed 's#/#-#g')
  TX=$(ls -t "$HOME/.claude/projects/${PROJSLUG}"/*.jsonl 2>/dev/null | head -1)
fi

python3 - "$TX" "$THRESHOLD" <<'PYEOF'
import sys, json, re, os, glob

path = sys.argv[1] if len(sys.argv) > 1 else ''
THRESHOLD = int(sys.argv[2]) if len(sys.argv) > 2 else 98

def user_text(c):
    if isinstance(c, str): return c.strip()
    if isinstance(c, list):
        return '\n'.join(i.get('text','').strip() for i in c
                         if isinstance(i, dict) and i.get('type')=='text').strip()
    return ''

def is_reminder(t):
    if not t: return True
    adm = ('<task-notification>','[task-notification]','<system-reminder>',
           'system-reminder:','Stop hook feedback:','[AUTO-LOOP]',
           # 루프 machinery 자체는 목표 아님 — 자기 프롬프트를 새 목표로 세어 종료불가(self-perpetuate)하던 결함 차단
           '# /loop', '/loop ', 'bash ~/.claude/hooks/session-goal-check',
           'bash $HOME/.claude/hooks/session-goal-check')
    return t.startswith(adm)

RECEIPT = ('검증 영수증',)
def substantive(t):
    t = (t or '').strip()
    if not t or is_reminder(t): return ''
    if any(ln.strip().lower().startswith('검증 영수증') or ln.strip().startswith('- [변경]')
           for ln in t.splitlines()): return ''
    return t

PUSHBACK_RE = re.compile(
    r'틀렸|틀림|잘못\s*(?:했|됐|봤|보고|판단|이해)|거짓말|거짓이(?:야|잖|다|네|라)|'
    r'거짓\s*보고(?:야|잖|네|하)|형편없|엉터리|실수\s*투성|왜\s+[^\n]{0,12}?안\s?[하되돼했]|'
    r'제대로\s*안|똑바로|다시\s*해|안\s*됐|안\s*돼(?:요|잖|$)|왜\s*안')

def classify(txt, is_last=False):
    if is_last: return '🔄진행중'
    if any(k in txt for k in ('done:', '완료', '커밋')): return '✅해결'
    if any(k in txt for k in ('대기','회신 대기','발주')): return '⏳대기'
    return '✅해결'

result = {'goals': [], 'total': 0, 'resolved': 0, 'gap': None,
          'capped': False, 'verdict': 'NO_GOALS', 'gate_blocks': 0,
          'pushback': 0, 'unverified': 0, 'final_receipt': False, 'transcript': path}

if not path or not os.path.exists(path):
    print(json.dumps(result, ensure_ascii=False)); sys.exit(3)

chunks = []; cur = None; gb = 0; pb = 0; unv = 0
try:
    lines = open(path, encoding='utf-8', errors='ignore').read().splitlines()
except Exception:
    print(json.dumps(result, ensure_ascii=False)); sys.exit(3)

for ln in lines[-6000:]:
    try: d = json.loads(ln)
    except Exception: continue
    t = d.get('type'); msg = d.get('message') if isinstance(d.get('message'), dict) else {}
    c = msg.get('content')
    if t == 'assistant' and isinstance(c, list):
        for b in c:
            if isinstance(b, dict) and b.get('type') == 'text':
                txt = b.get('text','')
                chunks.append(txt)
                unv += len(re.findall(r'\[미검증항목\]\s*([^\n]{4,90})', txt))
    elif t == 'user':
        ut = user_text(c)
        if isinstance(c, list) and '거짓·미검증 보고 차단' in json.dumps(c, ensure_ascii=False): gb += 1
        if '거짓·미검증 보고 차단' in ut or 'no-false-report-gate' in ut: gb += 1
        req = substantive(ut)
        if req:
            if cur is not None:
                result['goals'][cur]['status'] = classify('\n'.join(chunks))
            chunks = []
            result['goals'].append({'summary': re.sub(r'\s+',' ',req)[:60], 'status': '🔄진행중'})
            cur = len(result['goals']) - 1
        if ('거짓·미검증 보고 차단' not in ut and 'no-false-report-gate' not in ut
                and PUSHBACK_RE.search(ut)): pb += 1

if cur is not None:
    result['goals'][cur]['status'] = classify('\n'.join(chunks), is_last=True)

final_text = '\n'.join(chunks)
# final_receipt 는 실제 '## 검증 영수증' 헤더로만 판정 (2026-07-12 fix).
# 산문에서 '검증 영수증'을 언급(예: "이 턴은 검증 영수증이 없습니다")해도 오탐해
# 질문/잡담 턴에 autoloop 이 오발화하던 문제 차단.
result['final_receipt'] = bool(re.search(r'(?m)^\s*##\s*검증\s*영수증', final_text))
result['total'] = len(result['goals'])
result['resolved'] = sum(1 for g in result['goals'] if g['status'] == '✅해결')
result['gate_blocks'] = gb; result['pushback'] = pb; result['unverified'] = unv

if result['total'] == 0:
    result['verdict'] = 'NO_GOALS'
    print(json.dumps(result, ensure_ascii=False)); sys.exit(3)

# Gap = 목표 완료율 (advisor-stop L2와 동일: 완료율/보고품질 분리, 상한 없음)
# [RC-B fix 2026-07-12] 검증 영수증 '존재'만으로 마지막 목표를 완료 승격하면 안 된다.
#   no-false-report-gate + CLAUDE.md 규칙#1 이 매 보고에 '## 검증 영수증'을 강제하므로,
#   영수증 유무는 완료 신호가 될 수 없다(규칙 충돌 → 루프가 매 턴 조기종료 = 사용자 증상).
#   대신 영수증이 스스로 기록하는 [Gap] N% 를 완료 신호로 쓴다:
#     - [Gap] N% 가 있으면 N>=THRESHOLD 일 때만 승격(마지막 목표 해결로 인정)
#     - [Gap]% 미기재 시엔 진행/미완 텍스트 신호 부재를 요구(보수적: 애매하면 루프 계속)
#   종료 가능성 보존: 진짜 완료 턴은 [Gap] 100%(또는 미완신호 없는 영수증)로 종료된다.
# 영수증 필드 줄(줄머리 '- [Gap] N%')에만 앵커 — 산문 속 '[Gap]100%' 언급 오탐 방지
_gapm = re.findall(r'(?m)^\s*-\s*\[Gap\][^\n]*?(\d{1,3})\s*%', final_text)
_open_sig = ('진행중', '진행 중', '다음 작업', '다음 단계', '보류', '승인 대기',
             '확인 후 진행', '질문:', '이어서 진행', '계속 진행')
if _gapm:
    _receipt_done = int(_gapm[-1]) >= THRESHOLD
else:
    _receipt_done = not any(s in final_text for s in _open_sig)
last_promoted = result['final_receipt'] and _receipt_done and result['resolved'] < result['total']
result['receipt_done'] = _receipt_done
eff = result['resolved'] + (1 if last_promoted else 0)
gap = round(eff / result['total'] * 100)
result['gap'] = gap
result['quality_issues'] = {'gate_blocks': gb, 'pushback': pb, 'unverified': unv}
result['eff_resolved'] = eff

# 판정: 달성가능 종료조건 = 모든 목표 ✅해결(마지막턴 영수증 승격 포함). Gap>=THRESHOLD 보조.
all_resolved = (eff >= result['total'])
result['verdict'] = 'COMPLETE' if (all_resolved or gap >= THRESHOLD) else 'INCOMPLETE'

# 사람용 요약(stderr)
def e(s): sys.stderr.write(s + '\n')
e('━━━ 세션 목표 체크 ━━━')
for i, g in enumerate(result['goals'], 1):
    e(f'  {g["status"]}  {i}. {g["summary"]}')
q = [x for x in ([f'게이트{gb}' if gb else '', f'지적{pb}' if pb else '', f'미검증{unv}' if unv else '']) if x]
qnote = f' · ⚠️보고품질 이슈({", ".join(q)}, 완료율과 별도)' if q else ''
e(f'Gap(완료율): {gap}% (목표 {eff}/{result["total"]} 해결){qnote}')
e(f'판정: {result["verdict"]}' + (' — 모든 목표 ✅해결' if all_resolved
   else ' — 진행중/미완 목표 존재' if result['verdict']=='INCOMPLETE' else ''))

# ▶ 다음 단계 (체크 강화) — INCOMPLETE면 미완 목표를 자동실행 대상으로 명시.
# 루프는 이 목록이 비면(모두 ✅) COMPLETE로 종료 → "다음 단계 없을 때까지 진행" 계약 충족.
# [2026-07-12 fix] 현재(마지막) 턴 cur 은 "지금 답변 중인 프롬프트"라 항상 🔄진행중 →
#   next_steps 에 넣으면 "다음 단계 있는데 왜 진행 안하지?" 착시(사용자 반복 지적). cur 제외:
#   실제 '다음 단계' = 이전에 남겨둔 미완 목표만. (verdict 계산은 불변 — 표시/자동실행 대상만 정정)
_next = [g['summary'] for i, g in enumerate(result['goals'])
         if g['status'] in ('🔄진행중', '⏳대기') and i != cur]
result['next_steps'] = _next
if result['verdict'] == 'INCOMPLETE' and _next:
    e('▶ 다음 단계 (자동 실행 대상):')
    for _s in _next[:5]:
        e(f'  - {_s}')
elif result['verdict'] == 'COMPLETE':
    e('▶ 다음 단계: 없음 — 루프 종료')

print(json.dumps(result, ensure_ascii=False))
sys.exit(0 if result['verdict'] == 'COMPLETE' else 2)
PYEOF
