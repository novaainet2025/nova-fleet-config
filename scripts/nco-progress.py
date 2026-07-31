#!/usr/bin/env python3
"""NCO 실시간 진행 대시보드.

nco-progress / nco-analyze / nco-opus / nco-solve 가 참조하는 스크립트.
2026-07-29 이전에는 이 파일이 어느 머신에도 존재하지 않아
`/nco-progress` 는 전 모드가 exit 2 로 죽었고, 나머지 셋은 진행 모니터 단계에서 실패했다.

모든 수치는 NCO 백엔드(:6200)의 실제 응답에서만 가져온다. 추정·합성값 없음.
엔드포인트가 응답하지 않으면 그 섹션은 "조회 실패"로 표시하고 다음으로 넘어간다.

사용법:
  nco-progress.py --once           현재 상태 1회 출력
  nco-progress.py --once --cmd     최근 호출(명령어 워크플로우)만 출력
  nco-progress.py --interval N     N초 간격 갱신 (Ctrl+C 종료)
"""

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request

BASE = os.environ.get("NCO_URL", "http://localhost:6200")
TIMEOUT = 5


def get(path):
    """GET 후 (data, error). 실패해도 예외를 올리지 않는다."""
    try:
        with urllib.request.urlopen(f"{BASE}{path}", timeout=TIMEOUT) as r:
            return json.loads(r.read().decode("utf-8")), None
    except urllib.error.HTTPError as e:
        return None, f"HTTP {e.code}"
    except Exception as e:  # 연결 거부/타임아웃/JSON 파손
        return None, str(e).split("\n")[0][:60]


def line(char="─", n=64):
    print(char * n)


def section_health():
    d, err = get("/health")
    if err:
        print(f"  서버      : 조회 실패 ({err})")
        return False
    rt = d.get("runtime", {}) or {}
    up = rt.get("uptime")
    uptime_txt = f"  uptime={int(up)}s" if isinstance(up, (int, float)) else ""
    print(f"  서버      : {d.get('status', '?')}  "
          f"providers={d.get('providerCount', '?')}  "
          f"online={rt.get('agentsOnline', '?')}  "
          f"redis={'on' if rt.get('redis') else 'off'}"
          f"{uptime_txt}")
    return True


def section_tasks():
    d, err = get("/api/observability/metrics")
    if err:
        print(f"  태스크    : 조회 실패 ({err})")
        return
    t = d.get("tasks", {}) or {}
    total = t.get("total", 0) or 0
    done = t.get("completed", 0) or 0
    rate = (done / total * 100) if total else 0.0
    print(f"  태스크    : 전체 {total}  완료 {done}  실패 {t.get('failed', 0)}  "
          f"실행중 {t.get('running', 0)}  (완료율 {rate:.1f}%)")
    disc = d.get("discussions", {}) or {}
    if disc:
        print(f"  토론      : 전체 {disc.get('total', 0)}  완료 {disc.get('completed', 0)}")


def section_queue():
    d, err = get("/api/queue/metrics")
    if err:
        print(f"  큐        : 조회 실패 ({err})")
        return
    rows = [m for m in (d.get("metrics") or [])
            if (m.get("waiting") or m.get("active") or m.get("completed") or m.get("failed"))]
    if not rows:
        print("  큐        : 전 에이전트 유휴")
        return
    for m in rows:
        print(f"    {m.get('agentId', '?'):<14} "
              f"wait={m.get('waiting', 0)} active={m.get('active', 0)} "
              f"done={m.get('completed', 0)} fail={m.get('failed', 0)}")


def section_invocations(limit=5):
    d, err = get(f"/api/invocations/overview?limit={limit}")
    if err:
        print(f"  진행 호출 : 조회 실패 ({err})")
        return
    active = d.get("active") or []
    recent = d.get("recentCompleted") or []
    if not active:
        print("  진행 호출 : 없음")
    for inv in active[:limit]:
        prompt = (inv.get("prompt") or "").replace("\n", " ")[:52]
        print(f"    ▶ {inv.get('targetAgentId', '?'):<14} "
              f"{inv.get('status', '?'):<8} {prompt}")
    for inv in recent[:limit]:
        ms = inv.get("durationMs")
        dur = f"{ms / 1000:.1f}s" if isinstance(ms, (int, float)) else "-"
        mark = "✓" if inv.get("status") == "completed" else "✗"
        prompt = (inv.get("prompt") or "").replace("\n", " ")[:44]
        print(f"    {mark} {inv.get('targetAgentId', '?'):<14} "
              f"{dur:<8} {prompt}")


def render(cmd_only=False):
    if os.environ.get("NCO_PROGRESS_CLEAR"):
        # 인터벌 모드에서만 화면을 지운다 (--once 출력은 파이프/로그로 흘러가야 하므로 보존)
        sys.stdout.write("\033[H\033[J")
    line("═")
    print(f"  NCO 진행 대시보드   {time.strftime('%Y-%m-%d %H:%M:%S')}   {BASE}")
    line("═")
    if cmd_only:
        print("  [최근 호출]")
        section_invocations(limit=10)
        line()
        return
    section_health()
    section_tasks()
    line()
    print("  [큐]")
    section_queue()
    line()
    print("  [호출]")
    section_invocations()
    line()


def main():
    p = argparse.ArgumentParser(add_help=True)
    p.add_argument("--once", action="store_true", help="1회 출력 후 종료")
    p.add_argument("--cmd", action="store_true", help="최근 호출만 출력")
    p.add_argument("--interval", type=int, metavar="N", help="N초 간격 갱신")
    a = p.parse_args()

    if a.interval and not a.once:
        os.environ["NCO_PROGRESS_CLEAR"] = "1"
        try:
            while True:
                render(cmd_only=a.cmd)
                time.sleep(max(1, a.interval))
        except KeyboardInterrupt:
            print("\n종료")
            return 0
    render(cmd_only=a.cmd)
    return 0


if __name__ == "__main__":
    sys.exit(main())
