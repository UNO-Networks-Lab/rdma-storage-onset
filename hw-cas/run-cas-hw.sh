#!/usr/bin/env bash
# run-cas-hw.sh -- E1 hardware experiment (closed-loop): does CAS fix the
# processor-sharing pathology on real NVMe-oF/RoCE, and beat the naive
# "just cap iodepth" fix? Sweeps admission policies with a fixed set of
# closed-loop clients (bounded outstanding), N reps each; writes per-I/O logs
# + summaries for analyze-cas-hw.py.
#
# Prereq: initiator connected to the target namespace; $DEV is that block dev.
# liburing-dev installed. Run on the INITIATOR.
#
#   sudo ./run-cas-hw.sh /dev/nvme2n1 ./out 5
set -euo pipefail
DEV="${1:?usage: run-cas-hw.sh <nvme-of-dev> <outdir> [reps]}"
OUT="${2:?outdir required}"
REPS="${3:-5}"
[ -b "$DEV" ] || { echo "ERROR: $DEV is not a block device"; exit 1; }
echo "WARNING: writes O_DIRECT to $DEV (destructive). Scratch namespace only."

HERE="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$OUT"; command -v make >/dev/null && make -C "$HERE" >/dev/null
BIN="$HERE/cas_gate"

W=32          # flush clients: the queue-per-core fan-out that processor-shares
L=4           # append (latency-class) clients
DUR=15        # measured seconds/run
COMMON=(--dev "$DEV" --batch-size $((2*1024*1024)) --small-size $((64*1024))
        --flush-clients "$W" --append-clients "$L" --duration "$DUR")

run_mode() {                          # $1=name, rest=cas_gate args
  local name="$1"; shift
  for r in $(seq 1 "$REPS"); do
    echo "  [$name] rep $r/$REPS"
    "$BIN" "$@" --seed "$((1000+r))" \
        --log "$OUT/${name}_r${r}.csv" > "$OUT/${name}_r${r}.summary" 2>&1 || {
        echo "  !! $name rep $r failed:"; cat "$OUT/${name}_r${r}.summary"; }
  done
}

echo "== idle reference (1 flush + 1 append client) =="
run_mode idle     --dev "$DEV" --batch-size $((2*1024*1024)) --small-size $((64*1024)) \
                  --flush-clients 1 --append-clients 1 --duration 5 --mode cas --k 1
echo "== baseline (all $W flush clients concurrent) =="
run_mode baseline "${COMMON[@]}" --mode baseline
echo "== naivecap (class-unaware iodepth cap: baseline, qd=8) =="
run_mode naivecap "${COMMON[@]}" --mode baseline --qd 8
echo "== cas k=1/2/4 (flush admitted at K, append bypass) =="
run_mode cas-k1   "${COMMON[@]}" --mode cas --k 1
run_mode cas-k2   "${COMMON[@]}" --mode cas --k 2
run_mode cas-k4   "${COMMON[@]}" --mode cas --k 4

echo "done -> $OUT"
echo "analyze: python3 $HERE/analyze-cas-hw.py $OUT"
