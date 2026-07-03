# NCO 자율성 축 조사 — 자율 학습·개선·성장·무인 완주 (2026-07-03)

조사 주체: kangnote-claude-1. 사용자 요구 8개(에이전트 능력/효율/세션간 통신/오케스트레이션/한번 설정→완료/장기기억/컨텍스트 공유/상호 인지 + 자율 학습·개선·성장·문제해결)를 기존 구현·조사와 대조, 갭인 자율성 축을 집중 조사.
관련 문서: [nco-tech-radar-2026-07.md](nco-tech-radar-2026-07.md), [nco-port-candidates-2026-07.md](nco-port-candidates-2026-07.md)

## 1. 자율 학습 — 결과 피드백으로 스스로 최적화

**DSPy + GEPA 옵티마이저 (ICLR 2026)** — 이 축의 현재 최강 기술.
- 실행 trace를 자연어로 반성(reflection)해 프롬프트를 진화시키는 gradient-free 옵티마이저. RL(GRPO) 대비 +20% 성능을 **35× 적은 롤아웃**으로 달성, 20~100개 예제면 프로덕션 최적화 가능.
- Pareto frontier로 다양한 프롬프트 후보 유지 — 분기 많은 에이전트 워크플로우에 특히 적합.
- 프로덕션 적용 사례 존재 (Decagon: 대화 분석 supervisor 모델 프롬프트 최적화).
- 대안 판정(심층 조사): TextGrad(3.6k★)는 2024-12 이후 정체, MS Trace(744★)는 베타 — **DSPy(35.8k★)+GEPA가 유일한 라이브 베팅**. 독립 패키지 gepa-ai/gepa도 프레임워크 비종속으로 사용 가능.
- **NCO 도입 경로**: 각 프로바이더 persona.systemPrompt를 GEPA로 자동 튜닝. 학습 신호는 이미 있음 — invocation 성공/실패 + verifier PASS/FAIL + leaderboard 점수가 그대로 GEPA의 피드백. Python이므로 사이드카 배치(주기적으로 DB에서 trace 읽어 프롬프트 개선안 생성 → 사람/감독관 승인 후 반영).

## 2. 자율 성장 — 스킬 라이브러리 (한 번 배우면 영구 재사용)

**Voyager 패턴 (NVIDIA, 2023 → 2026 계열 연구 활발)**
- 핵심 루프: 코드 생성→실행→에러 관찰→수정→**검증된 스킬을 임베딩과 함께 저장**→새 태스크에서 시맨틱 검색으로 재사용. 시행착오를 휘발성 추론이 아닌 **내구성 있는 조합 가능한 프로그램**으로 전환.
- 이식성 입증: Voyager 스킬 라이브러리를 AutoGPT에 이식하자 zero-shot 성공률 0/3→1-2/3.
- 2026 계열: SkillFlow(스킬 검색 확장), SkillAudit(궤적 쌍 비교로 스킬 진화 검증), markdown 스킬을 자가개선 메모리로 쓰는 흐름 — **Claude Code의 skills 체계가 정확히 이 계보**.
- **NCO 도입 경로 (가장 실용적)**: 이미 갖춘 것들의 연결로 구현 가능 —
  1. 태스크 완료+verifier PASS 시 해법을 스킬 md로 증류 (기존 개선노트 자동생성의 승격)
  2. `~/.claude/skills/` + fleet-config 배포 체계가 저장·전파 레이어 (이미 있음)
  3. MARM/gbrain 임베딩이 검색 레이어 (이미 있음)
  4. 필요한 신규 코드는 "증류기" 하나: 성공 궤적 → 재사용 스킬 md 변환 + 중복 검사
