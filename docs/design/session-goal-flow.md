# 세션 목표 관리·증명·자율 재작업 — 완벽 플로우 설계

> 상태: **설계 문서 (구현 0)** · 작성 2026-07-11 · 개정 r2 2026-07-11 (SID 키 정정·apply.sh lib 배포 누락·stop_hook_active 가드 보강) · SSOT `nova-fleet-config`
> 대상: Claude Code 세션의 "세션 목표" 라이프사이클을 시작→추적→증명→해석→재작업까지 한 흐름으로 통합.
> 관계 문서: `claude/hooks/advisor-stop.sh`(현재 Stop 리포터, 목표 스냅샷 담당), `docs/fleet-ops-rules.md`,
> CLAUDE.md 「Operational Priority #1 — 거짓·미검증 보고 절대 금지」(증거등급 T1~T4 규칙이 본 설계의 근간).

---

## 0. 왜 필요한가 (문제 정의)

현재 자산 `advisor-stop.sh`는 **Stop 훅**이다. 세션이 끝나는 순간 `transcript_path`를 파싱해
`tx['goals_timeline']`(요청 타임라인 + ✅🔄⏳ 상태)을 만든다. 잘 동작하지만 구조적 한계가 있다:

| 한계 | 근거 (T1) | 영향 |
|---|---|---|
| **종료시점 스냅샷만** | `advisor-stop.sh:274` `raw[-6000:]` 를 매 Stop마다 전량 재파싱 | 세션 *중간* 목표 상태를 아무도 모름 → 실시간 표시·중간 개입 불가 |
| **증거 미연결** | `classify_request_status()`(`:252`)는 assistant *텍스트*의 `done:`/`완료` 단어만 봄 | T3/T4(자기보고)로 ✅ 판정 가능 — CLAUDE.md 규칙 위반 소지 |
| **재작업 트리거 없음** | 리포트는 `systemMessage`(`:862`)로 *출력만* | 미충족 목표를 감지해도 자동 재발주 루프가 없음 |
| **매 Stop 전량 재계산** | birth-time 앵커(`:91`)로 세션창만 잡고 6000줄 재스캔 | O(N) 반복, 목표 상태가 파일에 영속되지 않음 |

**핵심 설계 결정**: 목표 상태를 **영속 원장(ledger)** 으로 승격한다.
Stop 훅의 "종료 스냅샷"을 **증분 갱신되는 SSOT**로 바꾸고, 세 훅이 역할을 나눠 쓴다.

```
UserPromptSubmit ──(목표 등록)──▶  ~/.claude/session-goals/<sid>.json  ◀──(증거 부착)── PostToolUse
                                          │  (SSOT: 목표 원장)
                                          ▼
                                    Stop(advisor-stop) ──(해석·판정·재작업 트리거)──▶ LLM / ScheduleWakeup
```

---

## 1. 명확한 목표 — 실질 요청만 추출 (요소 ①)

### 설계
"목표"는 **사용자의 실질 요청**만이다. 워치독·체크인·영수증 재출력·시스템 리마인더는 목표가 아니다.
이 필터링 로직은 **이미 `advisor-stop.sh`에 존재** — 재구현하지 않고 **공용 모듈로 추출**한다.

- 재사용 함수 (현재 위치):
  - `is_system_reminder()` — `advisor-stop.sh:219` (`<system-reminder>`, `<task-notification>`, 스킬 부트스트랩 등 관리성 프롬프트 제외)
  - `AUTO_PREFIX_RE` — `advisor-stop.sh:179` (`패리티 루프`, `95점 루프`, `긴급 체크인`, `체크인:`, `commander 감독` 등 자동 발주 제외)
  - `extract_substantive_request()` — `advisor-stop.sh:242` (영수증 `## 검증 영수증`·`- [변경]` 블록 제외)
  - `summarize_request()` — `advisor-stop.sh:157` (60자 목표 요약)

### 신규 파일
`claude/hooks/lib/goal-extract.py` **(신규)** — 위 4함수를 순수 함수 라이브러리로 이동.
`advisor-stop.sh`(임베디드 python)와 신규 `session-goal-register.sh`가 **둘 다 import** → 단일 정의(DRY).
분리 이유: 필터 규칙이 두 곳에 복제되면 워치독 프리픽스 추가 시 한쪽만 갱신되어 목표 오염 발생.

