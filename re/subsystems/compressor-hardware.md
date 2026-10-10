# Master compressor: hardware and firmware reference

What mod 0006 relies on about the Rytm MKII's master compressor, its input and
the compressor page, on stock OS 1.73 (MAIN OS at `0x40000400`). The estimator
built on it is [compressor-model.md](compressor-model.md); its calibration is
[compressor-calibration.md](compressor-calibration.md).

The compressor is analog, on the FX track, after the analog mix and the master
distortion (see [audio-engine.md](audio-engine.md)). Nothing in the MKII
firmware reads its gain back, so the preview is an estimate from the
compressor's input. The MK1 did read it, through the on-chip ADC input AN1;
on the MKII, AN1 does not carry it ("Gain-reduction readback").

## Parameters

Eight, on the FX channel. NRPN MSB 2, LSB 24..31 in the same order. The rest of
the Rytm's CCs are in [midi-cc.md](midi-cc.md).

| | CC | values |
|---|---|---|
| THR threshold | 78 | 0..127 |
| ATK attack | 79 | 0.03, 0.1, 0.3, 1, 3, 10, 30 ms |
| REL release | 80 | 0.1, 0.2, 0.4, 0.6, 1, 2 s, A1, A2 |
| MUP makeup | 81 | 0..127 |
| RAT ratio | 82 | 4 values |
| SEQ sidechain EQ | 83 | OFF, LPF, HPF, HIT |
| MIX dry/wet | 84 | 0..127 |
| VOL output volume | 85 | 0..127 |

A CC past the end of an enumeration makes the device show ERR rather than
clamp. The firmware's parameter table is not a source for these CC numbers: the
half-word at record `+0x28` holds 0x4f..0x55, which looks like a CC block and is
not one.

**RAT's labels run against its behaviour.** The device labels stored values
0..3 as 1:2, 1:4, 1:8 and MAX (label table `0x401ec45c`, confirmed on the
display), but value 0 compresses hardest. At THR 72, where the knee is compact
enough to read an asymptote, values 0..3 give 0.098, 0.165, 0.283 and 0.401 dB
out per dB in: about 10:1, 6:1, 3.5:1 and 2.5:1. Everything in this repo uses the
stored value, and the device's label where a name is needed.

The live parameter block is at `0x8000fbd4`, 8.8 words: THR +0, ATK +2, REL +4,
RAT +6, SEQ +8, MUP +10, MIX +12, VOL +14. DIST's amount is `0x8000fbce` and its
symmetry `0x8000fbd0` (64 at centre). The FX track's other effective parameters
follow the per-track layout in [lfo.md](lfo.md): `0x8000f7a8 + 84*track +
2*index`, FX being track 12.

## Behaviour

Measured through EXT IN, 2026-09-19 and 20, on a 1 kHz sine unless stated. EXT
IN joins after the distortion and before the compressor, so that path is the
compressor alone. The absolute levels are the rig's, not the estimator's.

### Static curve

- **Threshold slides the curve along the level axis**, about 0.9 dB per THR step
  at every ratio. On a level-against-GR plot this appears as a vertical shift
  of `(1 - 1/R)` dB per step, which is what makes the shift rate a second
  measure of the ratio.
- **The knee is very soft.** At THR 64 on the gentlest ratio, reduction runs 5 dB
  at -43 dBFS to 19 dB at -5 dBFS without reaching an asymptote. A low ratio
  compresses more at low levels and less at high ones: it is compression spread
  over a wider range, not less of it.
- **No reduction at THR 105 and above** on program material.

The estimator's curve and its fitted constants are in compressor-model.md,
stage 7.

### Detector

- **Predominantly peak-sensing.** At matched RMS, reduction rises 0.37 dB per dB
  of crest factor from a square to a 5% pulse. Divided by the local curve slope
  (0.53), that is a weighting of about 0.70, where 0 is RMS and 1 is peak.
- **One gain for both sides, driven by `max(|L|,|R|)`.** A panned voice's quiet
  and loud sides are reduced equally (27.96 and 28.02 dB at CC 10 = 32), and
  placing each pan on the centre curve by the level each candidate detector
  would see leaves `max` within 0.05 dB and the power sum up to 1.8 dB out. L+R
  is constant across pan while the reduction moves 3.8 dB. Whether the max is
  taken per sample or between per-side envelopes is not measurable with the
  same content on both sides.

### SEQ

