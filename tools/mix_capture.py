"""Record a section of each of a list of patterns off the Rytm, over USB: MAIN
and the eight voice slots.

    mix_capture.py record A01-A04,B02 [--bars 8] [--no-split]

Each pattern is started clean: MIDI Stop, then CC 120 (All Sound Off), which
silences the voices and the delay and reverb tails within about 0.5 s as a
double STOP on the device does - a second MIDI Stop does not (measured
2026-09-27) - a gap, the program change on the auto channel, a wait for the new
kit to load, then Start from the pattern's first step. Starting before the kit
has loaded plays the first steps on a kit still changing over. The Rytm
needs MIDI input from USB, TRANSPORT RECEIVE on, CLOCK RECEIVE off, and
PROGRAM CHANGE RECEIVE on the auto channel.

With CLOCK SEND on, the tempo is read from the Rytm's MIDI clock after Start:
the settle time is rounded up to whole bars, so recording begins on a
downbeat, and `--bars` bars are recorded. Without clock, `--settle` and
`--seconds` are used as given.

Four track pairs share a voice: 3/4, 7/8, 9/10 and 11/12. Two further passes
per pattern split them, each with one track of every pair muted (CC 94, the
sequencer mute), so its partner plays the voice alone. `--no-split` skips them.

Captures go to build/mix/<run>/: <pattern>.wav (MAIN, stereo, 24-bit),
<pattern>_voices.wav (the eight voice slots), <pattern>_a_voices.wav and
_b_voices.wav (the solo passes), and <pattern>.json (tempo and length).
`mix_report.py analyse` reports on a run, and the voice_dac_* tools read one.
"""
import argparse
import json
import math
import sys
import time
from datetime import datetime
from pathlib import Path

import numpy as np
import soundfile as sf

sys.path.insert(0, str(Path(__file__).resolve().parent / "comp"))
import cal_io  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "build" / "mix"
FS = 48000
SILENT_DBFS = -60.0
CC_MUTE = 94                                          # sequencer mute, on the track's channel
CC_ALL_SOUND_OFF = 120                                # voices and FX tails, on any channel


def db(x, floor=1e-12):
    return 10 * np.log10(np.maximum(x, floor))


def slot_tracks(slot):
    """Receive slot -> the tracks that play on its voice."""
    voice = cal_io.VOICE_SLOT.index(slot)
    return [t + 1 for t, v in enumerate(cal_io.TRACK_VOICE) if v == voice]


SHARED = [s for s in range(8) if len(slot_tracks(s)) == 2]
# Solo pass a mutes the second track on each shared voice, pass b the first, so
# each shared slot carries one track alone. The muted track does not trigger,
# so it cannot steal the voice either.
SOLO_MUTES = {"a": [slot_tracks(s)[1] for s in SHARED], "b": [slot_tracks(s)[0] for s in SHARED]}
SHARED_TRACKS = sorted(sum(SOLO_MUTES.values(), []))


class Clock:
    """The Rytm's MIDI clock, timed as it arrives: 24 ticks a beat."""

    def __init__(self, name):
        self.ticks = []
        self.port = cal_io.mido.open_input(name, callback=self._on)

    def _on(self, msg):
        if msg.type == "clock":
            self.ticks.append(time.perf_counter())

    def reset(self):
        self.ticks = []

    def bpm(self):
        """The tempo from a line fitted through every tick's arrival time. The
        ticks come over USB with bursts (2.6 ms apart against 18.7), so the
        first and last alone read up to 1.5% off over a second."""
        t = np.array(self.ticks)
        if len(t) < 25:
            return None
        return float(60 / (24 * np.polyfit(np.arange(len(t)), t, 1)[0]))

    def close(self):
        self.port.close()


def play(dev, n, args, clock, mute=(), bpm=None):
    """Start pattern `n` clean with the tracks in `mute` muted and every other
    shared-voice track unmuted, and record it. The length comes from `bpm`, or
    the clock over the settle time. -> (capture, the tempo from the clock over
    the settle time and the capture, or `bpm`, or None)."""
    dev.port.send(cal_io.mido.Message("stop"))
    dev.port.send(cal_io.mido.Message("control_change", channel=cal_io.rig.AUTO_CHANNEL - 1,
                                      control=CC_ALL_SOUND_OFF, value=0))
    dev.stream.drain(args.gap)                           # All Sound Off takes about 0.5 s
    dev.port.send(cal_io.mido.Message("program_change", channel=cal_io.rig.AUTO_CHANNEL - 1,
                                      program=n - 1))
    dev.stream.drain(args.kit_wait)                      # the kit loads
    for t in SHARED_TRACKS:
        dev.track_cc(t, CC_MUTE, 127 if t in mute else 0)
    clock.reset()
    dev.port.send(cal_io.mido.Message("start"))
    dev.playing = True
    dev.flush()
    # The delay and reverb build over the settle time, counted in samples from
    # Start; the clock is read meanwhile, for up to 3 s.
    got = 0
    while got < args.settle * FS or (bpm is None and clock.bpm() is None and got < 3 * FS):
        if dev.stream.read(0.05) is None:
            raise SystemExit("the capture overran")
        got += int(0.05 * FS)
    bpm = bpm or clock.bpm()
    if bpm:
        bar = 240 / bpm
        rest = int(math.ceil(got / FS / bar) * bar * FS) - got   # to the next downbeat
        if rest and dev.stream.read(rest / FS) is None:
            raise SystemExit("the capture overran")
        seconds = args.bars * bar
    else:
        seconds = args.seconds
    x = dev.stream.read(seconds)
    if x is None:
        raise SystemExit("the capture overran")
    return x, clock.bpm() or bpm


