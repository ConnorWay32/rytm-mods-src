# User manual

What each mod in the default build does on the device and how to use it. For
building see `README.md`, for installing see `docs/FLASHING.md`, and read
`docs/HAZARDS.md` before flashing.

The default image is
`Analog-Rytm_MKII_OS1.73_0000_0002_0003_0004_0006_0008_0009_0010_0012_0013_0014_0015.syx`. It is stock
OS 1.73 with the mods below added; everything not mentioned here behaves as stock.

| mod | where | what |
|---|---|---|
| 0002 | TRIG > euclidean page, OP | euclid sets accents on your trigs instead of placing trigs |
| 0003 | TRIG page, FUNC + VEL | per-track random velocity |
| 0004 | LFO key, pressed twice | LFO RND page: two random modifiers per sound |
| 0006 | FX track, AMP key, pressed twice | compressor gain-reduction preview |
| 0008 | FILTER page, FRQ | cutoff shown in Hz |
| 0009 | FX track, compressor pages | VOL label lights when the main output is loud |
| 0010 | NO + PLAY | switch between the edited kit and the saved one |
| 0012 | FUNC + CHRO, SLICE LOOP | slice a one-bar loop across 16 trigs |
| 0013 | AUDIO ROUTING > DAC SUM; FILTER key, pressed twice | voices summed through the DAC, with a per-sound filter, transient shaper and polarity |
| 0014 | TRK + any knob | turn that parameter on every sound track |
| 0015 | SOUND SETTINGS > ENV RESET | AMP and AMP+FILT: the amp envelope restarts on every trig |

0000 is the shared code the others call into. It has no controls.

0002 to 0008, 0010 and 0012 to 0015 have been verified on hardware. 0009's display has
been checked on the device.

## 0002 - Euclidean accents

Normally the euclidean generator decides which steps play. With this mod it can
instead leave the pattern's trigs alone and mark some of them with ACCENT: the
grid says when, euclid says which hits are accented.

**Use.** On the euclidean page, the Bool Operator (OP) now has eight values instead
of four:

| value | icon | behaviour |
|---|---|---|
| OR, XOR, AND, SUB | stock gate glyph | stock euclidean |
| OR\*, XOR\*, AND\*, SUB\* | the same glyph with a dot, top right | accent mode, same operator |

In accent mode:

- Only steps with a trig in the grid play. Euclid adds nothing.
- A trig on a step where the euclidean pattern has a hit plays accented.
- Accents you set by hand stay; euclid only ever adds accent.
- Turning euclid off with FUNC held bakes the result: the accents are written
  into the pattern. Turning it off without FUNC leaves the pattern as it was,
  as stock does.

The setting is per track and survives save, power cycle and reload.

**On stock firmware** a pattern saved with an accent-mode track loads with euclid
off on that track.

## 0003 - Velocity humanise

Adds a random offset to the velocity of every trig on a track.

**Use.** On the TRIG page, hold FUNC and turn the VEL knob. While FUNC is held
the label reads RND and the knob selects the amount N:

    0, 1, 2, 3, 4, 6, 8, 10, 12, 16, 20, 24, 32, 40, 48, 64

The sixteen settings sit on evenly spaced positions of the knob. Each trig then
plays at its velocity plus a random amount between -N and +N, kept within
1..127. Release FUNC and VEL behaves as stock. N = 0 is off.

The amount is per track and stored with the pattern. It needs 0002, which saves
it; the two are always built together.

## 0004 - LFO RND

A second LFO page with two random modifiers per sound. On every note trig each
modifier picks a random offset for its destination parameter and holds it until
the next note.

**Use.** Press the LFO page key a second time for LFO RND; press it again to
return to LFO.

| knob | label | setting |
|---|---|---|
| A | DS1 | modifier 1 destination |
| B | DS2 | modifier 2 destination |
| E | DP1 | modifier 1 depth |
| F | DP2 | modifier 2 depth |

A destination knob shows the parameter's short name instead of a dial. Turning it
opens the destination list, as LFO DST does. Pick with the knob, confirm with YES.
The list holds sixteen destinations:

- the eight machine parameters (SRC page), which follow the machine
- FIN, STA (sample)
- FRQ, RES (filter)
- DEC, PAN (amp)
- DEL, REV (sends)

A depth knob selects N from the same sixteen settings as 0003 (0 to 64). Each
note trig offsets the destination by a random amount between -N and +N, clamped
to the parameter's range. The offset is added on top of the parameter's value,
p-locks, slides and LFO 1. Depth 0 is off.

