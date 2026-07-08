#!/usr/bin/env python3
"""Read the KTD11 verdict out of the phone's own ledger (SPEC §9.2, plan U1).

Prerequisite is one physical Action Button press on a locked phone. The capture
instruments itself; this only interprets what it wrote.

A cold press — the one SPEC §9.2 budgets — spends most of its time before
`start()` ever runs: process spawn, App Intents resolution, PhoneModel init.
That is `processAgeAtStartMS`. `startLatencyMS` covers only audio-session
activation and engine start. Press-to-first-sample is at least their sum; the
press-to-spawn gap is not observable from inside the process.

    usage: app/scripts/action-button-latency.py [device-udid]

Exit 0 within budget, 1 over budget, 2 if the press hasn't happened yet.
"""

import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

DEFAULT_DEVICE = "00008150-001C04AA3AC1401C"
APP_GROUP = "group.com.davidraphael.firmament"
LEDGER_DIR = "Library/Application Support/Firmament"
BUDGET_MS = 2000
# A process younger than this when start() ran was spawned to serve the press.
COLD_CEILING_MS = 10_000


def pull_ledger(device: str, workdir: Path) -> Path:
    for name in ("ledger.sqlite", "ledger.sqlite-wal"):
        subprocess.run(
            [
                "xcrun", "devicectl", "device", "copy", "from",
                "--device", device,
                "--source", f"{LEDGER_DIR}/{name}",
                "--destination", str(workdir / name),
                "--domain-type", "appGroupDataContainer",
                "--domain-identifier", APP_GROUP,
            ],
            capture_output=True,
        )
    ledger = workdir / "ledger.sqlite"
    if not ledger.exists():
        sys.exit("could not pull the phone ledger (is the device attached and trusted?)")
    return ledger


def captures(ledger: Path) -> list[dict]:
    out = subprocess.run(
        ["sqlite3", str(ledger),
         "SELECT payload FROM event WHERE kind='capture.audio' ORDER BY recorded_at;"],
        capture_output=True, text=True, check=True,
    ).stdout
    return [json.loads(line) for line in out.splitlines() if line.strip()]


def main() -> int:
    device = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_DEVICE
    if not shutil.which("xcrun"):
        sys.exit("xcrun not found")

    with tempfile.TemporaryDirectory() as tmp:
        rows = captures(pull_ledger(device, Path(tmp)))

    presses = [
        r for r in rows
        if r.get("context", {}).get("source") == "actionButton"
        and "startLatencyMS" in r.get("context", {})
    ]
    if not presses:
        instrumented = sum("startLatencyMS" in r.get("context", {}) for r in rows)
        print(f"No instrumented Action Button capture yet "
              f"({len(rows)} captures on the phone, {instrumented} instrumented).")
        print("Assign the shortcut, lock the phone, press, speak, press again.")
        return 2

    worst_cold = None
    for r in presses:
        ctx = r["context"]
        when = r.get("occurredAt", "?")
        engine = int(ctx["startLatencyMS"])
        age = int(ctx.get("processAgeAtStartMS", -1))
        if age < 0:
            print(f"  {when}  engine {engine} ms  (pre-fix build — launch cost unmeasured)")
        elif age <= COLD_CEILING_MS:
            total = age + engine
            worst_cold = total if worst_cold is None else max(worst_cold, total)
            print(f"  {when}  COLD  launch {age} ms + engine {engine} ms "
                  f"= >={total} ms press-to-first-sample")
        else:
            print(f"  {when}  warm  engine {engine} ms "
                  f"(process was already {age / 1000:.0f}s old)")

    print()
    if worst_cold is None:
        print("No cold press recorded. Lock the phone first — a warm press does not test KTD11.")
        return 2
    if worst_cold > BUDGET_MS:
        print(f"OVER BUDGET: {worst_cold} ms > {BUDGET_MS} ms. "
              f"KTD11 flips to the warm-session fallback (plan Risks).")
        return 1
    print(f"WITHIN BUDGET: {worst_cold} ms <= {BUDGET_MS} ms. "
          f"KTD11 stands as specified (AudioRecordingIntent).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
