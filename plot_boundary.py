#!/usr/bin/env python3
"""Figures and tables for 'The Collapse Boundary' (ICNC 2026).

Every number is recomputed from the raw per-op logs and counter snapshots under
data/testbed/ -- nothing is transcribed from a findings doc. Outputs go to
paper-boundary/figs/*.pdf and paper-boundary/tables/*.tex, and every figure
prints the values it drew so the prose can be checked against them.

    python3 plot_boundary.py [fig1 fig2 ... | all]
"""
import csv
import glob
import os
import re
import sys
from collections import defaultdict
from statistics import mean, pstdev

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

D = "data/testbed"
# The ICNC submission is a separate, shorter tree (paper-icnc/) built from the
# same raw logs as the full paper (paper-boundary/). Point the generator at it
# with PAPER_DIR rather than maintaining two copies of the numbers.
PAPER = os.environ.get("PAPER_DIR", "paper-boundary")
FIGS = f"{PAPER}/figs"
TABS = f"{PAPER}/tables"
os.makedirs(FIGS, exist_ok=True)
os.makedirs(TABS, exist_ok=True)

plt.rcParams.update({
    "font.size": 8, "axes.titlesize": 8, "axes.labelsize": 8,
    "legend.fontsize": 7, "xtick.labelsize": 7, "ytick.labelsize": 7,
    "figure.dpi": 150, "pdf.fonttype": 42, "ps.fonttype": 42,
    "axes.spines.top": False, "axes.spines.right": False,
    "axes.grid": True, "grid.alpha": 0.25, "grid.linewidth": 0.4,
    "lines.linewidth": 1.3,
})
COL1, COL2 = (3.4, 2.2), (7.0, 2.0)
SAFE, COLL, ACC = "#0072B2", "#D55E00", "#009E73"

# Arm-1 sweep levels: aggregate flush transfers -> flush MB (S=2MiB)
LEVELS = [8, 10, 12, 14, 16, 20, 24, 32]
RETX = ("local_ack_timeout_err", "packet_seq_err", "out_of_sequence")


# ---------------------------------------------------------------- helpers
def ops(pattern, cls=None):
    """All ops under run dirs matching pattern; list of (t_ms, latency_us, client, file)."""
    out = []
    for f in glob.glob(os.path.join(D, pattern, "init*.csv")):
        for r in csv.DictReader(open(f)):
            if cls and r["class"] != cls:
                continue
            out.append((float(r["t_ms"]), float(r["latency_us"]), int(r["client"]), f))
    return out


def lat(pattern, cls=None):
    return sorted(x[1] for x in ops(pattern, cls))


def pct(v, p):
    if not v:
        return 0.0
    i = p / 100 * (len(v) - 1)
    lo = int(i)
    return v[-1] if lo + 1 >= len(v) else v[lo] * (1 - (i - lo)) + v[lo + 1] * (i - lo)


def counters(pattern, subset=RETX):
    """Mean per-rep summed delta over `subset`, across all endpoints."""
    per_rep = []
    for d in sorted(glob.glob(os.path.join(D, pattern))):
        tot = 0
        for bf in glob.glob(os.path.join(d, "*.before")):
            af = bf[: -len(".before")] + ".after"
            if not os.path.exists(af):
                continue
            b = dict(t.split("=") for t in open(bf).read().split() if "=" in t)
            a = dict(t.split("=") for t in open(af).read().split() if "=" in t)
            for k in subset:
                if k in a and k in b:
                    tot += max(0, int(a[k]) - int(b[k]))
        per_rep.append(tot)
    return mean(per_rep) if per_rep else 0.0, per_rep


def goodput(pattern, common_window=True):
    """Per-rep aggregate MB/s, and the mean.

    Each initiator reports throughput over ITS OWN wall clock, and supercritical
    runs overrun their nominal duration by different amounts per initiator (up
    to 4.5 s apart in this data). Summing those rates computes
    sum_i bytes_i/wall_i, which is not the aggregate rate of the experiment:
    that is sum_i bytes_i divided by ONE window. The two agree only when every
    initiator ran for the same time, which is exactly the subcritical case -- so
    the naive sum is correct where nothing happens and overstates goodput by up
    to 26% where it matters.

    We therefore reconstruct bytes_i = rate_i * wall_i and divide by the longest
    initiator window in that repetition. That is still not a true common-window
    measurement -- there is no globally synchronised start, and an initiator
    that finished early contributed nothing to the tail of the window -- so it
    is an UPPER bound on the rate over the union interval -- the union is at
    least as long as the longest individual run -- and the paper labels it a
    drain-inclusive completion rate. Fixing this properly requires globally
    timestamped byte counters, which these runs do not have.

    common_window=False restores the old behaviour for comparison only.
    """
    per_rep_bytes = defaultdict(float)
    per_rep_wall = defaultdict(float)
    per_rep_naive = defaultdict(float)
    for f in glob.glob(os.path.join(D, pattern, "init*.sum")):
        rep = os.path.dirname(f)
        txt = open(f).read()
        mr = re.search(r"throughput_MBps=([\d.]+)", txt)
        mw = re.search(r"wall_s=([\d.]+)", txt)
        if not (mr and mw):
            continue
        rate, wall = float(mr.group(1)), float(mw.group(1))
        per_rep_naive[rep] += rate
        per_rep_bytes[rep] += rate * wall
        per_rep_wall[rep] = max(per_rep_wall[rep], wall)
    if not common_window:
        vals = list(per_rep_naive.values())
        return (mean(vals) if vals else 0.0), vals
    vals = [per_rep_bytes[r] / per_rep_wall[r] for r in per_rep_bytes if per_rep_wall[r] > 0]
    return (mean(vals) if vals else 0.0), vals


def flush_goodput(pattern, S_MiB=2.0):
    """Flush-only MB/s per rep. Theorem C models the FLUSH class, but the .sum
    throughput figure includes the bypass appends, so quoting it against a
    flush-only model mixes two populations. flush_ops * S / wall gives the like-for-like quantity."""
    per_rep = defaultdict(float)
    per_rep_wall = {}
    for f in glob.glob(os.path.join(D, pattern, "init*.sum")):
        ops_n = wall = None
        for ln in open(f):
            if "flush_ops=" in ln:
                ops_n = float(ln.split("flush_ops=")[1].split()[0])
            if "wall_s=" in ln:
                wall = float(ln.split("wall_s=")[1].split()[0])
        if ops_n and wall:
            key = os.path.dirname(f)
            per_rep[key] += ops_n * S_MiB * 1.048576          # bytes (MB)
            per_rep_wall[key] = max(per_rep_wall.get(key, 0.0), wall)
    vals = [per_rep[r] / per_rep_wall[r] for r in per_rep if per_rep_wall.get(r, 0) > 0]
    return (mean(vals) if vals else 0.0), vals


def jain(pattern):
    """Jain fairness index over per-initiator throughput, averaged across reps.

    Added 2026-09-09. An earlier draft asserted that the goodput-maximal and the
    fairest operating points coincide; they do not.
    An asserted fairness claim is exactly the kind this project has had to
    retract, so it is computed here from the raw per-initiator rates like every
    other number in the paper.

    CAVEAT, carried into the text: each initiator reports MB/s over its OWN
    wall clock, and supercritical runs overrun their nominal window by
    different amounts per initiator. So this is fairness of *rate over each
    initiator's active window*, not of bytes over a common window; it is the
    honest reading of what the logs contain, not a bytes-per-fixed-interval
    index.
    """
    # Fairness must be over BYTES delivered in a shared interval, not over each
    # initiator's own rate: an initiator that ran 4 s longer is not "fairer" for
    # having sustained a similar rate over a longer window. We therefore index
    # Jain on reconstructed bytes (rate * wall) within a repetition.
    per_rep = defaultdict(list)
    for f in glob.glob(os.path.join(D, pattern, "init*.sum")):
        txt = open(f).read()
        mr = re.search(r"throughput_MBps=([\d.]+)", txt)
        mw = re.search(r"wall_s=([\d.]+)", txt)
        if mr and mw:
            per_rep[os.path.dirname(f)].append(float(mr.group(1)) * float(mw.group(1)))
    out = []
    for vals in per_rep.values():
        if len(vals) < 2:
            continue
        n, tot, sq = len(vals), sum(vals), sum(x * x for x in vals)
        if sq > 0:
            out.append(tot * tot / (n * sq))
    return (mean(out) if out else float("nan")), len(out)


