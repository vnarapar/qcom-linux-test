Systemd Boot KPI: How to Use the Two Tests
==========================================

We provide two complementary tests for measuring systemd boot KPIs:

1. **Per-boot KPI collector**  
   `Boot_Systemd_Validate/run.sh`
2. **Reboot loop wrapper / KPI aggregator**  
   `Boot_Systemd_KPI_Loop/run.sh`

They are designed to work together but serve **different use-cases**.

Typical paths in qcom-linux-testkit:

```text
suites/Performance/Boot_Systemd_Validate/run.sh
suites/Performance/Boot_Systemd_KPI_Loop/run.sh
```

---

1. `Boot_Systemd_Validate` – Per-boot KPI collector
---------------------------------------------------

**Path (example):**

```text
suites/Performance/Boot_Systemd_Validate/run.sh
```

### Purpose

Runs **once per boot** and collects detailed systemd boot KPIs:

- `systemd-analyze time` (parsed into firmware/loader/kernel/userspace/total)
- `systemd-analyze blame` (full + top-20)
- `systemd-analyze critical-chain`
- `systemd-analyze plot` → `boot_analysis.svg` (optional)
- `systemd-analyze dot` → `boot.dot`
- `systemctl` unit dependency trees and per-unit state CSV
- Journals: full boot, warnings, errors (when `journalctl` is available)
- Optional **gating on required units** (e.g. “all critical services must be active”)
- **UEFI loader timings** from efivars (Init/Exec/Total) when EFI vars exist
- **Exclusion of slow services** from userspace/total (e.g. `systemd-networkd-wait-online.service`)

All logs are stored under a test-local directory:

```text
./logs_Boot_Systemd_Validate/
```

When `--iterations N` is passed, the script still runs **once**, but includes
this hint in the KPI output so that the KPI loop wrapper knows the intended
window size.

---

### Usage (CLI help)

The script has a built-in help that matches the implementation:

```text
Usage: ./run.sh [OPTIONS]

Options:
  --out DIR           Output directory for logs (default: ./logs_Boot_Systemd_Validate)
  --required FILE     File listing systemd units that must become active
  --timeout S         Timeout per required unit (seconds, default: $TIMEOUT_PER_UNIT)
  --no-svg            Skip systemd-analyze plot SVG generation
  --boot-type TYPE    Tag boot type (e.g. cold, warm, unknown)
  --disable-getty     Disable serial-getty@ttyS0.service for this KPI run
  --disable-sshd      Disable sshd.service for this KPI run

  --exclude-networkd-wait-online
                      Exclude systemd-networkd-wait-online.service time
                      from userspace/total based on systemd-analyze blame

  --exclude-services "svc1 svc2 ..."
                      Exclude one or more services (matching names in
                      systemd-analyze blame) from userspace/total.
                      The summed time is subtracted and reported as
                      an effective KPI.

  --iterations N      Hint for KPI iterations (wrapper/LAVA metadata; this
                      script still runs once per invocation)

  --verbose           Dump key .txt artifacts from OUT_DIR to console for
                      LAVA debugging (skips large journal_*.txt files)

  -h, --help          Show this help and exit
```

**Environment knobs (optional):**

- `TIMEOUT_PER_UNIT` – default per-unit wait time for `--required`
- `SVG=yes|no` – default for SVG generation (overridden by `--no-svg`)
- `BOOT_TYPE` – default boot type tag (overridden by `--boot-type`)
- `BOOT_KPI_ITERATIONS` – default for the `iterations` field in the KPI output

---

### Outputs / Artifacts

All written under `OUT_DIR` (default: `./logs_Boot_Systemd_Validate`):

- Platform + metadata  
  - `platform.txt`, `platform.json`  
  - `clocksource.txt` (current clocksource)  
  - `boot_type.txt` (e.g. `cold`, `warm`, `unknown`)

- Units & dependencies  
  - `sysinit_deps.txt`, `basic_deps.txt`  
  - `units.list`  
  - `unit_states.csv` (per-unit state/export from `systemctl show`)

- Systemd timing & graphs  
  - `analyze_time.txt` (raw `systemd-analyze time` output)  
  - `blame.txt`, `blame_top20.txt`  
  - `critical_chain.txt`  
  - `boot_analysis.svg` (unless `--no-svg`)  
  - `boot.dot`

- Journals  
  - `journal_boot.txt` – full boot journal  
  - `journal_warn.txt` – warnings and above  
  - `journal_err.txt` – errors and above  

- Bootchart (if enabled via `init=/lib/systemd/systemd-bootchart`)  
  - `bootchart.tgz` (if present under `/run/log/...`)

