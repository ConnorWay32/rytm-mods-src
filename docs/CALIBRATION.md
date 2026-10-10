# Calibrated values

Which mods take values from measurements of the analog side, where each value
is kept, and how to measure them again. The values themselves are kept only
where they are set.

| Mod | What is calibrated | Values set in | Procedure | Checked by the build |
|---|---|---|---|---|
| 0006-comp-preview | input trims, PRE return gains, distortion, symmetry, sidechain, curve, ballistics | `mods/0006-comp-preview/calibration.toml` | `re/subsystems/compressor-calibration.md` | yes: `calib_tables.py --check` |
| 0013-voice-dac | K, per-slot gain | `mods/0013-voice-dac/mod.toml` (`k`), `stub.s` (`gaintab`) | below | no |

## A new machine

Calibrate in this order:

1. 0006, by its procedure. Its calibration image is built with 0006 alone, so
   0013 is not in it and the voices reach MAIN on the analog bus, as the
   model assumes.
2. 0013, below. It starts from 0006's slot trims.

## 0013's per-slot gain

Each voice slot's gain into the PRE pair is `k` times the slot's entry in
`gaintab`:

    gaintab[s] = 32767 * 10^(-trim_db[s] / 20)

`trim_db` starts as 0006's `slot_trim_db`. 0013 then corrects any slot that
does not match the analog path, so a slot may differ from 0006's (slot 6 does,
by 0.57 dB, unexplained). A new 0006 calibration does not reach `gaintab`: it
is recomputed by hand, then corrected by `tools/voice_dac_gain.py`. The
measurements behind the current values are in the comments beside `k` and
`gaintab`.

### Procedure

The comparison is DAC SUM off against on: with it off the voices take the
analog bus, with it on the DAC path, and the two should read the same at MAIN.

1. Set `trim_db` to 0006's `slot_trim_db`, recompute `gaintab`, and leave `k`
   at its current value. Build and flash the shipping mods.
2. Choose two or more patterns that between them play all eight voice slots
   at a steady level, with no p-locked pan or level, the delay and reverb
   sends at zero, and no DIST or compressor on the voices. Set every DAC
   FILTER TYP to OFF.
3. Record each with `tools/mix_capture.py record PATTERNS --no-split` (its
   docstring lists the MIDI settings it needs), once with DAC SUM off and once
   with it on, nothing else changed between the two runs. Quit anything that
   loops the Rytm's USB audio back to it.
4. Run `tools/voice_dac_gain.py OFF_RUN ON_RUN`. It prints how many dB each
   slot reads low with DAC SUM on, and `k` and `gaintab` corrected from the
   values in `mods/0013-voice-dac`. A pattern whose fit leaves more than
   -20 dB of MAIN unexplained is left out: a send, DIST or the compressor is
   still reaching MAIN.
5. Set `k` and `gaintab` to the printed values; `k` is Q15 and at most 16384.
6. Rebuild, flash and repeat 3 to 5 until every slot reads within 0.1 dB.
7. Check headroom: build with `timing = 1`, turn DAC SUM on, record the
   loudest patterns with `mix_capture.py record --no-split`, and run
   `tools/voice_dac_headroom.py` on the run. No side-frame should reach full
   scale. Build with `timing = 0` again to ship.
8. Note the new values, the date and the run directories in the comments
   beside `k` and `gaintab`.
