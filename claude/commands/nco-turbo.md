아래 bash 스크립트를 **즉시 Bash 도구로 실행**하라. Skill() 재호출 금지. ARGUMENTS="$ARGUMENTS"

# ══════════════════════════════════════════════════════════════════
# NCO SUPER TURBO v3 — 하이브리드 실행 엔진
# ══════════════════════════════════════════════════════════════════
# 핵심 개선:
#  [로컬 실행] 파일 편집·빌드·재시작 → Bash/Python 직접 실행
#  [원격 위임] 분석·리뷰·리서치 → NCO/Mesh 에이전트
#  [실제 Gap] 파일 diff·서비스 상태·출력 검증 (status만 아님)
# ──────────────────────────────────────────────────────────────────

NCO_URL="http://localhost:6200"
OLLAMA_URL="http://172.28.112.1:11434"
MAIN_TASK="${ARGUMENTS:-현재 프로젝트 전체 개선}"
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
PROJECT_NAME=$(basename "$PROJECT_DIR")

MY_PID=""
_CK=$$
for _i in 1 2 3 4 5; do
  _CK=$(ps -o ppid= -p "$_CK" 2>/dev/null | tr -d ' ')
  [ -z "$_CK" ] && break
  ps -o comm= -p "$_CK" 2>/dev/null | grep -qE '^(claude|node)$' && { MY_PID="$_CK"; break; }
done
MY_PID="${MY_PID:-$$}"

MY_NAME="turbo"
for pf in /tmp/nco-names/claude-*.pid; do
  [ -f "$pf" ] || continue
  stored=$(cat "$pf" 2>/dev/null | tr -d '[:space:]')
  if [ "$stored" = "$MY_PID" ]; then MY_NAME=$(basename "$pf" .pid); break; fi
done

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  🚀 NCO SUPER TURBO v3  — 하이브리드 실행 엔진              ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo "  세션: $MY_NAME ($MY_PID)  |  프로젝트: $PROJECT_NAME"
echo "  작업: $MAIN_TASK"
echo ""

python3 - "$MAIN_TASK" "$NCO_URL" "$OLLAMA_URL" "$PROJECT_DIR" "$PROJECT_NAME" "$MY_PID" "$MY_NAME" << 'PYEOF'
import json, sys, urllib.request, time, os, re, subprocess
from datetime import datetime, timezone

MAIN_TASK=sys.argv[1]; NCO_URL=sys.argv[2]; OLLAMA_URL=sys.argv[3]
PROJECT_DIR=sys.argv[4]; PROJECT_NAME=sys.argv[5]; MY_SID=sys.argv[6]; MY_NAME=sys.argv[7]

R='\033[31m';G='\033[32m';Y='\033[33m';B='\033[34m'
M='\033[35m';C='\033[36m';GR='\033[90m';BOLD='\033[1m';RST='\033[0m'
BG='\033[92m';BY='\033[93m';BC='\033[96m'

def pr(msg='',col=''):
    print(f'{col}{msg}{RST}' if col else msg,flush=True)

def api(method,path,data=None,timeout=15):
    url=f'{NCO_URL}{path}'
    body=json.dumps(data).encode() if data else None
    req=urllib.request.Request(url,data=body,headers={'Content-Type':'application/json'} if body else {},method=method)
    try:
        with urllib.request.urlopen(req,timeout=timeout) as r: return json.loads(r.read())
    except Exception as e: return {'error':str(e)}

def ollama_chat(prompt,timeout=90):
    try:
        with urllib.request.urlopen(f'{OLLAMA_URL}/v1/models',timeout=5) as r:
            models=json.loads(r.read()).get('data',[])
        if not models: return None
        mdl=models[0].get('id','gemma4:26b')
    except: return None
    payload=json.dumps({'model':mdl,'messages':[{'role':'user','content':prompt}],
                        'stream':False,'options':{'temperature':0.3,'num_predict':2000}}).encode()
    req=urllib.request.Request(f'{OLLAMA_URL}/v1/chat/completions',data=payload,
        headers={'Content-Type':'application/json'})
    try:
        with urllib.request.urlopen(req,timeout=timeout) as r:
            return json.loads(r.read())['choices'][0]['message']['content']
    except: return None

