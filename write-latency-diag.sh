#!/bin/bash
#
# write-latency-diag.sh
#
# Beobachtet Schreiblatenz und grenzt ein, ob die Wartezeit auf den SSDs
# (Gerät, Controller, Flush) oder oberhalb davon (CPU, shfs/FUSE, ZFS, btrfs,
# Locks) entsteht.
#
# Liest nur /proc und /sys. Schreibtests (-t / -S) schreiben ausschließlich
# eine temporäre Testdatei in das angegebene Verzeichnis und löschen sie danach.
#

VERSION="1.2"

PASSIVE=""            # Dauer der passiven Beobachtung in Sekunden
INTERVAL=1
TEST_RUNTIME=30
TEST_SIZE="256M"
SEQ_SIZE=""
OUTBASE="/tmp"
DEVRE='^(sd[a-z]+|nvme[0-9]+n[0-9]+|vd[a-z]+|xvd[a-z]+)$'
SKIP_STATIC=0
QUIET=0
TRACE=1
STATE_DIR="/var/lib/write-latency-diag"   # SMART-Verlauf für die aktuelle Schreibverstärkung
TARGETS=()

usage() {
  cat <<EOF
write-latency-diag.sh $VERSION - Schreiblatenz: SSD oder CPU/Software?

Aufruf: $0 [Optionen]

  -d SEK     Passiv beobachten (Standard: 60 s, wenn kein -t angegeben ist).
             Währenddessen das Problem auslösen/abwarten. Ctrl+C beendet
             vorzeitig und zeigt trotzdem die Auswertung.
  -t DIR     Aktiver Test: 4k-Schreiben mit O_SYNC (QD1, wie Datenbanken/
             Docker) in DIR, während gemessen wird. Mehrfach angeben, um
             Pfade zu vergleichen, z.B. -t /srv/data/test -t /var/lib/docker/test
  -r SEK     Laufzeit je aktivem Test (Standard: $TEST_RUNTIME)
  -S GRÖSSE  Zusätzlich sequentiellen Dauerschreibtest im ersten -t DIR
             (z.B. 20G) - zeigt Einbrüche durch vollen SLC-Cache.
             Achtung: schreibt GRÖSSE auf die SSD.
  -i SEK     Messintervall (Standard: $INTERVAL)
  -D REGEX   Nur diese Geräte beobachten (Standard: $DEVRE)
  -o DIR     Basisverzeichnis für Report/CSV (Standard: $OUTBASE)
  -n         Systemcheck überspringen
  -q         Nur auffällige Intervalle ausgeben (für lange Läufe)
  -T         Kein bpftrace-Tracing (fsync-Aufrufer, beendete Prozesse)
  -h         Hilfe

Beispiele:
  $0 -d 300
  $0 -d 86400 -q -i 5
  $0 -t /srv/.lattest
  $0 -t /srv/.lattest -S 30G
EOF
}

while getopts "d:t:r:S:i:D:o:nqTh" opt; do
  case $opt in
    d) PASSIVE=$OPTARG ;;
    t) TARGETS+=("${OPTARG%/}") ;;
    r) TEST_RUNTIME=$OPTARG ;;
    S) SEQ_SIZE=$OPTARG ;;
    i) INTERVAL=$OPTARG ;;
    D) DEVRE=$OPTARG ;;
    o) OUTBASE=$OPTARG ;;
    n) SKIP_STATIC=1 ;;
    q) QUIET=1 ;;
    T) TRACE=0 ;;
    h) usage; exit 0 ;;
    *) usage; exit 1 ;;
  esac
done

if [ -z "$PASSIVE" ]; then
  if [ ${#TARGETS[@]} -eq 0 ]; then PASSIVE=60; else PASSIVE=0; fi
fi
if [ -n "$SEQ_SIZE" ] && [ ${#TARGETS[@]} -eq 0 ]; then
  echo "-S braucht mindestens ein -t DIR" >&2
  exit 1
fi

for t in "${TARGETS[@]}"; do
  mkdir -p "$t" 2>/dev/null
  if ! touch "$t/.wlat-probe" 2>/dev/null; then
    echo "Kann nicht in '$t' schreiben." >&2
    exit 1
  fi
  rm -f "$t/.wlat-probe"
done

HAVE_FIO=0
command -v fio >/dev/null 2>&1 && [ -z "${NO_FIO:-}" ] && HAVE_FIO=1
HAVE_BT=0
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
hint()    { printf '  [?]  %s\n' "$*"; WARN+=("(prüfen) $*"); }

declare -A ROLE
MDMEMBERS=""          # physische Laufwerke in mdadm-Arrays (für die Auswertung)

# Die SMART-Zähler gelten für die ganze Lebensdauer. Jeder Lauf speichert sie, damit der
# nächste Lauf die Schreibverstärkung seit dem letzten Messpunkt zeigt (aktueller Zustand).
waf_history() { # dev serial num den host_gib nand_in_gib(0/1)
  local f="$STATE_DIR/smart-history.csv" now prev
  [ -n "$2" ] || return
  now=$(date +%s)
  # bevorzugt einen Messpunkt >= 12 h alt, sonst >= 1 h
  [ -r "$f" ] && prev=$(awk -F, -v s="$2" -v now="$now" '$2 == s {
      if (now - $1 >= 43200) l12 = $0; else if (now - $1 >= 3600) l1 = $0 }
      END { print (l12 != "" ? l12 : l1) }' "$f")
  if [ -n "$prev" ]; then
    awk -F, -v now="$now" -v num="$3" -v den="$4" -v host="$5" -v gib="$6" -v l="$prev" 'BEGIN {
      split(l, p, ","); h = (now - p[1]) / 3600
      dn = num - p[3]; dd = den - p[4]; dh = host - p[5]
      c = "date -d @" p[1] " \"+%F %H:%M\""; c | getline ts; close(c)
      printf "      Seit %s (%.0f h): Host +%.0f GiB", ts, h, dh
      if (gib) printf ", NAND +%.0f GiB", dn
      if (dd > 0) printf "  =>  WAF in diesem Zeitraum %.1f", dn / dd
      printf "   (Host %.0f GiB/Tag)\n", dh * 24 / h
      exit (dd > 0 && dn >= 5 * dd) ? 3 : 0 }'
    [ $? -eq 3 ] && warn "$1: Auch aktuell (seit dem letzten Messpunkt) hohe Schreibverstärkung - die Ursache besteht weiter."
  else
    info "Verlauf: Messpunkt gespeichert ($f). Der nächste Lauf (frühestens in 1 h, aussagekräftig ab ~12 h) zeigt die aktuelle WAF."
  fi
  mkdir -p "$STATE_DIR" 2>/dev/null && printf '%s,%s,%s,%s,%s\n' "$now" "$2" "$3" "$4" "$5" >> "$f"
}

# Reicht wöchentliches TRIM? ext4 merkt sich, welche Blockgruppen schon getrimmt sind. Jeder weitere
# fstrim-Lauf im selben Boot meldet deshalb ungefähr, wie viel seit dem letzten Lauf gelöscht wurde
# (eher etwas zu viel, weil ganze Gruppen neu getrimmt werden). Der erste Lauf nach einem Neustart
# gibt den ganzen freien Platz frei und zählt nicht. Bei XFS/btrfs ist die Zahl nicht aussagekräftig.
# Bis zum nächsten TRIM verhält sich Gelöschtes für die SSD wie belegter Platz. Consumer-SSDs haben nur
# ~7 % Reserve: Sammelt sich mehr als ~2 % der Kapazität an, lohnt tägliches TRIM.
trim_advice() { # OnCalendar-Wert des fstrim.timer
  command -v journalctl >/dev/null 2>&1 || return
  local mnt src size rota res period
  while read -r src mnt; do
    rota=$(lsblk -ndo ROTA "$src" 2>/dev/null | tr -d ' ')
    [ "$rota" = 0 ] || continue
    size=$(df -B1 --output=size "$mnt" 2>/dev/null | tail -1 | tr -d ' ')
    case "$1" in
      daily|*-*-*\ 0*) period=1 ;; weekly|"") period=7 ;; monthly) period=30 ;; *) period="" ;;
    esac
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
        # Median der letzten (bis zu) 5 Läufe
        k = 0; for (i = (n > 5 ? n - 4 : 1); i <= n; i++) { k++; r[k] = R[i]; d[k] = I[i] }
        for (i = 1; i <= k; i++) for (j = i + 1; j <= k; j++) {
          if (r[j] < r[i]) { x = r[i]; r[i] = r[j]; r[j] = x }
          if (d[j] < d[i]) { x = d[i]; d[i] = d[j]; d[j] = x }
        }
        printf "%.0f %.2f %d\n", r[int((k + 1) / 2)], d[int((k + 1) / 2)], k
      }')
    [ -n "$res" ] || continue
    if [ "$res" = none ]; then
      info "TRIM $mnt: noch keine Empfehlung möglich - es braucht mindestens zwei fstrim-Läufe ohne Neustart dazwischen."
      continue
    fi
    local rate interval runs
    read -r rate interval runs <<<"$res"
    [ -n "$period" ] || period=$interval
    awk -v m="$mnt" -v rate="$rate" -v p="$period" -v size="${size:-0}" -v runs="$runs" -v cal="${1:-?}" 'BEGIN {
      back = rate * p; pct = size > 0 ? 100 * back / size : 0
      printf "      TRIM %s: Ø %.1f GiB/Tag gelöscht (aus %d fstrim-Läufen) - bei Zeitplan \"%s\" bis zu %.0f GiB (%.1f %% der Kapazität) ungetrimmt\n", m, rate / 2^30, runs, cal, back / 2^30, pct
      exit (p > 1 && pct >= 2) ? 3 : (p <= 1 && rate * 7 < 0.02 * size) ? 4 : (p > 1) ? 5 : 0 }'
    case $? in
      3) hint "TRIM $mnt: Zwischen zwei TRIM-Läufen sammelt sich viel gelöschter Platz an, den die SSD noch für belegt hält (mehr Garbage Collection, höhere Schreibverstärkung). Täglich trimmen: systemctl edit fstrim.timer und dort [Timer] OnCalendar= sowie OnCalendar=daily eintragen." ;;
      4) info "TRIM $mnt: Es wird wenig gelöscht - wöchentliches TRIM würde hier auch reichen." ;;
      5) ok "TRIM $mnt: Der Zeitplan reicht - bis zum nächsten Lauf sammelt sich wenig gelöschter Platz an." ;;
    esac
  done < <(awk '$3 == "ext4" && $1 ~ "^/dev/" {print $1, $2}' /proc/mounts | sort -u -k2,2)
}

