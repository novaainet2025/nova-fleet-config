# gbrain 사용 가이드 — NCO/nova-ax 스택 통합

> 버전: 0.42.51.0 | 최초 설치: 2026-06-18 | 양쪽 OS 동일 조건

---

## 개요

gbrain은 AI 에이전트용 지식 레이어다. 하이브리드 검색(벡터+BM25)과 자가 배선 지식 그래프를 제공하며, Claude Code에 MCP 서버로 등록되어 92개 도구를 통해 즉시 사용 가능하다.

**역할**: nova-ax의 RAGEngine 강화 레이어 + NCO 에이전트 공통 지식 저장소

---

## 바이너리 경로

| OS | gbrain | bun |
|---|---|---|
| WSL/Linux | `/home/nova/.bun/bin/gbrain` | `/home/nova/.nvm/versions/node/v22.22.3/bin/bun` |
| Mac | `/Users/nova-ai/.bun/bin/gbrain` | `/Users/nova-ai/.bun/bin/bun` |

---

## 설치 절차 (공통)

```bash
# 1. bun 설치
npm install -g bun           # WSL/Linux (sudo 없음)
# 또는: brew install bun     # Mac
# 또는: curl -fsSL https://bun.sh/install | bash

# 2. gbrain 설치
~/.bun/bin/bun install -g github:garrytan/gbrain

# 3. 초기화
~/.bun/bin/gbrain init --pglite --no-embedding

# 4. Claude Code MCP 등록
claude mcp add gbrain -- ~/.bun/bin/gbrain serve

# 5. retrieval-reflex 스킬 배포
mkdir -p ~/.claude/skills/retrieval-reflex
cp ~/nova-fleet-config/claude/skills/retrieval-reflex/SKILL.md ~/.claude/skills/retrieval-reflex/

# 6. 상태 확인
~/.bun/bin/gbrain doctor
```

---

## 자동 트리거 (retrieval-reflex)

retrieval-reflex는 Claude가 brain을 **언제** 조회할지 판단하는 정책 스킬이다.  
`~/.claude/skills/retrieval-reflex/SKILL.md`에 위치하며 매 세션 자동 로드된다.

### 트리거 조건 (자동 실행)

| 조건 | 예시 |
|---|---|
| 개체(사람/회사/프로젝트)가 대화의 주제일 때 | "nova-ax가 뭐야?", "NCO 구조 설명해줘" |
| brain 페이지 포인터가 컨텍스트에 주입됐을 때 | 자동 감지 |
| 모르는 이름/용어가 등장했을 때 | 빠른 resolve |
| 비자명한 세부사항을 주장하기 전 | 사실 확인 |

### 트리거 제외 (skip)

- 단순 언급(로직 핑, 단순 열거)
- 이미 컨텍스트에 로드된 개체
- 사소한 세부사항

---

## MCP 도구 목록 (92개 중 핵심)

| 도구 | 용도 |
|---|---|
| `query` | 하이브리드 검색 (BM25+벡터) |
| `think` | 합성 답변 + 인용 + 간격 분석 |
| `get_page` | 특정 brain 페이지 조회 |
| `graph` | 지식 그래프 탐색 |
| `backlinks` | 역링크 조회 |
| `capture` | 신호/메모 저장 |
| `import_source` | 마크다운 디렉터리 인덱싱 |

---

## CLI 명령 (빠른 참조)

```bash
# 검색 (LLM 비용 없음, 즉시)
~/.bun/bin/gbrain search "검색어"

# 합성 답변 (LLM 사용)
~/.bun/bin/gbrain think "질문"

# 마크다운 인덱싱
~/.bun/bin/gbrain import ~/projects/neural-cli-orchestrator/docs/
~/.bun/bin/gbrain import ~/projects/nova-ax/docs/

# 상태 진단
~/.bun/bin/gbrain doctor

# MCP 서버 수동 시작 (보통 불필요 — Claude Code가 자동 시작)
~/.bun/bin/gbrain serve

# 설정 확인
~/.bun/bin/gbrain config list
```

---

## NCO 에이전트별 활용 패턴

| NCO 에이전트 | gbrain 활용 방법 |
|---|---|
| `copilot` (Researcher) | `gbrain search` 로 사전 컨텍스트 조회 후 리서치 |
| `nvidia` (Reasoner) | `gbrain think` 결과를 추론 인풋으로 사용 |
| `cursor-agent` (Reviewer) | `gbrain search` 로 관련 코드/문서 컨텍스트 확인 |
| `opencode` (Architect) | brain에서 아키텍처 결정 이력 조회 |

---

## nova-ax 연동

nova-ax의 `.env`에 추가 (HTTP 모드 사용 시):
```bash
GBRAIN_MCP_URL=http://localhost:6400   # stdio 기본은 불필요
```

nova-ax `src/index.ts` RAGEngine이 현재 내부 구현체 — 향후 gbrain MCP로 교체 가능.

---

## embedding 설정 (선택 — 나중에 추가 가능)

현재 상태: BM25 키워드 검색만 동작 (기능 65/100, 정상 운용 가능)

embedding 활성화 시 벡터+BM25 하이브리드 + 그래프 탐색 활성 (기능 95+/100):
```bash
# OpenAI (추천, 고품질)
export OPENAI_API_KEY=sk-...
~/.bun/bin/gbrain config set embedding_model openai:text-embedding-3-large

# 로컬 Ollama (무료)
~/.bun/bin/gbrain config set embedding_model ollama:nomic-embed-text

# Voyage (고품질 대안)
export VOYAGE_API_KEY=pa-...
~/.bun/bin/gbrain config set embedding_model voyage:voyage-3-large
```

---

## 상태 확인 및 장애 대응

```bash
~/.bun/bin/gbrain doctor              # 전체 상태 (정상: 65+/100)
~/.bun/bin/gbrain config list         # 현재 설정
claude mcp list                       # MCP 연결 확인 (✔ Connected)
ls ~/.gbrain/                         # brain DB 파일 확인
```

**brain DB 위치**: `~/.gbrain/brain.pglite`  
**MCP 등록 위치**: `~/.claude.json` (project-scope)

---

## 자동 PATH 설정 (선택)

매 세션 자동으로 gbrain을 사용하려면 `~/.zshrc` 또는 `~/.bashrc`에 추가:
```bash
export PATH="$HOME/.bun/bin:$PATH"
```

---

## 버전 이력

| 날짜 | 버전 | 변경 |
|---|---|---|
| 2026-06-18 | 0.42.51.0 | 최초 설치 — WSL + Mac 동시 설치, retrieval-reflex 설정 |
