#!/usr/bin/env bash
# Sample ENDPOINT state during a workload: RDMA credit/flow-control counters,
# per-QP send progress, and NVMe-oF queue depth.
#
# Why this exists: the 2026-09-01 incast measurement showed a sharp knee between
# 3:1 and 4:1 fan-in (p99.9 latency 19 ms -> 813 ms, fairness 0.93 -> 0.61) with
# ZERO packet loss and ZERO PFC pause frames. Four fabric congestion-control
# algorithms in ns-3 (DCQCN, HPCC, TIMELY, DCTCP) all failed to reproduce it and
# all reported perfect fairness, understating the measured tail by 52-72x. The
# fabric is therefore not where the knee lives -- the endpoints are. This script
# captures the endpoint signals the fabric cannot see.
#
#   usage: sudo bash 40-endpoint-telemetry.sh [-i interval_s] [-o outdir] [-d duration_s]
#          sudo bash 40-endpoint-telemetry.sh -d 30 -o /local/telemetry
#   stop early: touch <outdir>/STOP   (or send SIGINT/SIGTERM)
#
# Outputs (CSV, one row per sample):
#   endpoint-<host>.csv  aggregate counters + NVMe queue depth
#   qp-<host>.csv        per-QP send-sequence progress (stall detection)
set -uo pipefail

INTERVAL=0.1
DURATION=0
OUTDIR=/local/telemetry
while getopts "i:o:d:" opt; do
  case $opt in
    i) INTERVAL=$OPTARG ;;
    o) OUTDIR=$OPTARG ;;
    d) DURATION=$OPTARG ;;
    *) echo "usage: $0 [-i interval_s] [-o outdir] [-d duration_s]" >&2; exit 2 ;;
  esac
done

[[ $EUID -eq 0 ]] || { echo "run with sudo (sysfs hw_counters need root)" >&2; exit 1; }
# shellcheck disable=SC1091
source /local/dsscc-env    # IF, IP, RDMA_DEV
mkdir -p "$OUTDIR"
HOST=$(hostname -s)
HW=/sys/class/infiniband/$RDMA_DEV/ports/1/hw_counters

# The NVMe controller reached over RDMA (transport=rdma), not the local PCIe ones.
RDMA_NVME=""
for c in /sys/class/nvme/nvme*; do
  [[ -r "$c/transport" ]] || continue
  if [[ "$(cat "$c/transport")" == "rdma" ]]; then RDMA_NVME=$(basename "$c"); break; fi
