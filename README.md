# write-latency-diag

A diagnostic script for Linux. It is tested on Ubuntu, Unraid is detected as well. It measures write latency and
narrows down whether the wait happens **on the SSDs** (device, controller, cache flush) or **above them** (CPU, RAID
parity, encryption, file system, locks).

It only needs `bash` and `awk`. `fio`, `smartctl`, `bpftrace` and `hdparm` are optional but provide much more
detail:

```bash
sudo apt install fio smartmontools bpftrace hdparm
```

## Installation

```bash
wget -O /tmp/wlat.sh https://raw.githubusercontent.com/Commifreak/write-latency-diag/main/write-latency-diag.sh
chmod +x /tmp/wlat.sh
```

Run the script as root (`sudo`). Otherwise SMART data is missing.

**Automatic update:** On every start the script downloads the current version from GitHub (`main`), checks it
(complete, valid bash syntax) and restarts itself if it changed. If the CheckMK agent is installed
(`/usr/lib/check_mk_agent`), it also installs or updates the two local checks (see below). Without a network
connection the existing version keeps running. If the script lives in a Git working copy, it is not overwritten.
Disable with `-U` or `WLAT_NO_UPDATE=1`. Since the script runs as root, the update executes code from this
repository with root privileges. If you do not want that, always start it with `-U`.

## Procedure

**1. Active test (about 1 minute)**

```bash
sudo /tmp/wlat.sh -t /path/on/the/ssd-volume/.lattest
```

The test writes 4k blocks with O_SYNC (queue depth 1). This is how databases, Docker containers and VMs write as
well. The test file is 256 MB and is deleted afterwards. With several `-t` you can compare volumes, e.g. RAID
against a single SSD or encrypted against unencrypted.

**2. Observe in everyday use when things hang (passive)**

```bash
sudo /tmp/wlat.sh -d 600
```

Every second the script shows CPU, core peak, PSI and top processes, and for every active SSD throughput, await,
flush latency and utilization. Slow intervals are marked with `<< SLOW`. `Ctrl+C` stops the measurement early,
the analysis still follows.

**3. Observe over a whole day**

```bash
sudo /tmp/wlat.sh -d 86400 -q -i 5
```

With `-q` the script only shows the conspicuous intervals, each with the processes writing at that moment. The
analysis at the end summarizes the whole period. This way nightly backups, cron jobs and database maintenance end
up in the measurement too. Best started in `tmux` or `screen`.

**4. Optional: sustained load (SLC cache)**

```bash
sudo /tmp/wlat.sh -t /path/.lattest -S 30G
```

This test writes 30 GB. If the write rate drops sharply after a few GB, the SSD's SLC cache is full. This is
typical for QLC SSDs and DRAM-less SSDs.

Report and samples (`samples.csv`, one line per second and device) are stored under `/tmp/wlat-<timestamp>/`.

## Check a new or used SSD before installing it

```bash
sudo /tmp/wlat.sh --check-disk /dev/sdX -o /root
```

**Caution: the check erases the whole drive.** It only runs on a whole drive that is not mounted, not part of a
RAID/LVM and not active as swap. Before starting, the script shows model, serial number and content and asks you
to type the device name. Needs `fio`, `smartctl` and `blkdiscard` (`apt install fio smartmontools`). Best started in
`tmux` or `screen`.

Steps:

1. **SMART before and short self-test**: overall health, attributes at their threshold, counters that are 0 on a
   healthy SSD (reallocated, pending and uncorrectable sectors, program and erase errors, reserve blocks), error
   log, earlier self-tests, wear, power-on hours, data written and unexpected power losses. For Samsung SSDs with a
   NAND counter (attribute 251, e.g. SM883/PM883) also the write amplification over the lifetime and, at the end,
   during the check.
2. **TRIM over the whole drive** (`blkdiscard`): used SSDs start without old allocations.
3. **Flush latency**: 60 s of 4k writes with O_SYNC directly to the drive, every write with a flush. With
   effective power loss protection (PLP) the SSD acknowledges immediately: median below 0.5 ms. Without PLP it
   takes milliseconds.
