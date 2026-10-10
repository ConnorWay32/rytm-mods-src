"""Sitting 1: the input model, the master distortion and DIST symmetry - their
recordings at MIX 0 and their fits."""
from datetime import datetime

import numpy as np

import calframes as cf
import calib_tables as ct
import rig
import stub_model as sm

from cal_io import (
    FIXED, FLOOR_DB, FS_GUARD, PRESAT, check_voices, load, load_session, ran_on, save,
    sides_current, slots, switched, write_session)
from cal_io import pattern_name, pattern_number, roll_call_capture


INPUT_CONDITIONS = [
    ("voices", {rig.CC_DELAY_VOL: 0, rig.CC_REVERB_VOL: 0, rig.CC_DIST: 0}),
    ("returns", {rig.CC_DELAY_VOL: 100, rig.CC_REVERB_VOL: 100, rig.CC_DIST: 0}),
    ("ret_dist64", {rig.CC_DELAY_VOL: 100, rig.CC_REVERB_VOL: 100, rig.CC_DIST: 64}),
]


def block_null(c):
    """Per block and side: the model's side against MAIN, dB, and the blocks fit to
    score (the estimator ran, MAIN above FLOOR_DB and not at full scale)."""
    out = []
    for i, side in ((0, c.side_l), (1, c.side_r)):
        a = np.sqrt(np.mean((cf.MAIN_PER_SIDE * side) ** 2, axis=1))
        b = np.sqrt(np.mean(c.main[:, :, i] ** 2, axis=1))
        ok = (~c.rec["aside"]) & (b > 10 ** (FLOOR_DB / 20)) & (np.max(np.abs(c.main), axis=(1, 2)) < FS_GUARD)
        out.append((20 * np.log10(np.maximum(a, 1e-12) / np.maximum(b, 1e-12)), ok))
    return out


def input_report(rows):
    """Per pattern and condition, the null's median after the session offset (the
    median of every voices-only null: MAIN moves with the volume knob)."""
    off = float(np.median([m for r in rows if r["condition"] == "voices" for m in (r["L"], r["R"])]))
    print(f"session offset {off:+.2f} dB (the median voices-only null)")
    for cond in [c for c, _ in INPUT_CONDITIONS]:
        sub = [r for r in rows if r["condition"] == cond]
        if not sub:
            continue
        med = np.array([m - off for r in sub for m in (r["L"], r["R"])])
        spread = np.array([r[k] for r in sub for k in ("spreadL", "spreadR")])
        print(f"  {cond:11s} pattern medians {np.median(med):+.2f} (max |x| {np.abs(med).max():.2f}),"
              f" p5..p95 width {np.median(spread):.2f} dB")
    return off


def level_check(c):
    """Per block: the device's recorded level, and the level the hardware's
    detector sees - MAIN at MIX 0, which is the compressor's input, taken per side
    through the twin's sidechain and detector with the same calibration. dB."""
    C = sm.constants()
    q = int(np.median(c.rec["SEQ"]))
    pk = sm.peaks_from_sides(c.main[:, :, 0] / cf.MAIN_PER_SIDE, c.main[:, :, 1] / cf.MAIN_PER_SIDE, q, C)
    hw = sm.level(sm.peak_q31(pk), q, 64 << 8, C)
    n = min(len(hw), len(c.rec["level"]))
    ok = (~c.rec["aside"][:n]) & (np.max(np.abs(c.main[:n]), axis=(1, 2)) < FS_GUARD)
    ok[:20] = False                                   # past the detector's start
    return c.rec["level"][:n][ok] / 256, hw[:n][ok] / 256


def run_input_sym(dev, args):
    """The detector level at each DIST symmetry against the hardware's, at MIX 0."""
    syms = [int(v) for v in args.sym.split(",")]
    dists = [int(v) for v in args.sym_dist.split(",")]
    stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    session = f"calinsym_{stamp}"
    rows = []
    try:
        for slot in slots(args.patterns):
            dev.pattern(slot)
            for d in dists:
                for sy in syms:
                    dev.set({**FIXED, "DELAY": 0, "REVERB": 0, "MIX": 0, "VOL": 127, "DIST": d, "SYM": sy})
                    x = dev.capture(args.seconds)
                    stem = save(x, session, stem=f"{session}_{pattern_name(slot)}_d{d}_s{sy}", slim=True)
                    rows.append({"pattern": slot, "dist": d, "sym": sy, "stem": stem})
                    print(f"{pattern_name(slot)} DIST {d:3d} SYM {sy:3d}", flush=True)
    finally:
        write_session(session, {"patterns": args.patterns, "rows": rows})
        dev.set({"DIST": 0, "SYM": 64})
        print(f"session {session}; left DIST 0, SYM 64 and MIX 0")
    input_sym_report(rows)


