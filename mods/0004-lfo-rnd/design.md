# 0004 LFO RND - status and outstanding work

## What exists

A second LFO page, LFO RND, reached by pressing the LFO page key again. Two random
modifiers per sound, each a destination (DS1/DS2, one of 16) above a depth (DP1/DP2,
0..64 in 16 steps). The four settings are packed into the sound's free parameter
word at sound index 0 (live sound `+0x14`, storage slot 41). On each note trig of a
voice track, each modifier draws an offset of up to +-N for its destination, held
until the next note and added to the effective parameter array before LFO 1 runs.

Destinations: the 8 machine parameters, then FIN, STA, FRQ, RES, DEC, PAN, DEL, REV.

Parameter ids 1..4 are repurposed dead `Error` records. Everything is in `cave2`.

## The destination list

DS1/DS2 open stock's LFO DST list, restricted to the sixteen. Ids 1 and 3 carry
DST's modflag (`0x24` = `0x10000`) so `page_knob_turn` routes them to `0x40039b8e`,
which builds the half-width list view. `list_filter_gate` compacts the vector that
`dest_list_build` returns down to the entries in `dst_indices`, and `setter_gate`
catches the commit - which writes the chosen parameter's container index through
`param_set_value` - and rewrites the nibble instead.

A destination's value is therefore its container index, not its list position, which
is how DST encodes one. That is what lets the list seed and highlight the current
entry with no mapping of our own.

## Confirmed on hardware

- LFO RND page: flipping between LFO and LFO RND, titles, empty knobs.
- All four knobs edit, with working dial and popup. DST shows the destination's
  short name for the track's machine; DEP shows N.
- Phase 2: randomisation is audible on note trigs.
- DS1/DS2 draw the destination's short name in place of a dial, as LFO DST does.
- The destination list: opens on DS1/DS2, holds only the sixteen, sits against the
  left edge, and commits on YES rather than as the knob turns (2026-09-20).
- 0003 running from cave3, and both mods calling into 0000-shared.
- The compaction round of 2026-09-20: the per-track offsets held as bytes, the sound
  lookup shared with 0003, and the knob draw handed off to stock's LFO DST callback.

## Not yet checked on hardware

- Persistence: save, power-cycle, reload, per track.
- Sound copy/paste, sound pool store and load, machine change (machine-parameter
  names should follow the new machine).
- What factory and older-OS sounds hold in slot 41. All four settings should read
  the first destination and 0.
- Whether Randomize (the sound menu function) writes sound index 0. Static reading
  says very likely not, but ids 28 and 29's randomiser slots are not fully resolved.
- Page copy/paste/clear on LFO RND, and whether the view returns to page 1 on a
  track change.
- Whether trigless and lock trigs also redraw the offsets. The redraw is keyed on
  the per-track flag at `0x8000e508`, assumed to mean "a note started this block".
- That a pick survives a save and reload.
- That a machine change re-filters the list, since the eight machine parameters
  change with it.
- That MOD SETUP's list and stock's own LFO DST list are untouched by the filter -
  both are built by the same constructor, and only the mask and container index
  tell them apart.

## Known limitations

- **Held offsets after stop.** The last offsets stay applied until the next note, as
  LFO 1's modulation does. They are audible on ringing notes and on pads or trig
  previews while stopped. Fix: clear the held offsets when the sequencer stops.
- **Pads before the first sequenced trig.** The per-track settings table is filled
  only by `trig_fire`, so pads get no randomisation until the pattern has played.
  Fix: fill the table from the kit's sounds at kit load, or read it in the audio
  hook's redraw.
- **Sound locks.** A step that plays a pool sound still uses the kit sound's settings.
- **Project not marked modified.** Editing writes the live sound directly, so the
  project may not prompt to save. The same applies to 0003's amount.
- **Dial range.** The shared knob draw callback's range source is not traced. Worst
  case the dial does not span its full ring; values and popups are correct.

## Requested, not started

- Nothing outstanding.

## By decision, not planned

- **Empty machine slots in the destination list.** The sixteen destinations are fixed
  positions, so on a machine whose SRC page has empty slots a knob can sit on one and
  reads `--`. The list is built from the sound's real parameters, so those slots never
  appear in it. Decided 2026-09-20 to leave the two inconsistent rather than add `--`
  rows to the list or make the knob skip positions. A destination is stored as its
  machine slot, not as a parameter - the same way stock DST stores a container index -
  so a setting follows the slot across a machine change and reads `--` where the new
  machine has nothing. Whether the modifier's offset is silent when it lands on an
  unused slot is assumed, not verified.

- FX track support.
- P-locking the four settings. The delta hook returns before stock creates a lock.
