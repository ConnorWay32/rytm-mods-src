"""The calibration's plumbing: the device over MIDI and USB, the pattern library,
runs, sessions and captures on disk, and the calibration project's roles."""
import json
import re
import time
import tomllib
from datetime import datetime
from pathlib import Path

import mido
import numpy as np
import soundfile as sf

import calframes as cf
import calib_tables as ct
import rig
import stub_model as sm


CAPTURES = rig.CAPTURES


FS = 48000


# ---------------------------------------------------------------- the pattern library
# Patterns are switched by program change on the auto channel. Switching loads the
# pattern's kit, but not a fresh copy: CC edits to the working kit survive a
# switch. So every condition sets everything the model depends on, and the
# patterns supply only the content.
#
# Applied with every condition: both returns PRE, since the model carries only
# PRE returns; DIST symmetry centred; and the compressor's VOL at 127, where the
# dry taper is unity - VOL is part of the kit and at MIX 0 it scales the whole
# of MAIN.
FIXED = {rig.CC_DELAY_ROUTE: 0, rig.CC_REVERB_ROUTE: 0, rig.CC_DIST_SYM: 64, "VOL": 127}


# MUP selects what the cal build's sides carry: 0 the side after the saturation,
# anything else the side before it. Makeup is out of the path at MIX 0, where the
# distortion stages record, so it doubles as the switch.
PRESAT = 127


GR_BASE = {"ATK": 0, "REL": 0, "MUP": 0, "VOL": 127, "SEQ": 1, "MIX": 127,
           rig.CC_DELAY_VOL: 100, rig.CC_REVERB_VOL: 100, rig.CC_DIST: 0}


GR_CONDITIONS = [(f"thr{t}_rat{r}", {"THR": t, "RAT": r})
                 for t in (90, 70) for r in (0, 2, 3)] + [
    ("atk10", {"THR": 80, "RAT": 2, "ATK": 5}),
    ("rel2s", {"THR": 80, "RAT": 2, "REL": 5}),
    ("atk30_rel1s", {"THR": 80, "RAT": 2, "ATK": 6, "REL": 4}),
    ("dist64", {"THR": 80, "RAT": 2, rig.CC_DIST: 64}),
    ("dist127", {"THR": 80, "RAT": 2, rig.CC_DIST: 127}),
]


# The extended matrix: every THR x RAT on a grid, every ATK at every ratio, every
# REL and every SEQ, each against ATK 0.03, REL 0.1, SEQ LPF otherwise.
GR_EXTENDED = ([(f"thr{t}_rat{r}", {"THR": t, "RAT": r})
                for t in (100, 90, 80, 70, 60) for r in range(4)]
               + [(f"atk{a}_rat{r}", {"THR": 80, "RAT": r, "ATK": a})
                  for r in range(4) for a in range(1, 7)]
               + [(f"rel{v}", {"THR": 80, "RAT": 2, "REL": v}) for v in range(1, 8)]
               + [(f"seq{q}", {"THR": 80, "RAT": 2, "SEQ": q}) for q in (0, 2, 3)])


# The slow-attack loss per SEQ beyond LPF's (fit_ballistics.py --seq-suite): ATK
# 0.3, 3 and 30 ms and an ATK 0.03 baseline at each other SEQ, the hardest and
# softest ratio, THR 80, REL 0.1.
ATK_SEQ = [(f"s{q}_atk{a}_rat{r}", {"THR": 80, "RAT": r, "SEQ": q, "ATK": a})
           for q in (0, 2, 3) for r in (0, 3) for a in (0, 2, 4, 6)]


# Per SEQ, the THR x RAT grid its level offset is fitted on (fit_shift.py --suite).
SEQ_THR = (100, 80, 60)


def seq_matrix(seqs, thrs=SEQ_THR):
    return [(f"s{q}_thr{t}_rat{r}", {"SEQ": q, "THR": t, "RAT": r})
            for q in seqs for t in thrs for r in range(4)]


BANKS = "ABCDEFGH"


def pattern_number(p):
    """A pattern as the Rytm names it (A01 .. H16) or its number (1 .. 128), to
    its number: program change p - 1 selects it."""
    t = str(p).strip()
    m = re.fullmatch(r"([A-Ha-h])(\d{1,2})", t)
    n = BANKS.index(m[1].upper()) * 16 + int(m[2]) if m else int(t)
    if not 1 <= n <= 128 or (m and not 1 <= int(m[2]) <= 16):
        raise SystemExit(f"no pattern {t}: A01 .. H16, or 1 .. 128")
    return n