4. **Full write with checksums**: the whole drive is written and read back (`fio --verify=crc32c`). This finds
   defective areas and shows the sustained write rate, also per 10 % of the drive (drop caused by a full SLC
   cache).
5. **Performance when full**: 4k random reads and writes at queue depth 32 and reads at queue depth 1, 30 s
   each.
6. **Sustained load as in production** (`-r SEC`, default 3600): 16 sync writes per second (like databases), plus
   a 1 MB/s stream (like a camera recording) and 50 reads per second, on the completely written, untrimmed SSD.
   The script detects stalls with the same rules as the service. It also measures the wait time of every single
   sync write. An SSD with regular firmware pauses stands out here, including the pattern of duration and
   interval.
7. **Long self-test** of the SSD.
8. **SMART after**: if one of the error counters rises during the check, it fails. The script also compares the
   SSD's write counter with the amount the kernel has written. If it does not match, read wear and data written
   with caution. Finally the drive is trimmed again.

The result is `PASSED`, `PASSED WITH FINDINGS` or `FAILED` (exit code 2), with all findings. A line with the most
important values is also appended to `ssdcheck-summary.txt` in the `-o` directory, so several SSDs can be compared
side by side. Report, SMART output and samples are stored under `ssdcheck-<device>-<timestamp>/`. `Ctrl+C` aborts
and shows what has been checked so far.

For a 480 GB SSD the check takes about 2.5 hours. Several SSDs can be checked at the same time in separate runs.
The check usually works via a USB adapter too (SMART via `-d sat`), but the adapter adds latency to every request,
and some do not pass flush and TRIM on correctly. The flush latency can then only be judged roughly. Self-tests are
not available for NVMe SSDs.

## Who causes the load?

- **Writers per process**: in every interval the line `writes:` shows which processes write how much (from
  `/proc/<pid>/io`, complete only as root). The analysis names the biggest writers over the whole phase and,
  separately, in the slow intervals. When a process exits, the kernel adds its writes to the parent process. That
  is why `systemd`, `cron` or `containerd-shim` show up with the writes of their exited child processes.
- **fsync callers** (with `bpftrace`): who calls `fsync`, `fdatasync`, `sync_file_range`, `msync(MS_SYNC)`, `sync`
  or `syncfs`, how often, and how long do they wait for it? Shown as process/thread, e.g. `mysqld/ib_log_flush`.
  Processes that exit during the measurement are recorded with their writes as well. `-T` disables tracing.
- **Write amplification over time**: the SMART counters cover the whole lifetime of the SSD. Every run saves them
  in `/var/lib/write-latency-diag/smart-history.csv`. From the second run on (at the earliest after 1 h, better
  after 12 h or more) the script shows the write amplification since the last data point. This shows whether a
  change has worked.

## Continuous recording with a web UI

Instead of single runs, a service can record continuously. It shows the results on its own web page (default:
port 81):

```bash
sudo /tmp/wlat.sh --install-service
```

Then open `http://<server-ip>:81/` in the browser. The page shows:

- **Findings**: the same rules as the script and CheckMK (write cache, write amplification, remaining lifetime,
  stalls, TRIM, IO and CPU pressure)
- **Noticeable stalls** in real seconds for the last hour, 24 h and 7 days: how often, how long in total, the
  longest stall and how long an application waited for its fsync at most. Plus the last noticeable stall, the
  noticeable seconds per hour and every noticeable stall individually (time, device, duration, who waited and who
  wrote). Noticeable means: from 1 s wait time (`felt_ms` in the configuration) or from 2 s duration.
- **Drives**: current latency and flushes, write amplification over the last 24 h, wear with remaining lifetime,
  write cache
- **History** (1 h to 90 days): maximum wait per device, flushes per second, writes, PSI and CPU
- **Stalls**: every phase in which an SSD stalls (wait time from 100 ms or requests in flight without progress),
  with duration, device, the processes that were writing and those that waited for it via fsync
