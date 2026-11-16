# write-latency-diag

Tools that measure write latency on Linux servers and narrow down its cause: SSD (device, flush, firmware) or
CPU/software. The main target is Ubuntu with mdadm, the script also detects Unraid.

## Way of working

- Commit and push directly to `main`, no pull requests.
- Everything users see (output, findings, web UI, README) is in English, with a decimal point. Commit messages in
  English.
- Bump `VERSION` with every change: in the script (`write-latency-diag.sh`) or in the service
  (`service/wlat-service.py`). The auto-update compares the file content, the version appears in the report.
- The repo is public and is loaded by the auto-update from `raw.githubusercontent.com` (branch `main`).
  Never commit data of a specific server (IPs, serial numbers, user names, reports).

## Structure

| Part | File | Purpose |
|---|---|---|
| Service | `service/wlat-service.py` | The single source for continuous measurement: collector, SQLite, web UI (port 81), text report `/api/report`, CheckMK lines `/api/checkmk` |
| CheckMK checks | `checkmk/write_latency`, `checkmk/write_latency_smart` | Pass on the service's output when it is running and has data. Otherwise they measure themselves |
| Script | `write-latency-diag.sh` | Active tests (fio, sustained load), one-off analysis, check of new SSDs before installation (`--check-disk`, erases the drive), installation of the service (`--install-service`), auto-update of script, service and checks |

- The logic for stalls, write amplification (WAF), wear/remaining lifetime, write cache and TRIM exists in several
  parts. It must stay identical: same thresholds, same rules, same service names in CheckMK. Whoever changes a rule
  changes it everywhere (script awk, service, `checkmk_lines()` and the checks' own measurement).
- Stalls (also in the sustained load of `--check-disk`): a time slice is slow if requests take >= 100 ms
  (`stall_ms`) or the device has requests in flight and completes none. Consecutive slow slices (gap < 3 s) form one
  event. An event is noticeable from 1 s wait time (`felt_ms`) or 2 s duration. HDDs (rotational) do not count as
  an SSD finding.
- Writers per process are counted net (`write_bytes - cancelled_write_bytes`). When a process exits, the kernel
  adds its amount to the parent process. What was already counted for the child is subtracted there.
- On SATA, SMART queries bypass the NCQ queue. The service remembers their time spans and marks stalls that fall
  into a query.
- CheckMK service names (since script 1.14 / service 1.7, previously German): `SSD sdX Latency`, `IO pressure`,
  `CPU pressure`, `Top writers`, `SSD stalls`, `SSD sdX Write cache`, `SSD sdX Write amplification`,
  `SSD sdX Wear`, `SSD TRIM <mount>`, `SSD SMART`.

## Code rules

- Service: Python standard library only (runs on Ubuntu 24.04 with Python 3.12 and on 26.04). No packages, nothing
  from the internet at runtime. The web UI is read-only and has no login. It must never trigger commands or tests.
  Always insert process names in the browser as text (`textContent`), never as HTML.
- The service itself should cause hardly any write load: SQLite with WAL and `synchronous=NORMAL`, write in one
  batch per minute.
- Script: bash and awk, compatible with mawk (Ubuntu default). No `strftime`, no gawk extensions. Do not read files
  under `/proc/<pid>/` via `getline`: mawk aborts on read errors (EACCES). Use `grep -s -H` over all files instead.
- Handle numbers in script and checks with `LC_NUMERIC=C` (set at the top of both): with a German or other
  locale awk would otherwise print commas and comparisons turn into string comparisons. Format numbers for users
  with `dc_num` (script) or `num()` (service).
- bpftrace: up to 0.20 "Attaching N probes..." goes to stdout, newer versions (e.g. 0.25 on Ubuntu 26.04) print
  "Attached N probes" to stderr. Accept both and always read stderr too. The map output format is the same.
- SMART write amplification: SanDisk/WD 233/241 (GiB), Samsung 251/241 (LBAs, converted to GiB), Crucial/Micron
  247/248. The service only shows drives from the latest SMART query, the history stays per serial number.
- Check downloads in the auto-update before replacing (complete, `bash -n` or `compile()`). A Git working copy is
  never overwritten.
- Describe new options, services or findings in the README.

## Testing

The development environment is a VM without real SATA SSDs, without systemd and without a CheckMK agent.

- Static checks: `bash -n write-latency-diag.sh checkmk/*`, `python3 -m pyflakes service/wlat-service.py`.
- bpftrace needs tracefs: `mount -t tracefs nodev /sys/kernel/tracing`.
- `WLAT_TEST_ALL_SSD=1` treats the (rotational) VM disks as SSDs, in the script and in the service.
- Start the service with a test configuration: `WLAT_CONF=<file>` with e.g. `bind = 127.0.0.1`, `port = 18081`,
  `db = <scratchpad>/metrics.db`, `auto_update = 0`. Stalls can be produced with a large write block followed by
  `fsync`.
- Auto-update against a local test server: `WLAT_UPDATE_URL=http://127.0.0.1:<port>` and
  `python3 -m http.server`. `WLAT_NO_UPDATE=1` disables the update.
- SMART, hdparm, journalctl and systemctl are missing or not real in the VM: for tests, put small stand-in scripts
  first in `PATH` and write test data directly into the SQLite database.
- Web UI: screenshots with Playwright (`NODE_PATH=/opt/node-tools/node_modules node <script>.js`), light, dark and
  390 px wide each. Check for browser errors and horizontal scrolling.
- `--check-disk`: test on a loop device (`losetup` on a file in the scratchpad) with a stand-in `smartctl` that
  emulates a SATA SSD (`-i -A -c -t -X -l selftest -l devstat`). `WLAT_CONFIRM_DEV=<device name>` replaces the
  confirmation prompt. Test aborting with `TERM`: background processes of a non-interactive shell ignore `INT`.
- RAID and boot checks (`md_groups`, `md_extra_checks`, `fs_boot_check`, `boot_check`): the VM kernel has no md.
  Test with loop drives (`losetup -f`, `partx -a`, GPT with an EFI partition), a fake md directory
  (`WLAT_TEST_SYSBLOCK=<dir>` with `md0/md/level`, `layout`, `raid_disks`, `chunk_size`, `slaves/`,
  `md/dev-*/slot`), a device name `/dev/md0` via `mknod` pointing to a loop drive (mount with `mount -c`) and the
  functions via `eval`.
- Stop test processes specifically (`pkill -f '^python3 service/wlat-service.py'`), not with a pattern that also
  matches your own shell.

## Context summary

When summarizing (automatically or `/compact`), keep in full:

- The state of the analysis on the user's target server: findings with the most important measurements, purchased
  or planned hardware, changes already made and the open steps there, each with the commands still to be run.
  This data is intentionally not in the repo and exists only in the conversation.
- Disproved assumptions and why they were wrong, so they are not suggested again.
- What the user announced for later ("keep in mind").
- Ongoing work on the code: what is changed, tested and pushed, and what is still missing.
