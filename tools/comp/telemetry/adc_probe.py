"""Does the MKII's ADC input AN1 carry the compressor's gain reduction?

The MK1's compressor page drew a gain-reduction bar from AN1 (re/subsystems/
compressor-hardware.md, "Gain-reduction readback"). The MKII still samples AN1,
in result slot 0. This reads slots 0..3 from mod 0006's telemetry (`telem = 1`)
while it steps THR over CC, a few seconds a step, with the compressor at its
hardest ratio and fully wet.

Play a pattern with a steady kick before starting; the run stops if MAIN is
silent. Each step's THR is checked against the parameter block the telemetry
reads back.

A slot that carries gain reduction moves with THR and, within a step, with the
kick: its spread and its correlation with MAIN's block peak rise as the
compressor works harder. A slot that holds still, or moves the same at every
THR, does not.

    adc_probe.py [--thr 0,32,64,96,127] [--seconds 3]

Writes build/comp/telemetry/adc_probe_<time>.npz: per block the THR step, the
four slots and MAIN's peak.
"""
import argparse
import queue
from datetime import datetime

import numpy as np
import sounddevice as sd

import monitor
from monitor import BLOCK, FS, OUT, TAGS, decode, fields, rig

SETTLE_S = 0.5


class Reader:
    """Locks onto the telemetry frame and yields (fields, MAIN peak) per block."""

    def __init__(self):
        self.pending = np.zeros((0, 12), np.float32)
        self.offset = None

    def feed(self, x):
        buf = np.concatenate([self.pending, x])
        tags, data = decode(buf[:, 11])
        if self.offset is None:
            self.offset = next((i for i in range(len(tags) - BLOCK + 1)
                                if np.array_equal(tags[i:i + BLOCK], TAGS)), None)
            if self.offset is None:
                self.pending = buf[-BLOCK * 2:]
                return []
        n = (len(buf) - self.offset) // BLOCK
        sl = slice(self.offset, self.offset + n * BLOCK)
        t, d = tags[sl].reshape(n, BLOCK), data[sl].reshape(n, BLOCK)
        peak = np.abs(buf[sl, :2]).reshape(n, BLOCK * 2).max(axis=1)
        good = np.all(t == TAGS, axis=1)
        out = [(fields(d[k]), float(peak[k])) for k in np.nonzero(good)[0]]
        if n and not np.any(good):
            self.offset = None
        rest = self.offset + n * BLOCK if self.offset is not None else len(buf)
        self.pending = buf[rest:]
        if self.offset is not None:
            self.offset = 0
        return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--thr", default="0,32,64,96,127")
    ap.add_argument("--seconds", type=float, default=3.0)
    args = ap.parse_args()
    steps = [int(v) for v in args.thr.split(",")]

    cfg = rig.load_config()
    send = rig.open_midi(cfg)
    q = queue.Queue()

    def cb(indata, frames, t, status):
        q.put(indata.copy())

    reader = Reader()
    rows = []

    def collect(seconds, keep):
        want = int(seconds * FS / BLOCK)
        got = []
        while len(got) < want:
            for f, pk in reader.feed(q.get()):
                got.append((f, pk))
        if keep is not None:
            rows.extend((keep, *f["adc"], pk, f["THR"]) for f, pk in got)
        return got

    with sd.InputStream(device=rig.find_device(), channels=12, samplerate=FS,
                        dtype="float32", blocksize=4800, callback=cb):
        first = collect(0.5, None)
        if not first:
            raise SystemExit("no telemetry frames: flash a telem = 1 build of 0006")
        send("RAT", 0)                         # hardest
        send("ATK", 0)
        send("MIX", 127)
        print(" THR  took   MAIN dB   slot:  mean   sd  min  max   r(peak)")
        for thr in steps:
            send("THR", thr)
            collect(SETTLE_S, None)
            got = collect(args.seconds, thr)
            f_last = got[-1][0]
            pk = np.array([p for _, p in got])
            main_db = 20 * np.log10(max(pk.max(), 1e-9))
            if main_db < -60:
                raise SystemExit(f"MAIN silent at THR {thr} ({main_db:.0f} dB): "
                                 f"play a pattern and run again")
            took = "yes" if f_last["THR"] == thr else f"NO ({f_last['THR']})"
            adc = np.array([f["adc"] for f, _ in got], float)
            for s in range(4):
                a = adc[:, s]
                r = (np.corrcoef(a, pk)[0, 1]
                     if a.std() > 0 and pk.std() > 0 else float("nan"))
                lead = f"{thr:4d}  {took:4s}  {main_db:7.1f}" if s == 0 else " " * 22
                print(f"{lead}      {s}  {a.mean():6.0f} {a.std():4.0f} "
                      f"{a.min():4.0f} {a.max():4.0f}   {r:+.2f}")
            if took != "yes":
                raise SystemExit("THR did not take: check the FX channel in build/comp_rig.json")

    OUT.mkdir(parents=True, exist_ok=True)
    path = OUT / f"adc_probe_{datetime.now().strftime('%Y%m%d_%H%M%S')}.npz"
    np.savez(path, rows=np.array(rows, float),
             cols=np.array(["thr", "adc0", "adc1", "adc2", "adc3", "main_peak", "thr_read"]))
    print(f"wrote {path.relative_to(monitor.ROOT)}")


if __name__ == "__main__":
    main()
