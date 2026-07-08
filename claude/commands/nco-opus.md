# Opus Commander — 전략적 지휘관 모드: 분석→설계→Plan→Mesh배분→감독→Gap검증→100%루프
# 사용자 요청을 받아 전체 에이전트+CLI세션을 지휘하여 완전 해결한다.
# $ARGUMENTS를 작업 요청으로 사용합니다.
# 형식: /nco-opus <작업 요청>
# 예: /nco-opus 인증 모듈 전체 리팩토링 + 테스트 추가
# 예: /nco-opus 실시간 알림 시스템 신규 구현

# Opus는 코드를 직접 작성하지 않는다. 모든 구현은 에이전트+Mesh 세션을 통해 실행한다.
# 상세 규격: docs/opus-commander-spec.md

# ---

## 세션 초기화

```bash
bash ~/projects/nco-session-log.sh "nco-opus" "0" "세션시작" "start" "$ARGUMENTS"
echo "═══════════════════════════════════════════"
echo "  OPUS COMMANDER — Strategic Orchestrator"
echo "═══════════════════════════════════════════"
echo "[진행 모니터] 새 터미널에서: python3 ~/projects/nco-progress.py"
```

---

## PHASE 1: 상황 분석 (ANALYZE)

```bash
bash ~/projects/nco-session-log.sh "nco-opus" "P1" "상황분석" "start" "$ARGUMENTS"

# NCO 서버 상태
echo "── NCO 상태 ──"
curl -s http://localhost:6200/health | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    print(f'NCO: {d.get(\"status\",\"?\")} | 에이전트: {d.get(\"runtime\",{}).get(\"agentsOnline\",0)}개')
except: print('NCO: offline')
"

# Mesh 세션 현황
echo ""
echo "── Mesh 세션 ──"
curl -s http://localhost:6200/api/mesh/sessions | python3 -c "
import sys,json
try:
    sessions=json.load(sys.stdin)
    if isinstance(sessions, list):
        active=[s for s in sessions if s.get('status') not in ('done','offline')]
        print(f'활성 세션: {len(active)}개')
        for s in active:
            name=s.get('agentId','?')
            mode=s.get('workMode','?')
            task=s.get('currentTask','(대기)')[:50]
            print(f'  {name:16} [{mode:8}] {task}')
    else:
        print('세션 없음')
except: print('Mesh 조회 불가')
"

# 가용 에이전트
echo ""
echo "── 가용 에이전트 ──"
curl -s http://localhost:6200/api/ai-providers | python3 -c "
import sys,json
try:
    providers=json.load(sys.stdin)
    enabled=[p for p in providers if p.get('enabled')]
    for p in enabled:
        name=p.get('id','?')
        role=p.get('role','?')
        score=p.get('score',0)
        print(f'  {name:16} [{role:10}] score:{score}')
    print(f'총 {len(enabled)}개 활성')
except: print('프로바이더 조회 불가')
"

bash ~/projects/nco-session-log.sh "nco-opus" "P1" "상황분석" "done" "상황 분석 완료"
```

$ARGUMENTS를 분석하여 다음을 판단한다:

| 항목 | 판단 기준 |
|------|----------|
| **복잡도** (1-10) | 단어 수, 기술 키워드, 파일 범위, 요구사항 수 |
| **영향 범위** | 관련 파일 수, 모듈 수, 의존성 깊이 |
| **위험도** | 보안/성능/호환성 영향 여부 |
| **실행 모드** | 단순(task) / 병렬(parallel) / 계층(commander) / 전체(hive) |

출력:
```
[OPUS 분석]
요청: <$ARGUMENTS>
복잡도: X/10
영향 범위: 파일 N개, 모듈 N개
위험도: 낮음/중간/높음
실행 모드: <선택된 모드>
가용 자원: 세션 N개, 에이전트 N개
```

---

## PHASE 2: 설계 + 에이전트 매핑 (DESIGN)

```bash
bash ~/projects/nco-session-log.sh "nco-opus" "P2" "설계" "start" "작업 분해 + 에이전트 매핑"
```

작업을 독립 단위로 분해한다 (각 단위 = 파일 1-2개):

