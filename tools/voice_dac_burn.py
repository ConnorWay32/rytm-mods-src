"""How much more audio-interrupt time the Rytm tolerates, from mod 0013's burn build.

    voice_dac_burn.py [--steps 0,1,2,...] [--seconds 60] [--mix-after 67]

Needs one image with 0013 `timing = 1`, `burn = 1` and 0006 `telem = 1` (so
without 0008 and 0010). The burn build spins in every audio interrupt for MUP's
integer part (CC 81) times 0.5% of a block (the first burn image did so at any
MIX; later ones only while MIX, CC 84, is 0). MUP is the makeup gain, up to
about +40 dB, which MIX 0, the dry path, keeps out of MAIN. This sets MIX to 0
and checks from the telemetry that it took before touching MUP.

For each step it first drains: MUP 0, then it waits until the UI event queue is
back at --idle-queue or below. Then it sets MUP, checks the device took it, and
holds for --seconds, reading 0006's telemetry (USB channel 11) and 0013's timing
words (channel 10) in 5 s chunks. It reports:
    0013    0013's run, burn included, as a share of the block: median
    queue   the UI event queue at the hold's start and end, its deepest point,
            and its trend in events a second (a straight-line fit): a load the
            UI keeps up with settles, one it does not grows without bound
    bg      the share of frames with BgWorker jobs pending
    aside   the share of frames 0006's estimator stood aside (run under 2%)
It stops when the unit stops responding - a CC the telemetry does not show
within 6 s, no telemetry, or the USB device gone - or when the queue passes
--max-queue, past which the UI is seconds behind and the device has hung. MUP
then goes back to its starting value and MIX to --mix-after (default: its
starting value), if the device takes them.

Set the scene first: DAC SUM on, a busy pattern playing, the page and DAC
FILTER as the load should be measured. Logs to build/voice_dac_burn_<time>.log.
"""
import argparse
import sys
import time
from datetime import datetime
from pathlib import Path

import numpy as np
import sounddevice as sd

sys.path.insert(0, str(Path(__file__).resolve().parent / "comp"))
sys.path.insert(0, str(Path(__file__).resolve().parent / "comp" / "telemetry"))
import rig  # noqa: E402
import monitor as mon  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
FS = 48000
BLOCK = 32
CH_TIMING, CH_TELEM = 9, 11                 # indices, as voice_dac_timing.py and monitor.py read them


