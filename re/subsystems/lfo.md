# LFO

Investigation only, **closed - see Verdict**: what a **second** LFO per track
would cost. No patch, no `mods/` entry, no `registry/` claim. Findings are from stock MKII 1.73, MAIN OS
at `0x40000400`; `file_offset = addr - 0x40000400`.

Every claim is tagged **[measured]** (read out of `build/stock_mainos.bin` or
`build/mainos.dis`) or **[inferred]** (reasoned from surrounding evidence).

**Headline: a reduced second LFO is storage-feasible; a full eight-parameter one
is not.** The per-sound record maps 42 slots, but the member holding them is 96
bytes = 48 words, and slots 42..47 are allocated and carried across every format
upgrade while being addressed by no code. Six new saved settings therefore cost no
format change (but see Q8: a stock **save** zeroes them), and nine spare
parameter ids already sit in the record table as dead `Error` entries - so neither the sound format nor the id space is
the binding constraint. A full eight-parameter LFO still does not fit: there are
six slots and nine scattered ids, with no free id run adjacent to the LFO's own.
Details in Q1, Q4, Q6 and the decision section.

**The runtime side moves the binding constraint again (Q7).** The block that
the LFO modulates is rebuilt every audio block, so a second LFO can add into it
the same way the first does, and LFO 2 can even target LFO 1's own settings.
The LFO's runtime state is its own 13 x 40-byte table that nothing else reads.
Neither has room for a second instance, though. The per-track live arrays are
42 words, all indexed by sound index, so the six spare storage slots have no
runtime home of their own. Q8 and Q9 show that giving them one means a hook
on every path that moves a sound. But **sound index 0 (storage slot 41) is a
free 16-bit word per track that stock already carries end to end** (Q9). That
is enough for a very coarse LFO 2 with no config RAM and no load or save hook.
The only proven-free RAM, the cave, has 192 bytes left after 0002, so **the
binding constraint is runtime RAM** for state and code.

## The parameter record, and a base-address correction

The code's record base is **`0x401bf918`**, stride `0x34` **[measured]**. This is
not a detail: `[data.param_table_rom]` in `re/symbols.toml` gives the base as
`0x401bf940`, which is `0x28` into each record, so that entry's field offsets are
all shifted by one word. The 19 `lea 0x401bf918,%aN` sites in `build/mainos.dis`
(including `0x40006d34`, `0x400a8fa0`) are the evidence.

| offset | field | evidence |
|---|---|---|
| `+0x00`..`+0x24` | numeric fields, see below | measured |
| `+0x04` | machine-parameter index within the machine | `Speed` = 5, matching DSP order |
| `+0x18` | sequential id, high half increments across the modulatable run | measured |
| `+0x1c` | dense ordinal | LFO reads `0xa0..0xa7` |
| `+0x24` | modflags | see distribution below |
| `+0x28` / `+0x2c` / `+0x30` | long / group / short name pointers | `Bool Operator` / `Euclidean` / `OP` |

Record 467 is the cross-check: `0x401bf918 + 0x34*467 + 0x28 = 0x401c581c` holds
`Bool Operator`, `Euclidean`, `OP`. Record 0 is the placeholder `Error`.

**`+0x18` is a per-page counter, and it is not the MIDI CC** **[measured]**. Its
high halfword increments by exactly 1 along a page's own id list - LFO `64-71` ->
`102..109`, FILTER -> `70..77`, COMPRESSOR -> `78..85`, SAMPLE -> `24..31`,
DELAY -> `16..23`. Ordering by page, not by id, is what makes it monotonic; the
compressor's ids are stored `92, 95, 96, 93, 98, 97, 94, 99`, which is exactly
`78..85` reordered. That is what a MIDI CC table looks like, and it is why
`[data.param_table_rom]`'s note records the guess. **But it is not globally
unique**: the amp envelope (ids `56..61`, `ATK HLD DEC OVR DEL REV`) reads
`78..83`, the same run as the compressor's `THR VOL`. One CC number cannot name
two parameters, so the field is a per-group ordinal, not a CC - the recorded
conclusion holds, though the evidence that entry gives for it (a `+0x28`
halfword reading `0x4f..0x55`) does not reproduce in the corrected frame: real
`+0x28` is the long-name pointer and `+0x50` reads zero for those ids. The low
halfword is `0xffff` on every record but id 71 (`DEP`, `0x76`).

**The table cannot grow, but nine ids in it are dead** **[measured]**. 469 records
of `0x34` end at `0x401c585c`, and the next table starts immediately - the bytes
there are a byte table (`16 17 18 19 1a 1b 1c 1d`, then `00 01 02 .. 40`), not
padding. The record count and the id clamp at `0x400ff556` (`id < 0x1d5` = 469)
are the same number for the same reason, so a 470th parameter would need the
table relocated *and* the clamp widened. **But it does not need a 470th record.**
Nine records are `Error` placeholders that **no page in the 12-entry page table
references**: ids **1-5** and **11-14**. All nine carry machine index `-1`
(`0xffffffff`) and ordinal `0xffffffff`, and their name pointers are shared
`Error`/`ERR` strings. Only id 0 is live as filler - pages 0, 9 and 10 use it to
pad their gaps. So nine parameter slots exist inside the current table, needing
neither a relocation nor a clamp change: repoint the name fields, set `+0x04` and
`+0x1c`, and the id is addressable. The id is not the constraint.

