"""Drum-pattern suites, the device against the twin, the final verification on
random settings, and the run's report."""
import json
import re
import tomllib
from datetime import datetime
from pathlib import Path

import numpy as np

import calframes as cf
import calib_tables as ct
import stub_model as sm

from cal_io import (
    ATK_SEQ, FIXED, GR_BASE, GR_CONDITIONS, GR_EXTENDED, SEQ_THR, block_gr, check_voices, load,
    load_session, run_dir, save, seq_matrix, side_peaks, sides_current, slots, switched, wet_q,
    write_session)
from cal_io import pattern_name


# ---------------------------------------------------------------- reports
def summary(c):
    r = c.rec
    n = len(r["blk"])
    ran = ~r["aside"]
    load = r["run"][ran] / np.maximum(r["interval"][ran], 1)
    p = {k: int(np.bincount(r[k]).argmax()) for k in cf.PARAMS + ("DIST",)}
    print(f"  cal = {c.cal}: {n} blocks, {c.lost} lost, {c.bad} with a bad tag, "
          f"{100 * np.mean(r['aside']):.1f}% stood aside")
    print("  " + "  ".join(f"{k} {v}" for k, v in p.items()) + f"  SYM {int(np.median(r['SYM_raw'])) >> 8}")
    if ran.any():
        print(f"  run {100 * np.median(load):.2f}% of a block (max {100 * load.max():.2f}),"
              f" UI queue max {int(r['queue'].max())}, BgWorker max {int(r['bg'].max())}")


RESUME_BLOCKS = 100                # ~67 ms: the device's detector recovering after it stood aside


def twin_report(c):
    """The device against the twin, three ways."""
    C = sm.constants()
    r, ok = c.rec, ~c.rec["aside"]
    rms = lambda e: float(np.sqrt(np.mean(np.square(e)))) if len(e) else float("nan")

    # 1 The level from the detector's peak: to_db, CAL_Q8 and the row's offset.
    lvl = np.array([sm.to_db(int(pk), C["log2tab"]) + C["CAL_Q8"] + sm.sc_row(int(q), C)[1]
                    + sm.sym_gain(sy, C) for pk, q, sy in zip(r["peak"], r["SEQ"], r["SYM_raw"])])
    e1 = (lvl - r["level"])[ok]
    print(f"  level from the peak      {np.sum(e1 != 0)} of {len(e1)} blocks differ (max {int(np.abs(e1).max()) if len(e1) else 0} Q8)")

    # 2 The demand from the level: the gate, the curve and the slow-attack scale.
    dem = np.zeros(len(r["blk"]), dtype=np.int64)
    for i in np.nonzero(ok)[0]:
        if r["level"][i] > C["SILENCE_Q8"]:
            t = sm.static_gr(int(r["level"][i]), int(r["THR"][i]), int(r["RAT"][i]), int(r["SEQ"][i]), C)
            sc = C["atkscale"][(int(r["ATK"][i]) * 8 + int(r["REL"][i])) * 4 + int(r["RAT"][i])] + 1
            off = C["seqatk"][int(r["SEQ"][i]) * 7 + int(r["ATK"][i])] << 4
            dem[i] = max(0, ((t * sc) >> 8) - off)
    e2 = (dem - r["demand"])[ok]
    print(f"  demand from the level    {np.sum(e2 != 0)} of {len(e2)} blocks differ (max {int(np.abs(e2).max()) if len(e2) else 0} Q8)")

    # 3 The gain reduction from the demand and the last block's: the ballistics.
    diffs, n3 = 0, 0
    for s in cf.runs(c):
        for i in range(s.start + 1, s.stop):
            if not (ok[i] and ok[i - 1]):
                continue
            st, tg = int(r["gr"][i - 1]), int(r["demand"][i])
            atk, rel = int(r["ATK"][i]), int(r["REL"][i])
            st = sm.step(st, tg, C["atktab"][min(atk, 7)], C["reltab"][rel])
            diffs += st != r["gr"][i]
            n3 += 1
    print(f"  GR from the demand       {diffs} of {n3} block steps differ")

    # 4 The detector's peak from the sides: the sidechain and the peak follower,
    # run by the twin in floating point, so close rather than exact. Not on the
    # blocks the estimator stood aside, when the device's detector is frozen and
    # the twin's runs on, nor the RESUME_BLOCKS after, while the device's recovers
    # from the value it froze at: those read up to 10 dB apart and are no model
    # error.
    live = ok.copy()
    for i in np.nonzero(r["aside"])[0]:
        live[i:i + RESUME_BLOCKS] = False
    e4 = []
    for s in cf.runs(c):
        if s.stop - s.start < 40 or c.cal != 1:
            continue
        q = int(np.bincount(r["SEQ"][s]).argmax())
        pk = side_peaks(c, s, q, C) * 2 ** 31
        dev = r["peak"][s].astype(float)
        use = (live[s] & (dev > 2 ** 31 * 1e-4))[20:]        # past the filters' start
        e4.append(20 * np.log10(pk[20:][use] / dev[20:][use]))
    e4 = np.concatenate(e4) if e4 else np.array([])
    print(f"  peak from the sides      {rms(e4):.3f} dB rms, mean {np.mean(e4) if len(e4) else float('nan'):+.3f}"
          + ("" if c.cal == 1 else "  (not with MUP set: the sides are before the saturation)"))

    # 5 The input model against MAIN, per side, on blocks with signal.
    scale = cf.MAIN_PER_SIDE
    for name, side, m in (("L", c.side_l, c.main[:, :, 0]), ("R", c.side_r, c.main[:, :, 1])):
        a = np.sqrt(np.mean((scale * side) ** 2, axis=1))
        b = np.sqrt(np.mean(m ** 2, axis=1))
        use = ok & (b > 10 ** (-40 / 20))
        if c.cal != 1 or not use.any():
            print(f"  input null {name}             (no signal above -40 dBFS, or MUP set)")
            continue
        e = 20 * np.log10(a[use] / b[use])
        print(f"  input null {name}             median {np.median(e):+.2f} dB, p5 {np.percentile(e, 5):+.2f}, "
              f"p95 {np.percentile(e, 95):+.2f} ({use.sum()} blocks)")