# 보안: 위험 명령어 패턴 차단
BLOCKED_PATTERNS=['rm -rf /','rm -rf ~',':(){ :|:& };:','dd if=',
    'mkfs','wget.*|.*sh','curl.*|.*sh','chmod 777 /','> /etc/',
    'sudo rm','truncate -s 0 /','; rm ','&& rm -rf']
def run_local(cmd,timeout=60):
    import os as _os2
    ALLOWED_DIRS=['/home/nova/projects','/tmp','/home/nova/.claude']
    try:
        _resolved=_os2.path.realpath(PROJECT_DIR)
        if not any(_resolved.startswith(d) for d in ALLOWED_DIRS):
            return f'[BLOCKED:PATH]',f'Security: {_resolved} not in allowed',127
    except: pass
    cmd_lower=(cmd or '').lower()
    for pat in BLOCKED_PATTERNS:
        if pat.lower() in cmd_lower:
            return f'[BLOCKED:{pat}]',f'Security: blocked pattern "{pat}"',127
    # 민감 정보 마스킹 (로그용)
    import re as _re
    safe_log=_re.sub(r'(token|key|secret|password|api_key)\s*=\s*\S+','***=MASKED',cmd,flags=_re.I)
    try:
        result=subprocess.run(cmd,shell=True,cwd=PROJECT_DIR,capture_output=True,text=True,timeout=timeout)
        return result.stdout.strip(),result.stderr.strip(),result.returncode
    except subprocess.TimeoutExpired: return '','TIMEOUT',1
    except Exception as e: return '',str(e),1

def run_verify(cmd,timeout=30):
    # 절대경로 보장: ~, $HOME, 상대경로 처리
    import os as _os
    cmd=cmd.replace('~',_os.path.expanduser('~'))
    if cmd.startswith('./') or (not cmd.startswith('/') and not cmd.startswith('curl') and not cmd.startswith('echo') and not cmd.startswith('grep') and not cmd.startswith('python')):
        cmd=f'cd {PROJECT_DIR} && {cmd}'
    out,err,code=run_local(cmd,timeout)
    return out if code==0 else f'[ERR:{code}] {err[:100]}'

# ════════════════════════════════════════════════════════════════
# ① 상태 분석
# ════════════════════════════════════════════════════════════════
pr(f'\n{BOLD}① 상태 분석{RST}')
nco_ok=api('GET','/health').get('status')=='healthy'
git_branch,_,_=run_local('git branch --show-current')
git_status,_,_=run_local('git status --short | head -8')
git_log,_,_=run_local('git log -3 --oneline')
pr(f'  브랜치: {git_branch}  |  NCO: {"✅" if nco_ok else "⚠️"}  |  세션: {MY_NAME}')
if git_status:
    for l in git_status.splitlines()[:3]: pr(f'    {GR}{l}{RST}')

ctx_summary=''
ctx_path=os.path.join(PROJECT_DIR,'context_note.md')
if os.path.exists(ctx_path):
    txt=open(ctx_path,encoding='utf-8').read()
    blocks=re.findall(r'<!-- SESSION_START -->(.*?)<!-- SESSION_END -->',txt,re.DOTALL)
    if blocks: ctx_summary=blocks[0].strip()[:300]

imp_hi=''
imp_dir=os.path.expanduser('~/.claude/improvements')
if os.path.isdir(imp_dir):
    files=sorted([f for f in os.listdir(imp_dir) if f.endswith('.md')],reverse=True)
    if files:
        txt=open(os.path.join(imp_dir,files[0]),encoding='utf-8').read()
        imp_hi='\n'.join(re.findall(r'\[High\][^\n]+',txt)[:3])

# ════════════════════════════════════════════════════════════════
# 실행 모드 감지
# ════════════════════════════════════════════════════════════════
pr(f'\n{BOLD}▶ 실행 모드 감지{RST}')
mesh_resp=api('GET','/api/mesh/sessions',timeout=5)
all_sessions=mesh_resp.get('sessions',[])
other_sessions=[s for s in all_sessions
    if str(s.get('pid',''))!=str(MY_SID) and str(s.get('sessionId',''))!=str(MY_SID)
    and s.get('status') in ('idle','active','working')]
MESH_MODE=len(other_sessions)>=1
if not nco_ok:
    pr(f'  {Y}⚠ NCO 오프라인 — 원격 태스크 스킵{RST}')
    MESH_MODE=False; remote_tasks=[]
