# 0002 - Euclidean generator places accents instead of trigs

Per track: when the setting is on, the euclidean generator stops deciding which steps
fire and instead sets ACCENT on the pattern's own trigs. The grid says *when*, euclid
says *what is accented*.

Status: **built and verified in the image, not yet flashed.**

## How stock euclidean works

`euclid_generate` (`0x400c1998`) runs two Bjorklund passes into 64-byte bool arrays at
`0x4196dbb8` and `0x4196db78`, combines them with one of four operators, and writes a
per-track map at `TrackPattern+0x2d1`: `-1` for no hit, otherwise the **ordinal** of
that hit (0, 1, 2, …).

`trig_fire` is the **only** playback reader of that map - the step scheduler never
touches it and every other reader is UI. In euclidean mode it does:

```c
ordinal = map[step];
flags   = trigword[step] & 0x10          // swing from THIS step
        | trigword[ordinal] & 0xffef     // everything else from the ordinal's step
        | TRIG_BIT_TRIG;                 // forced on
```

so the Nth euclidean hit borrows the Nth grid trig's note, velocity and length.

**Live edits are not written to the pattern.** That is why the toggle behaves the way
it does:

- turn euclid off with FUNC held -> `euclid_bake` (`0x400c3c0e`, the `FREEZE TRACK`
  path) materialises the result
- turn it off without FUNC -> nothing to undo, because nothing was ever written

`euclid_bake` walks steps **backwards** from `len-1`. For `map[step] < 0` it clears the
trig and its note/velocity/length; otherwise it copies every attribute from the ordinal
step onto this step. Backwards because the ordinal is always <= the step, so descending
never overwrites a source before it has been read.

## The trig word

16 bits per step, array of 64 at `TrackPattern+0x00`. Written through `trig_flags_set`
(`0x400c2416`). Bits established by finding each setter's caller:

| bit | meaning |
|---|---|
| `0x0001` | trig present |
| `0x0004` | lock / trigless (inferred from behaviour) |
| `0x0008` | **ACCENT** - caller references `ACCENT` / `CLEAR ACCENT` |
| `0x0010` | SWING - caller sits beside the swing menu |
| `0x0020` | SLIDE - caller references `PARAMETER SLIDE` |

## What the mod changes

**Playback**, in `trig_fire`: when the setting is on, take the ordinary non-euclidean
path and colour it.

```c
if (!(trigword[step] & TRIG_BIT_TRIG)) skip;   // the grid decides when
flags = trigword[step];                         // not the ordinal's
if (map[step] >= 0) flags |= TRIG_BIT_ACCENT;   // euclid decides what is accented
```

An OR, never a clear - a step the user accented by hand stays accented whether or not
euclid hits it.

**Bake**, in `euclid_bake`: freeze what you were hearing. Move nothing; for each step
with a trig, set ACCENT where `map[step] >= 0`. Detour at the top of the function and
return early when the setting is on, otherwise fall through to stock.

**Revert**: nothing to do. Live mode still writes nothing.

## Where the setting lives

On the **Bool Operator** parameter (`Bool Operator` / labels `OR XOR AND SUB`), whose
range goes 4 -> 8: the same four operators, each with an accent variant. Per track,
saved, visible on the euclidean page, no new gesture to learn or collide with.

It is **not** stored as 4..7 in the operator byte. `euclid_generate` indexes a 4-entry
(0x40-byte) combiner array with it, so a project carrying 4..7 opened on **stock**
firmware would call a wild function pointer. Instead:

| | where | range |
|---|---|---|
| operator | `TrackPattern+0x2d0` | unchanged, 0..3 |
| accent flag | `TrackPattern+0x2ca` **bit 1** | 0 or 1 |

displayed value = `(accentBit << 2) | operator`.

`+0x2ca` is the euclid-enable byte. Its setter clamps to 0/1, so bit 1 is free, and it
is already per track and already initialised to zero. It is **not** saved whole: see
Persistence below. It has exactly **six** access sites in code - load store `0x40008cca`,
save read `0x40008f62`,
init `0x4001192c`, `trig_fire` read `0x4009aaca`, getter `0x400c0e02`, setter
`0x400c0e32`. Four further matches in the disassembly land inside data tables (one is
visibly a monotonic float table), so they are coincidental bytes, not instructions.

Three patches keep it safe: preserve bit 1 in the setter's clamp, and mask with `0x01`
in the getter and in `trig_fire`'s read.

**On stock firmware** a project saved with the bit set reads as euclid *off* - both
`euclid_generate` and `trig_fire` test for exactly 1. Benign degradation, not
corruption. That is the whole reason for splitting the value across two fields.

## Display (corrected)

