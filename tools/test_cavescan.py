#!/usr/bin/env python3
"""Small dependency-free regression tests for cavescan.py.

The analysis behind the cave4..cave6 pools is the kind that fails quietly: every one
of these pieces produced a confident, wrong answer at some point while it was being
written, and the only thing that caught it was comparing the output against numbers
worked out by hand. The worst of them offered a live switch body as free space, which
is how a unit gets bricked rather than how a scan gets embarrassed.

So each test below pins one of those failures:
  - resolve_table  must read the 23-entry table at 0x4013d072 exactly, because
                   0x4013d0de is arm 1 of it and looks dead to any absolute scan;
  - boot_layout    must return the ceiling, and must refuse a changed image rather
                   than read six arbitrary longwords;
  - text_end       must land on 0x401bea90 and not be dragged off the image by a
                   displacement that happens to look like an address;
  - dead_regions   must find 0x4002905e AND must not offer 0x4013d0de.
"""

import struct
import unittest
from pathlib import Path

import cavescan

ROOT = Path(__file__).resolve().parents[1]
IMAGE = ROOT / "build" / "stock_mainos.bin"
DIS = ROOT / "build" / "mainos_emac.dis"
BASE = 0x40000400
CEILING = 0x402CE000
TEXT_END = 0x401BEA90

needs_image = unittest.skipUnless(IMAGE.exists(), "run make build first")
needs_dis = unittest.skipUnless(DIS.exists(), "run make disasm first")


def image():
    return IMAGE.read_bytes()


class RunTests(unittest.TestCase):
    """The filler scan, on data that does not need the image."""

    def test_runs_finds_only_long_enough(self):
        data = bytes([1, 0, 0, 0, 0, 2, 0, 0])
        self.assertEqual(cavescan.runs(data, 0x00, 4), [(1, 4)])
        self.assertEqual(cavescan.runs(data, 0x00, 5), [])

    def test_all_runs_stops_at_the_ceiling(self):
        data = bytes([0xAA] * 8 + [0xBB] * 8)
        self.assertEqual(cavescan.all_runs(data, 4, 16),
                         [(0, 8, 0xAA), (8, 8, 0xBB)])
        # a run crossing `upto` is reported clipped, never at its full length
        self.assertEqual(cavescan.all_runs(data, 4, 12),
                         [(0, 8, 0xAA), (8, 4, 0xBB)])

    def test_tail_start(self):
        self.assertEqual(cavescan.tail_start(b"\x01\x02\x00\x00\x00"), 2)
        self.assertEqual(cavescan.tail_start(b""), 0)


class BootLayoutTests(unittest.TestCase):
    """The ceiling. Everything else in the tool is scoped by this."""

    @needs_image
    def test_reads_the_ceiling_out_of_the_image(self):
        boot = cavescan.boot_layout(image(), BASE)
        self.assertEqual(boot["bss_start"], CEILING)
        self.assertEqual(boot["sram1_src"], CEILING)
        self.assertEqual(boot["sram1_end"], 0x402D6000)
        self.assertEqual(boot["sram2_src"], 0x402D6000)
        # the second load image ends on the image's last byte
        self.assertEqual(boot["sram2_end"], BASE + len(image()))
        self.assertEqual(boot["bss_end"], 0x42FBB250)

    @needs_image
    def test_the_two_sram_blocks_are_32k_each(self):
        boot = cavescan.boot_layout(image(), BASE)
        self.assertEqual(boot["sram1_end"] - boot["sram1_src"], 0x8000)
        # the second is 8 B short of 32 KB; the clear loop zeroes the remainder
        self.assertEqual(boot["sram2_end"] - boot["sram2_src"], 0x7FF8)

    @needs_image
    def test_refuses_an_image_whose_startup_moved(self):
        data = bytearray(image())
        opcode = cavescan.BOOT_SITES["bss_start"][1]
        struct.pack_into(">H", data, opcode - BASE, 0x4E71)     # nop
        with self.assertRaises(SystemExit) as caught:
            cavescan.boot_layout(bytes(data), BASE)
        self.assertIn("startup guard failed", str(caught.exception))


