# NCO 이식 후보 분석 — 소형 에이전트 군집 오픈소스 조사 (2026-07-02)

> **진행 상태 갱신 (2026-07-03, kangnote-claude-1)** — fleet 협업 구현 현황:
> - **P0 (1~4번): 전부 구현·E2E 완료** — 실패분류기(1754e37)+preflight(동일)+면제(99c3369) / 상태기계·orphan·멱등cancel·dead-letter·drain(57114b2, E2E 검증) / 서킷(de5b449→025b457 오탐수정)
> - **P1: 5번 ✅ Verifier Gate v0/v1(5ff76c3, 7c3c0dd) / 7번 ✅ Handoff Packet v1+v1.1 3단 파이프라인 완성(발신 scripts/handoff-send.py·수신 annotate·서버 POST /api/handoff, 왕복 E2E) / 8번 ✅ PRM trajectory-guard(05d0e45) / 6번 증거번들 미착수**
> - **협업축: 14번 MARM ✅ Phase A 중앙 배치 완료(2026-07-03 사용자 결재 후 macstudio pip venv+pm2, Tailscale 100.88.88.69:8001 — kangNote 원격 /health 200 T1 확인) — 잔여: API키 보안 배포+48h 파일럿 / 18번 ✅ comm-graph 게이트(shadow 기본, enforce 403 검증) / 15~17·19번 미착수**
> - **P2 (9~13번): 대부분 미착수** (12번 부분 — 가용성 게이트 409/failover)
> - 부수 성과: 이식 과정 실측으로 서킷 오탐(성공출력 인용 트립)·BullMQ 큐명·CHECK 스키마 등 기존 버그 6+건 발견·수정

조사 주체: kangnote-claude-1 (Fable 5). 대상 7개 레포 README 전수 분석 (Explore 에이전트 3개 병렬).
대상: opencode-swarm(376★), optio(990★), claudectl(188★), MARM-Systems(306★), fractals(641★), swarmclaw(598★), agency-swarm(4.5k★).

## 0. NCO 실측 약점 (2026-07-02 세션 T1 확인) ↔ 해법 매핑

| NCO 약점 (실측) | 해법 | 출처 |
|---|---|---|
| 429 시 invocation 영구 `running` | silent-failure 분류기 + 지수 백오프 + 자동 비활성 | swarmclaw `classifyWakeOutcome` |
| completed-but-actually-failed (cursor 한도초과=completed) | 빈 결과/에러 포함 결과 = 실패로 분류; 외부 검증 기준 완료(CI/PR) | swarmclaw empty-run, optio |
| task cancel API "pending implementation" | 멱등 cancel/drain + orphan dead-letter + retry API | claudectl supervisor, swarmclaw |
| 키/자격증명 사고 (placeholder 키 → 심층 401) | credential preflight — 키 미해결 시 즉시 명확한 실패 | swarmclaw v1.9.39 |
| 검증 ad-hoc (T1~T4 수동 등급) | fail-closed 선언적 verifier (run/brain/agent 3종, PASS/FAIL 강제) + 증거 게이트 | claudectl, opencode-swarm evidence/ |
| lost-event로 상태 표류 | reconciliation 루프 (pure-decision + CAS + 주기 resync) | optio |
| mesh DM dedup 루프/브로드캐스트 폭주 | 결정론적 cron(틱 기준), connector outbox(전달 증거+dedupe) | swarmclaw |
| 세션 간 메모리 = git 파일 동기화 | HTTP 공유 메모리 서버 (SQLite WAL + 직렬 쓰기큐 + 하이브리드 recall) | MARM |
| push telemetry 부재 (FLEET_CENTRAL_URL 미적용) | Prometheus exporter + 건강점수, PA inbox 모델 | claudectl, optio |

## 1. P0 — 즉시 이식 (NCO 신뢰성 이니셔티브와 직결)

1. **실패 분류기 + 백오프** (swarmclaw): 결과에 error 있음 OR text 공백 → 실패. 연속실패 카운터, 10s→5min 지수 백오프, MAX 10회 시 자동 비활성+통지. NCO invocation 종결 로직에 삽입.
2. **태스크 수명주기 상태기계 + reconciler** (optio): QUEUED→PROVISIONING→RUNNING→FAILED/COMPLETED 명시 전이 + 주기 resync가 ground truth에서 상태 재계산(CAS). "영구 running" 원천 차단.
3. **멱등 cancel/drain + dead-letter** (claudectl/swarmclaw): cancel API 구현, 시작 시 orphan 1회 재큐잉, 반복 실패 시 dead-letter + `POST /tasks/:id/retry`.
4. **credential preflight** (swarmclaw): API형 프로바이더 위임 전 키 해결 확인 — 오늘의 nvidia/openrouter 401 류를 위임 전에 잡음.

## 2. P1 — 검증 체계 (거짓보고 방지 규칙의 코드화)

