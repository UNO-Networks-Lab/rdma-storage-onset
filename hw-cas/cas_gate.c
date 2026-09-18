/*
 * cas_gate.c -- user-space initiator-side admission gate for NVMe-oF/RoCE.
 *
 * A faithful hardware prototype of CAS (Cohort-aware Admission Serialization):
 * CAS is "a submission-ordering policy in the initiator," so this program *is*
 * that policy, sitting in the I/O submission path over a real NVMe-oF block
 * device.
 *
 * CLOSED-LOOP workload (matches the ns-3 sim and real storage clients): a fixed
 * set of "clients", each with one outstanding I/O, re-issuing immediately on
 * completion. Outstanding work is bounded by the client count, so a slower
 * admission policy throttles the *offered rate* (backpressure) instead of
 * building an unbounded open-loop queue -- the correct model for storage.
 *
 *   FLUSH clients  -- W concurrent large writes (default 2 MiB). W models the
 *                     blk-mq queue-per-core fan-out that processor-shares a
 *                     batch across QPs (the pathology).
 *   APPEND clients -- L concurrent 64 KiB latency-class writes.
 *
 * Two modes select only the admission policy; everything else is identical:
 *
 *   baseline : every ready client issues at once (up to W+L in flight) --
 *              queue-per-core processor sharing.
 *   cas      : FLUSH issues are admitted FIFO with at most K in flight on the
 *              lane; APPEND issues bypass the gate entirely.
 *
 * Latency per op is measured from when its client became ready to issue (i.e.
 * the previous op's completion) to completion, so any wait at the CAS gate is
 * counted. Reports p50/p99/p99.9 per class + aggregate write throughput.
 *
 * Build:  make            (needs liburing-dev)
 * Run:    sudo ./cas_gate --dev /dev/nvme0n1 --mode cas --k 4 \
 *              --flush-clients 32 --append-clients 4 --duration 10 --log cas.csv
 *
 * O_DIRECT writes to random 4 KiB-aligned offsets in a bounded region -- a
 * destructive raw-device benchmark. Point it only at a scratch NVMe-oF
 * namespace (e.g. the null_blk-backed target here), never at data.
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <time.h>
#include <getopt.h>
#include <sys/ioctl.h>
#include <linux/fs.h>
#include <liburing.h>

enum cls { FLUSH = 0, APPEND = 1 };

struct io {
    int          in_use;
    enum cls     cls;
    int          client;      /* which client owns this in-flight op   */
    void        *buf;
    size_t       len;
    uint64_t     off;
    uint64_t     ready;       /* ns: when the client became ready to issue */
};

struct lat {                  /* growable per-class latency vector (us) */
    double  *v;
    size_t   n, cap;
};

static struct cfg {
    const char *dev, *mode, *log;
    size_t      batch_size, small_size;
    int         flush_clients;   /* W: concurrent large-write clients   */
    int         append_clients;  /* L: concurrent small-write clients   */
    double      duration_s;      /* measured run length                 */
    int         k;               /* CAS: max FLUSH in flight on lane     */
    int         qd;              /* io_uring depth (>= W+L)              */
    uint64_t    region_bytes;
    uint64_t    flush_ops;       /* FIXED-VOLUME mode: stop after this many
                                  * successful FLUSH ops instead of at a
                                  * deadline. 0 = time-based (unchanged).
                                  * This is what makes batch MAKESPAN
                                  * measurable rather than derived from
                                  * stationary goodput. */
} cfg = {
    .dev = NULL, .mode = "cas", .log = NULL,
    .batch_size = 2u << 20, .small_size = 64u << 10,
    .flush_clients = 32, .append_clients = 4, .duration_s = 10.0,
    .k = 4, .qd = 0, .region_bytes = 8ull << 30, .flush_ops = 0,
};

static struct io_uring ring;
static int   g_fd = -1;
static struct io *pool;
static int   inflight, flush_inflight, is_cas;

/* --mode adaptive: AIMD on the admission bound k, driven by the NIC's own
 * loss/recovery counters (go-back-N signature). Every interval: if any watched
 * counter advanced, k := max(1, k/2) and hold; after a quiet cooldown, k += 1
 * (up to W). The gate thus self-locates the collapse threshold with no
 * knowledge of fan-in N or switch buffer size. */