- **fsync callers and writers** over the selected period, **write amplification per day**
- **Raw data to copy**: a compact text report with everything above, including every single noticeable stall,
  meant for pasting into a chat or a ticket. A button copies it. Directly available at `/api/report`, e.g.
  `curl http://<server-ip>:81/api/report`

The service queries SMART values every 30 minutes. On SATA, SMART commands bypass the command queue, so other
requests wait briefly. Stalls that coincide with such a query are therefore marked with "SMART".

The page is read-only and has no login. It therefore belongs in the LAN only, not on the internet. The service only
needs Python 3 (standard library). With `bpftrace`, `smartmontools` and `hdparm` it provides all values. The data
is stored in `/var/lib/write-latency-diag/metrics.db` (SQLite): 5-second values for 7 days, minute values for 90
days, stalls for a year. The service writes in batches once per minute and causes hardly any fsyncs itself.

Settings (port, address, retention, stall threshold) are in `/etc/write-latency-diag.conf`. Afterwards run
`systemctl restart write-latency-diag`. The service checks daily for a new version, and every script run updates it
as well.

```bash
sudo systemctl stop write-latency-diag
```

```bash
sudo systemctl disable --now write-latency-diag
```

```bash
sudo /tmp/wlat.sh --uninstall-service
```

The first command stops the service, the second disables it permanently, the third removes it. Data and
configuration are kept.

## Continuous monitoring with CheckMK

The `checkmk/` folder contains two local checks for the CheckMK agent:

| File | Runs | Services |
|---|---|---|
| `write_latency` | on every agent call | `SSD sdX Latency` (flush and write latency, flushes/s, throughput, utilization), `IO pressure` and `CPU pressure` (PSI), `Top writers` (net, by process name) |
| `write_latency_smart` | every 30 minutes | `SSD sdX Write cache`, `SSD sdX Write amplification` (last 24 h), `SSD sdX Wear` (with remaining lifetime), `SSD TRIM <mount point>` |

Installation on the monitored server:

```bash
sudo wget -O /usr/lib/check_mk_agent/local/write_latency https://raw.githubusercontent.com/Commifreak/write-latency-diag/main/checkmk/write_latency
```

```bash
sudo mkdir -p /usr/lib/check_mk_agent/local/1800 && sudo wget -O /usr/lib/check_mk_agent/local/1800/write_latency_smart https://raw.githubusercontent.com/Commifreak/write-latency-diag/main/checkmk/write_latency_smart
```

```bash
sudo chmod +x /usr/lib/check_mk_agent/local/write_latency /usr/lib/check_mk_agent/local/1800/write_latency_smart
```

Then run a service discovery for the host in CheckMK. Easier: start the script once as root. If the agent is
present, it installs the checks itself and keeps them up to date on every further start.

**With the service** (see above) the checks do not measure themselves. They pass on the values of the service
(`/api/checkmk`), so that CheckMK and the web UI rely on the same measurement and SMART is queried only once. This
adds the service `SSD stalls` (noticeable stalls in the last hour: count, seconds, longest stall, longest wait of an
application; WARN from one noticeable stall, CRIT from 5 s). If the service is stopped or has no data yet, the checks
measure themselves again. The thresholds then come from the service, not from the files. Both checks can also be
called directly for testing. The values always refer to the period since the previous call (state under
`/var/lib/write-latency-diag/`). The first call therefore only returns starting values, and the write amplification
over the last 24 h is known after one day. The thresholds are at the top of the files:

| Service | WARN | CRIT |
|---|---|---|
| Flush latency avg | 10 ms | 50 ms |
| Write await avg | 20 ms | 100 ms |
| IO pressure (PSI io full, avg60) | 10 % | 25 % |
| CPU pressure (PSI cpu some, avg60) | 20 % | 40 % |
| Write amplification (24 h) | 5 | 10 |
| Remaining lifetime | < 2 years | < 1 year |
| Write cache | off | kernel considers it off although it is on |
| TRIM | overdue or more than 2 % of the capacity untrimmed | – |

