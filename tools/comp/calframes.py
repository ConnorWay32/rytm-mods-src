"""Decode mod 0006's calibration frames from a twelve-channel USB capture.

A `cal` build (mod.toml) writes USB channels 10 and 11 itself. Each 32-frame block
splits in two: on the frames the sample path uses (0, 2 .. 30) the channels carry
the model's L and R sides; on the others (1, 3 .. 31) they carry a tagged record
of the block, word k on frame 2*(k/2) + 1, channel 10 for even k and 11 for odd.
A record word is (0x5A ^ k) << 24 | data << 8 (cal_out in stub.s has the fields).

decode() locks onto the tags, keeps every block whose 32 tags arrived intact, and
returns per block the record, the sixteen sides and the MAIN and slot frames
beside them. Nothing is assumed about where a capture starts.
"""
from dataclasses import dataclass

import numpy as np

BLOCK = 32
HALF = BLOCK // 2
TAGS = np.array([0x5A ^ k for k in range(BLOCK)])
PARAMS = ("THR", "ATK", "REL", "RAT", "SEQ", "MUP", "MIX", "VOL")
# MAIN in the units of a side as the stub carries it: MAIN is 90.49 x the side
# sum (calibration.toml, [distortion] main_per_side), and the cal build writes each side x64
# after the saturation (record word 24 = 1, MUP 0) or x8 before it (2, MUP set).
SIDE_SCALE = {1: 64, 2: 8}
MAIN_PER_SIDE = 90.49


@dataclass
class Capture:
    rec: dict            # per block: name -> np.array, one entry per block
    side_l: np.ndarray   # (blocks, 16): the model's side, Q31 as a fraction
    side_r: np.ndarray
    main: np.ndarray     # (blocks, 16, 2): MAIN L, R on the sample frames
    slots: np.ndarray    # (blocks, 16, 8): the voice slots on the sample frames
    cal: int             # the build's cal value, from the record
    lost: int            # blocks missing from the count between kept ones
    bad: int             # blocks whose tags did not all arrive


def words(x):
    """Samples -> 32-bit words as the receive buffer held them."""
    return np.round(x.astype(np.float64) * 2.0 ** 31).astype(np.int64)


def record_index():
    """(frame within the block, channel) of each record word."""
    k = np.arange(BLOCK)
    return 2 * (k // 2) + 1, 10 + (k & 1)


def lock(w10, w11):
    """The frame offset of a block start: the offset whose record tags match on
    the most blocks of the first two hundred."""
    fr, ch = record_index()
    best, where = 0, None
    n = min(len(w10) // BLOCK - 1, 200)
    for o in range(BLOCK):
        idx = o + np.arange(n)[:, None] * BLOCK + fr[None, :]
        t = np.where(ch[None, :] == 10, w10[idx], w11[idx])
        good = np.sum(np.all(((t >> 24) & 0xFF) == TAGS, axis=1))
        if good > best:
            best, where = good, o
    return where


def decode(x):
    """x: (samples, 12) float capture -> Capture."""
    w10, w11 = words(x[:, 10]), words(x[:, 11])
    o = lock(w10, w11)
    if o is None:
        raise SystemExit("no calibration frames on USB channels 10 and 11 - is a cal build running?")
    n = (len(x) - o) // BLOCK
    base = o + np.arange(n)[:, None] * BLOCK
    fr, ch = record_index()
    idx = base + fr[None, :]
    rw = np.where(ch[None, :] == 10, w10[idx], w11[idx])
    good = np.all(((rw >> 24) & 0xFF) == TAGS, axis=1)
    d = (rw >> 8) & 0xFFFF
    d, base = d[good], base[good]

    u32 = lambda i: d[:, i] | (d[:, i + 1] << 16)
    s16 = lambda i: np.where(d[:, i] >= 32768, d[:, i] - 65536, d[:, i])
    rec = {"blk": u32(0)}
    for i, p in enumerate(PARAMS):
        rec[p] = d[:, 2 + i] >> 8
        rec[p + "_raw"] = d[:, 2 + i]
    rec.update(DIST=d[:, 10] >> 8, DIST_raw=d[:, 10], SYM_raw=d[:, 11],
               peak=u32(12), level=s16(14), demand=s16(15), gr=s16(16),
               aside=(d[:, 17] & 1).astype(bool), run=u32(18), interval=u32(20),
               queue=d[:, 22], bg=d[:, 23], cal=d[:, 24], calhash=u32(25))
    cal = int(np.bincount(rec["cal"]).argmax()) if len(d) else 0
    if cal not in SIDE_SCALE:
        raise SystemExit(f"the record says cal = {cal}; this decoder knows 1 and 2")

    sf = base + 2 * np.arange(HALF)[None, :]
    scale = SIDE_SCALE[cal]
    gaps = np.diff(rec["blk"]) & 0xFFFFFFFF
    return Capture(rec=rec, side_l=x[sf, 10].astype(np.float64) / scale,
                   side_r=x[sf, 11].astype(np.float64) / scale,
                   main=x[sf][:, :, 0:2].astype(np.float64),
                   slots=x[sf][:, :, 2:10].astype(np.float64), cal=cal,
                   lost=int(np.sum(gaps[gaps > 1] - 1)), bad=int(np.sum(~good)))


def runs(c):
    """Index ranges of consecutive blocks (no lost block between), as slices."""
    breaks = np.nonzero((np.diff(c.rec["blk"]) & 0xFFFFFFFF) != 1)[0] + 1
    edges = np.r_[0, breaks, len(c.rec["blk"])]
    return [slice(a, b) for a, b in zip(edges[:-1], edges[1:]) if b > a]
