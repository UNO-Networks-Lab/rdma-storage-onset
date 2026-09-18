#!/usr/bin/env bash
# run-controller.sh -- does the sensor choice actually matter?
#
# The paper explains its reactive controller's failure by blaming the sensor:
# "dominated by local_ack_timeout_err... a property of the sensor we chose".
# That explanation is not supported -- rp_cnp_handled and the sequence-error
# counters were in the trigger sum all along, and they move about one ACK
# timeout earlier. This turns the sensor into a variable and measures it.
#
# Arms (identical binary, identical workload; only the trigger differs):
#   baseline      no gate at all
#   static-k1     the known-safe fixed bound, as a lower bound on tail latency
#   aimd-all      the paper's controller: sum of all five counters
#   aimd-cnp      reaction-point CNP only -- the "most important missing baseline"
#   aimd-timeout  ACK timeout only -- the late sensor the paper THOUGHT it ran
#
# If aimd-cnp beats aimd-timeout, sensor latency mattered. If they are alike and
# both lose to static-k1, the failure is the probing asymmetry instead, which is
# what the zero-signal subcritical region predicts.
set -uo pipefail
EXP="${1:?usage: run-controller.sh <expbase> <outdir> [reps]}"
OUT="${2:?outdir}"; REPS="${3:-5}"
KEY=${KEY:-$HOME/.ssh/cloudlab_ed25519}
USER_CL=${USER_CL:?set USER_CL to your CloudLab username}
OPTS="-i $KEY -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"
N=${N:-3}; W=${W:-8}; L=${L:-2}; DUR=${DUR:-20}; BYTES=${BYTES:-4194304}
mkdir -p "$OUT"
init(){ echo "$USER_CL@initiator$1.$EXP"; }
DISC='for n in /dev/nvme*n1; do c=$(basename $n|sed "s/n[0-9]*$//"); grep -q dsscc /sys/class/nvme/$c/subsysnqn 2>/dev/null && echo $n && break; done'
CTRS="local_ack_timeout_err packet_seq_err out_of_sequence rnr_nak_retry_err out_of_buffer np_cnp_sent rp_cnp_handled"
snap(){ ssh -n $OPTS "$USER_CL@$1.$EXP" 'source /local/dsscc-env 2>/dev/null; for c in '"$CTRS"'; do
  f=/sys/class/infiniband/$RDMA_DEV/ports/1/hw_counters/$c
  if [ -e "$f" ]; then printf "%s=%s\n" "$c" "$(cat $f 2>/dev/null || echo ABSENT)"
  else printf "%s=ABSENT\n" "$c"; fi; done' 2>/dev/null; }

arm(){                 # $1=tag $2=rep  rest=gate args
  local tag="$1" rep="$2"; shift 2
  local d="$OUT/${tag}_r${rep}"; mkdir -p "$d"
  # Idle time since the previous arm ended. With a randomised schedule the
  # arms no longer alias onto run position, but a short gap after a collapsing
  # arm can still carry fabric state into the next one, so record it rather
  # than assume it away.
  local now; now=$(date +%s)
  if [ -n "${LAST_ARM_END:-}" ]; then echo $((now - LAST_ARM_END)) > "$d/idle_before_s"; fi
  snap target > "$d/target.before"
  for i in $(seq 1 "$N"); do snap "initiator$i" > "$d/init${i}.before"; done
  # Clear per-run outputs first. cas_gate writes a klog only in adaptive mode,
  # so a non-adaptive arm would otherwise scp back the PREVIOUS arm's klog and
  # the analysis would report an admission trajectory for a policy that has no
  # trajectory. Same hazard for .csv/.sum if a gate ever fails to start.
  local pids=()
  for i in $(seq 1 "$N"); do
    ssh -n $OPTS "$(init "$i")" "rm -f /tmp/ctl_i${i}.csv /tmp/ctl_i${i}.sum /tmp/ctl_i${i}.klog" >/dev/null 2>&1
  done
  for i in $(seq 1 "$N"); do
    ssh -n $OPTS "$(init "$i")" \
      "cd ~/hw-cas && DEV=\$($DISC) && sudo ./cas_gate --dev \$DEV --batch-size $BYTES \
        --flush-clients $W --append-clients $L --duration $DUR --seed $((31*rep+i)) \
        --rdma-dev \$(source /local/dsscc-env; echo \$RDMA_DEV) \
        $* --klog /tmp/ctl_i${i}.klog --log /tmp/ctl_i${i}.csv > /tmp/ctl_i${i}.sum 2>&1" &
    pids+=($!)
  done
  local fail=0; for p in "${pids[@]}"; do wait "$p" || fail=1; done
  for i in $(seq 1 "$N"); do
    for f in csv sum klog; do
      scp $OPTS -q "$(init "$i"):/tmp/ctl_i${i}.$f" "$d/init${i}.$f" 2>/dev/null || true
    done
    snap "initiator$i" > "$d/init${i}.after"
  done
  snap target > "$d/target.after"
  LAST_ARM_END=$(date +%s)
  # cas_gate now exits nonzero when its control loop missed its cadence, so a
  # blind run already shows up in fail= above; report the numbers too, since a
  # cadence failure invalidates the arm rather than merely degrading it.
  awk -F'gap_violations=' '/gap_violations=/{split($2,a," "); v+=a[1]}
       /max_tick_gap_ms=/{split($0,b,"max_tick_gap_ms="); split(b[2],c," ");
                          if (c[1]+0>m) m=c[1]+0}
       END{if (v>0) printf("  CADENCE FAIL: %d violations, max gap %.1f ms\n", v, m)}' \
      "$d"/init*.sum 2>/dev/null
  echo "  $tag rep$rep done (fail=$fail)"
}

# Randomised arm order. The earlier campaign ran a fixed order in every
# repetition, so any monotone drift across a repetition aliased onto arm; with
# five arms and a stochastic onset that is not a safe assumption.
mapfile -t PLAN < <(for r in $(seq 1 "$REPS"); do
    for a in baseline static-k1 aimd-all aimd-cnp aimd-timeout; do echo "$a $r"; done
  done | shuf --random-source=<(yes "${SEED:-ctlfix}"))
printf '%s\n' "${PLAN[@]}" > "$OUT/arm_order.txt"
echo "== ${#PLAN[@]} runs, randomised order in $OUT/arm_order.txt =="
for spec in "${PLAN[@]}"; do
  read -r a r <<<"$spec"
  case "$a" in
    baseline)     arm baseline     "$r" --mode baseline ;;
    static-k1)    arm static-k1    "$r" --mode cas --k 1 ;;
    aimd-all)     arm aimd-all     "$r" --mode adaptive --k $W --adapt-signal all ;;
    aimd-cnp)     arm aimd-cnp     "$r" --mode adaptive --k $W --adapt-signal cnp ;;
    aimd-timeout) arm aimd-timeout "$r" --mode adaptive --k $W --adapt-signal timeout ;;
  esac
done
echo "done -> $OUT"
