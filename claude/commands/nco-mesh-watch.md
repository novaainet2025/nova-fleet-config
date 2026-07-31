Live mesh inbox watcher — 새 DM이 도착할 때마다 system notification으로 즉시 알립니다.

## 동작 — Monitor 직접 spawn (기본)

> 2026-07-29 정정: 이전 판은 `mesh-receiver` 플러그인이
> `~/.claude/plugins/cache/mesh-receiver/0.1.0/monitors/monitors.json` 의
> `when: "always"` 로 자동 spawn 한다고 적혀 있었으나 **사실이 아니다**.
> 그런 플러그인도 그 경로도 이 fleet 에 존재하지 않는다. 실제 판정 주체는
> `session-start.sh` 이고, 그것이 보는 것은 `inter-session` 플러그인의 존재다
> (`plugins/marketplaces/mesh-receiver` 또는 `plugins/cache/inter-session/inter-session`).
> 또한 canonical `monitors.json` 에 `when: "always"` 를 두는 것은 금지돼 있다
> (lazy `on-skill-invoke` 만 허용). 따라서 **DM 실시간 수신은 Monitor 도구로
> 직접 spawn 해야 보장된다** — 자동으로 되는 것이 아니다.

세션 시작 시 다음을 직접 호출해야 idle 상태에서도 DM 이 conversation 에 주입된다:

```
Monitor(
  command="INTER_MODE=monitor NCO_NAME=<claude-N> NCO_SESSION_ID=<sid> \
           bash $HOME/.claude/hooks/mesh-inbox-poller.sh <sid> <claude-N> 5",
  description="mesh DM watcher (<claude-N>)",
  persistent=true, timeout_ms=3600000
)
```

- 시작 메시지: `[mesh-receiver] connected as <name> (session <sid>) — listening for mesh DMs`
- DM 한 줄: `[NEW <type>] <from_agent>(<from_session>) -> <content[:160]>`

`mesh-auto-responder.js`는 `/tmp/nco-inbox-<sid>/monitor.lock` 존재 여부로
gate를 결정합니다. Monitor 가 떠 있으면 lock 존재 → autoresponder yield →
Claude가 직접 처리. Monitor 부재 시 lock 없음 → Ollama 자동응답.

추가로 `session-start.sh`가 background daemon(`INTER_MODE=daemon`)을 띄워
`queue.log`에 누적합니다 — `user-prompt-nco-context.sh`가 다음 user prompt에
미처리 라인을 보강 주입합니다 (Monitor 채널 백업).
단 daemon 모드 출력은 conversation 에 도달하지 않으므로 Monitor 를 대체하지 못합니다.

## 수동 호출이 필요한 경우

1. **Monitor 미spawn** — 세션 시작 시 위 Monitor 호출을 빠뜨린 경우. 이 명령으로 1회 spawn.
2. **강제 재연결** — Monitor task가 죽었거나 lock이 stale. `TaskList()` → `TaskStop()` → 본 명령으로 재spawn.

## 수동 실행 절차

1. 현재 세션의 PID와 NAME 확인:

```bash
echo "PID=${NCO_SESSION_ID:-$PPID}  NAME=${NCO_NAME:-claude-code}"
```

2. `Monitor` 도구 호출:

   - `description`: `"mesh DM watcher for <NAME>"`
   - `command`: `INTER_MODE=monitor bash $HOME/.claude/hooks/mesh-inbox-poller.sh <PID> <NAME> 5`
   - `persistent`: `true`
   - `timeout_ms`: 무관 (persistent=true이므로 무시)

   **반드시** `INTER_MODE=monitor`로 호출해야 lock이 생성되고 autoresponder가 양보합니다.

3. 다른 세션에서 메시지 전송:

```bash
bash $HOME/.claude/hooks/mesh-send.sh <NAME> 'ping'
```

5초 안에 `[NEW info] claude-N(sid) -> ping` 라인이 도착해야 정상.

## 헬퍼 (inter-session 미러)

| 작업                | 명령                                                    |
| :------------------ | :------------------------------------------------------ |
| DM 전송             | `bash ~/.claude/hooks/mesh-send.sh <to> '<text>'`       |
| 전체 브로드캐스트   | `bash ~/.claude/hooks/mesh-broadcast.sh '<text>'`       |
| 활성 세션 목록      | `bash ~/.claude/hooks/mesh-list.sh`                     |
| 본 세션만           | `bash ~/.claude/hooks/mesh-list.sh --self`              |

## 중지

순서대로 수행한다. 1단계만 해도 실시간 수신은 멈춘다.

**1단계 — Monitor 태스크 종료 (이것이 본체다)**

`TaskList()` 로 `mesh DM watcher` 태스크 id 를 찾아 `TaskStop(task_id="<id>")` 호출.
플러그인을 지우는 방식이 아니다 — 애초에 `mesh-receiver` 라는 플러그인은 존재하지 않는다.

**2단계 — background daemon 과 lock 파일 정리 (선택)**

Monitor 를 멈춰도 `session-start.sh` 가 띄운 daemon 은 계속 `queue.log` 에 쌓는다.
그것까지 멈추려면:

```bash
INBOX_DIR="/tmp/nco-inbox-${NCO_SESSION_ID:-$PPID}"
kill "$(cat "$INBOX_DIR/poller.pid" 2>/dev/null)" 2>/dev/null && rm -f "$INBOX_DIR/poller.pid"
rm -f "$INBOX_DIR/monitor.lock"
```

2단계까지 하면 이후 세션은 daemon + queue.log 모드로만 동작한다.
`monitor.lock` 이 사라지면 `mesh-auto-responder.js` 가 yield 를 멈추고 Ollama 자동응답으로 되돌아간다.
