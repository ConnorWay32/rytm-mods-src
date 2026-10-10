# Analog controls

Every control the ColdFire has over the analog side: the frame it sends each
interrupt, what each part of it drives, and who writes it. Stock MKII 1.73,
read from the image 2026-09-29; nothing here has been measured on the device.
Tags: **[measured]** read from the image, **[inferred]** reasoned from it.

Builds on [machines.md](machines.md) (the machine functions and the TEST
machines that name most of the voice controls), [envelopes.md](envelopes.md)
(the segment command) and [compressor-hardware.md](compressor-hardware.md)
(the VCA words and the master section).

## The frame [measured]

- 492 16-bit words, `0x800063c0` to `0x80006797` (`+0..+983`). Both
  initialisers clear exactly `0x3d8` bytes.
- Written through each interrupt by the machines, the envelope builders and
  the master-section writer, then sent by `0x4007a538(0x800063c0)`, called at
  `0x40121464` after all of them:
  - double-buffered at `0x80004800 + 2064 * buf`, `buf` toggled in
    `0x417e38ac`
  - a header long `0x8000aaaa`, then each word as the long `0x8001wwww`,
    then a trailer `0x08005555`; bit 26 is set in the first data long
  - `0x4007a5c6` writes the buffer's address + 12 to `0xfc0451e0` and sets
    bits in `0xfc03c000` / `0xfc03c02c`: the transfer's start **[inferred]**
- After the send, the interrupt clears byte 4 of each of the 56 eight-byte
  segment slots `+168..+615` (`0x4012146e`), so a segment command is sent
  once.
- `0x4011eaf6`, from the audio startup (`0x4011fa8e`, and from the
  calibration paths `0x40109130` and `0x4010cd84`), clears the frame and
  writes its defaults. `0x4010879a`, from the calibration flow
  (compressor-hardware.md), does the same for calibration.

So the analog side is driven by nothing but these 492 words, the per-voice
digital streams (machines.md, "What a machine writes") and the route mask
byte (compressor-hardware.md).

## Map

`v` is the physical voice 0..7 (BD 0, BT 1, SD 2, LT 3, CH/OH 4, MT/HT 5,
CY/CB 6, RS/CP 7). Words are raw: most parameters arrive as `value << 9`,
bipolar ones as `(value - 64) << 9`.

