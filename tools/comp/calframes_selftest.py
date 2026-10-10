"""Synthetic checks for calframes.py: encode records and sides as cal_out writes
them, then decode. Touches no hardware."""
import numpy as np

import calframes as cf


def encode(blocks, cal=1, start=11, lose=(), damage=()):
    """-> a (samples, 12) capture: `blocks` records as cal_out lays them out, the
    capture starting `start` frames into a block, block numbers in `lose` never
    sent, the record of those in `damage` with one tag wrong."""
    rng = np.random.default_rng(1)
    frames, truth = [], []
    for b in range(blocks):
        if b in lose:
            continue
        d = np.zeros(32, dtype=np.int64)
        blk = 1000 + b
        d[0], d[1] = blk & 0xFFFF, blk >> 16
        d[2:10] = [(v << 8) for v in (100 + b % 20, 0, 1, 3, 1, 5, 127, 127)]
        d[10], d[11] = 64 << 8, 64 << 8
        peak = int(rng.integers(1, 2**31 - 1))
        d[12], d[13] = peak & 0xFFFF, peak >> 16
        d[14], d[15], d[16] = (-2000 - b) & 0xFFFF, 300 + b, 250 + b
        d[17] = b % 2
        d[24] = cal
        d[25], d[26] = HASH & 0xFFFF, HASH >> 16
        sl, sr = rng.uniform(-1e-3, 1e-3, 16), rng.uniform(-1e-3, 1e-3, 16)
        x = np.zeros((32, 12))
        x[:, :10] = rng.uniform(-0.5, 0.5, (32, 10))
        s = cf.SIDE_SCALE[cal]
        x[0::2, 10] = np.round(sl * s * 2**31) / 2**31
        x[0::2, 11] = np.round(sr * s * 2**31) / 2**31
        for k in range(32):
            tag = (0x5A ^ k) ^ (1 if (b in damage and k == 7) else 0)
            x[2 * (k // 2) + 1, 10 + (k & 1)] = ((tag << 24) | (int(d[k]) << 8)) / 2**31
        frames.append(x)
        if b not in damage:
            truth.append((blk, peak, -2000 - b, b % 2 == 1, sl, sr))
    cap = np.concatenate(frames)[start:]
    return cap, truth[1:] if start else truth


HASH = 0xE5F15EA9                     # a high bit set, as a CRC32 can have


def main():
    cap, truth = encode(40, cal=1, start=11, lose=(17,), damage=(25,))
    c = cf.decode(cap)
    assert c.cal == 1, c.cal
    assert list(c.rec["blk"]) == [t[0] for t in truth], "block numbers"
    assert list(c.rec["peak"]) == [t[1] for t in truth], "peak"
    assert list(c.rec["level"]) == [t[2] for t in truth], "signed level"
    assert list(c.rec["aside"]) == [t[3] for t in truth], "flags"
    assert c.lost == 2 and c.bad == 1, (c.lost, c.bad)     # 17 lost; 25 damaged
    assert np.allclose(c.side_l, [t[4] for t in truth], atol=1e-9)
    assert np.allclose(c.side_r, [t[5] for t in truth], atol=1e-9)
    assert (c.rec["THR"][:3] == [101, 102, 103]).all() and (c.rec["SEQ"] == 1).all()
    assert (c.rec["calhash"] == HASH).all(), "calibration hash"
    assert [s.stop - s.start for s in cf.runs(c)] == [16, 7, 14], [s.stop - s.start for s in cf.runs(c)]
    c2 = cf.decode(encode(20, cal=2, start=0)[0])
    assert c2.cal == 2
    print("calframes: records, sides, lost and damaged blocks, both cal values, the hash: PASS")


if __name__ == "__main__":
    main()