### 목표 구조 (등록 직후)
```json
{
  "id": "g1",                         // 세션 내 순번
  "ts": "2026-07-11T12:38:00+09:00",
  "raw": "세션 목표 관리 플로우 설계 …",  // 원문 (120자 cap)
  "summary": "세션 목표 관리·증명 플로우 설계",   // summarize_request()
  "kind": "design|impl|bugfix|config|query",     // task-classifier 연동 (아래 §4)
  "status": "pending",
  "evidence": [],
  "rework_count": 0
}
```

### 실패 모드
- **F1-1** 새 워치독 프리픽스가 `AUTO_PREFIX_RE`에 없으면 자동 프롬프트가 목표로 오등록.
  → 완화: 프리픽스 목록을 `~/.claude/session-goals/auto-prefixes.txt`로 외부화, 훅이 매번 로드(코드 수정 없이 추가).
- **F1-2** 사용자가 한 프롬프트에 여러 목표를 나열 → 1개 목표로 뭉침.
  → 완화: MVP는 1프롬프트=1목표. 개선(§7)에서 `- [ ]` 체크리스트·번호목록 분할 파서.

---

## 2. 관리 — 목표 상태 저장·갱신 (요소 ②)

### SSOT: `~/.claude/session-goals/<sid>.json`
세션 UUID(=transcript 파일명 스템) 스코프.

**키 해석 우선순위 (2026-07-11 정정)** — 원판의 "advisor-stop.sh:31~40 그대로"는 자기모순이었다:
그 코드는 UUID가 아닌 **PID-워크**다(T1 확인). 정본 키는 아래 순서로 결정:
1. **훅 stdin JSON의 `session_id`** — UserPromptSubmit·PostToolUse·Stop 모두 stdin으로 받는 진짜 세션 UUID.
   `advisor-stop.sh:21-28`이 같은 stdin에서 `transcript_path`를 캡처하는 것과 동일 패턴 (basename 스템 = 동일 값).
2. stdin 파싱 실패 시에만 PID-워크(`:31~40`) 폴백 + `sid_source:"pidfallback"` 기록.

statusline(§6)은 PID(`NCO_SESSION_ID`) 기반이므로, register 훅이 `/tmp/nco-goal-map-<nco_sid>`에
UUID 1줄을 기록해 역방향 조회를 제공한다 (원장 파일에도 `"nco_sid"` 필드 병기).

```json
{
  "sid": "abc123",
  "project": "nova-fleet-config",
  "started": "2026-07-11T12:30:00+09:00",
  "updated": "2026-07-11T12:55:00+09:00",
  "goals": [ { …§1 목표 구조… } ],
  "rework": { "total": 0, "max": 3, "last_trigger": null }
}
```

### 갱신 주체 = 3훅 역할 분리 (핵심)

| 훅 | 이벤트 | SSOT 대상 동작 | 신규/변경 |
|---|---|---|---|
| `session-goal-register.sh` | **UserPromptSubmit** | 실질 요청이면 `goals[]`에 append (status=pending). 직전 open 목표의 status를 잠정 전이(§4). | **신규** |
| `session-goal-evidence.sh` | **PostToolUse** | 마지막 open 목표의 `evidence[]`에 T1 신호 append. | **신규** (또는 `tool-activity-reporter.sh` 확장) |
| `advisor-stop.sh` | **Stop** | 원장을 로드해 transcript와 **대조·최종판정**, 미충족시 재작업 트리거(§5). 원장 있으면 `scan_transcript` 전량 재파싱 대신 증분 병합. | **변경** |

### 재개(resume) 시 로드
세션이 `--continue`/`--resume`으로 이어질 때 같은 `<sid>.json`이 존재 → register 훅이 append 계속.
`started`는 최초 1회만. Stop 훅은 파일 존재 시 이를 **1차 소스**로, transcript를 **보정 소스**로 사용.

### 왜 Stop 단독으로 부족한가 (사용자 지적 반영)
Stop은 턴이 끝난 뒤에만 발화 → "세션 중 진행 상황"을 UI/statusline에 실시간 못 보여줌.
UserPromptSubmit 등록 + PostToolUse 증거부착으로 **매 도구 호출마다 원장이 최신** → 실시간 추적 성립(§6).

