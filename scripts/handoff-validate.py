# FILE: /home/nova/projects/neural-cli-orchestrator/handoff-validate.py
# Example:
#   python3 handoff-validate.py '{"outcome":"failed","summary":"command failed","evidence":[{"tier":"T3","method":"exit_code","raw":"exit 1"}]}'
#   python3 handoff-validate.py @/tmp/handoff.json

import argparse
import json
import sys
from pathlib import Path


RANK = {"T1": 1, "T2": 2, "T3": 3, "T4": 4}
PREFIXES = ("done", "partial", "failed", "question", "status", "error")


def load_packet(source):
    if source.startswith("@"):
        text = Path(source[1:]).expanduser().read_text(encoding="utf-8")
    else:
        text = source
    text = text.strip()
    for prefix in PREFIXES:
        marker = f"{prefix}:"
        if text.startswith(marker):
            text = text[len(marker) :].strip()
            break
    try:
        packet = json.loads(text)
    except json.JSONDecodeError as exc:
        raise SystemExit(f"REJECT: invalid JSON: {exc}") from exc
    if not isinstance(packet, dict):
        raise SystemExit("REJECT: packet must be a JSON object")
    return packet


def evidence_tiers(packet):
    evidence = packet.get("evidence", [])
    if not isinstance(evidence, list):
        raise SystemExit("REJECT: evidence must be an array")
    tiers = []
    for item in evidence:
        if not isinstance(item, dict):
            tiers.append("T4")
            continue
        tiers.append(item.get("tier", "T4"))
    return tiers


def validate(packet):
    outcome = packet.get("outcome")
    summary = packet.get("summary", "")
    tiers = evidence_tiers(packet)
    ranks = sorted(RANK.get(tier, 4) for tier in tiers)

    ok = True
    reason = ""
    if outcome == "done":
        ok = 1 in ranks and any(rank in (2, 3) for rank in ranks)
        reason = "done requires T1 plus one of T2/T3"
    elif outcome == "partial":
        ok = 1 in ranks
        reason = "partial requires at least one T1"
    elif outcome == "failed":
        ok = any(rank <= 3 for rank in ranks)
        reason = "failed requires T1-T3 evidence"
    elif outcome == "question":
        ok = True
    else:
        ok = False
        reason = "outcome must be one of done, partial, failed, question"

    if not ok:
        print(f"REJECT: {reason}. Got tiers={tiers}")
        return 1
    print(f"ACCEPT: {summary}")
    return 0


def main():
    parser = argparse.ArgumentParser(description="Validate an NCO handoff packet v1.")
    parser.add_argument("packet", help="JSON string, prefixed packet string, or @path")
    args = parser.parse_args()
    packet = load_packet(args.packet)
    raise SystemExit(validate(packet))


if __name__ == "__main__":
    main()
