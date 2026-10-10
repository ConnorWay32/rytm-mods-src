"""An offline twin of mod 0006's estimator, with its constants read from stub.s.

Every coefficient is parsed out of the assembly rather than copied, so the twin
cannot drift from the device silently - which matters because the knees, THR_K
and the sctab level offsets are jointly fitted and a change to one invalidates
the others.

The structure mirrors the stub exactly, including where things happen:
  per sample   every DECIM-th sample: each side (the input model: pan,
               routing, trims, PRE returns and the master distortion) through
               the SEQ sidechain, then the louder of the two into a one-pole
               peak detector that jumps to a new peak and decays towards
               lower ones
  per block    32 samples: the detector value to dB, the silence gate, the
               static curve, the slow-attack scale, then the ballistics:
               attack a pole towards the demand with the 32-sample closed
               form, release a decay towards zero clamped at the demand

One implementation of each stage, integer where the stub is integer; the fits
and the verification call these rather than keeping copies. The sample-rate
loops are numba-compiled, since the fits run them over whole suites.

  sidechain, detector          one side at 48 kHz frames, as the stub steps it
  peaks_from_sides             the cal build's recorded sides (16 a block) -> peaks
  level                        Q31 peaks -> the Q8 level the curve is driven by
  static_gr_array, targets     level -> the demand before the slow-attack scale
  ballistics, ballistics_raw   demand -> GR
  gr_from_sides                all of it, from the recorded sides
"""
import re
from pathlib import Path

import numba
import numpy as np
from scipy.signal import lfilter

ROOT = Path(__file__).resolve().parent.parent.parent
STUB = ROOT / "mods/0006-comp-preview/stub.s"
BLOCK = 32


def _src(inc=None):
    """stub.s as the assembler sees it for calibration: calib.inc included and
    its table macros expanded where stub.s invokes them. inc: a calib.inc's text
    in place of the file's, such as the one a session ran on."""
    s = STUB.read_text()
    m = re.search(r'^\s*\.include\s+"([^"]*calib\.inc)"\s*$', s, re.M)
    if not m:
        return s
    inc = inc if inc is not None else (ROOT / m.group(1)).read_text()
    macros = dict(re.findall(r"^\s*\.macro\s+(\w+)\s*\n(.*?)^\s*\.endm", inc, re.M | re.S))
    body = re.sub(r"^\s*\.macro.*?^\s*\.endm\s*$", "", inc, flags=re.M | re.S)
    s = s[:m.start()] + body + s[m.end():]
    # A table calib.inc does not hold yet expands to nothing, so the generator
    # can read the stub's constants before its first run with a new table.
    return re.sub(r"^\s*(cal_\w+)\s*$", lambda t: macros.get(t.group(1), "").rstrip("\n"), s, flags=re.M)


def equ(n, s=None):
    """An .equ's value, its expression evaluated through the symbols it names.
    The first definition wins, which is the one outside any diagnostic-only .if."""
    s = s or _src()
    m = re.search(rf"^\s*\.equ\s+{n},\s*([^|\n]+)", s, re.M)
    if not m:
        raise SystemExit(f"no .equ {n} in stub.s")
    expr = m.group(1).strip()
    def sym(t):
        w = t.group(0)
        if re.fullmatch(r"0x[0-9a-fA-F]+|\d+", w):
            return str(int(w, 0))
        return f"({equ(w, s)})"
    return int(eval(re.sub(r"0x[0-9a-fA-F]+|[A-Za-z_]\w*|\d+", sym, expr)))


def table(n, kind, s=None):
    """The consecutive .word, .long or .byte lines after a label, comment lines
    between them and trailing | comments allowed."""
    s = s or _src()
    lines = s.splitlines()
    i = next(k for k, l in enumerate(lines) if l.strip().startswith(n + ":"))
    out = []
    for l in lines[i+1:]:
        t = l.split("|")[0].strip()
        if not t:
            continue
        if not t.startswith(kind):
            break
        out += [int(v, 0) for v in t[len(kind):].split(",") if v.strip()]
    if not out:
        raise SystemExit(f"no {kind} data found after {n}: in stub.s")
    return out


def constants(inc=None):
    s = _src(inc)
    eq = lambda n: equ(n, s)
    words = lambda n: table(n, ".word", s)
    return {
        "DET_ALPHA": eq("DET_ALPHA_H") / 2**31, "DECIM": eq("DECIM"),
        "CAL_Q8": eq("CAL_Q8"), "SILENCE_Q8": eq("SILENCE_Q8"),
        "sctab": table("sctab", ".long", s),
        "THR_K": eq("THR_K"), "GR_CAP": eq("GR_CAP"),
        "rattab": words("rattab"), "atktab": words("atktab"),
        "reltab": words("reltab"), "softtab": words("softtab"),
        "log2tab": words("log2tab"), "atkscale": table("atkscale", ".byte", s),
        "seqatk": table("seqatk", ".byte", s),
        "symgain": words("symgain"),
    }