def stall_pct(pattern, cls="flush", thresh=1e6):
    v = lat(pattern, cls)
    return (100 * sum(1 for x in v if x > thresh) / len(v)) if v else 0.0, len(v)


# ---------------------------------------------------------------- figures
def fairness_table():
    """Goodput vs fairness across the sweep -- are they maximized together?"""
    print("\nfairness: per-initiator throughput Jain index by level")
    print(f"  {'Phi(MiB)':>9} {'goodput':>9} {'Jain':>7} {'reps':>5}")
    rows = []
    for m in LEVELS:
        pat = f"collapse-boundary/A_agg{m}_r*"
        gm, gv = goodput(pat)
        if not gv:
            continue
        j, nr = jain(pat)
        rows.append((m * 2, gm, j))
        print(f"  {m*2:>9} {gm:>9.0f} {j:>7.3f} {nr:>5}")
    print("\n  flush-only goodput (Theorem C's like-for-like quantity)")
    fr = []
    for m in LEVELS:
        fg, fv = flush_goodput(f"collapse-boundary/A_agg{m}_r*")
        if fv:
            fr.append((m * 2, fg))
            print(f"  {m*2:>9} {fg:>9.0f} MB/s flush-only")
    if fr:
        pk = max(fr, key=lambda r: r[1]); lo = min(fr, key=lambda r: r[1])
        print(f"  flush-only ratio peak/deepest = {pk[1]/lo[1]:.2f}x "
              f"(Phi={pk[0]} -> {lo[0]} MiB)")

    if rows:
        bg = max(rows, key=lambda r: r[1])
        bf = max(rows, key=lambda r: r[2])
        print(f"  max goodput at Phi={bg[0]} MiB (G={bg[1]:.0f}, Jain={bg[2]:.3f})")
        print(f"  max fairness at Phi={bf[0]} MiB (G={bf[1]:.0f}, Jain={bf[2]:.3f})")
        print(f"  SAME POINT: {bg[0] == bf[0]}"
              + ("" if bg[0] == bf[0] else
                 f"  -> fairness costs {100*(bg[1]-bf[1])/bg[1]:.2f}% goodput"))


def fig1():
    """Phase diagram: completion rate, stall rate, latency vs admitted flush bytes."""
    phi, g, gdots, sp, p99, p999, mx = [], [], [], [], [], [], []
    for m in LEVELS:
        pat = f"collapse-boundary/A_agg{m}_r*"
        v = lat(pat, "flush")
        if not v:
            continue
        phi.append(m * 2)                       # flush MiB (S = 2 MiB); BINARY units throughout
        gm, gv = goodput(pat)
        g.append(gm); gdots.append(gv)
        sp.append(stall_pct(pat)[0])
        p99.append(pct(v, 99) / 1000)
        p999.append(pct(v, 99.9) / 1000)
        mx.append(v[-1] / 1000)

    fig, ax = plt.subplots(1, 3, figsize=COL2)
    for a in ax:
        # Shade the MEASURED clean region: Phi=16 and 20 both record zero on
        # every counter (and the boundary map measures 4-12 clean too), so it
        # ends at 20, not 16. Ending at 16 put the clean Phi=20 point -- the
        # rate peak -- outside the region the caption calls clean.
        a.axvspan(0, 20, color=SAFE, alpha=0.10)
        a.axvline(20, color="gray", ls=":", lw=0.8)
        a.axvline(24, color="gray", ls=":", lw=0.8)

    ax[0].plot(phi, g, "o-", color=SAFE, ms=3.5)
    for x, ys in zip(phi, gdots):
        ax[0].plot([x] * len(ys), ys, ".", color="gray", ms=2.2, alpha=0.7, zorder=1)
    # Not common-window goodput: starts were not globally aligned, so this is
    # an upper bound on the rate over the union interval. Label it honestly.
    ax[0].set_ylabel("completion rate (MB/s)")
    ax[0].set_title("(a) rate peaks at the onset")

    # True zeros cannot be drawn on a log axis. Plot them at a detection floor
    # and MARK them, rather than silently substituting a positive value.
    FLOOR = 1e-3
    nz = [(x, v) for x, v in zip(phi, sp) if v > 0]
    zr = [(x, FLOOR) for x, v in zip(phi, sp) if v == 0]
    ax[1].plot([x for x, _ in nz], [v for _, v in nz], "s-", color=COLL, ms=3.5)
    if zr:
        ax[1].plot([x for x, _ in zr], [v for _, v in zr], "o", mfc="none",
                   mec=SAFE, ms=5, label="zero (floor)")
        ax[1].legend(fontsize=6, frameon=False, loc="lower right")
    ax[1].set_yscale("log"); ax[1].set_ylabel("flush ops > 1 s (%)")
    ax[1].set_title("(b) stall rate")

    ax[2].plot(phi, mx, "^-", color=COLL, ms=3.5, label="max")
    ax[2].plot(phi, p999, "v-", color="#E69F00", ms=3.5, label="p99.9")
    ax[2].plot(phi, p99, "o-", color=SAFE, ms=3.5, label="p99")
    ax[2].set_yscale("log"); ax[2].set_ylabel("flush latency (ms)")
    ax[2].set_title("(c) bimodal entry"); ax[2].legend(frameon=False, loc="lower right")

    for a in ax:
        a.set_xlabel("admitted flush bytes $\\Phi$ (MiB)")
    fig.tight_layout(); fig.savefig(f"{FIGS}/fig1_phase.pdf"); plt.close(fig)
    print("fig1 phase diagram")
    print(f"  {'Phi':>5} {'G':>7} {'stall%':>7} {'p99':>7} {'p99.9':>8} {'max':>8}")
    for i, x in enumerate(phi):
        print(f"  {x:>5} {g[i]:7.0f} {sp[i]:7.3f} {p99[i]:7.1f} {p999[i]:8.1f} {mx[i]:8.1f}")


