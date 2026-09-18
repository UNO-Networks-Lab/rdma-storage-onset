#!/usr/bin/env bash
# Inspect (and optionally configure) RoCE congestion-control state on the ConnectX NIC.
# Usage: sudo bash 30-roce-inspect.sh              # show state only
#        sudo PFC_PRIO=3 bash 30-roce-inspect.sh   # + enable PFC on prio 3, steer RoCE onto it
set -euo pipefail
source /local/dsscc-env
[[ $EUID -eq 0 ]] || { echo "run with sudo" >&2; exit 1; }

PCI=$(ethtool -i "$IF" | awk '/bus-info/{print $2}')

echo "== NIC =="
ethtool -i "$IF" | head -3
lspci -s "$PCI" -nn 2>/dev/null | head -1 || true

echo; echo "== firmware congestion-control config (DCQCN = ROCE_CC_*) =="
mstconfig -d "$PCI" q 2>/dev/null | grep -iE "ROCE_CC|CNP|ECN" \
  || echo "(mstconfig query failed; full DCQCN knobs need NVIDIA DOCA-OFED / mlxconfig)"

echo; echo "== PFC state =="
dcb pfc show dev "$IF" 2>/dev/null || ethtool -a "$IF"

echo; echo "== per-priority + DCQCN counters (watch these under load) =="
ethtool -S "$IF" | grep -E "prio3" | head -8 || true
ethtool -S "$IF" | grep -iE "cnp|ecn_marked" || true

if [[ -n "${PFC_PRIO:-}" ]]; then
  echo; echo "== enabling lossless prio $PFC_PRIO for RoCE =="
  dcb pfc set dev "$IF" prio-pfc all:off "$PFC_PRIO":on
  dcb app replace dev "$IF" dscp-prio 26:"$PFC_PRIO" 2>/dev/null \
    || dcb app add dev "$IF" dscp-prio 26:"$PFC_PRIO"
  mountpoint -q /sys/kernel/config || mount -t configfs none /sys/kernel/config
  mkdir -p /sys/kernel/config/rdma_cm/"$RDMA_DEV"
  echo 106 > /sys/kernel/config/rdma_cm/"$RDMA_DEV"/ports/1/default_roce_tos
  echo "done: PFC on prio $PFC_PRIO; RoCE DSCP 26 -> prio $PFC_PRIO; default_roce_tos=106 (DSCP 26 + ECT)"
  echo "note: run this on BOTH nodes; re-run 10/20 scripts to pick up the new TOS on new connections"
  echo "note: per-prio DCQCN enable + alpha/rate tuning needs DOCA-OFED (mlnx_qos, /sys/class/net/*/ecn)"
fi
