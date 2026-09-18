#!/usr/bin/env bash
# NVMe-oF INITIATOR: discover, connect, and run a read-only fio smoke test.
# Usage: sudo bash 20-initiator-connect.sh     (after 00-common-setup.sh)
set -euo pipefail
source /local/dsscc-env

TARGET_IP="${TARGET_IP:-10.10.1.1}"
# On a 128-core node nvme-cli defaults to one I/O queue per CPU (63 here); bringing
# them up took ~14 s, past the target's 5 s keep-alive, so nvmet tore the controller
# down mid-connect. Bound the queues and widen the keep-alive. A fixed, known queue
# count is also what congestion-control runs want -- it pins the number of flows.
NR_IO_QUEUES="${NR_IO_QUEUES:-8}"
KATO="${KATO:-30}"
NQN="${NQN:-nqn.2026-08.edu.unomaha.dsscc:nvme1}"

[[ $EUID -eq 0 ]] || { echo "run with sudo" >&2; exit 1; }
modprobe nvme-rdma
nvme disconnect -n "$NQN" >/dev/null 2>&1 || true   # clear any stale controller

echo "== discover =="
nvme discover -t rdma -a "$TARGET_IP" -s 4420
echo "== connect =="
nvme connect -t rdma -a "$TARGET_IP" -s 4420 -n "$NQN" \
  -i "$NR_IO_QUEUES" -k "$KATO"
sleep 1

NVMEDEV=""
for d in /sys/class/nvme/nvme*; do
  [[ -f "$d/transport" ]] || continue
  [[ "$(cat "$d/transport")" == rdma ]] && { NVMEDEV="/dev/$(basename "$d")n1"; break; }
done
[[ -n "$NVMEDEV" && -b "$NVMEDEV" ]] || { echo "connected rdma nvme device not found" >&2; exit 1; }
nvme list

echo
echo "== fio smoke: 4KiB randread, QD32 x 4 jobs, 30s ($NVMEDEV over RoCEv2) =="
fio --name=iops --ioengine=libaio --filename="$NVMEDEV" --rw=randread --bs=4k --iodepth=32 \
    --numjobs=4 --direct=1 --time_based --runtime=30 --group_reporting
echo
echo "== fio smoke: 128KiB seqread, QD32 x 2 jobs, 30s (bandwidth) =="
fio --name=bw --ioengine=libaio --filename="$NVMEDEV" --rw=read --bs=128k --iodepth=32 \
    --numjobs=2 --direct=1 --time_based --runtime=30 --group_reporting
echo
echo "disconnect with: sudo nvme disconnect -n $NQN"
