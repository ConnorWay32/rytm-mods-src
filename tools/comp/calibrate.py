"""Mod 0006's calibration, driven from a `cal` build (re/subsystems/compressor-calibration.md).

The command line, the sittings and their fits. The stages live in cal_input.py
(sitting 1), cal_tone.py (sitting 2's tone stages) and cal_suite.py (the drum
suites, verification and the report); cal_io.py holds the device, the pattern
library, and the runs and sessions on disk.

Build and flash the calibration image first (make comp-cal-build):

    tools/build.py --tag cal --mods 0006-comp-preview --param 0006-comp-preview:cal=1

It estimates on every block and carries, on USB channels 10 and 11, the model's
sides and a record of each block (calframes.py). Every stage reads the device's
parameters back from that record rather than assuming a CC took.

    calibrate.py devices                    list audio inputs and MIDI ports
    calibrate.py setup --midi PORT --fx-channel N [--midi-in PORT]
                                            write build/comp_rig.json
    calibrate.py run new NAME | use NAME    start a calibration run, or return to one;
    calibrate.py run                        with no action, list the current run
    calibrate.py preflight [--seconds 8]    what the calibration assumes of the rig, the
                                            device and the project, checked before a
                                            sitting (cal_preflight.py)
    calibrate.py check [--seconds 3]        the build, the parameters, the load
    calibrate.py set NAME=V [NAME=V ...]    set controls and wait for the readback
    calibrate.py twin [--seconds 8]         the device against the twin, on what
                      [--stem cal_...]      is playing (or a saved capture)
    calibrate.py suite [--patterns P]       the pattern library through a set of
          [--seq-matrix 2,3 [--thr ...]]    conditions (cal_io.py's GR_*), each set
          [--extended | --atk-seq]          and read back; captures and a session
          [--seconds 8]
    calibrate.py score SESSION              the device's GR against the measured
                                            reduction, per SEQ and condition
    calibrate.py input [--patterns P]       the input model against MAIN at MIX 0:
                                            voices, each return alone, both, both
                                            and DIST 64; then the fit
    calibrate.py input --score SESSION      re-score a saved input session
    calibrate.py input --fit SESSION        the slot trims from blocks one slot
                     [--write]              dominates, each return's constant from
                                            blocks no slot sounds in
    calibrate.py dist [--patterns P]        the master distortion, pre-saturation sides:
                                            DIST 0 .. 127 at MIX 0, then the gain
                                            per DIST and the saturation fitted
    calibrate.py dist --fit SESSION         re-fit a saved distortion session
    calibrate.py dist --sym [--dists 64,96] DIST symmetry swept 0 .. 127 in 8s at
                                            each DIST, pre-saturation sides, and a
                                            bias and gain per SYM fitted
    calibrate.py dist --sym --fit SESSION   re-fit a saved symmetry session
                     [--write]              and put the tables in calibration.toml
    calibrate.py grid --seq 0 --ratios 3,2,1,0 --levels 127,95,.. --thresholds 127,..
                      [--cutoff 30]         a steady-tone grid on --track, centred:
                                            its filter self-oscillating at --cutoff
                                            (CC 74), or whatever sustained tone it
                                            plays; one capture per level kept, so
                                            the levels follow later calibration
    calibrate.py sidechain [--track T]      each SEQ's sidechain response, from the
                                            track's filter self-oscillating (a note
                                            held, resonance 127) swept by CC 74
    calibrate.py release [--track T]        level steps on the track's tone at each
                         [--cutoff 33]      REL: THR set for about 12 dB at the loud
                                            level, the level stepped loud / quiet
    calibrate.py release --fit SESSION      reltab per REL from the releases after
                         [--write]          each step down
    calibrate.py roles --fit P --verify P --scratch P --tone-track T
                                            which patterns and track of the
                                            calibration project play each part;
                                            recordings default to them
    calibrate.py sitting 1|2|3 [--resume M] record a sitting of the calibration
                                            (compressor-calibration.md) in order,
                                            and a manifest of its sessions
    calibrate.py fits MANIFEST [--write]    that sitting's fits, in order
    calibrate.py project --receive [FILE]   store the project the Rytm sends
                                            (SYSEX DUMP), or --send [FILE] it back;
                                            FILE by default the committed
                                            mods/0006-comp-preview/calibration_project.syx
    calibrate.py sidechain --fit SESSION    fit each SEQ's two sections and level to a
                     [--write]              saved sweep (a session name, or a path to
                                            its json), and put them into
                                            calibration.toml
    calibrate.py grid --score calgrid_...   a grid against the current curve, its
                      [--against CSV]       levels through the current twin; and
                                            against an earlier grid's reduction

Every session records the calibration it ran on (calibration.toml, calib.inc and
its CAL_HASH), and a recording refuses to start unless the device's CAL_HASH is
the host's calib.inc: a fit measures a correction against what ran, and reads
that from the session.

A suite switches patterns by program change (pattern change mode DIRECT
JUMP) and writes the compressor, returns and DIST of each pattern's kit.

Controls: THR ATK REL RAT SEQ MUP MIX VOL DIST SYM (read back), DELAY REVERB (the
FX returns) and LEVEL PAN (--track, 8 by default), which are not.

On disk, a run is build/comp/runs/<run>/: run.json, one directory per session
(session.json and its captures), fits/ and report.md; build/comp/current names
the run recordings go into, and every recording stage refuses to start without
one. A suite's captures are <session>_<pattern>_<condition>.wav, MAIN and
channels 10 and 11 only, 24-bit - all the calibration frames carry. check and
twin captures go to build/comp/scratch/.
"""
import argparse
import contextlib
import sys
import tomllib
from datetime import datetime
from pathlib import Path