def fig2():
    """Stall-duration structure, reported at the RECOVERY-EPISODE level.

    An earlier form of this analysis counted stalled OPERATION records, but
    go-back-N stalls a whole connection, so many operations complete together
    after one shared recovery: 1768 records reduce to 136 groups merging per
    initiator, or 37 merging across initiators within a run.

    These are OVERLAP GROUPS, not transport recovery episodes, and must not be
    reported as a count of independent recoveries. Each interval is
    reconstructed as [completion - latency, completion], and cas_gate measures
    latency from when a client became READY to issue, so it includes waiting at
    the admission gate (see cas_gate.c, "Latency per op"). Two operations can
    therefore overlap because they queued behind the same gate, with no shared
    recovery at all. The grouping bounds application-visible stall concurrency;
    identifying transport episodes needs submission timestamps, i.e. NVMe
    tracepoints.

    The band decomposition is also threshold-dependent and is reported as such
    rather than as a measurement: the gap rule below is a stated parameter, and
    its sensitivity is printed so a reader can see how little the band count
    survives changing it.
    """
    GAP = 0.5           # seconds; a stated clustering parameter, not a finding
    st = [x / 1e6 for x in lat("collapse-boundary/A_agg*_r*") if x > 1e6]
    fig, ax = plt.subplots(figsize=COL1)
    ax.hist(st, bins=80, color=COLL, alpha=0.85)
    ax.set_xlabel("stall duration (s)"); ax.set_ylabel("count")

    # episode counts: merge overlapping [completion - latency, completion]
    def _merge(iv):
        if not iv:
            return 0
        iv.sort(); n = 1; end = iv[0][1]
        for a, b in iv[1:]:
            if a > end:
                n += 1; end = b
            else:
                end = max(end, b)
        return n

    per_init = per_run = 0
    for d in sorted(glob.glob(os.path.join(D, "collapse-boundary/A_agg*_r*"))):
        run_iv = []
        for f in glob.glob(os.path.join(d, "init*.csv")):
            iv = []
            for r in csv.DictReader(open(f)):
                if r.get("class") != "flush":
                    continue
                try:
                    t = float(r["t_ms"]); ms = float(r["latency_us"]) / 1000.0
                except (ValueError, TypeError, KeyError):
                    continue
                if ms > 1000:
                    iv.append((t - ms, t))
            per_init += _merge(iv); run_iv += iv
        per_run += _merge(run_iv)

    ax.set_title(f"stall durations ($n$={per_run} episodes)")
    fig.tight_layout(); fig.savefig(f"{FIGS}/fig2_ladder.pdf"); plt.close(fig)
    st.sort()
    bands, cur = [], [st[0]]
    for a, b in zip(st, st[1:]):
        if b - a > GAP:
            bands.append((cur[0], cur[-1], len(cur))); cur = []
        cur.append(b)
    bands.append((cur[0], cur[-1], len(cur)))
    print(f"fig2: {len(st)} stalled operation records -> {per_init} episodes "
          f"merged per initiator, {per_run} merged per run (flush class)")
    print(f"  bands at GAP={GAP}s (lo, hi, records):")
    for lo, hi, n in bands:
        print(f"    [{lo:6.3f}, {hi:6.3f}] s  n={n}")
    # Sensitivity: the band count is a function of the threshold, so publish it.
    sens = []
    for g in (0.25, 0.5, 0.75, 1.0):
        c = 1
        for a, b in zip(st, st[1:]):
            if b - a > g:
                c += 1
        sens.append((g, c))
    print("  band-count sensitivity: " +
          ", ".join(f"gap={g}s->{c}" for g, c in sens))


def fig3():
    """Hysteresis: commanded ramp vs realized recovery (debt, not bistability)."""
    fig, ax = plt.subplots(figsize=COL1)
    rep = "collapse-boundary/B_hyst_r2"
    for f in sorted(glob.glob(os.path.join(D, rep, "init*.klog"))):
        rows = list(csv.DictReader(open(f)))
        ax.step([float(r["t_ms"]) / 1000 for r in rows], [int(r["k"]) for r in rows],
                where="post", lw=0.9, alpha=0.75,
                label=os.path.basename(f).split(".")[0])
    spans = [(t / 1000 - l / 1e6, t / 1000) for t, l, _, _ in ops(rep, "flush") if l > 1e6]
    for i, (s, e) in enumerate(spans[:60]):
        ax.plot([s, e], [0.5, 0.5], "-", color=COLL, lw=1.6, alpha=0.35,
                label="stall span" if i == 0 else None)
    ax.axvline(12, color="gray", ls=":", lw=0.8)
    ax.axvline(24, color="gray", ls=":", lw=0.8)
    ax.set_xlabel("time (s)"); ax.set_ylabel("admission bound $k$")
    ax.set_title("ramp $8\\!\\to\\!20\\!\\to\\!8$: recovery debt")
    ax.legend(frameon=False, fontsize=6, ncol=2)
    fig.tight_layout(); fig.savefig(f"{FIGS}/fig3_hysteresis.pdf"); plt.close(fig)
    for r in (1, 2, 3):
        pat = f"collapse-boundary/B_hyst_r{r}"
        back = []
        for f in glob.glob(os.path.join(D, pat, "init*.klog")):
            rows = list(csv.DictReader(open(f)))
            t = next((float(x["t_ms"]) for x in rows
                      if float(x["t_ms"]) > 15000 and int(x["k"]) <= 2), None)
            if t:
                back.append(t)
        t1 = max(back) / 1000 if back else None
        allst = [(t / 1000 - l / 1e6, t / 1000) for t, l, _, _ in ops(pat, "flush") if l > 1e6]
        after = [s for s, _ in allst if t1 and s > t1]
        last = max((e for _, e in allst), default=0)
        print(f"fig3 r{r}: all-initiators-subcritical t1={t1:.1f}s; "
              f"stalls STARTING after t1: {len(after)}; last completion {last:.1f}s "
              f"(+{last - t1:.1f}s past t1)")


def fig4():
    """Victim concentration: share of stalls on the worst initiator, vs level."""
    xs, ys = [], []
    for m in LEVELS:
        pat = f"collapse-boundary/A_agg{m}_r*"
        shares = []
        for d in sorted(glob.glob(os.path.join(D, pat))):
            per = defaultdict(int); tot = 0
            for f in glob.glob(os.path.join(d, "init*.csv")):
                init = re.search(r"init(\d+)", f).group(1)
                for r in csv.DictReader(open(f)):
                    if r["class"] == "flush" and float(r["latency_us"]) > 1e6:
                        per[init] += 1; tot += 1
            if tot:
                shares.append(max(per.values()) / tot)
        if shares:
            xs.append(m * 2); ys.append(mean(shares))
    fig, ax = plt.subplots(figsize=COL1)
    ax.plot(xs, ys, "o-", color=COLL, ms=4)
    ax.axhline(0.25, color=SAFE, ls="--", lw=0.9, label="uniform (1/N)")
    ax.set_ylim(0, 1); ax.set_xlabel("admitted flush bytes $\\Phi$ (MiB)")
    ax.set_ylabel("worst-initiator share of stalls")
    ax.set_title("victim concentration peaks at the boundary")
    ax.legend(frameon=False)
    fig.tight_layout(); fig.savefig(f"{FIGS}/fig4_victim.pdf"); plt.close(fig)
    print("fig4 victim share:", {x: round(y, 3) for x, y in zip(xs, ys)})


