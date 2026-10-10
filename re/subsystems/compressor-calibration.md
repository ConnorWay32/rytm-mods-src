# Compressor calibration: mod 0006

How to calibrate mod 0006's gain-reduction estimate on an Analog Rytm MKII from
scratch: what to prepare, what to record, how each value is fitted, and how the
result is verified. What the values mean is in
[compressor-model.md](compressor-model.md); the hardware facts behind them are
in [compressor-hardware.md](compressor-hardware.md). Commands run from the repo
root; `calibrate.py` is `.venv/bin/python tools/comp/calibrate.py`.

## The whole run

Three sittings at the device, about four and a half hours of recording, all
driven over MIDI and recorded over USB. Two flashes of the calibration image and
one of the shipping image:

    calibrate.py run new 2026-10-01                  # the run everything records into
    calibrate.py project --send                      # the calibration project, Rytm in SYSEX RECEIVE

    make comp-cal-build                              # flash 1: build/Analog-Rytm_MKII_OS1.73_cal.syx
    calibrate.py preflight                           # 3 min: the rig, the device and the project
    calibrate.py sitting 1                           # 30 min: input model, distortion, symmetry
    calibrate.py fits sitting1_... --write
    git commit mods/0006-comp-preview/calibration.toml calib.inc   # the point sitting 3 may return to

    make comp-cal-build                              # flash 2: with sitting 1's values
    calibrate.py preflight
    calibrate.py twin                                # device against twin: no block differs
    calibrate.py sitting 2                           # 3 h 45 min: sidechain, curve, ballistics
    calibrate.py fits sitting2_... --write
    calibrate.py sitting 3                           # 12 min, on the same image: verification
    calibrate.py fits sitting3_...                   # the verdict, and the run's report.md
                                                     # a FAIL: see "When sitting 2's fits do not help"

    make comp-cal-check && make comp-selftest && make verify
    calibrate.py report --publish
    git commit mods/0006-comp-preview/calibration.toml calib.inc calibration_report.md
    make build                                       # flash 3: the shipping image

Each sitting records its sessions in order and leaves a manifest; `fits` runs
that sitting's fits in order, printing what each would change and, with
`--write`, writing it. The sections below say what each records and fits.

## How it fits together

| File | Role |
|---|---|
| `mods/0006-comp-preview/calibration.toml` | every calibrated value, in physical units, with where it came from |
| `mods/0006-comp-preview/calib.inc` | generated from it; `stub.s` includes it |
| `mods/0006-comp-preview/calibration_report.md` | the last calibration's results: what it changed and its verification |
| `mods/0006-comp-preview/calibration_project.syx`, `.toml` | the calibration project, and which patterns and track play each part |
| `tools/comp/calibrate.py` | the command line: records each stage on the cal build, fits it, verifies, reports; the stages are in `cal_input.py`, `cal_tone.py` and `cal_suite.py`, the plumbing in `cal_io.py` |
| `tools/comp/stub_model.py` | the twin: `stub.s` with `calib.inc`, in Python, exact to the device |
| `tools/comp/fit_shift.py`, `fit_ballistics.py`, `fit_sidechain.py` | the curve, the slow-attack coupling, the sidechain sections |
| `tools/comp/calib_tables.py` | generates `calib.inc`; `--check` fails if it is stale (`make build` runs it) |

Nothing calibrated is edited in `stub.s`. A fit prints the values it would set;
with `--write` it rewrites their lines in `calibration.toml`, notes the source,
and regenerates `calib.inc`.

**The cal build** (`make comp-cal-build`) is 0006 alone, estimating on every
block. On USB channels 10 and 11 it carries the model's two sides and a record of
each block: the parameters, the detector's peak, the level, the demand, the GR,
the UI load, and `CAL_HASH`, the fingerprint of the `calib.inc` it was built
from. MUP's integer part picks the sides at run time: 0 after the saturation,
anything else before it (the distortion stages set it, at MIX 0, where makeup is
out of the path).

