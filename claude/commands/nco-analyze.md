# 심층 분석 명령어: 최적 AI 자동 선정 → 병렬 분석 → 토론 → 수정 → 검증 → Gap 분석(100% 루프)
# $ARGUMENTS를 분석 주제로 사용합니다.
# 형식: /nco-analyze <분석 주제 또는 질문>
# 예: /nco-analyze 현재 아키텍처의 성능 병목 원인

# ---

## 시작 전: 세션 초기화

# 먼저 아래 명령어를 실행하여 진행 상황 모니터를 시작한다:

# ```bash
# 현재 터미널 옆에 새 터미널을 열고 아래 명령을 실행하면 실시간 진행이 보인다
# python3 ~/projects/nco-progress.py

# 세션 로그 초기화
bash ~/projects/nco-session-log.sh "nco-analyze" "0" "세션시작" "start" "$ARGUMENTS"
```

---

## STEP 0: 사전 확인 및 모니터 시작

NCO 서버 상태를 확인하고 세션을 등록한다:

```bash
bash ~/projects/nco-session-log.sh "nco-analyze" "0" "사전확인" "start" "NCO 서버 확인 중"
curl -s http://localhost:6200/health | python3 -c "import sys,json; d=json.load(sys.stdin); print('NCO', d.get('status','?'), '| 에이전트:', d.get('runtime',{}).get('agentsOnline',0), '개')"
bash ~/projects/nco-session-log.sh "nco-analyze" "0" "사전확인" "done" "서버 확인 완료"
```

온라인이면 NCO API를 사용하고, 오프라인이면 직접 분석 모드로 전환하되 사용자에게 알린다.

---

## STEP 1: 분석 유형 자동 판별 및 최적 AI 선정

```bash
bash ~/projects/nco-session-log.sh "nco-analyze" "1" "유형판별" "start" "$ARGUMENTS"
```

$ARGUMENTS 내용을 분석하여 유형을 판별하고 최적 프로바이더를 선정한다:

| 유형 키워드 | 1순위 | 2순위 | 3순위 |
|------------|-------|-------|-------|
| 코드·아키텍처·리팩토링 | opencode | cursor-agent | codex |
| 보안·취약점·인증 | cursor-agent | vllm | openrouter |
| 성능·병목·최적화 | openrouter | vllm | opencode |
| UI/UX·인터페이스·설계 | agy | opencode | cursor-agent |
| 라이브러리·패턴·리서치 | copilot | openrouter | opencode |
| 데이터·통계·분석 | openrouter | agy | vllm |
| 범용·복잡·다학제 | opencode | agy | cursor-agent |

선정 결과를 출력하고 세션에 기록한다:
```bash
bash ~/projects/nco-session-log.sh "nco-analyze" "1" "유형판별" "done" "선정AI: <선정된 AI 목록>"
```

출력 형식:
```
[분석 시작]
주제: <$ARGUMENTS>
판별 유형: <유형>
선정 AI: <AI 목록>
예상 단계: 분석 → 토론 → 수정 → 검증 → Gap분석
```

---

## STEP 2: 병렬 심층 분석

```bash
bash ~/projects/nco-session-log.sh "nco-analyze" "2" "병렬분석" "start" "선정 AI에게 동시 분석 요청"

curl -s -X POST http://localhost:6200/api/realtime/parallel \
  -H "Content-Type: application/json" \
  -d "{
    \"prompt\": \"다음 주제를 심층 분석하라. 근본 원인, 메커니즘, 영향 범위, 개선 방향을 포함할 것: $ARGUMENTS\",
    \"providers\": [\"<선정AI1>\", \"<선정AI2>\", \"<선정AI3>\"]
  }" | python3 -m json.tool

bash ~/projects/nco-session-log.sh "nco-analyze" "2" "병렬분석" "done" "병렬 분석 요청 완료, 결과 수신 대기"
```

진행 상황 확인:
```bash
# 태스크 상태 확인 (선택적)
curl -s http://localhost:6200/api/tasks?limit=5 | python3 -c "
import sys,json; d=json.load(sys.stdin)
for t in d.get('tasks',[])[:3]:
    print(f'  {t[\"assigned_to\"]:14} [{t[\"status\"]:8}] {t[\"prompt\"][:60]}')
"
```

NCO 오프라인 시: WebSearch 도구로 직접 다각도 분석을 수행한다.

---

## STEP 3: 멀티 AI 비판적 토론

```bash
bash ~/projects/nco-session-log.sh "nco-analyze" "3" "멀티토론" "start" "비판적 토론 세션 시작"

curl -s -X POST http://localhost:6200/api/realtime/discussion \
  -H "Content-Type: application/json" \
  -d "{
    \"prompt\": \"위 분석 결과를 비판적으로 검토하라. 논리적 허점, 누락된 관점, 상충되는 견해를 제시하고 최선의 결론을 도출하라. 주제: $ARGUMENTS\",
    \"mode\": \"discussion\"
  }" | python3 -m json.tool

