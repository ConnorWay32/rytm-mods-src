"""The tone stages of sitting 2: the sidechain sweep, the grids and the release
steps on the tone track's self-oscillating filter, and their fits."""
import contextlib
import time
from datetime import datetime
from pathlib import Path

import numpy as np

import calframes as cf
import calib_tables as ct
import fit_sidechain as fsc
import stub_model as sm

from cal_io import (
    FIXED, FS, block_gr, load, load_session, ran_on, save, side_peaks, sides_current, wet_q,
    write_session)
from cal_io import track_slot


def settled_level(dev, timeout=10.0, tol=0.25):
    """Wait until the device's level stops moving - track level lags seconds
    behind its CC, and a self-oscillating filter builds up over seconds from
    silence - and return it, dB. Two readbacks in a row within tol, above the
    silence gate: silence before a tone has built is not a settled tone."""
    t0, last = time.time(), None
    floor = sm.constants()["SILENCE_Q8"] / 256
    while True:
        _, c = dev.readback(0.4)
        now = float(np.median(c.rec["level"][~c.rec["aside"]])) / 256
        if last is not None and abs(now - last) < tol and now > floor:
            return now, c
        if time.time() - t0 > timeout:
            raise SystemExit(f"the level did not settle in {timeout:g} s ({last:+.1f} -> {now:+.1f} dB)")
        last = now


# The tone track, set up before each tone stage (re/subsystems/midi-cc.md): an
# LP2 filter with no envelope or LFO on it, the amp opening at once and holding
# while the note is held, and no delay or reverb send.
TONE_SETUP = {76: 0,               # Filter Mode: LP2
              77: 64,              # Filter Env Depth: 0 (-64 .. +63)
              109: 64,             # LFO Depth: 0
              78: 0,               # Amp Attack
              79: 127,             # Amp Hold: the longest
              82: 0, 83: 0}        # Amp Delay Send, Amp Reverb Send
KICK_CUTOFF = 80                   # CC 74 the oscillation is started at


@contextlib.contextmanager
def resonant_tone(dev, track, cutoff):
    """The track's filter self-oscillating - resonance 127, a note held - which
    is a sine at the cutoff (CC 74), the sample all but gone."""
    # Spaced as every other CC the tools send: sent back to back, the Rytm dropped
    # some of them after a run of pattern changes, and the filter never
    # oscillated (test run, 2026-09-25).
    trcc = lambda n, v: dev.track_cc(track, n, v)
    note = lambda on: dev.note(track, on)
    loud = lambda x: np.sqrt(np.mean(x[:, 2 + slot] ** 2)) > 10 ** (-60 / 20)
    slot = track_slot(track)
    # The oscillation is kick-started: the note is played with the cutoff at
    # KICK_CUTOFF, where the hit excites the filter hard and the oscillation
    # builds at once, and the cutoff then moves to where it is wanted. Started at
    # 92 Hz it built over seconds, or never, in 1 trial in 8 (test run,
    # 2026-09-25). Each attempt counts only if the voice is still sounding a
    # second later.
    for attempt in range(3):
        if attempt:
            print(f"  tone: track {track} did not sustain; attempt {attempt + 1}", flush=True)
        for n, v in TONE_SETUP.items():
            trcc(n, v)
        trcc(75, 127)
        trcc(74, KICK_CUTOFF)
        dev.stream.drain(0.5)
        note(True)
        dev.stream.drain(0.3)
        if cutoff is not None:
            trcc(74, cutoff)
        dev.stream.drain(0.7)
        if loud(dev.capture(0.3)):
            dev.stream.drain(1.0)
            if loud(dev.capture(0.3)):
                break
        note(False)
    else:
        raise SystemExit(f"track {track} did not sustain a tone for its note, three times over")
    try:
        yield lambda v: trcc(74, v)
    finally:
        note(False)
        trcc(75, 0)


