"""Fit the static curve and the SEQ offsets on a calibration's recordings.

The device's threshold slides one compression curve per ratio along the input
axis: every point of a ratio falls on one curve against level - k * THR, with the
same k at every ratio. So

    GR = min(slope_r * w_r * softplus((L - k*thr - knee_r) / w_r), CAP)

with L the stub's level after the sidechain and its row offset, and SEQ entering
only as that offset. The offsets live in calibration.toml ([sidechain] level_db,
set by the sidechain sweep, plus transient_db); c_seq below is the change the
data asks for.

Data:
  grids     calibrate.py grid sessions (--grid, repeated), each level through
            the current twin from the capture the session kept of it. The curve
            and LPF's offset are fitted here.
  patterns  calibrate.py suite --seq-matrix sessions (--suite, repeated), the
            device's own level per block against the measured reduction. HPF
            and HIT have no grid, so their c_seq is fitted here; LPF's is only
            reported.

    fit_shift.py --grid calgrid_A --grid calgrid_B --suite calsuite_C [--write]

The stub keeps 2^22 / width in an unsigned word, so width is at least 65 (0.254
dB); --min-width sets the floor the fit may use.
"""
import argparse
from datetime import date
import pickle
import re
from pathlib import Path

import numpy as np
from scipy.optimize import least_squares, minimize_scalar

import calib_tables as ct
import stub_model as sm

ROOT = Path(__file__).resolve().parent.parent.parent
C = sm.constants()


# ---------------------------------------------------------------- the law
def softplus(x):
    return np.where(x > 30, x, np.log1p(np.exp(np.minimum(x, 30))))


def law(p, L, thr, rat):
    """Float form. p = k, cap, then slope, width, knee per ratio. dB in, dB out."""
    k, cap = p[0], p[1]
    sl, w, kn = p[2:6], p[6:10], p[10:14]
    u = L - k * thr - kn[rat]
    return np.minimum(sl[rat] * w[rat] * softplus(u / w[rat]), cap)


def to_int(p):
    """The stub's constants: K Q12, CAP Q8, per ratio slope Q12, width Q8,
    2^22 / width, knee Q8 at THR 64."""
    w = [max(65, int(round(v * 256))) for v in p[6:10]]
    return {"K": int(round(p[0] * 4096)), "CAP": int(round(p[1] * 256)),
            "slope": [int(round(v * 4096)) for v in p[2:6]], "width": w,
            "recip": [int(round(2**22 / v)) for v in w],
            # knees at THR 64: the stub multiplies k by thr - 64
            "knee": [int(round(v * 256)) + ((int(round(p[0] * 4096)) * 64) >> 4) for v in p[10:14]]}


def law_int(q, lvl, thr, rat):
    """The stub's curve, stub_model.static_gr_array, with a candidate's
    constants (to_int's) in place of calib.inc's. Q8 levels -> Q8 GR."""
    rattab = [v for r in range(4) for v in (q["knee"][r], q["width"][r], q["recip"][r], q["slope"][r])]
    return sm.static_gr_array(lvl, thr, rat, {**C, "THR_K": q["K"], "GR_CAP": q["CAP"], "rattab": rattab})


# ---------------------------------------------------------------- data
def grid_points(sessions):
    """-> L (dB, the stub's level: CAL_Q8 and the row's offset added), thr, rat,
    seq, measured GR (dB), from calibrate.py grid sessions."""
    import cal_io
    import cal_tone
    pts = [(r["level_db"], r["thr"], r["rat"], r["seq"], r["gr"])
           for n in sessions for r in cal_tone.grid_data(cal_io.load_session(n), C)]
    a = np.array(pts)
    return a[:, 0], a[:, 1], a[:, 2].astype(int), a[:, 3].astype(int), a[:, 4]