5. **fail-closed verifier** (claudectl): tasks에 verifier 선언(run=exit code / brain=로컬LLM 판정 / agent=적대적 headless). PASS/FAIL 접두사 없으면 FAIL. FAIL 출력이 다음 재시도 프롬프트가 됨("verifier-is-the-gradient"). → NCO의 T1~T4 증거등급 규칙을 사람 규율이 아닌 코드 게이트로.
6. **증거 번들 게이트** (opencode-swarm): 태스크별 evidence/ 디렉터리에 review✓ tests✓ 등 증거 없으면 phase_complete 불가. NCO Gap 분석의 종결 조건으로 이식.
7. **핸드오프 패킷** (swarmclaw): 결과·증거·아티팩트·타임라인·재개 명령이 담긴 구조화 JSON. inter-session 위임 회신 형식(현재 자유 텍스트 `done:`)의 업그레이드.
8. **서킷브레이커/PRM** (opencode-swarm): 에이전트당 도구호출 200회/30분/동일도구 10회/연속에러 5-8회 상한 + 궤적 실패패턴 감지(반복루프·핑퐁·드리프트) 3단계 에스컬레이션.

## 3. P2 — 확장성/효율

9. **역할별 소형모델 라우팅** (opencode-swarm): explorer→flash급, coder→중형, reviewer→다른 계열("다른 모델이 다른 버그를 잡는다"). NCO 프로바이더 score 필드를 비용라우팅으로 확장.
10. **PA 수명주기 비용 노브** (optio): always-on / sticky(웜 유지) / on-demand — NCO CLI lazy-spawn에 sticky 모드 추가하면 반복 위임 시 cold-start 절감.
11. **재귀 분해 + lineage context + git worktree 격리** (fractals): 복합 태스크를 자기유사 트리로 분해, 리프 프롬프트에 조상 체인 주입, 리프별 worktree로 파일 충돌 원천 차단. depth cap 4.
12. **동시성 제어** (swarmclaw): maxConcurrency(기본4/상한16), joinPolicy all|first|quorum, parentSessionId 순환 감지.
13. **컨텍스트 예산 가드** (opencode-swarm): 토큰 회계, plan 압축(~1500tok), 100KB 초과 시 요약.

## 4. 원격 세션 공유·협업 특화 (사용자 요구 축)

14. **MARM 공유 메모리 서버** — 최우선. FastAPI MCP :8001, SQLite WAL, 직렬 쓰기큐(스웜 버스트 안전), FTS→시맨틱 rerank recall(p95 20-31ms), Bearer 인증, --swarm 200RPM 프리셋, 대시보드 :8002. **Tailscale 위에 1대 띄우면 전 fleet 세션이 같은 메모리를 읽고 씀** — 현재 git-파일 memory 동기화의 직접 대체. Apache-2.0, Docker 이미지 존재 → 도입 비용 최소.
15. **optio PA inbox 모델** — 영속 에이전트가 slug 주소 + Postgres inbox 보유, turn마다 inbox drain→실행→halt. 현재 inter-session bus의 휘발성 DM 대비 내구성 있는 메시징. reconciler가 유실 이벤트 자가치유.
16. **swarmclaw 게이트웨이 fleet 제어** — Tailnet 피어를 named gateway로 등록, activate/drain/cordon/restart, 토폴로지 스냅샷(노드·페어링·프레즌스), draining 노드 라우팅 제외. NCO fleet의 노드 관리 UX로 적합.
17. **claudectl Relay + Hive Mind** — 초대코드 join, LAN 발견, HTTP 코디네이터(`GET /api/sessions` 통합 fleet 뷰). 브레인이 결정을 지식(best_practice/technique)으로 증류해 머신 간 전파, 개인 패턴은 로컬 유지 — gbrain과 결합 여지.
18. **agency-swarm 방향성 통신 그래프** — `ceo > dev` 식 "누가 누구에게 위임 개시 가능한지" 허가 행렬. 현재 mesh의 전방위 DM(감독관 사칭·승인 캡처 시도가 실제 발생했던)을 정책 그래프로 제약 가능. `send_message`를 타입드 도구로.
19. **Pydantic 타입 검증 위임 페이로드** (agency-swarm) — 오늘 겪은 `ai` 필드 enum 미검증(Unknown agent가 assigned로 접수되는) 버그의 구조적 해결.

## 5. 이식성 요약

| 소스 | 언어/런타임 | 라이선스 | NCO(Node/TS) 적합도 |
|---|---|---|---|
| optio | TS/Node22, (K8s 결합) | MIT | 높음 — reconciler·상태기계는 K8s 없이 이식 가능 |
| swarmclaw | TS/Node22.6+ | **README에 명시 없음 — 코드 복사 전 확인 필수** | 높음 (패턴 재구현 권장) |
| opencode-swarm | TS/Bun, OpenCode 플러그인 | MIT | 개념 이식 (게이트·락·PRM) |
| claudectl | Rust | MIT | 패턴 이식 (ledger·verifier 설계) |
| MARM | Python, MCP | Apache-2.0 | **그대로 도입 가능** (별도 서비스) |
| fractals | TS/Node | MIT | decompose 패턴 이식 (OpenAI 결합 주의) |
| agency-swarm | Python 3.12 | MIT | 개념 이식 (통신 그래프·타입 검증) |

## 6. 권장 실행 순서
1주차: P0-1 실패분류기 + P0-4 preflight (작음, 즉효) → 2주차: P0-3 cancel/dead-letter + P0-2 상태기계 → 3주차: MARM 파일럿(중앙 1대, Tailscale) + 핸드오프 패킷 표준 → 이후: verifier 게이트, 통신 허가 그래프.

— 이 문서는 감독관(nova-macstudio-claude-1)의 NCO 신뢰성 수정 이니셔티브 입력으로 공유 가능.