def run_grid(dev, args):
    """Per ratio and track level: one capture of the tone at THR 127 kept (the
    level does not depend on THR), then the ratio of the model's input to MAIN at
    each THR. The reduction and each level are worked out at fit time."""
    ratios, levels, thrs = ([int(v) for v in a.split(",")] for a in (args.ratios, args.levels, args.thresholds))
    session = f"calgrid_{datetime.now().strftime('%Y%m%d_%H%M%S')}"
    blocks, rows = [], []
    dev.cc("PAN", 64)
    dev.set({**{k: v for k, v in FIXED.items()}, "DELAY": 0, "REVERB": 0, "DIST": 0,
             "ATK": 0, "REL": 0, "MUP": 0, "VOL": 127, "MIX": 127, "SEQ": args.seq, "THR": 127})
    print(f"grid: SEQ {args.seq}, {len(ratios) * len(levels) * len(thrs)} points", flush=True)
    tone = resonant_tone(dev, args.track, args.cutoff) if args.cutoff is not None else contextlib.nullcontext()
    try:
        with tone:
            for rat in ratios:
                dev.set({"RAT": rat})
                for lc in levels:
                    # THR back to 127 first: the last block leaves it low, and the
                    # reduction it would apply is no part of settling the level.
                    dev.set({"THR": 127})
                    dev.cc("LEVEL", lc)
                    lvl, _ = settled_level(dev)
                    x = dev.capture(args.seconds)
                    c = cf.decode(x)
                    a, b = (np.sqrt(np.mean(v ** 2)) * cf.MAIN_PER_SIDE for v in (c.side_l, c.side_r))
                    if max(a, b) < 10 ** (-70 / 20):
                        raise SystemExit(f"the model's input is silent at track level {lc} - is the tone "
                                         f"playing on track {args.track}?")
                    if abs(20 * np.log10(a / b)) > 0.5:
                        raise SystemExit(f"the input's L and R differ by {20 * np.log10(a / b):+.2f} dB - the "
                                         "tone is not centred, or something else is playing")
                    stem = save(x, session, stem=f"{session}_rat{rat}_lvl{lc}", slim=True)
                    blocks.append({"rat": rat, "level_cc": lc, "stem": stem})
                    for t in thrs:
                        dev.set({"THR": t})
                        dev.stream.drain(args.settle)
                        c = cf.decode(dev.capture(args.seconds))
                        rows.append({"rat": rat, "level_cc": lc, "thr": t, "ratio_db": round(ratio_db(c), 3),
                                     "device_level_db": round(float(np.median(c.rec["level"][~c.rec["aside"]])) / 256, 3)})
                    print(f"  rat{rat} lvl{lc}: level {lvl:+.1f} dB, THR {thrs[0]}..{thrs[-1]} ratio "
                          f"{rows[-len(thrs)]['ratio_db']:+.2f} .. {rows[-1]['ratio_db']:+.2f} dB", flush=True)
    finally:
        write_session(session, {"seq": args.seq, "cutoff": args.cutoff, "blocks": blocks, "rows": rows})
        dev.set({"THR": 127})
        print(f"session {session}: {len(rows)} points")
    grid_report(load_session(session))
    return session


def tone_level(c, seq, C):
    """A steady tone's level under C, dB: the median over the capture's longest
    run, past the filters' start, of to_db, CAL_Q8 and the row's offset."""
    s = max(cf.runs(c), key=lambda r: r.stop - r.start)
    pk = side_peaks(c, s, seq, C)[20:]
    return float(np.median(sm.level(sm.peak_q31(pk), seq, 64 << 8, C))) / 256