def record(dev, seconds):
    """The 12 channels as 32-bit words. Read as float and scaled by 2^31, as
    monitor.py does: an int32 read scales by 2^31 - 1, which turns a word with
    zero data bits, 0x41000000, into 0x40ffffff and so its tag into another."""
    x = sd.rec(int(seconds * FS), samplerate=FS, channels=12, dtype="float32", device=dev)
    sd.wait()
    x = x[FS // 2:]                                         # the stream's first moments are not audio
    return np.round(x.astype(np.float64) * 2.0**31).astype(np.int64) & 0xffffffff


def timing(x):
    """0013's run share per block, from its tagged words."""
    w = x[:, CH_TIMING]
    is_run, is_iv = (w >> 24) == 0xa5, (w >> 24) == 0x5a
    if not is_run.any() or not is_iv.any():
        raise SystemExit("no 0013 timing words on channel 10: is the burn image flashed?")
    run = ((w[is_run] >> 8) & 0xffff)[::BLOCK // 4]
    iv = (((w[is_iv] >> 8) & 0xffff) * 4)[::BLOCK // 4]
    n = min(len(run), len(iv))
    return 100.0 * run[:n] / np.maximum(iv[:n], 1)


def telemetry(x):
    """0006's frames, as monitor.fields dicts; [] when none locks."""
    w = x[:, CH_TELEM]
    tags, data = (w >> 24) & 0xff, (w >> 8) & 0xffff
    start = next((i for i in range(len(tags) - BLOCK + 1)
                  if np.array_equal(tags[i:i + BLOCK], mon.TAGS)), None)
    if start is None:
        return []
    n = (len(tags) - start) // BLOCK
    t = tags[start:start + n * BLOCK].reshape(n, BLOCK)
    d = data[start:start + n * BLOCK].reshape(n, BLOCK)
    return [mon.fields(d[k]) for k in np.nonzero(np.all(t == mon.TAGS, axis=1))[0]]


class Unresponsive(Exception):
    pass


def read(dev, seconds):
    """(words, frames), or Unresponsive when the device or its telemetry is gone."""
    try:
        x = record(dev, seconds + 0.5)
    except sd.PortAudioError as e:
        raise Unresponsive(f"USB audio failed: {e}")
    fr = telemetry(x)
    if not fr:
        raise Unresponsive("no telemetry frames")
    return x, fr


def set_and_check(send, dev, param, value):
    """Send a CC and wait up to 6 s for the telemetry to show it."""
    send(param, value)
    for _ in range(3):
        _, fr = read(dev, 1.5)
        if fr[-1][param] == value:
            return fr
    raise Unresponsive(f"{param} {value} not taken within 6 s (device reads {fr[-1][param]})")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--steps", default="0,1,2,3,4,5,6,8,10,12",
                    help="MUP values; each is 0.5%% of a block of added load")
    ap.add_argument("--seconds", type=float, default=60.0, help="hold at each step")
    ap.add_argument("--idle-queue", type=int, default=12, help="queue depth that counts as drained")
    ap.add_argument("--max-queue", type=int, default=2000, help="stop when the queue passes this")
    ap.add_argument("--mix-after", type=int, default=None, help="MIX to leave set (default: as found)")
    a = ap.parse_args()
    steps = [int(s) for s in a.steps.split(",")]
    if any(not 0 <= s <= 127 for s in steps):
        raise SystemExit("steps are MUP values, 0..127")

    dev = rig.find_device()
    send = rig.open_midi(rig.load_config())
    log = ROOT / "build" / f"voice_dac_burn_{datetime.now():%Y%m%d_%H%M%S}.log"

    def say(line):
        line = f"{datetime.now():%H:%M:%S} {line}"
        print(line, flush=True)
        with open(log, "a") as f:
            f.write(line + "\n")

    _, first = read(dev, 1.5)
    mup0, mix0 = first[-1]["MUP"], first[-1]["MIX"]
    mix_after = mix0 if a.mix_after is None else a.mix_after
    say(f"start: MUP {mup0}, MIX {mix0}")
    try:
        set_and_check(send, dev, "MIX", 0)
    except Unresponsive as e:
        raise SystemExit(f"{e}; stopping before touching MUP")
    say(f"{'MUP':>4} {'burn':>5}  {'0013':>6}  {'queue start/end/max':>19} {'trend':>8}  {'bg':>4} {'aside':>5}  verdict")
    responsive = True
    try:
        for k in steps:
            # drain: no added load until the queue is back to idle
            set_and_check(send, dev, "MUP", 0)
            waited = 0.0
            while True:
                _, fr = read(dev, 2.0)
                if fr[-1]["queue"] <= a.idle_queue:
                    break
                waited += 2.5
                if waited > 180:
                    raise Unresponsive(f"the queue did not drain in 180 s (at {fr[-1]['queue']})")
            set_and_check(send, dev, "MUP", k)
            t0 = time.time()
            ts, qs, qmax, shares, bg, aside = [], [], 0, [], [], []
            while time.time() - t0 < a.seconds:
                x, fr = read(dev, 5.0)
                if fr[-1]["MUP"] != k:
                    raise Unresponsive(f"MUP reads {fr[-1]['MUP']} during the hold")
                ts.append(time.time() - t0)
                qs.append(fr[-1]["queue"])
                qmax = max(qmax, max(f["queue"] for f in fr))
                shares.append(np.median(timing(x)))
                bg += [bool(f["bg_cur"] or f["bg_node"]) for f in fr]
                aside += [f["interval"] > 0 and f["run"] < 0.02 * f["interval"] for f in fr]
                if qmax > a.max_queue:
                    break
            slope = np.polyfit(ts, qs, 1)[0] if len(ts) > 1 else 0.0
            verdict = "grows" if slope > 0.5 and qs[-1] > qs[0] + 20 else "settles"
            say(f"{k:4d} {k * 0.5:4.1f}%  {np.median(shares):5.2f}%  {qs[0]:6d} {qs[-1]:6d} {qmax:6d} "
                f"{slope:+7.1f}/s  {100 * np.mean(bg):3.0f}% {100 * np.mean(aside):4.0f}%  {verdict}")
            if qmax > a.max_queue:
                say(f"the queue passed {a.max_queue}: stopping")
                break
    except Unresponsive as e:
        responsive = False
        say(f"unit not responding: {e}")
    except KeyboardInterrupt:
        say("interrupted")
    finally:
        try:
            send("MUP", mup0)
            send("MIX", mix_after)
            say(f"sent MUP {mup0}, MIX {mix_after}{'' if responsive else ' (the device may not take them until it recovers)'}; "
                f"log {log.name}")
        except Exception as e:
            say(f"could not restore MUP/MIX: {e}")


if __name__ == "__main__":
    main()
