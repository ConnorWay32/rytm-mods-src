# MIDI CC map

The Analog Rytm MKII's MIDI CC assignments, from the manual's MIDI implementation
chart (appendix C), as supplied by the user on 2026-09-25. The same numbers mean
different things on different channels: the sound parameters (C.5) are received
on a track's channel, the effect parameters on the FX track's. Which channel the
trig, sequencer, kit and performance parameters (C.1-C.4) are received on is not
stated here.

Where the chart's NRPN column was supplied it is given as MSB/LSB; the rest were
not transcribed. The compressor's NRPNs are MSB 2, LSB 24-31
([compressor-hardware.md](compressor-hardware.md)).

The firmware's parameter table is not a source for these numbers: the half-word
at record `+0x28` looks like a CC block and is not one.

## C.1 Trig parameters

| Parameter | CC |
|---|---|
| Note | 3 |
| Velocity | 4 |
| Length | 5 |
| Synth Trig | 11 |
| Sample Trig | 12 |
| ENV Trig | 13 |
| LFO Trig | 14 |

## C.2 Euclidean sequencer

| Parameter | CC |
|---|---|
| Pulse Generator 1 | 86 |
| Pulse Generator 2 | 87 |
| Boolean Operator | 88 |
| Rotation Generator 1 | 89 |
| Rotation Generator 2 | 90 |
| Track Rotation | 91 |
| Euclidean on/off | 117 |

## C.3 Kit parameters

| Parameter | CC |
|---|---|
| Track Machine Type | 15 |
| Active Scene | 92 |
| Track Solo (sequencer mute) | 93 |
| Track Mute (sequencer mute) | 94 |
| Track Level | 95 |

## C.4 Performance parameters

| Parameter | CC | NRPN |
|---|---|---|
| Performance 1 | 35 | |
| Performance 2 | 36 | |
| Performance 3 | 37 | |
| Performance 4 | 39 | |
| Performance 5 | 40 | |
| Performance 6 | 41 | |
| Performance 7 | 42 | |
| Performance 8 | 43 | |
| Performance 9 | 44 | |
| Performance 10 | 45 | |
| Performance 11 | 46 | 0/10 |
| Performance 12 | 47 | 0/11 |

There is no CC 38 in the list: Performance 3 is 37 and Performance 4 is 39.

## C.5 Sound parameters, on a track's channel

| Parameter | CC | NRPN |
|---|---|---|
| Synth 1 .. 8 | 16 .. 23 | |
| Sample Tune | 24 | |
| Sample Fine Tune | 25 | |
| Sample Bit Reduction | 26 | |
| Sample Slot | 27 | |
| Sample Start | 28 | |
| Sample End | 29 | |
| Sample Loop | 30 | |
| Sample Level | 31 | |
| Filter Attack Time | 70 | |
| Filter Decay Time | 71 | |
| Filter Sustain Level | 72 | |
| Filter Release Time | 73 | |
| Filter Frequency | 74 | |
| Filter Resonance | 75 | |
| Filter Mode | 76 | |
| Filter Env Depth | 77 | |
| Amp Attack Time | 78 | 1/24 |
| Amp Hold Time | 79 | 1/25 |
| Amp Decay Time | 80 | |
| Amp Overdrive | 81 | |
| Amp Delay Send | 82 | |
| Amp Reverb Send | 83 | |
| Amp Pan | 10 | |
| Amp Volume | 7 | |
| LFO Speed | 102 | |
| LFO Multiplier | 103 | |
| LFO Fade In/Out | 104 | |
| LFO Destination | 105 | |
| LFO Waveform | 106 | |
| LFO Start Phase | 107 | |
| LFO Trig Mode | 108 | |
| LFO Depth | 109 | |

## Effect parameters, on the FX track's channel

| Parameter | CC |
|---|---|
| Delay Time | 16 |
| Delay Pingpong | 17 |
| Delay Stereo Width | 18 |
| Delay Feedback | 19 |
| Delay Highpass Filter | 20 |
| Delay Lowpass Filter | 21 |
| Delay Reverb Send | 22 |
| Delay Mix Volume | 23 |
| Reverb Predelay | 24 |
| Reverb Decay Time | 25 |
| Reverb Shelving Freq | 26 |
| Reverb Shelving Gain | 27 |
| Reverb Highpass Filter | 28 |
| Reverb Lowpass Filter | 29 |
| Reverb Mix Volume | 31 |
| Dist Amount | 70 |
| Dist Symmetry | 71 |
| Delay Overdrive | 72 |
| Delay Dist/Comp Routing (pre/post) | 76 |
| Reverb Dist/Comp Routing (pre/post) | 77 |
| Compressor Threshold | 78 |
| Compressor Attack Time | 79 |
| Compressor Release Time | 80 |
| Compressor Makeup Gain | 81 |
| Compressor Ratio | 82 |
| Compressor Sidechain EQ | 83 |
| Compressor Dry/Wet Mix | 84 |
| Compressor Output Volume | 85 |

The FX track has no Reverb CC 30 in the list.

## Notes

Measured on the device, 2026-09-25, with the sequencer stopped, on channel 1
(track 1's) and channel 14 (the auto channel) alike:

| Note | Plays |
|---|---|
| 0 .. 11 | tracks 1 .. 12, one note each, at the track's own pitch |
| 12 .. 59 | the selected track, chromatically |
| 60 and up | nothing |

So note t - 1 on the auto channel triggers track t whatever is selected. A CC on
a track's own channel does reach that track (Track Level on channel 2 silenced
track 2).

Transport, measured the same day:

- With CLOCK RECEIVE on, MIDI Start arms the sequencer (the play icon lights)
  but it waits for MIDI clock. Off, it starts at once.
- A program change on the auto channel switches pattern and loads its kit with
  the sequencer paused (2026-09-26); the kit takes a moment to change over, and
  Start 0.5 s after the change plays on the new kit from the first step. A
  2026-09-25 run recorded the kit staying unloaded while stopped; what differed
  is not known.
- MIDI Stop only pauses: voices sounding go on sounding. Further Stops, 100 ms
  apart, back to back or seconds later, do not stop fully (2026-09-26), unlike
  pressing STOP twice on the device. Start after a program change begins the
  new pattern from its top.
- CC 120 (All Sound Off), on any channel (1, 13 and 14 tried), silences the
  voices and the delay and reverb tails, as the double STOP does. Sent 0.25 s
  after a Stop, MAIN fell to -72 dB within 0.5-1 s and to the noise floor (-90)
  after 1 s, against -44.5 and -56 dB without it. The kit and its effects play
  as before afterwards. CC 123 (All Notes Off) and a second Stop change nothing
  (2026-09-27).
- Loading a kit resets its parameters, undoing CC changes sent before it: send
  CCs after the switch.

## Used by mod 0006's calibration

On the FX channel (`tools/comp/rig.py`): the compressor (78-85), Dist Amount and
Symmetry (70, 71), the delay and reverb mix volumes (23, 31) and routing (76,
77). On the tone track (`cal_tone.py`, TONE_SETUP): Filter Mode (76, 0 LP2, 1
LP1), Filter Env Depth and LFO Depth (77, 109, 64 for zero: the display runs
-64 to +63), Amp Attack and Hold (78, 79), the sends (82, 83), Filter Frequency
and Resonance (74, 75), Track Level (95) and Amp Pan (10). On the roll-call
tracks (`cal_io.py`): the sends (82, 83). Tracks are triggered by note t - 1 on
the auto channel.
