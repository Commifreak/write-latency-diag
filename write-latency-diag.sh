#!/bin/bash
#
# write-latency-diag.sh
#
# Observes write latency and narrows down whether the wait happens on the SSDs
# (device, controller, flush) or above them (CPU, shfs/FUSE, ZFS, btrfs,
# locks).
#
# Reads only /proc and /sys. Write tests (-t / -S) write nothing but a
# temporary test file in the given directory and delete it afterwards.
#

VERSION="1.14"

# Always process numbers with a dot: with a German or other locale awk would print "3,000", bash printf would reject
# "3.5" and comparisons would turn into string comparisons.
if [ -n "${LC_ALL:-}" ]; then export LANG="$LC_ALL"; unset LC_ALL; fi
export LC_NUMERIC=C

PASSIVE=""            # duration of the passive observation in seconds
INTERVAL=1
TEST_RUNTIME=30
TEST_SIZE="256M"
SEQ_SIZE=""
OUTBASE="/tmp"
DEVRE='^(sd[a-z]+|nvme[0-9]+n[0-9]+|vd[a-z]+|xvd[a-z]+)$'
SKIP_STATIC=0
QUIET=0
TRACE=1
STATE_DIR="/var/lib/write-latency-diag"   # SMART history for the current write amplification
TARGETS=()
AUTO_UPDATE=1
UPDATE_URL="${WLAT_UPDATE_URL:-https://raw.githubusercontent.com/Commifreak/write-latency-diag/main}"
CMK_LOCAL="/usr/lib/check_mk_agent/local"
ORIG_ARGS=("$@")
SVC_DIR="/usr/local/lib/write-latency-diag"
SVC_FILE="$SVC_DIR/wlat-service.py"
SVC_UNIT="/etc/systemd/system/write-latency-diag.service"
SVC_CONF="/etc/write-latency-diag.conf"
ACTION=""
CHECK_DEV=""
R_SET=0
case "${1:-}" in
  --install-service) ACTION=install; shift ;;
  --uninstall-service) ACTION=uninstall; shift ;;
  --check-disk) ACTION=check; CHECK_DEV=${2:-}; shift; [ $# -gt 0 ] && shift ;;
esac

usage() {
  cat <<EOF
write-latency-diag.sh $VERSION - write latency: SSD or CPU/software?

Usage: $0 [options]

  -d SEC     Observe passively (default: 60 s if no -t is given).
             Trigger or wait for the problem meanwhile. Ctrl+C stops
             early and still shows the analysis.
  -t DIR     Active test: 4k writes with O_SYNC (QD1, like databases/
             Docker) in DIR while measuring. Give it several times to
             compare paths, e.g. -t /srv/data/test -t /var/lib/docker/test
  -r SEC     Runtime per active test (default: $TEST_RUNTIME)
  -S SIZE    Additional sustained sequential write test in the first -t DIR
             (e.g. 20G) - shows drops caused by a full SLC cache.
             Caution: writes SIZE to the SSD.
  -i SEC     Sampling interval (default: $INTERVAL)
  -D REGEX   Observe only these devices (default: $DEVRE)
  -o DIR     Base directory for report/CSV (default: $OUTBASE)
  -n         Skip the system check
  -q         Print only conspicuous intervals (for long runs)
  -T         No bpftrace tracing (fsync callers, exited processes)
  -U         No automatic update (script, CheckMK checks, service)

  --install-service    Install and start the service with web UI (port 81)
  --uninstall-service  Remove the service (data and configuration are kept)
  --check-disk DEV     Check a new or used SSD before installing it: SMART, self-tests,
             flush latency (PLP), full write with checksums, performance and sustained load
             as in production (-r SEC, default 3600). ERASES THE WHOLE DRIVE.
             With -o DIR the report and summary go there, e.g. -o /root
  -h         Help

Examples:
  $0 -d 300
  $0 -d 86400 -q -i 5
  $0 -t /srv/.lattest
  $0 -t /srv/.lattest -S 30G
  $0 --check-disk /dev/sdf -o /root
EOF
}

while getopts "d:t:r:S:i:D:o:nqTUh" opt; do
  case $opt in
    d) PASSIVE=$OPTARG ;;
    t) TARGETS+=("${OPTARG%/}") ;;
    r) TEST_RUNTIME=$OPTARG; R_SET=1 ;;
    S) SEQ_SIZE=$OPTARG ;;
    i) INTERVAL=$OPTARG ;;
    D) DEVRE=$OPTARG ;;
    o) OUTBASE=$OPTARG ;;
    n) SKIP_STATIC=1 ;;
    q) QUIET=1 ;;
    T) TRACE=0 ;;
    U) AUTO_UPDATE=0 ;;
    h) usage; exit 0 ;;
    *) usage; exit 1 ;;
  esac
done

# ---------------------------------------------------------------------------
# Automatic update: bring the script and, if the CheckMK agent is installed, the local checks
# to the state on GitHub (main). Disable with -U or WLAT_NO_UPDATE=1.
# ---------------------------------------------------------------------------
UPDATE_MSGS=()
fetch() { # url target
  if command -v curl >/dev/null 2>&1; then curl -fsSL --max-time 15 -o "$2" "$1" 2>/dev/null
  elif command -v wget >/dev/null 2>&1; then wget -q -T 15 -O "$2" "$1" 2>/dev/null
  else return 1; fi
}
# Only accept complete, syntactically correct bash scripts (aborted download, error page)
valid_script() { [ -s "$1" ] && head -1 "$1" | grep -q '^#!/bin/bash' && bash -n "$1" 2>/dev/null; }

self_update() {
  local self tmp new
  [ "${WLAT_UPDATED:-}" = 1 ] && return   # just updated and restarted
  self=$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null)
  [ -f "$self" ] && [ -w "$self" ] || return
  [ -e "$(dirname "$self")/.git" ] && return   # Git working copy: do not overwrite local changes
  tmp=$(mktemp "$(dirname "$self")/.wlat-update.XXXXXX" 2>/dev/null) || return
  if ! fetch "$UPDATE_URL/write-latency-diag.sh" "$tmp"; then
    UPDATE_MSGS+=("Update: GitHub not reachable - using the existing version $VERSION.")
  elif valid_script "$tmp" && ! cmp -s "$tmp" "$self"; then
    new=$(sed -n 's/^VERSION="\(.*\)"/\1/p' "$tmp" | head -1)
    chmod --reference="$self" "$tmp" 2>/dev/null || chmod 755 "$tmp"
    if mv -f "$tmp" "$self"; then
      exec env WLAT_UPDATED=1 WLAT_UPDATE_MSG="Script updated: $VERSION -> ${new:-?}" bash "$self" "${ORIG_ARGS[@]}"
    fi
  fi
  rm -f "$tmp"
}

cmk_update() {
  local name dest tmp fresh
  [ -d "${CMK_LOCAL%/local}" ] && [ "$(id -u)" -eq 0 ] || return
  for name in write_latency write_latency_smart; do
    # Update an existing installation in place, otherwise the default location (the slow part every 30 min)
    dest=$(find "$CMK_LOCAL" -maxdepth 2 -type f -name "$name" 2>/dev/null | head -1)
    fresh=0
    if [ -z "$dest" ]; then
      fresh=1
      if [ "$name" = write_latency ]; then dest="$CMK_LOCAL/$name"; else dest="$CMK_LOCAL/1800/$name"; fi
    fi
    tmp=$(mktemp 2>/dev/null) || return
    if fetch "$UPDATE_URL/checkmk/$name" "$tmp" && valid_script "$tmp" && ! cmp -s "$tmp" "$dest"; then
      mkdir -p "$(dirname "$dest")" && install -m 755 "$tmp" "$dest" &&
        UPDATE_MSGS+=("CheckMK check $([ $fresh = 1 ] && echo installed || echo updated): $dest")
    fi
    rm -f "$tmp"
  done
  [ ${#UPDATE_MSGS[@]} -gt 0 ] && grep -q 'CheckMK check installed' <<<"${UPDATE_MSGS[*]}" &&
    UPDATE_MSGS+=("New CheckMK checks: run a service discovery for the host in CheckMK.")
}

# Service with web UI (service/wlat-service.py): install, update, remove
py_valid() { [ -s "$1" ] && python3 -c 'import sys; compile(open(sys.argv[1], "rb").read(), sys.argv[1], "exec")' "$1" 2>/dev/null; }

service_fetch() { # target: prefer the local copy from a Git working copy, otherwise GitHub
  local local_copy
  local_copy="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/service/wlat-service.py"
  if [ -f "$local_copy" ] && [ -e "$(dirname "$local_copy")/../.git" ]; then cp "$local_copy" "$1"
  else fetch "$UPDATE_URL/service/wlat-service.py" "$1"; fi
}

service_update() {
  local tmp
  [ -f "$SVC_FILE" ] && [ "$(id -u)" -eq 0 ] && command -v python3 >/dev/null 2>&1 || return
  tmp=$(mktemp) || return
  if service_fetch "$tmp" && py_valid "$tmp" && ! cmp -s "$tmp" "$SVC_FILE"; then
    install -m 755 "$tmp" "$SVC_FILE" && systemctl try-restart write-latency-diag.service 2>/dev/null &&
      UPDATE_MSGS+=("Service updated and restarted: $SVC_FILE")
  fi
  rm -f "$tmp"
}

service_install() {
  local tmp port ip
  [ "$(id -u)" -eq 0 ] || { echo "Please run as root (sudo)." >&2; exit 1; }
  [ -d /run/systemd/system ] || { echo "The service needs systemd (e.g. Ubuntu, Debian)." >&2; exit 1; }
  command -v python3 >/dev/null 2>&1 || { echo "python3 missing: apt install python3" >&2; exit 1; }
  tmp=$(mktemp)
  if ! service_fetch "$tmp" || ! py_valid "$tmp"; then
    echo "Could not load the service ($UPDATE_URL/service/wlat-service.py)." >&2; rm -f "$tmp"; exit 1
  fi
  install -D -m 755 "$tmp" "$SVC_FILE"; rm -f "$tmp"
  if [ ! -f "$SVC_CONF" ]; then
    cat > "$SVC_CONF" <<'CONF'
# write-latency-diag service - changes take effect after: systemctl restart write-latency-diag
# Web UI (no login, read-only - make it reachable only in the LAN)
bind = 0.0.0.0
port = 81
# Database: 5-second values 7 days, minute values 90 days, stalls 365 days
db = /var/lib/write-latency-diag/metrics.db
keep_5s_days = 7
keep_1m_days = 90
keep_events_days = 365
# From this wait time on a second counts as a stall
stall_ms = 100
# Noticeable for users: from this wait time on (or stalls lasting 2 s or more)
felt_ms = 1000
# Record fsync callers with bpftrace (1/0)
bpftrace = 1
# Check daily for a new version (1/0)
auto_update = 1
CONF
  fi
  port=$(sed -n 's/^ *port *= *\([0-9]*\).*/\1/p' "$SVC_CONF" | tail -1); port=${port:-81}
  if ! systemctl is-active -q write-latency-diag.service && command -v ss >/dev/null 2>&1 &&
     ss -ltnH "sport = :$port" 2>/dev/null | grep -q .; then
    echo "Caution: port $port is already in use. Change the port in $SVC_CONF, then: systemctl restart write-latency-diag" >&2
  fi
  cat > "$SVC_UNIT" <<UNIT
[Unit]
Description=write-latency-diag: write latency recording with web UI
After=network.target

[Service]
ExecStart=/usr/bin/env python3 $SVC_FILE
Restart=always
RestartSec=10
Nice=10

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload && systemctl enable --now write-latency-diag.service >/dev/null 2>&1 &&
    systemctl restart write-latency-diag.service
  sleep 2
  ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  if systemctl is-active -q write-latency-diag.service; then
    echo "Service running: http://${ip:-<server-ip>}:$port/"
  else
    echo "Service does not start - details: journalctl -u write-latency-diag -n 30" >&2
  fi
  for t in bpftrace smartctl hdparm; do
    command -v $t >/dev/null 2>&1 || echo "Recommended: $t is missing (apt install $( [ $t = smartctl ] && echo smartmontools || echo $t ))"
  done
  echo "Stop: systemctl stop write-latency-diag   Disable permanently: systemctl disable --now write-latency-diag"
  echo "Configuration: $SVC_CONF"
  exit 0
}

service_uninstall() {
  [ "$(id -u)" -eq 0 ] || { echo "Please run as root (sudo)." >&2; exit 1; }
  systemctl disable --now write-latency-diag.service 2>/dev/null
  rm -f "$SVC_UNIT"; rm -rf "$SVC_DIR"; systemctl daemon-reload 2>/dev/null
  echo "Service removed. Data and configuration are still there: /var/lib/write-latency-diag/metrics.db, $SVC_CONF"
  exit 0
}

# Wear in % (0 = new) from the SMART data: first the standardized value (ATA Device Statistics,
# NVMe "Percentage Used"), otherwise vendor-specific.
wear_used() { # dev smartctl-output(-i -A) wdsd
  local u
  u=$(smartctl -l devstat "$1" 2>/dev/null | awk '/Percentage Used Endurance Indicator/ {print $4 + 0; exit}')
  [ -n "$u" ] || u=$(awk -v wdsd="$3" '
    /^Percentage Used:/ { v = $3; gsub("%", "", v); print v + 0; exit }
    wdsd && $1 == 230 && NF >= 10 { print $10 + 0; exit }
    ($1 == 169 || $1 == 202 || $1 == 177 || $1 == 231) && NF >= 10 { print 100 - $4; exit }' <<<"$2")
  echo "$u"
}

# ---------------------------------------------------------------------------
# --check-disk: check a new or used SSD before installing it. The drive gets erased.
# Steps: SMART before, short self-test, TRIM, flush latency (PLP), full write with checksums,
# performance when full, sustained load as in production, long self-test, SMART after, TRIM.
# The sustained load detects stalls with the same rules as the service (stall_ms, felt_ms, gap < 3 s).
# ---------------------------------------------------------------------------
DC_STALL=100
DC_FELT=1000
DC_RES=()
DC_ABORT=0
DC_STOP=""
dc_section() { printf '\n=== %s ===\n' "$*"; }
dc_info() { printf '      %s\n' "$*"; }
dc_res() { # level text (crit, warn, hint, ok)
  DC_RES+=("$1|$2")
  case $1 in
    crit) printf '  [CRITICAL] %s\n' "$2" ;;
    warn) printf '  [!]  %s\n' "$2" ;;
    hint) printf '  [?]  %s\n' "$2" ;;
    *)    printf '  [ok] %s\n' "$2" ;;
  esac
}
dc_smart() { smartctl "${DC_SMOPT[@]}" "$@" "$DC_DEV"; }
dc_attr() { awk -v id="$2" '$1 == id && NF >= 10 { print $10 + 0; exit }' "$1"; }
dc_devstat() { awk -v n="$2" '$1 ~ /^0x/ && index($0, n) { print $4 + 0; exit }' "$1"; }
dc_nvme() { awk -v n="$2" 'index($0, n ":") == 1 { v = substr($0, length(n) + 2); gsub(/[ ,%]/, "", v); sub(/\[.*/, "", v); print v + 0; exit }' "$1"; }
dc_num() { awk -v x="$1" -v f="${2:-%.1f}" 'BEGIN { printf f "\n", x }'; }
dc_ds() { awk -v d="$DC_NAME" '$3 == d { print $6, $10; exit }' /proc/diskstats; }   # sectors read, written

dc_snap() { # name: SMART in the standard format (for the analysis) and complete (for the record)
  dc_smart -i -H -A -l error -l selftest -l devstat > "$OUT/smart-$1.txt" 2>&1
  dc_smart -x > "$OUT/smart-$1-x.txt" 2>&1
}

dc_written() { # SMART file: bytes written according to the drive (empty if unknown)
  local f=$1 lss v
  lss=$(sed -n 's/^Sector Sizes\{0,1\}: *\([0-9]*\) bytes logical.*/\1/p' "$f" | head -1)
  v=$(dc_devstat "$f" "Logical Sectors Written")
  if [ -n "$v" ]; then echo $(( v * ${lss:-512} )); return; fi
  v=$(dc_nvme "$f" "Data Units Written")
  if [ -n "$v" ]; then echo $(( v * 512000 )); return; fi
  # Samsung counts LBAs in attribute 241, other vendors GiB or 32 MiB - use only for Samsung
  if grep -qE '^(Device Model|Model Number): *(SAMSUNG|MZ)' "$f"; then
    v=$(dc_attr "$f" 241); [ -n "$v" ] && echo $(( v * 512 ))
  fi
}

dc_terse() { # fio-terse-file direction(r/w) -> "iops mb_s mean_ms p50_ms p99_ms p999_ms max_ms errors"
  awk -F';' -v dir="$2" '$1 == 3 {
    if (dir == "r") { i = $8; b = $7; m = $16; x = $15; split($24, a, "="); split($30, p, "="); split($32, q, "=") }
    else            { i = $49; b = $48; m = $57; x = $56; split($65, a, "="); split($71, p, "="); split($73, q, "=") }
    printf "%.0f %.1f %.3f %.3f %.3f %.3f %.3f %s\n", i, b * 1024 / 1e6, m / 1000, a[2] / 1000, p[2] / 1000, q[2] / 1000, x / 1000, $5
    exit }' "$1"
}

dc_ticker() { # text total_bytes interval: progress in the background until $DC_TICK exists
  local r0 w0 r1 w1 t0 t1 lr lw lt
  read -r r0 w0 < <(dc_ds); t0=$(date +%s); lr=$r0; lw=$w0; lt=$t0
  while [ ! -e "$DC_TICK" ]; do
    sleep 5; [ -e "$DC_TICK" ] && break
    t1=$(date +%s); [ $(( t1 - lt )) -ge "$3" ] || continue
    read -r r1 w1 < <(dc_ds)
    awk -v txt="$1" -v tot="$2" -v r="$((r1 - r0))" -v w="$((w1 - w0))" -v dr="$((r1 - lr))" -v dw="$((w1 - lw))" \
        -v dt="$((t1 - lt))" -v el="$((t1 - t0))" 'BEGIN {
      s = sprintf("      [%d min] %s: written %.0f GB", el / 60, txt, w * 512 / 1e9)
      if (tot > 0) s = s sprintf(" (%.0f %%)", 100 * w * 512 / tot)
      s = s sprintf(", read %.0f GB", r * 512 / 1e9)
      if (tot > 0) s = s sprintf(" (%.0f %%)", 100 * r * 512 / tot)
      s = s sprintf(" - currently %.0f MB/s writing, %.0f MB/s reading", dw * 512 / 1e6 / dt, dr * 512 / 1e6 / dt)
      print s }'
    lr=$r1; lw=$w1; lt=$t1
  done
}

dc_sampler() { # output file: the drive's diskstats counters every second until $DC_STOP exists
  local up
  while [ ! -e "$DC_STOP" ]; do
    read -r up _ < /proc/uptime
    awk -v d="$DC_NAME" -v t="$up" '$3 == d { print t, $4, $8, $11, $12, $13, ($19 == "" ? 0 : $19), ($20 == "" ? 0 : $20); exit }' /proc/diskstats
    sleep 1
  done > "$1"
}

