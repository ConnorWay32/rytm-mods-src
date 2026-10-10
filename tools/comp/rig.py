"""The rig for mod 0006's calibration: the Rytm's twelve-channel USB stream and
its MIDI port.

The stream is the audio interrupt's receive buffer verbatim - MAIN on 0-1, the
eight voice slots on 2-9, and on a cal build the model's sides and a record of
each block on 10-11 - so the device's input, its output and the estimator's
state arrive sample-aligned. MIDI sets the compressor and FX over CC on the FX
channel, switches patterns on the auto channel, and sets the tone track on its
own channel.

    calibrate.py devices                  list audio and MIDI ports
    calibrate.py setup --midi PORT --fx-channel N
                                          write build/comp_rig.json
"""
import json
import time
from pathlib import Path

import numpy as np
import sounddevice as sd

ROOT = Path(__file__).resolve().parent.parent.parent
CONFIG = ROOT / "build" / "comp_rig.json"
CAPTURES = ROOT / "build" / "comp"

# The compressor's CCs on the FX channel, from the manual's MIDI implementation
# chart (re/subsystems/midi-cc.md has the whole map).
CC = {
    "THR": 78,   # threshold
    "ATK": 79,   # attack time
    "REL": 80,   # release time
    "MUP": 81,   # makeup gain
    "RAT": 82,   # ratio
    "SEQ": 83,   # sidechain EQ
    "MIX": 84,   # dry/wet mix
    "VOL": 85,   # output volume
}
# The FX channel's return volumes, DIST and its symmetry, and the returns'
# PRE/POST routing (0 PRE, 1 POST).
CC_DELAY_VOL, CC_REVERB_VOL, CC_DIST = 23, 31, 70
CC_DIST_SYM, CC_DELAY_ROUTE, CC_REVERB_ROUTE = 71, 76, 77
# Program change on this channel switches pattern, with the pattern change mode
# set to DIRECT JUMP.
AUTO_CHANNEL = 14

# Four of the eight are enumerations, not 0..127. A CC value past the end of the
# list makes the device show ERR rather than clamping.
DISCRETE = {
    "ATK": ["0.03", "0.1", "0.3", "1", "3", "10", "30"],          # ms
    "REL": ["0.1", "0.2", "0.4", "0.6", "1", "2", "A1", "A2"],    # s, then auto
    # As the device labels them. The labels run against the behaviour: value 0
    # compresses hardest.
    "RAT": ["1:2", "1:4", "1:8", "MAX"],
    "SEQ": ["OFF", "LPF", "HPF", "HIT"],
}


def load_config() -> dict:
    if not CONFIG.exists():
        raise SystemExit(
            f"no rig config at {CONFIG}\n"
            f"run:  .venv/bin/python tools/comp/calibrate.py devices\n"
            f"then: .venv/bin/python tools/comp/calibrate.py setup --midi PORT --fx-channel N"
        )
    return json.loads(CONFIG.read_text())


def save_config(cfg: dict) -> None:
    CONFIG.parent.mkdir(parents=True, exist_ok=True)
    CONFIG.write_text(json.dumps(cfg, indent=2) + "\n")


def devices():
    """Print the audio inputs and MIDI ports, for setup."""
    print("audio inputs:")
    for i, d in enumerate(sd.query_devices()):
        if d["max_input_channels"]:
            print(f"  [{i:2}] {d['name']}  (in:{d['max_input_channels']})")
    try:
        import mido
        print("\nMIDI outputs:")
        for n in mido.get_output_names():
            print(f"  {n!r}")
        print("\nMIDI inputs:")
        for n in mido.get_input_names():
            print(f"  {n!r}")
    except Exception as e:
        print(f"\nMIDI unavailable: {e}")


def setup(midi, fx_channel, midi_in=None):
    """Write the rig config, keeping anything else it holds."""
    cfg = json.loads(CONFIG.read_text()) if CONFIG.exists() else {}
    cfg.update({"midi_out": midi, "fx_channel": fx_channel, "cc_settle_s": 0.05})
    if midi_in:
        cfg["midi_in"] = midi_in
    save_config(cfg)
    print(f"wrote {CONFIG}")
    for k, v in cfg.items():
        print(f"  {k}: {v}")


def open_midi(cfg):
    """Return a callable send(param, value) for the compressor's CCs."""
    import mido

    port = mido.open_output(cfg["midi_out"])
    ch = cfg["fx_channel"] - 1

    def send(param: str, value: int):
        if param not in CC:
            raise SystemExit(f"unknown parameter {param!r}; known: {', '.join(CC)}")
        if not 0 <= value <= 127:
            raise SystemExit(f"{param}={value} out of range 0..127")
        if param in DISCRETE and value >= len(DISCRETE[param]):
            names = ", ".join(f"{i}={n}" for i, n in enumerate(DISCRETE[param]))
            raise SystemExit(
                f"{param}={value} is past the end of its list; the device shows "
                f"ERR rather than clamping.\n  valid: {names}")
        port.send(mido.Message("control_change", channel=ch,
                               control=CC[param], value=value))
        # The device needs a moment to act on a parameter change before the
        # next capture is meaningful.
        time.sleep(cfg.get("cc_settle_s", 0.05))

    send.port = port
    return send


def find_device(name="Analog Rytm", want=12):
    """The input device's index, and say what was actually there when it is wrong.

    The Rytm presents different USB descriptors per USB CONFIG mode: the
    multichannel one enumerates as "Analog Rytm" with 12 in, the plain
    audio/MIDI one as "Elektron Analog Rytm MKII" with 2. Only the first
    carries the voice slots, so matching on the name alone picks the wrong
    device and records two channels of MAIN.
    """
    devs = list(enumerate(sd.query_devices()))
    named = [(i, d) for i, d in devs if name.lower() in d["name"].lower()]
    for i, d in named:
        if d["max_input_channels"] >= want:
            return i
    lines = [f"no input device matching {name!r} with {want} channels."]
    if named:
        lines.append("matched by name, but too few input channels:")
        lines += [f"  [{i}] {d['name']} - {d['max_input_channels']} in" for i, d in named]
        lines.append(f"the Rytm needs its USB CONFIG in the mode that enumerates"
                     f" {want} inputs; 2 inputs is MAIN only, with no voice slots.")
    lines.append("input devices seen:")
    lines += [f"  [{i}] {d['name']} - {d['max_input_channels']} in"
              for i, d in devs if d["max_input_channels"]]
    raise SystemExit("\n".join(lines))


class Stream:
    """One persistent input stream for the whole run.

    sd.rec() opens and closes a stream per call, and on this device that costs
    about two seconds during which the buffer is not yet real audio - a 2.5 s
    capture came back as silence, NaNs, or uninitialised memory reading
    +150 dBFS. Holding one stream open removes the startup entirely, and lets a
    settle period be read and discarded rather than slept through blind.
    """

    def __init__(self, device, fs, channels=12):
        self.fs = fs
        self.stream = sd.InputStream(samplerate=fs, channels=channels,
                                     dtype="float32", device=device,
                                     blocksize=1024)
        self.stream.start()

    def read(self, seconds):
        want = int(seconds * self.fs)
        out, got = [], 0
        while got < want:
            n = min(self.stream.read_available, want - got)
            if n <= 0:
                sd.sleep(5)
                continue
            data, over = self.stream.read(n)
            if over:
                return None
            out.append(np.asarray(data, dtype=np.float64)); got += n
        return np.concatenate(out) if out else None

    def drain(self, seconds):
        self.read(seconds)

    def close(self):
        self.stream.stop(); self.stream.close()