class JumpTableTests(unittest.TestCase):
    """The trap. An arm's address appears nowhere as a 32-bit value."""

    @needs_image
    def test_resolves_the_known_table(self):
        arms, count = cavescan.resolve_table(image(), BASE, 0x4013D072)
        self.assertEqual(count, 23)                 # the bound before the jmp is 22
        self.assertEqual(arms[0], 0x4013D0A0)
        self.assertEqual(arms[1], 0x4013D0DE)       # the false positive that started this
        self.assertEqual(arms[-1], 0x4013DCBA)
        self.assertEqual(max(arms), 0x4013DD10)     # the default arm, entry 13
        self.assertEqual(len(set(arms)), 23)

    @needs_image
    def test_table_ends_where_its_first_arm_begins(self):
        arms, count = cavescan.resolve_table(image(), BASE, 0x4013D072)
        self.assertEqual(0x4013D072 + 2 * count, min(arms))

    @needs_image
    def test_gives_up_rather_than_guessing(self):
        # a first word that is not a plausible offset must return None, so the caller
        # blacks the table's whole reach out instead of trusting a bad arm list
        data = bytearray(image())
        struct.pack_into(">H", data, 0x4013D072 - BASE, 0xD568)
        self.assertIsNone(cavescan.resolve_table(bytes(data), BASE, 0x4013D072))


class ComputedJumpTests(unittest.TestCase):
    """Every computed jump is found; only the switch shape is read as a table."""

    def shape(self, text):
        m = cavescan.JT_RE.search(text)
        return None if m is None else ("table" if m.group(1) == "jmp" and not m.group(3)
                                       else "blackout")

    def test_the_switch_shape_is_a_table(self):
        self.assertEqual(self.shape("jmp %pc@(0x4013d072,%d0:l)"), "table")
        self.assertEqual(self.shape("jmp %pc@(0x4013d072,%a1:l)"), "table")
        self.assertEqual(self.shape("jmp %pc@(0x4013d072,%d1)"), "table")

    def test_other_shapes_are_blacked_out_not_missed(self):
        # a computed jsr, and a scaled index: once matched by nothing at all
        self.assertEqual(self.shape("jsr %pc@(0x401f7179,%d0:w)"), "blackout")
        self.assertEqual(self.shape("jsr %pc@(0x402175a2,%d3:l:4)"), "blackout")
        self.assertEqual(self.shape("jmp %pc@(0x402175a2,%d3:l:2)"), "blackout")

    def test_a_plain_pc_relative_call_is_not_computed(self):
        self.assertIsNone(self.shape("jsr %pc@(0x400af0d2)"))


class TextEndTests(unittest.TestCase):
    @needs_dis
    @needs_image
    def test_boundary(self):
        insns = cavescan.load_dis(DIS, CEILING)
        self.assertEqual(cavescan.text_end(insns, BASE, BASE + len(image())),
                         TEXT_END)

    @needs_dis
    @needs_image
    def test_a_displacement_is_not_a_call_target(self):
        # `jsr %a2@(0x40bc67fd)` is a displacement off a register, not a direct call.
        # Matching it pushed the boundary past the end of the image.
        self.assertIsNone(cavescan.CALL_RE.match("%a2@(0x40bc67fd)"))
        self.assertIsNotNone(cavescan.CALL_RE.match("0x401bea50"))
        self.assertIsNotNone(cavescan.CALL_RE.match("%pc@(0x401bea50)"))


