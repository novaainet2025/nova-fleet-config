# CLAUDE-reference.md — 상세 참조 (동적 로드)

> 이 파일은 세션에 자동 로드되지 않는다. `CLAUDE.md`에서 포인터로 참조하며,
> 해당 작업이 실제로 필요할 때만 `Read`로 열어 사용한다. (컨텍스트 절감 목적)

---

## R1. gbrain — 지식그래프 + 하이브리드 검색 MCP (전체 가이드)

gbrain은 AI 에이전트용 지식 레이어다. Claude Code MCP로 등록 후 `gbrain search`/`gbrain think`를 사용한다. NCO·nova-ax와 독립 동작하며 nova-ax의 RAGEngine을 강화한다.
> 원본 가이드: `~/nova-fleet-config/docs/gbrain-guide.md`

### 자동 트리거 (retrieval-reflex)
`~/.claude/skills/retrieval-reflex/SKILL.md`에 위치, 매 세션 자동 로드. `apply.sh` 실행 시 `nova-fleet-config/claude/skills/retrieval-reflex/` → `~/.claude/skills/` 배포.

brain 조회 조건: (1) 개체(사람/회사/프로젝트/장소)가 주제일 때 `get_page <slug>` (2) brain 포인터 주입 시 즉시 open (3) 모르는 이름/용어 등장 시 `query` resolve (4) 비자명 세부 주장 전 사실 확인.
skip: 단순 언급·이미 로드된 개체·사소한 세부.

### 설치 (WSL/Linux + Mac 동일)
```bash
npm install -g bun                                   # 또는 curl -fsSL https://bun.sh/install | bash  /  brew install bun
~/.bun/bin/bun install -g github:garrytan/gbrain
~/.bun/bin/gbrain init --pglite --no-embedding       # embedding 있으면: --embedding-model openai:text-embedding-3-large
claude mcp add gbrain -- ~/.bun/bin/gbrain serve
~/.bun/bin/gbrain doctor
```
바이너리: WSL/Linux `/home/nova/.bun/bin/gbrain` · Mac `/Users/nova-ai/.bun/bin/gbrain`

### 명령
| 명령 | 용도 |
|---|---|
| `gbrain search <쿼리>` | 하이브리드 검색 (LLM 비용 없음) |
| `gbrain think <질문>` | 합성 답변 + 인용 + 간격 분석 (LLM) |
| `gbrain import <디렉터리>` | 마크다운 인덱싱 |
| `gbrain capture <텍스트>` | 신호 포착 |
| `gbrain doctor` | 상태 진단 |
| `gbrain serve` / `serve --http` | MCP 서버 (stdio / HTTP, 포트 6200·6300 제외) |

에이전트 역할: copilot=`gbrain search` 사전 컨텍스트 · nvidia=`gbrain think` 추론 인풋 · cursor-agent=`gbrain search` 코드 컨텍스트.
nova-ax 연동: `.env`에 `GBRAIN_MCP_URL=stdio` (HTTP 모드면 `http://localhost:<포트>`).
embedding(선택): `gbrain config set embedding_model openai:text-embedding-3-large` 또는 로컬 `ollama:nomic-embed-text`. 미설정 시 BM25 키워드 검색만(정상 운영 가능).

---

## R2. inter-session 이름 산출 bash (BOOTSTRAP 자동화 상세)

`/inter-session connect` 호출 시 이름을 추측하지 말고 아래 순서로 결정 (이미 `~/.claude/hooks/user-prompt-nco-context.sh`의 BOOTSTRAP 블록에 구현됨 — 새 세션은 자동 `<device>-claude-N`로 connect):

```bash
# 1) statusline NCO 이름(claude-N): 최근 user-prompt-hook의 [NCO:claude-N] 토큰 또는 /tmp/nco-names 매칭
my_pid=$(ck=$$; for _ in 1 2 3 4 5; do ck=$(ps -o ppid= -p "$ck" | tr -d ' '); cm=$(ps -o comm= -p "$ck"); echo "$cm" | grep -qE '^(claude|node)$' && echo "$ck" && break; done)
MY_NAME=$(for pf in /tmp/nco-names/claude-*.pid; do [ "$(cat "$pf")" = "$my_pid" ] && basename "$pf" .pid && break; done)
# 2) Claude Code 세션은 라벨 치환 없음 — claude-N 그대로
_ISLABEL="${MY_NAME}"
# 3) 디바이스 prefix (소문자·비[a-z0-9]→'-'·.local제거·40자cap)
_ISDEV=$(hostname 2>/dev/null | tr '[:upper:]' '[:lower:]' | sed -E 's/\.local$//; s/[^a-z0-9]+/-/g; s/^-+//; s/-+$//'); [ -z "$_ISDEV" ] && _ISDEV="dev"
_ISSUF="-${_ISLABEL}"; _ISDEV="${_ISDEV:0:$((40-${#_ISSUF}))}"; _ISDEV="${_ISDEV%-}"
ISNAME="${_ISDEV}${_ISSUF}"   # → /inter-session connect "$ISNAME"  (예: nova-macstudio-claude-2)
```

