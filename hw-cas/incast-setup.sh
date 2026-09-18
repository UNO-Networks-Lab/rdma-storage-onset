#!/usr/bin/env bash
# incast-setup.sh -- stage an N:1 incast testbed on a live CloudLab experiment.
#
# run-incast.sh and friends all begin "assumes the target is exporting null_blk,
# every initiator is connected, and cas_gate is built on each initiator". This
# is the script that establishes those assumptions. It was referenced by those
# headers long before it existed; written 2026-09-04 ahead of the 8:1 window so
# bring-up is not improvised against a running reservation clock.
#
# Idempotent: safe to re-run after a node reboots or a connection drops.
#
#   ./incast-setup.sh <expbase> [N]
#   expbase = cas-incast.dsscc-pg0.utah.cloudlab.us   (from the portal List View)
#   N       = number of initiators (default 4; use 8 for the TGATE window)
#
# Node names come from cloudlab/profile-incast.py: "target", "initiator1..N".
set -uo pipefail
EXP="${1:?usage: incast-setup.sh <expbase> [N]}"
N="${2:-4}"
KEY=${KEY:-$HOME/.ssh/cloudlab_ed25519}
USER_CL=${USER_CL:?set USER_CL to your CloudLab username}
# The experiment link is 10.10.1.x under cloudlab/profile-incast.py. Overridable
# so this script can be rehearsed against a lab VM on a different subnet before
# reserved time is spent on it.
EXP_SUBNET=${EXP_SUBNET:-10.10.1.}
OPTS="-i $KEY -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15"
HERE="$(cd "$(dirname "$0")" && pwd)"
FAIL=0

host(){ echo "$USER_CL@$1.$EXP"; }
say(){ printf '\n=== %s ===\n' "$*"; }
ck(){ if [ "$1" -eq 0 ]; then echo "  ok:   $2"; else FAIL=$((FAIL+1)); echo "  FAIL: $2"; fi; }

ALL="target"; for i in $(seq 1 "$N"); do ALL="$ALL initiator$i"; done

# ---------------------------------------------------------------- reachability
say "reachability ($((N+1)) nodes)"
for n in $ALL; do
  ssh $OPTS "$(host "$n")" true 2>/dev/null; ck $? "ssh $n"
done
[ "$FAIL" -eq 0 ] || { echo; echo "ABORT: not all nodes reachable. Check the key ($KEY) is registered in the portal (Manage SSH Keys) and that the experiment is fully booted."; exit 1; }

# ---------------------------------------------------------------- stage code
say "stage scripts + hw-cas onto every node"
# scp -r DIR dest creates dest on the first run but copies INTO it on every
# run after, producing ~/scripts/scripts and leaving the top-level copy stale.
# That silently defeats the whole point of re-running this script after editing
# something. Clear the destinations and copy contents, so staging is genuinely
# idempotent.
for n in $ALL; do
  ( ssh $OPTS "$(host "$n")" 'rm -rf ~/scripts ~/hw-cas && mkdir -p ~/scripts ~/hw-cas' &&
    scp $OPTS -qr "$HERE/../cloudlab/scripts/." "$(host "$n"):scripts/" &&
    scp $OPTS -qr "$HERE/." "$(host "$n"):hw-cas/" ) 2>/dev/null
  ck $? "staged $n"
done

# ---------------------------------------------------------------- common setup
say "common setup (apt + RoCE sanity) -- slowest step, runs in parallel"
pids=(); for n in $ALL; do
  ssh $OPTS "$(host "$n")" "sudo EXP_SUBNET='$EXP_SUBNET' bash ~/scripts/00-common-setup.sh > /tmp/setup.log 2>&1" &
  pids+=($!)
done
i=0; for n in $ALL; do wait "${pids[$i]}"; ck $? "00-common-setup on $n"; i=$((i+1)); done

