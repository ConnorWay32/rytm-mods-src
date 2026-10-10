# Sound storage

Where a sound lives on disk and in RAM, how it moves between the two, and what
room is left in each. Stock MKII 1.73, MAIN OS at `0x40000400`. Claims are
tagged **[measured]** (read from `build/mainos_emac.dis`) or **[inferred]**.

Builds on `lfo.md` Q1, Q8 and Q9, which found the six spare storage slots and
sound index 0. Investigated 2026-09-27 for a per-sound HPF, first dropped
because the voice path is analog end to end (`audio-engine.md`), then built by
mod 0013 once its voices went through the DAC: the design below, as built and
tested, is under "Built: mod 0013's filter bytes", and the route amounts' spare
bytes under "The routes' spare bytes".

## Summary

- The stored record (`0xa2` bytes) has **six spare words, slots 42..47**, that
  stock carries in every file, never reads, and zeroes on every save. The
  version upgrades (`0x40009de4` v2->v3, `0x40009ec4` v3->v4) copy the whole
  `0x60` block at `+0x1c`, so they carry them too (`lfo.md` Q6).
- The live sound (`0x98` bytes) has **three unexplained bytes, `+0x6d..+0x6f`**.
  Load, save and the default initialiser never touch them.
- Every load path found goes through `sound_load` and every save through
  `sound_save`, so one detour on each would cover files, kits, the pool and
  transfers.
- Sounds are copied by raw `0x98` memcpy, which would carry the three bytes.
- So **up to 24 bits per sound** can be opened up with two detours, without a
  format change. Stock load ignores them; a stock save erases them.
- Sound index 0 (slot 41) is a free 16-bit word stock already carries end to
  end (`lfo.md` Q9), but mod 0004 uses all of it.
- Each of the eight velocity and aftertouch routes' amount words has a low byte
  stock only ever writes as 0: **64 more bits**, usable with hooks where stock
  reads the whole word (below, "The routes' spare bytes").

## The stored record, `SoundStorage` v4 [measured]

`0xa2` bytes, from `sound_save` (`0x4000843a`) and `sound_load` (`0x400081f6`):

| offset | size | content |
|---|---|---|
| `+0x00` | 4 | magic `0xbeefbace` |
| `+0x04` | 4 | version, 4; load rejects anything else |
| `+0x08` | 4 | live `+0x00` |
| `+0x0c` | 16 | name, live `+0x04` |
| `+0x1c` | 96 | 48 words: slots 0..41 mapped from sound indices, **42..47 spare** |
| `+0x7c` | 1 | live `+0x68` |
| `+0x7d` | 1 | live `+0x69..+0x6c`, two bits each, packed `69<<6 \| 6a<<4 \| 6b<<2 \| 6c` |
| `+0x7e` | 16 | live `+0x7c` sub-object, via `0x40007ed6` / `0x40007be2` |
| `+0x8e` | 8 | live `+0x70`, four 3-byte entries as four words, via `0x400083ec` / `0x4000819c` |
| `+0x96` | 8 | live `+0x8c`, four 3-byte entries as four words, via `0x4000816c` / `0x40008138` |
| `+0x9e` | 4 | sentinel `0xbacef00c` |

Slot `k` is at `+0x1c + 2k`, so the spare slots 42..47 are `+0x70..+0x7b`.
`sound_slot_map` (`0x401c59cc`, index -> slot) and its inverse
(`0x401c5a74`) are 42-entry permutations, adjacent, so neither can grow in
place. Sound index 0 maps to slot 41. The word at slot 36 (`+0x64`) is
converted through the map on both paths: it holds LFO 1's destination as a
sound index, and the file stores it as a slot.

## The live sound [measured]

`0x98` bytes, heap-allocated (`pea 0x98; jsr 0x400829d4`) and held behind
shared pointers:

| offset | size | content |
|---|---|---|
| `+0x00` | 4 | stored at `+0x08` |
| `+0x04` | 16 | name |
| `+0x14` | 84 | 42 parameter words, `+0x14 + 2 * sound index` |
| `+0x68` | 5 | bytes `+0x68..+0x6c`, stored at `+0x7c`/`+0x7d` |
| **`+0x6d`** | **3** | **unexplained** |
| `+0x70` | 12 | four velocity `modTarget_t` (`{s16 amount, u8 destination}`) |
| `+0x7c` | 16 | sub-object, conditional on word `+0x3a` |
| `+0x8c` | 12 | four aftertouch `modTarget_t`, the same layout |

`sound_init_defaults` (`0x400122b6`, reached from `0x40012404`) writes the
name, `+0x68..+0x6b`, the 42 words and the three sub-objects, not
`+0x6c..+0x6f`.

### Are `+0x6d..+0x6f` free?

- `sound_load`, `sound_save` and `sound_init_defaults` never read or write them
  **[measured]**.
- An image-wide scan for byte accesses at displacements 109..111, word accesses
  at 108..110 and long accesses at 106..110 (excluding `%sp`, `%fp`, `%pc`)
  finds 118 instructions **[measured]**. The ones in and near the sound code
  belong to other structures:

  | site | why it is not the live sound |
  |---|---|
  | `0x400077ba`, `0x40011cb2` | a struct of longs at `+100..+112` |
  | `0x40007af2` | a stride-4 byte array `+87..+123` |
  | `0x4000975c`, `0x40009980` | a packed struct, word at odd `+107`, clamped to +-5000 |
  | `0x40009f64` | inside the v3->v4 converter `0x40009ec4`, on stored slot 40 |
  | `0x40009cf8` | in `0x40009c6c`, the function before the v2->v3 converter, on stored slots 36 and 40; its role is not established |

  The other ~110, elsewhere in the image, are **not triaged** one by one.
- A freshly allocated sound holds whatever the allocator leaves there
  **[inferred]**: nothing in the constructor paths below clears them.

So they are free as far as static reading goes, not proved free. The
cheapest proof is on the device: write a marker to `+0x6d..+0x6f` of every
live sound and check it after save/reload, kit load, pool load and save,
copy/paste, randomize, undo and SysEx/Overbridge transfer.

## Load and save paths [measured]

- **Load**, `sound_load(live, storage)`: 4 callers (`0x4018bbc0`, `0x4018ca06`,
  `0x4018cb98`, `0x4018cc4e`), plus the loop at `0x40008384` that loads 130
  sounds (live stride `0x98`, stored stride `0xa2`) and falls back to
  `0x40012404` for any that fail.
- **Save**, `sound_save(storage, live, ...)`: 10 callers (listed in
  `re/symbols.toml`), plus the matching loop at `0x4000857e`.
- Both are handed `(live, storage)` only, no track. The live pointer is often
  a heap temporary, so a side table keyed by it does not work (`lfo.md` Q9).

## How sounds move [measured]

- **Copies are raw.** 15 sites call memcpy (`0x40098b54`) with `0x98`
  directly, found by size, so not each confirmed to be a sound; more go
  through registers (`0x4001245c`, `0x4003b9a2`,
  `0x400af248`, `0x400bdb36`, `0x400bdb82`, `0x4018cb1c..0x4018cb34`). Example:
  `0x400a74c4` gets a kit track's sound from its owner and copies it whole into
  a new object. `sound_apply_step_locks` (`0x4003b8aa`) copies the track's
  sound into a `0x98` temporary before overlaying locks. A raw copy carries
  `+0x6d..+0x6f`.
- **Fresh sounds** are allocated and filled by `0x40012404` ->
  `sound_init_defaults`, e.g. the factory at `0x40035a66`, which then hands the
  object to its owner's setter (vtable `+20`).
