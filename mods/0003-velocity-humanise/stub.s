        | Mod 0003 - velocity humanise.
        |
        | The amount is a 4-bit index in bits 2..5 of the track's euclid-enable
        | byte (TrackPattern +0x2ca). Mod 0002 owns that byte: it saves bits 1..5,
        | and masks every euclid read to bits 0..1, so these bits change nothing
        | else. Bits 6..7 of the byte are never set - stock writes 0/1, 0002's load
        | fills bits 1..5 only - so byte >> 2 is the index without masking.

        .include "symbols.inc"
        .include "shared.inc"

        .equ    OFF_EUCLID_ENABLED, 0x2ca
        .equ    AMOUNT_SHIFT,       2
        .equ    AMOUNT_MASK,        0x3c          | bits 2..5 of the byte
        .equ    AMOUNT_MAX,         15
        .equ    PARAM_ID_VEL,       30
        .equ    VT_STORAGE,         0x28
        .equ    VT_NOTIFY,          0x10
        .equ    EUCLID_CHANGE_INFO, 0x401e0898

        .text

        | ------------------------------------------------------------------
        | trig_fire, where the trig's velocity is finalised.
        |
        | Reached by a jmp over `movel %sp@(60),%d0; addal %a2,%a3`. After those,
        | d0 is the velocity (the step's own, or the track default), a3 the track
        | base, and %sp@(72) the step's velocity as vel << 8, or -1 when the step
        | has none. trig_fire stores d0 << 8 and the low word of %sp@(72) into the
        | trig event straight after the resume point, so both are updated here.
        |
        | d1 and a0 are both reloaded before they are next read in trig_fire
        | (0x4009afa6..0x4009afe4); d3 (the step) and d5 are not touched. shared_rnd
        | clobbers d0 as well, which still holds the velocity here, so it is parked
        | across the call.
        | ------------------------------------------------------------------
        .align  2
vel_humanise:
        move.l  %sp@(60),%d0                      | displaced
        addal   %a2,%a3                           | displaced: a3 = track base
        mvzb    OFF_EUCLID_ENABLED(%a3),%d1
        lsr.l   #AMOUNT_SHIFT,%d1                 | index, 0..15
        beq.s   9f
        lea     shared_amounts,%a0
        mvzb    %a0@(0,%d1:l),%d1                 | N
        lea     rng_state,%a0                     | this mod's own stream
        move.l  %d0,-(%sp)                        | the velocity, across the call
        jsr     shared_rnd                        | -> d0 = -N..N
        move.l  %d0,%d1
        move.l  (%sp)+,%d0
        add.l   %d1,%d0

        moveq   #1,%d1
        cmp.l   %d1,%d0
        bge.s   1f
        move.l  %d1,%d0
1:      moveq   #127,%d1
        cmp.l   %d1,%d0
        ble.s   2f
        move.l  %d1,%d0
2:      move.l  %sp@(72),%d1
        addq.l  #1,%d1
        beq.s   9f                                | -1: the step has no velocity of its own
        move.l  %d0,%d1
        lsl.l   #8,%d1
        move.l  %d1,%sp@(72)
9:      jmp     trig_fire_vel_resume

        | ------------------------------------------------------------------
        | track_bytes() -> d0 = the current track's TrackPattern data, or 0,
        |                  and %a0 = the accessor it came from
        |
        | The same route 0002 takes: current_track_pattern's accessor, then its
        | vtable[0x28]. The accessor is kept because the change notification is
        | addressed to it. Clobbers d0/d1/a0/a1 only, like any call. Returns with
        | the flags set from d0.
        | ------------------------------------------------------------------
        .align  2
track_bytes:
        jsr     project_singleton
        move.l  %d0,-(%sp)
        jsr     current_track_pattern
        move.l  %d0,(%sp)                         | the accessor is also the argument
        move.l  %d0,-(%sp)                        | and the copy returned in a0
        move.l  %d0,%a1
        move.l  (%a1),%a0
        move.l  VT_STORAGE(%a0),%a0
        jsr     (%a0)
        move.l  (%sp)+,%a0                        | the accessor
        addq.l  #4,%sp
        tst.l   %d0
        rts

        | ------------------------------------------------------------------
        | mark_changed(%a0 = accessor)
        |
        | The notification stock raises after writing the euclid-enable byte: a
        | pointer to that field's change descriptor goes into a stack local and
        | the local's address is passed with the pattern. It is what makes the
        | edit count as a change to the track, which the envelope byte alone is
        | not - the saved pattern is the converted record, and only a change
        | reaches that conversion.
        | ------------------------------------------------------------------
        .align  2
mark_changed:
        lea     -4(%sp),%sp                       | the stack local stock uses
        move.l  #EUCLID_CHANGE_INFO,(%sp)
        move.l  %sp,%d0
        move.l  %d0,-(%sp)                        | &local
        move.l  %a0,-(%sp)                        | the accessor
        move.l  (%a0),%a0
        move.l  VT_NOTIFY(%a0),%a0
        jsr     (%a0)
        lea     12(%sp),%sp
        rts

        | ------------------------------------------------------------------
        | FUNC + VEL edits the amount.
        |
        | Reached by a jmp over `moveal %sp@(16),%a2; movel %sp@(28),%d3`, after
        | param_apply_delta's prologue has run: %sp@(0..11) holds d2/d3/a2,
        | %sp@(20) is the parameter id, %sp@(24) the delta in 8.8 and %sp@(28) the
        | FUNC-held flag. Anything else continues into stock unchanged.
        |
        | The write goes straight into the envelope byte, so the change
        | notification that stock raises alongside its own write of that byte is
        | raised here too: without it the edit is not a change the track carries
        | into storage.
        | ------------------------------------------------------------------
        .align  2
vel_amount_gate:
        moveq   #PARAM_ID_VEL,%d0
        cmp.l   %sp@(20),%d0
        bne.s   8f
        tst.b   %sp@(31)                          | the flag is passed as a byte
        beq.s   8f

        move.l  %sp@(24),%d2
        asr.l   #8,%d2                            | whole steps, sign preserved
        beq.s   7f
        bsr.s   track_bytes
        beq.s   7f
        move.l  %d0,%a2
        mvzb    OFF_EUCLID_ENABLED(%a2),%d3
        moveq   #AMOUNT_MASK,%d1
        and.l   %d3,%d1                           | old field, in place
        move.l  %d1,%d0
        lsr.l   #AMOUNT_SHIFT,%d0
        add.l   %d2,%d0
        bpl.s   1f
        clr.l   %d0
1:      moveq   #AMOUNT_MAX,%d2
        cmp.l   %d2,%d0
        ble.s   2f
        move.l  %d2,%d0
2:      lsl.l   #AMOUNT_SHIFT,%d0
        eor.l   %d1,%d3                           | clear the old field
        or.l    %d0,%d3
        move.b  %d3,OFF_EUCLID_ENABLED(%a2)
        bsr.w   mark_changed                      | a0 still holds the accessor
7:      movem.l (%sp),%d2-%d3/%a2                 | param_apply_delta's epilogue
        lea     12(%sp),%sp
        rts

8:      moveal  %sp@(16),%a2                      | displaced
        movel   %sp@(28),%d3                      | displaced
        jmp     param_apply_delta_body

        | ------------------------------------------------------------------
        | vel_get_ui(TrackPattern *p) -> d0.b
        |
        | Replaces the jsr target in the get-by-id switch arm for VEL, which the
        | page's dial and value popup read through (the arm shifts the byte into
        | 8.8). While FUNC is held it answers the amount's stop on the dial, which
        | is what gives the knob its sixteen even positions: the stops are the
        | amount's sixteen settings spread evenly over VEL's range, so the needle
        | steps the same distance each time. The popup turns the stop back into
        | the amount (vel_text_gate); otherwise it tail-calls the stock getter, and
        | the dial and popup show the real velocity. Only this call site is
        | repointed: the getter's five direct callers are live play and record,
        | which must keep reading the real velocity.
        | ------------------------------------------------------------------
        .align  2
