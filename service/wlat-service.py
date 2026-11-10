#!/usr/bin/env python3
#
# write-latency-diag Dienst
#
# Zeichnet dauerhaft Schreiblatenz, Flushes, Hänger, Schreiber, fsync-Wartezeiten und SMART-Werte
# auf (SQLite) und zeigt sie auf einer Web-Oberfläche an (nur lesend, ohne Login, gedacht fürs LAN).
#
# Nur Python-Standardbibliothek. Optional: bpftrace (fsync-Aufrufer), smartctl, hdparm.
# Konfiguration: /etc/write-latency-diag.conf (Schlüssel = Wert), siehe DEFAULTS.
#

import glob
import json
import os
import re
import signal
import sqlite3
import subprocess
import sys
import threading
import time
import urllib.request
from collections import defaultdict
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

VERSION = "1.5"
CONF_FILE = os.environ.get("WLAT_CONF", "/etc/write-latency-diag.conf")
DEFAULTS = {
    "bind": "0.0.0.0",
    "port": "81",
    "db": "/var/lib/write-latency-diag/metrics.db",
    "devices": r"^(sd[a-z]+|nvme[0-9]+n[0-9]+|vd[a-z]+|xvd[a-z]+)$",
    "stall_ms": "100",           # ab dieser Wartezeit zählt eine Sekunde als Hänger
    "felt_ms": "1000",           # spürbar: ab dieser Wartezeit (oder Hänger ab 2 s Dauer)
    "keep_5s_days": "7",         # 5-Sekunden-Werte
    "keep_1m_days": "90",        # Minutenwerte, fsync-Statistik
    "keep_events_days": "365",
    "smart_interval": "1800",
    "bpftrace": "1",
    "auto_update": "1",
    "update_url": "https://raw.githubusercontent.com/Commifreak/write-latency-diag/main",
}

STOP = threading.Event()
RESTART = threading.Event()   # nach einem Update: beenden, systemd startet neu
INFO = {"started": time.time(), "bpftrace": "aus", "update": ""}


def log(msg):
    print(time.strftime("%Y-%m-%d %H:%M:%S"), msg, flush=True)


def load_conf():
    conf = dict(DEFAULTS)
    try:
        with open(CONF_FILE) as f:
            for line in f:
                line = line.split("#", 1)[0].strip()
                if "=" in line:
                    k, v = line.split("=", 1)
                    conf[k.strip()] = v.strip()
    except OSError:
        pass
    return conf


def read(path, default=""):
    try:
        with open(path) as f:
            return f.read()
    except OSError:
        return default


def run(cmd, timeout=30):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout).stdout
    except (OSError, subprocess.SubprocessError):
        return ""


# ---------------------------------------------------------------------------
# Datenbank
# ---------------------------------------------------------------------------
SCHEMA = """
CREATE TABLE IF NOT EXISTS disk (res INTEGER, ts INTEGER, dev TEXT, w_iops REAL, w_mbs REAL, w_await REAL,
  w_await_max REAL, f_rate REAL, f_await REAL, f_await_max REAL, r_mbs REAL, util REAL, PRIMARY KEY (res, ts, dev));
CREATE TABLE IF NOT EXISTS sys (res INTEGER, ts INTEGER, cpu REAL, iowait REAL, maxcore REAL, psi_cpu REAL,
  psi_io_some REAL, psi_io_full REAL, writers TEXT, PRIMARY KEY (res, ts));
CREATE TABLE IF NOT EXISTS fsync (ts INTEGER, secs INTEGER, proc TEXT, thread TEXT, n INTEGER, sum_ms REAL, max_ms REAL);
CREATE INDEX IF NOT EXISTS fsync_ts ON fsync (ts);
CREATE TABLE IF NOT EXISTS slow_fsync (ts REAL, ms REAL, proc TEXT, thread TEXT);
CREATE INDEX IF NOT EXISTS slow_fsync_ts ON slow_fsync (ts);
CREATE TABLE IF NOT EXISTS events (id INTEGER PRIMARY KEY, dev TEXT, start REAL, end REAL, max_w REAL, max_f REAL,
  writers TEXT, waiters TEXT);
CREATE INDEX IF NOT EXISTS events_start ON events (start);
CREATE TABLE IF NOT EXISTS smart (ts INTEGER, dev TEXT, serial TEXT, model TEXT, rot INTEGER, usb INTEGER, poh INTEGER,
  used INTEGER, num REAL, den REAL, host_gib REAL, nand_gib INTEGER, temp INTEGER, realloc INTEGER, crc INTEGER,
  wc_drive TEXT, wc_kernel TEXT, wc_boot TEXT, sct TEXT);
CREATE INDEX IF NOT EXISTS smart_serial ON smart (serial, ts);
CREATE TABLE IF NOT EXISTS kv (k TEXT PRIMARY KEY, v TEXT);
CREATE TABLE IF NOT EXISTS smart_runs (start REAL, end REAL);
"""


def db_connect(path):
    con = sqlite3.connect(path, timeout=30, check_same_thread=False)
    # WAL + synchronous=NORMAL: Der Dienst soll selbst kaum fsyncs erzeugen (nur bei Checkpoints)
    con.execute("PRAGMA journal_mode=WAL")
    con.execute("PRAGMA synchronous=NORMAL")
    return con


class Store:
    """Schreibt gesammelte Werte gebündelt einmal pro Minute in die Datenbank."""

    def __init__(self, path):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        self.path = path
        self.con = db_connect(path)
        self.con.executescript(SCHEMA)
        self.con.commit()
        self.lock = threading.Lock()     # schützt pending
        self.dblock = threading.Lock()   # eine Verbindung, mehrere Threads: Schreiben nacheinander
        self.pending = []   # (sql, params)

    def add(self, sql, params):
        with self.lock:
            self.pending.append((sql, params))

    def flush(self):
        with self.lock:
            items, self.pending = self.pending, []
        if not items:
            return
        with self.dblock:
            try:
                with self.con:
                    for sql, params in items:
                        self.con.execute(sql, params)
            except sqlite3.Error as e:
                log(f"Datenbankfehler: {e}")

    def kv_set(self, k, v):
        self.add("INSERT OR REPLACE INTO kv (k, v) VALUES (?, ?)", (k, json.dumps(v)))

    def cleanup(self, conf):
        now = time.time()
        d5, d1, de = (float(conf[k]) * 86400 for k in ("keep_5s_days", "keep_1m_days", "keep_events_days"))
        with self.dblock:
            self._cleanup(now, d5, d1, de)

    def _cleanup(self, now, d5, d1, de):
        try:
            with self.con:
                self.con.execute("DELETE FROM disk WHERE res = 5 AND ts < ?", (now - d5,))
                self.con.execute("DELETE FROM sys WHERE res = 5 AND ts < ?", (now - d5,))
                self.con.execute("DELETE FROM disk WHERE res = 60 AND ts < ?", (now - d1,))
                self.con.execute("DELETE FROM sys WHERE res = 60 AND ts < ?", (now - d1,))
                self.con.execute("DELETE FROM fsync WHERE ts < ?", (now - d1,))
                self.con.execute("DELETE FROM slow_fsync WHERE ts < ?", (now - d1,))
                self.con.execute("DELETE FROM events WHERE start < ?", (now - de,))
            self.con.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        except sqlite3.Error as e:
            log(f"Aufräumen fehlgeschlagen: {e}")


# ---------------------------------------------------------------------------
# Laufwerke und System
# ---------------------------------------------------------------------------
def devices(regex):
    out = {}
    for p in sorted(glob.glob("/sys/block/*")):
        d = os.path.basename(p)
        if not re.match(regex, d):
            continue
        try:
            if int(read(f"{p}/size", "0")) == 0:
                continue
        except ValueError:
            continue
        rot = read(f"{p}/queue/rotational").strip() == "1"
        if os.environ.get("WLAT_TEST_ALL_SSD"):
            rot = False
        usb = "/usb" in os.path.realpath(f"{p}/device")
        out[d] = {"rot": rot, "usb": usb, "model": read(f"{p}/device/model").strip()}
    return out


def diskstats(names):
    res = {}
    for line in read("/proc/diskstats").splitlines():
        p = line.split()
        if len(p) < 14 or p[2] not in names:
            continue
        v = [int(x) for x in p[3:]]
        fl, ft = (v[15], v[16]) if len(v) >= 17 else (0, 0)
        # Anfragen/Sektoren/ms für Lesen und Schreiben, laufende Anfragen, io_ticks, Flushes
        res[p[2]] = (v[0], v[2], v[3], v[4], v[6], v[7], v[8], v[9], fl, ft)
    return res


def cpustat():
    cpus = {}
    for line in read("/proc/stat").splitlines():
        if not line.startswith("cpu"):
            break
        p = line.split()
        vals = [int(x) for x in p[1:9]]
        cpus[p[0]] = (sum(vals), vals[3], vals[4])   # gesamt, idle, iowait
    return cpus


def psi_totals():
    out = {}
    for res in ("cpu", "io"):
        for line in read(f"/proc/pressure/{res}").splitlines():
            kind = line.split()[0]
            m = re.search(r"total=(\d+)", line)
            if m:
                out[f"{res}_{kind}"] = int(m.group(1))
    return out


def norm_comm(c):
    if c.startswith("kworker"):
        return "kworker"
    return re.sub(r"/\d+$", "", c)


class ProcWriters:
    """Netto-Schreibmenge je Prozessname (write_bytes - cancelled_write_bytes) aus /proc/<pid>/io.
    Endet ein Prozess, rechnet der Kernel seine Menge dem abräumenden Elternprozess zu - was beim Kind
    schon gezählt wurde, wird dort wieder abgezogen."""

    def __init__(self):
        self.prev, self.first, self.cred = {}, {}, defaultdict(int)

    def sample(self):
        cur = {}
        for pid in os.listdir("/proc"):
            if not pid.isdigit():
                continue
            try:
                with open(f"/proc/{pid}/io") as f:
                    io = f.read()
                with open(f"/proc/{pid}/stat") as f:
                    st = f.read()
            except OSError:
                continue
            wb = cw = 0
            for line in io.splitlines():
                if line.startswith("write_bytes:"):
                    wb = int(line.split()[1])
                elif line.startswith("cancelled_write_bytes:"):
                    cw = int(line.split()[1])
            lp, rp = st.find("("), st.rfind(")")
            rest = st[rp + 2:].split()
            cur[pid] = (wb - cw, rest[1] if len(rest) > 1 else "0", norm_comm(st[lp + 1:rp]))
        gone = {p for p in self.prev if p not in cur and p in self.first}
        for _ in range(50):
            done = [p for p in gone if not any(self.prev[q][1] == p for q in gone)]
            if not done:
                break
            for p in done:
                parent = self.prev[p][1]
                self.cred[parent] += self.prev[p][0] - self.first[p] + self.cred.pop(p, 0)
                self.first.pop(p, None)
                gone.discard(p)
        out = defaultdict(int)
        for p, (net, _, comm) in cur.items():
            if p in self.prev:
                d = net - self.prev[p][0]
                if d > 0 and self.cred.get(p, 0) > 0:
                    c = min(d, self.cred[p])
                    d -= c
                    self.cred[p] -= c
                if d > 0:
                    out[comm] += d
            self.first.setdefault(p, net)
        self.prev = cur
        return out


def top(d, n, scale=1.0):
    return [[k, round(v * scale, 3)] for k, v in sorted(d.items(), key=lambda kv: -kv[1])[:n] if v > 0]


