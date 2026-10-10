# Machines

How a track's machine becomes sound: the engine table, the machine functions,
what they write, how availability is decided, what each public machine's
parameters drive, and the 19 hidden machines. Stock MKII 1.73, read from the
image 2026-09-29, parameter mappings 2026-10-06; nothing here has been heard.
Tags: **[measured]** read from the image, **[inferred]** reasoned from it.

The machine functions decompile only with `re/ghidra/emac.sh`'s Ghidra
(`GHIDRA=build/ghidra-emac`); stock Ghidra stops at the first `movclr`.

## Dispatch [measured]

- The live sound's machine byte (`+0x68`) reaches `0x8000ea00[track]` through
  the sound push `0x4011f5d6`, which first refuses a machine not available on
  the track's voice (`machine_available`, below).
- In the audio interrupt (`0x401210ee`) each physical voice takes its owner
  track from `0x40290dd8`, reads that byte, skips the voice if it is above 52,
  and otherwise calls `0x4029037c[machine]` once per interrupt:

      fn(voice, 0x800063c0 /* control block */, params, pitch)

  - `params` is `0x8000f7ba + 84 * track`: sound index 9, so the eight SRC
    words, after p-locks and LFO.
  - `pitch` is `60 << 16`, or `0x80006388[track]` when bit 0 of the `+0x6a`
    settings byte is set **[inferred: keytracked note]**.
- The table holds 53 longs and data follows it, so it cannot grow in place.

## What a machine writes

- **Control block** `0x800063c0`, one block for all voices; each voice owns
  its own offsets. The whole frame is mapped in
  [analog-controls.md](analog-controls.md). Oscillator CV words, analog switch bits from
  `+0xa0`, and segment-command slots of the kind `envelopes.md` describes.
- **Digital streams**, 32 frames a block, per voice `v`:
  - `0x80006bf8 + 128v`: a machine's own waveform (UT IMPULSE, FUNC. GEN.)
  - `0x80007040 + 128v`: noise, filled by `noise_generate` (`0x4011bc4e`)
    from a four-word preset
  - `0x80007000 + 8v`: the noise gain, ramped across the block
  - `0x800067f8 + 128v`: a third source; not traced

  `voice_output_mix` (`0x4010ea30`) sums them into the voice's output-ring
  channel **[measured]**. That channel feeding the voice's analog filter is
  **[inferred]** from the manual's diagram (noise and samples digital, filter
  analog).
- **State**: 32 bytes at `0x8000fef8 + 32v`; word 0 is commonly the
  first-call / trig flag.
- **Shared helpers**: `0x4011e456(voice, ctrl)` resets a voice's circuit on a
  trig; `0x4011e844` / `0x4011e814` combine TUN and pitch into a log-frequency
  word (below); `0x4011e86e` clamps it and calls the exponential converter
  `0x4009897c`.

## Availability [measured]

`0x401bf17c + 2m`, two bytes per machine: a home track (signed, -1 none) and a
mask of the physical voices it may run on. `machine_available(m, voice)` is
`0x400070e6`; the track's physical voice comes from `0x401bf1e8[track]`:

| track | BD | SD | RS | CP | BT | LT | MT | HT | CH | OH | CY | CB |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| voice | 0 | 2 | 7 | 7 | 1 | 3 | 5 | 5 | 4 | 4 | 6 | 6 |

The mask is checked by the machine picker (`0x400beb62`, which lists
home-track machines, then other available ones, then those with no home), the
machine setter (`0x400bd18e`), the sound push, the sound pool
(`0x401201c6`, `0x40120596`) and the kit load. **On kit load a sound whose
machine is not available is set to 27, DISABLE** (`0x40008708`).

Machines 34..52 have mask 0, which is the whole of what hides them. Unhiding
one is a one-byte patch at `0x401bf17d + 2m`; a kit saved with it loads as
DISABLE on stock.

## Parameters [measured]

