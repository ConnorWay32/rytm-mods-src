"""A transient shaper for mod 0013's voice path, modelled offline on mix_capture runs.

    voice_dac_shaper.py RUN PATTERN --tracks 1,2 [--atk STEPS] [--sus STEPS]
                        [--mode block|sample] [--plot]

RUN is a build/mix/<run> directory recorded with DAC SUM on, so each voice slot
is the voice as the DAC path receives it. Each selected track's slot is shaped
and written to build/shaper/<run>/ beside its dry copy, and a mono sum of all
eight slots, dry and with the selected ones shaped, so the change can be heard
in context (no pan, no FX). A track that shares its voice (3/4, 7/8, 9/10,
11/12) is read from the solo pass that plays it alone when the run has one; in
the mix its slot carries both tracks, and both are shaped. A run recorded with
0013's timing build carries its timing words on slot 7 in place of the voice (a
12 kHz tone at about -4 dBFS); that slot is left out of the mix, and tracks 7
and 8, which play on it, cannot be shaped from such a run.

The model is the one planned for the ColdFire. Four followers on the level:
  Ef  instant attack, --rel-fast release      Es  --att-slow attack, --rel-slow release
  Eh  instant attack, --rel-hold release
Es releasing slower than Ef closes the attack gap once a hit decays; with one
release for both, a hit Es never caught up with keeps its gap through the tail.
the attack signal t = dB(Ef / Es) and the sustain signal s = dB(Eh / Ef), each
clipped to 0..--span and scaled to 0..1, give the gain in dB:
  g = atk * --step * t + sus * --step * s,   capped at +--max-boost
--mode block follows the ColdFire plan: the level is the peak of each 32-frame
block and the followers and gain move once a block. With --lag 0 a block's own
peak sets its gain, a first pass over the block measuring it before a second
scales it; with --lag 1 the gain comes a block late, from one pass that measures
and scales together. The gain is ramped across the block from the last one's,
or steps there at the block's start when it moves more than --jump dB, as at an
onset. --mode sample runs the same followers and gain on every sample, with no
delay, as the reference.

Reports, per track: the gain's range, the output peak against the input's (the
sum's headroom is about 12 dB), and the energy change in the first --onset-ms of
each hit against the rest.
"""
import argparse
import json
import math
import sys
from pathlib import Path

import numpy as np
import soundfile as sf

sys.path.insert(0, str(Path(__file__).resolve().parent / "comp"))
import cal_io  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "build" / "shaper"
BLOCK = 32
EPS = 1e-9


def db(x):
    return 20 * np.log10(np.maximum(x, EPS))


def coef(tau_ms, dt):
    """One-pole smoothing per step of dt seconds; 0 ms is instant."""
    return 0.0 if tau_ms <= 0 else math.exp(-dt / (tau_ms / 1000))


def follow(level, att, rel):
    """Peak follower over a level sequence, attack and release coefficients."""
    out = np.empty_like(level)
    e = 0.0
    for i, p in enumerate(level):
        c = att if p > e else rel
        e = p + c * (e - p)
        out[i] = e
    return out


def gain_db(level, dt, a):
    """The shaper's gain in dB for a level sequence sampled every dt seconds."""
    ef = follow(level, 0.0, coef(a.rel_fast, dt))
    es = follow(level, coef(a.att_slow, dt), coef(a.rel_slow, dt))
    eh = follow(level, 0.0, coef(a.rel_hold, dt))
    t = np.clip(db(ef) - db(es), 0, a.span) / a.span
    s = np.clip(db(eh) - db(ef), 0, a.span) / a.span
    # below the gate the followers carry noise; hold the gain at unity there
    live = db(eh) > a.gate
    g = (a.atk * a.step * t + a.sus * a.step * s) * live
    return np.minimum(g, a.max_boost)


def shape(x, fs, a):
    """x shaped; also the per-sample gain applied, in dB."""
    if a.mode == "sample":
        g = gain_db(np.abs(x), 1 / fs, a)
        return x * 10 ** (g / 20), g
    n = len(x) // BLOCK * BLOCK
    peaks = np.abs(x[:n]).reshape(-1, BLOCK).max(axis=1)
    gd = gain_db(peaks, BLOCK / fs, a)
    if a.lag:
        gd = np.r_[0.0, gd[:-1]]
    end = 10 ** (gd / 20)
    start = np.r_[1.0, end[:-1]]
    step = np.abs(np.r_[0.0, np.diff(gd)]) > a.jump
    start[step] = end[step]
    ramp = (np.arange(1, BLOCK + 1) / BLOCK)[None, :]
    gs = (start[:, None] + (end - start)[:, None] * ramp).ravel()
    gs = np.r_[gs, np.full(len(x) - n, gs[-1] if n else 1.0)]
    return x * gs, db(gs)


