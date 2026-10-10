#!/usr/bin/env python3
"""Find candidate code caves in the stock MAIN OS.

octatrack-mods inherited its cave from octamax's survey and paid for trusting it
(registry/allocations.toml, patch_ram pool). There is no equivalent survey for the
Rytm, so the pool in registry/allocations.toml has to come from a scan of this exact
image, and the scan has to be re-runnable to stay honest.

Three passes, in the order a candidate has to survive them:

1. The ceiling. The startup code names the image's writable boundary outright, so it
   is read out of the image rather than assumed. Everything at or above __bss_start
   is disqualified twice over: it is the source of the two SRAM load images copied at
   boot, and it is then zeroed by the .bss clear. That is the trap octatrack-mods hit,
   and here it is decided rather than guessed.

2. Filler runs below the ceiling. A cave is a run of a single filler byte long enough
   to hold a stub. Every run is reported with what references it, because in this
   image almost every long run of 0xff or 0x00 below the ceiling turns out to be live
   table content - "no mapping" entries, or a group in a mask table - rather than
   padding.

3. Dead code in .text, which is where the space actually is. A function that nothing
   calls is as free as padding and is provably not .bss, since .bss starts above all
   of it. This pass needs build/mainos_emac.dis (`make disasm`).

The reachability analysis in pass 3 has one trap of its own, and it is the reason the
pass exists in this form. ColdFire switches compile to `jmp %pc@(table,%dn:l)` over a
table of 16-bit offsets, so an arm's address appears NOWHERE in the image as a 32-bit
value. Scanning for absolute references alone reports whole live switch bodies as
dead. Every such table is resolved here; the ones that cannot be are blacked out
across their full 64 KB reach rather than ignored, as is every computed jump or call
of another shape (a `jsr`, a scaled index).

A region opens only where the instruction before it ends the flow, and ends at the
first address anything refers to. A routine whose own tail branches back into itself
would end there, so regions are grown over the blocks after them for as long as every
reference into those blocks comes from the region or another dead one.
"""

import argparse
import bisect
import re
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(Path(__file__).resolve().parent))
import symbols as symmod

# Startup sites read by boot_layout(). Each is (address of the 32-bit operand,
# address of the opcode that introduces it, expected opcode word). The opcode is the
# guard: if the image ever changes under this tool, it stops instead of reading six
# arbitrary longwords and reporting a confident, wrong ceiling.
BOOT_SITES = {
    "sram1_src":  (0x400007E8, 0x400007E6, 0x45F9),   # lea   <src>,%a2
    "sram1_end":  (0x400007FA, 0x400007F8, 0xB5FC),   # cmpal #<end>,%a2
    "sram2_src":  (0x40000810, 0x4000080E, 0x45F9),
    "sram2_end":  (0x40000822, 0x40000820, 0xB5FC),
    "bss_start":  (0x40000844, 0x40000842, 0x207C),   # moveal #<start>,%a0
    "bss_end":    (0x4000084A, 0x40000848, 0x223C),   # movel  #<end>,%d1
}

# Flow ends here, so the next instruction is not reached by falling through.
TERMINATORS = {"rts", "rte", "jmp", "bra", "bras", "braw", "bral", "rtd"}

DIS = ROOT / "build" / "mainos_emac.dis"


def runs(data: bytes, value: int, minlen: int):
    """(offset, length) for every run of `value` at least `minlen` bytes long."""
    out, i, n = [], 0, len(data)
    while i < n:
        if data[i] != value:
            i += 1
            continue
        j = i
        while j < n and data[j] == value:
            j += 1
        if j - i >= minlen:
            out.append((i, j - i))
        i = j
    return out


def all_runs(data: bytes, minlen: int, upto: int):
    """(offset, length, fill) for every run of one repeated byte below `upto`."""
    out, i = [], 0
    while i < upto:
        j = i
        while j < upto and data[j] == data[i]:
            j += 1
        if j - i >= minlen:
            out.append((i, j - i, data[i]))
        i = j
    return out


def tail_start(data: bytes) -> int:
    """Offset where the trailing filler begins, or len(data) if there is none."""
    if not data:
        return 0
    last = data[-1]
    i = len(data)
    while i > 0 and data[i - 1] == last:
        i -= 1
    return i