**에이전트 매핑 규칙**:
```
설계/구조 분석     → opencode (score:90)
UI/스키마 설계     → agy (score:85)
빠른 구현          → codex (score:83)
다중 파일 수정     → codex 또는 nco_parallel [codex, cursor-agent]
코드 리뷰          → cursor-agent (score:78)
리서치/문서        → copilot (score:75)
범용 추론          → openrouter (score:75, 무료)
로컬 검증          → ollama (score:75, 무료)
복잡 추론          → nvidia (Nemotron-Super-49B, 무료)
```

**비용 최적화 원칙**: 무료 우선(ollama→openrouter→nvidia), 복잡한 것만 유료

**의존성 판별**:
- 독립 작업 → `par` (병렬 실행 가능)
- 선행 필요 → `seq` (순차, 앞 결과 필요)

출력:
```
[OPUS 설계]
├─ T1: <설명> → <에이전트> (seq:1)
├─ T2: <설명> → <에이전트> (par:2)
├─ T3: <설명> → <에이전트> (par:2)
├─ T4: <설명> → <에이전트> (seq:3, depends: T2,T3)
└─ T5: <검증> → vllm+cursor-agent (seq:4)

에러 대비:
  codex 실패 → cursor-agent 또는 openrouter 대체
  opencode 실패 → agy+copilot 대체
  cursor-agent 실패 → ollama+openrouter 대체
```

```bash
bash ~/projects/nco-session-log.sh "nco-opus" "P2" "설계" "done" "설계 완료: 태스크 N개 (병렬:N, 순차:N)"
```

---

## PHASE 3: Plan 생성 + Task 등록 (PLAN)

```bash
bash ~/projects/nco-session-log.sh "nco-opus" "P3" "Plan생성" "start" "Plan+칸반 태스크 생성"

# Plan 파일 생성
mkdir -p docs/plans
PLAN_FILE="docs/plans/$(date '+%Y%m%d-%H%M%S')-opus-plan.md"
```

설계 결과를 기반으로 Plan 마크다운을 생성한다:

```bash
cat > "$PLAN_FILE" << 'PLAN_EOF'
# Opus Plan: <작업명>
생성: <날짜> | Commander: Opus

## 태스크 목록
- [ ] T1: <설명> → <에이전트> (seq:1)
- [ ] T2: <설명> → <에이전트> (par:2)
- [ ] T3: <설명> → <에이전트> (par:2)
- [ ] T4: <설명> → <에이전트> (seq:3)
- [ ] T5: 검증 → vllm+cursor-agent (seq:4)

## 검증 기준
- [ ] tsc --noEmit 에러 0개
- [ ] 기존 테스트 통과
- [ ] Gap Rate ≥ 100%

## 에러 대체 맵
codex→cursor-agent | cursor-agent→codex | opencode→agy+copilot | agy→opencode | ollama→openrouter
PLAN_EOF
echo "Plan 생성: $PLAN_FILE"
```

```bash
bash ~/projects/nco-session-log.sh "nco-opus" "P3" "Plan생성" "done" "$PLAN_FILE"
```

---

## PHASE 4: 작업 배분 (DISPATCH)

```bash
bash ~/projects/nco-session-log.sh "nco-opus" "P4" "작업배분" "start" "Mesh세션+에이전트에 작업 배분"
```

### 배분 우선순위:
1. **Mesh 세션** — 열린 CLI에 직접 위임 (가장 빠름)
2. **NCO team** — 에이전트 병렬 배분
3. **NCO task** — 단일 에이전트 위임

### Mesh 세션 배분 (세션이 있을 때):
```bash
# 예: 특정 세션에 작업 위임
curl -s -X POST http://localhost:6200/api/mesh/send \
  -H "Content-Type: application/json" \
  -d "{\"from\":\"opus\",\"to\":\"@claude-2\",\"message\":\"[TASK] T1: <구체적 지시>\"}" | python3 -c "
import sys,json
try:
    r=json.load(sys.stdin)
    print(f'전송: {r.get(\"delivered\",0)}개 세션')
except: print('전송 실패')
"

# 예: 모든 세션에 병렬 작업 브로드캐스트
curl -s -X POST http://localhost:6200/api/mesh/send \
  -H "Content-Type: application/json" \
  -d "{\"from\":\"opus\",\"to\":\"*\",\"message\":\"[TASK] <공통 작업 지시>\"}" | python3 -c "
import sys,json
try:
    r=json.load(sys.stdin)
    print(f'브로드캐스트: {r.get(\"delivered\",0)}개 세션')
except: print('전송 실패')
"
```

