"""Time pattern changes from mod 0006's USB telemetry (`telem = 1`).

Hardware, 2026-09-23: with the preview page up, a kit load after a pattern
change stalled for minutes - the loading icon stayed up and the UI answered keys
seconds late - and finished in about 20 s once the page was left. While it ran,
stock's display idle counter rose about 51 a second instead of its usual 20.

For each program change this sends, it reads the telemetry and reports:
    ack    the idle counter resets: the device has taken the change
    kit    the compressor parameter block changes: the kit's values landed
    load   seconds the idle counter rose faster than 30 a second, and when that
           ended - the UI loop draining a backlog
    queue  the UI event queue's deepest point in the window
Nothing else is sent, so run it with the page and settings you want to compare.

    pc_timing.py [--patterns 1,5,8,2] [--window 60]

Logs to build/comp/telemetry/pc_timing_<time>.log.
"""
import argparse
import queue
import threading
import time
from datetime import datetime

import mido
import sounddevice as sd

import sys
from pathlib import Path as _Path

sys.path.insert(0, str(_Path(__file__).resolve().parent.parent))   # rig.py, in tools/comp
import monitor as mon
import rig


class Recorder(mon.Monitor):
    """monitor.Monitor's frame decoding, keeping (time, idle, params) per frame."""

    def __init__(self, stem):
        super().__init__(stem)
        self.trail = []
        self.lock_ = threading.Lock()

    def frame(self, f):
        super().frame(f)
        with self.lock_:
            self.trail.append((time.time(), f["idle"], tuple(f[p] for p in mon.PARAMS),
                               f["queue"]))


def analyse(trail, t0, window):
    pts = [p for p in trail if p[0] >= t0 - 1]
    if not pts:
        return None
    before = [p for p in pts if p[0] < t0]
    params0 = before[-1][2] if before else pts[0][2]
    ack = kit = None
    prev = None
    qmax = max((p[3] for p in pts if p[0] >= t0), default=0)
    for t, idle, params, _ in pts:
        if t < t0:
            prev = idle
            continue
        if ack is None and prev is not None and idle < prev:
            ack = t - t0
        if kit is None and params != params0:
            kit = t - t0
        prev = idle
    # idle rate per second after the change, from whole seconds
    fast, end = 0, None
    for s in range(int(window)):
        seg = [p for p in pts if t0 + s <= p[0] < t0 + s + 1]
        if len(seg) < 2:
            continue
        rate = (seg[-1][1] - seg[0][1]) / (seg[-1][0] - seg[0][0])
        if rate > 30:
            fast += 1
            end = s + 1
    return ack, kit, fast, end, qmax, pts[-1][2]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--patterns", default="1,5,8,2")
    ap.add_argument("--window", type=float, default=60)
    args = ap.parse_args()
    stem = f"pc_timing_{datetime.now().strftime('%Y%m%d_%H%M%S')}"
    m = Recorder(stem)
    m.second = lambda: None                        # no per-second monitor output
    q = queue.Queue()
    idx = rig.find_device()
    send = rig.open_midi(rig.load_config())
    stop = threading.Event()

    def cb(indata, frames, t, status):
        q.put(indata.copy())

    def pump():
        while not stop.is_set():
            try:
                m.feed(q.get(timeout=0.5))
            except queue.Empty:
                pass

    th = threading.Thread(target=pump, daemon=True)
    try:
        with sd.InputStream(device=idx, channels=12, samplerate=mon.FS, dtype="float32",
                            blocksize=4800, callback=cb):
            th.start()
            time.sleep(3)
            if not m.trail:
                raise SystemExit("no telemetry frames: is a telem = 1 build running?")
            m.say(f"pc_timing: patterns {args.patterns}, {args.window:g} s each")
            for slot in (int(v) for v in args.patterns.split(",")):
                t0 = time.time()
                send.port.send(mido.Message("program_change", channel=rig.AUTO_CHANNEL - 1,
                                            program=slot - 1))
                time.sleep(args.window)
                with m.lock_:
                    r = analyse(list(m.trail), t0, args.window)
                if r is None:
                    m.say(f"A{slot:02d}: no telemetry after the change")
                    continue
                ack, kit, fast, end, qmax, p1 = r
                fmt = lambda v: "none" if v is None else f"{v:5.1f} s"
                m.say(f"A{slot:02d}: ack {fmt(ack)}  kit {fmt(kit)}  load {fast:2d} s fast"
                      f"{'' if end is None else f', ended by {end} s'}  queue max {qmax}  "
                      f"params {dict(zip(mon.PARAMS, p1))}")
    finally:
        stop.set()
        send.port.close()


if __name__ == "__main__":
    main()