# ---------------------------------------------------------------------------
# Systemcheck
# ---------------------------------------------------------------------------
static_check() {
  local ver=""
  if [ -f /etc/unraid-version ]; then
    ver=$(. /etc/unraid-version 2>/dev/null; echo "Unraid $version")
  elif [ -f /etc/os-release ]; then
    ver=$(. /etc/os-release 2>/dev/null; echo "$PRETTY_NAME")
  fi
  section "Systemüberblick"
  info "Host: $(hostname)   Kernel: $(uname -r)   $ver"
  [ "$(id -u)" -ne 0 ] && warn "Nicht als root gestartet - SMART-Daten und einige Werte fehlen."

  # CPU
  local model threads gov drv epp curf maxf
  model=$(awk -F': *' '/^model name/{print $2; exit}' /proc/cpuinfo)
  threads=$(grep -c '^processor' /proc/cpuinfo)
  gov=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "?")
  drv=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver 2>/dev/null || echo "?")
  epp=$(cat /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference 2>/dev/null)
  curf=$(cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq 2>/dev/null | awk '{s+=$1;n++} END{if(n) printf "%.0f", s/n/1000}')
  maxf=$(awk '{printf "%.0f", $1/1000}' /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq 2>/dev/null)
  info "CPU: $model ($threads Threads), Load: $(cut -d' ' -f1-3 /proc/loadavg)"
  info "Takt: Treiber $drv, Governor $gov${epp:+, EPP $epp}, aktuell Ø ${curf:-?} MHz / max ${maxf:-?} MHz"
  case "$gov" in
    powersave)
      case "$drv" in
        intel_pstate|amd-pstate-epp) ;;
        *) warn "Governor 'powersave' mit Treiber $drv hält die CPU auf Minimaltakt - erhöht Latenz." ;;
      esac ;;
    conservative) hint "Governor 'conservative' taktet träge hoch - kurze IO-Bursts laufen auf niedrigem Takt." ;;
  esac
  [ "$epp" = "power" ] && hint "EPP=power: CPU taktet sehr zurückhaltend hoch. Test: echo balance_performance > /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference"

  # Dirty page cache
  local memkb dr db dirty_mb
  memkb=$(awk '/^MemTotal/{print $2}' /proc/meminfo)
  dr=$(cat /proc/sys/vm/dirty_ratio 2>/dev/null)
  db=$(cat /proc/sys/vm/dirty_bytes 2>/dev/null)
  if [ "${db:-0}" -gt 0 ]; then dirty_mb=$((db / 1048576)); else dirty_mb=$((memkb * dr / 100 / 1024)); fi
  info "RAM: $((memkb / 1048576)) GB, vm.dirty_ratio=$dr, dirty_background_ratio=$(cat /proc/sys/vm/dirty_background_ratio) (=> bis ~${dirty_mb} MB ungeschriebene Daten)"
  [ "$dirty_mb" -gt 4096 ] && hint "Großer Dirty-Puffer (~${dirty_mb} MB): bei Dauerschreiblast entstehen lange Schreibstaus, wenn der Puffer voll ist."

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
  section "Laufwerke"
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
      # sysfs liefert bei SATA nur 4 Zeichen der Firmware-Version
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
    info "Port: ${ata:-?} ${spd:+Link $spd}  ALPM: ${alpm:-n/a}  Scheduler: ${sched:-?}  Schreibcache: ${wc:-?}  TRIM: $([ "${disc:-0}" -gt 0 ] && echo ja || echo nein)"

    if [ -n "$alpm" ] && [ "$alpm" != "max_performance" ] && [ "$alpm" != "keep_firmware_settings" ]; then
      warn "$d: SATA-Link-Power-Management '$alpm' - Link schläft zwischen Zugriffen, Aufwachen kostet Latenz (typisch nach powertop --auto-tune). Test: echo max_performance > /sys/class/scsi_host/$host/link_power_management_policy"
    fi
    if [ "$rot" = 0 ] && [ -n "$spd" ] && [ "$spd" != "6.0 Gbps" ] && [ "$spd" != "<unknown>" ]; then
      warn "$d: SATA-Link läuft nur mit $spd (erwartet 6.0 Gbps) - Kabel/Backplane/Port prüfen."
    fi
    [ "$rot" = 0 ] && [ "${disc:-0}" -eq 0 ] && hint "$d: Gerät/Schicht meldet kein TRIM - ohne TRIM werden SSDs bei Schreiblast langsamer."
    [ "$wc" = "write through" ] && [ "$rot" = 0 ] && hint "$d: Schreibcache ist 'write through' (aus) - deutlich langsamere Schreibzugriffe."
    # Der Schreibcache-Schalter (SET FEATURES, hdparm -W) ist laut ATA-Standard flüchtig: Nach dem Einschalten
    # gilt die Werkseinstellung des Laufwerks, und manche BIOS/UEFI schalten ihn beim Start ab.
    # Dauerhaft im Laufwerk lässt er sich nur über SCT Feature Control setzen (smartctl -s wcache-sct,on,p).
    if [[ $d == sd* ]] && [ "$kind" != USB ] && [ "$(id -u)" -eq 0 ]; then
      local hw="" sct="" boot="" fix wcinfo=""
      command -v hdparm >/dev/null 2>&1 && hw=$(hdparm -W "$dev" 2>/dev/null | sed -n 's/.*write-caching *= *\([01]\).*/\1/p')
      command -v smartctl >/dev/null 2>&1 && sct=$(smartctl -g wcache-sct "$dev" 2>/dev/null | sed -n 's/^SCT Write Cache Control: *//p' | head -1)
      grep -qiE 'not supported|unavailable' <<<"$sct" && sct=""
      # Erster Eintrag dieses Starts = Zustand bei der Erkennung, bevor udev-Regeln o.ä. eingreifen
      boot=$( (journalctl -k -b -o cat 2>/dev/null || dmesg 2>/dev/null) | grep -m1 "\[$d\] Write cache:" | sed -n 's/.*Write cache: *\([a-z]*\).*/\1/p')
      [ -n "$hw" ] && wcinfo="Laufwerk $([ "$hw" = 1 ] && echo an || echo aus)"
      [ -n "$boot" ] && wcinfo="${wcinfo:+$wcinfo, }beim Start $([ "$boot" = enabled ] && echo an || echo aus)"
      [ -n "$sct" ] && wcinfo="${wcinfo:+$wcinfo, }SCT: $sct"
      [ -n "$wcinfo" ] && info "Schreibcache: $wcinfo"
      if [ -n "$sct" ]; then
        fix="dauerhaft im Laufwerk einschalten: smartctl -s wcache-sct,on,p $dev (danach Kaltstart und prüfen: journalctl -k -b | grep -i 'write cache')"
      else
        fix="bei jedem Start einschalten, z.B. per udev-Regel mit hdparm -W1 $dev (das Laufwerk kennt kein SCT Feature Control)"
      fi
      if grep -qi 'force disabled' <<<"$sct"; then
        warn "$d: Der Schreibcache ist per SCT dauerhaft abgeschaltet - hdparm -W1 wirkt nicht. Einschalten: smartctl -s wcache-sct,on,p $dev"
      elif [ "$hw" = 0 ]; then
        warn "$d: Schreibcache im Laufwerk ist AUS - jeder Schreibzugriff geht direkt in den Flash: langsam und bei Consumer-SSDs sehr hohe Schreibverstärkung. Abhilfe: $fix."
      elif [ "$hw" = 1 ] && [ "$wc" = "write through" ]; then
        warn "$d: Das Laufwerk hat den Schreibcache AN, der Kernel hält ihn aber für aus ('write through') und schickt deshalb keine Flushes - bei Stromausfall droht Datenverlust. Abhilfe: echo 1 > /sys/block/$d/device/rescan"
      elif [ "$boot" = disabled ] && ! grep -qi 'force enabled' <<<"$sct"; then
        hint "$d: Der Schreibcache ist beim Start aus (BIOS oder Firmware) und wird erst danach eingeschaltet (udev-Regel/hdparm). Greift das einmal nicht, läuft die SSD ohne Cache. Besser: $fix."
      fi
    fi
    case "$role" in
      */Parity|*/Data)
        [ "$rot" = 0 ] && warn "$d: SSD im Unraid-Array ($role). Kein TRIM im Array und jede Schreiboperation erzeugt Paritäts-Read-Modify-Write - SSDs gehören in einen Pool." ;;
    esac

    if [ -n "$sm" ]; then
      trim=$(sed -n 's/^TRIM Command: *//p' <<<"$sm")
      sata=$(sed -n 's/^SATA Version is: *//p' <<<"$sm")
      [ -n "$sata$trim" ] && info "SMART: ${sata:+$sata} ${trim:+| TRIM: $trim}"
      # SanDisk/WD-SSDs: 173 = Ø Löschzyklen, 233 = NAND-Schreibmenge (GiB), 241 = Host-Schreibmenge (GiB).
      # Ältere smartctl-Datenbanken kennen die Namen nicht und zeigen falsche/Unknown-Bezeichnungen.
      wdsd=0
      grep -qE 'SanDisk|^SD |SDSSD|WDS[0-9]|WD (Blue|Red|Green)' <<<"$model" && [ "$rot" = 0 ] && wdsd=1
      # Für Verschleiß-Attribute ist der normierte Wert (100 = neu) aussagekräftiger als der Rohwert.
      attrs=$(awk -v wdsd=$wdsd '$1 ~ /^(5|9|169|173|177|194|199|202|230|231|232|233|234|241)$/ && NF >= 10 {
          n = $2
          if (wdsd) { if ($1 == 173) n = "Avg_Erase_Count"; else if ($1 == 230) n = "Media_Wearout"; else if ($1 == 233) n = "NAND_GiB_Written"
                      else if ($1 == 234) n = "NAND_GiB_Written_SLC"; else if ($1 == 241) n = "Host_GiB_Written" }
          printf "%s:%s=%s%s  ", $1, n, $10, ($1 ~ /^(169|173|177|202|230|231|232|233)$/ ? " (norm. " ($4 + 0) ")" : "") }' <<<"$sm")
      [ -z "$attrs" ] && attrs=$(grep -E '^(Temperature|Percentage Used|Data Units Written|Media and Data Integrity Errors|Unsafe Shutdowns):' <<<"$sm" | sed 's/  */ /g' | paste -sd'|' -)
      [ -n "$attrs" ] && info "SMART: $attrs"
      crc=$(awk '$1==199 {print $10+0}' <<<"$sm")
      realloc=$(awk '$1==5 {print $10+0}' <<<"$sm")
      [ "${crc:-0}" -gt 0 ] && warn "$d: UDMA_CRC_Error_Count=$crc - Übertragungsfehler (Kabel/Backplane). Fehler kosten Retries und damit Latenz. Steigt der Wert weiter?"
      [ "${realloc:-0}" -gt 0 ] && warn "$d: $realloc reallokierte Sektoren."
      # Schreibverstärkung: WAF = num/den, host = Host-Schreibmenge in GiB.
      # SanDisk/WD: 233 NAND-GiB / 241 Host-GiB. Crucial/Micron: (247 Host- + 248 FTL-Pages) / 247, Host über 246 (LBAs).
      local nand hostw poh erase num="" den="" hgib="" serial
      poh=$(awk '$1==9 {print $10+0}' <<<"$sm")
      serial=$(sed -n 's/^Serial Number: *//p' <<<"$sm" | head -1)
      if [ $wdsd -eq 1 ]; then
        nand=$(awk '$1==233 {print $10+0}' <<<"$sm"); hostw=$(awk '$1==241 {print $10+0}' <<<"$sm")
        erase=$(awk '$1==173 {print $10+0}' <<<"$sm")
        if [ "${nand:-0}" -gt 0 ] && [ "${hostw:-0}" -gt 0 ]; then
          num=$nand; den=$hostw; hgib=$hostw
          awk -v n="$nand" -v h="$hostw" -v poh="${poh:-0}" -v e="${erase:-}" 'BEGIN {
            printf "      Schreibverstärkung (WAF = NAND/Host): %.1f", n / h
            if (poh > 24) printf "   Host %.0f GiB/Tag, NAND %.0f GiB/Tag", h * 24 / poh, n * 24 / poh
            if (e != "") printf "   Ø Löschzyklen %s", e
            print "" }'
        fi
      elif grep -q 'FTL_Program_Page_Count' <<<"$sm"; then
        read -r num den hgib < <(awk '$1==247 {h=$10} $1==248 {f=$10} $1==246 {l=$10}
          END { if (h > 0) printf "%.0f %.0f %.1f\n", h + f, h, l * 512 / 2^30 }' <<<"$sm")
        [ -n "$den" ] && awk -v n="$num" -v h="$den" -v g="$hgib" -v poh="${poh:-0}" 'BEGIN {
            printf "      Schreibverstärkung (WAF = (Host+FTL-Pages)/Host-Pages): %.1f", n / h
            if (poh > 24) printf "   Host %.0f GiB/Tag", g * 24 / poh
            print "" }'
      fi
      if [ -n "$den" ]; then
        awk -v n="$num" -v h="$den" 'BEGIN { exit !(n >= 5 * h) }' &&
          warn "$d: interne Schreibverstärkung $(awk -v n="$num" -v h="$den" 'BEGIN{printf "%.0f", n/h}')x - die SSD schreibt intern ein Vielfaches dessen, was das System schreibt. Typisch für viele kleine fsync-Schreibzugriffe (Datenbanken, NVR, Logs) auf Consumer-SSDs ohne Power-Loss-Protection: Die SSD ist dauerhaft mit Garbage Collection beschäftigt (Latenzspitzen) und verschleißt schnell."
        waf_history "$d" "$serial" "$num" "$den" "$hgib" "$wdsd"
      fi
    fi

    if [ "$rot" = 0 ] && grep -qiE 'QVO|BX500|A400|SU630|SU650|660p|665p|670p|Crucial P1|P3 Plus|WD ?Green|WDS[0-9]+G[0-9]A|SSD Plus|SDSSDA|Intenso|NV1|NV2|TM8FP' <<<"$model"; then
      warn "$d: '$model' ist als QLC- und/oder DRAM-lose SSD bekannt - bricht bei Dauerlast stark ein (SLC-Cache voll) und hat oft hohe Flush-Latenz."
    fi
  done

  section "Speicher-Layout"
  if command -v lsblk >/dev/null 2>&1; then
    lsblk -e 7 -o NAME,TYPE,FSTYPE,SIZE,MOUNTPOINT 2>/dev/null | sed 's/^/      /'
  fi
  echo
  awk '$1 ~ "^/dev/" && $1 !~ "^/dev/loop" && $2 !~ "^/(snap|boot/efi)" && $3 != "squashfs" || $3 == "zfs" || $3 == "fuse.shfs" {
         printf "      %-26s %-8s %s\n", $2, $3, substr($4, 1, 80) }' /proc/mounts
  if grep -q ' /mnt/user fuse.shfs' /proc/mounts; then
    hint "/mnt/user läuft über shfs (FUSE). Jeder Zugriff dort kostet CPU. Vergleich: -t /mnt/user/<share>/x -t /mnt/<pool>/<share>/x"
  fi
  if grep -qE ' (ext4|xfs|btrfs) .*(^|,)(sync|dirsync)(,|$)' /proc/mounts 2>/dev/null; then
    warn "Ein Dateisystem ist mit 'sync' gemountet - jeder Schreibzugriff wartet auf das Gerät."
  fi
  if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    if [ "$(systemctl is-enabled fstrim.timer 2>/dev/null)" = "enabled" ]; then
      local cal
      cal=$(systemctl show fstrim.timer -p TimersCalendar --value 2>/dev/null | sed -n 's/.*OnCalendar=\([^ ;]*\).*/\1/p' | head -1)
      ok "fstrim.timer aktiv (${cal:-Zeitplan unbekannt})."
      trim_advice "$cal"
    elif ! grep -qE '(^|,)discard' <(awk '{print $4}' /proc/mounts); then
      hint "fstrim.timer ist nicht aktiv und kein Dateisystem nutzt 'discard' - ohne TRIM werden SSDs bei Schreiblast langsamer (systemctl enable --now fstrim.timer)."
    fi
  fi

  # Linux Software-RAID (mdadm). Unraid nutzt eigene md-Treiber ohne /proc/mdstat-Arrays.
  if grep -qE '^md[0-9]+ : active' /proc/mdstat 2>/dev/null; then
    section "Software-RAID (mdadm)"
    sed 's/^/      /' /proc/mdstat
    if grep -qE '(resync|recovery|check|reshape) *=' /proc/mdstat; then
      warn "Ein MD-RAID führt gerade resync/check/recovery aus - das bremst Schreibzugriffe massiv. Ubuntu startet 'checkarray' jeden ersten Sonntag im Monat."
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
      info "${md##*/}: $lvl, Bitmap: $(cat "$md/md/bitmap/location" 2>/dev/null || echo none)${lvl:+, }$( [ -f "$md/md/stripe_cache_size" ] && echo "stripe_cache_size=$(cat "$md/md/stripe_cache_size")")"
      # RAID10 near-Layout: aufeinanderfolgende Slots bilden Spiegelgruppen, die immer dieselben Daten bekommen
      if [ "$lvl" = raid10 ]; then
        local layout nc ndev groups
        layout=$(cat "$md/md/layout" 2>/dev/null); ndev=$(cat "$md/md/raid_disks" 2>/dev/null)
        nc=$(( ${layout:-0} & 255 ))
        if [ "$nc" -ge 2 ] && [ $(( (${layout:-0} >> 8) & 255 )) -eq 1 ] && [ "${ndev:-0}" -gt 0 ] && [ $((ndev % nc)) -eq 0 ]; then
          groups=$(for s in "$md"/md/dev-*; do
              sl=$(cat "$s/slot" 2>/dev/null); part=${s##*/dev-}
              [[ $sl =~ ^[0-9]+$ ]] || continue
              [ -e "/sys/block/$part" ] || part=$(basename "$(readlink -f "/sys/class/block/$part/..")")
              echo "$((sl / nc)) $part"
            done | sort -n | awk '{ g[$1] = g[$1] (g[$1] == "" ? "" : "+") $2 } END { for (i = 0; i in g; i++) printf "%s%s", (i ? ", " : ""), g[i] }')
          [ -n "$groups" ] && info "${md##*/}: Spiegelgruppen (bekommen jeweils dieselben Schreibzugriffe): $groups"
        fi
      fi
      case "$lvl" in
        raid1|raid10|raid5|raid6)
          info "${md##*/}: jedes fsync/Flush geht an alle Mitglieder (${members# }) - die jeweils langsamste SSD bestimmt die Latenz." ;;&
        raid5|raid6)
          hint "${md##*/} ist $lvl: kleine Schreibzugriffe brauchen Read-Modify-Write für die Parität, und die Paritätsberechnung läuft im Kernel-Thread ${md##*/}_$lvl (CPU). Für viele kleine/Sync-Writes ist RAID10 deutlich schneller."
          if [ "$(cat "$md/md/stripe_cache_size" 2>/dev/null || echo 0)" -le 256 ]; then
            hint "${md##*/}: stripe_cache_size ist klein. Test: echo 4096 > $md/md/stripe_cache_size (kostet RAM: 4096 x 4 KB x Anzahl Disks)."
          fi ;;
      esac
    done
  fi

  # LVM / dm-crypt
  if command -v dmsetup >/dev/null 2>&1 && dmsetup table 2>/dev/null | grep -q ' crypt '; then
    info "dm-crypt (LUKS) aktiv: Verschlüsselung kostet CPU, Threads heißen kcryptd/dmcrypt_write."
  fi

  if command -v zpool >/dev/null 2>&1 && [ -n "$(zpool list -H -o name 2>/dev/null)" ]; then
    section "ZFS"
    local pool
    for pool in $(zpool list -H -o name); do
      info "Pool $pool: ashift=$(zpool get -H -o value ashift "$pool")  $(zfs get -H -o property,value sync,compression,recordsize,atime,encryption "$pool" | awk '{printf "%s=%s  ", $1, $2}')"
      zpool list -v -H -o name,size,alloc,frag,cap,health "$pool" 2>/dev/null | sed 's/^/        /'
      [ "$(zfs get -H -o value sync "$pool")" = "always" ] && warn "ZFS-Pool $pool: sync=always - jeder Schreibzugriff wartet auf Flush."
    done
    info "Tipp: 'zpool iostat -vl 1' zeigt parallel, ob Zeit in Warteschlangen (syncq/asyncq) oder auf der Disk (disk_wait) entsteht."
  fi

  section "Kernel-Log (ATA/IO-Fehler)"
  local errs
  errs=$(dmesg 2>/dev/null | grep -Ei 'ata[0-9.]+:.*(error|exception|failed|hard resetting|link down|SError|timeout)|I/O error|blk_update_request|critical medium')
  if [ -n "$errs" ]; then
    warn "$(wc -l <<<"$errs") ATA/IO-Fehlermeldungen im Kernel-Log (letzte 8 unten). Resets/Timeouts erzeugen Latenzspitzen von Sekunden."
    tail -n 8 <<<"$errs" | sed 's/^/        /'
  else
    ok "Keine ATA/IO-Fehler im Kernel-Log."
  fi
}