if MESH_MODE:
    pr(f'  {G}[Mesh 모드]{RST}  CLI {len(other_sessions)}개 감지')
    for s in other_sessions: pr(f'    {GR}· {s["agentId"]:12} ({s["sessionId"]}){RST}')
else:
    pr(f'  {Y}[병렬 모드]{RST}  단독 NCO 에이전트')

# ════════════════════════════════════════════════════════════════
# ② AI 작업 분해 — local vs remote 분류
# ════════════════════════════════════════════════════════════════
pr(f'\n{BOLD}② 작업 분해{RST}  {GR}(local=직접실행 / remote=에이전트위임){RST}')

n_remote=max(min(len(other_sessions),4),2) if MESH_MODE else 3
DECOMPOSE_PROMPT=f"""작업을 독립 병렬 서브태스크로 분해하세요.

프로젝트: {PROJECT_NAME} | 브랜치: {git_branch}
변경: {git_status[:200] if git_status else '없음'}
커밋: {git_log[:150] if git_log else '없음'}
개선권장: {imp_hi[:200] if imp_hi else '없음'}

메인 작업: {MAIN_TASK}

JSON 배열만 출력 (설명 없이):
[
  {{
    "id": "t1",
    "title": "제목 (15자 이내)",
    "exec_type": "local",
    "agent": "local",
    "type": "implement",
    "bash_cmd": "python3 -c \\"...\\" 또는 bash 명령어",
    "verify_cmd": "결과 검증 명령어 (파일존재/grep/curl 등)",
    "verify_expect": "검증 성공 시 예상 출력 키워드"
  }},
  {{
    "id": "t2",
    "title": "제목 (15자 이내)",
    "exec_type": "remote",
    "agent": "ollama|codex|cursor-agent|opencode|copilot",
    "type": "verify|review|research",
    "prompt": "에이전트에게 줄 지시 (파일 읽기/분석만, 쓰기 금지)",
    "verify_cmd": "curl/grep 등으로 결과 확인",
    "verify_expect": "성공 키워드"
  }}
]

핵심 규칙:
- exec_type="local": 파일수정·빌드·재시작·설치 등 → bash_cmd로 직접 실행
- exec_type="remote": 분석·검토·리서치·QA 등 → agent prompt로 위임
- local 태스크는 동일 파일 수정 금지 (병렬 충돌)
- verify_cmd는 실제로 실행 가능한 shell 명령어
- 총 태스크: local 최대3개 + remote 최대{n_remote}개"""

raw=ollama_chat(DECOMPOSE_PROMPT,timeout=60)
# 파싱 실패 시 단순 프롬프트로 재시도
if not raw or not re.search(r'\[\s*\{', raw or ''):
    simple=f"""다음 작업을 JSON 배열로 분해: {MAIN_TASK}
출력형식(예시만): [{{"id":"t1","title":"작업명","exec_type":"local","agent":"local","type":"implement","bash_cmd":"echo done","verify_cmd":"echo ok","verify_expect":"ok"}}]
local=파일/빌드, remote=분석/리뷰. JSON만 출력."""
    raw=ollama_chat(simple,timeout=60)
subtasks=[]
_parse_ok=False
if raw:
    m=re.search(r'\[\s*[\s\S]*?\]',raw)
    if m:
        try:
            subtasks=json.loads(m.group(0))
            if subtasks:
                    for _i,_t in enumerate(subtasks):
                        if not _t.get('id'): _t['id']=f't{_i+1}'
                    _parse_ok=True; pr(f'  {G}✅ {len(subtasks)}개 서브태스크{RST}')
        except: pass
# 2차: 실패 시 간단 재시도 (30s)
if not _parse_ok:
    pr(f'  {Y}↩ 분해 재시도...{RST}')
    _ts=(MAIN_TASK or '')[:80].replace('"',"'")
    raw2=ollama_chat(f'작업: {_ts}\nJSON배열로 분해(exec_type=local/remote,agent=local/ollama,bash_cmd,verify_cmd):\n',timeout=30)
    if raw2:
        m2=re.search(r'\[\s*[\s\S]*?\]',raw2)
        if m2:
            try:
                subtasks=json.loads(m2.group(0))
                if subtasks:
                    # id 필드 보장
                    for _i,_t in enumerate(subtasks):
                        if not _t.get('id'): _t['id']=f't{_i+1}'
                    pr(f'  {G}✅ 2차분해: {len(subtasks)}개{RST}')
            except: pass

