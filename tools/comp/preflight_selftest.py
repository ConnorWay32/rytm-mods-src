"""Synthetic check of calibrate.py preflight, with no hardware: a fake device
that plays a fake calibration project as cal-build captures. A sound project
must pass; a parameter lock on a fit pattern, a roll call that misses a voice,
and a tone that does not hold must each fail."""
import contextlib
import io
import sys
import tempfile
from pathlib import Path

import numpy as np

import cal_io
import cal_preflight as pf
import calframes as cf
from verify_selftest import encode

BLOCKS_PER_S = 48000 / cf.BLOCK
ROLES = {"fit": "1-2", "verify": "3", "scratch": 4, "tone_track": 8}


class Port:
    def __init__(self, dev):
        self.dev = dev

    def send(self, m):
        if m.type == "note_on":
            self.dev.held, self.dev.note_t = m.velocity > 0, self.dev.t
        elif m.type == "note_off":
            self.dev.held = False


class Stream:
    def __init__(self, dev):
        self.dev = dev

    def drain(self, seconds):
        self.dev.t += int(seconds * 24000)

    def read(self, seconds):
        return self.dev.capture(seconds).astype(np.float64)


class FakeDevice:
    """Plays the project: a pattern's voices, the parameters as last set - with
    a lock, if asked, holding one of them for half of every capture - and the
    tone track's note."""

    def __init__(self, faults=()):
        self.faults = set(faults)
        self.cfg = {"midi_out": "fake", "fx_channel": 13}
        self.port, self.stream = Port(self), Stream(self)
        self.slot, self.params, self.held, self.note_t = None, {}, False, 0
        self.playing, self.track = False, None
        self.rng = np.random.default_rng(11)
        self.t = 0

    def pattern(self, slot, settle=3.0, play=True):
        self.slot, self.playing = slot, play

    def track_cc(self, track, num, v):
        pass

    def note(self, track, on, velocity=100):
        if track == ROLES["tone_track"]:                 # the tone: held while the note is
            self.held, self.note_t = on, self.t
        else:                                            # a roll-call hit
            self.track = track if on else None

    def flush(self):
        pass

    def set(self, want, timeout=4.0):
        self.params.update(want)

    def cc(self, name, v):
        pass

    def readback(self, seconds=0.3):
        c = cf.decode(self.capture(seconds))
        last = {k: int(v[-1]) for k, v in c.rec.items()}
        last["SYM"] = last["SYM_raw"] >> 8
        return last, c

    def voices(self, nb):
        v = np.zeros((nb, cf.HALF, 8))
        n = np.arange(nb)
        if self.track is not None:                       # the roll call: one track's hit, 0.3 s
            if not (self.track == 9 and "roll_call" in self.faults):
                hit = min(nb, int(0.3 * BLOCKS_PER_S))
                v[:hit, :, cal_io.track_slot(self.track)] = self.rng.normal(0, 0.05, (hit, cf.HALF))
        elif self.slot in (1, 2, 3) and self.playing:    # drums: four voices, a hit every 20 blocks
            env = np.exp(-(n % 20) / 6.0)[:, None, None]
            v[:, :, :4] = self.rng.normal(0, 0.05, (nb, cf.HALF, 4)) * env
        elif self.slot == 4 and self.held:               # the tone: slot 7 a steady sine,
            t = (self.t + np.arange(nb * cf.HALF)) / 24000   # or 3 dB down 3 s after the note
            amp = 0.2 * (0.7 if "tone" in self.faults and self.t - self.note_t > 3.0 * 24000 else 1.0)
            v[:, :, cal_io.track_slot(ROLES["tone_track"])] = (amp * np.sin(2 * np.pi * 92 * t)).reshape(nb, cf.HALF)
        return v

    def capture(self, seconds):
        nb = max(int(seconds * BLOCKS_PER_S), 8)
        p = {k: 0 for k in cf.PARAMS} | {"DIST": 0, "SYM": 64} | {k: v for k, v in self.params.items()
                                                                  if k in cf.PARAMS or k in ("DIST", "SYM")}
        v = self.voices(nb)
        side = v.sum(axis=2) / cf.MAIN_PER_SIDE
        main = np.stack([side, side], -1) * cf.MAIN_PER_SIDE * 0.5
        if self.track is not None:                       # the returns' tail under the roll call
            main += self.rng.normal(0, 0.01, main.shape)
        lvl = 10 * np.log10(np.maximum(np.mean(v ** 2, axis=(1, 2)), 1e-12)) * 256
        self.t += nb * cf.HALF
        x = encode((side, side), p, np.zeros(nb), main, voices=v, level_q8=lvl)
        if "lock" in self.faults and self.slot == 2:     # THR locked to 90 on half the blocks
            y = encode((side, side), {**p, "THR": 90}, np.zeros(nb), main, voices=v, level_q8=lvl)
            x = np.concatenate([x[:len(x) // 2], y[len(y) // 2:]])
        return x


def run(faults):
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        ok = pf.run_preflight(FakeDevice(faults), seconds=2.0)
    return ok, out.getvalue()


def main():
    with tempfile.TemporaryDirectory() as tmp:
        cal_io.ROLES_FILE = Path(tmp) / "calibration_project.toml"
        cal_io.save_roles(ROLES)
        pf.CURRENT = cal_io.CURRENT = Path(tmp) / "current"
        ok, text = run(())
        assert ok, text
        for fault, says in (("lock", "A02 (fit): THR set 101 read [90, 101]"),
                            ("roll_call", "tracks [9] never sound alone"),
                            ("tone", "must hold steady")):
            ok, text = run((fault,))
            assert not ok and says in text, (fault, text)
    print("preflight: a sound project passes; a lock, a missing voice and a decaying tone fail: PASS")


if __name__ == "__main__":
    sys.exit(main())