def boot_layout(data: bytes, base: int) -> dict:
    """The SRAM load images and the .bss bounds, read out of the startup code.

    The first routine copies two blocks out of the image into SRAM; the second zeroes
    from __bss_start upwards. Both are called from the reset path, copy first. So the
    top of the image is read once at boot and then overwritten, and nothing below
    __bss_start is .bss - which is what makes everything this tool reports below that
    line a question about live data only, never about runtime writes.
    """
    out = {}
    for name, (operand, opcode, want) in BOOT_SITES.items():
        got = struct.unpack_from(">H", data, opcode - base)[0]
        if got != want:
            raise SystemExit(
                f"cavescan: startup guard failed at 0x{opcode:08x}: expected opcode "
                f"0x{want:04x}, found 0x{got:04x}. The image is not the one this tool "
                f"was written against; re-derive BOOT_SITES before trusting any ceiling."
            )
        out[name] = struct.unpack_from(">I", data, operand - base)[0]
    if not out["bss_start"] == out["sram1_src"]:
        raise SystemExit(
            f"cavescan: __bss_start 0x{out['bss_start']:08x} is not the start of the "
            f"first SRAM load image 0x{out['sram1_src']:08x}; the two no longer agree, "
            f"so the ceiling needs re-deriving by hand."
        )
    return out


def load_dis(path: Path, limit: int):
    """[(addr, mnemonic, operands)] for every disassembled instruction below `limit`.

    objdump elides repeated identical lines as "...", so some addresses are missing.
    That only ever loses a terminator, which makes this scan report fewer regions
    rather than more, and it loses no reference: references are taken from the raw
    image as well, where nothing is elided.
    """
    line_re = re.compile(rb"^([0-9a-f]{8}):\t[0-9a-f ]+\t(\S+) ?(.*)$")
    out = []
    with open(path, "rb") as fh:
        for line in fh:
            m = line_re.match(line)
            if not m:
                continue
            addr = int(m.group(1), 16)
            if addr >= limit:
                break
            out.append((addr, m.group(2).decode(), m.group(3).decode().rstrip()))
    return out


# A direct call, and nothing else. A displacement that happens to look like an address
# (`jsr %a2@(0x40bc67fd)`) is not a target, and in the tables above the code there are
# enough garbage decodes carrying one to push the boundary clean off the image.
CALL_RE = re.compile(r"^(?:0x(40[0-9a-f]{6})|%pc@\(0x(40[0-9a-f]{6})\))$")


# Longest stretch of real code expected to contain no direct call at all. Used to tell
# where code stops: the tables above it disassemble into occasional plausible-looking
# calls, so the boundary has to be grown from the bottom rather than taken as the
# highest target anywhere in the image.
CALL_GAP = 4096


def text_end(insns, base: int, image_end: int) -> int:
    """First address past the last routine anything calls directly.

    Taken from the image rather than assumed. Walking up from the load base, each
    direct call extends the known code as far as its target; a call sitting more than
    CALL_GAP past the end of what is already known to be code is a garbage decode in
    the tables and is not allowed to drag the boundary with it. The boundary is then
    the rts that ends the last routine. Above it the image is tables and strings, plus
    one further code region reached only through pointers - which is why this cannot
    be read off a filler run.
    """
    calls = []
    for addr, mnem, ops in insns:
        if not mnem.startswith(("jsr", "jmp", "bsr")):
            continue
        m = CALL_RE.match(ops)
        if not m:
            continue
        target = int(m.group(1) or m.group(2), 16)
        if base <= target < image_end:
            calls.append((addr, target))
    calls.sort()
    highest = base
    for addr, target in calls:
        if addr > highest + CALL_GAP:
            break
        highest = max(highest, target, addr)
    # The last routine can have several exits, so walk to the end of the code rather
    # than to its first rts: objdump renders the tables that follow as .short, and
    # that first undecodable word is the boundary.
    end = highest
    for i, (addr, mnem, _ops) in enumerate(insns):
        if addr < highest:
            continue
        if mnem.startswith("."):
            break
        if mnem == "rts" and i < len(insns) - 1:
            end = insns[i + 1][0]
    return end