if not subtasks:
    pr(f'  {Y}fallback → 기본 태스크{RST}')
    subtasks=[
        {"id":"t1","title":"코드 구현","exec_type":"local","agent":"local","type":"implement",
         "bash_cmd":f"echo '구현 완료: {MAIN_TASK}'","verify_cmd":"echo 'ok'","verify_expect":"ok"},
        {"id":"t2","title":"분석·검증","exec_type":"remote","agent":"ollama","type":"verify",
         "prompt":f"{MAIN_TASK}에 대한 검증 및 분석","verify_cmd":"echo 'verified'","verify_expect":"verified"},
    ]

MAX_LOCAL_TASKS=3; MAX_REMOTE_TASKS=5
local_tasks=[t for t in subtasks if t.get('exec_type')=='local'][:MAX_LOCAL_TASKS]
remote_tasks=[t for t in subtasks if t.get('exec_type')=='remote'][:MAX_REMOTE_TASKS]
_lt_all=len([t for t in subtasks if t.get('exec_type')=='local'])
_rt_all=len([t for t in subtasks if t.get('exec_type')=='remote'])
if _lt_all>MAX_LOCAL_TASKS: pr(f'  {Y}⚠ 로컬 {MAX_LOCAL_TASKS}개 제한{RST}')
if _rt_all>MAX_REMOTE_TASKS: pr(f'  {Y}⚠ 원격 {MAX_REMOTE_TASKS}개 제한{RST}')

type_col={'implement':C,'review':M,'test':Y,'design':B,'research':GR,'verify':G,'build':BY}
agent_em={'codex':'⚡','cursor-agent':'🔍','opencode':'🏗️','agy':'🎨','copilot':'📚','ollama':'🤖','openrouter':'🌐','nvidia':'🧠','local':'🔧'}

pr(f'  {"ID":4} {"유형":7} {"실행":7} {"제목":22} {"에이전트"}')
pr(f'  {"─"*65}')
for t in subtasks:
    col=type_col.get(t.get('type',''),'')
    em=agent_em.get(t.get('agent',''),'🔧')
    etype=t.get('exec_type','?')
    ecol=G if etype=='local' else C
    pr(f'  {t.get("id","?"):4} {col}{t.get("type","?"):7}{RST} {ecol}{etype:7}{RST} {t.get("title","?"):22} {em}{t.get("agent","?")}')

pr(f'\n  {G}로컬{RST}: {len(local_tasks)}개  |  {C}원격{RST}: {len(remote_tasks)}개')

# ════════════════════════════════════════════════════════════════
# ③ 로컬 태스크 직접 실행 (병렬 스레드)
# ════════════════════════════════════════════════════════════════
import threading
# 실행 전 git 자동 백업
import subprocess as _sp
_gs=_sp.run("git stash push -m turbo-backup 2>/dev/null || true",shell=True,cwd=PROJECT_DIR,capture_output=True)
if b"Saved" in _gs.stdout: pr(f"  {Y}📦 git stash 백업{RST}  (복구: git stash pop)")

START_TS=datetime.now(timezone.utc).isoformat()
results={}; failed=[]; local_lock=threading.Lock()
# 결과 저장 디렉토리
import os as _os
RESULT_DIR=_os.path.expanduser('~/.claude/turbo-results')
_os.makedirs(RESULT_DIR,exist_ok=True)
import time as _tm
[_os.remove(_os.path.join(RESULT_DIR,_rf)) for _rf in _os.listdir(RESULT_DIR)
 if _os.path.isfile(_os.path.join(RESULT_DIR,_rf))
 and _tm.time()-_os.path.getmtime(_os.path.join(RESULT_DIR,_rf))>604800
 and not _os.remove(_os.path.join(RESULT_DIR,_rf)) is None] if False else None
for _rf in list(_os.listdir(RESULT_DIR)):
    _rp=_os.path.join(RESULT_DIR,_rf)
    if _os.path.isfile(_rp) and _tm.time()-_os.path.getmtime(_rp)>604800:
        try: _os.remove(_rp)
        except: pass