- Required units  
  - `failed_units.txt` (from `systemctl --failed`)  

- **KPI breakdown (this run)**  
  - `boot_kpi_this_run.txt` – structured, human-readable KPI summary

---

### KPI breakdown: fields and exclusions

At the end of the run, the script prints a KPI summary **to console** and
writes the same content into `boot_kpi_this_run.txt`, for example:

```text
Boot KPI (this run)
 boot_type : cold
 iterations : 5
 clocksource : arch_sys_counter
 uefi_time_sec : 438093.283 (Init=214751.707, Exec=223341.576)
 firmware_time_sec : 3.765
 bootloader_time_sec : 0.176
 kernel_time_sec : 6.124
 userspace_time_sec : 126.942
 userspace_effective_time_sec : 6.825
 boot_total_sec : 137.008
 boot_total_effective_sec : 16.891
```

Fields:

- `uefi_time_sec`  
  Sum of UEFI loader Init+Exec time in seconds, derived from EFI vars:

  - `LoaderTimeInitUSec-4a67b082-0a4c-41cf-b6c7-440b29bb8c4f`
  - `LoaderTimeExecUSec-4a67b082-0a4c-41cf-b6c7-440b29bb8c4f`

  with individual Init/Exec components also printed.

- `firmware_time_sec`, `bootloader_time_sec`, `kernel_time_sec`,
  `userspace_time_sec`, `boot_total_sec`  
  Parsed from `systemd-analyze time`:

  ```text
  Startup finished in 3.801s (firmware) + 174ms (loader) + 6.106s (kernel) + 2min 7.045s (userspace) = 2min 17.127s
  ```

- `userspace_effective_time_sec`, `boot_total_effective_sec`  

  These are derived from the raw userspace/total time by subtracting:

  1. `systemd-networkd-wait-online.service` time when
     `--exclude-networkd-wait-online` is passed.
  2. Any additional services given via `--exclude-services "svc1 svc2"`.

The script logs exclusions clearly, for example:

```text
[INFO] ... Excluded systemd-networkd-wait-online.service=120.117s from userspace/total; boot_total_effective_sec=16.891
[INFO] ... Excluded services from userspace/total (sum=2.500s): docker.service=0.966s; NetworkManager.service=1.534s;  boot_total_effective_sec=14.391
```

If `systemd-analyze time` reports:

```text
Bootup is not yet finished (org.freedesktop.systemd1.Manager.FinishTimestampMonotonic=0).
```

the script:

- Marks the timing fields as `unknown`.
- Logs the active jobs from `systemctl list-jobs` to **console** so that
  blocking services (including our own KPI service if misconfigured) are
  visible during LAVA debugging.

This diagnostic logging happens **even without `--verbose`**.

---

### Verbose mode (`--verbose`)

When `--verbose` is set, the script:

- Prints all “reasonable” `.txt` artifacts from `OUT_DIR` to console
  (excluding `journal_*.txt` for size reasons).
- This is intended for LAVA and other CI where you cannot easily inspect the
  filesystem but can scroll the job log.

Example tail of the verbose section:

```text
[INFO] ... Verbose mode: dumping text artifacts from ./logs_Boot_Systemd_Validate (excluding journal_*.txt)
===== analyze_time.txt =====
Startup finished in ...
...
===== boot_kpi_this_run.txt =====
Boot KPI (this run)
 ...
```

---

### Typical usage examples

**1) Basic per-boot KPI with required units**

```sh
./run.sh   --timeout 60   --required required-units.txt
```

**2) Cold-boot KPI, excluding networkd-wait-online + Docker/Weston**

```sh
./run.sh   --boot-type cold   --disable-getty   --exclude-networkd-wait-online   --exclude-services "docker.service weston.service"
```

**3) LAVA-friendly verbose run**

```sh
./run.sh   --boot-type warm   --disable-getty   --exclude-networkd-wait-online   --iterations 5   --verbose
```

In all cases, the main KPI is in `logs_Boot_Systemd_Validate/boot_kpi_this_run.txt`
and echoed to console.

---

2. `Boot_Systemd_KPI_Loop` – Reboot loop wrapper & KPI aggregator
-----------------------------------------------------------------

**Path (example):**

```text
suites/Performance/Boot_Systemd_KPI_Loop/run.sh
```

### Purpose

A **thin wrapper** that drives multiple KPI iterations across reboots and
computes averages over the last **N boots** of a given `boot_type`.

On each (re)boot it:

1. Loads state from `Boot_Systemd_KPI_Loop.state` (if present) to determine:
   - Total iterations requested
   - Iterations already completed
   - Boot type & options
   - KPI script path + base out dir
