# 0012 SLICE LOOP - status and outstanding work

## What it does

FUNC + CHRO opens the track menu: TRIGS SETUP, PAD SCALE, RELOAD TRACK, SAVE TRACK,
and now SLICE LOOP. On the selected track it:

1. refuses, changing nothing, on the FX track ("ONLY ON SOUND TRACKS", stock's
   text), on a track shorter than 16 steps ("NEEDS 16 STEPS"), or on a track with
   any trig, lock trigs included ("TRACK NOT EMPTY");
2. sets the track's TRIG page defaults: SYN off, SMP on;
3. places a normal trig on steps 1..16, each following those defaults;
4. locks trig n's sample START to 6(n-1) and END to 6n: 0/6, 6/12 .. 90/96;
5. shows "LOOP SLICED" and closes the menu.

For a one-bar loop padded so the bar is 96/120 of the sample. Swing, accents and
micro timing then move each slice as they would a drum hit.

## How

**The item.** TrackMenuView's constructor builds each item from four std::function
objects on its stack - label, action, an empty one, icon - a 0x54-byte MenuItem
(menu_item_ctor 0x40072f50), an append (0x40072786) and four destructors
(0x401709c6). A detour over its epilogue (0x400f9e96) runs SAVE TRACK's sequence
once more with three invokers of ours and SAVE TRACK's own managers, whose
captures match: nothing for the label and icon, the menu for the action. At that
point every register the sequence uses still holds its value, and the stack is
at the depth each item starts at. Checked on the built image against stock's
SAVE TRACK sequence, line by line: the only differences are the three invokers
and `jsr mem_new` for `jsr %a4@`, which the last item overwrote.

**The action,** SAVE TRACK's (0x400fa112) in shape:

| step | stock routine |
|---|---|
| the track | track_index_of(track_selection(project)) |
| its block | current_track_pattern(project) |
| empty? | trig_flag_get(block, step, 0x01) for every step of its length |
| defaults | param_set_value(param_target_for_track(project, track, 1), 34 / 35, 0 / 0x100, track, 1, 1) |
| a trig | trig_place(block, step, 1) - not trig_place_lock, which makes a trigless lock trig |
| a lock | track_lock_set(block, step, 21 / 22, value in 8.8, 1) |
| the popup | std::string, popup_ctor, a shared_ptr, view_show_popup via the menu's +100 |
| close | the menu's vtable +128 |

Locks are a dense array, one int16 per track, step and sound parameter
(re/symbols.toml, lock_pool_set), so there is no lock pool to fill.

Code and texts: 752 B in cave8, the first claim in the pools 0011 promoted.

## Status

Hardware-verified 2026-09-27.

## Open

- The lock flag is 1, as stock computes it for START and END (their records'
  long at +0x0e is non-zero).
- param_set_value's last three arguments copy the destination list's commit
  (track, 1, 1); for trig parameters they are not traced further.
- cave8 was not exercised by 0011's session on the paths it did not cover
  (sampling, the sound pool, save/reload, song mode, +Drive, USB and
  Overbridge, SysEx).

## Hardware test

1. FUNC + CHRO: SLICE LOOP is listed after SAVE TRACK, with no icon.
2. On a track with a trig: TRACK NOT EMPTY, and nothing changes.
3. On the FX track: ONLY ON SOUND TRACKS.
4. On an empty track of 16 steps with a loop sample assigned: LOOP SLICED;
   trigs on 1..16; hold a trig - START and END read 6(n-1) and 6n; the TRIG
   page reads SYN off, SMP on. The loop plays through, and swing moves the
   slices.
5. Save the pattern, reload it, power cycle: the trigs, locks and defaults stay.
6. Undo, if the device offers it after SLICE LOOP.