def grid_data(rec, C=None):
    """-> [{rat, level_cc, thr, level_db, gr}] of a grid session under C (the
    current twin by default): each block's level from its capture, and the
    reduction as the ratio against the no-reduction ratio at that track level.
    That is the median of the THR 127 readings the curve says do not compress
    (under 0.05 dB), across ratios; where none qualify, the median of those at
    every level - the input model's ratio does not depend on the level."""
    C = C or sm.constants()
    sides_current(rec)
    seq = rec["seq"]
    level = {(b["rat"], b["level_cc"]): tone_level(cf.decode(load(b["stem"])), seq, C) for b in rec["blocks"]}
    clean = {}
    for r in rec["rows"]:
        L = level[r["rat"], r["level_cc"]]
        if r["thr"] == 127 and sm.static_gr(int(round(L * 256)), 127, r["rat"], seq, C) < 13:
            clean.setdefault(r["level_cc"], []).append(r["ratio_db"])
    if not clean:
        raise SystemExit(f"{rec['name']}: no THR 127 reading the curve says is free of reduction")
    every = float(np.median([v for vs in clean.values() for v in vs]))
    ref = {lc: float(np.median(clean[lc])) if lc in clean else every for lc in {r["level_cc"] for r in rec["rows"]}}
    spread = [v for lc, v in ref.items() if lc in clean]
    print(f"{rec['name']}: no-reduction ratio {min(spread):+.2f} .. {max(spread):+.2f} dB across track levels"
          + (f"; levels {sorted(lc for lc in ref if lc not in clean)} take the median" if len(clean) < len(ref) else ""))
    return [{"rat": r["rat"], "level_cc": r["level_cc"], "thr": r["thr"], "seq": seq,
             "level_db": level[r["rat"], r["level_cc"]], "gr": r["ratio_db"] - ref[r["level_cc"]]}
            for r in rec["rows"]]


def grid_report(rec, against=None):
    C = sm.constants()
    rows = grid_data(rec, C)
    rms = lambda e: float(np.sqrt(np.mean(np.square(e))))
    e = np.array([sm.static_gr(int(round(r["level_db"] * 256)), r["thr"], r["rat"], r["seq"], C) / 256 - r["gr"]
                  for r in rows])
    print(f"{rec['name']}: {len(rows)} points; the current curve minus measured")
    print(f"  all      rms {rms(e):.2f} dB, mean {e.mean():+.2f}")
    for key in ("rat", "level_cc"):
        for v in sorted({r[key] for r in rows}, reverse=True):
            k = np.array([r[key] == v for r in rows])
            print(f"  {key} {v:3d}  rms {rms(e[k]):.2f}, mean {e[k].mean():+.2f}  (level "
                  f"{np.median([r['level_db'] for r in np.array(rows)[k]]):+.1f} dB)" if key == "level_cc" else
                  f"  {key} {v:3d}  rms {rms(e[k]):.2f}, mean {e[k].mean():+.2f}")
    if against:
        import csv
        old = list(csv.DictReader(open(against)))
        ref = {}
        for r in old:
            if r["thr"] == "127":
                ref[r["level_cc"]] = min(ref.get(r["level_cc"], 1e9), float(r["ratio_db"]))
        g = {(int(r["rat"]), int(r["level_cc"]), int(r["thr"])): float(r["ratio_db"]) - ref[r["level_cc"]] for r in old}
        d = np.array([r["gr"] - g[(r["rat"], r["level_cc"], r["thr"])] for r in rows
                      if (r["rat"], r["level_cc"], r["thr"]) in g])
        print(f"  against {Path(against).name}: {len(d)} shared points, measured GR differs "
              f"rms {rms(d):.2f} dB, mean {d.mean():+.2f}")


def tone_hz(c):
    """The tone's frequency from the model's L side, 24 kHz."""
    x = c.side_l.ravel()
    f = np.fft.rfftfreq(len(x), 1 / 24000)
    S = np.abs(np.fft.rfft(x * np.hanning(len(x))))
    k = int(np.argmax(S[3:])) + 3
    if 0 < k < len(S) - 1:                             # parabolic peak interpolation
        a, b, d = np.log(S[k - 1:k + 2] + 1e-30)
        k = k + 0.5 * (a - d) / (a - 2 * b + d)
    return float(k * 24000 / len(x))


def invert_curve(gr_db, thr, rat, C):
    """The level, dB, at which the stub's curve gives gr_db at thr and rat."""
    lo, hi = -200 * 256, 100 * 256
    t = gr_db * 256
    while hi - lo > 1:
        m = (lo + hi) // 2
        if sm.static_gr(m, thr, rat, 0, C) >= t:
            hi = m
        else:
            lo = m
    return hi / 256