- 심층 조사 확인: **Claude Code SKILL.md 스펙 자체가 자가작성 스킬 표준** — 에이전트가 `~/.claude/skills/<x>/SKILL.md`를 쓰면 다음 실행부터 자동 로드, agentskills.io로 에이전트 간 이식. 스킬 마켓플레이스(SkillsMP, LobeHub) 존재. **NCO에겐 빌드가 아니라 설정 수준의 변화.**
- claudectl Hive Mind(레이더 §17)의 지식 증류·전파와 동일 사상 — fleet 전 머신으로 스킬이 퍼지는 구조.

## 2.5 자기진화 프레임워크 (심층 조사 — 전부 실행 가능 코드, 단 ⚠️ 공통 경고)

| 도구 | ★ | 요지 | NCO 적용 |
|---|---|---|---|
| **EvoAgentX** | 3.1k | 에이전틱 워크플로우 빌드·평가·**진화** (TextGrad/MIPRO/AFlow 번들, pip) | **실용 1픽** — NCO 워크플로우 진화 직접 구동 가능. MIT |
| Darwin-Gödel Machine (Sakana) | 2.2k | 자기 코드 재작성, SWE-bench 20→50% 실증 | 감독된 self-modify 루프의 참조 아키텍처. Apache-2.0 |
| ADAS (ICLR'25) | 1.6k | 메타 에이전트가 더 나은 에이전트를 코드로 설계 | 오프라인에서 신규 에이전트 구성 탐색→leaderboard로 승격. Apache-2.0 |
| AgentSquare | 230 | planning/reasoning/tool/memory 모듈 조합 탐색 | NCO 모듈 구조와 일대일 대응 |
| awesome-agent-evolution | 170 | 684 레포 증거 지도 | 소싱/실사 체크리스트 |

⚠️ **안전 원칙**: 위 전부 "모델 생성 코드를 실행"함 — 자기수정은 반드시 **샌드박스(microsandbox)+서킷브레이커 뒤에서만**. 무인화 = 게이트 제거가 아니라 게이트의 코드화.

## 3. 상호 인지 — "서로 뭘 하는지" 표준

**Google A2A (Agent2Agent) 프로토콜 — 2026년 사실상 표준 확정**
- v1.0(2026 초)→v1.2, Linux Foundation Agentic AI Foundation 거버넌스, **150+ 조직 프로덕션 채택**(Google/MS/AWS/Salesforce/SAP/IBM...), GitHub 22k★, SDK 5개 언어(Py/JS/Java/Go/.NET).
- **Signed Agent Card**: 도메인 소유자의 암호 서명으로 카드 진위 검증 — 탈중앙 발견의 신뢰 모델. **우리 fleet이 겪은 감독관 사칭·승인 캡처 공격의 표준적 해법.**
- **NCO 도입 경로**: 단계적 — (a) 각 세션/프로바이더에 agent card JSON 발행(현재 mesh heartbeat 확장) (b) swarmclaw가 이미 노출하는 `/.well-known/agent-card.json` 관례 채택 (c) 서명 카드로 피어 신원 검증(장기). inter-session bus를 대체하는 게 아니라 **신원·능력 광고 레이어**로 얹는 것.
- 표준 통합 확정(심층 조사): IBM ACP는 A2A에 병합, AGNTCY는 Linux Foundation에 기증 — **추적할 표준은 A2A 하나**. Agent Card 위치 관례: `/.well-known/agent.json`.

## 4. 무인 완주 (한 번 설정 → 끝까지)

- **이미 보유**: 상태기계+orphan 자동복구+dead-letter+retry(57114b2), per-task timeout, Gap 100% 루프(최대 5회), 서킷·게이트. "중간에 죽어도 스스로 일어나는" 기반은 완성.
- **갭**: "죽지 않고 계속 도는" 루프 — Claude Code 진영의 continuous-loop 패턴(autonomous loop / self-pacing wakeup)과 durable execution(hatchet, 레이더 §4). 핵심 설계 원칙(커뮤니티 수렴): **무인화는 게이트 제거가 아니라 게이트의 코드화** — verifier가 사람 대신 PASS/FAIL을 내리고, 실패가 다음 반복의 입력이 되는 구조(claudectl "verifier-is-the-gradient", 이미 이식 후보 P1-5).
- 심층 조사 추가: **Ralph Wiggum 루프**(Huntley 패턴, Anthropic B.Cherny 정식화) — 동일 프롬프트를 반복 주입하되 **진행 상태를 컨텍스트가 아닌 git/TODO/파일에 외재화**, Stop hook이 "됐나? 안 됐으면 고치고 계속"을 재주입. 2026-01 최초의 무인 프로덕션 버그 자가치유 사례. NCO 상태기계+핸드오프 패킷과 직결. ⚠️ 주의: LangGraph류 체크포인트 ≠ durable execution — watchdog/자동재개는 별도(우리 서킷·orphan 복구가 그 역할).
**NCO 도입 경로**: kanban-engine+nco-do(이미 있음)에 ①verifier 게이트 통과를 전진 조건으로 ②실패 시 FAIL 출력을 재시도 프롬프트에 주입 ③N회 초과 시만 사람 에스컬레이션. 이 3개 규칙이면 "한 번 설정→완료까지"가 안전하게 성립.

## 5. 백그라운드 자가 개선 (sleep-time compute)

- Letta의 sleep-time agents 개념: 유휴 시간에 메모리 정리·반성·스킬 개선을 수행하는 백그라운드 에이전트.
- **NCO 도입 경로**: 이미 있는 조각의 재배선 — Stop hook의 개선노트 생성(Ollama)·MARM compaction(stage/apply)·gbrain skillopt를 **유휴 시간 cron**으로 묶으면 됨. GPU 드라이버 갱신 후 gpt-oss:20b가 이 층의 엔진 적임(레이더 §2).

## 6. NCO에 이미 있는 자율성 씨앗 (재발견)

| 모듈 | 현재 | 승격 방향 |
|---|---|---|
| `reflexion.ts` | 존재 | GEPA식 자연어 반성 루프의 수신부로 |
| `agent-evolver.ts` | 성공 기록→persona 튜닝 | GEPA 사이드카의 적용 지점으로 |
| `knowledge-base.ts` + gbrain | 지식 축적 | 스킬 증류기의 저장소로 |
| leaderboard | 성공률 집계 | 라우팅·최적화의 보상 신호로 |
| 개선노트 자동생성 | Stop 시 | sleep-time 파이프라인의 입력으로 |

**결론**: 자율성 축은 "새 프레임워크 도입"이 아니라 **이미 있는 모듈들을 GEPA(학습)·Voyager 패턴(성장)·A2A 카드(인지)·verifier 루프(무인 완주)라는 검증된 설계로 연결하는 문제**다.

## 7. 권장 순서
1. **스킬 증류기** (성공 궤적→스킬 md, 기존 인프라 재사용 — 최소 코드로 최대 효과)
2. **무인 완주 3규칙** (kanban+verifier 결합)
3. **agent card 발행** (mesh heartbeat 확장, 서명은 후순위)
4. **GEPA 사이드카 파일럿** (프로바이더 1개 persona부터)
5. **sleep-time cron** (기존 조각 재배선)

## 출처
[GEPA 프로덕션 적용(Decagon)](https://decagon.ai/blog/optimizing-gepa-for-production) · [GEPA 해설(Morph)](https://www.morphllm.com/gepa-prompt-optimization) · [A2A 2026 채택 현황](https://www.glukhov.org/ai-systems/comparisons/a2a-protocol-2026-adoption) · [A2A 150+ 조직](https://stellagent.ai/insights/a2a-protocol-google-agent-to-agent) · [Voyager 원논문](https://arxiv.org/html/2305.16291) · [Voyager 계보 정리](https://beancount.io/bean-labs/research-logs/2026/05/08/voyager-open-ended-embodied-agent-lifelong-learning) · SkillFlow/SkillAudit arXiv