dc_selftest() { # short|long max_minutes
  local kind=$1 max=$2 n t0 last=-1 rem res
  if [ "$DC_NVME" = 1 ]; then dc_res hint "Self-test ($kind) not implemented for NVMe - skipped."; return; fi
  dc_smart -t "$kind" > "$OUT/selftest-$kind.txt" 2>&1
  if ! grep -qiE 'has begun|Testing has begun|will complete' "$OUT/selftest-$kind.txt"; then
    dc_res hint "Self-test ($kind) could not be started (adapter?) - see $OUT/selftest-$kind.txt"; return
  fi
  t0=$(date +%s)
  while :; do
    sleep 10
    if [ $DC_ABORT -eq 1 ]; then dc_smart -X >/dev/null 2>&1; dc_info "Self-test aborted."; return; fi
    n=$(dc_smart -c 2>/dev/null | sed -n 's/^Self-test execution status: *( *\([0-9]*\)).*/\1/p' | head -1)
    [ -n "$n" ] || n=0
    [ "$n" -ge 240 ] 2>/dev/null || break
    rem=$(( (n - 240) * 10 ))
    if [ "$kind" = long ] && [ "$rem" != "$last" ]; then dc_info "[$(( ($(date +%s) - t0) / 60 )) min] $rem % of the self-test remaining"; last=$rem; fi
    if [ $(( $(date +%s) - t0 )) -gt $(( max * 60 )) ]; then
      dc_smart -X >/dev/null 2>&1; dc_res warn "Self-test ($kind) not finished after $max min - aborted."; return
    fi
  done
  res=$(dc_smart -l selftest 2>/dev/null | awk '/^# *1 / { sub(/^# *1 +/, ""); gsub(/  +/, "  "); print; exit }')
  if grep -q 'Completed without error' <<<"$res"; then
    dc_res ok "Self-test ($kind) without errors ($(( ($(date +%s) - t0 + 30) / 60 )) min)."
  elif [ -z "$res" ]; then
    dc_res hint "Self-test ($kind): no result in the log."
  else
    dc_res crit "Self-test ($kind) with error: $res"
  fi
}

dc_smart_eval() { # SMART file before
  local f=$1 h v used poh pc por wr
  h=$(sed -n 's/^SMART overall-health self-assessment test result: *//p; s/^SMART Health Status: *//p' "$f" | head -1)
  case "$h" in
    PASSED|OK) dc_res ok "SMART overall health: $h" ;;
    "") dc_res hint "SMART overall health not readable (adapter? try smartctl -d sat)" ;;
    *) dc_res crit "SMART overall health: $h" ;;
  esac
  while IFS='|' read -r lv tx; do [ -n "$lv" ] && dc_res "$lv" "$tx"; done < <(awk '$1 ~ /^[0-9]+$/ && NF >= 10 {
      if ($6 + 0 > 0 && $4 + 0 <= $6 + 0) print "crit|SMART " $1 " " $2 ": value " $4 + 0 " has reached the threshold " $6 + 0
      else if ($9 != "-") print "warn|SMART " $1 " " $2 ": was at the threshold before (" $9 ")" }' "$f")
  # Counters that are 0 on a healthy SSD
  for v in "5:reallocated sectors:warn" "179:used reserve blocks:warn" "181:program errors:warn" \
           "182:erase errors:warn" "183:runtime bad blocks:warn" "187:uncorrectable read errors:warn" \
           "197:pending (unreadable) sectors:crit" "198:uncorrectable sectors:crit" \
           "199:transfer errors (CRC, cable/adapter - is the value rising?):hint"; do
    local id=${v%%:*} rest=${v#*:}; local txt=${rest%:*} lv=${rest##*:} x
    x=$(dc_attr "$f" "$id")
    [ "${x:-0}" -gt 0 ] 2>/dev/null && dc_res "$lv" "SMART $id: $x $txt"
  done
  if [ "$DC_NVME" = 1 ]; then
    x=$(dc_nvme "$f" "Media and Data Integrity Errors"); [ "${x:-0}" -gt 0 ] && dc_res crit "NVMe: $x media/data integrity errors"
    x=$(sed -n 's/^Critical Warning: *//p' "$f" | head -1); [ -n "$x" ] && [ "$x" != 0x00 ] && dc_res crit "NVMe Critical Warning: $x"
  fi
  if grep -q 'No Errors Logged' "$f"; then :
  else
    x=$(sed -n 's/^ATA Error Count: *\([0-9]*\).*/\1/p' "$f" | head -1)
    [ -z "$x" ] && x=$(dc_nvme "$f" "Error Information Log Entries")
    [ "${x:-0}" -gt 0 ] && dc_res hint "Error log: $x entries (often from the previous owner, e.g. after a power failure). Details: $OUT/smart-before-x.txt"
  fi
  x=$(awk '/^# *[0-9]+ / && !/Completed without error|in progress|Aborted by host|Interrupted/ { n++ } END { print n + 0 }' "$f")
  [ "$x" -gt 0 ] && dc_res warn "Earlier self-tests with errors: $x (see smart-before.txt)"

  used=$(wear_used "$DC_DEV" "$(cat "$f")" 0)
  [ -z "$used" ] && [ "$DC_NVME" = 1 ] && used=$(dc_nvme "$f" "Percentage Used")
  poh=$(awk '$1 == 9 && NF >= 10 { print $10 + 0; exit }' "$f"); [ -z "$poh" ] && poh=$(dc_nvme "$f" "Power On Hours")
  pc=$(awk '$1 == 12 && NF >= 10 { print $10 + 0; exit }' "$f"); [ -z "$pc" ] && pc=$(dc_nvme "$f" "Power Cycles")
  por=$(awk '$1 == 235 && $2 ~ /POR/ { print $10 + 0; exit }' "$f"); [ -z "$por" ] && por=$(dc_nvme "$f" "Unsafe Shutdowns")
  wr=$(dc_written "$f")
  DC_USED=$used; DC_POH=$poh; DC_W0=$wr
  dc_info "Power-on hours: ${poh:-?}$([ -n "$poh" ] && echo " (~$(dc_num "$(awk -v h="$poh" 'BEGIN{print h/24/365}')") years)")  Power cycles: ${pc:-?}${por:+  unexpected power losses: $por}"
  [ -n "$wr" ] && dc_info "Written: $(dc_num "$(awk -v b="$wr" 'BEGIN{print b/1e12}')") TB$( [ -n "$poh" ] && [ "$poh" -gt 24 ] && echo " (avg $(awk -v b="$wr" -v h="$poh" 'BEGIN{printf "%.0f", b/1e9/(h/24)}') GB/day)")"
  # Samsung (e.g. SM883/PM883): 251 NAND writes and 241 host writes, both in LBAs
  local nw hw
  nw=$(dc_attr "$f" 251); hw=$(dc_attr "$f" 241)
  if grep -qE '^(Device Model|Model Number): *(SAMSUNG|MZ)' "$f" && [ "${nw:-0}" -gt 0 ] && [ "${hw:-0}" -gt 0 ]; then
    DC_WAF=$(awk -v n="$nw" -v h="$hw" 'BEGIN { printf "%.2f", n / h }')
    dc_info "Write amplification over the lifetime (NAND/host): $(dc_num "$DC_WAF" %.2f)"
  fi
  if [ -z "$used" ]; then dc_res hint "Wear not readable."
  elif [ "$used" -ge 90 ]; then dc_res crit "Wear $used % - the rated endurance is almost reached."
  elif [ "$used" -ge 50 ]; then dc_res warn "Wear $used % - more than half of the rated endurance is used up."
  elif [ "$used" -ge 10 ]; then dc_res hint "Wear $used %."
  else dc_res ok "Wear $used %."
  fi
}

dc_events() { # sampler-file start_epoch: stalls by the service's rules, output "start duration max_ms felt"
  awk -v stall="$DC_STALL" -v felt="$DC_FELT" -v ep="$2" '
    function close_ev() { printf "%.0f %.0f %.0f %d\n", ep + s, e - s, (mw > mf ? mw : mf), ((mw >= felt || mf >= felt || e - s >= 2) ? 1 : 0); open = 0 }
    NR == 1 { pt = $1; pr = $2; pw = $3; pwt = $4; pio = $6; pf = $7; pft = $8; next }
    {
      dt = $1 - pt; dr = $2 - pr; dw = $3 - pw; dwt = $4 - pwt; dio = $6 - pio; df = $7 - pf; dft = $8 - pft; inf = $5
      t = $1
      pt = $1; pr = $2; pw = $3; pwt = $4; pio = $6; pf = $7; pft = $8
      if (dt < 0.5) next
      wa = dw ? dwt / dw : 0; fa = df ? dft / df : 0; util = dio / (dt * 10); if (util > 100) util = 100
      slow = (dw && wa >= stall) || (df && fa >= stall) || (util >= 90 && inf > 0 && dr + dw + df == 0)
      if (slow) {
        if (!open) { open = 1; s = t - 1; mw = 0; mf = 0 }
        e = t; if (wa > mw) mw = wa; if (fa > mf) mf = fa
      } else if (open && t - e >= 3) close_ev()
    }
    END { if (open) close_ev() }' "$1"
}

dc_realistic() { # seconds
  local rt=$1 job="$OUT/sustained.fio" ep n nf
  cat > "$job" <<JOB
[global]
filename=$DC_DEV
direct=1
time_based
runtime=$rt
randrepeat=0
# like a server with databases: small sync writes (each with a flush), plus a video stream and reads
[sync]
rw=randwrite
bs=4k
ioengine=psync
sync=1
rate_iops=16
size=2g
write_lat_log=$OUT/sustained
[stream]
rw=write
bs=128k
ioengine=psync
rate=1m
offset=10%
size=20%
[reads]
rw=randread
bs=4k
ioengine=psync
rate_iops=50
norandommap
JOB
  DC_STOP="$OUT/.stop"; rm -f "$DC_STOP"
  ep=$(awk -v now="$(date +%s.%N)" '{ printf "%.3f", now - $1 }' /proc/uptime)   # epoch at uptime 0
  dc_sampler "$OUT/sustained-diskstats.txt" &
  local sp=$!
  ( i=0; while [ ! -e "$DC_STOP" ] && [ $i -lt "$rt" ]; do sleep 10; i=$((i + 10)); [ $((i % 600)) -eq 0 ] && [ $i -lt "$rt" ] && printf '      [%d min] sustained load running, %d min left\n' $((i / 60)) $(( (rt - i) / 60 )); done ) &
  local tp=$!
  fio --minimal "$job" > "$OUT/sustained.terse" 2> "$OUT/sustained.err"
  touch "$DC_STOP"; wait "$sp" "$tp" 2>/dev/null; DC_STOP=""

  dc_events "$OUT/sustained-diskstats.txt" "$ep" > "$OUT/sustained-stalls.txt"
  n=$(wc -l < "$OUT/sustained-stalls.txt"); nf=$(awk '$4 == 1' "$OUT/sustained-stalls.txt" | wc -l)
  DC_EV=$n; DC_EVF=$nf
  # Wait time of every single sync write (what a program notices)
  local lat="$OUT/sustained_clat.1.log" st
  [ -f "$lat" ] || lat="$OUT/sustained_lat.1.log"
  st=$(awk -F', *' -v stall="$DC_STALL" -v felt="$DC_FELT" '{ v = $2 / 1e6; n++; if (v > mx) mx = v; if (v >= stall) a++; if (v >= felt) b++ }
       END { printf "%d %.1f %d %d\n", n, mx, a, b }' "$lat" 2>/dev/null)
  read -r DC_SN DC_SMAX DC_SSLOW DC_SFELT <<<"${st:-0 0 0 0}"
  dc_info "Sync writes: ${DC_SN} (16/s), longest wait $(dc_num "$DC_SMAX" %.0f) ms, >= $DC_STALL ms: $DC_SSLOW, >= $(dc_num "$(awk -v f=$DC_FELT 'BEGIN{print f/1000}')" %.0f) s: $DC_SFELT"
  if [ "$n" -gt 0 ]; then
    dc_info "Stalls (device, same rules as the service): $n, noticeable $nf"
    awk '{ c = "date -d @" $1 " +%H:%M:%S"; c | getline ts; close(c)
           printf "        %s  %3d s  max %6.0f ms%s\n", ts, $2, $3, ($4 ? "  noticeable" : "") }' "$OUT/sustained-stalls.txt" | head -25
  fi
  if [ "$nf" -ge 3 ]; then
    local md mg
    md=$(awk '$4 == 1 { print $2 }' "$OUT/sustained-stalls.txt" | sort -n | awk '{ a[NR] = $1 } END { print a[int((NR + 1) / 2)] }')
    mg=$(awk '$4 == 1 { if (p) print ($1 - p) / 60; p = $1 }' "$OUT/sustained-stalls.txt" | sort -n | awk '{ a[NR] = $1 } END { print a[int((NR + 1) / 2)] }')
    dc_info "Pattern: duration median $md s, interval median $(dc_num "$mg") min"
  fi
  if [ "$nf" -gt 0 ] || [ "${DC_SFELT:-0}" -gt 0 ]; then
    dc_res crit "Noticeable stalls under sustained load: $nf (longest wait $(dc_num "$DC_SMAX" %.0f) ms) - exactly the behavior that is to be replaced."
  elif [ "$n" -gt 0 ] || [ "${DC_SSLOW:-0}" -gt 0 ]; then
    dc_res hint "Short delays under sustained load, not noticeable: $n stalls on the device, $DC_SSLOW writes >= $DC_STALL ms, longest wait $(dc_num "$DC_SMAX" %.0f) ms."
  else
    dc_res ok "No stalls in $((rt / 60)) min of sustained load, longest wait $(dc_num "$DC_SMAX" %.0f) ms."
  fi
}