### NCO 에이전트 배분 (병렬 작업):
```bash
# 병렬 실행
curl -s -X POST http://localhost:6200/api/realtime/parallel \
  -H "Content-Type: application/json" \
  -d "{
    \"prompt\": \"$ARGUMENTS\",
    \"providers\": [\"codex\", \"cursor-agent\"]
  }" | python3 -c "
import sys,json
try:
    r=json.load(sys.stdin)
    print(f'병렬 태스크: {len(r.get(\"results\",[]))}개 생성')
except: print('병렬 실행 요청 완료')
"
```

### NCO 단일 에이전트 배분 (순차 작업):
```bash
# 단일 태스크
curl -s -X POST http://localhost:6200/api/task \
  -H "Content-Type: application/json" \
  -d "{
    \"callerSessionId\": \"$NCO_SESSION_ID\", \"callerAgentId\": \"$NCO_NAME\",
    \"ai\": \"opencode\",
    \"prompt\": \"[컨텍스트] <상황> [목표] <결과> [제약] <금지사항> [검증] <성공기준>\",
    \"mode\": \"task\"
  }" | python3 -c "
import sys,json
try:
    r=json.load(sys.stdin)
    tid=r.get('taskId','?')
    print(f'태스크 생성: {tid}')
except: print('태스크 생성 완료')
"
```

```bash
bash ~/projects/nco-session-log.sh "nco-opus" "P4" "작업배분" "done" "배분 완료: Mesh N개 + 에이전트 N개"
```

---

## PHASE 5: 감독 + 에러 대응 (MONITOR)

```bash
bash ~/projects/nco-session-log.sh "nco-opus" "P5" "감독" "start" "실시간 모니터링 시작"
```

### 상태 확인:
```bash
# 태스크 상태
echo "── 태스크 상태 ──"
curl -s http://localhost:6200/api/tasks?limit=10 | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    for t in d.get('tasks',[])[:10]:
        status=t.get('status','?')
        agent=t.get('assigned_to','?')
        prompt=t.get('prompt','')[:50]
        icon='✔' if status=='completed' else '✘' if status=='failed' else '…'
        print(f'  {icon} {agent:14} [{status:10}] {prompt}')
except: print('태스크 조회 불가')
"

# Mesh 메시지 확인
echo ""
echo "── Mesh 응답 ──"
curl -s "http://localhost:6200/api/mesh/messages?to=opus&limit=5" | python3 -c "
import sys,json
try:
    msgs=json.load(sys.stdin)
    if isinstance(msgs, list):
        for m in msgs[:5]:
            frm=m.get('from','?')
            msg=m.get('message','')[:60]
            print(f'  ← {frm}: {msg}')
    else: print('  메시지 없음')
except: print('  메시지 조회 불가')
"
```

### 에러 감지 시 행동:

| 상황 | P등급 | 행동 |
|------|-------|------|
| 에이전트 에러 | P1 | 이슈로그 저장 → /nco-mesh로 즉시 수정 요청 |
| 에이전트 멈춤 (60초+) | P1 | 다른 에이전트에 재위임 + 동시에 이슈로그 |
| 파일 충돌 | P0 | 즉시 중단 → 충돌 해소 → 재개 |
| 품질 미달 결과 | P2 | 피드백 후 동일 에이전트 재시도 (3회 한도) |

### 이슈 로그 저장:
```bash
mkdir -p docs/plans
ISSUE_LOG="docs/plans/issue-log-$(date '+%Y%m%d-%H%M%S').md"
cat > "$ISSUE_LOG" << 'ISSUE_EOF'
# Opus Issue Log
## [timestamp] Agent: <agent> | Task: <task-id>
- Error: <에러 내용>
- Context: <발생 상황>
- Action: <취한 조치 — reassigned/retried/escalated>
- Status: <resolved/pending>
ISSUE_EOF
```