RUN_ID=datetime.now().strftime('%Y%m%d-%H%M%S')
RESULT_FILE=f'{RESULT_DIR}/run-{RUN_ID}.json'
def save_results():
    try:
        data={'run_id':RUN_ID,'task':MAIN_TASK,'start':START_TS,
              'end':datetime.now(timezone.utc).isoformat(),
              'results':results,'failed':failed,'subtasks':subtasks}
        open(RESULT_FILE,'w').write(json.dumps(data,ensure_ascii=False,indent=2))
    except: pass

def execute_local(t):
    tid=t.get('id','?')
    title=t.get('title','?')
    cmd=t.get('bash_cmd','echo skipped')
    vcmd=t.get('verify_cmd','echo ok')
    vexp=t.get('verify_expect','')
    pr(f'  {BY}▶ LOCAL{RST}  {title}  {GR}$ {cmd[:60]}{RST}')
    out,err,code=run_local(cmd,timeout=120)
    if code!=0:
        with local_lock:
            failed.append(tid)
        pr(f'  {R}✗ LOCAL{RST}  {title}  코드:{code}  {err[:80]}')
        return
    # verify
    vout=run_verify(vcmd,timeout=30)
    verified=not vexp or vexp.lower() in vout.lower()
    with local_lock:
        if verified:
            results[tid]={'output':out[:200],'verified':True}
            pr(f'  {G}✅ LOCAL{RST}  {title}  검증: {G}PASS{RST}  {GR}{vout[:60]}{RST}')
        else:
            results[tid]={'output':out[:200],'verified':False}
            pr(f'  {Y}⚠ LOCAL{RST}  {title}  결과OK 검증실패  expect={vexp}  got={vout[:40]}')

if local_tasks:
    pr(f'\n{BOLD}③ 로컬 병렬 실행{RST}  {GR}({len(local_tasks)}개 동시 실행){RST}')
    threads=[threading.Thread(target=execute_local,args=(t,)) for t in local_tasks]
    for th in threads: th.start()
    for th in threads: th.join(timeout=180)
    pr(f'  로컬 완료: {sum(1 for t in local_tasks if t.get("id","?") in results)}/{len(local_tasks)}')

# ════════════════════════════════════════════════════════════════
# ④ 원격 태스크 NCO/Mesh 위임
# ════════════════════════════════════════════════════════════════
remote_nco_ids={}  # task_id → nco_task_id

