#!/usr/bin/env bash
# Common setup for BOTH nodes: tooling + RoCE sanity checks.
# Usage: sudo bash 00-common-setup.sh
set -euo pipefail

EXP_SUBNET="${EXP_SUBNET:-10.10.1.}"   # experiment-link subnet assigned by profile.py

[[ $EUID -eq 0 ]] || { echo "run with sudo" >&2; exit 1; }

export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -yq rdma-core ibverbs-utils rdmacm-utils infiniband-diags \
  perftest nvme-cli fio mstflint ethtool

# libaio is only needed for fio's libaio ioengine, and its package name is not
# stable across releases: Ubuntu 22.04 has libaio1, 24.04 renamed it libaio1t64
# in the 64-bit time_t transition. Installing it in the line above meant that on
# 24.04 apt exited non-zero, `set -e` aborted the script, and /local/dsscc-env
# below was never written -- so every downstream script died on `source`. One
# optional package must not be able to do that.
if ! apt-get install -yq libaio1t64 2>/dev/null && \
   ! apt-get install -yq libaio1   2>/dev/null; then
    echo "WARNING: no libaio package available; fio --ioengine=libaio will not work" >&2
fi

# The experiment interface is the one carrying the 10.10.1.x address.
IF=$(ip -o -4 addr show | awk -v s="$EXP_SUBNET" '$4 ~ s {print $2; exit}')
[[ -n "$IF" ]] || { echo "no interface on ${EXP_SUBNET}0/24 -- is the experiment link up?" >&2; exit 1; }
IP=$(ip -o -4 addr show dev "$IF" | awk '{split($4,a,"/"); print a[1]; exit}')
RDMA_DEV=$(rdma link show | awk -v ifc="$IF" '$NF == ifc {split($2,a,"/"); print a[1]; exit}')

modprobe nvme-rdma

echo
echo "== RoCE sanity =="
echo "experiment interface : $IF ($IP)"
echo "rdma device          : ${RDMA_DEV:-NOT FOUND}"
rdma link show
ibv_devinfo 2>/dev/null | grep -E "hca_id|link_layer|active_mtu|state" || true
echo
echo "GID types on $RDMA_DEV (RoCEv2 entries expected):"
grep -H . /sys/class/infiniband/"${RDMA_DEV:-mlx5_0}"/ports/1/gid_attrs/types/* 2>/dev/null | head -4 || true

# /local exists on CloudLab nodes but not necessarily elsewhere (e.g. when
# rehearsing this stack on a lab VM), and every later script sources this file.
: "${DSSCC_ENV:=/local/dsscc-env}"   # NB: assign here, not inside $( ), which
                                      # would set it only in the subshell
mkdir -p "$(dirname "$DSSCC_ENV")"
cat > "$DSSCC_ENV" <<ENV
IF=$IF
IP=$IP
RDMA_DEV=$RDMA_DEV
ENV
echo
echo "wrote $DSSCC_ENV"
echo "next: 10-target-nvmet.sh (on target) / 20-initiator-connect.sh (on initiator)"
