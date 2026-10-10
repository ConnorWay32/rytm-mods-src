# 0010 kit A/B - status and outstanding work

## What it does

NO + PLAY toggles between the kit as edited and as saved.

| press | kit before | does | popup |
|---|---|---|---|
| first | edited | stashes the working kit, then stock's reload | KIT 1 RELOADED! (stock's) |
| next | original, unchanged | copies the stash back, applied as reload applies | EDITS RESTORED! |
| next | original, changed since | stashes the kit as it now is, reloads: a first press | KIT 1 RELOADED! |
| any | already as saved | stock's reload; nothing armed | KIT 1 RELOADED! |

"Changed since" is a checksum (h = 33h + b over the kit's 0x9e3 bytes) of the
working kit, taken after each press. An edit, a change of kit and any other
reload all change it, so the rule "editing the original ends the A/B" is applied
lazily, at the next press, with no hook on edits.

"Already as saved" is the same checksum before and after the press's reload: the
kit held no edits, so the A/B is not armed and the next press is another plain
reload, rather than an "EDITS RESTORED!" that restores nothing.

## How

Stock reload (`kit_reload`, 0x400af0d2) is one memcpy of the saved kit's 0x9e3
bytes over the working kit (`project + 352`), then `kit_mark(working, 0)`,
`kit_apply(working)` and `kit_push(data)`. Two places call it for one kit, each
followed by its popup:

- NO + PLAY, in a key handler: the call at 0x400cd4ae, then "KIT %d RELOADED!"
  (0x40255ea6, pushed at 0x400cd4d6) with the kit's number. Found on hardware:
  the first build patched only the other site, and NO + PLAY stayed a plain
  reload showing "KIT 1 RELOADED!".
- `kit_reload_key` (0x400dd546): the call at 0x400dd5de, then "KIT RELOADED!"
  (0x402578ae, pushed at 0x400dd5e6). What reaches it is not established;
  probably the kit menu's reload.

Four patches repoint both calls and both strings to the toggle and its buffer;
reloading every kit stays stock. For a reload the toggle copies the calling
site's own stock string into the buffer, told apart by its return address
(0x400cd4b4 for NO + PLAY): only NO + PLAY's formatter is passed the kit's
number, so only its string may hold %d. Its own messages hold no %.

The stash comes from `mem_new` on the first press and is kept. If that fails,
the press is a plain reload under stock's text.

Code: 274 B of the 292 at the end of cave7. At the end of cave6, section `.kab`
(`"awx"`), 70 B: the state, the popup buffer, "EDITS RESTORED!" and the checksum
routine, moved there when cave7 ran out. The Rytm runs code from any RAM.
The telem and cal builds of 0006 take all of cave6 and leave this mod out.

## Open

- `kit_mark`'s meaning. Every stock caller passes 0, after reload and after save,
  so it may be a modified flag. The restore passes 0 as reload does, so a
  restored kit may read as unmodified; saving it keeps the edits (hardware test
  step 6).

## Verified

On hardware, 2026-09-27, the test below: the toggle, the FX track restored with
the rest - so edits do live in the working kit's 0x9e3 bytes - edits on the
original replacing the stash, a plain reload on an unedited kit, and restored
edits surviving a save and power cycle.

## Hardware test

1. On a kit, turn a few knobs (a filter, a level, an FX send). NO + PLAY:
   "KIT 1 RELOADED!", and the saved sound plays. NO + PLAY again: "EDITS RESTORED!", and
   every edit is back, including the FX track.
2. Toggle several times; each press switches cleanly.
3. On the original, turn a knob, then NO + PLAY: "KIT 1 RELOADED!", and the
   original plays; NO + PLAY again brings back the knob just turned, not the
   first edits.
4. Change to a pattern on another kit while the original plays, then NO + PLAY:
   a plain reload of that kit.
5. On a kit with no edits, NO + PLAY twice: "KIT 1 RELOADED!" both times.
6. Save the kit after restoring the edits, power-cycle, and check the edits were
   saved.
7. NO + PLAY with the reload-all setting: stock's ALL KITS RELOADED!