def ratio_db(c):
    """Model input (L + R) over MAIN (L + R), dB, over the blocks where it ran."""
    ran = ~c.rec["aside"]
    inp = cf.MAIN_PER_SIDE * (c.side_l + c.side_r)[ran]
    o = (c.main[:, :, 0] + c.main[:, :, 1])[ran]
    return 20 * np.log10(np.sqrt(np.mean(inp ** 2)) / np.sqrt(np.mean(o ** 2)))


SC_CCS = tuple(range(16, 124, 4))


SC_TARGET_GR = 12.0


def run_sidechain(dev, args):
    C = sm.constants()
    stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    session = f"calsc_{stamp}"
    rows = []
    rat = 0
    knee, width, recip, slope = C["rattab"][0:4]
    dev.set({**FIXED, "DELAY": 0, "REVERB": 0, "DIST": 0, "SYM": 64, "ATK": 0, "REL": 0, "MUP": 0,
             "VOL": 127, "MIX": 127, "RAT": rat, "THR": 127})
    try:
        with resonant_tone(dev, args.track, None) as cutoff:
            for seq in range(4):
                dev.set({"SEQ": seq})
                for v in SC_CCS:
                    cutoff(v)
                    dev.set({"THR": 127})
                    dev.stream.drain(0.4)
                    ref = cf.decode(dev.capture(args.seconds))
                    lm = float(np.median(ref.rec["level"][~ref.rec["aside"]])) / 256
                    # THR for about SC_TARGET_GR on the straight part of the curve
                    u = SC_TARGET_GR / (slope / 4096)
                    thr = int(round(64 + (lm - knee / 256 - u) / (C["THR_K"] / 4096)))
                    thr = max(0, min(126, thr))
                    dev.set({"THR": thr})
                    dev.stream.drain(0.4)
                    c = cf.decode(dev.capture(args.seconds))
                    row = {"seq": seq, "cc": v, "hz": tone_hz(ref), "thr": thr,
                           "ref_ratio": ratio_db(ref), "ratio": ratio_db(c),
                           "ref_level": lm, "level": float(np.median(c.rec["level"][~c.rec["aside"]])) / 256,
                           "ref_demand": float(np.median(ref.rec["demand"])) / 256,
                           "demand": float(np.median(c.rec["demand"])) / 256}
                    rows.append(row)
                    print(f"SEQ {seq} {row['hz']:7.1f} Hz  THR {thr:3d}  model {row['demand']:5.1f} dB"
                          f"  measured {row['ratio'] - row['ref_ratio']:5.1f} dB", flush=True)
    finally:
        write_session(session, {"rows": rows})
        dev.set({"THR": 127, "SEQ": 0})
        print(f"session {session}; left THR 127, SEQ OFF, the track's resonance 0")
    sidechain_fit(load_session(session), False)
    return session


BLOCKS_PER_S = FS / cf.BLOCK


REL_STEP_DB = 6.0          # a level drop this deep within REL_STEP_BLOCKS: a step down


REL_STEP_BLOCKS = 40