**Runs and sessions.** A calibration is one run, a directory under
`build/comp/runs/`:

    build/comp/runs/<run>/
      run.json              when, the git commit, the rig, the roles, the calibration it started from
      <session>/            one per recording: session.json and its captures
      sitting<N>_<time>/    a sitting's manifest: the sessions it recorded
      fits/                 the output of every `calibrate.py fits`
      report.md             the run's results (`calibrate.py report`)

`calibrate.py run new NAME` starts one and makes it current; every recording
goes into the current run and refuses to start without one. `run use NAME`
returns to an earlier run, `run` lists the current one. `build/` is not
committed: a calibration's result is `calibration.toml`, `calib.inc` and
`calibration_report.md`, each value noting the session it came from.

Each session records the calibration it ran on, and a recording refuses to start
unless the device's `CAL_HASH` matches the host's `calib.inc`. The one exception
is verification: see sitting 3. Fits read what ran from the session, so a
session can be refitted after later changes, except after a change to `[input]`
or `[distortion]`, which the recorded sides depend on; a fit on stale sides
warns.

## Before you start

Everything the tools assume, as a checklist. `calibrate.py preflight` (below)
checks what the device can show; the rest is for the person at it.

### The host

- The repo set up: `make setup`, and `m68k-elf-binutils` for `make build`.
- Flashing as in `docs/FLASHING.md`.
- The Rytm on USB, and a MIDI connection to it (USB MIDI will do). No audio
  interface: everything is recorded from the Rytm's own USB audio.
- `calibrate.py devices`, then `calibrate.py setup --midi PORT --fx-channel N`,
  which writes `build/comp_rig.json`. `--midi-in PORT` if the Rytm's MIDI input
  port is named differently from its output, for `project --receive`.

### The Rytm

- OS 1.73, flashed with the cal image before each sitting as the sittings say.
- USB audio in the mode that presents twelve input channels (MAIN on 0-1, the
  voice slots on 2-9, the cal frames on 10-11). The mode with two is MAIN only.
- MIDI (SETTINGS > MIDI CONFIG): receive CCs, program change and transport
  (MIDI Start and Stop), with the USB port among the inputs; CLOCK RECEIVE off -
  with it on, MIDI Start arms the sequencer but it waits for clock the tools do
  not send. The
  channels the tools assume: track N on MIDI channel N, which the tone track's
  CCs and note use; the FX track on the channel given to `setup`; the auto
  channel 14, on which program change switches patterns.
- Pattern change mode DIRECT JUMP.
- Nothing connected to the external audio inputs. They reach the compressor,
  but not the model, and the cal build uses their USB channels for its frames.
- The main volume knob set once and left alone for the whole of each sitting
  (docs/HAZARDS.md): USB MAIN follows it, and every fit compares against MAIN.
- Your own work saved: `project --send` replaces the Rytm's active project.

### The calibration project

The tools set everything they vary over CC and read it back: the compressor,
DIST and its symmetry, the delay and reverb volumes and routing, and the tone
track's filter, level and pan. A kit's own values for those do not matter, but
nothing may change them behind the tools' backs. For every pattern:

- Named as the Rytm names them (A01 .. H16) or numbered 1 .. 128; any bank.
  Each role its own patterns: no verify pattern may be a fit pattern.
- No parameter lock, LFO or other modulation on the FX track's compressor,
  DIST, DIST symmetry, delay and reverb volumes or PRE/POST routing.
- Plays continuously: no fills, mutes or conditional trigs that leave long
  silences in an 8-second capture.
- Loud enough that the mix into the compressor is above -40 dBFS for most of
  each capture, but MAIN does not reach full scale: blocks outside that window
  are not scored.

| Role | Content | Used by |
|---|---|---|
| fit | eight or so drum patterns of varied material, with some delay and reverb send | the input model, distortion and symmetry (the first three), the extended and SEQ suites |
| verify | two or more further drum patterns | verification only |
| scratch | one empty pattern - no trigs on any track - on a kit of its own with a sound on every track; the Rytm's default kit will do | the roll call, and the tone for the sidechain sweep, the grids and the release steps |

The scratch pattern serves both stages that play the Rytm by MIDI note rather
than by its sequencer:

- **The roll call** (the input stage). The tools switch to the scratch pattern
  to load its kit, stop the sequencer, set the delay and reverb sends of tracks
  1, 2, 3, 5, 6, 7, 9 and 11, and play them one at a time by MIDI note (note t - 1
  on the auto channel triggers track t, midi-cc.md), 1.5 s
  apart, so each voice sounds alone and then the returns' tails alone. The
  twelve tracks share eight voices - 3 and 4 share one, as do 7 and 8, 9 and 10,
  11 and 12 - and those eight tracks cover every voice.
- **The tone** (sitting 2's tone stages). The tools set the tone track (track 8
  by default) up themselves - filter LP2 with no envelope or LFO depth, amp
  attack 0 and hold at its longest, no delay or reverb send - then hold its note
  with resonance 127 and a cutoff: a self-oscillating sine. The filter does not
  always start oscillating at the grids' low cutoff, so the note starts at
  cutoff 80 and moves down once it sounds. Its level and pan too.

Both leave the kit changed, which is why the scratch pattern needs a kit no drum
pattern uses. CC changes also stay in the working kit: do not save the project
after a calibration.

If `mods/0006-comp-preview/calibration_project.syx` exists, put the Rytm in
SYSEX RECEIVE and

    calibrate.py project --send

and the roles are already in `calibration_project.toml`. Otherwise build the
project once, then record the roles and store it with the repo:

    calibrate.py roles --fit A01-A08 --verify A09,A10 --scratch B01 --tone-track 8
    calibrate.py project --receive                   # then SYSEX DUMP of the project on the Rytm

and commit `calibration_project.syx` and `calibration_project.toml`.

### Preflight

With the cal image flashed and the project loaded, before each sitting:

    calibrate.py preflight                           # about 3 minutes

It plays every role's patterns and reports PASS, WARN or FAIL for each check,
exiting non-zero if any failed:

- the cal build running and its calibration against `calib.inc`, the current
  run, the roles;
- each pattern switched to and playing - program change and MIDI Start work;
- on each fit and verify pattern and the roll call, a deliberately unusual
  compressor, DIST and symmetry setting read back unchanged on every block - no
  lock or LFO on them - and the share of blocks inside the scoring window;
- the roll call: every roll-call track sounding alone, 20 dB over the rest, and
  the returns alone after the hits, and for how many blocks;
- the scratch pattern silent with no note held, and the tone track's held note a
  steady, loud enough sine.

It lists what the device cannot show - the knob, the external inputs, locks on
the delay and reverb and on pan, silences in the patterns - for you to confirm,
and writes its result into the current run.

## Sitting 1: input model and distortion

    make comp-cal-build                              # flash it
    calibrate.py preflight                           # everything below assumes it passed
    calibrate.py sitting 1                           # about 30 minutes
    calibrate.py fits sitting1_... --write
    git commit mods/0006-comp-preview/calibration.toml calib.inc

which is, in order:

    calibrate.py input                               # then input --fit S --write
    calibrate.py dist                                # then dist --fit S --write
    calibrate.py dist --sym --dists 64,96            # then dist --sym --fit S --write

The later fits here warn that their sides ran on an older `[input]`: expected,
since each fit reads what ran from its session.

**Input model** (`[input]`: `slot_trim_db`, `delay_db`, `reverb_db`). At MIX 0,
MAIN is the compressor's input, so the model's energy over MAIN's per block (the
null) scores the model. Blocks where one slot is 20 dB over every other give
that slot's null; the trims make every slot's null equal, the quietest at 0 dB
(the stub can only cut). Blocks where no slot sounds and one return is on give
that return alone; its constant is set to match the slots. Values with fewer
than 50 blocks are held - the roll call is there to give every slot and both
returns enough. Only differences between nulls mean anything, since MAIN
follows the volume knob.

**Distortion** (`gain`, `sat_c_pos`, `sat_c_neg`). DIST 0..127 at MIX 0, on the
sides before the saturation: the hardware's gain per DIST against the model's,
and the saturation's c per sign fitted on blocks past the knee. `gain` is written
when it moves over 0.15 dB, each c only when every pattern moves it the same way
by over 0.02 (hats saturate earlier than kicks, so a median would follow the
material).