def fig5():
    """Boundary map over (transfer size, admitted flush bytes)."""
    cells = {}   # (S_MiB, Phi_MB) -> (retx_per_rep, stall_pct)
    for m in LEVELS:
        pat = f"collapse-boundary/A_agg{m}_r*"
        if lat(pat, "flush"):
            cells[(2.0, m * 2)] = (counters(pat)[0], stall_pct(pat)[0])
    for tag, phi in (("C2_k3s1M_12MB", 12), ("C2_k5s1M_20MB", 20),
                     ("C2_k6s1M_24MB", 24), ("C2_k7s1M_28MB", 28)):
        pat = f"spotchecks/{tag}_r*"
        if lat(pat, "flush"):
            cells[(1.0, phi)] = (counters(pat)[0], stall_pct(pat)[0])
    for k, phi in ((8, 16), (10, 20), (12, 24)):
        pat = f"probe512k/k{k}_r*"
        if lat(pat, "flush"):
            cells[(0.5, phi)] = (counters(pat, RETX)[0], stall_pct(pat)[0])

    # The 2026-09 hardware campaign added S = 4..8 MiB. Directory names encode
    # N and the policy, and Phi = N*k*S exactly, so the whole campaign folds
    # into the same map -- which is what makes the boundary's verticality
    # visible across a 16x range of transfer size rather than a 4x one.
    for d, S in (("p1-s2", 2.0), ("p1-s4", 4.0), ("p1-s8", 8.0),
                 ("wstar-s5", 5.0), ("wstar-s6", 6.0), ("wstar-s7", 7.0)):
        for run in glob.glob(os.path.join(D, d, "N*_cas-k*_r*")):
            m = re.match(r"N(\d+)_cas-k(\d+)_r", os.path.basename(run))
            if not m:
                continue
            N, k = int(m.group(1)), int(m.group(2))
            pat = f"{d}/N{N}_cas-k{k}_r*"
            if (S, N * k * S) in cells or not lat(pat, "flush"):
                continue
            cells[(S, N * k * S)] = (counters(pat, RETX)[0], stall_pct(pat)[0])

    sizes = sorted({s for s, _ in cells}); phis = sorted({p for _, p in cells})
    fig, ax = plt.subplots(figsize=COL1)
    for (s, p), (c, sp) in cells.items():
        safe = (c == 0 and sp == 0)
        ax.scatter(p, s, s=95, marker="s",
                   color=(SAFE if safe else COLL),
                   alpha=(0.85 if safe else min(0.35 + sp, 1.0)),
                   edgecolors="k", linewidths=0.4)
    ax.axvspan(21, 24, color=ACC, alpha=0.18, lw=0)
    ax.text(24.5, max(sizes) + 0.18, "$W^*\\in(21,24]$", color=ACC, fontsize=6.5)
    ax.set_ylim(min(sizes) - 0.45, max(sizes) + 0.55)
    ax.set_yticks(sizes); ax.set_yticklabels([f"{s:g}" for s in sizes])
    ax.set_xticks(phis)
    ax.set_xlabel("admitted flush bytes $\\Phi$ (MiB)")
    ax.set_ylabel("transfer size $S$ (MiB)")
    ax.set_title("boundary map: blue = deterministic zero")
    fig.tight_layout(); fig.savefig(f"{FIGS}/fig5_map.pdf"); plt.close(fig)
    print("fig5 boundary map (S MiB, Phi MB) -> retx/rep, stall%:")
    for k in sorted(cells):
        c, sp = cells[k]
        print(f"  S={k[0]:>3} Phi={k[1]:>3}: retx/rep={c:7.1f} stall%={sp:6.3f} "
              f"{'SAFE' if (c == 0 and sp == 0) else 'collapse'}")


def fig6():
    """AIMD trajectory: the controller dwells supercritical."""
    fig, ax = plt.subplots(figsize=COL1)
    f = f"{D}/adaptive-demo/A_adaptive_r1/init1.klog"
    if not os.path.exists(f):
        print("fig6: no klog"); return
    rows = list(csv.DictReader(open(f)))
    t = [float(r["t_ms"]) / 1000 for r in rows]
    k = [int(r["k"]) for r in rows]
    ax.step(t, k, where="post", color=COLL, lw=1.0, label="AIMD $k(t)$")
    md = [(float(r["t_ms"]) / 1000, int(r["k"])) for r in rows if int(r["signal_delta"]) > 0]
    ax.plot([x for x, _ in md], [y for _, y in md], "v", color="k", ms=3,
            label=f"loss signal (n={len(md)})")
    ax.axhspan(0, 2, color=SAFE, alpha=0.15)
    ax.text(t[0] + 0.3, 1.1, "safe ($k\\leq2$)", color=SAFE, fontsize=6.5)
    ax.set_xlabel("time (s)"); ax.set_ylabel("admission bound $k$")
    ax.set_title("reactive AIMD cannot hold the boundary")
    ax.legend(frameon=False, loc="upper right")
    fig.tight_layout(); fig.savefig(f"{FIGS}/fig6_aimd.pdf"); plt.close(fig)
    print(f"fig6 AIMD: mean k={mean(k):.1f}, MD events={len(md)}, "
          f"span={t[-1] - t[0]:.1f}s, frac time k>2={sum(1 for x in k if x > 2) / len(k):.2f}")


def table1():
    """Per-level phase-diagram table (LaTeX)."""
    rows = []
    for m in LEVELS:
        pat = f"collapse-boundary/A_agg{m}_r*"
        v = lat(pat, "flush")
        if not v:
            continue
        gm, gv = goodput(pat)
        cm, cv = counters(pat)
        sp, n = stall_pct(pat)
        rows.append((m * 2, m, gm, pct(v, 50) / 1000, pct(v, 99) / 1000,
                     pct(v, 99.9) / 1000, v[-1] / 1000, sp, cm, n, len(gv)))
    with open(f"{TABS}/table1_phase.tex", "w") as f:
        f.write("% auto-generated by plot_boundary.py -- do not edit\n")
        f.write("\\begin{tabular}{rrrrrrrrr}\n\\toprule\n")
        f.write("$\\Phi$ (MiB) & xfers & $G$ (MB/s) & p50 & p99 & p99.9 & max & "
                "$>$1\\,s (\\%) & retx/rep \\\\\n\\midrule\n")
        for (phi, m, g, p50, p99, p999, mx, sp, cm, n, nr) in rows:
            mxs = f"{mx / 1000:.2f}\\,s" if mx > 1000 else f"{mx:.0f}\\,ms"
            f.write(f"{phi} & {m} & {g:.0f} & {p50:.1f} & {p99:.1f} & "
                    f"{p999:.1f} & {mxs} & {sp:.3f} & {cm:.0f} \\\\\n")
        f.write("\\bottomrule\n\\end{tabular}\n")
    print(f"table1: {len(rows)} levels -> {TABS}/table1_phase.tex")

    # Compact single-column variant for the page-limited ICNC build. Drops the
    # columns Fig.1 already shows (p50, p99.9, transfer count) and keeps the
    # ones it does not (goodput, p99, max, retx). Same rows, same source.
    with open(f"{TABS}/table1_compact.tex", "w") as f:
        f.write("% auto-generated by plot_boundary.py -- do not edit\n")
        f.write("\\begin{tabular}{rrrrr}\n\\toprule\n")
        f.write("$\\Phi$ (MiB) & $G$ (MB/s) & p99 & max & retx/rep \\\\\n\\midrule\n")
        for (phi, m, g, p50, p99, p999, mx, sp, cm, n, nr) in rows:
            mxs = f"{mx / 1000:.2f}\\,s" if mx > 1000 else f"{mx:.0f}\\,ms"
            f.write(f"{phi} & {g:.0f} & {p99:.1f}\\,ms & {mxs} & {cm:.0f} \\\\\n")
        f.write("\\bottomrule\n\\end{tabular}\n")
    print(f"table1 compact -> {TABS}/table1_compact.tex")