The latency service only sees short stalls within a minute if they raise the minute average noticeably. For a
detailed analysis with fsync callers, use the script.

The script detects stalls exactly like the service: as events with time, SSD, duration and wait time, plus the
typical duration and the typical interval per SSD. If an SSD pauses at a fixed rhythm (e.g. every 10 minutes for 7
seconds), the findings say so explicitly. If the service is running, the script points to its web UI and to the
report over the whole period at the end.

## How is it decided?

| Metric | Meaning |
|---|---|
| **Device time share** (active test) | Sum of all request times of the SSD (writes and flushes) divided by the test duration. At QD1 this shows which share of the wait time lies on the device. ≥ 70 % points to the SSD, ≤ 35 % to CPU/software. |
| **w_await / flush latency** per SSD | The latency the device itself delivers. Flush is what `fsync` waits for. Guide values: good SATA SSD < 2 ms, enterprise SSD with PLP < 0.1 ms. |
| **SLOW intervals** | High latency at low throughput, i.e. a real drop and not a normal queue backlog. |
| **Outlier SSD** | One SSD is much slower than the others. Then check this drive (firmware, wear, cable). |
| **Alternating stalls** | Sometimes one SSD stalls, sometimes another, while the others respond quickly at the same moment. The device pauses internally (garbage collection, firmware). This is not a single defect but rather a model or load problem. In an mdadm RAID every `fsync` waits for all members, so every stall of a single SSD slows down the whole array. |
| **Write amplification (WAF)** | For SanDisk/WD SSDs calculated from SMART 233 (NAND GiB) and 241 (host GiB), for Samsung SSDs with a NAND counter (e.g. SM883/PM883) from 251 and 241 (NAND and host LBAs), for Crucial/Micron from 247/248 (host and FTL pages). About 1–3 is normal. Values from 5 mean that the SSD internally rewrites a multiple. This is typical for many small `fsync` writes on consumer SSDs without PLP. The consequences are constant garbage collection, latency spikes and fast wear. |
| **TRIM schedule** | On ext4 every `fstrim` run reports roughly how much was deleted since the last run (the first run after a reboot does not count). From this the script calculates how much deleted but not yet trimmed space can accumulate until the next run. From about 2 % of the capacity it recommends daily TRIM: until then this space is used for the SSD, and consumer SSDs only have ~7 % spare area. |
| **Wear / remaining lifetime** | Wear in % (ATA Device Statistics, NVMe "Percentage Used" or vendor-specific). The script calculates the remaining lifetime twice: with the average of the lifetime so far and, from the second run on, with the current rate since the last data point (from the NAND writes, for SanDisk/WD, Samsung and Crucial/Micron). Below two years there is a note, below one year a warning. |
| **Mirror groups** (mdadm RAID10) | Which SSDs always receive the same writes. They wear out at the same rate and often pause for garbage collection at the same time. |
| **RAID setup** (mdadm) | Without a write-intent bitmap, the whole RAID has to be resynchronized after every crash (remedy: `mdadm --grow --bitmap=internal`). If the array is missing from `mdadm.conf`, the initramfs may assemble it under a different name. With RAID10, there is a note if the two by far oldest SSDs (power-on hours) are in the same mirror group. As a tip: if the RAID partitions reach up to the end of the drives, a replacement SSD needs at least as many sectors. |
| **ext4** | Behavior on errors: with "Continue" ext4 keeps writing despite damaged metadata, `tune2fs -e remount-ro` is recommended. The reserve for root (default 5 %) is of little use if the services run as root anyway (tip: `tune2fs -m 1`). On software RAID the script checks whether `stride` and `stripe-width` match the chunk. |
| **Boot with RAID as `/`** | Does every drive of the RAID have an EFI partition? Does `/boot/efi` have `nofail` in the fstab, so the server also boots normally without this drive? Does GRUB keep all EFI partitions up to date on updates (`grub-efi/install_devices`, remedy: `dpkg-reconfigure grub-efi-amd64`)? |
| **Swap** | If a lot is in swap although enough RAM is free, the kernel has to read swapped-out program parts back from disk on the next access (page faults). If that coincides with an SSD stall, the program waits. Remedy: `swapoff -a && swapon -a`, swap less often with `vm.swappiness=10`. |
| **Write cache** | Shows the state in the drive (`hdparm -W`), at boot (first kernel message, before udev rules apply) and the SCT setting. If the cache is off, every write goes straight to flash. If the kernel considers it off although it is on, it sends no flushes, and data loss is possible on power failure. |
| **Core ≥ 95 % / PSI cpu** | A single thread is the bottleneck, or processes wait for CPU time. |
| **Top processes** | `md0_raid5`/`md0_raid6` stands for the RAID parity calculation, `kcryptd`/`dmcrypt_write` for LUKS, `z_wr_*` for ZFS, `md0_resync` for a running RAID check. |
| **iowait** | This is **not** CPU load. The CPU waits for IO. |

