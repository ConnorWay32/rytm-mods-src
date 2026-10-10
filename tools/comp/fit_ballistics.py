"""Fit mod 0006's ballistics on calibration suites: the slow-attack coupling behind
atkscale, and what the release table would want.

The data is an extended calibration suite (calibrate.py suite --extended): every
ATK at every stored RAT and every REL at RAT 2, at THR 80, SEQ LPF, each with a
THR 80 baseline at ATK 0, REL 0. Each capture's recorded sides go through the
current sidechain, detector and curve - the twin, exact to the device - and the
ballistics are the only thing varied. A setting is judged by its bias against the
baseline at the same ratio, which a curve offset cannot fake.

atkscale is the coupling form (compressor-model.md, stage 8),
    s = (1 + C (0.03 ms / rel)^p) / (1 + C (atk / rel)^p)
with C and p per stored ratio and an effective release time per REL setting
(calibration.toml, [ballistics]). The suite sweeps ATK at REL 0.1 s only, so it
fits C and p for the ratios it sweeps (suites before 2026-09-25 only RAT 2 and
3); the release times need ATK swept at every REL and are held. reltab is
reported, not written: REL 0.1 s comes from level-step data, and REL 0.2 s .. A2
were set by hand from this report (each REL's bias matched to the THR 80
baseline's, 2026-09-25).

    fit_ballistics.py --suite calsuite_...       fit and report, on an extended suite
    ... --holdout                                fit on the odd patterns, score on
                                                 the even; keep the ratios that improve
    ... [--holdout] --write                      put C and p into calibration.toml
                                                 (with --holdout, the kept ratios
                                                 only); atkscale is generated from them

The coupling is fitted at SEQ LPF. The HPF and HIT sidechains are more transient
and a slow attack loses more there, whatever the release: seq_atk_db takes
c * ATK / 6 dB off the demand per SEQ (seqatk), c the dB at ATK 6, fitted on an
ATK x SEQ suite (calibrate.py suite --atk-seq) so each ATK's bias matches its
SEQ's ATK 0 baseline, as the coupling does at LPF.

    fit_ballistics.py --seq-suite calsuite_...  [--holdout] [--write]
"""
import argparse
import pickle
from datetime import date

import numpy as np
from scipy.optimize import minimize, minimize_scalar

import calib_tables as ct
import cal_io as cio
import cal_suite as cs
import stub_model as sm


def load(session, C):
    """-> captures with the curve's per-block target under the current constants."""
    key = (4, session, C["CAL_Q8"], tuple(C["sctab"]), tuple(C["rattab"]), C["THR_K"], C["GR_CAP"])
    cache = cio.session_path(session) / "fit_ballistics.pkl"
    cio.sides_current(cio.load_session(session))
    if cache.exists():
        k, caps = pickle.load(open(cache, "rb"))
        if k == key:
            return caps
    caps = []
    for r, c, meas, ok in cs.session_blocks(session):
        med = lambda k: int(np.median(c.rec[k]))
        seq = med("SEQ")
        pk = sm.peaks_from_sides(c.side_l, c.side_r, seq, C)
        t = sm.targets(sm.level(sm.peak_q31(pk), seq, med("SYM_raw"), C), med("THR"), med("RAT"), C)
        n = min(len(t), len(meas))
        ok = ok[:n].copy(); ok[:20] = False
        caps.append(dict(cond=r["condition"], pattern=r["pattern"], rat=med("RAT"), atk=med("ATK"), rel=med("REL"),
                         seq=seq, t=t[:n], meas=meas[:n], ok=ok))
    pickle.dump((key, caps), open(cache, "wb"))
    return caps


def bias(caps, cond, scale, aa, ar, off=0):
    e = [sm.ballistics_raw(c["t"], scale, aa, ar, 0, off)[c["ok"]] - c["meas"][c["ok"]]
         for c in caps if c["cond"] == cond]
    return float(np.mean(np.concatenate(e))) if e else float("nan")


