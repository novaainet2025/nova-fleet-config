> 검토 메모 (kangnote-claude-1 Commander, 2026-07-03): copilot 초안을 검토·보정함.
> 보정: 허구의 NCO 코드 경로 제거(개념 서술로 대체), MCP 등록 명령을 실측 방식으로 교체,
> 미확인 플래그 (미확인) 표기, Slack→mesh 알림, 머신 수 실제화, 대시보드 바인딩 정합.
> 이 문서는 제안서이며 실행은 감독관·사용자 승인 후.

# MARM 중앙 배치 제안서

**대상**: 감독관(nova-macstudio-claude-2), nova fleet 관리자  
**작성 근거**: MARM MCP 서버 v2.15.2 파일럿 T1 검증 완료  
**제출 일시**: 2026-07-03

---

## 1. 현황 및 문제

### 현재 메모리 아키텍처
- **메커니즘**: 여러 머신(kangNote·nova-macstudio·newkangpc 등)의 claude-code 세션들이 `nova-fleet-config` git repo 파일로 세션 간 상태 공유
- **장점**: 분산, 트랜잭션 이력(commit log)
- **한계**:
  1. Pull 타이밍에 의존 → 실시간성 부족(분 단위 지연)
  2. 동시 push 충돌 해결 수동 개입 필요
  3. 검색 기능 없음(grep 의존)
  4. 대규모 메모리(>100MB)는 git 관리 부담

### MARM 파일럿 결과
**검증 근거**(kangNote 세션):
- SQLite WAL + 직렬 쓰기큐 → swarm burst safe ✓
- MCP /health: database connected, semantic_search available ✓
- FTS→시맨틱 rerank: p95 20-31ms ✓
- Docker image + pip venv 설치 모두 동작 ✓

---

## 2. 제안 아키텍처

### 토폴로지
```
nova-macstudio (100.88.88.69:8001)
  ├─ MARM MCP Server [persistent, Tailscale bind]
  ├─ SQLite WAL DB + Dashboard (:8002)
  └─ MARM_API_KEY (Bearer auth)

각 워크스테이션 세션들
  ├─ session-A → MCP HTTP [Tailscale] → :8001
  ├─ session-B → MCP HTTP [Tailscale] → :8001
  └─ ...
```

### 배포 방법 (우선순위)

#### Option A: Docker (권장)
```bash
# nova-macstudio에서 실행
docker run -d \
  --name marm-mcp \
  -p 100.88.88.69:8001:8001 \
  -p 127.0.0.1:8002:8002 \
  -v /var/lib/marm:/data \
  -e MARM_API_KEY="$(openssl rand -hex 32)" \
  -e MARM_SWARM_MODE=200 \  # (미확인 — 실제 프리셋은 CLI --swarm 플래그일 수 있음)
  lyellr88/marm-mcp-server:latest
```

#### Option B: pip venv (폴백)
```bash
python3 -m venv /opt/marm-env
source /opt/marm-env/bin/activate
pip install marm-mcp-server==2.15.2
marm-mcp-server \  # (미확인) --bind/--port 플래그명 — kangNote 파일럿은 기본 127.0.0.1:8001 + env MARM_API_KEY로 기동함
  --db-path /var/lib/marm/marm.db \
  --api-key "$(openssl rand -hex 32)"
```

### 인증키 배포 (금지 사항 ✓)
- **금지**: `nova-fleet-config` repo에 커밋 X
- **권장**:
  1. nova-macstudio에서 `.env.marm` 로컬 생성 (root only)
  2. 각 워크스테이션 `.env` 파일 수동 배포 또는 1password/Vault
  3. sessionhook에서 읽기: `MARM_API_KEY=$(cat ~/.env | grep MARM_API_KEY)`

---

## 3. 세션 연동

### MCP 클라이언트 설정 (각 워크스테이션)
```bash
# HTTP transport로 등록 (kangNote 파일럿에서 MCP initialize 200 OK 확인한 방식)
claude mcp add --transport http marm-central http://100.88.88.69:8001/mcp \
  --header "Authorization: Bearer $MARM_API_KEY"
```

### NCO 에이전트 통합 (개념 — 코드 미구현)
NCO 에이전트는 MCP 클라이언트가 아니므로 직접 연동하려면 별도 브리지가 필요하다.
현실적 경로: 각 Claude 세션이 MARM MCP 도구를 쓰고, NCO 위임 프롬프트에 recall 결과를 주입하는 방식(현행 vector-memory 주입과 동일 패턴). NCO 백엔드에 MARM HTTP 클라이언트를 넣는 것은 Phase C 이후 별도 결정.

---

## 4. 운영

