# Hazards

## The bootstrap is the only net - do not touch it

Section 2 of the container is the bootstrap: 42,302 B of ColdFire loaded at
0x07020000. It draws the STARTUP menu and implements the DIN-MIDI OS UPGRADE that
does not depend on MAIN OS. It is the reason a bad MAIN OS is recoverable.

Nothing in this project writes to it. `tools/verify.py` asserts that the bootstrap
section extracted from our rebuilt `.syx` still hashes to
`1b8d3b7288df118512740ac7c59d8dd9f71f44e6633a29628bcb068d756e2ed8`, and fails the
build if it does not. Keep that check. A mod that needs the bootstrap changed is a
mod that removes the ability to undo itself.

The one moment the net is genuinely down is Elektron's own bootstrap upgrade, which
runs on the first restart after some OS updates and rewrites that section. Do not
cut power there.

## The cave pool is a candidate, not a fact

`registry/allocations.toml` names a 1760-byte run at 0x402cc920. It was chosen
because it ends the code section - the bytes before it disassemble and finish on an
`rts`, the bytes after it are UTF-16 string data - so it reads as alignment padding
between `.text` and `.rodata`.

That is an argument, not a measurement. A zero run in the image can also be `.bss`,
which is written the moment the engine runs. octatrack-mods inherited exactly such a
region from someone else's survey, shipped a mod into it, and found the mod worked
with the sequencer stopped and not at all during playback, because the audio engine
was writing over its state between keypresses.

Before the first mod ships: fill the region with a known pattern, flash, run the
machine hard - playback, sampling, Overbridge, +Drive access - and read it back.
Only then set `status = "verified"`.

## The assembler target is ColdFire V4e, and it matters

Stubs assemble with `-mcpu=5475`: ISA_B plus EMAC. That is what the stock image
uses - `mvz`/`mvs` and `sats.l` throughout, and `mac`/`msac`/`movclr` in the audio
path - so it is the target the firmware was built for.

This was `-mcpu=5407` (ISA_A, the older MAC unit) until mod 0006 needed EMAC and
would not assemble. Nothing had gone wrong, because no mod until then reached past
ISA_A, and the switch rebuilt 0000/0002/0003/0004 byte-identically. The lesson is
the direction of the error: too *narrow* a target fails loudly at assembly time,
while too wide a one would silently accept instructions the chip does not have and
fail on hardware. Widen it only with the same byte-identical check.

## Verify before flashing, every time

`make verify` is not a formality. It asserts:

- the vendored tool rebuilds Elektron's own untouched `.syx` byte for byte
  (null repack) - if that fails, nothing else it says is worth anything
- MAIN OS is unchanged in size and round-trips out of our own `.syx`
- sections 5, 2, 1 and 8 come back byte-identical to stock
- every byte that differs from stock lies inside a registry claim
- every detour jumps to a symbol resolved from the linked ELF, at an even address,
  inside one of its mod's own cave claims
- the bytes each detour displaced reappear verbatim in that mod's stub

## Status means what it says

`built` means the image assembled. It says nothing about whether the device runs.
Only `hardware-verified` counts, and only for the exact image that was flashed -
flash one mod at a time when bisecting.

## USB MAIN moves with the kit's VOL, and a little with the volume knob

Two things move MAIN in the USB stream against the voice slots and the
compressor's detector, which neither affects:
- The main volume knob, although in principle it sets only the analog outputs:
  there is an interaction worth a few dB over its full travel (the user,
  2026-09-22). Moving it shifted MAIN by 1.40 dB on both dry and wet paths
  (re/subsystems/compressor-hardware.md).
- The compressor's VOL, part of the kit: it sets the dry level at MIX 0 and
  scales the whole of MAIN. Left as authored across 16 patterns, 0006's input
  model read 2.4 to 7.5 dB hot by pattern.

Anything fitted or nulled against MAIN - `MAIN_CAL`, 0006's diag mode 3, every
`tools/comp` capture fit - holds only with VOL pinned (127, with DIST symmetry 64
and PRE routing, as tools/comp/calibrate.py sets) and the knob unmoved. The
remaining offset is removed per session from a voices-only reference: -1.39 dB,
the same on all 16 patterns, with the knob at 0 on 2026-09-22. Pattern switches
do not reset kit settings: CC edits persist in the working kit.
The on-device estimator does not read MAIN - its input is the voice slots, the
VCA words and the PRE return buffers - and is not affected.