A ROM parameter record (`0x401bf918`, stride `0x34`) whose kind (`+0x00`) is
0..52 belongs to that machine; `+0x04` is its sound index (9..16). At boot
`param_tables_build` puts the record ids into `0x413db5fc[m * 8 + index - 9]`.
Other fields, from comparing pairs **[inferred]**: `+0x08` min, `+0x0c` max,
`+0x10` default (all `<< 8`), `+0x14` display (1 = bipolar), `+0x18` the MIDI
CC. `+0x20` is set on every public record and 0 on every hidden one
**[measured]**; that it is the Overbridge / NRPN id is **[inferred]**.

## The machines

Voices are the availability mask; SRC is sound index 9..16 by short name.

| # | name | function | voices | SRC 1..8 |
|---|---|---|---|---|
| 0 | BD HARD | `0x401112f4` | 0,2,7 | LEV TUN DEC HLD SWT SNP WAV TIC |
| 1 | BD CLASSIC | `0x4011055c` | 0,2,7 | LEV TUN DEC HLD SWT SWD WAV TRA |
| 2 | SD HARD | `0x401184c4` | 0,2,7 | LEV TUN DEC SWD TIC NOD NOL SWT |
| 3 | SD CLASSIC | `0x40117950` | 0,2,7 | LEV TUN DEC DET SNP NOD NOL BAL |
| 4 | RS HARD | `0x40116030` | 7 | LEV TUN DEC SWD TIC NOL SYM SWT |
| 5 | RS CLASSIC | `0x40115ba0` | 7 | LEV T1 DEC BAL T2 SYM NOL TIC |
| 6 | CP CLASSIC | `0x40112c78` | 7 | LEV TON NOD NUM RAT NOL RND CPD |
| 7 | BT CLASSIC | `0x4011b534` | 1 | LEV TUN DEC - NOL SNP SWD - |
| 8 | XT CLASSIC | `0x4011b7e4` | 3,5 | LEV TUN DEC SWD SWT NOD NOL TON |
| 9 | CH CLASSIC | `0x4011495c` | 4 | LEV TUN DEC COL - - - - |
| 10 | OH CLASSIC | `0x40115264` | 4 | LEV TUN DEC COL - - - - |
| 11 | CY CLASSIC | `0x401137e0` | 6 | LEV TUN DEC COL TON - - - |
| 12 | CB CLASSIC | `0x40113270` | 6 | LEV TUN DEC DET PW1 PW2 - - |
| 13 | BD FM | `0x40110bf4` | 0,2,7 | LEV TUN DEC FMA SWT FMS FMD FMT |
| 14 | SD FM | `0x40117f18` | 0,2,7 | LEV TUN DEC FMT FMD NOD NOL FMA |
| 15 | UT NOISE | `0x4011405c` | all | LEV LPF DEC HPF LPQ ATK SWT SWD |
| 16 | UT IMPULSE | `0x40113f5c` | all | LEV ATK DEC HLD SHP REP NUM POL |
| 17 | CH METALLIC | `0x40114774` | 4 | LEV TUN DEC - - - - - |
| 18 | OH METALLIC | `0x40115098` | 4 | LEV TUN DEC - - - - - |
| 19 | CY METALLIC | `0x40113544` | 6 | LEV TUN DEC TON TRD - - - |
| 20 | CB METALLIC | `0x40112f98` | 6 | LEV TUN DEC DET PW1 PW2 - - |
| 21 | BD PLASTIC | `0x40111eee` | 0,2,7 | LEV TUN DEC TYP MOD SWT SWD TIC |
| 22 | BD SILKY | `0x401119c0` | 0,2,7 | LEV TUN DEC HLD SWT SWD DUS CLK |
| 23 | SD NATURAL | `0x40118a48` | 0,2,7 | LEV TUN BDY DEC BAL LPF HPF RES |
| 24 | HH BASIC | `0x40114bc0` | 4 | LEV TUN DEC TON TRD RST NOL NOD |
| 25 | CY RIDE | `0x40113b12` | 6 | LEV TUN DEC TYP HIT C1 C2 C3 |
| 26 | BD SHARP | `0x401125ec` | 0,2,7 | LEV TUN DEC HLD SWT SWD WAV TIC |
| 27 | DISABLE | `0x40113efc` | all | - |
| 28 | SY DUAL VCO | `0x401198d4` | 0,2,7 | LEV TUN DEC DET DEC BAL BND CFG |
| 29 | SY CHIP | `0x40119f90` | 0,2,7 | LEV TUN DEC OF2 OF3 OF4 WAV SPD |
| 30 | BD ACOUSTIC | `0x4010fea0` | 0,2,7 | LEV TUN DEC HLD SWT SWD WAV IMP |
| 31 | SD ACOUSTIC | `0x401172e8` | 0,2,7 | LEV TUN BDY NOD NOL HLD SWD IMP |
| 32 | SY RAW | `0x4011a9e0` | 0,2,7 | LEV TUNE DEC2 DET NLEV WAV1 WAV2 BAL |
| 33 | HH LAB | `0x40114de4` | 4 | LEV OSC1 DEC OSC2 OSC3 OSC4 OSC5 OSC6 |
| 34 | BT IMPROVED | `0x4011b278` | hidden | LEV TUN DEC - NOL SNP - - |
| 35 | BD HARD 2 | `0x4010f990` | hidden | LEV TUN DEC HLD SWT SNP WAV TIC |
| 36 | BD CLASSIC 2 | `0x4010ee08` | hidden | LEV TUN DEC HLD SWT SWD WAV TRA |
| 37 | SD HARD 2 | `0x40116e58` | hidden | LEV TUN DEC SWD TIC NOD NOL SWT |
| 38 | SD CLASSIC 2 | `0x4011657c` | hidden | LEV TUN DEC DET SNP NOD NOL BAL |
| 39 | RS HARD 2 | `0x401157d8` | hidden | LEV TUN DEC SWD TIC NOL SYM SWT |
| 40 | RS CLASSIC 2 | `0x4011541c` | hidden | LEV T1 DEC BAL T2 SYM NOL TIC |
| 41 | BD FM 2 | `0x4010f34c` | hidden | LEV TUN DEC FMA SWT FMS FMD FMT |
| 42 | RS FM 2 | `0x401169f8` | hidden | LEV TUN DEC FMT FMD NOD NOL FMA |
| 43 | FUNC. GEN. | `0x4011425c` | hidden | NOL SLV SFQ PLV PLN - - - |
| 44 | BD TEST | `0x4011daf2` | hidden | TU1 TU2 LE1 LE2 WF1 WF2 FM RM |
| 45 | SD TEST | `0x4011d288` | hidden | TU1 TU2 LE1 LE2 - - WAV FRO |
| 46 | RS TEST | `0x4011d40c` | hidden | TU1 TU2 LE1 LE2 RS1 RS2 WAV FRO |
| 47 | BT TEST | `0x4011df00` | hidden | TUN DEC PL PW BIT - - - |
| 48 | LT TEST | `0x4011e898` | hidden | TUN DEC PL PW - - - - |
| 49 | MT TEST | `0x4011de10` | hidden | TUN DEC PL PW - - - - |
| 50 | HH TEST | `0x40114460` | hidden | TUN SEL LEV MIN MAX - - VCA |
| 51 | CY TEST | `0x4011d5b4` | hidden | TUN SEL 50 500 80 800 8000 VCA |
| 52 | CB TEST | `0x4011d8b0` | hidden | - SEL 5EN 8EN - - - VCA |