## Typical causes and remedies

- **mdadm RAID5/6**: small writes need a read-modify-write, and the parity calculation runs in a single kernel
  thread. Increase `stripe_cache_size`. For sync-heavy workloads RAID10 is much faster.
- **RAID check**: Ubuntu starts `checkarray` on the first Sunday of every month (`/etc/cron.d/mdadm`). During this
  time writes are much slower.
- **SATA ALPM** (`med_power_with_dipm`, `min_power`): set the link back with
  `echo max_performance > /sys/class/scsi_host/hostX/link_power_management_policy`. This setting is often made by
  TLP or `powertop --auto-tune`.
- **High flush latency**: consumer SSDs without power loss protection. With ZFS `sync=standard` helps (not
  `always`). For databases, enterprise SSDs with PLP make sense.
- **Drop under sustained load**: the SSD is a QLC or DRAM-less SSD, or TRIM is missing. Enable
  `systemctl enable --now fstrim.timer`. If a lot is deleted (backups, NVR recordings), trim daily instead of
  weekly: `systemctl edit fstrim.timer`, there `[Timer]`, `OnCalendar=` and `OnCalendar=daily`. With mdadm, TRIM has
  to be passed through all layers (`lsblk --discard`).
- **High write amplification**: caused by many small sync writes (databases, NVRs like Frigate, logs). Remedy:
  reduce the sync load (e.g. recordings on separate disks, check the database `fsync` settings), over-provisioning
  (leave 10–20 % unpartitioned) or use enterprise SSDs with PLP. They acknowledge a flush immediately from the
  protected cache.
- **Databases (MySQL/MariaDB)**: the defaults secure every commit twice via `fsync` (redo log and binlog). Without
  replication you do not need the binlog (`disable-log-bin`). With `innodb_flush_log_at_trx_commit = 2` at most ~1 s
  of transactions is lost on power failure, the database stays consistent. A larger `innodb_buffer_pool_size` and a
  smaller `innodb_io_capacity` (MySQL 8.4: default 10000) let InnoDB collect changes instead of writing back every
  page immediately.
- **Write cache off**: according to the ATA standard the switch (`hdparm -W1`) is not permanent. If the drive comes
  up without cache at boot (BIOS or firmware), many drives allow enabling it permanently in the drive via SCT
  Feature Control: `smartctl -s wcache-sct,on,p /dev/sdX`. Then do a cold boot and check with
  `journalctl -k -b | grep -i 'write cache'`. To revert: `smartctl -s wcache-sct,ata,p /dev/sdX`. Without SCT the
  only option is to enable the cache at every boot with a udev rule running `hdparm -W1`.
- **CRC errors / ATA resets in dmesg**: check cable, backplane or port.
- **Large dirty buffer**: many GB of RAM with `vm.dirty_ratio=20` build up large writeback bursts. A smaller
  `vm.dirty_bytes` value smooths them.

For ZFS, `zpool iostat -vl 1` shows in parallel whether time is spent in the queues (`syncq_wait`/`asyncq_wait`)
or on the disk (`disk_wait`).
