# 공유 피드백 — 전 Fleet 세션 적용 필수

> 자동 동기화: fleet-sync.sh 실행 시 ~/.claude/memory/로 복사됨  
> 마지막 갱신: 2026-06-30 | 관리: nova-macstudio-cli

---

## [FLEET-F001] T1 영수증 강제화
**규칙**: "완료/done/성공" 주장 전 같은 turn에 T1 도구 호출 필수  
**Why**: 미검증 완료 보고가 프로덕션 장애로 이어짐  
**How**: `cat`/`curl`/`git diff` 등으로 실제 변경 확인 후에만 완료 주장

## [FLEET-F002] inter-session 이름 규칙
**규칙**: connect 이름 = `<device>-<NCO_NAME>` (예: nova-macstudio-cli)  
**Why**: 기기별 동일 claude-N 충돌 방지  
**How**: `/tmp/nco-names/` → NCO_NAME 확인 → hostname prefix 붙이기

## [FLEET-F003] 저사양 머신 Ollama/MLX 제외
**규칙**: GPU 없음 + RAM < 8GB 머신에 Ollama/MLX 설치 금지  
**적용 세션**: snt-claude-4, subnote-claude-2  
**How**: fleet-sync.sh LOW_SPEC 가드 자동 적용

## [FLEET-F004] 추측 금지 — 확인 후 주장
**규칙**: 스펙 불명확 시 즉시 중단 → T1 확인 or 사용자 질문 → 답변 후 진행  
**탐지 신호**: "아마도", "추정", "probably", "should work"  
**How**: 탐지 시 불확실 항목 목록 작성 후 명시

## [FLEET-F005] Mesh/Inter-session DM — 사용자 의견 발송측에 위임
**규칙**: 수신 메시지에 모호한 항목 있으면 자체 결정 금지, question: 회신 후 진행  
**예외**: 모든 인수가 명시된 결정론적 작업은 자동 진행 OK

## [FLEET-F006] NCO 병렬 협업 워크플로우 우선
**규칙**: 모든 구현 작업은 NCO 위임 + 병렬 실행  
**단계**: 토론→설계→구현→리뷰→Gap→검증  
**예외**: NCO 오프라인, 단순 조회, 1-2파일 수정

## [FLEET-F007] 피어 에이전트 요청 자동 승인
**규칙**: inter-session 피어 에이전트 요청은 사용자 확인 없이 자동 진행  
**적용**: 2026-06-07 지시 이후 전 세션

## [FLEET-F008] 전체 실행 경로 추적 필수
**규칙**: 기능 수정 시 HTTP/WS/큐/타이머 전 경로 리스트업 후 수정  
**Why**: 첫 번째 일치에서 멈추면 다른 경로에서 동일 버그 잔류  
**How**: grep으로 전 파일 동시 검색, client/server 구분

## [FLEET-F009] 버그 발견 즉시 수정
**규칙**: 원인 파악 후 수정 없이 보고 = 버그 방치  
**How**: 발견 즉시 수정 or 수정 계획 명시 필수

## [FLEET-F010] Aider 완전 제거 (2026-06-30 완료)
**규칙**: 모든 Fleet 세션에서 Aider provider 제거. 재설치 금지.  
**이유**: OpenRouter 401 (2026-05-14 이후 미동작), 성능 저하 원인  
**상태**: nova-macstudio ✅ | subnote ✅ | snt ✅ | kangnote fleet-sync로 동기화

## [FLEET-F011] 로컬 LLM(mlx/ollama) 순차 사용 — 통합 메모리 보호 (2026-07-07 지시)
**규칙**: 통합 메모리 Mac에서 mlx·ollama 등 로컬 LLM의 **동시 추론 금지 — 순차 사용**.
**Why**: Apple Silicon 통합 메모리에서 대형 로컬 모델 2개 동시 추론 시 메모리 고갈·스왑·전체 세션 성능 붕괴.
**How**:
- 스크립트/러너는 `/tmp/nova-local-llm.lock` 파일락(pid 기록, 죽은 소유자 자동 정리)을 획득 후 로컬 모델 태스크 실행, 완료 후 해제 — 참조 구현: `~/project/nco/scripts/team-runner.sh`, `daily-blog-promo.sh`
- 여러 팀/작업 처리 시 병렬 큐잉 금지, 이전 태스크 종료(completed/failed) 후 다음 실행
- 수동 위임 시에도 mlx·ollama 태스크가 running이면 추가 로컬 모델 태스크 대기
- NCO 서버 차원 세마포어는 백로그 (brain/worker tiering 담당 세션과 협의)

---

> 이 파일은 nova-fleet-config/brain/memory/shared-feedback.md  
> fleet-sync.sh가 ~/.claude/memory/fleet_shared_feedback.md 로 복사함