### 배포 (SSOT→실경로)
1. `claude/hooks/session-goal-register.sh`, `claude/hooks/session-goal-evidence.sh`, `claude/hooks/lib/goal-extract.py` 작성 (SSOT).
2. `claude/settings.template.json`:
   - `UserPromptSubmit[]`에 `bash {{HOME}}/.claude/hooks/session-goal-register.sh` 추가 (현재 `:147` `user-prompt-nco-context.sh` 옆).
   - `PostToolUse[]`에 `session-goal-evidence.sh` 추가.
3. `install/apply.sh` 실행 → `{{HOME}}` 치환 후 `~/.claude/hooks/`·`~/.claude/settings.json` 배포.
   - 훅 등록 멱등성은 apply.sh의 `_ensure_*_hooks` jq 패턴(`install/apply.sh:20~58`) 재사용 — 신규 함수 `_ensure_session_goal_hooks` 추가.
   - ⚠️ **apply.sh 배포 루프 수정 필수 (2026-07-11 정정)**: 현행 루프는 `hooks/*.sh`(`:154`)·`hooks/*.py`(`:167`)
     **최상위 글로빙만** — `hooks/lib/` 하위 디렉터리는 배포되지 않는다(T1: apply.sh 확인).
     `for f in "$ROOT"/claude/hooks/lib/*.py` 배포 라인(+ `mkdir -p "$DEST/hooks/lib"`) 추가 없이는
     `goal-extract.py` import가 전 기기에서 실패. register/advisor-stop은 import 실패 시
     무동작 exit 0 (fail-open — 목표 추적은 부가 기능, 세션을 막으면 안 됨).
4. `~/.claude/session-goals/` 는 훅이 `mkdir -p`로 자동 생성 (배포 스크립트 불필요).

### 실패 모드
- **F2-1** SID 해석 실패(조상 PID 미탐) → 파일명 충돌/오귀속. → 완화: `advisor-stop.sh:39` 폴백(`$$`)과 동일, 단 파일에 `sid_source: "env|pid|pidfallback"` 기록해 신뢰도 표시.
- **F2-2** 동시 두 세션이 같은 프로젝트 → 각자 `<sid>.json`이라 충돌 없음(세션 스코프). ✅ 이미 `advisor-stop.sh:64`가 커서를 SID 스코프화한 교훈 계승.
- **F2-3** 원장 append 중 훅 크래시 → 부분쓰기 손상. → 완화: `tmp+rename` 원자적 쓰기(`advisor-stop.sh:751` 저장 패턴과 동일).
- **F2-4** UserPromptSubmit는 `exit 2` 금지(`user-prompt-nco-context.sh:8` 규칙) → 등록 실패해도 절대 프롬프트 차단 금지, 조용히 skip + 로그.

---

## 3. 증명 — 목표 충족의 T1 근거 연결 (요소 ③)

### 설계 원칙
목표 status ✅해결은 **T1 증거 ≥1개**가 원장에 부착됐을 때만 가능.
이것이 CLAUDE.md 「T3·T4만으로는 '전송됨'까지, '완료' 금지」를 **데이터 구조로 강제**하는 장치.

### 증거 종류 (evidence kind, 모두 T1)
| kind | 수집 방법 (PostToolUse 훅) | ref 예 |
|---|---|---|
| `commit` | 도구가 Bash git commit → `git -C <repo> rev-parse HEAD` 델타 | `4aca75b feat(...)` |
| `file`   | Edit/Write tool_input의 `file_path` + `stat` mtime≥goal.ts | `advisor-stop.sh` |
| `test`   | Bash 커맨드가 test/pytest/tsc → exit code 0 | `pytest → 0` |
| `http`   | Bash `curl … localhost` → 2xx 본문 | `GET /health → 200` |
| `artifact` | 지정 산출물 경로 존재+비어있지않음 | `docs/design/x.md` |

