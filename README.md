# write-latency-diag

Ein Diagnose-Skript für Linux. Getestet ist es für Ubuntu, Unraid wird zusätzlich erkannt. Es misst
Schreiblatenz und grenzt ein, ob die Wartezeit **auf den SSDs** (Gerät, Controller, Cache-Flush) entsteht oder
**darüber** (CPU, RAID-Parität, Verschlüsselung, Dateisystem, Locks).

Es braucht nur `bash` und `awk`. `fio`, `smartctl`, `bpftrace` und `hdparm` sind optional, liefern aber deutlich
mehr Details:

```bash
sudo apt install fio smartmontools bpftrace hdparm
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

**3. Über einen ganzen Tag beobachten**

```bash
sudo /tmp/wlat.sh -d 86400 -q -i 5
```

Mit `-q` zeigt das Skript nur die auffälligen Intervalle, jeweils mit den Prozessen, die gerade schreiben. Die
Auswertung am Ende fasst den ganzen Zeitraum zusammen. So landen auch nächtliche Backups, Cronjobs und
Datenbank-Wartung in der Messung. Am besten in `tmux` oder `screen` starten.

**4. Optional: Dauerlast (SLC-Cache)**

```bash
sudo /tmp/wlat.sh -t /pfad/.lattest -S 30G
```

Dieser Test schreibt 30 GB. Bricht die Schreibrate nach einigen GB stark ein, ist der SLC-Cache der SSD voll.
Das ist typisch für QLC-SSDs und DRAM-lose SSDs.

Report und Messwerte (`samples.csv`, eine Zeile pro Sekunde und Gerät) liegen unter `/tmp/wlat-<Zeitstempel>/`.

## Wer erzeugt die Last?

- **Schreiber pro Prozess**: In jedem Intervall zeigt die Zeile `schreibt:`, welche Prozesse wie viel schreiben
  (aus `/proc/<pid>/io`, nur als root vollständig). Die Auswertung nennt die größten Schreiber über die ganze Phase
  und getrennt davon in den langsamen Intervallen. Endet ein Prozess, rechnet der Kernel seine Schreibmenge dem
  Elternprozess zu. Darum tauchen `systemd`, `cron` oder `containerd-shim` mit der Schreibmenge ihrer beendeten
  Kindprozesse auf.
- **fsync-Aufrufer** (mit `bpftrace`): Wer ruft `fsync`, `fdatasync`, `sync_file_range`, `msync(MS_SYNC)`, `sync`
  oder `syncfs` auf, wie oft, und wie lange wartet er darauf? Angezeigt wird Prozess/Thread, z.B.
  `mysqld/ib_log_flush`. Auch Prozesse, die während der Messung enden, werden mit ihrer Schreibmenge erfasst.
  `-T` schaltet das Tracing ab.
- **Schreibverstärkung im Verlauf**: Die SMART-Zähler gelten für die ganze Lebensdauer der SSD. Jeder Lauf speichert
  sie in `/var/lib/write-latency-diag/smart-history.csv`. Ab dem zweiten Lauf (frühestens nach 1 h, besser nach
  12 h oder mehr) zeigt das Skript die Schreibverstärkung seit dem letzten Messpunkt. So sieht man, ob eine Änderung
  gewirkt hat.

## Wie wird entschieden?

| Messgröße | Bedeutung |
|---|---|
| **Gerätezeit-Anteil** (aktiver Test) | Summe aller Anfragezeiten der SSD (Schreiben und Flush) geteilt durch die Testdauer. Bei QD1 zeigt das, welcher Anteil der Wartezeit auf dem Gerät liegt. ≥ 70 % deutet auf die SSD, ≤ 35 % auf CPU/Software. |
| **w_await / Flush-Latenz** pro SSD | Die Latenz, die das Gerät selbst liefert. Flush ist das, worauf `fsync` wartet. Richtwerte: gute SATA-SSD < 2 ms, Enterprise-SSD mit PLP < 0,1 ms. |
| **LANGSAM-Intervalle** | Hohe Latenz bei geringem Durchsatz, also ein echter Einbruch und kein normaler Warteschlangenstau. |
| **Ausreißer-SSD** | Eine SSD ist deutlich langsamer als die anderen. Dann dieses Laufwerk prüfen (Firmware, Verschleiß, Kabel). |
| **Wechselnde Stalls** | Mal hängt die eine SSD, mal die andere, während die übrigen im selben Moment schnell antworten. Das Gerät hält intern an (Garbage Collection, Firmware). Ein einzelner Defekt ist das nicht, eher ein Modell- oder Lastproblem. Im mdadm-RAID wartet jedes `fsync` auf alle Mitglieder, darum bremst jeder Stall einer einzelnen SSD das ganze Array. |
| **Schreibverstärkung (WAF)** | Bei SanDisk/WD-SSDs berechnet aus SMART 233 (NAND-GiB) und 241 (Host-GiB), bei Crucial/Micron aus 247/248 (Host- und FTL-Pages). Normal sind etwa 1–3. Werte ab 5 bedeuten, dass die SSD intern ein Vielfaches neu schreibt. Typisch ist das für viele kleine `fsync`-Schreibzugriffe auf Consumer-SSDs ohne PLP. Folgen sind Dauer-Garbage-Collection, Latenzspitzen und schneller Verschleiß. |
| **Spiegelgruppen** (mdadm RAID10) | Welche SSDs immer dieselben Schreibzugriffe bekommen. Sie verschleißen gleich schnell und halten oft auch gleichzeitig für die Garbage Collection an. |
| **Schreibcache** | Ist der Cache im Laufwerk aus (`hdparm -W`), geht jeder Schreibzugriff direkt in den Flash. Hält der Kernel ihn für aus, obwohl er an ist, schickt er keine Flushes, und bei Stromausfall droht Datenverlust. |
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
- **Hohe Schreibverstärkung**: Ursache sind viele kleine Sync-Schreibzugriffe (Datenbanken, NVR wie Frigate,
  Logs). Abhilfe: die Sync-Last verringern (z.B. Aufnahmen auf eigene Disks, Datenbank-`fsync`-Einstellungen
  prüfen), Over-Provisioning (10–20 % unpartitioniert lassen) oder Enterprise-SSDs mit PLP verwenden. Die bestätigen
  einen Flush sofort aus dem geschützten Cache.
- **Datenbanken (MySQL/MariaDB)**: Die Standardwerte sichern jeden Commit doppelt per `fsync` (Redo-Log und
  Binlog). Ohne Replikation braucht man das Binlog nicht (`disable-log-bin`). Mit
  `innodb_flush_log_at_trx_commit = 2` gehen bei Stromausfall höchstens ~1 s Transaktionen verloren, die Datenbank
  bleibt konsistent. Ein größerer `innodb_buffer_pool_size` und ein kleinerer `innodb_io_capacity` (MySQL 8.4:
  Standard 10000) lassen InnoDB Änderungen sammeln, statt jede Seite sofort zurückzuschreiben.
- **Schreibcache aus**: Der Schalter (`hdparm -W1`) ist laut ATA-Standard nicht dauerhaft. Schaltet ihn das BIOS
  beim Start ab (bei HPE z.B. „Drive Write Cache“ in den SATA-Optionen), dort einschalten oder per udev-Regel bei
  jedem Start setzen.
- **CRC-Fehler / ATA-Resets im dmesg**: Kabel, Backplane oder Port prüfen.
- **Großer Dirty-Puffer**: Viele GB RAM mit `vm.dirty_ratio=20` bauen große Writeback-Stöße auf. Ein kleinerer
  `vm.dirty_bytes`-Wert glättet sie.

Für ZFS zeigt parallel `zpool iostat -vl 1`, ob Zeit in den Warteschlangen (`syncq_wait`/`asyncq_wait`) oder
auf der Disk (`disk_wait`) verbracht wird.