The four settings belong to the sound. They are saved with the kit and survive a
power cycle, and they travel with the sound through copy/paste and the sound
pool. Sounds made before the mod read the first destination at depth 0.

**Limitations**

- Voice tracks only; the FX track has no LFO RND.
- The four settings cannot be p-locked.
- After the sequencer stops, the last offsets stay applied until the next note.
  You may hear this on ringing notes and on pads.
- Pads get no randomisation until the pattern has played at least once.
- A step that plays a sound from the pool (sound lock) uses the kit sound's
  settings.
- A destination is stored as a machine slot. After a machine change it points at
  the same slot on the new machine; where that slot is empty the knob reads `--`
  and the empty slot does not appear in the list.

## 0006 - Compressor preview

An extra compressor page showing a scrolling estimate of the master compressor's
gain reduction. The Rytm has no gain-reduction meter and nothing in the firmware
measures it, so the mod computes an estimate from the voices, the PRE delay and
reverb returns, master distortion and the compressor settings.

**Use.** On the FX track, the compressor page is on the AMP key. Press AMP again
to switch between the stock page and the preview. The knobs keep their stock
compressor parameters on both.

On the preview page:

| keys | action |
|---|---|
| FUNC + AMP | switch layout: full, or GR alone |
| FUNC + LEFT / RIGHT | slower / faster scrolling |
| FUNC + UP / DOWN | vertical scale: more / less range on screen |

- **Full layout:** the input level as a fill, the threshold as a dotted row, and
  the gain-reduction line dipping below the threshold row as the compressor
  works.
- **GR layout:** the gain-reduction line alone, 0 dB at the top.

Scrolling runs from 4 bars to 1/8 bar across the screen at 130 BPM, starting at
1/2 bar. The vertical scale runs from 0.25 to 4 dB a row, starting at 1 dB. The
screen shows the page you left when you come back to the compressor.

**Accuracy.** On drum patterns at random settings the estimate reads about
1.6 dB rms from the measured reduction, with no overall bias; on a steady tone,
0.56 dB. It is a guide to what the compressor is doing, not a measurement.

**Known limits**

- DIST symmetry (SYM) away from 64 is outside the model.
- Reduction beyond about 36 dB is capped.
- POST delay and reverb returns are not modelled; PRE returns register about
  4 ms early.
- Material whose crest factor is far from the calibration tone's (very spiky or
  very dense) reads off.
- To protect the UI, the estimate pauses when the device is busy (for example
  loading after a pattern change), and stops when the page has not been shown for
  about a second.

With 0013's DAC SUM on, the estimate follows the voices after their DAC filter,
as the compressor hears them.

The model and the calibration behind these numbers are in
`re/subsystems/compressor-model.md` and `mods/0006-comp-preview/calibration_report.md`.

## 0008 - Filter frequency in Hz

The FILTER page's FRQ value popup reads as the cutoff frequency instead of
0..127, to three significant figures:

| FRQ | shows |
|---|---|
| 0 | 13.8Hz |
| 60 | 440Hz |
| 76 | 1.11kHz |
| 127 | 21.1kHz |

Each step is one semitone, with 440 Hz at 60.

**Limitations**

- It is the knob's value: filter envelope depth and LFO modulation are not
  included.
- The scale was measured on LP2 with the filter self-oscillating. That the other
  filter types share it is assumed.

## 0009 - Main output level indicator

For gain staging: on the compressor pages, the VOL knob's label is drawn inverted
while the main output is louder than -18 dBFS RMS.

**Use.** On the FX track, open the compressor page (AMP), stock or 0006's preview.
Play the pattern and watch the VOL label: inverted means the output is over the
threshold. It turns off again 1 dB below, so it does not flicker at the edge.

The level is the louder of the two sides, averaged over about 300 ms. A
full-scale square wave reads 0 dBFS and a full-scale sine -3 dBFS.

**Limitations**

- It measures the main output after the compressor, before the MAIN volume knob,
  so the knob does not set it. The knob's position can still shift it by a few
  dB.
- The threshold is set when the firmware is built (`rms_db` in the mod), not on
  the device.
- A label stock already highlights reads normal while over.

## 0010 - Kit A/B

Compare your edits to a kit against the saved version, and go back to your
edits.

**Use.** NO + PLAY, as for a stock reload.

| you press NO + PLAY when | it does | popup |
|---|---|---|
| you have edited the kit | keeps your edits aside and reloads the saved kit | KIT 1 RELOADED! |
| the saved kit plays, untouched since | brings your edits back | EDITS RESTORED! |
| the saved kit plays, but you have edited it | keeps those newer edits instead and reloads | KIT 1 RELOADED! |
| the kit has no edits | a plain reload, as stock | KIT 1 RELOADED! |