# ---------------------------------------------------------------- target
say "target: export null_blk over nvmet-rdma"
ssh $OPTS "$(host target)" 'sudo FORCE_NULLBLK=1 bash ~/scripts/10-target-nvmet.sh > /tmp/target.log 2>&1'
ck $? "10-target-nvmet.sh"
ssh $OPTS "$(host target)" 'sudo dmesg | grep -q "nvmet_rdma: enabling port"'
ck $? "nvmet_rdma port enabled (dmesg)"

# ---------------------------------------------------------------- initiators
say "initiators: connect + build cas_gate"
# 20-initiator-connect.sh defaults TARGET_IP to 10.10.1.1, which is only correct
# because profile-incast.py happens to assign that to the target. Read the
# address the target actually bound and pass it explicitly, so a profile change
# or a different node ordering surfaces as a clear failure here rather than as
# initiators quietly dialling the wrong host.
TARGET_IP=$(ssh $OPTS "$(host target)" 'sed -n "s/^IP=//p" /local/dsscc-env' 2>/dev/null)
ck $([ -n "$TARGET_IP" ] && echo 0 || echo 1) "target bound address: ${TARGET_IP:-UNKNOWN}"

pids=(); for i in $(seq 1 "$N"); do
  ssh $OPTS "$(host "initiator$i")" \
    "sudo TARGET_IP='$TARGET_IP' bash ~/scripts/20-initiator-connect.sh > /tmp/connect.log 2>&1;
     sudo apt-get install -yq liburing-dev >> /tmp/connect.log 2>&1;
     cd ~/hw-cas && make clean >/dev/null 2>&1; make >> /tmp/connect.log 2>&1" &
  pids+=($!)
done
i=0; for j in $(seq 1 "$N"); do wait "${pids[$i]}"; ck $? "connect+build on initiator$j"; i=$((i+1)); done

# ---------------------------------------------------------------- verify
say "verify: every initiator sees the dsscc namespace and has a cas_gate binary"
DISC='for n in /dev/nvme*n1; do c=$(basename $n|sed "s/n[0-9]*$//"); grep -q dsscc /sys/class/nvme/$c/subsysnqn 2>/dev/null && echo $n && break; done'
for i in $(seq 1 "$N"); do
  DEV=$(ssh $OPTS "$(host "initiator$i")" "$DISC" 2>/dev/null)
  ck $([ -n "$DEV" ] && echo 0 || echo 1) "initiator$i namespace: ${DEV:-NONE}"
  ssh $OPTS "$(host "initiator$i")" 'test -x ~/hw-cas/cas_gate' 2>/dev/null
  ck $? "initiator$i cas_gate built"
done

say "collapse-signature counters must be readable on every node"
# The pre-registered criterion is a counter criterion. If these are missing --
# wrong NIC, wrong device name, a fabric that does not implement them -- then a
# collapsed run and a clean run look identical, and P1 cannot be scored at all.
# Fail here, during bring-up, rather than after the measurement.
CTRS="local_ack_timeout_err packet_seq_err out_of_sequence"
for n in $ALL; do
  missing=$(ssh $OPTS "$(host "$n")" 'source /local/dsscc-env 2>/dev/null; m=""
    for c in '"$CTRS"'; do
      [ -e /sys/class/infiniband/$RDMA_DEV/ports/1/hw_counters/$c ] || m="$m $c"
    done; echo "$m"' 2>/dev/null)
  ck $([ -z "$missing" ] && echo 0 || echo 1) "counters on $n${missing:+ -- MISSING:$missing}"
done

say "result"
if [ "$FAIL" -eq 0 ]; then
  echo "  ${N}:1 testbed READY."
  echo "  next:  ./run-incast.sh $EXP <outdir> 3        # NLIST=\"1 2 4 8\" MAXN=8 for the 8:1 sweep"
else
  echo "  $FAIL check(s) failed -- fix before spending reservation time."
  echo "  logs on each node: /tmp/setup.log /tmp/target.log /tmp/connect.log"
fi
exit "$FAIL"
