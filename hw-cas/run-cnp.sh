#!/usr/bin/env bash
# run-cnp.sh -- how much warning does an ECN/CNP signal actually give?
#
# The review called a CNP/DCQCN-class comparison "the most important missing
# baseline", and our own control section concedes the signal is present well
# before the ACK timeout. We have never measured the INTERVAL. Per-run
# before/after snapshots cannot: they say a counter moved, not when.
#
# This runs the workload with a 10 ms counter sampler on every node, so on a
# SINGLE node's clock we can order rp_cnp_handled (the CNP a reaction point
# actually handled -- what an initiator-side controller could see) against
# local_ack_timeout_err (the signal our AIMD controller used, which fires after
# the stall). No cross-node clock sync is needed for that comparison, which is
# why it is framed per-initiator rather than target-to-initiator.
#
# It also settles an open item from the replication: at Phi=24 / S=4 MiB we
# recorded ACK timeouts alongside a 46 ms maximum latency, which is not
# self-consistent. The before/after snapshots bracket `nvme connect` as well as
# the workload, so those timeouts may not be workload events at all. The
# sampler timestamps every increment, so the question is answerable instead of
# arguable -- we record the workload window explicitly and attribute each
# increment to inside or outside it.
#
#   ./run-cnp.sh <expbase> <outdir> [reps]
set -uo pipefail
EXP="${1:?usage: run-cnp.sh <expbase> <outdir> [reps]}"
OUT="${2:?outdir}"; REPS="${3:-5}"
KEY=${KEY:-$HOME/.ssh/cloudlab_ed25519}
USER_CL=${USER_CL:?set USER_CL to your CloudLab username}
OPTS="-i $KEY -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"
W=${W:-8}
L=${L:-2}
DUR=${DUR:-30}
IVL=${IVL:-10}          # sampler tick, ms
# A collapsed arm overruns its nominal duration (that IS the effect), so the
# sampler must outlive the worst case rather than DUR plus a guess.
SAMP_S=${SAMP_S:-$((DUR*2+45))}
mkdir -p "$OUT"
init() { echo "$USER_CL@initiator$1.$EXP"; }
host() { echo "$USER_CL@$1.$EXP"; }

# label            N  S(bytes)   k    Phi(MiB)  expectation
# ------------------------------------------------------------------
# clean            2  8388608    1    16        no signal of any kind
# edge             3  4194304    2    24        counters move, tail usually benign
# collapse         2  8388608    2    32        reliable multi-second tail
ARMS=${ARMS:-"clean:2:8388608:1 edge:3:4194304:2 collapse:2:8388608:2"}