def scale_byte(C_, p, atk, rel):
    s = (1 + C_ * (3e-5 / rel) ** p) / (1 + C_ * (atk / rel) ** p)
    return int(min(255, max(0, round(s * 256 - 1)))) + 1


def seq_fit(args, C):
    """seq_atk_db per SEQ OFF, HPF, HIT on an ATK x SEQ suite; LPF stays 0."""
    caps = load(args.seq_suite, C)
    aa = [C["atktab"][min(a, 7)] for a in range(7)]
    ar0 = C["reltab"][0]
    held = list(ct.load()["ballistics"]["seq_atk_db"])
    rm = lambda v: float(np.sqrt(np.mean(np.square(v))))
    print(f"{args.seq_suite}: {len(caps)} captures; bias against each SEQ's ATK 0 baseline, dB")

    def biases(cs, q, k):
        out = []
        for rat in sorted({c["rat"] for c in cs if c["seq"] == q}):
            b0 = bias(cs, f"s{q}_atk0_rat{rat}", 256, aa[0], ar0)
            for a in sorted({c["atk"] for c in cs if c["seq"] == q and c["rat"] == rat and c["atk"]}):
                s1 = C["atkscale"][(a * 8) * 4 + rat] + 1
                off = ct.seqatk([k] * 4)[a] << 4
                out.append(bias(cs, f"s{q}_atk{a}_rat{rat}", s1, aa[a], ar0, off) - b0)
        return np.array(out)

    def fit(cs, q):
        return float(minimize_scalar(lambda k: rm(biases(cs, q, k)), bounds=(0.0, 12.0), method="bounded",
                                     options=dict(xatol=0.01)).x)

    new = list(held)
    seqs = sorted({c["seq"] for c in caps})
    keep = seqs
    if args.holdout:
        fit_on = [c for c in caps if c["pattern"] % 2 == 1]
        test = [c for c in caps if c["pattern"] % 2 == 0]
        print("hold-out: fitted on the odd patterns, scored on the even; bias rms over ATK and RAT")
        keep = []
        for q in seqs:
            k = fit(fit_on, q)
            now, got = rm(biases(test, q, held[q])), rm(biases(test, q, k))
            print(f"   SEQ {q}: {k:.2f} dB at ATK 6   even patterns: now {now:.2f} -> fitted {got:.2f}"
                  + ("   kept" if got < now else "   held: the fit does not hold out"))
            if got < now:
                keep.append(q)
    for q in keep:
        new[q] = round(fit(caps, q), 2)
    for q in seqs:
        b0, b1 = biases(caps, q, held[q]), biases(caps, q, new[q])
        print(f"SEQ {q}: {held[q]} -> {new[q]} dB   bias now " + " ".join(f"{v:+.2f}" for v in b0)
              + f" (rms {rm(b0):.2f})   fitted " + " ".join(f"{v:+.2f}" for v in b1) + f" (rms {rm(b1):.2f})")
    if args.write and new != held:
        ct.set_values("ballistics", {"seq_atk_db": new}, f"fit_ballistics.py --seq-suite {args.seq_suite}, {date.today()}")
        print("wrote [ballistics] seq_atk_db, and calib.inc")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--suite", help="a calibrate.py suite --extended session")
    ap.add_argument("--seq-suite", help="a calibrate.py suite --atk-seq session: fit seq_atk_db")
    ap.add_argument("--write", action="store_true")
    ap.add_argument("--holdout", action="store_true",
                    help="fit C and p on the odd patterns, score the even ones")
    ap.add_argument("--rats", default="0,1,2,3", help="the stored ratios to fit; the rest are held")
    args = ap.parse_args()
    C = sm.constants()
    if args.seq_suite:
        return seq_fit(args, C)
    if not args.suite:
        ap.error("--suite or --seq-suite")
    cal = ct.load()["ballistics"]
    caps = load(args.suite, C)
    atk_s, rel_eff = cal["atk_s"], cal["rel_eff_s"]
    aa = [C["atktab"][min(a, 7)] for a in range(7)]
    ar = C["reltab"]
    print(f"{args.suite}: {len(caps)} captures")

    fitted = [list(v) for v in cal["coupling"]]
    rats = [int(v) for v in args.rats.split(",")]
    rats = [r for r in rats if any(c["cond"] == f"atk1_rat{r}" for c in caps)]
    rm = lambda v: float(np.sqrt(np.mean(v ** 2)))

    def biases(cs, rat, q):
        b0 = bias(cs, f"thr80_rat{rat}", 256, aa[0], ar[0])
        return np.array([bias(cs, f"atk{a}_rat{rat}", scale_byte(q[0], q[1], atk_s[a], rel_eff[0]), aa[a], ar[0]) - b0
                         for a in range(1, 7)])

    def fit(cs, rat):
        return minimize(lambda q: float(np.sum(biases(cs, rat, q) ** 2)) if q[0] > 0 and q[1] > 0 else 1e9,
                        cal["coupling"][rat], method="Nelder-Mead", options=dict(xatol=1e-3, fatol=1e-6)).x

    if args.holdout:
        # Fitted on the odd patterns, scored on the even: a ratio is kept only if
        # the fit improves patterns it has not seen.
        fit_on = [c for c in caps if c["pattern"] % 2 == 1]
        test = [c for c in caps if c["pattern"] % 2 == 0]
        print("hold-out: fitted on the odd patterns, scored on the even; ATK bias rms over ATK 1..6")
        keep = []
        for rat in rats:
            q = fit(fit_on, rat)
            now, new = rm(biases(test, rat, cal["coupling"][rat])), rm(biases(test, rat, q))
            print(f"   RAT {rat}: C {q[0]:.3f} p {q[1]:.3f}   even patterns: now {now:.2f} -> fitted {new:.2f}"
                  + ("   kept" if new < now else "   held: the fit does not hold out"))
            if new < now:
                keep.append(rat)
        rats = keep
    for rat in rats:
        q = fit(caps, rat)
        now, new = biases(caps, rat, cal["coupling"][rat]), biases(caps, rat, q)
        fitted[rat] = [round(float(q[0]), 4), round(float(q[1]), 4)]
        print(f"RAT {rat}: C {cal['coupling'][rat][0]} p {cal['coupling'][rat][1]} -> C {fitted[rat][0]} p {fitted[rat][1]}")
        print(f"   ATK   " + "  ".join(f"{a:>6d}" for a in range(1, 7)))
        print(f"   now   " + "  ".join(f"{v:+6.2f}" for v in now) + f"   rms {rm(now):.2f}")
        print(f"   fit   " + "  ".join(f"{v:+6.2f}" for v in new) + f"   rms {rm(new):.2f}")
    print(f"fitted RAT {rats}; the others held, and the release times")

    print("\nreltab, pattern-only optimum per REL at RAT 2 (reported, not written):")
    base = bias(caps, "thr80_rat2", 256, aa[0], ar[0])
    for rel in range(1, 8):
        cond = f"rel{rel}"
        if not any(c["cond"] == cond for c in caps):
            continue
        f = lambda v: (bias(caps, cond, 256, aa[0], int(round(v))) - base) ** 2
        best = minimize_scalar(f, bounds=(10, 2000), method="bounded", options=dict(xatol=1)).x
        print(f"   REL {rel}: now {ar[rel]:4d} (bias {bias(caps, cond, 256, aa[0], ar[rel]) - base:+.2f})"
              f"   patterns alone {int(round(best)):4d}")

    if args.write and rats:
        src = f"fit_ballistics.py on {args.suite}, {date.today()}"
        ct.set_values("ballistics", {"coupling": fitted}, src)
        ct.remove_value("ballistics", "atkscale")
        print("wrote [ballistics] coupling; atkscale is now generated from it, and calib.inc with it")


if __name__ == "__main__":
    main()