def resolve_table(data: bytes, base: int, tbl: int):
    """Arms of a 16-bit offset jump table at `tbl`, or None if it cannot be read.

    The table is immediately followed by its own arms, so it ends where the lowest
    offset points. Growing the entry count while it stays below that bound converges
    on the real length; a gap of more than a few bytes between the end of the table
    and the first arm means the shape is not the one assumed, and the caller then has
    to treat the table's whole reach as live.
    """
    def w16(addr):
        return struct.unpack_from(">H", data, addr - base)[0]

    n, lim = 1, w16(tbl)
    while 2 * n < lim:
        v = w16(tbl + 2 * n)
        if v == 0 or v > 0x8000:
            break
        lim = min(lim, v)
        n += 1
    slack = lim - 2 * n
    if slack < 0 or slack > 16:
        return None
    return [tbl + w16(tbl + 2 * i) for i in range(n)], n


# Every PC-relative computed jump or call: `jmp` or `jsr`, any index register, with
# or without a size and a scale.
JT_RE = re.compile(r"(jmp|jsr) %pc@\(0x([0-9a-f]+),%[ad]\d(?::[lw])?(:[1248])?\)")


def references(data: bytes, base: int, insns, limit: int):
    """(source, target) for everything that can reach an address below `limit`.

    Three kinds, and all three are needed:
      - every 4-byte value at an even offset in the image. Pointer tables, vtables and
        instruction immediates all live at even addresses on this core, so an odd
        match is a coincidence inside some other instruction and would only ever hide
        free space.
      - every in-image address printed as a disassembly operand, which covers the
        PC-relative calls and branches that never appear as a 32-bit value anywhere.
      - the arms of each computed jump table, charged to the table.
    Sources are kept because a dead routine's own branches must not count as
    reaching it; see dead_regions().
    """
    pairs = []
    for off in range(0, len(data) - 3, 2):
        v = struct.unpack_from(">I", data, off)[0]
        if base <= v < limit:
            pairs.append((base + off, v))

    addr_re = re.compile(r"0x(40[0-9a-f]{6})")
    tables, unresolved = [], []
    for addr, mnem, ops in insns:
        for m in addr_re.finditer(ops):
            v = int(m.group(1), 16)
            if base <= v < limit:
                pairs.append((addr, v))
        m = JT_RE.search(f"{mnem} {ops}")
        if m:
            tbl = int(m.group(2), 16)
            # Only `jmp` through an unscaled index is the switch shape resolve_table
            # reads. A computed `jsr`, or a scaled index, is some other table, and
            # gets the full-reach blackout below rather than a misread arm list.
            if m.group(1) == "jmp" and not m.group(3):
                tables.append((addr, tbl))
            else:
                unresolved.append((addr, tbl))

    for site, tbl in tables:
        got = resolve_table(data, base, tbl)
        if got is None:
            unresolved.append((site, tbl))
            continue
        arms, n = got
        pairs.extend((tbl, a) for a in arms)
        pairs.extend((tbl, tbl + 2 * i) for i in range(n))
    # A table that cannot be read still reaches base..base+0xffff, the span a 16-bit
    # unsigned offset covers. Blacking all of it out costs candidates; guessing at the
    # shape would cost a unit.
    for site, tbl in unresolved:
        pairs.extend((tbl, a) for a in range(tbl, min(tbl + 0x10000, limit), 2))
    return pairs, len(tables), unresolved


# The fixpoint has to run down to small regions even when only large ones are wanted.
# Dead routines reference each other, so a cluster only unravels if the small members
# are found too; raising this floor to the reporting threshold silently keeps the
# large ones alive.
DEAD_FLOOR = 64


def dead_regions(base, insns, limit, pairs, minlen):
    """Spans of .text that nothing can reach, to a fixpoint.

    A span qualifies when no instruction falls into it - the instruction before it
    ends the flow - and nothing outside it refers to any address in it. The fixpoint
    matters: a dead routine still branches within itself, and counting those branches
    as references would cut every dead routine down to its first basic block.
    """
    follows = [insns[i + 1][0] for i in range(len(insns) - 1)
               if insns[i][1] in TERMINATORS]
    follows_sorted = sorted(follows)
    by_target = sorted((t, src) for src, t in pairs)
    dead: list[tuple[int, int]] = []
    for _ in range(16):
        starts = [d[0] for d in dead]

        def is_dead(a):
            i = bisect.bisect_right(starts, a) - 1
            return i >= 0 and a < dead[i][0] + dead[i][1]

        live = set()
        for src, tgt in pairs:
            if base <= src < limit and is_dead(src):
                continue
            live.add(tgt)
        ordered = sorted(live)
        found = []
        for start in follows:
            if start in live:
                continue
            i = bisect.bisect_left(ordered, start)
            end = ordered[i] if i < len(ordered) else limit
            if end - start >= minlen:
                found.append((start, end - start))
        found.sort()
        merged = merge(found)
        merged = merge([absorb_tail(a, n, merged, follows_sorted, by_target, limit)
                        for a, n in merged])
        if merged == dead:
            break
        dead = merged
    return dead