42's name string reads RS FM 2; its short name (S2FM) and parameters are SD
FM's. Names are at `0x401befa4`, long and short name pointers per machine.

## What the parameters drive

Offsets are into the control block; [analog-controls.md](analog-controls.md)
names the words. Parameter words are 8.8 (`value << 8`).

### Shared paths [measured]

- **Pitch.** `0x4011e844(TUN, pitch)` gives a log-frequency word,
  `0x1000000` an octave; one TUN unit is one semitone, so the public TUN's
  32..96 is ±32 semitones. `0x4011e86e` clamps it and exponentiates in
  software; the result times a per-machine constant, clamped to 0..`0x7fff`,
  is the oscillator word. So the circuit takes a CV linear in frequency.
- **Oscillator trims.** `0x40119788(voice, osc, wave, word, ...)` writes the
  oscillator's pair at `+844/+860/+876` (+0, +4 per oscillator) from a
  calibration table indexed by voice, oscillator, waveform code and one of
  ten frequency breakpoints (`0x42fb4d68`), or three bands
  (`0x40118f90`) when the table is not loaded.
- **Levels.** LEV is squared before it reaches any level or VCA word.
- **Crossfades.** `0x40109810(BAL)` returns a linear complementary pair;
  `0x40109848` a clamped pair (TON, BAL on the newer machines).