vel_get_ui:
        jsr     shared_func_held
        beq.s   9f
        bsr.w   track_bytes
        beq.s   9f
        move.l  %d0,%a0
        mvzb    OFF_EUCLID_ENABLED(%a0),%d0
        lsr.l   #AMOUNT_SHIFT,%d0                 | index, 0..15
        lea     shared_stops,%a0
        mvzb    %a0@(0,%d0:l),%d0                 | the setting's stop
        .if     P_DIAG_CANARY
        | DIAGNOSTIC: answer a count instead of N.
        | Modes 1 and 2 count canary words that no longer hold their pattern, so 0
        | means the region was not written. Mode 3 reads 0007-cave-probe's entry
        | counter instead, so 0 means the dead-code pool under test was never
        | ENTERED - which is the only question that can be asked of .text, since
        | nothing writes it and a canary there is clean either way.
        |
        | The count is answered as the STOP for index min(count, 15), not as the
        | count itself. vel_text_gate turns the dial value back into one of sixteen
        | amounts, so answering a raw count made 1..4 all print as "0" - the one
        | reading the whole experiment turns on, indistinguishable from "none".
        | Through the stops the popup reads 0, 1, 2, 3, 4, 6, 8, 10, 12, 16, 20, 24,
        | 32, 40, 48, 64, and only a true zero reads 0. Counts above 15 saturate:
        | the question is whether the region was touched at all, not how often.
        .if     P_DIAG_CANARY == 3
        move.l  PROBE_COUNT,%d0
        .else
        .if     P_DIAG_CANARY == 2
        lea     CAVE3,%a0                         | the pool 0005 fills
        move.l  #CAVE3_WORDS,%d1
        .else
        lea     canary,%a0
        move.l  #CANARY_WORDS,%d1
        .endif
        move.l  #CANARY_WORD,%a1
        clr.l   %d0
1:      cmpa.l  (%a0)+,%a1
        beq.s   2f
        addq.l  #1,%d0
2:      subq.l  #1,%d1
        bne.s   1b
        .endif
        moveq   #15,%d1
        cmp.l   %d1,%d0
        ble.s   3f
        move.l  %d1,%d0
