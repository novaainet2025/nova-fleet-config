# Obsidian 연결 방법

이 `brain/` 디렉터리를 Obsidian vault로 열면 에이전트가 쓴 지식을 GUI로 열람할 수 있습니다.

## 연결 절차

1. Obsidian 실행 → "Open folder as vault"
2. `~/nova-fleet-config/brain/` 선택
3. 완료 — 에이전트가 brain-capture.sh로 추가한 패턴/피드백이 실시간 반영됨

## 파일 구조

| 파일 | 내용 |
|---|---|
| `errors/patterns.md` | 오류 패턴 라이브러리 (에이전트 자동 축적) |
| `memory/shared-feedback.md` | 크로스 디바이스 피드백 규칙 |
| `improvements/log.md` | 자가 개선 이력 및 메트릭 |
| `rules/` | 자동 승격된 방지 규칙 |

## 역할 분리

- **사용자** → Obsidian GUI로 읽기·주석
- **에이전트** → 파일 직접 쓰기 (brain-capture.sh / fleet-sync)
- **gbrain** → MCP를 통해 검색 API 제공

## git sync

`brain/`은 nova-fleet-config의 일부로 git-sync됨.  
에이전트가 push하면 모든 디바이스에서 `git pull`로 최신 지식 수신.
