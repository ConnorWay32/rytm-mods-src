# Compressor model: mod 0006's estimator and its calibrated constants

The gain-reduction estimate on mod 0006's preview pages, as it stands on
2026-09-25: what each stage computes, every constant that was calibrated, where
its value came from and how well it holds. `mods/0006-comp-preview/stub.s` is the
implementation; `tools/comp/stub_model.py` is its offline twin, reading every
constant from the stub, bit-exact to the device on the cal build. Every
calibrated value lives in one file, `mods/0006-comp-preview/calibration.toml`, in
physical units with where it came from; `tools/comp/calib_tables.py` generates
`calib.inc` from it, the constants and one macro per table, which `stub.s`
includes. The procedure that produces the values is in
[compressor-calibration.md](compressor-calibration.md); the hardware and
firmware facts the model rests on are in
[compressor-hardware.md](compressor-hardware.md).

The estimate is not a measurement. Nothing reads the analog compressor's gain
back; the stub rebuilds the compressor's input from the voice slots and models
the gain computer.

## Signal path

Mode 0 (the shipping build), once per audio interrupt: a block of 32 samples at
48 kHz. The per-sample stages run on every second frame (`DECIM = 2`, 24 kHz);
the per-block stages run once.

| Stage | Rate | Computes |
|---|---|---|
| 1 Input model | sample | each side of the compressor's input, from the voice slots and the PRE returns |
| 2 Master distortion | sample | DIST's gain, then the analog saturation, per side, biased by SYM |
| 3 SEQ sidechain | sample | two first-order sections per side, then \|.\| |
| 4 Detector | sample | the louder side, into a peak follower |
| 5 Level | block | the peak in Q8 dB, calibrated |
| 6 Silence gate | block | no demand below -70 dB |
| 7 Static curve | block | the gain reduction the level demands |
| 8 Slow-attack scale | block | the demand, scaled by ATK, REL and RAT |
| 9 Ballistics | block | attack towards the demand, release towards zero |

The first preview page draws the result (the GR line), the stage 5 level (the
fill) and the stage 7 threshold (a dotted row); the second draws the GR line
alone, 0 dB at the top. The estimator stands aside for any
block that finds the UI event queue deeper than `QUEUE_MAX` (8) or BgWorker
waiting longer than `BG_WAIT` (375 blocks), or, outside the cal build, BgWorker
waiting longer than `BG_NUDGE` (30 blocks) with the queue at `QUEUE_BUSY` (6) or
more; it idles when the page has not drawn for about a second.

Compressor parameters are read live from the block at `0x8000fbd4` (8.8): THR +0,
ATK +2, REL +4, RAT +6, SEQ +8. DIST is `0x8000fbce`. RAT is the stored value
0..3, hardest first; the device labels those 1:2, 1:4, 1:8, MAX, the reverse of
their behaviour.

### 1 Input model

For each voice slot s, the physical voice's VCA words give the pan split
f = wL / (wL + wR), and

    cL[s] = f * trim[s],   cR[s] = trim[s] - cL[s]         (Q28: 1/8 of Q31)

both zero when the voice is routed off the main bus. Each side is the sum of the
eight slots through their coefficients, plus the PRE delay and reverb returns of
the same block, each times its live PRE gain word ((2 * volume * FX level)^2) and
a measured constant. The compressor applies one gain to both sides, driven by the
louder (compressor-hardware.md), so the sides are kept apart to stage 4.

### 2 Master distortion

    g = interp(disttab, DIST)             applied as g/8
    y = c * f(|x| / c) * sign(x),   f(u) = u / (1 + u^12)^(1/12)

c differs by sign. Below c/2 the sample passes unchanged, within 0.0002 dB of the
curve; above, u is formed by a multiply with 2^38 / c and f comes from a 33-point
table.

DIST symmetry (SYM) away from 64 is a bias before the saturation and a gain
after it:

    y = gain(SYM) * (sat(x + bias(SYM)) - sat(bias(SYM)))

bias and gain interpolated from 17-point tables (SYM 0, 8 .. 128). The gain is
applied once a block, as a level offset at stage 5. At SYM 64 the bias is zero
and the sample path takes the plain saturation (`satur`); otherwise
`satur_sym`, selected through `a5` once a block.

### 3 SEQ sidechain

    y = k*x - k*r*x[-1] + P*y[-1]         two sections, cascaded, per side