def table2():
    """Pre-registered predictions and outcomes."""
    out = []
    pat = "spotchecks/C1_n2k4s2M_r*"
    v = lat(pat, "flush")
    out.append(("C1 fan-in invariance", "2:1, $k$=4, $\\Phi$=16\\,MiB", "SAFE",
                counters(pat)[0], stall_pct(pat)[0], v[-1] / 1000, len(v), "CONFIRMED"))
    for tag, phi, pred in (("C2_k3s1M_12MB", 12, "SAFE"), ("C2_k5s1M_20MB", 20, "SAFE"),
                           ("C2_k6s1M_24MB", 24, "boundary"), ("C2_k7s1M_28MB", 28, "collapse")):
        p = f"spotchecks/{tag}_r*"
        v = lat(p, "flush")
        if not v:
            continue
        c = counters(p)[0]; sp = stall_pct(p)[0]
        got = "SAFE" if (c == 0 and sp == 0) else "collapse"
        # "boundary" predicts either outcome, so it cannot be refuted; SAFE and
        # collapse are hard predictions and are scored strictly.
        if pred == "boundary":
            verdict = "consistent"
        elif got == pred:
            verdict = "held"
        else:
            verdict = "REFUTED"
        out.append((f"C2 bytes-vs-count", f"4:1, $S$=1\\,MiB, $\\Phi$={phi}\\,MiB", pred,
                    c, sp, v[-1] / 1000, len(v), verdict))
    with open(f"{TABS}/table2_prereg.tex", "w") as f:
        f.write("% auto-generated by plot_boundary.py -- do not edit\n")
        f.write("\\begin{tabular}{llrrrrl}\n\\toprule\n")
        f.write("Prediction & Configuration & Predicted & retx/rep & $>$1\\,s (\\%) & "
                "max (ms) & Outcome \\\\\n\\midrule\n")
        for (name, cfg, pred, c, sp, mx, n, verdict) in out:
            f.write(f"{name} & {cfg} & {pred} & {c:.0f} & {sp:.3f} & {mx:.0f} & {verdict} \\\\\n")
        f.write("\\bottomrule\n\\end{tabular}\n")
    # The 2026-09 campaign registered two further predictions before running
    # them. They are appended from their own datasets rather than hand-written,
    # so the table stays generated end to end.
    extra = []
    for name, cfg, pred, pat, N, k, S in (
            ("C3 bytes-vs-count", "$N$=2, $k$=2, $S$=4\\,MiB, $\\Phi$=16\\,MiB",
             "SAFE", "p1-s4/N2_cas-k2_r*", 2, 2, 4),
            ("C3 bytes-vs-count", "$N$=3, $k$=2, $S$=4\\,MiB, $\\Phi$=24\\,MiB",
             "collapse", "p1-s4/N3_cas-k2_r*", 3, 2, 4),
            ("C4 per-initiator limit", "$N$=2, $k$=1, $S$=8\\,MiB, $\\Phi$=16\\,MiB",
             "SAFE", "p1-s8/N2_cas-k1_r*", 2, 1, 8),
            ("C4 per-initiator limit", "$N$=3, $k$=1, $S$=8\\,MiB, $\\Phi$=24\\,MiB",
             "collapse", "p1-s8/N3_cas-k1_r*", 3, 1, 8)):
        v = lat(pat, "flush")
        if not v:
            continue
        c = counters(pat, RETX)[0]
        sp = stall_pct(pat)[0]
        mx = v[-1] / 1000
        clean = (c == 0)
        verdict = "held" if (clean == (pred == "SAFE")) else "REFUTED"
        extra.append((name, cfg, pred, c, sp, mx, verdict))
    if extra:
        with open(f"{TABS}/table2_prereg.tex") as f:
            body = f.read()
        rows = "".join(
            f"{n} & {cfg} & {pr} & {c:.0f} & {sp:.3f} & {mx:.0f} & {v} \\\\\n"
            for n, cfg, pr, c, sp, mx, v in extra)
        body = body.replace("\\bottomrule", "\\midrule\n" + rows + "\\bottomrule")
        with open(f"{TABS}/table2_prereg.tex", "w") as f:
            f.write(body)
        for e in extra:
            print(f"  {e[0]:<22} {e[1][:38]:<40} pred={e[2]:<9} retx={e[3]:6.1f} -> {e[6]}")

    # Compact single-column variant for the page-limited ICNC build: keeps what
    # makes pre-registration meaningful (what was predicted, what happened) and
    # drops the columns that merely restate the phase table.
    compact = [(n, cfg, pr, c, v) for n, cfg, pr, c, sp, mx, nn, v in out]
    compact += [(n, cfg, pr, c, v) for n, cfg, pr, c, sp, mx, v in extra]
    with open(f"{TABS}/table2_compact.tex", "w") as f:
        f.write("% auto-generated by plot_boundary.py -- do not edit\n")
        f.write("\\begin{tabular}{lllrl}\n\\toprule\n")
        f.write("\\# & Configuration & Pred. & retx & Outcome \\\\\n\\midrule\n")
        for (n, cfg, pr, c, v) in compact:
            short = cfg.replace("\\,MiB", "")
            f.write(f"{n.split()[0]} & {short} & {pr} & {c:.0f} & {v} \\\\\n")
        f.write("\\bottomrule\n\\end{tabular}\n")
    print(f"table2 compact -> {TABS}/table2_compact.tex")

    print(f"table2: {len(out)} rows -> {TABS}/table2_prereg.tex")
    for r in out:
        print(f"  {r[0]:<22} {r[1]:<34} pred={r[2]:<9} retx={r[3]:6.1f} "
              f"stall%={r[4]:6.3f} -> {r[7]}")


def fig7():
    """Makespan and its variance against admitted flush bytes.

    The point of this figure is the contrast between the two panels: the mean is
    flat across the boundary and the spread is not. A reader who looks only at
    throughput sees no reason to stay subcritical.
    """
    import numpy as np
    CURVES = [
        ("$S$=4 MiB, $N$=3", "makespan-curve",    3, 4),
        ("$S$=8 MiB, $N$=2", "makespan-curve-s8", 2, 8),
    ]
    fig, ax = plt.subplots(1, 2, figsize=COL2[0:1] + (COL2[1],) if False else (7.0, 2.6))
    for label, d, N, S in CURVES:
        pts = []
        for arm in ("cas-k1", "cas-k2", "cas-k3", "cas-k4", "baseline"):
            k = 8 if arm == "baseline" else int(arm[-1])
            vals = []
            for f in glob.glob(os.path.join(D, d, f"{arm}_r*", "makespan_s")):
                vals.append(float(open(f).read().strip()))
            if vals:
                pts.append((N * k * S, mean(vals),
                            (max(vals) - min(vals)) / 2, pstdev(vals) / mean(vals) * 100))
        if not pts:
            continue
        pts.sort()
        phi = [p[0] for p in pts]
        ax[0].errorbar(phi, [p[1] for p in pts], yerr=[p[2] for p in pts],
                       marker="o", capsize=3, label=label)
        ax[1].plot(phi, [p[3] for p in pts], marker="o", label=label)
    for a, yl, ti in ((ax[0], "batch makespan (s)", "(a) mean is flat across the boundary"),
                      (ax[1], "$\\sigma$/mean (%)", "(b) variance is not")):
        a.axvspan(0, 16, color=SAFE, alpha=0.10)
        a.set_xscale("log", base=2); a.set_xlabel("admitted flush bytes $\\Phi$ (MiB)")
        a.set_ylabel(yl); a.set_title(ti, fontsize=9); a.legend(fontsize=7)
    fig.tight_layout(); fig.savefig(f"{FIGS}/fig7_makespan.pdf")
    print(f"fig7 -> {FIGS}/fig7_makespan.pdf")
    for label, d, N, S in CURVES:
        print(f"  {label}: " + ", ".join(
            f"Phi={N*(8 if a=='baseline' else int(a[-1]))*S}" for a in
            ("cas-k1","cas-k2","cas-k3","cas-k4","baseline")))



