#!/usr/bin/env python3
"""How much warning does an ECN/CNP signal give before the ACK timeout?

Reads the 10 ms counter series written by sample-counters.sh and reports, per
initiator and on that initiator's own clock:

  * whether rp_cnp_handled moves at all (an initiator-side controller's signal)
  * whether local_ack_timeout_err moves (the signal our AIMD controller used)
  * the interval between the first of each -- the warning a CNP-driven
    controller would have had
  * per-episode lead: for each ACK-timeout increment, how long before it the
    most recent CNP increment arrived

It also attributes every increment to INSIDE or OUTSIDE the workload window,
because the paper's before/after snapshots bracket `nvme connect` too, and an
open item from the replication is whether some recorded ACK timeouts are setup
artifacts rather than workload events.

    python3 analyze-cnp.py <outdir>
"""
import csv
import glob
import os
import sys
from statistics import mean, median

CNP = "rp_cnp_handled"
ACK = "local_ack_timeout_err"
SEQ = ("packet_seq_err", "out_of_sequence")
ECN = "np_ecn_marked_roce_packets"
STALL_US = 1e6      # an operation this slow is the failure a controller must avoid


def stalls(d, idx, w0):
    """Epoch-ms times at which this initiator's own >1s operations COMPLETED.

    The op log timestamps completions relative to the gate's own t0, and w0 is
    the epoch captured immediately before the gate was exec'd. The gap between
    the two is sudo+init, tens to low hundreds of ms, which is an offset on
    every stall equally and is small against the multi-second quantity being
    measured -- but it is an offset, not zero, and lead times below ~0.5 s
    should not be read from this correlation.
    """
    out = []
    f = os.path.join(d, f"init{idx}.csv")
    if not os.path.exists(f):
        return out
    for r in csv.DictReader(open(f)):
        try:
            if float(r["latency_us"]) >= STALL_US:
                out.append(w0 + int(float(r["t_ms"])))
        except (KeyError, TypeError, ValueError):
            continue
    return sorted(out)


def series(path):
    """-> (header list, [(epoch_ms, {counter: value})])"""
    rows = []
    with open(path) as f:
        lines = [l for l in f if not l.startswith("#")]
    rd = csv.DictReader(lines)
    for r in rd:
        try:
            t = int(r["epoch_ms"])
        except (KeyError, TypeError, ValueError):
            continue
        vals = {}
        for k, v in r.items():
            if k == "epoch_ms" or v is None:
                continue
            try:
                vals[k] = int(v)
            except ValueError:
                vals[k] = None          # unparsable stays None, never 0
        rows.append((t, vals))
    return rows


def increments(rows, name):
    """Times (epoch_ms) at which `name` increased, with the size of the step."""
    out, prev = [], None
    for t, v in rows:
        cur = v.get(name)
        if cur is None:
            continue
        if prev is not None and cur > prev:
            out.append((t, cur - prev))
        prev = cur
    return out


def window(path):
    try:
        nums = [int(x) for x in open(path).read().split()]
        return (nums[0], nums[1]) if len(nums) >= 2 else None
    except Exception:
        return None


STALL_LEADS = {}
ARM = [""]