def run_release(dev, args):
    """Per REL: the track's tone stepped between a loud and a quiet level, THR set
    so the loud level is reduced by about 12 dB, captured without a break. The
    level is baked into the voice slot, so the model sees each step as the
    compressor does, and the tone never stops, so the release stays measurable to
    its end. A THR 127 capture at the loud level gives the wet path's gain."""
    C = sm.constants()
    session = f"calrel_{datetime.now().strftime('%Y%m%d_%H%M%S')}"
    rows = []
    knee, _, _, slope = C["rattab"][args.rat * 4:args.rat * 4 + 4]
    dev.set({**FIXED, "DELAY": 0, "REVERB": 0, "DIST": 0, "SYM": 64, "ATK": 0, "REL": 0, "MUP": 0,
             "VOL": 127, "MIX": 127, "RAT": args.rat, "SEQ": 0, "THR": 127})
    dev.cc("PAN", 64)
    ref = None
    try:
        with resonant_tone(dev, args.track, args.cutoff):
            dev.cc("LEVEL", args.loud)
            lvl, _ = settled_level(dev)
            x = dev.capture(args.seconds)
            ref = save(x, session, stem=f"{session}_ref", slim=True)
            thr = int(round(64 + (lvl - knee / 256 - SC_TARGET_GR / (slope / 4096)) / (C["THR_K"] / 4096)))
            thr = max(0, min(126, thr))
            dev.set({"THR": thr})
            for rel in range(8):
                dev.set({"REL": rel})
                dev.cc("LEVEL", args.loud)
                dev.stream.drain(args.hold)
                dev.flush()
                parts = []
                for i in range(2 * args.cycles):
                    dev.cc("LEVEL", args.quiet if i % 2 == 0 else args.loud)
                    part = dev.stream.read(args.hold)
                    if part is None:
                        raise SystemExit("the capture overran")
                    parts.append(part)
                stem = save(np.concatenate(parts), session, stem=f"{session}_rel{rel}", slim=True)
                rows.append({"rel": rel, "stem": stem})
                print(f"REL {rel}: {stem}", flush=True)
    finally:
        write_session(session, {"rat": args.rat, "thr": thr if ref else None, "ref": ref, "rows": rows,
                                "loud": args.loud, "quiet": args.quiet})
        dev.set({"THR": 127, "REL": 0})
        dev.cc("LEVEL", args.loud)
        print(f"session {session}; left THR 127, REL 0, the track at level {args.loud}")
    release_fit(load_session(session), args.write)
    return session


def release_segments(c):
    """-> [(start, stop)] blocks: from each step down in the device's level to the
    next step up, or the capture's end."""
    lv = c.rec["level"] / 256
    d = lv[REL_STEP_BLOCKS:] - lv[:-REL_STEP_BLOCKS]
    down = np.nonzero((d[1:] < -REL_STEP_DB) & (d[:-1] >= -REL_STEP_DB))[0] + REL_STEP_BLOCKS
    up = np.nonzero((d[1:] > REL_STEP_DB) & (d[:-1] <= REL_STEP_DB))[0] + REL_STEP_BLOCKS
    out = []
    for s in down:
        s0 = s - REL_STEP_BLOCKS            # where the drop began
        nxt = up[up > s]
        out.append((s0, int(nxt[0]) - REL_STEP_BLOCKS if len(nxt) else len(lv)))
    return out


RELEASE_LO, RELEASE_HI = 5, 3000         # reltab_q16's scan
RELEASE_GAIN_DB = 0.05                     # the improvement a new value must show


