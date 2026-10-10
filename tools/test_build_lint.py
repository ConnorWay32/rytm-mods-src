#!/usr/bin/env python3
"""Regression tests for build.py's check on `|` used as an operator.

In m68k-elf-as `|` begins a comment. Three lines were lost to it without any
warning: 0013's FLT_DEFAULT, `(FRQ_MAX << 16) | (DEP_FULL << 8)`, which dropped
DEP from every untouched sound's default (hardware, 2026-09-29), and the range
guards `.if P_K < 1 || P_K > 16384` (0013) and `.if P_RMS_DB > 0 || P_RMS_DB <
-60` (0009), which each tested one bound. The check must catch those, and must
not flag the aligned comments every stub is full of.
"""

import unittest
from pathlib import Path

from build import bar_operator_lines

ROOT = Path(__file__).resolve().parents[1]


class BarOperator(unittest.TestCase):
    def test_catches_the_lost_lines(self):
        for line in (
            "        .equ    FLT_DEFAULT,    (FRQ_MAX << 16) | (DEP_FULL << 8)",
            "        .if     P_K < 1 || P_K > 16384",
            "        .if     P_RMS_DB > 0 || P_RMS_DB < -60",
            "        .long   A|B",
            "        move.l  #X | Y,%d0",
        ):
            self.assertTrue(bar_operator_lines(line), line)

    def test_leaves_comments_alone(self):
        for line in (
            "        move.l  %d1,-(%sp)                        | TYP",
            "        .equ    FX_DELAY,       0x80007c44  | FX_REVERB + 256",
            "        | a whole-line comment with a | b",
            "        rts                                       | as stock's, after it",
        ):
            self.assertFalse(bar_operator_lines(line), line)

    def test_every_stub_is_clean(self):
        for path in sorted(ROOT.glob("mods/*/*.s")) + sorted(ROOT.glob("mods/*/*.inc")):
            self.assertEqual(bar_operator_lines(path.read_text(errors="replace")), [],
                             str(path))


if __name__ == "__main__":
    unittest.main()
