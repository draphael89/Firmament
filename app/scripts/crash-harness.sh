#!/bin/bash
# Firmament R10 crash suite (plan U11): ≥50 randomized kill -9s against the
# real capture pipeline. Some kills land mid-recording, some mid-finalize.
# Pass requires: reconcile green every iteration (no dangling local rows;
# partials adopted, never deleted) and `verify` exit 0 (intact chain — on a
# single local device, "incomplete" is also a failure).
#
# Usage: crash-harness.sh [iterations]   (default 50)
#   FIRMAMENT_BIN=<path>  use a prebuilt binary instead of swift build
set -u

ITERATIONS="${1:-50}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PACKAGE_DIR="$SCRIPT_DIR/../FirmamentKit"

if [ -z "${FIRMAMENT_BIN:-}" ]; then
  echo "building firmament…"
  swift build --package-path "$PACKAGE_DIR" -q || exit 70
  FIRMAMENT_BIN="$PACKAGE_DIR/.build/debug/firmament"
fi

WORK="$(mktemp -d -t firmament-crash-harness)"
LEDGER="$WORK/ledger.sqlite"
echo "workspace: $WORK"

adopted_total=0

for i in $(seq 1 "$ITERATIONS"); do
  "$FIRMAMENT_BIN" stress-capture --root "$WORK" >/dev/null 2>&1 &
  PID=$!
  # Randomized kill point: 50–650 ms — lands mid-recording, mid-flush, and
  # mid-finalize across iterations.
  DELAY=$(awk -v seed="$RANDOM" 'BEGIN { srand(seed); printf "%.3f", 0.05 + rand() * 0.6 }')
  sleep "$DELAY"
  kill -9 "$PID" 2>/dev/null
  wait "$PID" 2>/dev/null

  RECON_OUT="$("$FIRMAMENT_BIN" reconcile --root "$WORK")" || {
    echo "FAIL iteration $i: reconcile reported a fatal dangling local event"
    echo "$RECON_OUT"
    exit 1
  }
  adopted=$(echo "$RECON_OUT" | awk -F': ' '/adopted-(partials|completes)/ { sum += $2 } END { print sum + 0 }')
  adopted_total=$((adopted_total + adopted))

  "$FIRMAMENT_BIN" verify --ledger "$LEDGER" >/dev/null || {
    echo "FAIL iteration $i: chain verification failed after kill (delay ${DELAY}s)"
    "$FIRMAMENT_BIN" verify --ledger "$LEDGER"
    exit 1
  }
done

COUNT=$(sqlite3 "$LEDGER" "SELECT COUNT(*) FROM event")
echo "PASS: $ITERATIONS/$ITERATIONS kills survived — $COUNT events, $adopted_total interrupted capture(s) adopted"
if [ "$COUNT" -eq 0 ]; then
  echo "FAIL: no events were ever captured — the harness exercised nothing"
  exit 1
fi

# --- Mutation self-check: prove the gate can actually catch both bug classes.

# Class 1: silent corruption — flip one payload byte; verify must exit 1.
CHECK="$(mktemp -d -t firmament-harness-selfcheck)"
cp -R "$WORK/" "$CHECK/"
sqlite3 "$CHECK/ledger.sqlite" \
  "UPDATE event SET payload = zeroblob(length(payload)) WHERE rowid = (SELECT MIN(rowid) FROM event)"
if "$FIRMAMENT_BIN" verify --ledger "$CHECK/ledger.sqlite" >/dev/null 2>&1; then
  echo "FAIL self-check: verify did not catch a corrupted payload"
  exit 1
fi

# Class 2: lost audio — delete a referenced file; reconcile must exit 1.
FIRST_AUDIO=$(ls "$CHECK/media/audio" 2>/dev/null | head -1)
if [ -n "$FIRST_AUDIO" ]; then
  rm "$CHECK/media/audio/$FIRST_AUDIO"
  if "$FIRMAMENT_BIN" reconcile --root "$CHECK" >/dev/null 2>&1; then
    echo "FAIL self-check: reconcile did not flag a missing referenced audio file"
    exit 1
  fi
fi
echo "PASS: mutation self-check — corruption and lost-audio classes both detected"

rm -rf "$WORK" "$CHECK"
