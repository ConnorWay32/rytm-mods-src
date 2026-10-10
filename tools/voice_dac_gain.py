"""Mod 0013's per-slot gain against the analog path, from two mix_capture runs.

    voice_dac_gain.py OFF_RUN ON_RUN

OFF_RUN and ON_RUN are build/mix/<run> directories recorded with
`tools/mix_capture.py record PATTERNS --no-split`, DAC SUM off then on, every
DAC FILTER TYP OFF, nothing else changed (docs/CALIBRATION.md). The patterns
are the ones in both runs.

For each run and pattern, MAIN L and R are fitted on the active voice slots
(least squares, as mix_report's fit_gains), the ON run's MAIN first moved back
by its lag behind the slots, fractional part included: the DAC path's 2.58 ms is
not a whole number of samples. A slot's gain into MAIN is the length of its
(L, R) pair, so pan does not enter. What the fit leaves over is the delay and
reverb returns and what DIST and the compressor do; a pattern whose fit leaves
more than --max-residual of MAIN in either run is left out, as its gains are
pulled by it. A slot reads low by how many dB its ON gain is under its OFF gain;
the per-slot figure is the median over the patterns kept where the slot is
active in both runs, with the spread beside it.

Prints the slots, then `k` and `gaintab` corrected from the values now in
mods/0013-voice-dac, which the ON run is taken to have been built with: each
measured slot's gain k * gaintab raised by what it reads low, then `k` set so
the largest entry is 32767. A slot not measured keeps its gain.
"""
import argparse
import re
import sys
import tomllib
from pathlib import Path

import numpy as np
import soundfile as sf

from mix_capture import SILENT_DBFS, db

ROOT = Path(__file__).resolve().parent.parent
MOD = ROOT / "mods" / "0013-voice-dac"
MAXLAG = 1200          # samples, 25 ms
K_MAX = 16384          # k is Q15, at most 0.5


def load(run, pat):
    m, fs = sf.read(Path(run) / f"{pat}.wav", dtype="float64", always_2d=True)
    v, _ = sf.read(Path(run) / f"{pat}_voices.wav", dtype="float64", always_2d=True)
    n = min(len(m), len(v))
    return m[:n], v[:n], fs


def lag_of(y, x):
    """How far y trails x, in samples, from the cross-correlation peak refined
    by a parabola through it and its neighbours."""
    n = 1 << int(np.ceil(np.log2(len(y) * 2)))
    c = np.abs(np.fft.irfft(np.fft.rfft(y, n) * np.conj(np.fft.rfft(x, n)), n))
    c = np.r_[c[-MAXLAG:], c[:MAXLAG + 1]]
    i = int(np.argmax(c[1:-1])) + 1
    a, b, d = c[i - 1], c[i], c[i + 1]
    return i - MAXLAG + 0.5 * (a - d) / (a - 2 * b + d)


def advance(y, lag):
    """y moved `lag` samples earlier, by a phase ramp; the wrapped ends are cut
    off by the caller."""
    f = np.fft.rfftfreq(len(y))
    return np.fft.irfft(np.fft.rfft(y, axis=0) * np.exp(2j * np.pi * f * lag)[:, None],
                        len(y), axis=0)


def slot_gains(main, voices, active, lag):
    """Each active slot's gain into MAIN, the length of its (L, R) pair, and
    what the fit leaves of MAIN, in dB. -> ({slot: gain}, residual dB)."""
    if lag:
        main = advance(main, lag)
    cut = slice(MAXLAG, len(main) - MAXLAG)
    m, v = main[cut], voices[cut][:, active]
    g = np.linalg.lstsq(v, m, rcond=None)[0]
    res = db(np.mean((m - v @ g) ** 2)) - db(np.mean(m ** 2))
    return dict(zip(active, np.hypot(g[:, 0], g[:, 1]))), float(res)


def patterns(run):
    return {p.name[:-len("_voices.wav")] for p in Path(run).glob("*_voices.wav")
            if not p.name[:-len("_voices.wav")].endswith(("_a", "_b"))}


def current():
    """(k, the gaintab entries before k) from mods/0013-voice-dac."""
    k = tomllib.loads((MOD / "mod.toml").read_text())["params"]["k"]
    m = re.search(r"^gaintab:\s*\n\s*\.irp\s+t,([\d,]+)", (MOD / "stub.s").read_text(), re.M)
    if not m:
        raise SystemExit(f"{MOD / 'stub.s'}: no gaintab .irp list")
    return k, [int(v) for v in m.group(1).split(",")]


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("off")
    ap.add_argument("on")
    ap.add_argument("--max-residual", type=float, default=-20.0,
                    help="dB of MAIN the fit may leave over, in either run")
    a = ap.parse_args()

    pats = sorted(patterns(a.off) & patterns(a.on))
    if not pats:
        raise SystemExit("no pattern is in both runs")
    low = {s: [] for s in range(8)}
    for pat in pats:
        m0, v0, fs = load(a.off, pat)
        m1, v1, _ = load(a.on, pat)
        active = [s for s in range(8)
                  if min(db(np.mean(v0[:, s] ** 2)), db(np.mean(v1[:, s] ** 2))) > SILENT_DBFS]
        if not active:
            print(f"{pat}: no voice slot active in both runs, skipped")
            continue
        g0, r0 = slot_gains(m0, v0, active, 0)
        w = np.array([g0[s] for s in active])
        lag = lag_of(m1.sum(axis=1), v1[:, active] @ w)
        g1, r1 = slot_gains(m1, v1, active, lag)
        kept = max(r0, r1) <= a.max_residual
        print(f"{pat}: ON lag {1000 * lag / fs:.2f} ms, slots {' '.join(map(str, active))}, "
              f"residual {r0:.1f} / {r1:.1f} dB{'' if kept else ', left out'}")
        if not kept:
            continue
        for s in active:
            low[s].append(20 * np.log10(g0[s] / g1[s]))

    measured = [s for s in range(8) if low[s]]
    if not measured:
        raise SystemExit("no slot measured")
    print("\nslot   reads low dB   spread dB   patterns")
    for s in range(8):
        if low[s]:
            print(f"  {s}      {np.median(low[s]):+6.2f}       {np.ptp(low[s]):5.2f}       {len(low[s])}")
        else:
            print(f"  {s}      -")

    k, tab = current()
    gain = [k * tab[s] * (10 ** (np.median(low[s]) / 20) if low[s] else 1) for s in range(8)]
    k_new = int(np.ceil(max(gain) / 32767))
    new = [round(v / k_new) for v in gain]
    print(f"\nk: {k} -> {k_new}")
    print(f"gaintab: {','.join(map(str, tab))}")
    print(f"      -> {','.join(map(str, new))}")
    if k_new > K_MAX:
        print(f"   k over {K_MAX}: the voices cannot be brought up this far")

if __name__ == "__main__":
    main()