def check_mutes(name, voices, solo):
    """Stop if the solo passes left every active shared slot where the full
    pass had it: the mutes did not take."""
    lv = lambda v, s: db(np.mean(v[:, s] ** 2))
    act = [s for s in SHARED if lv(voices, s) > SILENT_DBFS]
    if act and all(abs(lv(solo[k], s) - lv(voices, s)) < 0.3 for k in "ab" for s in act):
        raise SystemExit(f"{name}: the shared voices read the same muted as not - CC {CC_MUTE} "
                         f"did not mute (tracks {', '.join(map(str, SHARED_TRACKS))})")


def new_run():
    run = OUT / datetime.now().strftime("%Y%m%d_%H%M%S")
    run.mkdir(parents=True)
    return run


def record(args, run, each=None):
    """Record every pattern in `args.patterns` into `run`, calling
    `each(name, main, voices, solo, bpm)` after each one."""
    if args.bars % 2:
        raise SystemExit("--bars must be even, so each half of a capture is whole bars")
    patterns = cal_io.slots(args.patterns)
    dev = cal_io.Device()
    clock = Clock(dev.cfg.get("midi_in", dev.cfg["midi_out"]))
    prev = None
    try:
        for i, n in enumerate(patterns):
            name = cal_io.pattern_name(n)
            x, bpm = play(dev, n, args, clock)
            if bpm is None and not i:
                print("no MIDI clock from the Rytm (CLOCK SEND off?): recording --seconds",
                      flush=True)
            main, voices = x[:, :2], x[:, 2:10]
            if db(np.mean(main ** 2)) < SILENT_DBFS:
                raise SystemExit(f"{name}: MAIN is silent - is TRANSPORT RECEIVE on and CLOCK "
                                 f"RECEIVE off, and does the pattern have content?")
            lvl = np.concatenate([[0, 0], db(np.mean(voices ** 2, axis=0))])
            prev = cal_io.switched(prev, lvl, name)
            sf.write(run / f"{name}.wav", main, FS, subtype="PCM_24")
            sf.write(run / f"{name}_voices.wav", voices, FS, subtype="PCM_24")
            (run / f"{name}.json").write_text(json.dumps({"bpm": bpm, "seconds": len(x) / FS}) + "\n")
            solo = None
            if args.split:
                solo = {k: play(dev, n, args, clock, mute, bpm)[0][:, 2:10] for k, mute in SOLO_MUTES.items()}
                check_mutes(name, voices, solo)
                for k, v in solo.items():
                    sf.write(run / f"{name}_{k}_voices.wav", v, FS, subtype="PCM_24")
            if each:
                each(name, main, voices, solo, bpm)
            else:
                print(f"{name}: {bpm and f'{bpm:.1f}' or '-'} BPM", flush=True)
    finally:
        for t in SHARED_TRACKS:
            dev.track_cc(t, CC_MUTE, 0)
        clock.close()
        dev.close()


def add_args(r):
    r.add_argument("patterns", help="e.g. A01-A04,B02 or 1-4,18")
    r.add_argument("--bars", type=int, default=8, help="bars recorded per pattern, with clock; even")
    r.add_argument("--seconds", type=float, default=16.0, help="length recorded per pattern, without clock")
    r.add_argument("--settle", type=float, default=1.0,
                   help="least wait after Start before recording; with clock, rounded up to whole bars")
    r.add_argument("--gap", type=float, default=1.0, help="wait after Stop and All Sound Off")
    r.add_argument("--kit-wait", type=float, default=0.5, help="wait after the program change before Start")
    r.add_argument("--no-split", dest="split", action="store_false",
                   help="skip the two solo passes that split the shared voices into their tracks")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    add_args(sub.add_parser("record", help="play and record each pattern"))
    args = ap.parse_args()
    run = new_run()
    print(run, flush=True)
    record(args, run)


if __name__ == "__main__":
    main()