**Bool Operator does not render as text.** Its descriptor carries two callbacks and
the euclidean page uses the icon one, `boolop_icon_draw`, which indexes a set of four
17x12 bitmaps - logic-gate glyphs. `euclid_bool_op_format` is a *different*
std::function slot (`0x419a42d0` rather than `0x419a42c0`) and never reaches this page;
an early version of this mod repointed its label table, which did nothing at all. Those
patches were removed.

The real display path:

```c
value = arg >> 8;
if (value > 3) value = 3;                      // moveq #3 at 0x400ff3e0 and 0x400ff3ea
label = ((char **)0x401ec400)[value];
```

```c
value = arg >> 8;
if (value > 3) value = 3;                  // moveq #3 at 0x400ff476 and 0x400ff492
bitmap = getBitmap(boolop_icon_set, value, 0);
```

Bitmaps are **column-major**: one 32-bit big-endian word per column, MSB = top row, so
a 17x12 icon is 68 bytes. Row 11 is empty in all four stock glyphs, which is where the
accent variants get an underline.

The set is built by `bitmap_set_make(set, first, 4, ...)` from four `Bitmap` objects on
the caller's stack. Repointing that one call at `bitmapset8` is enough: it copies the
four stock objects verbatim, builds four more with `bitmap_ctor` from the generated
pixel data, and calls through with eight.

## The encoder range - not widened, bypassed

Five attempts to find the stock clamp failed. It is behind
`param_apply_delta`'s dispatch to `target->vtable[0x2c]`, where the target is
`pattern_track(activePattern, track) + 0x30`, and the vtable installed at that
offset was never identified.

So the mod stops looking for it. `param_apply_delta` receives the encoder delta
*before* that dispatch, and hardware confirmed this path is ours - forcing
`boolop_get_ui` to a constant pinned the icon regardless of the encoder. For
parameter 467 alone the stub applies the delta itself, clamps to 0..7 and
returns; the stock clamp is never reached rather than being widened.

### What that cost in wrong turns

`param_info(id)+4` and `+8` are **step sizes**, not range bounds - `0x4006ef5e`
picks one and multiplies by the encoder delta. `param_info(id)+0x10` is the
encoder *acceleration* triple. Neither clamps. A probe that rewrote every long
in the record reading as a max of four came back negative on hardware.

The worst of it was systematic: the page class `ParametersSeqNoteView` puts its
key handler at vtable `+0x48`, not `+0x08` as the two view classes examined
earlier do. Every slot computed by assuming `+0x08` was wrong by `0x40`, which
is why `vtable[0x58]` appeared to be an eleven-argument drawing routine. Derive
a vtable base from its typeinfo, never from where a handler sits in a sibling
class.

Bool Operator is **parameter id 467**, from the master table at `0x401bf93c`: 469
records of 0x34 bytes indexed by global id, which matches `param_info`'s `id < 0x1d5`
clamp exactly, with Track Rotation at 466 and Track Length at 468 - the last record.
Its short name, `+0x0c` in that record, is `OP`.

Dead ends worth not repeating: the numeric fields at `+0x18`/`+0x1c`/`+0x20` of the ROM
record are not min/max (`PL1` and `OP` share `0x4000` despite ranges of 0..64 and 0..3),
and `param_minmax` at `0x400a8f34` does read the pair but is used for parameter `0x29`
alone.

## The patch table

Sites confirmed, stock bytes read out of the image.

| site | bytes | what |
|---|---|---|
| `0x4009ab72` | `75f20800 6014` | `trig_fire`'s non-euclid arm, `mvzw (a2,d0.l),d2`. 6-byte detour; stub re-emits, ORs accent, jumps to `0x4009ab8c` |
| `0x400a884c` | `4eb9400c11b0` | get-by-id arm. Repoint the `jsr` target: 4-byte `from_symbol` patch at `+2` |
| `0x400a9caa` | `4eb9400c11e0` | set-by-id arm. Same |
| `0x400ff3e0` | `7203` | `moveq #3,%d1` -> `#7`, display clamp |
| `0x400ff3ea` | `7003` | `moveq #3,%d0` -> `#7`, display clamp |
| `0x400ff3f4` | `43f9401ec400` | label-table `lea`: 4-byte `from_symbol` patch at `+2` |
| `0x400c0e02` | | `euclid_enabled_get`, detour, return `raw & 1` |
| `0x400c0e32` | | `euclid_enabled_set`, detour, write `(raw & 2) | (arg & 1)` |
| `0x40008f62` | `712a02ca ef88` | `pattern_track_save`, detour; re-emits, packs live bits 1..5 into storage `+0x279` bits 2..6 |
| `0x40008cc4` | `d0809180 4480` | `pattern_track_load`, detour; re-emits, unpacks storage `+0x279` bits 2..6 into live bits 1..5 |
| `0x4009aaca` | `102802ca 43f37a00` | `trig_fire`'s euclid test, detour; re-emits, masks the byte to bits 0..1 before stock's `== 1` test |

