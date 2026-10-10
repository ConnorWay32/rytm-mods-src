"""Profile mod 0006's estimator by stage, on a `telem = 1, prof = 1` build.

In that build MUP's integer part selects stages to skip, one bit each:
    1 the voice sum     2 the saturation    4 the SEQ sidechain
    8 the peak tracker  16 everything after the sample loop
This steps MUP through each selector, reads the stub's run time per block from
the telemetry, and prints the median as a share of the interval between
interrupts, and what skipping that stage saves. Blocks where the estimator
stood aside (the valve, or the page off screen) run about 1% and are left out;
their share is printed too. Run it with the preview page up and a pattern
playing. Leaves MUP at 0.

    profile_stages.py [--seconds 3]
"""
import argparse
import time

import numpy as np
import sounddevice as sd

import sys
from pathlib import Path as _Path

sys.path.insert(0, str(_Path(__file__).resolve().parent.parent))   # rig.py, in tools/comp
import monitor as mon
import rig

STAGES = [(0, "everything"), (1, "no voice sum"), (2, "no saturation"),
          (4, "no SEQ sidechain"), (8, "no peak tracker"), (16, "no per-block tail"),
          (31, "none of them")]


def run_times(idx, seconds):
    x = sd.rec(int(seconds * mon.FS), samplerate=mon.FS, channels=12, dtype="float32",
               device=idx)
    sd.wait()
    tags, data = mon.decode(x[:, 11])
    off = mon.Monitor.lock(None, tags)
    if off is None:
        raise SystemExit("no telemetry frames: is a telem = 1, prof = 1 build running?")
    n = (len(tags) - off) // mon.BLOCK
    t = tags[off:off + n * mon.BLOCK].reshape(n, mon.BLOCK)
    d = data[off:off + n * mon.BLOCK].reshape(n, mon.BLOCK)
    fr = [mon.fields(d[k]) for k in range(n) if np.all(t[k] == mon.TAGS)]
    iv = float(np.median([f["interval"] for f in fr]))
    run = np.array([f["run"] for f in fr], float) / iv * 100
    return run, fr


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seconds", type=float, default=3.0)
    args = ap.parse_args()
    idx = rig.find_device()
    send = rig.open_midi(rig.load_config())
    rows = []
    try:
        for sel, name in STAGES:
            send("MUP", sel)
            time.sleep(1.5)
            run, fr = run_times(idx, args.seconds)
            mup = fr[-1]["MUP"]
            active = run[run > 2.0]
            aside = 100 * (1 - len(active) / len(run))
            med = float(np.median(active)) if len(active) else float("nan")
            rows.append((sel, name, med, aside, mup))
    finally:
        send("MUP", 0)
        send.port.close()
    base = rows[0][2]
    print(f"{'MUP':>3}  {'stages':18s} {'run %':>6}  {'saves':>6}  {'aside %':>7}  MUP read")
    for sel, name, med, aside, mup in rows:
        print(f"{sel:3d}  {name:18s} {med:6.2f}  {base - med:6.2f}  {aside:7.1f}  {mup}")


if __name__ == "__main__":
    main()
