#!/usr/bin/env bash
# run-incast-telemetry.sh -- mechanistic incast experiment: capture RDMA
# hw_counter deltas (go-back-N / loss indicators) on target + initiators around
# baseline vs CAS runs at a fixed fan-in, to show CAS suppresses the triggers
# (local_ack_timeout_err, packet_seq_err, out_of_sequence) that cause the
# multi-second tail. Also records per-initiator throughput for fairness.
#
#   ./run-incast-telemetry.sh <expbase> <outdir> [fanin] [reps]
set -euo pipefail
EXP="${1:?expbase}"; OUT="${2:?outdir}"; N="${3:-4}"; REPS="${4:-3}"
KEY=$HOME/.ssh/cloudlab_ed25519
OPTS="-i $KEY -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"
W=8; L=2; DUR=15
CTRS="local_ack_timeout_err packet_seq_err out_of_sequence rnr_nak_retry_err out_of_buffer np_cnp_sent np_ecn_marked_roce_packets"
mkdir -p "$OUT"
host(){ echo "${USER_CL:?set USER_CL to your CloudLab username}@$1.$EXP"; }

# snapshot the counters on a node -> "name=val name=val ..."
snap(){ ssh $OPTS "$(host "$1")" 'source /local/dsscc-env; d=$RDMA_DEV
  for c in '"$CTRS"'; do
    v=$(cat /sys/class/infiniband/$d/ports/1/hw_counters/$c 2>/dev/null || cat /sys/class/infiniband/$d/hw_counters/$c 2>/dev/null || echo 0)
    printf "%s=%s " "$c" "$v"; done'; }

one(){ # $1=tag  rest=cas_gate args
  local tag="$1"; shift
  for r in $(seq 1 "$REPS"); do
    local d="$OUT/${tag}_r${r}"; mkdir -p "$d"
    # before-counters (target + initiators)
    snap target > "$d/target.before" 2>/dev/null
    for i in $(seq 1 "$N"); do snap "initiator$i" > "$d/init$i.before" 2>/dev/null; done
    # launch gates on all N initiators at once
    local pids=()
    for i in $(seq 1 "$N"); do
      ssh $OPTS "$(host "initiator$i")" \
        "cd ~/hw-cas && DEV=\$(for n in /dev/nvme*n1; do c=\$(basename \$n|sed 's/n[0-9]*\$//'); grep -q dsscc /sys/class/nvme/\$c/subsysnqn 2>/dev/null && echo \$n && break; done) && \
         sudo ./cas_gate --dev \$DEV --flush-clients $W --append-clients $L --duration $DUR --seed $((100*r+i)) $* \
           --log /tmp/tel_i$i.csv > /tmp/tel_i$i.sum 2>&1" &
      pids+=($!)
    done
    for p in "${pids[@]}"; do wait "$p" || true; done
    # after-counters + pull logs
    snap target > "$d/target.after" 2>/dev/null
    for i in $(seq 1 "$N"); do
      snap "initiator$i" > "$d/init$i.after" 2>/dev/null
      scp $OPTS -q "$(host "initiator$i"):/tmp/tel_i$i.sum" "$d/init$i.sum" 2>/dev/null || true
    done
    echo "  $tag rep$r done"
  done
}

echo "== fan-in $N:1, RDMA-counter telemetry, $REPS reps =="
one baseline --mode baseline
one cas-k1   --mode cas --k 1
one cas-k2   --mode cas --k 2
one cas-k4   --mode cas --k 4
echo "done -> $OUT"