### modflags at `+0x24` [measured]

Across all 469 records: `0x600` -> 348, `0` -> 113, `0x200` -> exactly 7, and
`0x10000` -> exactly 1.

- `0x200` is on ids **64, 65, 66, 68, 69, 70, 71** - every LFO control *except*
  Destination. That is the set a modulation destination list should offer, which
  is what corroborates this frame over the `0x401bf940` one.
- `0x10000` is on id **67**, Destination alone.

## The LFO parameters

Page 3 of the parameter page table at `0x4028843c` (`{namePtr, id0..id7}`, `0x24`
B per entry, 12 entries) **[measured]**.

| id | long | short | machine idx | ordinal | storage slot |
|---|---|---|---|---|---|
| 64 | Speed | SPD | 5 | `0xa0` | 33 |
| 65 | Multiplier | MUL | 1 | `0xa1` | 34 |
| 66 | Fade In/Out | FAD | 6 | `0xa2` | 35 |
| 67 | Destination | DST | 4 | `0xa3` | 36 |
| 68 | Waveform | WAV | 2 | `0xa4` | 37 |
| 69 | Start Phase | SPH | 7 | `0xa5` | 38 |
| 70 | Trig Mode | MOD | 3 | `0xa6` | 39 |
| 71 | Depth | DEP | 8 | `0xa7` | 40 |

The storage slot column is `DAT_401c59cc[machine_idx]` - see Q1.

## The per-track modulation block

The LFO runs inside an **existing** per-block loop over all 13 tracks, called
from the audio interrupt. A second LFO therefore needs no new interrupt entry
point.

| item | address | |
|---|---|---|
| mod block | `0x4009e790` | **[measured]** |
| per-track array | `0x8000f7a8` | **[measured]** - `0x8000e57c + 4652` |
| fade envelope | `getFadeStep` `0x4009e580` | the block's only call |
| call site | `0x40120fae` | in the audio interrupt |
| loop body | `0x4009e7c4`..`0x4009ead2` | 13 iterations, `moveq #13` / `cmp` / `bne` |

The per-track stride is `0x54`; the array is **42 words per track** [inferred].
The LFO's own eight settings live in words 1-8 of that same array, which is why
the block reads its configuration from the array it writes modulated values into
**[inferred]** - no separate config block was found.

Destination writes go through `movel %sp@(48),%d1` (track 0..12), `mulsl` by 42,
`addil #2326` (a *word* index), then `%a1@(0,%d4:l:2)` **[measured]**. The
destination index is clamped at 41 with an unsigned compare, so the range is
`0..41` (open question 4). Nothing in the write path constrains a
destination to the non-config region, so free destination words are word 0 and
words 9-41 [inferred].

## Q1 - where a parameter id maps to per-sound storage

**Both maps are full permutations - but the member they address is wider than
either.** `DAT_401c59cc` (voice machines) and `DAT_401c589c` (FX machines) are
the machine-index -> storage-slot maps. Dumped and sorted **[measured]**:

- `DAT_401c59cc` is a **permutation of `0..41`** - 42 slots, all addressed
- `DAT_401c589c` is a **permutation of `0..37`** - 38 slots, all addressed

LFO values occupy storage slots **33..40**, contiguous, via the table above.

`+0x04` is a **container-local** index, not a global one. Proof: id 30 `VEL` (a
per-trig value) and id 65 `MUL` (per-sound) both carry `+0x04 = 1`, and id 38
`PRB` collides with id 101 `BD HD / LEV` at `9` **[measured]**. A per-trig value
cannot share a slot with a per-sound value, so these are two namespaces that
reuse the same index values; only one of them is what `DAT_401c59cc` indexes.

That one is the **sound's**, and it is densely packed `1..41` with index `0`
unused **[measured]** - the ranges below are each contiguous and none overlap:

| sound index | slots | group |
|---|---|---|
| 1..8 | 33..40 | LFO |
| 9..16 | 0..7 | voice machine |
| 17..24 | 8..15 | Sample |
| 25..32 | 16..23 | Filter |
| 33..36 | 24..27 | Amp |
| 37..41 | 28..32 | ACC / DEL / REV / PAN / VOL |

No record in the whole 469-entry table uses sound index 0 - the only ids carrying
it are `Error` (28) and `NOT` (29), and `NOT` is a trig value **[measured]**. So
41 slots are claimed and one (`DAT_401c59cc[0] = 41`) carries no parameter.