**Symmetry** (`sym_bias`, `sym_gain_db`). SYM 0..127 in steps of 8 at DIST 64 and
96; per SYM, a bias before the saturation and a gain after it, fitted on the
detector's 5 ms peak level. Near SYM 0 and 127 with DIST near 0 the hardware all
but mutes and the model does not follow; that corner is left.

The distortion fits use the saturation's current c, so the distortion is written
before the symmetry is fitted; `fits` keeps that order.

## Sitting 2: sidechain, curve, ballistics

The recorded sides depend on sitting 1's values, so they must be in the image:

    make comp-cal-build                              # with sitting 1's values; flash it
    calibrate.py preflight
    calibrate.py twin                                # device against twin: no block differs
    calibrate.py sitting 2                           # about three and three quarter hours
    calibrate.py fits sitting2_... --write

A sitting that stops part way (a tone that will not start, a lost connection)
resumes from its manifest, recording only what it lacks:

    calibrate.py sitting 2 --resume sitting2_...

which is, in order, the sidechain sweep, the two grids and the release steps on
the scratch pattern, then the extended suite, the SEQ suite and the ATK x SEQ
suite on the fit patterns:

    calibrate.py sidechain                           # 10 min
    calibrate.py grid --cutoff 33 --seq 0 ...        # the grids, an hour
    calibrate.py grid --cutoff 33 --seq 1 ...
    calibrate.py release --cutoff 33                 # 5 min
    calibrate.py suite --extended                    # an hour and a quarter
    calibrate.py suite --seq-matrix 0,1,2,3 --thr 100,80    # 45 min
    calibrate.py suite --atk-seq                     # 30 min

**Sidechain sweep.** The tool holds the note, sweeps the cutoff 35 Hz to 14 kHz
at each SEQ, sets THR for about 12 dB of reduction at each frequency, and takes
the measured reduction back through the curve to the level the hardware's
detector saw. Against the model's level, that is the sidechain's error per
frequency; every point sits at the same reduction, so an error in the curve's
slope cancels.

**Grids.** The same tone, parked at about 92 Hz: SEQ OFF at track levels 127 down
to 10 and THR 127 down to 40 in steps of 3, which finds the knees; SEQ LPF at
levels 127 down to 50 and THR 127 down to 91 in steps of 2, which finds the top
of the range. Every ratio. The session keeps one capture of the tone per ratio
and level, so the fit can work the levels out again through any later sidechain.

**Release steps.** Per REL, the tone stepped between track level 120 and 70
every 2.5 s, THR set for about 12 dB of reduction at the loud level. The tone
never stops, so each release can be measured to its end, which a drum pattern
cannot give.

**Extended suite.** Drum patterns: every THR 60-100 at every ratio, every ATK at
every ratio and every REL at RAT 2, at THR 80, SEQ LPF, each against a THR 80
baseline.

**SEQ suite.** Drum patterns: every ratio at THR 100 and 80 under each SEQ. HPF
and HIT have no grid, so their offsets, and `transient_db`, are fitted on this.

**ATK x SEQ suite.** Drum patterns: ATK 0.3, 3 and 30 ms and an ATK 0.03
baseline under SEQ OFF, HPF and HIT, at RAT 0 and 3, THR 80, REL 0.1 s. The
extended suite's ATK sweeps are all at LPF; this is what the slow-attack loss at
the other SEQs is fitted on.

The fits, in order:

    calibrate.py sidechain --fit calsc_... --write
    fit_shift.py --grid calgrid_A --grid calgrid_B --suite calsuite_SEQ --write
    calibrate.py sidechain --fit calsc_... --write          # once more, on the new curve
    calibrate.py release --fit calrel_... --write
    fit_ballistics.py --suite calsuite_EXT --holdout --write
    fit_ballistics.py --seq-suite calsuite_ATKSEQ --holdout --write

**Sidechain** (`[sidechain]` sections, `level_db`). The error is added to the
response of the rows the sweep ran on; two first-order sections and a level per
SEQ are fitted to that, under 9 kHz, OFF as the level reference. Expect
residuals of 0.1-0.2 dB rms (HIT about 0.4).