- **Clicks.** `0x4011e9d8(a, LEV)` is `(a·LEV)²`; machines write it, or a
  ROM transient scaled by it, into the voice's waveform buffer.
- **Noise.** `noise_generate` (`0x4011bc4e`, often inlined) filters noise
  through a resonant filter whose coefficients come from `0x401f8a64`,
  indexed by two preset bytes; the gain word at `0x80007004 + 8v` is set on
  the trig and ramped or multiplied down per block.
- **Envelope commands.** Machines write the voice's circuit slots with
  command 0xF (level reset, envelopes.md) and a level word whose bits 15:8
  and 7:0 are used as start and target, then later commands 0xB/0x9 that
  ramp on. That reading of the level word is **[inferred]**.
- **Timing.** State word 1 (`0x8000fefc + 32v`) is a countdown; each state
  adds its duration (fixed, a hold parameter, or the decay coefficient
  through `0x4011e802`) and waits for it to fall below 16.

### Voices 0, 2, 7: the two-oscillator circuit

Per voice: two frequency words, two level words, the switch table (entry 1
osc 1 waveform, 2/3/6 osc 2 waveform code, 4 FM, 5 ring mod by the TEST
names, 0 trig), and four envelope slots. Their roles **[inferred]** from use:
E0 osc 1 pitch, E1 osc 2 pitch, E2 osc 1 amplitude, E3 osc 2 amplitude. SD
HARD gives E0/E1 the same sweep and E2/E3 the decay; the BD machines zero
osc 1's level and program only E1/E3; the FM machines put DEC on E2 and FMD
on E3. Osc 2's waveform code is the `wave` argument of the trim call: codes
0, 1, 2, 3 and 5 are used. Voice 7 adds RS2 (`+116`), bipolar; RS1 is held at
`0x7fff`.