def onsets(x, fs, gate_db, min_gap_s=0.05):
    """Sample indices where a 5 ms window's peak is above the gate and 6 dB above
    the 20 ms before it, at least min_gap_s apart: hits, not the cycles of one."""
    hop = int(0.005 * fs)
    n = len(x) // hop
    lv = db(np.abs(x[:n * hop]).reshape(n, hop).max(axis=1))
    idx, last = [], -10**9
    for k in range(4, n):
        if lv[k] > gate_db and lv[k] - lv[k - 4:k].max() > 6 and (k - last) * hop > min_gap_s * fs:
            idx.append(k * hop)
            last = k
    return idx


def onset_change(x, y, fs, hits, onset_ms):
    """Energy change, dB, in the first onset_ms of each hit and in the rest of it."""
    on, rest = [], []
    w = int(onset_ms / 1000 * fs)
    ends = hits[1:] + [len(x)]
    for h, e in zip(hits, ends):
        a, b = slice(h, min(h + w, e)), slice(min(h + w, e), e)
        for sl, acc in ((a, on), (b, rest)):
            ex, ey = np.sum(x[sl] ** 2), np.sum(y[sl] ** 2)
            if ex > EPS:
                acc.append(10 * math.log10(max(ey, EPS) / ex))
    return (np.median(on) if on else float("nan"), np.median(rest) if rest else float("nan"))


def timing_slot(v):
    """The slot carrying 0013's timing words, tagged 0xa5, 0x5a, 0x3c, 0xc3 in
    the top byte of four frames in turn, from whichever frame the recording
    began on, or None."""
    top = (np.round(v[:4096] * 2**23).astype(np.int64) >> 16) & 0xff
    tags = (0xa5, 0x5a, 0x3c, 0xc3)
    for s in range(v.shape[1]):
        for ph in range(4):
            if all(np.all(top[k::4, s] == tags[(k + ph) % 4]) for k in range(4)):
                return s
    return None


