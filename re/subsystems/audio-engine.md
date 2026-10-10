# The audio engine

For current compressor-preview work, start with
[compressor-model.md](compressor-model.md). This file retains historical
architecture deductions; register observations are not a complete inventory of
available audio or telemetry paths.

> **2026-09-19 metering correction:** The assertions below that no audio comes
> back / no metering exists are not established by the register scan. The sampler
> reads level and likely peak-hold values from RAM, with a source list including
> MAIN. A pre-compressor tap and actual analog GR readback remain unidentified.
> See `compressor-hardware.md` for addresses and evidence.

> **The signal path is settled by the manual's architecture diagram, not by
> inference.** Two earlier conclusions in this file were wrong - first that the audio
> work is in the FPGA, then that it is all ColdFire DSP. The truth is a split path,
> below. The wrong reasoning is kept at the end because both errors are instructive.

## The signal path (from the manual's architecture diagram)

**Analog:** percussion sound generator, overdrive, multimode filter, amp, pan, and on
the FX track the **mixer, distortion and compressor**.

**Digital:** noise generator, sample playback engine, filter/amp envelopes, LFOs and
fade envelopes, delay send, reverb send, and the **delay and reverb** themselves.

So the eight drum voices are summed in the **analog** domain, and the master
compressor sits in that analog path. Delay and reverb are digital sends whose returns
are mixed back in analog.

### What that means for this project

- **The compressor is analog.** Parameter/control mapping changes do not by
  themselves rewire its physical detector. No selectable independent sidechain
  or direct VCA gain-reduction readback has been identified in this investigation;
  neither absence is proved by the register scan. CPU-visible audio buffers and
  sampler meter state do exist. A model-based preview therefore remains possible
  if its input can be acquired or reconstructed; see the current handover.
- **The delay and reverb are digital**, and live in the ColdFire EMAC code described
  below. Those are ordinary targets for a mod.
- Same for the sample playback engine, the noise generator, and every envelope and
  LFO.

## What is in the machine

The bootstrap's power-on self-test enumerates the hardware, one line per device:

    UI:(%c) %s          UI FIRMWARE: 1.%d.%d.%d
    DRAM:(%c) %s
    FPGA:(%c) %s        BAD FIRMWARE
    +DRIVE:(%c) %s
    AUDIO:(+)
    USB:(%c)

So: a ColdFire running MAIN OS, a separate UI board with its own firmware, DRAM, an
FPGA, the +Drive, and an audio device. **No DSP.** MAIN OS's strings mention `CODEC`
and `FPGA` and contain no occurrence of DSP, SHARC, ADSP or any codec part number, and
the container carries no DSP firmware - its five sections are meta, bootstrap
(ColdFire), FPGA bitstream, MAIN OS (ColdFire) and the ARM Outbox 8 blob.

The compressor is **analog** - see the architecture diagram at the top. An earlier
version of this note argued it must be digital because it has a `Dry/Wet Mix`
parameter and discrete ratios. Both are ordinary analog compressor features: switched
ratio networks and a parallel-blend VCA. That argument was worthless.

## Scanned register window: limited readback, not the whole audio interface

Absolute addresses MAIN OS touches, by 1 MB window:

| window | accesses | what |
|---|---|---|
| `0x41900000`, `0x41300000`, `0x41700000`, `0x42a00000`, `0x42f00000` | ~6000 | DRAM data |
| `0x80000000` | 1299 | SRAM |
| `0xfc000000` | 1064 | ColdFire IPSBAR, on-chip peripherals |
| `0xfff00000` | 553 | |
| **`0xec000000`** | **272** | **external device - see below** |

The `0xec` window holds 57 distinct byte-wide registers: a dense block at
`0xec09400c`..`0xec09406e`, plus `0xec090000` and a sparser 4-byte-stride block at
`0xec070000`/`0xec074000`.

Of those 57, MAIN OS ever **reads** three - `0xec090014`, `0xec094018`, `0xec09401d` -
each once or twice, and the only reader of `0xec094018` is this, in full:

```c
byte fpga_status_bit5(void) { return DAT_ec094018 & 0x20; }
```

A single status bit in this function. No level or gain-reduction register was
identified in this scan. The earlier conclusion that no audio or metering comes
back was false: later receive-buffer and sampler analysis found both. This
register-window observation cannot rule out other readback paths.

Audio parameters do not go through this window either - there are far too few
addresses for twelve tracks of voice parameters. They travel in shared DRAM: `trig_fire`
builds per-voice blocks around `0x42ac173c`..`0x42ac2aa0` and the engine consumes them.

## Routing