def analyse(d):
    ARM[0] = os.path.basename(d).rsplit("_r", 1)[0]
    cfg = open(os.path.join(d, "config")).read().strip() if \
        os.path.exists(os.path.join(d, "config")) else os.path.basename(d)
    print(f"\n=== {os.path.basename(d)}   {cfg}")
    leads_all = []
    for cf in sorted(glob.glob(os.path.join(d, "initiator*.ctr.csv"))):
        node = os.path.basename(cf).split(".")[0]
        idx = node.replace("initiator", "")
        rows = series(cf)
        if not rows:
            print(f"  {node}: NO SAMPLES")
            continue
        w = window(os.path.join(d, f"init{idx}.window"))
        cnp = increments(rows, CNP)
        ack = increments(rows, ACK)
        seq = [x for s in SEQ for x in increments(rows, s)]
        span = (rows[-1][0] - rows[0][0]) / 1000.0

        def inside(ev):
            return [e for e in ev if w and w[0] <= e[0] <= w[1]]

        ci, ai, si = inside(cnp), inside(ack), inside(seq)
        ecn = increments(rows, ECN)
        print(f"  {node}: {len(rows)} samples over {span:.1f}s"
              + (f", workload window {(w[1]-w[0])/1000.0:.1f}s" if w else ", NO WINDOW"))
        print(f"    {CNP:24s} {len(cnp):4d} increments ({len(ci)} in-window), "
              f"total +{sum(n for _, n in cnp)}")
        print(f"    {ACK:24s} {len(ack):4d} increments ({len(ai)} in-window), "
              f"total +{sum(n for _, n in ack)}")
        print(f"    {'seq/oos':24s} {len(seq):4d} increments ({len(si)} in-window)")

        if ack and not ci and not cnp:
            print("    !! ACK timeouts with NO CNP at all on this node")
        if ack and w:
            out_of_window = len(ack) - len(ai)
            if out_of_window:
                print(f"    !! {out_of_window}/{len(ack)} ACK-timeout increments fall "
                      f"OUTSIDE the workload window (setup/teardown, not load)")
        print(f"    {ECN:24s} {len(ecn):4d} increments, "
              f"total +{sum(n for _, n in ecn)}"
              + ("   <-- NO ECN MARKING OBSERVED" if not ecn else ""))

        # The comparison that actually matters for control, and the only one
        # free of cross-node clock error: this initiator's own CNP signal
        # against this initiator's own multi-second stalls.
        if w:
            st = stalls(d, idx, w[0])
            print(f"    {'stalls >1s (own ops)':24s} {len(st):4d}")
            if st and ci:
                per_st = []
                for t_s in st:
                    before = [t for t, _ in ci if t < t_s]
                    if before:
                        per_st.append((t_s - before[-1]) / 1000.0)
                if per_st:
                    print(f"    CNP -> own stall completion: n={len(per_st)} "
                          f"median={median(per_st):.3f}s min={min(per_st):.3f}s "
                          f"max={max(per_st):.3f}s")
                    STALL_LEADS.setdefault(ARM[0], []).extend(per_st)
                unwarned = sum(1 for t_s in st if not [t for t, _ in ci if t < t_s])
                if unwarned:
                    print(f"    !! {unwarned}/{len(st)} stalls had NO preceding CNP")
            elif st and not ci:
                print("    !! stalls occurred with NO CNP signal at all on this node")

        if ci and ai:
            first_lead = (ai[0][0] - ci[0][0]) / 1000.0
            print(f"    first CNP -> first ACK timeout: {first_lead:+.3f} s")
            per = []
            for t_a, _ in ai:
                before = [t for t, _ in ci if t < t_a]
                if before:
                    per.append((t_a - before[-1]) / 1000.0)
            if per:
                print(f"    per-episode lead: n={len(per)} median={median(per):.3f}s "
                      f"mean={mean(per):.3f}s min={min(per):.3f}s max={max(per):.3f}s")
                leads_all += per
    return leads_all


def main(root):
    dirs = sorted(d for d in glob.glob(os.path.join(root, "*")) if os.path.isdir(d))
    if not dirs:
        print(f"no run directories under {root}")
        return 1
    by_arm = {}
    for d in dirs:
        arm = os.path.basename(d).rsplit("_r", 1)[0]
        by_arm.setdefault(arm, []).extend(analyse(d) or [])
    print("\n" + "=" * 62)
    print("CNP -> own-stall lead (initiator-local, no cross-node clock)")
    for arm, leads in STALL_LEADS.items():
        print(f"  {arm:10s} n={len(leads):4d}  median={median(leads):.3f}s  "
              f"mean={mean(leads):.3f}s  min={min(leads):.3f}s  max={max(leads):.3f}s")
    if not STALL_LEADS:
        print("  (no arm produced both a CNP signal and a >1s stall)")
    print("\nPer-episode CNP -> ACK-timeout lead, pooled per arm")
    for arm, leads in by_arm.items():
        if leads:
            print(f"  {arm:10s} n={len(leads):4d}  median={median(leads):.3f}s  "
                  f"mean={mean(leads):.3f}s  min={min(leads):.3f}s  max={max(leads):.3f}s")
        else:
            print(f"  {arm:10s} no paired CNP/ACK episodes")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "../data/testbed/cnp"))
