# write-latency-diag

Werkzeuge, die Schreiblatenz auf Linux-Servern messen und eingrenzen: SSD (Gerät, Flush, Firmware) oder
CPU/Software. Zielsystem ist vor allem Ubuntu mit mdadm, Unraid wird im Skript zusätzlich erkannt.

## Arbeitsweise

- Direkt auf `main` committen und pushen, keine Pull Requests.
- Alles, was Benutzer sehen (Ausgaben, Befunde, Web-Oberfläche, README), ist auf Deutsch, mit Dezimalkomma in
  Fließtext und Tabellen. Commit-Nachrichten auf Englisch.
- Bei jeder Änderung `VERSION` hochzählen: im Skript (`write-latency-diag.sh`) bzw. im Dienst
  (`service/wlat-service.py`). Das Auto-Update vergleicht den Dateiinhalt, die Version erscheint im Report.
- Das Repo ist öffentlich und wird per Auto-Update von `raw.githubusercontent.com` (Zweig `main`) geladen.
  Keine Daten eines konkreten Servers einchecken (IPs, Seriennummern, Benutzernamen, Reports).

## Aufbau

| Teil | Datei | Aufgabe |
|---|---|---|
| Dienst | `service/wlat-service.py` | Die eine Quelle für dauerhafte Messung: Sammler, SQLite, Web-Oberfläche (Port 81), Textbericht `/api/report`, CheckMK-Zeilen `/api/checkmk` |
| CheckMK-Checks | `checkmk/write_latency`, `checkmk/write_latency_smart` | Geben die Ausgabe des Dienstes weiter, wenn er läuft und Daten hat. Sonst messen sie selbst |
| Skript | `write-latency-diag.sh` | Aktive Tests (fio, Dauerlast), Einmal-Analyse, Prüfung neuer SSDs vor dem Einbau (`--check-disk`, löscht das Laufwerk), Installation des Dienstes (`--install-service`), Auto-Update von Skript, Dienst und Checks |

- Die Logik für Hänger, Schreibverstärkung (WAF), Verschleiß/Restlaufzeit, Schreibcache und TRIM gibt es in mehreren
  Teilen. Sie muss gleich bleiben: gleiche Schwellwerte, gleiche Regeln, gleiche Service-Namen in CheckMK. Wer eine
  Regel ändert, ändert sie überall (Skript-awk, Dienst, `checkmk_lines()` und die eigene Messung der Checks).
- Hänger (auch in der Dauerlast von `--check-disk`): Ein Zeitabschnitt ist langsam, wenn Anfragen >= 100 ms dauern (`stall_ms`) oder das Gerät Anfragen offen
  hat und gar keine beendet. Aufeinanderfolgende langsame Abschnitte (Lücke < 3 s) bilden ein Ereignis. Spürbar ist
  ein Ereignis ab 1 s Wartezeit (`felt_ms`) oder 2 s Dauer. HDDs (rotierend) zählen nicht als SSD-Befund.
- Schreiber pro Prozess werden netto gezählt (`write_bytes - cancelled_write_bytes`). Beim Ende eines Prozesses
  rechnet der Kernel seine Menge dem Elternprozess zu. Was beim Kind schon gezählt wurde, wird dort abgezogen.
- SMART-Abfragen laufen bei SATA am NCQ-Puffer vorbei. Der Dienst merkt sich ihre Zeiträume und markiert Hänger, die
  in eine Abfrage fallen.

## Regeln für den Code

- Dienst: nur Python-Standardbibliothek (läuft auf Ubuntu 24.04 mit Python 3.12). Keine Pakete, nichts aus dem
  Internet zur Laufzeit. Die Web-Oberfläche ist nur lesend und hat keinen Login. Sie darf nie Befehle oder Tests
  auslösen. Prozessnamen im Browser immer als Text einsetzen (`textContent`), nie als HTML.
- Der Dienst soll selbst kaum Schreiblast erzeugen: SQLite mit WAL und `synchronous=NORMAL`, gebündelt einmal pro
  Minute schreiben.
- Skript: bash und awk, kompatibel mit mawk (Ubuntu-Standard). Kein `strftime`, keine gawk-Erweiterungen. Dateien
  unter `/proc/<pid>/` nicht per `getline` lesen: mawk bricht bei Lesefehlern (EACCES) ab. Stattdessen
  `grep -s -H` über alle Dateien.
- Downloads beim Auto-Update vor dem Ersetzen prüfen (vollständig, `bash -n` bzw. `compile()`). Eine
  Git-Arbeitskopie wird nie überschrieben.
- Neue Optionen, Services oder Befunde im README beschreiben.

## Testen

Die Entwicklungsumgebung ist eine VM ohne echte SATA-SSDs, ohne systemd und ohne CheckMK-Agent.

- Statische Prüfung: `bash -n write-latency-diag.sh checkmk/*`, `python3 -m pyflakes service/wlat-service.py`.
- bpftrace braucht tracefs: `mount -t tracefs nodev /sys/kernel/tracing`.
- `WLAT_TEST_ALL_SSD=1` behandelt die (rotierenden) VM-Platten als SSD, im Skript und im Dienst.
- Dienst mit Testkonfiguration starten: `WLAT_CONF=<datei>` mit z.B. `bind = 127.0.0.1`, `port = 18081`,
  `db = <scratchpad>/metrics.db`, `auto_update = 0`. Hänger lassen sich mit einem großen Schreibblock und
  anschließendem `fsync` erzeugen.
- Auto-Update gegen einen lokalen Testserver: `WLAT_UPDATE_URL=http://127.0.0.1:<port>` und
  `python3 -m http.server`. `WLAT_NO_UPDATE=1` schaltet das Update ab.
- SMART, hdparm, journalctl und systemctl gibt es in der VM nicht oder nicht echt: für Tests kleine Ersatzskripte
  per `PATH` voranstellen, Testdaten direkt in die SQLite-Datenbank schreiben.
- Web-Oberfläche: Screenshots mit Playwright (`NODE_PATH=/opt/node-tools/node_modules node <skript>.js`), jeweils
  hell, dunkel und 390 px breit. Auf Browser-Fehler und horizontales Scrollen prüfen.
- `--check-disk`: an einem Loop-Device testen (`losetup` auf eine Datei im Scratchpad) mit einem Ersatz-`smartctl`,
  das eine SATA-SSD nachbildet (`-i -A -c -t -X -l selftest -l devstat`). `WLAT_CONFIRM_DEV=<gerätename>` ersetzt
  die Eingabe zur Bestätigung. Abbruch mit `TERM` testen: Hintergrundprozesse einer nicht interaktiven Shell
  ignorieren `INT`.
- Testprozesse gezielt beenden (`pkill -f '^python3 service/wlat-service.py'`), nicht mit einem Muster, das auch auf
  die eigene Shell passt.

## Zusammenfassung des Kontexts

Bei einer Zusammenfassung (automatisch oder `/compact`) vollständig behalten:

- Den Stand der Analyse am Zielserver des Benutzers: Befunde mit den wichtigsten Messwerten, gekaufte oder geplante
  Hardware, bereits umgesetzte Änderungen und die offenen Schritte dort, jeweils mit den Befehlen, die noch
  auszuführen sind. Diese Daten stehen absichtlich nicht im Repo und gibt es nur in der Unterhaltung.
- Widerlegte Annahmen und warum sie falsch waren, damit sie nicht erneut vorgeschlagen werden.
- Was der Benutzer für später angekündigt hat („behalte im Hinterkopf“).
- Laufende Arbeit am Code: was geändert, getestet und gepusht ist und was noch fehlt.