from the SEQ's `sctab` row. Each section's peak gain is 1. The row's last word
is the SEQ's level offset, added at stage 5: the cascade's loss at 1 kHz less
OFF's, plus `level_db + transient_db`. All four SEQs, LPF included, are fitted to
the hardware's measured response (a self-oscillating filter swept 35 Hz to
14 kHz); `transient_db` is what drums need beyond that sine, HIT only.

### 4 Detector

max(|L|, |R|) after the sidechain, into a peak follower: a new peak is taken at
once, a lower one is approached with `DET_ALPHA_H`, a 5 ms pole at 24 kHz.

### 5 Level

    L = to_db(peak) + CAL_Q8 + sctab offset[SEQ]            Q8 dB

At SEQ OFF, L is the louder side's peak in dBFS of MAIN, plus 3.01 dB. `CAL_Q8`
is arithmetic: +18.06 dB undoes the sum's 1/8 headroom, +3.01 is the voice gain
K = sqrt(2), +18.06 undoes DIST's g/8, and +3.01 is the L+R convention the curve
was first fitted in (6.02) less the peak-against-RMS of a sine (3.01).
`CURVE_REF`, the curve's own reference, is zero: the knees carry it.

### 6 Silence gate

L at or below `SILENCE_Q8` gives no demand. It is needed: at low THR the curve's
knee sits below the converter floor, and the idle noise of eight slots (about
-79 dBFS) would read as reduction.

### 7 Static curve

    T  = knee[RAT] + THR_K * (THR - 64)                     the threshold
    GR = min(slope[RAT] * w[RAT] * softplus((L - T) / w[RAT]), GR_CAP)

THR slides one curve per ratio along the level axis, 0.955 dB a step at every
ratio; SEQ is only a level offset. On the 2026-09-23 grids every point of a ratio
falls on one curve against L - k*THR to about 0.3 dB. The curve this replaced kept
a fixed knee and subtracted a threshold term from GR, which agreed only above the
knee. T is the threshold the page dots on its threshold row.

### 8 Slow-attack scale

    demand = GR * (atkscale[(ATK*8 + REL)*4 + RAT] + 1) / 256
    atkscale = 256 * s - 1,   s = (1 + C (0.03 ms / rel)^p) / (1 + C (atk / rel)^p)

A slow attack settles at less reduction as well as later, by ratio and by how the
attack compares with the release: C and p per stored ratio, atk the ATK label's
time, rel the REL setting's effective release time.

    demand = max(0, demand - seqatk[SEQ*7 + ATK] / 16 dB)
    seqatk = 16 * c[SEQ] * ATK / 6

The coupling is fitted at SEQ LPF. The HPF and HIT sidechains are more transient,
and a slow attack loses more of them, whatever the release: on the 2026-09-26
verify draws the estimate read 0.53 dB deeper a step of ATK at HPF and HIT, and
no other setting mattered. c is the dB at ATK 6, per SEQ, LPF 0. The loss is a
fixed dB, not a fraction of the demand: a fraction fitted on the ATK x SEQ suite,
at 4 to 17 dB of reduction, took 2 to 3 times too much from the verify draws at
20 to 35 dB, where dB fitted on the same suite carried over. The routine is in
`.sc`, called from the estimator, whose pool is full.

### 9 Ballistics

    rising:   state += (demand - state) * atktab[ATK] / 65536
    falling:  state  = max(demand, state - ceil(state * reltab[REL] / 65536))

Attack is a pole towards the demand. Release decays towards zero reduction,
clamped at the demand - not a pole towards it. The step is rounded up so the
state reaches zero; rounded down, it stalled where state * reltab < 65536, up to
7.5 dB at REL 2 s.

## Calibrated constants

Every value below is set in `calibration.toml`; `calib_tables.py` turns it into
the stub's integers. Kind says what the file holds: **derived** - a measured or
chosen source value (a dB, a time, a coefficient) the table is computed from;
**fitted** - a fitting tool's result, stored as it came out; **fixed** -
arithmetic or a choice, in `stub.s` itself. `fit_shift.py` reports the fitted
curve against the grids it is fitted on.