def track_source(run, pat, track):
    """(file, slot) holding the track alone, or with its partner when no solo pass."""
    slot = cal_io.track_slot(track)
    shared = [t for t in range(1, 13) if cal_io.track_slot(t) == slot]
    if len(shared) == 2:
        pas = "a" if track == shared[0] else "b"
        f = Path(run) / f"{pat}_{pas}_voices.wav"
        if f.exists():
            return f, slot, True
    return Path(run) / f"{pat}_voices.wav", slot, len(shared) == 1


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("run")
    ap.add_argument("pattern")
    ap.add_argument("--tracks", required=True, help="voice tracks, e.g. 1,2,5")
    ap.add_argument("--atk", type=float, default=0, help="attack steps, -3..3")
    ap.add_argument("--sus", type=float, default=0, help="sustain steps, -3..3")
    ap.add_argument("--step", type=float, default=4.0, help="dB per step at a full-scale signal")
    ap.add_argument("--span", type=float, default=12.0, help="dB of follower gap for a full-scale signal")
    ap.add_argument("--att-slow", type=float, default=15.0, help="slow follower attack, ms")
    ap.add_argument("--rel-fast", type=float, default=40.0, help="release of Ef, ms")
    ap.add_argument("--rel-slow", type=float, default=150.0, help="release of Es, ms")
    ap.add_argument("--rel-hold", type=float, default=300.0, help="release of Eh, ms")
    ap.add_argument("--gate", type=float, default=-60.0, help="dBFS below which the gain stays 0 dB")
    ap.add_argument("--max-boost", type=float, default=6.0, help="dB")
    ap.add_argument("--mode", choices=("block", "sample"), default="block")
    ap.add_argument("--lag", type=int, choices=(0, 1), default=0, help="blocks of gain delay, block mode")
    ap.add_argument("--jump", type=float, default=3.0, help="dB of gain change that steps rather than ramps")
    ap.add_argument("--onset-ms", type=float, default=15.0)
    ap.add_argument("--plot", action="store_true", help="a PNG of each track's first hits")
    a = ap.parse_args()

    run = Path(a.run)
    out = OUT / run.name
    out.mkdir(parents=True, exist_ok=True)
    tag = f"atk{a.atk:+g}_sus{a.sus:+g}_{a.mode}" + (f"_lag{a.lag}" if a.mode == "block" else "")
    tracks = [int(t) for t in a.tracks.split(",")]

    mix, fs = sf.read(run / f"{a.pattern}_voices.wav", dtype="float64")
    tslot = timing_slot(mix)
    if tslot is not None:
        print(f"slot {tslot} holds the timing build's words, not a voice: left out of the mix")
        mix[:, tslot] = 0
        bad = [t for t in tracks if cal_io.track_slot(t) == tslot]
        if bad:
            sys.exit(f"tracks {bad} play on slot {tslot}, which this run does not carry")
    shaped_mix = mix.copy()
    report = {}
    for tr in tracks:
        f, slot, alone = track_source(run, a.pattern, tr)
        v, fs = sf.read(f, dtype="float64")
        x = v[:, slot]
        y, g = shape(x, fs, a)
        hits = onsets(x, fs, a.gate + 20)
        on, rest = onset_change(x, y, fs, hits, a.onset_ms)
        pk_in, pk_out = db(np.max(np.abs(x))), db(np.max(np.abs(y)))
        live = g[np.abs(g) > 0.01]
        report[tr] = {"slot": slot, "alone": alone, "hits": len(hits),
                      "gain_min_db": float(live.min()) if live.size else 0.0,
                      "gain_max_db": float(live.max()) if live.size else 0.0,
                      "peak_in_dbfs": float(pk_in), "peak_out_dbfs": float(pk_out),
                      "onset_change_db": float(on), "rest_change_db": float(rest)}
        print(f"track {tr:2} slot {slot} ({'alone' if alone else 'shares its voice'}), {len(hits)} hits: "
              f"gain {report[tr]['gain_min_db']:+.1f}..{report[tr]['gain_max_db']:+.1f} dB, "
              f"peak {pk_in:.1f} -> {pk_out:.1f} dBFS, first {a.onset_ms:g} ms {on:+.1f} dB, rest {rest:+.1f} dB")
        sf.write(out / f"{a.pattern}_t{tr}_dry.wav", x, fs, subtype="PCM_24")
        sf.write(out / f"{a.pattern}_t{tr}_{tag}.wav", y, fs, subtype="PCM_24")
        # the mix is the main take, where a shared slot carries both its tracks
        shaped_mix[:, slot], _ = shape(mix[:, slot], fs, a)
        if a.plot:
            plot(out / f"{a.pattern}_t{tr}_{tag}.png", x, y, g, fs, hits, tr, a)

    dry_sum, wet_sum = mix.sum(axis=1), shaped_mix.sum(axis=1)
    scale = 0.5 / max(np.max(np.abs(dry_sum)), np.max(np.abs(wet_sum)), EPS)
    sf.write(out / f"{a.pattern}_mix_dry.wav", dry_sum * scale, fs, subtype="PCM_24")
    sf.write(out / f"{a.pattern}_mix_t{'-'.join(map(str, tracks))}_{tag}.wav", wet_sum * scale, fs, subtype="PCM_24")
    (out / f"{a.pattern}_{tag}.json").write_text(json.dumps({"args": vars(a), "tracks": report}, indent=1))
    print(f"wrote {out}/{a.pattern}_*  (mix files share one scale, so they compare by ear)")


def plot(path, x, y, g, fs, hits, tr, a):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    if not hits:
        return
    h0 = max(hits[0] - int(0.01 * fs), 0)
    h1 = min(hits[min(3, len(hits) - 1)] + int(0.3 * fs), len(x))
    t = np.arange(h0, h1) / fs * 1000
    fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(11, 6), sharex=True)
    ax1.plot(t, x[h0:h1], lw=0.5, label="dry", color="0.6")
    ax1.plot(t, y[h0:h1], lw=0.5, label="shaped", color="C0")
    ax1.set_ylabel("level")
    ax1.legend(loc="upper right")
    ax1.set_title(f"track {tr}: atk {a.atk:+g}, sus {a.sus:+g}, {a.mode} mode")
    ax2.plot(t, g[h0:h1], color="C1")
    ax2.set_ylabel("gain, dB")
    ax2.set_xlabel("ms")
    ax2.grid(alpha=0.3)
    fig.tight_layout()
    fig.savefig(path, dpi=110)
    plt.close(fig)


if __name__ == "__main__":
    main()
