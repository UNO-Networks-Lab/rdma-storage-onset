#!/usr/bin/env bash
# run-incast.sh -- E-incast: the TRUE form of the pathology. N initiators write
# concurrently to one target (null_blk over nvmet-rdma); their flush streams
# converge on the target's single switch port, oversubscribing it N:1 -> PFC /
# ECN / go-back-N -> the multi-second tail. Per-initiator CAS bounds each
# sender's concurrency, cutting aggregate switch pressure.
#
# Runs from the LOCAL orchestrator over SSH. Assumes the target is already
# exporting null_blk, every initiator is connected to it, and cas_gate is built
# on each initiator (use incast-setup.sh first). Sweeps fan-in N x admission
# policy, launching the N gates SIMULTANEOUSLY so their writes actually collide.
#
#   ./run-incast.sh <expbase> <outdir> [reps]
#   expbase = cas-incast.dsscc-pg0.utah.cloudlab.us
set -euo pipefail
EXP="${1:?usage: run-incast.sh <expbase> <outdir> [reps]}"
OUT="${2:?outdir}"; REPS="${3:-3}"
KEY=${KEY:-$HOME/.ssh/cloudlab_ed25519}
USER_CL=${USER_CL:?set USER_CL to your CloudLab username}   # overridable so this can be rehearsed off-CloudLab
OPTS="-i $KEY -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"
MAXN=${MAXN:-4}        # initiators available (export MAXN=8 for the 8:1 window)
W=${W:-8}              # flush clients per initiator
L=${L:-2}              # append clients per initiator
DUR=${DUR:-15}         # seconds/run
BYTES=${BYTES:-2097152}     # flush transfer size S in bytes (4 MiB = 4194304)
NLIST=${NLIST:-"1 2 3 4"}   # fan-in points to sweep (export NLIST="1 2 4 8")
mkdir -p "$OUT"

init() { echo "$USER_CL@initiator$1.$EXP"; }
host() { echo "$USER_CL@$1.$EXP"; }

# The collapse criterion in this project is a COUNTER criterion: a level is
# "clean" when these read zero deltas and "collapsed" when they move (246
# retx/rep at the measured 4:1 collapse point). This runner previously logged
# only latency, so a P1 run could not be scored against its own pre-registered
# criterion. Snapshot before and after every arm, on the target and every
# initiator.
CTRS="local_ack_timeout_err packet_seq_err out_of_sequence rnr_nak_retry_err out_of_buffer np_cnp_sent"
snap() {   # $1 = node name
  # An ABSENT counter must NEVER read as 0. These names are mlx5-specific; on
  # soft-RoCE (rxe) none of them exist, and a `|| echo 0` fallback would report
  # a perfectly clean run for a fabric whose collapse signature we cannot see at
  # all. On CloudLab the same fallback would turn a wrong device name into
  # "P1 falsified".
  ssh $OPTS "$(host "$1")" 'source /local/dsscc-env 2>/dev/null; for c in '"$CTRS"'; do
    f=/sys/class/infiniband/$RDMA_DEV/ports/1/hw_counters/$c
    if [ -e "$f" ]; then printf "%s=%s\n" "$c" "$(cat $f 2>/dev/null || echo ABSENT)"
    else printf "%s=ABSENT\n" "$c"; fi; done' 2>/dev/null
}
snap_all() {  # $1 = N, $2 = dir, $3 = suffix (before|after)
  snap target > "$2/target.$3" &
  local p=($!)
  for i in $(seq 1 "$1"); do snap "initiator$i" > "$2/init${i}.$3" & p+=($!); done
  for x in "${p[@]}"; do wait "$x" 2>/dev/null; done
}
# retx delta across one arm, so the collapse signature is visible AS IT RUNS
retx_delta() {  # $1 = dir, $2 = N
  python3 - "$1" "$2" <<'PYEOF' 2>/dev/null || echo "n/a"
import sys, os, glob
d, n = sys.argv[1], int(sys.argv[2])
KEY = ("local_ack_timeout_err", "packet_seq_err", "out_of_sequence")
tot = 0
for b in glob.glob(os.path.join(d, "*.before")):
    a = b[:-7] + ".after"
    if not os.path.exists(a):
        continue
    rd = lambda f: {k: int(v) for k, v in
                    (l.strip().split("=") for l in open(f) if "=" in l)}
    try:
        B = dict(l.strip().split("=") for l in open(b) if "=" in l)
        A = dict(l.strip().split("=") for l in open(a) if "=" in l)
    except ValueError:
        continue
    for k in KEY:
        if B.get(k) == "ABSENT" or A.get(k) == "ABSENT" or k not in A or k not in B:
            print("ABSENT"); sys.exit(0)
        tot += max(0, int(A[k]) - int(B[k]))
print(tot)
PYEOF
}