기존 monitor가 다른 이름으로 떠 있으면 → kill listener_pid → 1.5s 대기 → `--name <device>-claude-N` 재spawn. (`<device>-nova-N`은 nova-cli 세션 정상 이름이므로 건드리지 않음.)
구분자는 하이픈(`-`) — `NAME_RE=^[a-z0-9][a-z0-9-]{0,39}$`가 언더스코어 거부(T1 shared.py:61). NCO/mesh 내부 이름(`NCO_NAME`)은 `claude-N` 그대로.
금지: cwd/주제 기반 임의 이름(`nco-commander` 등). 상세 근거 [[feedback_inter_session_name]]

---

## R3. Mesh 프롬프트 주입 — 자동화 상세

idle Claude 세션이 mesh DM을 자동 수신하려면 **Monitor 도구로 spawn한 poller**가 필수(데몬 모드는 stdout이 queue.log로만 가 conversation에 닿지 못함).

1. **canonical**: `mesh-receiver` 플러그인 `monitors.json`은 `when: "on-skill-invoke:mesh-receiver"`(lazy)만 허용. `when:"always"`(데몬) 금지 — 회귀 시 `mesh-plugin-guard.sh` 자동 복원.
2. **SessionStart 3단계**: (a) `cleanup_dead_pollers` 좀비 정리 (b) 데몬 poller spawn 비활성(`NCO_DISABLE_MESH_DAEMON=1`) (c) `/tmp/nco-bootstrap-<sid>` flag.
3. **LLM 자가 기동(필수)**: 첫 user prompt에 `[BOOTSTRAP]` 라벨 → 어떤 작업보다 먼저 Monitor로 mesh-inbox-poller spawn (`INTER_MODE=monitor NCO_NAME=<n> NCO_SESSION_ID=<s>`, `persistent=true`, `timeout_ms=3600000`).
4. **autoresponder yield**: Monitor poller가 `monitor.lock` 생성 시 `mesh-auto-responder.js`가 yield. 봇 자연어(T4)를 실작업 완료로 착각 말 것.
5. **3-tier 좀비 정리**: SessionStart 즉시 + 30분+ idle poller는 mesh-list 무시 + (선택) cron 6h. `/tmp/nco-names/claude-*.pid` 매핑 우선 확인(현재 활성 세션 디렉터리 보호).

### 세션 시작 자동활성 (BOOTSTRAP)
UserPromptSubmit additionalContext에 `[BOOTSTRAP]` 있으면 첫 응답 전 1회:
1. `/inter-session connect` (name=`<device>-claude-N`, BOOTSTRAP 라벨이 명시)
2. mesh-receiver Monitor:
```
Monitor(command="INTER_MODE=monitor NCO_NAME=<claude-N> NCO_SESSION_ID=<sid> bash $HOME/.claude/hooks/mesh-inbox-poller.sh <sid> <claude-N> 5",
        description="mesh DM watcher", persistent=true, timeout_ms=3600000)
```
둘 다 idempotent. `[BOOTSTRAP]` 없으면 추가 invoke 불필요.

---

## R4. NCO 서버 / Ollama / 프록시

- NCO health: `curl -s http://localhost:6200/health` — 오프라인 시 직접 처리 후 알림
- Ollama 접근: WSL → `host.docker.internal:11434` (Windows Ollama)
- 프록시: `security-kb/anthropic-ollama-proxy.py` (포트 4100)

---

## R5. 지시 구조 / 세션 노트

지시 구조: [컨텍스트] [목표] [제약] [출력형식] [검증기준]

| 노트 | 위치 | 생성 시점 |
|---|---|---|
| 맥락노트 | `~/projects/context_note.md` | Stop 시 자동 |
| 개선노트 | `~/.claude/improvements/` | Stop 시 자동 (의미있는 작업만) |
| 생성기 | `~/projects/security-kb/note-generator.sh` | Ollama 우선 |