**But the mapped array is not the whole member.** `sizeof(soundStorage_v4_t) =
0xa2` (162), and the member holding the array is **96 bytes = 48 words**, not 42
**[measured]**: three independent calls clear or copy that member as one block -
`memset(storage+0x1c, 0, 0x60)` at `0x4000847e` (the live -> storage
serializer, Q8), and
`memcpy(dst+0x1c, src+0x1c, 0x60)` at `0x40009de4` (v2->v3) and `0x40009ec4`
(v3->v4). The live mirror is `memset(live+0x14, 0, 0x54)` = 42 words at
`0x40008256`, so storage is deliberately 12 bytes wider than the live array it
mirrors. Size and sentinel agree: allocation `0xb4 = round_up(16+162,4)` at the
`make_shared` helper `0x40170ed4`, `pea 0xa2` memset length at `0x40170f08`, end
sentinel written at `+0x9e` (`movel %d2,%a2@(158)`, `0x40008570`), next member at
`+0x7c` with no padding.

That leaves **slots 42..47, storage offsets `0x70..0x7b` - six 16-bit words that
are allocated, zeroed and carried across every version upgrade, but addressed by
no code** **[measured]**. The converter loop is bounded at 42 (`moveq #84`, byte
step 2, six sites), the map is a 42-entry permutation, and a scan of the sound
code finds no *word* access at any even offset in `0x70..0x7a`. The one apparent
counterexample, `pea %a3@(112)` at `0x400084f2`, is the **live** `sound_t`: in
that function `%a3` is live and `%a2` is storage.

So a second LFO has **six** spare settings, not zero and not eight, and their
three possible homes are

1. **slots 42..47**, which need no size change, no version bump and no format
   change, but do need the 42-entry map `DAT_401c59cc` grown to 48 and the
   converter loop bound with it. It cannot be grown in place:
   `0x401c59cc + 168 = 0x401c5a74` is the *next* table, and the live clear at
   `0x4000826a` reads it. So this means relocating the map and repointing every
   `lea 0x401c59cc`, or
2. growing the struct past `0xa2` - a **serialization format change**, touching
   the converters at `0x4000847e`/`0x40009de4`/`0x40009ec4`, the machine-load
   inverse, and the file-format version (see Q6).

**Resolved:** the size question that gated this is closed - see the measurement
above. Six words are provably free and provably already serialized. The ordinal
space does have headroom - `0xa8..0xff` is a free run of 88 - but that is the
MIDI/Overbridge numbering space, **not** storage.

## Q3 - the four `modTarget_t[4]` slots are all live

Eliminated. All four slots are live modulation routes (`{u16 amount, u8
destination}`, indexed 0..3, defaulting to destination 28 = "None"), enumerated
by a 4-iteration loop in `ModSetupView`'s draw at `0x4004b57a` **[measured]**.
The "ride an unused slot" design needs no new storage or parameters, and is dead.

## Q4 - pages

Pages are a **12-entry data table**, not hard-coded per page. Page IDs are clamped
below 12 at `0x400ff574` **[measured - single pass]**. Pages 9 and 10 (REVERB,
DISTORTION) already contain zero gaps, so a partly-populated page is a
stock-supported shape.

The parameter **ids** are allocated contiguously per page - LFO `64-71`, DELAY
`72-79`, DIST `80-91`, COMP `92-99` - so **there is no free 8-id run adjacent to
the LFO**. There are nine spare ids total (`1-5`, `11-14`, all `Error` records no
page references - see the record section), but they are not contiguous and none
of them is near `64-71`. A second full page adjacent to the LFO's ids is not
available; a second page drawing on scattered spare ids is.

`compressor-hardware.md` records the idiom: a second page works by
duplicating a valid page ID in the vector and distinguishing by the selected
index at `+0x8c`. That note also records that the "audit all selected-page
consumers" step was skipped for the compressor; it has **not** been done here
either, so a duplicated LFO page is a shape, not a verified plan.

## Q5 - cost

Loop body `0x4009e7c4`..`0x4009ead2` is 267 instruction lines across all branch
arms; roughly 200 execute per track. Times 13 tracks = **~2,600 instructions per
32-sample block** **[inferred - static count, no cycle weighting and no
measurement]**. There is no measured CPU-utilisation figure anywhere in `re/`,
and the cycle-probe harness does not exist. Whether a second instance fits is
**not established**; do not read the instruction count as headroom.

## Q6 - what extending the record past 48 words would cost

The save format is **versioned, with the limit hardcoded per file type**. Three
reader functions each check a type byte at `+0x0d` and a version field at `+0x11`
**[measured]**:

| file type | type byte | version limit | storage class | reader |
|---|---|---|---|---|
| project | 1 | `moveq #9` | `projectStorage_v9_t` | contains `0x4002e136` |
| bank | 2 | `moveq #4` | `soundPoolStorage_v4_t` | contains `0x4002fc3c` |
| sound | 3 | `moveq #4` | `soundStorage_v4_t` | `0x4002fd0c` |

Each rejects version `-1` as "Invalid ... version" and version > limit as "... is
newer than what the device supports" (`0x4023e9c6`, `0x4023e9b1`, `0x4023eb67`,
`0x4023eb7d`, `0x4023eb1d`, `0x4023e9d8`, `0x4023e9f0`). The three limits match
the three class version suffixes exactly, so the header version *is* the storage
class version.

