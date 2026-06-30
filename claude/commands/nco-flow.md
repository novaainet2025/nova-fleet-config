# NCO Flow — 원샷 자동 풀파이프라인 (MVP Phase A)
# 사용자 한 줄 입력으로 인텐트 정제→맥락 수집→분류→위임→Gap→루프→보고서까지 자동.
# 형식: /nco-flow <요청>
# 옵션: --bypass (워크플로우 게이트 우회) | --auto-approve (동의 게이트 자동) | --loop=N (루프 cap)
# 예: /nco-flow 인증 모듈에 JWT 검증 추가하고 테스트도 만들어줘
#
# Phase A (MVP): STAGE 0·1·2·6-simplified·9·10·11
# Phase B (2026-05-25 추가): STAGE 3 토론 + 4 합의 + 8 교차검증 3-way + 6.5 Mesh 브로드캐스트
# Phase C (예정): STAGE 5 테스트/검증 문서 자동 + hwpforge 변환
#
# 모든 위임은 MCP 도구(Skill 또는 mcp__nco-commands__*)로 호출하여
# /tmp/nco-stages-${SID}.json 자동 마킹 → Phase 1 워크플로우 게이트와 통합.

---

## STAGE 0 — 인텐트 정제 (Intent Refinement)

$ARGUMENTS 를 분석하여 다음을 판단한다:

1. **모호도 점수** (0.0-1.0): 동사 명확성, 범위 명시, 대상 파일/모듈 언급 여부
   - 모호 시그널: "최적화"·"개선"·"좋게"·"잘"·"전반적"·"여러가지"·동사 없음
   - 명확 시그널: 구체적 파일/함수명, 측정 가능한 목표, 명확한 동사("추가"·"수정"·"삭제")
2. **모호도 ≥ 0.5 AND `--auto-approve` 미설정**이면 `AskUserQuestion` 1회만 호출:
   - 질문: "이 요청을 어떤 방향으로 진행할까요?"
   - 옵션 3개: 추정 1순위 / 추정 2순위 / 다른 방향 (사용자가 Other로 자유 입력)
3. **모호도 < 0.5 OR `--auto-approve`**: 그대로 진행, 정제된 의도를 `/tmp/nco-flow-intent-${NCO_SESSION_ID:-$$}.json` 에 저장

```bash
INTENT_FILE="/tmp/nco-flow-intent-${NCO_SESSION_ID:-$$}.json"
echo "[STAGE 0] 인텐트 정제 — $ARGUMENTS"
```

출력:
```
[STAGE 0] 정제된 의도: <한 줄 요약>
모호도: 0.XX | AskUser: yes/no
```

---

## STAGE 1 — 맥락 자동 수집 (Context Auto-Load)

병렬로 6개 정보 수집 (단일 Bash 메시지에 묶기 — 의존성 없음):

```bash
echo "── NCO 헬스 ──"
curl -s -m 2 http://localhost:6200/health | python3 -c "import sys,json; d=json.load(sys.stdin); print(f'NCO: {d.get(\"status\")} | 에이전트: {d.get(\"runtime\",{}).get(\"agentsOnline\",0)}개')" 2>/dev/null

echo ""
echo "── 활성 Mesh 세션 ──"
curl -s -m 2 http://localhost:6200/api/mesh/sessions | python3 -c "import sys,json; s=json.load(sys.stdin); s=s if isinstance(s,list) else s.get('sessions',[]); active=[x for x in s if x.get('status') not in ('done','offline')]; print(f'활성: {len(active)}개'); [print(f'  {x.get(\"agentId\",\"?\"):16} [{x.get(\"workMode\",\"?\"):8}]') for x in active[:5]]" 2>/dev/null

echo ""
echo "── Git 상태 ──"
git status --short 2>/dev/null | head -10
echo "최근 커밋:"
git log --oneline -5 2>/dev/null

echo ""
echo "── 맥락 노트 (최신 1세션) ──"
python3 -c "
import re
try:
    text = open('/home/nova/projects/context_note.md').read()
    blocks = re.findall(r'<!-- SESSION_START -->(.*?)<!-- SESSION_END -->', text, re.DOTALL)
    print(blocks[0].strip()[:400] if blocks else text[:400])
except: pass" 2>/dev/null

echo ""
echo "── 이전 세션 개선 권고 ──"
ls -t /home/nova/.claude/improvements/*.md 2>/dev/null | head -1 | xargs -I{} grep -oP '\[High\][^\n]+' {} 2>/dev/null | head -3
```

---