def pattern_caps(suites):
    """-> captures, and the session each came from: every SEQ x THR x RAT
    condition of each --seq-matrix session, the device's own level per block and
    the measured reduction on the same block."""
    key = ([sm.sc_row(s, C)[1] for s in range(4)], list(suites))
    import cal_io
    import cal_suite
    cache = cal_io.session_path(suites[0]) / "fit_shift.pkl"
    if cache.exists():
        saved = pickle.load(open(cache, "rb"))
        if len(saved) == 3 and saved[0] == key:
            return saved[1], saved[2]
    caps, names = [], []
    for sess in suites:
        for r, c, meas, ok in cal_suite.session_blocks(sess):
            if not re.fullmatch(r"s\d_thr\d+_rat\d", r["condition"]):
                continue
            seq, thr, rat = (int(np.median(c.rec[k])) for k in ("SEQ", "THR", "RAT"))
            lvl = c.rec["level"].astype(np.int64)
            caps.append((seq, thr, rat, lvl, lvl <= C["SILENCE_Q8"], ok, meas))
            names.append(sess)
    pickle.dump((key, caps, names), open(cache, "wb"))
    return caps, names


# ---------------------------------------------------------------- scoring
def windows(t, gate, rat):
    """The estimate per block, through the stub's ballistics."""
    t = t.copy(); t[gate] = 0
    return sm.ballistics(t, 0, 0, rat, C)


def pattern_err(caps, curve):
    """curve(lvl Q8, seq, thr, rat) -> target Q8. Estimate minus measurement."""
    return np.concatenate([(windows(curve(lvl, seq, thr, rat), gate, rat) - meas)[ok]
                           for seq, thr, rat, lvl, gate, ok, meas in caps])