import numpy as np

import calframes as cf
import calib_tables as ct
import rig

from cal_io import (
    CONTROLS, Device, GRID_CUTOFF, PROJECT, ROLES, ROLES_FILE, dist_patterns, load,
    load_session, require_current, roles, run_dir, run_new, run_project, run_show, run_use,
    save, save_roles, slots, write_session)
from cal_io import pattern_number
from cal_input import (
    dist_report, input_fit, input_report, input_sym_report, null_stats, run_dist, run_input,
    run_input_sym, run_sym, sym_report)
from cal_tone import grid_report, release_fit, run_grid, run_release, run_sidechain, sidechain_fit
from cal_suite import run_report, run_suite, run_verify, score, summary, twin_report, verify_report


def sittings(r):
    """The three sittings: each's recordings in order, each a recorder and its
    arguments. Tone stages run on the scratch pattern."""
    tr = r["tone_track"]
    return {
        1: ([("input", dict(patterns=r["fit"], roll_call=r["scratch"], seconds=8.0)),
                ("dist", dict(patterns=dist_patterns(r), seconds=8.0)),
                ("sym", dict(patterns=dist_patterns(r), seconds=8.0, dists="64,96"))]),
        2: ([("sidechain", dict(track=tr, seconds=1.0)),
                ("grid", dict(seq=0, ratios="3,2,1,0", levels="127,95,65,50,35,20,10",
                              thresholds=",".join(str(t) for t in range(127, 39, -3)),
                              track=tr, seconds=1.5, settle=0.5, cutoff=GRID_CUTOFF)),
                ("grid", dict(seq=1, ratios="3,2,1,0", levels="127,110,95,80,65,50",
                              thresholds=",".join(str(t) for t in range(127, 90, -2)),
                              track=tr, seconds=1.5, settle=0.5, cutoff=GRID_CUTOFF)),
                ("release", dict(track=tr, cutoff=GRID_CUTOFF, rat=1, loud=120, quiet=70, hold=2.5, cycles=3,
                                 seconds=1.5)),
                ("suite", dict(patterns=r["fit"], seq_matrix=None, thr=None, extended=True, seconds=8.0,
                               sym=None)),
                ("seqsuite", dict(patterns=r["fit"], seq_matrix="0,1,2,3", thr="100,80", extended=False,
                                  seconds=8.0, sym=None)),
                ("atkseq", dict(patterns=r["fit"], seq_matrix=None, thr=None, extended=False, atk_seq=True,
                                seconds=8.0, sym=None))]),
        3: ([("verify", dict(patterns=r["verify"], draws=60, seed=None, seconds=8.0))]),
    }


