#!/usr/bin/env bash
# run-fanin.sh -- is the boundary the same aggregate Phi at every fan-in?
#
# F2 says aggregate in-flight BYTES determine the outcome "irrespective of how
# Phi was assembled". But every equal-Phi pair in the paper's byte-invariance
# table holds fan-in FIXED (Phi=8 and 16 are both N=2; Phi=12 and 24 are both
# N=3), so the claim was never tested across the one variable it names.
#
# It now looks false. At N=2, k=1 the fine sweep found Phi=19..26 MiB all
# clean -- including Phi=24 and 26 -- while the paper has Phi=24 collapsing at
# N=3, replicated twice. Offered load is not the explanation: the N=2 arms push
# ~2840 MB/s against ~2790 for the collapsed N=3 arms, both at line rate.
#
# This sweeps Phi at BOTH fan-ins in ONE randomised campaign, so the comparison
# is not across days or allocations. Every Phi here is reachable at N=2 and N=3
# with a whole number of 512 KiB units, and k=1 throughout so the per-initiator
# policy is identical.
set -uo pipefail
EXP="${1:?usage: run-fanin.sh <expbase> <outdir> [reps]}"
OUT="${2:?outdir}"; REPS="${3:-4}"
KEY=${KEY:-$HOME/.ssh/cloudlab_ed25519}
USER_CL=${USER_CL:?set USER_CL to your CloudLab username}
OPTS="-i $KEY -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"
W=${W:-8}; L=${L:-2}; DUR=${DUR:-15}
PHIS=${PHIS:-"18 21 24 27 30 33 36"}
mkdir -p "$OUT"
init(){ echo "$USER_CL@initiator$1.$EXP"; }
CTRS="local_ack_timeout_err packet_seq_err out_of_sequence rnr_nak_retry_err out_of_buffer np_cnp_sent rp_cnp_handled"
snap(){ ssh -n $OPTS "$USER_CL@$1.$EXP" 'source /local/dsscc-env 2>/dev/null; for c in '"$CTRS"'; do
  f=/sys/class/infiniband/$RDMA_DEV/ports/1/hw_counters/$c
  if [ -e "$f" ]; then printf "%s=%s\n" "$c" "$(cat $f 2>/dev/null || echo ABSENT)"
  else printf "%s=ABSENT\n" "$c"; fi; done' 2>/dev/null; }
DISC='for n in /dev/nvme*n1; do c=$(basename $n|sed "s/n[0-9]*$//"); grep -q dsscc /sys/class/nvme/$c/subsysnqn 2>/dev/null && echo $n && break; done'

one(){                 # $1=N $2=bytes $3=phi $4=rep
  local N="$1" B="$2" PHI="$3" rep="$4"
  local d="$OUT/phi${PHI}_N${N}_r${rep}"; mkdir -p "$d"
  echo "N=$N k=1 W=$W S_bytes=$B phi_MiB=$PHI" > "$d/config"
  snap target > "$d/target.before"
  for i in $(seq 1 "$N"); do
    snap "initiator$i" > "$d/init${i}.before"
    ssh -n $OPTS "$(init "$i")" "rm -f /tmp/fi_i${i}.csv /tmp/fi_i${i}.sum" >/dev/null 2>&1
  done
  local pids=()
  for i in $(seq 1 "$N"); do
    ssh -n $OPTS "$(init "$i")" \
      "cd ~/hw-cas && DEV=\$($DISC) && sudo ./cas_gate --dev \$DEV --batch-size $B \
        --flush-clients $W --append-clients $L --duration $DUR --seed $((97*rep+i)) \
        --mode cas --k 1 --log /tmp/fi_i${i}.csv > /tmp/fi_i${i}.sum 2>&1" &
    pids+=($!)
  done
  local fail=0; for p in "${pids[@]}"; do wait "$p" || fail=1; done
  for i in $(seq 1 "$N"); do
    scp $OPTS -q "$(init "$i"):/tmp/fi_i${i}.csv" "$d/init${i}.csv" 2>/dev/null || true
    scp $OPTS -q "$(init "$i"):/tmp/fi_i${i}.sum" "$d/init${i}.sum" 2>/dev/null || true
    snap "initiator$i" > "$d/init${i}.after"
  done
  snap target > "$d/target.after"
  echo "  Phi=$PHI N=$N rep$rep done (fail=$fail)"
}

mapfile -t PLAN < <(
  for PHI in $PHIS; do
    for N in 2 3; do
      B=$(python3 -c "
phi,n=$PHI,$N
b=phi*1048576//n
print(b if (phi*1048576)%(n*524288)==0 else '')")
      [ -n "$B" ] || continue
      for r in $(seq 1 "$REPS"); do echo "$N $B $PHI $r"; done
    done
  done | shuf --random-source=<(yes "fanin")
)
printf '%s\n' "${PLAN[@]}" > "$OUT/arm_order.txt"
echo "== ${#PLAN[@]} runs, k=1 throughout, randomised order in $OUT/arm_order.txt =="
for a in "${PLAN[@]}"; do read -r N B PHI r <<<"$a"; one "$N" "$B" "$PHI" "$r"; done
echo "done -> $OUT"
