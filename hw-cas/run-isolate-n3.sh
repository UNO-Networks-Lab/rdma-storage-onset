#!/usr/bin/env bash
# run-isolate.sh -- hold Phi AND command count fixed, vary only application
# write concurrency.
#
# The block layer splits at 1 MiB (max_hw_sectors_kb=1024), so at N=2 the
# configurations
#
#   S=1 MiB  k=10   -> 20 app writes, 20 commands of 1 MiB, Phi=20 MiB
#   S=2 MiB  k=5    -> 10 app writes, 20 commands of 1 MiB, Phi=20 MiB
#   S=5 MiB  k=2    ->  4 app writes, 20 commands of 1 MiB, Phi=20 MiB
#   S=10 MiB k=1    ->  2 app writes, 20 commands of 1 MiB, Phi=20 MiB
#
# are identical in aggregate bytes, in outstanding command count, and in
# command size. They differ ONLY in how many application writes are
# outstanding. The paper reports Phi=20 as clean at S>=2 MiB and collapsed at
# S=1 MiB, which no byte or command hypothesis explains -- but which this
# variable would.
#
# S=0.5 MiB is included as the one arm that also changes command count and
# size (40 commands of 512 KiB at the same Phi), separating those in turn.
#
# If every arm at a given Phi agrees, application-write concurrency is not the
# control variable and the reported sub-MiB exception needs re-examination. If
# they disagree, the paper's control variable is incompletely identified.
set -uo pipefail
EXP="${1:?usage: run-isolate.sh <expbase> <outdir> [reps]}"
OUT="${2:?outdir}"; REPS="${3:-4}"
KEY=${KEY:-$HOME/.ssh/cloudlab_ed25519}
USER_CL=${USER_CL:?set USER_CL to your CloudLab username}
OPTS="-i $KEY -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"
N=${N:-2}; W=${W:-32}; L=${L:-2}; DUR=${DUR:-15}
mkdir -p "$OUT"
init(){ echo "$USER_CL@initiator$1.$EXP"; }
CTRS="local_ack_timeout_err packet_seq_err out_of_sequence rnr_nak_retry_err out_of_buffer np_cnp_sent rp_cnp_handled"
BLK='for n in /dev/nvme*n1; do c=$(basename $n); grep -q dsscc /sys/class/nvme/${c%n*}/subsysnqn 2>/dev/null && cat /sys/block/$c/stat && break; done'
snap(){ ssh -n $OPTS "$USER_CL@$1.$EXP" 'source /local/dsscc-env 2>/dev/null; for c in '"$CTRS"'; do
  f=/sys/class/infiniband/$RDMA_DEV/ports/1/hw_counters/$c
  if [ -e "$f" ]; then printf "%s=%s\n" "$c" "$(cat $f 2>/dev/null || echo ABSENT)"
  else printf "%s=ABSENT\n" "$c"; fi; done' 2>/dev/null; }
DISC='for n in /dev/nvme*n1; do c=$(basename $n|sed "s/n[0-9]*$//"); grep -q dsscc /sys/class/nvme/$c/subsysnqn 2>/dev/null && echo $n && break; done'

PLANS="21:1048576:7 21:3670016:2 21:7340032:1"

one(){
  local PHI="$1" B="$2" K="$3" rep="$4"
  local lbl="phi${PHI}_S$((B/1024))k_k${K}"
  local d="$OUT/${lbl}_r${rep}"; mkdir -p "$d"
  echo "N=$N W=$W k=$K S_bytes=$B phi_MiB=$PHI" > "$d/config"
  snap target > "$d/target.before"
  for i in $(seq 1 "$N"); do
    snap "initiator$i" > "$d/init${i}.before"
    ssh -n $OPTS "$(init "$i")" "$BLK" > "$d/init${i}.blk.before" 2>/dev/null
  done
  local pids=()
  for i in $(seq 1 "$N"); do
    ssh -n $OPTS "$(init "$i")" \
      "cd ~/hw-cas && DEV=\$($DISC) && sudo ./cas_gate --dev \$DEV --batch-size $B \
        --flush-clients $W --append-clients $L --duration $DUR --seed $((71*rep+i)) \
        --mode cas --k $K --log /tmp/is_i${i}.csv > /tmp/is_i${i}.sum 2>&1" &
    pids+=($!)
  done
  local fail=0; for p in "${pids[@]}"; do wait "$p" || fail=1; done
  for i in $(seq 1 "$N"); do
    ssh -n $OPTS "$(init "$i")" "$BLK" > "$d/init${i}.blk.after" 2>/dev/null
    scp $OPTS -q "$(init "$i"):/tmp/is_i${i}.csv" "$d/init${i}.csv" 2>/dev/null || true
    scp $OPTS -q "$(init "$i"):/tmp/is_i${i}.sum" "$d/init${i}.sum" 2>/dev/null || true
    snap "initiator$i" > "$d/init${i}.after"
  done
  snap target > "$d/target.after"
  echo "  $lbl rep$rep done (fail=$fail)"
}

mapfile -t ORDER < <(for p in $PLANS; do for r in $(seq 1 "$REPS"); do echo "$p $r"; done; done | shuf --random-source=<(yes "isolate"))
printf '%s\n' "${ORDER[@]}" > "$OUT/arm_order.txt"
echo "== ${#ORDER[@]} runs at N=$N W=$W, randomised order in $OUT/arm_order.txt =="
for a in "${ORDER[@]}"; do
  read -r spec r <<<"$a"; IFS=: read -r PHI B K <<<"$spec"
  one "$PHI" "$B" "$K" "$r"
done
echo "done -> $OUT"
