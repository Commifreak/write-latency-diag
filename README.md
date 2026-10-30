# write-latency-diag

Ein Diagnose-Skript für Linux. Getestet ist es für Ubuntu, Unraid wird zusätzlich erkannt. Es misst
Schreiblatenz und grenzt ein, ob die Wartezeit **auf den SSDs** (Gerät, Controller, Cache-Flush) entsteht oder
**darüber** (CPU, RAID-Parität, Verschlüsselung, Dateisystem, Locks).

Es braucht nur `bash` und `awk`. `fio` und `smartctl` sind optional, liefern aber deutlich mehr Details:

```bash
sudo apt install fio smartmontools
```

## Installation

```bash
wget -O /tmp/wlat.sh https://raw.githubusercontent.com/Commifreak/write-latency-diag/main/write-latency-diag.sh
chmod +x /tmp/wlat.sh
```

Das Skript als root starten (`sudo`). Sonst fehlen SMART-Daten.

## Vorgehen

**1. Aktiver Test (ca. 1 Minute)**

```bash
sudo /tmp/wlat.sh -t /pfad/auf/dem/ssd-volume/.lattest
```

Der Test schreibt 4k-Blöcke mit O_SYNC (Queue-Tiefe 1). So schreiben auch Datenbanken, Docker-Container und
VMs. Die Testdatei ist 256 MB groß und wird danach gelöscht. Mit mehreren `-t` lassen sich Volumes vergleichen,
z.B. RAID gegen Einzel-SSD oder verschlüsselt gegen unverschlüsselt.

**2. Im Alltag beobachten, wenn es hakt (passiv)**

```bash
sudo /tmp/wlat.sh -d 600
```

Das Skript zeigt jede Sekunde CPU, Kern-Spitze, PSI und Top-Prozesse sowie für jede aktive SSD Durchsatz,
await, Flush-Latenz und Auslastung. Langsame Intervalle sind mit `<< LANGSAM` markiert. `Ctrl+C` beendet die
Messung vorzeitig, die Auswertung kommt trotzdem.

**3. Optional: Dauerlast (SLC-Cache)**

```bash
sudo /tmp/wlat.sh -t /pfad/.lattest -S 30G
```

Dieser Test schreibt 30 GB. Bricht die Schreibrate nach einigen GB stark ein, ist der SLC-Cache der SSD voll.
Das ist typisch für QLC-SSDs und DRAM-lose SSDs.

Report und Messwerte (`samples.csv`, eine Zeile pro Sekunde und Gerät) liegen unter `/tmp/wlat-<Zeitstempel>/`.

## Wie wird entschieden?

| Messgröße | Bedeutung |
|---|---|
| **Gerätezeit-Anteil** (aktiver Test) | Summe aller Anfragezeiten der SSD (Schreiben und Flush) geteilt durch die Testdauer. Bei QD1 zeigt das, welcher Anteil der Wartezeit auf dem Gerät liegt. ≥ 70 % deutet auf die SSD, ≤ 35 % auf CPU/Software. |
| **w_await / Flush-Latenz** pro SSD | Die Latenz, die das Gerät selbst liefert. Flush ist das, worauf `fsync` wartet. Richtwerte: gute SATA-SSD < 2 ms, Enterprise-SSD mit PLP < 0,1 ms. |
| **LANGSAM-Intervalle** | Hohe Latenz bei geringem Durchsatz, also ein echter Einbruch und kein normaler Warteschlangenstau. |
| **Ausreißer-SSD** | Eine SSD ist deutlich langsamer als die anderen. Dann dieses Laufwerk prüfen (Firmware, Verschleiß, Kabel). |
| **Kern ≥ 95 % / PSI cpu** | Ein einzelner Thread ist der Engpass, oder Prozesse warten auf CPU-Zeit. |
| **Top-Prozesse** | `md0_raid5`/`md0_raid6` steht für die RAID-Paritätsberechnung, `kcryptd`/`dmcrypt_write` für LUKS, `z_wr_*` für ZFS, `md0_resync` für einen laufenden RAID-Check. |
| **iowait** | Das ist **keine** CPU-Last. Die CPU wartet auf IO. |

## Typische Ursachen und Maßnahmen

- **mdadm RAID5/6**: Kleine Schreibzugriffe brauchen ein Read-Modify-Write, und die Paritätsberechnung läuft in
  nur einem Kernel-Thread. `stripe_cache_size` erhöhen. Für Sync-lastige Workloads ist RAID10 deutlich
  schneller.
- **RAID-Check**: Ubuntu startet `checkarray` jeden ersten Sonntag im Monat (`/etc/cron.d/mdadm`). In dieser
  Zeit sind Schreibzugriffe deutlich langsamer.
- **SATA ALPM** (`med_power_with_dipm`, `min_power`): Den Link wieder auf
  `echo max_performance > /sys/class/scsi_host/hostX/link_power_management_policy` stellen. Diese Einstellung
  setzen oft TLP oder `powertop --auto-tune`.
- **Hohe Flush-Latenz**: Consumer-SSDs ohne Power-Loss-Protection. Bei ZFS hilft `sync=standard`
  (nicht `always`). Für Datenbanken sind Enterprise-SSDs mit PLP sinnvoll.
- **Einbruch bei Dauerlast**: Die SSD ist eine QLC- oder DRAM-lose SSD, oder TRIM fehlt.
  `systemctl enable --now fstrim.timer` aktivieren. Bei mdadm muss TRIM durch alle Schichten durchgereicht
  werden (`lsblk --discard`).
- **CRC-Fehler / ATA-Resets im dmesg**: Kabel, Backplane oder Port prüfen.
- **Großer Dirty-Puffer**: Viele GB RAM mit `vm.dirty_ratio=20` bauen große Writeback-Stöße auf. Ein kleinerer
  `vm.dirty_bytes`-Wert glättet sie.

Für ZFS zeigt parallel `zpool iostat -vl 1`, ob Zeit in den Warteschlangen (`syncq_wait`/`asyncq_wait`) oder
auf der Disk (`disk_wait`) verbracht wird.
