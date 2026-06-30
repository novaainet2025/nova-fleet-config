# 오류 패턴 라이브러리 — Nova Fleet

> 자동 축적: brain-capture.sh 실행 시 추가됨  
> 패턴 임계값: 2회 이상 동일 패턴 → rules/error-prevention.md 자동 승격  
> 마지막 갱신: 2026-06-30

---

## 패턴 목록

### ERR-001 | inter-session 이름 오결정
- **발생**: 2026-06-30 세션 시작 시 nova-macstudio-claude-1 오설정
- **근본 원인**: NCO_NAME=cli 확인 없이 추측으로 이름 결정
- **결과**: fleet-sync.sh COORDINATOR 오설정, broadcast 실패
- **방지**: `/tmp/nco-names/` 파일 먼저 읽기 → NCO_NAME 확정 후 connect
- **등급**: T1 (git commit 5a78479로 수정 확인)
- **발생 횟수**: 1

### ERR-002 | T4 응답을 T1 완료로 착각
- **발생**: mesh autoresponder 응답 → 작업 완료로 오판
- **근본 원인**: T4(LLM 자연어)와 T1(Ground Truth)의 혼동
- **결과**: 미완료 작업을 완료로 보고
- **방지**: autoresponder 응답은 "응답 수신됨"까지만, T1 별도 확인 필수
- **발생 횟수**: 2

### ERR-003 | panLimited 능동 홀드
- **발생**: Insta360 카메라 제어 작업
- **근본 원인**: 매 틱 setPanTilt 재전송 → 카메라 영구 정지
- **방지**: 쿨다운 후 1회 복귀 패턴 고정
- **발생 횟수**: 1

### ERR-004 | UTC 타임존 미처리
- **발생**: SQLite UTC → JS 표시 시 Z 누락
- **근본 원인**: `slice(11,16)` 직접 파싱 → KST 오표시
- **방지**: `new Date(val + 'Z')` 패턴 강제
- **발생 횟수**: 1

### ERR-005 | Aider 제거 불완전 (레이어 누락)
- **발생**: Aider 제거 작업 시 일부 레이어 누락
- **근본 원인**: providers.list 제거 후 소스/테스트/문서 레이어 미확인
- **방지**: 도구 제거 체크리스트: providers.list → config JSON → source → test → docs → scripts
- **발생 횟수**: 1 (2026-06-30, 총 15파일 수정으로 완료)

### ERR-006 | Mesh DM 자체 결정
- **발생**: 발송측 요청에 모호한 항목 있을 때 자체 판단으로 진행
- **근본 원인**: 대화 흐름을 끊지 않으려는 경향
- **방지**: 모호 항목 탐지 → question: 회신 → 답변 후 진행
- **발생 횟수**: 복수

---

## 신규 패턴 추가 방법

```bash
bash ~/nova-fleet-config/brain/scripts/brain-capture.sh \
  --id ERR-XXX \
  --summary "오류 요약" \
  --cause "근본 원인" \
  --fix "방지책"
```

### ERR-007 | fleet-sync dirty-tree pull-failed
- **발생**: 2026-06-30 10:32 (snt-claude-4 발견)
- **근본 원인**: git pull --ff-only 전 stash 없음 → 로컬 미커밋 변경 22개로 매 sync pull abort
- **방지**: pull 전 git stash push --include-untracked, pop 후 충돌 시 theirs 자동 채택
- **발생 횟수**: 1

### ERR-008 | 동일 Mac에서 두 CC 세션이 같은 statusline 이름(claude-1) 표시
- **발생**: 2026-06-30 11:10 (nova-macstudio-claude-1)
- **근본 원인**: user-prompt-nco-context.sh가 NCO_NAME 환경변수 비어있을 때만 PID 파일 조회 → Warp 터미널에서 NCO_NAME=claude-1 상속된 세션 2는 블록 전체 스킵, claude-2.pid 미생성
- **방지**: ALWAYS check PID file first (PID match > inherited env). 충돌 감지 시 다음 번호 자동 할당. user-prompt-nco-context.sh 25-35행 교체. nova-fleet-config commit으로 전 세션 배포
- **발생 횟수**: 1
