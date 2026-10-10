# Tempo

The tempo word, and a stock display bug in the top bar. Stock MKII 1.73, MAIN
OS at `0x40000400`. Claims are tagged **[measured]** (read from
`build/mainos_emac.dis` or on the device) or **[inferred]**.

## The tempo word [measured]

`0x40287c9c`, a long holding the tempo in **1/120 BPM**. Its initial value in
the image is 14400 (120.0 BPM). `0x4011f2f0` returns it; it is written at
`0x4009e482` (not analysed) and read at 16 other sites.

## The top bar shows 132.0 as "BPM:131.10" [measured]

On the device, 2026-09-27, tempo 132.0: the top bar, left of the transport
icon, read `BPM:131.10`; the TEMPO popup read `132.0`.

The top bar is drawn by `0x400c827a`, which also draws the kit number
(`K%03d`). Its tempo branch, `0x400c8490..0x400c852e`:

```text
t      = tempo word (0x4011f2f0)
whole  = t / 120
tenths = (t - 120 * whole + 6) / 12      ; rounded to the nearest tenth
sprintf("BPM:%3d.%d", whole, tenths)     ; 0x40255dc2
```

When `t mod 120` is 114..119 - a tempo from 131.95 up to 132.0, exclusive -
the rounding gives `tenths = 10`, which is neither carried into `whole` nor
limited to one digit. So the display should show "132.0" and shows "131.10".

The other branch, taken when `0x400353e4` returns true, shows whole BPM only,
as `(t + 60) / 120` with `%d` (`0x4025b683`); it rounds correctly.

That the top bar read the bug means the word held 15834..15839, a hair under
the 132.0 setting **[inferred]**. What the popup reads is not traced.

**Fix, not built:** compute `t10 = (t + 6) / 12`, then print `t10 / 10` and
`t10 % 10`.

## Open: the MIDI clock runs fast of the setting

At 132.0, the Rytm's MIDI clock out measured **132.26 BPM**: a line fitted to
529 consecutive ticks over 10 s, timed on the Mac (tick jitter under 1 ms,
so the fit is good to about 0.01%) **[measured]**. That is 0.2% fast of the
setting and of the tempo word. Short windows are worse: fitting only the first
second after Start gave 131.95 to 134.0, because the ticks arrive with bursts
(shortest interval 2.6 ms against 18.7 ms). Not yet compared with the tempo
taken from the audio's own sample clock.
