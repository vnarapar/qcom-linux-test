# Tiotest

Tiotest storage KPI runner for Yocto/LE images, aligned to qcom-linux-testkit performance suite conventions.

It runs the requested tiotest modes (sequential + random) for one or more thread counts, for N iterations:
- `seqwr`  Sequential Write
- `seqrd`  Sequential Read
- `rndwr`  Random Write
- `rndrd`  Random Read

Outputs:
- Per-run logs: `OUT_DIR/tiotest_<mode>_t<threads>_iter<it>.log`
- Metrics TSV: `OUT_DIR/tiotest_metrics.tsv`
- Summary: `OUT_DIR/tiotest_summary.txt`
- Result file: `./Tiotest.res` (OVERWRITTEN, not appended; LAVA-friendly)

> Note: The `tiotest -h` shown on RB3GEN2 (v0.3.3) does NOT include `--direct-io`.  
> Some internal forks may have extra flags; this runner follows your target help output and keeps everything non-hardcoded.

---

## Prerequisites

1. `tiotest` binary available on target (in PATH or pass `--tiotest-bin /path/to/tiotest`)
2. A writable directory on the storage you want to benchmark (filesystem mode), OR a block device (raw mode).
3. Recommended: keep system idle and (optionally) use performance governor for more stable KPIs.

Dependencies (checked by script):
- `awk sed grep date tee`
- `tiotest` (or the path you pass)

---

## Quick Start (filesystem mode)

Run on a disk-backed path (recommended, avoids tmpfs variance):

```sh
cd Runner/suites/Performance/Tiotest

./run.sh \
  --out-dir ./tiotest_out \
  --iterations 3 \
  --threads-list "1 4" \
  --tiotest-bin tiotest \
  --use-raw 0 \
  --tiotest-dir /var/tmp/tiotest_fileio \
  --mode-list "seqwr seqrd rndwr rndrd" \
  --seq-block 524288 \
  --seq-file-mb 1024 \
  --rnd-block 4096 \
  --rnd-file-mb 1 \
  --rnd-ops 12500 \
  --hide-latency 1 \
  --drop-caches 0 \
  --set-perf-gov 1 \
  --require-non-tmpfs 1
```

Result:
- `Tiotest.res` contains **one line**: `Tiotest PASS|FAIL|SKIP`
- Summary at `./tiotest_out/tiotest_summary.txt`

---

## Raw Device Mode (USE_RAW=1)

Raw mode uses tiotest `-R` and expects `--tiotest-dir` to be a **block device**:

```sh
./run.sh \
  --out-dir ./tiotest_out_raw \
  --iterations 2 \
  --threads-list "1" \
  --tiotest-bin tiotest \
  --use-raw 1 \
  --tiotest-dir /dev/sda \
  --offset-mb 0 \
  --offset-first 0 \
  --mode-list "seqwr seqrd rndwr rndrd"
```

Options:
- `--offset-mb N` corresponds to `-o N` (offset between threads) when using `-R`
- `--offset-first 1` corresponds to `-O` (apply offset to first thread as well)

> Caution: Raw mode can stress the device. Ensure you are using the correct target block device.

---

## Running Only a Subset of Modes

Example: sequential only

```sh
./run.sh --mode-list "seqwr seqrd"
```

Example: random only

```sh
./run.sh --mode-list "rndwr rndrd"
```

---

## Changing Block Size / File Size

Sequential 1MB block size (per thread 1GB):

```sh
./run.sh --seq-block 1048576 --seq-file-mb 1024
```

Random 4KB blocks, larger file per thread, more ops:

```sh
./run.sh --rnd-block 4096 --rnd-file-mb 64 --rnd-ops 12500
```

---

## Latency Output

Your tiotest supports:
- `-L` hide latency output

Runner control:
- `--hide-latency 1` => adds `-L`
- `--hide-latency 0` => do not add `-L` (latency may be printed if tiotest emits it)

The runner also supports an optional strict check:
- If latency is enabled (hide-latency != 1) and `perf_tiotest_latency_strict_check()` exists in `lib_performance.sh`,
  the run can FAIL if `% >2 sec` or `% >10 sec` becomes non-zero.

---

## Optional Baseline Gating

If you provide a baseline file, the runner can evaluate average KPIs vs baseline with allowed deviation.

- Baseline auto-detect: `./tiotest_baseline.conf` (same folder as `run.sh`)
- Or pass: `--baseline /path/to/tiotest_baseline.conf`
- Control deviation: `--delta 0.10` (10%)

