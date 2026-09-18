#!/usr/bin/env bash
# run-collapse-boundary.sh -- the "Collapse Boundary" measurement campaign:
#  Arm 1  FINE THRESHOLD SWEEP: aggregate in-flight in {8,10,12,14,16,20,24,32}
#         2MiB transfers at 4:1 via per-initiator static k, 4 reps x 15s,
#         per-op logs + per-rep RDMA counter snapshots (target + initiators).
#         -> localizes W* to ~one transfer; victim attribution comes free from
#            per-initiator logs + counters.
#  Arm 2  HYSTERESIS RAMP: within-run aggregate schedule 8 -> 20 -> 8 (12s each)
#         via kfile control; timestamped op logs + time-aligned counter klogs.
#         -> does the collapse persist after load returns below the upward
#            threshold? (first-order/bistable signature)
#
#   ./run-collapse-boundary.sh <expbase> <outdir>
set -euo pipefail
EXP="${1:?}"; OUT="${2:?}"
KEY=$HOME/.ssh/cloudlab_ed25519
OPTS="-i $KEY -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"
W=8; L=2
DISC='for n in /dev/nvme*n1; do c=$(basename $n|sed "s/n[0-9]*$//"); grep -q dsscc /sys/class/nvme/$c/subsysnqn 2>/dev/null && echo $n && break; done'
CTRS="local_ack_timeout_err packet_seq_err out_of_sequence rnr_nak_retry_err out_of_buffer np_cnp_sent"
mkdir -p "$OUT"; host(){ echo "${USER_CL:?set USER_CL to your CloudLab username}@$1.$EXP"; }
recon(){ local d; d=$(ssh $OPTS "$(host "initiator$1")" "$DISC" 2>/dev/null||true)
  [ -z "$d" ] && ssh $OPTS "$(host "initiator$1")" 'sudo bash ~/scripts/20-initiator-connect.sh >/tmp/rc.log 2>&1' || true; }
snap(){ ssh $OPTS "$(host "$1")" 'source /local/dsscc-env; for c in '"$CTRS"'; do
  v=$(cat /sys/class/infiniband/$RDMA_DEV/ports/1/hw_counters/$c 2>/dev/null||echo 0); printf "%s=%s " "$c" "$v"; done'; }

collect(){ local d="$OUT/$1"; mkdir -p "$d"
  for i in $(seq 1 "${N:-4}"); do for ext in csv sum klog; do
    scp $OPTS -q "$(host "initiator$i"):/tmp/cb_i$i.$ext" "$d/init$i.$ext" 2>/dev/null || true; done
    ssh $OPTS "$(host "initiator$i")" 'rm -f /tmp/cb_i*.klog /tmp/cb_i*.csv' 2>/dev/null || true; done; }

echo "== Arm 1: fine threshold sweep =="
# per-initiator k assignments -> aggregate {8,10,12,14,16,20,24,32}
LEVELS=("8:2,2,2,2" "10:3,3,2,2" "12:3,3,3,3" "14:4,4,3,3" "16:4,4,4,4" "20:5,5,5,5" "24:6,6,6,6" "32:8,8,8,8")
for r in 1 2 3 4; do
  for lv in "${LEVELS[@]}"; do
    agg="${lv%%:*}"; IFS=',' read -ra KS <<< "${lv#*:}"
    for i in 1 2 3 4; do recon "$i"; done
    d="$OUT/A_agg${agg}_r${r}"; mkdir -p "$d"
    snap target > "$d/target.before"; for i in 1 2 3 4; do snap "initiator$i" > "$d/init$i.before"; done
    pids=()
    for i in 1 2 3 4; do
      ssh $OPTS "$(host "initiator$i")" \
        "cd ~/hw-cas && DEV=\$($DISC) && sudo ./cas_gate --dev \$DEV --flush-clients $W --append-clients $L \
          --duration 15 --seed $((100*r+i)) --mode cas --k ${KS[$((i-1))]} \
          --log /tmp/cb_i$i.csv > /tmp/cb_i$i.sum 2>&1" & pids+=($!)
    done
    for p in "${pids[@]}"; do wait "$p" || true; done
    snap target > "$d/target.after"; for i in 1 2 3 4; do snap "initiator$i" > "$d/init$i.after"; done
    for i in 1 2 3 4; do for ext in csv sum; do
      scp $OPTS -q "$(host "initiator$i"):/tmp/cb_i$i.$ext" "$d/init$i.$ext" 2>/dev/null || true; done; done
    echo "  A agg=$agg rep$r done"
  done
done

echo "== Arm 2: hysteresis ramp 8 -> 20 -> 8 (12s each) =="
for r in 1 2 3; do
  for i in 1 2 3 4; do recon "$i"; ssh $OPTS "$(host "initiator$i")" 'echo 2 | sudo tee /tmp/kctl >/dev/null'; done
  pids=()
  for i in 1 2 3 4; do
    ssh $OPTS "$(host "initiator$i")" \
      "cd ~/hw-cas && source /local/dsscc-env && DEV=\$($DISC) && sudo RDMA_DEV=\$RDMA_DEV ./cas_gate --dev \$DEV \
        --flush-clients $W --append-clients $L --duration 36 --seed $((500+r*10+i)) \
        --mode adaptive --kfile /tmp/kctl --rdma-dev \$RDMA_DEV --adapt-interval-ms 25 \
        --log /tmp/cb_i$i.csv --klog /tmp/cb_i$i.klog > /tmp/cb_i$i.sum 2>&1" & pids+=($!)
  done
  ( sleep 12; for i in 1 2 3 4; do ssh $OPTS "$(host "initiator$i")" 'echo 5 | sudo tee /tmp/kctl >/dev/null'; done
    sleep 12; for i in 1 2 3 4; do ssh $OPTS "$(host "initiator$i")" 'echo 2 | sudo tee /tmp/kctl >/dev/null'; done ) & pids+=($!)
  for p in "${pids[@]}"; do wait "$p" || true; done
  collect "B_hyst_r${r}"
  echo "  B hysteresis rep$r done"
done
echo "done -> $OUT"