Gain reduction at -6 dBFS against frequency, THR 60, RAT stored 3, referenced
to the same point uncompressed:

| SEQ | 50 | 100 | 200 | 500 | 1k | 2k | 5k | 10k |
|---|---|---|---|---|---|---|---|---|
| OFF | 20.86 | 19.60 | 18.95 | 18.71 | 18.67 | 18.65 | 18.61 | 18.51 |
| LPF | 25.41 | 23.58 | 20.90 | 17.05 | 14.01 | 11.08 | 9.43 | 8.73 |
| HPF | 12.78 | 14.40 | 16.66 | 18.89 | 19.60 | 19.82 | 19.85 | 19.76 |
| HIT | 15.05 | 15.25 | 16.82 | 18.95 | 19.90 | 20.90 | 23.23 | 25.31 |

OFF is not flat: 5.9 dB of lift at 50 Hz relative to 1 kHz, once the curve is
inverted. The estimator's sidechain sections are fitted to the device's own
swept response instead (compressor-calibration.md, sitting 2).

### Attack and release

- **Attack is one pole at close to the labelled time.** Fitted through the
  burst-window average the measurement performs: 0.40, 0.99, 3.20, 9.47 and
  26.6 ms for labels 0.3 to 30 ms. 0.03 and 0.1 ms both complete inside 0.5 ms
  and cannot be told apart by burst length.
- **A slow attack settles at less reduction, not only later.** A steady tone
  at ATK 30 ms settles at 0.51 to 0.73 of the reduction at ATK 0.03 ms,
  depending on ratio; it is a scale, not an offset, and the same at 1 and 8
  kHz. It depends on the attack against the release too, which is the
  coupling form in compressor-model.md, stage 8.
- **Fixed releases are one pole**, tau about 0.45 times the label (40 ms at
  0.1 s to 1033 ms at 2 s), measured in the carrier's band. A broadband
  envelope counts the step's low-frequency thump as signal and makes them look
  two-stage.
- **A1 and A2 are program-dependent.** Their release lengthens the longer the
  compressor has been working; A1 more than A2. Level steps give A1 a best
  single coefficient that varies 5x with step depth, where fixed releases vary
  1.5x; A2 behaves nearly like a fixed release.

### Output stages

- **Wet against dry.** At MUP 0, MIX 127 and THR 127 the wet path is 6.9 dB
  below the dry path (MIX 0).
- **MIX** is close to a linear amplitude crossfade between dry and wet.
- **MUP** adds about 0.6 dB a step to 48, then flattens to +40.3 dB at 127, the
  same at inputs 16 dB apart.
- **VOL** attenuates the wet path 1.95 dB for every dB of the dry path, so it
  moves the balance. At MIX 0 it scales all of MAIN, which is why every
  calibration pins VOL at 127. It does not move the static curve: reduction at
  a fixed input varies 0.15 dB across its whole range.

  | VOL | 40 | 52 | 64 | 76 | 88 | 100 | 112 | 124 | 127 |
  |---|---|---|---|---|---|---|---|---|---|
  | dry, dB re VOL 127 | -10.85 | -8.30 | -6.38 | -4.85 | -3.44 | -2.20 | -1.13 | -0.21 | 0 |
  | wet minus dry | -16.57 | -14.18 | -12.35 | -10.86 | -9.59 | -8.42 | -7.38 | -6.34 | -6.26 |

## The compressor's input

### The receive buffer

`0x80007440`, filled each audio interrupt by `0x4010e944`: 32 frames of 12
32-bit words, 48-byte stride.

| word | content |
|---|---|
| 0, 1 | MAIN L, R: post-compressor, written negated |
| 2..9 | the eight voice slots, mono |
| 10, 11 | AUDIO IN L, R |

The class-compliant twelve-channel USB stream is this buffer verbatim (the
packetizer at `0x4012144c`), so MAIN, the voices and the AUDIO IN words can be
recorded sample-aligned. Nothing downstream plays the AUDIO IN words when no
external input is connected: a -18 dBFS square written there reaches USB
channels 10 and 11 and leaves MAIN at its noise floor. The cal and telem builds
carry the model's signals there.

MAIN is post-compressor: over USB and at the analog outputs, a tone's level
moves with THR identically (within 0.05 dB). The USB OUT selector's MAIN OUT,
track pair and AUDIO IN options copy words 0-1, 2-9 and 10-11 of this buffer; the
sampler's MAIN source is the same pair. There is no other pre-compressor stereo
pair in it.