class DeadRegionTests(unittest.TestCase):
    """The whole point, and the one result that has to stay honest."""

    @classmethod
    def setUpClass(cls):
        if not (IMAGE.exists() and DIS.exists()):
            return
        data = image()
        insns = cavescan.load_dis(DIS, CEILING)
        tend = cavescan.text_end(insns, BASE, BASE + len(data))
        insns = [i for i in insns if i[0] < tend]
        pairs, _tables, _unresolved = cavescan.references(data, BASE, insns, tend)
        cls.dead = cavescan.dead_regions(BASE, insns, tend, pairs,
                                         cavescan.DEAD_FLOOR)

    def covered(self, addr):
        return any(a <= addr < a + n for a, n in self.dead)

    @needs_dis
    @needs_image
    def test_finds_the_pools(self):
        for start in (0x4002905E, 0x4002871A, 0x401BA28E):
            self.assertTrue(self.covered(start), f"lost 0x{start:08x}")

    @needs_dis
    @needs_image
    def test_does_not_offer_a_live_switch_arm(self):
        # 0x4013d0de is arm 1 of the table at 0x4013d072. Nothing in the image refers
        # to it, it sits after a braw, and it is perfectly reachable. If this ever
        # fails, the tool is handing out live code as free space.
        for arm in (0x4013D0DE, 0x4013D194, 0x4013D24A, 0x4013D80E):
            self.assertFalse(self.covered(arm),
                             f"0x{arm:08x} is a live switch arm, not free space")

    @needs_dis
    @needs_image
    def test_small_pools_sit_wholly_in_one_region(self):
        # what the registry actually claims, not just the start addresses
        for name, lo, hi in (("cave5", 0x4002871C, 0x40028A14),
                             ("cave6", 0x401BA290, 0x401BA4E8)):
            covering = [(a, n) for a, n in self.dead if a <= lo and hi <= a + n]
            self.assertEqual(len(covering), 1,
                             f"{name} is not wholly inside one reported region")

    @needs_dis
    @needs_image
    def test_cave4_is_one_region_with_its_tail(self):
        """cave4's routine is reported whole, tail included.

        dead_regions only opens a region where the preceding instruction ends the
        flow, so the 458 B at 0x40029380, reached by falling through, once split the
        routine into 0x4002905e +802 and 0x4002954a +752. The region also stopped at
        0x4002983a, which the routine's own tail branches back to (from 0x400298ee).

        absorb_tail grows a region over the blocks after it while every reference
        into them comes from the region itself or another dead one, so the routine
        now reads as one region running to 0x40029a90: 598 B past the cave4 pool.
        This test pins that shape so that a future change to the rule shows up here
        rather than silently resizing a pool.
        """
        pieces = sorted((a, n) for a, n in self.dead
                        if a < 0x40029a90 and 0x40029060 < a + n)
        self.assertEqual(pieces, [(0x4002905E, 2610)])
        self.assertEqual(0x4002905E + 2610, 0x40029A90)

    @needs_dis
    @needs_image
    def test_an_absorbed_tail_is_reached_only_from_its_region(self):
        # every reference into the tail absorb_tail added past the old end comes from
        # inside the routine: the pairs the scan itself uses, not just 32-bit values
        data = image()
        insns = [i for i in cavescan.load_dis(DIS, CEILING) if i[0] < TEXT_END]
        pairs, _tables, _unresolved = cavescan.references(data, BASE, insns, TEXT_END)
        outside = [(src, tgt) for src, tgt in pairs
                   if 0x4002983A <= tgt < 0x40029A90 and not 0x4002905E <= src < 0x40029A90]
        self.assertEqual(outside, [])

    @needs_dis
    @needs_image
    def test_nothing_outside_a_region_references_into_it(self):
        data = image()
        for lo, hi in ((0x4002905E, 0x40029A90), (0x4002871A, 0x40028A14),
                       (0x401BA28E, 0x401BA4E8)):
            hits = []
            for off in range(0, len(data) - 3, 2):     # pointers are even-aligned
                value = struct.unpack_from(">I", data, off)[0]
                if lo <= value < hi and not lo <= BASE + off < hi:
                    hits.append((BASE + off, value))
            self.assertEqual(hits, [], f"0x{lo:08x} is referenced after all")


if __name__ == "__main__":
    unittest.main()