def conditions(args):
    if args.sym:
        # DIST symmetry at a fixed operating point, per DIST: THR 90, RAT 2, SEQ LPF
        syms = [int(v) for v in args.sym.split(",")]
        dists = [int(v) for v in args.sym_dist.split(",")]
        return [(f"sym{sy}_d{d}", {"THR": 90, "RAT": 2, "SEQ": 1, "DIST": d, "SYM": sy})
                for d in dists for sy in syms]
    if getattr(args, "atk_seq", False):
        return ATK_SEQ
    if args.seq_matrix:
        thrs = tuple(int(v) for v in args.thr.split(",")) if args.thr else SEQ_THR
        return seq_matrix([int(v) for v in args.seq_matrix.split(",")], thrs)
    return GR_EXTENDED if args.extended else GR_CONDITIONS


def run_suite(dev, args):
    stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    session = f"calsuite_{stamp}"
    base = {**{k: v for k, v in FIXED.items()}, **GR_BASE}
    rows, prev = [], None
    try:
        for slot in slots(args.patterns):
            dev.pattern(slot)
            dev.set({**base, "SEQ": 0, "THR": 127, "RAT": 2})
            x = dev.capture(args.seconds)
            lvl = 20 * np.log10(np.maximum(np.sqrt(np.mean(x ** 2, axis=0)), 1e-12))
            check_voices(lvl, f"{pattern_name(slot)} ref")
            prev = switched(prev, lvl, f"{pattern_name(slot)} ref")
            stem = save(x, session, stem=f"{session}_{pattern_name(slot)}_ref", slim=True)
            q = wet_q(cf.decode(x))
            rows.append({"pattern": slot, "condition": "ref", "stem": stem, "q_db": 20 * np.log10(q)})
            for name, cond in conditions(args):
                dev.set({**base, **cond})
                x = dev.capture(args.seconds)
                stem = save(x, session, stem=f"{session}_{pattern_name(slot)}_{name}", slim=True)
                c = cf.decode(x)
                meas, ok = block_gr(c, q)
                e = (c.rec["gr"] / 256 - meas)[ok]
                rows.append({"pattern": slot, "condition": name, "stem": stem,
                             "rms": float(np.sqrt(np.mean(e ** 2))), "mean": float(np.mean(e)),
                             "lost": c.lost, "aside": float(np.mean(c.rec["aside"]))})
                print(f"{pattern_name(slot)} {name:14s} rms {rows[-1]['rms']:5.2f}  mean {rows[-1]['mean']:+5.2f}"
                      f"  measured {np.median(meas[ok]):5.1f}  device {np.median(c.rec['gr'][ok]) / 256:5.1f}"
                      + (f"  {c.lost} lost" if c.lost else ""), flush=True)
    finally:
        write_session(session, {"patterns": args.patterns, "base": {str(k): v for k, v in base.items()}, "rows": rows})
        dev.set({"MIX": 0, "THR": 127, "DIST": 0, "SYM": 64})
        print(f"session {session}; left MIX 0, THR 127, DIST 0 and SYM 64")
    return session


