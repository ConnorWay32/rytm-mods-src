"""Monitor the Rytm through mod 0006's USB telemetry (mod.toml `telem = 1`).

The stub writes one 32-word frame a block on USB channel 11: word k is
(0x5A ^ k) << 24 | data << 8. This records continuously, locks onto the frame
by its tags, decodes every block, and logs a line a second:

    block rate and frames lost, words with a bad tag, stock's display idle
    counter and stage, the interval between interrupts and the stub's longest
    run (DMA timer 0 ticks, and the run as a share of the interval), the
    compressor parameters, DIST, the THR DAC word the interrupt builds, the
    preview page's draw budget, compressor page draws a second, the
    interrupt's stack pointer, the UI event queue's deepest point, the ADC's
    result slots 0 and 1 (12 bits), the share
    of the second the background worker had jobs pending, the share of blocks
    the estimator stood aside (run under 2% of the interval), and MAIN's level.

Alarms, each logged once when it starts and once when it clears:
    frames    no valid frame for a second, blocks skipped, or bad tags
    idle      the idle counter has not moved for 3 s below its 72000 cap
    draws     compressor page draws stopped after running
    timing    an interval over 1.5x the median, or a run over half of one
    backlog   the UI event queue has held more than 16 events for 3 s
On an alarm's first start the last 60 s of MAIN and channel 11 are saved.

    monitor.py [--minutes N]     until Ctrl-C, or N minutes
    monitor.py --check           10 s, then a verdict on bit exactness

Writes build/comp/telemetry/monitor_<time>.log and .csv, and monitor_<time>_<alarm>.wav.
"""
import argparse
import collections
import queue
import time
from datetime import datetime
from pathlib import Path

import numpy as np
import sounddevice as sd
import soundfile as sf

import sys
from pathlib import Path as _Path

sys.path.insert(0, str(_Path(__file__).resolve().parent.parent))   # rig.py, in tools/comp
import rig


ROOT = Path(__file__).resolve().parents[3]
OUT = ROOT / "build" / "comp" / "telemetry"
FS = 48000
BLOCK = 32
TAGS = np.array([0x5A ^ k for k in range(BLOCK)])
PARAMS = ("THR", "ATK", "REL", "RAT", "SEQ", "MUP", "MIX", "VOL")
IDLE_CAP = 20 * 3600
KEEP_S = 60


def decode(ch11):
    """Channel 11 samples -> (tags, data) as int arrays."""
    w = np.round(ch11.astype(np.float64) * 2.0**31).astype(np.int64)
    return (w >> 24) & 0xFF, (w >> 8) & 0xFFFF


def fields(d):
    """One frame's 32 data words -> dict."""
    u32 = lambda i: int(d[i]) | int(d[i + 1]) << 16
    s16 = lambda v: v - 65536 if v >= 32768 else v
    f = {"blk": u32(0), "idle": u32(2), "stage": int(d[4]), "interval": u32(5),
         "run": u32(7), "dist": int(d[17]), "thr_dac": int(d[18]),
         "wet": s16(int(d[19])), "dry": s16(int(d[20])), "seen": s16(int(d[21])),
         "draws": int(d[22]), "sp": u32(23), "queue": int(d[25]),
         "bg_cur": s16(int(d[26])), "bg_node": s16(int(d[27])),
         "adc": [int(d[28 + i]) >> 3 for i in range(4)]}
    for i, p in enumerate(PARAMS):
        f[p] = int(d[9 + i]) >> 8
    return f


