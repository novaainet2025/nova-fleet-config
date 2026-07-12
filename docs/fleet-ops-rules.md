# 플릿 운영 절대규칙 v1 (2026-07-02)

> 근거: nova-macstudio 세션에서 T1 실측으로 확인된 장애 패턴들.
> 요약본은 Obsidian `00-SYSTEM/MASTER-CONTEXT.md`(전 세션 자동 주입)에 있음.

## ① 프로세스 위생
- 상주 서비스(nco-backend, nova-ax, mlx-server, bridge, dashboard)는 **PM2 단일 감독** 하에서만 실행한다.
- TS 서비스는 `npm run build` 후 **dist 실행** (tsx+cluster 조합 금지 — ERR_MODULE_NOT_FOUND 크래시 루프).
- `nohup`/`&` 고아 spawn 금지. 고아가 포트를 선점하면 PM2가 EADDRINUSE 무한 재시작에 빠진다 (실측: 252회).
- 점검: `pm2 list`의 PID = `lsof -i :PORT`의 PID 일치 확인.

## ② 프로바이더 정합성
- **헬스체크 URL = 실추론 URL**. 다르면 "online인데 전부 타임아웃" 착시 발생 (실측: ollama successRate 0%).
- endpoint는 머신별로: Mac은 `127.0.0.1:11434`, WSL은 Windows 게이트웨이. env 우선 구조 유지.
- 쿼터/자격증명 상태를 안다: cursor-agent(월한도), openrouter(무료 일일한도), copilot(월한도), agy(OAuth 만료 시 재로그인).
- 로컬 2축(ollama, mlx)은 항상 웜 상태로 유지 — 쿼터 0 예비군.

## ③ 통신 프로토콜
- **기계 요청(fleet-status-request 등)에 LLM이 응답하지 않는다** — autoresponder에 코드 즉답 핸들러를 둔다
  (수신 text가 `fleet-status-request` 시작 → `localhost:6200/api/agents` fetch → `status: {JSON}` 회신, 60초 1회 가드).
- 브로드캐스트는 서버측 쿨다운 90초 (다중 탭이 열려도 1회만).
- `done:`/`status:`/`error:`/`ack:` 접두사 메시지는 **절대 태스크로 재변환하지 않는다** (echo 루프·쿼터 소진).

## ④ 상태 데이터 신뢰성
- 원격 상태는 각 호스트 NCO가 중앙으로 **push**: `.env`에 `FLEET_CENTRAL_URL=http://<중앙>:6200` 설정 시
  60초마다 `POST /api/fleet/report` 자동 발신 (nco `src/server/routes/fleet-ops.ts`).
  - **(2026-07-12) 온보딩 자동화**: `install/bootstrap.sh`가 `.env` 생성 후 self-guard로
    `FLEET_CENTRAL_URL=http://100.88.88.69:6200`(중앙 tailscale)을 자동 기록한다. 자기 IP가
    중앙이면 미기록, 이미 있으면 유지. `.env` 자체는 여전히 git 비추적(값만 온보딩이 write).
    → **새 원격 기기는 온보딩(또는 `bootstrap.sh --update`)만으로 프로바이더 노드가 자동 생성**된다.
    기존 기기는 `bash ~/nova-fleet-config/install/bootstrap.sh --update` 1회로 소급 적용.
- 3분 초과 stale 데이터는 대시보드가 `⏱Nm` 표시하고 working을 신뢰하지 않는다.
- 원격/타세션 완료 주장은 T1 증거 필수. T4(LLM 자연어)는 참고만.

## ④-1 작업상태 보고 의무 (절대, 2026-07-10 사용자 지시)
- **로컬·원격 불문 모든 세션은 작업을 수행하면 반드시 인터세션 호스트(중앙 코디네이터)에 작업 상태를 전송한다.**
- **자동 경로(기본)**: tool-activity-reporter 훅 활성 + 로컬 NCO 가동 + (원격이면) nco ≥712219b
  pull로 fleet report `sessions[]` 자동 동봉. 이 조건이 갖춰진 세션은 별도 행동 불필요 — 훅이 이행한다.
