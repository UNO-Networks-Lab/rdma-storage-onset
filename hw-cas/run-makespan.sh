#!/usr/bin/env bash
# run-makespan.sh -- the FIXED-VOLUME batch makespan experiment.
#
# This is the falsification test the paper registers against Theorem C and has
# never performed. Theorem C's 1.87x advantage for bounded admission is
# currently DERIVED from stationary goodput, not measured; a committee asked for
# the app-visible number and we could not supply it. This measures it: every
# initiator writes a FIXED number of flush transfers, and we record wall-clock
# to completion. Makespan is the max over initiators, since they start together.
#
# The prediction is the interesting part: bounded admission runs at LOWER
# concurrency yet should finish SOONER, because above W* the retransmitted bytes
# consume the same bottleneck as useful work. If the gated arm is slower, the
# makespan half of Theorem C is false and must be withdrawn.
#
#   ./run-makespan.sh <expbase> <outdir> <N> <bytes> <ops-per-initiator> [reps]
#
# SIZING (measured on the frcc rehearsal, 2026-09-13). Makespan variance is
# dominated by startup jitter at short run lengths: at 20 ops/initiator the runs
# are 2-5 s and the spread ACROSS ALL ARMS is 27-33% of the mean, which is far
# larger than any effect worth reporting. Pick ops so a clean run lasts ~15-20 s.
# On the 25 GbE fabric (clean aggregate ~2800 MB/s, N=3):
#
#     S = 8 MiB  ->  ~1900 ops/initiator   (~44 GiB total)
#     S = 4 MiB  ->  ~3800 ops/initiator   (~44 GiB total)
#
# Note the op count DOUBLES when the transfer size halves -- it is the total
# bytes that sets the duration. Use 5+ reps. Collapsed arms run much longer than
# clean ones, which is the effect being measured, not a problem.
#
# CHOOSING N AND S. The gated arm must be genuinely SUBCRITICAL or the
# comparison is collapsed-vs-collapsed and tests nothing. Measured envelope:
# Phi <= 16 MiB clean, Phi >= 24 MiB collapsed. At N=3, k=1:
#     S = 8 MiB -> Phi = 24 MiB  ALREADY COLLAPSED -- do not use as the gated arm
#     S = 4 MiB -> Phi = 12 MiB  clean              -- use this
set -uo pipefail
EXP="${1:?usage: run-makespan.sh <expbase> <outdir> <N> <bytes> <ops> [reps]}"
OUT="${2:?outdir}"; N="${3:?N}"; BYTES="${4:?bytes}"; OPS="${5:?ops per initiator}"
REPS="${6:-3}"
KEY=${KEY:-$HOME/.ssh/cloudlab_ed25519}
USER_CL=${USER_CL:?set USER_CL to your CloudLab username}
OPTS="-i $KEY -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"
L=${L:-2}
W=${W:-8}
BARRIER=${BARRIER:-0}
mkdir -p "$OUT"
init(){ echo "$USER_CL@initiator$1.$EXP"; }
host(){ echo "$USER_CL@$1.$EXP"; }

# Snapshot the collapse-signature counters around each arm. Without these the
# collapse status of an arm has to be INFERRED from a separate sweep at the same
# Phi, which is what the first makespan run had to do. ABSENT must never read as
# 0 -- these names are mlx5-specific and a wrong device would otherwise make a
# collapsed arm look clean.
CTRS="local_ack_timeout_err packet_seq_err out_of_sequence rnr_nak_retry_err out_of_buffer np_cnp_sent"
snap(){
  ssh $OPTS "$(host "$1")" 'source /local/dsscc-env 2>/dev/null; for c in '"$CTRS"'; do
    f=/sys/class/infiniband/$RDMA_DEV/ports/1/hw_counters/$c
    if [ -e "$f" ]; then printf "%s=%s\n" "$c" "$(cat $f 2>/dev/null || echo ABSENT)"
    else printf "%s=ABSENT\n" "$c"; fi; done' 2>/dev/null
}
snap_all(){  # $1=dir $2=suffix
  snap target > "$1/target.$2" & local p=($!)
  for i in $(seq 1 "$N"); do snap "initiator$i" > "$1/init${i}.$2" & p+=($!); done
  for x in "${p[@]}"; do wait "$x" 2>/dev/null; done
}
retx_delta(){
  python3 - "$1" <<'PYEOF' 2>/dev/null || echo "n/a"
import sys,os,glob
d=sys.argv[1]; KEY=("local_ack_timeout_err","packet_seq_err","out_of_sequence"); tot=0
for b in glob.glob(os.path.join(d,"*.before")):
    a=b[:-7]+".after"
    if not os.path.exists(a): continue
    try:
        B=dict(l.strip().split("=") for l in open(b) if "=" in l)
        A=dict(l.strip().split("=") for l in open(a) if "=" in l)
    except ValueError: continue
    for k in KEY:
        if B.get(k)=="ABSENT" or A.get(k)=="ABSENT" or k not in A or k not in B:
            print("ABSENT"); sys.exit(0)
        tot+=max(0,int(A[k])-int(B[k]))
print(tot)
PYEOF
}
DISC='for n in /dev/nvme*n1; do c=$(basename $n|sed "s/n[0-9]*$//"); grep -q dsscc /sys/class/nvme/$c/subsysnqn 2>/dev/null && echo $n && break; done'