static struct {
    int      enabled;
    char     dir[300];        /* .../infiniband/<dev>/ports/1/hw_counters */
    uint64_t interval_ns;
    int      cur_k;
    int      cooldown;        /* intervals to hold after a decrease */
    uint64_t last_ns;
    uint64_t next_ns;         /* ABSOLUTE deadline for the next tick */
    uint64_t max_gap_ns;      /* worst observed interval between ticks */
    uint64_t gap_tol_ns;      /* fail the run if a gap exceeds this */
    uint64_t gap_violations;
    uint64_t ticks;
    unsigned long long prev_sum;
    const char *kfile;        /* if set: k is READ from this file each tick
                               * (target-informed mode) instead of AIMD */
    FILE    *klog;
} adapt;

/* Which counters the reactive controller may react to.
 *
 * This used to be a single fixed list summing all five, which made the
 * controller's own trigger unattributable and let the paper describe it as
 * "dominated by local_ack_timeout_err" when in fact rp_cnp_handled and the
 * sequence-error counters were in the sum too -- and those move at loss time,
 * roughly one ACK timeout earlier. Selecting the set turns the sensor into an
 * experimental variable, so a CNP-driven controller can be compared against a
 * timeout-driven one directly instead of argued about.
 *
 * ALL reproduces the historical behaviour exactly and remains the default. */
static const char *CTRS_ALL[] = {
    "local_ack_timeout_err", "packet_seq_err", "out_of_sequence",
    "rp_cnp_handled", "rnr_nak_retry_err", NULL,
};
static const char *CTRS_CNP[]     = { "rp_cnp_handled", NULL };
static const char *CTRS_TIMEOUT[] = { "local_ack_timeout_err", NULL };
static const char *CTRS_SEQ[]     = { "packet_seq_err", "out_of_sequence", NULL };
static const char **ADAPT_CTRS = CTRS_ALL;
static const char *adapt_signal_name = "all";

static unsigned long long adapt_read_sum(void) {
    unsigned long long sum = 0;
    char path[400];
    int found = 0;
    for (size_t i = 0; ADAPT_CTRS[i]; i++) {
        snprintf(path, sizeof(path), "%s/%s", adapt.dir, ADAPT_CTRS[i]);
        FILE *f = fopen(path, "r");
        if (!f) continue;
        unsigned long long v = 0;
        if (fscanf(f, "%llu", &v) == 1) { sum += v; found++; }
        fclose(f);
    }
    /* A controller whose sensor does not exist is not a conservative
     * controller -- it is a controller that never decreases, and it would be
     * reported as "the signal never fired". Fail loudly instead. */
    if (!found) {
        fprintf(stderr, "FATAL: none of the '%s' adapt counters readable under %s\n",
                adapt_signal_name, adapt.dir);
        exit(3);
    }
    return sum;
}

static void adapt_tick(uint64_t now, uint64_t t0, int W) {
    if (!adapt.enabled || now < adapt.next_ns) return;
    /* Record the REALISED cadence. The tick used to run only in the completion
     * loop, so during a stall -- when completions stop -- the controller also
     * stopped sampling, with p99 gaps of ~4 s against a nominal 50 ms. A
     * controller blind for longer than the signal it is meant to race cannot
     * test anything about sensor latency, so the gap is now measured and
     * reported rather than assumed. */
    if (adapt.ticks) {
        uint64_t gap = now - adapt.last_ns;
        if (gap > adapt.max_gap_ns) adapt.max_gap_ns = gap;
        /* Fail closed: a run whose controller went blind is not a controller
         * measurement, and must not be pooled with runs that stayed awake. */
        if (adapt.gap_tol_ns && gap > adapt.gap_tol_ns) adapt.gap_violations++;
    }
    adapt.ticks++;
    adapt.last_ns = now;
    /* Reschedule on an ABSOLUTE grid so a tick that ran late does not push the
     * whole cadence out; resynchronise only if we have fallen a full interval
     * behind, which is itself recorded as a gap violation above. */
    adapt.next_ns += adapt.interval_ns;
    if (adapt.next_ns <= now) adapt.next_ns = now + adapt.interval_ns;
    if (adapt.kfile) {                       /* target-informed: obey the file */
        FILE *f = fopen(adapt.kfile, "r");
        if (f) {
            int k = 0;
            if (fscanf(f, "%d", &k) == 1 && k >= 1) {
                if (k > W) k = W;
                adapt.cur_k = k;
            }
            fclose(f);
        }
        unsigned long long s2 = adapt_read_sum();      /* time-aligned counters */
        unsigned long long d2 = s2 >= adapt.prev_sum ? s2 - adapt.prev_sum : 0;
        adapt.prev_sum = s2;
        if (adapt.klog)
            fprintf(adapt.klog, "%.1f,%d,%llu\n", (now - t0) / 1e6, adapt.cur_k, d2);
        return;
    }
    unsigned long long s = adapt_read_sum();
    unsigned long long delta = s >= adapt.prev_sum ? s - adapt.prev_sum : 0;
    adapt.prev_sum = s;
    if (delta > 0) {
        adapt.cur_k = adapt.cur_k > 1 ? adapt.cur_k / 2 : 1;   /* MD */
        adapt.cooldown = 4;                                     /* hold */
    } else if (adapt.cooldown > 0) {
        adapt.cooldown--;
    } else if (adapt.cur_k < W) {
        adapt.cur_k++;                                          /* AI */
    }
    if (adapt.klog)
        fprintf(adapt.klog, "%.1f,%d,%llu\n", (now - t0) / 1e6, adapt.cur_k, delta);
}