Example:

```sh
./run.sh \
  --baseline ./tiotest_baseline.conf \
  --delta 0.10
```

If gating fails:
- `.res` will be `Tiotest FAIL`
- exit code `1` (LAVA will still collect logs, and your YAML uses `|| true` if desired)

---

## Output artifacts

All artifacts are written under `--out-dir`:

- `tiotest_summary.txt`: final human-readable summary (also printed to stdout)
- `tiotest_metrics.tsv`: per-iteration machine-readable metrics
- per-metric `.values` files (one value per iteration) used for averaging/gating
- `tiotest_seq_t<threads>_iter<N>.log` and `tiotest_rnd_t<threads>_iter<N>.log`: raw tiotest logs per iteration

### tiotest_metrics.tsv format

`tiotest_metrics.tsv` always has **8 tab-separated columns**:

```
mode   threads   mbps   iops   latavg_ms   latmax_ms   pct_gt2s   pct_gt10s
```

Example:

```
rndrd	4	3127.443	800625	0.003	0.133	0.00000	0.00000
```

## Baseline and gating

The runner can gate measured averages against a baseline file (default: `tiotest_baseline.conf`).

### Baseline file format

Key-value format compatible with `perf_baseline_get_value()`:

```
# tiotest.<threads>.<metric>.baseline=...
# tiotest.<threads>.<metric>.goal=...
# tiotest.<threads>.<metric>.op=>=|<=|>|<|==

tiotest.1.seqwr_mbps.baseline=180
tiotest.1.seqwr_mbps.goal=180
tiotest.1.seqwr_mbps.op=>=

tiotest.1.seqrd_mbps.baseline=800
tiotest.1.seqrd_mbps.goal=800
tiotest.1.seqrd_mbps.op=>=

tiotest.1.rndwr_mbps.baseline=45
tiotest.1.rndwr_mbps.goal=45
tiotest.1.rndwr_mbps.op=>=

tiotest.1.rndwr_iops.baseline=11000
tiotest.1.rndwr_iops.goal=11000
tiotest.1.rndwr_iops.op=>=

tiotest.1.rndrd_mbps.baseline=50
tiotest.1.rndrd_mbps.goal=50
tiotest.1.rndrd_mbps.op=>=

tiotest.1.rndrd_iops.baseline=12000
tiotest.1.rndrd_iops.goal=12000
tiotest.1.rndrd_iops.op=>=

tiotest.4.seqwr_mbps.baseline=500
tiotest.4.seqwr_mbps.goal=500
tiotest.4.seqwr_mbps.op=>=

tiotest.4.seqrd_mbps.baseline=1200
tiotest.4.seqrd_mbps.goal=1200
tiotest.4.seqrd_mbps.op=>=

tiotest.4.rndwr_mbps.baseline=80
tiotest.4.rndwr_mbps.goal=80
tiotest.4.rndwr_mbps.op=>=

tiotest.4.rndwr_iops.baseline=30000
tiotest.4.rndwr_iops.goal=30000
tiotest.4.rndwr_iops.op=>=

tiotest.4.rndrd_mbps.baseline=90
tiotest.4.rndrd_mbps.goal=90
tiotest.4.rndrd_mbps.op=>=

tiotest.4.rndrd_iops.baseline=32000
tiotest.4.rndrd_iops.goal=32000
tiotest.4.rndrd_iops.op=>=
```

### Goal and delta behavior

If `.goal` is missing, it can be derived from `.baseline` and `ALLOWED_DEVIATION` (delta) depending on the operator:

- `>=` / `>`: `goal = baseline * (1 - delta)`
- `<=` / `<`: `goal = baseline * (1 + delta)`
- `==`: `goal = baseline`

Gating output is logged and also appended to the summary. The summary prints `goal${op}${goal}` so you will see
strings like `goal=>=90` or `goal>90` exactly.

## LAVA Usage

Use the test definition YAML: `Tiotest.yaml`

Typical steps:
- `cd Runner/suites/Performance/Tiotest/`
- Run `./run.sh ...`
- Send `.res` with:
  `Runner/utils/send-to-lava.sh Tiotest.res`

---

## Tips for Stable KPI Numbers

- Use a disk-backed directory (e.g., `/var/tmp/...` or your storage mount), not tmpfs.
- Keep device idle; run 2–3 iterations and compare variance.
- Consider performance governor (`--set-perf-gov 1`) if supported on your platform.