disk_check() {
  local dev d real t busy p rot bytes model serial fw sata lss ext force est rt ans
  [ "$(id -u)" -eq 0 ] || { echo "Please run as root (sudo)." >&2; exit 1; }
  for t in fio smartctl blkdiscard lsblk; do
    command -v $t >/dev/null 2>&1 && continue
    echo "$t is missing: apt install $(case $t in smartctl) echo smartmontools ;; fio) echo fio ;; *) echo util-linux ;; esac)" >&2; exit 1
  done
  [ -n "$1" ] || { echo "Usage: $0 --check-disk /dev/sdX [-r SEC] [-o DIR]" >&2; exit 1; }
  dev=$(readlink -f "$1"); d=${dev##*/}
  if [ ! -b "$dev" ] || [ ! -d "/sys/block/$d" ]; then
    echo "$1 is not a whole drive. Please give the drive, not a partition (e.g. /dev/sdf instead of /dev/sdf1)." >&2; exit 1
  fi
  busy=$(lsblk -nrpo NAME,MOUNTPOINT "$dev" 2>/dev/null | awk 'NF > 1 { print "mounted: " $1 " on " $2 }')
  for p in "/sys/block/$d"/holders/* "/sys/block/$d/$d"*/holders/*; do
    [ -e "$p" ] && busy+=$'\n'"used by ${p##*/} (RAID/LVM/dm)"
  done
  grep -q "^$dev" /proc/swaps 2>/dev/null && busy+=$'\n'"active as swap"
  if [ -n "${busy//$'\n'/}" ]; then
    echo "$dev is in use - aborting:" >&2; sed '/^$/d; s/^/  /' <<<"$busy" >&2; exit 1
  fi

  DC_DEV=$dev; DC_NAME=$d; DC_SMOPT=(); DC_NVME=0; DC_USB=0
  [[ $d == nvme* ]] && DC_NVME=1
  real=$(readlink -f "/sys/block/$d/device" 2>/dev/null)
  [[ $real == */usb* ]] && DC_USB=1
  if ! smartctl -i "$dev" 2>/dev/null | grep -qiE '^SMART support is: *Enabled|^SMART/Health Information' &&
     smartctl -d sat -i "$dev" 2>/dev/null | grep -qi '^SMART support is: *Enabled'; then DC_SMOPT=(-d sat); fi

  OUT="$OUTBASE/ssdcheck-$d-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$OUT" || exit 1
  exec > >(trap '' INT; exec tee -ai "$OUT/report.txt") 2>&1
  local teep=$!
  trap 'DC_ABORT=1; [ -n "$DC_STOP" ] && touch "$DC_STOP"' INT TERM

  echo "write-latency-diag $VERSION - SSD check - $(date '+%F %T') - output: $OUT"
  for m in "${UPDATE_MSGS[@]}"; do echo "  $m"; done
  dc_snap before
  local sm="$OUT/smart-before.txt"
  model=$(sed -n 's/^\(Device Model\|Model Number\|Product\): *//p' "$sm" | head -1)
  [ -z "$model" ] && model=$(sed 's/ *$//' "/sys/block/$d/device/model" 2>/dev/null)
  serial=$(sed -n 's/^Serial [Nn]umber: *//p' "$sm" | head -1)
  fw=$(sed -n 's/^Firmware Version: *//p' "$sm" | head -1)
  sata=$(sed -n 's/^SATA Version is: *//p' "$sm" | head -1)
  lss=$(sed -n 's/^Sector Sizes\{0,1\}: *\([0-9]*\) bytes logical, \([0-9]*\) bytes physical.*/\1 logical \/ \2 physical/p; s/^Sector Sizes\{0,1\}: *\([0-9]*\) bytes logical\/physical.*/\1 logical and physical/p' "$sm" | head -1)
  bytes=$(( $(cat "/sys/block/$d/size") * 512 ))
  rot=$(cat "/sys/block/$d/queue/rotational" 2>/dev/null)
  if grep -q '^Rotation Rate: *Solid State' "$sm"; then rot=0
  elif grep -qE '^Rotation Rate: *[0-9]+ rpm' "$sm"; then rot=1
  elif [ "$DC_NVME" = 1 ]; then rot=0; fi
  # USB adapters often report SSDs as rotational: abort there only if SMART reports a rotation rate
  if [ "$rot" = 1 ] && [ -z "${WLAT_TEST_ALL_SSD:-}" ] && { [ $DC_USB -eq 0 ] || grep -qE '^Rotation Rate: *[0-9]+ rpm' "$sm"; }; then
    echo "$dev is an HDD (${model:-model unknown}) - this check is meant for SSDs. Aborting."; rm -rf "$OUT"; exit 1
  fi

  dc_section "Drive"
  dc_info "Device:     $dev  ${model:-?}  SN ${serial:-?}  FW ${fw:-?}"
  dc_info "Size:       $(dc_num "$(awk -v b=$bytes 'BEGIN{print b/1e9}')") GB ($(dc_num "$(awk -v b=$bytes 'BEGIN{print b/2^30}')") GiB)${lss:+, sectors $lss}"
  dc_info "Interface:  ${sata:-?}$([ $DC_USB -eq 1 ] && echo "  - via USB adapter")${DC_SMOPT[*]:+  (SMART via ${DC_SMOPT[*]})}"
  lsblk -no NAME,SIZE,FSTYPE,LABEL "$dev" 2>/dev/null | sed 's/^/      Content:    /'
  if [ $DC_USB -eq 1 ]; then
    dc_res hint "Attached via USB: the adapter adds latency to every request, and some do not pass flush and TRIM on correctly. Stalls and errors are still detected, but the flush latency (PLP) only roughly. Best checked directly on SATA."
  fi
  if grep -q '(current: [1-3]\.[0-9] Gb/s)' <<<"$sata" && ! grep -q '(current: 6.0' <<<"$sata"; then
    dc_res hint "SATA link is not running at 6 Gb/s: $sata - check cable/port."
  fi

  ext=$(dc_smart -c 2>/dev/null | awk '/Extended self-test routine/ { f = 1 } f && /polling time/ { gsub(/[^0-9]/, " "); split($0, a, " "); print a[1] + 0; exit }')
  [ -n "$rt" ] || rt=3600; [ "$R_SET" = 1 ] && rt=$TEST_RUNTIME
  est=$(awk -v b=$bytes -v rt="$rt" -v e="${ext:-0}" 'BEGIN { printf "%.0f", 6 + b / 450e6 / 60 + b / 500e6 / 60 + 3 + rt / 60 + e }')
  echo
  echo "  Steps (about $((est / 60)) h $((est % 60)) min in total):"
  echo "    1. SMART values and short self-test              5. Performance when full (4k, 30 s each)"
  echo "    2. trim the whole drive (TRIM)                   6. Sustained load as in production ($((rt / 60)) min), stall detection"
  echo "    3. Flush latency: does power loss protection     7. Long self-test${ext:+ (~$ext min)}"
  echo "       work?                                         8. SMART comparison before/after, trim the drive again"
  echo "    4. Write the whole SSD and read it back with checksums ($(awk -v b=$bytes 'BEGIN{printf "%.0f", b/1e9}') GB, sustained write rate)"
  echo
  echo "  CAUTION: All data on $dev ($model, SN $serial) will be erased."
  if [ -n "${WLAT_CONFIRM_DEV:-}" ]; then ans=$WLAT_CONFIRM_DEV
  else printf '  Type the device name to confirm (%s): ' "$d"; read -r ans; fi
  if [ "$ans" != "$d" ]; then echo "  Cancelled, nothing changed."; exec >&- 2>&-; wait "$teep" 2>/dev/null; rm -rf "$OUT"; exit 1; fi

  local dm0 ds0 t_start
  dm0=$(dmesg 2>/dev/null | wc -l); read -r _ ds0 < <(dc_ds); t_start=$(date +%s)

  dc_section "1. SMART before"
  dc_smart_eval "$sm"
  dc_selftest short 15

  if [ $DC_ABORT -eq 0 ]; then
    dc_section "2. TRIM over the whole drive"
    force=""; blkdiscard --help 2>&1 | grep -q -- '--force' && force=-f
    if blkdiscard $force "$dev" 2> "$OUT/trim.err"; then dc_res ok "Whole drive trimmed - the SSD starts without leftovers."
    else dc_res hint "TRIM not possible ($(head -1 "$OUT/trim.err")) - common with USB adapters. The check continues anyway."; fi
  fi

  if [ $DC_ABORT -eq 0 ]; then
    dc_section "3. Flush latency (4k writes with O_SYNC, QD1, 60 s)"
    local wc r iops mbs mean p50 p99 p999 mx err
    wc=$(cat "/sys/block/$d/queue/write_cache" 2>/dev/null)
    fio --name=flush --filename="$dev" --rw=randwrite --bs=4k --ioengine=psync --direct=1 --sync=1 --size=1g \
        --runtime=60 --time_based --randrepeat=0 --minimal > "$OUT/flush.terse" 2> "$OUT/flush.err"
    read -r iops mbs mean p50 p99 p999 mx err < <(dc_terse "$OUT/flush.terse" w)
    DC_FP50=$p50; DC_FIOPS=$iops
    dc_info "$(dc_num "${iops:-0}" %.0f) writes/s, wait median $(dc_num "${p50:-0}" %.3f) ms, p99 $(dc_num "${p99:-0}" %.3f) ms, p99.9 $(dc_num "${p999:-0}" %.3f) ms, max $(dc_num "${mx:-0}" %.1f) ms"
    dc_info "Write cache according to the kernel: ${wc:-?}$([ "$wc" = "write through" ] && echo " - the kernel sends no flushes, only the write itself is measured")"
    if [ -z "$p50" ]; then dc_res warn "Flush test returned no result - see $OUT/flush.err"
    elif awk -v x="$p50" 'BEGIN { exit !(x < 0.5) }'; then dc_res ok "Flush is acknowledged immediately (median $(dc_num "$p50" %.2f) ms) - power loss protection works."
    elif awk -v x="$p50" 'BEGIN { exit !(x < 2) }'; then dc_res hint "Flush takes median $(dc_num "$p50" %.2f) ms - slower than usual for SSDs with PLP (< 0.5 ms)$([ $DC_USB -eq 1 ] && echo ", part of it is the USB adapter")."
    else dc_res "$([ $DC_USB -eq 1 ] && echo warn || echo crit)" "Flush takes median $(dc_num "$p50" %.1f) ms - this is how an SSD without effective power loss protection behaves."; fi
    awk -v x="${mx:-0}" -v s=$DC_STALL 'BEGIN { exit !(x >= s) }' && dc_res warn "A single write waited $(dc_num "$mx" %.0f) ms."
  fi

  if [ $DC_ABORT -eq 0 ]; then
    dc_section "4. Write the whole SSD and read it back with checksums"
    DC_TICK="$OUT/.tick"; rm -f "$DC_TICK"
    dc_ticker "Full write" "$bytes" 300 &
    local tk=$!
    fio --name=full --filename="$dev" --rw=write --bs=1M --ioengine=libaio --iodepth=16 --direct=1 --size=100% \
        --verify=crc32c --verify_state_save=0 --write_bw_log="$OUT/fullwrite" --log_avg_msec=1000 --minimal \
        > "$OUT/fullwrite.terse" 2> "$OUT/fullwrite.err"
    touch "$DC_TICK"; wait "$tk" 2>/dev/null
    local wr rr verr bw
    read -r _ wr _ _ _ _ _ err < <(dc_terse "$OUT/fullwrite.terse" w)
    read -r _ rr _ < <(dc_terse "$OUT/fullwrite.terse" r)
    verr=$(grep -ciE 'verify|bad magic|crc32c' "$OUT/fullwrite.err")
    bw=$(ls "$OUT"/fullwrite_bw*.log 2>/dev/null | head -1)
    if [ -n "$bw" ]; then
      read -r DC_WMED DC_WMIN DC_WDEC < <(awk -F', *' '$3 == 1 { n++; v[n] = $2 * 1024 / 1e6 }
        END {
          if (n < 1) exit
          for (i = 1; i <= n; i++) { c[i] = v[i]; d = int((i - 1) * 10 / n) + 1; s[d] += v[i]; k[d]++ }
          for (i = 2; i <= n; i++) { x = c[i]; j = i - 1; while (j > 0 && c[j] > x) { c[j + 1] = c[j]; j-- } c[j + 1] = x }
          mn = -1; for (i = 4; i <= n - 3; i++) if (mn < 0 || v[i] < mn) mn = v[i]
          if (mn < 0) mn = c[1]
          dec = ""; for (d = 1; d <= 10; d++) dec = dec (d > 1 ? "/" : "") (k[d] ? sprintf("%.0f", s[d] / k[d]) : "-")
          printf "%.0f %.0f %s\n", c[int((n + 1) / 2)], mn, dec }' "$bw")
    fi
    dc_info "Write: median ${DC_WMED:-?} MB/s, slowest second ${DC_WMIN:-?} MB/s, read (verify): $(dc_num "${rr:-0}" %.0f) MB/s"
    [ -n "$DC_WDEC" ] && dc_info "Write rate per 10 % of the drive (MB/s): $DC_WDEC"
    if [ $DC_ABORT -eq 1 ]; then dc_info "aborted"
    elif [ "${verr:-0}" -gt 0 ] || [ "${err:-0}" != 0 ]; then dc_res crit "Errors while writing/verifying (fio error ${err:-?}, checksum errors: $verr) - see $OUT/fullwrite.err"
    else dc_res ok "Whole drive written and read back without errors."; fi
    if [ -n "$DC_WMED" ] && [ "$DC_WMED" -gt 0 ] && [ $(( DC_WMIN * 100 / DC_WMED )) -lt 30 ]; then
      dc_res hint "Write rate drops at times to ${DC_WMIN} MB/s (median ${DC_WMED} MB/s) - typical for a full SLC cache, unusual for MLC SSDs with PLP."
    fi
  fi

  if [ $DC_ABORT -eq 0 ]; then
    dc_section "5. Performance when full (4k, 30 s each)"
    local spec name rw qd eng dir
    for spec in "Read-QD32:randread:32:libaio:r" "Write-QD32:randwrite:32:libaio:w" "Read-QD1:randread:1:psync:r"; do
      [ $DC_ABORT -eq 1 ] && break
      IFS=: read -r name rw qd eng dir <<<"$spec"
      fio --name="$name" --filename="$dev" --rw="$rw" --bs=4k --ioengine="$eng" --iodepth="$qd" --direct=1 --size=100% \
          --runtime=30 --time_based --norandommap --randrepeat=0 --minimal > "$OUT/perf-$name.terse" 2>> "$OUT/perf.err"
      read -r iops _ mean _ p99 _ mx _ < <(dc_terse "$OUT/perf-$name.terse" "$dir")
      [ "$name" = Write-QD32 ] && DC_WIOPS=$iops
      dc_info "$(printf '%-15s' "$name") $(printf '%7s' "$(dc_num "${iops:-0}" %.0f)") IOPS, avg $(dc_num "${mean:-0}" %.2f) ms, p99 $(dc_num "${p99:-0}" %.2f) ms, max $(dc_num "${mx:-0}" %.1f) ms"
    done
  fi

  if [ $DC_ABORT -eq 0 ]; then
    dc_section "6. Sustained load as in production ($((rt / 60)) min): 16 sync writes/s, 1 MB/s stream, 50 reads/s"
    dc_info "The SSD is now completely written and untrimmed - harder than in production."
    dc_realistic "$rt"
  fi

  [ $DC_ABORT -eq 0 ] && { dc_section "7. Long self-test"; dc_selftest long $(( ${ext:-60} * 3 + 30 )); }

  dc_section "8. SMART after"
  dc_snap after
  local sm2="$OUT/smart-after.txt" id a b w1 ds1 dw
  for id in 5 179 181 182 183 187 196 197 198 199; do
    a=$(dc_attr "$sm" $id); b=$(dc_attr "$sm2" $id)
    [ -n "$a" ] && [ -n "$b" ] && [ "$b" -gt "$a" ] || continue
    if [ $id = 199 ]; then dc_res warn "SMART 199 (transfer errors) rose during the check: $a -> $b - check cable/adapter."
    else dc_res crit "SMART $id $(awk -v id=$id '$1 == id { print $2; exit }' "$sm2") rose during the check: $a -> $b"; fi
  done
  h=$(sed -n 's/^SMART overall-health self-assessment test result: *//p' "$sm2" | head -1)
  [ -n "$h" ] && [ "$h" != PASSED ] && dc_res crit "SMART overall health after: $h"
  local kmsg
  local pat=$d port; port=$(grep -o 'ata[0-9]*' <<<"$real" | head -1); [ -n "$port" ] && pat="$d|$port"
  kmsg=$(dmesg 2>/dev/null | tail -n +$((dm0 + 1)) | grep -wE "$pat" | grep -iE 'error|fail|timeout|reset' | head -5)
  [ -n "$kmsg" ] && dc_res crit "Kernel reports errors on the drive during the check: $(head -1 <<<"$kmsg")" && sed 's/^/        /' <<<"$kmsg"
  w1=$(dc_written "$sm2"); read -r _ ds1 < <(dc_ds); dw=$(( (ds1 - ds0) * 512 ))
  if [ -n "$DC_W0" ] && [ -n "$w1" ] && [ "$dw" -gt 1000000000 ]; then
    local ratio; ratio=$(awk -v a="$DC_W0" -v b="$w1" -v d="$dw" 'BEGIN { printf "%.0f", 100 * (b - a) / d }')
    dc_info "Write counter: kernel $(dc_num "$(awk -v x=$dw 'BEGIN{print x/1e9}')" %.0f) GB, SSD +$(dc_num "$(awk -v a="$DC_W0" -v b="$w1" 'BEGIN{print (b-a)/1e9}')" %.0f) GB ($ratio %)"
    if [ "$ratio" -lt 80 ] || [ "$ratio" -gt 125 ]; then dc_res hint "The SSD's write counter does not match the amount written - read its SMART values (wear, data written) with caution."
    else dc_res ok "The SSD's write counter matches the amount written."; fi
  fi
  if [ -n "$DC_WAF" ]; then
    local n1 n2 h1 h2
    n1=$(dc_attr "$sm" 251); n2=$(dc_attr "$sm2" 251); h1=$(dc_attr "$sm" 241); h2=$(dc_attr "$sm2" 241)
    if [ -n "$n2" ] && [ -n "$h2" ] && [ $(( h2 - h1 )) -gt 2000000 ]; then
      DC_WAFT=$(awk -v n=$(( n2 - n1 )) -v h=$(( h2 - h1 )) 'BEGIN { printf "%.2f", n / h }')
      dc_info "Write amplification during the check (NAND/host): $(dc_num "$DC_WAFT" %.2f)"
      if awk -v x="$DC_WAFT" 'BEGIN { exit !(x >= 3) }'; then
        dc_res hint "High write amplification during the check ($(dc_num "$DC_WAFT" %.1f)) - values around 1 are usual for an SSD with PLP."
      fi
    fi
  fi
  if [ $DC_ABORT -eq 0 ]; then
    blkdiscard $force "$dev" 2>/dev/null && dc_info "Drive trimmed again - the SSD is empty and ready to be installed."
  fi

  dc_section "Result"
  local nc=0 nw=0 x verdict
  for x in "${DC_RES[@]}"; do case ${x%%|*} in crit) nc=$((nc + 1)) ;; warn) nw=$((nw + 1)) ;; esac; done
  if [ $DC_ABORT -eq 1 ]; then verdict="ABORTED (result incomplete)"
  elif [ $nc -gt 0 ]; then verdict="FAILED"
  elif [ $nw -gt 0 ]; then verdict="PASSED WITH FINDINGS"
  else verdict="PASSED"; fi
  echo "  $verdict"
  for x in "${DC_RES[@]}"; do
    case ${x%%|*} in crit) echo "   - [CRITICAL] ${x#*|}" ;; warn) echo "   - [!] ${x#*|}" ;; hint) echo "   - [?] ${x#*|}" ;; esac
  done
  local line
  line="$(date '+%F %H:%M')  $d  ${model:-?}  SN ${serial:-?}  FW ${fw:-?}  wear ${DC_USED:-?} %  ${DC_POH:-?} h  $( [ -n "$DC_W0" ] && echo "$(dc_num "$(awk -v b="$DC_W0" 'BEGIN{print b/1e12}')") TB written  ")$([ -n "$DC_WAF" ] && echo "WAF $(dc_num "$DC_WAF" %.2f)${DC_WAFT:+ (check $(dc_num "$DC_WAFT" %.2f))}  ")flush $([ -n "$DC_FP50" ] && dc_num "$DC_FP50" %.2f || echo ?) ms  4k write QD32 $([ -n "$DC_WIOPS" ] && dc_num "$DC_WIOPS" %.0f || echo ?) IOPS  write ${DC_WMED:-?} MB/s (min ${DC_WMIN:-?})  stalls ${DC_EV:-?}/noticeable ${DC_EVF:-?}  => $verdict"
  echo
  echo "  Summary: $line"
  echo "$line" >> "$OUTBASE/ssdcheck-summary.txt"
  echo "  Report: $OUT/report.txt   All summaries: $OUTBASE/ssdcheck-summary.txt   Duration: $(( ($(date +%s) - t_start) / 60 )) min"
  exec >&- 2>&-
  wait "$teep" 2>/dev/null
  [ $nc -gt 0 ] && exit 2
  exit 0
}

if [ $AUTO_UPDATE -eq 1 ] && [ -z "${WLAT_NO_UPDATE:-}" ]; then
  self_update
  cmk_update
  service_update
fi
[ "$ACTION" = install ] && service_install
[ "$ACTION" = uninstall ] && service_uninstall
[ "$ACTION" = check ] && disk_check "$CHECK_DEV"
[ -n "${WLAT_UPDATE_MSG:-}" ] && UPDATE_MSGS=("$WLAT_UPDATE_MSG" "${UPDATE_MSGS[@]}")