def session_blocks(session):
    """-> [(row, Capture, measured GR, ok)] for every condition of a session."""
    rec = load_session(session)
    sides_current(rec)
    q = {r["pattern"]: 10 ** (r["q_db"] / 20) for r in rec["rows"] if r["condition"] == "ref"}
    out = []
    for r in rec["rows"]:
        if r["condition"] == "ref":
            continue
        c = cf.decode(load(r["stem"]))
        meas, ok = block_gr(c, q[r["pattern"]])
        out.append((r, c, meas, ok))
    return out


def score(session):
    rms = lambda e: float(np.sqrt(np.mean(e ** 2)))
    f = lambda e: f"{rms(e):5.2f} ({e.mean():+5.2f})"
    got = session_blocks(session)
    print(f"{session}: {len(got)} captures; device GR - measured, per block, rms (mean) dB")
    for q in range(4):
        sub = [(r, c, m, ok) for r, c, m, ok in got if int(np.median(c.rec["SEQ"])) == q]
        if not sub:
            continue
        e = np.concatenate([(c.rec["gr"] / 256 - m)[ok] for r, c, m, ok in sub])
        print(f"  {('OFF', 'LPF', 'HPF', 'HIT')[q]}  {len(sub):4d}  {f(e)}")
        for t in sorted({int(np.median(c.rec["THR"])) for r, c, m, ok in sub}, reverse=True):
            et = np.concatenate([(c.rec["gr"] / 256 - m)[ok] for r, c, m, ok in sub
                                 if int(np.median(c.rec["THR"])) == t])
            print(f"        THR {t:3d}  {f(et)}")
    # DIST symmetry conditions, one line each.
    symc = sorted({r["condition"] for r, c, m, ok in got if re.fullmatch(r"sym\d+_d\d+", r["condition"])},
                  key=lambda k: tuple(int(v) for v in re.findall(r"\d+", k))[::-1])
    if symc:
        print("  DIST symmetry, device - measured")
        for cond in symc:
            e = np.concatenate([(c.rec["gr"] / 256 - m)[ok] for r, c, m, ok in got if r["condition"] == cond])
            med = np.median(np.concatenate([m[ok] for r, c, m, ok in got if r["condition"] == cond]))
            print(f"    {cond:12s} {f(e)}   measured GR median {med:5.1f} dB")
    # ATK and REL against their baseline, THR 80 at ATK 0, REL 0, the same SEQ and
    # RAT: that is what judges atkscale and reltab, since a curve offset shows in
    # the baseline too.
    by = {}
    for r, c, m, ok in got:
        by.setdefault(r["condition"], []).append((c, m, ok))
    med = lambda c, k: int(np.median(c.rec[k]))
    base = {}
    for cond, v in by.items():
        c = v[0][0]
        if med(c, "THR") == 80 and med(c, "ATK") == 0 and med(c, "REL") == 0:
            base[(med(c, "SEQ"), med(c, "RAT"))] = np.concatenate([(c.rec["gr"] / 256 - m)[ok] for c, m, ok in v]).mean()
    dyn = [k for k, v in by.items() if med(v[0][0], "ATK") or med(v[0][0], "REL")]
    if dyn:
        print("  ATK and REL, device - measured; rel = against the THR 80 baseline")
        for cond in sorted(dyn):
            v = by[cond]; c = v[0][0]
            e = np.concatenate([(c.rec["gr"] / 256 - m)[ok] for c, m, ok in v])
            b = base.get((med(c, "SEQ"), med(c, "RAT")))
            print(f"    {cond:14s} {f(e)}" + (f"   rel {e.mean() - b:+5.2f}" if b is not None else ""))