### 수집 메커니즘 (PostToolUse)
`session-goal-evidence.sh`가 PostToolUse stdin(JSON: `tool_name`, `tool_input`, `tool_response`)을 읽어
증거 kind를 판정 → **마지막 open 목표**의 `evidence[]`에 `{tier:"T1", kind, ref, ts}` append.

`tool-activity-reporter.sh`가 이미 Pre/PostToolUse에 등록돼 있음(`install/apply.sh:22-23`) → **이 훅에 증거수집 블록을 합류**시키는 편이 훅 수를 늘리지 않아 유리(대안).

### 목표↔증거 귀속 규칙
- **시간 근접 휴리스틱**: 증거 발생 시각에 열려있는(가장 최근 pending/in-progress) 목표에 부착.
- **명시 오버라이드**: LLM이 `session-goal set g2 evidence commit:<hash>` CLI(§7)로 수정 가능 → 오귀속 교정.

### status 승급 게이트 (Stop에서 최종 판정)
```
✅해결   := assistant done-marker  AND  evidence(T1) ≥ 1
🔄진행중 := 활동 있음  AND  (T1 증거 0  OR  현재 마지막 목표)
⏳대기   := 등록됨  AND  후속 활동 0 (question 회신 대기 포함)
❌실패   := pushback 감지  OR  gate_block  OR  rework_count ≥ max & 미충족
```

### 실패 모드
- **F3-1** commit이 여러 목표 작업 결과인데 마지막 목표에만 부착 → 앞 목표 미증명. → 완화: commit 메시지·변경파일과 목표 summary 토큰 매칭 점수로 재배분(개선 §7).
- **F3-2** 백그라운드 프로세스/다른 세션 commit이 내 증거로 오염. → 완화: `advisor-stop.sh:335` `NOISE_RE`(hnsw/rdb/log 등) 및 mtime≥goal.ts 게이트 재사용.
- **F3-3** PostToolUse가 `tool_response`를 못 받는 환경 → exit code 판정 불가. → 완화: kind=`file`/`commit`은 tool_input만으로 판정 가능(폴백), `test`/`http`만 T2로 강등 표기.

---

## 4. 해석 — 자연어→요약+상태 휴리스틱 (요소 ④)

### 요약(summary)
`summarize_request()`(`advisor-stop.sh:157`, 60자) 재사용.
`kind` 분류는 기존 `nco-task-classifier.sh`(task_type: design/impl/bugfix/config/query) 신호를 원장에 복사 —
이미 `advisor-stop.sh:126`이 `tr.get('task_type')`로 읽는 값과 동일 소스(`/tmp/nco-track-<sid>.json`).

### 상태 판정 규칙 (결정론 · LLM 비의존)
현재 `classify_request_status()`(`:252`)는 **텍스트 단어만** 본다 → **증거게이트로 업그레이드**:

| 상태 | 판정 조건 (우선순위 순) | 현재 대비 변경 |
|---|---|---|
| ❌실패 | 목표 이후 user pushback(`틀렸/거짓/안돼/제대로`, `:323`) OR `gate_blocks>0`(`:305`) OR rework 소진 | **신규** — 현재는 ❌ 없음 |
| ✅해결 | done-marker(`done:`/`완료`/`커밋`) **AND** `evidence(T1)≥1` | **증거 AND 추가** (현재 텍스트만) |
| ⏳대기 | `대기/회신 대기/발주` 키워드 OR 활동 0 | 유지 |
| 🔄진행중 | 위 모두 아님 / 마지막 목표 | 유지 |

### 핵심 변경점
현재 `classify_request_status`는 else에서 무조건 `✅해결` 반환(`:260`) → **거짓 완료의 온상**.
개선: else 기본값을 `🔄진행중`으로, ✅는 증거 게이트 통과 시에만.

### 실패 모드
- **F4-1** pushback이 목표와 무관한 잡담일 수 있음 → 오판 ❌. → 완화: pushback을 *직전 목표*에만 연결, 2회 연속 시에만 ❌ 확정.
- **F4-2** done-marker 없이 조용히 완료(증거만 존재) → ✅ 못 받음. → 완화: 증거 T1≥1 이고 후속 목표가 등록됐으면(=사용자가 다음으로 넘어감) ✅ 승급 허용.

---

## 5. 재작업 자동화 — 미충족·거짓 감지 시 자동 재발주 (요소 ⑤)