### 에러 시 재위임:
```bash
# 대체 에이전트에 재위임
curl -s -X POST http://localhost:6200/api/task \
  -H "Content-Type: application/json" \
  -d "{
    \"callerSessionId\": \"$NCO_SESSION_ID\", \"callerAgentId\": \"$NCO_NAME\",
    \"ai\": \"<대체에이전트>\",
    \"prompt\": \"[재위임] 이전 에이전트(<원래에이전트>)가 실패함. 에러: <에러내용>. 원래 작업: <작업지시>\",
    \"mode\": \"task\"
  }" | python3 -m json.tool

# 동시에 Mesh로 수정 요청
curl -s -X POST http://localhost:6200/api/mesh/send \
  -H "Content-Type: application/json" \
  -d "{\"from\":\"opus\",\"to\":\"*\",\"message\":\"[FIX] <에이전트>에서 에러 발생. 관련 파일 수정 필요: <파일목록>\"}"
```

**에이전트 대체 맵**:
```
codex 실패     → cursor-agent 또는 openrouter
opencode 실패  → agy + copilot 병렬
cursor-agent   → ollama + openrouter 병렬
ollama 실패    → openrouter
copilot 실패   → openrouter
agy 실패    → opencode
openrouter     → vllm (단순) 또는 codex (복잡)
```

```bash
bash ~/projects/nco-session-log.sh "nco-opus" "P5" "감독" "done" "감독 완료: 성공 N개, 실패 N개, 재위임 N개"
```

---

## PHASE 6: Gap 분석 + E2E 검증 (VERIFY)

```bash
bash ~/projects/nco-session-log.sh "nco-opus" "P6" "검증" "start" "Gap분석 + E2E 검증 시작"
```

### 6-1. 에이전트 병렬 검증:
```bash
# vllm: 로직 검증 + 엣지케이스
curl -s -X POST http://localhost:6200/api/task \
  -H "Content-Type: application/json" \
  -d "{
    \"callerSessionId\": \"$NCO_SESSION_ID\", \"callerAgentId\": \"$NCO_NAME\",
    \"ai\": \"vllm\",
    \"prompt\": \"변경된 코드의 로직을 검증하라. 엣지케이스(빈입력, 최대값, 동시성, 에러)를 확인하라. 요청: $ARGUMENTS\",
    \"mode\": \"task\"
  }" | python3 -c "import sys,json; print('vllm 검증 요청:', json.load(sys.stdin).get('taskId','?'))" 2>/dev/null

# cursor-agent: 코드 리뷰 (보안/성능/품질)
curl -s -X POST http://localhost:6200/api/task \
  -H "Content-Type: application/json" \
  -d "{
    \"callerSessionId\": \"$NCO_SESSION_ID\", \"callerAgentId\": \"$NCO_NAME\",
    \"ai\": \"cursor-agent\",
    \"prompt\": \"코드 리뷰: 보안 취약점, 성능 문제, 코드 품질을 검토하라. 요청: $ARGUMENTS\",
    \"mode\": \"task\"
  }" | python3 -c "import sys,json; print('cursor-agent 리뷰 요청:', json.load(sys.stdin).get('taskId','?'))" 2>/dev/null
```

### 6-2. E2E 자동 검증:
```bash
echo "── E2E 검증 ──"

# TypeScript 검사
TSC_ERRORS=$(npx tsc --noEmit 2>&1 | grep -c "error TS" 2>/dev/null || echo "0")
echo "tsc 에러: ${TSC_ERRORS}개"

# ESLint 검사 (변경 파일만)
CHANGED=$(git diff --name-only HEAD 2>/dev/null | grep -E '\.(ts|tsx|js|jsx)$' | head -20)
if [ -n "$CHANGED" ]; then
    LINT_ERRORS=$(echo "$CHANGED" | xargs npx eslint --no-error-on-unmatched-pattern 2>&1 | grep -cE "(error|warning)" 2>/dev/null || echo "0")
    echo "lint 에러: ${LINT_ERRORS}개"
else
    LINT_ERRORS=0
    echo "lint: 변경된 JS/TS 파일 없음"
fi

# 테스트 실행
npm test 2>/dev/null && echo "✔ 테스트 통과" || \
pytest 2>/dev/null && echo "✔ 테스트 통과" || \
echo "테스트 명령어 미감지 — 수동 확인 필요"
```