**The main volume knob does not set USB MAIN**, which is before it; the knob
sets the analog outputs. An interaction in the circuit still moves USB MAIN by up
to a few dB over the knob's travel, against the voices and the compressor's
detector - an artifact, not a control. Anything fitted against MAIN
holds only at one knob position (docs/HAZARDS.md).

### Voices: level, pan and routing

**The slots carry level, volume, velocity and accent.** Only pan and a per-voice
gain are applied after the tap. Track level over 11 dB leaves the gain from slot
to MAIN unchanged.

**The pan law keeps `gL + gR = S` constant.** Swept over CC 10, `gL + gR` holds to
0.01 dB from centre to hard while `gL^2 + gR^2` doubles. The split is within
0.018 of linear (at most 0.18 dB on the louder side). A hard-panned voice puts
all of `S` on one side, 6.02 dB above either side at centre.

**`S` is equal on six slots; slots 5 and 6 read 0.85 dB hot** against their
contribution to MAIN, so the model trims those two.

The firmware writes the analog VCA controls each interrupt in `0x401098d4`,
called from `0x40121246`, per physical voice `p`:

```text
uint16[0x800063ca + 2p] = 58000 * levsq * lvl * |pl|     ; left VCA
uint16[0x800063da + 2p] = 58000 * levsq * lvl * |pr|     ; right VCA
uint16[0x800063ea + 2p] = 2 * Overdrive
```

The stub takes each voice's split from these as `wL / (wL + wR)`. They lead the
audio by four interrupts: the send mixer reads its coefficients from a bank four
interrupts old (`0x41329c60 + 64*((counter - 4) & 7)`), matching the ADC round
trip of the voice slots.

**Voice order.** Three ROM tables:

| table | values | meaning |
|---|---|---|
| `0x4025a070` | `0,2,7,7,1,3,5,5,4,4,6,6` | logical track 1..12 to physical voice |
| `0x401ef1d0` | `0,3,1,4,6,5,7,2` (longs) | physical voice to receive slot |
| `0x401f85dc` | `7,6,5,4,0,1,2,3` | physical order packed into the route byte |

`0x40290dd8` holds each physical voice's current owning track.

**Route to main.** `0x80006466` is the main-disable mask packed from physical
voices 7,6,5,4,0,1,2,3, MSB first; a set bit takes that voice off the main bus
(from `0x8000ed6c`, or the global `0x8000ee58` when negative). The send mask
comes from `0x8000ed70`/`0x8000ee5c` the same way and zeroes the voice's sends
before the effects run.

The byte has three writers. The audio interrupt's main path packs it every
block at `0x401212b6`, through the owner table `0x40290dd8` (physical voice to
owning track), so the bit for voice p is bit `owner[p]` of the word above. The
other two belong to analog circuit calibration and both store `0xff`, every voice
off, after an eight-voice loop that resets per-voice state:

| store | routine | reached from |
|---|---|---|
| `0x40109032` | `0x4010879a` | `0x401096de`, from the view that prints "UNABLE TO START CALIBRATION" (`0x400d65ec`); and `0x4010929c`, in the state machine on `0x42fb4218` |
| `0x4010ac52` | `0x4010aa22` | `0x4010cdbc`, with interrupts masked (`movew #0x2700,%sr`), jumped to from `0x400d4fdc` in the Calibration view class |

Neither ever puts a voice back on the bus, and the main path overwrites the
byte on its next block, so outside calibration the byte always equals the
per-track bits packed through the owner table. Mod 0013's DAC SUM forces it to
`0xff` at the main path's store; mod 0006 reads the per-track bits instead of
the byte, which is identical without 0013 and keeps the voices with it.

**Gain ramps.** Firmware gains move as a 32-sample linear ramp that lags one
block: `step = (target - current) >> 5` per block. A p-locked pan change
therefore reaches the audio a little after the VCA words show it.

### FX returns

`0x4010e650`, called at `0x4012139a`, mixes the voices into two send buses and
runs the effects. Each buffer is 32 interleaved L/R long frames:

| buffer | content |
|---|---|
| `0x80007a44` | delay send |
| `0x80007c44` | delay output |
| `0x80007b44` | reverb send, then reverb output (processed in place) |