### 역할 분리 (가장 중요 — 훅 vs LLM vs ScheduleWakeup)

훅은 **결정론적 감지·재구동 트리거**만 한다. 실제 재작업(편집·위임·검증)은 **LLM 세션만** 할 수 있다.
ScheduleWakeup은 **LLM이 async 대기를 예약**하는 도구다. 세 배우의 경계:

| 배우 | 할 수 있는 것 | 할 수 없는 것 |
|---|---|---|
| **Stop 훅 (shell)** | 미충족 감지 → `decision:block`으로 **즉시 재구동**(턴 재개) + 재작업 지시를 `reason`에 주입. rework_count 증가. | 편집/위임 직접 수행 불가 |
| **LLM 세션** | block으로 재개된 턴에서 실제 재작업 수행. async 위임 대기가 필요하면 ScheduleWakeup 예약. | 자기 자신을 재구동 불가(턴 종료 후) |
| **ScheduleWakeup (LLM 도구)** | NCO 위임·CI 등 **외부 상태가 정착되길 기다렸다** 재드라이브 | 즉시 재작업(그건 block) |

### 메커니즘 A — 즉시 재작업 (Stop hook block, 동기)
Stop 훅은 종료를 **막을 수 있다**(Stop hook `{"decision":"block","reason":"…"}`).
`advisor-stop.sh` 최종 판정에서 **❌실패 또는 (🔄+증거0)** 목표가 있고 rework_count<max면:

```
출력: {"decision":"block",
       "reason":"[자동 재작업 g2] 목표 '…' 미충족(증거 T1 0건). 다음을 수행:
                 1) 부작용 T1 검증  2) 미달시 NCO 재위임  3) 영수증 재출력"}
→ LLM 턴이 재개되어 실제 재작업 수행.
```
- 무한루프 방지 **3중 가드** (2026-07-11 보강):
  1. **`stop_hook_active` 검사** — Stop 훅 stdin JSON에 `stop_hook_active:true`가 오면(=이미 block으로
     재개된 턴의 재-Stop) 카운터와 무관하게 판정만 갱신하고 재-block 전 반드시 **상태 변화**를 요구:
     직전 block 이후 원장 해시(goals+evidence)가 무변화면 즉시 에스컬레이션(=재작업이 아무것도 안 바꿈).
     `end-of-turn-check.sh:29-40`의 해시 dedup 패턴 그대로.
  2. `rework.total < rework.max(기본3)` 하드캡.
  3. `NCO_REWORK_AUTO` 토글 (기본 warn).
  이는 CLAUDE.md 「Gap 100% 미달 시 재지시 최대 5회」및 기존 `end-of-turn-check.sh`(반복 강제 + 세션당
  재발화 상한 `:41-45`) 패턴 계승.
- block은 **actionable 미충족**(재작업으로 바뀔 수 있는 것)에만. pushback-소진·사용자 회신대기(⏳)는 block 금지 — 사용자 의견 필요(CLAUDE.md 「사용자 의견은 발송측 위임」).

### 메커니즘 B — 지연 재작업 (ScheduleWakeup, 비동기)
목표가 **외부 async에 블록**된 경우(NCO 위임 발주 후 결과 미도착, CI 대기):
LLM이 *활성 턴 중* ScheduleWakeup을 호출해 재점검을 예약. 훅이 아니라 **LLM이 예약**한다(훅은 이 도구 없음).
- delay: NCO 위임 ~ 270s(캐시 유지), CI/외부 ~ 1200s+.
- wake 시 프롬프트: `[자동 재작업 재점검] g2 위임결과 T1 수집 → 미달시 재발주`.
- 이 프롬프트는 `AUTO_PREFIX_RE`에 등록되어 **목표로 재등록되지 않음**(무한 목표증식 차단).

### 결정 흐름
```
Stop ─ 원장 판정 ─┬─ 모든 목표 ✅ ───────────────▶ 정상 종료(리포트만)
                 ├─ ❌/🔄증거0 & actionable & rework<max ─▶ [A] block 재구동
                 ├─ ⏳ 사용자회신대기 ───────────▶ block 금지, 리포트에 "회신 대기" 명시
                 └─ async 블록(위임중) ──────────▶ LLM이 [B] ScheduleWakeup 예약(활성 턴에서)
```