The upgrade ladder is real code, not just names: `0x40009de4` is v2->v3 and
`0x40009ec4` is v3->v4, each copying the record **member by member** - the `0x60`
block at `+0x1c` whole, then `+0x7c`, `+0x7d`, `+0x7e`... by name **[measured]**.
That is precisely why slots 42..47 are free: they ride inside the block every
upgrade copies verbatim, so they survive the whole ladder without anyone knowing
they exist.

Growing the record past 48 words would therefore mean: a v5 record with a longer
member; a v4->v5 converter added to the chain, plus a fifth step in the driver
`0x4000db4a`; `soundStorageContainer_t` raised from `0xac` to the new max; and
the header version limit bumped `4 -> 5` at both `0x4002fd80` (sound) and
`0x4002fca2` (bank - banks embed sounds and carry their max version). Three of
those four are mechanical; only the converter is new logic.

**Forward compatibility.** Stock 1.73 running the same check rejects a v5 sound
outright, and rejects the **whole bank** containing one - the message is
whole-bank, not per-sound. That is clean forward incompatibility rather than
corruption, but it means one modified sound poisons a bank on stock firmware.
The reverse direction is the designed path: v1..v4 are all still readable.

**The payload is a binary blob, so the spare slots survive the upgrade chain
for free** - but not a stock save, which rewrites them as zero (Q8). The
record carries magic `0xbeefbace` at `+0x00`, its **own version at `+0x04`**, and
the sentinel `0xbacef00c` at the end of whichever version it is **[measured]**.
`0x40009c92` checks the magic; `0x4000a0c4` stamps `4` into `dst+0x04`;
`0x4000dd8c` tests `cmpl %a2@(4),%d0` with `moveq #4`. The JSON in the image is
container metadata (`"sound_tags":[`, `"hash"`), not the record.