# How many blocks past a span's end absorb_tail looks for the one that closes it.
TAIL_LOOKAHEAD = 16


def merge(spans):
    out: list[tuple[int, int]] = []
    for a, n in sorted(spans):
        if out and a <= out[-1][0] + out[-1][1]:
            prev = out[-1]
            out[-1] = (prev[0], max(prev[1], a + n - prev[0]))
        else:
            out.append((a, n))
    return out


def absorb_tail(a, n, dead, follows_sorted, by_target, limit):
    """Extend the dead span (a, n) over the blocks after it that only it reaches.

    A span ends at the first address something refers to. When that something is
    the routine's own tail - a loop branching back, a shared exit - the tail keeps
    itself alive and the span stops short of the routine's end. So the span is
    tried grown by one block, two, and so on up to TAIL_LOOKAHEAD, a block ending
    at the next address that follows a terminator, and takes the longest growth in
    which every reference to an address in the added blocks comes from inside the
    grown span or from another dead span. That is the same test a span passes to
    be found at all: nothing outside it refers to it. Trying longer growths rather
    than stopping at the first block that fails is what lets a block referenced
    only by a later block of the same routine join.
    """
    starts = [d[0] for d in dead]

    def elsewhere_dead(src):
        i = bisect.bisect_right(starts, src) - 1
        return i >= 0 and src < dead[i][0] + dead[i][1]

    end = a + n
    while end < limit:
        j = bisect.bisect_right(follows_sorted, end)
        best = None
        for nxt in follows_sorted[j:j + TAIL_LOOKAHEAD]:
            lo = bisect.bisect_left(by_target, (end, -1))
            hi = bisect.bisect_left(by_target, (nxt, -1))
            if all(a <= src < nxt or elsewhere_dead(src) for _, src in by_target[lo:hi]):
                best = nxt
        if best is None:
            break
        end = best
    return (a, end - a)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--image", default=str(ROOT / "build" / "stock_mainos.bin"))
    ap.add_argument("--min", type=int, default=256, help="smallest filler run to report")
    ap.add_argument("--top", type=int, default=15)
    ap.add_argument("--fill-any", action="store_true",
                    help="report runs of any repeated byte, not just 0x00 and 0xff")
    ap.add_argument("--dead-min", type=int, default=256,
                    help="smallest dead-code region to report")
    ap.add_argument("--no-dead", action="store_true", help="skip the dead-code pass")
    args = ap.parse_args()

    img = Path(args.image)
    if not img.exists():
        raise SystemExit(f"{img} missing; run `make build` first")
    data = img.read_bytes()
    base = symmod.load(ROOT / "re" / "symbols.toml")["meta"]["base"]
    tail = tail_start(data)
    boot = boot_layout(data, base)
    ceiling = boot["bss_start"]

    print(f"{img.name}: {len(data):,} B, load base 0x{base:08x}")
    print(f"tail filler starts at 0x{base + tail:08x} (file 0x{tail:x}), "
          f"{len(data) - tail:,} B of 0x{data[-1]:02x}")
    print()
    print("ceiling, read out of the startup code:")
    print(f"  SRAM load image 1  0x{boot['sram1_src']:08x}..0x{boot['sram1_end']:08x}"
          f"  ({boot['sram1_end'] - boot['sram1_src']:,} B, copied at boot)")
    print(f"  SRAM load image 2  0x{boot['sram2_src']:08x}..0x{boot['sram2_end']:08x}"
          f"  ({boot['sram2_end'] - boot['sram2_src']:,} B, copied at boot)")
    print(f"  .bss clear         0x{boot['bss_start']:08x}..0x{boot['bss_end']:08x}"
          f"  ({(boot['bss_end'] - boot['bss_start']) / 2**20:.1f} MB, zeroed at boot)")
    print(f"  usable region      0x{base:08x}..0x{ceiling:08x}"
          f"  - at or above 0x{ceiling:08x} is read as initialiser data and then zeroed")
    print()

    ceil_off = ceiling - base
    if args.fill_any:
        found = list(all_runs(data, args.min, ceil_off))
    else:
        # A run that crosses the ceiling is reported as the part below it and nothing
        # more: the rest is initialiser data, and quoting the whole length is how the
        # 24 KB run at 0x402cd89c reads as a prize instead of as cave2 plus .bss.
        found = [(o, min(n, ceil_off - o), v) for v in (0x00, 0xFF)
                 for o, n in runs(data, v, args.min) if o < ceil_off]
        found = [r for r in found if r[1] >= args.min]
    found.sort(key=lambda r: -r[1])

    # which runs anything points into, so a run that is really table content is not
    # mistaken for padding
    targets = set()
    for off in range(0, len(data) - 3, 2):
        v = struct.unpack_from(">I", data, off)[0]
        if base <= v < ceiling:
            targets.add(v)
    ordered = sorted(targets)

    kind = "any repeated byte" if args.fill_any else "0x00 and 0xff"
    print(f"filler runs of {kind} >= {args.min} B below the ceiling: {len(found)}")
    print(f"  {'addr':>10} {'len':>6} {'fill':>5}  refs into it")
    for o, n, fill in found[:args.top]:
        a = base + o
        lo = bisect.bisect_left(ordered, a)
        hi = bisect.bisect_left(ordered, a + n)
        inside = ordered[lo:hi]
        if not inside:
            note = "none"
        elif inside == [a]:
            note = f"1, at its start (0x{a:08x}) - the run IS the object"
        else:
            note = f"{len(inside)}, first 0x{inside[0]:08x}"
        print(f"  0x{a:08x} {n:>6}  0x{fill:02x}   {note}")
    if not found:
        print("  (none)")
    print()

    above = []
    for v in (0x00, 0xFF):
        for o, n in runs(data, v, args.min):
            lo, hi = max(o, ceil_off), min(o + n, tail)
            if hi - lo >= args.min:
                above.append((base + lo, hi - lo))
    above.sort(key=lambda r: -r[1])
    if above:
        print(f"disqualified by the ceiling ({len(above)} runs, "
              f"{sum(n for _, n in above):,} B):")
        for a, n in above[:6]:
            print(f"  0x{a:08x} +{n}")
        print()

    if args.no_dead:
        return
    if not DIS.exists():
        print(f"dead-code pass skipped: {DIS.relative_to(ROOT)} missing "
              f"(run `make disasm`)")
        return

    insns = load_dis(DIS, ceiling)
    tend = text_end(insns, base, base + len(data))
    insns = [i for i in insns if i[0] < tend]
    pairs, n_tables, unresolved = references(data, base, insns, tend)
    found_dead = dead_regions(base, insns, tend, pairs, DEAD_FLOOR)
    dead = [r for r in found_dead if r[1] >= args.dead_min]

    print(f".text ends at 0x{tend:08x} (highest direct call target, from the image)")
    print(f"computed jump tables: {n_tables}, of which {len(unresolved)} unresolved "
          f"and blacked out across their full 64 KB reach")
    print(f"unreachable .text regions >= {DEAD_FLOOR} B: {len(found_dead)}, "
          f"total {sum(n for _, n in found_dead):,} B")
    print(f"  of those >= {args.dead_min} B: {len(dead)}, "
          f"total {sum(n for _, n in dead):,} B")
    print(f"  {'addr':>10} {'len':>6}  first bytes")
    for a, n in sorted(dead, key=lambda r: -r[1])[:args.top]:
        o = a - base
        print(f"  0x{a:08x} {n:>6}  {data[o:o + 12].hex()}")
    if not dead:
        print("  (none)")
    print()
    print("A region here is unreachable, not unwritten - which for .text is the whole "
          "question, since .bss starts above all of it. Prove one before claiming it: "
          "fill it with an illegal-instruction pattern so that entry faults loudly, "
          "flash that alone, and run the machine hard.")


if __name__ == "__main__":
    main()