def input_sym_report(rows):
    diff = {}
    for r in rows:
        dev, hw = level_check(cf.decode(load(r["stem"])))
        diff[(r["pattern"], r["dist"], r["sym"])] = float(np.median(dev - hw))
    print("device level - hardware detector level, dB, relative to SYM 64 (removes the volume knob)")
    pats = sorted({k[0] for k in diff}); dists = sorted({k[1] for k in diff}); syms = sorted({k[2] for k in diff})
    for d in dists:
        print(f"  DIST {d:3d}   " + "  ".join(f"SYM {sy:3d}" for sy in syms))
        for p in pats:
            ref = diff.get((p, d, 64), 0.0)
            print(f"    {pattern_name(p)}      " + "  ".join(f"{diff[(p, d, sy)] - ref:+7.2f}" for sy in syms))
    return diff


# The input stage's conditions: INPUT_CONDITIONS, and each return alone for the fit.
INPUT_CONDITIONS = INPUT_CONDITIONS + [
    ("delay", {rig.CC_DELAY_VOL: 127, rig.CC_REVERB_VOL: 0, rig.CC_DIST: 0}),
    ("reverb", {rig.CC_DELAY_VOL: 0, rig.CC_REVERB_VOL: 127, rig.CC_DIST: 0}),
]


DOMINANT_DB = 20.0         # a slot this far over every other: its block is a solo


SOLO_FLOOR_DB = -45.0      # MAIN over this, per block, to measure on


SILENT_SLOT_DB = -50.0     # every slot under this: the block is the returns alone


MIN_BLOCKS = 50            # fewer blocks than this: the value is held


def run_input(dev, args):
    stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    session = f"calinput_{stamp}"
    rows, prev = [], None
    try:
        # The fit patterns playing, then the roll call on its pattern's kit.
        todo = [(s, False) for s in slots(args.patterns)] + [(pattern_number(args.roll_call), True)]
        for slot, roll in todo:
            tag = f"{pattern_name(slot)}{' roll call' if roll else ''}"
            if not roll:
                dev.pattern(slot)
            for i, (name, cond) in enumerate(INPUT_CONDITIONS):
                named = {("DIST" if k == rig.CC_DIST else k): v for k, v in cond.items()}
                want = {**FIXED, **named, "MIX": 0}          # DIST by name, so it is read back
                if roll:
                    x = roll_call_capture(dev, slot, want)
                else:
                    dev.set(want)
                    x = dev.capture(args.seconds)
                lvl = 20 * np.log10(np.maximum(np.sqrt(np.mean(x ** 2, axis=0)), 1e-12))
                check_voices(lvl, f"{tag} {name}")
                if i == 0 and not roll:
                    prev = switched(prev, lvl, f"{tag} {name}")
                stem = save(x, session, stem=f"{session}_{pattern_name(slot)}{'_rollcall' if roll else ''}_{name}",
                            pcm24=True)
                rows.append({"pattern": slot, "roll_call": roll, "condition": name, "stem": stem,
                             **null_stats(cf.decode(x))})
                r = rows[-1]
                print(f"{tag} {name:11s} L {r['L']:+.2f}  R {r['R']:+.2f}  (before the session offset)", flush=True)
    finally:
        write_session(session, {"patterns": args.patterns, "roll_call": args.roll_call, "rows": rows})
        dev.set({"DIST": 0})
        print(f"session {session}; left DIST 0 and MIX 0")
    input_report(rows)
    input_fit(load_session(session), args.write)
    return session


