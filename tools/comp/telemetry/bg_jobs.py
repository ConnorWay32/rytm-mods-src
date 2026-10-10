"""Name the jobs BgWorker runs, from mod 0006's `telem = 2` telemetry.

That build sends, in place of the ADC slots, the first 8 characters of the name
of the job at the front of BgWorker's deque - the one running - on every block.
This records for a while, splits the blocks into episodes of one job, and prints
each episode: when it started, how long it held the worker, how much of it the
estimator stood aside for, and the UI queue's deepest point. With --bpm, each
start is also given as a position in the bar, counted from the first episode, so
a job that recurs at one place in the bar shows as a fixed position.

The names are those given to the enqueue at 0x40033224 by its 76 callers, cut
to 8 characters: "Pattern:" is Pattern::updateMirror, "Periodic" PeriodicTasks,
"Write pr" Write project MRAM, and so on.

    bg_jobs.py [--seconds 30] [--bpm 120] [--beats 4]
"""
import argparse
import sys
from collections import defaultdict
from pathlib import Path

import numpy as np
import sounddevice as sd

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))   # rig.py, in tools/comp
import monitor as mon
import rig

BLOCKS_S = 1500.0


def job_name(d):
    """Words 28..31, two characters each, high byte first -> the name, or ''."""
    raw = b"".join(bytes([(int(d[28 + i]) >> 8) & 0xFF, int(d[28 + i]) & 0xFF])
                   for i in range(4))
    return raw.split(b"\0")[0].decode("latin1")


def record(idx, seconds):
    x = sd.rec(int(seconds * mon.FS), samplerate=mon.FS, channels=12, dtype="float32",
               device=idx)
    sd.wait()
    tags, data = mon.decode(x[:, 11])
    off = mon.Monitor.lock(None, tags)
    if off is None:
        raise SystemExit("no telemetry frames: is a telem = 2 build running?")
    n = (len(tags) - off) // mon.BLOCK
    t = tags[off:off + n * mon.BLOCK].reshape(n, mon.BLOCK)
    d = data[off:off + n * mon.BLOCK].reshape(n, mon.BLOCK)
    rows = []
    for k in range(n):
        if not np.all(t[k] == mon.TAGS):
            continue
        f = mon.fields(d[k])
        f["job"] = job_name(d[k])
        rows.append(f)
    return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seconds", type=float, default=30.0)
    ap.add_argument("--bpm", type=float, help="the pattern's tempo, to place episodes in the bar")
    ap.add_argument("--beats", type=int, default=4, help="beats a bar")
    args = ap.parse_args()
    rows = record(rig.find_device(), args.seconds)
    if not rows:
        raise SystemExit("no complete frames")
    blk0 = rows[0]["blk"]
    iv = float(np.median([f["interval"] for f in rows]))

    eps, cur = [], None
    for f in rows:
        name = f["job"] if (f["bg_cur"] or f["bg_node"]) else ""
        if cur and name == cur["name"] and f["blk"] == cur["last"] + 1:
            cur["last"] = f["blk"]
        else:
            if cur and cur["name"]:
                eps.append(cur)
            cur = {"name": name, "first": f["blk"], "last": f["blk"], "aside": 0, "queue": 0}
        cur["aside"] += f["run"] < 0.02 * iv
        cur["queue"] = max(cur["queue"], f["queue"])
    if cur and cur["name"]:
        eps.append(cur)

    bar = 60.0 / args.bpm * args.beats if args.bpm else None
    t0 = (eps[0]["first"] - blk0) / BLOCKS_S if eps else 0.0
    print(f"{len(rows)} blocks ({len(rows) / BLOCKS_S:.1f} s), {len(eps)} job episodes")
    print(f"{'start s':>8} {'len s':>6} {'aside %':>7} {'queue':>5}"
          + (f" {'bar pos':>7}" if bar else "") + "  job")
    per = defaultdict(list)
    for e in eps:
        start = (e["first"] - blk0) / BLOCKS_S
        n = e["last"] - e["first"] + 1
        per[e["name"]].append(n / BLOCKS_S)
        pos = f" {((start - t0) % bar) / bar:7.3f}" if bar else ""
        print(f"{start:8.2f} {n / BLOCKS_S:6.2f} {100 * e['aside'] / n:7.0f} {e['queue']:5d}{pos}  {e['name']}")
    print("\nper job: episodes, total s, median s, longest s")
    for name, ls in sorted(per.items(), key=lambda kv: -sum(kv[1])):
        print(f"  {name:10s} {len(ls):4d} {sum(ls):7.2f} {np.median(ls):6.2f} {max(ls):6.2f}")


if __name__ == "__main__":
    main()
