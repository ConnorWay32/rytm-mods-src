"""Validate registry/allocations.toml: every claim inside its pool, no overlaps."""

import re
import tomllib
from pathlib import Path

# claim table -> the pattern of the pool names a claim may live in; each claim must fit
# wholly in one. Every pool named cave, cave2, cave3, ... holds cave claims.
POOL_OF = {"cave": r"cave\d*",
           "ram": r"patch_ram"}

# A pool at status "candidate" has not been proven on hardware, so the only thing
# allowed to claim it is the mod that does the proving. Without this the pools would
# simply be listed and the next feature mod would help itself to unverified space -
# which is the mistake octatrack-mods made once already. A probe earns the exception
# by being the experiment: it puts nothing in the image it is not willing to lose.
PROBE_SUFFIXES = ("-probe", "-canary")


def load(path: Path) -> dict:
    with open(path, "rb") as fh:
        return tomllib.load(fh)


def _overlaps(a_start, a_size, b_start, b_size):
    return a_start < b_start + b_size and b_start < a_start + a_size


def gated_out(gate, params, owner):
    """True if a claim's `gate` says to skip it.

    A gate names a mod param; the claim applies only when that param is truthy, a
    leading "!" inverts it, and `name==value` selects one of several. That is what lets
    two claims cover the same region with exactly one selected, so a mod can stage
    several phases from one region and still build each of them.

    Terms joined by "&" must all hold, so a claim can apply only when several params
    are off at once.

    An unknown param name aborts rather than silently disabling a claim.
    """
    if gate is None:
        return False
    if "&" in gate:
        return any(gated_out(g.strip(), params, owner) for g in gate.split("&"))
    if "==" in gate:
        name, _, want = gate.partition("==")
        name = name.strip()
        if name not in params:
            raise SystemExit(f"{owner}: gate {gate!r} names no param in mod.toml [params]")
        # "phase==3|4" selects a SET, so a claim shared by several phases needs one entry
        # rather than one per phase.
        return str(params[name]) not in {w.strip() for w in want.split("|")}
    negate = gate.startswith("!")
    name = gate[1:] if negate else gate
    if name not in params:
        raise SystemExit(f"{owner}: gate {gate!r} names no param in mod.toml [params]")
    return bool(params[name]) == negate


def load_excludes(root: Path) -> dict:
    """owner -> the owners it declares `excludes`, made symmetric.

    Two mods may implement the same feature different ways and deliberately claim the
    same region. They can never be in one image, so a collision between them is not a
    bug; a collision between either and anything else still is. Without this a
    standalone run, which treats every mod as active, reports the overlap forever and
    trains you to ignore the one check that catches real ones.
    """
    ex: dict[str, set] = {}
    for f in sorted((root / "mods").glob("*/mod.toml")):
        with open(f, "rb") as fh:
            m = tomllib.load(fh)
        mid = m["mod"]["id"]
        for other in m["mod"].get("excludes", []):
            ex.setdefault(mid, set()).add(other)
            ex.setdefault(other, set()).add(mid)
    return ex