class Monitor:
    def __init__(self, stem):
        OUT.mkdir(parents=True, exist_ok=True)
        self.log = OUT / f"{stem}.log"
        self.csv = OUT / f"{stem}.csv"
        self.stem = stem
        self.raw = collections.deque(maxlen=KEEP_S * FS // 4800 + 1)
        self.pending = np.zeros((0, 12), np.float32)
        self.offset = None
        self.alarms = {}
        self.saved = set()
        self.last_idle, self.idle_since = None, time.time()
        self.draws_ran = False
        self.last_draws, self.draws_since = None, time.time()
        self.last_valid = None
        self.prev_blk = None
        self.backlog_since = None
        self.sec = self.fresh()
        self.header = False

    def fresh(self):
        return {"frames": 0, "lost": 0, "badtags": 0, "intervals": [], "runs": [],
                "last": None, "draws0": None, "main": [], "queue": 0, "bg": 0, "aside": 0}

    def say(self, line):
        line = f"{datetime.now().strftime('%H:%M:%S')} {line}"
        print(line, flush=True)
        with open(self.log, "a") as f:
            f.write(line + "\n")

    def alarm(self, name, on, why=""):
        was = self.alarms.get(name, False)
        if on and not was:
            self.say(f"ALARM {name}: {why}")
            if name not in self.saved:
                self.save(name)
                self.saved.add(name)
        elif was and not on:
            self.say(f"clear {name}")
        self.alarms[name] = on

    def save(self, name):
        if not self.raw:
            return
        x = np.concatenate(list(self.raw))
        path = OUT / f"{self.stem}_{name}.wav"
        sf.write(path, x[:, [0, 1, 11]], FS, subtype="FLOAT")
        self.say(f"  saved the last {len(x) / FS:.0f} s: {path.name}")

    def feed(self, x):
        self.raw.append(x)
        buf = np.concatenate([self.pending, x])
        self.sec["main"].append(float(np.sqrt(np.mean((x[:, 0] + x[:, 1]) ** 2))))
        tags, data = decode(buf[:, 11])
        if self.offset is None:
            self.offset = self.lock(tags)
            if self.offset is None:
                self.pending = buf[-BLOCK * 2:]
                return
        n = (len(buf) - self.offset) // BLOCK
        t = tags[self.offset:self.offset + n * BLOCK].reshape(n, BLOCK)
        d = data[self.offset:self.offset + n * BLOCK].reshape(n, BLOCK)
        good = np.all(t == TAGS, axis=1)
        self.sec["badtags"] += int(np.sum(t != TAGS))
        for k in np.nonzero(good)[0]:
            self.frame(fields(d[k]))
        if n and not good[-1] and not np.any(good):
            self.offset = None                     # lost lock: search again
        rest = self.offset + n * BLOCK if self.offset is not None else len(buf)
        self.pending = buf[rest:]
        if self.offset is not None:
            self.offset = 0

    def lock(self, tags):
        for i in range(len(tags) - BLOCK + 1):
            if tags[i] == TAGS[0] and np.array_equal(tags[i:i + BLOCK], TAGS):
                return i
        return None

    def frame(self, f):
        s = self.sec
        s["frames"] += 1
        if self.prev_blk is not None:
            gap = (f["blk"] - self.prev_blk) & 0xFFFFFFFF
            if gap > 1:
                s["lost"] += gap - 1
        self.prev_blk = f["blk"]
        s["intervals"].append(f["interval"])
        s["runs"].append(f["run"])
        s["queue"] = max(s["queue"], f["queue"])
        if f["interval"] and f["run"] < 0.02 * f["interval"]:
            s["aside"] += 1                        # the estimator did not run
        if f["bg_cur"] or f["bg_node"]:
            s["bg"] += 1                           # frames with worker jobs pending
        if s["draws0"] is None:
            s["draws0"] = f["draws"]
        s["last"] = f
        self.last_valid = time.time()

    def second(self):
        s, now = self.sec, time.time()
        f = s["last"]
        if self.last_valid is None:                # the stream has not started yet
            self.sec = self.fresh()
            return
        self.alarm("frames", now - self.last_valid > 1 or s["lost"] > 0 or s["badtags"] > 0,
                   f"lost {s['lost']}, bad tags {s['badtags']}, "
                   f"{now - self.last_valid:.1f} s since a valid frame")
        main = 20 * np.log10(np.mean(s["main"]) + 1e-12) if s["main"] else float("nan")
        if f is None:
            self.sec = self.fresh()
            return
        iv = np.array(s["intervals"], float)
        med = float(np.median(iv))
        run_max = max(s["runs"])
        draws = (f["draws"] - s["draws0"]) & 0xFFFF
        if f["idle"] != self.last_idle:
            self.last_idle, self.idle_since = f["idle"], now
        self.alarm("idle", f["idle"] < IDLE_CAP and now - self.idle_since > 3,
                   f"idle counter held at {f['idle']} for {now - self.idle_since:.0f} s")
        if draws:
            self.draws_ran, self.draws_since = True, now
        self.alarm("draws", self.draws_ran and now - self.draws_since > 3,
                   f"no compressor page draw for {now - self.draws_since:.0f} s")
        if s["queue"] > 16:
            self.backlog_since = self.backlog_since or now
        else:
            self.backlog_since = None
        self.alarm("backlog", self.backlog_since is not None and now - self.backlog_since >= 3,
                   f"UI event queue at {s['queue']} for "
                   f"{0 if self.backlog_since is None else now - self.backlog_since:.0f} s")
        self.alarm("timing", iv.max() > 1.5 * med or run_max > med / 2,
                   f"interval max {iv.max():.0f} against median {med:.0f}, "
                   f"run max {run_max} ticks")
        row = {"time": datetime.now().strftime("%H:%M:%S"), "frames": s["frames"],
               "lost": s["lost"], "badtags": s["badtags"], "idle": f["idle"],
               "stage": f["stage"], "iv_med": round(med), "iv_max": int(iv.max()),
               "run_max": run_max, "run_pct": round(100 * run_max / med, 2),
               **{p: f[p] for p in PARAMS}, "dist": f["dist"], "thr_dac": f["thr_dac"],
               "wet": f["wet"], "dry": f["dry"], "seen": f["seen"], "draws_s": draws,
               "sp": hex(f["sp"]), "queue_max": s["queue"],
               "bg_pct": round(100 * s["bg"] / max(s["frames"], 1)),
               "bg_cur": f["bg_cur"], "bg_node": f["bg_node"],
               "aside_pct": round(100 * s["aside"] / max(s["frames"], 1)),
               "adc0": f["adc"][0], "adc1": f["adc"][1],
               "adc2": f["adc"][2], "adc3": f["adc"][3],
               "main_db": round(main, 1)}
        with open(self.csv, "a") as out:
            if not self.header:
                out.write(",".join(row) + "\n")
                self.header = True
            out.write(",".join(str(v) for v in row.values()) + "\n")
        print(f"{row['time']} frames {s['frames']:4d} lost {s['lost']} bad {s['badtags']}  "
              f"idle {f['idle']:6d}/{f['stage']}  run {row['run_pct']:5.2f}% "
              f"iv {med:.0f}/{iv.max():.0f}  THR {f['THR']:3d} dac {f['thr_dac']:5d}  "
              f"draws {draws:3d}/s seen {f['seen']:5d}  queue {s['queue']:3d}  "
              f"bg {row['bg_pct']:3d}% ({f['bg_cur']},{f['bg_node']})  "
              f"aside {row['aside_pct']:3d}%  adc {f['adc'][0]:4d} {f['adc'][1]:4d}  "
              f"MAIN {main:6.1f}", flush=True)
        self.sec = self.fresh()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--minutes", type=float, default=0, help="0: until Ctrl-C")
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    stem = f"monitor_{datetime.now().strftime('%Y%m%d_%H%M%S')}"
    m = Monitor(stem)
    q = queue.Queue()
    idx = rig.find_device()

    def cb(indata, frames, t, status):
        if status:
            q.put(status)
        q.put(indata.copy())

    minutes = 10 / 60 if args.check else args.minutes
    m.say(f"monitor: {'check, ' if args.check else ''}"
          f"{f'{minutes:g} min' if minutes else 'until Ctrl-C'}; log {m.log.name}")
    start = next_sec = time.time()
    totals = collections.Counter()
    try:
        with sd.InputStream(device=idx, channels=12, samplerate=FS, dtype="float32",
                            blocksize=4800, callback=cb):
            while not minutes or time.time() - start < minutes * 60:
                item = q.get()
                if not isinstance(item, np.ndarray):
                    m.say(f"stream status: {item}")
                    continue
                m.feed(item)
                if time.time() >= next_sec + 1:
                    totals.update(frames=m.sec["frames"], lost=m.sec["lost"],
                                  bad=m.sec["badtags"])
                    m.second()
                    next_sec += 1
    except KeyboardInterrupt:
        pass
    if args.check:
        ok = totals["frames"] > 0 and totals["bad"] == 0 and totals["lost"] == 0
        m.say(f"check: {totals['frames']} frames, {totals['lost']} lost, "
              f"{totals['bad']} bad tag words: {'bit-exact' if ok else 'NOT clean'}")


if __name__ == "__main__":
    main()