def table3_makespan():
    """Batch makespan: work identical by construction, shared start barrier.

    Reads the 12-repetition barrier campaign (ms-barrier) rather than the
    earlier 8-repetition run. Two reasons: makespan is measured from a shared
    epoch rather than per-process wall clocks, and 12 reps support bootstrap
    intervals. Report the interval -- the ratio's uncertainty is dominated
    entirely by the ungated arm, whose cv is ~200x the gated arm's, so any
    single-campaign point estimate of it is worth about +/-0.25.

    The earlier makespan run carried an uncapped append class, so the ungated
    arm moved 39% more bytes than the gated one and every effect had to be
    confound-adjusted. This run is flush-only. The work-equality check below is
    an ASSERTION, not a report: if the arms did not move identical work the
    comparison is meaningless and the build must stop rather than print a
    number that looks fine.
    """
    N, S = 3, 4
    SRC = os.environ.get("MS_SRC", "ms-barrier")
    ARMS = (("baseline", 8), ("cas-k4", 4), ("cas-k2", 2), ("cas-k1", 1))
    rows, work, raw = [], set(), {}
    for arm, k in ARMS:
        ms, rx = [], []
        for d in sorted(glob.glob(os.path.join(D, SRC, f"{arm}_r*"))):
            f = os.path.join(d, "makespan_barrier_s")
            if not os.path.exists(f):
                f = os.path.join(d, "makespan_s")
            if not os.path.exists(f):
                continue
            ms.append(float(open(f).read().strip()))
            for sm in glob.glob(os.path.join(d, "init*.sum")):
                m = re.search(r"flush_ops=(\d+) append_ops=(\d+)", open(sm).read())
                if m:
                    work.add((int(m.group(1)), int(m.group(2))))
            rx.append(counters(os.path.join(SRC, os.path.basename(d)))[0])
        if not ms:
            raise RuntimeError(f"no makespan data for arm {arm}")
        mu = mean(ms)
        raw[arm] = ms
        from statistics import stdev as _sd
        sd = _sd(ms) if len(ms) > 1 else 0.0          # sample, not population
        rows.append((arm, N * k * S, len(ms), mu, sd, 100 * sd / mu, mean(rx)))
    if len(work) != 1:
        raise RuntimeError(f"WORK NOT EQUAL across arms: {sorted(work)} -- "
                           "the makespan comparison is invalid, refusing to emit")
    flush_ops, append_ops = work.pop()
    if append_ops != 0:
        raise RuntimeError(f"expected L=0 (flush-only), got append_ops={append_ops}")
    # ARM-ORDER CONFOUND CHECK.
    #
    # The published campaign ran baseline then each k in that order in every
    # repetition, so arm and run position were perfectly collinear and the
    # ratio below identifies nothing. That must be visible in the analysis
    # output, not only in the prose, or it will be published as causal again.
    order_f = os.path.join(D, SRC, "arm_order.txt")
    if os.path.exists(order_f):
        pos = {}
        for i, line in enumerate(open(order_f)):
            parts = line.split()
            if len(parts) == 2:
                pos[(parts[0], int(parts[1]))] = i
        print(f"  RANDOMISED arm order ({len(pos)} runs) from {order_f}")
        pooled_x, pooled_y = [], []
        for arm, _k in ARMS:
            xs, ys = [], []
            for d in sorted(glob.glob(os.path.join(D, SRC, f"{arm}_r*"))):
                m = re.search(r"_r(\d+)$", os.path.basename(d))
                fp = os.path.join(d, "makespan_barrier_s")
                if not os.path.exists(fp):
                    fp = os.path.join(d, "makespan_s")
                if m and os.path.exists(fp) and (arm, int(m.group(1))) in pos:
                    xs.append(pos[(arm, int(m.group(1)))])
                    ys.append(float(open(fp).read().strip()))
            if len(xs) > 2:
                mx, my = mean(xs), mean(ys)
                cov = sum((a - mx) * (b - my) for a, b in zip(xs, ys))
                vx = sum((a - mx) ** 2 for a in xs) ** 0.5
                vy = sum((b - my) ** 2 for b in ys) ** 0.5
                r = cov / (vx * vy) if vx and vy else float("nan")
                print(f"    {arm:<10} run-position vs makespan  r={r:+.3f}  (n={len(xs)})")
                # Centre within arm so the pooled statistic tests position
                # AFTER accounting for arm -- which is the actual question.
                pooled_x += [a - mx for a in xs]
                pooled_y += [b - my for b in ys]
        if len(pooled_x) > 4:
            mx, my = mean(pooled_x), mean(pooled_y)
            cov = sum((a - mx) * (b - my) for a, b in zip(pooled_x, pooled_y))
            vx = sum((a - mx) ** 2 for a in pooled_x) ** 0.5
            vy = sum((b - my) ** 2 for b in pooled_y) ** 0.5
            rp = cov / (vx * vy) if vx and vy else float("nan")
            # Calibrated by simulation under no drift (4 arms x 12 runs): the
            # 95th percentile of |r| is 0.296, so 0.30 is a 5% false-alarm
            # rule. Per-arm r is far noisier -- its max exceeds 0.30 on 81% of
            # clean campaigns -- so it is a diagnostic, not the test.
            verdict = "OK" if abs(rp) < 0.30 else "STOP: position predicts outcome"
            print(f"    POOLED within-arm r={rp:+.3f} (n={len(pooled_x)}) "
                  f"[|r|<0.30 => identified]  {verdict}")
    else:
        print("  !! FIXED ARM ORDER (no arm_order.txt in "
              f"{os.path.join(D, SRC)}):")
        print("     arm is collinear with run position, so the ratio below is")
        print("     DESCRIPTIVE ONLY and must not be reported as a policy effect.")

    base = [r for r in rows if r[0] == "baseline"][0][3]

    # Bootstrap CI on the speedup ratio. Deterministic seed so the emitted
    # table is reproducible; the paper quotes the interval, not the point.
    import random as _rnd
    def _ci(num, den, iters=20000):
        r = _rnd.Random(20260915)
        vals = []
        for _ in range(iters):
            a = [r.choice(num) for _ in num]; b = [r.choice(den) for _ in den]
            vals.append(mean(a) / mean(b))
        vals.sort()
        return vals[int(0.025 * iters)], vals[int(0.975 * iters)]
    name = {"baseline": "ungated", "cas-k1": "$k{=}1$",
            "cas-k2": "$k{=}2$", "cas-k4": "$k{=}4$"}
    with open(f"{TABS}/table3_makespan.tex", "w") as fh:
        fh.write("\\begin{tabular}{lrrrrrr}\n\\toprule\n")
        fh.write("policy & $\\Phi$ & $n$ & makespan & sd & cv & CI \\\\\n")
        fh.write(" & (MiB) & & (s) & (s) & (\\%) & \\\\\n\\midrule\n")
        for arm, phi, n, mu, sd, cv, rx in rows:
            if arm == "baseline":
                sp = ""
            else:
                lo, hi = _ci(raw["baseline"], raw[arm])
                sp = f" ({base/mu:.2f}$\\times$)"
            ci = "--" if arm == "baseline" else f"{lo:.2f}--{hi:.2f}"
            fh.write(f"{name[arm]} & {phi} & {n} & {mu:.2f}{sp} & {sd:.2f} & "
                     f"{cv:.2f} & {ci} \\\\\n")
        fh.write("\\bottomrule\n\\end{tabular}\n")
    print(f"table3 -> {TABS}/table3_makespan.tex")
    print(f"  work identical across all arms: flush_ops={flush_ops} append_ops={append_ops}")
    for arm, phi, n, mu, sd, cv, rx in rows:
        extra = ""
        if arm != "baseline":
            lo, hi = _ci(raw["baseline"], raw[arm])
            extra = f" speedup={base/mu:.3f}x CI[{lo:.2f},{hi:.2f}]"
        print(f"  {arm:9s} Phi={phi:3d} n={n} {mu:6.2f}s sd={sd:5.2f} cv={cv:5.2f}% "
              f"retx={rx:5.1f}{extra}")


