"""Synthetic check of a calibration run's verification and report, with no
hardware: captures laid out as the cal build writes them, from a device that
behaves exactly as the twin does, recorded into a temporary run. The device and
the twin must then score within rounding of the measured reduction, and the
run's report must carry the verification."""
import json
import sys
import tempfile
from pathlib import Path

import numpy as np

import calframes as cf
import cal_io as cio
import cal_suite as cs
import calib_tables as ct
import stub_model as sm

HASH = ct.inc_hash(ct.INC.read_text())


def encode(sides, params, gr_q8, main, cal=1, voices=None, level_q8=None):
    """-> a (samples, 12) capture: per block the record (params, gr, the hash,
    and the level if given) and the sides, MAIN and the voice slots (blocks, 16,
    8) if given on the frames the sides use."""
    nb = len(sides[0])
    x = np.zeros((nb * cf.BLOCK, 12))
    k = np.arange(cf.BLOCK)
    fr, ch = cf.record_index()
    for b in range(nb):
        d = np.zeros(cf.BLOCK, dtype=np.int64)
        blk = 5000 + b
        d[0], d[1] = blk & 0xFFFF, blk >> 16
        for i, p in enumerate(cf.PARAMS):
            d[2 + i] = params[p] << 8
        d[10], d[11] = params["DIST"] << 8, params["SYM"] << 8
        d[16] = int(gr_q8[b]) & 0xFFFF
        if level_q8 is not None:
            d[14] = int(level_q8[b]) & 0xFFFF
        d[24] = cal
        d[25], d[26] = HASH & 0xFFFF, HASH >> 16
        o = b * cf.BLOCK
        x[o:o + cf.BLOCK:2, 10] = np.round(sides[0][b] * cf.SIDE_SCALE[cal] * 2**31) / 2**31
        x[o:o + cf.BLOCK:2, 11] = np.round(sides[1][b] * cf.SIDE_SCALE[cal] * 2**31) / 2**31
        x[o:o + cf.BLOCK:2, 0:2] = main[b]
        if voices is not None:
            x[o:o + cf.BLOCK:2, 2:10] = voices[b]
        for j in k:
            x[o + fr[j], ch[j]] = ((((0x5A ^ j) << 24) | (int(d[j]) << 8)) & 0xFFFFFFFF) / 2**31
    x[x >= 1.0] -= 2.0                      # the tagged words as the signed samples USB carries
    return x


def drums(rng, nb):
    """Per block, 16 samples a side: decaying noise bursts, a hit every 20 blocks."""
    t = np.arange(nb * cf.HALF)
    env = np.exp(-(t % (20 * cf.HALF)) / 60.0)
    s = rng.normal(0, 1, len(t)) * env * 2e-3
    return s.reshape(nb, cf.HALF)


def capture(rng, params, q, nb=400, deep=0):
    """A device that is the twin: its GR is the twin's from its own sides, and
    MAIN is the input times q, reduced by that GR, block by block. deep: dB the
    device's reported GR reads deeper than the reduction it applied."""
    sl = drums(rng, nb); sr = 0.8 * sl
    inp = cf.MAIN_PER_SIDE * (sl + sr)
    x = encode((sl, sr), params, np.zeros(nb), np.stack([inp, inp], axis=-1) * q / 2)
    c = cf.decode(x)
    gr, valid = cs.twin_gr(c, sm.constants())
    gr = np.nan_to_num(gr)
    g = np.round(gr * 256)
    gain = q * 10 ** (-g / 256 / 20)
    return encode((sl, sr), params, g + round(deep * 256), np.stack([inp, inp], axis=-1) * gain[:, None, None] / 2)


def record(rng, session, q, deep=0):
    base = {"THR": 127, "ATK": 0, "REL": 0, "RAT": 2, "SEQ": 0, "MUP": 0, "MIX": 127, "VOL": 127,
            "DIST": 0, "SYM": 64}
    rows = []
    stem = cio.save(capture(rng, base, q), session, stem=f"{session}_A01_ref", slim=True)
    rows.append({"pattern": 1, "condition": "ref", "stem": stem, "q_db": 20 * np.log10(q)})
    for i in range(12):
        d = cs.draw_settings(rng)
        p = {**base, **{k: v for k, v in d.items() if k in base}}
        stem = cio.save(capture(rng, p, q, deep=deep), session, stem=f"{session}_A01_v{i:03d}", slim=True)
        rows.append({"pattern": 1, "condition": f"v{i:03d}", "stem": stem, "settings": d})
    cio.write_session(session, {"seed": 7, "patterns": "1", "draws": 12, "ranges": cs.VERIFY_DRAW,
                               "rows": rows})
    cs.verify_report(session)
    return json.loads((cio.run_dir() / session / "verify.json").read_text())["verdict"]


def main():
    rng = np.random.default_rng(7)
    with tempfile.TemporaryDirectory() as tmp:
        cio.RUNS, cio.CURRENT, cio.SCRATCH = Path(tmp) / "runs", Path(tmp) / "current", Path(tmp) / "scratch"
        cio.run_new("selftest")
        session = "calverify_selftest"
        v = record(rng, session, 0.3)
        for who in ("device", "twin"):
            assert v[who]["rms"] < 0.05 and abs(v[who]["mean"]) < 0.05, (who, v[who])
        w = record(rng, "calverify_deep", 0.3, deep=1.0)     # the device 1 dB deep
        assert abs(w["device"]["mean"] - 1.0) < 0.01 and abs(w["twin"]["mean"]) < 0.05, w
        cs.run_report(publish=False)
        rep = (cio.run_dir() / "report.md").read_text()
        assert "### Verification calverify_selftest" in rep and "Values changed" in rep
    print(f"verification: device {v['device']['rms']:.3f} dB rms, twin {v['twin']['rms']:.3f}; report: PASS")


if __name__ == "__main__":
    sys.exit(main())