**Curve** (`[curve]`: `knee_db`, `slope`, `width_db`, `thr_step_db`,
`cap_db`). Each grid level is worked out through the current twin; the reduction
is the input-to-MAIN ratio against the no-reduction ratio (THR 127 readings the
current curve says do not compress). Acceptance: the grids at 0.65 dB rms or
better, which `fit_shift.py` reports. New sidechain sections move the whole level
scale, and the knees follow them; the sweep in turn is read through the curve.
The second sidechain fit settles that - it should barely move anything.

**Transient offset** (`transient_db`). `fit_shift.py` also fits, on the SEQ
suite, the SEQ offsets the drums ask for beyond `level_db + transient_db`. The
part LPF, HPF and HIT share (the median) is the steady tone against drums, the
detector's crest sensitivity, and is left; a SEQ's departure from it goes into
its `transient_db`, written past 0.2 dB.

**Release** (`reltab_q16`). The stub's ballistics are run on the device's own
demand with a candidate release coefficient per REL, against the measured
reduction after each step down, both taken relative to the loud plateau before
the step so a static-curve error does not enter. Written when a REL moves over
5%. A1 and A2 are program-dependent on the hardware; their entries are the best
fixed stand-in for these steps.

**Ballistics** (`[ballistics] coupling`; `atkscale` is generated from it). Each
capture's sides go through the twin and the slow-attack coupling C and p per
ratio is fitted on the ATK biases against the baseline. With `--holdout` it is
fitted on the odd patterns and scored on the even, and only the ratios whose
held-out bias improves are written. The script also reports what each REL's
`reltab` value would be on these patterns alone, as a check on the release fit.

**SEQ slow-attack loss** (`[ballistics] seq_atk_db`; `seqatk` is generated from
it). The same, on the ATK x SEQ suite: per SEQ OFF, HPF and HIT, the dB at ATK 6
that takes each ATK's bias to its SEQ's ATK 0 baseline, held out the same way.

## Sitting 3: verify

On the same image as sitting 2 - no flash:

    calibrate.py sitting 3                           # about 12 minutes
    calibrate.py fits sitting3_...                   # the verdict, and the run's report.md

which is

    calibrate.py verify                              # 60 random draws on the verify patterns

Each draw sets THR 40-120, every RAT, SEQ, ATK and REL, DIST 0-127 and both
return volumes at random, with SYM at 64 - the model does not handle symmetry
away from 64 at low DIST (compressor-model.md, Known limits) - from a seed the session records (`--seed`
repeats a draw set; `verify --score SESSION` re-scores one). Every draw is scored
against the measured reduction twice: the device's own GR, and the twin running
the current `calibration.toml` over the recorded sides.

The device still runs sitting 2's image, which sitting 2's fits have since
written over; verify accepts it because the sides depend only on `[input]` and
`[distortion]`, which sitting 2 does not change, and the twin - bit-exact to the
device, as `calibrate.py twin` showed at the start of sitting 2 - scores the new
curve, sidechain and ballistics on them. The device's own row scores the old
values and is for reference; the verdict is the twin's.

The twin starts each draw from the device's GR at the draw's first block: the
compressor carries the last draw's reduction in, and a slow release takes
seconds to let it go.

`verify.md` in the session's directory gives both scorers, a breakdown by
setting, the worst draws and the verdict:

| Measure | Accept |
|---|---|
| rms, all draws | 2.0 dB or less |
| mean, all draws | within 0.5 dB |
| mean of any one setting with 3 draws or more | within 1.5 dB |