| machine | oscillators | levels | envelopes | digital |
|---|---|---|---|---|
| BD HARD | osc 1 ×`0x62000`, osc 2 ×`0x4168f` (1.498:1); WAV 0..2 → osc 2 code | LE1 0, LE2 LEV² | E1: start SNP, fixed rate, then SWT to 0. E3: jump to full, settle, hold HLD, decay DEC | TIC: 2-sample click (TIC·LEV)²; noise ∝ LEV², fixed preset |
| BD CLASSIC | as BD HARD | as BD HARD | E1: start SWD², rate SWT. E3: hold HLD, decay DEC | TRA 0..55 picks click gain, noise gain and noise preset (`0x401f07a4`) |
| BD FM | osc 1 TUN ×`0x4168f`, osc 2 FMT ×`0x82d1e`; FM on | LE1 LEV², LE2 FMA | E0 SWT; E1 FMS; E2 fixed `0x500` then DEC; E3 FMD | small fixed click, noise |
| BD PLASTIC | both TUN ×`0x4168f`; FM on; TYP 0/1 sets/clears ring mod (`0x401f0cbc`); osc 2 code 3 | LE1 LEV², LE2 MOD² | E0 = E1: SWD/SWT. E2 hold `0x200` then DEC; E3 held open | TIC: 8/16/8-sample shaped click |
| BD SILKY | osc 1 TUN; osc 2 word 0; switch entries 3 set, 2 clear | LE1 LEV², LE2 (CLK·LEV)² | E0: SWD/SWT. E2: hold HLD, decay DEC. E3: fixed fast, so CLK is an analog click | DUS: noise (DUS·LEV)², decay from DEC |
| BD SHARP | WAV 0..11 (`0x401f0edc`): osc 2 codes 0,1,2,3,5 or osc 1, each A/B; A pulses the trig bit at note start | LEV² to the chosen oscillator | E1: SWD/SWT. E2/E3: hold HLD, decay DEC | TIC: 88-sample ROM transient (`0x401f0f6c`) |
| BD ACOUSTIC | as BD SHARP, table `0x401f0510` | as BD SHARP | as BD SHARP | IMP: sampled impulse from `*0x4028b7b8`, up to 4800 samples |
| SD HARD | ×`0xff000`, ×`0xaa000`: 3:2 | LEV² at 1:3 | E0 = E1: start SWD, rate SWT. E3 DEC, E2 DEC × 0.93 | TIC click; NOL noise, linear decay over NOD |
| SD CLASSIC | both ×`0xee000`; osc 2 TUN + DET semitones | BAL crossfades LEV² | E0 = E1: start SNP, fixed rate. E2 and E3 from DEC, E3 shorter | fixed click; NOL noise, exponential decay `0x401f57fc[NOD]` |
| SD FM | osc 1 TUN, osc 2 FMT, both ×`0xee000`; FM on | LE1 LEV², LE2 FMA | E0 = E1 fixed blip; E2 DEC; E3 FMD | fixed click; NOL/NOD linear |
| SD ACOUSTIC | osc 2 TUN + 7 semitones ×`0x82d1e` | LEV², osc 2 at 1/6 | E0 = E1: start SWD, fixed rate. E2/E3: hold HLD, decay BDY | NOL/NOD noise; IMP impulse |
| SD NATURAL | osc 2 only, ×`0x82d1e` | BAL splits LEV between LE2 and the noise | E3: hold `0x20`, decay BDY | noise preset from LPF, HPF, RES; DEC its decay; fixed 32-sample click |
| RS HARD | ×`0x683000`, ×`0x1c7000`: 3.66:1 | LEV², low one 3× | E0 = E1: SWD/SWT. E2/E3 DEC | SYM → RS2; TIC; NOL noise, fixed decay |
| RS CLASSIC | T2 → osc 1 ×`0x683000`, T1 → osc 2 ×`0x1c7000` | BAL crossfade | E2 = E3 DEC; no pitch envelope | SYM → RS2; TIC; NOL |
| SY DUAL VCO | osc 1 TUN + BND (decays ×0.99 a block), osc 2 + DET, ×`0x82cf5` | BAL crossfade, or BAL² as FM depth | E2 DEC1, E3 DEC2; 127 holds | CFG 0..79: bit 0 trig pulse, then osc 1 wave × osc 2 code (`0x401f5f88`) × RM/FM |
| SY RAW | osc 1 TUN + DET, osc 2 TUN; WAV1 0..3, WAV2 0..6 (`0x401f7ca0/cb0`) | BAL crossfade | DEC2 → E2 and E3 | NLEV: noise, fixed preset |
| SY CHIP | arpeggio over 0, OF2, OF3, OF4 at SPD (`0x401f7798`; below 24 from the tempo); WAV 0..29 picks a step program (`0x401f6208`) | per step from tables | DEC → E2/E3 | steps may instead be a software pulse (PWM sweep) or a 23-bit LFSR noise clocked from the pitch |

The 808's rimshot oscillators sit at about the RS ratio **[inferred]**.

### Voices 1, 3, 5: the resonator

No oscillators and no envelope slots. Two words, pitch and damping, and an
excitation pulse written as a digital stream into output-ring channel 8, 9 or
10. The pitch word is the **square** of the exponentiated frequency after a
per-voice offset and gain (`0x42fb6b50/54`, `0x42fb6b58..`), so the circuit's
frequency goes as the square root of its word. The damping word combines the
log pitch, a per-voice calibration pair (`0x42fb6b70/74`, `0x42fb6b78..`) and
`-k / (DEC + 0x100)`: damping compensated for pitch **[inferred]**.