## STAGE 2 — 분류 & 라우팅 (Classify + Route)

$ARGUMENTS 와 STAGE 1 결과를 종합해 다음을 결정:

| 판단 | 후보 | 결정 기준 |
|---|---|---|
| `task_type` | bug / new_feature / config / research | 동사·키워드·범위 |
| `complexity` | 1-10 | 파일 수, 의존성, 새 기술 도입 |
| `mode` | task / parallel / commander | complexity 1-3=task, 4-6=parallel, 7+=commander |
| `primary_agent` | codex / opencode / cursor-agent / agy / nvidia | task_type별 매핑 |

**에이전트 매핑** (Phase A는 단일, Phase B에서 3-way 확장):
- bug → `codex`
- new_feature → complexity≥6면 `opencode` (설계 먼저), 아니면 `codex`
- config → `codex`
- research → `copilot` 또는 `nvidia`

출력:
```
[STAGE 2] task_type=<X> complexity=<N>/10 mode=<M> agent=<A>
```

---

## STAGE 3 — 자동 토론 (Auto Discussion, Phase B)

**트리거 조건** (둘 중 하나):
- `complexity ≥ 6`
- `task_type == "new_feature"` AND 모호도 ≥ 0.4
- `task_type == "unknown"` (분류 자체가 애매)

해당 시 자동 호출:
```
mcp__nco-commands__nco-discussion(arguments="opencode,agy,codex: <정제된 의도>. 5턴 cap.")
```

→ `discussion` stage 자동 마킹. 결과(JSON 또는 텍스트)를 STAGE 4로 전달.

스킵 조건: `complexity ≤ 5` AND `task_type ∈ {bug, config, simple, research}`.

## STAGE 4 — 합의 (Consensus, Phase B)

STAGE 3 토론 결과가 있을 때만 발화. 3 이상의 안이 나오면:
```
mcp__nco-commands__nco-consensus(arguments="STAGE 3 토론에서 도출된 안 중 최적 1개를 투표로 선정. 후보: <안1>, <안2>, <안3>")
```

투표 결과 → `design` stage 자동 마킹.

**사용자 동의 게이트 #1** (`--auto-approve` 없을 때):
- `AskUserQuestion`: "합의된 설계로 진행할까요?"
- 옵션: (1) 진행 (2) 수정 후 진행 (3) 중단

## STAGE 6 — 위임 (Delegation)

분류 결과대로 **MCP 도구로 호출** (curl 금지 — stages.json 마킹 위해 필수):

```
# complexity ≤ 6 (단일 위임):
Skill(nco-task) <primary_agent> '<정제된 의도 또는 합의된 설계>'

# complexity 7-8 (병렬 위임):
mcp__nco-commands__nco-team(arguments="codex,cursor-agent: <설계>")
또는
mcp__nco-commands__nco-conductor(arguments="<설계>")

# complexity ≥ 9 (대형 — Commander 모드):
mcp__nco-commands__nco-commander(arguments="<설계>")
```

위임 후 응답을 받아 다음 stage로 전달. 응답이 30초 내 없으면 대체 에이전트 자동 전환 (opus 에러 대체 맵 차용):
- codex 실패 → cursor-agent
- opencode 실패 → agy
- cursor-agent 실패 → ollama 또는 openrouter

## STAGE 6.5 — Mesh Peer 브로드캐스트 (Phase B, 옵트인)

**트리거 조건**:
- `complexity ≥ 8` AND 활성 peer 세션 ≥ 2개
- 또는 `--broadcast` 옵션 명시

활성 mesh 세션에 sub-task을 분산 (autoresponder가 Ollama로 즉시 응답):
```bash
# 정확한 schema: {fromSessionId, fromAgent, toAgent, content, type}
# 진단 결과 2026-05-25: 4 세션 모두 mesh-auto-responder.js 활성, Ollama qwen2.5:3b 폴백 동작
curl -s -X POST http://localhost:6200/api/mesh/send \
  -H "Content-Type: application/json" \
  -d '{"fromSessionId":"'${NCO_SESSION_ID:-$$}'","fromAgent":"'${NCO_NAME:-claude-cli}'","toAgent":"*","content":"[TASK] <sub-task 1줄>","type":"task"}'
```

응답 회수: 5초 대기 후 `/api/mesh/messages?to=<나>&limit=10`. 응답 합산해 STAGE 8 교차검증 입력으로 사용.

스킵 (Phase A 호환): 옵션·트리거 미충족이면 그대로 STAGE 7로.

---

## STAGE 8 — 교차검증 3-way (Cross-Verify, Phase B)