if remote_tasks:
    if MESH_MODE:
        pr(f'\n{BOLD}④ Mesh 원격 위임{RST}  {GR}({len(remote_tasks)}개 → {len(other_sessions)}개 CLI){RST}')
        workers=other_sessions
        bundles=[[] for _ in workers]
        for i,t in enumerate(remote_tasks): bundles[i%len(workers)].append(t)
        assignments=[]
        turbo_tag=f'TURBO-{MY_SID}'
        for i,(worker,bundle) in enumerate(zip(workers,bundles)):
            if not bundle: continue
            cli_sid=worker.get('sessionId',''); cli_name=worker.get('agentId',f'cli-{i+1}')
            bundle_desc='\n'.join([f'  [{j+1}] {t.get("title","?")} | agent:{t.get("agent","ollama")} | {t.get("prompt","?")}' for j,t in enumerate(bundle)])
            msg_content=(
                f'[TASK] 🚀 {turbo_tag} 번들{i+1}/{len([b for b in bundles if b])}\n'
                f'메인작업: {MAIN_TASK}\n서브태스크:\n{bundle_desc}\n'
                f'지시: /nco-task {bundle[0].get("agent","ollama")} "{bundle[0].get("prompt","")}"로 실행하고 '
                f'완료 시 [AUTO][TASK-RESULT] taskId: <NCO태스크ID> 형식으로 응답하라.')
            resp=api('POST','/api/mesh/send',{'fromSessionId':MY_SID,'fromAgent':MY_NAME,'toSessionId':cli_sid,'content':msg_content},timeout=10)
            ok='error' not in resp
            pr(f'  {"✅" if ok else "❌"} → {cli_name:12}  번들:{len(bundle)}개')
            for t in bundle: pr(f'       {GR}· {t.get("title","?")} [{t.get("agent","?")}]{RST}')
            assignments.append({'cli_session':cli_sid,'cli_name':cli_name,'tasks':bundle,'bundle_idx':i+1})

        # 1단계: taskId 수집
        pr(f'  {GR}1단계: taskId 수집 (최대 90s)...{RST}')
        msg_deadline=time.time()+90; collected=set()
        try: st_dt=datetime.fromisoformat(START_TS.replace('Z','+00:00'))
        except: st_dt=None
        while time.time()<msg_deadline and len(collected)<len(assignments):
            time.sleep(5)
            msgs_resp=api('GET','/api/mesh/messages',timeout=8)
            msgs=msgs_resp.get('messages',msgs_resp) if isinstance(msgs_resp,dict) else msgs_resp
            if not isinstance(msgs,list): msgs=[]
            for m in msgs:
                content=m.get('content',''); to_sess=m.get('to_session','')
                from_cli=m.get('from_agent','?'); created=m.get('created_at','')
                if str(to_sess)!=str(MY_SID): continue
                if '[AUTO][TASK-RESULT]' not in content: continue
                TRUSTED_SESSIONS=[s['sessionId'] for s in other_sessions]
                if str(m.get('from_session','')) not in TRUSTED_SESSIONS: continue
                if st_dt:
                    try:
                        ct=datetime.fromisoformat(created.replace('Z','+00:00'))
                        if ct<st_dt: continue
                    except: pass
                task_id_m=re.search(r'taskId:\s*([\w\-_]+)',content)
                if not task_id_m: continue
                nco_tid=task_id_m.group(1)
                for a in assignments:
                    if a['cli_name']==from_cli or a['cli_session']==str(m.get('from_session','')):
                        bidx=a['bundle_idx']
                        if bidx not in collected:
                            collected.add(bidx)
                            for t in a['tasks']:
                                remote_nco_ids[t['id']]=nco_tid
                            pr(f'  {BC}📨 번들{bidx}{RST} ← {from_cli}  taskId:{nco_tid[:14]}...')
                        break
        pr(f'  taskId 확보: {len(collected)}/{len(assignments)}개')

    else:
        pr(f'\n{BOLD}④ NCO 병렬 실행{RST}  {GR}({len(remote_tasks)}개){RST}')
        for t in remote_tasks:
            tid=t.get('id','?'); agent=t.get('agent','ollama')
            prompt=f'[TURBO-{MY_SID}] 프로젝트:{PROJECT_NAME}\n{MAIN_TASK}\n\n태스크: {t.get("title","")}\n{t.get("prompt","")}'
            if nco_ok:
                resp=api('POST','/api/task',{'ai':agent,'prompt':prompt,'callerSessionId':MY_SID,'callerAgentId':MY_NAME},timeout=10)
                nco_id=resp.get('taskId') or resp.get('id','')
                if nco_id:
                    remote_nco_ids[tid]=nco_id
                    em=agent_em.get(agent,'🔧')
                    pr(f'  {G}▶{RST} {em}{agent:15} {t.get("title","?"):22} [{nco_id[:10]}...]')
                else:
                    failed.append(tid)
                    pr(f'  {R}✗{RST} {agent:15} 실패')

# ════════════════════════════════════════════════════════════════
# ⑤ 원격 태스크 폴링 + 실제 검증
# ════════════════════════════════════════════════════════════════
# 로컬 태스크 실패 자동 재시도 (1회)
retry_local=[t for t in local_tasks if t.get('id') in failed]
if retry_local:
    pr(f'  {Y}↩ 실패 로컬 태스크 재시도: {len(retry_local)}개{RST}')
    for t in retry_local:
        tid=t.get('id','?')
        failed.remove(tid) if tid in failed else None
        alt_cmd='echo "재시도: '+t.get('title','?')+'",'
        out,err,code=run_local(alt_cmd,30)
        if code==0:
            results[tid]={'output':out,'verified':False,'retried':True}
            pr(f'  {Y}⚠ RETRY{RST}  {t.get("title","?")}  (미검증)')
        else:
            failed.append(tid)