if [ -z "$PASSIVE" ]; then
  if [ ${#TARGETS[@]} -eq 0 ]; then PASSIVE=60; else PASSIVE=0; fi
fi
if [ -n "$SEQ_SIZE" ] && [ ${#TARGETS[@]} -eq 0 ]; then
  echo "-S needs at least one -t DIR" >&2
  exit 1
fi

for t in "${TARGETS[@]}"; do
  mkdir -p "$t" 2>/dev/null
  if ! touch "$t/.wlat-probe" 2>/dev/null; then
    echo "Cannot write to '$t'." >&2
    exit 1
  fi
  rm -f "$t/.wlat-probe"
done

HAVE_FIO=0
command -v fio >/dev/null 2>&1 && [ -z "${NO_FIO:-}" ] && HAVE_FIO=1
HAVE_BT=0
# Rotational drives (HDDs): 5-20 ms per request and flush are normal there, they do not count as an SSD finding
ROTDEVS=$(for p in /sys/block/*; do [ "$(cat "$p/queue/rotational" 2>/dev/null)" = 1 ] && printf '%s ' "${p##*/}"; done)
[ -n "${WLAT_TEST_ALL_SSD:-}" ] && ROTDEVS=""   # only for tests in VMs whose disks count as rotational
[ $TRACE -eq 1 ] && [ "$(id -u)" -eq 0 ] && command -v bpftrace >/dev/null 2>&1 && HAVE_BT=1
HZ=$(getconf CLK_TCK 2>/dev/null || echo 100)

OUT="$OUTBASE/wlat-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT" || exit 1
CSV="$OUT/samples.csv"
exec > >(trap '' INT; exec tee -ai "$OUT/report.txt") 2>&1
TEE_PID=$!

ABORT=0
CUR_STOP=""
CUR_FILE=""
on_int() {
  ABORT=1
  [ -n "$CUR_STOP" ] && touch "$CUR_STOP"
}
trap on_int INT TERM

WARN=()
section() { printf '\n=== %s ===\n' "$*"; }
info()    { printf '      %s\n' "$*"; }
ok()      { printf '  [ok] %s\n' "$*"; }
warn()    { printf '  [!]  %s\n' "$*"; WARN+=("$*"); }
hint()    { printf '  [?]  %s\n' "$*"; WARN+=("(check) $*"); }

declare -A ROLE
SYSBLOCK=${WLAT_TEST_SYSBLOCK:-/sys/block}   # only for tests of the RAID/boot checks in VMs without md
declare -A DEVPOH        # power-on hours per drive (SMART), for checking the RAID10 mirror groups
MDMEMBERS=""          # physical drives in mdadm arrays (for the analysis)

# The SMART counters cover the whole lifetime. Every run saves them so that the
# next run shows the write amplification since the last data point (current state).
waf_history() { # dev serial num den host_gib nand_in_gib(0/1)
  local f="$STATE_DIR/smart-history.csv" now prev
  WH_RATE=""   # NAND writes per day since the reference point (same unit as num), for the wear forecast
  [ -n "$2" ] || return
  now=$(date +%s)
  # preferably a data point >= 12 h old, otherwise >= 1 h
  [ -r "$f" ] && prev=$(awk -F, -v s="$2" -v now="$now" '$2 == s {
      if (now - $1 >= 43200) l12 = $0; else if (now - $1 >= 3600) l1 = $0 }
      END { print (l12 != "" ? l12 : l1) }' "$f")
  if [ -n "$prev" ]; then
    awk -F, -v now="$now" -v num="$3" -v den="$4" -v host="$5" -v gib="$6" -v l="$prev" 'BEGIN {
      split(l, p, ","); h = (now - p[1]) / 3600
      dn = num - p[3]; dd = den - p[4]; dh = host - p[5]
      c = "date -d @" p[1] " \"+%F %H:%M\""; c | getline ts; close(c)
      printf "      Since %s (%.0f h): host +%.0f GiB", ts, h, dh
      if (gib) printf ", NAND +%.0f GiB", dn
      if (dd > 0) printf "  =>  WAF in this period %.1f", dn / dd
      printf "   (host %.0f GiB/day)\n", dh * 24 / h
      exit (dd > 0 && dn >= 5 * dd) ? 3 : 0 }'
    [ $? -eq 3 ] && warn "$1: high write amplification also currently (since the last data point) - the cause persists."
    WH_RATE=$(awk -F, -v now="$now" -v num="$3" -v l="$prev" 'BEGIN { split(l, p, ","); d = (now - p[1]) / 86400; if (d > 0 && num > p[3]) printf "%.6f", (num - p[3]) / d }')
  else
    info "History: data point saved ($f). The next run (at the earliest in 1 h, meaningful from ~12 h) shows the current WAF."
  fi
  mkdir -p "$STATE_DIR" 2>/dev/null && printf '%s,%s,%s,%s,%s\n' "$now" "$2" "$3" "$4" "$5" >> "$f"
}

# Remaining lifetime: at x % wear after num NAND units, the budget lasts for num*(100-x)/x more.
# "Average so far" uses the whole lifetime, "current rate" the NAND rate since the last data point.
wear_forecast() { # dev used% poh num rate_per_day
  [ -n "$2" ] || return
  awk -v u="$2" -v poh="${3:-0}" -v num="${4:-0}" -v r="${5:-0}" '
    function fmt(d) { return d >= 730 ? sprintf("~%.1f years", d / 365) : d >= 60 ? sprintf("~%.0f months", d / 30.4) : sprintf("~%.0f days", d) }
    BEGIN {
      if (u <= 0) { print "      Wear: 0 % (practically new)"; exit }
      if (u >= 100) { print "      Wear: " u " % - rated endurance reached"; exit 3 }
      printf "      Wear: %d %% - remaining lifetime", u
      lt = (poh > 24) ? (100 - u) / u * poh / 24 : -1
      cur = (r > 0 && num > 0) ? num * (100 - u) / u / r : -1
      if (lt >= 0) printf " at the average so far %s", fmt(lt)
      if (cur >= 0) printf "%s at the current rate %s", (lt >= 0 ? "," : ""), fmt(cur)
      if (lt < 0 && cur < 0) printf " unknown"
      print ""
      d = (cur >= 0) ? cur : lt
      exit (d >= 0 && d < 365) ? 3 : (d >= 0 && d < 730) ? 4 : 0 }'
  case $? in
    3) warn "$1: At this rate the SSD reaches the end of its rated endurance in less than a year - plan a replacement." ;;
    4) hint "$1: At this rate the SSD reaches the end of its rated endurance in less than two years." ;;
  esac
}

# Interval in days for an OnCalendar expression. systemd shows daily as "*-*-* 00:00:00",
# weekly as "Mon *-*-* 00:00:00" and monthly as "*-*-01 00:00:00". Unknown: empty (then measured).
trim_period() {
  case "$1" in
    *..*|*,*) echo "" ;;
    weekly|Mon*|Tue*|Wed*|Thu*|Fri*|Sat*|Sun*|"") echo 7 ;;
    daily|'*-*-* '*|'*-*-*') echo 1 ;;
    monthly|'*-*-'[0-9]*) echo 30 ;;
    *) echo "" ;;
  esac
}

# Is weekly TRIM enough? ext4 remembers which block groups are already trimmed. Every further
# fstrim run in the same boot therefore reports roughly how much was deleted since the last run
# (rather a bit too much, because whole groups are trimmed again). The first run after a reboot
# releases all free space and does not count. On XFS/btrfs the number is not meaningful.
# Until the next TRIM, deleted data behaves like used space for the SSD. Consumer SSDs have only
# ~7 % spare area: if more than ~2 % of the capacity accumulates, daily TRIM pays off.
trim_advice() { # OnCalendar value of fstrim.timer
  command -v journalctl >/dev/null 2>&1 || return
  local mnt src size rota res period
  while read -r src mnt; do
    rota=$(lsblk -ndo ROTA "$src" 2>/dev/null | tr -d ' ')
    [ "$rota" = 0 ] || continue
    size=$(df -B1 --output=size "$mnt" 2>/dev/null | tail -1 | tr -d ' ')
    period=$(trim_period "$1")
    res=$(journalctl -u fstrim.service -o json --no-pager -q -n 1000 2>/dev/null | awk -v m="$mnt" '
      {
        if (!match($0, /"MESSAGE":"[^"]*"/)) next
        msg = substr($0, RSTART + 11, RLENGTH - 12)
        if (index(msg, m ": ") != 1 || msg !~ /bytes\) trimmed/) next
        b = msg; sub(/.*\(/, "", b); sub(/ bytes.*/, "", b)
        match($0, /"__REALTIME_TIMESTAMP":"[0-9]+"/); t = substr($0, RSTART + 24, RLENGTH - 25) / 1e6
        match($0, /"_BOOT_ID":"[^"]*"/); boot = substr($0, RSTART, RLENGTH)
        if (boot == lastboot && t - last > 3600) { n++; R[n] = b / (t - last) * 86400; I[n] = (t - last) / 86400 }
        lastboot = boot; last = t
      }
      END {
        if (n == 0) { print "none"; exit }
        # Median of the last (up to) 5 runs
        k = 0; for (i = (n > 5 ? n - 4 : 1); i <= n; i++) { k++; r[k] = R[i]; d[k] = I[i] }
        for (i = 1; i <= k; i++) for (j = i + 1; j <= k; j++) {
          if (r[j] < r[i]) { x = r[i]; r[i] = r[j]; r[j] = x }
          if (d[j] < d[i]) { x = d[i]; d[i] = d[j]; d[j] = x }
        }
        printf "%.0f %.2f %d\n", r[int((k + 1) / 2)], d[int((k + 1) / 2)], k
      }')
    [ -n "$res" ] || continue
    if [ "$res" = none ]; then
      info "TRIM $mnt: no recommendation possible yet - it needs at least two fstrim runs without a reboot in between."
      continue
    fi
    local rate interval runs
    read -r rate interval runs <<<"$res"
    [ -n "$period" ] || period=$interval
    awk -v m="$mnt" -v rate="$rate" -v p="$period" -v size="${size:-0}" -v runs="$runs" -v cal="${1:-?}" 'BEGIN {
      back = rate * p; pct = size > 0 ? 100 * back / size : 0
      printf "      TRIM %s: avg %.1f GiB/day deleted (from %d fstrim runs) - with schedule \"%s\" up to %.0f GiB (%.1f %% of the capacity) untrimmed\n", m, rate / 2^30, runs, cal, back / 2^30, pct
      exit (p > 1 && pct >= 2) ? 3 : (p <= 1 && rate * 7 < 0.02 * size) ? 4 : (p > 1) ? 5 : 0 }'
    case $? in
      3) hint "TRIM $mnt: Between two TRIM runs a lot of deleted space accumulates that the SSD still considers used (more garbage collection, higher write amplification). Trim daily: systemctl edit fstrim.timer and add [Timer] OnCalendar= and OnCalendar=daily there." ;;
      4) info "TRIM $mnt: Little is deleted - weekly TRIM would be enough here as well." ;;
      5) ok "TRIM $mnt: The schedule is sufficient - little deleted space accumulates until the next run." ;;
    esac
  done < <(awk '$3 == "ext4" && $1 ~ "^/dev/" {print $1, $2}' /proc/mounts | sort -u -k2,2)
}

# ---------------------------------------------------------------------------
# System check
# ---------------------------------------------------------------------------
# RAID10 near layout: show the mirror groups and check whether the two oldest SSDs are in the same group
md_groups() { # /sys/block/mdX level
  local md=$1 lvl=$2 s sl part
  # RAID10 near layout: consecutive slots form mirror groups that always receive the same data
  if [ "$lvl" = raid10 ]; then
    local layout nc ndev groups
    layout=$(cat "$md/md/layout" 2>/dev/null); ndev=$(cat "$md/md/raid_disks" 2>/dev/null)
    nc=$(( ${layout:-0} & 255 ))
    if [ "$nc" -ge 2 ] && [ $(( (${layout:-0} >> 8) & 255 )) -eq 1 ] && [ "${ndev:-0}" -gt 0 ] && [ $((ndev % nc)) -eq 0 ]; then
      local glist oldpair
      glist=$(for s in "$md"/md/dev-*; do
          sl=$(cat "$s/slot" 2>/dev/null); part=${s##*/dev-}
          [[ $sl =~ ^[0-9]+$ ]] || continue
          [ -e "/sys/block/$part" ] || part=$(basename "$(readlink -f "/sys/class/block/$part/..")")
          echo "$((sl / nc)) $part"
        done | sort -n)
      groups=$(awk '{ g[$1] = g[$1] (g[$1] == "" ? "" : "+") $2 } END { for (i = 0; i in g; i++) printf "%s%s", (i ? ", " : ""), g[i] }' <<<"$glist")
      [ -n "$groups" ] && info "${md##*/}: mirror groups (each receives the same writes): $groups"
      # If the two by far oldest SSDs are in the same group, they may fail shortly after each other
      oldpair=$(while read -r g dv; do [ -n "$dv" ] && echo "$g $dv ${DEVPOH[$dv]:-x}"; done <<<"$glist" | awk '
        $3 == "x" { miss = 1 } { g[NR] = $1; p[NR] = $2; h[NR] = $3 + 0 }
        END {
          if (miss || NR < 4) exit
          a = 0; for (i = 1; i <= NR; i++) if (!a || h[i] > h[a]) a = i
          b = 0; for (i = 1; i <= NR; i++) if (i != a && (!b || h[i] > h[b])) b = i
          if (g[a] != g[b]) exit
          mo = 0; for (i = 1; i <= NR; i++) if (i != a && i != b && h[i] > mo) mo = h[i]
          if (h[b] > 2 * mo && h[b] > 8760) printf "%s and %s (%d and %d power-on hours)", p[a], p[b], h[a], h[b] }')
      [ -n "$oldpair" ] && hint "${md##*/}: The two by far oldest SSDs $oldpair form a mirror group. If both fail before one is replaced, the data is gone - spread them across different groups at the next replacement or rebuild."
    fi
  fi
}

# Bitmap, mdadm.conf and spare room at the end of the RAID members
md_extra_checks() { # /sys/block/mdX level
  local md=$1 lvl=$2 s f
  if [[ $lvl =~ ^raid(1|10|4|5|6)$ ]]; then
    # Without a write-intent bitmap the whole array has to be resynchronized after every crash
    if [ "$(cat "$md/md/bitmap/location" 2>/dev/null || echo none)" = none ] && [ "$(cat "$md/size" 2>/dev/null || echo 0)" -gt 200000000 ]; then
      hint "${md##*/}: no write-intent bitmap - after a crash or power failure the whole RAID has to be resynchronized (hours, slows things down meanwhile). Add it while running: mdadm --grow --bitmap=internal /dev/${md##*/}"
    fi
    # If the array is missing from mdadm.conf, the initramfs may assemble it under a different name (md127)
    local mdconf="" uuid
    for f in /etc/mdadm/mdadm.conf /etc/mdadm.conf; do [ -f "$f" ] && { mdconf=$f; break; }; done
    if [ -n "$mdconf" ] && command -v mdadm >/dev/null 2>&1; then
      uuid=$(mdadm --detail --export "/dev/${md##*/}" 2>/dev/null | sed -n 's/^MD_UUID=//p')
      if [ -n "$uuid" ] && ! grep -qi "UUID=$uuid" "$mdconf"; then
        hint "${md##*/} is not listed in $mdconf - at boot it may be assembled under a different name or not at all. Add it: mdadm --detail --scan | grep $uuid >> $mdconf && update-initramfs -u"
      fi
    fi
    # Spare room at the end: a replacement SSD of the same nominal size does not always have as many sectors
    local tight="" part disk free
    for s in "$md"/slaves/*; do
      [ -e "$s" ] || continue
      part=${s##*/}
      if [ -e "/sys/class/block/$part/partition" ]; then
        disk=$(basename "$(readlink -f "/sys/class/block/$part/..")")
        free=$(( $(cat "/sys/block/$disk/size") - $(cat "/sys/class/block/$part/start") - $(cat "/sys/class/block/$part/size") ))
      else
        free=0
      fi
      [ "$free" -lt 1048576 ] && tight="$tight $part"
    done
    [ -n "$tight" ] && info "Tip: The RAID members of ${md##*/} reach up to the end of the drives (${tight# }). A replacement SSD then needs at least as many sectors - the same nominal size is not always enough. Leave about 1 GiB free at the end at the next rebuild."
  fi
}

# ext4 settings (behavior on errors, reserve, RAID alignment) and boot redundancy with RAID as /
fs_boot_check() {
  [ "$(id -u)" -eq 0 ] || return
  section "File system and boot"
  local src mnt fstype opts real tl eb bc rbc bs st sw md lvl chunk nd layout data es ew any=0
  while read -r src mnt fstype opts; do
    [ "$fstype" = ext4 ] || continue
    case "$src" in /dev/loop*|/dev/zram*) continue ;; esac
    tl=$(tune2fs -l "$src" 2>/dev/null) || continue
    any=1
    eb=$(sed -n 's/^Errors behavior: *//p' <<<"$tl")
    bc=$(sed -n 's/^Block count: *//p' <<<"$tl"); rbc=$(sed -n 's/^Reserved block count: *//p' <<<"$tl")
    bs=$(sed -n 's/^Block size: *//p' <<<"$tl")
    st=$(sed -n 's/^RAID stride: *//p' <<<"$tl"); sw=$(sed -n 's/^RAID stripe width: *//p' <<<"$tl")
    info "ext4 $mnt ($src): on errors ${eb:-?}, reserved for root $(awk -v r="${rbc:-0}" -v b="${bc:-1}" -v s="${bs:-4096}" 'BEGIN { printf "%.1f %% (%.0f GiB)", 100 * r / b, r * s / 2^30 }'), RAID stride ${st:-0} / stripe-width ${sw:-0}"
    if [ "$eb" != Continue ] && grep -qE '(^|,)errors=continue(,|$)' <<<"$opts"; then
      hint "ext4 $mnt: The file system is set to '$eb', but it is still mounted with errors=continue (takes effect only at the next mount). Apply now: mount -o remount,errors=remount-ro $mnt"
    elif [ "$eb" = Continue ] && ! grep -qE '(^|,)errors=(remount-ro|panic)' <<<"$opts"; then
      hint "ext4 $mnt: On file system errors ext4 keeps writing ('Continue') - damage can spread unnoticed. Safer: tune2fs -e remount-ro $src (on an error it then only reads)."
    fi
    if awk -v r="${rbc:-0}" -v b="${bc:-1}" -v s="${bs:-4096}" 'BEGIN { exit !(100 * r / b >= 2 && r * s / 2^30 >= 10) }'; then
      info "Tip: ext4 $mnt reserves $(awk -v r="$rbc" -v s="$bs" 'BEGIN { printf "%.0f", r * s / 2^30 }') GiB for root. If the services run as root anyway (e.g. Docker), this protects hardly anything: tune2fs -m 1 $src"
    fi
    # Alignment with software RAID: stride = chunk / block size, stripe-width = stride x data drives
    real=$(readlink -f "$src"); md=${real##*/}
    if [[ $md == md* ]] && [ -f "$SYSBLOCK/$md/md/level" ]; then
      lvl=$(cat "$SYSBLOCK/$md/md/level"); chunk=$(cat "$SYSBLOCK/$md/md/chunk_size" 2>/dev/null); nd=$(cat "$SYSBLOCK/$md/md/raid_disks" 2>/dev/null)
      layout=$(cat "$SYSBLOCK/$md/md/layout" 2>/dev/null); data=""
      case "$lvl" in
        raid0) data=$nd ;;
        raid5) data=$((nd - 1)) ;;
        raid6) data=$((nd - 2)) ;;
        raid10) [ $(( (${layout:-0} >> 8) & 255 )) -eq 1 ] && [ $(( ${layout:-0} & 255 )) -gt 0 ] && data=$(( nd / (${layout:-0} & 255) )) ;;
      esac
      if [ -n "$data" ] && [ "${chunk:-0}" -gt 0 ] && [ "${bs:-0}" -gt 0 ]; then
        es=$((chunk / bs)); ew=$((es * data))
        if [ "${st:-0}" != "$es" ] || [ "${sw:-0}" != "$ew" ]; then
          hint "ext4 $mnt: RAID alignment does not match $md (chunk $((chunk / 1024)) KiB): stride ${st:-0} instead of $es, stripe-width ${sw:-0} instead of $ew$( [ "$lvl" = raid10 ] && echo " - with RAID10 this hardly matters"). Adjust: tune2fs -E stride=$es,stripe_width=$ew $src"
        fi
      fi
    fi
  done < <(awk '$1 ~ "^/dev/" { print $1, $2, $3, $4 }' /proc/mounts | sort -u -k1,1)
  [ $any -eq 0 ] && info "No ext4 file system mounted."
  boot_check "$(findmnt -no SOURCE / 2>/dev/null)" /etc/fstab /var/cache/debconf/config.dat
}

