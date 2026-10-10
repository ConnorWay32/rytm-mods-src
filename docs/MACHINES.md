# Machine guide

How each machine on the Analog Rytm MKII makes its sound, and what each of its
SRC parameters does to the synthesis engine. It covers the 33 machines in the
stock OS 1.73 machine list.

This guide was written from the firmware, not from measurements. It says which
part of the engine each parameter controls and how, but not exact values in Hz,
dB or milliseconds. Statements marked *(inferred)* follow from how the firmware
uses a control but have not been confirmed by listening or measurement. The
register-level detail behind this guide is in `re/subsystems/machines.md`.

## The voice

Every track plays through one of eight analog voices. A voice has two parts.

**The sound generator** is what the machine controls. It differs from voice to
voice: some have two VCOs, some a tuned resonator, some a bank of six
oscillators. Alongside it, every voice has a **digital input**: a stream from
the processor that is mixed into the voice before the filter. Machines use it
for noise, clicks, short recorded transients and, on a few machines, the whole
sound.

**The voice channel** follows the generator and is the same for every machine:
the overdrive, the multimode VCF with its own envelope (FILTER page), and the
VCA with the amp envelope, pan and level (AMP page). The machine's own
envelopes, described below, shape the sound before it reaches this channel. A
short DEC on the machine therefore cuts the sound even if the amp envelope is
long.

```
             +-------------------------+
 machine --> | sound generator         |--+
 (SRC)       | VCOs, envelopes, VCAs   |  |
             +-------------------------+  +--> overdrive --> VCF --> VCA --> pan
             | digital input           |--+                  ^       ^
             | noise, clicks, samples  |                     |       |
             +-------------------------+                  filter    amp
                                                         envelope  envelope
```

| voice | tracks | sound generator |
|---|---|---|
| 1 | BD | two-VCO circuit |
| 2 | BT | tuned resonator |
| 3 | SD | two-VCO circuit |
| 4 | LT | tuned resonator |
| 5 | CH, OH | six-oscillator bank, four outputs |
| 6 | MT, HT | tuned resonator |
| 7 | CY, CB | six-oscillator bank, eight envelopes |
| 8 | RS, CP | two-VCO circuit with a symmetry control |

A machine can run on any voice that has its generator. This is why the BD and
SD machines are offered on the BD, SD and RS/CP tracks: those three voices
share the two-VCO circuit.

## Conventions

These hold for every machine unless its section says otherwise.

- **LEV** sets the generator's output level. The value is squared before it
  reaches the VCA, so the control has an audio taper: halving LEV lowers the
  level by about 12 dB.
- **TUN** is in semitones, with fine steps between them. Where TUN is shown
  bipolar it spans ±32 semitones around the track's base pitch. Pitch is
  computed digitally and sent to the oscillators as a control voltage, so
  keyboard tracking and pitch locks follow TUN exactly.
- **Machine envelopes** are hardware envelope generators inside the sound
  generator. On a trig each one jumps to a start level and moves towards a
  target at a set rate. A hold stage keeps the level up for a time before the
  decay starts.
- **DEC** at 127 means no decay (infinite) on the SY machines, HH LAB and
  UT NOISE.
- **Noise** comes from the digital input. It is generated, filtered by a
  digital resonant filter whose setting is fixed per machine unless a
  parameter is given for it, and faded out by its own decay.
- **Clicks** (TIC and similar) are short digital transients added at the start
  of the note. Their level follows LEV as well as their own control.

## Two-VCO circuit (BD, SD, RS/CP tracks)

The circuit has two VCOs. Each has:

- a frequency control voltage
- a level control
- a waveform selector: one bit on VCO 1, several shapes on VCO 2
- a pitch envelope generator
- an amplitude envelope generator driving its own VCA

There are two switches between the VCOs. One routes VCO 2 into VCO 1's
frequency as audio-rate FM, with VCO 2's level setting the modulation index. The
other is labelled ring modulation in the firmware's test machine; what it does
on the bass drum machines is not established. The RS/CP voice adds a symmetry
control (SYM) that changes the oscillator wave shape.

Most BD machines use only one VCO as the audible oscillator. The other is
silent, acts as an FM modulator, or produces a click.

### BD HARD

A single VCO with a pitch snap and a hold-then-decay amplitude
envelope. VCO 2 is the audible oscillator; VCO 1 is tuned a fifth above it but
its level is zero.