run_one() {            # $1=label $2=N $3=bytes $4=k $5=rep
  local lbl="$1" N="$2" B="$3" K="$4" rep="$5"
  local d="$OUT/${lbl}_r${rep}"; mkdir -p "$d"
  local nodes=("target"); for i in $(seq 1 "$N"); do nodes+=("initiator$i"); done

  # Samplers first, so the series brackets the workload on both sides.
  #
  # -n and </dev/null are load-bearing. Without them ssh keeps the session open
  # until the backgrounded sampler releases stdin, so each call blocks for the
  # sampler's FULL lifetime and the nodes sample strictly one after another --
  # every series then ends before the workload even starts and every counter
  # reads zero. That failure is silent and looks exactly like "CNP never
  # fires", which is the result this experiment exists to test. Launch them in
  # parallel too, so the series overlap rather than stagger.
  for n in "${nodes[@]}"; do
    ssh -n $OPTS "$(host "$n")" \
      "cd ~/hw-cas && rm -f /tmp/ctr.csv && nohup ./sample-counters.sh /tmp/ctr.csv $IVL $SAMP_S \
       >/tmp/ctr.log 2>&1 </dev/null & echo started" >/dev/null 2>&1 &
  done
  # Deliberately NOT waiting on those ssh PIDs. ssh does not return until the
  # backgrounded sampler releases the channel, so waiting here blocks for the
  # sampler's entire lifetime and the workload then runs AFTER every series has
  # ended -- which reads as "no signal on any counter". Instead, poll until the
  # sampler has actually produced rows, so we confirm it is running rather than
  # assume it.
  local ready=0
  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    ready=0
    for n in "${nodes[@]}"; do
      local cnt
      cnt=$(ssh -n $OPTS "$(host "$n")" 'wc -l < /tmp/ctr.csv 2>/dev/null || echo 0' 2>/dev/null)
      [ "${cnt:-0}" -gt 5 ] && ready=$((ready+1))
    done
    [ "$ready" -eq "${#nodes[@]}" ] && break
    sleep 1
  done
  if [ "$ready" -ne "${#nodes[@]}" ]; then
    echo "  !! only $ready/${#nodes[@]} samplers producing rows -- run will be unusable"
  fi

  local pids=()
  for i in $(seq 1 "$N"); do
    ssh $OPTS "$(init "$i")" \
      "cd ~/hw-cas && DEV=\$(for n in /dev/nvme*n1; do c=\$(basename \$n|sed 's/n[0-9]*\$//'); grep -q dsscc /sys/class/nvme/\$c/subsysnqn 2>/dev/null && echo \$n && break; done) && \
       date +%s%3N > /tmp/cnp_window.txt && \
       sudo ./cas_gate --dev \$DEV --batch-size $B --flush-clients $W --append-clients $L \
         --duration $DUR --seed $((100*rep + i)) --mode cas --k $K \
         --log /tmp/cnp_i${i}.csv >/tmp/cnp_i${i}.sum 2>&1; \
       date +%s%3N >> /tmp/cnp_window.txt" &
    pids+=($!)
  done
  local fail=0; for p in "${pids[@]}"; do wait "$p" || fail=1; done

  sleep 3
  for n in "${nodes[@]}"; do
    ssh $OPTS "$(host "$n")" 'pkill -f sample-counters.sh >/dev/null 2>&1; exit 0' >/dev/null 2>&1
    scp $OPTS -q "$(host "$n"):/tmp/ctr.csv" "$d/${n}.ctr.csv" 2>/dev/null || true
  done
  for i in $(seq 1 "$N"); do
    scp $OPTS -q "$(init "$i"):/tmp/cnp_i${i}.csv"     "$d/init${i}.csv"    2>/dev/null || true
    scp $OPTS -q "$(init "$i"):/tmp/cnp_i${i}.sum"     "$d/init${i}.sum"    2>/dev/null || true
    scp $OPTS -q "$(init "$i"):/tmp/cnp_window.txt"    "$d/init${i}.window" 2>/dev/null || true
  done
  echo "$lbl N=$N S=$((B/1048576))MiB k=$K Phi=$((N*K*B/1048576))MiB" > "$d/config"

  # COVERAGE GUARD. A counter series that does not span the workload window
  # shows zero increments for the same reason an unplugged probe does. Write
  # the verdict into the run directory so the analysis cannot mistake a
  # measurement failure for a physical null.
  local cov=OK
  for i in $(seq 1 "$N"); do
    local wf="$d/init${i}.window" cf="$d/initiator${i}.ctr.csv"
    [ -s "$wf" ] && [ -s "$cf" ] || { cov="MISSING(init$i)"; continue; }
    local w0 w1 s0 s1
    w0=$(sed -n 1p "$wf"); w1=$(sed -n 2p "$wf")
    s0=$(awk -F, '$1 ~ /^[0-9]+$/ {print $1; exit}' "$cf")
    s1=$(awk -F, '!/^#/ && $1 ~ /^[0-9]+$/ {t=$1} END{print t}' "$cf")
    [ -n "$w0" ] && [ -n "$w1" ] && [ -n "$s0" ] && [ -n "$s1" ] || { cov="UNPARSABLE(init$i)"; continue; }
    if [ "$s0" -gt "$w0" ] || [ "$s1" -lt "$w1" ]; then
      cov="GAP(init$i: sampler ${s0}..${s1} vs workload ${w0}..${w1})"
    fi
  done
  echo "$cov" > "$d/coverage"
  local rows; rows=$(wc -l < "$d/initiator1.ctr.csv" 2>/dev/null || echo 0)
  echo "  $lbl rep$rep done (fail=$fail, rows/init1=$rows, coverage=$cov)"
}

for spec in $ARMS; do
  IFS=: read -r lbl N B K <<<"$spec"
  echo "== $lbl  N=$N S=$((B/1048576))MiB k=$K  Phi=$((N*K*B/1048576))MiB =="
  for r in $(seq 1 "$REPS"); do run_one "$lbl" "$N" "$B" "$K" "$r"; done
done
echo "done -> $OUT"