static inline uint64_t now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ull + ts.tv_nsec;
}

static void lat_push(struct lat *l, double us) {
    if (l->n == l->cap) {
        l->cap = l->cap ? l->cap * 2 : 4096;
        l->v = realloc(l->v, l->cap * sizeof(*l->v));
        if (!l->v) { perror("realloc"); exit(1); }
    }
    l->v[l->n++] = us;
}

static int cmp_d(const void *a, const void *b) {
    double x = *(const double *)a, y = *(const double *)b;
    return (x > y) - (x < y);
}

static double pct(struct lat *l, double p) {          /* l must be sorted */
    if (l->n == 0) return 0.0;
    double idx = p / 100.0 * (l->n - 1);
    size_t lo = (size_t)idx;
    if (lo + 1 >= l->n) return l->v[l->n - 1];
    return l->v[lo] * (1 - (idx - lo)) + l->v[lo + 1] * (idx - lo);
}

static uint64_t rng_state = 0x9e3779b97f4a7c15ull;
static uint64_t xorshift(void) {
    uint64_t x = rng_state;
    x ^= x << 13; x ^= x >> 7; x ^= x << 17;
    return rng_state = x;
}
static uint64_t rand_off(size_t len, uint64_t region) {
    uint64_t span = region > len ? region - len : 4096;
    return (xorshift() % span) & ~((uint64_t)4095);
}

static int find_slot(void) {
    for (int i = 0; i < cfg.qd; i++) if (!pool[i].in_use) return i;
    return -1;
}

/* Issue one op for a client. Returns 0 on success, -1 if no uring slot free. */
static int issue(enum cls cls, int client, uint64_t ready_ns) {
    int si = find_slot();
    if (si < 0) return -1;
    struct io *io = &pool[si];
    io->in_use = 1; io->cls = cls; io->client = client;
    io->len = cls == FLUSH ? cfg.batch_size : cfg.small_size;
    io->off = rand_off(io->len, cfg.region_bytes);
    io->ready = ready_ns;
    struct io_uring_sqe *sqe = io_uring_get_sqe(&ring);
    if (!sqe) { io->in_use = 0; return -1; }
    io_uring_prep_write(sqe, g_fd, io->buf, io->len, io->off);
    io_uring_sqe_set_data(sqe, io);
    io_uring_submit(&ring);
    inflight++;
    if (cls == FLUSH) flush_inflight++;
    return 0;
}

