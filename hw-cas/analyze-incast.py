#!/usr/bin/env python3
"""Analyze the multi-initiator incast sweep: pool per-I/O flush/append latencies
across ALL initiators (and reps) for each fan-in degree x admission policy, and
show the fan-in knee (baseline tail growing with N) vs CAS.

    python3 analyze-incast.py <outdir>
"""
import csv, glob, os, re, sys
from statistics import median

def pool(outdir, N, tag, cls):
    v = []
    for f in glob.glob(os.path.join(outdir, f"N{N}_{tag}_r*", "init*.csv")):
        for r in csv.DictReader(open(f)):
            if r["class"] == cls:
                v.append(float(r["latency_us"]))
    return sorted(v)

def contributors(outdir, N, tag):
    """Which initiator indices actually produced a log, per rep.

    run-incast.sh scp's back whatever exists and reports fail=1 on the console,
    but nothing downstream knew: a run where one initiator died still produced a
    complete-looking "N:1" row computed from fewer than N senders. That is the
    same failure shape as the FIFO-starvation bug -- data silently absent,
    output still plausible -- so the count is now carried into the table.
    """
    per_rep = {}
    for f in glob.glob(os.path.join(outdir, f"N{N}_{tag}_r*", "init*.csv")):
        rep = os.path.basename(os.path.dirname(f))
        idx = re.search(r"init(\d+)", os.path.basename(f))
        if idx:
            per_rep.setdefault(rep, set()).add(int(idx.group(1)))
    return per_rep


def fanins_present(outdir):
    """Fan-in levels actually on disk. Was hardcoded to (1,2,3,4), which would
    have silently dropped the N=5/N=6 rows the S=4 MiB arm produces."""
    ns = set()
    for d in glob.glob(os.path.join(outdir, "N*_baseline_r*")):
        m = re.match(r"N(\d+)_", os.path.basename(d))
        if m:
            ns.add(int(m.group(1)))
    return sorted(ns)


def pct(v, p):
    if not v: return 0.0
    i = p/100*(len(v)-1); lo = int(i)
    return v[-1] if lo+1 >= len(v) else v[lo]*(1-(i-lo)) + v[lo+1]*(i-lo)

def agg_tput(outdir, N, tag):
    """sum of per-initiator throughput (aggregate offered), mean over reps."""
    per_rep = {}
    for f in glob.glob(os.path.join(outdir, f"N{N}_{tag}_r*", "init*.sum")):
        rep = re.search(r"_r(\d+)", f).group(1)
        for ln in open(f):
            if "throughput_MBps=" in ln:
                per_rep.setdefault(rep, 0.0)
                per_rep[rep] += float(ln.split("throughput_MBps=")[1].split()[0])
    return sum(per_rep.values())/len(per_rep) if per_rep else 0.0

def main():
    if len(sys.argv) != 2: sys.exit(__doc__)
    outdir = sys.argv[1]
    tags = ["baseline", "cas-k1", "cas-k2"]
    print("Flush-class pooled across all initiators (us). Fan-in knee = baseline tail vs N.\n")
    print(f"{'fan-in':>6} {'policy':>9} | {'flush p50':>9} {'p99':>9} {'p99.9':>9} {'max':>10} | "
          f"{'append p99.9':>12} {'aggMB/s':>8} {'inits':>7}")
    print("-"*98)
    suspect = []
    for N in fanins_present(outdir):
        for tag in tags:
            f = pool(outdir, N, tag, "flush")
            a = pool(outdir, N, tag, "append")
            if not f: continue
            per_rep = contributors(outdir, N, tag)
            got = min((len(v) for v in per_rep.values()), default=0)
            flag = "" if got == N else f"  <-- {got}/{N}"
            if got != N:
                suspect.append((N, tag, got))
            print(f"{N:>4}:1 {tag:>9} | {pct(f,50):8.0f}u {pct(f,99):8.0f}u {pct(f,99.9):8.0f}u "
                  f"{f[-1]:9.0f}u | {pct(a,99.9):11.0f}u {agg_tput(outdir,N,tag):8.0f} "
                  f"{got:>3}/{N}{flag}")
        print()
    if suspect:
        print("!! INCOMPLETE FAN-IN -- these rows are NOT the fan-in they are labelled:")
        for N, tag, got in suspect:
            print(f"     N={N} {tag}: only {got} initiator(s) logged")
        print("   Re-run them, or report each at the fan-in actually logged.\n")
    # headline: baseline vs CAS at max fan-in
    for N in reversed(fanins_present(outdir)):
        if N < 2:
            continue
        b = pool(outdir, N, "baseline", "flush")
        if b:
            c1 = pool(outdir, N, "cas-k1", "flush")
            print(f"At {N}:1 -- baseline flush p99={pct(b,99)/1000:.1f}ms max={b[-1]/1e6:.2f}s; "
                  f"CAS k=1 p99={pct(c1,99)/1000:.2f}ms max={c1[-1]/1000:.2f}ms")
            break

if __name__ == "__main__":
    main()