The returns are routed PRE (before the distortion and compressor) or POST by
`0x8000fbbc` (delay) and `0x8000fbcc` (reverb), 0 PRE and 1 POST. `0x4010e8a0`
builds the return gains, `(2 * return level * FX track level)^2` in Q31:

| | delay | reverb |
|---|---|---|
| PRE | `0x42fb4ab4` | `0x42fb4ab8` |
| POST | `0x42fb4abc` | `0x42fb4ac0` |

Only the bank selected is nonzero, so a POST return clears its PRE word. The PRE
consumer `0x4010eb26` sends `-(gain * return) >> 8` to the DAC. The return
levels are `0x8000fbb8` (delay) and `0x8000fbca` (reverb); the FX track level is
`0x8000f7a4`.

**The returns are ahead of the voices.** The FX buffer written this interrupt is
derived from voices already four interrupts old and must still go out through
the DAC. By the output ring's geometry (four 2048-byte slots at `0x80000000`)
the offset is about six blocks, 4 ms; the stub pairs the returns with the same
block's voices and carries that error (compressor-model.md, Known limits).

### The interrupt, and the hook

The audio interrupt `0x4011fafa` runs, on its main path:

| call site | callee | effect |
|---|---|---|
| `0x4012123a` | `0x4010d090` | analog voice controls |
| `0x40121246` | `0x401098d4` | VCA words and coefficient bank for block k |
| `0x40121338` | `0x4010ede2` | return consumers read the FX buffers (block k-1) |
| `0x40121358` | `0x4010e944` | receive buffer filled with block k |
| `0x40121394` | indirect | sampler meter writer |
| `0x4012139a` | `0x4010e650` | FX sends; delay and reverb write block k |
| `0x4012143a` | `0x4009ef40` | may overwrite the receive buffer with a test marker |

The estimator hooks at `0x401213a0`, between the effects and `0x4009ef40`:
the receive buffer holds block k's voices and the FX buffers block k's output.
MACSR is `0x20` there (fractional, saturation off) and must be left so; the
accumulators belong to the interrupted context.

**Budget.** Extra interrupt time starves everything below the interrupt:

- The UI event queue at `0x41943f54` (depth at +4) rests at 2 to 4. With the
  estimator at about 10% of a block on a busy pattern it grew into the
  thousands in minutes, and pattern changes waited seconds behind it.
- BgWorker (singleton `*0x419f2898`, job deque cursors at +44 and +60) takes
  the sample-load jobs a pattern change queues, about 55 per change, and runs
  only while the UI is idle.
- The display idle counter (screen manager `*0x419f28f8`, +0x748) steps 20 a
  second and dims at 6000.

The shipping estimator costs about 4% of a block and stands aside when either
queue backs up (compressor-model.md, Signal path).

## The compressor page

`CompressorPageView`: typeinfo `0x401e1194` (base `ParameterPageView`), vtable
`0x401e11a8`.

| slot | stock | used for |
|---|---|---|
| +0x08 key handler | `0x4003a544` | FUNC + arrows and FUNC + the page key on the preview page |
| +0x10 draw | `0x400c674c`, thunk to `0x40039782` | the preview pages' renderer |
| +0x60 set sub-page | | keeps the sub-page when the view is shown again |
| +0x68 selected page | `0x40037660`, returns `begin[index]` | |

**Pages.** The page vector is at object +0x7c (begin) / +0x80 (end), the
selected index at +0x8c, incremented modulo the count on a repeat press of the
page key. The constructor `0x400c676e`, called from `0x400cb1a4`, copies a
one-entry source at `0x401e1b04` holding page 11. Every consumer except the draw
slot reaches the page through +0x68, so listing page 11 more than once gives
pages with identical parameter lookup, title and encoders, told apart only by
the index in the draw slot; 0006 lists it twice. Page 11's descriptor is `0x402885c8`, encoder
parameter IDs 92, 95, 96, 93, 98, 97, 94, 99.

**Drawing.** The draw slot has the view at `4(%sp)` and the canvas at `8(%sp)`.
`bitmap_ctor` `0x4006f9c2(Bitmap*, w, h, pixels, mask)`; blit
`0x40071674(dest, src, x, y, centre)`. Pixels are column-major, one big-endian
word per column, MSB the top row; a larger y is higher on screen. `text_draw`
`0x400714e0` finds its own target and draws nothing from this slot, so the
readout uses bitmaps. The knob loop `0x40039782` with the knob draw's last
argument set draws labels only.