bash ~/projects/nco-session-log.sh "nco-analyze" "3" "멀티토론" "done" "토론 세션 시작됨"
```

---

## STEP 4: 분석 수정 및 개선

```bash
bash ~/projects/nco-session-log.sh "nco-analyze" "4" "분석수정" "start" "opencode에게 토론 반영 수정 요청"

curl -s -X POST http://localhost:6200/api/task \
  -H "Content-Type: application/json" \
  -d "{
    \"ai\": \"opencode\",
    \"prompt\": \"토론에서 도출된 개선점을 반영하여 분석을 수정하라. 누락된 관점을 보완하고 모순을 해소하라. 원주제: $ARGUMENTS\",
    \"mode\": \"task\"
  }" | python3 -m json.tool

bash ~/projects/nco-session-log.sh "nco-analyze" "4" "분석수정" "done" "수정 태스크 큐 등록 완료"
```

---

## STEP 5: 독립 검증

```bash
bash ~/projects/nco-session-log.sh "nco-analyze" "5" "독립검증" "start" "vllm에게 독립 검증 요청"

curl -s -X POST http://localhost:6200/api/task \
  -H "Content-Type: application/json" \
  -d "{
    \"ai\": \"vllm\",
    \"prompt\": \"다음 분석 결과를 독립적으로 검증하라. 사실 오류, 논리적 모순, 중요한 누락을 찾아라. 주제: $ARGUMENTS\",
    \"mode\": \"task\"
  }" | python3 -m json.tool

bash ~/projects/nco-session-log.sh "nco-analyze" "5" "독립검증" "done" "검증 태스크 큐 등록 완료"
```

---

## STEP 6: Gap 분석 (100% 임계값)

```bash
bash ~/projects/nco-session-log.sh "nco-analyze" "6" "Gap분석" "gap" "점수 산출 중..."
```

다음 4개 기준으로 점수를 산출한다:

- **완전성** (30점): 주제의 핵심 측면이 빠짐없이 다뤄졌는가?
- **정확성** (25점): 사실 오류, 논리적 모순이 없는가?
- **깊이** (25점): 표면 설명이 아닌 근본 원인/메커니즘을 다뤘는가?
- **실행가능성** (20점): 구체적 다음 행동이 제시됐는가?

Gap Rate = (총점 / 100) × 100

```bash
# Gap Rate 계산 후 세션에 기록
bash ~/projects/nco-session-log.sh "nco-analyze" "6" "Gap분석" "done" "Gap Rate: XX% (완전성:XX 정확성:XX 깊이:XX 실행가능:XX)"
```

출력 형식:
```
[Gap 분석]
Gap Rate: XX%  ← 100% 미만이면 루프 재실행
완전성:      XX/30
정확성:      XX/25
깊이:        XX/25
실행가능성:  XX/20

미흡 영역: <목록>
루프 횟수: N/3
```

---

## STEP 7: 루프 판단

```bash
# 100% 미만이면 루프
bash ~/projects/nco-session-log.sh "nco-analyze" "7" "루프판단" "loop" "Gap XX% — STEP 2로 재실행 (N/3회)"
# 100% 이상이면 완료
bash ~/projects/nco-session-log.sh "nco-analyze" "7" "루프판단" "done" "Gap XX% — 100% 달성, 최종 보고서 출력"
```

- **Gap Rate ≥ 100%** → STEP 8 최종 보고서 출력
- **Gap Rate < 100%, 루프 횟수 < 3** → STEP 2로 돌아가되, 미흡 영역을 명시한 보강 지시와 함께 재실행
- **3회 루프 후에도 미달** → 현재 최고 결과를 출력하고 미흡 사항과 추가 조치를 명시

---

## STEP 8: 최종 보고서

```bash
bash ~/projects/nco-session-log.sh "nco-analyze" "8" "최종보고" "done" "분석 완료"
```

보고서를 docs/analysis/ 에 마크다운으로 저장한다:

```bash
mkdir -p docs/analysis
FILENAME="docs/analysis/$(date '+%Y%m%d-%H%M%S')-analysis.md"
# 아래 내용을 파일로 저장
cat > "$FILENAME" << 'REPORT'
# 분석 보고서: <주제>
날짜: <현재 날짜>
Gap Rate: XX% | 루프: N회 | 사용 AI: <목록>

## 핵심 요약 (TL;DR)
<3줄 이내>

## 주요 발견사항
- <bullet>

## 상세 분석
<내용>

## 토론 인사이트
<토론에서 도출된 핵심 합의/이견>

## 권장 행동
1. <즉시 실행 가능한 항목>
2. <중기 개선 항목>
3. <장기 전략 항목>

## 근거 및 출처
<참조 목록>
REPORT
echo "보고서 저장: $FILENAME"
```

진행 모니터 확인:
```bash
python3 ~/projects/nco-progress.py --once
```
