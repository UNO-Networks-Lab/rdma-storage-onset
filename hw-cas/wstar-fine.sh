#!/usr/bin/env bash
# wstar-fine.sh -- is the boundary in BYTES or in outstanding COMMANDS?
#
# The paper's F2 says aggregate bytes separate the outcomes better than
# admitted operations, and carefully notes it cannot distinguish byte count
# from NVMe command count because "we did not record that mapping". The mapping
# is now measured: max_hw_sectors_kb = 1024 on every initiator, so the block
# layer splits any write of S MiB into ceil(S) commands of 1 MiB. Consequently
# the outstanding command count equals Phi in MiB EXACTLY, for every
# configuration the paper reports -- the two hypotheses are perfectly
# collinear there and no run in the paper can separate them.
#
# Half-MiB transfer sizes break the collinearity, because ceil() is flat across
# them. At N=2, k=1:
#
#     S=10.5 -> 11 cmds/write -> 22 commands, Phi=21 MiB
#     S=11.0 -> 11 cmds/write -> 22 commands, Phi=22 MiB
#
# Same commands, different bytes. Four such pairs straddle the measured
# boundary (21,24]. If the boundary is byte-driven, a pair can split. If it is
# command-driven, pairs must agree internally and transitions can only fall
# BETWEEN pairs. Either outcome is informative and one of them falsifies F2's
# preferred reading.
#
# The split factor is verified per run from /sys/block/<dev>/stat rather than
# assumed from max_hw_sectors_kb.
set -uo pipefail
EXP="${1:?usage: wstar-fine.sh <expbase> <outdir> [reps]}"
OUT="${2:?outdir}"; REPS="${3:-4}"
KEY=${KEY:-$HOME/.ssh/cloudlab_ed25519}
USER_CL=${USER_CL:?set USER_CL to your CloudLab username}
OPTS="-i $KEY -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"
N=${N:-2}; W=${W:-8}; L=${L:-2}; DUR=${DUR:-15}
HALVES=${HALVES:-"19 20 21 22 23 24 25 26"}   # S = half/2 MiB
mkdir -p "$OUT"
init(){ echo "$USER_CL@initiator$1.$EXP"; }
CTRS="local_ack_timeout_err packet_seq_err out_of_sequence rnr_nak_retry_err out_of_buffer np_cnp_sent rp_cnp_handled"
BLK='for n in /dev/nvme*n1; do c=$(basename $n); grep -q dsscc /sys/class/nvme/${c%n*}/subsysnqn 2>/dev/null && cat /sys/block/$c/stat && break; done'
snap(){ ssh -n $OPTS "$USER_CL@$1.$EXP" 'source /local/dsscc-env 2>/dev/null; for c in '"$CTRS"'; do
  f=/sys/class/infiniband/$RDMA_DEV/ports/1/hw_counters/$c
  if [ -e "$f" ]; then printf "%s=%s\n" "$c" "$(cat $f 2>/dev/null || echo ABSENT)"
  else printf "%s=ABSENT\n" "$c"; fi; done' 2>/dev/null; }
DISC='for n in /dev/nvme*n1; do c=$(basename $n|sed "s/n[0-9]*$//"); grep -q dsscc /sys/class/nvme/$c/subsysnqn 2>/dev/null && echo $n && break; done'

one(){                 # $1=bytes $2=label $3=rep
  local B="$1" lbl="$2" rep="$3"
  local d="$OUT/${lbl}_r${rep}"; mkdir -p "$d"
  echo "N=$N k=1 S_bytes=$B" > "$d/config"
  snap target > "$d/target.before"
  for i in $(seq 1 "$N"); do
    snap "initiator$i" > "$d/init${i}.before"
    ssh -n $OPTS "$(init "$i")" "$BLK" > "$d/init${i}.blk.before" 2>/dev/null
  done
  local pids=()
  for i in $(seq 1 "$N"); do
    ssh -n $OPTS "$(init "$i")" \
      "cd ~/hw-cas && DEV=\$($DISC) && sudo ./cas_gate --dev \$DEV --batch-size $B \
        --flush-clients $W --append-clients $L --duration $DUR --seed $((53*rep+i)) \
        --mode cas --k 1 --log /tmp/wf_i${i}.csv > /tmp/wf_i${i}.sum 2>&1" &
    pids+=($!)
  done
  local fail=0; for p in "${pids[@]}"; do wait "$p" || fail=1; done
  for i in $(seq 1 "$N"); do
    ssh -n $OPTS "$(init "$i")" "$BLK" > "$d/init${i}.blk.after" 2>/dev/null
    scp $OPTS -q "$(init "$i"):/tmp/wf_i${i}.csv" "$d/init${i}.csv" 2>/dev/null || true
    scp $OPTS -q "$(init "$i"):/tmp/wf_i${i}.sum" "$d/init${i}.sum" 2>/dev/null || true
    snap "initiator$i" > "$d/init${i}.after"
  done
  snap target > "$d/target.after"
  echo "  $lbl rep$rep done (fail=$fail)"
}

mapfile -t PLAN < <(
  for h in $HALVES; do
    B=$(python3 -c "print(int($h/2*1048576))")
    lbl=$(python3 -c "print('S%.1f' % ($h/2))" | tr -d ' ')
    for r in $(seq 1 "$REPS"); do echo "$B $lbl $r"; done
  done | shuf --random-source=<(yes "wstar-fine-v2")
)
printf '%s\n' "${PLAN[@]}" > "$OUT/arm_order.txt"
echo "== ${#PLAN[@]} runs at N=$N k=1, randomised order in $OUT/arm_order.txt =="
for a in "${PLAN[@]}"; do read -r B lbl r <<<"$a"; one "$B" "$lbl" "$r"; done
echo "done -> $OUT"