- fleet-sync/apply는 `~/.claude/settings.json`의 `hooks.PreToolUse`/`hooks.PostToolUse`에 tool-activity-reporter 등록을 자동 보장한다.
- **수동 경로(자동 불가 시 의무)**: 훅/NCO/신버전 미비 세션은 작업 시작 시
  `status: working — <한 줄 요약>`, 완료 시 `done: <결과 요약>`을 IS로 중앙에 발신한다.
- 세션 시작 시 자기 점검: `curl -s localhost:6200/api/activity`에 자기 세션명이 도구 사용 후 나타나면
  자동 경로 정상. 안 나타나면 수동 경로로 전환하고 훅/NCO 상태를 점검·보고한다.
- 보고 없는 장시간 작업은 대시보드에서 idle로 간주된다 — "작업했는데 안 보임"은 이 규칙 위반의 결과다.

## ⑤ 병렬 오케스트레이션
- 독립 작업은 병렬 위임. 단발 소작업은 직접 (오버헤드 실측 +2.1s/task).
- 파일 편집 전 lease: PreToolUse 훅이 `POST :6200/api/lease {file, session, ttlSec:30}` 자동 수행.
  다른 세션 보유 시 permissionDecision=ask로 사용자 확인.

## ⑥ 완결성 루프
- 구현 → **다른 모델** 교차 리뷰 → Gap 분석 → T1 검증(HTTP 본문/DB row/DOM) → 미달 시 재지시 (최대 5회).
- "exit 0"·"전송됨"·에이전트 자기보고는 완료 증거가 아니다.
- 보고에는 검증 영수증([변경]/[검증방법]/[등급]/[Gap]/[미검증항목]) 필수.

## ⑦ 코드 배포 절차 (git, 2026-07-02 추가 — snt 머지충돌 사건 재발 방지)

**원칙: 공유 저장소에는 코드와 중립 기본값만. 머신별 정책은 비추적 오버레이에.**

| 구분 | 파일 | git |
|---|---|---|
| 코드·중립 기본값 (SSOT) | src/*, config/ai-providers.json | 추적 (main 단일 브랜치) |
| 머신 정책 (enable/endpoint/모델) | config/ai-providers.local.json | **비추적** (.gitignore) |
| 머신 환경값 (URL·키·FLEET_CENTRAL_URL) | .env | **비추적** |

**풀 절차 (모든 머신 공통):**
1. `git pull --ff-only` — 항상 fast-forward만. 충돌이 났다는 것 자체가 tracked 파일을 로컬 수정했다는 신호.
2. 충돌 시 복구 절차: 로컬 수정분을 `ai-providers.local.json`/`.env`로 옮기고
   `git checkout -- <파일>` → `git pull --ff-only` 재시도. **tracked 파일 로컬 수정 금지.**
3. `npm run build` → pm2 재시작 → `/health` 확인.

**푸시 절차:**
- 푸시 전 `git diff --stat`에서 ai-providers.json 변경이 있으면 자문: "이 값이 모든 머신에서 참인가?"
  아니면 local overlay로 이동. 예/아니오 판단이 안 서면 question:으로 발신측에 확인.
- 커밋 메시지에 영향 범위 명시 (예: "requires rebuild", "config-neutral").

**플랫폼 구분 (Mac/WSL/Linux):**
- 코드가 자동 감지: `detectPlatform()` (darwin/wsl/linux, WSL은 /proc/version microsoft 마커).
- 프로바이더에 `"platforms": ["wsl","linux"]` 지정 시 타 플랫폼에서 자동 비활성.
- Ollama 주소: .env의 OLLAMA_BASE_URL/OLLAMA_HOST가 최우선 (Mac은 127.0.0.1, WSL은 Windows 게이트웨이).