def pattern_name(n):
    return f"{BANKS[(n - 1) // 16]}{(n - 1) % 16 + 1:02d}"


def slots(spec):
    """Patterns from a list such as A01-A08,B02 (or 1-8,18): their numbers."""
    out = []
    for part in str(spec).split(","):
        a, _, b = part.partition("-")
        out += list(range(pattern_number(a), pattern_number(b or a) + 1))
    return out


def check_voices(lvl, tag):
    if max(lvl[2:10]) < -60:
        raise SystemExit(f"{tag}: every voice slot is silent - is the pattern playing (TRANSPORT "
                         f"RECEIVE on in the Rytm's MIDI CONFIG), and does it have content?")


def switched(prev, lvl, tag):
    """Stop if a pattern switch did not take: the voice slots' levels match the
    previous pattern's to within a fraction of a dB. A pattern that blocks a
    change otherwise repeats silently."""
    if prev is not None and np.max(np.abs(np.asarray(prev) - lvl[2:10])) < 0.5:
        raise SystemExit(f"{tag}: the voice slots match the previous pattern's - the "
                         f"pattern change did not take")
    return lvl[2:10]


# name -> (channel: "fx" or "track", CC, the record's field and how its 8.8 word
# compares, or None when the record does not carry it)
CONTROLS = {**{p: ("fx", rig.CC[p], p) for p in cf.PARAMS},
            "DIST": ("fx", 70, "DIST"), "SYM": ("fx", 71, "SYM"),
            "DELAY": ("fx", 23, None), "REVERB": ("fx", 31, None),
            "LEVEL": ("track", 95, None), "PAN": ("track", 10, None)}


class Device:
    def __init__(self, track=None):
        self.cfg = rig.load_config()
        self.port = mido.open_output(self.cfg["midi_out"])
        self.fx = self.cfg["fx_channel"] - 1
        self.track = None if track is None else track - 1
        self.stream = rig.Stream(rig.find_device(), FS)
        self.playing = False

    def cc(self, name, v):
        if isinstance(name, int):                # a raw FX-channel CC
            self.port.send(mido.Message("control_change", channel=self.fx, control=name, value=int(v)))
            time.sleep(self.cfg.get("cc_settle_s", 0.05))
            return
        where, num, _ = CONTROLS[name]
        if where == "track" and self.track is None:
            raise SystemExit(f"{name} needs a track: --track, or the roles' tone track")
        ch = self.fx if where == "fx" else self.track
        self.port.send(mido.Message("control_change", channel=ch, control=num, value=int(v)))
        time.sleep(self.cfg.get("cc_settle_s", 0.05))

    def track_cc(self, track, num, v):
        """A CC on track `track`'s channel (track N on MIDI channel N)."""
        self.port.send(mido.Message("control_change", channel=track - 1, control=num, value=int(v)))
        time.sleep(self.cfg.get("cc_settle_s", 0.05))

    def note(self, track, on, velocity=100):
        """Trigger track `track`: note track - 1 on the auto channel. Notes 0-11
        trigger tracks 1-12, 12-59 play the selected track chromatically, and 60
        and up do nothing (measured 2026-09-25, midi-cc.md)."""
        self.port.send(mido.Message("note_on" if on else "note_off", channel=rig.AUTO_CHANNEL - 1,
                                    note=track - 1, velocity=velocity if on else 0))

    def flush(self):
        """Discard what the stream buffered while nothing read it - CC sends,
        waits - and the overflow flag that backlog raises."""
        s = self.stream.stream
        n = s.read_available
        if n:
            s.read(n)

    def capture(self, seconds):
        self.flush()
        x = self.stream.read(seconds)
        if x is None:
            raise SystemExit("the capture overran")
        return x

    def readback(self, seconds=0.3):
        c = cf.decode(self.capture(seconds))
        last = {k: int(v[-1]) for k, v in c.rec.items()}
        last["SYM"] = last["SYM_raw"] >> 8
        return last, c

    def set(self, want, timeout=4.0):
        """Send each control, then capture until every read-back one reads what
        was sent. Returns the last record."""
        for k, v in want.items():
            self.cc(k, v)
        check = {k: v for k, v in want.items() if not isinstance(k, int) and CONTROLS[k][2]}
        t0 = time.time()
        while True:
            last, _ = self.readback()
            off = {k: (v, last[CONTROLS[k][2]]) for k, v in check.items() if last[CONTROLS[k][2]] != v}
            if not off:
                return last
            if time.time() - t0 > timeout:
                raise SystemExit("did not take: " + ", ".join(f"{k} sent {a} reads {b}" for k, (a, b) in off.items()))

    def pattern(self, slot, settle=3.0, play=True):
        """Switch to pattern number `slot`, loading its kit, and start the
        sequencer if it is not running (MIDI Start: the Rytm's TRANSPORT RECEIVE
        on) - or with play False, stop it."""
        # The switch is made with the sequencer running: a program change while it
        # is stopped or paused does not load the new pattern's kit (test run,
        # 2026-09-25). To stop on a pattern, switch, let the kit load, then stop.
        if not self.playing:
            self.port.send(mido.Message("start"))
            self.playing = True
        self.port.send(mido.Message("program_change", channel=rig.AUTO_CHANNEL - 1, program=slot - 1))
        self.flush()
        self.stream.drain(settle)
        if not play:
            self.stop()

    def stop(self):
        """A full stop: MIDI Stop twice, as STOP twice on the Rytm. One Stop only
        pauses, and a paused Rytm holds a program change back rather than loading
        the new pattern's kit (test run, 2026-09-25)."""
        self.port.send(mido.Message("stop"))
        time.sleep(0.1)
        self.port.send(mido.Message("stop"))
        self.playing = False
        self.stream.drain(0.5)

    def close(self):
        if self.playing:
            self.stop()
        self.stream.close()
        self.port.close()