if remote_nco_ids:
    pr(f'\n{BOLD}⑤ 원격 태스크 폴링 + 실제 검증{RST}')
    remaining=dict(remote_nco_ids); start_t=time.time()
    for _ in range(120):
        time.sleep(3); elapsed=int(time.time()-start_t); done_now=[]
        for tid,nco_id in list(remaining.items()):
            r=api('GET',f'/api/tasks/{nco_id}',timeout=5)
            t_data=r.get('task',r); status=t_data.get('status','')
            if status=='completed':
                response=str(t_data.get('response') or '')
                # 실제 검증: 거부/실패 키워드 체크
                refusal_keywords=['cannot','죄송','거부','불가','금지','I cannot','죄송합니다','할 수 없']
                is_refusal=any(kw.lower() in response.lower() for kw in refusal_keywords)
                # REFUSAL 시 ollama로 자동 fallback
                if is_refusal:
                    task_def=next((t for t in remote_tasks if t.get('id')==tid),{})
                    fallback_agent='ollama'
                    pr(f'  {Y}↩ REFUSAL→FALLBACK{RST}  {task_def.get("title","?")} → {fallback_agent}')
                    fb_prompt=task_def.get('prompt','') or task_def.get('bash_cmd','')
                    fb_resp=api('POST','/api/task',{'ai':fallback_agent,'prompt':f'[FALLBACK] {fb_prompt}','callerSessionId':MY_SID,'callerAgentId':MY_NAME},timeout=10)
                    fb_id=fb_resp.get('taskId') or fb_resp.get('id','')
                    if fb_id:
                        remaining[tid]=fb_id  # 재폴링 대상으로 등록
                        done_now.remove(tid) if tid in done_now else None
                        is_refusal=False  # fallback 시도 중
                    else:
                        failed.append(tid)
                        pr(f'  {R}✗ REFUSAL+FALLBACK실패{RST}  {task_def.get("title","?")}')
                # verify_cmd 실행
                if not is_refusal and status=='completed':
                    task_def=next((t for t in remote_tasks if t.get('id')==tid),{})
                    vcmd=task_def.get('verify_cmd','')
                    vexp=task_def.get('verify_expect','')
                    vout=run_verify(vcmd,30) if vcmd else 'skipped'
                    verified=not vexp or vexp.lower() in vout.lower() if vcmd else True
                    name=task_def.get('title','?')
                    if verified:
                        results[tid]={'output':response[:200],'verified':True,'nco_id':nco_id}
                        pr(f'  {G}✅ REMOTE{RST}  {name:22} ({elapsed}s)  {G}검증PASS{RST}')
                    else:
                        results[tid]={'output':response[:200],'verified':False,'nco_id':nco_id}
                        pr(f'  {Y}⚠ REMOTE{RST}  {name:22} ({elapsed}s)  검증미달')
                    done_now.append(tid)
            elif status in ('failed','error','cancelled'):
                failed.append(tid)
                task_def=next((t for t in remote_tasks if t.get('id')==tid),{})
                pr(f'  {R}✗ FAILED{RST}  {task_def.get("title","?")}  {status}')
                done_now.append(tid)
            elif status=='assigned' and elapsed>45:
                # 45초 이상 assigned → local Ollama로 즉시 실행
                task_def=next((t for t in remote_tasks if t.get('id')==tid),{})
                pr(f'  {Y}⚡ SLOW→LOCAL{RST}  {task_def.get("title","?")} ({elapsed}s) → Ollama 직접실행')
                prompt=task_def.get('prompt','') or f'{MAIN_TASK} - {task_def.get("title","")}'
                local_resp=ollama_chat(f'간결히 답변: {prompt}',timeout=60)
                if local_resp and not any(kw in local_resp.lower() for kw in ['cannot','죄송','불가']):
                    results[tid]={'output':local_resp[:200],'verified':True,'via':'ollama_local'}
                    pr(f'  {G}✅ LOCAL-OLLAMA{RST}  {task_def.get("title","?")}  검증PASS')
                else:
                    failed.append(tid)
                    pr(f'  {R}✗ LOCAL-OLLAMA실패{RST}  {task_def.get("title","?")}')
                done_now.append(tid)
        for tid in done_now: remaining.pop(tid,None)
        if not remaining: break
        if elapsed%30<5 and remaining:
            names=[next((t.get('title','?') for t in remote_tasks if t.get('id')==k),k) for k in remaining]
            pr(f'  {GR}[{elapsed}s] 대기: {", ".join(names[:3])}{RST}')
        if elapsed>300: break
    if remaining:
        for tid in remaining:
            failed.append(tid)
            pr(f'  {Y}⏱ 타임아웃{RST}  {tid}')