def block_db(c):
    """Per block: each slot's energy, MAIN's and the model's (both sides, MAIN
    units), dB, and the blocks fit to measure on - the estimator ran, and MAIN
    stays under the saturation's knee, c/4, where the model is linear."""
    db = lambda v: 10 * np.log10(np.maximum(v, 1e-24))
    knee = min(ct.load()["distortion"]["sat_c_pos"], ct.load()["distortion"]["sat_c_neg"]) / 4
    slots = db(np.mean(c.slots ** 2, axis=1))
    main = db(np.mean(c.main ** 2, axis=(1, 2)))
    model = db(np.mean((cf.MAIN_PER_SIDE * np.stack([c.side_l, c.side_r], -1)) ** 2, axis=(1, 2)))
    ok = (~c.rec["aside"]) & (np.max(np.abs(c.main), axis=(1, 2)) < knee) & (main > SOLO_FLOOR_DB)
    return slots, main, model, ok


def input_fit(rec, write=False):
    """The null (model over MAIN) where one slot sounds alone gives that slot's
    trim; where no slot sounds, each return's constant. MAIN moves with the volume
    knob, so only differences mean anything: the trims keep the quietest slot at
    0 dB (the stub can only cut), and each return is matched to that slot's null."""
    ran = ran_on(rec)[0]["input"]
    solo = {s: [] for s in range(8)}
    alone = {"delay": [], "reverb": []}
    for r in rec["rows"]:
        if r["condition"] not in ("voices", "delay", "reverb"):
            continue
        slots, main, model, ok = block_db(cf.decode(load(r["stem"])))
        null = model - main
        if r["condition"] == "voices":
            top = np.argmax(slots, axis=1)
            srt = np.sort(slots, axis=1)
            dom = ok & (srt[:, -1] - srt[:, -2] > DOMINANT_DB)
            for s in range(8):
                solo[s] += list(null[dom & (top == s)])
        else:
            alone[r["condition"]] += list(null[ok & (slots.max(axis=1) < SILENT_SLOT_DB)])
    # u: each slot's null without its trim, the model's gain against the hardware's
    u = {s: float(np.median(v)) + ran["slot_trim_db"][s] for s, v in solo.items() if len(v) >= MIN_BLOCKS}
    print(f"{rec['name']}: slots alone (one slot {DOMINANT_DB:g} dB over the rest), null before its trim")
    for s in range(8):
        n = len(solo[s])
        print(f"  slot {s}: {n:5d} blocks  " + (f"{u[s]:+.2f} dB" if s in u else "too few: held"))
    trims = list(ran["slot_trim_db"])
    ref = min(u.values()) if u else None
    for s, v in u.items():
        trims[s] = round(v - ref, 4)
    print(f"  slot_trim_db = {trims}   (ran {ran['slot_trim_db']})")
    out = {}
    if trims != list(ran["slot_trim_db"]) and max(abs(a - b) for a, b in zip(trims, ran["slot_trim_db"])) > 0.1:
        out["slot_trim_db"] = trims
    for name, key in (("delay", "delay_db"), ("reverb", "reverb_db")):
        v = alone[name]
        if len(v) < MIN_BLOCKS or ref is None:
            print(f"  {name} alone: {len(v)} blocks, too few: {key} held (a sparse pattern with sends gives them)")
            continue
        new = round(ran[key] - (float(np.median(v)) - ref), 2)
        print(f"  {name} alone: {len(v)} blocks, null {np.median(v):+.2f} dB against the slots' {ref:+.2f}:"
              f" {key} = {new}   (ran {ran[key]})")
        if abs(new - ran[key]) > 0.2:
            out[key] = new
    if write and out:
        ct.set_values("input", out, f"calibrate.py input {rec['name']}, {datetime.now():%Y-%m-%d}")
        print("wrote [input] " + ", ".join(out) + " and calib.inc")
    elif write:
        print("nothing to write: every change within its tolerance (trims 0.1 dB, returns 0.2)")
    elif out:
        print("rerun with --write to put " + ", ".join(out) + " into calibration.toml")


def null_stats(c):
    out = {}
    for name, (e, ok) in zip("LR", block_null(c)):
        v = e[ok]
        out[name] = float(np.median(v)) if len(v) else float("nan")
        out["spread" + name] = float(np.percentile(v, 95) - np.percentile(v, 5)) if len(v) else float("nan")
    return out