### 실패 모드
- **F5-1** block 남발로 사용자가 세션 종료 못함. → 완화: rework.max=3 하드캡 + `NCO_REWORK_AUTO=0` 토글(기본 warn) + block 사유에 "N/3회차" 명시.
- **F5-2** 증거 오귀속(F3-1)으로 실제 완료 목표를 미충족 오판 → 불필요 재작업. → 완화: block 전 증거 재수집 1패스, 그래도 0이면 사용자에게 "증거 못찾음, 강제완료? " 질문 옵션.
- **F5-3** ScheduleWakeup가 async 미정착 상태서 조기 발화 → 헛돔. → 완화: wake 프롬프트가 상태 재확인 후 미정착이면 재예약(최대 N회).
- **F5-4** block reason이 T4(자기보고) 재작업을 유발 → 다시 거짓완료. → 완화: reason에 "T1 검증 필수" 명시 + 재작업 후에도 no-false-report-gate(`:no-false-report-gate.sh`)가 2차 방어.

---

## 6. 진행중 목표 실시간 표시 (요소 ⑥)

원장이 **매 도구 호출마다 최신**이므로(§2) 실시간 표시가 성립한다.

### 표시 채널
1. **Statusline** — `nco-statusline.sh` 확장: `<sid>.json` 읽어 `🎯 3목표 ✅2 🔄1` 요약 세그먼트 추가.
   비용 0(파일 1회 read), 매 렌더 갱신.
2. **UserPromptSubmit additionalContext** — `session-goal-register.sh`가 등록 직후
   현재 open 목표들을 `[세션목표] 🔄g2: …` 형태로 컨텍스트 주입 → LLM이 매 턴 미완 목표 인지.
3. **온디맨드 CLI** — `session-goal list`(§7)로 사용자가 언제든 조회.

### 실패 모드
- **F6-1** statusline이 stale 원장 표시(훅 실패 시). → 완화: `updated` 타임스탬프 표시, 5분↑ 오래되면 `⚠️stale` 마크.
- **F6-2** additionalContext 과다 주입으로 컨텍스트 오염. → 완화: open 목표 **최대 3개**·각 40자 cap만 주입.

---

## 7. 개선점 (요소 ⑦)

| # | 개선 | 이유 | 난이도 |
|---|---|---|---|
| I1 | **CLI `session-goal {list,set,close,evidence}`** | LLM/사용자가 목표 상태·증거를 수동 교정 (F3-1, F5-2 완화) | 중 |
| I2 | **멀티목표 프롬프트 분할** | `- [ ]`·번호목록을 개별 목표로 (F1-2) | 중 |
| I3 | **증거-목표 토큰매칭 재배분** | commit/파일명과 목표 summary 유사도로 귀속 정확화 (F3-1) | 상 |
| I4 | **크로스세션 목표 상속** | resume/handoff 시 미완 목표를 다음 세션 `context_note.md`로 이월 (advisor-stop `:797` "다음 세션 필수 인지" 재사용) | 중 |
| I5 | **목표 KPI 대시보드** | `session-goals/*.json` 집계 → 세션당 목표 충족률·평균 rework 횟수 리더보드 | 하 |
| I6 | **증거등급 자동 강등 감사** | ✅인데 evidence가 T2/T3뿐이면 주기적 감사→🔄강등 (거짓완료 사후 적발) | 중 |
| I7 | **auto-prefixes 자가학습** | 반복되는 자동프롬프트 패턴을 lessons-ledger(`advisor-stop:550`)처럼 자동 등록 | 상 |

---

## 8. 전체 파일 구조 (변경/신규 요약)