| Constant | Stage | Kind | Source | Tool |
|---|---|---|---|---|
| `trimtab` | 1 | derived | per-slot S against MAIN (compressor-hardware.md), `calinput_20260925_142121` | `calibrate.py input --fit` |
| `CAL_DELAY` | 1 | derived | on-device null against MAIN, delay alone, `calinput_20260925_142121` | `calibrate.py input --fit` |
| `CAL_REVERB` | 1 | derived | on-device null against MAIN, reverb alone, `calinput_20260925_142121` | `calibrate.py input --fit` |
| `disttab` | 2 | derived | voice-path probe, 2026-09-21 | `calibrate.py dist` |
| `SAT_CP`, `SAT_CN` | 2 | derived | pre-saturation tap, 2026-09-22 | `calibrate.py dist` |
| `SAT_RP`, `SAT_RN` | 2 | derived | arithmetic on `SAT_CP/CN` | generated |
| `sattab` | 2 | derived | the curve's form, order 12 | generated |
| `symbias`, `symgain` | 2, 5 | fitted | detector level at DIST 64 and 96, `calsym_20260925_143626` | `calibrate.py dist --sym` |
| `sctab` sections | 3 | fitted | filter sweep, `calsc_20260924_205340` | `calibrate.py sidechain --fit` |
| `sctab` offsets | 5 | fitted | unity at 1 kHz less OFF's, plus `level_db` (sweep) and `transient_db` (HIT +1.36 dB, drums) | `calibrate.py sidechain --fit`; `fit_shift.py` reports |
| `DET_ALPHA_H` | 4 | derived | 5 ms decay, a choice | generated |
| `VOICE_CAL`, `DIST_HEADROOM` | 5 | fixed | arithmetic, see stage 5 | - |
| `CURVE_REF` | 5 | fixed | carried by the knees since 2026-09-24 | - |
| `SILENCE_Q8` | 6 | fixed | 9 dB over the idle floor, 24 dB under the lowest fitted level | - |
| `rattab` knee | 7 | fitted | 2026-09-23 grids, after the sweep's sections | `fit_shift.py` |
| `rattab` slope | 7 | fitted | 2026-09-23 grids | `fit_shift.py` |
| `rattab` width | 7 | fitted | 2026-09-23 grids; floor 0.254 dB | `fit_shift.py` |
| `THR_K` | 7 | fitted | 2026-09-23 grids | `fit_shift.py` |
| `GR_CAP` | 7 | fitted | 2026-09-23 grids | `fit_shift.py` |
| `atkscale` | 8 | derived | the coupling form from `coupling` and `rel_eff_s` | generated |
| `coupling` | 8 | fitted | RAT 2: extended suite, 2026-09-24, held out; RAT 0, 1, 3: 2026-09-22 | `fit_ballistics.py --holdout` |
| `seqatk` | 8 | derived | | generated |
| `seq_atk_db` | 8 | fitted | ATK x SEQ suite, A01-A08, 2026-09-26, held out | `fit_ballistics.py --seq-suite --holdout` |
| `rel_eff_s` | 8 | fitted | each on its own sweep at RAT 1:4, 2026-09-22 | by hand |
| `atktab` | 9 | derived | the device's labels | generated |
| `reltab` | 9 | fitted | REL 0.1 s: release probe, 2026-09-20; the rest: extended suite, each REL's bias matched to the THR 80 baseline's, step rounded up, 2026-09-25 | REL 0.1 s: a level-step probe; the rest: `fit_ballistics.py`'s report, entered by hand; `calibrate.py release --fit` from scratch |

`log2tab` and `softtab` are the math of `to_db` and softplus, not calibration,
and stay in `stub.s`.

### Coupled constants

- The knees, `THR_K`, `CAL_Q8` and the `sctab` offsets set one level scale
  between them: a common shift in the level and the knees is invisible. The knees
  are the reference; `CURVE_REF` is held at zero and OFF's offset at zero.
- `slope`, `width` and the knee of a ratio are fitted together.
- The sidechain sections set the level scale's normalisation: new sections move
  every level, and the knees are refitted after them (-4.91 dB on 2026-09-24,
  4.87 predicted by the sweep).
- `atkscale` scales stage 7's output, so a change of static curve can move its
  biases; refit it after the curve.
- `sctab`'s offsets change when the sections, `level_db` or `transient_db`
  change; `calib_tables.py` computes the combined row.

## Accuracy

Gain reduction, estimate minus measurement, rms dB (+ mean: estimate deeper).