- **Owners.** Sounds sit behind objects reached through virtual getters and
  setters, off the project object from `0x4017f83e`:
  - kit tracks: `project + 205340`, then `0x400bf1f0(kit, track)`; per-track
    owners at `+60 + 352 * track`, getter at vtable `+40`
  - the 128 saved kits: `project + 7388 + 68 * i`, `i` = 0..127. The single
    kit reload `0x400af0d2` copies `0x9e3` bytes from entry `i`'s data (vtable
    `+40`) over the working kit's (`project + 352`), so these are kits, not
    the sound pool; where the pool lives is not located
  - thunks such as `0x400b34d4` tail-call vtable `+16` on these.

  **The setters' implementations are not read.** If any copies field by field
  rather than as a whole `0x98`, `+0x6d..+0x6f` would be lost on that path
  (for example pool -> track).

## Opening up the spare room

A design that fits what is established, not built:

- **Live:** keep the value in `+0x6d..+0x6f`: a tag byte and 16 bits of
  payload. A wrong tag reads as unset, so allocator garbage in fresh sounds
  and zeroed slots in old files both read as off.
- **Load detour** on `sound_load`: copy stored slot 42 (and a byte of 43) into
  live `+0x6d..+0x6f`.
- **Save detour** on `sound_save`, after its memset: write them back.
- **Capacity:** 24 bits, of which 16 are usable with a tag. The storage side
  has 12 bytes; the live object's three bytes are the limit.
- **Portability:** stock loads such a file normally and ignores the value; a
  stock save of that sound or kit erases it. Silent loss, not corruption.

## Built: mod 0013's filter bytes

Mod 0013 keeps each sound's DAC FILTER settings in the spare room, as above.
The first version (HIGH-PASS) used a tag byte; the current one has none.

- **Live:** `+0x6d` bits 0-2 TYP (OFF, then stock's FILTER order: LP2, LP1,
  BP, HP1, HP2, BS, PK), `+0x6e` FRQ xor `0x7f`, `+0x6f` DEP xor `0x7f`, and
  RES (0..127) in velocity route 0's amount low byte, `+0x71` (below, "The
  routes' spare bytes"); the transient shaper's ATK and SUS, signed -64..63, in
  velocity routes 1's and 2's (`+0x74`, `+0x77`), clamped where read; POL in
  `+0x6d` bit 3. All zero is the defaults (TYP OFF, FRQ 127, DEP FULL, RES 0, no
  shaping, not inverted). `+0x6d` bits 4-7 and bit 7 of `+0x6e`, `+0x6f` and
  `+0x71` are spare; a field there must read 0 as its default.
- **Stored:** slot 42 `(0xb8 + TYP) << 8 | FRQ`, slot 43 `POL << 8 | DEP`,
  written only when the live bytes are not all zero; RES with the route bytes in slots 44..47.
  Anything else in slot 42, including stock's zeroes and the HIGH-PASS tag
  `0xb5`, loads as the defaults. TYP took stock's order when the 2-pole types
  came (2026-10-06); sounds saved before that load another type.
- **Load** (`0x4000826a`, after `sound_load` clears the live array) and **save**
  (`0x40008492`, after its memset) convert between the two.
- **Undefined bytes:** a new object holds whatever the allocator left in
  `+0x6d..+0x6f`, so two more detours clear them: `sound_init_defaults` past
  its null test (`0x400122d0`), and `sound_load`'s entry (`0x400081f6`) when the
  load will fail (record null or not version 4), because `0x4018cb98` uses the
  object without checking the result. A sound reset (`0x400bd756` runs
  `sound_init_defaults` on the track's sound) now resets the filter too.

Every path that creates a live sound was checked statically (2026-10-06): the
six shared-pointer constructions (control block `0x401cbb20`) and six sound
wrappers (`0x9c` bytes, vtable `0x401cbab4`, sound at `+4`), the raw `0x98`
buffers, and the static arrays (in .bss, zeroed at boot). Each is filled by
`sound_init_defaults`, `sound_load` or a whole copy. The search was keyed on the
`0x98` size and those two vtables, so a sound built another way would be missed.

How the original open questions came out:

1. **Whole-object copies, and nothing else writing `+0x6d..+0x6f`:** on the
   device (2026-09-28 and, untagged, 2026-10-06) the values survived kit save
   and reload, loading another kit and back, a pattern change to another kit
   and back, NO + PLAY kit reload, the sound pool, sound copy/paste and a power
   cycle. Not covered: SysEx and Overbridge transfers, undo, randomize, song
   mode.
2. **Runtime access:** still no stock push routine located. 0013 does not need
   one: a tick in the screen's idle routine (`0x400a2aaa`, about 20 a second,
   UI context) reads each track's live sound through `shared_sound_of` and
   copies the values into a 12-entry table the audio interrupt reads. Kit
   loads, pattern changes and sound loads reach the audio within a tick.