### The euclid test at `0x4009aaca`

```
4009aac4:  lea %a2@(0,%a3:l),%a0      | a0 = track base
4009aaca:  moveb %a0@(714),%d0        | euclid_enabled          <-- detour here
4009aace:  lea %a3@(0,%d7:l:2),%a1    | displaced, re-emitted
4009aad2:  eorl %d5,%d0 ; tstb ; seq  | d0 = (enabled == 1)
...
4009aae8:  movel %d3,%sp@(44)         | sets Z on the euclid flag
4009aaec:  beqs 0x4009aaf8            | flag 0 -> grid path
```

`seq` sets the flag only when `raw ^ 1` is zero, i.e. when `raw` is exactly 1. An accent
track carries `raw == 3`, so stock takes the grid path, and `d3` is already the step
when the flags are assembled. With accent alone, no detour is needed. The detour exists
because bits 2..5 are reserved for other mods: a euclid track with any of them set
would fail `== 1` and stop generating. The stub masks `raw` to bits 0..1 and leaves the
test itself unchanged.

### How the flags word is assembled

```
4009ab66:  movel %d3,%d0 ; addl %d0,%d0 ; addl %a3,%d0
4009ab6c:  tstl %sp@(44) ; bnes 0x4009ab78          | euclid path
4009ab72:  mvzw %a2@(0,%d0:l),%d2                   | grid path   <-- detour here
4009ab76:  bras 0x4009ab8c
4009ab78:  ...                                      | euclid path builds its own d2
4009ab8c:  movel %d2,%d0                            | converge
```

At the detour `d3` is the step and `a2 + a3` is the track base, so the stub reaches
`map[step]` directly. `d0` is dead immediately after (reassigned at `0x4009ab8c`);
anything else the stub touches must be saved.

## Open

1. **Label strings and field width** - eight values, four of them new.
2. Register liveness in the `0x4009ab72` stub, instruction by instruction, before
   anything is assembled; `a0` in particular is used further down another path.
3. Whether anything outside MAIN OS - Overbridge, the class-compliant parameter map -
   reads the Bool Operator or the euclid-enable byte and would object to bit 1.
4. `euclid_bake`'s accent-mode body is designed but not written.

## Verification

**Confirmed on hardware (2026-09-17):**

1. OP scrolls through eight values.
2. The four new values draw as the stock gate glyphs with a dot in the top-right
   corner.
3. The popup names them `OR*` / `XOR*` / `AND*` / `SUB*`.
4. Stock euclidean behaviour is unchanged on the base four values.
5. On an accent value, euclid colours the pattern's own trigs instead of
   generating them.
6. Toggling euclid off with FUNC held bakes the result.

Three diagnostics did what reading the code could not - the icon-set probe
(which set is on screen, and that the row order was inverted), the forced
getter (whether the composite accessors are on the page's value path), and the
record probe (whether the encoder range lives in the parameter record; it does
not). Five attempts at the range by inspection eliminated nothing.

**Persistence: the byte is not copied whole.** Reading the converters disproved the
reasoning above. The save (`0x40008dc8`) packs storage `+0x279` as
`(live[0x2ca] << 7) | (live[0x2d0] & 3)` in one byte. Enable lands in bit 7, and accent
lands in bit 8, which the byte write drops. The load (`0x40008b2e`) restores `+0x2ca`
from bit 7 alone. So until the fix below, accents were lost on every save and reload
[measured from the disassembly, not reproduced on hardware].

The fix is two detours that carry live bits 1..5 in storage `+0x279` bits 2..6: accent
in bit 2, and bits 3..6 for live bits 2..5, which 0002 reserves for other mods (0003
keeps its velocity amount there). Three more changes make those bits inert: the setter
keeps bits 1..7, and a detour at `0x4009aaca` masks `trig_fire`'s `== 1` test to bits
0..1. The getter already masked to bit 0. Stock load
ignores bits 2..6 of that byte and stock save writes them as zero. The only other
writer, the v4 -> v5 pattern upgrade at `0x4000b0e6`, writes the byte as zero. Built
and `make verify` passes. **Not yet tested on hardware**: save, power cycle, reload,
and check that accents come back per track without bleeding between tracks.

**Out of scope by decision:** loading a project made here on stock 1.73. The
split storage was designed so that degrades to euclid-off rather than
corruption, and that is still true by construction, but it has not been tested
and is not a goal.
