# 하네스 최적화 · 루프 엔진 · 결과 검증 설계 (2026-07-23)

> NCO 토론(`sess_EccLMg4rsy7SEsDV`, codex·agy) + 실측 T1 진단 종합.
> claude-code 프로바이더는 circuit-breaker-open으로 미참여 → agy 제안 + codex 비평 기반.

## 0. 실행 원칙 (codex 비평 반영)
- **Master Hook 단일화 안 함** — 단일 장애점(SPOF)·디버깅 난이도. 대신 생명주기별로 훅을 최소화하고 안전 게이트(secret-scan, false-report, verify)는 **분리 유지**.
- **샌드박스 전면 완화 안 함** — Agent는 *리서치/조사/병렬분석만* 무조건 허용, 구현은 비차단 권고. 하드블록은 `NCO_AGENT_HARD_BLOCK=1`로 복원 가능.
- **단계적 마이그레이션 + T1 측정** — 모든 변경은 백업 → 편집 → 파싱/문법/동작 T1 검증.

## 1. 적용 완료 (이번 세션, T1 검증됨)
| # | 변경 | 파일 | 검증 |
|---|---|---|---|
| ① | 중복 훅 제거 (false-report 2→1, tool-activity Pre/Post 각 2→1) | `~/.claude/settings.json` | JSON 파싱 OK |
| ② | Stop 훅 17→8, canonical-drift→SessionStart 이관 | `~/.claude/settings.json` | 훅 수 카운트 |
| ③ | Agent 하드차단→소프트권고(리서치/병렬 허용) | `nco-agent-enforce.sh` (canonical+local) | 4케이스 동작 |
| ④ | CLAUDE.md 21.4KB→8.4KB core + 6.7KB reference (61%↓) | `CLAUDE.md`+`CLAUDE-reference.md` | 규칙 7종 grep |
| ⑤⑥ | 루프 엔진 설계 + `verify.sh` 공통 검증기 | 본 문서 + `verify.sh` | 5/5 PASS, exit코드 |

## 2. 루프 엔진 (Plan → Act → Verify → Gap → Rework)
```
[사용자 요청]
   │
   ▼
① 목표 분해 → 체크리스트 생성  [ ] G1  [ ] G2 ... [ ] Gn
   │
   ▼
② Act — 도구/위임으로 각 목표 수행
   │
   ▼
③ Verify — verify.sh로 T1 증거 수집 (파일/HTTP/포트/명령)
   │
   ▼
④ Gap 분석 — 요구(Goal) vs 검증(Verify) 차이 계산
   │
   ├─ Gap=0 (전부 [x]) ──────────────► [완료] 검증 영수증 + 다음 추천 단계
   │
   └─ Gap>0 (미달 목표 존재)
          │  실패 사유를 자가학습 캐시에 기록 (~/.claude/.loop-lessons/)
          ▼
       재작업 큐 발행 → ②로 복귀 (최대 5회, feedback_delegation 규칙)
```
- **정지 조건**: 모든 목표 `[x]` **또는** 5회 초과 **또는** 사용자 중단.
- **자가학습**: 동일 에러 3회 감지 시 우회로 탐색 + 로컬 룰 캐시 업데이트 → 다음 동일 작업에 선적용.
- **완료 판정은 verify.sh exit 0에만 의존** (자기보고 금지 = Priority #1).

## 3. 체크리스트 자동 진행 + 번호 승인 UX
마일스톤 종료/승인 필요 시 장황한 설명 대신:
```markdown
✅ 진행 완료 (T1 증거: verify.sh 5/5 PASS)

▶️ 다음 추천 단계 (번호 입력 또는 '모두'):
[ ] 1. <다음 작업 A>
[ ] 2. <다음 작업 B>
[ ] 3. 커밋 & 푸시
```
Claude Code에서는 `AskUserQuestion`(multiSelect)로 렌더 → 사용자는 체크만.

## 4. 거짓보고 방지 (변경 없음, 기존 유지)
T1~T4 증거등급 + pre-claim verify + 검증 영수증. `no-false-report-gate.sh`(block) Stop 훅 1개로 유지. verify.sh가 완료 주장의 T1 증거를 강제 생성.

## 5. 프로바이더 공통 적용 (Universal Adapter)
1. **공통 룰 주입** — 각 프로바이더 전역 지침 파일에 코어 룰(pre-claim verify·증거등급) 동일 주입:
   | 프로바이더 | 지침 파일 |
   |---|---|
   | Claude Code | `~/.claude/CLAUDE.md` (core) |
   | cursor | `.cursorrules` |
   | agy / opencode / codex | `AGENTS.md` / `.agyrules` |
   | ollama (로컬) | 시스템 프롬프트 프리픽스 |
2. **독립 검증 스크립트** — `verify.sh`는 훅 비의존. 어떤 프로바이더든:
   `./verify.sh --file X --http URL --cmd 'test' ` 호출 → T1 영수증 + exit 코드.
   지침: *"작업 완료 후 반드시 verify.sh를 실행하고 그 출력(T1)을 확인하라."*
3. **범용 이벤트 래퍼** — 프로바이더별 이벤트(PreToolUse 등)를 `onBeforeAction`/`onAfterAction`으로 추상화(브릿지). 코어 루프는 프로바이더 종류를 몰라도 동작. (미구현 — 다음 단계)

## 6. 남은 후보 (미적용 · 다음 단계)
- [ ] UserPromptSubmit 12훅 감량 (상시 배너 → statusline 이관)
- [ ] PreToolUse 8훅 dispatcher 패턴 통합 (안전 게이트는 분리 유지)
- [ ] 이벤트 래퍼(브릿지) 실제 구현
- [ ] 자가학습 캐시(`~/.claude/.loop-lessons/`) 실제 배선
- [ ] 각 프로바이더 지침 파일에 코어 룰 실제 주입 + verify.sh 배포

## 검증 영수증
- [변경] settings.json(①②)·nco-agent-enforce.sh(③)·CLAUDE.md+reference(④)·verify.sh(⑤⑥) + 본 문서
- [검증방법] `python3 json.load`(파싱)·`bash -n`(문법)·4케이스 exit코드(agent-enforce)·`grep`(규칙 7종)·verify.sh 5/5 PASS+FAIL exit1
- [등급] T1 (파싱 결과·문법·exit 코드·파일 내용·HTTP 본문 직접 확인)
- [Gap] 설계·구현 100% (①~⑥ 적용+검증) / 로드맵 §6은 의도적 미구현
- [미검증항목] 실제 다음 세션에서 슬림 CLAUDE.md 로드 후 행동 회귀 여부(런타임 미관찰)·fleet 타 디바이스 전파(미push)
