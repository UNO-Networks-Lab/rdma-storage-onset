#!/usr/bin/env python3
"""Analyze E1 hardware CAS runs: pool raw per-I/O latencies across reps (never
average percentiles), compute per-class tails, and normalize to the idle
reference to report slowdown. Prints the baseline-vs-CAS-vs-naivecap table.

    python3 analyze-cas-hw.py <outdir>
"""
import csv
import glob
import os
import sys
from statistics import median


def pooled(outdir, mode, cls):
    """All latency samples (us) for a mode+class, pooled across reps."""
    vals = []
    for f in sorted(glob.glob(os.path.join(outdir, f"{mode}_r*.csv"))):
        for row in csv.DictReader(open(f)):
            if row["class"] == cls:
                vals.append(float(row["latency_us"]))
    return sorted(vals)


def pct(v, p):
    if not v:
        return 0.0
    idx = p / 100.0 * (len(v) - 1)
    lo = int(idx)
    if lo + 1 >= len(v):
        return v[-1]
    return v[lo] * (1 - (idx - lo)) + v[lo + 1] * (idx - lo)


def tput(outdir, mode):
    """Mean throughput (MB/s) across reps from the summary files."""
    ts = []
    for f in sorted(glob.glob(os.path.join(outdir, f"{mode}_r*.summary"))):
        for ln in open(f):
            if "throughput_MBps=" in ln:
                ts.append(float(ln.split("throughput_MBps=")[1].split()[0]))
    return sum(ts) / len(ts) if ts else 0.0


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    outdir = sys.argv[1]
    modes = ["baseline", "naivecap", "cas-k1", "cas-k2", "cas-k4"]

    # idle reference: unloaded per-class median = slowdown denominator
    ideal = {c: (median(pooled(outdir, "idle", c)) or 1.0) for c in ("flush", "append")}
    print(f"idle reference (us): batch p50={ideal['flush']:.1f}  small p50={ideal['append']:.1f}\n")

    hdr = f"{'mode':>10} | {'flush p99':>9} {'flush p99.9':>11} {'flush slow':>10} | " \
          f"{'append p99':>10} {'append slow':>11} | {'MB/s':>7}"
    print(hdr); print("-" * len(hdr))
    for m in modes:
        b = pooled(outdir, m, "flush")
        s = pooled(outdir, m, "append")
        if not b:
            print(f"{m:>10} |  (no data)")
            continue
        fb99, fb999 = pct(b, 99), pct(b, 99.9)
        fslow = fb99 / ideal["flush"]
        s99 = pct(s, 99)
        sslow = s99 / ideal["append"]
        print(f"{m:>10} | {fb99:8.1f}u {fb999:10.1f}u {fslow:9.1f}x | "
              f"{s99:9.1f}u {sslow:10.1f}x | {tput(outdir, m):7.0f}")

    print("\nRead: CAS should cut flush slowdown toward 1x while keeping append")
    print("slowdown and MB/s near baseline; naivecap should cut flush too but")
    print("inflate the append tail and/or drop throughput (it throttles both).")


if __name__ == "__main__":
    main()