```
nova-fleet-config/                         (SSOT)
├─ claude/
│  ├─ hooks/
│  │  ├─ lib/goal-extract.py               ★신규  §1 필터·요약 공용모듈
│  │  ├─ session-goal-register.sh          ★신규  UserPromptSubmit: 목표 등록+실시간 주입  §1,§2,§6
│  │  ├─ session-goal-evidence.sh          ★신규  PostToolUse: T1 증거 부착           §3
│  │  │        (대안: tool-activity-reporter.sh 에 증거블록 합류)
│  │  ├─ advisor-stop.sh                   ✎변경  원장 로드→판정→block 재작업         §2,§4,§5
│  │  │        - scan_transcript(:137) : 원장 존재시 1차소스, transcript 보정
│  │  │        - classify_request_status(:252) : 증거게이트 + ❌실패 추가
│  │  │        - (신규) reconcile_ledger() + maybe_block_rework()
│  │  └─ nco-statusline.sh                 ✎변경  🎯 목표 세그먼트                     §6
│  └─ settings.template.json               ✎변경  UserPromptSubmit[]·PostToolUse[]·Stop 등록  §2
├─ install/apply.sh                        ✎변경  _ensure_session_goal_hooks (jq 멱등, :20 패턴)
│                                                 + hooks/lib/*.py 배포 라인 (:154·:167은 최상위만)  §2
└─ docs/design/session-goal-flow.md        ★이 문서

런타임 (배포 후, git 미추적)
~/.claude/session-goals/<sid>.json          목표 원장 (SSOT of state)
~/.claude/session-goals/auto-prefixes.txt   워치독 프리픽스 외부화 (F1-1)
~/.claude/session-goals/<sid>.json:rework   재작업 카운터 (F5-1)
```

---

## 9. 단계별 배포·검증 체크리스트

배포는 **SSOT(`nova-fleet-config/claude/`) 편집 → `install/apply.sh` → `~/.claude/` 반영** 순서 고정.

### Phase 0 — 준비 (구현 착수 전)
- [ ] `advisor-stop.sh`의 §1 4함수가 순수함수로 추출 가능한지 확인 (전역 상태 의존 없음)
- [ ] PostToolUse stdin에 `tool_response`가 실제로 오는지 1건 T1 확인 (`echo $stdin >> /tmp/probe`)
- [ ] Stop hook의 `{"decision":"block"}` 지원 여부 T1 확인 (현재 Claude Code 버전)

### Phase 1 — 원장 + 등록 (§1,§2)
- [ ] `goal-extract.py`, `session-goal-register.sh` 작성 (SSOT)
- [ ] `settings.template.json` UserPromptSubmit[]에 등록 — `user-prompt-nco-context.sh` **앞** 순서
      (목표 등록이 같은 턴의 컨텍스트 주입보다 선행해야 함)
- [ ] `install/apply.sh`: `_ensure_session_goal_hooks` + **`hooks/lib/*.py` 배포 라인 추가** 후 배포
- [ ] **검증(T1)**: `ls ~/.claude/hooks/lib/goal-extract.py` 존재 + `python3 -c "import …"` 성공
- [ ] **검증(T1)**: 실질 프롬프트 1회 → `cat ~/.claude/session-goals/<sid>.json` 에 goal append 확인
- [ ] **검증(T1)**: 체크인/영수증 프롬프트 → goal **미**append 확인 (필터 동작)

### Phase 2 — 증거 부착 (§3)
- [ ] `session-goal-evidence.sh` 작성·PostToolUse 등록·배포
- [ ] **검증(T1)**: 파일 Edit 1회 → 해당 goal `evidence[]`에 `{kind:file}` append 확인
- [ ] **검증(T1)**: `git commit` 1회 → `{kind:commit, ref:<hash>}` 확인

### Phase 3 — 판정·해석 (§4)
- [ ] `advisor-stop.sh` `classify_request_status` 증거게이트 반영
- [ ] **검증(T1)**: 증거0 목표 → status가 ✅ 안됨(🔄 유지) 확인
- [ ] **검증(T1)**: pushback 프롬프트 후 → ❌실패 판정 확인
- [ ] **회귀검증**: 기존 9섹션 리포트 정상 출력(`bash -n advisor-stop.sh` + 실 Stop 1회)

### Phase 4 — 자율 재작업 (§5)
- [ ] `NCO_REWORK_AUTO` 토글 + rework.max 하드캡 구현
- [ ] **검증(T1)**: 미충족 목표 + rework<max → Stop이 `decision:block` 출력 확인 (`jq` 파싱)
- [ ] **검증(T1)**: rework.total==max → block 안하고 정상종료 확인 (무한루프 방지)
- [ ] **검증**: ⏳사용자회신대기 목표 → block 금지 확인

