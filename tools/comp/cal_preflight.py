"""Before a sitting: check what the calibration assumes of the rig, the device
and the calibration project, as far as the device can show it, and say what
failed and what to change. Records nothing a fit reads; leaves the device as
the stages expect to find it.

    calibrate.py preflight [--seconds 8]

Each check prints PASS, WARN or FAIL. FAIL means a stage would stop or record
something unusable; WARN means a stage would run but a fit would have less to
work with. The last lines are the ones the device cannot show, for the person
at it to confirm.
"""
from datetime import datetime

import numpy as np

import calframes as cf
import calib_tables as ct
import rig
from cal_input import DOMINANT_DB, MIN_BLOCKS, SILENT_SLOT_DB, block_db
from cal_io import (
    CURRENT, FIXED, FLOOR_DB, FS_GUARD, GRID_CUTOFF, PROJECT, ROLES_FILE, RUNS, block_gr, roles, slots)
from cal_io import ROLL_TRACKS, pattern_name, pattern_number, roll_call_capture, track_slot
from cal_tone import resonant_tone, settled_level

# Set on every pattern: a setting no pattern's kit is likely to hold, so a
# parameter lock or an LFO on it shows as a block that reads back otherwise.
PROBE = {"THR": 101, "ATK": 1, "REL": 1, "RAT": 1, "SEQ": 2, "MUP": 0, "MIX": 127, "VOL": 127,
         "DIST": 5, "SYM": 60, "DELAY": 100, "REVERB": 100}
CHECKED = ("THR", "ATK", "REL", "RAT", "SEQ", "MUP", "MIX", "VOL", "DIST")
SCORABLE_MIN = 0.3                 # of a pattern's blocks, input over FLOOR_DB and MAIN not clipped
CLIP_MAX = 0.05                    # of a pattern's blocks with MAIN within 0.5 dB of full scale
SILENT_DB = -60.0                  # a voice slot under this is silent
TONE_MIN_DB = -40.0                # the tone's level, dB on the curve's scale, at least
TONE_DRIFT_DB = 0.5                # the tone's level, held, moves no more than this in 3 s


class Checks:
    def __init__(self):
        self.lines, self.failed, self.warned = [], 0, 0

    def __call__(self, verdict, text):
        self.failed += verdict == "FAIL"
        self.warned += verdict == "WARN"
        line = f"{verdict:4s}  {text}"
        self.lines.append(line)
        print(line, flush=True)


def params_held(c, want):
    """-> the controls whose read-back moved off the value set, with what they read."""
    out = {}
    for k in CHECKED:
        v = c.rec[k]
        if np.any(v != want[k]):
            out[k] = sorted(set(int(x) for x in v))
    sym = c.rec["SYM_raw"] >> 8
    if np.any(sym != want["SYM"]):
        out["SYM"] = sorted(set(int(x) for x in sym))
    return out


def pattern_check(dev, check, slot, role, seconds):
    """Program change, playback, levels and locks on one pattern; -> its capture."""
    dev.pattern(slot)
    dev.set({**FIXED, **PROBE})
    c = cf.decode(dev.capture(seconds))
    voices = 10 * np.log10(np.maximum(np.mean(c.slots ** 2, axis=(0, 1)), 1e-24))
    live = int(np.sum(voices > SILENT_DB))
    if live == 0:
        check("FAIL", f"{pattern_name(slot)} ({role}): every voice slot silent - the pattern did not play: program "
                      f"change on channel {rig.AUTO_CHANNEL}, MIDI Start (transport receive), or no trigs")
        return c
    moved = params_held(c, PROBE)
    if moved:
        check("FAIL", f"{pattern_name(slot)} ({role}): " + ", ".join(f"{k} set {PROBE[k]} read {v}" for k, v in moved.items())
              + " - a parameter lock or LFO on the FX track")
    _, ok = block_gr(c, 1.0)
    clip = float(np.mean(np.max(np.abs(c.main), axis=(1, 2)) >= FS_GUARD))
    scor = float(np.mean(ok))
    verdict = "PASS" if scor >= SCORABLE_MIN and clip <= CLIP_MAX else "WARN"
    check(verdict, f"{pattern_name(slot)} ({role}): {live} voices, {100 * scor:.0f}% of blocks scorable "
                   f"(input over {FLOOR_DB:g} dBFS), {100 * clip:.0f}% with MAIN at full scale"
          + ("" if verdict == "PASS" else " - raise the pattern's level" if scor < SCORABLE_MIN
             else " - lower the pattern's level"))
    return c