**Enumerated values** (ATK, REL, RAT, SEQ) have no text formatter; the stock page
draws them in the dial. Label tables: `0x401ec410` REL, `0x401ec430` ATK,
`0x401ec44c` SEQ, `0x401ec45c` RAT.

**Keys.** The event code is at +12 (LEFT, RIGHT, UP, DOWN = 0x40..0x43, the six
page keys 0x30..0x35) and the word at +16 its state: bit 0 down, bit 3 a long
hold. `0x40081bbc(0x80)` tests FUNC held. The view's own page key's id is at
+0x88. Stock's handler (`0x4003a544`) cycles the page on that key's release
(bit 4 set, not a long hold), and only if the press armed it: a press of any
page key sets `0x417e32b9` to whether it was the view's own (`0x4003ab08`), and
the release tests it (`0x4003a834`). Nothing on that path looks at FUNC; 0006
takes FUNC + the page key's press and clears the flag, so the release does
nothing.

## Gain-reduction readback

The MK1 (OS 1.73 for the MK1, same load base) drew a gain-reduction bar on its
compressor page from the ColdFire's on-chip ADC. Register names are the
MCF5441x ADC's (base `0xFC094000`: ADCR1 +0x00, ADLST1 +0x06, ADSTAT +0x0C,
ADRSLT0..7 +0x12..+0x20, results left-justified in bits 14..3), inferred from
the access pattern and not checked against this board.

**MK1.** The compressor page's draw slot (vtable `0x401aec78` +0x10,
`0x400c37c0`) runs the generic page draw `0x400394d2`, then fills a 3-pixel
column at x 120..122 from the bottom up to `(v << 5) >> 14` rows, with v from
`0x4011730a`, which returns `[0x416c4834]`. The writer `0x401172ce` (called from
`0x40119eec`) halves the held value and takes the larger of that and ADRSLT1
(`0xfc094014`): a peak hold with a fast decay. The MK1 never writes ADLST1, so
slot n converts input ANn and the meter reads AN1. It reads ADRSLT0 (AN0)
elsewhere, smoothed (`0x4009d14e`).

**MKII.** Boot (`0x40000946`) writes ADLST1 = `0x0021`, so slot 0 converts AN1
and slot 1 AN2. The compressor page draws no meter. Two routines read the slots:

- `0x4013f1c8`, from the audio interrupt at `0x40120e94`, once a block: each of
  slots 0 and 1 through a one-pole smoother (0.98 / 0.02) into `0x419f0310`,
  then mapped by a 40-byte config record per input (from `0x8000fd00`; mode at
  +0, a min/max pair at +4/+8 or +12/+16) into `0x419f0308`/`0x419f0300`,
  posting an event when a value moves. The strings beside its users are the
  pedal setup's: "EXPRESSION LEARN", "MOVE PEDAL UP AND DOWN.", "FOOTSW DEST".
- `0x40139c68(sel)`, a blocking average of 2048 conversions of slot 0 or 1,
  called only from the factory protocol's `#READ_ADC` (`0x4013a658`,
  `0x4013a678`; [os-upgrade.md](os-upgrade.md)).

So the MKII firmware treats AN1 and AN2 as pedal inputs. That points to AN1
being rewired away from the compressor, but does not prove it: the code may be
shared with another Elektron model and dormant on the Rytm.

**The test.** 0006's telemetry build (`telem = 1`) streams ADRSLT0..3 as words
28..31 of its frame; `tools/comp/telemetry/adc_probe.py` steps THR with the
compressor at its hardest ratio, fully wet, over a playing pattern, and prints
each slot's mean, spread and correlation with MAIN's block peak per step. A slot
that moves with THR and with the kick carries gain reduction.

**Result, 2026-09-27** (`build/comp/telemetry/adc_probe_20260927_225256.npz`):
over a playing pattern, RAT hardest, ATK 0.03 ms, MIX 127, THR 0 / 32 / 64 /
96 / 127 moved MAIN's block peak from -37 to -7 dB. Throughout, slot 0 (AN1)
read 2048 and slot 1 (AN2) 2044, each 12-bit, with a spread of 3 and no
correlation with MAIN's peak (|r| <= 0.02); slots 2 and 3 read 0. So AN1 and AN2
carry no gain reduction on the MKII: they sit at mid-scale, as an undriven,
biased input would. Slots 2 and up are disabled (ADSDIS = 4), so AN0 and
AN3..AN7 are not converted and remain untested.