| machine | TUN | other parameters |
|---|---|---|
| BT CLASSIC | `(TUN - 64)/2`, clamped to about ±16 semitones | SWD: pitch offset decaying ×0.961 a block. SNP: window ∝ SNP / pitch with switch `+165` bit 3 clear, damping computed an octave up inside it. LEV² → pulse, halved each block. NOL² × LEV → noise, decay ×0.854 a block |
| XT CLASSIC | full, clamped to about ±2.7 octaves | SWD: offset decaying by `0x401f7eec[SWT]` a block. LEV → pulse. NOL² × LEV → noise, decay `0x401f80ec[NOD]`; noise preset from TUN + TON. After 4500 and 9000 blocks damping and then pitch drift by one a block |

### Voice 4: the hat bank

`0x4011e9ea(words, mode, TUN, pitch, ratios, flags, reset)` writes the six
words at `+616`: each the exponentiated pitch times a ratio, 22 bits, ORed
with the mode at bits 22..23, flags from bit 24, and bit 31 when `reset` is
set. Four output paths A..D each have an envelope slot (`+456`, `+464`,
`+472`, `+480`); a fifth (`+488`) is used by every hat machine. Unused paths
are closed with `0x40007f80` / `0xb0188000`. `+130` takes COL or TON;
`+140` is LEV².

| machine | path | bank | parameters |
|---|---|---|---|
| CH CLASSIC | C | mode 1, `0x401f4594` | COL → `+130`; C: fixed drop (`0x73806`), then DEC; E held, then DEC |
| OH CLASSIC | D | as CH | COL → `+130`; D and E: DEC (`0x401f4dfc`) |
| CH METALLIC | A | mode 2, `0x401f437c` | DEC (`0x401f4394`) |
| OH METALLIC | A | mode 2, `0x401f4bcc` | E held open, A fixed, then both DEC |
| HH BASIC | B | mode 1, `0x401f47b4` | TON → `+130`; TRD → B's first decay; DEC → B and E; RST → reset bit; NOL/NOD noise; fixed click |
| HH LAB | B | mode 1, ratios from OSC1..6 via `0x4015cfd4`, pitch an octave down | DEC |

Ratios `0x401f4594` (CH/OH/CY CLASSIC, RIDE type 0): 1, 1.4815, 0.9667,
0.563, 0.6852, 0.3796. These are the TR-808's 540, 800, 523, 304, 370 and 205
Hz **[measured as ratios]**. HH BASIC's: 1, 1.699, 1.252, 1.789, 0.980, 2.549.
The metallic table (`0x401f437c`, `0x401f20cc`) holds values past 22 bits after
scaling and is not decoded.

The 22-bit frequency field, the reset bit and the cowbell's pulse width in the
top byte point to digitally generated square or pulse oscillators feeding the
analog paths **[inferred]**.

### Voice 6: cymbal and cowbell

The same bank at `+640` and `+142` as its colour word, `+158` its VCA (LEV²),
eight slots from `+496`. `+552` is held at full and then decays with DEC in
every machine.

| machine | slots | parameters |
|---|---|---|
| CY CLASSIC | `+512`, `+520`, `+528` | 808 bank. TON (`0x40109848`) sets the start levels, crossfading `+512` and `+528` with a little of `+520`. `+512`/`+520` decay at fixed rates; DEC sets `+528` and `+552`. COL → `+142` |
| CY METALLIC | `+496`, `+504` | mode 2 bank. TON balances the two; TRD → `+496`'s rate, DEC → `+504`. Click (LEV·`0xd00`)² decaying ×0.625 a block |
| CY RIDE | `+512`, `+520`, `+528` | TYP 0..3 → bank (`0x401f24fc`): 808 in mode 1, HH BASIC in mode 1, metallic in mode 1, metallic in mode 2. C1..C3 → start levels; HIT → `+512`'s rate; DEC → the others. Shaped click; reset bit on the trig |
| CB CLASSIC | `+544` | two words at `+640/+644`: TUN and TUN + DET/4, ×`0x594d24`, mode 3, PW1/PW2 in bits 24..30. `+544` fixed first stage (`0x14` to `0x88`), then DEC |
| CB METALLIC | `+536` | as CB CLASSIC with TUN halved and DET whole |

