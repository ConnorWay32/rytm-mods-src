"""Mod 0013's DAC headroom, per pattern, from a mix_capture run on the timing build.

    voice_dac_headroom.py RUN

RUN is a build/mix/<run> directory recorded with `tools/mix_capture.py record`
while mod 0013's timing build (mod.toml `timing = 1`) ran with DAC SUM on. That
build writes, over voice slot 7 (channel 7 of each <pattern>_voices.wav), each
block's largest |sum| on either side (tag 0x3c, Q31 >> 15) and how many of its
side-frames reached full scale (tag 0xc3). Prints, per pattern, the peak in
dBFS of the DAC sum, the share of blocks with any clipping, and the clipped
side-frames in all.
"""
import sys
from pathlib import Path

import numpy as np
import soundfile as sf


def words(path):
    v, _ = sf.read(path, dtype="int32")
    return v[:, 7].astype(np.int64) & 0xffffffff


def main():
    run = Path(sys.argv[1])
    print("pattern   peak dBFS   blocks clipping   clipped side-frames")
    for f in sorted(run.glob("*_voices.wav")):
        w = words(f)
        tag, data = w >> 24, (w >> 8) & 0xffff
        pk, clip = data[tag == 0x3c], data[tag == 0xc3]
        if not len(pk):
            print(f"{f.name[:3]}       no telemetry: is the timing build flashed and DAC SUM on?")
            continue
        pk, clip = pk[::8], clip[::8]            # eight of each word a block; keep one
        peak = 20 * np.log10(max(pk.max(), 1) / 65536)
        print(f"{f.name[:3]}       {peak:+7.2f}      {100 * np.mean(clip > 0):6.2f}%         {int(clip.sum())}")


if __name__ == "__main__":
    main()