# ---------------------------------------------------------------- verification
# The final check: settings drawn at random, from a recorded seed, on patterns no
# fit has seen, each scored against the measured reduction. Two scorers: the
# device's own GR, and the twin running the current calibration.toml over the
# recorded sides - the same numbers when the device runs calib.inc, and the
# way a new calibration is judged before it is flashed. The sides depend only
# on [input] and [distortion], so the twin can score any curve, sidechain or
# ballistics on them.
VERIFY_DRAW = {                         # control: (low, high), both inclusive
    "THR": (40, 120), "RAT": (0, 3), "SEQ": (0, 3), "ATK": (0, 6), "REL": (0, 7),
    "DIST": (0, 127),
    # SYM held at 64: the symmetry model depends on SYM alone, fitted at DIST 64
    # and 96, and at low DIST reads 1 to 19 dB deep anywhere off 64 (test run,
    # 2026-09-25; compressor-model.md, Known limits).
    "SYM": (64, 64),
    "DELAY": (0, 127), "REVERB": (0, 127),
}


# Acceptance, dB. Set from the drum-pattern accuracy of 2026-09-24 (1.2 to 1.6
# rms, each SEQ's bias within 0.2) widened for settings those patterns never
# varied; revisit after the first full run.
ACCEPT_RMS = 2.0                        # overall rms


ACCEPT_BIAS = 0.5                       # overall mean


ACCEPT_GROUP_BIAS = 1.5                 # any one setting's mean, with 3 draws or more


SETTLE_BLOCKS = 50                      # the twin's detector and state settle


def twin_gr(c, C):
    """Per block, the GR the twin gives from the recorded sides under C, dB, and
    the blocks past each run's settling. Needs sides after the saturation (MUP 0).
    Each run starts from the device's GR at its first block: the compressor
    carries the last draw's reduction in, and a slow release takes seconds to
    let it go."""
    r = c.rec
    out = np.full(len(r["blk"]), np.nan)
    valid = np.zeros(len(r["blk"]), dtype=bool)
    for s in cf.runs(c):
        if s.stop - s.start <= SETTLE_BLOCKS:
            continue
        m = lambda k: int(np.median(r[k][s]))
        g = sm.gr_from_sides(c.side_l[s], c.side_r[s], m("SEQ"), m("THR"), m("RAT"), m("ATK"), m("REL"),
                             m("SYM_raw"), C, int(r["gr"][s.start]))
        n = min(len(g), s.stop - s.start)
        out[s.start:s.start + n] = g[:n]
        valid[s.start + SETTLE_BLOCKS:s.start + n] = True
    return out, valid


def draw_settings(rng):
    return {k: int(rng.integers(lo, hi + 1)) for k, (lo, hi) in VERIFY_DRAW.items()}