# ---------------------------------------------------------------------------
# Sampler (awk, läuft parallel zur Last)
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
    D_iot[d] = a[13]; D_tiq[d] = a[14]
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
  # Schreibmenge je Prozess (inkl. beendeter Kindprozesse, die er abgeräumt hat); nur als root vollständig.
  # Netto: Daten, die vor dem Zurückschreiben wieder gelöscht werden (cancelled_write_bytes), erreichen die Platte nie.
  # Über grep statt getline: mawk bricht bei Lesefehlern (EACCES) auf /proc/<pid>/io komplett ab.
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

  # Beim Ende eines Prozesses rechnet der Kernel seine gesamte Schreibmenge dem abräumenden Elternprozess zu.
  # Was bereits beim Kind gezählt wurde, wird dort wieder abgezogen, damit nichts doppelt erscheint.
  # Kinder vor ihren Eltern abarbeiten, falls beide im selben Intervall enden (z.B. timeout -> dd).
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
    # Gelöschtes kann ein Intervall später als das Schreiben zählen: in der Summe verrechnen, in der Zeile nicht
    if (dd != 0) Wtot[P_comm[p]] += dd
    if (dd > 0) Wd[P_comm[p]] += dd
  }
  wtop = topw(Wd, dt, 3)

  # Ausgabe sammeln: mit -q nur Intervalle zeigen, in denen ein Gerät auffällt
  tclock = clock()
  buf = sprintf("%-8s %4.0f%% %5.0f%%(c%-3s) %5.0f%% %7s %6s/%-6s   %s\n", tclock, busy, maxc, substr(maxcn, 4), iow, fp(pc), fp(pis), fp(pif), top)
  if (wtop != "") buf = buf "   schreibt: " wtop "\n"
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
    # Summe der Anfragezeiten inkl. Flush (Flushes zählen nicht in io_ticks).
    # Bei QD1 = Anteil der Zeit, in der auf das Gerät gewartet wird.
    devt = 100 * (dwt + drt + dft) / (dt * 1000)
    aqu = dtiq / (dt * 1000)
    reqkb = (dw > 0) ? dws * 512 / 1024 / dw : 0
    if (devt > maxdevt) maxdevt = devt
    totw += dw

    T_wios[d] += dw; T_wsec[d] += dws; T_wtk[d] += dwt; T_fios[d] += df; T_ftk[d] += dft
    T_rsec[d] += drs

    if (dw > 0 || df > 0) {
      A_n[d]++
      A_util[d] += util
      flag = ""
      # Hohe await-Werte bei hohem Durchsatz sind normale Warteschlange (Writeback),
      # langsam ist hohe Latenz bei wenig Durchsatz.
      if (dw >= 5 && ((wa >= 10 && wmbs < 100) || (wa >= 50 && wmbs < 200) || wa >= 1000)) flag = "<< LANGSAM"
      if (df >= 3 && fa >= 20) flag = "<< LANGSAM (Flush)"
      # Wenige Anfragen, die aber hunderte ms hängen, während das Gerät voll belegt ist: Stall im Gerät.
      if (flag == "" && util >= 50 && ((dw > 0 && wa >= 200) || (df > 0 && fa >= 200))) flag = "<< LANGSAM (Stall)"
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
      printf "%-8s %5s %11s %6s %7s %13s   %s\n", "Zeit", "CPU", "max.Kern", "iowait", "PSIcpu", "PSIio s/f", "Top-Prozesse (% eines Kerns)"
    Nprinted++
    printf "%s", buf
    fflush()
  }
  if (totw >= 5) { Nact++; S_devt += (maxdevt > 100 ? 100 : maxdevt) }
  # Intervalle, in denen ein Gerät hängt, während ein anderes gleichzeitig schnell antwortet
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
function summary(   i, d, k, n, x, aw, af, minaw, bf, first, last, tn, tops, wgb, busy, sat, verdict, cnt, avgp, dl, tpa, nst) {
  printf "\n--- Auswertung: %s (%d Messpunkte à %ss, %s) ---\n", label, N, interval_s, (S_dt < 3600 ? sprintf("%.0f s", S_dt) : sprintf("%.1f h", S_dt / 3600))
  if (N < 2) { print "  Zu wenige Messpunkte."; return }
  busy = S_busy / N; sat = 100 * Nsat / N
  printf "CPU:  Ø Auslastung %.0f%%, Ø iowait %.0f%% (= Warten auf IO, keine CPU-Last), ein Kern >=95%% in %.0f%% der Intervalle\n", busy, S_iow / N, sat
  if (N_pc) printf "PSI:  cpu some Ø %.1f%%   io some Ø %.1f%%   io full Ø %.1f%%\n", S_pc / N_pc, S_pis / N_pi, S_pif / N_pi
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
  printf "Top-Prozesse (Ø %% eines Kerns): %s\n", (tops == "" ? "-" : tops)
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
    printf "Top-Schreiber (Ø über die Phase): %s\n", tops
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
      if (tops != "") printf "Schreiber in den %d langsamen Intervallen: %s\n", Nslow, tops
    }
    print "  (Elternprozesse wie systemd, cron oder containerd-shim enthalten die Schreibmenge ihrer beendeten Kindprozesse.)"
  }

  printf "\n  %-8s %10s %9s %8s %10s %10s %9s %9s %7s %12s\n", "Gerät", "geschr.", "Ø Req", "Ø await", "max await", "Flush n", "Flush Ø", "Flush max", "Ø util", "Langsam"
  minaw = -1
  for (i = 1; i <= Ndev; i++) {
    d = Dlist[i]
    if (!(d in A_n)) continue
    aw = T_wios[d] ? T_wtk[d] / T_wios[d] : 0
    af = T_fios[d] ? T_ftk[d] / T_fios[d] : 0
    wgb = T_wsec[d] * 512 / 1e9
    printf "  %-8s %7.2f GB %7.0fK %6.2fms %8.1fms %10d %7.2fms %7.1fms %6.0f%% %6d/%-5d\n", d, wgb,
      T_wios[d] ? T_wsec[d] * 512 / 1024 / T_wios[d] : 0, aw, A_wamax[d], T_fios[d], af, A_famax[d], A_util[d] / A_n[d], A_stall[d], A_n[d]
    AW[d] = aw; AF[d] = af
    if (T_wios[d] >= 50 && (minaw < 0 || aw < minaw)) minaw = aw
  }

  if (APP["tool"] != "") {
    printf "\nAnwendungssicht (%s, %s): ", APP["tool"], APP["what"]
    if (APP["app_mean_ms"] != "")
    {
      x = ""
      if (APP["app_p99_ms"] != "")
        x = sprintf(", p50 %s ms, p99 %s ms, p99.9 %s ms, max %s ms", APP["app_p50_ms"], APP["app_p99_ms"], APP["app_p999_ms"], APP["app_max_ms"])
      printf "%s IOPS, Ø %s ms%s\n", APP["app_iops"], APP["app_mean_ms"], x
    }
    else
      printf "%s MB/s\n", APP["app_bw_mbs"]
  }

  # ---- Bewertung ----
  Sd = 0; Sc = 0; Fn = 0; bf = -1
  if (mode == "sync" && Nact >= 3) {
    bf = S_devt / Nact
    printf "Gerätezeit-Anteil während des Tests: %.0f%% (Rest der Wartezeit entsteht oberhalb der SSD)\n", bf
    if (APP["app_mean_ms"] != "" && APP["app_mean_ms"] + 0 < 1)
      printf "Testlatenz Ø %s ms ist gut - kein Engpass bei diesem Muster.\n", APP["app_mean_ms"]
    else if (bf >= 70) add("SSD", 3, sprintf("Die Testanfragen warten %.0f%% der Zeit auf die SSD selbst - die Latenz entsteht auf dem Gerät.", bf))
    else if (bf <= 35) add("CPU", 3, sprintf("Nur %.0f%% der Wartezeit entfallen auf die SSD; der Rest geht in CPU/Software verloren (Syscalls, shfs/FUSE, Dateisystem, Locks, Scheduling).", bf))
    else add("MIX", 1, sprintf("%.0f%% der Wartezeit auf der SSD, der Rest in CPU/Software - beide Seiten tragen bei.", bf))
  }
  nst = 0
  for (i = 1; i <= Ndev; i++) if (A_stall[Dlist[i]] > 0) nst++
  for (i = 1; i <= Ndev; i++) {
    d = Dlist[i]
    if (!(d in A_n) || A_n[d] < 3) continue
    x = 100 * A_stall[d] / A_n[d]
    if (x >= 20) add("SSD", 2, sprintf("%s: in %.0f%% der aktiven Intervalle extrem langsame Schreib-/Flush-Zeiten (max await %.0f ms%s).", d, x, A_wamax[d], A_famax[d] > 0 ? sprintf(", max Flush %.0f ms", A_famax[d]) : ""))
    else if (x >= 5) add("SSD", 1, sprintf("%s: gelegentliche Schreib-Stalls (%d Intervalle, max await %.0f ms).", d, A_stall[d], A_wamax[d]))
    if (T_fios[d] >= 10) {
      if (AF[d] >= 10) add("SSD", 2, sprintf("%s: Flush (fsync/Cache leeren) dauert Ø %.1f ms - sehr langsam (Consumer-SSD ohne Power-Loss-Protection, SLC-Cache voll oder Firmware).", d, AF[d]))
      else if (AF[d] >= 3) add("SSD", 1, sprintf("%s: Flush Ø %.1f ms - erhöht (gute SATA-SSDs < 2 ms, Enterprise mit PLP < 0.1 ms).", d, AF[d]))
    }
    # Hängen mehrere Geräte abwechselnd, ist ein einzelnes "langsamstes" Gerät kein Befund
    if (T_wios[d] >= 50 && minaw > 0 && AW[d] > 3 * minaw && AW[d] > 2 && !(nst >= 2 && A_stall[d] > 0))
      add("SSD", 1, sprintf("%s ist deutlich langsamer als die übrigen Geräte (Ø await %.2f ms vs. bestes %.2f ms) - dieses Laufwerk gezielt prüfen.", d, AW[d], minaw))
    if ((mode == "seq" && A_tpn[d] >= 10) || A_tpn[d] >= 30) {
      # Spitze (3er-Mittel) in der ersten Hälfte vs. Mittel kurz vor Ende (letzte 2 Werte = Abschluss-Flush)
      first = 0; last = 0
      for (k = 1; k + 2 <= A_tpn[d] / 2; k++) {
        x = (A_tp[d, k] + A_tp[d, k + 1] + A_tp[d, k + 2]) / 3
        if (x > first) first = x
      }
      for (k = 1; k <= 5; k++) last += A_tp[d, A_tpn[d] - 1 - k]
      last /= 5
      if (first > 80 && last < 0.4 * first)
        add("SSD", 2, sprintf("%s: Schreibrate fällt bei Dauerlast von %.0f auf %.0f MB/s - typisch für vollen SLC-Cache (QLC/TLC-Consumer-SSD) oder fehlendes TRIM.", d, first, last))
    }
  }
  n = 0; dl = ""; x = 0
  for (i = 1; i <= Ndev; i++) {
    d = Dlist[i]
    if (A_stall[d] > 0) { n++; dl = dl (dl == "" ? "" : ", ") d; if ((" " mdmembers " ") ~ (" " d " ")) x++ }
  }
  if (Nsplit > 0) {
    if (n >= 2)
      add("SSD", 1, sprintf("Die Stalls wechseln zwischen mehreren SSDs (%s), während die übrigen gleichzeitig schnell antworten. Das Gerät selbst hält an (interne Garbage Collection/Firmware) - kein Kabel-, Controller- oder CPU-Problem, und eher Modell-/Lastverhalten als ein einzelnes defektes Laufwerk.", dl))
    else
      add("SSD", 1, sprintf("Nur %s hängt, während die übrigen SSDs gleichzeitig schnell antworten - dieses Laufwerk gezielt prüfen (Firmware, Verschleiß, Kabel/Port tauschen).", dl))
    if (x >= 1)
      add("SSD", 0, "Im mdadm-RAID wartet jedes fsync auf alle Mitglieder: ein Stall auf irgendeiner SSD bremst das ganze Array. Mit mehr SSDs im Verbund steigt die Wahrscheinlichkeit, dass gerade eine davon hängt.")
  }
  if (N_pi && S_pif / N_pi >= 10 && Nstall > 0) add("SSD", 1, sprintf("PSI io full Ø %.0f%%: Prozesse sind regelmäßig komplett durch IO blockiert.", S_pif / N_pi))

  if (mode != "passive" && TOP1 ~ /^(fio|dd)$/) sat = 0   # Testwerkzeug selbst lastet den Kern aus
  if (sat >= 30) add("CPU", 2, sprintf("Mindestens ein CPU-Kern war in %.0f%% der Intervalle voll ausgelastet%s.", sat, busy < 70 ? " (Single-Thread-Engpass)" : ""))
  else if (sat >= 10) add("CPU", 1, sprintf("Ein CPU-Kern war in %.0f%% der Intervalle voll ausgelastet.", sat))
  if (N_pc) {
    x = S_pc / N_pc
    if (x >= 20) add("CPU", 2, sprintf("PSI cpu Ø %.0f%%: lauffähige Prozesse warten deutlich auf CPU-Zeit.", x))
    else if (x >= 5) add("CPU", 1, sprintf("PSI cpu Ø %.0f%%: spürbarer CPU-Wettbewerb.", x))
  }
  if (busy >= 85) add("CPU", 1, sprintf("CPU insgesamt Ø %.0f%% ausgelastet.", busy))
  for (k in TOP) {
    if (k == "shfs" && TOP[k] >= 30) add("CPU", 2, sprintf("shfs (FUSE-Schicht von /mnt/user) braucht Ø %.0f%% eines Kerns - Schreiben über /mnt/user ist CPU-gebunden. Abhilfe: direkt /mnt/<pool>/... nutzen bzw. Exclusive Shares.", TOP[k]))
    else if (k ~ /^(z_wr_iss|z_wr_int|z_rd_int|z_fr_iss|txg_sync|spl_|z_)/ && TOP[k] >= 30) add("CPU", 1, sprintf("ZFS-Thread %s braucht Ø %.0f%% eines Kerns (Kompression/Checksummen/RAIDZ/Verschlüsselung).", k, TOP[k]))
    else if (k ~ /^(unraidd|mdrecoveryd|md[0-9]+_raid)/ && TOP[k] >= 30) add("CPU", 2, sprintf("RAID-Thread %s braucht Ø %.0f%% eines Kerns (Paritätsberechnung läuft single-threaded).", k, TOP[k]))
    else if (k ~ /^md[0-9]+_resync/ && TOP[k] >= 5) add("SSD", 1, sprintf("%s läuft (RAID-Resync/Check) und konkurriert mit normalen Schreibzugriffen.", k))
    else if (k ~ /^(kcryptd|dmcrypt_write)/ && TOP[k] >= 30) add("CPU", 1, sprintf("Verschlüsselung (%s) braucht Ø %.0f%% eines Kerns.", k, TOP[k]))
    else if (k ~ /^btrfs/ && TOP[k] >= 30) add("CPU", 1, sprintf("btrfs-Thread %s braucht Ø %.0f%% eines Kerns.", k, TOP[k]))
  }

  if (Fn == 0) print "\nBefund: keine Auffälligkeiten in diesem Zeitraum."
  else { print "\nBefund:"; for (i = 1; i <= Fn; i++) print F[i] }
  if (Sd < 2 && Sc < 2) verdict = "unauffällig"
  else if (Sd >= Sc + 2) verdict = "SSD/Storage"
  else if (Sc >= Sd + 2) verdict = "CPU/Software"
  else verdict = "gemischt"
  printf "=> Hauptverdacht: %s   (Punkte SSD %d / CPU %d)\n", verdict, Sd, Sc

  printf "label=%s\nmode=%s\nverdict=%s\nscore_ssd=%d\nscore_cpu=%d\ndev_frac=%s\napp_mean_ms=%s\napp_p99_ms=%s\napp_iops=%s\napp_bw_mbs=%s\n",
    label, mode, verdict, Sd, Sc, (bf < 0 ? "-" : sprintf("%.0f", bf)), APP["app_mean_ms"], APP["app_p99_ms"], APP["app_iops"], APP["app_bw_mbs"] > sumfile
  close(sumfile)
}
BEGIN {
  if (hz <= 0) hz = 100
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
# bpftrace (optional): wer ruft fsync & Co. auf, wie lange dauert es,
# und wie viel haben Prozesse geschrieben, die während der Messung enden
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

// Jeder Thread meldet beim Ende nur seine eigene Schreibmenge - nichts wird doppelt gezählt.
// Getrennt davon, wie viel er vor dem Zurückschreiben wieder gelöscht hat (erreicht die Platte nie).
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
    grep -q '^Attaching' "$BT_OUT" 2>/dev/null && return
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
  if ! grep -q '^Attaching' "$BT_OUT" 2>/dev/null; then
    printf '\nbpftrace-Tracing nicht möglich: %s\n' "$(grep -v RLIMIT_MEMLOCK "$BT_OUT.err" | grep -m1 -i error)"
    return
  fi
  # Läuft ein Prozess noch, waren es nur beendete Threads; die stecken schon in den Top-Schreibern.
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
      printf "\nfsync-Aufrufer (bpftrace, %d s): insgesamt %.1f pro Sekunde\n", dur, tot / dur
      if (tot > 0) {
        printf "  %-36s %8s %7s %8s %9s\n", "Prozess/Thread", "Aufrufe", "pro s", "Ø ms", "max ms"
        for (i = 1; i <= 12; i++) {
          b = ""; bv = 0
          for (k in N) if (!(k in used) && N[k] > bv) { bv = N[k]; b = k }
          if (b == "") break
          used[b] = 1
          printf "  %-36.36s %8d %7.2f %8.2f %9.1f%s\n", name(b), N[b], N[b] / dur, U[b] / N[b] / 1000, M[b] / 1000, (M[b] >= 200000 ? "  << hängt" : "")
          if (i == 1) top = b
        }
        printf "=> Häufigster fsync-Aufrufer: %s (%.0f%% aller Aufrufe)\n", name(top), 100 * N[top] / tot
      }
      s = ""
      for (i = 1; i <= 8; i++) {
        b = ""; bv = 0
        for (k in E) if (!(k in usedE) && index(running, "|" k "|") == 0 && E[k] > bv) { bv = E[k]; b = k }
        if (b == "" || bv < 1048576) break
        usedE[b] = 1
        s = s sprintf("%s %.2f GB%s  ", b, bv / 1e9, C[b] > 0.1 * bv ? sprintf(" (davon %.2f GB gleich wieder gelöscht)", (C[b] < bv ? C[b] : bv) / 1e9) : "")
      }
      if (s != "") {
        printf "Während der Messung beendete Prozesse (Schreibmenge über ihre ganze Laufzeit): %s\n", s
        print "  (Steckt oben auch beim Elternprozess, der sie abgeräumt hat, z.B. systemd. Gleich wieder Gelöschtes erreicht die Platte nicht.)"
      }
    }' "$BT_OUT"
}

