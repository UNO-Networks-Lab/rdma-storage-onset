#!/usr/bin/env bash
# run-boundary-spotchecks.sh -- two pre-registered predictions of the
# aggregate-BYTES boundary theory (W* in (20,24] MB):
#
#  Check 1  N-INVARIANCE: 2:1, k=4/initiator, S=2MiB -> Phi = 2*4*2 = 16 MB.
#           Same per-initiator k that COLLAPSED at 4:1 (Phi=32MB, 247 seq errs
#           on disk). Byte-theory: SAFE (counters 0). Per-initiator-k theory:
#           collapse. 3 reps.
#
#  Check 2  BYTES-vs-COUNT: 4:1, S=1MiB, k in {3,5,6,7}/initiator ->
#           Phi = {12,20,24,28} MB but transfer counts {12,20,24,28}.
#           Byte-theory: safe,safe,boundary,collapse.
#           Count-theory (boundary at 10-12 transfers): collapse already at k=3.
#           2 reps each.
#
#   ./run-boundary-spotchecks.sh <expbase> <outdir>
set -euo pipefail
EXP="${1:?}"; OUT="${2:?}"
KEY=$HOME/.ssh/cloudlab_ed25519
OPTS="-i $KEY -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"
W=8; L=2
DISC='for n in /dev/nvme*n1; do c=$(basename $n|sed "s/n[0-9]*$//"); grep -q dsscc /sys/class/nvme/$c/subsysnqn 2>/dev/null && echo $n && break; done'
CTRS="local_ack_timeout_err packet_seq_err out_of_sequence np_cnp_sent"
mkdir -p "$OUT"; host(){ echo "${USER_CL:?set USER_CL to your CloudLab username}@$1.$EXP"; }
recon(){ local d; d=$(ssh $OPTS "$(host "initiator$1")" "$DISC" 2>/dev/null||true)
  [ -z "$d" ] && ssh $OPTS "$(host "initiator$1")" 'sudo bash ~/scripts/20-initiator-connect.sh >/tmp/rc.log 2>&1' || true; }
snap(){ ssh $OPTS "$(host "$1")" 'source /local/dsscc-env; for c in '"$CTRS"'; do
  v=$(cat /sys/class/infiniband/$RDMA_DEV/ports/1/hw_counters/$c 2>/dev/null||echo 0); printf "%s=%s " "$c" "$v"; done'; }

runlevel(){ # $1=tag $2=nInit $3=k $4=batchbytes $5=rep
  local tag="$1" n="$2" k="$3" bb="$4" r="$5"
  local d="$OUT/${tag}_r${r}"; mkdir -p "$d"
  for i in $(seq 1 "$n"); do recon "$i"; done
  snap target > "$d/target.before"; for i in $(seq 1 "$n"); do snap "initiator$i" > "$d/init$i.before"; done
  local pids=()
  for i in $(seq 1 "$n"); do
    ssh $OPTS "$(host "initiator$i")" \
      "cd ~/hw-cas && DEV=\$($DISC) && sudo ./cas_gate --dev \$DEV --batch-size $bb \
        --flush-clients $W --append-clients $L --duration 15 --seed $((700+r*10+i)) \
        --mode cas --k $k --log /tmp/sc_i$i.csv > /tmp/sc_i$i.sum 2>&1" & pids+=($!)
  done
  for p in "${pids[@]}"; do wait "$p" || true; done
  snap target > "$d/target.after"; for i in $(seq 1 "$n"); do snap "initiator$i" > "$d/init$i.after"; done
  for i in $(seq 1 "$n"); do for ext in csv sum; do
    scp $OPTS -q "$(host "initiator$i"):/tmp/sc_i$i.$ext" "$d/init$i.$ext" 2>/dev/null || true; done; done
  echo "  $tag rep$r done"
}

echo "== Check 1: N-invariance (2:1, k=4, S=2MiB, Phi=16MB -> predict SAFE) =="
for r in 1 2 3; do runlevel "C1_n2k4s2M" 2 4 2097152 "$r"; done

echo "== Check 2: bytes-vs-count (4:1, S=1MiB) =="
for r in 1 2; do
  runlevel "C2_k3s1M_12MB" 4 3 1048576 "$r"   # byte: safe | count: collapse
  runlevel "C2_k5s1M_20MB" 4 5 1048576 "$r"   # byte: safe | count: collapse
  runlevel "C2_k6s1M_24MB" 4 6 1048576 "$r"   # byte: boundary
  runlevel "C2_k7s1M_28MB" 4 7 1048576 "$r"   # byte: collapse
done
echo "done -> $OUT"
