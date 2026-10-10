# Calibration run test_2026-09-25

Started 2026-09-25T11:01:33 at commit 1dfe9fc-dirty; calibration 92967d49 -> c282c273.

## Notes

- Sitting 1's values are kept. Sitting 2's fits (curve, SEQ offsets, sidechain,
  release, coupling) were written, verified and reverted: on fresh draws they
  scored no better than the calibration they replaced (calverify_20260926_031447).
- Verification holds SYM at 64: the symmetry model is fitted at DIST 64 and 96
  and reads 1 to 19 dB deep at low DIST with SYM away from 64
  (calverify_20260925_210047 and the one-factor sweeps).
- The twin now starts each draw from the device's GR; before, a slow release
  read as model error. The verdicts below were each scored when recorded.
- The remaining error was a slow-attack loss at SEQ OFF, HPF and HIT that the
  coupling, fitted at LPF, did not carry. The stub gained `seqatk`, fitted on the
  ATK x SEQ suite (calsuite_20260926_100114, fit_ballistics.py --seq-suite
  --holdout) and verified on fresh draws (calverify_20260926_104653).

## Values changed

- `[input] slot_trim_db`: [0.0, 0.0, 0.0, 0.0, 0.0, 0.8474, 0.8474, 0.0] -> [0.0, 0.0027, 0.0, 0.0346, 0.0793, 0.9241, 1.1018, 0.1957]
- `[input] delay_db`: 9.4 -> 10.18
- `[input] reverb_db`: 15.5 -> 16.83
- `[distortion] sym_bias`: [0.7334, 0.5353, 0.485, 0.4313, 0.3746, 0.286, 0.1662, 0.0678, 0.0, -0.0862, -0.17, -0.2833, -0.3777, -0.4409, -0.4952, -0.5394, -0.5902] -> [0.7199, 0.4966, 0.4372, 0.396, 0.352, 0.2717, 0.1695, 0.0741, 0.0, -0.0821, -0.1599, -0.2592, -0.3479, -0.4139, -0.4662, -0.5353, -0.5988]
- `[distortion] sym_gain_db`: [-9.225, -8.535, -5.827, -3.42, -1.521, -0.679, -0.389, -0.242, 0.0, -0.236, -0.382, -0.64, -1.277, -2.655, -4.92, -7.603, -10.153] -> [-8.927, -8.114, -5.625, -3.508, -1.747, -0.94, -0.026, -0.43, 0.0, -0.42, -0.571, -0.919, -1.589, -2.867, -4.825, -7.143, -9.541]
- `[ballistics] seq_atk_db`: None -> [1.56, 0.0, 2.77, 3.47]

## Sessions

- caldist_20260925_143012
- calgrid_20260925_160124
- calgrid_20260925_163628
- calgrid_20260925_165636
- calinput_20260925_142121
- calrel_20260925_171617
- calsc_20260925_155438
- calsuite_20260925_172052
- calsuite_20260925_182832
- calsuite_20260926_034215
- calsuite_20260926_100114
- calsym_20260925_143626
- calverify_20260925_210047
- calverify_20260925_234151
- calverify_20260926_031447
- calverify_20260926_104653
- sitting1_20260925_142118
- sitting2_20260925_155435
- sitting3_20260925_210044
- sitting3_20260925_234148
- sitting3_20260926_031444
- sitting3_20260926_104650

## Fits

- fits/sitting1_20260925_142118_write.log
- fits/sitting2_20260925_155435.log
- fits/sitting2_20260925_155435_write.log

## Verification

- calverify_20260925_210047, calibration 13bcf029: **FAIL** - over: THR 60-79, RAT 1, RAT 3, SEQ 2, SEQ 3, ATK 0, ATK 2, ATK 3, ATK 6, REL 0, REL 2, REL 3, DIST 0-31, DIST 32-63, SYM 20-39, SYM 40-59, DELAY 64-95, DELAY 96-127, REVERB 64-95, REVERB 96-127
- calverify_20260925_234151, calibration 13bcf029: **FAIL** - over: RAT 3, ATK 4, ATK 5, ATK 6
- calverify_20260926_031447, calibration 355fab79: **FAIL** - over: SEQ 1, REL 5