# The roll call: with the sequencer stopped on a pattern, to load its kit, each
# of these tracks played alone by MIDI note, its delay and reverb sends set so
# the hit leaves tails, and ROLL_GAP_S for the hit and its tails to die away.
# The twelve tracks share eight voices - 3 and 4, 7 and 8, 9 and 10, 11 and 12 -
# and these eight cover every one. The input stage finds each voice alone, and
# the returns alone, in what this records.
ROLL_TRACKS = (1, 2, 3, 5, 6, 7, 9, 11)
# Track 1..12 to physical voice (ROM 0x4025a070), and physical voice to receive
# slot (0x401ef1d0): compressor-hardware.md, "Voice order".
TRACK_VOICE = (0, 2, 7, 7, 1, 3, 5, 5, 4, 4, 6, 6)
VOICE_SLOT = (0, 3, 1, 4, 6, 5, 7, 2)


def track_slot(track):
    return VOICE_SLOT[TRACK_VOICE[track - 1]]
ROLL_GAP_S = 1.5
ROLL_HITS = 2                                   # per track: short sounds give few blocks each
ROLL_SEND = 64
CC_DELAY_SEND, CC_REVERB_SEND = 82, 83          # on a track's channel (midi-cc.md)
# On the FX channel, so the tails do not depend on the kit: Delay Time, Delay
# Feedback, Reverb Decay Time. Feedback 80 made the delay sustain itself at -4
# dBFS on the test run; 40 decays. Feedback goes back to 0 after the roll call.
ROLL_FX = {16: 48, 19: 40, 25: 80}
CC_DELAY_FEEDBACK = 19
RUNAWAY_DB = -20.0                              # MAIN over this with every voice silent


def roll_call_capture(dev, slot, settings):
    """-> one capture of every roll-call track played alone in turn, on
    pattern `slot`'s kit with the sequencer stopped, `settings` set once the kit
    has loaded (loading it resets what was set before). The sends stay changed
    in the working kit."""
    dev.pattern(slot, play=False)
    dev.set(settings)
    for num, v in ROLL_FX.items():
        dev.cc(num, v)
    for t in ROLL_TRACKS:
        dev.track_cc(t, CC_DELAY_SEND, ROLL_SEND)
        dev.track_cc(t, CC_REVERB_SEND, ROLL_SEND)
    dev.flush()
    parts = []
    for t in ROLL_TRACKS:
        for _ in range(ROLL_HITS):
            dev.note(t, True)
            part = dev.stream.read(ROLL_GAP_S / ROLL_HITS)
            dev.note(t, False)
            if part is None:
                raise SystemExit("the roll call's capture overran")
            parts.append(part)
        tail = dev.stream.read(ROLL_GAP_S)              # the returns' tails, alone
        if tail is None:
            break
        parts.append(tail)
        end = tail[-int(0.25 * FS):]
        if (np.sqrt(np.mean(end[:, :2] ** 2)) > 10 ** (RUNAWAY_DB / 20)
                and np.sqrt(np.mean(end[:, 2:10] ** 2, axis=0)).max() < 10 ** (-60 / 20)):
            dev.cc(CC_DELAY_FEEDBACK, 0)
            raise SystemExit(f"the returns stay over {RUNAWAY_DB:g} dB with every voice silent: the delay or "
                             "reverb is sustaining itself; delay feedback set to 0")
    dev.cc(CC_DELAY_FEEDBACK, 0)
    if len(parts) < len(ROLL_TRACKS) * (ROLL_HITS + 1) or any(p is None for p in parts):
        raise SystemExit("the roll call's capture overran")
    return np.concatenate(parts)