int main(int argc, char **argv) {
    static struct option opts[] = {
        {"dev", required_argument, 0, 'd'}, {"mode", required_argument, 0, 'm'},
        {"log", required_argument, 0, 'l'}, {"batch-size", required_argument, 0, 'B'},
        {"small-size", required_argument, 0, 'S'},
        {"flush-clients", required_argument, 0, 'W'},
        {"append-clients", required_argument, 0, 'L'},
        {"duration", required_argument, 0, 'T'}, {"k", required_argument, 0, 'k'},
        {"qd", required_argument, 0, 'q'}, {"seed", required_argument, 0, 'e'},
        {"region", required_argument, 0, 'R'},
        {"rdma-dev", required_argument, 0, 'D'},
        {"adapt-interval-ms", required_argument, 0, 'I'},
        {"klog", required_argument, 0, 'K'},
        {"kfile", required_argument, 0, 'F'},
        {"flush-ops", required_argument, 0, 'N'},
        {"adapt-signal", required_argument, 0, 'G'},
        {"max-tick-gap-ms", required_argument, 0, 'M'},
        {0, 0, 0, 0}
    };
    const char *rdma_dev = NULL, *klog_path = NULL;
    double adapt_ms = 50.0;
    double max_gap_ms = 0.0;      /* 0 => 4x the tick interval */
    int rc = 0;                   /* nonzero => run is not usable as a measurement */
    int ch;
    while ((ch = getopt_long(argc, argv, "d:m:l:B:S:W:L:T:k:q:e:R:D:I:K:F:N:G:M:", opts, NULL)) != -1) {
        switch (ch) {
        case 'd': cfg.dev = optarg; break;             case 'm': cfg.mode = optarg; break;
        case 'l': cfg.log = optarg; break;
        case 'B': cfg.batch_size = strtoull(optarg,0,0); break;
        case 'S': cfg.small_size = strtoull(optarg,0,0); break;
        case 'W': cfg.flush_clients = atoi(optarg); break;
        case 'L': cfg.append_clients = atoi(optarg); break;
        case 'T': cfg.duration_s = atof(optarg); break; case 'k': cfg.k = atoi(optarg); break;
        case 'q': cfg.qd = atoi(optarg); break;         case 'e': rng_state = strtoull(optarg,0,0)|1; break;
        case 'R': cfg.region_bytes = strtoull(optarg,0,0); break;
        case 'D': rdma_dev = optarg; break;
        case 'I': adapt_ms = atof(optarg); break;
        case 'K': klog_path = optarg; break;
        case 'F': adapt.kfile = optarg; break;
        case 'M': max_gap_ms = atof(optarg); break;
        case 'N': cfg.flush_ops = strtoull(optarg,0,0); break;
        case 'G':
            adapt_signal_name = optarg;
            if      (!strcmp(optarg, "all"))     ADAPT_CTRS = CTRS_ALL;
            else if (!strcmp(optarg, "cnp"))     ADAPT_CTRS = CTRS_CNP;
            else if (!strcmp(optarg, "timeout")) ADAPT_CTRS = CTRS_TIMEOUT;
            else if (!strcmp(optarg, "seq"))     ADAPT_CTRS = CTRS_SEQ;
            else { fprintf(stderr, "--adapt-signal must be all|cnp|timeout|seq\n"); return 2; }
            break;
        default: fprintf(stderr, "bad arg\n"); return 2;
        }
    }
    if (!cfg.dev) { fprintf(stderr, "--dev required\n"); return 2; }
    is_cas = strcmp(cfg.mode, "cas") == 0;
    adapt.enabled = strcmp(cfg.mode, "adaptive") == 0;
    if (adapt.enabled) is_cas = 1;              /* gate active, cap dynamic */
    if (!is_cas && strcmp(cfg.mode, "baseline") != 0) {
        fprintf(stderr, "--mode must be baseline|cas|adaptive\n"); return 2;
    }
    if (adapt.enabled) {
        if (!rdma_dev) rdma_dev = getenv("RDMA_DEV");
        if (!rdma_dev && !adapt.kfile) { fprintf(stderr, "adaptive mode needs --rdma-dev (or RDMA_DEV env) or --kfile\n"); return 2; }
        if (!rdma_dev) rdma_dev = "none";
        if (rdma_dev[0] == '/')            /* absolute dir (testing) */
            snprintf(adapt.dir, sizeof(adapt.dir), "%s", rdma_dev);
        else
            snprintf(adapt.dir, sizeof(adapt.dir),
                     "/sys/class/infiniband/%s/ports/1/hw_counters", rdma_dev);
        adapt.interval_ns = (uint64_t)(adapt_ms * 1e6);
        adapt.gap_tol_ns = max_gap_ms > 0 ? (uint64_t)(max_gap_ms * 1e6)
                                          : adapt.interval_ns * 4;
        adapt.cur_k = cfg.k > 0 ? cfg.k : cfg.flush_clients;  /* start high by default via --k */
        adapt.prev_sum = adapt_read_sum();
        if (klog_path) {
            adapt.klog = fopen(klog_path, "w");
            if (adapt.klog) fprintf(adapt.klog, "t_ms,k,signal_delta\n");
        }
    }
    if (cfg.qd <= 0) cfg.qd = cfg.flush_clients + cfg.append_clients + 8;

    g_fd = open(cfg.dev, O_WRONLY | O_DIRECT);
    if (g_fd < 0) { perror("open dev"); return 1; }
    uint64_t devsz = 0;
    if (ioctl(g_fd, BLKGETSIZE64, &devsz) == 0 && devsz > 0 && devsz < cfg.region_bytes)
        cfg.region_bytes = devsz;

    if (io_uring_queue_init(cfg.qd, &ring, 0) < 0) { perror("uring init"); return 1; }
    pool = calloc(cfg.qd, sizeof(*pool));
    size_t maxlen = cfg.batch_size > cfg.small_size ? cfg.batch_size : cfg.small_size;
    for (int i = 0; i < cfg.qd; i++) {
        if (posix_memalign(&pool[i].buf, 4096, maxlen)) { perror("memalign"); return 1; }
        memset(pool[i].buf, 0xa5, maxlen);
    }

    /* client readiness: ready[c]!=0 means client c wants to issue now */
    int W = cfg.flush_clients, L = cfg.append_clients;
    uint64_t *fready = calloc(W, sizeof(*fready));   /* flush client ready-times */
    uint64_t *aready = calloc(L, sizeof(*aready));   /* append client ready-times */
    char *abusy = calloc(L, 1);
    /* FLUSH admission is a real FIFO: a ready client joins the tail; the gate
     * admits from the head while flush_inflight < cap. Every client waits its
     * turn (its latency counts the queue wait), so no low-index starvation. */
    int *fq = calloc(W + 1, sizeof(*fq));            /* ring of ready flush clients */
    int fq_head = 0, fq_tail = 0;
    long *fissued = calloc(W, sizeof(*fissued));     /* per-client issue count */
    if (!fready || !aready || !abusy || !fq || !fissued) { perror("calloc"); return 1; }

    struct lat lf = {0}, ls = {0};
    FILE *lg = cfg.log ? fopen(cfg.log, "w") : NULL;
    if (lg) fprintf(lg, "class,client,t_ms,offset,bytes,latency_us\n");

    uint64_t t0 = now_ns();
    for (int i = 0; i < W; i++) { fready[i] = t0; fq[fq_tail++] = i; }  /* all ready -> FIFO */
    for (int i = 0; i < L; i++) aready[i] = t0;
    uint64_t deadline = t0 + (uint64_t)(cfg.duration_s * 1e9);
    uint64_t bytes = 0;
    uint64_t flush_done = 0;    /* completed  */
    uint64_t flush_issued = 0;  /* submitted  */
    int stopping = 0;

    while (inflight > 0 || !stopping) {
        uint64_t now = now_ns();
        /* Fixed-volume mode ends on work ISSUED, not completed. Stopping on
         * completions lets everything already in flight finish on top of the
         * target, and that overshoot is bounded by concurrency -- so an ungated
         * arm overshoots by ~W while a k=1 arm overshoots by 0. The arms then
         * do UNEQUAL work, which is fatal for a makespan comparison and biased
         * in favour of the gated arm. Gating issuance makes every arm submit
         * exactly cfg.flush_ops transfers. */
        if (!stopping && (cfg.flush_ops ? flush_issued >= cfg.flush_ops
                                        : now >= deadline)) stopping = 1;
        adapt_tick(now, t0, W);

        if (!stopping) {
            /* APPEND clients bypass the gate; FLUSH clients pass it under CAS */
            for (int a = 0; a < L; a++)
                if (!abusy[a] && issue(APPEND, a, aready[a]) == 0) abusy[a] = 1;
            int cap = adapt.enabled ? adapt.cur_k : (is_cas ? cfg.k : W);
            while (flush_inflight < cap && fq_head != fq_tail
                   && (!cfg.flush_ops || flush_issued < cfg.flush_ops)) {
                int f = fq[fq_head];
                if (issue(FLUSH, f, fready[f]) != 0) break;   /* no uring slot; retry later */
                fq_head = (fq_head + 1) % (W + 1);
                fissued[f]++; flush_issued++;
            }
        }
        if (inflight == 0) { if (stopping) break; else continue; }

        struct io_uring_cqe *cqe;
        /* Wait with a timeout so the control loop keeps ticking while the
         * fabric is stalled and no completion arrives. Without this the tick
         * is completion-driven and goes blind exactly during recovery. */
        int ret;
        if (adapt.enabled) {
            /* Wait only for the time REMAINING until the next-tick deadline.
             * Waiting a full interval after every completion lets a completion
             * arriving just before the deadline defer the tick to nearly twice
             * the requested interval. */
            uint64_t w = now_ns();
            uint64_t rem = adapt.next_ns > w ? adapt.next_ns - w : 0;
            struct __kernel_timespec ts = {
                .tv_sec  = (long long)(rem / 1000000000ULL),
                .tv_nsec = (long long)(rem % 1000000000ULL),
            };
            ret = io_uring_wait_cqe_timeout(&ring, &cqe, &ts);
            if (ret == -ETIME) continue;      /* deadline reached; tick */
        } else {
            ret = io_uring_wait_cqe(&ring, &cqe);
        }
        if (ret < 0) { fprintf(stderr, "cqe: %s\n", strerror(-ret)); break; }
        struct io *io = io_uring_cqe_get_data(cqe);
        int res = cqe->res; io_uring_cqe_seen(&ring, cqe);
        uint64_t done = now_ns();
        if (res < 0) fprintf(stderr, "write off=%lu: %s\n", io->off, strerror(-res));
        else if ((size_t)res != io->len)
            fprintf(stderr, "short write off=%lu %d/%zu\n", io->off, res, io->len);
        else {
            double us = (done - io->ready) / 1e3;
            if (io->cls == FLUSH) { lat_push(&lf, us); flush_done++; } else lat_push(&ls, us);
            if (lg) fprintf(lg, "%s,%d,%.1f,%lu,%zu,%.3f\n",
                            io->cls == FLUSH ? "flush" : "append", io->client,
                            (done - t0) / 1e6, io->off, io->len, us);
            bytes += io->len;
        }
        /* client becomes ready again immediately (think time 0) */
        if (io->cls == FLUSH) {           /* re-join the FIFO tail (think time 0) */
            flush_inflight--; fready[io->client] = done;
            fq[fq_tail] = io->client; fq_tail = (fq_tail + 1) % (W + 1);
        } else { abusy[io->client] = 0; aready[io->client] = done; }
        io->in_use = 0; inflight--;
    }

    double wall = (now_ns() - t0) / 1e9;
    qsort(lf.v, lf.n, sizeof(double), cmp_d);
    qsort(ls.v, ls.n, sizeof(double), cmp_d);
    printf("mode=%s k=%d flush_clients=%d append_clients=%d dur=%.1f\n",
           cfg.mode, is_cas ? cfg.k : W, W, L, cfg.duration_s);
    printf("wall_s=%.2f throughput_MBps=%.1f flush_ops=%zu append_ops=%zu\n",
           wall, bytes / 1e6 / wall, lf.n, ls.n);
    printf("flush  n=%zu p50=%.1f p99=%.1f p99.9=%.1f max=%.1f (us)\n",
           lf.n, pct(&lf,50), pct(&lf,99), pct(&lf,99.9), lf.n ? lf.v[lf.n-1] : 0);
    printf("append n=%zu p50=%.1f p99=%.1f p99.9=%.1f max=%.1f (us)\n",
           ls.n, pct(&ls,50), pct(&ls,99), pct(&ls,99.9), ls.n ? ls.v[ls.n-1] : 0);
    /* starvation check: every flush client must have received service */
    long fmin = W ? fissued[0] : 0, fmax = 0;
    for (int i = 0; i < W; i++) { if (fissued[i] < fmin) fmin = fissued[i]; if (fissued[i] > fmax) fmax = fissued[i]; }
    printf("flush per-client ops: min=%ld max=%ld  (min>0 => no starvation)\n", fmin, fmax);
    if (adapt.enabled) {
        printf("adaptive: signal=%s final_k=%d ticks=%llu max_tick_gap_ms=%.1f "
               "gap_tol_ms=%.1f gap_violations=%llu\n",
               adapt_signal_name, adapt.cur_k,
               (unsigned long long)adapt.ticks, adapt.max_gap_ns / 1e6,
               adapt.gap_tol_ns / 1e6,
               (unsigned long long)adapt.gap_violations);
        if (adapt.klog) fclose(adapt.klog);
        if (adapt.gap_violations) {
            fprintf(stderr,
                    "FAIL: controller cadence violated %llu times "
                    "(max gap %.1f ms > tolerance %.1f ms); this run did not "
                    "sample often enough to be a controller measurement\n",
                    (unsigned long long)adapt.gap_violations,
                    adapt.max_gap_ns / 1e6, adapt.gap_tol_ns / 1e6);
            rc = 3;
        }
    }

    if (lg) fclose(lg);
    io_uring_queue_exit(&ring); close(g_fd);
    free(fready); free(aready); free(abusy); free(fq); free(fissued); free(pool);
    return rc;
}
