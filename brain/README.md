# Nova Brain — 크로스 디바이스 공유 지식 베이스

**목적**: 모든 Fleet 세션(Mac·Windows·WSL)이 동일한 규칙·기억·오류패턴을 공유한다.  
**동기화**: `nova-fleet-config` git repo를 통해 `fleet-sync.sh` 실행 시 자동 적용.  
**Obsidian**: Mac에서는 `~/obsidian/mac-obsidian/` 볼트로 자동 연동.

## 구조

```
brain/
├── rules/          — 공유 규칙 (전 세션 적용)
│   ├── core.md     — 핵심 절대 규칙 (T1 강제화 등)
│   ├── error-prevention.md — 오류 방지 패턴
│   └── verification.md    — 검증 프로토콜
├── memory/         — 공유 피드백·학습 메모리
│   └── shared-feedback.md — 전 세션 공유 피드백
├── errors/         — 오류 패턴 라이브러리 (자동 축적)
│   └── patterns.md
├── improvements/   — 자가 개선 이력
│   └── log.md
├── sessions/       — 세션 작업 로그
└── scripts/        — 운영 스크립트
    ├── brain-capture.sh     — 오류 캡처 → brain/ 기록
    ├── brain-to-memory.sh   — brain/ → ~/.claude/memory/ 동기화
    ├── self-assess.sh       — 자가 개선 평가
    └── obsidian-bridge.sh   — (Mac only) Obsidian 볼트 ↔ brain/ 연동
```

## 동작 원리

```
[오류 발생] → brain-capture.sh → brain/errors/patterns.md
                                      ↓
                              패턴 임계값 초과
                                      ↓
                        brain/rules/error-prevention.md 업데이트
                                      ↓
                          fleet-sync.sh git push
                                      ↓
             [전 세션] fleet-sync.sh pull → brain-to-memory.sh 실행
                                      ↓
                        ~/.claude/memory/ 자동 업데이트
```