| parameter | drives | effect |
|---|---|---|
| LEV | VCO 2 level | output level |
| TUN | both VCO frequencies | pitch |
| DEC | amplitude envelope, decay rate | length of the tail |
| HLD | amplitude envelope, hold time | how long the drum stays up before decaying. The envelope peaks at the trig and settles to a lower level for the hold *(inferred)* |
| SWT | pitch envelope, fall time | how quickly the pitch drops from the initial snap to the tuned pitch |
| SNP | pitch envelope, start level | depth of the initial pitch snap |
| WAV | VCO 2 waveform | one of three wave shapes |
| TIC | digital click | level of a two-sample click at the start of the note |

A small amount of filtered noise, scaled by LEV, is mixed in from the digital
input.

### BD CLASSIC

The same circuit and tuning as BD HARD, with a sweep depth control and a choice
of transients instead of SNP and TIC.

| parameter | drives | effect |
|---|---|---|
| LEV | VCO 2 level | output level |
| TUN | both VCO frequencies | pitch |
| DEC | amplitude envelope, decay | length of the tail |
| HLD | amplitude envelope, hold | time at full level before the decay |
| SWT | pitch envelope, fall time | sweep time |
| SWD | pitch envelope, start level | sweep depth; the value is squared, so the low half of the range is subtle |
| WAV | VCO 2 waveform | one of three wave shapes |
| TRA | digital transient | selects one of 56 attack transients, each a combination of click level, noise level and noise filter colour |

### BD FM

Two-operator FM. VCO 1 is the carrier and VCO 2 the modulator, with the FM
switch on.

| parameter | drives | effect |
|---|---|---|
| LEV | carrier level | output level |
| TUN | carrier frequency | pitch |
| DEC | carrier amplitude envelope | length of the tail, after a short fixed initial punch |
| FMA | modulator level | FM amount (modulation index); higher values add brighter, more inharmonic partials |
| SWT | carrier pitch envelope, fall time | pitch sweep time of the drum |
| FMS | modulator pitch envelope, fall time | pitch sweep time of the modulator, which moves the FM timbre |
| FMD | modulator amplitude envelope | FM decay: how quickly the FM brightness fades, leaving the plain carrier |
| FMT | modulator frequency | FM tune; at equal settings the modulator sits an octave above the carrier |

### BD PLASTIC

Both VCOs at the same pitch, with VCO 2 frequency-modulating VCO 1. The
modulation does not decay, so the FM character stays through the whole note.

| parameter | drives | effect |
|---|---|---|
| LEV | VCO 1 level | output level |
| TUN | both VCO frequencies | pitch |
| DEC | VCO 1 amplitude envelope | tail length, after a short fixed hold |
| TYP | modulation switches | two types: FM with the ring-modulation switch on, or FM alone |
| MOD | VCO 2 level | modulation amount (squared) |
| SWT | pitch envelopes of both VCOs, fall time | sweep time |
| SWD | pitch envelopes of both VCOs, start level | sweep depth |
| TIC | digital click | level of a short shaped click |

### BD SILKY

One VCO, and an analog click made by the second VCO.

| parameter | drives | effect |
|---|---|---|
| LEV | VCO 1 level | output level |
| TUN | VCO 1 frequency | pitch |
| DEC | VCO 1 amplitude envelope, decay | tail length |
| HLD | VCO 1 amplitude envelope, hold | time at full level before the decay |
| SWT | VCO 1 pitch envelope, fall time | sweep time |
| SWD | VCO 1 pitch envelope, start level | sweep depth |
| DUS | digital noise level | "dust": a noise layer whose level follows LEV and whose decay follows DEC |
| CLK | VCO 2 level | click: VCO 2 is held at zero frequency and gated by a very fast envelope, giving an analog click at the start of the note |

### BD SHARP

A single VCO with a choice of twelve waveforms and a recorded transient.

| parameter | drives | effect |
|---|---|---|
| LEV | level of the selected VCO | output level |
| TUN | VCO frequency | pitch |
| DEC | amplitude envelope, decay | tail length |
| HLD | amplitude envelope, hold | time at full level before the decay |
| SWT | pitch envelope, fall time | sweep time |
| SWD | pitch envelope, start level | sweep depth |
| WAV | VCO selection and waveform | twelve choices: five VCO 2 shapes and one VCO 1 shape, each in an A and a B version. The A versions restart the oscillator in step with the trig, so every hit starts the same way; the B versions let it run freely *(inferred)* |
| TIC | digital transient | level of a short recorded attack transient |