| Test | Result |
|---|---|
| Verification, 60 random draws on patterns not fitted (A09, A10), SYM 64, cal build c282c273, 2026-09-26 | 1.57 (+0.03); every setting's mean within 0.44; blocks within 1 dB 56%, within 2 dB 84% |
| The same draws without `seqatk` | 2.04 (+0.73); HPF and HIT at ATK 1 ms and over 2.42 (+1.56), with it 1.69 (-0.18) |
| Steady tone, 2026-09-23 grids, 1296 points | 0.56 (+0.01) |
| Steady tone, 2026-09-20 grid, own level offset | 0.74 |
| Drum patterns, twin, 1 ms windows, 956 captures | OFF 1.33, LPF 1.63, HPF 1.45, HIT 1.57 |
| Drum patterns, cal build, 2 patterns x 32 conditions | OFF 1.25, LPF 1.23, HPF 1.33, HIT 1.44; each bias within 0.2 |
| Device against twin, cal build | bit-exact |
| Sidechain sweep repeated on the fitted image | OFF, LPF, HPF within about 0.5 dB at every frequency |
| ATK against the THR 80 baseline, 8 patterns, twin | RAT 2 0.13 rms (ATK 10 ms -0.22), RAT 3 0.11 |
| THR 127 and 110 at HPF and HIT (never fitted) | 1.1 to 1.4, no bias |

On the cal build the twin runs on the device's own sides, so device and twin
agree exactly; earlier builds that streamed only L + R differed by 0.4 to
0.65 dB.

## Known limits

- **Detector crest sensitivity.** Against a clean tone (crest 2.27 dB) the twin
  reads 0.58 dB hotter than against an overdriven one (1.37 dB), relative to the
  hardware (2026-09-24, `grid_20260924_081259`): the stub's detector responds to
  crest factor more than the compressor's does. The level scale is set on the
  grid's overdriven tone and the SEQ levels on the sweep's sine; material with
  a very different crest factor will read off. Not yet modelled.
- **Release into quiet passages** is held too long. A1 is program-dependent
  (its best coefficient runs 160 to 800 with the step); `reltab` holds a fixed
  stand-in.
- **Tone against drums.** The SEQ levels come from a steady sine. The drum
  suites ask for LPF, HPF and HIT each about 0.5 dB higher against OFF (HIT on
  top of its 1.36 dB `transient_db`), and for LPF the grid and the patterns
  differ by 0.8 dB; `fit_shift.py` reports these without writing them.
- **Deep reduction on drums** reads about 0.7 dB deep at LPF THR 60. Not the
  detector, an attack slew or a depth-dependent release; unexplained.
- **Depth on drums** (the 2026-09-26 verify draws, steady blocks): the estimate
  reads 0.5 to 1.5 dB deep under 15 dB of reduction and up to 1.3 dB shallow
  over 32, and the hardware reaches 41 dB against `GR_CAP`'s 35.9. The curve's
  knees and cap are fitted on a tone; refitting them on drums is open.
- **The hardware's GR moves faster than the estimate's**: on the verify draws
  the estimate reads about 0.8 dB deep while the reduction falls and 0.8 dB
  shallow while it rises, even at the fastest attack. Not timing (the best
  alignment is zero), the detector's 5 ms decay, or the attack and release
  tables scaled. Most of the remaining rms.
- **RAT 3** read 0.7 dB deep on the verify draws before `seqatk`; on the ATK x
  SEQ suite HIT at ATK 30 ms still reads 1.1 dB deep at RAT 0 and 1.7 shallow
  at RAT 3 - `seqatk` has no ratio in it.
- **Reverb send** widens the scatter, not the bias: about 0.8 dB rms more from
  send 0 to 127.
- **`coupling` for RAT 0 and 1** rests on one pattern's ATK sweeps, and the
  release times on single sweeps at RAT 1:4.
- **DIST symmetry depends on DIST, and the model does not.** Its bias and gain
  are per SYM only, fitted at DIST 64 and 96. At low DIST the hardware responds
  to symmetry very differently: one-factor sweeps at DIST 0 (2026-09-25) read the
  estimate 1 to 7 dB deep on one pattern and 11 to 19 dB on another anywhere
  from SYM 24 to 104 but 64, where it is within 0.5 dB, as it is at every DIST
  with SYM at 64. Near SYM 0 and 127 with DIST near 0 the hardware all but
  mutes. Treat SYM away from 64 as outside the model; verification holds it
  at 64. A fix needs a SYM x DIST model and the symmetry sweep at low DIST.
- **PRE returns** join the sum about six blocks early; POST returns are not
  modelled; hats saturate about 1 dB earlier than the fitted curve.
- **A p-locked pan change** glitches the input model briefly: the VCA words lead
  the audio by four ticks.
- **The 2026-09-23 grids** used one voice, centred; the curve's shape was fitted
  on a single tone.