### 백업
```bash
# 매주 일요일 03:00 (cron)
0 3 * * 0 cp /var/lib/marm/marm.db /backup/marm-$(date +\%Y\%m\%d).db
0 3 * * 0 tar -czf /backup/marm-config-$(date +\%Y\%m\%d).tar.gz /etc/marm/
```

### 장애 폴백
- **MARM 다운 시**: git 파일 메모리 병행 유지 (최소 3개월)
- **복구 SLA**: 4시간 내 복구 목표
- **헬스 체크**: `/health` 1분 간격 polling → mesh broadcast 알림

### 모니터링
```bash
# healthcheck endpoint (매 1분)
curl -H "Authorization: Bearer $MARM_API_KEY" \
  http://100.88.88.69:8001/health \
  | jq '.status, .database, .semantic_search'
```

**대시보드**: macstudio 로컬 http://127.0.0.1:8002 (위 Docker 바인딩 기준 — 원격 접근 필요 시 바인딩 변경 결정 필요)

---

## 5. 리스크 및 완화

| 리스크 | 영향도 | 완화 방법 |
|--------|--------|----------|
| 단일 장애점 (nova-macstudio 다운) | 높음 | git 병행, 자동 폴백, 재해복구 절차 |
| 크로스머신 메모리 노출 | 중간 | TLS 추가(미확인), Tailscale ACL 강화 |
| 인증키 탈취 | 높음 | 1password 저장, 6개월 순환, audit log |
| 스웜 버스트(600RPM) 초과 | 낮음 | rate limiter built-in, 429 fallback |
| 민감정보 저장 | 높음 | 정책: 세션 토큰·API 키 저장 금지 |

---

## 6. 단계 도입

### Phase A: 파일럿 (1주)
**목표**: 중앙 설치 + 2세션 연동 검증  
**성공 기준**:
- [ ] MARM 48h 무중단 가동
- [ ] session-A, session-B MCP 쿼리 성공 (p95 <50ms)
- [ ] 검색 정확도 baseline 기록
- [ ] 백업 cron 실행 확인

**담당**: nova-macstudio-claude-2 (설치), 파일럿 세션 2개

### Phase B: 전체 연동 (1주)
**목표**: 전 활성 세션 연결  
**성공 기준**:
- [ ] 전 활성 세션 MCP 핸드셰이크 성공
- [ ] 예측 가능한 지연 (<100ms p95)
- [ ] 동시 쿼리 안정성 (10x 스트레스 테스트)
- [ ] 운영 문서 완성

### Phase C: Git 메모리 아카이브 (2주)
**목표**: nova-fleet-config → archive branch로 전환  
**성공 기준**:
- [ ] MARM에 모든 주요 메모리 마이그레이션 완료
- [ ] Audit log에서 30일간 git pull 0회 확인
- [ ] 재해 복구 절차 테스트 완료

---

## 7. 결정 필요 사항 체크리스트

**감독관(nova-macstudio-claude-2)에게**:
- [ ] MARM 중앙 배치 승인 (Docker vs pip 선택)
- [ ] nova-macstudio의 24/7 가동 보장 가능 여부
- [ ] Tailscale ACL 정책 업데이트 (MCP port 8001 all ↔ marm)
- [ ] 민감정보 저장 정책 문서화

**nova fleet 사용자(전체)에게**:
- [ ] Phase A 파일럿 세션 자원봉사 (2개 세션)
- [ ] git 메모리 병행 운영 기간(최소 3개월) 동의
- [ ] 장애 폴백 SOP 리뷰

---

## 첨부: 즉시 실행 명령어

```bash
# 1. nova-macstudio 준비 (root)
ssh nova-macstudio
mkdir -p /var/lib/marm /backup

# 2. Docker 배포
MARM_KEY=$(openssl rand -hex 32)
echo "MARM_API_KEY=$MARM_KEY" > /root/.env.marm
docker run -d --name marm-mcp \
  -p 100.88.88.69:8001:8001 -p 127.0.0.1:8002:8002 \
  -v /var/lib/marm:/data \
  -e "MARM_API_KEY=$MARM_KEY" \
  lyellr88/marm-mcp-server:latest

# 3. 헬스 체크
curl -H "Authorization: Bearer $MARM_KEY" \
  http://100.88.88.69:8001/health

# 4. 파일럿 세션에서
claude mcp add marm-central http://100.88.88.69:8001 \
  --header "Authorization: Bearer $(cat ~/.env | grep MARM_API_KEY | cut -d= -f2)"
```

---

**상태**: 감독관·사용자 승인 대기  
**미확인 사항**: TLS/mTLS 요구사항, 1password 통합 가능성, existing git 메모리 마이그레이션 비용  
**다음 단계**: Phase A 파일럿 세션 선정 → 설치 스크립트 작성