SLIM = (0, 1, 10, 11)


def snapshot():
    """The calibration the host would build: what a session records it ran on."""
    inc = ct.INC.read_text()
    return {"hash": ct.inc_hash(inc), "toml": ct.TOML.read_text(), "inc": inc}


# ---------------------------------------------------------------- runs on disk
# A calibration run is one directory, build/comp/runs/<run>/: run.json (when,
# the git commit, the rig, the roles, the calibration it started from), one
# directory per session holding session.json and its captures, fits/ with the
# output of every `fits`, and report.md. build/comp/current names the run new
# recordings go into.
RUNS = CAPTURES / "runs"


CURRENT = CAPTURES / "current"


SCRATCH = CAPTURES / "scratch"          # captures made outside a run: check, twin


_INDEX = {}                             # capture stem -> path, from loaded sessions


def run_dir():
    """The current run's directory; recording without one is refused."""
    if not CURRENT.exists():
        raise SystemExit("no calibration run: calibrate.py run new NAME")
    d = RUNS / CURRENT.read_text().strip()
    if not d.is_dir():
        raise SystemExit(f"the current run {d.name} is missing: calibrate.py run new NAME, or run use NAME")
    return d


def run_new(name):
    import subprocess
    d = RUNS / name
    if d.exists():
        raise SystemExit(f"run {name} exists: calibrate.py run use {name}")
    d.mkdir(parents=True)
    head = subprocess.run(["git", "-C", str(ct.ROOT), "rev-parse", "--short", "HEAD"],
                          capture_output=True, text=True).stdout.strip()
    dirty = subprocess.run(["git", "-C", str(ct.ROOT), "status", "--porcelain"],
                           capture_output=True, text=True).stdout.strip() != ""
    cfg = rig.load_config() if rig.CONFIG.exists() else {}
    rl = tomllib.loads(ROLES_FILE.read_text()).get("roles", {}) if ROLES_FILE.exists() else {}
    (d / "run.json").write_text(json.dumps({
        "run": name, "created": datetime.now().isoformat(timespec="seconds"),
        "commit": head + ("-dirty" if dirty else ""), "rig": cfg, "roles": rl,
        "calibration": snapshot()}, indent=1))
    CURRENT.write_text(name + "\n")
    print(f"run {name}: {d}")


def run_use(name):
    if not (RUNS / name).is_dir():
        raise SystemExit(f"no run {name}; runs: {', '.join(sorted(p.name for p in RUNS.glob('*'))) or 'none'}")
    CURRENT.write_text(name + "\n")
    print(f"current run {name}")


def run_show():
    d = run_dir()
    info = json.loads((d / "run.json").read_text())
    print(f"run {d.name}, created {info['created']} at {info['commit']}")
    for s in sorted(p for p in d.iterdir() if (p / "session.json").exists()):
        n = len(list(s.glob("*.wav")))
        print(f"  {s.name}" + (f"  ({n} captures)" if n else ""))


def session_path(name):
    """A session's directory: the current run's, else any run's."""
    if CURRENT.exists() and (RUNS / CURRENT.read_text().strip() / name / "session.json").exists():
        return RUNS / CURRENT.read_text().strip() / name
    hits = sorted(RUNS.glob(f"*/{name}/session.json"))
    if not hits:
        raise SystemExit(f"no session {name} in {RUNS}")
    return hits[-1].parent


def write_session(name, payload):
    d = run_dir() / name
    d.mkdir(parents=True, exist_ok=True)
    (d / "session.json").write_text(json.dumps({**payload, "calibration": snapshot()}, indent=1))


