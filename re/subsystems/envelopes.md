# Envelopes and ENV RESET

How the filter and amp envelopes are driven on the analog voices, and how
SOUND SETTINGS' ENV RESET reaches them. Traced 2026-09-28/29 for mod 0015 on
stock MKII 1.73. Tags: **[measured]** read from the image or recorded on the
device, **[inferred]** reasoned from them.

## Where the envelopes run

Both envelopes run in the voice hardware, not on the ColdFire **[measured]**.
Each interrupt the CPU sends each voice segment commands - a rate and a target -
and the hardware moves the level. There is no software envelope state that
could be reset directly.

## ENV RESET, from the menu to the engine

| step | where | what |
|---|---|---|
| storage | live sound `+0x6c` | 0..3: bit 0 amp, bit 1 filter; stored packed in the record's `+0x7d` (sound-storage.md) |
| labels | `0x401e8ecc` | OFF, AMP, FILTER, AMP+FILT, by value & 3 |
| menu | `0x400ef83a` | `set(get() + 2 * delta)`: stock steps OFF <-> FILTER only |
| setter | `0x400bcee4` | clamps 0..3, then masks with 2: the amp bit never survives |
| engine copy | sound push `0x4011f5d6` | `+0x68..+0x6c` to `0x8000ea00/0c/18/24/30[track]` |
| engine use | `0x4010d1f2` | `((v * 2) & 4) + 11` into the filter attack command's nibble |

So stock refuses the amp bit three times - the menu, the setter and the engine
**[measured]**. The labels suggest it once existed **[inferred]**.

## The segment command

Each command is two words **[measured]**:

    rate word:  [31:28 command] [27:24 counter] [23:20 flags] [19:0 coefficient]
    level word: [30 flag] ... [7:0 target, signed: 0x7f = +127, 0x80 = -128]

The coefficient is one-pole, 20 bits: 0 is instant, near 0xfffff slow.

## Filter envelope, `0x4010d090`

Per physical voice: owner track from `0x40290dd8`, the effective slice from sound
index 25 (`0x8000f7da + 84 * track`: depth, ATK, DEC, SUS, REL, frequency,
resonance, type), a six-state machine at `0x42fb49b4 + 32v` with a counter at
`0x42fb49b8 + 32v`, one command into the voice control block (`0x800063c0`) at
`+296 + 8v`. Every command has nibble 0xB except the trig's attack with ENV RESET
FILTER, which has 0xF: rate bit 30 **[measured]**.

## Amp envelope, `0x401098d4`

The same function writes the VCA gain and overdrive words (compressor-hardware.md).
Per physical voice: state at `0x41329b54 + 32v` (hold counter at `+4`), AMP
ATK/HLD/DEC from `0x8000f7ea + 84 * track`, and each state's command written to
`+168/+172` and again to `+232/+236` of the block **[measured]**.

| state | entered | rate word | level word |
|---|---|---|---|
| 0 | the trig (`0x8000e508[track] == 1`) | `0xB0000000 \| atk[ATK]` | `0x4000007f` |
| 1 | HLD 0, until note-off clears the voice's bit in `0x41329b50` | `0x30000000 \| atk[ATK]` | `0x7f` |
| 2 | HLD > 0, until the counter (+16 each interrupt) reaches `hld[HLD]` | `0x30000000 \| atk[ATK]` | `0x7f` |
| 3 | decay; DEC 127 sends nothing (INF) | `0xB0100000 \| dec[DEC]` | `0x80` |
| 4 | `0x8000e508[track] == 3` | `0xB01748FA` | `0x40000080` |

Tables, 128 longs each: decay `0x401ee36c`, hold `0x401ee56c`, attack
`0x401ee76c`. State 0 lasts one interrupt; the ramp to +127 is carried by states
1 and 2 resending the attack with command 0x3, which continues from the current
level. So a trig on a sounding voice does not restart the attack: it ramps on from
wherever the level is **[measured]** - the behaviour 0015 was made for.

## The probe, and what the bits do

0015's `bit_probe` build flipped one bit of state 0's two words, chosen by AMP OVR,
and added four combinations. Heard, and recorded on track 1's USB voice channel,
BD SILKY, ATK swept 0..127 **[measured]**:

- No single bit of either word restarted the attack. Only rate bit 30 changed
  anything.
- **Rate bit 30 resets the level to 0.** On the amp that is half gain: hits start
  6.3 dB down (-16.7 to -23.0 dBFS on the voice channel) and ramp up at the ATK
  rate, so at ATK above about 20 the kick is over before the ramp does anything.
  The level word makes no difference (0x40000080, 0x80 and 0 alike). On the
  filter, 0 is the neutral point, which is why the same bit serves ENV RESET
  FILTER **[inferred]**.
- **The decay form with coefficient 0** - rate `0xB0100000`, level `0x80` - takes
  the level to -128 at once, and states 1 and 2 then ramp it up from silence at
  the ATK rate. That is the amp restart; 0015 sends it on the trig for tracks
  with the amp bit.

Not established: rate bits 20..27 and 28/29/31, and level bits 8..31, did
nothing audible when flipped alone in state 0. They were only tested there,
where one interrupt later the next command overrides them, so bits that set up
a segment rather than act at once would not have shown.