# ---------------------------------------------------------------------------
# Sammler: jede Sekunde Laufwerke (für Hänger), alle 5 s eine Zeile, jede Minute eine Minutenzeile
# ---------------------------------------------------------------------------
class Collector(threading.Thread):
    def __init__(self, conf, store, fsync):
        super().__init__(daemon=True)
        self.conf, self.store, self.fsync = conf, store, fsync
        self.stall = float(conf["stall_ms"])
        self.devs = devices(conf["devices"])
        self.writers = ProcWriters()
        self.live = {}            # letzte 5-s-Werte für die Statusseite
        self.open_ev = {}         # dev -> laufender Hänger
        self.closing = []         # beendete Hänger, warten noch auf fsync-Meldungen
        self.recent_writers = []  # (ts, {comm: bytes/s})

    def run(self):
        names = set(self.devs)
        prev, t_prev = diskstats(names), time.monotonic()
        cpu_prev, psi_prev = cpustat(), psi_totals()
        win = defaultdict(lambda: defaultdict(float))
        minute = defaultdict(lambda: defaultdict(float))
        min_sys = defaultdict(float)
        min_writers = defaultdict(float)
        min_n = 0
        t5 = time.time() // 5 * 5 + 5
        t60 = time.time() // 60 * 60 + 60
        self.writers.sample()
        while not STOP.is_set():
            STOP.wait(1 - (time.time() % 1))
            now, mono = time.time(), time.monotonic()
            cur = diskstats(names)
            dt = max(mono - t_prev, 0.001)
            for d, c in cur.items():
                if d not in prev:
                    continue
                p = prev[d]
                dr, dr_s = c[0] - p[0], c[1] - p[1]
                dw, dw_s, dw_t = c[3] - p[3], c[4] - p[4], c[5] - p[5]
                inflight, dio, df, df_t = c[6], c[7] - p[7], c[8] - p[8], c[9] - p[9]
                wa = dw_t / dw if dw else 0.0
                fa = df_t / df if df else 0.0
                util = min(100.0, dio / (dt * 10))
                w = win[d]
                for k, v in (("dw", dw), ("dw_s", dw_s), ("dw_t", dw_t), ("df", df), ("df_t", df_t),
                             ("dr_s", dr_s), ("dio", dio), ("dt", dt)):
                    w[k] += v
                w["wa_max"] = max(w["wa_max"], wa)
                w["fa_max"] = max(w["fa_max"], fa)
                if not self.devs[d]["rot"] and dt >= 0.5:
                    # Hänger: langsame Anfragen, oder das Gerät hat Anfragen offen und beendet gar keine
                    slow = (dw and wa >= self.stall) or (df and fa >= self.stall) or \
                           (util >= 90 and inflight > 0 and dr + dw + df == 0)
                    self.track_event(d, now, bool(slow), wa, fa)
            prev, t_prev = cur, mono
            self.finish_events(now)

            if now >= t5:
                t5 = now // 5 * 5 + 5
                ts = int(now // 5 * 5)
                cpu, psi = cpustat(), psi_totals()
                sysrow = self.sys_values(cpu_prev, cpu, psi_prev, psi)
                cpu_prev, psi_prev = cpu, psi
                wr = self.writers.sample()
                span = sum(w["dt"] for w in win.values()) / max(len(win), 1) or 5
                wr_rate = {k: v / span for k, v in wr.items()}
                self.recent_writers = [x for x in self.recent_writers if x[0] > now - 120] + [(now, wr_rate)]
                for k, v in wr.items():
                    min_writers[k] += v
                self.store.add("INSERT OR REPLACE INTO sys VALUES (5,?,?,?,?,?,?,?,?)",
                               (ts, *sysrow, json.dumps(top(wr_rate, 5, 1 / 1048576))))
                for k, v in zip(("cpu", "iowait", "maxcore", "psi_cpu", "psi_io_some", "psi_io_full"), sysrow):
                    min_sys[k] += v
                min_n += 1
                live = {"ts": ts, "sys": dict(zip(("cpu", "iowait", "maxcore", "psi_cpu", "psi_io_some",
                                                   "psi_io_full"), sysrow)),
                        "writers": top(wr_rate, 5, 1 / 1048576), "disk": {}}
                for d, w in win.items():
                    row = self.disk_row(w)
                    live["disk"][d] = dict(zip(("w_iops", "w_mbs", "w_await", "w_await_max", "f_rate", "f_await",
                                                "f_await_max", "r_mbs", "util"), row))
                    self.store.add("INSERT OR REPLACE INTO disk VALUES (5,?,?,?,?,?,?,?,?,?,?,?)", (ts, d, *row))
                    m = minute[d]
                    for k, v in w.items():
                        if k in ("wa_max", "fa_max"):
                            m[k] = max(m[k], v)
                        else:
                            m[k] += v
                self.live = live
                win.clear()

            if now >= t60:
                t60 = now // 60 * 60 + 60
                ts = int(now // 60 * 60) - 60
                for d, m in minute.items():
                    self.store.add("INSERT OR REPLACE INTO disk VALUES (60,?,?,?,?,?,?,?,?,?,?,?)",
                                   (ts, d, *self.disk_row(m)))
                if min_n:
                    span = 60.0
                    self.store.add("INSERT OR REPLACE INTO sys VALUES (60,?,?,?,?,?,?,?,?)",
                                   (ts, *(round(min_sys[k] / min_n, 2) for k in
                                          ("cpu", "iowait", "maxcore", "psi_cpu", "psi_io_some", "psi_io_full")),
                                    json.dumps(top({k: v / span for k, v in min_writers.items()}, 10, 1 / 1048576))))
                minute.clear()
                min_sys.clear()
                min_writers.clear()
                min_n = 0
                self.store.flush()

    @staticmethod
    def disk_row(w):
        dt = w["dt"] or 1
        return (round(w["dw"] / dt, 2), round(w["dw_s"] * 512 / 1048576 / dt, 3),
                round(w["dw_t"] / w["dw"], 3) if w["dw"] else 0.0, round(w["wa_max"], 2),
                round(w["df"] / dt, 2), round(w["df_t"] / w["df"], 3) if w["df"] else 0.0, round(w["fa_max"], 2),
                round(w["dr_s"] * 512 / 1048576 / dt, 3), round(min(100.0, w["dio"] / (dt * 10)), 1))

    @staticmethod
    def sys_values(cp, cc, pp, pc):
        busy = iow = maxcore = 0.0
        if "cpu" in cp and "cpu" in cc:
            tot = cc["cpu"][0] - cp["cpu"][0]
            if tot > 0:
                busy = 100 * (tot - (cc["cpu"][1] - cp["cpu"][1]) - (cc["cpu"][2] - cp["cpu"][2])) / tot
                iow = 100 * (cc["cpu"][2] - cp["cpu"][2]) / tot
        for k in cc:
            if k == "cpu" or k not in cp:
                continue
            tot = cc[k][0] - cp[k][0]
            if tot > 0:
                maxcore = max(maxcore, 100 * (tot - (cc[k][1] - cp[k][1]) - (cc[k][2] - cp[k][2])) / tot)

        def psi(k):
            return round(min(100.0, (pc.get(k, 0) - pp.get(k, 0)) / 5e4), 2) if k in pc and k in pp else 0.0
        return (round(busy, 1), round(iow, 1), round(maxcore, 1), psi("cpu_some"), psi("io_some"), psi("io_full"))

    def track_event(self, d, now, slow, wa, fa):
        ev = self.open_ev.get(d)
        if slow:
            if ev is None:
                ev = self.open_ev[d] = {"dev": d, "start": now - 1, "end": now, "max_w": 0.0, "max_f": 0.0}
            ev["end"] = now
            ev["max_w"] = max(ev["max_w"], wa)
            ev["max_f"] = max(ev["max_f"], fa)
        elif ev is not None and now - ev["end"] >= 3:
            self.closing.append(self.open_ev.pop(d))

    def finish_events(self, now):
        # 20 s nach dem Ende abschließen: bis dahin sind die fsync-Meldungen der Wartenden eingetroffen
        keep = []
        for ev in self.closing:
            if now - ev["end"] < 20:
                keep.append(ev)
                continue
            wr = defaultdict(float)
            n = 0
            for t, w in self.recent_writers:
                if ev["start"] - 5 <= t <= ev["end"] + 5:
                    n += 1
                    for k, v in w.items():
                        wr[k] += v
            writers = top({k: v / max(n, 1) for k, v in wr.items()}, 5, 1 / 1048576)
            waiters = self.fsync.waiters(ev["start"], ev["end"]) if self.fsync else []
            self.store.add("INSERT INTO events (dev, start, end, max_w, max_f, writers, waiters) "
                           "VALUES (?,?,?,?,?,?,?)",
                           (ev["dev"], round(ev["start"], 1), round(ev["end"], 1), round(ev["max_w"], 1),
                            round(ev["max_f"], 1), json.dumps(writers), json.dumps(waiters)))
        self.closing = keep


# ---------------------------------------------------------------------------
# bpftrace: fsync-Aufrufer (alle 5 min zusammengefasst) und einzelne langsame Aufrufe (>= 100 ms)
# ---------------------------------------------------------------------------
BPF = r"""
tracepoint:syscalls:sys_enter_fsync, tracepoint:syscalls:sys_enter_fdatasync,
tracepoint:syscalls:sys_enter_sync_file_range, tracepoint:syscalls:sys_enter_syncfs, tracepoint:syscalls:sys_enter_sync
{ @start[tid] = nsecs; @n[curtask->group_leader->comm, comm] = count(); }
tracepoint:syscalls:sys_enter_msync /args->flags & 4/
{ @start[tid] = nsecs; @n[curtask->group_leader->comm, comm] = count(); }
tracepoint:syscalls:sys_exit_fsync, tracepoint:syscalls:sys_exit_fdatasync,
tracepoint:syscalls:sys_exit_sync_file_range, tracepoint:syscalls:sys_exit_syncfs, tracepoint:syscalls:sys_exit_sync,
tracepoint:syscalls:sys_exit_msync
/@start[tid]/
{
  $us = (nsecs - @start[tid]) / 1000;
  @us[curtask->group_leader->comm, comm] = sum($us);
  @max[curtask->group_leader->comm, comm] = max($us);
  if ($us >= 100000) { printf("SLOW|%d|%s|%s\n", $us, curtask->group_leader->comm, comm); }
  delete(@start[tid]);
}
interval:s:300 { print(@n); print(@us); print(@max); clear(@n); clear(@us); clear(@max); printf("TICK\n"); }
END { clear(@start); clear(@n); clear(@us); clear(@max); }
"""
MAPLINE = re.compile(r"^@(\w+)\[(.*)\]: (-?\d+)$")


class FsyncTracer(threading.Thread):
    def __init__(self, store):
        super().__init__(daemon=True)
        self.store = store
        self.proc = None
        self.slow = []   # (start, end, ms, proc, thread)
        self.lock = threading.Lock()

    def waiters(self, start, end):
        with self.lock:
            hits = [s for s in self.slow if s[0] <= end and s[1] >= start]
        agg = {}
        for s0, s1, ms, proc, thread in hits:
            name = proc if proc == thread else f"{proc}/{thread}"
            agg[name] = max(agg.get(name, 0), ms)
        return [[k, round(v, 1)] for k, v in sorted(agg.items(), key=lambda kv: -kv[1])[:8]]

    def run(self):
        while not STOP.is_set():
            if not shutil_which("bpftrace"):
                INFO["bpftrace"] = "nicht installiert (apt install bpftrace)"
                return
            try:
                self.proc = subprocess.Popen(["bpftrace", "-B", "none", "-e", BPF], stdout=subprocess.PIPE,
                                             stderr=subprocess.PIPE, text=True)
            except OSError as e:
                INFO["bpftrace"] = f"Start fehlgeschlagen: {e}"
                return
            maps = defaultdict(dict)
            t_tick = time.time()
            for line in self.proc.stdout:
                line = line.rstrip("\n")
                # bpftrace bis 0.20: "Attaching N probes...", neuere Versionen: "Attached N probes"
                if line.startswith("Attach"):
                    INFO["bpftrace"] = "läuft"
                    continue
                if line.startswith("SLOW|") or line == "TICK":
                    INFO["bpftrace"] = "läuft"
                if line.startswith("SLOW|"):
                    p = line.split("|", 3)
                    if len(p) == 4:
                        ms, now = int(p[1]) / 1000, time.time()
                        with self.lock:
                            self.slow = [s for s in self.slow if s[1] > now - 600] + \
                                        [(now - ms / 1000, now, ms, p[2], p[3])]
                        self.store.add("INSERT INTO slow_fsync VALUES (?,?,?,?)",
                                       (round(now - ms / 1000, 2), round(ms, 1), p[2], p[3]))
                elif line == "TICK":
                    now = time.time()
                    for key, n in maps["n"].items():
                        proc, _, thread = key.partition(", ")
                        self.store.add("INSERT INTO fsync VALUES (?,?,?,?,?,?,?)",
                                       (int(now), int(now - t_tick), proc, thread or proc, n,
                                        round(maps["us"].get(key, 0) / 1000, 1),
                                        round(maps["max"].get(key, 0) / 1000, 1)))
                    maps.clear()
                    t_tick = now
                else:
                    m = MAPLINE.match(line)
                    if m:
                        maps[m.group(1)][m.group(2)] = int(m.group(3))
                if STOP.is_set():
                    break
            err = self.proc.stderr.read() if self.proc.stderr else ""
            self.proc.wait()
            if STOP.is_set():
                return
            msg = next((l for l in err.splitlines() if "ERROR" in l and "RLIMIT" not in l), "beendet")
            INFO["bpftrace"] = f"Fehler: {msg[:200]} - neuer Versuch in 5 min"
            STOP.wait(300)

    def stop(self):
        if self.proc and self.proc.poll() is None:
            self.proc.send_signal(signal.SIGINT)
            try:
                self.proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.proc.kill()


def shutil_which(name):
    for d in os.environ.get("PATH", "/usr/sbin:/usr/bin:/sbin:/bin").split(":"):
        if os.access(os.path.join(d, name), os.X_OK):
            return True
    return False


# ---------------------------------------------------------------------------
# SMART, Schreibcache und TRIM (alle 30 min)
# ---------------------------------------------------------------------------
WDSD = re.compile(r"SanDisk|^SD |SDSSD|WDS[0-9]|WD (Blue|Red|Green)")


def attr(sm, num, col=9):
    for line in sm.splitlines():
        p = line.split()
        if len(p) >= 10 and p[0] == str(num):
            try:
                return int(p[col].split()[0]) if col == 9 else int(p[col])
            except ValueError:
                return None
    return None


def smart_sample(store, conf):
    if not shutil_which("smartctl"):
        store.kv_set("smart", {"error": "smartctl nicht installiert (apt install smartmontools)"})
        return
    t0 = time.time()
    boot_log = run(["journalctl", "-k", "-b", "-o", "cat"]) or run(["dmesg"])
    now = int(time.time())
    for d, info in devices(conf["devices"]).items():
        dev = f"/dev/{d}"
        sm = run(["smartctl", "-i", "-A", dev])
        model = (re.search(r"^(?:Device Model|Model Number):\s*(.+)$", sm, re.M) or [None, info["model"]])[1].strip()
        serial = (re.search(r"^Serial Number:\s*(.+)$", sm, re.M) or [None, d])[1].strip()
        poh = attr(sm, 9)
        if poh is None:
            m = re.search(r"^Power On Hours:\s*([\d,]+)", sm, re.M)
            poh = int(m.group(1).replace(",", "")) if m else None
        temp = attr(sm, 194)
        if temp is None:
            m = re.search(r"^Temperature:\s*(\d+)", sm, re.M)
            temp = int(m.group(1)) if m else None
        used = None
        if not info["rot"]:
            for line in run(["smartctl", "-l", "devstat", dev]).splitlines():
                if "Percentage Used Endurance Indicator" in line:
                    try:
                        used = int(line.split()[3])
                    except (IndexError, ValueError):
                        pass
            if used is None:
                m = re.search(r"^Percentage Used:\s*(\d+)%", sm, re.M)
                if m:
                    used = int(m.group(1))
                elif WDSD.search(model) and attr(sm, 230) is not None:
                    used = attr(sm, 230)
                else:
                    for a in (169, 202, 177, 231):
                        v = attr(sm, a, 3)
                        if v is not None:
                            used = 100 - v
                            break
        num = den = host = nand = None
        if WDSD.search(model) and attr(sm, 233) and attr(sm, 241):
            num, den = attr(sm, 233), attr(sm, 241)
            host, nand = den, 1
        elif re.search(r"SAMSUNG|^MZ", model) and attr(sm, 251) and attr(sm, 241):
            # Samsung (SM883/PM883 u.ä.): NAND- und Host-Schreibmenge in LBAs, umgerechnet in GiB
            num, den = round(attr(sm, 251) * 512 / 2 ** 30, 2), round(attr(sm, 241) * 512 / 2 ** 30, 2)
            host, nand = den, 1
        elif "FTL_Program_Page_Count" in sm and attr(sm, 247):
            num, den = attr(sm, 247) + (attr(sm, 248) or 0), attr(sm, 247)
            host, nand = round((attr(sm, 246) or 0) * 512 / 2 ** 30, 1), 0
        wc_drive = sct = wc_boot = None
        wc_kernel = read(f"/sys/block/{d}/queue/write_cache").strip() or None
        if d.startswith("sd") and not info["usb"]:
            if shutil_which("hdparm"):
                m = re.search(r"write-caching\s*=\s*([01])", run(["hdparm", "-W", dev]))
                wc_drive = m.group(1) if m else None
            m = re.search(r"^SCT Write Cache Control:\s*(.+)$", run(["smartctl", "-g", "wcache-sct", dev]), re.M)
            sct = m.group(1).strip() if m and not re.search(r"not supported|unavailable", m.group(1), re.I) else None
            m = re.search(rf"\[{d}\] Write cache: (\w+)", boot_log)
            wc_boot = m.group(1) if m else None
        store.add("INSERT INTO smart VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                  (now, d, serial, model, int(info["rot"]), int(info["usb"]), poh, used, num, den, host, nand, temp,
                   attr(sm, 5), attr(sm, 199), wc_drive, wc_kernel, wc_boot, sct))
    # SMART-/hdparm-Befehle laufen am NCQ-Puffer vorbei: Zeitraum merken, um Hänger in dieser Zeit zu kennzeichnen
    store.add("INSERT INTO smart_runs VALUES (?, ?)", (round(t0, 1), round(time.time(), 1)))
    store.kv_set("trim", trim_status())
    store.flush()


def trim_period(cal):
    if ".." in cal or "," in cal:
        return None
    if cal in ("", "weekly") or re.match(r"^(Mon|Tue|Wed|Thu|Fri|Sat|Sun)", cal):
        return 7
    if cal == "daily" or cal.startswith("*-*-* ") or cal == "*-*-*":
        return 1
    if cal == "monthly" or re.match(r"^\*-\*-\d", cal):
        return 30
    return None


def trim_status():
    if run(["systemctl", "is-enabled", "fstrim.timer"]).strip() != "enabled":
        return {"enabled": False}
    m = re.search(r"OnCalendar=([^;]*[^ ;]) *;", run(["systemctl", "show", "fstrim.timer", "-p", "TimersCalendar",
                                                       "--value"]))
    cal = m.group(1) if m else ""
    period = trim_period(cal) or 7
    out = {"enabled": True, "schedule": cal, "period": period, "mounts": []}
    entries = []
    for line in run(["journalctl", "-u", "fstrim.service", "-o", "json", "--no-pager", "-q", "-n", "1000"]).splitlines():
        try:
            e = json.loads(line)
        except ValueError:
            continue
        msg = e.get("MESSAGE")
        if isinstance(msg, str) and "bytes) trimmed" in msg:
            entries.append((int(e.get("__REALTIME_TIMESTAMP", "0")) / 1e6, e.get("_BOOT_ID"), msg))
    for line in read("/proc/mounts").splitlines():
        p = line.split()
        if len(p) < 3 or p[2] != "ext4" or not p[0].startswith("/dev/"):
            continue
        if run(["lsblk", "-ndo", "ROTA", p[0]]).strip() != "0":
            continue
        mnt = p[1]
        try:
            st = os.statvfs(mnt)
            size = st.f_blocks * st.f_frsize
        except OSError:
            continue
        rates, last, lastboot = [], 0, None
        for t, boot, msg in entries:
            if not msg.startswith(mnt + ": "):
                continue
            m = re.search(r"\((\d+) bytes\)", msg)
            if not m:
                continue
            if boot == lastboot and t - last > 3600:
                rates.append(int(m.group(1)) / (t - last) * 86400)
            lastboot, last = boot, t
        item = {"mount": mnt, "last": last or None}
        if rates:
            r = sorted(rates[-5:])[len(rates[-5:]) // 2]
            item.update({"deleted_gib_day": round(r / 2 ** 30, 1),
                         "untrimmed_pct": round(100 * r * period / size, 1) if size else 0})
        out["mounts"].append(item)
    return out


# ---------------------------------------------------------------------------
# Auswertung für die Statusseite
# ---------------------------------------------------------------------------
def fmt_days(x):
    if x >= 730:
        return f"~{x / 365:.1f} Jahre".replace(".", ",")
    if x >= 60:
        return f"~{x / 30.4:.0f} Monate"
    return f"~{x:.0f} Tage"


def smart_view(con):
    # Nur Laufwerke aus der letzten SMART-Abfrage: Ausgebaute SSDs (andere Seriennummer) verschwinden aus Anzeige,
    # Befunden und CheckMK. Ihr Verlauf bleibt in der Datenbank (Schreibverstärkung pro Tag).
    rows = con.execute("SELECT * FROM smart WHERE ts = (SELECT MAX(ts) FROM smart s2 WHERE s2.serial = smart.serial) "
                       "AND ts >= (SELECT MAX(ts) FROM smart) - 60 ORDER BY dev").fetchall()
    cols = [c[0] for c in con.execute("SELECT * FROM smart LIMIT 0").description]
    out = []
    for r in rows:
        s = dict(zip(cols, r))
        s["waf_24h"] = s["host_day"] = s["nand_day"] = s["remaining_days"] = None
        s["remaining_lifetime_days"] = None
        if s["num"] and s["den"]:
            s["waf_total"] = round(s["num"] / s["den"], 1)
            ref = con.execute("SELECT ts, num, den, host_gib FROM smart WHERE serial = ? AND ts <= ? "
                              "ORDER BY ts DESC LIMIT 1", (s["serial"], s["ts"] - 72000)).fetchone() or \
                con.execute("SELECT ts, num, den, host_gib FROM smart WHERE serial = ? AND ts <= ? "
                            "ORDER BY ts ASC LIMIT 1", (s["serial"], s["ts"] - 3600)).fetchone()
            if ref and s["den"] > ref[2]:
                days = (s["ts"] - ref[0]) / 86400
                s["waf_24h"] = round((s["num"] - ref[1]) / (s["den"] - ref[2]), 1)
                s["window_h"] = round(days * 24)
                s["host_day"] = round((s["host_gib"] - ref[3]) / days, 1) if s["host_gib"] is not None else None
                if s["nand_gib"]:
                    s["nand_day"] = round((s["num"] - ref[1]) / days)
                rate = (s["num"] - ref[1]) / days
                if s["used"] and rate > 0:
                    s["remaining_days"] = round(s["num"] * (100 - s["used"]) / s["used"] / rate)
        if s["used"] and s["poh"] and s["poh"] > 24:
            s["remaining_lifetime_days"] = round((100 - s["used"]) / s["used"] * s["poh"] / 24)
        out.append(s)
    return out


def build_status(con, collector, conf):
    now = time.time()
    smart = smart_view(con)
    findings = []

    def add(level, text):
        findings.append({"level": level, "text": text})

    for s in smart:
        d = s["dev"]
        if s["rot"]:
            continue
        if s["wc_drive"] == "1" and s["wc_kernel"] == "write through":
            add("crit", f"{d}: Kernel hält den Schreibcache für aus und schickt keine Flushes - Datenverlust bei "
                        f"Stromausfall möglich (echo 1 > /sys/block/{d}/device/rescan).")
        elif s["wc_drive"] == "0" or (s["sct"] and "force disabled" in s["sct"].lower()):
            add("warn", f"{d}: Schreibcache aus - langsam und hohe Schreibverstärkung."
                        + (f" Dauerhaft einschalten: smartctl -s wcache-sct,on,p /dev/{d}" if s["sct"] else ""))
        elif s["wc_boot"] == "disabled" and not (s["sct"] and "force enabled" in s["sct"].lower()):
            add("info", f"{d}: Schreibcache ist beim Start aus und wird erst danach eingeschaltet."
                        + (f" Dauerhaft: smartctl -s wcache-sct,on,p /dev/{d}" if s["sct"] else ""))
        if s["waf_24h"] is not None:
            lvl = "crit" if s["waf_24h"] >= 10 else "warn" if s["waf_24h"] >= 5 else None
            if lvl:
                add(lvl, f"{d}: Schreibverstärkung {str(s['waf_24h']).replace('.', ',')} in den letzten {s.get('window_h')} h - viele kleine "
                         f"Sync-Schreibzugriffe/Flushes auf einer SSD ohne Power-Loss-Protection.")
        rem = s["remaining_days"] if s["remaining_days"] is not None else s["remaining_lifetime_days"]
        if rem is not None and rem < 730:
            add("crit" if rem < 365 else "warn", f"{d}: Restlaufzeit bei aktuellem Tempo {fmt_days(rem)}.")
        if s["realloc"]:
            add("info", f"{d}: {s['realloc']} reallokierte Sektoren.")
        if s["crc"]:
            add("warn", f"{d}: {s['crc']} CRC-Fehler (Kabel/Backplane/Port prüfen).")

    ev24 = con.execute("SELECT COUNT(*), SUM(end - start), MAX(MAX(max_w, max_f)) FROM events WHERE start > ?",
                       (now - 86400,)).fetchone()
    long24 = con.execute("SELECT COUNT(*) FROM events WHERE start > ? AND (end - start >= 2 OR MAX(max_w, max_f) >= 1000)",
                         (now - 86400,)).fetchone()[0]
    # Wie viel der letzten 24 h ist überhaupt aufgezeichnet? (Dienst neu, oder nach Pause)
    first = con.execute("SELECT MIN(ts) FROM disk WHERE res = 5 AND ts > ?", (now - 86400,)).fetchone()[0] or now
    up = now - first
    since = "in den letzten 24 h" if up >= 82800 else \
        f"seit Beginn der Aufzeichnung vor {up / 3600:.0f} h" if up >= 3600 else \
        f"seit Beginn der Aufzeichnung vor {up / 60:.0f} min"
    hours = min(24.0, max(up / 3600, 1.0))   # Raten erst ab einer Stunde sinnvoll
    if long24:
        add("crit" if long24 / hours >= 1 else "warn", f"{long24} lange Hänger (≥ 2 s oder ≥ 1 s Wartezeit) {since}.")
    elif ev24[0] and ev24[0] / hours >= 5:
        add("warn", f"{ev24[0]} kurze Hänger {since} ({ev24[0] / hours:.0f} pro Stunde).")

    trim = json.loads((con.execute("SELECT v FROM kv WHERE k = 'trim'").fetchone() or ["{}"])[0])
    if trim.get("enabled") is False:
        add("warn", "fstrim.timer ist nicht aktiv: systemctl enable --now fstrim.timer")
    for m in trim.get("mounts", []):
        if trim.get("period", 7) > 1 and m.get("untrimmed_pct", 0) >= 2:
            add("warn", f"TRIM {m['mount']}: bis zum nächsten Lauf bis zu {str(m['untrimmed_pct']).replace('.', ',')} % der "
                        f"Kapazität ungetrimmt ({str(m['deleted_gib_day']).replace('.', ',')} GiB/Tag gelöscht) - täglich trimmen: systemctl edit "
                        f"fstrim.timer, [Timer] OnCalendar= und OnCalendar=daily")
        if m.get("last") and now - m["last"] > (trim.get("period", 7) + 1) * 86400:
            add("warn", f"TRIM {m['mount']}: letzter Lauf vor {(now - m['last']) / 86400:.0f} Tagen.")

    psi1h = con.execute("SELECT AVG(psi_io_full), AVG(psi_cpu) FROM sys WHERE res = 60 AND ts > ?",
                        (now - 3600,)).fetchone()
    if psi1h[0] and psi1h[0] >= 10:
        add("warn", f"IO-Druck: Prozesse waren in der letzten Stunde zu {psi1h[0]:.0f} % komplett durch IO blockiert.")
    if psi1h[1] and psi1h[1] >= 20:
        add("warn", f"CPU-Druck: Prozesse warteten in der letzten Stunde zu {psi1h[1]:.0f} % auf CPU-Zeit.")
    if not any(f["level"] in ("warn", "crit") for f in findings):
        add("ok", "Keine Auffälligkeiten.")
    order = {"crit": 0, "warn": 1, "info": 2, "ok": 3}
    findings.sort(key=lambda f: order[f["level"]])

    lat5 = {r[0]: {"w_await": r[1], "f_await": r[2], "f_rate": r[3], "max": r[4], "util": r[5]} for r in con.execute(
        "SELECT dev, AVG(w_await), AVG(f_await), AVG(f_rate), MAX(MAX(w_await_max, f_await_max)), AVG(util) "
        "FROM disk WHERE res = 5 AND ts > ? GROUP BY dev", (now - 300,))}
    return {"version": VERSION, "host": os.uname().nodename, "now": now, "started": INFO["started"],
            "bpftrace": INFO["bpftrace"], "update": INFO["update"], "findings": findings, "smart": smart,
            "devices": collector.devs, "live": collector.live, "last5min": lat5, "trim": trim,
            "events24": {"count": ev24[0] or 0, "seconds": round(ev24[1] or 0, 1), "max_ms": ev24[2],
                         "long": long24}}


RANGES = {"1h": 3600, "6h": 21600, "24h": 86400, "7d": 604800, "30d": 2592000, "90d": 7776000}


def series(con, rng):
    secs = RANGES.get(rng, 21600)
    now = time.time()
    res = 5 if secs <= 21600 else 60
    bucket = max(res, int(secs / 900) // res * res)
    since = now - secs
    disk = defaultdict(lambda: defaultdict(list))
    for r in con.execute(
            "SELECT dev, ts / ? * ? AS b, MAX(MAX(w_await_max, f_await_max)), AVG(f_rate), AVG(w_mbs), AVG(util), "
            "AVG(f_await) FROM disk WHERE res = ? AND ts > ? GROUP BY dev, b ORDER BY b", (bucket, bucket, res, since)):
        dd = disk[r[0]]
        for k, v in zip(("t", "lat_max", "f_rate", "w_mbs", "util", "f_await"), r[1:]):
            dd[k].append(round(v, 2) if isinstance(v, float) else v)
    sysd = defaultdict(list)
    for r in con.execute("SELECT ts / ? * ? AS b, AVG(cpu), AVG(iowait), AVG(psi_cpu), AVG(psi_io_some), "
                         "AVG(psi_io_full) FROM sys WHERE res = ? AND ts > ? GROUP BY b ORDER BY b",
                         (bucket, bucket, res, since)):
        for k, v in zip(("t", "cpu", "iowait", "psi_cpu", "psi_io_some", "psi_io_full"), r):
            sysd[k].append(round(v, 2) if isinstance(v, float) else v)
    return {"range": rng, "bucket": bucket, "since": since, "now": now, "disk": disk, "sys": sysd}


FELT_EV = "(MAX(max_w, max_f) >= ? OR end - start >= 2)"
SMART_OVERLAP = "EXISTS (SELECT 1 FROM smart_runs r WHERE r.start <= events.end + 1 AND r.end >= events.start - 1)"


def event_dict(r):
    return {"id": r[0], "dev": r[1], "start": r[2], "dur": round(r[3] - r[2], 1), "max_w": r[4], "max_f": r[5],
            "writers": json.loads(r[6] or "[]"), "waiters": json.loads(r[7] or "[]"), "smart": bool(r[8])}


def felt(con, rng, felt_ms):
    """Hänger in echten Sekunden, so wie Benutzer sie merken: Geräte-Hänger ab felt_ms Wartezeit oder 2 s Dauer,
    und Anwendungen, die einzeln ab felt_ms auf ein fsync gewartet haben."""
    now = time.time()
    out = {"felt_ms": felt_ms, "windows": {}}
    for name, secs in (("1h", 3600), ("24h", 86400), ("7d", 604800)):
        since = now - secs
        n, total, longest = con.execute(f"SELECT COUNT(*), SUM(end - start), MAX(end - start) FROM events "
                                        f"WHERE start > ? AND {FELT_EV}", (since, felt_ms)).fetchone()
        an, atotal, amax = con.execute("SELECT COUNT(*), SUM(ms), MAX(ms) FROM slow_fsync WHERE ts > ? AND ms >= ?",
                                       (since, felt_ms)).fetchone()
        who = con.execute("SELECT proc, thread FROM slow_fsync WHERE ts > ? ORDER BY ms DESC LIMIT 1",
                          (since,)).fetchone() if amax else None
        out["windows"][name] = {"n": n or 0, "secs": round(total or 0, 1), "longest": round(longest or 0, 1),
                                "app_n": an or 0, "app_secs": round((atotal or 0) / 1000, 1),
                                "app_max": round((amax or 0) / 1000, 1),
                                "app_who": (who[0] if who[0] == who[1] else f"{who[0]}/{who[1]}") if who else None}
    last = con.execute(f"SELECT dev, start, end, MAX(max_w, max_f), waiters FROM events WHERE {FELT_EV} "
                       f"ORDER BY start DESC LIMIT 1", (felt_ms,)).fetchone()
    if last:
        out["last"] = {"dev": last[0], "start": last[1], "dur": round(last[2] - last[1], 1), "max_ms": last[3],
                       "waiters": json.loads(last[4] or "[]")}
    since = now - RANGES.get(rng, 604800)
    hours = defaultdict(lambda: {"secs": 0.0, "app_max": 0.0})
    for t, secs in con.execute(f"SELECT CAST(start / 3600 AS INTEGER) * 3600, SUM(end - start) FROM events "
                               f"WHERE start > ? AND {FELT_EV} GROUP BY 1", (since, felt_ms)):
        hours[t]["secs"] = round(secs, 1)
    for t, mx in con.execute("SELECT CAST(ts / 3600 AS INTEGER) * 3600, MAX(ms) FROM slow_fsync WHERE ts > ? "
                             "GROUP BY 1", (since,)):
        hours[t]["app_max"] = round(mx / 1000, 2)
    out["hours"] = [{"t": t, **v} for t, v in sorted(hours.items())]
    out["list"] = [event_dict(r) for r in con.execute(
        f"SELECT id, dev, start, end, max_w, max_f, writers, waiters, {SMART_OVERLAP} FROM events "
        f"WHERE start > ? AND {FELT_EV} ORDER BY start DESC LIMIT 200", (since, felt_ms))]
    out["since"], out["now"] = since, now
    return out


def events(con, rng, min_ms):
    since = time.time() - RANGES.get(rng, 604800)
    rows = con.execute(f"SELECT id, dev, start, end, max_w, max_f, writers, waiters, {SMART_OVERLAP} FROM events "
                       f"WHERE start > ? AND MAX(max_w, max_f) >= ? ORDER BY start DESC LIMIT 500", (since, min_ms)).fetchall()
    per_hour = con.execute("SELECT CAST(start / 3600 AS INTEGER) * 3600, COUNT(*), SUM(end - start) FROM events "
                           "WHERE start > ? AND MAX(max_w, max_f) >= ? GROUP BY 1 ORDER BY 1", (since, min_ms)).fetchall()
    return {"events": [event_dict(r) for r in rows],
            "per_hour": [{"t": r[0], "n": r[1], "secs": round(r[2] or 0, 1)} for r in per_hour],
            "since": since, "now": time.time()}


def fsync_stats(con, rng):
    since = time.time() - RANGES.get(rng, 86400)
    rows = con.execute("SELECT proc, thread, SUM(n), SUM(sum_ms), MAX(max_ms) FROM fsync WHERE ts > ? "
                       "GROUP BY proc, thread ORDER BY SUM(n) DESC LIMIT 25", (since,)).fetchall()
    span = con.execute("SELECT SUM(secs) FROM (SELECT DISTINCT ts, secs FROM fsync WHERE ts > ?)", (since,)).fetchone()[0]
    span = span or 1
    writers = defaultdict(float)
    n = 0
    for (w,) in con.execute("SELECT writers FROM sys WHERE res = 60 AND ts > ?", (since,)):
        n += 1
        for k, v in json.loads(w or "[]"):
            writers[k] += v
    return {"span": span,
            "fsync": [{"name": p if p == t else f"{p}/{t}", "per_s": round(c / span, 2), "n": c,
                       "avg_ms": round(s / c, 2) if c else 0, "max_ms": m} for p, t, c, s, m in rows],
            "writers": [[k, round(v / max(n, 1), 3)] for k, v in sorted(writers.items(), key=lambda kv: -kv[1])[:10]
                        if v / max(n, 1) >= 0.001]}


def smart_history(con):
    out = defaultdict(list)
    for serial, dev, ts, num, den, used in con.execute(
            "SELECT serial, dev, MAX(ts), num, den, used FROM smart WHERE rot = 0 AND num IS NOT NULL "
            "GROUP BY serial, CAST(ts / 86400 AS INTEGER) ORDER BY serial, ts"):
        out[serial].append({"dev": dev, "t": ts, "num": num, "den": den, "used": used})
    res = {}
    for serial, pts in out.items():
        days = []
        for a, b in zip(pts, pts[1:]):
            if b["den"] > a["den"]:
                days.append({"t": b["t"], "waf": round((b["num"] - a["num"]) / (b["den"] - a["den"]), 1),
                             "used": b["used"]})
        res[f"{pts[-1]['dev']} ({serial})"] = days
    return res


# ---------------------------------------------------------------------------
# Textbericht zum Kopieren (z.B. für eine Auswertung im Chat)
# ---------------------------------------------------------------------------
def de(v, nd=1):
    return f"{v:.{nd}f}".replace(".", ",")


def secs_txt(v):
    return f"{de(v, 1)} s" if v < 10 else f"{v:.0f} s"


def ms_txt(v):
    return "–" if v is None else secs_txt(v / 1000) if v >= 1000 else f"{v:.0f} ms"


def report(con, collector, conf):
    now = time.time()
    st = build_status(con, collector, conf)
    fe = felt(con, "7d", float(conf["felt_ms"]))
    fs = fsync_stats(con, "24h")
    ts = lambda t: time.strftime("%d.%m. %H:%M:%S", time.localtime(t))   # noqa: E731
    first = con.execute("SELECT MIN(ts) FROM disk WHERE res = 5").fetchone()[0] or \
        con.execute("SELECT MIN(ts) FROM disk").fetchone()[0] or now
    L = [f"write-latency-diag Bericht - {st['host']} - {time.strftime('%Y-%m-%d %H:%M')} - Dienst {VERSION}, "
         f"bpftrace {st['bpftrace']}",
         f"Aufzeichnung seit {ts(first)} ({de((now - first) / 3600)} h), Dienst läuft seit {ts(st['started'])}",
         "", "BEFUND"]
    names = {"crit": "KRITISCH", "warn": "PRÜFEN", "info": "HINWEIS", "ok": "OK"}
    L += [f"  [{names[f['level']]}] {f['text']}" for f in st["findings"]]

    L += ["", f"SPÜRBARE HÄNGER (ab {secs_txt(fe['felt_ms'] / 1000)} Wartezeit oder 2 s Dauer)",
          "  Zeitraum   Anzahl  zusammen  längster | App ≥1s  zusammen  längste Wartezeit"]
    for k, w in fe["windows"].items():
        L.append(f"  {k:<9} {w['n']:>6}  {secs_txt(w['secs']):>8}  {secs_txt(w['longest']):>8} | {w['app_n']:>7}  "
                 f"{secs_txt(w['app_secs']):>8}  {secs_txt(w['app_max'])}" + (f" ({w['app_who']})" if w["app_who"] else ""))
    L += ["", "SPÜRBARE HÄNGER EINZELN (neueste zuerst, max. 25)"]
    if not fe["list"]:
        L.append("  keine")
    for e in fe["list"][:25]:
        wt = ", ".join(f"{n} {ms_txt(v)}" for n, v in e["waiters"][:4]) or "-"
        wr = ", ".join(f"{n} {de(v, 2)}" for n, v in e["writers"][:3] if v >= 0.01) or "-"
        L.append(f"  {ts(e['start'])}  {e['dev']:<6} {secs_txt(e['dur']):>6}  Gerät max {ms_txt(max(e['max_w'], e['max_f'])):>6}"
                 f"  wartete: {wt}  |  schrieb (MB/s): {wr}" + ("  [während SMART-Abfrage]" if e["smart"] else ""))

    L += ["", "HÄNGER PRO STUNDE (letzte 24 h): alle ab Schwelle / spürbar / spürbare Sekunden"]
    rows = con.execute(f"SELECT CAST(start / 3600 AS INTEGER) * 3600 h, COUNT(*), SUM({FELT_EV}), "
                       f"SUM(CASE WHEN {FELT_EV} THEN end - start ELSE 0 END) FROM events WHERE start > ? "
                       f"GROUP BY h ORDER BY h", (float(conf["felt_ms"]), float(conf["felt_ms"]), now - 86400)).fetchall()
    L += [f"  {time.strftime('%d.%m. %H:00', time.localtime(h))}  {n:>4} / {f or 0:>3} / {secs_txt(s or 0)}"
          for h, n, f, s in rows] or ["  keine"]

    L += ["", "MUSTER PRO GERÄT (spürbare Hänger, letzte 24 h): Anzahl, typische Dauer, typischer Abstand"]
    per = defaultdict(list)
    for dev, start, end in con.execute(f"SELECT dev, start, end FROM events WHERE start > ? AND {FELT_EV} ORDER BY start",
                                       (now - 86400, float(conf["felt_ms"]))):
        per[dev].append((start, end - start))
    for dev in sorted(per):
        ev = per[dev]
        durs = sorted(d for _, d in ev)
        gaps = sorted((b[0] - a[0]) / 60 for a, b in zip(ev, ev[1:]))
        line = f"  {dev:<6} {len(ev):>3}×  Dauer Median {secs_txt(durs[len(durs) // 2])}"
        if gaps:
            line += (f"  Abstand Median {de(gaps[len(gaps) // 2])} min (min {de(gaps[0])}, max {de(gaps[-1])})")
        L.append(line)
    if not per:
        L.append("  keine")

    L += ["", "LAUFWERKE"]
    for s_ in st["smart"]:
        d = s_["dev"]
        parts = [f"  {d:<5} {s_['model'] or '?'}" + (f"  SN {s_['serial']}" if s_["serial"] != d else "")
                 + f"  {'HDD' if s_['rot'] else 'SSD'}{' USB' if s_['usb'] else ''}"]
        if s_["used"] is not None:
            rem = []
            if s_["remaining_days"] is not None:
                rem.append(f"aktuell {fmt_days(s_['remaining_days'])}")
            if s_["remaining_lifetime_days"] is not None:
                rem.append(f"Ø {fmt_days(s_['remaining_lifetime_days'])}")
            parts.append(f"Verschleiß {s_['used']} %" + (f" (Rest {', '.join(rem)})" if rem else ""))
        if s_.get("waf_24h") is not None:
            parts.append(f"WAF {de(s_['waf_24h'])} in {s_.get('window_h')} h (Host {de(s_['host_day'] or 0)} GiB/Tag"
                         + (f", NAND {s_['nand_day']} GiB/Tag" if s_.get("nand_day") else "") + ")")
        elif s_.get("waf_total") is not None:
            parts.append(f"WAF gesamt {de(s_['waf_total'])}")
        if s_["wc_drive"] or s_["sct"] or s_["wc_boot"]:
            parts.append(f"Cache {'an' if s_['wc_drive'] == '1' else 'aus' if s_['wc_drive'] == '0' else '?'}"
                         f"/Start {s_['wc_boot'] or '?'}/SCT {s_['sct'] or '-'}/Kernel {s_['wc_kernel'] or '?'}")
        extra = [f"{k} {v}" for k, v in (("Temp", s_["temp"]), ("POH", s_["poh"]), ("Realloc", s_["realloc"]),
                                         ("CRC", s_["crc"])) if v is not None]
        if extra:
            parts.append("  ".join(extra))
        L.append("  ".join(parts))
        l5 = st["last5min"].get(d)
        if l5 and (l5["f_rate"] or l5["w_await"] or l5["max"]):
            L.append(f"        letzte 5 min: Flush Ø {de(l5['f_await'] or 0, 2)} ms bei {de(l5['f_rate'] or 0)}/s, "
                     f"Write Ø {de(l5['w_await'] or 0, 2)} ms, max. Wartezeit {ms_txt(l5['max'])}, "
                     f"Auslastung {de(l5['util'] or 0, 0)} %")
    for d, i in st["devices"].items():
        if not any(x["dev"] == d for x in st["smart"]):
            L.append(f"  {d:<5} {i['model'] or '?'}  {'HDD' if i['rot'] else 'SSD'}  (noch keine SMART-Daten)")

    L += ["", "FSYNC-AUFRUFER (letzte 24 h)"]
    L += [f"  {x['name']:<36} {de(x['per_s'], 2):>6}/s  Ø {ms_txt(x['avg_ms']):>7}  max {ms_txt(x['max_ms'])}"
          for x in fs["fsync"][:15]] or ["  keine Daten"]
    L += ["", "SCHREIBER NETTO (letzte 24 h, Ø MB/s): " + (", ".join(f"{n} {de(v, 3)}" for n, v in fs["writers"]) or "-")]
    p1 = con.execute("SELECT AVG(psi_io_full), AVG(psi_io_some), AVG(psi_cpu), AVG(cpu) FROM sys WHERE res = 60 AND ts > ?",
                     (now - 3600,)).fetchone()
    p24 = con.execute("SELECT AVG(psi_io_full), AVG(psi_io_some), AVG(psi_cpu), AVG(cpu) FROM sys WHERE res = 60 AND ts > ?",
                      (now - 86400,)).fetchone()
    for lbl, p in (("1 h", p1), ("24 h", p24)):
        if p[0] is not None:
            L.append(f"DRUCK {lbl}: IO komplett {de(p[0])} %, IO teilweise {de(p[1])} %, CPU-Wartezeit {de(p[2])} %, "
                     f"CPU {de(p[3], 0)} %")
    tr = st["trim"]
    if tr:
        L.append("TRIM: " + ("Timer aus" if tr.get("enabled") is False else
                             f"Zeitplan {tr.get('schedule') or '?'}; " + "; ".join(
                                 f"{m['mount']}: letzter Lauf {ts(m['last']) if m.get('last') else '?'}"
                                 + (f", {de(m['deleted_gib_day'])} GiB/Tag gelöscht, bis {de(m['untrimmed_pct'])} % ungetrimmt"
                                    if "deleted_gib_day" in m else "") for m in tr.get("mounts", []))))
    runs = con.execute("SELECT COUNT(*), AVG(end - start) FROM smart_runs WHERE start > ?", (now - 86400,)).fetchone()
    if runs[0]:
        L.append(f"SMART-Abfragen (24 h): {runs[0]}, Ø {de(runs[1] or 0)} s")
    return "\n".join(L) + "\n"


# ---------------------------------------------------------------------------
# CheckMK: fertige Local-Check-Zeilen. Die Checks in checkmk/ geben diese Ausgabe weiter, wenn der Dienst läuft,
# damit Web-Oberfläche und CheckMK auf derselben Messung beruhen. Leere Antwort = noch keine Daten
# (die Checks messen dann selbst). Service-Namen und Schwellwerte wie in den Checks.
# ---------------------------------------------------------------------------
def checkmk_lines(con, collector, conf, part):
    now = time.time()
    out = []
    if part == "fast":
        rows = con.execute(
            "SELECT dev, SUM(f_await * f_rate) / NULLIF(SUM(f_rate), 0), SUM(w_await * w_iops) / NULLIF(SUM(w_iops), 0), "
            "AVG(f_rate), AVG(w_mbs), AVG(util), MAX(MAX(w_await_max, f_await_max)), SUM(f_rate) * 5, SUM(w_iops) * 5, "
            "MAX(ts) - MIN(ts) + 5 FROM disk WHERE res = 5 AND ts > ? GROUP BY dev", (now - 60,)).fetchall()
        if not rows:
            return ""
        for dev, fa, wa, fr, wmbs, util, mx, nf, nw, span in rows:
            info = collector.devs.get(dev)
            if not info or info["rot"] or info["usb"]:
                continue
            fa, wa = fa or 0.0, wa or 0.0
            st = 0
            if nf >= 10:
                st = 2 if fa >= 50 else 1 if fa >= 10 else 0
            if nw >= 10:
                st = max(st, 2 if wa >= 100 else 1 if wa >= 20 else 0)
            out.append(f'{st} "SSD {dev} Latenz" flush_ms={fa:.2f};10;50|write_await_ms={wa:.2f};20;100|'
                       f'flush_per_s={fr:.1f}|write_mbs={wmbs:.2f}|util={util:.1f};;;0;100|max_wait_ms={mx:.1f} '
                       f'Flush {fa:.2f} ms ({fr:.1f}/s), Write-await {wa:.2f} ms, {wmbs:.2f} MB/s, Auslastung {util:.0f} %, '
                       f'max. Wartezeit {ms_txt(mx)} (Mittel über {span:.0f} s, vom write-latency-diag Dienst)')
        ps = con.execute("SELECT AVG(psi_io_full), AVG(psi_io_some), AVG(psi_cpu) FROM sys WHERE res = 5 AND ts > ?",
                         (now - 60,)).fetchone()
        if ps[0] is not None:
            st = 2 if ps[0] >= 25 else 1 if ps[0] >= 10 else 0
            out.append(f'{st} "IO-Druck" psi_io_full={ps[0]:.2f};10;25|psi_io_some={ps[1]:.2f} Prozesse komplett durch IO '
                       f'blockiert: {de(ps[0])} %, teilweise: {de(ps[1])} % (letzte 60 s)')
            st = 2 if ps[2] >= 40 else 1 if ps[2] >= 20 else 0
            out.append(f'{st} "CPU-Druck" psi_cpu_some={ps[2]:.2f};20;40 Prozesse warten auf CPU-Zeit: {de(ps[2])} % (letzte 60 s)')
        wr, n = defaultdict(float), 0
        for (w,) in con.execute("SELECT writers FROM sys WHERE res = 5 AND ts > ?", (now - 60,)):
            n += 1
            for k, v in json.loads(w or "[]"):
                wr[k] += v
        top3 = sorted(((k, v / max(n, 1)) for k, v in wr.items()), key=lambda kv: -kv[1])
        txt = ", ".join(f"{k} {v:.2f} MB/s" for k, v in top3[:3] if v >= 0.01) or "kaum Schreibzugriffe"
        out.append(f'0 "Top-Schreiber" write_total_mbs={sum(v for _, v in top3):.2f} {txt}')
        w = felt(con, "1h", float(conf["felt_ms"]))
        h = w["windows"]["1h"]
        st = 2 if h["longest"] >= 5 or h["app_max"] >= 5 else 1 if h["n"] or h["app_n"] else 0
        txt = (f"letzte Stunde: {h['n']}× spürbar (ab {secs_txt(w['felt_ms'] / 1000)} Wartezeit oder 2 s Dauer), "
               f"zusammen {secs_txt(h['secs'])}, längster {secs_txt(h['longest'])}")
        if h["app_max"]:
            txt += f"; Anwendung wartete max. {secs_txt(h['app_max'])}" + (f" ({h['app_who']})" if h["app_who"] else "")
        if w.get("last"):
            la = w["last"]
            txt += f"; zuletzt {time.strftime('%d.%m. %H:%M', time.localtime(la['start']))} {la['dev']} {secs_txt(la['dur'])}"
        out.append(f'{st} "SSD Hänger" felt_stalls_1h={h["n"]}|felt_secs_1h={h["secs"]}|longest_stall_s={h["longest"]}|'
                   f'longest_wait_s={h["app_max"]} {txt}')
    elif part == "smart":
        smart = [x for x in smart_view(con) if not x["rot"] and not x["usb"]]
        if not smart:
            return ""
        for x in smart:
            d = x["dev"]
            if d.startswith("sd") and (x["wc_drive"] or x["sct"] or x["wc_boot"]):
                st = 0
                txt = f"Laufwerk {'an' if x['wc_drive'] == '1' else 'aus' if x['wc_drive'] == '0' else '?'}"
                if x["wc_boot"]:
                    txt += f", beim Start {'an' if x['wc_boot'] == 'enabled' else 'aus'}"
                if x["sct"]:
                    txt += f", SCT: {x['sct']}"
                if x["wc_drive"] == "1" and x["wc_kernel"] == "write through":
                    st = 2
                    txt += f" - Kernel hält den Cache für aus und schickt keine Flushes: echo 1 > /sys/block/{d}/device/rescan"
                elif x["wc_drive"] == "0" or (x["sct"] and "force disabled" in x["sct"].lower()):
                    st = 1
                    txt += " - Cache aus" + (f". Dauerhaft einschalten: smartctl -s wcache-sct,on,p /dev/{d}" if x["sct"] else "")
                elif x["wc_boot"] == "disabled" and not (x["sct"] and "force enabled" in x["sct"].lower()):
                    txt += " - beim Start aus" + (f"; dauerhaft: smartctl -s wcache-sct,on,p /dev/{d}" if x["sct"] else "")
                out.append(f'{st} "SSD {d} Schreibcache" write_cache={1 if x["wc_drive"] == "1" else 0};;;0;1 {txt}')
            if x.get("waf_24h") is not None:
                waf = x["waf_24h"]
                st = 2 if waf >= 10 else 1 if waf >= 5 else 0
                perf = f"waf={waf:.2f};5;10|host_gib_day={x['host_day'] or 0}"
                txt = f"WAF {de(waf)} in den letzten {x.get('window_h')} h, Host {de(x['host_day'] or 0)} GiB/Tag"
                if x.get("nand_day"):
                    perf += f"|nand_gib_day={x['nand_day']}"
                    txt += f", NAND {x['nand_day']} GiB/Tag"
                out.append(f'{st} "SSD {d} Schreibverstärkung" {perf} {txt} (gesamte Laufzeit: WAF {de(x["waf_total"])})')
            elif x.get("waf_total") is not None:
                out.append(f'0 "SSD {d} Schreibverstärkung" - Noch kein Vergleichspunkt (ab 1 h Verlauf), '
                           f'gesamte Laufzeit: WAF {de(x["waf_total"])}')
            if x["used"] is not None:
                rem = x["remaining_days"] if x["remaining_days"] is not None else x["remaining_lifetime_days"]
                st = 2 if rem is not None and rem < 365 else 1 if rem is not None and rem < 730 else 0
                perf = f"wear_used={x['used']};;;0;100" + (f"|remaining_days={rem}" if rem is not None else "")
                txt = f"Verschleiß {x['used']} %"
                if x["remaining_days"] is not None:
                    txt += f", Restlaufzeit bei aktuellem Tempo {fmt_days(x['remaining_days'])}"
                if x["remaining_lifetime_days"] is not None:
                    txt += f", bei bisherigem Durchschnitt {fmt_days(x['remaining_lifetime_days'])}"
                out.append(f'{st} "SSD {d} Verschleiß" {perf} {txt}')
        tr = json.loads((con.execute("SELECT v FROM kv WHERE k = 'trim'").fetchone() or ["{}"])[0])
        if tr.get("enabled") is False:
            out.append('1 "SSD TRIM" - fstrim.timer ist nicht aktiv: systemctl enable --now fstrim.timer')
        for m in tr.get("mounts", []):
            p = tr.get("period", 7)
            st, txt = 0, ""
            if m.get("last"):
                age = (now - m["last"]) / 86400
                txt = f"letzter Lauf vor {de(age)} Tagen (Zeitplan {tr.get('schedule') or '?'})"
                if age > p + 1:
                    st, txt = 1, txt + " - überfällig"
            else:
                st, txt = 1, "noch kein fstrim-Lauf im Journal"
            perf = f"trim_age_days={((now - m['last']) / 86400) if m.get('last') else 0:.1f};{p + 1}"
            if "deleted_gib_day" in m:
                perf += f"|deleted_gib_day={m['deleted_gib_day']}|untrimmed_pct={m['untrimmed_pct']};2"
                txt += (f", Ø {de(m['deleted_gib_day'])} GiB/Tag gelöscht, bis zum nächsten Lauf bis zu "
                        f"{de(m['untrimmed_pct'])} % ungetrimmt")
                if p > 1 and m["untrimmed_pct"] >= 2:
                    st = max(st, 1)
                    txt += " - täglich trimmen: systemctl edit fstrim.timer, [Timer] OnCalendar= und OnCalendar=daily"
            out.append(f'{st} "SSD TRIM {m["mount"]}" {perf} {txt}')
    return "\n".join(out) + ("\n" if out else "")


# ---------------------------------------------------------------------------
# Web-Oberfläche
# ---------------------------------------------------------------------------
class Handler(BaseHTTPRequestHandler):
    server_version = f"write-latency-diag/{VERSION}"

    def log_message(self, fmt, *args):
        pass

    def send(self, code, body, ctype):
        data = body.encode() if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        u = urlparse(self.path)
        q = {k: v[0] for k, v in parse_qs(u.query).items()}
        srv = self.server
        if u.path == "/":
            self.send(200, PAGE, "text/html; charset=utf-8")
            return
        try:
            con = sqlite3.connect(f"file:{srv.conf['db']}?mode=ro", uri=True, timeout=10)
            try:
                if u.path == "/api/status":
                    data = build_status(con, srv.collector, srv.conf)
                elif u.path == "/api/series":
                    data = series(con, q.get("range", "6h"))
                elif u.path == "/api/events":
                    data = events(con, q.get("range", "7d"), float(q.get("min_ms", "0")))
                elif u.path == "/api/fsync":
                    data = fsync_stats(con, q.get("range", "24h"))
                elif u.path == "/api/felt":
                    data = felt(con, q.get("range", "7d"), float(srv.conf["felt_ms"]))
                elif u.path == "/api/smart":
                    data = smart_history(con)
                elif u.path == "/api/checkmk":
                    self.send(200, checkmk_lines(con, srv.collector, srv.conf, q.get("part", "fast")),
                              "text/plain; charset=utf-8")
                    return
                elif u.path == "/api/report":
                    self.send(200, report(con, srv.collector, srv.conf), "text/plain; charset=utf-8")
                    return
                else:
                    self.send(404, "nicht gefunden", "text/plain; charset=utf-8")
                    return
            finally:
                con.close()
            self.send(200, json.dumps(data), "application/json")
        except (sqlite3.Error, ValueError) as e:
            self.send(500, json.dumps({"error": str(e)}), "application/json")
        except (BrokenPipeError, ConnectionResetError):
            pass


# ---------------------------------------------------------------------------
# Selbst-Update (täglich): neue Version prüfen, ersetzen, beenden - systemd startet neu
# ---------------------------------------------------------------------------
def self_update(conf):
    url = f"{conf['update_url']}/service/wlat-service.py"
    try:
        with urllib.request.urlopen(url, timeout=30) as r:
            new = r.read()
        compile(new, "wlat-service.py", "exec")
    except Exception as e:   # noqa: BLE001 - Netz/Syntax: einfach beim nächsten Mal wieder versuchen
        INFO["update"] = f"Update-Prüfung fehlgeschlagen: {str(e)[:120]}"
        return False
    me = os.path.realpath(__file__)
    with open(me, "rb") as f:
        if f.read() == new:
            INFO["update"] = f"aktuell (geprüft {time.strftime('%d.%m. %H:%M')})"
            return False
    if os.path.exists(os.path.join(os.path.dirname(me), ".git")):
        return False
    tmp = me + ".new"
    with open(tmp, "wb") as f:
        f.write(new)
    os.chmod(tmp, 0o755)
    os.replace(tmp, me)
    log("Neue Version installiert, starte neu")
    return True


def main():
    conf = load_conf()
    store = Store(conf["db"])
    tracer = FsyncTracer(store) if conf["bpftrace"] == "1" else None
    collector = Collector(conf, store, tracer)
    if tracer:
        tracer.start()
    collector.start()
    threading.Thread(target=lambda: (STOP.wait(15), smart_sample(store, conf)), daemon=True).start()

    srv = ThreadingHTTPServer((conf["bind"], int(conf["port"])), Handler)
    srv.daemon_threads = True
    srv.conf, srv.collector = conf, collector
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    log(f"write-latency-diag Dienst {VERSION} läuft: http://{conf['bind']}:{conf['port']}/  "
        f"Datenbank {conf['db']}, Geräte {', '.join(collector.devs)}")

    def handle(sig, frame):
        STOP.set()
    signal.signal(signal.SIGTERM, handle)
    signal.signal(signal.SIGINT, handle)

    next_smart = time.time() + int(conf["smart_interval"])
    next_clean = time.time() + 3600
    next_update = time.time() + 600
    while not STOP.is_set():
        STOP.wait(10)
        now = time.time()
        if now >= next_smart:
            next_smart = now + int(conf["smart_interval"])
            threading.Thread(target=smart_sample, args=(store, conf), daemon=True).start()
        if now >= next_clean:
            next_clean = now + 3600
            store.cleanup(conf)
        if conf["auto_update"] == "1" and now >= next_update:
            next_update = now + 86400
            if self_update(conf):
                RESTART.set()
                STOP.set()
    srv.shutdown()
    if tracer:
        tracer.stop()
    store.flush()
    log("beendet")
    sys.exit(0)


PAGE = r"""<!doctype html>
<html lang="de"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Schreiblatenz</title>
<style>
:root{--bg:#f6f7f9;--card:#fff;--fg:#1d2330;--mut:#667085;--line:#e3e6eb;--ok:#1a7f4b;--warn:#b26b00;--crit:#c2272d;--info:#2f6fbf;--grid:#eceef2}
@media (prefers-color-scheme:dark){:root{--bg:#14171c;--card:#1d2128;--fg:#e6e8ec;--mut:#98a1b0;--line:#2c323b;--ok:#3fbf7f;--warn:#e0a030;--crit:#ef5b5b;--info:#6aa6ef;--grid:#262b33}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);font:14px/1.45 system-ui,-apple-system,Segoe UI,Roboto,sans-serif}
header{display:flex;flex-wrap:wrap;gap:8px 16px;align-items:baseline;padding:14px 16px;border-bottom:1px solid var(--line);background:var(--card)}
h1{font-size:18px;margin:0}h2{font-size:15px;margin:22px 0 8px}main{max-width:1280px;margin:0 auto;padding:0 16px 40px}
.mut{color:var(--mut)}.small{font-size:12px}.grid{display:grid;gap:12px;grid-template-columns:repeat(auto-fill,minmax(min(260px,100%),1fr))}
.grid.wide{grid-template-columns:repeat(auto-fill,minmax(min(560px,100%),1fr))}.grid.mid{grid-template-columns:repeat(auto-fill,minmax(min(420px,100%),1fr))}
.card{background:var(--card);border:1px solid var(--line);border-radius:8px;padding:12px}
.card h3{margin:0 0 6px;font-size:14px;display:flex;justify-content:space-between;gap:8px}
.kv{display:grid;grid-template-columns:auto 1fr;gap:2px 10px;font-size:13px}.kv span:nth-child(odd){color:var(--mut)}
.f{padding:8px 10px;border-radius:6px;margin:6px 0;border-left:4px solid}.f.ok{border-color:var(--ok)}.f.warn{border-color:var(--warn)}
.f.crit{border-color:var(--crit)}.f.info{border-color:var(--info)}.f{background:var(--card)}
.dot{display:inline-block;width:9px;height:9px;border-radius:50%;margin-right:6px}.b-ok{background:var(--ok)}.b-warn{background:var(--warn)}.b-crit{background:var(--crit)}.b-mut{background:var(--mut)}
.ranges button{border:1px solid var(--line);background:var(--card);color:var(--fg);padding:4px 10px;border-radius:6px;cursor:pointer;margin-right:4px}
.ranges button.on{background:var(--fg);color:var(--bg)}
.chart{position:relative;height:220px}.chart canvas{width:100%;height:100%;display:block}
.tip{position:absolute;pointer-events:none;background:var(--card);border:1px solid var(--line);border-radius:6px;padding:6px 8px;font-size:12px;display:none;white-space:nowrap;z-index:2;box-shadow:0 2px 8px rgba(0,0,0,.15)}
.big{font-size:28px;font-weight:650;line-height:1.1;font-variant-numeric:tabular-nums}.big small{font-size:14px;font-weight:500;color:var(--mut)}
.legend{font-size:12px;margin-top:4px}.legend span{margin-right:12px;white-space:nowrap}
table{width:100%;border-collapse:collapse;font-size:13px}th,td{text-align:left;padding:5px 8px;border-bottom:1px solid var(--line);vertical-align:top}
th{color:var(--mut);font-weight:600}td.num{text-align:right;font-variant-numeric:tabular-nums}.scroll{overflow-x:auto}
.btn{border:1px solid var(--line);background:var(--card);color:var(--fg);padding:5px 12px;border-radius:6px;cursor:pointer}
.tag{font-size:11px;padding:1px 6px;border-radius:9px;border:1px solid var(--line);color:var(--mut);white-space:nowrap}
select{background:var(--card);color:var(--fg);border:1px solid var(--line);border-radius:6px;padding:3px 6px}
</style></head><body>
<header><h1>Schreiblatenz <span id="host" class="mut"></span></h1><span id="meta" class="mut small"></span></header>
<main>
<h2>Befund</h2><div id="findings"></div>
<h2>Spürbare Hänger <span class="mut small" id="feltdef"></span></h2>
<div class="grid" id="felttiles"></div><div id="feltlast" class="small" style="margin:8px 0"></div>
<div class="card"><h3>Spürbare Sekunden pro Stunde</h3><div class="chart" style="height:160px"><canvas id="feltchart"></canvas><div class="tip"></div></div>
<div class="legend"><span><span class="dot" style="background:#c2272d"></span>Summe der Hänger (s)</span><span><span class="dot" style="background:#2f6fbf"></span>längste Wartezeit einer Anwendung (s)</span></div>
<h3 style="margin-top:14px">Einzeln <span class="mut small" id="feltcount"></span></h3><div class="scroll" style="max-height:420px;overflow-y:auto"><table id="felttab"></table></div></div>
<h2>Laufwerke</h2><div id="cards" class="grid"></div>
<div style="display:flex;align-items:center;justify-content:space-between;flex-wrap:wrap;gap:8px;margin-top:22px">
<h2 style="margin:0">Verlauf</h2><div class="ranges" id="ranges"></div></div>
<div class="grid wide" style="margin-top:8px" id="charts"></div>
<h2>Hänger <select id="evmin"><option value="0">alle</option><option value="200">≥ 200 ms</option><option value="500" selected>≥ 500 ms</option><option value="1000">≥ 1 s</option></select></h2>
<div class="card"><div class="chart" style="height:120px"><canvas id="evchart"></canvas><div class="tip"></div></div>
<div class="scroll"><table id="evtab"></table></div></div>
<h2>fsync-Aufrufer und Schreiber <span class="mut small" id="fsspan"></span></h2>
<div class="grid mid"><div class="card scroll"><table id="fstab"></table></div><div class="card scroll"><table id="wrtab"></table></div></div>
<h2>Schreibverstärkung pro Tag</h2><div class="card"><div class="chart" style="height:180px"><canvas id="wafchart"></canvas><div class="tip"></div></div><div class="legend" id="waflegend"></div></div>
<h2>Rohdaten zum Kopieren</h2>
<div class="card"><div style="display:flex;gap:8px;align-items:center;margin-bottom:8px"><button id="rawcopy" class="btn">Kopieren</button><button id="rawload" class="btn">Neu laden</button><span id="rawmsg" class="mut small"></span>
<span class="mut small" style="margin-left:auto">auch abrufbar unter <code>/api/report</code></span></div>
<textarea id="raw" readonly spellcheck="false" style="width:100%;height:360px;font:12px/1.4 ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;background:var(--bg);color:var(--fg);border:1px solid var(--line);border-radius:6px;padding:8px;white-space:pre;overflow:auto"></textarea></div>
</main>
<script>
const COLORS=['#2f6fbf','#d1497b','#1a9a8a','#c88a12','#7b5cc4','#5d8f2e','#c4552f'];
let RANGE=localStorageGet('range')||'6h';
function localStorageGet(k){try{return localStorage.getItem(k)}catch(e){return null}}
function localStorageSet(k,v){try{localStorage.setItem(k,v)}catch(e){}}
const $=s=>document.querySelector(s);
function el(tag,attrs,...kids){const e=document.createElement(tag);for(const[k,v]of Object.entries(attrs||{})){if(k==='class')e.className=v;else if(k==='style')e.style.cssText=v;else e.setAttribute(k,v)}for(const c of kids){if(c==null)continue;e.append(c.nodeType?c:document.createTextNode(String(c)))}return e}
const fmtT=t=>new Date(t*1000).toLocaleString('de-DE',{day:'2-digit',month:'2-digit',hour:'2-digit',minute:'2-digit',second:'2-digit'});
const fmtD=d=>d>=730?'~'+(d/365).toFixed(1)+' Jahre':d>=60?'~'+Math.round(d/30.4)+' Monate':'~'+Math.round(d)+' Tage';
const ms=v=>v==null?'–':v>=1000?(v/1000).toFixed(1).replace('.',',')+' s':v.toFixed(v<10?1:0).replace('.',',')+' ms';
const mbs=l=>l.filter(w=>w[1]>=0.01).map(w=>w[0]+' '+w[1].toFixed(2).replace('.',',')).join(', ')||'–';
async function J(u){const r=await fetch(u);return r.json()}

function chart(canvas,series,opt){
  opt=opt||{};const box=canvas.parentElement,tip=box.querySelector('.tip');
  const dpr=window.devicePixelRatio||1,W=box.clientWidth,H=box.clientHeight;canvas.width=W*dpr;canvas.height=H*dpr;
  const c=canvas.getContext('2d');c.scale(dpr,dpr);const cs=getComputedStyle(document.documentElement);
  const fg=cs.getPropertyValue('--mut'),grid=cs.getPropertyValue('--grid');
  const L=48,R=10,T=8,B=22,pw=W-L-R,ph=H-T-B;let x0=opt.x0,x1=opt.x1,ymax=0;
  for(const s of series)for(let i=0;i<s.t.length;i++){if(x0==null||s.t[i]<x0)x0=s.t[i];if(x1==null||s.t[i]>x1)x1=s.t[i];if(s.v[i]>ymax)ymax=s.v[i]}
  if(opt.ymin!=null)ymax=Math.max(ymax,opt.ymin);if(!ymax)ymax=1;if(x0==null||!series.some(s=>s.t.length)){c.fillStyle=fg;c.font='12px system-ui';c.fillText(opt.empty||'noch keine Daten',L+8,T+20);return}
  if(x1<=x0)x1=x0+1;const log=opt.log&&ymax>10;
  const yv=v=>log?Math.log10(Math.max(v,1))/Math.log10(ymax*1.1):v/(ymax*1.08);
  const X=t=>L+(t-x0)/(x1-x0)*pw,Y=v=>T+ph-yv(v)*ph;
  c.strokeStyle=grid;c.fillStyle=fg;c.font='11px system-ui';c.lineWidth=1;
  const ticks=log?[1,10,100,1000,10000,100000].filter(v=>v<=ymax*1.1):[0,.25,.5,.75,1].map(f=>f*ymax*1.08);
  for(const v of ticks){const y=Math.round(Y(v))+.5;c.beginPath();c.moveTo(L,y);c.lineTo(W-R,y);c.stroke();c.fillText(opt.fmt?opt.fmt(v):(+v.toPrecision(3)).toString(),4,y+4)}
  const span=x1-x0,nt=Math.max(2,Math.floor(pw/110));let lastR=-1e9;for(let i=0;i<=nt;i++){const t=x0+span*i/nt,d=new Date(t*1000);
    const s=span>1296000?d.toLocaleDateString('de-DE',{day:'2-digit',month:'2-digit'}):span>172800?d.toLocaleDateString('de-DE',{day:'2-digit',month:'2-digit'})+' '+d.toLocaleTimeString('de-DE',{hour:'2-digit'}):d.toLocaleTimeString('de-DE',{hour:'2-digit',minute:'2-digit'});const lw=c.measureText(s).width,lx=Math.max(L-10,Math.min(X(t)-lw/2,W-R-lw));if(lx<lastR+8)continue;c.fillText(s,lx,H-6);lastR=lx+lw}
  series.forEach((s,k)=>{c.strokeStyle=s.color||COLORS[k%COLORS.length];c.lineWidth=1.4;
    if(s.bars){c.fillStyle=c.strokeStyle;const bw=Math.max(2,(s.bars/(x1-x0))*pw-1);for(let i=0;i<s.t.length;i++){if(!s.v[i])continue;const y=Y(s.v[i]);c.fillRect(X(s.t[i]),y,bw,T+ph-y)}return}
    c.beginPath();let pen=false,gap=opt.gap||Infinity;
    for(let i=0;i<s.t.length;i++){const x=X(s.t[i]),y=Y(s.v[i]);if(!pen||s.t[i]-s.t[i-1]>gap){c.moveTo(x,y);pen=true}else c.lineTo(x,y)}c.stroke();
    if(opt.dots){c.fillStyle=c.strokeStyle;for(let i=0;i<s.t.length;i++){c.beginPath();c.arc(X(s.t[i]),Y(s.v[i]),2.5,0,7);c.fill()}}});
  if(opt.thresholds)for(const th of opt.thresholds){if(th.v>ymax*1.1)continue;c.strokeStyle=th.color;c.setLineDash([4,4]);c.beginPath();c.moveTo(L,Y(th.v)+.5);c.lineTo(W-R,Y(th.v)+.5);c.stroke();c.setLineDash([])}
  canvas.onmousemove=e=>{const r=canvas.getBoundingClientRect(),mx=e.clientX-r.left;if(mx<L){tip.style.display='none';return}
    const t=x0+(mx-L)/pw*(x1-x0);tip.replaceChildren(el('div',{class:'mut'},fmtT(t)));
    series.forEach((s,k)=>{let bi=-1,bd=Infinity;for(let i=0;i<s.t.length;i++){const d=Math.abs(s.t[i]-t);if(d<bd){bd=d;bi=i}}
      if(bi>=0&&bd<(x1-x0)/40)tip.append(el('div',{},el('span',{class:'dot',style:'background:'+(s.color||COLORS[k%COLORS.length])}),s.name+': '+(opt.fmt?opt.fmt(s.v[bi]):s.v[bi])))});
    tip.style.display='block';tip.style.left=Math.min(mx+12,W-tip.offsetWidth-4)+'px';tip.style.top='8px'};
  canvas.onmouseleave=()=>tip.style.display='none';
}

function finding(f){const lbl={ok:'OK',warn:'Prüfen',crit:'Kritisch',info:'Hinweis'}[f.level];return el('div',{class:'f '+f.level},el('b',{},lbl+': '),f.text)}

function card(s,st){
  const lv=(st.live.disk||{})[s.dev]||{},l5=st.last5min[s.dev]||{};const kv=el('div',{class:'kv'});
  const add=(k,v)=>{kv.append(el('span',{},k),el('span',{},v))};
  let lvl='ok';
  if(!s.rot){
    if(s.waf_24h!=null){add('WAF (letzte '+s.window_h+' h)',s.waf_24h+(s.host_day!=null?' · Host '+s.host_day+' GiB/Tag':''));if(s.waf_24h>=10)lvl='crit';else if(s.waf_24h>=5&&lvl==='ok')lvl='warn'}
    else if(s.waf_total!=null)add('WAF (gesamt)',s.waf_total+' – 24-h-Wert folgt');
    if(s.used!=null){let r=s.remaining_days!=null?'aktuell '+fmtD(s.remaining_days):'';if(s.remaining_lifetime_days!=null)r+=(r?', ':'')+'Ø '+fmtD(s.remaining_lifetime_days);add('Verschleiß',s.used+' %'+(r?' · Rest '+r:''))}
    if(s.wc_drive||s.wc_boot||s.sct)add('Schreibcache',(s.wc_drive==='1'?'an':s.wc_drive==='0'?'aus':'?')+(s.wc_boot?', beim Start '+(s.wc_boot==='enabled'?'an':'aus'):'')+(s.sct?' · SCT: '+s.sct:''));
  } else add('Typ','HDD'+(s.usb?' (USB)':''));
  if(l5.f_await!=null){add('Flush Ø (5 min)',ms(l5.f_await)+' · '+l5.f_rate.toFixed(1)+'/s');add('max. Wartezeit (5 min)',ms(l5.max));
    if(!s.rot&&l5.max>=1000)lvl='crit';else if(!s.rot&&l5.max>=200&&lvl==='ok')lvl='warn'}
  if(lv.w_mbs!=null)add('Schreiben',lv.w_mbs.toFixed(2)+' MB/s · Auslastung '+Math.round(lv.util)+' %');
  if(s.temp!=null)add('Temperatur',s.temp+' °C'+(s.poh?' · '+s.poh+' h':''));
  return el('div',{class:'card'},el('h3',{},el('span',{},el('span',{class:'dot b-'+(s.rot?'mut':lvl)}),s.dev+' '),el('span',{class:'mut small'},s.model)),el('div',{class:'mut small',style:'margin-bottom:6px'},s.serial),kv);
}

async function loadStatus(){
  const st=await J('api/status');$('#host').textContent=st.host;
  $('#meta').textContent='Version '+st.version+' · läuft seit '+fmtT(st.started)+' · bpftrace: '+st.bpftrace+(st.update?' · Update: '+st.update:'')+' · Stand '+fmtT(st.now);
  $('#findings').replaceChildren(...st.findings.map(finding));
  const smart=st.smart.length?st.smart:Object.entries(st.devices).map(([d,i])=>({dev:d,model:i.model,rot:i.rot,usb:i.usb,serial:''}));
  $('#cards').replaceChildren(...smart.map(s=>card(s,st)));
}

function chartCard(id,title,legend){return el('div',{class:'card'},el('h3',{},title),el('div',{class:'chart'},el('canvas',{id}),el('div',{class:'tip'})),el('div',{class:'legend',id:id+'l'},...(legend||[])))}
function legend(names){return names.map((n,k)=>el('span',{},el('span',{class:'dot',style:'background:'+COLORS[k%COLORS.length]}),n))}

async function loadCharts(){
  const s=await J('api/series?range='+RANGE),devs=Object.keys(s.disk).sort(),gap=s.bucket*3;
  const box=$('#charts');box.replaceChildren(chartCard('c1','Max. Wartezeit je Gerät (ms, logarithmisch)'),chartCard('c2','Flushes pro Sekunde'),chartCard('c3','Schreiben (MB/s)'),chartCard('c4','Druck (PSI) und CPU (%)'));
  const mk=k=>devs.map((d,i)=>({name:d,color:COLORS[i%COLORS.length],t:s.disk[d].t,v:s.disk[d][k]}));
  const o={x0:s.since,x1:s.now,gap};
  chart($('#c1'),mk('lat_max'),{...o,log:true,fmt:ms,ymin:10,thresholds:[{v:200,color:'#b26b00'},{v:1000,color:'#c2272d'}]});$('#c1l').replaceChildren(...legend(devs));
  chart($('#c2'),mk('f_rate'),o);$('#c2l').replaceChildren(...legend(devs));
  chart($('#c3'),mk('w_mbs'),o);$('#c3l').replaceChildren(...legend(devs));
  const sy=s.sys,ss=[['IO komplett blockiert','psi_io_full'],['IO teilweise','psi_io_some'],['CPU-Wartezeit','psi_cpu'],['CPU-Auslastung','cpu']].map(([n,k],i)=>({name:n,color:COLORS[i],t:sy.t||[],v:sy[k]||[]}));
  chart($('#c4'),ss,{...o,ymin:5});$('#c4l').replaceChildren(...legend(ss.map(x=>x.name)));
}

const sec=v=>v>=100?Math.round(v)+' s':v>=10?v.toFixed(0)+' s':v.toFixed(1).replace('.',',')+' s';
async function loadFelt(){
  const rng=['1h','6h','24h'].includes(RANGE)?'7d':RANGE,f=await J('api/felt?range='+rng);
  $('#feltdef').textContent='(ab '+sec(f.felt_ms/1000)+' Wartezeit oder 2 s Dauer)';
  const lbl={'1h':'Letzte Stunde','24h':'Letzte 24 Stunden','7d':'Letzte 7 Tage'};
  $('#felttiles').replaceChildren(...Object.entries(f.windows).map(([k,w])=>{
    const lv=w.n===0&&w.app_n===0?'ok':(w.longest>=5||w.app_max>=5)?'crit':'warn';
    return el('div',{class:'card'},el('h3',{},el('span',{},el('span',{class:'dot b-'+lv}),lbl[k])),
      el('div',{class:'big'},w.n+'× ',el('small',{},'zusammen '+sec(w.secs))),
      el('div',{class:'kv',style:'margin-top:6px'},el('span',{},'längster Hänger'),el('span',{},w.n?sec(w.longest):'–'),
        el('span',{},'Anwendung wartete'),el('span',{},w.app_n?w.app_n+'× ≥ '+sec(f.felt_ms/1000)+', zusammen '+sec(w.app_secs):'nie ≥ '+sec(f.felt_ms/1000)),
        el('span',{},'längste Wartezeit'),el('span',{},w.app_max?sec(w.app_max)+(w.app_who?' ('+w.app_who+')':''):'–')))}));
  const l=f.last;$('#feltlast').replaceChildren(l?el('span',{},el('b',{},'Zuletzt: '),fmtT(l.start)+' – '+sec(l.dur)+' auf '+l.dev+
    (l.waiters.length?', es warteten: '+l.waiters.slice(0,3).map(w=>w[0]+' '+sec(w[1]/1000)).join(', '):'')):el('span',{class:'mut'},'Noch kein spürbarer Hänger aufgezeichnet.'));
  const h=f.hours;chart($('#feltchart'),[{name:'Hänger',color:'#c2272d',bars:3600,t:h.map(x=>x.t),v:h.map(x=>x.secs)},{name:'längste Wartezeit',color:'#2f6fbf',t:h.filter(x=>x.app_max).map(x=>x.t),v:h.filter(x=>x.app_max).map(x=>x.app_max)}],
    {dots:true,ymin:1,x0:f.since,x1:f.now,gap:3600,fmt:v=>sec(+v),empty:'keine spürbaren Hänger'});
  $('#feltcount').textContent='('+f.list.length+(f.list.length>=200?'+':'')+' im Zeitraum, neueste zuerst)';
  const t=$('#felttab');t.replaceChildren(el('tr',{},...['Zeit','Gerät','Dauer','max. Wartezeit','Wer wartete (fsync)','Wer schrieb (MB/s)',''].map(h=>el('th',{},h))));
  if(!f.list.length)t.append(el('tr',{},el('td',{colspan:7,class:'mut'},'Keine spürbaren Hänger in diesem Zeitraum.')));
  for(const x of f.list)t.append(el('tr',{},el('td',{},fmtT(x.start)),el('td',{},x.dev),el('td',{class:'num'},sec(x.dur)),
    el('td',{class:'num'},ms(Math.max(x.max_w,x.max_f))),el('td',{},x.waiters.map(w=>w[0]+' '+ms(w[1])).join(', ')||'–'),
    el('td',{},mbs(x.writers)),el('td',{},x.smart?el('span',{class:'tag',title:'Zeitgleich mit einer SMART-Abfrage des Dienstes'},'SMART'):'')));
}
async function loadRaw(){const r=await fetch('api/report');$('#raw').value=await r.text();$('#rawmsg').textContent='Stand '+new Date().toLocaleTimeString('de-DE')}
async function copyRaw(){const ta=$('#raw');let ok=false;
  try{if(window.isSecureContext&&navigator.clipboard){await navigator.clipboard.writeText(ta.value);ok=true}}catch(e){}
  if(!ok){ta.focus();ta.select();try{ok=document.execCommand('copy')}catch(e){}ta.setSelectionRange(0,0)}
  $('#rawmsg').textContent=ok?'kopiert':'Kopieren nicht möglich - bitte markieren und manuell kopieren'}
async function loadEvents(){
  const rng=['1h','6h','24h'].includes(RANGE)?'24h':RANGE,e=await J('api/events?range='+rng+'&min_ms='+$('#evmin').value);
  const ph=e.per_hour;chart($('#evchart'),[{name:'Hänger pro Stunde',t:ph.map(x=>x.t),v:ph.map(x=>x.n)}],{dots:true,ymin:1,x0:e.since,x1:e.now,gap:3600,empty:'keine Hänger'});
  const t=$('#evtab');t.replaceChildren(el('tr',{},...['Zeit','Gerät','Dauer','max. Wartezeit','Wer schrieb (MB/s)','Wer wartete (fsync)',''].map(h=>el('th',{},h))));
  if(!e.events.length)t.append(el('tr',{},el('td',{colspan:7,class:'mut'},'Keine Hänger in diesem Zeitraum.')));
  for(const x of e.events)t.append(el('tr',{},el('td',{},fmtT(x.start)),el('td',{},x.dev),el('td',{class:'num'},x.dur.toFixed(0)+' s'),
    el('td',{class:'num'},ms(Math.max(x.max_w,x.max_f))),el('td',{},mbs(x.writers)),
    el('td',{},x.waiters.map(w=>w[0]+' '+ms(w[1])).join(', ')||'–'),el('td',{},x.smart?el('span',{class:'tag',title:'Zeitgleich mit einer SMART-Abfrage des Dienstes'},'SMART'):'')));
}

async function loadFsync(){
  const rng=RANGE==='1h'||RANGE==='6h'?'24h':RANGE,f=await J('api/fsync?range='+rng);$('#fsspan').textContent='(letzte '+rng+')';
  const t=$('#fstab');t.replaceChildren(el('tr',{},...['fsync-Aufrufer','pro s','Ø','max'].map(h=>el('th',{},h))));
  if(!f.fsync.length)t.append(el('tr',{},el('td',{colspan:4,class:'mut'},'Noch keine Daten (bpftrace fasst alle 5 Minuten zusammen).')));
  for(const x of f.fsync)t.append(el('tr',{},el('td',{},x.name),el('td',{class:'num'},x.per_s.toFixed(2)),el('td',{class:'num'},ms(x.avg_ms)),el('td',{class:'num'},ms(x.max_ms))));
  const w=$('#wrtab');w.replaceChildren(el('tr',{},el('th',{},'Schreiber (netto)'),el('th',{},'Ø MB/s')));
  if(!f.writers.length)w.append(el('tr',{},el('td',{colspan:2,class:'mut'},'Noch keine Daten.')));
  for(const[n,v]of f.writers)w.append(el('tr',{},el('td',{},n),el('td',{class:'num'},v.toFixed(3))));
}

async function loadSmart(){
  const h=await J('api/smart'),names=Object.keys(h);
  chart($('#wafchart'),names.map((n,i)=>({name:n,color:COLORS[i%COLORS.length],t:h[n].map(x=>x.t),v:h[n].map(x=>x.waf)})),{dots:true,ymin:5,thresholds:[{v:5,color:'#b26b00'},{v:10,color:'#c2272d'}],empty:'noch keine Daten (ab dem zweiten Tag)'});
  $('#waflegend').replaceChildren(...legend(names));
}

function ranges(){const r=$('#ranges');r.replaceChildren(...['1h','6h','24h','7d','30d','90d'].map(x=>{const b=el('button',{class:x===RANGE?'on':''},x);b.onclick=()=>{RANGE=x;localStorageSet('range',x);ranges();loadCharts();loadFelt();loadEvents();loadFsync()};return b}))}
$('#rawcopy').onclick=copyRaw;$('#rawload').onclick=loadRaw;
async function all(){try{await loadStatus()}catch(e){console.error(e)}try{await loadRaw()}catch(e){console.error(e)}try{await loadFelt()}catch(e){console.error(e)}try{await loadCharts()}catch(e){console.error(e)}try{await loadEvents()}catch(e){console.error(e)}try{await loadFsync()}catch(e){console.error(e)}try{await loadSmart()}catch(e){console.error(e)}}
$('#evmin').onchange=loadEvents;ranges();all();
setInterval(()=>{loadStatus();loadCharts()},15000);setInterval(()=>{loadFelt();loadEvents();loadFsync();loadSmart()},60000);
let rt;window.addEventListener('resize',()=>{clearTimeout(rt);rt=setTimeout(()=>{loadCharts();loadFelt();loadEvents();loadSmart()},200)});
</script></body></html>
"""

if __name__ == "__main__":
    main()