def load_session(name):
    """A session record by name (the current run, else any run) or path to its
    session.json. Its captures become loadable by stem."""
    p = Path(name) if name.endswith(".json") else session_path(name) / "session.json"
    rec = json.loads(p.read_text())
    rec["name"] = p.parent.name
    rec["dir"] = str(p.parent)
    for f in p.parent.glob("*.wav"):
        _INDEX[f.stem] = f
    return rec


def ran_on(rec):
    """-> (calibration.toml's values, the twin's constants) as the session's image
    ran them."""
    c = rec.get("calibration")
    if c is None:
        raise SystemExit(f"{rec['name']} does not record the calibration it ran on")
    return tomllib.loads(c["toml"]), sm.constants(c["inc"])


def sides_current(rec):
    """The recorded sides depend on [input] and [distortion]; a fit downstream of
    them is only as good as those. -> False, with a warning, if they changed."""
    c = rec.get("calibration")
    if c is None:
        print(f"warning: {rec['name']} does not record its calibration; its sides are taken as current")
        return True
    was, now = tomllib.loads(c["toml"]), ct.load()
    stale = [k for k in ("input", "distortion") if was[k] != now[k]]
    if stale:
        print(f"warning: {rec['name']} ran on a different [{'], ['.join(stale)}]: its sides are stale;"
              " record it again for a fit that depends on them")
    return not stale


def require_current(dev, sides_only=False):
    """Refuse to record unless the device runs the host's calib.inc. With
    sides_only, for verification, a calibration this run recorded with is
    enough if its [input] and [distortion] - all the sides depend on - are the
    host's: the twin scores the rest from the sides, so a calibration written
    since can be verified before it is flashed."""
    last, _ = dev.readback()
    want = ct.inc_hash(ct.INC.read_text())
    if last["calhash"] == want:
        return
    if sides_only:
        now = ct.load()
        for f in sorted(run_dir().glob("*/session.json")):
            snap = json.loads(f.read_text()).get("calibration", {})
            if snap.get("hash") != last["calhash"]:
                continue
            was = tomllib.loads(snap["toml"])
            if all(was[k] == now[k] for k in ("input", "distortion")):
                print(f"the device runs {last['calhash']:08x} (as {f.parent.name}); its sides match "
                      f"calib.inc {want:08x}, so the twin scores the current calibration")
                return
    raise SystemExit(f"the device runs calibration {last['calhash']:08x}, calib.inc is {want:08x}:"
                     " make comp-cal-build and flash it")


def save(x, session=None, stem=None, slim=False, pcm24=False):
    """A capture into its session's directory, or build/comp/scratch without one.
    slim keeps MAIN and channels 10 and 11 only, 24-bit."""
    d = run_dir() / session if session else SCRATCH
    d.mkdir(parents=True, exist_ok=True)
    stem = stem or f"cal_{datetime.now().strftime('%Y%m%d_%H%M%S')}"
    if slim:
        sf.write(d / f"{stem}.wav", x[:, SLIM], FS, subtype="PCM_24")
    elif pcm24:
        sf.write(d / f"{stem}.wav", x, FS, subtype="PCM_24")
    else:
        sf.write(d / f"{stem}.wav", x.astype(np.float32), FS)
    _INDEX[stem] = d / f"{stem}.wav"
    return stem


def capture_path(stem):
    if stem in _INDEX:
        return _INDEX[stem]
    hits = sorted(RUNS.glob(f"*/*/{stem}.wav")) + sorted(SCRATCH.glob(f"{stem}.wav"))
    if not hits:
        raise SystemExit(f"no capture {stem} under {CAPTURES}")
    return hits[-1]


def load(stem):
    """A capture as twelve columns; a slim one comes back with the slots zero."""
    x, fs = sf.read(capture_path(stem), dtype="float64")
    if x.shape[1] == len(SLIM):
        full = np.zeros((len(x), 12))
        full[:, SLIM] = x
        x = full
    return x


# ---------------------------------------------------------------- suites
FS_GUARD = 10 ** (-0.5 / 20)       # MAIN within 0.5 dB of full scale: left out


FLOOR_DB = -40.0                   # input below this: too quiet to measure GR on