def table4_repl():
    """Within-size near-boundary points, replicated on a fresh allocation.

    One objection to the byte-invariance map is that a threshold
    classifier separating the observations is not the same as a common physical
    boundary. These are within-size points run five days later on hardware we
    did not hold continuously, which is the only independent replication in the
    project.
    """
    CFG = (("ws-s4", 4, 3, "cas-k1", 1), ("ws-s4", 4, 3, "cas-k2", 2),
           ("ws-s8", 8, 2, "cas-k1", 1), ("ws-s8", 8, 2, "cas-k2", 2))
    # First-campaign values are transcribed from docs/byte-invariance-result.md,
    # whose own numbers this script emitted; they are summarised as range and n
    # to fit one column. Full per-rep values are in that file.
    PRIOR = {(4, 3, 1): "$0$ ($n{=}3$)", (4, 3, 2): "$186$--$231$ ($n{=}3$)",
             (8, 2, 1): "$0$ ($n{=}6$)", (8, 2, 2): "$30$--$229$ ($n{=}6$)"}
    rows = []
    for d, S, N, arm, k in CFG:
        rx, mx = [], []
        for run in sorted(glob.glob(os.path.join(D, d, f"N{N}_{arm}_r*"))):
            rel = os.path.join(d, os.path.basename(run))
            rx.append(int(counters(rel)[0]))
            l = lat(rel, cls="flush")
            if l:
                mx.append(max(l))
        if not rx:
            raise RuntimeError(f"no data for {d} N{N} {arm}")
        rows.append((S, N, k, N * k * S, PRIOR[(S, N, k)],
                     (f"$0$ ($n{{=}}{len(rx)}$)" if set(rx) == {0}
                      else f"${min(rx)}$--${max(rx)}$ ($n{{=}}{len(rx)}$)"),
                     max(mx) / 1e6 if mx else float("nan")))
    with open(f"{TABS}/table4_repl.tex", "w") as fh:
        fh.write("\\begin{tabular}{crll r}\n\\toprule\n")
        fh.write("$S$/$N$/$k$ & $\\Phi$ & retx, 09-10 & retx, 09-15 & max \\\\\n")
        fh.write(" & (MiB) & (first) & (replication) & (s) \\\\\n\\midrule\n")
        for S, N, k, phi, prior, now, mx in rows:
            fh.write(f"{S}/{N}/{k} & {phi} & {prior} & {now} & {mx:.2f} \\\\\n")
        fh.write("\\bottomrule\n\\end{tabular}\n")
    print(f"table4 -> {TABS}/table4_repl.tex")
    for S, N, k, phi, prior, now, mx in rows:
        print(f"  S={S} N={N} k={k} Phi={phi:2d}  prior=[{prior}]  now=[{now}]  max={mx:.2f}s")



# ---------------------------------------------------------------- 2026-09-15
# The campaign that refuted byte-invariance. These generators read the raw
# counter snapshots directly; none of the numbers are transcribed.

def _retx_classes(rundir):
    """-> (ack_timeouts, sequence_errors) summed over every endpoint."""
    ack = seq = 0
    for a in glob.glob(os.path.join(D, rundir, "*.after")):
        if ".blk." in a:
            continue
        b = a[: -len(".after")] + ".before"
        if not os.path.exists(b):
            continue
        va = dict(t.split("=") for t in open(a).read().split() if "=" in t)
        vb = dict(t.split("=") for t in open(b).read().split() if "=" in t)
        for k, bucket in (("local_ack_timeout_err", "ack"),
                          ("packet_seq_err", "seq"), ("out_of_sequence", "seq")):
            if va.get(k, "ABSENT") == "ABSENT" or vb.get(k, "ABSENT") == "ABSENT":
                continue
            d = int(va[k]) - int(vb[k])
            if bucket == "ack":
                ack += d
            else:
                seq += d
    return ack, seq


def _maxlat(rundir):
    """FLUSH-class maximum only. Append operations are excluded, and they can
    exceed 1 s where the flush class does not -- so this must never be quoted
    as "the worst operation" without saying flush."""
    v = lat(rundir, "flush")
    return v[-1] / 1e6 if v else float("nan")


def table5_fanin():
    """The safe envelope is not one aggregate: it moves with fan-in.

    One randomised campaign sweeping Phi at N=2 and N=3 with k=1 throughout and
    S=Phi/N, so the per-initiator policy is identical at both fan-ins. The
    paper's byte-invariance table never varied N at fixed Phi -- every equal-Phi
    pair in it holds fan-in constant -- so this axis was untested.
    """
    PHIS = [18, 21, 24, 27, 30, 33, 36]
    rows = []
    for phi in PHIS:
        cells = {}
        for N in (2, 3):
            runs = sorted(glob.glob(os.path.join(D, "fanin", f"phi{phi}_N{N}_r*")))
            if not runs:
                continue
            acks, seqs, mx = [], [], []
            for r in runs:
                rel = os.path.join("fanin", os.path.basename(r))
                a, q = _retx_classes(rel)
                acks.append(a); seqs.append(q); mx.append(_maxlat(rel))
            cells[N] = (mean(acks), mean(seqs), max(mx), len(runs))
        if cells:
            rows.append((phi, cells))
    if not rows:
        raise RuntimeError("no fanin data")
    with open(f"{TABS}/table5_fanin.tex", "w") as f:
        f.write("% auto-generated by plot_boundary.py -- do not edit\n")
        f.write("\\begin{tabular}{r rrr rrr}\n\\toprule\n")
        f.write("& \\multicolumn{3}{c}{$N{=}2$} & \\multicolumn{3}{c}{$N{=}3$} \\\\\n")
        f.write("\\cmidrule(lr){2-4}\\cmidrule(lr){5-7}\n")
        f.write("$\\Phi$ & ack & seq & max & ack & seq & max \\\\\n")
        f.write("(MiB) & t/o & err & (s) & t/o & err & (s) \\\\\n\\midrule\n")
        for phi, cells in rows:
            out = [f"{phi}"]
            for N in (2, 3):
                if N in cells:
                    a, q, mx, _ = cells[N]
                    out += [f"{a:.1f}", f"{q:.0f}", f"{mx:.2f}"]
                else:
                    out += ["--", "--", "--"]
            f.write(" & ".join(out) + " \\\\\n")
        f.write("\\bottomrule\n\\end{tabular}\n")
    print(f"table5 -> {TABS}/table5_fanin.tex")
    for phi, cells in rows:
        d = "  ".join(f"N={N}: ack={cells[N][0]:.1f} seq={cells[N][1]:.0f} max={cells[N][2]:.2f}s"
                      for N in sorted(cells))
        print(f"  Phi={phi:2d}  {d}")
    # the finer localisation runs
    for lbl, d_, N in (("N=2", "fine-n2", 2), ("N=3", "fine-n3", 3)):
        for run in sorted(set(os.path.basename(x).rsplit("_r", 1)[0]
                              for x in glob.glob(os.path.join(D, d_, "S*_r*")))):
            S = float(run[1:])
            reps = sorted(glob.glob(os.path.join(D, d_, f"{run}_r*")))
            qs = [_retx_classes(os.path.join(d_, os.path.basename(r)))[1] for r in reps]
            print(f"  fine {lbl} S={S} Phi={N*S:.1f} seq/rep={qs}")


def table6_concurrency():
    """At fixed bytes, fixed command count and fixed fan-in, concurrency decides.

    max_hw_sectors_kb is 1024 on every initiator, so a write of S MiB becomes
    ceil(S) commands of 1 MiB. For INTEGER-MiB S the outstanding command count
    therefore equals Phi in MiB; at non-integer S the ceiling makes them differ
    (S=3.5 at N=3,k=2 carries 24 commands for 21 MiB), which is why the matched
    comparisons use integer sizes. Those arms hold the command count fixed as
    well as the byte count, leaving the application-write grouping as the only
    difference.
    """
    import math as _m
    GROUPS = [("isolate", 24, 2), ("isolate-n3", 21, 3)]
    out_rows = []
    for d_, phi, N in GROUPS:
        keys = sorted(set(os.path.basename(x).rsplit("_r", 1)[0]
                          for x in glob.glob(os.path.join(D, d_, f"phi{phi}_*_r*"))))
        for key in keys:
            reps = sorted(glob.glob(os.path.join(D, d_, f"{key}_r*")))
            if not reps:
                continue
            cfg = open(os.path.join(reps[0], "config")).read()
            k = int(re.search(r"k=(\d+)", cfg.split("W=")[1]).group(1))
            S = int(re.search(r"S_bytes=(\d+)", cfg).group(1)) / 1048576
            acks, seqs, mx = [], [], []
            for r in reps:
                rel = os.path.join(d_, os.path.basename(r))
                a, q = _retx_classes(rel)
                acks.append(a); seqs.append(q); mx.append(_maxlat(rel))
            out_rows.append((N, phi, S, k, N * k, N * k * max(1, _m.ceil(S)),
                             mean(acks), mean(seqs), max(mx), len(reps)))
    if not out_rows:
        raise RuntimeError("no isolation data")
    out_rows.sort(key=lambda r: (r[0], -r[2]))
    with open(f"{TABS}/table6_concurrency.tex", "w") as f:
        f.write("% auto-generated by plot_boundary.py -- do not edit\n")
        f.write("\\begin{tabular}{rrrrrrr}\n\\toprule\n")
        f.write("$N$ & $\\Phi$ & $S$ & app & 1\\,MiB & seq & max \\\\\n")
        f.write(" & (MiB) & (MiB) & writes & cmds & err & (s) \\\\\n\\midrule\n")
        last = None
        for N, phi, S, k, appw, cmds, a, q, mx, n in out_rows:
            if last is not None and N != last:
                f.write("\\midrule\n")
            last = N
            f.write(f"{N} & {phi} & {S:.1f} & {appw} & {cmds} & {q:.0f} & {mx:.2f} \\\\\n")
        f.write("\\bottomrule\n\\end{tabular}\n")
    print(f"table6 -> {TABS}/table6_concurrency.tex")
    for N, phi, S, k, appw, cmds, a, q, mx, n in out_rows:
        print(f"  N={N} Phi={phi} S={S:5.1f} k={k:2d} appwr={appw:2d} cmds={cmds:2d} "
              f"ack={a:5.1f} seq={q:6.1f} max={mx:5.2f}s (n={n})")