### BD ACOUSTIC

Built like BD SHARP, with a longer recorded impulse in place of the tick.

| parameter | drives | effect |
|---|---|---|
| LEV | level of the selected VCO | output level |
| TUN | VCO frequency | pitch |
| DEC | amplitude envelope, decay | tail length |
| HLD | amplitude envelope, hold | time at full level before the decay |
| SWT | pitch envelope, fall time | sweep time |
| SWD | pitch envelope, start level | sweep depth |
| WAV | VCO selection and waveform | twelve choices, as BD SHARP |
| IMP | digital sample | level of a recorded beater impulse layered over the start of the note |

### SD HARD

Two VCOs a fifth apart (3:2), both swept, with a noise layer.

| parameter | drives | effect |
|---|---|---|
| LEV | both VCO levels | output level; VCO 2 is three times louder than VCO 1 |
| TUN | both VCO frequencies | pitch |
| DEC | both amplitude envelopes | body decay; VCO 1 decays slightly faster |
| SWD | both pitch envelopes, start level | sweep depth |
| TIC | digital click | attack click level |
| NOD | digital noise decay | length of the noise; the noise fades linearly |
| NOL | digital noise level | snare noise level |
| SWT | both pitch envelopes, fall time | sweep time |

### SD CLASSIC

Two VCOs at a variable interval, with a fixed snap and a noise layer.

| parameter | drives | effect |
|---|---|---|
| LEV | both VCO levels | output level |
| TUN | VCO 1 frequency, and VCO 2 through DET | pitch |
| DEC | both amplitude envelopes | body decay; VCO 2 decays faster than VCO 1 |
| DET | VCO 2 frequency offset | interval between the two VCOs, in semitones |
| SNP | both pitch envelopes, start level | depth of a fast fixed pitch snap |
| NOD | digital noise decay | length of the noise; the noise fades exponentially |
| NOL | digital noise level | snare noise level |
| BAL | VCO levels | crossfade between VCO 1 and VCO 2 |

### SD FM

Two-operator FM snare with a noise layer.

| parameter | drives | effect |
|---|---|---|
| LEV | carrier level | output level |
| TUN | carrier frequency | pitch |
| DEC | carrier amplitude envelope | body decay |
| FMT | modulator frequency | FM tune |
| FMD | modulator amplitude envelope | FM decay |
| NOD | digital noise decay | length of the noise |
| NOL | digital noise level | noise level |
| FMA | modulator level | FM amount |

A short fixed pitch blip is applied to both VCOs at the start of each note.

### SD ACOUSTIC

Two VCOs a fifth apart (7 semitones), a noise layer and a recorded impulse.

| parameter | drives | effect |
|---|---|---|
| LEV | both VCO levels | output level; VCO 2 is set well below VCO 1 |
| TUN | both VCO frequencies | pitch |
| BDY | both amplitude envelopes, decay | body decay |
| NOD | digital noise decay | length of the snare noise |
| NOL | digital noise level | snare noise level |
| HLD | both amplitude envelopes, hold | time at full level before the body decays |
| SWD | both pitch envelopes, start level | sweep depth; the sweep time is fixed and short |
| IMP | digital sample | level of a recorded stick impulse |

### SD NATURAL

One VCO for the drum body and a noise layer with its own filter.

| parameter | drives | effect |
|---|---|---|
| LEV | body and noise levels | output level |
| TUN | VCO frequency | body pitch |
| BDY | VCO amplitude envelope, decay | body decay |
| DEC | digital noise decay | length of the noise |
| BAL | body and noise levels | balance between body and noise |
| LPF | noise filter, low-pass cutoff | brightness of the noise |
| HPF | noise filter, high-pass cutoff | thinness of the noise |
| RES | noise filter, resonance | resonant peak in the noise |

The noise filter is digital and separate from the voice's VCF. A short fixed
attack click is added.

### RS HARD

Two VCOs at a fixed inharmonic ratio of about 3.7:1, close to the TR-808 rim
shot *(inferred)*.

