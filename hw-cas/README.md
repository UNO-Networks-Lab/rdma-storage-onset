# Hardware CAS prototype (E1)

A real, user-space implementation of CAS to answer the question the simulation
cannot: **does cohort-aware admission serialization fix the measured
NVMe-oF/RoCE incast pathology on actual hardware, and does it beat the obvious
cheap fixes?** This closes the loop -- the pathology is characterized on this
testbed (see `../README.md`), and here CAS is run on the *same* hardware.

## Why this is a faithful CAS

The paper frames CAS as "a submission-ordering policy in the initiator, the same
vantage that already picks an I/O queue per request." `cas_gate.c` *is* that
policy: an io_uring submission gate over a connected NVMe-oF block device.
Nothing about the fabric, target, protocol, or wire changes -- only the order
and concurrency in which the initiator submits I/O. That is exactly CAS's
deployment story (initiator-only, no switch/protocol/wire changes).

Two I/O classes share one (initiator, target) lane:

- **BATCH** -- large flush writes (2 MiB), issued in cohorts of 8 every 0.7 ms
  (the 24.1 Gb/s, rho~=0.96 burst regime the ns-3 waves model).
- **SMALL** -- 64 KiB latency-class appends at a steady rate.

Modes differ *only* in admission policy:

| mode      | policy                                                        | models |
|-----------|--------------------------------------------------------------|--------|
| `baseline`| submit everything up to the io_uring depth                   | blk-mq queue-per-core processor sharing (the pathology) |
| `naivecap`| `baseline` with a shallow queue (`--qd 8`)                   | the "just cap iodepth" fix -- throttles *both* classes |
| `cas` k=1 | BATCH admitted FIFO at 1 in flight; SMALL bypasses the gate  | CAS, flush-serialized |
| `cas` k=2 | BATCH admitted FIFO at 2 in flight; SMALL bypasses           | CAS, k=2 operating point |

The A/B of `baseline` vs `cas` on the same device isolates admission order; the
`naivecap` arm is the alt-fix bake-off (E3): a class-*un*aware cap cuts the flush
tail but leaves the append tail high, because it gates the latency class too.

## Build & run (on the initiator node)

```bash
sudo apt-get install -y liburing-dev
make
# DEV is the connected NVMe-oF namespace (destructive O_DIRECT writes -- scratch only)
sudo ./run-cas-hw.sh /dev/nvme1n1 ./out 5
python3 analyze-cas-hw.py ./out
```

`run-cas-hw.sh` sweeps idle/baseline/naivecap/cas-k1/cas-k2, N reps each, writing
per-I/O logs (`<mode>_r<N>.csv`) and summaries. `analyze-cas-hw.py` **pools raw
per-I/O samples across reps** (percentiles are never averaged) and normalizes to
the idle reference to report per-class slowdown plus throughput.

## What "success" looks like

CAS should drive the flush tail toward the single-QP floor (the `../README.md`
fan-out bound: 1.07x at one QP vs 21x at queue-per-core) **while** keeping the
append tail and aggregate throughput near baseline -- the combination the raw
QP-count knob cannot deliver. `naivecap` should cut the flush tail but inflate
the append tail and/or drop throughput, showing why class-awareness is needed.

## Local functional validation (pre-hardware)

Compiled against liburing and run on a local ext4 SSD (a smoke test, not the
fabric): the admission logic is correct and directionally right -- CAS cut the
flush-class tail vs baseline and beat `naivecap` on *both* classes at equal
throughput. The fabric numbers will be larger (incast + go-back-N), but the
apparatus is verified end to end before consuming testbed time.