def sym_gain(sym_raw, C):
    """DIST symmetry's gain as the stub adds it to the level, Q8 dB, from the
    8.8 SYM word (64 << 8 at centre, where it is zero)."""
    return _interp(C["symgain"], int(sym_raw), 11)


def _interp(tab, x, sh):
    i = min(x >> sh, len(tab) - 2); o = x - (i << sh)
    return ((tab[i+1] - tab[i]) * o >> sh) + tab[i]


def interp_array(tab, x, sh):
    """_interp over an array of indices."""
    tab = np.asarray(tab, dtype=np.int64)
    i = np.minimum(x >> sh, len(tab) - 2)
    o = x - (i << sh)
    return (((tab[i + 1] - tab[i]) * o) >> sh) + tab[i]


# ---------------------------------------------------------------- level
def to_db_array(peak, log2tab, floor=-24576):
    """Q31 magnitudes -> Q8 dB, as to_db in the stub: normalise to [2^30, 2^31),
    log2(1+f) from the table, 6.0206 dB an octave."""
    p = np.atleast_1d(np.asarray(peak, dtype=np.int64))
    out = np.full(p.shape, floor, dtype=np.int64)
    pos = p > 0
    x = p[pos]
    e = np.zeros_like(x)
    for k in (16, 8, 4, 2, 1):
        m = x < (1 << (31 - k))
        x = np.where(m, x << k, x)
        e += np.where(m, k, 0)
    d = ((x - 0x40000000) >> 8) >> 6
    d = interp_array(log2tab, d, 13) - ((e + 1) << 12)
    out[pos] = (d * 1541) >> 12
    return out


def to_db(peak, log2tab, floor=-24576):
    """to_db_array for one Q31 magnitude."""
    return int(to_db_array([int(peak)], log2tab, floor)[0])


def peak_q31(pk):
    """Float peaks, a fraction of full scale, to the Q31 the stub holds."""
    return (np.minimum(np.asarray(pk, dtype=np.float64), 0.9999) * 2 ** 31).astype(np.int64)


def level(peak, seq, sym_raw, C):
    """Q31 detector peaks -> the level the curve is driven by, Q8 dB: to_db,
    CAL_Q8, the SEQ row's offset and DIST symmetry's gain."""
    return to_db_array(peak, C["log2tab"]) + C["CAL_Q8"] + sc_row(seq, C)[1] + sym_gain(sym_raw, C)


# ---------------------------------------------------------------- curve
def static_gr_array(level_q8, thr, rat, C):
    """THR slides one curve per ratio along the level axis; SEQ is already in
    the level through its sctab offset. Q8 levels -> Q8 GR, the stub's integer
    steps; thr and rat may be arrays alongside the levels."""
    lvl = np.asarray(level_q8, dtype=np.int64)
    thr = np.broadcast_to(np.asarray(thr, dtype=np.int64), lvl.shape)
    rat = np.broadcast_to(np.asarray(rat, dtype=np.int64), lvl.shape)
    rt = np.asarray(C["rattab"], dtype=np.int64).reshape(4, 4)[rat]
    knee, width, recip, slope = rt[..., 0], rt[..., 1], rt[..., 2], rt[..., 3]
    u = lvl - ((C["THR_K"] * (thr - 64)) >> 4) - knee          # knees at THR 64
    d = (u * recip) >> 14
    a = np.abs(d)
    corr = (interp_array(C["softtab"], np.minimum(a, 2047), 8) + 8) >> 4
    d = np.where(a >= 2048, np.maximum(d, 0), np.maximum(d, 0) + corr)
    d = (((d * width) >> 8) * slope) >> 12
    return np.minimum(d, C["GR_CAP"])


def static_gr(level_q8, thr, rat, seq, C):
    """static_gr_array for one level; seq is unused, as in the stub."""
    return int(static_gr_array([level_q8], thr, rat, C)[0])


def targets(level_q8, thr, rat, C):
    """The demand before the slow-attack scale: the curve, gated below
    SILENCE_Q8."""
    lvl = np.asarray(level_q8, dtype=np.int64)
    t = static_gr_array(lvl, thr, rat, C)
    return np.where(lvl <= C["SILENCE_Q8"], 0, t)