# If / is on a software RAID, the server should also boot without the SSD that holds the mounted EFI partition
boot_check() { # source-of-/ fstab debconf-file
  local real md disks="" d esps="" n=0 ne=0 opts inst missing="" l p pp
  real=$(readlink -f "$1" 2>/dev/null); md=${real##*/}
  [[ $md == md* ]] && [ -d "$SYSBLOCK/$md/slaves" ] || return
  for p in "$SYSBLOCK/$md"/slaves/*; do
    [ -e "$p" ] || continue
    d=${p##*/}; [ -e "/sys/class/block/$d/partition" ] && d=$(basename "$(readlink -f "/sys/class/block/$d/..")")
    disks="$disks $d"; n=$((n + 1))
    # Detect the EFI partition by its GPT type (blkid reads it directly, without udev)
    l=""
    for pp in "/sys/block/$d/$d"*; do
      [ -e "$pp/partition" ] || continue
      [ "$(blkid -p -o value -s PART_ENTRY_TYPE "/dev/${pp##*/}" 2>/dev/null | tr 'A-F' 'a-f')" = c12a7328-f81f-11d2-ba4b-00a0c93ec93b ] && l="$l /dev/${pp##*/}"
    done
    [ -n "$l" ] && { ne=$((ne + 1)); esps="$esps$l"; }
  done
  [ "$n" -gt 1 ] || return
  if findmnt -n /boot/efi >/dev/null 2>&1; then
    info "/ is on $md (${disks# }), EFI partitions on $ne of $n drives"
    [ "$ne" -lt "$n" ] && hint "Only $ne of $n drives of the RAID have an EFI partition. If a drive with an EFI partition fails, the server may not boot. Create one on every drive at the next rebuild (Ubuntu installer: 'Add As Another Boot Device')."
    opts=$(awk '$1 !~ /^#/ && $2 == "/boot/efi" { print $4 }' "$2" 2>/dev/null)
    if [ -n "$opts" ] && ! grep -qE '(^|,)nofail(,|$)' <<<"$opts"; then
      hint "/boot/efi has no 'nofail' in $2. If exactly this drive fails, the server boots into emergency mode instead of normally from the RAID. In $2 replace '$opts' at /boot/efi with '$opts,nofail'."
    fi
    # Ubuntu/Debian: GRUB updates only write to the EFI partitions in grub-efi/install_devices
    if [ -r "$3" ] && grep -q '^Name: grub-efi/install_devices$' "$3"; then
      inst=$(sed -n '/^Name: grub-efi\/install_devices$/,/^$/s/^Value: //p' "$3" | tr -d ',' | while read -ra a; do for l in "${a[@]}"; do readlink -f "$l"; done; done)
      for p in $esps; do grep -qx "$p" <<<"$inst" || missing="$missing ${p#/dev/}"; done
      if [ -n "$missing" ]; then
        hint "GRUB does not keep all EFI partitions up to date on updates (missing:$missing). A drive with an outdated EFI partition may no longer boot after a GRUB update. Add them: dpkg-reconfigure grub-efi-amd64 and select all EFI partitions."
      else
        ok "GRUB keeps all $ne EFI partitions up to date."
      fi
    fi
  fi
}

static_check() {
  local ver=""
  if [ -f /etc/unraid-version ]; then
    ver=$(. /etc/unraid-version 2>/dev/null; echo "Unraid $version")
  elif [ -f /etc/os-release ]; then
    ver=$(. /etc/os-release 2>/dev/null; echo "$PRETTY_NAME")
  fi
  section "System overview"
  info "Host: $(hostname)   Kernel: $(uname -r)   $ver"
  [ "$(id -u)" -ne 0 ] && warn "Not started as root - SMART data and some values are missing."

  # CPU
  local model threads gov drv epp curf maxf
  model=$(awk -F': *' '/^model name/{print $2; exit}' /proc/cpuinfo)
  threads=$(grep -c '^processor' /proc/cpuinfo)
  gov=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "?")
  drv=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver 2>/dev/null || echo "?")
  epp=$(cat /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference 2>/dev/null)
  curf=$(cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq 2>/dev/null | awk '{s+=$1;n++} END{if(n) printf "%.0f", s/n/1000}')
  maxf=$(awk '{printf "%.0f", $1/1000}' /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq 2>/dev/null)
  info "CPU: $model ($threads threads), load: $(cut -d' ' -f1-3 /proc/loadavg)"
  info "Clock: driver $drv, governor $gov${epp:+, EPP $epp}, current avg ${curf:-?} MHz / max ${maxf:-?} MHz"
  case "$gov" in
    powersave)
      case "$drv" in
        intel_pstate|amd-pstate-epp) ;;
        *) warn "Governor 'powersave' with driver $drv keeps the CPU at minimum clock - increases latency." ;;
      esac ;;
    conservative) hint "Governor 'conservative' clocks up sluggishly - short IO bursts run at a low clock." ;;
  esac
  [ "$epp" = "power" ] && hint "EPP=power: the CPU clocks up very reluctantly. Test: echo balance_performance > /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference"

  # Dirty page cache
  local memkb dr db dirty_mb
  memkb=$(awk '/^MemTotal/{print $2}' /proc/meminfo)
  dr=$(cat /proc/sys/vm/dirty_ratio 2>/dev/null)
  db=$(cat /proc/sys/vm/dirty_bytes 2>/dev/null)
  if [ "${db:-0}" -gt 0 ]; then dirty_mb=$((db / 1048576)); else dirty_mb=$((memkb * dr / 100 / 1024)); fi
  info "RAM: $((memkb / 1048576)) GB, vm.dirty_ratio=$dr, dirty_background_ratio=$(cat /proc/sys/vm/dirty_background_ratio) (=> up to ~${dirty_mb} MB of unwritten data)"
  [ "$dirty_mb" -gt 4096 ] && hint "Large dirty buffer (~${dirty_mb} MB): under sustained write load long write congestion occurs when the buffer is full."
  # Swap: the kernel has to read swapped-out program parts back from disk on the next access (page faults)
  local swt swf avail swu swp
  read -r swt swf avail < <(awk '/^SwapTotal/ {t = $2} /^SwapFree/ {f = $2} /^MemAvailable/ {a = $2} END {print t + 0, f + 0, a + 0}' /proc/meminfo)
  swu=$(( (swt - swf) / 1024 )); swp=$(cat /proc/sys/vm/swappiness 2>/dev/null)
  if [ "$swt" -gt 0 ]; then
    info "Swap: $swu MB of $((swt / 1024)) MB used, vm.swappiness=${swp:-?}, available RAM $((avail / 1048576)) GB"
    if [ "$swu" -ge 256 ] && [ $((avail / 1024)) -ge $((swu * 4)) ]; then
      hint "$swu MB are in swap although $((avail / 1048576)) GB of RAM are free. The kernel has to read swapped-out program parts back from disk on the next access (page faults) - if that coincides with an SSD stall, the program waits. Bring them back: swapoff -a && swapon -a$( [ "${swp:-60}" -gt 10 ] && echo ". Swap less often: echo vm.swappiness=10 > /etc/sysctl.d/90-swappiness.conf && sysctl --system")"
    fi
  fi

  # Unraid roles
  if [ -f /var/local/emhttp/disks.ini ]; then
    while read -r dev name typ; do
      [ -n "$dev" ] && ROLE[$dev]="$name/$typ"
    done < <(awk -F'=' '
      /^\[/ { s=$0; gsub(/[\[\]"]/, "", s); next }
      { v=$2; gsub(/"/, "", v) }
      $1=="device" { dev[s]=v } $1=="type" { typ[s]=v }
      END { for (k in dev) if (dev[k] != "") print dev[k], k, typ[k] }' /var/local/emhttp/disks.ini)
    local mwm
    mwm=$(sed -n 's/^md_write_method="\(.*\)"/\1/p' /var/local/emhttp/var.ini 2>/dev/null)
    [ -n "$mwm" ] && info "Unraid md_write_method: $mwm"
  fi

  # Disks
  section "Drives"
  local p d dev rot sched wc disc ata host spd alpm model fw sm trim sata attrs crc realloc role kind wdsd
  for p in /sys/block/*; do
    d=${p##*/}
    [[ $d =~ $DEVRE ]] || continue
    dev=/dev/$d
    [ "$(cat "$p/size" 2>/dev/null)" -gt 0 ] 2>/dev/null || continue
    rot=$(cat "$p/queue/rotational" 2>/dev/null)
    sched=$(sed -n 's/.*\[\(.*\)\].*/\1/p' "$p/queue/scheduler" 2>/dev/null)
    wc=$(cat "$p/queue/write_cache" 2>/dev/null)
    disc=$(cat "$p/queue/discard_max_bytes" 2>/dev/null)
    model=$(cat "$p/device/model" 2>/dev/null | sed 's/ *$//')
    fw=$(cat "$p/device/rev" "$p/device/firmware_rev" 2>/dev/null | head -1 | sed 's/ *$//')
    role=${ROLE[$d]:-}
    local real
    real=$(readlink -f "$p/device" 2>/dev/null)
    kind=$([ "$rot" = 0 ] && echo SSD || echo HDD)
    [[ $real == */usb* ]] && kind="USB"
    sm=""
    if command -v smartctl >/dev/null 2>&1 && [ "$(id -u)" -eq 0 ]; then
      sm=$(smartctl -i -A "$dev" 2>/dev/null)
      local smodel sfw
      smodel=$(sed -n 's/^\(Device Model\|Model Number\): *//p' <<<"$sm" | head -1)
      sfw=$(sed -n 's/^Firmware Version: *//p' <<<"$sm" | head -1)
      [ -n "$smodel" ] && model=$smodel
      # sysfs only provides 4 characters of the firmware version for SATA
      [ -n "$sfw" ] && fw=$sfw
    fi
    printf '\n  %s  %s  (%s GB, %s, FW %s)%s\n' "$d" "${model:-?}" \
      "$(awk '{printf "%.0f", $1*512/1e9}' "$p/size")" "$kind" "${fw:-?}" \
      "${role:+  Unraid: $role}"

    ata=""; host=""; spd=""; alpm=""
    ata=$(grep -o 'ata[0-9]*' <<<"$real" | head -1)
    host=$(grep -o 'host[0-9]*' <<<"$real" | head -1)
    [ -n "$ata" ] && spd=$(cat "/sys/class/ata_link/link${ata#ata}/sata_spd" 2>/dev/null)
    [ -n "$host" ] && alpm=$(cat "/sys/class/scsi_host/$host/link_power_management_policy" 2>/dev/null)
    info "Port: ${ata:-?} ${spd:+Link $spd}  ALPM: ${alpm:-n/a}  Scheduler: ${sched:-?}  Write cache: ${wc:-?}  TRIM: $([ "${disc:-0}" -gt 0 ] && echo yes || echo no)"

    if [ -n "$alpm" ] && [ "$alpm" != "max_performance" ] && [ "$alpm" != "keep_firmware_settings" ]; then
      warn "$d: SATA link power management '$alpm' - the link sleeps between accesses, waking up costs latency (typical after powertop --auto-tune). Test: echo max_performance > /sys/class/scsi_host/$host/link_power_management_policy"
    fi
    if [ "$rot" = 0 ] && [ -n "$spd" ] && [ "$spd" != "6.0 Gbps" ] && [ "$spd" != "<unknown>" ]; then
      warn "$d: SATA link runs at only $spd (expected 6.0 Gbps) - check cable/backplane/port."
    fi
    [ "$rot" = 0 ] && [ "${disc:-0}" -eq 0 ] && hint "$d: device/layer reports no TRIM - without TRIM SSDs get slower under write load."
    [ "$wc" = "write through" ] && [ "$rot" = 0 ] && hint "$d: write cache is 'write through' (off) - much slower writes."
    # According to the ATA standard the write cache switch (SET FEATURES, hdparm -W) is volatile: after power-on
    # the drive's factory setting applies, and some BIOS/UEFI switch it off at boot.
    # It can only be set permanently in the drive via SCT Feature Control (smartctl -s wcache-sct,on,p).
    if [[ $d == sd* ]] && [ "$kind" != USB ] && [ "$(id -u)" -eq 0 ]; then
      local hw="" sct="" boot="" fix wcinfo=""
      command -v hdparm >/dev/null 2>&1 && hw=$(hdparm -W "$dev" 2>/dev/null | sed -n 's/.*write-caching *= *\([01]\).*/\1/p')
      command -v smartctl >/dev/null 2>&1 && sct=$(smartctl -g wcache-sct "$dev" 2>/dev/null | sed -n 's/^SCT Write Cache Control: *//p' | head -1)
      grep -qiE 'not supported|unavailable' <<<"$sct" && sct=""
      # First entry of this boot = state at detection, before udev rules or similar intervene
      boot=$( (journalctl -k -b -o cat 2>/dev/null || dmesg 2>/dev/null) | grep -m1 "\[$d\] Write cache:" | sed -n 's/.*Write cache: *\([a-z]*\).*/\1/p')
      [ -n "$hw" ] && wcinfo="drive $([ "$hw" = 1 ] && echo on || echo off)"
      [ -n "$boot" ] && wcinfo="${wcinfo:+$wcinfo, }at boot $([ "$boot" = enabled ] && echo on || echo off)"
      [ -n "$sct" ] && wcinfo="${wcinfo:+$wcinfo, }SCT: $sct"
      [ -n "$wcinfo" ] && info "Write cache: $wcinfo"
      if [ -n "$sct" ]; then
        fix="enable it permanently in the drive: smartctl -s wcache-sct,on,p $dev (then cold boot and check: journalctl -k -b | grep -i 'write cache')"
      else
        fix="enable it at every boot, e.g. with a udev rule running hdparm -W1 $dev (the drive does not support SCT Feature Control)"
      fi
      if grep -qi 'force disabled' <<<"$sct"; then
        warn "$d: The write cache is permanently disabled via SCT - hdparm -W1 has no effect. Enable it: smartctl -s wcache-sct,on,p $dev"
      elif [ "$hw" = 0 ]; then
        warn "$d: The drive's write cache is OFF - every write goes straight to flash: slow, and very high write amplification on consumer SSDs. Remedy: $fix."
      elif [ "$hw" = 1 ] && [ "$wc" = "write through" ]; then
        warn "$d: The drive has its write cache ON, but the kernel considers it off ('write through') and therefore sends no flushes - data loss is possible on power failure. Remedy: echo 1 > /sys/block/$d/device/rescan"
      elif [ "$boot" = disabled ] && ! grep -qi 'force enabled' <<<"$sct"; then
        hint "$d: The write cache is off at boot (BIOS or firmware) and only switched on afterwards (udev rule/hdparm). If that fails once, the SSD runs without cache. Better: $fix."
      fi
    fi
    case "$role" in
      */Parity|*/Data)
        [ "$rot" = 0 ] && warn "$d: SSD in the Unraid array ($role). No TRIM in the array, and every write causes a parity read-modify-write - SSDs belong in a pool." ;;
    esac

    if [ -n "$sm" ]; then
      trim=$(sed -n 's/^TRIM Command: *//p' <<<"$sm")
      sata=$(sed -n 's/^SATA Version is: *//p' <<<"$sm")
      [ -n "$sata$trim" ] && info "SMART: ${sata:+$sata} ${trim:+| TRIM: $trim}"
      # SanDisk/WD SSDs: 173 = avg erase count, 233 = NAND writes (GiB), 241 = host writes (GiB).
      # Older smartctl databases do not know the names and show wrong/Unknown labels.
      wdsd=0
      grep -qE 'SanDisk|^SD |SDSSD|WDS[0-9]|WD (Blue|Red|Green)' <<<"$model" && [ "$rot" = 0 ] && wdsd=1
      # For wear attributes the normalized value (100 = new) is more meaningful than the raw value.
      attrs=$(awk -v wdsd=$wdsd '$1 ~ /^(5|9|169|173|177|194|199|202|230|231|232|233|234|241)$/ && NF >= 10 {
          n = $2
          if (wdsd) { if ($1 == 173) n = "Avg_Erase_Count"; else if ($1 == 230) n = "Media_Wearout"; else if ($1 == 233) n = "NAND_GiB_Written"
                      else if ($1 == 234) n = "NAND_GiB_Written_SLC"; else if ($1 == 241) n = "Host_GiB_Written" }
          printf "%s:%s=%s%s  ", $1, n, $10, ($1 ~ /^(169|173|177|202|230|231|232|233)$/ ? " (norm. " ($4 + 0) ")" : "") }' <<<"$sm")
      [ -z "$attrs" ] && attrs=$(grep -E '^(Temperature|Percentage Used|Data Units Written|Media and Data Integrity Errors|Unsafe Shutdowns):' <<<"$sm" | sed 's/  */ /g' | paste -sd'|' -)
      [ -n "$attrs" ] && info "SMART: $attrs"
      crc=$(awk '$1==199 {print $10+0}' <<<"$sm")
      realloc=$(awk '$1==5 {print $10+0}' <<<"$sm")
      [ "${crc:-0}" -gt 0 ] && warn "$d: UDMA_CRC_Error_Count=$crc - transfer errors (cable/backplane). Errors cost retries and thus latency. Is the value still rising?"
      [ "${realloc:-0}" -gt 0 ] && warn "$d: $realloc reallocated sectors."
      # Write amplification: WAF = num/den, host = host writes in GiB.
      # SanDisk/WD: 233 NAND GiB / 241 host GiB. Crucial/Micron: (247 host + 248 FTL pages) / 247, host via 246 (LBAs).
      # Samsung (SM883/PM883 and similar): 251 NAND LBAs / 241 host LBAs, converted to GiB here.
      local nand hostw poh erase num="" den="" hgib="" serial nandgib=$wdsd
      poh=$(awk '$1 == 9 && NF >= 10 {print $10 + 0; exit} /^Power On Hours:/ {gsub(",", "", $4); print $4 + 0; exit}' <<<"$sm")
      [ -n "$poh" ] && DEVPOH[$d]=$poh
      serial=$(sed -n 's/^Serial Number: *//p' <<<"$sm" | head -1)
      if [ $wdsd -eq 1 ]; then
        nand=$(awk '$1==233 {print $10+0}' <<<"$sm"); hostw=$(awk '$1==241 {print $10+0}' <<<"$sm")
        erase=$(awk '$1==173 {print $10+0}' <<<"$sm")
        if [ "${nand:-0}" -gt 0 ] && [ "${hostw:-0}" -gt 0 ]; then
          num=$nand; den=$hostw; hgib=$hostw
          awk -v n="$nand" -v h="$hostw" -v poh="${poh:-0}" -v e="${erase:-}" 'BEGIN {
            printf "      Write amplification (WAF = NAND/host): %.1f", n / h
            if (poh > 24) printf "   host %.0f GiB/day, NAND %.0f GiB/day", h * 24 / poh, n * 24 / poh
            if (e != "") printf "   avg erase count %s", e
            print "" }'
        fi
      elif grep -qE 'SAMSUNG|^MZ' <<<"$model" && awk '$1 == 251 && $10 > 0 { a = 1 } $1 == 241 && $10 > 0 { b = 1 } END { exit !(a && b) }' <<<"$sm"; then
        read -r num den < <(awk '$1 == 251 {n = $10} $1 == 241 {h = $10} END { printf "%.2f %.2f\n", n * 512 / 2^30, h * 512 / 2^30 }' <<<"$sm")
        hgib=$den; nandgib=1
        awk -v n="$num" -v h="$den" -v poh="${poh:-0}" 'BEGIN {
            printf "      Write amplification (WAF = NAND/host): %.2f", n / h
            if (poh > 24) printf "   host %.0f GiB/day, NAND %.0f GiB/day", h * 24 / poh, n * 24 / poh
            print "" }'
      elif grep -q 'FTL_Program_Page_Count' <<<"$sm"; then
        read -r num den hgib < <(awk '$1==247 {h=$10} $1==248 {f=$10} $1==246 {l=$10}
          END { if (h > 0) printf "%.0f %.0f %.1f\n", h + f, h, l * 512 / 2^30 }' <<<"$sm")
        [ -n "$den" ] && awk -v n="$num" -v h="$den" -v g="$hgib" -v poh="${poh:-0}" 'BEGIN {
            printf "      Write amplification (WAF = (host+FTL pages)/host pages): %.1f", n / h
            if (poh > 24) printf "   host %.0f GiB/day", g * 24 / poh
            print "" }'
      fi
      if [ -n "$den" ]; then
        awk -v n="$num" -v h="$den" 'BEGIN { exit !(n >= 5 * h) }' &&
          warn "$d: internal write amplification $(awk -v n="$num" -v h="$den" 'BEGIN{printf "%.0f", n/h}')x - the SSD internally writes a multiple of what the system writes. Typical for many small fsync writes (databases, NVR, logs) on consumer SSDs without power loss protection: the SSD is constantly busy with garbage collection (latency spikes) and wears out quickly."
        waf_history "$d" "$serial" "$num" "$den" "$hgib" "$nandgib"
      fi
      [ "$rot" = 0 ] && wear_forecast "$d" "$(wear_used "$dev" "$sm" "$wdsd")" "$poh" "$num" "$([ -n "$den" ] && echo "$WH_RATE")"
    fi

    if [ "$rot" = 0 ] && grep -qiE 'QVO|BX500|A400|SU630|SU650|660p|665p|670p|Crucial P1|P3 Plus|WD ?Green|WDS[0-9]+G[0-9]A|SSD Plus|SDSSDA|Intenso|NV1|NV2|TM8FP' <<<"$model"; then
      warn "$d: '$model' is known as a QLC and/or DRAM-less SSD - drops sharply under sustained load (SLC cache full) and often has high flush latency."
    fi
  done

  section "Storage layout"
  if command -v lsblk >/dev/null 2>&1; then
    lsblk -e 7 -o NAME,TYPE,FSTYPE,SIZE,MOUNTPOINT 2>/dev/null | sed 's/^/      /'
  fi
  echo
  awk '$1 ~ "^/dev/" && $1 !~ "^/dev/loop" && $2 !~ "^/(snap|boot/efi)" && $3 != "squashfs" || $3 == "zfs" || $3 == "fuse.shfs" {
         printf "      %-26s %-8s %s\n", $2, $3, substr($4, 1, 80) }' /proc/mounts
  if grep -q ' /mnt/user fuse.shfs' /proc/mounts; then
    hint "/mnt/user runs via shfs (FUSE). Every access there costs CPU. Compare: -t /mnt/user/<share>/x -t /mnt/<pool>/<share>/x"
  fi
  if grep -qE ' (ext4|xfs|btrfs) .*(^|,)(sync|dirsync)(,|$)' /proc/mounts 2>/dev/null; then
    warn "A file system is mounted with 'sync' - every write waits for the device."
  fi
  if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    if [ "$(systemctl is-enabled fstrim.timer 2>/dev/null)" = "enabled" ]; then
      local cal
      cal=$(systemctl show fstrim.timer -p TimersCalendar --value 2>/dev/null | sed -n 's/.*OnCalendar=\([^;]*[^ ;]\) *;.*/\1/p' | head -1)
      ok "fstrim.timer active (${cal:-schedule unknown})."
      trim_advice "$cal"
    elif ! grep -qE '(^|,)discard' <(awk '{print $4}' /proc/mounts); then
      hint "fstrim.timer is not active and no file system uses 'discard' - without TRIM SSDs get slower under write load (systemctl enable --now fstrim.timer)."
    fi
  fi

  # Linux software RAID (mdadm). Unraid uses its own md driver without /proc/mdstat arrays.
  if grep -qE '^md[0-9]+ : active' /proc/mdstat 2>/dev/null; then
    section "Software RAID (mdadm)"
    sed 's/^/      /' /proc/mdstat
    if grep -qE '(resync|recovery|check|reshape) *=' /proc/mdstat; then
      warn "An MD RAID is currently running resync/check/recovery - this slows down writes massively. Ubuntu starts 'checkarray' on the first Sunday of every month."
    fi
    local md lvl
    for md in /sys/block/md*; do
      [ -f "$md/md/level" ] || continue
      lvl=$(cat "$md/md/level")
      local s mem members=""
      for s in "$md"/slaves/*; do
        [ -e "$s" ] || continue
        mem=${s##*/}
        [ -e "/sys/block/$mem" ] || mem=$(basename "$(readlink -f "/sys/class/block/$mem/..")")
        members="$members $mem"
      done
      MDMEMBERS="$MDMEMBERS$members"
      local bml; bml=$(cat "$md/md/bitmap/location" 2>/dev/null || echo none)
      case "$bml" in [+-][0-9]*) bml="internal" ;; none) bml="none" ;; esac
      info "${md##*/}: $lvl, Bitmap: $bml$( [ -f "$md/md/stripe_cache_size" ] && echo ", stripe_cache_size=$(cat "$md/md/stripe_cache_size")")"
      md_groups "$md" "$lvl"
      md_extra_checks "$md" "$lvl"
      case "$lvl" in
        raid1|raid10|raid5|raid6)
          info "${md##*/}: every fsync/flush goes to all members (${members# }) - the slowest SSD determines the latency." ;;&
        raid5|raid6)
          hint "${md##*/} is $lvl: small writes need a read-modify-write for the parity, and the parity calculation runs in the kernel thread ${md##*/}_$lvl (CPU). For many small/sync writes RAID10 is much faster."
          if [ "$(cat "$md/md/stripe_cache_size" 2>/dev/null || echo 0)" -le 256 ]; then
            hint "${md##*/}: stripe_cache_size is small. Test: echo 4096 > $md/md/stripe_cache_size (costs RAM: 4096 x 4 KB x number of disks)."
          fi ;;
      esac
    done
  fi

  # LVM / dm-crypt
  if command -v dmsetup >/dev/null 2>&1 && dmsetup table 2>/dev/null | grep -q ' crypt '; then
    info "dm-crypt (LUKS) active: encryption costs CPU, the threads are called kcryptd/dmcrypt_write."
  fi

  if command -v zpool >/dev/null 2>&1 && [ -n "$(zpool list -H -o name 2>/dev/null)" ]; then
    section "ZFS"
    local pool
    for pool in $(zpool list -H -o name); do
      info "Pool $pool: ashift=$(zpool get -H -o value ashift "$pool")  $(zfs get -H -o property,value sync,compression,recordsize,atime,encryption "$pool" | awk '{printf "%s=%s  ", $1, $2}')"
      zpool list -v -H -o name,size,alloc,frag,cap,health "$pool" 2>/dev/null | sed 's/^/        /'
      [ "$(zfs get -H -o value sync "$pool")" = "always" ] && warn "ZFS pool $pool: sync=always - every write waits for a flush."
    done
    info "Tip: 'zpool iostat -vl 1' shows in parallel whether time is spent in queues (syncq/asyncq) or on the disk (disk_wait)."
  fi

  fs_boot_check
  section "Kernel log (ATA/IO errors)"
  local errs
  errs=$(dmesg 2>/dev/null | grep -Ei 'ata[0-9.]+:.*(error|exception|failed|hard resetting|link down|SError|timeout)|I/O error|blk_update_request|critical medium')
  if [ -n "$errs" ]; then
    warn "$(wc -l <<<"$errs") ATA/IO error messages in the kernel log (last 8 below). Resets/timeouts cause latency spikes of seconds."
    tail -n 8 <<<"$errs" | sed 's/^/        /'
  else
    ok "No ATA/IO errors in the kernel log."
  fi
}