def roll_call_check(dev, check, slot):
    """Each roll-call track alone on pattern `slot`'s kit, over MAIN's floor,
    and the returns alone after the hits, often enough for the input fit."""
    c = cf.decode(roll_call_capture(dev, slot, {**FIXED, "DELAY": 127, "REVERB": 127, "DIST": 0, "SYM": 64,
                                                "MIX": 0}))
    sl, main, _, ok = block_db(c)
    top = np.argmax(sl, axis=1)
    srt = np.sort(sl, axis=1)
    dom = ok & (srt[:, -1] - srt[:, -2] > DOMINANT_DB)
    n = {t: int(np.sum(dom & (top == track_slot(t)))) for t in ROLL_TRACKS}
    alone = int(np.sum(ok & (sl.max(axis=1) < SILENT_SLOT_DB)))
    text = (f"roll call on {pattern_name(slot)}'s kit: blocks alone per track "
            + ", ".join(f"{t}: {v}" for t, v in n.items()) + f"; returns alone {alone}")
    missing = [t for t, v in n.items() if v == 0]
    few = [t for t, v in n.items() if 0 < v < MIN_BLOCKS // 2]
    if missing:
        check("FAIL", text + f" - tracks {missing} never sound alone: the kit needs a sound on each of tracks "
                      + ", ".join(str(t) for t in ROLL_TRACKS) + ": the scratch pattern's kit")
    elif few or alone < MIN_BLOCKS:
        check("WARN", text + (f" - tracks {few} are short" if few else "")
              + (" - little delay or reverb tail: longer returns in the kit give the return fit more" if alone < MIN_BLOCKS
                 else ""))
    else:
        check("PASS", text)


def tone_check(dev, check, r):
    """The scratch pattern silent; the tone track's held note a steady sine."""
    dev.pattern(pattern_number(r["scratch"]))
    c = cf.decode(dev.capture(2.0))
    voices = 10 * np.log10(np.maximum(np.mean(c.slots ** 2, axis=(0, 1)), 1e-24))
    if np.any(voices > SILENT_DB):
        check("FAIL", f"scratch pattern {pattern_name(pattern_number(r['scratch']))}: slots {list(np.nonzero(voices > SILENT_DB)[0])} sound with "
                      "no note held - it must have no trigs")
        return
    check("PASS", f"scratch pattern {pattern_name(pattern_number(r['scratch']))}: silent")
    dev.set({**FIXED, "DELAY": 0, "REVERB": 0, "DIST": 0, "SYM": 64, "MIX": 127, "THR": 127, "SEQ": 0})
    dev.cc("PAN", 64)
    dev.cc("LEVEL", 100)
    try:
        with resonant_tone(dev, r["tone_track"], GRID_CUTOFF):
            try:
                lvl, c = settled_level(dev)
            except SystemExit as e:
                check("FAIL", f"tone track {r['tone_track']}: {e} - the note must sustain while held")
                return
            sl = 10 * np.log10(np.maximum(np.mean(c.slots ** 2, axis=(0, 1)), 1e-24))
            dev.stream.drain(3.0)
            later, _ = settled_level(dev)
    except SystemExit as e:
        check("FAIL", f"tone track {r['tone_track']}: {e}")
        return
    loud = int(np.sum(sl > sl.max() - 20))
    if lvl < TONE_MIN_DB:
        check("FAIL", f"tone track {r['tone_track']}: {lvl:+.1f} dB held - too quiet for a self-oscillating "
                      f"filter: resonance 127 on a lowpass, the track triggered by note {r['tone_track'] - 1} on the auto "
                      f"channel {rig.AUTO_CHANNEL}")
    elif abs(later - lvl) > TONE_DRIFT_DB:
        check("FAIL", f"tone track {r['tone_track']}: {lvl:+.1f} dB, then {later:+.1f} dB 3 s later - the note "
                      "must hold steady: amp hold, no LFO or lock on the filter or level")
    elif loud > 1:
        check("WARN", f"tone track {r['tone_track']}: {loud} slots sound with the note - only the tone track should")
    else:
        check("PASS", f"tone track {r['tone_track']}: a steady {lvl:+.1f} dB while held")


def run_preflight(dev, seconds=8.0):
    check = Checks()
    print(f"preflight {datetime.now():%Y-%m-%d %H:%M}\n")

    # The host and the image.
    check("PASS", f"rig: MIDI {dev.cfg['midi_out']!r}, FX channel {dev.cfg['fx_channel']}, "
                  "the Rytm's twelve-channel USB input")
    last, c = dev.readback()
    want = ct.inc_hash(ct.INC.read_text())
    check("PASS", f"cal build running: {c.lost} lost and {c.bad} damaged blocks in 0.3 s")
    check("PASS" if last["calhash"] == want else "WARN",
          f"the device runs calibration {last['calhash']:08x}, calib.inc is {want:08x}"
          + ("" if last["calhash"] == want else " - rebuild and flash before recording (verify excepted)"))
    check("PASS" if CURRENT.exists() else "WARN",
          f"current run: {CURRENT.read_text().strip()}" if CURRENT.exists() else
          f"no current run under {RUNS}: calibrate.py run new NAME before recording")

    # The project.
    r = roles()
    check("PASS" if PROJECT.exists() else "WARN",
          f"roles: fit {r['fit']}, verify {r['verify']}, scratch {pattern_name(pattern_number(r['scratch']))}, "
          f"tone track {r['tone_track']} ({ROLES_FILE.name})"
          + ("" if PROJECT.exists() else f"; {PROJECT.name} not committed yet: calibrate.py project --receive"))
    used = slots(r["fit"]) + slots(r["verify"]) + [pattern_number(r["scratch"])]
    if len(set(used)) != len(used):
        check("FAIL", f"roles share patterns ({', '.join(pattern_name(p) for p in used)}): every role needs "
                      "its own, and no verify pattern may be fit")

    # Each pattern: plays, holds what is set, levels usable.
    for s in slots(r["fit"]):
        pattern_check(dev, check, s, "fit", seconds)
    for s in slots(r["verify"]):
        pattern_check(dev, check, s, "verify", seconds)
    roll_call_check(dev, check, pattern_number(r["scratch"]))
    tone_check(dev, check, r)
    dev.set({"MIX": 0, "THR": 127, "DIST": 0, "SYM": 64, "MUP": 0})

    print("\nNot visible to the device - confirm by hand:")
    for t in ("the main volume knob stays where it is for the whole sitting",
              "nothing is connected to the Rytm's external audio inputs",
              "no parameter lock or LFO on the delay and reverb volumes or routing, or on track pan",
              "the patterns play without fills, mutes or conditional trigs that leave silence"):
        print(f"  - {t}")
    print(f"\n{check.failed} failed, {check.warned} warned")
    if CURRENT.exists():
        d = RUNS / CURRENT.read_text().strip()
        if d.is_dir():
            (d / f"preflight_{datetime.now():%Y%m%d_%H%M%S}.txt").write_text("\n".join(check.lines) + "\n")
    return check.failed == 0
