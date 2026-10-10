"""Read mod 0013's timing build (mod.toml `timing = 1`) off the Rytm's USB stream.

The stub writes, over voice slot 7's word (USB channel 10), four words in turn,
each (tag << 24) | (data << 8): the stub's run in DMA timer 0 ticks (0xa5), the
interval between interrupts / 4 (0x5a), the block's peak sum (0x3c) and its
clipped side-frames (0xc3); tools/voice_dac_headroom.py reads the last two.
The audio itself is untouched. This records a few
seconds and reports the run as a share of the interval: median, 99th
percentile and worst, over the blocks whose tags check.

With --prof (a build with `prof = 1`), it steps the compressor's MUP over CC
through the stub's stage selector - bit 0 skips the filter pass, bit 1 the
sum and output pass, bit 2 filters a slot at a time rather than in pairs - and
reports each. MUP is left at 0.

USB channel 10 carries the timing words in place of voice slot 7 while the
build runs.

    voice_dac_timing.py [--seconds 5] [--prof]
"""
import argparse
import sys
from pathlib import Path

import numpy as np
import sounddevice as sd

sys.path.insert(0, str(Path(__file__).resolve().parent / "comp"))
import rig  # noqa: E402

FS = 48000
BLOCK = 32


STAGES = {0: "filter (pairs) + sum", 1: "sum only", 2: "filter (pairs) only", 3: "neither",
          4: "filter (single) + sum", 6: "filter (single) only"}


def measure(dev, seconds, label):
    x = sd.rec(int(seconds * FS), samplerate=FS, channels=12, dtype="int32", device=dev)
    sd.wait()
    x = x[FS // 2:].astype(np.int64) & 0xffffffff        # the stream's first moments are not audio
    w = x[:, 9]
    is_run, is_iv = (w >> 24) == 0xa5, (w >> 24) == 0x5a
    if not is_run.any() or not is_iv.any():
        raise SystemExit("no tagged frames on channel 10: is the timing build flashed?")
    ok = is_run | is_iv | ((w >> 24) == 0x3c) | ((w >> 24) == 0xc3)
    # each word comes every fourth frame, so eight times a block; keep one
    run = ((w[is_run] >> 8) & 0xffff)[::BLOCK // 4]
    iv = (((w[is_iv] >> 8) & 0xffff) * 4)[::BLOCK // 4]
    n = min(len(run), len(iv))
    run, iv = run[:n], iv[:n]
    share = 100.0 * run / np.maximum(iv, 1)
    if label:
        print(f"\n{label}")
    print(f"{ok.mean() * 100:.1f}% of frames tagged, {len(run)} blocks")
    print(f"interval  median {np.median(iv):.0f} ticks ({np.median(iv) / 130e6 * 1e6:.0f} us at 130 MHz)")
    print(f"run       median {np.median(run):.0f}  p99 {np.percentile(run, 99):.0f}  max {run.max()} ticks")
    print(f"share     median {np.median(share):.2f}%  p99 {np.percentile(share, 99):.2f}%  max {share.max():.2f}%")


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--seconds", type=float, default=5.0)
    ap.add_argument("--prof", action="store_true")
    a = ap.parse_args()
    dev = rig.find_device()
    if not a.prof:
        measure(dev, a.seconds, None)
        return
    send = rig.open_midi(rig.load_config())
    for sel, name in STAGES.items():
        send("MUP", sel)
        measure(dev, a.seconds, f"MUP {sel}: {name}")
    send("MUP", 0)


if __name__ == "__main__":
    main()