# ---------------------------------------------------------------------------
# Sampler (awk, runs in parallel to the load)
# ---------------------------------------------------------------------------
cat > "$OUT/sampler.awk" <<'AWK'
function uptime_s(   l, a) { l = ""; getline l < "/proc/uptime"; close("/proc/uptime"); split(l, a, " "); return a[1] + 0 }
function clock(   c, t) { c = "date +%H:%M:%S"; t = ""; c | getline t; close(c); return t }
function exists(f,   x, r) { r = (getline x < f); close(f); return r >= 0 }
function psi_total(f, which,   line, a, n, i, v) {
  v = -1
  while ((getline line < f) > 0)
    if (substr(line, 1, length(which)) == which) {
      n = split(line, a, " ")
      for (i = 1; i <= n; i++) if (a[i] ~ /^total=/) v = substr(a[i], 7) + 0
    }
  close(f)
  return v
}
function read_stat(   line, a, n, i, t) {
  while ((getline line < "/proc/stat") > 0) {
    if (line !~ /^cpu/) break
    n = split(line, a, " ")
    t = 0
    for (i = 2; i <= 9 && i <= n; i++) t += a[i]
    C_tot[a[1]] = t; C_idle[a[1]] = a[5]; C_iow[a[1]] = a[6]
  }
  close("/proc/stat")
}
function read_disks(   line, a, n, d) {
  while ((getline line < "/proc/diskstats") > 0) {
    n = split(line, a, " ")
    d = a[3]
    if (d !~ devre) continue
    if (!(d in Dseen)) { Dseen[d] = 1; Ndev++; Dlist[Ndev] = d }
    D_rios[d] = a[4]; D_rsec[d] = a[6]; D_rtk[d] = a[7]
    D_wios[d] = a[8]; D_wsec[d] = a[10]; D_wtk[d] = a[11]
    D_iot[d] = a[13]; D_tiq[d] = a[14]; D_infl[d] = a[12]
    D_fios[d] = (n >= 20) ? a[19] : 0; D_ftk[d] = (n >= 20) ? a[20] : 0
  }
  close("/proc/diskstats")
}
function norm_comm(c) {
  if (c ~ /^kworker/) { if (match(c, /[+-][a-z_]+/)) return "kworker" substr(c, RSTART, RLENGTH); return "kworker" }
  sub(/\/[0-9]+$/, "", c)
  return c
}
function read_procs(   cmd, pid, f, line, lp, a, v) {
  delete P_cur; delete P_wb
  cmd = "ls /proc 2>/dev/null"
  while ((cmd | getline pid) > 0) {
    if (pid !~ /^[0-9]+$/) continue
    f = "/proc/" pid "/stat"
    if ((getline line < f) > 0) {
      lp = index(line, "(")
      if (lp > 0 && match(line, /\)[^)]*$/)) {
        P_comm[pid] = norm_comm(substr(line, lp + 1, RSTART - lp - 1))
        split(substr(line, RSTART + 2), a, " ")
        P_ppid[pid] = a[2]
        P_cur[pid] = a[12] + a[13]
      }
    }
    close(f)
  }
  close(cmd)
  # Bytes written per process (incl. exited child processes it has reaped); complete only as root.
  # Net: data deleted again before writeback (cancelled_write_bytes) never reaches the disk.
  # Via grep instead of getline: mawk aborts completely on read errors (EACCES) on /proc/<pid>/io.
  cmd = "grep -s -H -E \"^(cancelled_)?write_bytes\" /proc/[0-9]*/io"
  while ((cmd | getline line) > 0)
    if (split(line, a, "/") >= 4) {
      v = line; sub(/.* /, "", v)
      if (line ~ /:cancelled_/) P_wb[a[3]] -= v; else P_wb[a[3]] += v
    }
  close(cmd)
}
function sample() {
  read_stat(); read_disks(); read_procs()
  Pc = psi_total("/proc/pressure/cpu", "some")
  Pis = psi_total("/proc/pressure/io", "some")
  Pif = psi_total("/proc/pressure/io", "full")
}
function remember(   k) {
  for (k in C_tot) { Cp_tot[k] = C_tot[k]; Cp_idle[k] = C_idle[k]; Cp_iow[k] = C_iow[k] }
  for (k in D_wios) {
    Dp_rios[k] = D_rios[k]; Dp_rsec[k] = D_rsec[k]; Dp_rtk[k] = D_rtk[k]
    Dp_wios[k] = D_wios[k]; Dp_wsec[k] = D_wsec[k]; Dp_wtk[k] = D_wtk[k]
    Dp_iot[k] = D_iot[k]; Dp_tiq[k] = D_tiq[k]; Dp_fios[k] = D_fios[k]; Dp_ftk[k] = D_ftk[k]
  }
  delete P_prev; delete P_wbp
  for (k in P_cur) P_prev[k] = P_cur[k]
  for (k in P_wb) { P_wbp[k] = P_wb[k]; if (!(k in P_first)) P_first[k] = P_wb[k] }
  Pc_p = Pc; Pis_p = Pis; Pif_p = Pif
}
function pct(cur, prev, dt,   v) {
  if (cur < 0 || prev < 0) return -1
  v = 100 * (cur - prev) / (dt * 1000000)
  return v > 100 ? 100 : v
}
function fp(v) { return v < 0 ? "  n/a" : sprintf("%4.0f%%", v) }
function top3(arr, dt,   k, best, bv, s, j, used) {
  s = ""; TopName = "-"; TopPct = 0
  for (j = 1; j <= 3; j++) {
    best = ""; bv = 0
    for (k in arr) if (!(k in used) && arr[k] > bv) { bv = arr[k]; best = k }
    if (best == "") break
    used[best] = 1
    s = s (s == "" ? "" : ", ") best " " sprintf("%.0f%%", 100 * bv / hz / dt)
    if (j == 1) { TopName = best; TopPct = 100 * bv / hz / dt }
  }
  return s
}
function topw(arr, dt, n,   k, best, bv, s, j, used) {
  s = ""; TopW = "-"; TopWmbs = 0
  for (j = 1; j <= n; j++) {
    best = ""; bv = 0
    for (k in arr) if (!(k in used) && arr[k] > bv) { bv = arr[k]; best = k }
    if (best == "" || bv / 1048576 / dt < 0.05) break
    used[best] = 1
    s = s (s == "" ? "" : ", ") best " " sprintf("%.1f MB/s", bv / 1048576 / dt)
    if (j == 1) { TopW = best; TopWmbs = bv / 1048576 / dt }
  }
  return s
}
# Stalls as events, as in the service: an interval is slow if requests take >= stall_ms or the device
# has requests in flight and completes none. Consecutive slow intervals (gap < 3 s) = one stall.
function track(d, t, dt, slow, w) {
  if (slow) {
    if (!(d in Op_s)) { Op_s[d] = t - dt; Op_m[d] = 0 }
    Op_e[d] = t
    if (w > Op_m[d]) Op_m[d] = w
  } else if ((d in Op_s) && t - Op_e[d] >= 3) close_ev(d)
}
function close_ev(d) {
  EvN++; Ev_d[EvN] = d; Ev_s[EvN] = Op_s[d]; Ev_e[EvN] = Op_e[d]; Ev_m[EvN] = Op_m[d]
  delete Op_s[d]; delete Op_e[d]; delete Op_m[d]
}
function sortn(a, n,   i, j, x) { for (i = 2; i <= n; i++) { x = a[i]; for (j = i - 1; j >= 1 && a[j] > x; j--) a[j + 1] = a[j]; a[j + 1] = x } }
function wall(t,   c, r) { c = "date -d @" int(start_epoch + t - t0) " '+%m-%d %H:%M:%S'"; r = ""; c | getline r; close(c); return r }
function interval(dt,   c, t, b, busy, iow, maxc, maxcn, dtot, pc, pis, pif, p, dd, top, i, d,
                  dw, dws, dwt, dr, drs, drt, df, dft, diot, dtiq, wmbs, rmbs, wa, fa, util, devt, aqu, reqkb,
                  flag, maxdevt, totw, tclock, buf, iflag, wtop, k, V) {
  N++
  dtot = C_tot["cpu"] - Cp_tot["cpu"]
  busy = 0; iow = 0
  if (dtot > 0) {
    busy = 100 * (dtot - (C_idle["cpu"] - Cp_idle["cpu"]) - (C_iow["cpu"] - Cp_iow["cpu"])) / dtot
    iow = 100 * (C_iow["cpu"] - Cp_iow["cpu"]) / dtot
  }
  maxc = 0; maxcn = "-"
  for (c in C_tot) {
    if (c == "cpu" || !(c in Cp_tot)) continue
    t = C_tot[c] - Cp_tot[c]
    if (t <= 0) continue
    b = 100 * (t - (C_idle[c] - Cp_idle[c]) - (C_iow[c] - Cp_iow[c])) / t
    if (b > maxc) { maxc = b; maxcn = c }
  }
  S_busy += busy; S_iow += iow; S_dt += dt
  if (maxc >= 95) Nsat++
  pc = pct(Pc, Pc_p, dt); pis = pct(Pis, Pis_p, dt); pif = pct(Pif, Pif_p, dt)
  if (pc >= 0) { S_pc += pc; N_pc++ }
  if (pis >= 0) { S_pis += pis; S_pif += pif; N_pi++ }

  delete Cd
  for (p in P_cur) if (p in P_prev) {
    dd = P_cur[p] - P_prev[p]
    if (dd > 0) { Cd[P_comm[p]] += dd; Ctot[P_comm[p]] += dd }
  }
  top = top3(Cd, dt)

  # When a process exits, the kernel adds its total writes to the parent that reaps it.
  # What was already counted for the child is subtracted there again so that nothing appears twice.
  # Handle children before their parents in case both exit in the same interval (e.g. timeout -> dd).
  delete V
  for (p in P_wbp) if (!(p in P_wb) && (p in P_first)) V[p] = 1
  for (i = 0; i < 50; i++) {
    c = 0
    for (p in V) {
      for (k in V) if (P_ppid[k] == p) break
      if (k in V && P_ppid[k] == p) continue
      Cred[P_ppid[p]] += P_wbp[p] - P_first[p] + Cred[p]
      delete Cred[p]; delete P_first[p]; delete P_ppid[p]; delete V[p]; c++
    }
    if (c == 0) break
  }
  delete Wd
  for (p in P_wb) if (p in P_wbp) {
    dd = P_wb[p] - P_wbp[p]
    if (dd > 0 && Cred[p] > 0) { c = (Cred[p] < dd) ? Cred[p] : dd; dd -= c; Cred[p] -= c }
    # Deleted data can count one interval later than the write: offset it in the total, not in the line
    if (dd != 0) Wtot[P_comm[p]] += dd
    if (dd > 0) Wd[P_comm[p]] += dd
  }
  wtop = topw(Wd, dt, 3)

  # Collect output: with -q only show intervals in which a device stands out
  tclock = clock()
  buf = sprintf("%-8s %4.0f%% %5.0f%%(c%-3s) %5.0f%% %7s %6s/%-6s   %s\n", tclock, busy, maxc, substr(maxcn, 4), iow, fp(pc), fp(pis), fp(pif), top)
  if (wtop != "") buf = buf "   writes: " wtop "\n"
  iflag = 0

  maxdevt = 0; totw = 0
  delete I_stall; delete I_fast
  for (i = 1; i <= Ndev; i++) {
    d = Dlist[i]
    if (!(d in Dp_wios)) continue
    dw = D_wios[d] - Dp_wios[d]; dws = D_wsec[d] - Dp_wsec[d]; dwt = D_wtk[d] - Dp_wtk[d]
    dr = D_rios[d] - Dp_rios[d]; drs = D_rsec[d] - Dp_rsec[d]; drt = D_rtk[d] - Dp_rtk[d]
    df = D_fios[d] - Dp_fios[d]; dft = D_ftk[d] - Dp_ftk[d]
    diot = D_iot[d] - Dp_iot[d]; dtiq = D_tiq[d] - Dp_tiq[d]
    wmbs = dws * 512 / 1048576 / dt
    rmbs = drs * 512 / 1048576 / dt
    wa = (dw > 0) ? dwt / dw : 0
    fa = (df > 0) ? dft / df : 0
    util = 100 * diot / (dt * 1000); if (util > 100) util = 100
    # Sum of request times incl. flush (flushes do not count in io_ticks).
    # At QD1 = share of the time spent waiting for the device.
    devt = 100 * (dwt + drt + dft) / (dt * 1000)
    aqu = dtiq / (dt * 1000)
    reqkb = (dw > 0) ? dws * 512 / 1024 / dw : 0
    if (devt > maxdevt) maxdevt = devt
    totw += dw
    if (!index(" " rotdevs " ", " " d " "))
      track(d, now, dt, (dw > 0 && wa >= stall_ms) || (df > 0 && fa >= stall_ms) || (util >= 90 && D_infl[d] > 0 && dr + dw + df == 0), (wa > fa ? wa : fa))

    T_wios[d] += dw; T_wsec[d] += dws; T_wtk[d] += dwt; T_fios[d] += df; T_ftk[d] += dft
    T_rsec[d] += drs

    if (dw > 0 || df > 0) {
      A_n[d]++
      A_util[d] += util
      flag = ""
      # High await values at high throughput are a normal queue (writeback),
      # slow means high latency at little throughput.
      if (dw >= 5 && ((wa >= 10 && wmbs < 100) || (wa >= 50 && wmbs < 200) || wa >= 1000)) flag = "<< SLOW"
      if (df >= 3 && fa >= 20) flag = "<< SLOW (flush)"
      # Few requests that hang for hundreds of ms while the device is fully busy: stall in the device.
      if (flag == "" && util >= 50 && ((dw > 0 && wa >= 200) || (df > 0 && fa >= 200))) flag = "<< SLOW (stall)"
      if (index(" " rotdevs " ", " " d " ")) flag = ""
      if (flag != "") { A_stall[d]++; Nstall++; I_stall[d] = 1; iflag = 1 } else I_fast[d] = 1
      if ((dw >= 5 || wa >= 200) && wa > A_wamax[d]) A_wamax[d] = wa
      if ((df >= 3 || fa >= 200) && fa > A_famax[d]) A_famax[d] = fa
      if (wmbs > 5) { A_tpn[d]++; A_tp[d, A_tpn[d]] = wmbs }
      buf = buf sprintf("   %-8s W %6.1f MB/s %6.0f/s %4.0fK  await %7.2f ms | Flush %4.0f/s %7.2f ms | R %6.1f MB/s | util %3.0f%% qd %4.1f %s\n",
          d, wmbs, dw / dt, reqkb, wa, df / dt, fa, rmbs, util, aqu, flag)
    }
    printf "%s,%s,%s,%.2f,%.1f,%.3f,%.1f,%.3f,%.2f,%.1f,%.2f,%.1f,%.1f,%.1f,%.1f,%.1f,%.1f,%s,%s,%.2f\n",
      tclock, phase, d, wmbs, dw / dt, wa, df / dt, fa, rmbs, util, aqu, busy, iow, maxc, pc, pis, pif, TopName, TopW, TopWmbs >> csv
  }
  if (iflag) { Nslow++; S_dtslow += dt; for (k in Wd) Wslow[k] += Wd[k] }
  if (!quiet || iflag) {
    if (Nprinted % 20 == 0)
      printf "%-8s %5s %11s %6s %7s %13s   %s\n", "Time", "CPU", "max.core", "iowait", "PSIcpu", "PSIio s/f", "Top processes (% of a core)"
    Nprinted++
    printf "%s", buf
    fflush()
  }
  if (totw >= 5) { Nact++; S_devt += (maxdevt > 100 ? 100 : maxdevt) }
  # Intervals in which one device stalls while another one responds quickly at the same time
  for (d in I_stall) for (i in I_fast) { Nsplit++; break }
}
function load_app(f,   line, a) {
  while ((getline line < f) > 0) if (split(line, a, "=") == 2) APP[a[1]] = a[2]
  close(f)
}
function add(side, pts, msg) {
  if (side == "SSD") Sd += pts; else if (side == "CPU") Sc += pts; else { Sd += pts; Sc += pts }
  Fn++; F[Fn] = sprintf("  [%s] %s", side, msg)
}
function summary(   i, d, k, n, x, aw, af, minaw, bf, first, last, tn, tops, wgb, busy, sat, verdict, cnt, avgp, dl, tpa, nst,
                    fn, fsum, flong, FE, pl, pn, pgap, pdur, j, G, U, S, m, c) {
  printf "\n--- Analysis: %s (%d samples of %ss, %s) ---\n", label, N, interval_s, (S_dt < 3600 ? sprintf("%.0f s", S_dt) : sprintf("%.1f h", S_dt / 3600))
  if (N < 2) { print "  Too few samples."; return }
  busy = S_busy / N; sat = 100 * Nsat / N
  printf "CPU:  avg utilization %.0f%%, avg iowait %.0f%% (= waiting for IO, no CPU load), one core >=95%% in %.0f%% of the intervals\n", busy, S_iow / N, sat
  if (N_pc) printf "PSI:  cpu some avg %.1f%%   io some avg %.1f%%   io full avg %.1f%%\n", S_pc / N_pc, S_pis / N_pi, S_pif / N_pi
  tops = ""; cnt = 0
  for (k in Ctot) tn[k] = Ctot[k]
  for (i = 1; i <= 6; i++) {
    x = ""; n = 0
    for (k in tn) if (tn[k] > n) { n = tn[k]; x = k }
    if (x == "") break
    avgp = 100 * n / hz / S_dt
    if (avgp < 1) break
    TOP[x] = avgp
    if (i == 1) TOP1 = x
    tops = tops sprintf("%s %.0f%%  ", x, avgp)
    delete tn[x]
  }
  printf "Top processes (avg %% of a core): %s\n", (tops == "" ? "-" : tops)
  tops = ""
  for (k in tn) delete tn[k]
  for (k in Wtot) tn[k] = Wtot[k]
  for (i = 1; i <= 8; i++) {
    x = ""; n = 0
    for (k in tn) if (tn[k] > n) { n = tn[k]; x = k }
    if (x == "" || n < 1048576) break
    tops = tops sprintf("%s %.2f MB/s (%.2f GB)  ", x, n / 1048576 / S_dt, n / 1e9)
    delete tn[x]
  }
  for (k in tn) delete tn[k]
  if (tops != "") {
    printf "Top writers (avg over the phase): %s\n", tops
    if (Nslow > 0) {
      tops = ""
      for (k in Wslow) tn[k] = Wslow[k]
      for (i = 1; i <= 5; i++) {
        x = ""; n = 0
        for (k in tn) if (tn[k] > n) { n = tn[k]; x = k }
        if (x == "" || n < 1048576) break
        tops = tops sprintf("%s %.2f MB/s  ", x, n / 1048576 / S_dtslow)
        delete tn[x]
      }
      for (k in tn) delete tn[k]
      if (tops != "") printf "Writers in the %d slow intervals: %s\n", Nslow, tops
    }
    print "  (Parent processes such as systemd, cron or containerd-shim include the writes of their exited child processes.)"
  }

  printf "\n  %-8s %10s %9s %8s %10s %10s %9s %9s %7s %12s\n", "Device", "written", "avg req", "avg wait", "max await", "flush n", "flush avg", "flush max", "avg util", "slow"
  minaw = -1
  for (i = 1; i <= Ndev; i++) {
    d = Dlist[i]
    if (!(d in A_n)) continue
    aw = T_wios[d] ? T_wtk[d] / T_wios[d] : 0
    af = T_fios[d] ? T_ftk[d] / T_fios[d] : 0
    wgb = T_wsec[d] * 512 / 1e9
    hdd = index(" " rotdevs " ", " " d " ") > 0
    printf "  %-8s %7.2f GB %7.0fK %6.2fms %8.1fms %10d %7.2fms %7.1fms %6.0f%% %6d/%-5d%s\n", d, wgb,
      T_wios[d] ? T_wsec[d] * 512 / 1024 / T_wios[d] : 0, aw, A_wamax[d], T_fios[d], af, A_famax[d], A_util[d] / A_n[d], A_stall[d], A_n[d], (hdd ? " (HDD)" : "")
    AW[d] = aw; AF[d] = af
    if (!hdd && T_wios[d] >= 50 && (minaw < 0 || aw < minaw)) minaw = aw
  }

  if (APP["tool"] != "") {
    printf "\nApplication view (%s, %s): ", APP["tool"], APP["what"]
    if (APP["app_mean_ms"] != "")
    {
      x = ""
      if (APP["app_p99_ms"] != "")
        x = sprintf(", p50 %s ms, p99 %s ms, p99.9 %s ms, max %s ms", APP["app_p50_ms"], APP["app_p99_ms"], APP["app_p999_ms"], APP["app_max_ms"])
      printf "%s IOPS, avg %s ms%s\n", APP["app_iops"], APP["app_mean_ms"], x
    }
    else
      printf "%s MB/s\n", APP["app_bw_mbs"]
  }

  # ---- Stall events and pattern per SSD ----
  for (d in Op_s) close_ev(d)
  fn = 0; fsum = 0; flong = 0
  for (i = 1; i <= EvN; i++) {
    x = Ev_e[i] - Ev_s[i]
    if (Ev_m[i] >= felt_ms || x >= 2) { fn++; FE[fn] = i; fsum += x; if (x > flong) flong = x }
  }
  if (EvN > 0) {
    printf "\nStalls (SSD, wait time from %d ms): %d, noticeable (from %.0f s wait time or 2 s duration): %d, total %.0f s, longest %.0f s%s\n",
      stall_ms, EvN, felt_ms / 1000, fn, fsum, flong, (interval_s > 1 ? sprintf(" (duration accurate to %ss)", interval_s) : "")
    if (fn > 0) printf "  %-17s %-8s %7s  %s\n", "Time", "Device", "Duration", "max. wait"
    for (k = fn; k >= 1 && k > fn - 25; k--) {
      i = FE[k]
      printf "  %-17s %-8s %6.0fs  %s\n", wall(Ev_s[i]), Ev_d[i], Ev_e[i] - Ev_s[i], (Ev_m[i] >= 1000 ? sprintf("%.1f s", Ev_m[i] / 1000) : sprintf("%.0f ms", Ev_m[i]))
    }
    if (fn > 25) printf "  (%d older noticeable stalls not listed)\n", fn - 25
    # Pattern: typical duration and typical interval of the noticeable stalls per SSD
    pl = ""; pn = 0; pgap = 0; pdur = 0
    for (j = 1; j <= Ndev; j++) {
      d = Dlist[j]; n = 0; delete G; delete U
      for (k = 1; k <= fn; k++) { i = FE[k]; if (Ev_d[i] == d) { n++; U[n] = Ev_e[i] - Ev_s[i]; S[n] = Ev_s[i] } }
      if (n == 0) continue
      for (k = 2; k <= n; k++) G[k - 1] = (S[k] - S[k - 1]) / 60
      sortn(U, n); sortn(G, n - 1)
      x = sprintf("  Pattern %-6s %3d× noticeable, duration median %.0f s", d, n, U[int((n + 1) / 2)])
      if (n >= 2) x = x sprintf(", interval median %.1f min (min %.1f, max %.1f)", G[int(n / 2)], G[1], G[n - 1])
      print x
      # Regular: at least 4 stalls and most intervals close to the median
      if (n >= 4) {
        m = G[int(n / 2)]; c = 0
        for (k = 1; k < n; k++) if (G[k] >= 0.6 * m && G[k] <= 1.6 * m) c++
        if (c >= 0.6 * (n - 1)) { pn++; pl = pl (pl == "" ? "" : ", ") d; pgap += m; pdur += U[int((n + 1) / 2)] }
      }
    }
  }

  # ---- Assessment ----
  Sd = 0; Sc = 0; Fn = 0; bf = -1
  if (mode == "sync" && Nact >= 3) {
    bf = S_devt / Nact
    printf "Device time share during the test: %.0f%% (the rest of the wait happens above the SSD)\n", bf
    if (APP["app_mean_ms"] != "" && APP["app_mean_ms"] + 0 < 1)
      printf "Test latency avg %s ms is good - no bottleneck with this pattern.\n", APP["app_mean_ms"]
    else if (bf >= 70) add("SSD", 3, sprintf("The test requests wait %.0f%% of the time for the SSD itself - the latency happens on the device.", bf))
    else if (bf <= 35) add("CPU", 3, sprintf("Only %.0f%% of the wait time is spent on the SSD; the rest is lost in CPU/software (syscalls, shfs/FUSE, file system, locks, scheduling).", bf))
    else add("MIX", 1, sprintf("%.0f%% of the wait time on the SSD, the rest in CPU/software - both sides contribute.", bf))
  }
  nst = 0
  for (i = 1; i <= Ndev; i++) if (A_stall[Dlist[i]] > 0) nst++
  for (i = 1; i <= Ndev; i++) {
    d = Dlist[i]
    if (!(d in A_n) || A_n[d] < 3) continue
    if (index(" " rotdevs " ", " " d " ")) continue   # HDDs: latencies in the ms range are normal there
    x = 100 * A_stall[d] / A_n[d]
    if (x >= 20) add("SSD", 2, sprintf("%s: extremely slow write/flush times in %.0f%% of the active intervals (max await %.0f ms%s).", d, x, A_wamax[d], A_famax[d] > 0 ? sprintf(", max flush %.0f ms", A_famax[d]) : ""))
    else if (x >= 5) add("SSD", 1, sprintf("%s: occasional write stalls (%d intervals, max await %.0f ms).", d, A_stall[d], A_wamax[d]))
    if (T_fios[d] >= 10) {
      if (AF[d] >= 10) add("SSD", 2, sprintf("%s: flush (fsync/emptying the cache) takes avg %.1f ms - very slow (consumer SSD without power loss protection, SLC cache full or firmware).", d, AF[d]))
      else if (AF[d] >= 3) add("SSD", 1, sprintf("%s: flush avg %.1f ms - elevated (good SATA SSDs < 2 ms, enterprise with PLP < 0.1 ms).", d, AF[d]))
    }
    # If several devices stall alternately, a single "slowest" device is not a finding
    if (T_wios[d] >= 50 && minaw > 0 && AW[d] > 3 * minaw && AW[d] > 2 && !(nst >= 2 && A_stall[d] > 0))
      add("SSD", 1, sprintf("%s is much slower than the other devices (avg await %.2f ms vs. best %.2f ms) - check this drive specifically.", d, AW[d], minaw))
    if ((mode == "seq" && A_tpn[d] >= 10) || A_tpn[d] >= 30) {
      # Peak (mean of 3) in the first half vs. mean shortly before the end (last 2 values = final flush)
      first = 0; last = 0
      for (k = 1; k + 2 <= A_tpn[d] / 2; k++) {
        x = (A_tp[d, k] + A_tp[d, k + 1] + A_tp[d, k + 2]) / 3
        if (x > first) first = x
      }
      for (k = 1; k <= 5; k++) last += A_tp[d, A_tpn[d] - 1 - k]
      last /= 5
      if (first > 80 && last < 0.4 * first)
        add("SSD", 2, sprintf("%s: write rate drops under sustained load from %.0f to %.0f MB/s - typical for a full SLC cache (QLC/TLC consumer SSD) or missing TRIM.", d, first, last))
    }
  }
  n = 0; dl = ""; x = 0
  for (i = 1; i <= Ndev; i++) {
    d = Dlist[i]
    if (A_stall[d] > 0) { n++; dl = dl (dl == "" ? "" : ", ") d; if ((" " mdmembers " ") ~ (" " d " ")) x++ }
  }
  if (Nsplit > 0) {
    if (n >= 2)
      add("SSD", 1, sprintf("The stalls alternate between several SSDs (%s) while the others respond quickly at the same time. The device itself pauses (internal garbage collection/firmware) - not a cable, controller or CPU problem, and rather model/load behavior than a single defective drive.", dl))
    else
      add("SSD", 1, sprintf("Only %s stalls while the other SSDs respond quickly at the same time - check this drive specifically (firmware, wear, swap cable/port).", dl))
    if (x >= 1)
      add("SSD", 0, "In an mdadm RAID every fsync waits for all members: a stall on any SSD slows down the whole array. With more SSDs in the array the probability rises that one of them is stalling.")
  }
  if (N_pi && S_pif / N_pi >= 10 && Nstall > 0) add("SSD", 1, sprintf("PSI io full avg %.0f%%: processes are regularly fully blocked by IO.", S_pif / N_pi))
  if (fn > 0) add("SSD", 2, sprintf("%d noticeable stalls (from %.0f s wait time or 2 s duration), total %.0f s, longest %.0f s - during this time everything that writes waits.", fn, felt_ms / 1000, fsum, flong))
  if (pn > 0) add("SSD", 1, sprintf("Regular rhythm: %s %s about every %.0f min for ~%.0f s. If no program writes a lot in this rhythm (see writers), this is background work in the SSD firmware - it cannot be switched off with settings, only with other SSDs (e.g. with power loss protection).", pl, (pn > 1 ? "each pause" : "pauses"), pgap / pn, pdur / pn))

  if (mode != "passive" && TOP1 ~ /^(fio|dd)$/) sat = 0   # the test tool itself saturates the core
  if (sat >= 30) add("CPU", 2, sprintf("At least one CPU core was fully busy in %.0f%% of the intervals%s.", sat, busy < 70 ? " (single-thread bottleneck)" : ""))
  else if (sat >= 10) add("CPU", 1, sprintf("One CPU core was fully busy in %.0f%% of the intervals.", sat))
  if (N_pc) {
    x = S_pc / N_pc
    if (x >= 20) add("CPU", 2, sprintf("PSI cpu avg %.0f%%: runnable processes wait noticeably for CPU time.", x))
    else if (x >= 5) add("CPU", 1, sprintf("PSI cpu avg %.0f%%: noticeable CPU contention.", x))
  }
  if (busy >= 85) add("CPU", 1, sprintf("CPU busy avg %.0f%% overall.", busy))
  for (k in TOP) {
    if (k == "shfs" && TOP[k] >= 30) add("CPU", 2, sprintf("shfs (FUSE layer of /mnt/user) needs avg %.0f%% of a core - writing via /mnt/user is CPU-bound. Remedy: use /mnt/<pool>/... directly or exclusive shares.", TOP[k]))
    else if (k ~ /^(z_wr_iss|z_wr_int|z_rd_int|z_fr_iss|txg_sync|spl_|z_)/ && TOP[k] >= 30) add("CPU", 1, sprintf("ZFS thread %s needs avg %.0f%% of a core (compression/checksums/RAIDZ/encryption).", k, TOP[k]))
    else if (k ~ /^(unraidd|mdrecoveryd|md[0-9]+_raid)/ && TOP[k] >= 30) add("CPU", 2, sprintf("RAID thread %s needs avg %.0f%% of a core (parity calculation runs single-threaded).", k, TOP[k]))
    else if (k ~ /^md[0-9]+_resync/ && TOP[k] >= 5) add("SSD", 1, sprintf("%s is running (RAID resync/check) and competes with normal writes.", k))
    else if (k ~ /^(kcryptd|dmcrypt_write)/ && TOP[k] >= 30) add("CPU", 1, sprintf("Encryption (%s) needs avg %.0f%% of a core.", k, TOP[k]))
    else if (k ~ /^btrfs/ && TOP[k] >= 30) add("CPU", 1, sprintf("btrfs thread %s needs avg %.0f%% of a core.", k, TOP[k]))
  }

  if (Fn == 0) print "\nFindings: no issues in this period."
  else { print "\nFindings:"; for (i = 1; i <= Fn; i++) print F[i] }
  if (Sd < 2 && Sc < 2) verdict = "none"
  else if (Sd >= Sc + 2) verdict = "SSD/storage"
  else if (Sc >= Sd + 2) verdict = "CPU/software"
  else verdict = "mixed"
  printf "=> Main suspect: %s   (points SSD %d / CPU %d)\n", verdict, Sd, Sc

  printf "label=%s\nmode=%s\nverdict=%s\nscore_ssd=%d\nscore_cpu=%d\ndev_frac=%s\napp_mean_ms=%s\napp_p99_ms=%s\napp_iops=%s\napp_bw_mbs=%s\n",
    label, mode, verdict, Sd, Sc, (bf < 0 ? "-" : sprintf("%.0f", bf)), APP["app_mean_ms"], APP["app_p99_ms"], APP["app_iops"], APP["app_bw_mbs"] > sumfile
  close(sumfile)
}
BEGIN {
  if (hz <= 0) hz = 100
  stall_ms = 100; felt_ms = 1000
  interval_s = interval_arg + 0
  t0 = uptime_s()
  sample(); remember(); tprev = t0
  while (1) {
    system("sleep " interval_s)
    now = uptime_s()
    sample()
    if (now - tprev > 0) interval(now - tprev)
    remember(); tprev = now
    if (duration > 0 && now - t0 >= duration) break
    if (stopfile != "" && exists(stopfile)) break
  }
  if (appfile != "") load_app(appfile)
  summary()
  exit
}
AWK

