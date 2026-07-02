# FILE: /home/nova/projects/neural-cli-orchestrator/handoff-send.py
# Example:
#   python3 handoff-send.py --task-id task1 --desc "Implement X" --outcome done --summary "Done" \
#     --evidence '[{"tier":"T1","method":"file_read","claim":"file exists","raw":"/tmp/x"},{"tier":"T3","method":"exit_code","claim":"tests pass","raw":"exit 0"}]'

import argparse
import json
import os
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path


OUTCOMES = ("done", "partial", "failed", "question")


def load_json_arg(value, name, default):
    if value is None:
        return default
    try:
        return json.loads(value)
    except json.JSONDecodeError as exc:
        raise SystemExit(f"{name}: invalid JSON: {exc}") from exc


def require_type(value, name, expected_type):
    if not isinstance(value, expected_type):
        raise SystemExit(f"{name}: expected {expected_type.__name__}")
    return value


def utc_timestamp():
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def make_packet(args):
    evidence = require_type(load_json_arg(args.evidence, "--evidence", []), "--evidence", list)
    artifacts = require_type(load_json_arg(args.artifacts, "--artifacts", []), "--artifacts", list)
    unverified = require_type(load_json_arg(args.unverified, "--unverified", []), "--unverified", list)
    resume = load_json_arg(args.resume, "--resume", None)
    if resume is not None:
        require_type(resume, "--resume", dict)

    packet = {
        "schema_version": "1.0",
        "sender": {
            "agent_name": os.getenv("AGENT_NAME", "unknown"),
            "session_id": os.getenv("SESSION_ID"),
            "timestamp": utc_timestamp(),
        },
        "task": {
            "id": args.task_id,
            "description": args.desc,
        },
        "outcome": args.outcome,
        "summary": args.summary,
        "evidence": evidence,
        "artifacts": artifacts,
        "unverified": unverified,
    }
    if resume is not None:
        packet["resume"] = resume
    return packet


def resolve_send_py(send_bin):
    if not send_bin:
        raise SystemExit("--to requires --send-bin or INTER_SESSION_BIN")
    path = Path(send_bin).expanduser()
    if path.is_dir():
        path = path / "send.py"
    if not path.exists():
        raise SystemExit(f"send.py not found: {path}")
    return path


def fit_summary(summary, budget):
    if budget <= 0:
        return ""
    if len(summary) <= budget:
        return summary
    if budget <= 3:
        return "." * budget
    return summary[: budget - 3] + "..."


def message_for_bus(packet, packet_json, packet_dir):
    full_message = f"{packet['outcome']}: {packet_json}"
    if len(full_message) <= 400:
        return full_message, None

    out_dir = Path(packet_dir).expanduser()
    out_dir.mkdir(parents=True, exist_ok=True)
    packet_path = out_dir / f"{packet['task']['id']}.json"
    packet_path.write_text(json.dumps(packet, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    prefix = f"{packet['outcome']}: outcome={packet['outcome']}, summary='"
    suffix = f"'. Full packet at {packet_path}"
    summary_budget = 400 - len(prefix) - len(suffix)
    if summary_budget < 0:
        raise SystemExit(f"truncated message path is too long for 400 chars: {packet_path}")
    compact_summary = fit_summary(packet["summary"], summary_budget)
    return f"{prefix}{compact_summary}{suffix}", packet_path


def send_to_peer(send_py, peer, text):
    subprocess.run(
        [sys.executable, str(send_py), "--to", peer, "--text", text],
        check=True,
        text=True,
        stdout=sys.stderr,
    )


def main():
    parser = argparse.ArgumentParser(description="Create and optionally send an NCO handoff packet v1.")
    parser.add_argument("--task-id", required=True)
    parser.add_argument("--desc", required=True)
    parser.add_argument("--outcome", required=True, choices=OUTCOMES)
    parser.add_argument("--summary", required=True)
    parser.add_argument("--evidence")
    parser.add_argument("--artifacts")
    parser.add_argument("--unverified")
    parser.add_argument("--resume")
    parser.add_argument("--to")
    parser.add_argument("--send-bin", default=os.getenv("INTER_SESSION_BIN"))
    parser.add_argument("--packet-dir", default="~/.nco/handoffs")
    args = parser.parse_args()

    packet = make_packet(args)
    packet_json = json.dumps(packet, ensure_ascii=False, separators=(",", ":"))

    print(f"{args.outcome}: {packet_json}", flush=True)

    if args.to:
        send_py = resolve_send_py(args.send_bin)
        bus_message, _packet_path = message_for_bus(packet, packet_json, args.packet_dir)
        send_to_peer(send_py, args.to, bus_message)


if __name__ == "__main__":
    main()