done
# Block devices carrying in-flight depth. With nvme_core.multipath=Y (the default
# here) the HEAD device nvme<C>n<N> always reports 0 -- the real counters live on
# the PATH device nvme<C>c<C>n<N>. Measured under 293k IOPS: head=0, path=118.
# Collect every path device for this controller and sum; fall back to the head.
NS_BLKS=()
if [[ -n "$RDMA_NVME" ]]; then
  for b in /sys/block/${RDMA_NVME}c*n*; do
    [[ -r "$b/inflight" ]] && NS_BLKS+=("$(basename "$b")")
  done
  if [[ ${#NS_BLKS[@]} -eq 0 ]]; then
    for b in /sys/block/${RDMA_NVME}n*; do
      [[ -r "$b/inflight" ]] && NS_BLKS+=("$(basename "$b")")
    done
  fi
fi

# Counters worth sampling. Credit/flow-control first -- these are the hypothesis:
#   out_of_buffer      receiver had no posted buffer (RNR condition)
#   rnr_nak_retry_err  RNR NAK retries exhausted -- explicit credit starvation
# then retransmission/ordering, then host-side DCQCN reaction-point counters.
COUNTERS=(
  out_of_buffer rnr_nak_retry_err
  packet_seq_err out_of_sequence implied_nak_seq_err local_ack_timeout_err
  req_cqe_error resp_cqe_error duplicate_request
  roce_adp_retrans roce_adp_retrans_to
  roce_slow_restart roce_slow_restart_cnps roce_slow_restart_trans
  np_cnp_sent np_ecn_marked_roce_packets rp_cnp_handled rp_cnp_ignored
  rx_write_requests rx_read_requests
)

MAIN="$OUTDIR/endpoint-$HOST.csv"
QPCSV="$OUTDIR/qp-$HOST.csv"
{
  printf "ts_ns,host,iface,rdma_dev"
  for c in "${COUNTERS[@]}"; do printf ",%s" "$c"; done
  printf ",nvme_ctrl,nvme_queue_count,inflight_read,inflight_write"
  printf ",prio3_pause,prio3_discards,prio3_rx_bytes,qp_count\n"
} > "$MAIN"
echo "ts_ns,host,lqpn,rqpn,state,sq_psn,rq_psn" > "$QPCSV"

echo "sampling every ${INTERVAL}s -> $MAIN"
echo "  rdma_dev=$RDMA_DEV nvme_over_rdma=${RDMA_NVME:-none} block=${NS_BLKS[*]:-none}"
[[ "$DURATION" != 0 ]] && echo "  duration=${DURATION}s" || echo "  duration=until STOP file or signal"

rm -f "$OUTDIR/STOP"
trap 'echo; echo "stopped -> $MAIN"; exit 0' INT TERM
START=$(date +%s.%N)

while :; do
  NOW_NS=$(date +%s%N)
  row="$NOW_NS,$HOST,$IF,$RDMA_DEV"
  for c in "${COUNTERS[@]}"; do
    v=$(cat "$HW/$c" 2>/dev/null); row+=",${v:-NA}"
  done
  qc=$([[ -n "$RDMA_NVME" ]] && cat "/sys/class/nvme/$RDMA_NVME/queue_count" 2>/dev/null || echo NA)
  if [[ ${#NS_BLKS[@]} -gt 0 ]]; then
    ifr=0; ifw=0
    for nb in "${NS_BLKS[@]}"; do
      read -r a b < <(awk '{print $1, $2}' "/sys/block/$nb/inflight" 2>/dev/null)
      ifr=$(( ifr + ${a:-0} )); ifw=$(( ifw + ${b:-0} ))
    done
  else ifr=NA; ifw=NA; fi
  row+=",${RDMA_NVME:-NA},${qc:-NA},${ifr:-NA},${ifw:-NA}"

  # ethtool per-priority: proves whether the fabric saw anything at all
  es=$(ethtool -S "$IF" 2>/dev/null)
  p3p=$(awk -F: '/tx_prio3_pause:/{gsub(/ /,"",$2); print $2; exit}' <<<"$es")
  p3d=$(awk -F: '/rx_prio3_discards:/{gsub(/ /,"",$2); print $2; exit}' <<<"$es")
  p3b=$(awk -F: '/rx_prio3_bytes:/{gsub(/ /,"",$2); print $2; exit}' <<<"$es")

  # per-QP send progress: a QP whose sq_psn stops advancing is stalled, which is
  # what unfair bandwidth allocation looks like from the endpoint side.
  qpn=0
  while read -r line; do
    [[ "$line" == *lqpn* ]] || continue
    l=$(grep -oP 'lqpn \K[0-9]+' <<<"$line" | head -1)
    r=$(grep -oP 'rqpn \K[0-9]+' <<<"$line" | head -1)
    # negative lookbehind: 'path-mig-state MIGRATED' also ends in 'state', and a
    # bare 'state \K' match grabs both values, embedding a newline that splits
    # the CSV row in two.
    st=$(grep -oP '(?<!-)state \K[A-Z_]+' <<<"$line" | head -1)
    sq=$(grep -oP 'sq-psn \K[0-9]+' <<<"$line" | head -1)
    rq=$(grep -oP 'rq-psn \K[0-9]+' <<<"$line" | head -1)
    [[ -n "${l:-}" ]] || continue
    echo "$NOW_NS,$HOST,$l,$r,${st:-NA},${sq:-NA},${rq:-NA}" >> "$QPCSV"
    qpn=$((qpn+1))
  done < <(rdma resource show qp link "$RDMA_DEV" 2>/dev/null)

  echo "$row,${p3p:-NA},${p3d:-NA},${p3b:-NA},$qpn" >> "$MAIN"

  [[ -e "$OUTDIR/STOP" ]] && { echo "STOP file seen"; break; }
  if [[ "$DURATION" != 0 ]]; then
    el=$(awk -v s="$START" 'BEGIN{printf "%.3f", systime()+0-s}' 2>/dev/null || echo 0)
    now=$(date +%s.%N)
    if awk -v a="$now" -v b="$START" -v d="$DURATION" 'BEGIN{exit !(a-b>=d)}'; then break; fi
  fi
  sleep "$INTERVAL"
done
echo "wrote $(wc -l < "$MAIN") samples -> $MAIN"
echo "wrote $(wc -l < "$QPCSV") per-QP rows -> $QPCSV"
