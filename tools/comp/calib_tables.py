"""Generate mod 0006's calib.inc from calibration.toml, and check it is current.

mods/0006-comp-preview/calibration.toml holds every calibrated value in physical
units with where it came from. This turns it into calib.inc: the constants as
.equ and each table as a macro, which stub.s invokes where the table belongs, so
the image's layout does not depend on what is calibrated. stub_model.py reads the
same values through the stub, so the twin cannot drift from the device.

    calib_tables.py            write calib.inc
    calib_tables.py --check    fail if calib.inc is not what calibration.toml gives

The check also reports, for tables held as fitted values, how far the parameters
recorded beside them are from regenerating them.
"""
import argparse
import math
import tomllib
from pathlib import Path

import numpy as np

import fit_sidechain as fsc
import stub_model as sm

ROOT = Path(__file__).resolve().parent.parent.parent
MOD = ROOT / "mods" / "0006-comp-preview"
TOML = MOD / "calibration.toml"
INC = MOD / "calib.inc"
Q31 = 2 ** 31
FS = 48000
BLOCK = 32


def load():
    return tomllib.loads(TOML.read_text())


def decim():
    """The sample path's decimation, from stub.s: not calibration, but the
    sidechain and detector are quantised at its rate."""
    return sm.equ("DECIM")


def pole_q31(fs, tau):
    return int(round((1 - math.exp(-1 / (fs * tau))) * Q31))


def generate(cal):
    """-> (equs, tables): {name: int}, {name: (directive, [ints], per line)}."""
    inp, dist, sc, cur, bal = (cal[k] for k in ("input", "distortion", "sidechain", "curve", "ballistics"))
    d = decim()
    equs, tabs = {}, {}

    equs["CAL_DELAY"] = int(round(-Q31 / 8 * 10 ** (inp["delay_db"] / 20)))
    equs["CAL_REVERB"] = int(round(-Q31 / 8 * 10 ** (inp["reverb_db"] / 20)))
    tabs["trimtab"] = (".word", [min(32767, int(round(32767 * 10 ** (-t / 20)))) for t in inp["slot_trim_db"]], 8)

    g = dict(zip(dist["gain_dist"], dist["gain"]))
    g[128] = g[96] + (g[127] - g[96]) * 32 / 31
    tabs["disttab"] = (".word", [int(round(g[x] * 4096)) for x in (0, 32, 64, 96, 128)], 8)
    cp, cn = (int(round(c / dist["main_per_side"] * Q31)) for c in (dist["sat_c_pos"], dist["sat_c_neg"]))
    equs.update(SAT_CP=cp, SAT_CN=cn, SAT_RP=int(round(2 ** 38 / cp)), SAT_RN=int(round(2 ** 38 / cn)))
    n = dist["sat_order"]
    f = lambda u: u / (1 + u ** n) ** (1 / n)
    tabs["sattab"] = (".word", [int(round(f(k / 8) * 16384)) for k in range(33)], 17)
    # Symmetry: the bias in MAIN units, Q12, and SYM_K taking it to the side sum's
    # Q31 (c / 90.49, as SAT_CP); the gain in dB, Q8. SYM 0, 8 .. 128.
    tabs["symbias"] = (".word", [int(round(v * 4096)) for v in dist["sym_bias"]], 17)
    tabs["symgain"] = (".word", [int(round(v * 256)) for v in dist["sym_gain_db"]], 17)
    equs["SYM_K"] = int(round(Q31 / (dist["main_per_side"] * 4096)))

    secs = {s: sc[k] for s, k in enumerate(fsc.KEYS)}
    level = [a + b for a, b in zip(sc["level_db"], sc["transient_db"])]
    rows = fsc.quantised_rows(secs, level, FS / d)
    tabs["sctab"] = (".long", [w for s in range(4) for w in rows[s]], None)

    equs["DET_ALPHA_H"] = pole_q31(FS / d, cal["detector"]["tau_s"])
    equs["SILENCE_Q8"] = int(round(cal["gate"]["silence_db"] * 256))

    equs["THR_K"] = int(round(cur["thr_step_db"] * 4096))
    equs["GR_CAP"] = int(round(cur["cap_db"] * 256))
    rat = []
    for k, w, s in zip(cur["knee_db"], cur["width_db"], cur["slope"]):
        wq, kq = int(round(w * 256)), int(round(k * 256))
        if wq < 65 or not -32768 <= kq <= 32767:
            raise SystemExit("rattab: a width under 65 (2^22 / width overflows a word) or a knee past a word")
        rat.append([kq, wq, int(round(2 ** 22 / wq)), int(round(s * 4096))])
    tabs["rattab"] = (".word", [v for r in rat for v in r], 4)

    at = [min(65535, int(round((1 - math.exp(-BLOCK / (FS * a))) * 65536))) for a in bal["atk_s"]]
    tabs["atktab"] = (".word", at + [at[-1]], 8)             # the last repeats 30 ms
    tabs["reltab"] = (".word", list(bal["reltab_q16"]), 8)
    # atkscale: the table as stored, or generated from the coupling it was fitted as
    tabs["atkscale"] = (".byte", list(bal["atkscale"]) if "atkscale" in bal else atkscale_from_coupling(bal), 4)
    tabs["seqatk"] = (".byte", seqatk(bal["seq_atk_db"]), 7)
    return equs, tabs