echo "time,phase,dev,w_mbs,w_iops,w_await_ms,flush_per_s,flush_await_ms,r_mbs,util_pct,queue,cpu_busy,cpu_iowait,max_core,psi_cpu,psi_io_some,psi_io_full,top_proc,top_writer,top_writer_mbs" > "$CSV"

# ---------------------------------------------------------------------------
# bpftrace (optional): who calls fsync & co., how long does it take,
# and how much did processes write that exit during the measurement
# ---------------------------------------------------------------------------
cat > "$OUT/trace.bt" <<'BT'
tracepoint:syscalls:sys_enter_fsync,
tracepoint:syscalls:sys_enter_fdatasync,
tracepoint:syscalls:sys_enter_sync_file_range,
tracepoint:syscalls:sys_enter_syncfs,
tracepoint:syscalls:sys_enter_sync
{ @start[tid] = nsecs; @sync_n[curtask->group_leader->comm, comm] = count(); }

tracepoint:syscalls:sys_enter_msync
/args->flags & 4/
{ @start[tid] = nsecs; @sync_n[curtask->group_leader->comm, comm] = count(); }

tracepoint:syscalls:sys_exit_fsync,
tracepoint:syscalls:sys_exit_fdatasync,
tracepoint:syscalls:sys_exit_sync_file_range,
tracepoint:syscalls:sys_exit_syncfs,
tracepoint:syscalls:sys_exit_sync,
tracepoint:syscalls:sys_exit_msync
/@start[tid]/
{
  $us = (nsecs - @start[tid]) / 1000;
  @sync_us[curtask->group_leader->comm, comm] = sum($us);
  @sync_max[curtask->group_leader->comm, comm] = max($us);
  delete(@start[tid]);
}

