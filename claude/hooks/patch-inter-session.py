"""
Post-install patch for inter-session plugin (cross-platform).
Adds NCO statusline name (claude-N) auto-detection.
Run: python patch-inter-session.py
"""
import json
import os
import sys
from pathlib import Path

CLAUDE_DIR = Path.home() / ".claude"
PLUGIN_DIR = CLAUDE_DIR / "plugins" / "cache" / "inter-session" / "inter-session"


def find_latest_version():
    if not PLUGIN_DIR.exists():
        return None
    versions = sorted(PLUGIN_DIR.iterdir(), key=lambda p: p.name)
    return versions[-1] if versions else None


def patch_shared_py(version_dir):
    shared = version_dir / "skills" / "inter-session" / "bin" / "shared.py"
    if not shared.exists():
        print(f"[patch] shared.py not found at {shared}")
        return False

    content = shared.read_text(encoding="utf-8")
    # 버전 마커 — v2는 retry+안전 fallback 포함. v1(또는 마커 없음)은 재패치.
    PATCH_MARKER = "NCO 패치 v2"
    if PATCH_MARKER in content:
        print("[patch] shared.py already patched (v2)")
        return True
    if "_nco_name_from_pid" in content:
        # v1 → v2 업그레이드: 기존 함수 제거 후 재삽입
        import re
        content = re.sub(
            r'\ndef _nco_name_from_pid\(\)[\s\S]*?\n    return ""\n\n\n',
            '\n',
            content
        )
        content = content.replace(
            "    nco = _nco_name_from_pid()\n    if nco:\n        return nco\n\n    ",
            "    "
        )
        print("[patch] v1→v2 upgrade — old function removed, re-injecting")

    nco_func = '''
def _nco_name_from_pid() -> str:
    """Check nco-names dir for a name matching this CC session.

    NCO 패치 v2 (2026-05-25): 3회 재시도 + dangerous fallback 제거.
    이전 버그: PID 매칭 실패 시 첫 .pid 픽업 → 다른 세션 이름 훔침.
    """
    import glob
    import platform
    import time
    if platform.system() == "Windows":
        nco_dir = os.path.join(os.environ.get("TEMP", ""), "nco-names")
    else:
        nco_dir = "/tmp/nco-names"
    if not os.path.isdir(nco_dir):
        return ""
    try:
        cc_pid = find_cc_ancestor_pid()
    except Exception:
        cc_pid = 0
    cc_pid_str = str(cc_pid) if cc_pid and cc_pid > 0 else ""
    if not cc_pid_str:
        return ""

    for attempt in range(3):
        for pf in glob.glob(os.path.join(nco_dir, "claude-*.pid")):
            try:
                with open(pf) as f:
                    stored_pid = f.read().strip()
                if stored_pid == cc_pid_str:
                    name = os.path.basename(pf).replace(".pid", "")
                    if validate_name(name):
                        return name
            except OSError:
                continue
        if attempt < 2:
            time.sleep(1)

    return ""  # cwd basename으로 위임 (first-pick 충돌 방지)


'''

    content = content.replace(
        "def auto_name_from_cwd(",
        nco_func + "def auto_name_from_cwd("
    )

    old_body = "    base = os.path.basename(cwd or os.getcwd()).lower()"
    new_body = """    nco = _nco_name_from_pid()
    if nco:
        return nco

    base = os.path.basename(cwd or os.getcwd()).lower()"""

    content = content.replace(old_body, new_body)

    shared.write_text(content, encoding="utf-8")
    print("[patch] shared.py patched successfully")
    return True


def patch_monitors_json(version_dir):
    """
    NCO 패치 v3 (2026-05-26): noop.

    이전 v1/v2는 client.py 앞에 `python3 -c "...print(ns[0])" |` 를 prepend했지만:
    1. client.py는 stdin을 읽지 않는다 (--name 인자 또는 INTER_SESSION_NAME env만 사용).
    2. shared.py 패치(_nco_name_from_pid)가 이미 NCO 이름을 직접 detect한다.
    3. 매 세션마다 prepend가 누적되어 monitors.json command가 종양처럼 부풀어 깨졌다 (80+회 파이프).

    monitors.json 복구는 marketplace 원본 사용:
      cp ~/.claude/plugins/marketplaces/inter-session/monitors/monitors.json \\
         ~/.claude/plugins/cache/inter-session/inter-session/<ver>/monitors/monitors.json
    """
    monitors = version_dir / "monitors" / "monitors.json"
    if not monitors.exists():
        print("[patch] monitors.json not found")
        return False

    # 멱등 가드: 부풀어 있으면 marketplace 원본으로 자동 복구.
    text = monitors.read_text(encoding="utf-8")
    if text.count("python3 -c") > 1 or len(text) > 2000:
        marketplace = CLAUDE_DIR / "plugins" / "marketplaces" / "inter-session" / "monitors" / "monitors.json"
        if marketplace.exists():
            monitors.write_text(marketplace.read_text(encoding="utf-8"), encoding="utf-8")
            print("[patch] monitors.json restored from marketplace (was bloated)")
            return True

    print("[patch] monitors.json: noop (v3 — patch unnecessary)")
    return True


