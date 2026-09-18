#!/usr/bin/env bash
# run-adaptive-demo.sh -- the adaptive-admission experiment, two phases:
#
#  A) STATIC 4:1: ungated vs static k=1 vs static k=4 (known-bad: re-triggers
#     collapse) vs adaptive (starts at k=W, self-locates safe k via NIC loss
#     counters). 3 reps each. Shows adaptation matches the best static k
#     without knowing N or the buffer.
#
#  B) DYNAMIC FAN-IN: initiators 1-2 start (2:1); initiators 3-4 join at
#     t=+12s (4:1). static k=4 (safe at 2:1, collapses at 4:1) vs adaptive.
#     The k trajectory (klog) shows the gate detecting the regime change.
#     This is the scenario no static configuration can win.
#
#   ./run-adaptive-demo.sh <expbase> <outdir>
set -euo pipefail
EXP="${1:?expbase}"; OUT="${2:?outdir}"
KEY=$HOME/.ssh/cloudlab_ed25519
OPTS="-i $KEY -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"
N=${N:-4}; W=${W:-8}; L=${L:-2}
DISC='for n in /dev/nvme*n1; do c=$(basename $n|sed "s/n[0-9]*$//"); grep -q dsscc /sys/class/nvme/$c/subsysnqn 2>/dev/null && echo $n && break; done'
mkdir -p "$OUT"
host(){ echo "${USER_CL:?set USER_CL to your CloudLab username}@$1.$EXP"; }

reconnect_if_needed(){ # $1 = initiator index
  local d
  d=$(ssh $OPTS "$(host "initiator$1")" "$DISC" 2>/dev/null || true)
  if [ -z "$d" ]; then
    ssh $OPTS "$(host "initiator$1")" 'sudo bash ~/scripts/20-initiator-connect.sh >/tmp/rc.log 2>&1' || true
  fi
}

# run one gate instance on initiator $1; args: idx tag delay_s dur extra...
run_one(){
  local i="$1" tag="$2" delay="$3" dur="$4"; shift 4
  ssh $OPTS "$(host "initiator$i")" \
    "sleep $delay; cd ~/hw-cas && source /local/dsscc-env && DEV=\$($DISC) && \
     sudo RDMA_DEV=\$RDMA_DEV ./cas_gate --dev \$DEV --flush-clients $W --append-clients $L \
       --duration $dur --seed $((11*i)) --rdma-dev \$RDMA_DEV $* \
       --log /tmp/ad_i$i.csv --klog /tmp/ad_i$i.klog > /tmp/ad_i$i.sum 2>&1"
}

collect(){ # $1=dirname $2=n_initiators
  local d="$OUT/$1"; mkdir -p "$d"
  for i in $(seq 1 "$2"); do
    scp $OPTS -q "$(host "initiator$i"):/tmp/ad_i$i.csv"  "$d/init$i.csv"  2>/dev/null || true
    scp $OPTS -q "$(host "initiator$i"):/tmp/ad_i$i.sum"  "$d/init$i.sum"  2>/dev/null || true
    scp $OPTS -q "$(host "initiator$i"):/tmp/ad_i$i.klog" "$d/init$i.klog" 2>/dev/null || true
    ssh $OPTS "$(host "initiator$i")" 'rm -f /tmp/ad_i*.klog' 2>/dev/null || true
  done
}

echo "== Phase A: static 4:1, 3 reps x {baseline, k1, k4, adaptive} =="
for r in 1 2 3; do
  for spec in "baseline|--mode baseline" "k1|--mode cas --k 1" "k4|--mode cas --k 4" "adaptive|--mode adaptive --k $W --adapt-interval-ms 50"; do
    tag="${spec%%|*}"; margs="${spec#*|}"
    for i in 1 2 3 4; do reconnect_if_needed "$i"; done
    pids=()
    for i in 1 2 3 4; do run_one "$i" "$tag" 0 15 $margs & pids+=($!); done
    for p in "${pids[@]}"; do wait "$p" || true; done
    collect "A_${tag}_r${r}" 4
    echo "  A $tag rep$r done"
  done
done

echo "== Phase B: dynamic fan-in (2:1 -> 4:1 at t=12s), 2 reps x {k4, adaptive} =="
for r in 1 2; do
  for spec in "k4|--mode cas --k 4" "adaptive|--mode adaptive --k $W --adapt-interval-ms 50"; do
    tag="${spec%%|*}"; margs="${spec#*|}"
    for i in 1 2 3 4; do reconnect_if_needed "$i"; done
    pids=()
    for i in 1 2; do run_one "$i" "$tag" 0 30 $margs & pids+=($!); done
    for i in 3 4; do run_one "$i" "$tag" 12 18 $margs & pids+=($!); done
    for p in "${pids[@]}"; do wait "$p" || true; done
    collect "B_${tag}_r${r}" 4
    echo "  B $tag rep$r done"
  done
done
echo "done -> $OUT"
