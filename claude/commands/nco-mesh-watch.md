Live mesh inbox watcher — 새 DM이 도착할 때마다 system notification으로 즉시 알립니다.

## 동작 — 자동 spawn (기본)

`mesh-receiver` 플러그인이 모든 세션 시작 시 자동으로 Monitor를 띄웁니다
(`~/.claude/plugins/cache/mesh-receiver/0.1.0/monitors/monitors.json` ·
`when: "always"`). 즉, **별도 명령 없이도** inter-session처럼 실시간 DM이
Claude 컨텍스트에 system notification으로 도착합니다.

- 시작 메시지: `[mesh-receiver] connected as <name> (session <sid>) — listening for mesh DMs`
- DM 한 줄: `[NEW <type>] <from_agent>(<from_session>) -> <content[:160]>`
- 반응 정책: `~/.claude/plugins/cache/mesh-receiver/0.1.0/skills/mesh-receiver/SKILL.md`

`mesh-auto-responder.js`는 `/tmp/nco-inbox-<sid>/monitor.lock` 존재 여부로
gate를 결정합니다. 플러그인이 활성이면 lock 존재 → autoresponder yield →
Claude가 직접 처리. 플러그인 비활성 시 lock 없음 → Ollama 자동응답.

추가로 `session-start.sh`가 background daemon(`INTER_MODE=daemon`)을 띄워
`queue.log`에 누적합니다 — `user-prompt-nco-context.sh`가 다음 user prompt에
미처리 라인을 보강 주입합니다 (Monitor 채널 백업).

## 수동 호출이 필요한 경우

자동 spawn이 기본이므로 `/nco-mesh-watch`는 다음 두 경우에만 호출:

1. **플러그인 비활성** — `~/.claude/plugins/cache/mesh-receiver/`가 삭제됐거나 비활성. 이 명령으로 Monitor 1회 수동 spawn.
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

```bash
# Monitor task 중지 (TaskList → TaskStop)
# 추가로 background daemon도 함께 멈추려면:
INBOX_DIR="/tmp/nco-inbox-${NCO_SESSION_ID:-$PPID}"
kill "$(cat "$INBOX_DIR/poller.pid" 2>/dev/null)" 2>/dev/null && rm -f "$INBOX_DIR/poller.pid"
rm -f "$INBOX_DIR/monitor.lock"
```

## 롤백 (mesh-receiver 플러그인 제거)

```bash
rm -rf ~/.claude/plugins/cache/mesh-receiver
rm -f /tmp/nco-inbox-*/monitor.lock
```

이후 세션은 background daemon + queue.log 모드로만 동작 (이전과 동일).