### Digital-only machines

These leave the circuit silent and use only the voice's filter and VCA.

- **CP CLASSIC**: zeroes the oscillator levels. `0x4011bd70` makes noise
  filtered by TON into voice 7's waveform and noise buffers; NUM bursts at RAT
  spacing with RND jitter (a Fibonacci generator at `0x4028dd3c`), each
  decaying by CPD; then a tail from NOL with decay `0x401f12a4[NOD]`.
- **UT NOISE**: trig reset of the circuit; noise preset HPF, HPF, LPF + SWD ×
  an SWT decay, LPQ; ATK (`0x401f417c`) and DEC (`0x401f2b7c`, 127 holds)
  shape the gain.
- **UT IMPULSE**: trig reset; a linear rise of LEV² over ATK steps, then
  decay ×`0x401f377c[DEC]` a sample; POL inverts it. HLD, SHP, REP and NUM are
  not read by `0x40113f5c`.

## The hidden machines

### BT IMPROVED (34)

BT CLASSIC reworked, hardcoded to voice 1 like it. Shared with BT CLASSIC
**[measured]**: TUN to pitch (`TUN / 2 + 0x2000` into `0x4011e814`), the
calibrated pitch word `+118` (`0x42fb6b50/54`) and decay word `+120`
(`0x42fb6b70/74`), the snap window (length ∝ SNP / pitch; `+165` bit 3
cleared and pitch raised a step inside it), the LEV² pulse level into
output-ring channel 8, and the noise preset. Different **[measured]**:

- no SWD and no pitch sweep (BT CLASSIC's starts at SWD at the trig and decays
  × 0.961 a block through `0x8000ff28`)
- noise gain `(NOL × LEV)²`, not `NOL² × LEV`
- a block counter from the trig (`0x8000ff2c`, capped at 74535): beyond 4500
  it adds 1 a block to the decay word, beyond 9000 to the pitch word too
- LEV 0 puts it in a kill state: decay word 32767, pitch word `0xffff`, noise
  off
- the decay word is clamped to ±32767
- never clears voice 1's `0x80006bf8` buffer, which BT CLASSIC does each block

At 32 frames a block, 4500 and 9000 blocks are 3 s and 6 s after the trig.
The kill state puts the decay word at the top of its range to silence the
voice, so the counter terms most likely damp a long note towards silence
**[inferred]**; their direction has not been heard.

### The "2" variants (35..42)

Duplicates of BD HARD, BD CLASSIC, SD HARD, SD CLASSIC, RS HARD, RS CLASSIC,
BD FM and SD FM **[measured]**:

- the same control-block offsets and switch-bit tables; their curve tables
  and noise presets are byte-identical copies of the public ones'
- TUN is 0..127, shown unipolar, through `0x4011e814` at 1/3 slope. The public
  TUN is 32..96, shown bipolar, through `0x4011e844` at 2/3 slope. Both put 64
  at the same point and span the same range, so the "2" TUN has twice the
  resolution.
- pitch is recomputed every interrupt; the public machines cache it, keyed on
  TUN and pitch, in `0x42fb6a78..` and `0x40290350`
- the RS pair hardcodes voice 7's buffers

**[inferred]** An earlier parameterisation kept in the image. Unhidden they
should sound as their public counterparts with a finer TUN.

### FUNC. GEN. (43)

A digital test signal generator that never touches the control block and
never looks at trigs **[measured]**:

- a free-running sine: SLV the level (ramped into `0x419ca028`), SFQ the phase
  increment, through the sine at `0x4011e0d4`, added into `0x80006bf8`
- noise at NOL through `noise_generate` with preset `0x4028dd44`
- a single rectangular pulse, PLV level (bipolar), PLN * 128 frames, written
  across as many blocks as it needs the first time
  it runs (state word 0 goes to -1 and nothing here clears it)

The smallest complete example of a digital machine; the natural template, and
slot, for a new one.