| parameter | drives | effect |
|---|---|---|
| LEV | both VCO levels | output level; the lower VCO is three times louder |
| TUN | both VCO frequencies | pitch |
| DEC | both amplitude envelopes | decay |
| SWD | both pitch envelopes, start level | sweep depth |
| TIC | digital click | attack click level |
| NOL | digital noise level | noise level; the noise decay is fixed |
| SYM | waveform symmetry | changes the oscillator wave shape |
| SWT | both pitch envelopes, fall time | sweep time |

### RS CLASSIC

Two independently tuned VCOs with no pitch envelope.

| parameter | drives | effect |
|---|---|---|
| LEV | both VCO levels | output level |
| T1 | lower VCO frequency | tune of the lower oscillator |
| DEC | both amplitude envelopes | decay |
| BAL | VCO levels | crossfade between the two VCOs |
| T2 | upper VCO frequency | tune of the upper oscillator |
| SYM | waveform symmetry | changes the oscillator wave shape |
| NOL | digital noise level | noise level; the noise decay is fixed |
| TIC | digital click | attack click level |

### SY DUAL VCO

A general two-VCO voice with independent decays and selectable modulation.

| parameter | drives | effect |
|---|---|---|
| LEV | VCO levels | output level |
| TUN | both VCO frequencies | pitch |
| DEC (first) | VCO 1 amplitude envelope | VCO 1 decay; 127 holds |
| DET | VCO 2 frequency offset | interval of VCO 2 above or below VCO 1 |
| DEC (second) | VCO 2 amplitude envelope | VCO 2 decay; 127 holds |
| BAL | VCO levels | crossfade between the VCOs; in FM configurations, the FM amount |
| BND | pitch offset at the trig | a pitch bend that starts at the set offset and glides back to the tuned pitch |
| CFG | waveforms and switches | 80 configurations: VCO 1 waveform × VCO 2 waveform × plain mix, ring modulation or FM, each with and without oscillator restart on the trig |

### SY RAW

Two VCOs with independent waveform choice and a noise layer.

| parameter | drives | effect |
|---|---|---|
| LEV | VCO levels | output level |
| TUNE | both VCO frequencies | pitch |
| DEC2 | both amplitude envelopes | decay; 127 holds |
| DET | VCO 1 frequency offset | detune of VCO 1 against VCO 2 |
| NLEV | digital noise level | noise level |
| WAV1 | VCO 1 waveform | four shapes |
| WAV2 | VCO 2 waveform | seven choices |
| BAL | VCO levels | crossfade between the VCOs |

### SY CHIP

An arpeggiating voice in the style of 8-bit sound chips. Each step of the
arpeggio can use a VCO or a digitally generated chip waveform.

| parameter | drives | effect |
|---|---|---|
| LEV | output level | level |
| TUN | base pitch | pitch of the first step |
| DEC | amplitude envelopes | decay; 127 holds |
| OF2 | pitch of step 2 | offset in semitones |
| OF3 | pitch of step 3 | offset in semitones |
| OF4 | pitch of step 4 | offset in semitones |
| WAV | step program | 30 programs. Each sets the number of steps, whether the pattern loops, and per step the sound source: a VCO waveform, a digital pulse wave (some with pulse-width sweeps), or digital "periodic" noise of the kind used for chip percussion. Some programs start with a short noise burst |
| SPD | step rate | arpeggio speed; the lower values are synced to the tempo |

## Tuned resonator (BT, LT, MT/HT tracks)

These voices have no oscillator. The sound generator is a resonant circuit
that rings at its tuned frequency when struck, like the tom circuits of
classic drum machines. Each strike is a short pulse sent from the processor.

The circuit has two controls: frequency and damping. Damping sets how long the
ring lasts, so the decay comes from the resonator itself rather than from an
envelope. The firmware adjusts the damping as the pitch changes, so a given DEC
value gives a similar decay length at any tuning *(inferred)*. Each voice's
frequency and damping are calibrated individually.

### BT CLASSIC

| parameter | drives | effect |
|---|---|---|
| LEV | strike pulse level | output level |
| TUN | resonator frequency | pitch, over about ±16 semitones (half the usual range) |
| DEC | resonator damping | ring length |
| NOL | digital noise level | noise layer with a fixed short decay |
| SNP | damping switch, timed | snap: for a short time after the strike, the resonator is switched to a different state, giving a sharper attack. The time is shorter at higher pitches |
| SWD | resonator frequency, decaying offset | pitch sweep depth; the sweep falls back to the tuned pitch at a fixed rate |