The migration is a real in-place chain, driven by `0x4000db4a`, which for each
version N = 1..4 does `make_shared<soundStorage_vN_t>`, runs the per-version
converter with the caller's buffer as source, and on success `memcpy(buffer, obj,
sizeof(vN))` - sizes `0xac`, `0xac`, `0xa8`, `0xa2` read straight off `pea`
immediates **[measured]**. The converters are `0x40009c6c` (v0->v1, requires
`src@(4) == 0`), `0x40009d1e` (v1->v2), `0x40009d88` (v2->v3), `0x40009e68`
(v3->v4). `soundStorageContainer_t` = `0xac` is the max-size load buffer.

**So the spare slots cost nothing at the version layer.** A sound that uses
`0x70..0x7b` is still a well-formed v4 record: the version stays 4, the converter
chain copies the `0x60` member verbatim, and the magic and sentinel are
untouched. Note the header version the validators read (at header `+0x11`) is a
**separate field from the record's own version at `+0x04`**; no firmware code was
found writing `+0x11`, so that header may be produced by the container or host
side. It does not affect the conclusion.

## Q7 - the runtime side: what the LFO reads, writes and keeps

### Four parallel per-parameter arrays [measured]

The trig-apply loop at `0x40120954` walks a list of 8-byte entries
`{u16 track, u16 sound_index, u16 value, u16 value2}` and writes each value
into several arrays that share one index. Let `g = 26 + 42*track + sound_index`
(26 global entries come first, then 13 tracks of 42, so 572 in total):

| array | element | written on trig | role |
|---|---|---|---|
| `0x8000e59e` (`e57c+34`) | u16 `[42*track + idx]` | `value` | [inferred] target |
| `0x8000ee84` | u32 `[g]` | `value << 16` | smoother state, snapped on trig |
| `0x8000f774` | u16 `[g]` | `value` | **effective value**, what the LFO modulates |
| `0x80005f10` | u16 `[42*track + idx]` | `value2` | second list only writes this one |

`0x8000f7a8`, the LFO's "per-track array", is `0x8000f774 + 2*26`: element `g`
for track 0, index 0. The LFO's own config and its destination therefore both
live in the **effective** array.

### The effective array is rebuilt every block [measured + inferred]

In the audio interrupt, in order:

1. `0x40120c8e`: a smoother loop, `d3 = 572`, stepping 2, writes the effective
   array `0x8000f774` from the state at `0x8000ee84` **[measured]**. It rewrites all 572 entries every block.
2. `0x40120e3a`: a 48-entry scatter into `0x8000f774` via the index table
   `0x8000ecac`, gated on `0x8000fce8`.
3. `0x40120f5c`: a 48-route add into `0x8000f774` - source index from byte
   table `0x8000ec7c`, `{dst, scale}` from `0x8000ebbc`. That is 12 x 4, the
   `modTarget_t[4]` routes (Q3) [inferred].
4. `0x40120fae`: `jsr 0x4009e790`, the LFO.

The LFO's destination write is read-modify-write with a clamp to `0..0x7fff`
(`0x4009ea88`..`0x4009eaa2`). It would run away if the array were not rebuilt,
and it does not, which corroborates step 1. **So a second LFO needs no new
refresh mechanism.** It adds into the same array at the same point.

**LFO 2 can modulate LFO 1.** LFO 1 reads its config from words 1-8 of the track's
effective slice at the start of each iteration. The mapping is `mvsb` at `+4654`,
`+4656`, `+4658` and `+4660` for MUL, WAV, MOD and DST (the byte is the high
half), and `mvsw` at `+4662`, `+4664`, `+4666` and `+4668` for SPD, FAD, SPH and
DEP. The destination clamp is `<= 41` and admits words 1-8, so an LFO 2 that
runs **before** `0x4009e790` and targets word 5 or 8 gives speed or depth
modulation of LFO 1 with no further work [inferred]. Stock LFO 1 aimed at its
own words would take effect one block late, if its destination list offers them
at all. That was not checked.

### LFO runtime state [measured]

`0x41942554`, stride `0x28`, 13 tracks, ending at `0x4194275c`. Cleared by
`0x4009e730`, which is called once from `0x4011fa6c`. A getter at `0x4009e76c`
returns the base, but nothing references it: no `jsr` and no stored pointer in
the image. **Nothing outside the LFO reads this state.**

| off | use |
|---|---|
| `+0x00` | phase accumulator, wraps at +/-`1382400000` |
| `+0x04` | current output / latched value |
| `+0x08` | random value, from the shared RNG `0x4009e774` |
| `+0x0c` | previous output, the RND smoother's state |
| `+0x10` | fade envelope, clamped `0..0x3fffffff` |
| `+0x14` | phase at the last RND draw |
| `+0x18` | one-shot/hold latch (`%a4`) |
| `+0x1c` | retrigger-this-block flag |
| `+0x20` | destination, copied from config |
| `+0x24` | output when not held |

All ten words are used, so there is no slack in the existing table.

Waveforms dispatch through `0x401db504`: six function pointers
(`0x4009e69a`, `0x4009e6b0`, `0x4009e67c`, `0x4009e68e`, `0x4009e70a`,
`0x4009e6fa`). Each takes the phase on the stack and returns the value in `d0`.
Entry 6 is 0: RND is handled inline, with SPH>>8 indexing the smoothing
coefficients at `0x401db51c`. The six functions are leaf routines, so **an LFO 2
stub can `jsr` them** rather than carry its own waveforms. The RNG
`0x4009e774` is a two-word additive generator in `0x40287ca4/8`. A second caller
only perturbs LFO 1's random sequence.

### What a second instance needs, and what is missing

- **Hook: available.** The call at `0x40120fae` is a 6-byte `jsr abs.l`, the
  one detour form the registry supports. The LFO has exactly one caller
  (`0x40120fb0` is the only occurrence of its address).
- **Destination: available**, as above.
- **Config at runtime: missing.** Every per-track array is 42 entries indexed
  by sound index. Sound index 0 is the only free one (Q1), and it gives one
  word per track, not six. Slots 42..47 exist only in the storage record: the
  live mirror is 42 words (`memset(live+0x14, 0, 0x54)`), and the trig list
  addresses `0..41`. An LFO 2 would have to read its settings from the
  per-track sound storage directly, which needs the storage->live path (open
  question 2) located. **P-locks and modulation of LFO 2's own settings are
  out of reach** without widening all four 572-entry arrays, their shared
  stride, and the 572 loop bounds.
- **State RAM: missing.** A reduced LFO needs at least a phase and a held
  value, 8 B x 13 = 104 B. A faithful copy of LFO 1 needs 520 B. The only
  verified pool is the cave (`0x402cc920`, 1760 B). Mod 0002 occupies 1568 B of
  it, measured as the last non-zero byte of `build/mainos_0002.bin` in the
  pool, so **192 B are left**. Once code is counted, that does not hold even
  the reduced LFO: phase step, waveform `jsr`, depth scale and clamped RMW for
  13 tracks is plausibly 150-250 B before state. No other pool has been found.
  The two large zero runs in the image are suspected `.bss` (see
  `registry/allocations.toml`).

## Q8 - the sound load and save path

Both directions are now located **[measured]**. Neither one carries slots 42..47.

**Load, storage -> live: `0x400081f6`**. It is called from `0x4018bbc0`,
`0x4018ca06`, `0x4018cb98` and `0x4018cc4e`. It requires record version 4
(`cmpl %a3@(4)` against 4), then `memset(live+0x14, 0, 0x54)`. Then, for slot
`k = 0..41`, it does `live[0x14 + 2*inv[k]] = storage[0x1c + 2*k]`, where
`inv = 0x401c5a74`. Slots 42..47 are never read.

**Save, live -> storage: `0x4000843a`**, with 10 callers (`0x4000ef0c`,
`0x40086c5c`, `0x40088414`, `0x40094bc2`, `0x400bc3e4`, `0x400bcdfc`,
`0x4010262e`, `0x4018bc28`, `0x4018cba4`, `0x4018cc5e`). It writes magic
`0xbeefbace` and version 4, then `memset(storage+0x1c, 0, 0x60)`. It then
writes the 42 mapped slots through `0x401c59cc` and stamps the sentinel at
`+0x9e`. The `memset` Q1 read as a converter is this serializer. **Every stock
save therefore writes slots 42..47 as zero.**

`0x401c5a74`, the table directly after `0x401c59cc`, is its **inverse**
(slot -> sound index). `0x401c5934` is the inverse of the FX map `0x401c589c`.
So growing the map to 48 (Q1 option 1) means growing two adjacent tables, not
one. The getters `0x40007602` (sound index -> slot) and `0x400075c8`
(slot -> sound index) choose the FX map for track 12 and the voice map for
0..11. Their callers at `0x40007fc4`..`0x4000819a` convert the 48 scene/perf
routes and the `modTarget_t` entries, not the parameter array.

**The live sound object has no known slack.** In the offsets the load writes,
`+0x14..+0x67` is the 42-word array and `+0x68..+0x6c` are unpacked bytes. The
`modTarget_t[4]` routes at `+0x70` are 3 bytes each. More 3-byte entries follow
from `+0x8c`, and the record at `+0x7c` is loaded through `0x40007be2`. The
three bytes `+0x6d..+0x6f` are the only unexplained gap, and nothing has proven
them unused.

### What this means for a second LFO's settings

The six spare slots are **usable, but only with two detours**, and not the free
lunch Q1 implied:

- a detour on the load at `0x400081f6` that copies storage slots 42..47 into
  an LFO 2 config table, and
- a detour on the save at `0x4000843a` that writes them back after its
  `memset`.

Both converters are handed only `(live, storage)`, not a track number, so the
config table has to be keyed by the live object's address. That needs the
live sounds' container: its base and stride give `track = (live - base) /
stride`. That container is not located. The four load callers in
`0x4018b..0x4018c` are where to look.

Portability follows directly. A sound saved on modded firmware and loaded on
stock keeps its LFO 2 settings in the file, because load ignores the slots.
**They are erased the first time stock saves that sound or its kit.** That is
silent loss, not corruption, and it is the price of avoiding a v5 record (Q6).

The audio interrupt still reads LFO 2's config from the RAM table, not from
the storage. So the config path costs another **6 words x 13 tracks = 156 B**
of RAM, on top of G6's state and code. With P-locks out (Q7), the table
changes only on load and on edit. Editing adds a third hook: the parameter-set
path for the new ids (G2), which must write the table.

## Q9 - keying LFO 2's settings, and the one word stock already carries

### Keying by live-object address does not work [measured]

The live sound object is **0x98 bytes**, and it moves between owners by value.
At `0x4018ca06` and `0x4018cb98`, the load target is a fresh `0x98`-byte heap
block: `pea 0x98; jsr 0x400829d4`, a thunk to the allocator `0x40082758`. At
`0x4018bb8c` and `0x4018cc44` a whole `0x98` is `memcpy`'d between objects. The
object is then handed to owners through virtual setters (vtable `+0x10`) and
read back through getters (`+0x28`). Examples are `0x400b34d4` and
`0x400b33dc`, both indexed off the project object that `0x4017f83e` returns.
So the `live` pointer Q8's load and save see is often a temporary, and a table
keyed by it would be keyed by garbage.

The object is also full. The load writes it up to `+0x97`: the array at
`+0x14..+0x67`, bytes to `+0x6c`, four 3-byte entries at `+0x70`, a 16-byte
record at `+0x7c`, and four 3-byte entries at `+0x8c`. Only `+0x6d..+0x6f` are
unexplained, and the save does not serialize them (see `sound-storage.md` for
the full layout and what those three bytes could carry). Six extra words cannot ride inside the object, so any settings
kept outside it have to be re-hooked on **every** path that moves a sound:
pool <-> track, file, kit load, copy/paste and reload. Those paths are not
enumerated. The Q8 plan is therefore **much more expensive than two detours**.

### Sound index 0 / slot 41: a free word with a complete stock path [measured]

`0x401c59cc[0] = 41` and `0x401c5a74[41] = 0`. Sound index 0 maps to storage
slot 41, and no parameter record uses sound index 0 (Q1). Every stock stage
handles that word like any other:

| stage | where | index 0 carried? |
|---|---|---|
| file | storage `+0x1c + 2*41` = `+0x6e` | inside the mapped 42, so written by save, read by load |
| save / load | `0x4000843a` / `0x400081f6` | yes, both loop over `k = 0..41` through the maps |
| live object | `+0x14` (word 0 of the array) | yes, moved with the whole `0x98` |
| effective array | `0x8000f7a8 + 0x54*track`, word 0 | an LFO 1 destination (`0..41`) already reaches it |

So **16 bits per track are saved, loaded, copied, pool-transferred and undone by
stock code**, with no load hook, no save hook, no side table and no RAM for
config. Stock firmware preserves the value too, unlike slots 42..47, because it
is inside the mapped 42. That removes Q8's portability loss.

What 16 bits buys is a **very reduced** LFO 2. One packing that fits:
destination, 6 bits (`0..41`); signed depth, 5 bits; and a combined
speed/waveform code, 5 bits. It is coarse, but it is a real second modulator,
and a destination of 5 or 8 gives modulation of LFO 1's speed or depth (Q7).

Not yet established, and each one gates this design:

1. **Whether the trig list writes index 0.** If the per-trig entry list
   (`0x40120954`) only carries indices that have parameter records, index 0
   never reaches the audio-side arrays, and the stub would have to find the
   track's live object. That object is reached by getter, not a fixed address.
2. **Which audio-side array to read.** The effective array `0x8000f774` is
   smoothed (Q7, step 1). A packed bitfield passing through a slew would be
   read as intermediate garbage during a change. The target array or
   `0x80005f10` is probably unsmoothed [inferred], but that is not proven.
3. **Editing.** A value needs a parameter record to be edited. That means
   repointing one of the nine dead ids (G2) at sound index 0, as `+0x04 = 0`,
   plus a page slot (G3). How the UI formats one packed word as three fields is
   a separate problem. The alternative is three records that share one word
   through read-modify-write setters, which is again a detour per path.

## Verdict: shelved

Decision (2026-09-19): only a full eight-parameter LFO is worth building, and a
full one does not fit this firmware at a reasonable cost. The investigation is
closed; nothing is claimed in `registry/`.

What a full LFO 2 would need, from Q1-Q9:

- **Saved settings.** Eight are needed and seven are free: slots 42..47, plus
  slot 41. So a v5 sound record is needed (Q6). Stock would then reject any
  bank that contains a modded sound.
- **Live sound object.** The object is `0x98` bytes, full, and copied by
  value. There are 45 `pea 0x98` sites to audit and grow (Q9).
- **Audio-side arrays.** Giving LFO 2's settings p-locks, scenes and
  modulation, as LFO 1 has, means widening the per-track stride from 42 to 50
  in all four arrays. Up to 108 `#42` sites need to be separated from
  unrelated uses, along with the 572-entry loops (Q7).