### TEST machines (44..52)

Each writes its parameters, unscaled or re-centred, into one voice's control
words, and so names that voice's circuit controls **[measured]**. None calls
the trig reset. BD, SD, RS, HH, CY and CB TEST write open levels into the
voice's segment-command slots, so they most likely drone **[inferred]**.

| machine | voice | writes |
|---|---|---|
| BD TEST | 0 | TU1, TU2 → `+90`, `+92` (bipolar); LE1, LE2 → `+94`, `+96`; WF1, WF2, FM, RM → switch bits from `0x401f5f6c`; `+161` bit 4 set on the first call; slots `+360..+391` open; `+844..+850` fixed |
| SD TEST | 2 | TU1, TU2 → `+98`, `+100`; LE1, LE2 → `+102`, `+104`; WAV, FRO Gray-coded into `+164` bits 0..4 and `+167` bit 0; slots `+392..+423` open |
| RS TEST | 7 | TU1, TU2 → `+106`, `+108`; LE1, LE2 → `+110`, `+112`; RS1, RS2 → `+114`, `+116`; WAV, FRO into `+160` bits 4..7, `+163` bit 0, `+167` bit 4; slots `+424..+455` open |
| BT TEST | 1 | TUN → `+118`; DEC → `+120` (bipolar); BIT → `+165` bit 3; PL ramped into output-ring channel 8 |
| LT TEST | 3 | TUN, through `0x4011e814` and the converter, squared → `+122`; `+124` from a counter at `0x40290378` that steps down 64 on each first call; DEC unread; PL → ring channel 9 |
| MT TEST | 5 | TUN → `+126`; DEC → `+128` (bipolar); PL → ring channel 10 |
| HH TEST | 4 | TUN → `+130`; VCA squared → `+140`; SEL 0..3 picks one of four outputs - LEV to `+132/134/136/138`, its slot `+456/464/472/480` opened, the other three closed by `0x40114394` - and one of three sets of six 22-bit words at `+616..+636` (SEL 2 and 3 share one); MIN, MAX → that output's pair at `+928/932/936/940` as half-span and centre |
| CY TEST | 6 | TUN → `+142`; 5ENV1, 5ENV2, 8ENV1, 8ENV2, 8ENV3 → `+144..+152` (bipolar); `+154`, `+156` off (`0x8000`); VCA → `+158`; SEL 0..2 loads six 22-bit words at `+640..+660`; slots `+496..+556` open |
| CB TEST | 6 | SEL loads two 22-bit words at `+640`, `+644`; 5EN, 8EN → `+154`, `+156`; `+144..+152` off; VCA → `+158`; slots as CY TEST |

- Voices 0, 2 and 7 are one two-oscillator topology - tune, level and
  waveform per oscillator, FM and ring-mod switches - at different offsets.
  That is why every BD and SD machine may run on all three.
- The per-voice switch tables, seven entries each as (byte, bit) from `+0xa0`:
  `0x401f5f6c` voice 0, `0x401f5f50` voice 2, `0x401f5f34` voice 7. BD HARD
  sets and clears the same entries BD TEST does.
- The six-word sets HH TEST loads are the same constants CY TEST loads, so the
  hat and cymbal voices share an oscillator-bank design **[inferred]**; the
  word's encoding is not decoded.
- PW is read by none of BT, LT and MT TEST.
- What output-ring channels 8..10 carry is not established.

## Open

- None of the above has been heard. A probe build that unhides FUNC. GEN. and
  BD TEST would test the DAC-path and circuit-control readings.
- The TEST machines' CV scaling and the switch bits' meanings rest on their
  parameter names. Entry 5 ("ring mod") is set by BD HARD and BD CLASSIC,
  whose osc 1 level is 0, so its name is doubtful.
- The circuit level word's layout, the hat bank's modes 1 and 2, and the
  metallic table's encoding.
- LT TEST's `+124` counter, and the HH/CY initialiser at `0x401143e2`.
- The `0x800067f8` source, and BT IMPROVED's reason for its drift terms.