def validate(reg: dict, enabled: set[str] | None = None, params: dict | None = None,
             excludes: dict | None = None) -> list[str]:
    """Return a list of human-readable problems; empty means the layout is sound.

    `params` maps owner -> that mod's [params]. Without it, gated claims are all treated
    as active, which makes two mutually exclusive claims on one region look like a
    collision - so build.py always passes it.
    """
    errors: list[str] = []
    excludes = excludes or {}
    pools = {p["name"]: p for p in reg.get("pool", [])}

    def exclusive(a, b):
        """True if these two claims belong to mods that can never share an image."""
        return b["owner"] in excludes.get(a["owner"], ())

    def active(claim):
        if not (enabled is None or claim["owner"] in enabled
                or claim["owner"].startswith("reserved:")):
            return False
        if params is None or claim["owner"] not in params:
            return True
        return not gated_out(claim.get("gate"), params[claim["owner"]], claim["owner"])

    for table, pattern in POOL_OF.items():
        claims = [c for c in reg.get(table, []) if active(c)]
        table_pools = [p for n, p in pools.items() if re.fullmatch(pattern, n)]
        if not table_pools:
            if claims:
                errors.append(f"{table}: no pool matching {pattern!r} is defined")
            continue
        for c in claims:
            lo, hi = c["addr"], c["addr"] + c["size"]
            home = next((p for p in table_pools
                         if p["start"] <= lo and hi <= p["end"]), None)
            if home is None:
                spans = ", ".join(f"{p['name']} 0x{p['start']:08x}..0x{p['end']:08x}"
                                  for p in table_pools)
                errors.append(
                    f"{table} claim by {c['owner']} at 0x{lo:08x}+0x{c['size']:x} "
                    f"does not fit wholly inside any pool ({spans})"
                )
            elif (home.get("status") == "candidate"
                  and not c["owner"].endswith(PROBE_SUFFIXES)):
                errors.append(
                    f"{table} claim by {c['owner']} at 0x{lo:08x}+0x{c['size']:x} is in "
                    f"pool {home['name']}, which is status \"candidate\" - not proven on "
                    f"hardware. Only a probe may claim it: run the experiment that "
                    f"promotes the pool, record the result in its note, and change its "
                    f"status. See the dead-code pool preamble in allocations.toml."
                )
        for i, a in enumerate(claims):
            for b in claims[i + 1:]:
                if exclusive(a, b):
                    continue
                if _overlaps(a["addr"], a["size"], b["addr"], b["size"]):
                    errors.append(
                        f"{table}: {a['owner']} (0x{a['addr']:08x}+0x{a['size']:x}) overlaps "
                        f"{b['owner']} (0x{b['addr']:08x}+0x{b['size']:x})"
                    )

    # A patch whose replacement equals what it expects changes nothing. That is always
    # either a copy-paste slip or a claim left behind after the value it targeted moved,
    # and it is invisible in the build log among dozens of real patches.
    for c in [q for q in reg.get("patch", []) if active(q)]:
        if "replace" in c and c.get("expect") == c.get("replace"):
            errors.append(
                f"patch by {c['owner']} at 0x{c['addr']:08x}: replace == expect "
                f"({c.get('expect')}) - the claim does nothing")

    patches = [q for q in reg.get("patch", []) if active(q)]
    for q in patches:
        if ("replace" in q) == ("from_symbol" in q):
            errors.append(
                f"patch by {q['owner']} at 0x{q['addr']:08x}: needs exactly one of "
                f"`replace` (literal bytes) or `from_symbol` (a label in its own stub)")
            continue
        want = bytes.fromhex(q["expect"])
        # from_symbol writes a 4-byte address resolved at build time, so that a stub edit
        # cannot leave a pointer aimed at where a routine used to be.
        repl = bytes.fromhex(q["replace"]) if "replace" in q else bytes(4)
        if len(want) != q["size"] or len(repl) != q["size"]:
            errors.append(
                f"patch by {q['owner']} at 0x{q['addr']:08x}: expect/replace must both be "
                f"exactly {q['size']} bytes (got {len(want)}/{len(repl)})"
            )

    detours = [d for d in reg.get("detour", []) if active(d)]
    for i, a in enumerate(patches):
        for b in patches[i + 1:]:
            if _overlaps(a["addr"], a["size"], b["addr"], b["size"]):
                errors.append(
                    f"patch: {a['owner']} and {b['owner']} both claim 0x{a['addr']:08x}"
                )
        for b in detours:
            if _overlaps(a["addr"], a["size"], b["addr"], b["size"]):
                errors.append(
                    f"patch by {a['owner']} at 0x{a['addr']:08x} overlaps detour by "
                    f"{b['owner']} at 0x{b['addr']:08x}"
                )
    for i, a in enumerate(detours):
        for b in detours[i + 1:]:
            # Mutually exclusive mods may share a host: they are never in one image, so
            # there is nothing to chain.
            if exclusive(a, b):
                continue
            if _overlaps(a["addr"], a["size"], b["addr"], b["size"]):
                errors.append(
                    f"detour: {a['owner']} and {b['owner']} both claim 0x{a['addr']:08x}. "
                    f"Two mods on one host must chain explicitly: give them distinct "
                    f"chain_pos values and have the earlier stub jmp to the later one "
                    f"instead of back to the host."
                )
    for d in detours:
        if d["size"] != 6:
            errors.append(
                f"detour by {d['owner']} at 0x{d['addr']:08x} has size {d['size']}; "
                f"only 6 (jmp abs.l) is supported"
            )
        # expect covers the whole displaced span the stub re-emits, which may be longer
        # than the 6 bytes actually overwritten by the jmp.
        if len(bytes.fromhex(d["expect"])) < d["size"]:
            errors.append(
                f"detour by {d['owner']} at 0x{d['addr']:08x}: expect is only "
                f"{len(bytes.fromhex(d['expect']))} bytes, must cover at least "
                f"the {d['size']} overwritten"
            )
        if not d.get("entry"):
            errors.append(
                f"detour by {d['owner']} at 0x{d['addr']:08x} has no entry symbol. "
                f"Name the stub label it jumps to, so the target is resolved from the "
                f"linked ELF rather than assumed to be the start of the cave block."
            )
    return errors


def load_params(root: Path) -> dict:
    """owner -> its mod.toml [params], so a standalone run gates claims the way a build does.

    Without this every gated claim looks active at once and mutually exclusive claims on
    one region read as a collision.
    """
    out = {}
    for f in sorted((root / "mods").glob("*/mod.toml")):
        with open(f, "rb") as fh:
            m = tomllib.load(fh)
        out[m["mod"]["id"]] = dict(m.get("params", {}))
    return out


if __name__ == "__main__":
    root = Path(__file__).resolve().parent.parent
    problems = validate(load(root / "registry" / "allocations.toml"),
                        None, load_params(root), load_excludes(root))
    if problems:
        for p in problems:
            print("ERROR:", p)
        raise SystemExit(1)
    print("layout ok")