### Verification calverify_20260926_104653

Seed 78882579, 60 draws on patterns A09,A10, calibration c282c273. GR estimate minus measured, dB, per block.

| scorer | blocks | rms | mean |
|---|---|---|---|
| device | 701648 | 1.56 | +0.05 |
| twin | 701648 | 1.57 | +0.03 |

By setting (twin; groups of 3 draws or more):

| setting | draws | rms | mean |
|---|---|---|---|
| THR 40-59 | 11 | 1.88 | -0.16 |
| THR 60-79 | 19 | 1.41 | +0.30 |
| THR 80-99 | 12 | 1.64 | -0.28 |
| THR 100-119 | 17 | 1.47 | +0.06 |
| RAT 0 | 13 | 1.66 | -0.22 |
| RAT 1 | 14 | 1.54 | -0.06 |
| RAT 2 | 18 | 1.60 | +0.28 |
| RAT 3 | 15 | 1.46 | +0.03 |
| SEQ 0 | 14 | 1.54 | +0.11 |
| SEQ 1 | 13 | 1.37 | +0.28 |
| SEQ 2 | 19 | 1.63 | -0.02 |
| SEQ 3 | 14 | 1.67 | -0.22 |
| ATK 0 | 8 | 1.42 | +0.06 |
| ATK 1 | 12 | 1.61 | -0.08 |
| ATK 2 | 6 | 1.27 | +0.44 |
| ATK 3 | 13 | 1.70 | -0.04 |
| ATK 4 | 3 | 1.80 | +0.33 |
| ATK 5 | 11 | 1.65 | -0.02 |
| ATK 6 | 7 | 1.37 | -0.09 |
| REL 0 | 9 | 1.48 | -0.14 |
| REL 1 | 9 | 1.44 | +0.02 |
| REL 2 | 7 | 1.81 | +0.01 |
| REL 3 | 7 | 1.68 | +0.02 |
| REL 4 | 9 | 1.81 | +0.02 |
| REL 5 | 6 | 1.35 | +0.10 |
| REL 6 | 5 | 1.19 | +0.32 |
| REL 7 | 8 | 1.53 | +0.03 |
| DIST 0-31 | 18 | 1.58 | +0.03 |
| DIST 32-63 | 21 | 1.47 | +0.07 |
| DIST 64-95 | 6 | 1.37 | +0.36 |
| DIST 96-127 | 15 | 1.74 | -0.17 |
| SYM 60-79 | 60 | 1.57 | +0.03 |
| DELAY 0-31 | 14 | 1.54 | +0.15 |
| DELAY 32-63 | 16 | 1.57 | -0.17 |
| DELAY 64-95 | 15 | 1.47 | +0.01 |
| DELAY 96-127 | 15 | 1.67 | +0.15 |
| REVERB 0-31 | 24 | 1.41 | -0.04 |
| REVERB 32-63 | 13 | 1.23 | +0.06 |
| REVERB 64-95 | 8 | 1.60 | +0.17 |
| REVERB 96-127 | 15 | 1.99 | +0.04 |

Worst draws (twin mean):

- A10 v038: -2.83 dB, measured GR 37.1; THR 47, RAT 0, SEQ 2, ATK 3, REL 4, DIST 120, SYM 64, DELAY 59, REVERB 124
- A10 v049: -1.66 dB, measured GR 11.5; THR 112, RAT 1, SEQ 3, ATK 1, REL 1, DIST 126, SYM 64, DELAY 57, REVERB 20
- A09 v015: +1.16 dB, measured GR 1.8; THR 110, RAT 2, SEQ 2, ATK 2, REL 6, DIST 105, SYM 64, DELAY 90, REVERB 11
- A09 v001: +1.09 dB, measured GR 31.6; THR 71, RAT 2, SEQ 0, ATK 3, REL 5, DIST 108, SYM 64, DELAY 54, REVERB 18
- A10 v036: -1.07 dB, measured GR 11.9; THR 93, RAT 0, SEQ 0, ATK 5, REL 0, DIST 122, SYM 64, DELAY 42, REVERB 7

Acceptance (twin): rms <= 2.0, |mean| <= 0.5, every setting's |mean| <= 1.5: **PASS**

