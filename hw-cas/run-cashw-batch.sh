#!/usr/bin/env bash
# run-cashw-batch.sh -- extra single-initiator (100G) hardware runs:
#   (1) gate overhead: latency-class (append) fast path with the gate present
#       vs absent, under negligible batch load -- isolates the gate's per-op cost.
#   (2) frontier: k = 1..16 at W=32 -- the full throughput/tail trade on hardware.
# Runs ON the initiator (invoked over SSH by the launcher). Writes per-I/O logs
# + summaries for analyze-cas-hw.py-style pooling.
set -euo pipefail
DEV="${1:?dev}"; OUT="${2:?outdir}"; REPS="${3:-5}"
HERE="$(cd "$(dirname "$0")" && pwd)"; BIN="$HERE/cas_gate"
mkdir -p "$OUT"
run(){ local name="$1"; shift
  for r in $(seq 1 "$REPS"); do
    "$BIN" "$@" --seed "$((200+r))" --log "$OUT/${name}_r${r}.csv" > "$OUT/${name}_r${r}.summary" 2>&1 || true
  done; echo "  $name done"; }

echo "== overhead: append-dominated (W=1 flush, L=16 append), gate off vs on =="
run ovh-baseline --dev "$DEV" --flush-clients 1 --append-clients 16 --duration 12 --mode baseline
run ovh-cas      --dev "$DEV" --flush-clients 1 --append-clients 16 --duration 12 --mode cas --k 1

echo "== frontier: W=32, baseline + CAS k=1..16 =="
run fr-baseline --dev "$DEV" --flush-clients 32 --append-clients 4 --duration 15 --mode baseline
for k in 1 2 4 8 16; do
  run "fr-cas-k$k" --dev "$DEV" --flush-clients 32 --append-clients 4 --duration 15 --mode cas --k "$k"
done
echo "done -> $OUT"