The number in KIT 1 RELOADED! is the current kit's, as stock shows it.

Only one set of edits is kept: editing the saved kit while comparing replaces the
edits kept aside. Changing to another kit, or any other reload, does the same.
The kit menu's reload behaves the same way; reloading all kits is stock.

**Limitations**

- The edits kept aside take 2.5 KB of the device's memory from the first press
  until power off.
- After EDITS RESTORED! the kit may not count as modified. Save explicitly.

## 0012 - Slice loop

Set up a track to play a one-bar loop sample as 16 slices, one per step.

**Use.** Select an empty track, FUNC + CHRO, choose SLICE LOOP. On a track with
16 or more steps and no trigs it:

- sets the track's TRIG page defaults to SYN off, SMP on;
- places a trig on steps 1 to 16;
- locks trig n's sample STA to 6(n-1) and END to 6n: 0/6, 6/12 .. 90/96;
- shows LOOP SLICED and closes the menu.

Swing, accents and micro timing then move each slice as they would a drum hit.
Assign the sample before or after; the locks do not depend on it.

**The sample.** The bar must fill 96/120 of the sample, the rest padding, so
that 16 slices of 6 land on the sixteenth notes.

| popup | cause | changes |
|---|---|---|
| LOOP SLICED | done | as above |
| TRACK NOT EMPTY | the track has a trig, lock trigs included | nothing |
| NEEDS 16 STEPS | the track is shorter than 16 steps | nothing |
| ONLY ON SOUND TRACKS | the FX track is selected | nothing |

**Limitations**

- Fixed at 16 slices of 6. Steps past 16 are left empty.

## 0013 - DAC sum, filter and shaper

Adds a filter, a transient shaper and a polarity switch to every voice, after
its analog filter, on a second FILTER page.
The Rytm's voices are analog all the way to the mix, so there is nowhere to put
a filter; with DAC SUM on, the voices leave the analog main bus and reach it
again through the DAC, processed on the way.

**DAC SUM.** In the GLOBAL menu, AUDIO ROUTING, the last item. ON routes every
voice to the main mix through the DAC; OFF is stock. The setting is kept with
the project, like the routing around it, and survives a power cycle.

With it on:

- level and pan are as through the analog path (within about 0.1 dB);
- the voices reach the mix about 2.6 ms later than through the analog path;
- ROUTE TO MAIN and track mutes work as usual;
- the delay and reverb sends, the compressor preview (0006), the sampler and
  the USB track channels all get the processed voice. The individual outputs
  do not: they carry the voice before the filter, shaper and polarity.

Switching DAC SUM clicks once.

**DAC FILTER.** With DAC SUM on, press FILTER a second time for the DAC FILTER
page. With DAC SUM off, pressing FILTER again stays on the stock page.

The top row is the filter:

| knob | values | |
|---|---|---|
| FRQ | 0..127 | the cutoff, on stock FRQ's scale: 13.8 Hz to 21.1 kHz, 440 Hz at 60 |
| RES | 0..127 | resonance, for the 2-pole types |
| TYP | OFF, LP2, LP1, BP, HP1, HP2, BS, PK | the filter type, in stock's order and shown as stock's glyph |
| DEP | 0.0dB, -0.3dB .. -31.5dB, FULL | how much of the voice goes through the filter |

- LP1 and HP1 are one-pole, 6 dB/oct, -3 dB at FRQ, with no resonance.
- LP2 and HP2 are two-pole, 12 dB/oct. RES raises a peak at FRQ, up to about
  +6 dB.
- BP is a band-pass, 0 dB at FRQ; BS a notch at FRQ; PK a peak at FRQ. For
  these RES narrows the band rather than adding a peak.

At FULL the voice is the filter's output alone. Below FULL the dry voice is
mixed back in, cutting by the amount DEP shows: HP1 and HP2 become low shelves,
LP1 and LP2 high shelves, BP cuts everything but the band, and BS becomes a bell
cut. 0.0dB is no filter at all. For PK, DEP is instead a boost at FRQ, +0.0dB
to +6.0dB.

The graph over FRQ and RES is stock's FILTER graph for the type, cutoff and
resonance; with TYP OFF it is a flat line. The FRQ popup reads as stock's FRQ
popup, in Hz where 0008 is installed. TYP and RES step as stock's knobs do.

The bottom row is the transient shaper and polarity:

| knob | values | |
|---|---|---|
| ATK | -64..+63 | the start of each hit: up to make it stand out, down to soften it |
| SUS | -64..+63 | what follows the start: up to bring the tail forward, down to tighten it |
| POL | +, - | the voice's polarity in the mix: - inverts it |

ATK and SUS at 0 leave the voice untouched; their dials show a dotted centre
there. At the ends they change a strong transient's attack or sustain by about
12 dB, with the total boost held to +6 dB. Quiet signal, below -60 dBFS, is
left alone. FUNC + turn jumps to the next of -64, 0 and +63. The shaper follows
the voice's level, so how much it acts depends on how sharp the sound's attack
is; a pad with no transient changes little.

POL is for lining up layered sounds, such as a kick and a bass on separate
tracks: turn one to - and listen for the low end filling in or thinning out.
It only changes the voice in the DAC sum.

The settings belong to the sound. They are saved and loaded with the sound and
the kit, and survive a power cycle with or without a kit save, as other kit
edits do. A sound that has never had them set
reads TYP OFF, FRQ 127, RES 0, DEP FULL, ATK 0, SUS 0, POL +.

Hold TRK while turning any of these knobs to change it on every voice track,
as 0014 does for stock's parameters.

**Known limits**

- None of these settings can be p-locked, and they have no MIDI CC.
- Saving a sound or kit with stock firmware drops them (the sound reads TYP
  OFF, ATK and SUS 0, POL +).
- Sounds saved with an earlier version of this mod, which had only LP1 and HP1,
  load with a different type: LP1 reads as LP2 and HP1 as LP1. Set TYP again.
- Switching TYP between LP1 and HP1 clicks on sounds with a lot of low or high
  content; switching between other types can click too.
- A voice driven very hot can clip in the filter or the shaper.
- The mod takes about 2.4% of the audio processing time with DAC SUM on and
  every filter off, and about 0.4% more for each pair of voices on LP1 or HP1.
  The 2-pole types and the shaper cost time only for the voices using them;
  their cost has not been measured.

The design and the measurements are in `mods/0013-voice-dac/mod.toml`.

## 0014 - Control all

Hold TRK and turn a knob to change that parameter on all twelve sound tracks at
once.

**Use.** On a sound page (SYNTH, SAMPLE, FILTER, AMP, LFO) or the TRIG page,
hold TRK and turn a knob. Every track moves by the same amount, so differences
between them are kept: a track at 40 and one at 70 both go up by 10. Each track
stops at its own limits. The screen shows the selected track as usual.

On the SYNTH page the knob changes the same position on every track, whatever
machine each one has, within each machine's own range. A track whose machine
has no parameter in that position is left alone.

FILTER TYP is the exception: the selected track's type changes as usual and
every other track is set to the same type.

The turn changes the selected track only, as stock:

- with the FX track selected;
- while a trig key is held, so parameter locks stay on the selected track;
- for LFO DST, and for the parameters other mods add: the euclidean OP beyond
  SUB (0002), VEL's humanise amount (0003) and the LFO RND page (0004).

The DAC FILTER page (0013) works the same way: every voice track moves by the
same step, each within its own limits. TYP and POL are set the same on every
track: the type the selected track reaches, and the same polarity. FUNC + TRK + turn on ATK or SUS moves each track to its own next
stop of -64, 0 and +63.

The changes are ordinary edits: saved with the kit, undone by reloading it.

## 0015 - Amp envelope reset

On the analog machines a new trig does not restart the amp envelope: it carries
on from wherever the level is. With a long DEC the envelope never closes, so
AMP ATK is heard on the first hit and not after. This mod adds the amp to ENV
RESET, so the attack is heard on every hit.

**Use.** In the SOUND menu, SOUND SETTINGS, ENV RESET. The values are now OFF,
AMP, FILTER and AMP+FILT:

| value | amp envelope | filter envelope |
|---|---|---|
| OFF | continues | continues |
| AMP | restarts from silence | continues |
| FILTER | continues | restarts (stock) |
| AMP+FILT | restarts from silence | restarts (stock) |

The setting belongs to the sound: saved and loaded with it, as stock's FILTER
value is.

**Known limits**

- A trig on a voice that is still sounding drops it to silence at once, which
  can click, most with ATK 0 and a long DEC.
- On stock firmware AMP has no effect.

## Returning to stock

Flash Elektron's stock OS 1.73 `.syx` the same way (`docs/FLASHING.md`). The mods
store their settings in bits stock firmware ignores, so projects open on stock
with the mod settings dropped.
