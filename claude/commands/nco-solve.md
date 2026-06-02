# 풀스택 원키 해결 명령어: 웹 검색 → 분석 → 라이브러리 설치 → 설계 → 토론 → 구현 → 검증 → Gap분석(100% 루프)
# $ARGUMENTS를 해결할 요청으로 사용합니다.
# 형식: /nco-solve <해결하고 싶은 것>
# 예: /nco-solve 실시간 주식 데이터를 가져와서 대시보드에 시각화하는 기능 추가
# 예: /nco-solve 현재 API 응답 속도가 너무 느린데 최적화 방법을 찾아서 적용해줘

# 이 명령어는 사용자의 요청을 처음부터 끝까지 완전히 해결한다.

# ---

## 시작 전: 세션 초기화 및 모니터 시작

# ```bash
bash ~/projects/nco-session-log.sh "nco-solve" "0" "세션시작" "start" "$ARGUMENTS"
echo "[진행 모니터] 새 터미널에서: python3 ~/projects/nco-progress.py"
```

---

## PHASE 0: 요청 이해 및 계획 수립

```bash
bash ~/projects/nco-session-log.sh "nco-solve" "P0" "요청분석" "start" "$ARGUMENTS"
```

$ARGUMENTS를 분석하여:
1. 핵심 목표 파악
2. 기술 스택 파악 (현재 프로젝트 언어/프레임워크)
3. 범위 추정 (파일 수, 신규 vs 수정)
4. 의존성 파악

```bash
# 현재 프로젝트 컨텍스트 파악
ls -la 2>/dev/null | head -20
cat package.json 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print('Node:', d.get('name'), d.get('version'))" 2>/dev/null
cat requirements.txt 2>/dev/null | head -10
git log --oneline -5 2>/dev/null

bash ~/projects/nco-session-log.sh "nco-solve" "P0" "요청분석" "done" "프로젝트 컨텍스트 파악 완료"
```

출력:
```
[작업 계획]
요청: $ARGUMENTS
핵심 목표: <목표>
기술 스택: <스택>
예상 작업: <목록>
필요 외부 자료: 있음/없음
```

---

## PHASE 1: 최신 자료 웹 검색

```bash
bash ~/projects/nco-session-log.sh "nco-solve" "P1" "웹검색" "start" "최신 라이브러리/패턴 검색 중"
```

신기술/최신 라이브러리가 필요한 경우 WebSearch 도구로 검색한다.

검색 대상:
- 목표 달성에 최적인 최신 라이브러리/도구 (2024-2025)
- 공식 문서 및 API 레퍼런스
- GitHub Stars 1000+ 구현 예제
- 주요 Breaking changes

선별 기준:
- 최신 안정 버전 (active 유지)
- 커뮤니티 채택률 높은 패턴
- 보안 취약점 없는 버전

```bash
bash ~/projects/nco-session-log.sh "nco-solve" "P1" "웹검색" "done" "필요 라이브러리: <목록>"
```

---

## PHASE 2: 아키텍처 설계

```bash
bash ~/projects/nco-session-log.sh "nco-solve" "P2" "설계" "start" "opencode+gemini 병렬 설계"

curl -s -X POST http://localhost:6200/api/realtime/parallel \
  -H "Content-Type: application/json" \
  -d "{
    \"prompt\": \"다음 요청을 구현하기 위한 아키텍처를 설계하라. 파일 구조, 인터페이스, 데이터 흐름을 포함할 것. 현재 프로젝트 스택 고려. 요청: $ARGUMENTS\",
    \"providers\": [\"opencode\", \"gemini\"]
  }" | python3 -m json.tool

bash ~/projects/nco-session-log.sh "nco-solve" "P2" "설계" "done" "설계안 생성 완료"
```

설계 결정을 정리하고 사용자에게 확인 받는다:
```
[설계 결정]
구조: <파일/모듈 계획>
인터페이스: <주요 함수/API 시그니처>
데이터 흐름: <흐름도>

계속 진행할까요? (설계 변경 요청 가능)
```

---

## PHASE 3: 의존성 설치

```bash
bash ~/projects/nco-session-log.sh "nco-solve" "P3" "의존성설치" "start" "라이브러리 설치 중"
```

설치 전 확인:
1. 현재 패키지 매니저 파악 (npm/yarn/pip/cargo/go mod)
2. 버전 충돌 없는지 확인
3. 보안 검사

```bash
# 설치 및 검증 (실제 라이브러리로 대체)
# npm install <library>@<latest-stable-version>
# pip install <library>==<version>

# 설치 검증
npm list <library> 2>/dev/null || pip show <library> 2>/dev/null

bash ~/projects/nco-session-log.sh "nco-solve" "P3" "의존성설치" "done" "라이브러리 설치 완료"
```

---

## PHASE 4: 병렬 구현

```bash
bash ~/projects/nco-session-log.sh "nco-solve" "P4" "구현" "start" "codex+cursor-agent 병렬 구현 시작"

curl -s -X POST http://localhost:6200/api/realtime/parallel \
  -H "Content-Type: application/json" \
  -d "{
    \"prompt\": \"다음 설계를 바탕으로 구현하라. 실제 작동하는 코드를 작성하고, 엣지케이스와 에러 처리를 포함하라. 요청: $ARGUMENTS\",
    \"providers\": [\"codex\", \"cursor-agent\"]
  }" | python3 -m json.tool

# 태스크 상태 실시간 확인
sleep 3
curl -s http://localhost:6200/api/tasks?limit=5 | python3 -c "
import sys,json; d=json.load(sys.stdin)
print('[구현 태스크 상태]')
for t in d.get('tasks',[])[:3]:
    print(f'  {t[\"assigned_to\"]:14} [{t[\"status\"]:8}] {t[\"prompt\"][:50]}')