2. Computes **this iteration index**, and a per-iteration out dir:

   ```text
   <base_out_dir>/iter_<N>
   ```

3. Calls `Boot_Systemd_Validate/run.sh` once with:
   - `--out <base_out_dir>/iter_N`
   - `--boot-type <TYPE>`
   - `--iterations <TOTAL>`
   - Forwarded flags (`--disable-getty`, `--exclude-...`, `--verbose`, etc.)
4. Parses `boot_kpi_this_run.txt` for this iteration, appends a row into:

   ```text
   Boot_Systemd_KPI_stats.csv
   ```

5. Computes averages over the last **N entries** for this `boot_type` and writes:

   ```text
   Boot_Systemd_KPI_summary.txt
   ```

6. In **auto-reboot mode**, if more iterations are pending:
   - Updates `Boot_Systemd_KPI_Loop.state`
   - Triggers a reboot
   - A small systemd service (`boot-systemd-kpi-loop.service`) invokes this
     script again on the next boot until all iterations complete.

When all iterations finish, the wrapper:

- Prints the KPI average summary to console.
- Leaves `.csv` and `.summary.txt` for further analysis.
- Cleans up the systemd hook + state file in auto-reboot mode.

---

### Usage (CLI help)

```text
Usage: ./run.sh [OPTIONS]

This wrapper:
  * Runs Boot_Systemd_Validate once for the *current boot*
  * Uses a per-iteration KPI out dir when --iterations > 1:
      base: ../Boot_Systemd_Validate/logs_Boot_Systemd_Validate
      iter: <base>/iter_<N>
  * Parses boot_kpi_this_run.txt from that test
  * Appends a row into Boot_Systemd_KPI_stats.csv
  * Computes averages over the last N boots (per boot_type) and prints summary.

Options:
  --kpi-script PATH   Override Boot_Systemd_Validate script path
                      (default: ../Boot_Systemd_Validate/run.sh)

  --kpi-out-dir DIR   Override base KPI output dir
                      (default: ../Boot_Systemd_Validate/logs_Boot_Systemd_Validate)

  --iterations N      Number of boots to average over (default: 1)
  --boot-type TYPE    Tag for this run (e.g. cold, warm, unknown)

  # Options forwarded to Boot_Systemd_Validate:
  --disable-getty     Disable serial-getty@ttyS0.service
  --disable-sshd      Disable sshd.service
  --exclude-networkd-wait-online
                      Exclude systemd-networkd-wait-online.service
  --exclude-services "A B"
                      Exclude these services from userspace/total
  --no-svg            Disable SVG plot generation
  --verbose           Print KPI .txt artifacts to console for debug

  # Auto-reboot orchestration:
  --auto-reboot       Install systemd hook and auto-reboot until
                      --iterations boots are collected. State is
                      stored in: Boot_Systemd_KPI_Loop.state

  -h, --help          Show this help and exit
```

---

### Files written by the loop wrapper

Under the same directory as `Boot_Systemd_KPI_Loop/run.sh`:

- `Boot_Systemd_KPI_Loop.res`  
  PASS/FAIL status for the wrapper itself.

- `Boot_Systemd_KPI_Loop.state`  
  Persistent state across reboots (total iterations, done so far, boot_type,
  options, KPI script path/out dir). Removed automatically when all iterations
  complete or on error.

- `Boot_Systemd_KPI_stats.csv`  
  Rolling KPI database across boots. Each row corresponds to the parsed
  `boot_kpi_this_run.txt` of one boot (for a given `boot_type`).

- `Boot_Systemd_KPI_summary.txt`  
  Human-readable summary of averages over the last **N** entries of that
  `boot_type`, e.g.:

  ```text
  Boot KPI summary (last 5 cold boot(s))
   entries_used : 5
   target_iterations : 5
   boot_type : cold
   avg_uefi_time_sec : ...
   avg_firmware_time_sec : ...
   avg_bootloader_time_sec : ...
   avg_kernel_time_sec : ...
   avg_userspace_time_sec : ...
   avg_userspace_effective_time_sec : ...
   avg_boot_total_sec : ...
   avg_boot_total_effective_sec : ...
  ```

- `Boot_Systemd_KPI_Loop_stdout_<timestamp>.log`  
  Stdout/stderr log(s) for the wrapper itself (if you preserve them).

Per-iteration artifacts from `Boot_Systemd_Validate` live under:

```text
../Boot_Systemd_Validate/logs_Boot_Systemd_Validate/iter_1/
../Boot_Systemd_Validate/logs_Boot_Systemd_Validate/iter_2/
...
```