구현 직후 3개 관점으로 동시 검증 (병렬):

```
# 구현 정확성 — codex 자체 self-check 또는 다른 agent에 정확성 확인
mcp__nco-commands__nco-task(arguments="codex '자체 정확성 검토 (변경 사항 vs 의도): <변경 요약>'")

# 보안·품질 — cursor-agent (online인 경우)
mcp__nco-commands__nco-task(arguments="cursor-agent '리뷰: 보안 취약점·코드 품질 점검. <변경 요약>'")

# 동작·테스트 — ollama 우선, 오프라인이면 agy fallback
mcp__nco-commands__nco-task(arguments="ollama '검증: 동작·테스트 통과 여부. <변경 요약>'")
```

→ `review` + `verification` stages 자동 마킹.

**3개 결과 비교 로직**:
- 3개 모두 PASS → 통과, STAGE 9로
- 1-2개 FAIL → 합의 시도: `mcp__nco-commands__nco-consensus(arguments="3가지 검증 결과 통합. 최종 판정.")` → 결과로 STAGE 10 루프 분기 결정
- 3개 모두 FAIL → STAGE 10 즉시 루프 (큰 문제)

**에이전트 오프라인 폴백 매트릭스**:
| 원래 | 1차 폴백 | 2차 폴백 |
|---|---|---|
| ollama | agy | openrouter |
| cursor-agent | agy | opencode |
| codex | opencode | agy |

## STAGE 9 — Gap 분석 (100점 기준)

```bash
echo "── 자동 검증 ──"
TSC_ERRORS=$(npx tsc --noEmit 2>&1 | grep -c "error TS" || echo 0)
echo "tsc 에러: ${TSC_ERRORS}개"

CHANGED=$(git diff --name-only 2>/dev/null | grep -E '\.(ts|tsx|js|jsx)$' | head -20)
LINT_ERRORS=0
if [ -n "$CHANGED" ]; then
  LINT_ERRORS=$(echo "$CHANGED" | xargs npx eslint --no-error-on-unmatched-pattern 2>&1 | grep -cE "(error|warning)" || echo 0)
fi
echo "lint 에러: ${LINT_ERRORS}개"

# 테스트 (있을 때만)
TEST_OK=0
npm test 2>/dev/null >/dev/null && TEST_OK=1
pytest 2>/dev/null >/dev/null && TEST_OK=1
echo "테스트: $([ $TEST_OK = 1 ] && echo '통과' || echo 'N/A 또는 실패')"
```

**점수 계산** (총 100점):
- 기능 완전성 25 — 요청한 모든 기능 구현?
- 코드 품질 20 — tsc/lint 에러 0?
- 테스트 20 — 통과? (없으면 partial 10점)
- 보안 15 — 명백한 취약점 0?
- 성능 10 — 명백한 문제 0?
- 문서화 10 — 변경 사항이 자명?

Gap 추가 검증은 `mcp__nco-commands__nco-analyze` 호출로 stage 마킹과 동시에 수행:
```
mcp__nco-commands__nco-analyze(arguments="Gap 분석 (간결, 100% 루프 비활성): <변경 요약>. tsc=N lint=N. 100점 기준 점수와 미흡 항목만 보고.")
```

출력:
```
[STAGE 9] Gap = XX/100
미흡: <항목 리스트>
```

---

## STAGE 10 — 루프 또는 종료

```
LOOP_FILE="/tmp/nco-flow-loop-${NCO_SESSION_ID:-$$}"
LOOP_CAP=${NCO_FLOW_LOOP_CAP:-5}   # --loop=N 옵션 처리
CUR=$(cat $LOOP_FILE 2>/dev/null || echo 0)
NEW=$((CUR + 1))
echo $NEW > $LOOP_FILE
```

- **Gap ≥ 100%** → STAGE 11 (완료 보고)
- **Gap < 100% AND NEW < LOOP_CAP** → 미흡 영역별 재실행:
  - 기능 미흡 → STAGE 6 재실행 (다른 프롬프트로)
  - 품질/보안 → cursor-agent 리뷰 1회 추가
  - 테스트 실패 → ollama 검증 1회 추가
- **NEW == LOOP_CAP** (cap 도달) → 사용자 동의 게이트 #2 (`--auto-approve` 없을 때만):
  - `AskUserQuestion`: "Gap XX% — (1) 잔여 이슈 받고 종료 (2) 루프 5회 추가 (3) 수동 전환"

---

## STAGE 11 — 완료 보고서 자동 생성