TONE_STAGES = ("sidechain", "grid", "release")


def run_sitting(dev, n, resume=None):
    """Record sitting n's sessions in order, fits reported and nothing written, and
    a manifest of them for `fits`. resume: a stopped sitting's manifest, whose
    recorded sessions are kept and the rest recorded into it."""
    r = roles()
    steps = sittings(r)[n]
    done = []
    if resume:
        rec = load_session(resume)
        if rec["sitting"] != n:
            raise SystemExit(f"{resume} is sitting {rec['sitting']}, not {n}")
        done = [tuple(x) for x in rec["sessions"]]
        if [s for s, _ in done] != [s for s, _ in steps[:len(done)]]:
            raise SystemExit(f"{resume}'s sessions are not the start of sitting {n}")
        print(f"resuming {resume}: {len(done)} of {len(steps)} recorded")
    run = {"input": run_input, "dist": run_dist, "sym": run_sym, "sidechain": run_sidechain,
           "grid": run_grid, "release": run_release, "suite": run_suite, "seqsuite": run_suite, "atkseq": run_suite,
           "verify": run_verify}
    manifest = resume or f"sitting{n}_{datetime.now().strftime('%Y%m%d_%H%M%S')}"
    try:
        for name, kw in steps[len(done):]:
            print(f"\n== sitting {n}: {name} {kw}", flush=True)
            dev.pattern(pattern_number(r["scratch"]) if name in TONE_STAGES else slots(kw.get("patterns", r["fit"]))[0])
            done.append((name, run[name](dev, argparse.Namespace(write=False, **kw))))
    finally:
        write_session(manifest, {"sitting": n, "sessions": done})
        print(f"\nmanifest {manifest}: {', '.join(s for _, s in done)}")
        if len(done) < len(steps):
            print(f"stopped after {len(done)} of {len(steps)} recordings")


class _Tee:
    """Writes to the terminal and a log file both."""
    def __init__(self, path):
        self.f = open(path, "a")
        self.out = sys.stdout

    def write(self, text):
        self.out.write(text)
        self.f.write(text)

    def flush(self):
        self.out.flush()
        self.f.flush()


def run_fits(manifest, write):
    """A sitting's fits, their output kept in the session's run under
    fits/<manifest>.log."""
    rec = load_session(manifest)
    log = Path(rec["dir"]).parent / "fits" / f"{rec['name']}{'_write' if write else ''}.log"
    log.parent.mkdir(exist_ok=True)
    tee = _Tee(log)
    tee.write(f"\n== {datetime.now().isoformat(timespec='seconds')} fits {rec['name']}"
              f"{' --write' if write else ''}\n")
    with contextlib.redirect_stdout(tee):
        _run_fits(rec, write)
    tee.f.close()
    print(f"\nlog: {log}")


def _run_fits(rec, write):
    """A sitting's fits in the order compressor-calibration.md gives. With --write
    each fit writes before the next reads calibration.toml."""
    import subprocess
    got = {}
    for name, sess in rec["sessions"]:
        got.setdefault(name, []).append(sess)
    py = [sys.executable]
    here = Path(__file__).resolve().parent
    w = ["--write"] if write else []

    def sh(cmd):
        """A fitting tool, its output through this one's, so the log has it."""
        r = subprocess.run(cmd, capture_output=True, text=True)
        print(r.stdout, end="")
        if r.returncode:
            print(r.stderr, end="")
            raise SystemExit(f"{Path(cmd[1]).name} failed")
    if rec["sitting"] == 1:
        input_fit(load_session(got["input"][0]), write)
        dist_report(load_session(got["dist"][0]), write)
        sym_report(load_session(got["sym"][0]), write)
    elif rec["sitting"] == 2:
        # The sweep is read through the curve and the grids through the
        # sidechain: sidechain, curve, then the sidechain once more. Release
        # before the ballistics, whose ATK sweeps run at REL 0.
        sidechain_fit(load_session(got["sidechain"][0]), write)
        sh(py + [str(here / "fit_shift.py")] + [a for g in got["grid"] for a in ("--grid", g)]
           + ["--suite", got["seqsuite"][0]] + w)
        sidechain_fit(load_session(got["sidechain"][0]), write)
        release_fit(load_session(got["release"][0]), write)
        sh(py + [str(here / "fit_ballistics.py"), "--suite", got["suite"][0], "--holdout"] + w)
        if "atkseq" in got:                       # sittings before 2026-09-26 have none
            sh(py + [str(here / "fit_ballistics.py"), "--seq-suite", got["atkseq"][0], "--holdout"] + w)
    else:
        verify_report(got["verify"][0])
        run_report(False)
    if write and rec["sitting"] == 1:
        print("\nnow: make comp-cal-check and make comp-cal-build, flash the cal image, then sitting 2")
    elif write and rec["sitting"] == 2:
        print("\nnow: sitting 3 on this same image - the twin scores the values just written")


