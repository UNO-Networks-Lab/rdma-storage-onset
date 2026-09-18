#!/usr/bin/env bash
# run-incast-extra.sh -- generality + rigor for the incast result:
#   (A) transfer-size sweep at 4:1 (512K/1M/2M/4M flushes), baseline vs CAS k=1
#   (B) long-duration 4:1 run for a tighter extreme-tail (more stall samples)
# Launches cas_gate on all 4 initiators at once; pulls per-I/O logs.
set -euo pipefail
EXP="${1:?expbase}"; OUT="${2:?outdir}"
KEY=$HOME/.ssh/cloudlab_ed25519
OPTS="-i $KEY -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"
N=${N:-4}; L=${L:-2}
DISC='for n in /dev/nvme*n1; do c=$(basename $n|sed "s/n[0-9]*$//"); grep -q dsscc /sys/class/nvme/$c/subsysnqn 2>/dev/null && echo $n && break; done'
mkdir -p "$OUT"
host(){ echo "${USER_CL:?set USER_CL to your CloudLab username}@$1.$EXP"; }

launch(){ # $1=tag $2=W $3=dur $4=bytes rest=mode args
  local tag="$1" W="$2" dur="$3" bytes="$4"; shift 4
  local d="$OUT/$tag"; mkdir -p "$d"; local pids=()
  for i in $(seq 1 "$N"); do
    ssh $OPTS "$(host "initiator$i")" \
      "cd ~/hw-cas && DEV=\$($DISC) && sudo ./cas_gate --dev \$DEV --batch-size $bytes \
        --flush-clients $W --append-clients $L --duration $dur --seed $((7*i)) $* \
        --log /tmp/ex_i$i.csv > /tmp/ex_i$i.sum 2>&1" &
    pids+=($!)
  done
  for p in "${pids[@]}"; do wait "$p" || true; done
  for i in $(seq 1 "$N"); do scp $OPTS -q "$(host "initiator$i"):/tmp/ex_i$i.csv" "$d/init$i.csv" 2>/dev/null || true; done
  echo "  $tag done"
}

echo "== (A) transfer-size sweep at 4:1, W=8, baseline vs CAS k=1 =="
for sz in 524288 1048576 2097152 4194304; do
  szl=$((sz/1024))K
  for r in 1 2; do
    launch "size${szl}_baseline_r${r}" 8 12 "$sz" --mode baseline
    launch "size${szl}_cas-k1_r${r}"   8 12 "$sz" --mode cas --k 1
  done
done

echo "== (B) long-duration 4:1 (45s) for extreme-tail, W=8, 2M =="
for r in 1 2; do
  launch "long_baseline_r${r}" 8 45 2097152 --mode baseline
  launch "long_cas-k1_r${r}"   8 45 2097152 --mode cas --k 1
done
echo "done -> $OUT"