```bash
mkdir -p docs/reports
REPORT="docs/reports/$(date '+%Y%m%d-%H%M%S')-nco-flow.md"
LOOP=$(cat $LOOP_FILE 2>/dev/null || echo 0)

cat > "$REPORT" << REPORT_EOF
# /nco-flow 완료 보고
날짜: $(date '+%Y-%m-%d %H:%M:%S')
요청: $ARGUMENTS

## 분류
- task_type: <STAGE 2 결과>
- complexity: <N>/10
- mode: <M>
- primary_agent: <A>

## 실행 요약
- 위임 호출: N회
- 루프: ${LOOP}/${LOOP_CAP}
- Gap: XX/100

## 변경 파일
$(git diff --name-only 2>/dev/null | head -20 | sed 's/^/- /')

## 검증 결과
- tsc 에러: ${TSC_ERRORS:-?}개
- lint 에러: ${LINT_ERRORS:-?}개
- 테스트: $([ ${TEST_OK:-0} = 1 ] && echo '통과' || echo 'N/A')

## 미흡 항목 (있으면)
<STAGE 9 미흡 리스트>

## Phase B/C 대상 (이번에 스킵된 단계)
- STAGE 3 토론 (complexity ≥ 6일 때)
- STAGE 4 합의 (consensus)
- STAGE 8 교차검증 3-way
- STAGE 5 테스트/검증 문서 분리 산출
REPORT_EOF

echo "[STAGE 11] 보고서 저장: $REPORT"
```

옵션 처리:
- `--hwpx`: hwpforge_convert로 .hwpx 변환 (Phase C 정식 통합, MVP는 패스)
- 정리: `rm -f /tmp/nco-flow-intent-${SID}.json /tmp/nco-flow-loop-${SID}`

---

## 최종 출력 양식

```
═══════════════════════════════════════════════
[/nco-flow 완료] Gap XX% | 루프 N/5 | 위임 N회
═══════════════════════════════════════════════
정제된 의도: <요약>
변경 파일: <N개>
보고서: docs/reports/<ts>-nco-flow.md
미흡: <있으면 표시, 없으면 "없음">
═══════════════════════════════════════════════
```

## 워크플로우 게이트 통합 (Phase 1과 자동 연계)

이 명령은 모든 위임을 MCP 도구로 수행하므로:
- `implementation` ← Skill(nco-task) codex 호출 시
- `review` ← cursor-agent 호출 시 (STAGE 10 미흡 시)
- `gap_analysis` ← mcp__nco-commands__nco-analyze 호출 시 (STAGE 9)
- `verification` ← ollama 호출 시 (STAGE 10 테스트 실패 보강 시)

→ Stop 시점에 `nco-stop-quality-gate.sh` GATE 0가 통과해야 정상 완료.
미통과 시 5회 cycle exit 2 (다른 의도였다면 `NCO_WORKFLOW_BYPASS=1 /nco-flow ...` 우회).

## 알려진 제한 (Phase B 적용 후)

1. ✅ ~~단일 에이전트 위임만~~ → 3-way 교차검증 추가됨 (STAGE 8)
2. ✅ ~~토론·합의 자동화 없음~~ → STAGE 3·4 추가됨
3. ⏳ 테스트/검증 문서 별도 산출 없음 — 보고서 1개에 통합 (Phase C)
4. ✅ ~~Mesh peer 세션 미활용~~ → STAGE 6.5 옵트인 (complexity≥8 OR --broadcast)
5. ⏳ --hwpx 옵션 미구현 (Phase C, hwpforge_convert 통합 예정)
6. ⏳ inter-session SDK 직접 호출 미통합 (Phase C, Skill(inter-session) 통합 예정)

## Mesh API 스키마 메모 (2026-05-25 진단 확정)

올바른 send 형식 — 이전 `{from, to, message}` 패턴은 **모두 깨져있음**:
```json
POST /api/mesh/send
{"fromSessionId":"<SID>", "fromAgent":"<NAME>", "toAgent":"<NAME|*>", "content":"<MSG>", "type":"info|task"}
```

응답: `{"delivered": N}` (수신 세션 수)

수신: `GET /api/mesh/messages?to=<NAME|SID>&limit=N`

autoresponder 동작 확인:
- mesh-auto-responder.js (node) 세션마다 1개씩 실행 중
- WebSocket으로 mesh:message 이벤트 수신 → Anthropic 프록시(:4100) 시도 → 실패 시 Ollama 직접(:11434) fallback → 자동 회신
- 모델: qwen2.5:3b (autoresponder 기본)