def patch_client_py_tailscale(version_dir):
    """
    v3-tailscale (2026-05-27): client.py가 외부 host에 connect할 수 있도록 두 곳 패치.

    이유:
      1. spawn.ensure_server_running: 외부 host에선 본인이 server를 spawn할 수 없음
         (다른 머신에 떠 있어야 함). 그대로 두면 EADDRNOTAVAIL.
      2. verify_server_identity: 로컬 pidfile/psutil 기반 검증 — 다른 머신의 server는
         pidfile 없어 항상 False. 외부 host에선 token 인증으로 충분
         (port squatting은 동일 머신 한정 위협).

    idempotent: marker 'NCO 패치 v3-tailscale' 발견 시 skip.
    """
    client = version_dir / "skills" / "inter-session" / "bin" / "client.py"
    if not client.exists():
        print("[patch] client.py not found")
        return False

    content = client.read_text(encoding="utf-8")
    MARKER = "NCO 패치 v3-tailscale"
    if MARKER in content:
        print("[patch] client.py already patched (v3-tailscale)")
        return True

    spawn_old = "                spawn.ensure_server_running(self.port, self.host, self.idle_shutdown_minutes)"
    spawn_new = (
        "                # NCO 패치 v3-tailscale (2026-05-27): host가 내 인터페이스 IP면 spawn, 외부면 skip\n"
        "                if _nco_is_local_host(self.host):\n"
        "                    spawn.ensure_server_running(self.port, self.host, self.idle_shutdown_minutes)\n"
        "                # else: external host (peer 머신의 IP) — 본인이 spawn 안 함"
    )

    verify_old = "        if not shared.verify_server_identity(self.host, self.port):"
    verify_new = (
        "        # NCO 패치 v3-tailscale (2026-05-27): local host만 squatting 검증, 외부는 token 인증으로 충분\n"
        "        if _nco_is_local_host(self.host) and not shared.verify_server_identity(self.host, self.port):"
    )

    if spawn_old not in content:
        print("[patch] client.py spawn line marker not found — version mismatch?")
        return False
    if verify_old not in content:
        print("[patch] client.py verify line marker not found — version mismatch?")
        return False

    # _nco_is_local_host helper: 127.0.0.1 + 현재 머신 IPv4 인터페이스 IP들과 매칭
    helper = (
        '\n# NCO 패치 v3-tailscale (2026-05-27): local interface IP set 캐싱·매칭\n'
        'def _nco_is_local_host(host: str) -> bool:\n'
        '    if host in ("127.0.0.1", "localhost", "0.0.0.0"):\n'
        '        return True\n'
        '    try:\n'
        '        import subprocess as _sp\n'
        '        out = _sp.run(["ip", "-4", "-o", "addr"], capture_output=True, text=True, timeout=2)\n'
        '        for line in out.stdout.splitlines():\n'
        '            parts = line.split()\n'
        '            if len(parts) >= 4:\n'
        '                if parts[3].split("/")[0] == host:\n'
        '                    return True\n'
        '    except Exception:\n'
        '        pass\n'
        '    try:\n'
        '        import socket as _sk\n'
        '        for info in _sk.getaddrinfo(_sk.gethostname(), None, _sk.AF_INET):\n'
        '            if info[4][0] == host:\n'
        '                return True\n'
        '    except Exception:\n'
        '        pass\n'
        '    return False\n\n\n'
    )
    # helper는 첫 'class Client' 정의 전에 삽입 (idempotent — marker로 중복 방지)
    class_marker = "class Client:"
    if class_marker in content and "_nco_is_local_host" not in content:
        content = content.replace(class_marker, helper + class_marker, 1)

    content = content.replace(spawn_old, spawn_new, 1)
    content = content.replace(verify_old, verify_new, 1)

    client.write_text(content, encoding="utf-8")
    print("[patch] client.py patched (v3-tailscale: external host support)")
    return True