def rms(e):
    return float(np.sqrt(np.mean(e ** 2)))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--min-width", type=float, default=0.5, help="dB")
    ap.add_argument("--write", action="store_true",
                    help="put the [curve] fit into calibration.toml")
    ap.add_argument("--grid", action="append", required=True,
                    help="a calibrate.py grid session to fit the curve on (repeat for each)")
    ap.add_argument("--suite", action="append", required=True,
                    help="a calibrate.py suite --seq-matrix session to fit HPF and HIT on (repeat for each)")
    args = ap.parse_args()

    L, thr, rat, seq, meas = grid_points(args.grid)
    cseq = np.zeros(4)

    # Grid fit: the law plus LPF's level offset.
    def resid(v):
        return law(v[:14], L + v[14] * (seq == 1), thr, rat) - meas
    # Knees start near where the first fit put them, at THR 0 on the level's scale.
    p0 = ([0.95, 36.0] + [0.78, 0.75, 0.67, 0.52] + [0.6] * 4
          + [-112.0, -115.0, -121.0, -127.0] + [0.0])
    lo = [0.5, 20] + [0.1] * 4 + [args.min_width] * 4 + [-250] * 4 + [-40]
    hi = [1.5, 60] + [1.2] * 4 + [20] * 4 + [50] * 4 + [40]
    r = least_squares(resid, p0, bounds=(lo, hi))
    p, cseq[1] = r.x[:14], r.x[14]
    q = to_int(p)

    Lc = L + cseq[1] * (seq == 1)
    e_new = law(p, Lc, thr, rat) - meas
    e_int = law_int(q, np.round(Lc * 256), thr, rat) / 256 - meas
    print(f"grids, {len(meas)} points (rms, mean; + = estimate deeper)")
    print(f"  shifted law, float   {rms(e_new):.2f}  {e_new.mean():+.2f}")
    print(f"  shifted law, stub    {rms(e_int):.2f}  {e_int.mean():+.2f}   "
          f"integer vs float max {np.max(np.abs(e_int - e_new)):.3f} dB")
    print(f"  acceptance           {'met' if rms(e_int) <= 0.65 else 'NOT met'}: 0.65 dB rms")
    for s in sorted(set(seq)):
        for a, b in ((-99, -40), (-40, -30), (-30, -20), (-20, -10), (-10, 99)):
            k = (seq == s) & (L >= a) & (L < b)
            if k.sum():
                print(f"    SEQ{s} level {a:+4d}..{b:+4d} dB: n {k.sum():4d}"
                      f"  {rms(e_int[k]):5.2f} {e_int[k].mean():+5.2f}")

    # Patterns: HPF and HIT offsets fitted here, LPF's checked.
    caps, names = pattern_caps(args.suite)
    def curve_with(c):
        return lambda lvl, s, t, r: law_int(q, lvl + int(round(c[s] * 256)), t, r)
    lpf_pat = None
    for s in (1, 2, 3):
        sub = [c for c in caps if c[0] == s]
        def f(v, s=s, sub=sub):
            c = cseq.copy(); c[s] = v
            return rms(pattern_err(sub, curve_with(c)))
        best = minimize_scalar(f, bounds=(-30, 30), method="bounded", options={"xatol": 0.05}).x
        if s == 1:
            lpf_pat = best
        else:
            cseq[s] = best
    print(f"\nc_seq, dB: OFF 0  LPF {cseq[1]:+.2f} (grid; patterns alone {lpf_pat:+.2f})  "
          f"HPF {cseq[2]:+.2f}  HIT {cseq[3]:+.2f} (patterns)")
    print(f"patterns, {len(caps)} captures (rms, mean)")
    for s in sorted({c[0] for c in caps}):
        sub = [c for c in caps if c[0] == s]
        en = pattern_err(sub, curve_with(cseq))
        print(f"  SEQ{s}: {len(sub):3d}  {rms(en):.2f} {en.mean():+.2f}")
    print("by session and THR (rms, mean)")
    for sess in sorted(set(names)):
        for s in (2, 3):
            for t in sorted({c[1] for c, n in zip(caps, names) if n == sess and c[0] == s}, reverse=True):
                sub = [c for c, n in zip(caps, names) if n == sess and c[0] == s and c[1] == t]
                e = pattern_err(sub, curve_with(cseq))
                print(f"  {sess} SEQ{s} THR{t:3d}: {len(sub):2d}  {rms(e):.2f} {e.mean():+.2f}")

    # The fit's values in calibration.toml's units: each the stub's integer over its
    # scale, so calib_tables.py regenerates exactly these integers.
    cal = ct.load()
    curve = {"thr_step_db": q["K"] / 4096, "cap_db": q["CAP"] / 256,
             "knee_db": [v / 256 for v in q["knee"]], "width_db": [v / 256 for v in q["width"]],
             "slope": [v / 4096 for v in q["slope"]]}
    print("\nfor calibration.toml [curve]" + ("   (unchanged)" if curve == {k: cal["curve"][k] for k in curve} else ":"))
    for k, v in curve.items():
        print(f"  {k} = {v}")
    for i in range(4):
        print(f"    RAT{i}: 1:{1 / (1 - p[2 + i]):.2f}, {p[6 + i]:.2f} dB wide, knee {p[10 + i]:+.2f} dB at THR 0")
    # The sweep sets level_db. What the drums ask for beyond it has a part shared
    # by LPF, HPF and HIT - a steady tone against drums, the detector's crest
    # sensitivity, not a SEQ's - and each SEQ's departure from that, which is
    # transient_db: written past 0.2 dB, the spread of the drum suites.
    names = ("OFF", "LPF", "HPF", "HIT")
    common = float(np.median(cseq[1:]))
    tr = list(cal["sidechain"]["transient_db"])
    tr_new = [0.0] + [round(tr[s] + float(cseq[s]) - common, 2) for s in (1, 2, 3)]
    print("the SEQ offsets the drums ask for, against level_db + transient_db: "
          + "  ".join(f"{names[s]} {cseq[s]:+.2f}" for s in (1, 2, 3)) + f"; shared {common:+.2f} (left)")
    tr_moved = max(abs(a - b) for a, b in zip(tr_new, tr)) > 0.2
    print(f"for calibration.toml [sidechain]: transient_db = {tr_new if tr_moved else tr}"
          + ("" if tr_moved else "   (unchanged: within 0.2 dB)"))
    if args.write:
        src = f"fit_shift.py on {', '.join(args.grid + args.suite)}, {date.today()}"
        wrote = []
        if curve != {k: cal["curve"][k] for k in curve}:
            ct.set_values("curve", curve, src); wrote.append("[curve]")
        if tr_moved:
            ct.set_values("sidechain", {"transient_db": tr_new}, src); wrote.append("transient_db")
        print("wrote " + ", ".join(wrote) + " and calib.inc" if wrote else
              "nothing to write: calibration.toml already holds these")
    else:
        print("then calib_tables.py writes calib.inc, or rerun with --write")


if __name__ == "__main__":
    main()