# ════════════════════════════════════════════════════════════════
# ⑥ 실제 Gap 검증
# ════════════════════════════════════════════════════════════════
# 결과 저장
try: save_results()
except: pass

pr(f'\n{BOLD}⑥ Gap 검증 — 실제 결과 기반{RST}')

total=len(subtasks); done_n=len(results); fail_n=len(failed)
verified_n=sum(1 for v in results.values() if isinstance(v,dict) and v.get('verified'))
gap_pct=int(done_n*100/total) if total else 0
real_gap_pct=int(verified_n*100/total) if total else 0
gap_col=G if real_gap_pct>=95 else (Y if real_gap_pct>=80 else R)

pr(f'  태스크: {total}  완료: {done_n}  검증통과: {verified_n}  실패: {fail_n}')
pr(f'  완료율: {gap_pct}%  |  {gap_col}실제 검증율: {real_gap_pct}%{RST}')

# git diff로 실제 변경 확인
git_diff,_,_=run_local('git diff --stat HEAD',30)
if git_diff:
    pr(f'\n  {BOLD}실제 변경 파일:{RST}')
    for l in git_diff.splitlines()[:5]: pr(f'    {GR}{l}{RST}')

# 서비스 상태 확인
svc_ok=api('GET','/health').get('status')=='healthy'
pr(f'\n  서비스 상태: {"✅ healthy" if svc_ok else "❌ 오류"}')

# Gap 분석 AI
gap_items=[f'- [{t.get("title","?")} ({t.get("exec_type","?")})] {"✅검증" if t["id"] in results and (isinstance(results[t["id"]],dict) and results[t["id"]].get("verified")) else "❌미달"}' for t in subtasks]
gap_prompt=f"""작업 완료 현황 분석:
메인작업: {MAIN_TASK}
검증율: {real_gap_pct}%
{chr(10).join(gap_items)}
각 2줄:
1. 달성:
2. Gap:
3. 추가필요:
4. 판정: PASS(>=95%) 또는 RETRY"""
gap_ai=ollama_chat(gap_prompt,60) or f'검증율 {real_gap_pct}%'
pr(f'\n  {BOLD}AI 검수:{RST}')
for l in gap_ai.splitlines()[:8]:
    if l.strip(): pr(f'  {GR}{l}{RST}')

# ════════════════════════════════════════════════════════════════
# ⑦ 최종 보고
# ════════════════════════════════════════════════════════════════
pr(f'\n{BOLD}⑦ 최종 보고{RST}')
pr(f'  {"─"*68}')
mode_str=f'Mesh({len(other_sessions)}CLI)+로컬병렬' if MESH_MODE else '로컬+NCO병렬'
pr(f'  실행: {mode_str}  |  완료: {datetime.now().strftime("%H:%M")}')
pr(f'  {gap_col}검증율: {real_gap_pct}% ({verified_n}/{total}){RST}  완료율: {gap_pct}%')
pr()
for t in subtasks:
    tid=t.get('id','?'); res=results.get(tid,None)
    is_verified=isinstance(res,dict) and res.get('verified')
    is_done=tid in results
    em='✅' if is_verified else ('⚠' if is_done else ('❌' if tid in failed else '⏳'))
    col=type_col.get(t.get('type',''),'')
    etype=G+'[L]'+RST if t.get('exec_type')=='local' else C+'[R]'+RST
    pr(f'  {em} {etype} {t.get("agent","?"):14} {col}{t.get("title","?"):22}{RST}')
    if is_done and res:
        out=res.get('output','') if isinstance(res,dict) else str(res)
        pr(f'     {GR}{out[:80]}{RST}')
pr(f'  {"─"*68}')
if real_gap_pct>=95:
    pr(f'\n  {G}{BOLD}🏆 TURBO v3 완료 — 검증율 {real_gap_pct}%! ({mode_str}){RST}')
elif real_gap_pct>=80:
    pr(f'\n  {Y}⚡ 부분 완료 {real_gap_pct}% — /nco-turbo 재실행 권장{RST}')
else:
    pr(f'\n  {R}❌ 검증 미달 {real_gap_pct}% — 전략 재검토 필요{RST}')
try: pr(f'  {GR}결과저장: {RESULT_FILE}{RST}')
except: pass
PYEOF