DISTS = (0, 16, 32, 48, 64, 80, 96, 112, 127)


def peaks24(v, c=None):
    """The stub's peak follower on a 24 kHz series (blocks, 16) -> its value at
    each block end."""
    a = (c or sm.constants())["DET_ALPHA"]          # DET_ALPHA_H, as the stub runs it
    x = np.abs(v).ravel()
    out, p = np.empty(len(x) // cf.HALF), 0.0
    for i, u in enumerate(x):
        p = u if u > p else p + a * (u - p)
        if i % cf.HALF == cf.HALF - 1:
            out[i // cf.HALF] = p
    return out


def sat(u, cp, cn, n):
    c = np.where(u >= 0, cp, cn)
    return u / (1 + np.abs(u / c) ** n) ** (1 / n)


def dist_fit_one(c):
    """Per side: MAIN's gain against the pre-saturation side from quiet samples,
    then the saturation's c+, c- and order on the peak metric where the signal
    nears the knee. Levels in MAIN units."""
    from scipy.optimize import minimize
    out = []
    keep = (~c.rec["aside"]) & (np.max(np.abs(c.main), axis=(1, 2)) < FS_GUARD)
    for side, pre_q31 in ((0, c.side_l), (1, c.side_r)):
        pre = cf.MAIN_PER_SIDE * pre_q31[keep]
        m = c.main[keep][:, :, side]
        quiet = np.abs(pre) < 0.2
        g = float(np.sum(pre[quiet] * m[quiet]) / np.sum(pre[quiet] ** 2))
        pm = peaks24(m / g)
        ok = pm > 1e-3
        row = {"gain_db": 20 * np.log10(g), "peak": float(np.percentile(np.abs(pre), 99.9))}
        if row["peak"] > 0.6:
            err = lambda q: float(np.mean((20 * np.log10(peaks24(sat(pre, np.exp(q[0]), np.exp(q[1]), q[2]))[ok] / pm[ok])) ** 2))
            r = minimize(err, [np.log(0.7), np.log(0.7), 12.0], method="Nelder-Mead",
                         options=dict(xatol=0.005, fatol=1e-6, maxiter=300))
            row.update(cp=float(np.exp(r.x[0])), cn=float(np.exp(r.x[1])), n=float(r.x[2]), rms=float(np.sqrt(r.fun)))
        out.append(row)
    return out


def dist_report(rec, write=False):
    rows, session = rec["rows"], rec["name"]
    cal = ct.load()["distortion"]
    ran = ran_on(rec)[0]["distortion"]
    fits = {}
    print("pattern DIST  gain L    R dB   peak   n      c+     c-    rms dB")
    for r in rows:
        f = dist_fit_one(cf.decode(load(r["stem"])))
        fits[(r["pattern"], r["dist"])] = f
        L = f[0]
        extra = (f"{L['n']:5.1f} {L['cp']:6.3f} {L['cn']:6.3f} {L['rms']:6.3f}" if "n" in L else "   below the knee")
        print(f"  {pattern_name(r['pattern'])}  {r['dist']:3d}  {f[0]['gain_db']:+6.2f} {f[1]['gain_db']:+6.2f}  "
              f"{L['peak']:5.2f}  {extra}")
    # The gain: the model applies its own DIST gain before the tap, so MAIN's gain
    # on the pre-saturation side should not move with DIST. Its drift from DIST 0
    # is the correction to [distortion] gain.
    print("\nDIST gain, the hardware's against the model's, relative to DIST 0 (dB, median of patterns and sides):")
    pats = sorted({p for p, _ in fits})
    drift = {}
    for d in DISTS:
        v = [fits[(p, d)][k]["gain_db"] - fits[(p, 0)][k]["gain_db"] for p in pats if (p, d) in fits for k in (0, 1)]
        if v:
            drift[d] = float(np.median(v))
    print("  " + "  ".join(f"{d}: {v:+.2f}" for d, v in drift.items()))
    gd = dict(zip(ran["gain_dist"], ran["gain"]))          # the drift is against the gain that ran
    new = [round(float(g * 10 ** (np.interp(d, list(drift), list(drift.values())) / 20)), 3) for d, g in gd.items()]
    print(f"  [distortion] gain = {new}   (now {cal['gain']})")
    fitted = [f[k] for f in fits.values() for k in (0, 1) if "n" in f[k]]
    if fitted:
        med = {k: float(np.median([f[k] for f in fitted])) for k in ("cp", "cn", "n")}
        print(f"saturation, median of {len(fitted)} fits at DIST past the knee: c+ {med['cp']:.3f}, c- {med['cn']:.3f}, "
              f"n {med['n']:.1f}   (now {cal['sat_c_pos']}, {cal['sat_c_neg']}, {cal['sat_order']})")
        cur = [f for f in fitted]
        print(f"  fit rms {np.median([f['rms'] for f in cur]):.3f} dB median")
    if write:
        from datetime import date
        src = f"calibrate.py dist {session}, {date.today()}"
        wrote = []
        if max(abs(v) for v in drift.values()) > 0.15:
            ct.set_values("distortion", {"gain": new}, src); wrote.append("gain")
        # c moves only when every pattern moves it the same way past 0.02: the
        # knee depends on the material (hats saturate about 1 dB earlier), and a
        # median across patterns follows whichever material there is most of.
        per = {}
        for (p, d), f in fits.items():
            for k in (0, 1):
                if "n" in f[k]:
                    per.setdefault(p, []).append((f[k]["cp"], f[k]["cn"]))
        shift = {p: (float(np.median([v[0] for v in vs])) - cal["sat_c_pos"],
                     float(np.median([v[1] for v in vs])) - cal["sat_c_neg"]) for p, vs in per.items()}
        for i, key in ((0, "sat_c_pos"), (1, "sat_c_neg")):
            moves = [v[i] for v in shift.values()]
            if moves and (all(m > 0.02 for m in moves) or all(m < -0.02 for m in moves)):
                ct.set_values("distortion", {key: round(cal[key] + float(np.median(moves)), 3)}, src)
                wrote.append(key)
        print("  c per pattern, against now: " + "  ".join(f"{pattern_name(p)} {a:+.3f}/{b:+.3f}" for p, (a, b) in shift.items()))
        print("wrote [distortion] " + ", ".join(wrote) + " and calib.inc" if wrote else
              "nothing to write: gain within 0.15 dB, and c not moved the same way by every pattern")


SYMS = tuple(range(0, 128, 8)) + (127,)


def sym_report(rec, write=False):
    """DIST symmetry as a bias before the saturation and a gain after it, per SYM:

        MAIN = g0 * gain * (sat(pre + bias) - sat(bias))

    with g0 each pattern's, DIST's and side's gain at SYM 64 (quiet samples), c
    and the order the current [distortion]'s. bias and gain are fitted per SYM
    over every pattern, DIST and side on the detector's 5 ms peak level, the
    metric the compressor sees. The sides are the pre-saturation ones, after DIST's gain
    and before the bias, so the tables that ran do not enter. SYM 127 is the
    tables' last point, at 128."""
    from scipy.optimize import minimize
    cal = ct.load()["distortion"]
    cp, cn, n = cal["sat_c_pos"], cal["sat_c_neg"], cal["sat_order"]
    sides_current(rec)
    data, g0 = {}, {}
    for r in rec["rows"]:
        c = cf.decode(load(r["stem"]))
        keep = (~c.rec["aside"]) & (np.max(np.abs(c.main), axis=(1, 2)) < FS_GUARD)
        for k, v in ((0, c.side_l), (1, c.side_r)):
            pre, m = cf.MAIN_PER_SIDE * v[keep], c.main[keep][:, :, k]
            pm = peaks24(m)
            data[r["pattern"], r["dist"], r["sym"], k] = (pre, pm, pm > 1e-3)
            if r["sym"] == 64:
                q = np.abs(pre) < 0.2
                g0[r["pattern"], r["dist"], k] = float(np.sum(pre[q] * m[q]) / np.sum(pre[q] ** 2))
    db = lambda a, b: 20 * np.log10(np.maximum(a, 1e-9) / np.maximum(b, 1e-9))
    fit = {}
    print(f"{rec['name']}: per SYM, over {len({k[0] for k in data})} patterns, DIST {sorted({k[1] for k in data})}, both sides")
    print("  SYM    bias    gain dB   rms dB  mean   (none: mean)")
    for sy in SYMS:
        keys = [k for k in data if k[2] == sy]

        def err(q):
            b, gl = q[0], 10 ** (q[1] / 20)
            e = [db(peaks24(g0[p, d, k] * gl * (sat(pre + b, cp, cn, n) - sat(np.array(b), cp, cn, n)))[ok], pm[ok])
                 for (p, d, _, k) in keys for pre, pm, ok in [data[p, d, sy, k]]]
            e = np.concatenate(e)
            return float(np.mean(e ** 2)), e
        x = [0.0, 0.0] if sy == 64 else minimize(lambda q: err(q)[0], [0.5 * (64 - sy) / 64, 0.0], method="Nelder-Mead",
                                                  options=dict(xatol=1e-3, fatol=1e-5)).x
        f, e = err(x)
        fit[sy] = (round(float(x[0]), 4), round(float(x[1]), 3))
        print(f"  {sy:3d}  {x[0]:+.4f}  {x[1]:+7.3f}  {np.sqrt(f):6.2f}  {np.mean(e):+5.2f}  ({np.mean(err([0.0, 0.0])[1]):+6.2f})")
    bias, gain = [fit[sy][0] for sy in SYMS], [fit[sy][1] for sy in SYMS]
    print(f"  sym_bias = {bias}\n  sym_gain_db = {gain}")
    moved = (max(abs(a - b) for a, b in zip(bias, cal["sym_bias"])) > 0.005
             or max(abs(a - b) for a, b in zip(gain, cal["sym_gain_db"])) > 0.1)
    if write and moved:
        ct.set_values("distortion", {"sym_bias": bias, "sym_gain_db": gain},
                      f"calibrate.py dist --sym {rec['name']}, {datetime.now():%Y-%m-%d}")
        print("wrote [distortion] sym_bias, sym_gain_db and calib.inc")
    elif write:
        print("nothing to write: within 0.005 of bias and 0.1 dB of gain at every SYM")


def run_sym(dev, args):
    stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    session = f"calsym_{stamp}"
    rows = []
    dists = [int(v) for v in args.dists.split(",")]
    try:
        for slot in slots(args.patterns):
            dev.pattern(slot)
            for d in dists:
                for sy in SYMS:
                    dev.set({**FIXED, "DELAY": 0, "REVERB": 0, "MIX": 0, "VOL": 127, "MUP": PRESAT,
                             "DIST": d, "SYM": sy})
                    x = dev.capture(args.seconds)
                    stem = save(x, session, stem=f"{session}_{pattern_name(slot)}_d{d}_s{sy}", slim=True)
                    rows.append({"pattern": slot, "dist": d, "sym": sy, "stem": stem})
                    print(f"{pattern_name(slot)} DIST {d:3d} SYM {sy:3d}  {stem}", flush=True)
    finally:
        write_session(session, {"patterns": args.patterns, "rows": rows})
        dev.set({"DIST": 0, "SYM": 64, "MUP": 0})
        print(f"session {session}; left DIST 0, SYM 64, MUP 0 and MIX 0")
    sym_report(load_session(session), args.write)
    return session


def run_dist(dev, args):
    stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    session = f"caldist_{stamp}"
    rows = []
    try:
        for slot in slots(args.patterns):
            dev.pattern(slot)
            for d in DISTS:
                dev.set({**FIXED, "DELAY": 0, "REVERB": 0, "MIX": 0, "VOL": 127, "MUP": PRESAT,
                         "DIST": d, "SYM": 64})
                x = dev.capture(args.seconds)
                lvl = 20 * np.log10(np.maximum(np.sqrt(np.mean(x ** 2, axis=0)), 1e-12))
                check_voices(lvl, f"{pattern_name(slot)} DIST {d}")
                stem = save(x, session, stem=f"{session}_{pattern_name(slot)}_d{d}", slim=True)
                rows.append({"pattern": slot, "dist": d, "stem": stem})
                print(f"{pattern_name(slot)} DIST {d:3d}  {stem}", flush=True)
    finally:
        write_session(session, {"patterns": args.patterns, "rows": rows})
        dev.set({"DIST": 0, "MUP": 0})
        print(f"session {session}; left DIST 0, MUP 0 and MIX 0")
    dist_report(load_session(session), args.write)
    return session