def patch_shared_py_wildcard(version_dir):
    """
    v4-wildcard (2026-06-03): verify_server_identity 가 0.0.0.0 바인드 서버를
    모든 로컬 dial host 에 대해 신뢰하도록 fallback 추가.

    이유:
      pidfile 은 host 문자열 정확 일치로 키잉됨 (server.<host>.<port>.pid).
      세션 간 INTER_SESSION_HOST 가 드리프트하면 (예: 어떤 세션은 stale
      tailscale IP 100.x, 다른 세션은 통일된 0.0.0.0) — 서버는 0.0.0.0 으로
      뜨는데 stale 세션 client 는 server.100.x.<port>.pid 를 찾다 실패,
      fail-closed 로 연결 거부. 실제로 0.0.0.0 바인드는 모든 로컬 인터페이스를
      수신하므로 그 client 의 정당한 리스너다.

    fix: 정확 host pidfile 부재 시 0.0.0.0 pidfile 로 fallback 후 그 host 로
    meta/cmdline 검증. 위협모델 불변 (same-UID pidfile 신뢰 — server.py cmdline
    + meta.pid 매칭 그대로 요구).

    idempotent: marker 'NCO 패치 v4-wildcard' 발견 시 skip.
    """
    shared = version_dir / "skills" / "inter-session" / "bin" / "shared.py"
    if not shared.exists():
        print("[patch] shared.py not found (v4-wildcard)")
        return False

    content = shared.read_text(encoding="utf-8")
    MARKER = "NCO 패치 v4-wildcard"
    if MARKER in content:
        print("[patch] shared.py already patched (v4-wildcard)")
        return True

    anchor = (
        "    pid_path, meta_path, using_legacy_path = _identity_lookup_paths(host, port)\n"
        "    if not pid_path.exists():\n"
        "        return False\n"
    )
    if anchor not in content:
        print("[patch] v4-wildcard anchor not found — version mismatch, skipping")
        return False

    replacement = (
        "    pid_path, meta_path, using_legacy_path = _identity_lookup_paths(host, port)\n"
        "    # NCO 패치 v4-wildcard (2026-06-03): 0.0.0.0 바인드 서버는 모든 로컬 dial host의\n"
        "    # 정당한 리스너. host-string 드리프트(stale INTER_SESSION_HOST)로 인한 fail-closed 방지.\n"
        "    if host not in (None, \"0.0.0.0\") and not pid_path.exists():\n"
        "        _w = _identity_lookup_paths(\"0.0.0.0\", port)\n"
        "        if _w[0].exists():\n"
        "            pid_path, meta_path, using_legacy_path = _w\n"
        "            host = \"0.0.0.0\"\n"
        "    if not pid_path.exists():\n"
        "        return False\n"
    )

    content = content.replace(anchor, replacement, 1)
    shared.write_text(content, encoding="utf-8")
    print("[patch] shared.py patched (v4-wildcard: 0.0.0.0 bind trust)")
    return True


def patch_client_py_bind_wildcard(version_dir):
    """
    v4-wildcard (2026-06-03): spawn 경로의 bind host를 항상 0.0.0.0 으로 강제.

    이유 (verify fix 의 대칭 보완):
      verify_server_identity fix 는 'server=0.0.0.0, client=특정IP' 방향만 닫는다.
      반대 방향 'server=특정IP-only bind, client=0.0.0.0/127.0.0.1 dial' 은
      identity 거부가 아니라 TCP 도달 실패라 verify 로는 못 고친다.
      특정-IP 서버를 만드는 주체 = INTER_SESSION_HOST 가 특정 IP 인 세션이
      spawn 레이스를 이길 때 (ensure_server_running 이 self.host 로 bind).
      bind 를 항상 0.0.0.0 으로 강제하면 어떤 세션이 spawn 하든 모든 로컬 dial
      host 가 도달 가능 → 양방향 폐쇄. dial host(self.host)는 유지.
      사용자 .bashrc/.profile 의 INTER_SESSION_HOST=0.0.0.0 의도와도 일치.

    v3-tailscale 패치 이후의 라인을 대상으로 하므로 그 뒤에 실행돼야 함.
    idempotent: 0.0.0.0 bind 인자 발견 시 skip.
    """
    client = version_dir / "skills" / "inter-session" / "bin" / "client.py"
    if not client.exists():
        print("[patch] client.py not found (bind-wildcard)")
        return False

    content = client.read_text(encoding="utf-8")
    if 'spawn.ensure_server_running(self.port, "0.0.0.0"' in content:
        print("[patch] client.py already patched (bind-wildcard)")
        return True

    anchor = (
        "                if _nco_is_local_host(self.host):\n"
        "                    spawn.ensure_server_running(self.port, self.host, self.idle_shutdown_minutes)\n"
    )
    if anchor not in content:
        print("[patch] bind-wildcard anchor not found (v3-tailscale not applied yet?) — skipping")
        return False

    replacement = (
        "                if _nco_is_local_host(self.host):\n"
        "                    # NCO 패치 v4-wildcard (2026-06-03): bind는 항상 0.0.0.0 (모든 로컬 인터페이스 수신).\n"
        "                    # dial host(self.host)는 유지 — 특정IP-only 바인드로 인한 연결 비대칭 차단.\n"
        "                    spawn.ensure_server_running(self.port, \"0.0.0.0\", self.idle_shutdown_minutes)\n"
    )

    content = content.replace(anchor, replacement, 1)
    client.write_text(content, encoding="utf-8")
    print("[patch] client.py patched (bind-wildcard: force 0.0.0.0 bind on spawn)")
    return True