def block_gr(c, q):
    """Per block: the measured reduction, dB, positive - the model input against
    MAIN, L + R, over the block's sixteen sample frames - and the blocks fit to
    score (the estimator ran, the input above FLOOR_DB, MAIN not at full scale)."""
    inp = cf.MAIN_PER_SIDE * (c.side_l + c.side_r)
    out = c.main[:, :, 0] + c.main[:, :, 1]
    ri = np.sqrt(np.mean(inp ** 2, axis=1))
    ro = np.sqrt(np.mean(out ** 2, axis=1))
    ok = (~c.rec["aside"]) & (ri > 10 ** (FLOOR_DB / 20)) & (np.max(np.abs(c.main), axis=(1, 2)) < FS_GUARD)
    meas = -20 * np.log10(np.maximum(ro, 1e-12) / (q * np.maximum(ri, 1e-12)))
    return meas, ok


def wet_q(c):
    """The wet path's gain at no reduction, from a reference capture."""
    inp = cf.MAIN_PER_SIDE * (c.side_l + c.side_r)
    out = c.main[:, :, 0] + c.main[:, :, 1]
    ri = np.sqrt(np.mean(inp ** 2, axis=1))
    ro = np.sqrt(np.mean(out ** 2, axis=1))
    use = (~c.rec["aside"]) & (ri > 10 ** (FLOOR_DB / 20))
    return float(np.median(ro[use] / ri[use]))


def side_peaks(c, s, q, C):
    """The detector's peak per block over the run s, from the recorded sides
    through the twin's sidechain for SEQ q and its peak follower, Q31 as a
    fraction. Floating point, so within about 0.001 dB of the device's."""
    return sm.peaks_from_sides(c.side_l[s], c.side_r[s], q, C)


# The calibration project's roles (compressor-calibration.md): the drum patterns
# the fits use and the ones kept back for verification, and the scratch pattern -
# empty, on a kit of its own - whose kit the roll call plays and whose tone track
# the tone stages turn into a sine. They belong to the project, so they are
# committed beside its dump, calibration_project.toml, and set with `calibrate.py
# roles`. Nothing here assumes a slot.
ROLES = ("fit", "verify", "scratch", "tone_track")
ROLES_FILE = ct.ROOT / "mods" / "0006-comp-preview" / "calibration_project.toml"


def roles():
    r = tomllib.loads(ROLES_FILE.read_text()).get("roles", {}) if ROLES_FILE.exists() else {}
    if any(k not in r for k in ROLES):
        raise SystemExit("the calibration project's roles are not set: calibrate.py roles --fit PATTERNS "
                         "--verify PATTERNS --scratch PATTERN --tone-track TRACK")
    return r


def save_roles(r):
    q = lambda v: f'"{v}"' if isinstance(v, str) else str(v)
    ROLES_FILE.write_text(
        "# The calibration project's roles: which patterns and which track play\n"
        "# each part of mod 0006's calibration (re/subsystems/compressor-calibration.md).\n"
        "# Written by calibrate.py roles; the project itself is calibration_project.syx.\n"
        "[roles]\n" + "".join(f"{k} = {q(r[k])}\n" for k in ROLES if k in r))


def dist_patterns(r):
    """Distortion and symmetry run on three of the fit patterns: the first three."""
    return ",".join(str(p) for p in slots(r["fit"])[:3])


GRID_CUTOFF = 33           # CC 74 for the grids' and release's tone: about 92 Hz


# The calibration project, committed: every calibration starts by sending it.
PROJECT = ct.ROOT / "mods" / "0006-comp-preview" / "calibration_project.syx"


def run_project(args):
    """The calibration project through the Rytm's own SysEx dump, byte for byte:
    --receive stores what it sends (SETTINGS > SYSEX DUMP > SEND, the project)
    until the port has been quiet for --idle seconds; --send plays a file back
    (SYSEX RECEIVE on the Rytm first), paced so it keeps up."""
    cfg = rig.load_config()
    if args.receive:
        Path(args.receive).parent.mkdir(parents=True, exist_ok=True)
        port = mido.open_input(cfg.get("midi_in", cfg["midi_out"]))
        print("waiting: start the project's SYSEX DUMP on the Rytm", flush=True)
        msgs, last = [], None
        while last is None or time.time() - last < args.idle:
            for m in port.iter_pending():
                if m.type == "sysex":
                    msgs.append(m); last = time.time()
            time.sleep(0.01)
        mido.write_syx_file(args.receive, msgs)
        print(f"wrote {args.receive}: {len(msgs)} messages, {sum(len(m.bin()) for m in msgs)} bytes")
    else:
        msgs = mido.read_syx_file(args.send)
        port = mido.open_output(cfg["midi_out"])
        for i, m in enumerate(msgs):
            port.send(m)
            time.sleep(args.pace)
        print(f"sent {args.send}: {len(msgs)} messages")