# ---------------------------------------------------------------- ballistics
@numba.njit(cache=True)
def step(st, tg, aa, ar):
    """One block: a pole up towards the demand, a decay towards zero clamped at
    the demand down. Q8 in and out."""
    if tg > st:
        return st + (((tg - st) * aa) >> 16)
    d = st - ((st * ar + 0xffff) >> 16)
    return tg if tg > d else d


@numba.njit(cache=True)
def ballistics_raw(target, scale, aa, ar, st0=0, off=0):
    """The ballistics over per-block Q8 targets with the slow-attack scale (byte
    + 1), then the SEQ's loss off (Q8 dB, not below zero), and both coefficients
    given, for fits that scan them, from GR st0 (Q8). -> dB."""
    out = np.empty(len(target))
    st = st0
    for i in range(len(target)):
        d = ((target[i] * scale) >> 8) - off
        st = step(st, d if d > 0 else 0, aa, ar)
        out[i] = st / 256.0
    return out


def ballistics(target, atk, rel, rat, C, st0=0, seq=1):
    """The stub's slow-attack scale, the SEQ's slow-attack loss and attack /
    release over per-block Q8 targets, from GR st0 (Q8). -> dB."""
    scale = C["atkscale"][(atk * 8 + rel) * 4 + rat] + 1
    off = C["seqatk"][seq * 7 + atk] << 4
    aa = C["atktab"][min(atk, len(C["atktab"]) - 1)]
    ar = C["reltab"][min(rel, len(C["reltab"]) - 1)]
    return ballistics_raw(np.asarray(target, dtype=np.int64), scale, aa, ar, st0, off)


# ---------------------------------------------------------------- sidechain, detector
SC_ROW = 7


def sc_row(seq, C):
    """sctab's row for SEQ: two (k, -k*r, P) sections as floats, then the Q8
    level offset."""
    r = C["sctab"][seq * SC_ROW:(seq + 1) * SC_ROW]
    return [(r[0] / 2**31, r[1] / 2**31, r[2] / 2**31),
            (r[3] / 2**31, r[4] / 2**31, r[5] / 2**31)], r[6]


def _sections(x, seq, C):
    for k, kr, P in sc_row(seq, C)[0]:
        x = lfilter([k, kr], [1.0, -P], x)
    return x


def sidechain(side, seq, C=None):
    """The SEQ sidechain on one side, as the stub runs it: every DECIM-th sample
    through two first-order sections in cascade, y = k*x - k*r*x[-1] + P*y[-1],
    from sctab, each output held for DECIM samples so the result stays at 48 kHz
    for detector(), which takes every DECIM-th sample again. The row's level
    offset is added by level()."""
    C = C or constants()
    d = C["DECIM"]
    x = _sections(np.asarray(side, dtype=np.float64)[::d], seq, C)
    return np.repeat(x, d)[:len(side)]


def louder(left, right):
    """The detector's input: max(|L|,|R|) per sample."""
    return np.maximum(np.abs(left), np.abs(right))


@numba.njit(cache=True)
def _follow(x, a, spb):
    """The peak follower over |x|: a new peak at once, a lower one by a a
    sample; its value at each block's last sample."""
    n = len(x) // spb
    out = np.empty(n)
    p = 0.0
    for i in range(n * spb):
        v = abs(x[i])
        p = v if v > p else p + a * (v - p)
        if i % spb == spb - 1:
            out[i // spb] = p
    return out


def detector(voice_sum, C=None):
    """The per-sample peak follower on 48 kHz frames, taking every DECIM-th as
    the stub does; block-end values only."""
    C = C or constants()
    d = C["DECIM"]
    return _follow(np.abs(np.asarray(voice_sum, dtype=np.float64))[::d], C["DET_ALPHA"], BLOCK // d)


def peaks_from_sides(side_l, side_r, seq, C):
    """The detector's peak per block from the cal build's recorded sides, (blocks,
    BLOCK / DECIM) each: the sidechain and the follower on the samples the stub
    used. Floating point, so within about 0.001 dB of the device's."""
    L, R = (_sections(np.asarray(v, dtype=np.float64).ravel(), seq, C) for v in (side_l, side_r))
    return _follow(louder(L, R), C["DET_ALPHA"], BLOCK // C["DECIM"])


def gr_from_sides(side_l, side_r, seq, thr, rat, atk, rel, sym_raw, C, st0=0):
    """The twin from the recorded sides to the GR, dB per block, under C, from
    GR st0 (Q8)."""
    lv = level(peak_q31(peaks_from_sides(side_l, side_r, seq, C)), seq, sym_raw, C)
    return ballistics(targets(lv, thr, rat, C), atk, rel, rat, C, st0, seq)