### XT CLASSIC

The tom machine for the LT, MT and HT tracks.

| parameter | drives | effect |
|---|---|---|
| LEV | strike pulse level | output level |
| TUN | resonator frequency | pitch, over about ±2.7 octaves |
| DEC | resonator damping | ring length |
| SWD | resonator frequency, decaying offset | pitch sweep depth |
| SWT | sweep rate | sweep time |
| NOD | digital noise decay | length of the noise |
| NOL | digital noise level | noise level |
| TON | noise filter | colour of the noise; the filter follows TUN, so the noise stays in tune with the drum |

Very long notes are damped gradually after about three seconds, and their
pitch drifts after about six.

## Hi-hat bank (CH, OH tracks)

A bank of six oscillators tuned to a fixed set of inharmonic
ratios. TUN moves the whole bank together. The firmware sets each oscillator's
frequency and pulse settings digitally, which suggests the oscillators
themselves are digital *(inferred)*; everything after them is analog.

The bank feeds four output paths, each with its own VCA and envelope, plus an
envelope shared by all paths. Each machine plays through one path and closes
the others. A colour control (COL or TON) shapes the bank's tone in the
circuit.

| machine | path | oscillator ratios |
|---|---|---|
| CH CLASSIC, OH CLASSIC | C (CH), D (OH) | the ratios of the TR-808's six oscillators (205, 304, 370, 523, 540 and 800 Hz) |
| CH METALLIC, OH METALLIC | A | a wider, more inharmonic set, in a second bank mode |
| HH BASIC, HH LAB | B | HH BASIC has its own set; HH LAB lets you set all six |

### CH CLASSIC

| parameter | drives | effect |
|---|---|---|
| LEV | hat VCA | output level |
| TUN | oscillator bank frequency | pitch of the whole bank |
| DEC | path and shared envelopes, decay | decay, after a short fixed initial drop |
| COL | colour control | tone of the bank |

### OH CLASSIC

| parameter | drives | effect |
|---|---|---|
| LEV | hat VCA | output level |
| TUN | oscillator bank frequency | pitch |
| DEC | path and shared envelopes, decay | decay |
| COL | colour control | tone |

### CH METALLIC

| parameter | drives | effect |
|---|---|---|
| LEV | hat VCA | output level |
| TUN | oscillator bank frequency | pitch |
| DEC | path and shared envelopes, decay | decay |

### OH METALLIC

| parameter | drives | effect |
|---|---|---|
| LEV | hat VCA | output level |
| TUN | oscillator bank frequency | pitch |
| DEC | path and shared envelopes, decay | decay, after a fixed opening segment |

### HH BASIC

| parameter | drives | effect |
|---|---|---|
| LEV | hat VCA | output level |
| TUN | oscillator bank frequency | pitch |
| DEC | path and shared envelopes, decay | body decay |
| TON | colour control | tone |
| TRD | path envelope, first stage | transient decay: length of the initial attack portion |
| RST | oscillator restart | when on, the oscillators restart on every trig, so every hit sounds the same |
| NOL | digital noise level | noise layer |
| NOD | digital noise decay | length of the noise; 127 holds |

A fixed short click is also added.

### HH LAB

A hat whose six oscillator frequencies you set directly.

| parameter | drives | effect |
|---|---|---|
| LEV | hat VCA | output level |
| OSC1 to OSC6 | one oscillator each | frequency of that oscillator |
| DEC | path and shared envelopes, decay | decay; 127 holds |

## Cymbal and cowbell bank (CY, CB tracks)

The same kind of six-oscillator bank as the hats, followed by several
envelope-controlled paths and a master envelope shared by all machines on this
voice. The cymbal machines use the paths as separate frequency bands with their
own decays. The cowbell machines use only two oscillators, as pulse waves with
adjustable width.

### CY CLASSIC

TR-808 ratios through three band paths. Two bands decay quickly at fixed rates;
the third carries the long tail.

| parameter | drives | effect |
|---|---|---|
| LEV | cymbal VCA | output level |
| TUN | oscillator bank frequency | pitch |
| DEC | tail band and master envelopes | length of the tail; the short bands are unaffected |
| COL | colour control | tone |
| TON | band levels | balance between the low and high bands |

