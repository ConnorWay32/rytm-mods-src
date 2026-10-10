"""What feeds the UI event queue, from mod 0006's `telem = 3` telemetry.

That build sends, in place of the ADC slots, the UI queue's write index, the types
of its two newest entries and the types of the two at its head, on every block.
An event's type is the first byte of the event, which the UI loop at 0x400a4684
switches on (0..41). From consecutive write indices this counts arrivals by type;
more than two arrivals in one block are counted as type "?".

It prints, per window: the arrivals a second by type, the queue's median and
deepest, and the share of blocks the estimator stood aside. Then the whole run:
arrivals by type, and which types sat at the head while the queue was deep.

    ui_events.py [--seconds 30] [--window 2] [--deep 6]
"""
import argparse
import sys
from collections import Counter
from pathlib import Path

import numpy as np
import sounddevice as sd

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))   # rig.py, in tools/comp
import monitor as mon
import rig

BLOCKS_S = 1500.0


def record(idx, seconds):
    x = sd.rec(int(seconds * mon.FS), samplerate=mon.FS, channels=12, dtype="float32",
               device=idx)
    sd.wait()
    tags, data = mon.decode(x[:, 11])
    off = mon.Monitor.lock(None, tags)
    if off is None:
        raise SystemExit("no telemetry frames: is a telem = 3 build running?")
    n = (len(tags) - off) // mon.BLOCK
    t = tags[off:off + n * mon.BLOCK].reshape(n, mon.BLOCK)
    d = data[off:off + n * mon.BLOCK].reshape(n, mon.BLOCK)
    rows = []
    for k in range(n):
        if not np.all(t[k] == mon.TAGS):
            continue
        f = mon.fields(d[k])
        f["widx"] = int(d[k][28])
        f["new"] = (int(d[k][29]) & 0xFF, int(d[k][29]) >> 8)      # entry w-2, w-1
        f["head"] = (int(d[k][30]) & 0xFF, int(d[k][30]) >> 8)      # head, next
        rows.append(f)
    return rows


def arrivals(rows):
    """Per block, the list of event types that arrived since the previous block."""
    size = 1 << max(1, int(max(f["widx"] for f in rows))).bit_length()
    out, prev, prev_blk = [], None, None
    for f in rows:
        got = []
        if prev is not None and f["blk"] == prev_blk + 1:
            n = (f["widx"] - prev) % size
            if n == 1:
                got = [f["new"][1]]
            elif n == 2:
                got = [f["new"][0], f["new"][1]]
            elif n > 2:
                got = ["?"] * n
        out.append(got)
        prev, prev_blk = f["widx"], f["blk"]
    return out, size


def fmt(counter, seconds, top=8):
    items = sorted(counter.items(), key=lambda kv: -kv[1])[:top]
    return "  ".join(f"{k}:{v / seconds:.1f}" for k, v in items)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seconds", type=float, default=30.0)
    ap.add_argument("--window", type=float, default=2.0, help="seconds a printed row")
    ap.add_argument("--deep", type=int, default=6, help="queue depth counted as deep")
    args = ap.parse_args()
    rows = record(rig.find_device(), args.seconds)
    if not rows:
        raise SystemExit("no complete frames")
    arr, size = arrivals(rows)
    iv = float(np.median([f["interval"] for f in rows]))
    aside = np.array([f["run"] < 0.02 * iv for f in rows])
    q = np.array([f["queue"] for f in rows])
    bg = np.array([bool(f["bg_cur"] or f["bg_node"]) for f in rows])
    w = max(1, int(args.window * BLOCKS_S))
    print(f"{len(rows)} blocks ({len(rows) / BLOCKS_S:.1f} s); queue ring of {size} "
          f"(inferred)\n")
    print(f"{'t s':>5} {'ev/s':>6} {'q med':>5} {'q max':>5} {'aside%':>6} {'bg%':>4}  arrivals/s by type")
    total = Counter()
    for s in range(0, len(rows), w):
        c = Counter(t for a in arr[s:s + w] for t in a)
        total += c
        secs = min(w, len(rows) - s) / BLOCKS_S
        print(f"{s / BLOCKS_S:5.1f} {sum(c.values()) / secs:6.1f} {np.median(q[s:s + w]):5.0f} "
              f"{q[s:s + w].max():5d} {100 * aside[s:s + w].mean():6.0f} "
              f"{100 * bg[s:s + w].mean():4.0f}  {fmt(c, secs)}")
    secs = len(rows) / BLOCKS_S
    print(f"\nwhole run, arrivals/s: {fmt(total, secs, top=20)}")
    deep = Counter(f["head"][0] for f, d in zip(rows, q >= args.deep) if d)
    n_deep = int((q >= args.deep).sum())
    if n_deep:
        print(f"head type while queue >= {args.deep} ({n_deep} blocks), share: "
              + "  ".join(f"{k}:{100 * v / n_deep:.0f}%" for k, v in deep.most_common(10)))


if __name__ == "__main__":
    main()