def patch_client_py_identity_retry(version_dir):
    """
    v5-identity-retry (2026-06-06): server identity check 실패를 fatal 종료가 아닌
    재시도 가능 오류로 전환.

    이전 버그:
      _connect_and_serve 가 verify_server_identity 실패 시 self._stop.set() 후 return →
      run() 의 `while not self._stop.is_set()` 루프가 영구 종료. 모니터가 죽어 idle
      wake-up 채널이 닫힘. 대량 동시 rename 시 server spawn 경합(EADDRINUSE)으로
      패배 프로세스가 공용 pidfile(server.0.0.0.0.<port>.pid)을 삭제 → 그 순간
      verify 가 일시적으로 False → 무관한 정상 세션들의 모니터가 줄줄이 死.

    fix:
      self._stop.set() 제거하고 OSError raise. run() 루프의
      `except (ConnectionRefusedError, OSError)` 가 잡아 지수 backoff 후 재시도하며,
      매 라운드 ensure_server_running 이 server/pidfile 을 재생성 → 레이스 자가복구.

    위협모델 불변:
      토큰은 verify 통과 후에만 전송(_connect_and_serve 가 매 라운드 재검증).
      실패 시 토큰 미전송 + 재시도이므로 squatter 토큰 유출 위험 동일.

    idempotent: marker 'NCO 패치 v5-identity-retry' 발견 시 skip.
    """
    client = version_dir / "skills" / "inter-session" / "bin" / "client.py"
    if not client.exists():
        print("[patch] client.py not found (v5-identity-retry)")
        return False

    content = client.read_text(encoding="utf-8")
    MARKER = "NCO 패치 v5-identity-retry"
    if MARKER in content:
        print("[patch] client.py already patched (v5-identity-retry)")
        return True

    anchor = (
        '                f"(port {self.port} is held by something that isn\'t bin/server.py); "\n'
        '                "refusing to connect"\n'
        "            )\n"
        "            self._stop.set()\n"
        "            return\n"
    )
    if anchor not in content:
        print("[patch] v5-identity-retry anchor not found — version mismatch or already changed, skipping")
        return False

    replacement = (
        '                f"(port {self.port} is held by something that isn\'t bin/server.py); "\n'
        '                "refusing to connect"\n'
        "            )\n"
        "            # NCO 패치 v5-identity-retry (2026-06-06): fatal(self._stop.set()) 대신 OSError raise →\n"
        "            # run() 루프가 지수 backoff 로 재시도 + 매 라운드 ensure_server_running 으로 server/pidfile\n"
        "            # 재생성(레이스 자가복구). 토큰은 검증 통과 후에만 전송 → squatter 유출 위험 불변.\n"
        "            raise OSError(\n"
        '                f"inter-session: server identity check failed on port {self.port}; will retry"\n'
        "            )\n"
    )

    content = content.replace(anchor, replacement, 1)
    client.write_text(content, encoding="utf-8")
    print("[patch] client.py patched (v5-identity-retry: transient identity fail → retry)")
    return True


def check_tailscale_setup():
    """
    v3-tailscale (2026-05-27) 안내: setup wizard 존재 확인.
    실제 코드 패치는 patch_client_py_tailscale 가 담당.
    """
    setup = CLAUDE_DIR / "hooks" / "inter-session-setup.sh"
    if setup.exists():
        print("[patch] tailscale-bind v3: wizard ready (~/.claude/hooks/inter-session-setup.sh)")
    else:
        print("[patch] tailscale-bind v3: WARNING setup.sh missing — wizard unavailable")
    return True


def main():
    latest = find_latest_version()
    if not latest:
        print("[patch] inter-session plugin not found (install it first via /install-plugin)")
        sys.exit(0)

    print(f"[patch] Found plugin at {latest}")
    patch_shared_py(latest)
    patch_monitors_json(latest)
    patch_client_py_tailscale(latest)
    patch_shared_py_wildcard(latest)
    patch_client_py_bind_wildcard(latest)
    patch_client_py_identity_retry(latest)
    check_tailscale_setup()
    print("[patch] done")


if __name__ == "__main__":
    main()