The limits start from the drum-pattern accuracy of 2026-09-24 (1.2 to 1.6 dB
rms, each SEQ's bias within 0.2) widened for the settings those patterns never
varied. The first full run passed at 1.57 dB rms, mean +0.03, every setting
within 0.44 (2026-09-26); tighten them once a second run holds to the same.

### When sitting 2's fits do not help

Each of sitting 2's fits is judged on its own data, several of them on held-out
patterns, but nothing checks them together against settings they never saw;
that is sitting 3's job. On the first run (2026-09-25) they were written, and on
fresh draws the result scored no better than sitting 1's commit: 2.04 against
1.98 dB rms, and the bias moved from +0.5 deep to -0.6 shallow. The fit patterns already sat within 0.5 dB of the model, so the fits had
little to take out and moved values on noise and on the tone-against-drums
difference.

So on a FAIL, score sitting 1's commit on the same verify session before
changing anything:

    T=mods/0006-comp-preview
    git stash push $T/calibration.toml $T/calib.inc  # sitting 2's values, kept
    calibrate.py verify --score calverify_...        # sitting 1's values, same draws
    git stash pop
    calibrate.py verify --score calverify_...        # sitting 2's again

No device is needed; each score prints its table and rewrites the session's
`verify.md`. Keep whichever scores better; a single group can be kept by restoring only its
lines. Choosing between the two on this session makes it fit data: verify the
choice on fresh draws (`calibrate.py verify`, a new seed), on an image built
from it. Then look at the breakdown by setting in `verify.md` for what neither
explains. That is how the SEQ slow-attack loss was found: at HPF and HIT the
estimate read 0.53 dB deeper a step of ATK, on no other setting, because every
ATK sweep ran at LPF. The ATK x SEQ suite now covers it; a failure of the same
kind means a setting the fit suites do not vary.

## Finish

    make comp-cal-check                              # calib.inc current
    make comp-selftest
    make verify                                      # the shipping image
    calibrate.py report --publish

`report --publish` writes the run's `report.md` - the values the run changed, its
sessions, fit logs and verification - and copies it to
`mods/0006-comp-preview/calibration_report.md`. Commit that with
`calibration.toml` and `calib.inc`, then flash the shipping image (`make build`).
If the per-sample path in `stub.s` changed, also check the interrupt load on a
`telem=1` build (`tools/comp/telemetry/monitor.py`, `pc_timing.py`): the UI queue should stay in
single digits.

## Values without a fitting tool

- `rel_eff_s` (each REL's effective release time in the slow-attack coupling):
  fitted by hand on 2026-09-22; a fit would need ATK swept at every REL.
- `tau_s` (the detector's 5 ms decay) and `silence_db`: choices, not
  measurements.

## Status of this process

Run end to end once on the device, 2026-09-25 to 26 (run `test_2026-09-25`;
`calibration_report.md`), from the calibration committed before it. Every stage
recorded and every fit ran. What that run found and changed:

- Kept: sitting 1's values, and `seq_atk_db`, fitted on the ATK x SEQ suite
  (added during the run) and verified on fresh draws at 1.57 dB rms, mean +0.03.
- Written and reverted: sitting 2's fits - sidechain, curve, `transient_db`,
  `reltab` and coupling (see "When sitting 2's fits do not help"). Those values
  are still from the earlier sessions `calibration.toml` names. The curve refit
  was on the clean self-oscillating tone; see below.
- Fixed on the way, now in the tools and this guide: CLOCK RECEIVE off, tracks
  played by note on the auto channel, kits loaded by program change while the
  sequencer runs and the sequencer stopped fully (midi-cc.md), the roll call's
  delay feedback and its runaway guard, the tone's start, `--resume`, the twin's
  start state, and SYM held at 64 in verification.

Not yet used on the device:

- `project --receive / --send`: `calibration_project.syx` is not in the repo
  yet. Until it is, the calibration project has to be built by hand from the
  roles in `calibration_project.toml` (A01-A08 fit, A09 and A10 verify, B16 the
  scratch pattern on the default kit, tone track 8).
- `sitting 2` and `fits` with the ATK x SEQ suite in them: the suite ran on its
  own and its fit by hand, after the rest of sitting 2.
- A run from blank values: every fit started from the values before it, and some
  start near them.
- Following this guide without the history: the run was driven by someone who
  wrote it, and fixed it as it broke.

**Open: the grid's tone.** The curve was fitted on an overdriven tone, and the
twin reads a clean tone about 0.6 dB hotter relative to the hardware
(compressor-model.md, Known limits). The 2026-09-25 grids on the clean
self-oscillating sine moved the knees about 0.6 to 1.5 dB down and the slopes
lower; on drums that read no better, and it was reverted with the rest of
sitting 2's fits. Add overdrive on the tone track for the grids, or fit the curve
on drums as well, before trusting a curve refit.