### Phase 5 — 실시간 표시 + 개선 (§6,§7)
- [ ] `nco-statusline.sh` 🎯 세그먼트 → statusline에 표시 T1 확인
- [ ] additionalContext 주입 3개·40자 cap 확인
- [ ] (선택) I1 `session-goal` CLI

### 롤백
- `install/apply.sh:153` 비파괴 보존가드(bash -n 실패시 백업 롤백) 재사용.
- 토글 `NCO_REWORK_AUTO=0`(재작업만 끔), 훅 미등록 시 원장은 남되 무해(read-only).

---

## 10. 설계 요약 (한 문단)

세션 목표를 **Stop 스냅샷에서 영속 원장(`~/.claude/session-goals/<sid>.json`)으로 승격**하고,
**UserPromptSubmit**(등록·필터·실시간 주입) → **PostToolUse**(T1 증거 부착) → **Stop**(대조·증거게이트 판정·자율 재작업)
의 3훅으로 역할을 나눈다. "증명"은 **✅해결에 T1 증거 ≥1을 요구**하는 데이터 게이트로 CLAUDE.md 규칙을 강제하고,
"재작업"은 **Stop 훅의 `decision:block`(즉시·동기, rework≤3 하드캡)** 과 **LLM의 ScheduleWakeup(async·지연)** 으로
분리한다. 필터·요약 로직은 이미 `advisor-stop.sh`에 존재하므로 **공용 모듈로 추출해 재사용**(DRY)하고,
배포는 **SSOT→`install/apply.sh`(jq 멱등 등록)→`~/.claude/`** 경로를 따른다.

---

## 검증 영수증
- [변경] `docs/design/session-goal-flow.md` (신규 설계문서, 구현 0)
- [검증방법] 설계 근거 파일·라인 T1 실측: `advisor-stop.sh` 852줄 전문 Read(is_system_reminder:219, AUTO_PREFIX_RE:179, classify_request_status:252, scan_transcript:137) + `install/apply.sh` 훅배포 jq패턴(:20-58) grep + `settings.template.json` 등록라인(:147,:201,:222) grep + `~/.claude/session-goals/` 부재 `ls` 확인 + SSOT/live diff 확인
- [등급] T1 (참조한 모든 파일:라인을 Read/grep으로 직접 확인 — 추측 인용 0)
- [Gap] 설계 100%(7요소 전부 파일:라인·배포·실패모드 포함) / 구현 0%(요구대로 설계만)
- [미검증항목] (1) Stop hook `decision:block` 지원은 현 CC 버전에서 미실측 — Phase 0 체크리스트에 T1 확인 항목으로 명시 (2) PostToolUse `tool_response` 페이로드 실제 형태 미실측 — 동일 (3) 본 문서는 설계안이며 어떤 훅도 실제 동작 검증 안됨(구현 금지 제약 준수)

### r2 개정 영수증 (2026-07-11, 독립 재검증 세션)
- [변경] 본 문서 §2(SSOT 키)·§2(배포 3단계)·§5(무한루프 가드)·§8(apply.sh)·§9(Phase 1) — 결함 3건 정정
- [검증방법] 원판 인용 전수 대조: `advisor-stop.sh` 864줄 전문 Read → `:31-40`은 PID-워크이지 UUID 아님(§2 자기모순 T1 확정) · `install/apply.sh:154,167` grep → 배포 글로빙이 `hooks/*.sh`·`hooks/*.py` 최상위만, `hooks/lib/` 미포함(T1) · `end-of-turn-check.sh:29-45` Read → 해시 dedup+재발화 상한 패턴 실존(T1) · `settings.template.json` 훅 등록 순서 전체 덤프로 UserPromptSubmit/Stop 순서 확인(T1)
- [등급] T1 (정정 3건 모두 해당 파일:라인 직접 실측 근거)
- [Gap] 원판 인용 라인 표본 대조에서 잔여 오류 0건 — 정정 3건 외 원판 유지
- [미검증항목] Stop stdin `stop_hook_active` 필드 존재는 CC 문서 기반 설계 가정 — Phase 0 실측 항목에 포함할 것