def run_verify(dev, args):
    seed = args.seed if args.seed is not None else int(np.random.SeedSequence().entropy % 2 ** 32)
    rng = np.random.default_rng(seed)
    pats = slots(args.patterns)
    session = f"calverify_{datetime.now().strftime('%Y%m%d_%H%M%S')}"
    base = {**FIXED, **{k: v for k, v in GR_BASE.items() if not isinstance(k, int)}}
    draws = [(int(rng.choice(pats)), draw_settings(rng)) for _ in range(args.draws)]
    rows = []
    try:
        for slot in pats:
            mine = [d for p, d in draws if p == slot]
            if not mine:
                continue
            dev.pattern(slot)
            dev.set({**base, "DELAY": 100, "REVERB": 100, "DIST": 0, "SYM": 64, "SEQ": 0, "THR": 127, "RAT": 2})
            x = dev.capture(args.seconds)
            lvl = 20 * np.log10(np.maximum(np.sqrt(np.mean(x ** 2, axis=0)), 1e-12))
            check_voices(lvl, f"{pattern_name(slot)} ref")
            stem = save(x, session, stem=f"{session}_{pattern_name(slot)}_ref", slim=True)
            q = wet_q(cf.decode(x))
            rows.append({"pattern": slot, "condition": "ref", "stem": stem, "q_db": 20 * np.log10(q)})
            for i, d in enumerate(mine):
                dev.set({**base, **d})
                x = dev.capture(args.seconds)
                name = f"v{len(rows):03d}"
                stem = save(x, session, stem=f"{session}_{pattern_name(slot)}_{name}", slim=True)
                rows.append({"pattern": slot, "condition": name, "stem": stem, "settings": d})
                print(f"{pattern_name(slot)} {name} " + " ".join(f"{k} {v}" for k, v in d.items()), flush=True)
    finally:
        last, _ = dev.readback()
        write_session(session, {"seed": seed, "patterns": args.patterns, "draws": args.draws,
                                "ranges": VERIFY_DRAW, "device_calhash": int(last["calhash"]), "rows": rows})
        dev.set({"MIX": 0, "THR": 127, "DIST": 0, "SYM": 64})
        print(f"session {session} (seed {seed}); left MIX 0, THR 127, DIST 0 and SYM 64")
    verify_report(session)
    return session


def verify_report(session):
    """Score a verify session: the device and the twin under the current
    calibration, each against the measured reduction. Writes verify.json and
    verify.md into the session's directory."""
    C = sm.constants()
    rec = load_session(session)
    per = []
    for r, c, meas, ok in session_blocks(session):
        tw, valid = twin_gr(c, C)
        use = ok & valid
        if use.sum() < 20:
            continue
        ed = c.rec["gr"][use] / 256 - meas[use]
        et = tw[use] - meas[use]
        per.append({"condition": r["condition"], "pattern": r["pattern"], "settings": r["settings"],
                    "n": int(use.sum()), "measured": float(np.median(meas[use])),
                    "device": [float(ed.sum()), float((ed ** 2).sum())],
                    "twin": [float(et.sum()), float((et ** 2).sum())]})
    if not per:
        raise SystemExit(f"{session}: no scorable blocks")

    def stat(rows, who):
        n = sum(p["n"] for p in rows)
        s1 = sum(p[who][0] for p in rows); s2 = sum(p[who][1] for p in rows)
        return n, s1 / n, float(np.sqrt(s2 / n))

    groups = {}
    bins = {"THR": 20, "DIST": 32, "SYM": 20, "DELAY": 32, "REVERB": 32}
    for p in per:
        for k, v in p["settings"].items():
            b = bins.get(k)
            label = f"{v // b * b}-{v // b * b + b - 1}" if b else str(v)
            groups.setdefault((k, label), []).append(p)
    lines = [f"# Verification {rec['name']}", "",
             f"Seed {rec['seed']}, {len(per)} draws on patterns {rec['patterns']}, "
             f"calibration {ct.inc_hash(ct.INC.read_text()):08x}. GR estimate minus measured, dB, per block.", ""]
    dh = rec.get("device_calhash")
    if dh is not None and dh != ct.inc_hash(ct.INC.read_text()):
        lines += [f"The device ran calibration {dh:08x}, written over since: its row scores that one. "
                  "The verdict is the twin's, on the current calibration.", ""]
    verdict = {}
    lines += ["| scorer | blocks | rms | mean |", "|---|---|---|---|"]
    for who in ("device", "twin"):
        n, mean, rms = stat(per, who)
        verdict[who] = {"rms": rms, "mean": mean, "rms_ok": rms <= ACCEPT_RMS, "mean_ok": abs(mean) <= ACCEPT_BIAS}
        lines.append(f"| {who} | {n} | {rms:.2f} | {mean:+.2f} |")
    lines += ["", "By setting (twin; groups of 3 draws or more):", "",
              "| setting | draws | rms | mean |", "|---|---|---|---|"]
    bad = []
    for (k, label), rows in sorted(groups.items(), key=lambda kv: (list(VERIFY_DRAW).index(kv[0][0]),
                                                                  int(kv[0][1].split("-")[0]))):
        if len(rows) < 3:
            continue
        n, mean, rms = stat(rows, "twin")
        flag = abs(mean) > ACCEPT_GROUP_BIAS
        bad += [f"{k} {label}"] if flag else []
        lines.append(f"| {k} {label} | {len(rows)} | {rms:.2f} | {mean:+.2f}{' **over**' if flag else ''} |")
    worst = sorted(per, key=lambda p: -abs(p["twin"][0] / p["n"]))[:5]
    lines += ["", "Worst draws (twin mean):", ""]
    for p in worst:
        lines.append(f"- {pattern_name(p['pattern'])} {p['condition']}: {p['twin'][0] / p['n']:+.2f} dB, measured GR "
                     f"{p['measured']:.1f}; " + ", ".join(f"{k} {v}" for k, v in p["settings"].items()))
    ok = verdict["twin"]["rms_ok"] and verdict["twin"]["mean_ok"] and not bad
    lines += ["", f"Acceptance (twin): rms <= {ACCEPT_RMS}, |mean| <= {ACCEPT_BIAS}, every setting's "
              f"|mean| <= {ACCEPT_GROUP_BIAS}: **{'PASS' if ok else 'FAIL'}**"
              + (f" - over: {', '.join(bad)}" if bad else ""), ""]
    text = "\n".join(lines)
    print(text)
    d = Path(rec["dir"])
    (d / "verify.md").write_text(text)
    (d / "verify.json").write_text(json.dumps({"verdict": verdict, "pass": ok, "over": bad, "draws": per}, indent=1))
    return ok