3. **Editing:** dead ids 5, 11 and 12 on a second FILTER page (page 13), with
   gates on `page_get_value`, `param_apply_delta` and `param_value_text`
   chained behind 0004's (see 0013's registry entries). Their container index
   stays -1, so stock never treats them as any of the 42 words: they cannot be
   p-locked or reached over MIDI. Each change sends `SoundConfigChangedInfo`
   through the track's sound accessor, or it is lost at a reboot without a kit
   save.
4. **Room:** cave9 and cave12.

## The routes' spare bytes [measured]

Each route is 3 bytes: the amount word (high byte the amount, -128..127; low
byte) and the destination byte. They are not parameters (not in the record
table), so only the VELOCITY MOD and AFTERTOUCH menus edit them.

**Stock never writes a low byte but 0.** Load writes `stored byte << 8`
(`0x40008138`); defaults are whole steps (`0x4001224e`, `0x40012282`); the menu
edits whole steps (`0x4004c09e`: `((getAmount >> 8) + delta) << 8`, or 0 for
FUNC); save keeps the high byte (`0x4000816c`).

**Stock reads the whole word** in three places:

| where | effect of a low byte | 0013's hook |
|---|---|---|
| sound push, `0x4011f63c` (velocity) and `0x4011f660` (aftertouch), copying to `0x8000ea3c + 32 * track`; `0x4011ddbe` multiplies by the whole word | up to one more amount step of modulation | cleared at both copies; the push is the tables' only writer, `0x40120ea4` their only reader |
| the menus' getAmount | the display (`0x4004b878`) rounds toward zero: negative amounts a step nearer 0 | cleared |
| the menus' setAmount and setRoute | whole-word writes would erase it | setAmount puts the old low byte back; setRoute stores the high byte only |

The menus' models are one template instantiated three times: **SoundModConf**
(`0x40033xxx`, aftertouch: setRoute `0x4003391e`, setAmount `0x40033a1c`,
getAmount `0x40033a90`), **Velocity** (`0x400c5xxx`: `0x400c5148`,
`0x400c5246`, `0x400c52ba`; ModSetupView's model is its `+36` interface), and
**ControlInputParam** (`0x40137xxx`), which holds the project's control inputs,
not a sound, and is left alone. CLEAR and PASTE MODULATIONS and their UNDO go
through getRoute and setRoute.

**Stored:** slots 44..47, route i's velocity byte at `+0x74 + i` and its
aftertouch byte at `+0x78 + i`, copied in once `sound_load` has loaded both
route sets (`0x40008364`). A failed load clears them.

**In use:** velocity routes 0..2's bytes hold 0013's RES, ATK and SUS; the other
five are free. Kits saved while the probe below ran carry its marker, `0x5a`, in
all eight: RES reads 90, ATK and SUS +63 (90 clamped).

**Hardware, 2026-10-06:** a debug probe marking every route byte showed them
surviving a kit save and reboot, amount edits, FUNC reset, destination changes,
and CLEAR/PASTE MODULATIONS with UNDO in both menus, with the engine's route
words staying clean. Hooking only SoundModConf at first left the velocity menu
clearing bytes, which is how the second copy was found. Bytes written without
`SoundConfigChangedInfo` did not persist: the stored state came back at boot.