Each `iter_N` has its own `boot_kpi_this_run.txt`, `analyze_time.txt`, etc.

---

### Auto-reboot mode details

When `--auto-reboot` is passed:

- The wrapper installs a small systemd service (e.g. `boot-systemd-kpi-loop.service`)
  that runs the wrapper at boot.
- On each boot, the wrapper:
  - Runs `Boot_Systemd_Validate` once.
  - Updates the `.state` file with the new iteration count.
  - If more iterations are required, it requests `reboot` again.
- After the final iteration:
  - KPI averages are computed and printed.
  - The systemd hook is removed.
  - The state file is deleted.

The reboot logic is designed to:

- Ensure the reboot actually happens (falling back between `reboot` and `/sbin/reboot`).
- Avoid blocking `systemd-analyze` permanently: the KPI scripts finish quickly,
  and if any unit (including our own) prevents boot from completing, it will
  show up in the “Bootup is not yet finished … list-jobs” diagnostics inside
  each `iter_N/analyze_time.txt` and in the **console logs**.

---

### Typical usage examples

**1) Manual KPI over last 5 cold boots (no auto-reboot)**

You manually reboot the board between runs:

```sh
# Boot 1 (cold boot)
./run.sh --iterations 5 --boot-type cold --disable-getty --exclude-networkd-wait-online

# Reboot the board manually (power-cycle or reboot)

# Boot 2..5 – re-run the same command each time
./run.sh --iterations 5 --boot-type cold --disable-getty --exclude-networkd-wait-online
...
```

After the 5th run, `Boot_Systemd_KPI_summary.txt` will contain the averages over
the last 5 `cold` entries.

**2) Fully automated cold-boot KPI campaign (auto-reboot)**

```sh
./run.sh   --iterations 5   --boot-type cold   --disable-getty   --exclude-networkd-wait-online   --auto-reboot
```

The wrapper will:

- Run `Boot_Systemd_Validate` on this boot.
- Reboot automatically until 5 iterations are captured.
- Finally, print a KPI summary and clean up the systemd hook/state.

**3) Warm-boot KPI with extra service exclusions and verbose logs**

```sh
./run.sh   --iterations 3   --boot-type warm   --disable-getty   --exclude-networkd-wait-online   --exclude-services "docker.service weston.service"   --auto-reboot   --verbose
```

This gives:

- Per-iteration directories: `iter_1`, `iter_2`, `iter_3`.
- Detailed logs printed to console from `Boot_Systemd_Validate` via `--verbose`.
- Aggregated averages in `Boot_Systemd_KPI_summary.txt`.

---

3. Which one should I use?
--------------------------

| Scenario                                      | Recommended test                      | Notes                                                                 |
|----------------------------------------------|---------------------------------------|-----------------------------------------------------------------------|
| Standard CI pipeline (no reboot-resume)      | `Boot_Systemd_Validate`               | Run once per job; no reboot inside the script.                        |
| Manual KPI measurement on a single boot      | `Boot_Systemd_Validate`               | E.g. after changing kernel/systemd configs.                          |
| Quick health-check of systemd units          | `Boot_Systemd_Validate`               | Use `--required` to gate on critical services.                        |
| Lab KPI across N cold/warm boots             | `Boot_Systemd_KPI_Loop`               | Wrapper handles per-boot dirs + CSV + averages; you may reboot manually. |
| Automated multi-boot campaign in lab         | `Boot_Systemd_KPI_Loop` with `--auto-reboot` | State file + systemd hook handle the full loop.                 |
| CI with explicit reboot-resume support       | `Boot_Systemd_KPI_Loop` (if allowed)  | CI must re-run the script after each reboot.                          |

---

4. Design principles
--------------------

- **Single responsibility**  
  - `Boot_Systemd_Validate`: _measure one boot and emit KPIs_.  
  - `Boot_Systemd_KPI_Loop`: _across boots: state, reboots, aggregation_.

- **CI friendliness**  
  - CI that cannot handle reboots should only use `Boot_Systemd_Validate`.  
  - Reboot orchestration via `--auto-reboot` is explicitly opt-in.

- **Robust & transparent**  
  - Rolling CSV + summary for long-term trends.  
  - Clear console logs for:
    - service time exclusions,
    - non-finished boots (`Bootup is not yet finished` + `systemctl list-jobs`),
    - per-iteration KPI values.

- **Local logs only**  
  - All artifacts (CSV, SVG, journals, etc.) are stored under the test’s
    working directory, making log collection and LAVA parsing straightforward.