- **RAM.** 520 B of state plus about `0x34e` B of code, copied from
  `0x4009e790`, against 192 B free (G6).
- **UI.** Eight of the nine dead ids and a page (G3, unresolved).
- **CPU.** This doubles an unmeasured ~2,600 instructions per block (G4).

Reduced variants (C2, and Q9's one-word LFO) are feasible but rejected as not
worth the effort.

## Decision: candidates against the gates

| gate | passes only if | verdict |
|---|---|---|
| G1 storage | >=2 free words/track in the `0x54` block, **or** slots 1..3 unused, **or** a new pool proven at runtime | **passes for C2** - six free 16-bit slots exist at 42..47 at no size cost, so nothing about the *format* changes; **fails for C4 as specified**, which wants eight; slots 1..3 live |
| G2 parameter identity | `0x1d5` clamp widen-able with a verified patch, or no new id needed | **passes for up to nine** - ids `1-5`, `11-14` are `Error` records no page references; repurposing them needs no table growth and no clamp change. A tenth would |
| G3 page | `<12` clamp widen-able, or page 3 reused | open; duplicate-a-page-id is stock-supported |
| G4 cost | stated static estimate shows plausibly fits | **unresolved** - estimate only |
| G5 recovery | patch/detour with stock `expect` bytes, bootstrap untouched | passes by construction |
| G6 runtime RAM | code + >=104 B state in a verified pool | **fails today**: 192 B of the cave remain after 0002 (Q7) |
| G7 runtime config | LFO 2's settings readable from the audio interrupt | **six words: expensive** (Q8, Q9). Slots 42..47 need a hook on every path that moves a sound, because the live object is copied by value and has no room. **One word: free** (Q9). Sound index 0 / slot 41 is carried end to end by stock, pending the three checks listed in Q9 |

Ranking:

- **C1 - global/performance LFO.** One accumulator through the existing
  `perfParam_t` path. Passes G2 and G3 by construction; trivial state. Cheapest,
  and gives up per-track independence, which is the point of a second LFO.
- **C3 - ride unused `modTarget_t[4]` slots.** **Eliminated** (Q3).
- **C2 - reduced LFO with its own destination and depth.** Two or three new
  parameters, riding spare ids or a widened clamp. **G1 passes**: slots 42..47
  hold six settings with no size change and no version bump. This is the shape
  the storage findings favour.
- **C4 - full second 8-parameter LFO on its own page.** Needs **both** clamps
  widened, eight parameter records, eight sound-storage slots, and a new page
  descriptor. Most valuable, least feasible - it is the one that requires the
  serialization change.

Feasibility ranks roughly **C1 > C2 > C4**; feature value ranks the reverse. The
measurement that decides between them - whether `soundStorage_v4_t` has free
slots beyond 41 - is now made and answers **six**: enough for C2, not for C4 as
written. C4 could be salvaged only by finding two of its eight settings a home
that is not per-sound storage.

Both identity questions now land favourably and independently: **six** spare
storage slots (G1) and **nine** spare parameter ids (G2), neither needing a
format change, a table relocation or a clamp widen. C2 needs at most three of
each, so the two gates that could have killed it are both open. What is left is
the page (G3) and the per-block cost (G4), and G4 is the one with nothing
measured behind it. The parameter *id* is addressable; whether anything on the
machine side reads it is the part no storage measurement can answer.

## Open questions

1. ~~Total size of `soundStorage_v4_t`, and blob-vs-JSON~~ - **closed**: `0xa2`,
   member is 48 words, slots 42..47 free and already carried by every upgrade;
   and the record is a **binary blob** (magic `0xbeefbace`, its own version at
   `+0x04`, sentinel at the end of the version). The spare slots survive the
   upgrade chain but are zeroed by every stock save (Q8). The JSON in the image
   is container metadata. See Q6.
2. ~~The storage -> live path~~ - **closed** (Q8): load `0x400081f6`, save
   `0x4000843a`. Mapping a live object to a track by address is not viable,
   because the object is copied by value (Q9).
3. ~~Which writer populates `0x8000e57c`~~ - **partly closed** (Q7): the trig
   list at `0x40120954` writes all four arrays. Still open: who builds that
   list, and whether LFO 1's destination list offers words 1-8.
4. ~~No lower bound on the LFO destination index~~ - closed: the clamp is an
   unsigned `bcss` against 41, and the destination is loaded with `mvsb`, so
   negative bytes wrap high and are rejected. The range is `0..41`.
5. Per-block cost, measured rather than counted.
6. `+0x18`'s exact meaning; it looks like a sequential id but no reader was found.
7. A second RAM pool. Without one, G6 fails, unless 0002 shrinks or is dropped.
   An LFO 2 needs its own pool, found by the fill-and-readback method the cave
   was verified with.
8. Q9's three checks for the sound-index-0 word: does the trig list carry
   index 0, which audio array is unsmoothed, and how would it be edited.

## Wrong turns, kept

- **The parameter-record base.** An `0x28` frame shift produced a whole pass of
  self-consistent but wrong field offsets - the table base was taken as
  `0x401bf940` (which is really `+0x28`, the long-name field) instead of the
  code's `0x401bf918`. Both frames name the eight LFO parameters correctly,
  because a record's first three words are its name pointers, so the shift is
  invisible to a name check. It only surfaced from the `lea` sites in the
  disassembly, and is corroborated by `0x200` landing on exactly the seven
  non-Destination LFO controls. `[data.param_table_rom]` in `re/symbols.toml`
  still carries the shifted base.
- **`ValueWithMirror<modTarget_t[4], ...>`.** A pass reported its constructor at
  `0x401803c6`; that address is the destructor. Records the hazard that a
  typeinfo-adjacent address is not automatically a constructor.
- **C3.** All four `modTarget_t[4]` slots are live. The cheapest candidate was
  the first eliminated, which is why Q3 was run second.
- **"The array is full."** Reading `DAT_401c59cc`'s 42 entries as the extent of
  the storage member gave "42 slots, 41 claimed, at most one spare" - and that
  was reported as a firm answer before the member's actual length was measured.
  The map's length is not the member's length: the member is 48 words and the
  map covers 42 of them. A permutation table bounds what is *addressed*, never
  what is *allocated*. Both frames are self-consistent; only the `memset` length
  distinguishes them.
- **"The constraint is the index map."** The correction above moved the binding
  constraint from the member's size to the map's length, and that was reported
  as the final answer. It was not: the parameter *table* is the same shape of
  constraint and was checked later, not at the same time. Both times the error
  was the same one - measuring the structure that was in hand and generalising
  it to the system. A parameter needs storage **and** a record **and** an id;
  measuring one of the three is not measuring the constraint.
- **"The spare slots round-trip for free."** Q1 and Q6 read the
  `memset(storage+0x1c, 0, 0x60)` at `0x4000847e` as a format converter, and
  concluded that slots 42..47 survive everything. It is the stock live ->
  storage **save**, which zeroes them every time. The upgrade chain does carry
  them, and that was the only path that had been checked. Same error class as
  the three below: one path through the system was measured, and the result was
  generalised to all of them.
- **"Nine ids is zero ids."** The third instance, caught within the same pass
  rather than reported: the record table ends exactly at the `0x1d5` clamp, so
  the table being full was read as the *id space* being full. It is not - the
  table is full of records, nine of which are dead `Error` entries no page
  references. A full table and a full id space look identical until you check
  what is *in* the table. Three times now the answer was one level of indirection
  away from the structure that was measured.

## Reproduction

Read-only. `build/mainos.dis` greps plus big-endian word dumps from
`build/stock_mainos.bin` at `addr - 0x40000400`. No Ghidra run was needed for the
findings above; no firmware was patched and no `make` target was changed.