def run_report(publish):
    """The run's report.md: where it started, what the fits changed, the fit logs
    and the verification. --publish copies it beside calibration.toml."""
    d = run_dir()
    info = json.loads((d / "run.json").read_text())
    start = tomllib.loads(info["calibration"]["toml"])
    now = ct.load()
    lines = [f"# Calibration run {d.name}", "",
             f"Started {info['created']} at commit {info['commit']}; calibration "
             f"{info['calibration']['hash']:08x} -> {ct.inc_hash(ct.INC.read_text()):08x}.", "",
             "## Values changed", ""]
    notes = d / "notes.md"                        # the run's decisions, written by hand
    if notes.exists():
        lines[-2:-2] = ["## Notes", "", notes.read_text().strip(), ""]
    changed = [(sec, k) for sec in now for k in now[sec] if start.get(sec, {}).get(k) != now[sec][k]]
    lines += [f"- `[{sec}] {k}`: {start.get(sec, {}).get(k)} -> {now[sec][k]}" for sec, k in changed] or ["None."]
    lines += ["", "## Sessions", ""]
    for s in sorted(p for p in d.iterdir() if (p / "session.json").exists()):
        lines.append(f"- {s.name}")
    logs = sorted((d / "fits").glob("*.log")) if (d / "fits").exists() else []
    lines += ["", "## Fits", ""] + [f"- fits/{p.name}" for p in logs]
    # The latest verification in full; the earlier ones, each scored when it was
    # recorded, by name, calibration and verdict.
    ver = sorted(d.glob("calverify_*/verify.md"))
    lines += ["", "## Verification", ""]
    if not ver:
        lines.append("Not run.")
    for p in ver[:-1]:
        t = p.read_text()
        cal = re.search(r"calibration ([0-9a-f]{8})", t)
        verdict = re.search(r"\*\*(PASS|FAIL)\*\*.*", t)
        lines.append(f"- {p.parent.name}, calibration {cal.group(1) if cal else '?'}: "
                     f"{verdict.group(0) if verdict else 'no verdict'}")
    if ver:
        lines += ["" if len(ver) > 1 else "", ver[-1].read_text().replace("# Verification", "### Verification")]
    text = "\n".join(lines) + "\n"
    (d / "report.md").write_text(text)
    print(f"wrote {d / 'report.md'}")
    if publish:
        dest = ct.TOML.parent / "calibration_report.md"
        dest.write_text(text)
        print(f"published {dest.relative_to(ct.ROOT)}")