### CY METALLIC

A metallic bank through two paths: an attack transient and a body.

| parameter | drives | effect |
|---|---|---|
| LEV | cymbal VCA and click | output level and the level of a digital click |
| TUN | oscillator bank frequency | pitch |
| DEC | body envelope | body decay |
| TON | path levels | balance between transient and body |
| TRD | transient envelope | transient decay |

### CY RIDE

A ride cymbal with a choice of banks and three separately set bands.

| parameter | drives | effect |
|---|---|---|
| LEV | cymbal VCA and click | output level, and a short shaped digital click |
| TUN | oscillator bank frequency | pitch |
| DEC | band 2 and 3 envelopes, master envelope | decay of the body |
| TYP | bank selection | four types: 808 ratios, the HH BASIC set, and the metallic set in two bank modes |
| HIT | band 1 envelope | decay of the hit (attack) band |
| C1 | band 1 level | level of the hit band |
| C2 | band 2 level | level of the second band |
| C3 | band 3 level | level of the third band |

The oscillators restart on every trig.

### CB CLASSIC

Two pulse-wave oscillators, like the TR-808 cowbell, with a two-stage
envelope.

| parameter | drives | effect |
|---|---|---|
| LEV | cowbell VCA | output level |
| TUN | oscillator 1 frequency, and oscillator 2 through DET | pitch |
| DEC | envelope, second stage | tail length, after a fixed short first stage |
| DET | oscillator 2 frequency offset | interval between the two oscillators, in quarter semitones |
| PW1 | oscillator 1 pulse width | timbre of oscillator 1 |
| PW2 | oscillator 2 pulse width | timbre of oscillator 2 |

### CB METALLIC

As CB CLASSIC through a different path, with TUN at half range and DET in whole
semitones.

| parameter | drives | effect |
|---|---|---|
| LEV | cowbell VCA | output level |
| TUN | oscillator 1 frequency, and oscillator 2 through DET | pitch, over half the usual range |
| DEC | envelope, second stage | tail length |
| DET | oscillator 2 frequency offset | interval in semitones |
| PW1 | oscillator 1 pulse width | timbre of oscillator 1 |
| PW2 | oscillator 2 pulse width | timbre of oscillator 2 |

## Digital machines

These machines make their whole sound on the digital input and mute the
voice's sound generator. They still pass through the voice's overdrive, VCF
and VCA, so the FILTER and AMP pages shape them as usual.

### CP CLASSIC

A hand clap made from bursts of filtered noise followed by a reverberant tail.
CP CLASSIC runs on the RS/CP voice only.

| parameter | drives | effect |
|---|---|---|
| LEV | burst and tail levels | output level |
| TON | noise filter | tone of the clap |
| NOD | tail decay | length of the tail |
| NUM | burst count | number of claps before the tail |
| RAT | burst spacing | time between claps |
| NOL | tail level | level of the tail |
| RND | burst timing | random variation in the spacing |
| CPD | burst decay | length of each clap |

### UT NOISE

A noise generator with a digital filter and envelope, available on every track.

| parameter | drives | effect |
|---|---|---|
| LEV | noise level | output level |
| LPF | digital low-pass cutoff | brightness |
| DEC | noise envelope, decay | decay; 127 holds |
| HPF | digital high-pass cutoff | thinness |
| LPQ | digital low-pass resonance | resonant peak |
| ATK | noise envelope, attack | attack time |
| SWT | low-pass sweep, time | how quickly the cutoff sweep returns to LPF |
| SWD | low-pass sweep, depth | bipolar cutoff sweep amount at the start of the note |

### UT IMPULSE

A single shaped pulse, available on every track. Used on its own it is a
click; sent into the VCF with high resonance, it makes the filter ring at its
cutoff frequency, turning the filter into a tuned percussion voice.

| parameter | drives | effect |
|---|---|---|
| LEV | pulse height | output level |
| ATK | pulse rise | rise time; the pulse rises in a straight line |
| DEC | pulse fall | fall time; the pulse falls exponentially |
| POL | pulse polarity | positive or negative pulse |

In OS 1.73 the firmware does not read UT IMPULSE's HLD, SHP, REP and NUM
parameters.
