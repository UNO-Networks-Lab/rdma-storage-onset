#!/usr/bin/env bash
# NVMe-oF TARGET: export one namespace over RDMA (RoCEv2) via kernel nvmet.
# Usage: sudo bash 10-target-nvmet.sh          (after 00-common-setup.sh)
# Env:   NQN=... to override the subsystem NQN.
set -euo pipefail
source /local/dsscc-env   # IF, IP, RDMA_DEV

NQN="${NQN:-nqn.2026-08.edu.unomaha.dsscc:nvme1}"
PORT_ID=1

[[ $EUID -eq 0 ]] || { echo "run with sudo" >&2; exit 1; }
modprobe nvmet
modprobe nvmet-rdma   # separate call: `modprobe nvmet nvmet-rdma` passes arg 2 as a module param
[[ -d /sys/module/nvmet_rdma ]] || { echo "nvmet_rdma failed to load; RDMA target cannot bind" >&2; exit 1; }

# Backing device: first NVMe namespace with nothing mounted on it; else null_blk.
DEV=""
# A single NVMe tops out well below 100 GbE line rate, so congestion runs want the
# RAM-speed null_blk backend instead. FORCE_NULLBLK=1 selects it explicitly.
if [[ "${FORCE_NULLBLK:-0}" == "1" ]]; then
  modprobe null_blk nr_devices=1 gb=64 bs=4096 irqmode=2 completion_nsec=10000 2>/dev/null || true
  DEV=/dev/nullb0
fi
[[ -n "$DEV" ]] || for cand in /dev/nvme*n1; do
  [[ -b "$cand" ]] || continue
  lsblk -no MOUNTPOINT "$cand" 2>/dev/null | grep -q . && continue
  DEV="$cand"; break
done
if [[ -z "$DEV" ]]; then
  # null_blk: RAM-less null device, ~10us simulated completion latency.
  # Reads return zeros; perfect for congestion-control work, useless for data tests.
  modprobe null_blk nr_devices=1 gb=64 bs=4096 irqmode=2 completion_nsec=10000
  DEV=/dev/nullb0
  echo "no free NVMe found -- exporting null_blk ($DEV)"
else
  if [[ "$DEV" == /dev/nullb* ]]; then
    echo "exporting null_blk ($DEV) -- RAM-speed backend for congestion runs"
  else
    echo "exporting real NVMe: $DEV (any data on it will be overwritten by write tests)"
  fi
fi

cd /sys/kernel/config/nvmet

# Idempotency: an already-enabled port rejects writes to addr_* with EBUSY, so a
# re-run would die at "echo: write error: Device or resource busy". Tear our own
# config down first -- order matters: unlink the port, then drop the namespace,
# then the subsystem.
if [[ -e ports/$PORT_ID/subsystems/"$NQN" ]]; then
  rm -f ports/$PORT_ID/subsystems/"$NQN"
fi
[[ -d ports/$PORT_ID ]] && rmdir ports/$PORT_ID 2>/dev/null
if [[ -d subsystems/"$NQN"/namespaces/1 ]]; then
  echo 0 > subsystems/"$NQN"/namespaces/1/enable 2>/dev/null || true
  rmdir subsystems/"$NQN"/namespaces/1 2>/dev/null || true
fi
[[ -d subsystems/"$NQN" ]] && rmdir subsystems/"$NQN" 2>/dev/null

mkdir -p subsystems/"$NQN"
echo 1 > subsystems/"$NQN"/attr_allow_any_host
mkdir -p subsystems/"$NQN"/namespaces/1
echo -n "$DEV" > subsystems/"$NQN"/namespaces/1/device_path
echo 1 > subsystems/"$NQN"/namespaces/1/enable

mkdir -p ports/$PORT_ID
echo rdma   > ports/$PORT_ID/addr_trtype
echo ipv4   > ports/$PORT_ID/addr_adrfam
echo "$IP"  > ports/$PORT_ID/addr_traddr
echo 4420   > ports/$PORT_ID/addr_trsvcid
if [[ ! -e ports/$PORT_ID/subsystems/"$NQN" ]]; then
  ln -s /sys/kernel/config/nvmet/subsystems/"$NQN" ports/$PORT_ID/subsystems/"$NQN" \
    || { echo "linking subsystem to port failed -- port did not enable" >&2; exit 1; }
fi
[[ -e ports/$PORT_ID/subsystems/"$NQN" ]] \
  || { echo "port has no subsystem linked; nothing is listening" >&2; exit 1; }

dmesg | tail -3
echo
echo "target ready: $NQN on $IP:4420/rdma backed by $DEV"