3:      lea     shared_stops,%a0
        mvzb    %a0@(0,%d0:l),%d0                 | the stop the popup reads back
        .endif
        rts
9:      jmp     vel_get_stock

        | ------------------------------------------------------------------
        | VEL's value text while FUNC is held.
        |
        | The dial answers with the amount's stop (vel_get_ui), so the popup is
        | given a stop too and turns it back into the amount here: the stop is one
        | sixteenth of VEL's range, the sixteenth is the index, and the index has
        | an amount. FUNC is tested rather than assumed because the real velocity
        | reaches the same formatter at all other times, and that value prints as
        | itself. VEL's formatter also rejects 0, so an amount of 0 - index 0,
        | stop 0, or a velocity of 0 - is written out here as "0".
        |
        | Reached by a jmp over `movel %sp@(28),%d4; moveal %sp@(24),%a3`, after
        | param_value_text's prologue: %sp@(0..19) holds d2-d4/a2-a3, %sp@(28) is
        | the id, %sp@(32) the value, %sp@(36) the output buffer.
        | ------------------------------------------------------------------
        .align  2
vel_text_gate:
        moveq   #PARAM_ID_VEL,%d0
        cmp.l   %sp@(28),%d0
        bne.s   8f
        move.l  %sp@(32),%d0
        beq.s   7f                                | 0, from either source
        move.l  %d1,-(%sp)                        | across the key test, for the
        move.l  %d2,-(%sp)                        | fall-through that still
        move.l  %d3,-(%sp)                        | needs them
        move.l  %a0,-(%sp)
        move.l  %a1,-(%sp)
        jsr     shared_func_held
        move.l  (%sp)+,%a1
        move.l  (%sp)+,%a0
        move.l  (%sp)+,%d3
        move.l  (%sp)+,%d2
        move.l  (%sp)+,%d1
        tst.l   %d0
        beq.s   8f
        move.l  %sp@(32),%d0                      | the stop, in 8.8
        lsr.l   #8,%d0
        moveq   #AMOUNT_MAX,%d1
        mulu.w  %d1,%d0                           | the stop as sixteenths of the
        moveq   #63,%d1                           | range, rounded to the nearest
        add.l   %d1,%d0
        moveq   #127,%d1
        divu.w  %d1,%d0                           | -> the index, 0..15
        andil   #AMOUNT_MAX,%d0
        lea     shared_amounts,%a0
        mvzb    %a0@(0,%d0:l),%d0                 | N
7:      move.l  %sp@(36),%a1                      | the output buffer
        jsr     shared_fmt_u8
        movem.l (%sp),%d2-%d4/%a2-%a3             | param_value_text's epilogue
        lea     20(%sp),%sp
        rts
8:      movel   %sp@(28),%d4                      | displaced
        moveal  %sp@(24),%a3                      | displaced
        jmp     param_value_text_body

        | ------------------------------------------------------------------
        | The VEL knob's label reads RND while FUNC is held.
        |
        | Every knob label comes from stock's short-name accessor, which walks the
        | ROM table to record +0x30. It has three call sites and each formats the
        | answer with "%.7s", so answering differently here covers them all. The
        | detour sits one instruction in, after the id load, so d1 already holds
        | the id. That id is parked on the stack across the key test, which is a
        | call and answers with its own d1, because the fall-through still needs
        | the id. Anything that is neither VEL nor FUNC-held re-emits the range
        | compare and carries on, leaving the flags the scs that follows reads.
        | ------------------------------------------------------------------
        .align  2
vel_label_gate:
        moveq   #PARAM_ID_VEL,%d0
        cmp.l   %d1,%d0
        bne.s   8f
        move.l  %d1,-(%sp)                        | the id, across the call
        jsr     shared_func_held
        move.l  (%sp)+,%d1
        tst.l   %d0
        beq.s   8f
        lea     label_rnd,%a0
        move.l  %a0,%d0
        rts
8:      cmp.l   #469,%d1                          | displaced
        jmp     param_short_name_body

        | This mod's own LCG word. The tables and the draw itself are 0000-shared's;
        | only the stream is private, so 0003 and 0004 never pull the same numbers.
        .align  2
rng_state:
        .long   0x2545f491

        | The label the VEL knob shows while FUNC is held.
        .align  2
label_rnd:
        .asciz  "RND"

        | Canary for verifying the cave2 pool on hardware: a known pattern
        | behind the code, counted by vel_get_ui's diagnostic arm. Mode 2 counts
        | the cave3 pool instead, which 0005 fills, and places nothing here.
        .equ    CANARY_WORD,  0xc0def00d
        .equ    CANARY_WORDS, 380
        .equ    CAVE3,        0x40289ab8
        .equ    CAVE3_WORDS,  256
        | Mode 3's readout. 0007-cave-probe links its counter here; the two mods are
        | in separate stubs and cannot share a symbol, so this address has to match
        | 0007's .state claim in allocations.toml by hand.
        .equ    PROBE_COUNT,  0x402ccfa8
        .if     P_DIAG_CANARY == 1
        .align  2
canary:
        .fill   CANARY_WORDS, 4, CANARY_WORD
        .endif
