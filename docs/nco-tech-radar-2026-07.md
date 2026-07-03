# NCO 기술 레이더 — 전방위 조사 (2026-07-03)

조사 주체: kangnote-claude-1. 방법: 병렬 리서치 에이전트 4갈래(GitHub 갭 카테고리 / 커뮤니티 Reddit·HN·YouTube / MCP·Claude Code·fleet 생태계 / 학술 축).
별점·라이선스는 GitHub API로 조사 시점 검증(T1). 커뮤니티 주장은 [PRIMARY]=빌더 블로그·HN 원문 / [AGG]=애그리게이터(저신뢰) 구분.
학술 축(copilot 위임)은 웹 접근 실패로 미검증 산출 → 불채택 (컨텍스트 엔지니어링 일반론만 §6에 일부 반영).
관련 문서: [nco-port-candidates-2026-07.md](nco-port-candidates-2026-07.md) · **자율성 축(자율 학습·성장·무인완주·A2A)은 [nco-autonomy-axis-2026-07.md](nco-autonomy-axis-2026-07.md)** — 별도 심층 조사 (7개 레포 — P0 전부·P1 대부분 구현 완료).

## 0. 요약 — 카테고리별 1픽

| 갭 | 픽 | ★ | 라이선스 | 왜 |
|---|---|---|---|---|
| 평가 하네스 | **promptfoo** | 22.9k | MIT | TS 네이티브, CLI 설정형, 어떤 프로바이더든 래핑 — NCO 라우팅 회귀 테스트에 즉납 |
| 관측성 | **Langfuse** + OTel GenAI 규약 | 30.3k | MIT-core | TS SDK·셀프호스트·비용 추적; `gen_ai.*` 스팬을 wire format으로 쓰면 백엔드 교체 자유 |
| 구조화 출력 | **BAML** | 8.5k | Apache-2.0 | Rust 코어+TS SDK — 유일하게 Node 스택 네이티브, CLI 프로바이더 위에서도 동작 |
| 샌드박스 | **microsandbox** | 6.8k | Apache-2.0 | microVM(<100ms 부트) + **MCP 서버 내장** — Claude Code 직결; 경량 대안 bubblewrap |
| 비용/라우팅 | **litellm proxy** | 52.5k | MIT | 프록시 1대로 예산·폴백·spend 로그 — 서킷브레이커·preflight 옆에 그대로 꽂힘 |
| 에이전트별 메모리 | **mem0** (+graphiti) | 60.0k / 28.3k | Apache-2.0 | MARM(공유)과 상보 — 에이전트별 장기 기억 추출·중복제거; graphiti는 시간축 KG |
| MCP 제어면 | **IBM ContextForge** | 4.0k | Apache-2.0 | 게이트웨이+레지스트리+감사 — 세션당 MCP URL 1개로 federate; 경량 대안 metamcp(2.5k) |
| CC 헤드리스 | **claude-agent-sdk** | 7.5k | MIT | 공식 SDK(query/hooks/권한) — TUI 우회 대신 정식 기반 |
| fleet 비용 | **ccusage** | 16.8k | MIT | 로컬 토큰/비용 로그 집계 — 세션별 JSONL 모으면 fleet 지출 대시보드 |
| 버스/큐 | **NATS JetStream** | 20.1k | Apache-2.0 | 단일 바이너리, subject=세션 매핑, 내구 큐 — inter-session bus의 구조적 대체 후보 |
| 안전 노출 | **Tailscale tsnet+serve/funnel** | — | Apache-2.0 | 포트 개방 없이 MARM류 fleet 서비스 노출하는 정석 |
| MCP 보안 | **Snyk mcp-scan** | 2.7k | Apache-2.0 | fleet 합류 전 MCP 서버 프롬프트 인젝션/tool-poisoning 스캔 — 우리 보안사건 이력과 직결 |
| worktree 병렬 | **vibe-kanban** | 27.2k | Apache-2.0 | 격리 워크스페이스 칸반+리뷰 — 상태기계·핸드오프의 시각 제어면; CC 내장 worktree 격리도 옵션 |

기피/주의: RouteLLM(2024-08 stale — 아이디어만), Not-Diamond(archived), openai/evals(정체), Crystal(deprecated→Nimbalyst), opcode·claude-squad(AGPL — 임베드 주의), swarmclaw(라이선스 미명시).

## 1. 커뮤니티가 말하는 것 [PRIMARY 위주] — 아키텍처 교훈

- **핵심 논쟁**: Cognition "Don't Build Multi-Agents"(병렬 서브에이전트는 컨텍스트 격리 탓에 상충 결정 — 단일 에이전트+컨텍스트 엔지니어링 선호) vs Anthropic(오케스트레이터-워커가 리서치 평가에서 단일 대비 +90.2%, 단 토큰 ~15×; **코딩엔 멀티에이전트 부적합** 명시).
- **HN 수렴**: "에이전트가 아니라 하네스가 어렵다" — 신뢰성은 스캐폴드(재시도·검증기·페이즈 게이트·구조화 핸드오프)가 결정. **NCO의 증거등급·검증 문화가 정확히 이 방향** — 이번 주 구현한 것들이 커뮤니티 수렴점과 일치.
- 컨텍스트는 토큰 한도 훨씬 전(~50k)부터 열화("dilution") — 서브에이전트는 병렬화가 아니라 **압축/격리** 용도로.
- NCO 시사점: nco_parallel 남용 주의 — 코딩 작업은 단일 강한 에이전트+검증 게이트, 병렬은 읽기 중심 리서치에.