"

bash ~/projects/nco-session-log.sh "nco-solve" "P4" "구현" "done" "구현 태스크 큐 등록 완료"
```

---

## PHASE 5: 코드 리뷰

```bash
bash ~/projects/nco-session-log.sh "nco-solve" "P5" "코드리뷰" "start" "cursor-agent 리뷰 요청"

curl -s -X POST http://localhost:6200/api/task \
  -H "Content-Type: application/json" \
  -d "{
    \"ai\": \"cursor-agent\",
    \"prompt\": \"구현된 코드를 리뷰하라. 버그, 보안 취약점, 성능 문제, 코드 스타일 위반을 찾아 수정 제안을 제공하라. 원요청: $ARGUMENTS\",
    \"mode\": \"task\"
  }" | python3 -m json.tool

bash ~/projects/nco-session-log.sh "nco-solve" "P5" "코드리뷰" "done" "리뷰 태스크 큐 등록 완료"
```

리뷰 결과의 Critical/High 이슈를 즉시 수정한다.

---

## PHASE 6: 테스트 및 엣지케이스 검증

```bash
bash ~/projects/nco-session-log.sh "nco-solve" "P6" "테스트" "start" "테스트 실행 + vllm 엣지케이스 검증"

# 기존 테스트 실행
npm test 2>/dev/null && echo "✔ npm test 통과" || \
pytest 2>/dev/null && echo "✔ pytest 통과" || \
cargo test 2>/dev/null && echo "✔ cargo test 통과" || \
echo "테스트 명령어를 직접 지정해주세요"

# 타입 검사
npx tsc --noEmit 2>/dev/null && echo "✔ TypeScript 오류 없음" || echo "✘ TypeScript 오류 있음"

# vllm 엣지케이스 검증
curl -s -X POST http://localhost:6200/api/task \
  -H "Content-Type: application/json" \
  -d "{
    \"ai\": \"vllm\",
    \"prompt\": \"다음 구현의 엣지케이스를 찾아라: 빈 입력, 최대값, 동시성, 네트워크 오류, 인증 실패 시나리오. 요청: $ARGUMENTS\",
    \"mode\": \"task\"
  }" | python3 -m json.tool

bash ~/projects/nco-session-log.sh "nco-solve" "P6" "테스트" "done" "테스트 실행 완료"
```

---

## PHASE 7: Gap 분석 (100% 임계값)

```bash
bash ~/projects/nco-session-log.sh "nco-solve" "P7" "Gap분석" "gap" "완성도 평가 중"
```

6개 기준으로 평가한다:

- **기능 완전성** (25점): 요청한 모든 기능 구현됐는가?
- **코드 품질** (20점): 버그, 타입 오류, 린트 에러 없는가?
- **테스트 통과** (20점): 기존 + 신규 테스트 모두 통과하는가?
- **보안** (15점): 보안 취약점 없는가?
- **성능** (10점): 명백한 성능 문제 없는가?
- **문서화** (10점): 사용법을 이해할 수 있는가?

```bash
# Gap Rate 기록
bash ~/projects/nco-session-log.sh "nco-solve" "P7" "Gap분석" "done" "Gap Rate: XX% (기능:XX 품질:XX 테스트:XX 보안:XX)"
```

출력:
```
[Gap 분석]
Gap Rate: XX%
기능 완전성: XX/25
코드 품질:   XX/20
테스트:      XX/20
보안:        XX/15
성능:        XX/10
문서화:      XX/10

미흡 항목: <목록>
루프 횟수: N/3
```

---

## PHASE 8: 루프 판단

```bash
# 루프 시
bash ~/projects/nco-session-log.sh "nco-solve" "P8" "루프판단" "loop" "Gap XX% — PHASE X부터 재실행 (N/3회)"
# 완료 시
bash ~/projects/nco-session-log.sh "nco-solve" "P8" "루프판단" "done" "Gap XX% — 100% 달성"
```

- **Gap Rate ≥ 100%** → PHASE 9 완료 보고서 출력
- **Gap Rate < 100%, 루프 < 3** → 미흡 항목에 해당하는 Phase부터 재실행
  - 기능 미흡 → PHASE 4부터
  - 코드/보안 → PHASE 5부터
  - 테스트 실패 → PHASE 6부터
- **3회 루프 후 미달** → 현재 결과 제출 + 남은 이슈 명시

---

## PHASE 9: 완료 보고서 저장

```bash
bash ~/projects/nco-session-log.sh "nco-solve" "P9" "완료보고" "start" "보고서 저장 중"

mkdir -p docs/solutions
FILENAME="docs/solutions/$(date '+%Y%m%d-%H%M%S')-solve.md"

cat > "$FILENAME" << 'REPORT'
# 해결 완료: <요청 제목>
날짜: <현재 날짜>
Gap Rate: XX% | 루프: N회 | 사용 AI: <목록>

## 구현 결과
- 변경/생성 파일: <목록>
- 설치 라이브러리: <목록 및 버전>

## 주요 기능
- <기능 1>: <설명>

## 사용 방법
<코드 예제>

## 테스트 결과
- 전체: N개 통과 / M개 실패

## 알려진 제한사항
<있을 경우>

## 참조 자료
<사용한 라이브러리 문서, 참고 자료 URL>
REPORT

echo "보고서 저장: $FILENAME"

bash ~/projects/nco-session-log.sh "nco-solve" "P9" "완료보고" "done" "$FILENAME"
```

진행 모니터 최종 확인:
```bash
python3 ~/projects/nco-progress.py --once
```
