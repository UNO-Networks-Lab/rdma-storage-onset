#!/usr/bin/env bash
# Concurrency-threshold sweep: vary flush clients W per initiator at 4:1 (so
# aggregate in-flight batch = 4*W * 2MB). Finds where the switch buffer overruns
# -> collapse. baseline maps the threshold; CAS k=1 confirms robustness.
set -euo pipefail
EXP="${1:?}"; OUT="${2:?}"
KEY=$HOME/.ssh/cloudlab_ed25519
OPTS="-i $KEY -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"
N=${N:-4}
DISC='for n in /dev/nvme*n1; do c=$(basename $n|sed "s/n[0-9]*$//"); grep -q dsscc /sys/class/nvme/$c/subsysnqn 2>/dev/null && echo $n && break; done'
mkdir -p "$OUT"; host(){ echo "${USER_CL:?set USER_CL to your CloudLab username}@$1.$EXP"; }
launch(){ local tag="$1" W="$2"; shift 2; local d="$OUT/$tag"; mkdir -p "$d"; local pids=()
  for i in $(seq 1 "$N"); do
    ssh $OPTS "$(host "initiator$i")" "cd ~/hw-cas && DEV=\$($DISC) && sudo ./cas_gate --dev \$DEV --batch-size 2097152 --flush-clients $W --append-clients 2 --duration 12 --seed $((3*i)) $* --log /tmp/w_i$i.csv >/tmp/w_i$i.sum 2>&1" &
    pids+=($!); done
  for p in "${pids[@]}"; do wait "$p" || true; done
  for i in $(seq 1 "$N"); do scp $OPTS -q "$(host "initiator$i"):/tmp/w_i$i.csv" "$d/init$i.csv" 2>/dev/null||true; done
  echo "  $tag done"; }
for W in 1 2 4 8 16; do
  for r in 1 2; do launch "W${W}_baseline_r${r}" "$W" --mode baseline; done
done
launch "W16_cas-k1" 16 --mode cas --k 1
echo "done -> $OUT"
