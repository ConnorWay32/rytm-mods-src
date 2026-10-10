"""Mod 0006's SEQ sidechain filters: the fit to a measured sweep, and the stub's
`sctab` rows.

Each SEQ setting is two first-order sections in cascade,

    y = k*x - k*r*x[-1] + P*y[-1],     H = k (1 - r z^-1) / (1 - P z^-1)

with the pole P and the zero r both inside the unit circle, so the cascade is
minimum phase. k scales each section's peak gain to 1, so no section can raise
a side past its input's headroom. The row's last word is a Q8 dB level offset:
the one that puts the cascade back to unity at 1 kHz, less OFF's, plus the SEQ's
level relative to OFF (calibration.toml, [sidechain] level_db and transient_db).

The sections are fitted to a sweep from `calibrate.py sidechain`: per SEQ and
frequency, the level the hardware's detector saw less the model's. Adding that
to the response of the rows the sweep ran on (the session keeps them) gives the
hardware's response; two sections and a free offset are fitted to it in dB,
points under 9 kHz. Each SEQ's level against OFF comes from the same fit.
`calibrate.py sidechain --fit SESSION [--write]` runs it.
"""
import numpy as np
from scipy.optimize import least_squares

NAMES = ("OFF", "LPF", "HPF", "HIT")
KEYS = ("off", "lpf", "hpf", "hit")
Q31 = 2 ** 31
FIT_BELOW_HZ = 9000
STARTS = [(50, 100, 1000, 1000), (250, 100, 5000, 5000), (250, 100, 12000, 2500),
          (50, 100, 2000, 1500), (300, 100, 15000, 3000), (100, 50, 800, 700),
          (50, 3000, 1000, 11000), (40, 1000, 3000, 11000), (300, 100, 6000, 11000)]


def e(f, fs):
    return np.exp(-2 * np.pi * f / fs)


def quantise(r, P):
    """(k, -k*r, P) as Q31 integers, k taking the section's peak gain to just
    under 1. A first-order section peaks at DC or Nyquist."""
    peak = max((1 - r) / (1 - P), (1 + r) / (1 + P))
    k = 1 / peak
    return [int(np.floor(v * Q31)) for v in (k * 0.9999, -k * 0.9999 * r, P)]


def words_db(words, f, fs):
    """A row's two sections, as the stub runs them, in dB at f (no offset)."""
    zi = np.exp(-2j * np.pi * np.asarray(f, float) / fs)
    h = 1.0
    for i in (0, 3):
        k, kr, P = words[i] / Q31, words[i + 1] / Q31, words[i + 2] / Q31
        h = h * (k + kr * zi) / (1 - P * zi)
    return 20 * np.log10(np.abs(h))


def section_words(sections, fs):
    w = []
    for fp, fz in sections:
        w += quantise(e(fz, fs), e(fp, fs))
    return w


def quantised_rows(sections, level_db, fs):
    """-> {seq: the seven sctab words}, from each SEQ's (pole, zero) pairs in Hz
    and its level relative to OFF in dB. Deterministic: this is what
    calib_tables.py writes."""
    words = {s: section_words(sections[s], fs) for s in range(4)}
    unity = {s: int(round(-words_db(words[s], [1000.0], fs)[0] * 256)) for s in range(4)}
    return {s: words[s] + [unity[s] - unity[0] + int(round(level_db[s] * 256))] for s in range(4)}


def fit_shape(f, target, fs):
    """Two min-phase sections plus a free offset, least squares in dB.
    -> [(pole, zero) Hz, x2], residual."""
    top = fs / 2 * 0.98

    def res(lf):
        fp1, fz1, fp2, fz2 = np.exp(lf)
        d = words_db(section_words(((fp1, fz1), (fp2, fz2)), fs), f, fs)
        return d - target - np.mean(d - target)
    best = min((least_squares(res, np.log(np.minimum(np.array(p0, float), top * 0.99)),
                              bounds=(np.log(5), np.log(top))) for p0 in STARTS),
               key=lambda r: r.cost)
    fp1, fz1, fp2, fz2 = np.exp(best.x)
    return [[float(fp1), float(fz1)], [float(fp2), float(fz2)]], best.fun


def fit_sweep(err, sctab, fs):
    """err: {seq: [(Hz, hardware - model dB), ...]} from calibrate.sidechain_report;
    sctab: the 28 words the sweep's image ran. -> (sections by seq, level_db,
    residual by seq): the sweep's own levels against OFF, before transient_db."""
    now = {s: sctab[7 * s:7 * s + 7] for s in range(4)}
    f, target, secs, resid = {}, {}, {}, {}
    for s, v in err.items():
        f[s] = np.array([hz for hz, _ in v if hz < FIT_BELOW_HZ])
        d = np.array([x for hz, x in v if hz < FIT_BELOW_HZ])
        target[s] = words_db(now[s], f[s], fs) + now[s][6] / 256 + d      # the hardware's response
        secs[s], resid[s] = fit_shape(f[s], target[s], fs)
    new = quantised_rows(secs, [0.0] * 4, fs)
    m = {s: words_db(new[s], f[s], fs) + new[s][6] / 256 for s in secs}
    d_off = float(np.mean(target[0] - m[0]))
    level = [0.0] + [float(np.mean(target[s] - d_off - m[s])) for s in (1, 2, 3)]
    return secs, level, resid