def release_fit(rec, write=False):
    """reltab per REL: the stub's ballistics run on the device's own demand with a
    candidate release coefficient, against the measured reduction over each
    release segment. The measured reduction is taken relative to the loud plateau
    just before each step, and the model's likewise, so a static-curve error in
    the plateau does not enter the release."""
    ran = ran_on(rec)[1]
    q = wet_q(cf.decode(load(rec["ref"])))
    cur = ct.load()["ballistics"]["reltab_q16"]
    new = list(cur)
    print(f"{rec['name']}: RAT {rec['rat']}, THR {rec['thr']}, level {rec['loud']} / {rec['quiet']}")
    for r in rec["rows"]:
        c = cf.decode(load(r["stem"]))
        meas, ok = block_gr(c, q)
        t = c.rec["demand"].astype(np.int64)
        segs = release_segments(c)
        if not segs:
            print(f"  REL {r['rel']}: no step down found: held")
            continue
        pre = 50                                 # plateau blocks before each step

        def err(coef):
            g = sm.ballistics_raw(t, 256, ran["atktab"][0], int(round(coef)))
            e = []
            for s0, s1 in segs:
                if s0 < pre:
                    continue
                k = slice(s0, s1)
                okk = ok[k]
                off = np.median((g[s0 - pre:s0] - meas[s0 - pre:s0])[ok[s0 - pre:s0]])
                e.append((g[k] - meas[k] - off)[okk])
            e = np.concatenate(e) if e else np.array([0.0])
            return float(np.sqrt(np.mean(e ** 2)))
        # A scan, not a bounded 1-D minimiser: the error is flat and noisy over much
        # of the range, and the minimiser settled at the bound with a worse error
        # than the current value (test run, 2026-09-25). A value is proposed only
        # if it beats the current one by RELEASE_GAIN_DB and is not at the scan's
        # edge.
        grid = np.unique(np.round(np.geomspace(RELEASE_LO, RELEASE_HI, 120)).astype(int))
        errs = np.array([err(g) for g in grid])
        best = int(grid[np.argmin(errs)])
        now = err(cur[r["rel"]])
        edge = best in (grid[0], grid[-1])
        better = errs.min() < now - RELEASE_GAIN_DB and not edge
        print(f"  REL {r['rel']}: {len(segs)} releases  best {best:4d}, rms {errs.min():.2f} dB;"
              f" now {cur[r['rel']]}, rms {now:.2f}"
              + ("" if better else "  - held: " + ("at the scan's edge" if edge else "no better than now")))
        if better:
            new[r["rel"]] = best
    moved = [i for i, (a, b) in enumerate(zip(new, cur)) if abs(a - b) > 0.05 * b]
    print(f"  reltab_q16 = {new}   (now {cur})")
    if write and moved:
        ct.set_values("ballistics", {"reltab_q16": new}, f"calibrate.py release {rec['name']}, {datetime.now():%Y-%m-%d}")
        print("wrote [ballistics] reltab_q16 and calib.inc")
    elif write:
        print("nothing to write: every REL within 5%")


def sidechain_report(rows):
    """Per SEQ and frequency: the level the hardware's detector saw - the measured
    reduction through the curve - against the model's, dB."""
    C = sm.constants()
    names = ("OFF", "LPF", "HPF", "HIT")
    err = {}
    for r in rows:
        gr = r["ratio"] - r["ref_ratio"]
        if r["ref_demand"] > 0.3 or gr < 2:
            continue                                   # the reference compressed, or too little to invert
        err.setdefault(r["seq"], []).append((r["hz"], invert_curve(gr, r["thr"], 0, C) - r["level"]))
    print("hardware detector level - model level, dB (+ = the hardware's sidechain passes more)")
    for q, v in sorted(err.items()):
        v.sort()
        print(f"  {names[q]}: " + "  ".join(f"{hz:.0f}:{e:+.1f}" for hz, e in v))
    return err


def sidechain_fit(rec, write):
    """The sweep's errors, then two sections and a level per SEQ fitted to the
    hardware's response they imply, from the rows the sweep's image ran."""
    session = rec["name"]
    sctab = ran_on(rec)[1]["sctab"]
    err = sidechain_report(rec["rows"])
    sc = ct.load()["sidechain"]
    secs, level, resid = fsc.fit_sweep(err, sctab, FS / sm.constants()["DECIM"])
    print("fitted, points under %d Hz (rms, max residual dB):" % fsc.FIT_BELOW_HZ)
    for s in sorted(secs):
        print(f"  {fsc.NAMES[s]}: {[[round(p), round(z)] for p, z in secs[s]]}"
              f"  {np.sqrt(np.mean(resid[s] ** 2)):.2f}, {np.abs(resid[s]).max():.2f}")
    level = [round(v, 4) for v in level]
    print(f"  level_db {level}   (now {sc['level_db']}; transient_db {sc['transient_db']} is added)")
    if write:
        ct.set_values("sidechain", {**{fsc.KEYS[s]: secs[s] for s in secs}, "level_db": level},
                      f"calibrate.py sidechain on {session}, {datetime.now():%Y-%m-%d}")
        print("wrote [sidechain] sections and level_db, and calib.inc")
    else:
        print("rerun with --write to put them into calibration.toml")
