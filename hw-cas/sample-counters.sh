#!/usr/bin/env bash
# sample-counters.sh -- high-rate RDMA counter sampler, run ON a testbed node.
#
# The paper's per-run before/after snapshots can say THAT a counter moved but
# never WHEN. That is exactly the gap behind the review's "most important
# missing baseline": we concede an ECN/CNP signal exists before the ACK
# timeout, but we have never measured how much warning it actually gives. This
# samples the counters on a fixed tick with epoch timestamps so the ORDER and
# the INTERVAL between signals are observable within a single node's clock.
#
#   ./sample-counters.sh <out.csv> [interval_ms] [max_s]
#
# A counter that does not exist is written as the literal ABSENT, never as 0 --
# these names are mlx5-specific and a silent 0 would turn a wrong device into a
# clean-looking measurement.
set -uo pipefail
OUT="${1:?usage: sample-counters.sh <out.csv> [interval_ms] [max_s]}"
IVL_MS="${2:-10}"
MAX_S="${3:-120}"
source /local/dsscc-env 2>/dev/null
DIR="/sys/class/infiniband/${RDMA_DEV:?RDMA_DEV unset}/ports/1/hw_counters"
CTRS="rp_cnp_handled np_cnp_sent np_ecn_marked_roce_packets local_ack_timeout_err packet_seq_err out_of_sequence out_of_buffer rnr_nak_retry_err roce_adp_retrans"

# Resolve which counters exist ONCE, up front, so the hot loop does no stat()s
# and the header is honest about what is being recorded.
have=(); miss=()
for c in $CTRS; do
  if [ -e "$DIR/$c" ]; then have+=("$c"); else miss+=("$c"); fi
done
{
  echo "# dev=${RDMA_DEV} interval_ms=${IVL_MS} host=$(hostname -s)"
  echo "# absent=${miss[*]:-none}"
  printf "epoch_ms"; for c in "${have[@]}"; do printf ",%s" "$c"; done; echo
} > "$OUT"

end=$(( $(date +%s) + MAX_S ))
# Read all counters per tick with a single cat so the sample is as close to
# atomic as sysfs allows; interleaving open() calls would smear the ordering
# this experiment exists to measure.
paths=(); for c in "${have[@]}"; do paths+=("$DIR/$c"); done
while [ "$(date +%s)" -lt "$end" ]; do
  ts=$(date +%s%3N)
  vals=$(cat "${paths[@]}" 2>/dev/null | tr '\n' ',' | sed 's/,$//')
  echo "${ts},${vals}" >> "$OUT"
  sleep "$(awk "BEGIN{print $IVL_MS/1000}")"
done