def table7_controller():
    """No sensor rescues reactive control (18 reps)."""
    ARMS = [("static-k1", "static $k{=}1$"), ("aimd-cnp", "AIMD on CNP"),
            ("aimd-all", "AIMD on all"), ("aimd-timeout", "AIMD on timeout"),
            ("baseline", "ungated")]
    rows = []
    for arm, label in ARMS:
        reps = sorted(glob.glob(os.path.join(D, "controller-hi", f"{arm}_r*")))
        if not reps:
            continue
        p99, mx, acks, stall = [], [], [], []
        for r in reps:
            rel = os.path.join("controller-hi", os.path.basename(r))
            v = lat(rel, "flush")
            if not v:
                continue
            p99.append(pct(v, 99) / 1000)
            mx.append(v[-1] / 1e6)
            acks.append(_retx_classes(rel)[0])
            stall.append(100 * sum(1 for x in v if x > 1e6) / len(v))
        rows.append((label, len(p99), mean(p99), mean(mx), mean(acks), mean(stall)))
    if not rows:
        raise RuntimeError("no controller-hi data")
    with open(f"{TABS}/table7_controller.tex", "w") as f:
        f.write("% auto-generated by plot_boundary.py -- do not edit\n")
        f.write("\\begin{tabular}{lrrrrr}\n\\toprule\n")
        f.write("policy & $n$ & p99 & max & ack & stall \\\\\n")
        f.write(" & & (ms) & (s) & t/o & (\\%) \\\\\n\\midrule\n")
        for label, n, a, b, c, d_ in rows:
            f.write(f"{label} & {n} & {a:.1f} & {b:.2f} & {c:.1f} & {d_:.3f} \\\\\n")
        f.write("\\bottomrule\n\\end{tabular}\n")
    print(f"table7 -> {TABS}/table7_controller.tex")
    for label, n, a, b, c, d_ in rows:
        print(f"  {label:18s} n={n:2d} p99={a:8.1f}ms max={b:6.2f}s ack={c:5.1f} stall={d_:.3f}%")



def fig8_grouping():
    """The F2 claim in one picture: identical budget, different grouping.

    Three configurations that are indistinguishable in admitted flush bytes
    (24 MiB) and in outstanding 1 MiB commands (24), differing only in how that
    budget is grouped into application writes and spread over initiators. The
    sequence-error counts are read from the raw logs, not drawn by hand.
    """
    import matplotlib.patches as mp
    CFG = [  # label, N, writes per initiator, MiB per write, source glob
        ("$N$=2, $k$=1\n$S$=12 MiB",  2, 1,  12, "fanin/phi24_N2_r*"),
        ("$N$=3, $k$=1\n$S$=8 MiB",   3, 1,   8, "fanin/phi24_N3_r*"),
        ("$N$=2, $k$=12\n$S$=1 MiB",  2, 12,  1, "isolate/phi24_S1024k_k12_r*"),
    ]
    rows = []
    for lbl, N, kk, S, pat in CFG:
        seqs = []
        for d in sorted(glob.glob(os.path.join(D, pat))):
            rel = os.path.join(*d.split(os.sep)[-2:])
            seqs.append(_retx_classes(rel)[1])
        if not seqs:
            raise RuntimeError(f"no data for {pat}")
        rows.append((lbl, N, kk, S, mean(seqs)))

    fig, ax = plt.subplots(figsize=(3.4, 1.62))
    ax.set_xlim(0, 10); ax.set_ylim(0, len(rows) * 1.05)
    ax.axis("off")
    for r, (lbl, N, kk, S, seq) in enumerate(rows):
        y = (len(rows) - 1 - r) * 1.05 + 0.12
        ax.text(-0.15, y + 0.30, lbl, fontsize=6.0, ha="left", va="center")
        x = 2.5
        for i in range(N):                      # one bracket per initiator
            w = kk * S * 0.155
            ax.add_patch(mp.Rectangle((x, y), w, 0.60, fill=False,
                                      ec="0.45", lw=0.7))
            for j in range(kk):                 # one block per application write
                bw = S * 0.155
                ax.add_patch(mp.Rectangle((x + j * bw + 0.02, y + 0.06),
                                          bw - 0.04, 0.48,
                                          fc=(COLL if seq > 0 else SAFE),
                                          alpha=0.55, ec="white", lw=0.4))
            x += w + 0.18
        verdict = f"{seq:.0f} seq err" if seq > 0 else "clean"
        ax.text(9.9, y + 0.30, verdict, fontsize=6.0, ha="right", va="center",
                color=(COLL if seq > 0 else SAFE), fontweight="bold")
    ax.text(5.0, len(rows) * 1.05 - 0.10,
            "all three: 24 MiB admitted, 24 outstanding 1 MiB commands",
            fontsize=6.0, ha="center", va="center", style="italic", color="0.3")
    fig.tight_layout(pad=0.2)
    fig.savefig(f"{FIGS}/fig8_grouping.pdf"); plt.close(fig)
    print(f"fig8 -> {FIGS}/fig8_grouping.pdf")
    for lbl, N, kk, S, seq in rows:
        print(f"  N={N} k={kk:2d} S={S:2d} MiB -> {N*kk} writes, "
              f"{N*kk*S} commands, seq={seq:.0f}")


ALL = dict(fig1=fig1, fig7=fig7, fig2=fig2, fig3=fig3, fig4=fig4, fig5=fig5, fig6=fig6,
           table1=table1, table2=table2, table3=table3_makespan,
           table4=table4_repl, table5=table5_fanin,
           table6=table6_concurrency, table7=table7_controller,
           fig8=fig8_grouping,
           fairness=fairness_table)

if __name__ == "__main__":
    # FAIL CLOSED. This previously swallowed every exception and exited 0, so a
    # generator that broke would leave the PREVIOUS figure or table on disk and
    # LaTeX would happily publish it. Since the paper's claim is that every
    # number is regenerated from raw logs, a silent stale artifact is a
    # correctness bug, not an inconvenience. Keep going so one failure does not
    # mask others, but exit non-zero so a build script stops.
    want = sys.argv[1:] or ["all"]
    failed = []
    for name, fn in ALL.items():
        if "all" in want or name in want:
            try:
                fn()
            except Exception as e:
                print(f"!! {name} FAILED: {type(e).__name__}: {e}")
                failed.append(name)
            print()
    if failed:
        print(f"!! {len(failed)} generator(s) failed: {', '.join(failed)}")
        print("!! figures/tables on disk may be STALE -- do not build the paper")
        sys.exit(1)
