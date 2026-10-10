        | Mod 0008 - filter frequency in Hz.
        |
        | The FILTER page's FRQ popup reads as a frequency instead of 0..127. The
        | cutoff is one semitone a step with 440 Hz at 60,
        |   f = 440 * 2^((v - 60) / 12) = 13.75 * 2^(v / 12),
        | measured on the self-oscillating filter (LP2, resonance 127) at every 4th
        | value from 16 to 116: every step 1.000 +- 0.01 semitone, 60 at 440.7 Hz
        | (0006's sidechain sweep, session calsc_20260925_155438).
        |
        | Shown to three significant figures: 13.8Hz, 440Hz, 1.11kHz, 21.1kHz. Every
        | value 0..127 lands within 0.6% of the formula.

        .include "symbols.inc"

        .equ    PARAM_ID_FRQ,   47

        .text

        | ------------------------------------------------------------------
        | param_value_text, where it tail-calls the record's text formatter.
        |
        | Reached by a jmp over `lea %a2@(20),%a0; movel %d3,%sp@(32)`, after
        | stock's own check has accepted the value. d4 is the id, d2 the value in
        | 8.8, d3 the output buffer; the frame still holds d2-d4/a2-a3, so d2 and
        | d3 are free once read and the epilogue restores them.
        | ------------------------------------------------------------------
        .align  2
filter_hz_gate:
        moveq   #PARAM_ID_FRQ,%d0
        cmp.l   %d4,%d0
        beq.s   1f
        lea     %a2@(20),%a0                      | displaced
        move.l  %d3,%sp@(32)                      | displaced
        jmp     param_value_text_invoke_resume

1:      move.l  %d3,%a1                           | the output buffer
        move.l  %d2,%d0
        asr.l   #8,%d0                            | the integer part, as stock prints
        bpl.s   2f
        moveq   #0,%d0
2:      moveq   #127,%d1
        cmp.l   %d1,%d0
        ble.s   3f
        move.l  %d1,%d0
3:      divu.w  #12,%d0                           | low word octave, high word semitone
        move.l  %d0,%d1
        swap    %d1
        mvzw    %d1,%d1
        add.l   %d1,%d1
        lea     semitones,%a0
        mvzw    %a0@(0,%d1:l),%d1                 | 2^(k/12), Q15
        mulu.w  #1375,%d1                         | 13.75 Hz in centi-Hz
        mvzw    %d0,%d0
        moveq   #15,%d2
        sub.l   %d0,%d2                           | 15 - octave, 5..15
        moveq   #1,%d0
        lsl.l   %d2,%d0
        lsr.l   #1,%d0
        add.l   %d0,%d1
        lsr.l   %d2,%d1                           | F = f in centi-Hz, rounded

        lea     ranges,%a0
4:      cmp.l   (%a0),%d1
        bcs.s   5f
        lea     RANGE(%a0),%a0
        bra.s   4b
5:      move.l  4(%a0),%d0                        | the divisor to three digits
        move.l  %d0,%d2
        lsr.l   #1,%d2
        add.l   %d2,%d1
        divu.l  %d0,%d1                           | n, 100..999

        mvzb    8(%a0),%d2                        | digits before the point, 0 = none
        divu.w  #100,%d1                          | low word hundreds, high word the rest
        mvzw    %d1,%d0
        bsr.s   digit
        swap    %d1
        mvzw    %d1,%d1
        divu.w  #10,%d1                           | low word tens, high word units
        mvzw    %d1,%d0
        bsr.s   digit
        swap    %d1
        mvzw    %d1,%d0
        bsr.s   digit
        tst.b   9(%a0)
        beq.s   6f
        move.b  #'k',(%a1)+
6:      move.b  #'H',(%a1)+
        move.b  #'z',(%a1)+
        clr.b   (%a1)
        movem.l (%sp),%d2-%d4/%a2-%a3             | param_value_text's epilogue
        lea     20(%sp),%sp
        rts

        | digit(d0 = 0..9, d2 = digits left before the point, a1 = output):
        | writes it, then the point when d2 reaches 0. Clobbers d0/d2/a1.
digit:
        addi.l  #0x30,%d0
        move.b  %d0,(%a1)+
        subq.l  #1,%d2
        bne.s   1f
        move.b  #'.',(%a1)+
1:      rts

        | Q15 2^(k/12), k = 0..11.
        .align  2
semitones:
        .word   32768, 34716, 36781, 38968, 41285, 43740
        .word   46341, 49097, 52016, 55109, 58386, 61858

        | One row a display range: F below the limit, the divisor that leaves
        | three digits, the digits before the point (0 = none) and whether the
        | unit is kHz. The last limit is never reached.
        .equ    RANGE,          12
ranges:
        .long   10000, 10
        .byte   2, 0, 0, 0                        | 13.8Hz .. 99.9Hz
        .long   100000, 100
        .byte   0, 0, 0, 0                        | 100Hz .. 999Hz
        .long   1000000, 1000
        .byte   1, 1, 0, 0                        | 1.00kHz .. 9.99kHz
        .long   0xffffffff, 10000
        .byte   2, 1, 0, 0                        | 10.0kHz ..