arm() {  # $1=tag $2=rep  rest=mode args
  local tag="$1" rep="$2"; shift 2
  local d="$OUT/${tag}_r${rep}"; mkdir -p "$d"
  # Idle since the previous arm ended. Randomising order removes the aliasing
  # of arm onto run position, but a short gap after a collapsing arm can still
  # carry fabric state into the next one, so record it rather than assume it.
  local now; now=$(date +%s)
  if [ -n "${LAST_ARM_END:-}" ]; then echo $((now - LAST_ARM_END)) > "$d/idle_before_s"; fi
  snap_all "$d" before
  # START BARRIER (BARRIER=1). Without one, "makespan" is the max of
  # per-process wall clocks, each starting whenever its own ssh happened to
  # land -- so it omits the start skew entirely and is not elapsed time from a
  # shared start. We pin a common epoch a few seconds out, have every initiator
  # spin until it, and measure from that epoch to the last completion. Node
  # clocks are NTP-synced and were measured within ~100 ms of each other, which
  # bounds the error on a 17-40 s batch below 1%.
  local T0=0
  [ "$BARRIER" = 1 ] && T0=$(( $(date +%s%3N) + 10000 ))
  local pids=()
  for i in $(seq 1 "$N"); do
    ssh -n $OPTS "$(init "$i")" \
      "cd ~/hw-cas && DEV=\$($DISC) && \
       if [ $T0 -gt 0 ]; then while [ \$(date +%s%3N) -lt $T0 ]; do :; done; fi && \
       date +%s%3N > /tmp/ms_start_i${i} && \
       sudo ./cas_gate --dev \$DEV --batch-size $BYTES \
        --flush-clients $W --append-clients $L --flush-ops $OPS --duration 99999 \
        --seed $((17*rep + i)) $* --log /tmp/ms_i${i}.csv > /tmp/ms_i${i}.sum 2>&1; \
       date +%s%3N > /tmp/ms_end_i${i}" &
    pids+=($!)
  done
  for p in "${pids[@]}"; do wait "$p" || true; done
  local mk=0
  for i in $(seq 1 "$N"); do
    scp $OPTS -q "$(init "$i"):/tmp/ms_i${i}.sum" "$d/init${i}.sum" 2>/dev/null || true
    scp $OPTS -q "$(init "$i"):/tmp/ms_i${i}.csv" "$d/init${i}.csv" 2>/dev/null || true
    local w
    w=$(sed -n 's/.*wall_s=\([0-9.]*\).*/\1/p' "$d/init${i}.sum" 2>/dev/null | head -1)
    # makespan = the LAST initiator to finish, not the mean
    [ -n "$w" ] && mk=$(python3 -c "print(max($mk,$w))")
  done
  snap_all "$d" after
  echo "$mk" > "$d/makespan_s"

  # Barrier-referenced makespan: elapsed from the SHARED start to the last
  # completion. Recorded alongside the per-process figure rather than replacing
  # it, so the two can be compared and the start skew quantified instead of
  # assumed negligible.
  if [ "$BARRIER" = 1 ] && [ "$T0" -gt 0 ]; then
    local last=0 firststart=0
    for i in $(seq 1 "$N"); do
      scp $OPTS -q "$(init "$i"):/tmp/ms_start_i${i}" "$d/init${i}.start" 2>/dev/null || true
      scp $OPTS -q "$(init "$i"):/tmp/ms_end_i${i}"   "$d/init${i}.end"   2>/dev/null || true
      local e0 e1
      e0=$(cat "$d/init${i}.start" 2>/dev/null); e1=$(cat "$d/init${i}.end" 2>/dev/null)
      [ -n "$e1" ] && [ "$e1" -gt "$last" ] && last=$e1
      [ -n "$e0" ] && { [ "$firststart" = 0 ] || [ "$e0" -lt "$firststart" ]; } && firststart=$e0
    done
    if [ "$last" -gt 0 ]; then
      echo "$T0" > "$d/barrier_epoch_ms"
      python3 -c "print(f'{($last - $T0)/1000.0:.3f}')" > "$d/makespan_barrier_s"
      # how far past the barrier the slowest initiator actually began
      local skew=0
      for i in $(seq 1 "$N"); do
        local e0; e0=$(cat "$d/init${i}.start" 2>/dev/null)
        [ -n "$e0" ] && [ $((e0 - T0)) -gt "$skew" ] && skew=$((e0 - T0))
      done
      echo "$skew" > "$d/start_skew_ms"
    fi
  fi
  # A makespan comparison is only meaningful if every arm moved the SAME bytes.
  # An earlier version stopped on completions, so in-flight ops finished on top
  # of the target and the overshoot scaled with concurrency -- the ungated arm
  # did ~15% more work than k=1, biasing the result toward the gated arm. Verify
  # rather than trust.
  local ops
  ops=$(for i in $(seq 1 "$N"); do
          sed -n 's/.*flush_ops=\([0-9]*\).*/\1/p' "$d/init${i}.sum" 2>/dev/null | head -1
        done | sort -u | tr '\n' ' ')
  if [ "$(echo $ops | wc -w)" -ne 1 ] || [ "$(echo $ops | tr -d ' ')" != "$OPS" ]; then
    printf '  %-12s rep%s  !! UNEQUAL WORK: flush_ops per initiator = %s (expected %s on all)\n' \
           "$tag" "$rep" "$ops" "$OPS"
    echo "UNEQUAL:$ops" > "$d/WORK_MISMATCH"
  fi
  printf '  %-12s rep%s  makespan = %s s   retx = %s   (ops/init: %s)\n' \
         "$tag" "$rep" "$mk" "$(retx_delta "$d")" "$ops"
  LAST_ARM_END=$(date +%s)
}