# one measurement: launch cas_gate on initiators 1..N at once, pull their logs
one() {                # $1=N $2=tag $3=rep  rest=cas_gate mode args
  local N="$1" tag="$2" rep="$3"; shift 3
  local d="$OUT/N${N}_${tag}_r${rep}"; mkdir -p "$d"
  snap_all "$N" "$d" before
  local pids=()
  for i in $(seq 1 "$N"); do
    ssh $OPTS "$(init "$i")" \
      "cd ~/hw-cas && DEV=\$(for n in /dev/nvme*n1; do c=\$(basename \$n|sed 's/n[0-9]*\$//'); grep -q dsscc /sys/class/nvme/\$c/subsysnqn 2>/dev/null && echo \$n && break; done) && \
       sudo ./cas_gate --dev \$DEV --batch-size $BYTES --flush-clients $W --append-clients $L \
         --duration $DUR --seed $((100*rep + i)) $* \
         --log /tmp/incast_i${i}.csv >/tmp/incast_i${i}.sum 2>&1" &
    pids+=($!)
  done
  local fail=0; for p in "${pids[@]}"; do wait "$p" || fail=1; done
  for i in $(seq 1 "$N"); do
    scp $OPTS -q "$(init "$i"):/tmp/incast_i${i}.csv" "$d/init${i}.csv" 2>/dev/null || true
    scp $OPTS -q "$(init "$i"):/tmp/incast_i${i}.sum" "$d/init${i}.sum" 2>/dev/null || true
  done
  snap_all "$N" "$d" after
  echo "  N=$N $tag rep$rep done (fail=$fail, retx=$(retx_delta "$d" "$N"))"
}

# SHUFFLE=1 randomises the order in which (fan-in, policy, rep) arms are run.
# The fixed order above confounds arm with time: any monotone drift in testbed
# state -- thermal, neighbour traffic, a slowly filling buffer -- aliases onto
# whatever the loop varies slowest. The paper's limitations section concedes
# this; randomising removes it rather than bounding it. SEED makes the order
# reproducible, and the realised order is written to the output directory so a
# reader can check it was not cherry-picked.
if [ "${SHUFFLE:-0}" = 1 ]; then
  mapfile -t ARMS < <(
    for N in $NLIST; do
      [ "$N" -le "$MAXN" ] || continue
      for r in $(seq 1 "$REPS"); do
        echo "$N baseline $r"; echo "$N cas-k1 $r"; echo "$N cas-k2 $r"
      done
    done | shuf --random-source=<(yes "${SEED:-icnc}")
  )
  printf '%s\n' "${ARMS[@]}" > "$OUT/arm_order.txt"
  echo "== randomised order (${#ARMS[@]} arms), recorded in $OUT/arm_order.txt =="
  for a in "${ARMS[@]}"; do
    read -r N tag r <<<"$a"
    case "$tag" in
      baseline) one "$N" baseline "$r" --mode baseline ;;
      cas-k1)   one "$N" cas-k1   "$r" --mode cas --k 1 ;;
      cas-k2)   one "$N" cas-k2   "$r" --mode cas --k 2 ;;
    esac
  done
else
for N in $NLIST; do
  [ "$N" -le "$MAXN" ] || continue
  echo "== fan-in $N:1 =="
  for r in $(seq 1 "$REPS"); do
    one "$N" baseline "$r" --mode baseline
    one "$N" cas-k1   "$r" --mode cas --k 1
    one "$N" cas-k2   "$r" --mode cas --k 2
  done
done
fi
echo "done -> $OUT"
echo "analyze: python3 $(dirname "$0")/analyze-incast.py $OUT"