# ---------------------------------------------------------------------------
# Phasen
# ---------------------------------------------------------------------------
PHASE_N=0
SUMFILES=()

start_sampler() { # label mode duration appfile
  CUR_STOP="$OUT/.stop$PHASE_N"
  rm -f "$CUR_STOP"
  ( trap '' INT; exec awk -v devre="$DEVRE" -v hz="$HZ" -v interval_arg="$INTERVAL" -v duration="$3" \
      -v stopfile="$CUR_STOP" -v csv="$CSV" -v phase="$PHASE_N" -v label="$1" -v mode="$2" \
      -v appfile="$4" -v sumfile="$OUT/phase$PHASE_N.sum" -v mdmembers="$MDMEMBERS" -v quiet="$QUIET" -f "$OUT/sampler.awk" ) &
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
  section "Phase $PHASE_N: passive Beobachtung (${PASSIVE}s) - jetzt das Problem auslösen, Ctrl+C beendet"
  [ $QUIET -eq 1 ] && info "(-q: es werden nur auffällige Intervalle angezeigt)"
  trace_start
  start_sampler "passiv ${PASSIVE}s" passive "$PASSIVE" ""
  wait_sampler
  trace_stop
}

phase_sync() { # dir
  local dir=$1 f app
  PHASE_N=$((PHASE_N + 1))
  f="$dir/.wlat-test-$$.bin"
  app="$OUT/phase$PHASE_N.app"
  CUR_FILE=$f
  section "Phase $PHASE_N: 4k O_SYNC-Schreiben (QD1) in $dir für ${TEST_RUNTIME}s"
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
  section "Phase $PHASE_N: sequentielles Dauerschreiben $SEQ_SIZE in $dir"
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
echo "write-latency-diag $VERSION - $(date '+%F %T') - Ausgabe: $OUT"
[ $SKIP_STATIC -eq 0 ] && static_check

if [ ${#TARGETS[@]} -gt 0 ] && [ $HAVE_FIO -eq 0 ]; then
  section "Hinweis"
  info "fio nicht gefunden - nutze dd als Ersatz (nur Mittelwert, keine Perzentile)."
fi
if [ $HAVE_BT -eq 0 ] && [ $TRACE -eq 1 ]; then
  section "Hinweis"
  info "bpftrace nicht verfügbar (oder nicht root) - ohne Auswertung der fsync-Aufrufer. Installieren: apt install bpftrace"
fi

[ "$PASSIVE" -gt 0 ] 2>/dev/null && phase_passive
for t in "${TARGETS[@]}"; do
  [ $ABORT -eq 1 ] && break
  phase_sync "$t"
done
[ $ABORT -eq 0 ] && [ -n "$SEQ_SIZE" ] && phase_seq "${TARGETS[0]}"
[ -n "$CUR_FILE" ] && rm -f "$CUR_FILE"

# ---------------------------------------------------------------------------
# Gesamtfazit
# ---------------------------------------------------------------------------
section "Zusammenfassung"
printf '  %-3s %-44s %9s %9s %8s %10s %8s  %s\n' "#" "Phase" "Ø ms" "p99 ms" "IOPS" "SSD-Anteil" "SSD/CPU" "Befund"
declare -A MEAN
for s in "${SUMFILES[@]}"; do
  [ -f "$s" ] || { echo "  Phase $(basename "$s" .sum | tr -dc 0-9): keine Auswertung (Sampler-Fehler, siehe oben)"; continue; }
  label=$(sed -n 's/^label=//p' "$s")
  mean=$(sed -n 's/^app_mean_ms=//p' "$s")
  printf '  %-3s %-44.44s %9s %9s %8s %10s %8s  %s\n' "$(basename "$s" .sum | tr -dc 0-9)" "$label" "${mean:--}" \
    "$(sed -n 's/^app_p99_ms=//p' "$s" | grep . || echo -)" "$(sed -n 's/^app_iops=//p' "$s" | grep . || echo -)" \
    "$(sed -n 's/^dev_frac=//p' "$s" | sed 's/^\([0-9]*\)$/\1%/')" "$(sed -n 's/^score_ssd=//p' "$s")/$(sed -n 's/^score_cpu=//p' "$s")" \
    "$(sed -n 's/^verdict=//p' "$s")"
  [ -n "$mean" ] && MEAN["${label#sync4k }"]=$mean
done

# /mnt/user vs. direkter Pfad
for a in "${!MEAN[@]}"; do
  case "$a" in /mnt/user/*|/mnt/user0/*) ;; *) continue ;; esac
  for b in "${!MEAN[@]}"; do
    case "$b" in /mnt/user*) continue ;; esac
    awk -v a="$a" -v b="$b" -v ma="${MEAN[$a]}" -v mb="${MEAN[$b]}" 'BEGIN {
      if (mb <= 0) exit
      r = ma / mb
      printf "\n  Vergleich: %s Ø %.2f ms vs. %s Ø %.2f ms => Faktor %.1f\n", a, ma, b, mb, r
      if (r >= 1.5) print "  => Der Umweg über /mnt/user (shfs/FUSE) kostet deutlich Latenz - das ist CPU/Software, nicht die SSD."
      else print "  => shfs kostet kaum zusätzliche Latenz."
    }'
  done
done

if [ ${#WARN[@]} -gt 0 ]; then
  echo
  echo "  Auffälligkeiten aus dem Systemcheck:"
  for w in "${WARN[@]}"; do echo "   - $w"; done
fi

echo
echo "  Report: $OUT/report.txt   Messwerte: $CSV"
exec >&- 2>&-
wait "$TEE_PID" 2>/dev/null