## 2. 소형/로컬 모델 실전 추천 [PRIMARY]

- **gpt-oss:20b** — 16GB GPU에서 MXFP4로 구동, 분류·라우팅·추출·헬스체크 등 대량 저위험 층에 최적 (초기 tool-calling 버그는 최신 llama.cpp에서 해소).
- **Qwen3-Coder-30B** (MoE, 활성 ~3.3B) — 24-32GB GPU 코딩/도구 사용.
- **Qwen3 4-9B** — 로컬 도구 사용·정보 추출 라우터 역할.
- kangNote 참고: 현재 GPU 드라이버 미갱신으로 Windows Ollama CPU만 — 드라이버 560+ 업데이트 시 gpt-oss:20b가 ollama 검증 에이전트 공백을 메울 1순위.
- [AGG 미검증 리드]: Mistral Small 3, Gemma 3/4, Phi-4-mini — 자체 평가 필요.

## 3. 메모리 전략 [PRIMARY]

- HN 회의론: mem0/zep/letta류 "연산마다 LLM" 메모리는 op당 200-500ms + 100k 메모리에 월 $1-3k — **"SQLite 파일 하나로 시작하라"**가 실전 기본값.
- **MARM 선택이 이 노선과 일치** (SQLite WAL, LLM 비의존 recall). mem0/graphiti는 에이전트별 자동 추출·시간축이 필요해질 때만.
- ~~파일럿 관찰 항목: smart_recall 인덱스 분리 소견~~ → **원인 확정(서버 소스 T1, macstudio)**: 설계상 분리 — log_entry는 log_entries 테이블, smart_recall 시맨틱은 memories 테이블만 대상. 로그 회수는 marm_log_show 또는 smart_recall include_logs:true(LIKE 부분일치). 첫 recall 20s+는 sentence-transformers lazy 웜업(이후 p95 20-31ms).

## 4. 신뢰성 전술 수렴점 [PRIMARY/AGG]

지수 백오프+jitter+Retry-After 파싱 / 서킷브레이커 (실화: 429에 재시도 폭주한 에이전트가 회사 IP를 Jira에서 차단당함 — 자해 DoS) / **"done" 후 실제 변화 확인** (에이전트는 완료를 조작함) / 체크포인트+재개 / 루브릭 명시 LLM-judge + ~20문항 인간 평가셋 / **microVM 샌드박스** (Docker/runc로는 부족 — Firecracker/Kata/gVisor 계열). → 대부분 구현 완료, 미구현은 **샌드박스**(microsandbox)와 **평가셋**(promptfoo).

## 5. 권장 도입 순서 (기존 구현과의 갭 기준)

1. **ccusage** — 설치만으로 fleet 비용 가시화 (반나절)
2. **promptfoo 회귀셋** — 프로바이더별 표준 태스크 20개, 라우팅 결정 근거 확보 (1-2일)
3. **OTel GenAI 스팬 방출** (openllmetry 참고) → Langfuse 셀프호스트는 필요 시 (2-3일)
4. **microsandbox** — 에이전트 생성 코드 실행 격리, MCP 직결 (2-3일)
5. **litellm proxy** — API 프로바이더 통합 게이트웨이 + 예산 (기존 preflight·서킷과 역할 정리 필요, 1주)
6. 중기: NATS JetStream 버스 전환 검토(inter-session 신뢰성 요구가 더 커지면), ContextForge MCP 제어면, BAML 구조화 위임 페이로드
7. 조건부: GPU 드라이버 갱신 후 gpt-oss:20b 로컬 판정 에이전트

## 6. 컨텍스트 엔지니어링 (코드화 가능 기법)

- 시맨틱 청킹+관련도·최신성·토큰예산 top-K 유지 (opencode-swarm의 Context Budget Guard와 동계열)
- 프롬프트 캐시 경계 설계 — 고정 프리픽스(시스템·도구정의)와 가변부 분리로 캐시 적중 극대화
- 서브에이전트를 요약기로: 긴 탐색 결과를 메인 궤적에 넣기 전 압축 (HN 수렴점과 동일)

## 출처

GitHub REST API(별점·라이선스·최근성), Anthropic engineering blog, Cognition 블로그, HN 스레드(44804397·44834571·44855690·45096962·46511540·46872706·46891715), LangChain 블로그, Modal/샌드박스 가이드, Tailscale tsnet/serve 문서, MintMCP·Composio 게이트웨이 라운드업. YouTube: "2026: The Year of Agent Orchestration"(Zach Lloyd, Coding Agents Conf), AgentEng 2026 트랙.
