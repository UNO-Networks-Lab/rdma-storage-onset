#!/usr/bin/env python3
"""Analyze incast RDMA-counter telemetry: per-mode deltas of go-back-N / loss
indicators (target + initiators, summed then meaned over reps), to show CAS
suppresses the triggers behind the multi-second tail.

    python3 analyze-telemetry.py <outdir>
"""
import glob
import os
import re
import sys
from collections import defaultdict
from statistics import mean

# the counters that matter, in report order
KEYS = ["local_ack_timeout_err", "packet_seq_err", "out_of_sequence",
        "rnr_nak_retry_err", "out_of_buffer", "np_cnp_sent",
        "np_ecn_marked_roce_packets"]


def parse(path):
    d = {}
    if not os.path.exists(path):
        return d
    for tok in open(path).read().split():
        if "=" in tok:
            k, v = tok.split("=", 1)
            try:
                d[k] = int(v)
            except ValueError:
                pass
    return d


def run_delta(rundir):
    """Sum after-before across target + all initiators for one run."""
    tot = defaultdict(int)
    for before in glob.glob(os.path.join(rundir, "*.before")):
        after = before[:-len(".before")] + ".after"
        b, a = parse(before), parse(after)
        for k in KEYS:
            if k in a and k in b:
                tot[k] += max(0, a[k] - b[k])
    return tot


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    outdir = sys.argv[1]
    modes = ["baseline", "cas-k1", "cas-k2", "cas-k4"]
    print("RDMA counter deltas around a 4:1 incast run (target+initiators summed, "
          "mean over reps).\nHigh local_ack_timeout_err / packet_seq_err / "
          "out_of_sequence = go-back-N recovery.\n")
    hdr = f"{'counter':>28} | " + " ".join(f"{m:>10}" for m in modes)
    print(hdr); print("-" * len(hdr))
    agg = {m: defaultdict(list) for m in modes}
    for m in modes:
        for rundir in sorted(glob.glob(os.path.join(outdir, f"{m}_r*"))):
            d = run_delta(rundir)
            for k in KEYS:
                agg[m][k].append(d.get(k, 0))
    for k in KEYS:
        cells = []
        for m in modes:
            vals = agg[m][k]
            cells.append(f"{mean(vals):10.0f}" if vals else f"{'-':>10}")
        print(f"{k:>28} | " + " ".join(cells))
    # headline ratio on the primary trigger
    base = agg["baseline"]["local_ack_timeout_err"]
    cas = agg["cas-k1"]["local_ack_timeout_err"]
    if base and cas is not None:
        b, c = mean(base), mean(cas)
        print(f"\nlocal_ack_timeout_err: baseline {b:.0f} -> CAS k=1 {c:.0f}"
              + (f" ({b/c:.0f}x fewer)" if c else " (eliminated)"))


if __name__ == "__main__":
    main()