def fmt(v):
    """A value as calibration.toml writes it: floats by repr, so they round-trip."""
    if isinstance(v, (list, tuple)):
        return "[" + ", ".join(fmt(x) for x in v) + "]"
    return repr(float(v)) if isinstance(v, float) else str(v)


def set_values(section, values, source):
    """Rewrite `key = value` lines of one section in place, keeping every comment,
    and note the source on the line: `key = value   # <source>`. Then regenerate
    calib.inc. Returns the old values."""
    import re
    text = TOML.read_text()
    m = re.search(rf"^\[{section}\]\s*$", text, re.M)
    if not m:
        raise SystemExit(f"no [{section}] in {TOML.name}")
    end = re.search(r"^\[", text[m.end():], re.M)
    body = text[m.end():m.end() + end.start()] if end else text[m.end():]
    old = load()[section]
    for k, v in values.items():
        pat = rf"^{k}\s*=\s*[^\n#]*(#[^\n]*)?$"
        if not re.search(pat, body, re.M):
            raise SystemExit(f"no {k} in [{section}]")
        body = re.sub(pat, f"{k} = {fmt(v)}   # {source}", body, count=1, flags=re.M)
    text = text[:m.end()] + body + (text[m.end() + end.start():] if end else "")
    TOML.write_text(text)
    INC.write_text(render(*generate(load())))
    return {k: old[k] for k in values}


def remove_value(section, key):
    """Remove `key = ...` from a section, a multi-line array included, with the
    comment lines directly above it. Then regenerate calib.inc."""
    import re
    text = TOML.read_text()
    m = re.search(rf"^\[{section}\]\s*$", text, re.M)
    end = re.search(r"^\[", text[m.end():], re.M)
    body = text[m.end():m.end() + end.start()] if end else text[m.end():]
    lines = body.split("\n")
    i = next((k for k, l in enumerate(lines) if re.match(rf"^{key}\s*=", l)), None)
    if i is None:
        return
    j = i
    if "[" in lines[i] and lines[i].count("[") > lines[i].count("]"):
        depth = lines[i].count("[") - lines[i].count("]")
        while depth > 0:
            j += 1
            depth += lines[j].count("[") - lines[j].count("]")
    k = i
    while k > 0 and lines[k - 1].startswith("#"):
        k -= 1
    del lines[k:j + 1]
    body = "\n".join(lines)
    text = text[:m.end()] + body + (text[m.end() + end.start():] if end else "")
    TOML.write_text(text)
    INC.write_text(render(*generate(load())))


def atkscale_from_coupling(bal):
    out = []
    for a in bal["atk_s"]:
        for r in bal["rel_eff_s"]:
            for C, p in bal["coupling"]:
                s = (1 + C * (bal["atk_s"][0] / r) ** p) / (1 + C * (a / r) ** p)
                out.append(int(min(255, max(0, round(s * 256 - 1)))))
    return out


def seqatk(c):
    """The dB off the demand per SEQ and ATK, 1/16 dB, index SEQ*7 + ATK:
    c[SEQ] * ATK / 6, c the dB at ATK 6."""
    return [int(min(255, max(0, round(16 * cq * a / 6)))) for cq in c for a in range(7)]


HASH_LINE = "        .equ    CAL_HASH,       "


def inc_hash(text):
    """CRC32 of a calib.inc without its CAL_HASH line: the fingerprint the cal
    build carries in its record, so a session knows what the device ran."""
    import zlib
    body = "".join(l for l in text.splitlines(keepends=True) if not l.startswith(HASH_LINE))
    return zlib.crc32(body.encode())


def render(equs, tabs):
    out = ["        | Generated by tools/comp/calib_tables.py from calibration.toml. Do not",
           "        | edit: change calibration.toml and run it. Each table is a macro, which",
           "        | stub.s invokes where the table sits. CAL_HASH is inc_hash() of the rest.", ""]
    for k, v in equs.items():
        out.append(f"        .equ    {k + ',':<15} {v}")
    for name, (directive, vals, per) in tabs.items():
        out += ["", f"        .macro  cal_{name}"]
        if name == "sctab":
            for s in range(4):
                w = vals[s * 7:(s + 1) * 7]
                out.append(f"        .long   {w[0]},{w[1]},{w[2]}")
                out.append(f"        .long   {w[3]},{w[4]},{w[5]}")
                out.append(f"        .long   {w[6]:<34}| {fsc.NAMES[s]}")
        else:
            for i in range(0, len(vals), per):
                out.append(f"        {directive:<7} " + ",".join(str(v) for v in vals[i:i + per]))
        out.append("        .endm")
    text = "\n".join(out) + "\n"
    return text.replace("\n\n", f"\n{HASH_LINE}{inc_hash(text):#010x}\n\n", 1)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args()
    cal = load()
    text = render(*generate(cal))
    if not args.check:
        INC.write_text(text)
        print(f"wrote {INC.relative_to(ROOT)}")
        return
    if "atkscale" in cal["ballistics"]:
        regen = np.array(atkscale_from_coupling(cal["ballistics"]))
        held = np.array(cal["ballistics"]["atkscale"])
        print(f"atkscale: the recorded coupling regenerates it to within {int(np.abs(regen - held).max())} "
              f"on {int((regen != held).sum())} of {len(held)} entries")
    else:
        print("atkscale: generated from [ballistics] coupling")
    if (INC.read_text() if INC.exists() else "") != text:
        raise SystemExit("FAIL: calib.inc is not what calibration.toml gives - run calib_tables.py")
    print("calib.inc matches calibration.toml: PASS")


if __name__ == "__main__":
    main()