def fill_roles(args):
    """A recording's patterns and track, when not given, from the project's roles."""
    need = ((args.cmd in ("suite", "input", "dist", "verify") and getattr(args, "patterns", None) is None)
            or (args.cmd == "input" and getattr(args, "roll_call", None) is None)
            or (args.cmd in ("sidechain", "grid", "release") and args.track is None)
            or args.cmd == "sitting")
    if not need:
        return
    r = roles()
    if args.cmd == "suite" and args.patterns is None:
        args.patterns = r["fit"]
    elif args.cmd == "verify" and args.patterns is None:
        args.patterns = r["verify"]
    elif args.cmd == "input":
        args.patterns = args.patterns or r["fit"]
        args.roll_call = args.roll_call or r["scratch"]
    elif args.cmd == "dist" and args.patterns is None:
        args.patterns = dist_patterns(r)
    if getattr(args, "track", 0) is None:
        args.track = r["tone_track"]


# ---------------------------------------------------------------- commands
def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("devices")
    a = sub.add_parser("run"); a.add_argument("action", nargs="?", choices=("new", "use", "show"), default="show")
    a.add_argument("name", nargs="?")
    a = sub.add_parser("setup"); a.add_argument("--midi", required=True, help="the Rytm's MIDI output port")
    a.add_argument("--fx-channel", type=int, required=True, help="the FX channel in the Rytm's MIDI CONFIG, 1-16")
    a.add_argument("--midi-in", help="the Rytm's MIDI input port, if its name differs, for project --receive")
    a = sub.add_parser("check"); a.add_argument("--seconds", type=float, default=3)
    a = sub.add_parser("preflight"); a.add_argument("--seconds", type=float, default=8)
    a = sub.add_parser("set"); a.add_argument("pairs", nargs="+"); a.add_argument("--track", type=int)
    a = sub.add_parser("twin"); a.add_argument("--seconds", type=float, default=8); a.add_argument("--stem")
    a = sub.add_parser("suite"); a.add_argument("--patterns", help="default: the fit patterns")
    a.add_argument("--seq-matrix"); a.add_argument("--thr"); a.add_argument("--extended", action="store_true")
    a.add_argument("--atk-seq", action="store_true", help="ATK at SEQ OFF, HPF and HIT (fit_ballistics.py --seq-suite)")
    a.add_argument("--seconds", type=float, default=8)
    a.add_argument("--sym", help="DIST symmetry values, e.g. 0,32,64,96,127, at THR 90 RAT 2 SEQ LPF")
    a.add_argument("--sym-dist", default="0,64", help="with --sym: the DIST values")
    a = sub.add_parser("score"); a.add_argument("session")
    a = sub.add_parser("verify"); a.add_argument("--patterns", help="default: the verify patterns")
    a.add_argument("--draws", type=int, default=60); a.add_argument("--seed", type=int)
    a.add_argument("--seconds", type=float, default=8); a.add_argument("--score", metavar="SESSION")
    a = sub.add_parser("report"); a.add_argument("--publish", action="store_true",
                                                 help="copy it beside calibration.toml")
    a = sub.add_parser("sidechain"); a.add_argument("--track", type=int, help="default: the tone track")
    a.add_argument("--seconds", type=float, default=1.0); a.add_argument("--fit", metavar="SESSION")
    a.add_argument("--write", action="store_true", help="with --fit: put the fit into calibration.toml")
    a = sub.add_parser("sitting"); a.add_argument("n", type=int, choices=(1, 2, 3))
    a.add_argument("--resume", metavar="MANIFEST", help="a stopped sitting: record only what it lacks")
    a = sub.add_parser("roles")
    a.add_argument("--fit", help="drum patterns every fit uses, e.g. 1-8")
    a.add_argument("--verify", help="drum patterns no fit uses")
    a.add_argument("--scratch", help="an empty pattern on a kit of its own, e.g. B01: the roll call and the tone")
    a.add_argument("--tone-track", type=int, help="the track whose filter self-oscillates")
    a = sub.add_parser("fits"); a.add_argument("manifest"); a.add_argument("--write", action="store_true")
    a = sub.add_parser("project"); g = a.add_mutually_exclusive_group(required=True)
    g.add_argument("--receive", metavar="FILE", nargs="?", const=str(PROJECT))
    g.add_argument("--send", metavar="FILE", nargs="?", const=str(PROJECT))
    a.add_argument("--idle", type=float, default=5.0); a.add_argument("--pace", type=float, default=0.05)
    a = sub.add_parser("release"); a.add_argument("--track", type=int, help="default: the tone track")
    a.add_argument("--cutoff", type=int, default=GRID_CUTOFF); a.add_argument("--rat", type=int, default=1)
    a.add_argument("--loud", type=int, default=120); a.add_argument("--quiet", type=int, default=70)
    a.add_argument("--hold", type=float, default=2.5); a.add_argument("--cycles", type=int, default=3)
    a.add_argument("--seconds", type=float, default=1.5)
    a.add_argument("--fit", metavar="SESSION"); a.add_argument("--write", action="store_true")
    a = sub.add_parser("dist"); a.add_argument("--patterns", help="default: the first three fit patterns")
    a.add_argument("--seconds", type=float, default=8); a.add_argument("--fit", metavar="SESSION")
    a.add_argument("--write", action="store_true", help="put changes past tolerance into calibration.toml")
    a.add_argument("--sym", action="store_true", help="sweep DIST symmetry instead")
    a.add_argument("--dists", default="64,96")
    a = sub.add_parser("grid"); a.add_argument("--seq", type=int, default=0)
    a.add_argument("--ratios", default="3,2,1,0"); a.add_argument("--levels")
    a.add_argument("--thresholds"); a.add_argument("--track", type=int, help="default: the tone track")
    a.add_argument("--seconds", type=float, default=1.5); a.add_argument("--settle", type=float, default=0.5)
    a.add_argument("--cutoff", type=int, help="self-oscillate the track's filter at this CC 74 value")
    a.add_argument("--score", metavar="SESSION"); a.add_argument("--against", metavar="CSV")
    a = sub.add_parser("input"); a.add_argument("--patterns", help="default: the fit patterns")
    a.add_argument("--roll-call", help="the pattern whose kit the roll call plays; default: the scratch pattern")
    a.add_argument("--seconds", type=float, default=8); a.add_argument("--score", metavar="SESSION")
    a.add_argument("--fit", metavar="SESSION"); a.add_argument("--write", action="store_true")
    a.add_argument("--sym", help="DIST symmetry values: the detector level against the hardware's, MIX 0")
    a.add_argument("--sym-dist", default="0,64")
    args = ap.parse_args()

    if args.cmd == "devices":
        return rig.devices()
    if args.cmd == "run":
        if args.action in ("new", "use") and not args.name:
            raise SystemExit(f"calibrate.py run {args.action} NAME")
        return {"new": run_new, "use": run_use}[args.action](args.name) if args.action != "show" else run_show()
    if args.cmd == "setup":
        return rig.setup(args.midi, args.fx_channel, args.midi_in)
    if args.cmd == "score":
        return score(args.session)
    if args.cmd == "verify" and args.score:
        return verify_report(args.score)
    if args.cmd == "report":
        return run_report(args.publish)
    if args.cmd == "fits":
        return run_fits(args.manifest, args.write)
    if args.cmd == "project":
        return run_project(args)
    if args.cmd == "release" and args.fit:
        return release_fit(load_session(args.fit), args.write)
    if args.cmd == "sidechain" and args.fit:
        return sidechain_fit(load_session(args.fit), args.write)
    if args.cmd == "grid" and args.score:
        return grid_report(load_session(args.score), args.against)
    if args.cmd == "dist" and args.fit and args.sym:
        return sym_report(load_session(args.fit), args.write)
    if args.cmd == "dist" and args.fit:
        return dist_report(load_session(args.fit), args.write)
    if args.cmd == "input" and args.fit:
        return input_fit(load_session(args.fit), args.write)
    if args.cmd == "input" and args.score and args.sym:
        return input_sym_report(load_session(args.score)["rows"])
    if args.cmd == "input" and args.score:
        rows = load_session(args.score)["rows"]
        for r in rows:
            r.update(null_stats(cf.decode(load(r["stem"]))))
        return input_report(rows)
    if args.cmd == "twin" and args.stem:
        c = cf.decode(load(args.stem))
        print(f"{args.stem}:"); summary(c); twin_report(c)
        return

    if args.cmd == "roles":
        r = tomllib.loads(ROLES_FILE.read_text()).get("roles", {}) if ROLES_FILE.exists() else {}
        r.update({k: v for k, v in vars(args).items() if k in ROLES and v is not None})
        save_roles(r)
        print("roles: " + ", ".join(f"{k} {r.get(k, '-')}" for k in ROLES))
        return
    fill_roles(args)
    if args.cmd not in ("check", "set", "twin", "preflight"):
        run_dir()                                   # before anything is recorded
    tone = tomllib.loads(ROLES_FILE.read_text()).get("roles", {}).get("tone_track") if ROLES_FILE.exists() else None
    dev = Device(track=getattr(args, "track", None) or tone)
    try:
        dev.stream.drain(0.5)
        if args.cmd not in ("check", "set", "preflight"):
            require_current(dev, sides_only=args.cmd == "verify" or (args.cmd == "sitting" and args.n == 3))
        if args.cmd == "preflight":
            from cal_preflight import run_preflight
            passed = run_preflight(dev, args.seconds)
        elif args.cmd == "check":
            x = dev.capture(args.seconds)
            c = cf.decode(x)
            print(f"check, {args.seconds:g} s:"); summary(c)
            want = ct.inc_hash(ct.INC.read_text())
            vals, n = np.unique(c.rec["calhash"], return_counts=True)
            got = int(vals[n.argmax()])
            print(f"  calibration {got:08x}, calib.inc {want:08x}: " + ("current" if got == want else
                  "DIFFERENT - make comp-cal-build and flash it before recording"))
        elif args.cmd == "set":
            want = {}
            for p in args.pairs:
                k, _, v = p.partition("=")
                if k.upper() not in CONTROLS:
                    raise SystemExit(f"unknown control {k}; known: {', '.join(CONTROLS)}")
                want[k.upper()] = int(v)
            last = dev.set(want)
            print("set, read back: " + "  ".join(f"{k} {last[CONTROLS[k][2]]}" for k in want if CONTROLS[k][2])
                  + ("  (not read back: " + ", ".join(k for k in want if not CONTROLS[k][2]) + ")"
                     if any(not CONTROLS[k][2] for k in want) else ""))
        elif args.cmd == "suite":
            run_suite(dev, args)
        elif args.cmd == "verify":
            run_verify(dev, args)
        elif args.cmd == "input" and args.sym:
            run_input_sym(dev, args)
        elif args.cmd == "input":
            run_input(dev, args)
        elif args.cmd == "grid":
            run_grid(dev, args)
        elif args.cmd == "sidechain":
            run_sidechain(dev, args)
        elif args.cmd == "release":
            run_release(dev, args)
        elif args.cmd == "sitting":
            run_sitting(dev, args.n, args.resume)
        elif args.cmd == "dist" and args.sym:
            run_sym(dev, args)
        elif args.cmd == "dist":
            run_dist(dev, args)
        elif args.cmd == "twin":
            x = dev.capture(args.seconds)
            stem = save(x)
            c = cf.decode(x)
            print(f"{stem}:"); summary(c); twin_report(c)
    finally:
        dev.close()
    if args.cmd == "preflight" and not passed:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
