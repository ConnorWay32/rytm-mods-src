        | Mod 0015 - ENV RESET AMP: the amp envelope restarts from silence on
        | every trig.
        |
        | The amp envelope runs in the voice hardware, fed segment commands by
        | 0x401098d4: on a trig (state 0) an attack command, rate word
        | 0xB0000000 | atk[ATK] with level word 0x4000007f, and from the next
        | interrupt the hold states resend the attack with nibble 0x3, which
        | ramps from wherever the level is. So a trig on a sounding voice
        | continues from its current level.
        |
        | With the amp bit of the track's ENV RESET set, state 0 sends stock's
        | decay form at DEC 0 instead - rate 0xB0100000, level 0x80 - which takes
        | the level to -128 at once; the hold states then ramp it up from silence
        | at the ATK rate. Verified on hardware 2026-09-29 through the probe below.
        |
        | Rate word bit 30, which stock sets for ENV RESET FILTER, resets the
        | level to 0 - the filter envelope's neutral point, but half gain on the
        | amp - so it is not used here.

        .equ    ATTACK_RESUME,  0x40109b0a        | state 0 past the oril
        .equ    VOICE_TRACK,    0x40290dd8        | voice -> track, bytes
        .equ    ENV_RESET,      0x8000ea30        | per track, the sound's +0x6c
        .equ    ENV_RESET_AMP,  0                 | bit 0 amp, bit 1 filter
        .equ    DROP_RATE,      0xb0100000        | decay form, coefficient 0
        .equ    DROP_LEVEL,     0x00000080        | to -128

        .text

        | ------------------------------------------------------------------
        | amp_attack: over `oril #0xb0000000,%d0` in state 0.
        |
        | d0 the rate word, d2 the level word (0x4000007f), d3 the voice, a4 the
        | track's slice of the effective array from AMP ATK. d1 and d4 are live;
        | d5, d6 and a0 are written before they are read on every pass of the
        | voice loop, so they are free.
        | ------------------------------------------------------------------
        .align  2
amp_attack:
        ori.l   #0xb0000000,%d0                   | displaced

.if P_BIT_PROBE
        | Bit probe, the experiment that found the drop. AMP OVR selects, and a
        | registry patch silences the overdrive:
        |   OVR 0        stock
        |   OVR 1..32    flip rate word bit OVR-1   (0..19 are the coefficient)
        |   OVR 33..64   flip level word bit OVR-33 (0..7 are the target)
        |   OVR 65..67   rate bit 30 set, level 0x40000080 / 0x80 / 0
        |   OVR 68       the drop
        |   OVR 69..127  stock
        | Results, 2026-09-28/29: no single bit restarted the attack. Rate bit
        | 30 alone restarts it from half gain (-6.3 dB), whatever the level word
        | says (65..67 alike). 68 restarts it from silence.
        mvz.b   6(%a4),%d5                        | OVR, 0..127
        subq.l  #1,%d5
        bmi.s   9f                                | 0: stock
        moveq   #31,%d6
        cmp.l   %d6,%d5
        bgt.s   1f
        moveq   #1,%d6
        lsl.l   %d5,%d6
        eor.l   %d6,%d0                           | a rate word bit
        bra.s   9f
1:      moveq   #32,%d6
        sub.l   %d6,%d5
        moveq   #31,%d6
        cmp.l   %d6,%d5
        bgt.s   2f
        moveq   #1,%d6
        lsl.l   %d5,%d6
        eor.l   %d6,%d2                           | a level word bit
        bra.s   9f
2:      sub.l   #32,%d5                           | 0..3 for OVR 65..68
        moveq   #3,%d6
        cmp.l   %d6,%d5
        bhi.s   9f                                | 69..127: stock
        beq.s   3f                                | 68
        bset    #30,%d0
        move.l  #0x40000080,%d2
        tst.l   %d5
        beq.s   9f                                | 65
        move.l  #0x00000080,%d2
        subq.l  #1,%d5
        beq.s   9f                                | 66
        moveq   #0,%d2                            | 67
        bra.s   9f
3:      move.l  #DROP_RATE,%d0
        move.l  #DROP_LEVEL,%d2
.else
        lea     VOICE_TRACK,%a0
        mvz.b   (%a0,%d3.l),%d5                   | the voice's track
        lea     ENV_RESET,%a0
        mvz.b   (%a0,%d5.l),%d6
        btst    #ENV_RESET_AMP,%d6
        beq.s   9f                                | continue from the current level
        move.l  #DROP_RATE,%d0                    | to silence; the hold states ramp up
        move.l  #DROP_LEVEL,%d2
.endif
9:      jmp     ATTACK_RESUME
