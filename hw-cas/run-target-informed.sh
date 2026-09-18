#!/usr/bin/env bash
# Phase B rematch: dynamic fan-in 2:1 -> 4:1 at t=12s.
#   static-k2       : k=2 everywhere (conservative oracle)
#   target-informed : k=4 while N=2; orchestrator (emulating the target's
#                     connect-event knowledge) drops kfile to 2 at the join.
set -euo pipefail
EXP="${1:?}"; OUT="${2:?}"; REPS="${3:-2}"
KEY=$HOME/.ssh/cloudlab_ed25519
OPTS="-i $KEY -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"
W=8; L=2
DISC='for n in /dev/nvme*n1; do c=$(basename $n|sed "s/n[0-9]*$//"); grep -q dsscc /sys/class/nvme/$c/subsysnqn 2>/dev/null && echo $n && break; done'
mkdir -p "$OUT"; host(){ echo "${USER_CL:?set USER_CL to your CloudLab username}@$1.$EXP"; }
recon(){ local d; d=$(ssh $OPTS "$(host "initiator$1")" "$DISC" 2>/dev/null||true)
  [ -z "$d" ] && ssh $OPTS "$(host "initiator$1")" 'sudo bash ~/scripts/20-initiator-connect.sh >/tmp/rc.log 2>&1' || true; }
run_one(){ local i="$1" delay="$2" dur="$3"; shift 3
  ssh $OPTS "$(host "initiator$i")" \
    "sleep $delay; cd ~/hw-cas && DEV=\$($DISC) && sudo ./cas_gate --dev \$DEV \
      --flush-clients $W --append-clients $L --duration $dur --seed $((13*i)) $* \
      --log /tmp/ti_i$i.csv --klog /tmp/ti_i$i.klog > /tmp/ti_i$i.sum 2>&1"; }
collect(){ local d="$OUT/$1"; mkdir -p "$d"
  for i in 1 2 3 4; do for ext in csv sum klog; do
    scp $OPTS -q "$(host "initiator$i"):/tmp/ti_i$i.$ext" "$d/init$i.$ext" 2>/dev/null || true; done; done; }

for r in $(seq 1 "$REPS"); do
  echo "== static-k2 rep$r =="
  for i in 1 2 3 4; do recon "$i"; done
  pids=()
  for i in 1 2; do run_one "$i" 0 30 --mode cas --k 2 & pids+=($!); done
  for i in 3 4; do run_one "$i" 12 18 --mode cas --k 2 & pids+=($!); done
  for p in "${pids[@]}"; do wait "$p" || true; done
  collect "static2_r${r}"

  echo "== target-informed rep$r =="
  for i in 1 2 3 4; do recon "$i"; done
  for i in 1 2; do ssh $OPTS "$(host "initiator$i")" 'echo 4 | sudo tee /tmp/kctl >/dev/null'; done
  for i in 3 4; do ssh $OPTS "$(host "initiator$i")" 'echo 2 | sudo tee /tmp/kctl >/dev/null'; done
  pids=()
  for i in 1 2; do run_one "$i" 0 30 --mode adaptive --kfile /tmp/kctl --adapt-interval-ms 25 & pids+=($!); done
  for i in 3 4; do run_one "$i" 12 18 --mode adaptive --kfile /tmp/kctl --adapt-interval-ms 25 & pids+=($!); done
  ( sleep 12; for i in 1 2; do ssh $OPTS "$(host "initiator$i")" 'echo 2 | sudo tee /tmp/kctl >/dev/null'; done ) &
  pids+=($!)
  for p in "${pids[@]}"; do wait "$p" || true; done
  collect "targetinf_r${r}"
done
echo "done -> $OUT"