### 6-3. Gap Rate 산출:

Plan 파일에서 태스크 완료율을 계산한다:

```bash
if [ -n "$PLAN_FILE" ] && [ -f "$PLAN_FILE" ]; then
    TOTAL=$(grep -c '^\- \[' "$PLAN_FILE" 2>/dev/null || echo "0")
    DONE=$(grep -c '^\- \[x\]' "$PLAN_FILE" 2>/dev/null || echo "0")
    echo "태스크: ${DONE}/${TOTAL} 완료"
fi
```

**Gap Rate 계산**:
```
기능 완전성: XX/25  (요청한 모든 기능 구현됐는가?)
코드 품질:   XX/20  (tsc + lint 에러 0개?)
테스트:      XX/20  (기존+신규 테스트 통과?)
보안:        XX/15  (취약점 없는가?)
성능:        XX/10  (명백한 성능 문제 없는가?)
문서화:      XX/10  (사용법 이해 가능?)

Gap Rate = 총점 / 100 × 100 (목표: 100%)
```

```bash
bash ~/projects/nco-session-log.sh "nco-opus" "P6" "검증" "done" "Gap Rate: XX% (tsc:${TSC_ERRORS} lint:${LINT_ERRORS})"
```

출력:
```
[OPUS Gap 분석]
Gap Rate: XX%
기능 완전성: XX/25
코드 품질:   XX/20
테스트:      XX/20
보안:        XX/15
성능:        XX/10
문서화:      XX/10

tsc 에러: N개 | lint 에러: N개
태스크: N/M 완료
루프 횟수: N/5
```

---

## PHASE 7: 루프 판단 (LOOP / REPORT)

```bash
# 100% 미만 — 재설계 루프
bash ~/projects/nco-session-log.sh "nco-opus" "P7" "루프판단" "loop" "Gap XX% < 100% — PHASE 2로 재설계 (N/5회)"

# 100% 이상 — 완료 보고
bash ~/projects/nco-session-log.sh "nco-opus" "P7" "루프판단" "done" "Gap XX% ≥ 100% — 작업 완료"
```

### < 100%일 때 (LOOP):
1. Gap 분석 결과에서 미흡 항목 추출
2. 미흡 영역별 재시작 지점 결정:
   - 설계 미흡 → PHASE 2부터
   - 구현 미흡 → PHASE 4부터
   - 품질/보안 → PHASE 5부터
   - 테스트 실패 → PHASE 6부터
3. 새 Plan 생성 (수정/보강 초점)
4. 루프 카운터 증가 (최대 5회)
5. **5회 초과 시**: 현재 결과 + 남은 이슈 목록을 사용자에게 보고 → 사용자 판단 요청

### >= 100%일 때 (REPORT):

```bash
bash ~/projects/nco-session-log.sh "nco-opus" "DONE" "완료보고" "start" "최종 보고서 작성"

mkdir -p docs/opus-reports
REPORT_FILE="docs/opus-reports/$(date '+%Y%m%d-%H%M%S')-opus-report.md"

cat > "$REPORT_FILE" << 'REPORT_EOF'
# Opus Commander 완료 보고
날짜: <날짜>
Gap Rate: XX% | 루프: N회

## 요청
<$ARGUMENTS>

## 실행 요약
| 에이전트 | 역할 | 태스크 | 결과 |
|---------|------|--------|------|
| <agent> | <role> | <task> | 성공/실패 |

## 변경 파일
- <파일 목록>

## 검증 결과
- tsc: 에러 0개
- lint: 에러 0개
- 테스트: 통과

## 이슈 로그
- <있으면 참조, 없으면 "이슈 없음">

## 잔여 Gap
- <있으면 목록, 없으면 "없음 (100%)">
REPORT_EOF

echo "보고서: $REPORT_FILE"

bash ~/projects/nco-session-log.sh "nco-opus" "DONE" "완료보고" "done" "$REPORT_FILE"
```

진행 모니터 최종 확인:
```bash
python3 ~/projects/nco-progress.py --once
```
