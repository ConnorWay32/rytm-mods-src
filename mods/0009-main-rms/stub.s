        | Mod 0009 - main output RMS indicator.
        |
        | On the compressor pages - stock's and 0006's preview - the VOL knob's
        | label draws inverted while the main output's RMS level is over a
        | threshold, for gain staging. The level is the louder of MAIN L and R,
        | each averaged over about 300 ms; a full-scale square wave reads 0 dBFS
        | and a full-scale sine -3.01. The label turns on above the threshold and
        | off 1 dB below it.
        |
        | MAIN L and R are read from the receive buffer, the pair USB and the
        | sampler record: after the compressor, and not set by the master volume
        | knob beyond a few dB of interaction.

        .include "symbols.inc"

        .equ    PARAM_ID_VOL,   99
        .equ    RXBUF,          0x80007440  | rx_buffer; MAIN L, R at +0, +4
        .equ    RXSTRIDE,       48
        .equ    FRAMES,         32
        | The smoothing: y += (ms - y) * ALPHA / 2^16 a block, a time constant
        | of 2^16 / ALPHA = 449 blocks of 32 frames at 48 kHz, 299 ms.
        .equ    ALPHA,          146

        | The threshold, as a mean square in the units the scan produces: a
        | sample's top 16 bits squared, so full scale is 2^30. Stepped down from
        | there 1 dB at a time by 10^-0.1; the assembler's 64-bit arithmetic
        | keeps that within 0.0001 dB of exact. RMS_OFF is 1 dB lower.
        | Two tests: | begins a comment, so `a || b` would test a alone.
        .if     P_RMS_DB > 0
        .error  "0009-main-rms: rms_db must be 0 .. -60"
        .endif
        .if     P_RMS_DB < -60
        .error  "0009-main-rms: rms_db must be 0 .. -60"
        .endif
        .set    RMS_ON, 1073741824
        .rept   -P_RMS_DB
        .set    RMS_ON, RMS_ON * 794328 / 1000000
        .endr
        .set    RMS_OFF, RMS_ON * 794328 / 1000000

        .text

        | ------------------------------------------------------------------
        | The audio interrupt, once the receive buffer holds this block.
        |
        | Reached by a jmp over `jsr %a2@; lea %sp@(24),%sp`, re-emitted here
        | first. d0 is that call's result and is read below the resume point, as
        | is d2, so everything this uses is parked.
        |
        | Each sample's top 16 bits are squared (muls.w, not the EMAC, whose
        | state belongs to the interrupted code) and shifted down 5 before
        | summing, so the 32 frames sum to the block's mean square with no
        | overflow: at most 32 * 2^30 / 32. The words are negated samples, which
        | squaring ignores.
        | ------------------------------------------------------------------
        .align  2
rms_scan:
        jsr     (%a2)                             | displaced
        lea     24(%sp),%sp                       | displaced
        lea     -24(%sp),%sp
        movem.l %d0-%d4/%a0,(%sp)
        lea     RXBUF,%a0
        moveq   #0,%d3                            | L
        moveq   #0,%d4                            | R
        moveq   #FRAMES,%d2
1:      move.l  (%a0),%d0
        swap    %d0
        muls.w  %d0,%d0
        lsr.l   #5,%d0
        add.l   %d0,%d3
        move.l  4(%a0),%d0
        swap    %d0
        muls.w  %d0,%d0
        lsr.l   #5,%d0
        add.l   %d0,%d4
        lea     RXSTRIDE(%a0),%a0
        subq.l  #1,%d2
        bne.s   1b

        lea     ms_l,%a0
        move.l  %d3,%d0
        bsr.s   smooth
        move.l  %d0,%d3
        lea     ms_r,%a0
        move.l  %d4,%d0
        bsr.s   smooth
        cmp.l   %d3,%d0
        bcc.s   2f
        move.l  %d3,%d0                           | the louder side
2:      tst.l   rms_over
        bne.s   3f
        cmp.l   #RMS_ON,%d0
        bls.s   4f
        moveq   #1,%d1
        move.l  %d1,rms_over
        bra.s   4f
3:      cmp.l   #RMS_OFF,%d0
        bcc.s   4f
        clr.l   rms_over
4:      movem.l (%sp),%d0-%d4/%a0
        lea     24(%sp),%sp
        jmp     audio_rx_filled_resume

        | smooth(a0 = the side's average, d0 = this block's mean square)
        |   -> d0 = the new average, also stored. Clobbers d1.
        | The difference is scaled down 7 before the multiply so it cannot
        | overflow: at most 2^23 * ALPHA.
smooth:
        sub.l   (%a0),%d0
        asr.l   #7,%d0
        move.l  #ALPHA,%d1
        muls.l  %d1,%d0
        asr.l   #8,%d0
        asr.l   #1,%d0
        add.l   (%a0),%d0
        move.l  %d0,(%a0)
        rts

        | ------------------------------------------------------------------
        | The compressor view's two knob draw slots.
        |
        | Each runs stock's knob draw with the caller's own arguments by swapping
        | the return address, so nothing is copied: the draw returns to vol_after
        | with its arguments still on the caller's stack, and vol_after returns to
        | the caller. The saved address is one word, which is safe because knob
        | draws happen on the UI task only and never nest.
        |
        | For VOL while over the threshold, it inverts the label's box - the same
        | box stock highlights a label with, (x-13, y-14)..(x+13, y-8) - through
        | fill_rect. Both pages draw the label at y - 13, so the box is the same
        | on each. fill_rect XORs: a label stock has already highlighted reads
        | normal while over, which is still a change.
        | ------------------------------------------------------------------
        .align  2
vol_knob_draw:
        lea     knob_draw,%a0
        bra.s   1f
vol_knob_draw_alt:
        lea     knob_draw_alt,%a0
1:      move.l  (%sp),vol_ret
        lea     vol_after,%a1
        move.l  %a1,(%sp)
        jmp     (%a0)

        | (sp) view, 4 canvas, 8 x, 12 y, 16 id
vol_after:
        moveq   #PARAM_ID_VOL,%d0
        cmp.l   16(%sp),%d0
        bne.s   9f
        tst.l   rms_over
        beq.s   9f
        move.l  8(%sp),%a1                        | x
        move.l  12(%sp),%a0                       | y
        pea     -1                                | XOR
        pea     -8(%a0)
        pea     13(%a1)
        pea     -14(%a0)
        pea     -13(%a1)
        move.l  24(%sp),-(%sp)                    | canvas, past the five pushes
        jsr     fill_rect
        lea     24(%sp),%sp
9:      move.l  vol_ret,%a0
        jmp     (%a0)

        | Written at runtime: the image is RAM, and the same 16 MB region 0006
        | writes its sidechain state into every block.
        .align  2
ms_l:
        .long   0
ms_r:
        .long   0
rms_over:
        .long   0
vol_ret:
        .long   0