Per track, from `AudioRoutingMenuView`: **`ROUTE TO MAIN`** and **`SEND TO FX`**, two
independent toggles. Separately there are incoming USB audio destinations
`PRE-FX` / `POST-FX` / `SAMPLER ONLY`, a `TRACK ROUTING` menu, and a
`BreakOutBoxRoutingMenuView`. Those destination labels do not establish selectable
pre/post-compressor readback taps; see `compressor-hardware.md`.

`ROUTE TO MAIN` being independent of the individual outputs is the useful fact: a track
can leave the main sum and still appear on its own output.

## The compressor

**Historical string-table extraction, not a verified CC/value mapping.** Some
values below were associated with the wrong control. Use the measured MIDI
mapping in [compressor-hardware.md](compressor-hardware.md), not this table, to drive probes.

Master bus, parameters from the Overbridge name table at `0x402375da`:

| short | name | values seen |
|---|---|---|
| THR | Threshold | |
| ATK | Attack (ms) | `.03 .1 .2 .4 .6` … |
| REL | Release (s) | `7.5 15 30` … `480` |
| RAT | Comp. Ratio | `1:2 1:4 1:8` |
| MUP | Makeup Gain | |
| SEQ | Sidechain EQ | |
| MIX | Dry/Wet Mix | |

`SEQ` reweights the **detector's spectrum**. It does not decouple the detector from the
gain stage, so a kick that drives the compressor is still compressed by it. There is no
sidechain *source* select - the detector is the master sum, full stop.

## Sidechain, in and out of the box

Whatever is reachable in firmware, the stock routing already supports a proper external
sidechain: take BD to an individual output with `ROUTE TO MAIN` off, feed that to an
outboard compressor's key input, pass the main out through its audio path, and sum
afterwards. `ROUTE TO MAIN` being independent of the individual outputs is what makes
that work.

Doing it *internally* means changing the detector's input, which is now a question
about ColdFire code rather than about fabric - see below.


## Audio DSP runs on the ColdFire

MAIN OS contains **600 `macl` and 303 `msacl`** instructions - the ColdFire EMAC
multiply-accumulate unit - concentrated in roughly 128 KB around `0x40100000`
to `0x4011ffff`. They are not scattered arithmetic; they sit in block loops of
this shape, at `0x4010d7e0`:

```
lea     0x8000cc3c,%a3         | state and coefficients in SRAM
moveml  %a5@,%d3-%d5
lea     0x8000ca10,%a1
moveq   #32,%d0                | 32-sample block
macl    %d4,%d1,%a0@+,%d1      | MAC with post-increment
...
movel   %d6,%a1@+              | store output
subql   #1,%d0
```

Block-based sample processing out of SRAM at `0x8000xxxx`. So the audio engine, or a
large part of it, is **ordinary ColdFire code in MAIN OS** - readable and patchable
like anything else here.

Not yet established: which of it is the compressor. The way in is the seven
compressor parameters, which must be converted to coefficients and written into that
SRAM state somewhere.

## The FPGA is small, which was the clue

Section 1 is a Xilinx bitstream: 32 bytes of `0xFF`, sync `0xAA99`, then 16-bit
Type-1 packets with `0x2000` NOPs. A write to register `0x0E` - IDCODE - carries
**`0x02218093`**. Xilinx UG332 v1.7 Table 12-4 identifies it exactly: revision 0,
Spartan-3A family, **XC3S200A** array, Xilinx vendor suffix `0x093`.

That is a small device: about 3,600 logic cells, 16 multipliers, 288 Kbit of block
RAM. Nowhere near enough memory for this machine's reverb. It is glue - voice timing,
scanning, codec plumbing - not the FX engine, and noticing that should have overturned
the conclusion below immediately.

## What the earlier, wrong reasoning was

The bootstrap self-test lists UI, DRAM, FPGA, +Drive, audio, USB and no DSP; the
container holds no DSP firmware; MAIN OS mentions `CODEC` and `FPGA` and never `DSP`.
From that I concluded the audio work must be in the FPGA and therefore unreachable.

The error was searching for **names** rather than for **arithmetic**. A grep for
`macl` would have settled it in one command and was never run. The register-window
findings remain accurate - that interface really is control-only - but "parameters do
not go through this window" never implied the processing was elsewhere.

Then the correction overshot: having found real DSP on the ColdFire, this note
implied the compressor was part of it. It is not. The machine has a **split** path,
and the manual's block diagram says so in one picture.

The lesson across both: the owner's manual documented this the whole time. Two rounds
of inference from firmware internals produced two wrong answers to a question the
vendor had already published a diagram for. Check the documentation before deducing
the architecture.