| offset | contents | source |
|---|---|---|
| `+0` | DIST amount × 2, from `0x8000fbce` (`0x40121326`) | measured |
| `+2..+8` | compressor: `+2` = `0x3000 - THR / 2`; `+4..+8` from the other compressor parameters at `0x8000fbd4` (`0x4010e1a0`) | measured; `+4..+8` not named |
| `+10 + 2v` | VCA left | compressor-hardware.md |
| `+26 + 2v` | VCA right | compressor-hardware.md |
| `+42 + 2v` | overdrive × 2 | compressor-hardware.md |
| `+58 + 2v` | sound index 30, re-centred and doubled (`0x4010d13a`) | measured; index 30 is filter frequency by envelopes.md's slice order |
| `+74 + 2v` | sound index 31, resonance, raw | measured |
| `+90..+96` | BD circuit: tune 1, tune 2 (bipolar), level 1, level 2 | TEST names |
| `+98..+104` | SD circuit: the same four | TEST names |
| `+106..+116` | RS circuit: the same four, then RS1, RS2 (bipolar) | TEST names |
| `+118`, `+120` | BT: tune, decay | TEST names |
| `+122`, `+124` | LT: pitch, decay | TEST names |
| `+126`, `+128` | MT/HT: pitch, decay | TEST names |
| `+130` | hats: tune | TEST names |
| `+132..+138` | hats: level of each of four outputs | TEST names |
| `+140` | hats: VCA | TEST names |
| `+142` | cymbal/cowbell: tune | TEST names |
| `+144..+152` | cymbal: five envelope CVs (5ENV1, 5ENV2, 8ENV1, 8ENV2, 8ENV3) | TEST names |
| `+154`, `+156` | cowbell: 5EN, 8EN | TEST names |
| `+158` | cymbal/cowbell: VCA | TEST names |
| `+160..+167` | 64 switch bits, below | measured |
| `+168..+615` | 56 segment slots, below | measured |
| `+616..+636` | hats: six 22-bit oscillator words (longs; the top bits of `+617` also set per selection) | measured; encoding not decoded |
| `+640..+660` | cymbal/cowbell: six 22-bit oscillator words (cowbell uses `+640`, `+644`) | measured; encoding not decoded |
| `+664..+779` | defaults from `0x4011eaf6`, rewritten by the calibration code; no per-interrupt writer found | trims **[inferred]** |
| `+780 + 4v`, `+782 + 4v` | filter cutoff × the voice's two calibration coefficients (`0x419c9f14 + 8v`, `+4`) | measured |
| `+812 + 4v` | filter cutoff × 0.45 | measured |
| `+814 + 4v` | the result of `0x40121888`, per voice | measured; not named |
| `+844..+891` | 16 bytes each for the BD, SD and RS circuits (`+844`, `+860`, `+876`); defaults, calibration, and writes by some BD/SD machines (BD TEST holds `+844..+850` at `0x4000, 0`) | partial |
| `+892..+983` | defaults and calibration only, as `+664..+779` (the hats' MIN/MAX pairs at `+928..+946` are in here) | trims **[inferred]** except `+928..+946` |

`+608..+615` is the 56th segment slot. No writer was found for it or for the
six slots before it.

### Switch bits `+160..+167`

Set and cleared by bit number from per-voice tables. What is named:

- **BD, SD, RS circuits**: seven bits each from `0x401f5f6c` (voice 0),
  `0x401f5f50` (voice 2), `0x401f5f34` (voice 7), as (byte, bit) from `+160`.
  BD TEST names them by table entry: 0 the bit it sets on its first call and
  clears after (`+161` bit 4 for voice 0: a trig **[inferred]**), 1 WF1, 2, 3
  and 6 WF2, 4 FM enable, 5 ring-mod enable. SD and RS TEST drive their
  voices' bits Gray-coded as WAV (SAW1 SAW2 SINE2) and FRO (FM RM OFS).
- **Filter type**: sound index 32 (clamped to 6) through `0x401ef188` to a
  3-bit code, placed at the voice's position from `0x401ef180[v]`: bits 1..3
  or 5..7 of a byte from `+160` (`0x4010d14c`).
- **BT**: `+165` bit 3 (BIT).
- **Master**: `0x4010e1a0` sets bits in `+162` and `+165` **[inferred:
  compressor ratio or SEQ]**.

### Segment slots `+168..+615`

Each slot is a rate word and a level word (envelopes.md); the hardware ramps a
level towards the target at the rate.

| slots | offset | use |
|---|---|---|
| 8 | `+168 + 8v` | amp envelope |
| 8 | `+232 + 8v` | amp envelope, the same commands again |
| 8 | `+296 + 8v` | filter envelope |
| 4 | `+360` | BD circuit's own envelopes |
| 4 | `+392` | SD circuit's |
| 4 | `+424` | RS circuit's |
| 5 | `+456` | hats: one per output (`+456..+480`), and `+488` |
| 8 | `+496` | cymbal/cowbell |
| 7 | `+560..+615` | no writer found |

The TEST machines hold their voice's circuit slots open; the stock machines
drive them per trig.

## Per voice

| voice | circuit | circuit controls | circuit envelopes |
|---|---|---|---|
| 0, 2, 7 (BD, SD, RS/CP) | two oscillators | tune and level each, 1 + 3 waveform bits, FM, ring mod, a trig bit; RS adds RS1, RS2 | 4 each |
| 1, 3, 5 (BT, LT, MT/HT) | one | pitch, decay; BT one switch bit | none; their pulse arrives as a digital stream (machines.md) |
| 4 (CH/OH) | six-oscillator bank | tune, bank frequencies, four output levels, VCA | 5 |
| 6 (CY/CB) | six-oscillator bank | tune, bank frequencies, five envelope CVs (cymbal), two amounts (cowbell), VCA | 8 |

Every voice, beyond its circuit: VCA left and right, overdrive, the filter
(frequency and resonance words, type bits, cutoff and its calibrated pair),
its amp and filter envelopes, and a digital input stream (samples, noise, a
machine's own waveform).

## Open

- **Physical units.** The mapping from words to Hz, volts or dB is unmeasured.
- The 22-bit oscillator words, and `+814`'s function `0x40121888`.
- The trim regions `+664..+779`, `+892..+983` and most of `+844..+891`.
- Per-bit meanings beyond the TEST names, and the master section's bits.
- The seven unused segment slots.
- How the map was built: a register-tracking scan of the writers (all 53
  machines, both envelope builders, the master writer, the trig reset, the
  initialisers) that ignores branches, so per-voice paths show only the last
  one; every row above was then read by hand. A voice-specific write the scan
  missed would not appear.