// On exit every thread reports only its own writes - nothing is counted twice.
// Separately, how much it deleted again before writeback (never reaches the disk).
tracepoint:sched:sched_process_exit
{
  $w = curtask->ioac.write_bytes; $c = curtask->ioac.cancelled_write_bytes;
  if ($w > 0) { @exit_wb[curtask->group_leader->comm] = sum($w); }
  if ($c > 0) { @exit_cw[curtask->group_leader->comm] = sum($c); }
}

END { clear(@start); }
BT

BT_PID=""
trace_start() {
  [ $HAVE_BT -eq 1 ] || return
  BT_OUT="$OUT/phase$PHASE_N.bt"
  BT_T0=$(date +%s)
  bpftrace "$OUT/trace.bt" > "$BT_OUT" 2> "$BT_OUT.err" &
  BT_PID=$!
  local i
  for i in $(seq 50); do
    grep -qE '^Attach(ing|ed)' "$BT_OUT" "$BT_OUT.err" 2>/dev/null && return
    kill -0 "$BT_PID" 2>/dev/null || break
    sleep 0.2
  done
}

trace_stop() {
  [ -n "$BT_PID" ] || return
  local i dur=$(( $(date +%s) - BT_T0 ))
  kill -INT "$BT_PID" 2>/dev/null
  for i in $(seq 50); do kill -0 "$BT_PID" 2>/dev/null || break; sleep 0.2; done
  kill "$BT_PID" 2>/dev/null
  wait "$BT_PID" 2>/dev/null
  BT_PID=""
  # bpftrace up to 0.20 reports "Attaching N probes..." on stdout, newer versions "Attached N probes" on stderr
  if ! grep -qE '^Attach(ing|ed)' "$BT_OUT" "$BT_OUT.err" 2>/dev/null; then
    printf '\nbpftrace tracing not possible: %s\n' "$( { grep -v RLIMIT_MEMLOCK "$BT_OUT.err" | grep -m1 -i error; } || tail -1 "$BT_OUT.err")"
    return
  fi
  # If a process is still running, only threads exited; they are already included in the top writers.
  local running
  running=$(cat /proc/[0-9]*/comm 2>/dev/null | sort -u | tr '\n' '|')
  awk -v dur="$dur" -v running="|$running" '
    function key(l) { sub(/^@[a-z_]+\[/, "", l); sub(/\]: -?[0-9]+$/, "", l); return l }
    function val(l) { sub(/.*\]: /, "", l); return l + 0 }
    function name(k,   a) { split(k, a, ", "); return (a[2] == "" || a[1] == a[2]) ? a[1] : a[1] "/" a[2] }
    /^@sync_n\[/   { k = key($0); N[k] = val($0); tot += N[k] }
    /^@sync_us\[/  { U[key($0)] = val($0) }
    /^@sync_max\[/ { M[key($0)] = val($0) }
    /^@exit_wb\[/  { E[key($0)] = val($0) }
    /^@exit_cw\[/  { C[key($0)] = val($0) }
    END {
      if (dur < 1) dur = 1
      printf "\nfsync callers (bpftrace, %d s): %.1f per second in total\n", dur, tot / dur
      if (tot > 0) {
        printf "  %-36s %8s %7s %8s %9s\n", "process/thread", "calls", "per s", "avg ms", "max ms"
        for (i = 1; i <= 12; i++) {
          b = ""; bv = 0
          for (k in N) if (!(k in used) && N[k] > bv) { bv = N[k]; b = k }
          if (b == "") break
          used[b] = 1
          printf "  %-36.36s %8d %7.2f %8.2f %9.1f%s\n", name(b), N[b], N[b] / dur, U[b] / N[b] / 1000, M[b] / 1000, (M[b] >= 200000 ? "  << stalls" : "")
          if (i == 1) top = b
        }
        printf "=> Most frequent fsync caller: %s (%.0f%% of all calls)\n", name(top), 100 * N[top] / tot
      }
      s = ""
      for (i = 1; i <= 8; i++) {
        b = ""; bv = 0
        for (k in E) if (!(k in usedE) && index(running, "|" k "|") == 0 && E[k] > bv) { bv = E[k]; b = k }
        if (b == "" || bv < 1048576) break
        usedE[b] = 1
        s = s sprintf("%s %.2f GB%s  ", b, bv / 1e9, C[b] > 0.1 * bv ? sprintf(" (of which %.2f GB deleted right away)", (C[b] < bv ? C[b] : bv) / 1e9) : "")
      }
      if (s != "") {
        printf "Processes that exited during the measurement (writes over their whole lifetime): %s\n", s
        print "  (Also included above in the parent process that reaped them, e.g. systemd. Data deleted right away does not reach the disk.)"
      }
    }' "$BT_OUT"
}

# ---------------------------------------------------------------------------
# Phases
# ---------------------------------------------------------------------------
PHASE_N=0
SUMFILES=()

start_sampler() { # label mode duration appfile
  CUR_STOP="$OUT/.stop$PHASE_N"
  rm -f "$CUR_STOP"
  ( trap '' INT; exec awk -v devre="$DEVRE" -v hz="$HZ" -v interval_arg="$INTERVAL" -v duration="$3" \
      -v stopfile="$CUR_STOP" -v csv="$CSV" -v phase="$PHASE_N" -v label="$1" -v mode="$2" \
      -v appfile="$4" -v sumfile="$OUT/phase$PHASE_N.sum" -v mdmembers="$MDMEMBERS" -v rotdevs="$ROTDEVS" -v quiet="$QUIET" -v start_epoch="$(date +%s)" -f "$OUT/sampler.awk" ) &
  SAMPLER=$!
  SUMFILES+=("$OUT/phase$PHASE_N.sum")
}

wait_sampler() {
  while kill -0 "$SAMPLER" 2>/dev/null; do wait "$SAMPLER"; done
  CUR_STOP=""
}

fio_terse_to_app() { # terse-file what
  awk -F';' -v what="$2" '$1 == 3 {
    split($65, a, "="); split($71, b, "="); split($73, c, "=")
    printf "tool=fio\nwhat=%s\napp_iops=%.0f\napp_bw_mbs=%.1f\napp_mean_ms=%.3f\napp_p50_ms=%.3f\napp_p99_ms=%.3f\napp_p999_ms=%.3f\napp_max_ms=%.3f\n",
      what, $49, $48 / 1024, $57 / 1000, a[2] / 1000, b[2] / 1000, c[2] / 1000, $56 / 1000
    exit }' "$1"
}

phase_passive() {
  PHASE_N=$((PHASE_N + 1))
  section "Phase $PHASE_N: passive observation (${PASSIVE}s) - trigger the problem now, Ctrl+C stops"
  [ $QUIET -eq 1 ] && info "(-q: only conspicuous intervals are shown)"
  trace_start
  start_sampler "passive ${PASSIVE}s" passive "$PASSIVE" ""
  wait_sampler
  trace_stop
}

phase_sync() { # dir
  local dir=$1 f app
  PHASE_N=$((PHASE_N + 1))
  f="$dir/.wlat-test-$$.bin"
  app="$OUT/phase$PHASE_N.app"
  CUR_FILE=$f
  section "Phase $PHASE_N: 4k O_SYNC writes (QD1) in $dir for ${TEST_RUNTIME}s"
  if [ $HAVE_FIO -eq 1 ]; then
    fio --name=wlat-prep --filename="$f" --rw=randwrite --bs=4k --size="$TEST_SIZE" --create_only=1 >/dev/null 2>&1
    sync
    trace_start
    start_sampler "sync4k $dir" sync 0 "$app"
    sleep 2
    fio --name=wlat-sync4k --filename="$f" --rw=randwrite --bs=4k --ioengine=psync --sync=1 \
        --size="$TEST_SIZE" --runtime="$TEST_RUNTIME" --time_based --group_reporting --minimal \
        > "$OUT/phase$PHASE_N.fio" 2> "$OUT/phase$PHASE_N.fio.err"
    fio_terse_to_app "$OUT/phase$PHASE_N.fio" "4k randwrite O_SYNC QD1" > "$app"
  else
    trace_start
    start_sampler "sync4k $dir" sync 0 "$app"
    sleep 2
    LC_ALL=C timeout -s INT "$TEST_RUNTIME" dd if=/dev/zero of="$f" bs=4k count=1000000 oflag=dsync 2> "$OUT/phase$PHASE_N.dd"
    awk '/records out/ { split($1, r, "+"); n = r[1] }
         / copied, / { for (i = 1; i <= NF; i++) if ($i == "s,") s = $(i-1) }
         END { if (n > 0 && s > 0) printf "tool=dd\nwhat=4k O_DSYNC QD1\napp_iops=%.0f\napp_mean_ms=%.3f\napp_bw_mbs=%.1f\n", n / s, 1000 * s / n, n * 4 / 1024 / s }' \
      "$OUT/phase$PHASE_N.dd" > "$app"
  fi
  sleep 2
  touch "$CUR_STOP"
  wait_sampler
  trace_stop
  rm -f "$f"; CUR_FILE=""
}

phase_seq() { # dir
  local dir=$1 f app
  PHASE_N=$((PHASE_N + 1))
  f="$dir/.wlat-seq-$$.bin"
  app="$OUT/phase$PHASE_N.app"
  CUR_FILE=$f
  section "Phase $PHASE_N: sustained sequential write of $SEQ_SIZE in $dir"
  trace_start
  start_sampler "seq $SEQ_SIZE $dir" seq 0 "$app"
  sleep 2
  if [ $HAVE_FIO -eq 1 ]; then
    fio --name=wlat-seq --filename="$f" --rw=write --bs=1M --ioengine=psync --size="$SEQ_SIZE" \
        --end_fsync=1 --group_reporting --minimal > "$OUT/phase$PHASE_N.fio" 2> "$OUT/phase$PHASE_N.fio.err"
    fio_terse_to_app "$OUT/phase$PHASE_N.fio" "1M seq write" | grep -E '^(tool|what|app_bw_mbs)=' > "$app"
  else
    local mb
    mb=$(numfmt --from=iec "$SEQ_SIZE" 2>/dev/null); mb=$(( ${mb:-0} / 1048576 ))
    LC_ALL=C dd if=/dev/zero of="$f" bs=1M count="$mb" conv=fdatasync 2> "$OUT/phase$PHASE_N.dd"
    awk '/ copied, / { for (i = 1; i <= NF; i++) if ($i == "s,") s = $(i-1); b = $1 }
         END { if (s > 0) printf "tool=dd\nwhat=1M seq write\napp_bw_mbs=%.1f\n", b / 1048576 / s }' "$OUT/phase$PHASE_N.dd" > "$app"
  fi
  sleep 3
  touch "$CUR_STOP"
  wait_sampler
  trace_stop
  rm -f "$f"; CUR_FILE=""
}

# ---------------------------------------------------------------------------
echo "write-latency-diag $VERSION - $(date '+%F %T') - output: $OUT"
for m in "${UPDATE_MSGS[@]}"; do echo "  $m"; done
[ $SKIP_STATIC -eq 0 ] && static_check

if [ ${#TARGETS[@]} -gt 0 ] && [ $HAVE_FIO -eq 0 ]; then
  section "Note"
  info "fio not found - using dd instead (mean only, no percentiles)."
fi
if [ $HAVE_BT -eq 0 ] && [ $TRACE -eq 1 ]; then
  section "Note"
  info "bpftrace not available (or not root) - no analysis of the fsync callers. Install: apt install bpftrace"
fi

[ "$PASSIVE" -gt 0 ] 2>/dev/null && phase_passive
for t in "${TARGETS[@]}"; do
  [ $ABORT -eq 1 ] && break
  phase_sync "$t"
done
[ $ABORT -eq 0 ] && [ -n "$SEQ_SIZE" ] && phase_seq "${TARGETS[0]}"
[ -n "$CUR_FILE" ] && rm -f "$CUR_FILE"

# ---------------------------------------------------------------------------
# Overall conclusion
# ---------------------------------------------------------------------------
section "Summary"
printf '  %-3s %-44s %9s %9s %8s %10s %8s  %s\n' "#" "Phase" "avg ms" "p99 ms" "IOPS" "SSD share" "SSD/CPU" "Verdict"
declare -A MEAN
for s in "${SUMFILES[@]}"; do
  [ -f "$s" ] || { echo "  Phase $(basename "$s" .sum | tr -dc 0-9): no analysis (sampler error, see above)"; continue; }
  label=$(sed -n 's/^label=//p' "$s")
  mean=$(sed -n 's/^app_mean_ms=//p' "$s")
  printf '  %-3s %-44.44s %9s %9s %8s %10s %8s  %s\n' "$(basename "$s" .sum | tr -dc 0-9)" "$label" "${mean:--}" \
    "$(sed -n 's/^app_p99_ms=//p' "$s" | grep . || echo -)" "$(sed -n 's/^app_iops=//p' "$s" | grep . || echo -)" \
    "$(sed -n 's/^dev_frac=//p' "$s" | sed 's/^\([0-9]*\)$/\1%/')" "$(sed -n 's/^score_ssd=//p' "$s")/$(sed -n 's/^score_cpu=//p' "$s")" \
    "$(sed -n 's/^verdict=//p' "$s")"
  [ -n "$mean" ] && MEAN["${label#sync4k }"]=$mean
done

# /mnt/user vs. direct path
for a in "${!MEAN[@]}"; do
  case "$a" in /mnt/user/*|/mnt/user0/*) ;; *) continue ;; esac
  for b in "${!MEAN[@]}"; do
    case "$b" in /mnt/user*) continue ;; esac
    awk -v a="$a" -v b="$b" -v ma="${MEAN[$a]}" -v mb="${MEAN[$b]}" 'BEGIN {
      if (mb <= 0) exit
      r = ma / mb
      printf "\n  Comparison: %s avg %.2f ms vs. %s avg %.2f ms => factor %.1f\n", a, ma, b, mb, r
      if (r >= 1.5) print "  => The detour via /mnt/user (shfs/FUSE) costs considerable latency - this is CPU/software, not the SSD."
      else print "  => shfs adds hardly any latency."
    }'
  done
done

if [ ${#WARN[@]} -gt 0 ]; then
  echo
  echo "  Issues from the system check:"
  for w in "${WARN[@]}"; do echo "   - $w"; done
fi

echo
if command -v systemctl >/dev/null 2>&1 && systemctl is-active -q write-latency-diag.service 2>/dev/null; then
  sport=$(sed -n 's/^ *port *= *\([0-9]*\).*/\1/p' "$SVC_CONF" 2>/dev/null | tail -1); sport=${sport:-81}
  echo
  echo "  The service records continuously: http://$(hostname -I 2>/dev/null | awk '{print $1}'):$sport/"
  echo "  Report over the whole period: curl -s http://127.0.0.1:$sport/api/report"
fi
echo "  Report: $OUT/report.txt   Samples: $CSV"
exec >&- 2>&-
wait "$TEE_PID" 2>/dev/null