echo "fixed-volume makespan: N=$N, S=$((BYTES/1048576)) MiB, $OPS flush ops/initiator"
echo "total work = $((N*OPS*BYTES/1048576)) MiB across $N initiators, identical in every arm"
echo
KLIST=${KLIST:-"1 2"}     # per-initiator admission bounds to sweep

# RANDOMISED ARM ORDER.
#
# This loop used to run baseline, then each k, in that order, in every
# repetition. Arm and run position were therefore perfectly collinear, and no
# cross-arm ratio the campaign produced could distinguish a policy effect from
# a monotone drift across the window -- which is exactly the objection the
# published 2.16x makespan comparison could not answer. Randomise across the
# whole campaign, not within a repetition, and record the realised order so the
# analysis can regress outcome on run position and report the correlation.
mkdir -p "$OUT"
mapfile -t PLAN < <(for r in $(seq 1 "$REPS"); do
    echo "baseline $r"
    for k in $KLIST; do echo "cas-k$k $r"; done
  done | shuf --random-source=<(yes "${SEED:-msfix}"))
printf '%s\n' "${PLAN[@]}" > "$OUT/arm_order.txt"
echo "== ${#PLAN[@]} runs, randomised order recorded in $OUT/arm_order.txt =="
echo
for spec in "${PLAN[@]}"; do
  read -r a r <<<"$spec"
  case "$a" in
    baseline) arm baseline "$r" --mode baseline ;;
    cas-k*)   arm "$a" "$r" --mode cas --k "${a#cas-k}" ;;
    *)        echo "unknown arm: $a" >&2; exit 2 ;;
  esac
done
echo
echo "== makespan summary (lower is better) =="
for tag in baseline $(for k in ${KLIST:-1 2}; do echo "cas-k$k"; done); do
  vals=$(cat "$OUT/${tag}"_r*/makespan_s 2>/dev/null | tr '\n' ' ')
  [ -n "$vals" ] && printf '  %-10s %s\n' "$tag" "$vals"
done
