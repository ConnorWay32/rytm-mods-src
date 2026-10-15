        | Mod 0014 - CTRL ALL: TRK + knob turns that parameter on every sound track.
        |
        | The same step goes to tracks 1..12, so their differences are kept. A SYNTH
        | knob applies by position: each track takes the id its own machine has in
        | the same slot, within that id's range, and a track whose machine has none
        | there is left alone; stock's write drops an id of another machine. Each
        | track's set comes from the page's own getter and each write
        | goes through that set's delta handler, which reads and writes the set's
        | own track; storage and the display see ordinary edits.
        |
        | Stock handles the turn alone with the FX track selected, with any trig key
        | held, and on any page whose set is not a sound or trig set.
        |
        | The FILTER page's TYP is not stepped on every track: the selected track
        | takes the turn and every other track is set to the type it reached.

        .include "symbols.inc"

        .equ    FX_TRACK,       12
        .equ    TRACKS,         12                | the sound tracks, 0..11
        .equ    TRIG_KEYS,      16                | key ids 0..15
        .equ    VT_PAGE_SET,    0xa0              | page view: page_param_set(view, track)
        .equ    VT_READ,        0x28              | set: param_set_read(set, id)
        .equ    VT_APPLY_DELTA, 0x2c              | set: param_set_apply_delta
        .equ    ID_FLT_TYP,     49                | FILTER TYP
        .equ    SET_SOUND,      0x18              | sound set: its live sound's source
        .equ    VT_SOUND_LIVE,  0x28              | source: the live sound
        .equ    SOUND_MACHINE,  0x68              | live sound: machine byte

        .text

        | ------------------------------------------------------------------
        | ctrl_all_gate: param_apply_delta after the track lookup.
        |
        | Reached by a jmp over `moveal %a2@,%a0; pea -1`, the end of the gate chain
        | 0002, 0003, 0004 and 0013 form, so the ids those mods take never get here.
        | d0 is the selected track, a2 the view, d3 funcHeld zero-extended; the
        | lookup's argument is still pushed, so %sp@(24) is the id, %sp@(28) the
        | delta in 8.8 and %sp@(36) outFlag. d2 is free: stock loads it from d0
        | after this point, and the epilogue restores it.
        | ------------------------------------------------------------------
        .align  2
ctrl_all_gate:
        moveq   #FX_TRACK,%d1
        cmp.l   %d1,%d0
        bcc.w   9f                                | the FX track
        move.l  %d0,-(%sp)                        | park the selected track
        pea     KEY_TRK
        jsr     is_key_held
        addq.l  #4,%sp
        tst.l   %d0
        beq.w   8f
        moveq   #TRIG_KEYS-1,%d2
1:      move.l  %d2,-(%sp)
        jsr     is_key_held
        addq.l  #4,%sp
        tst.l   %d0
        bne.w   8f                                | a trig is held: stock, which locks it
        subq.l  #1,%d2
        bpl.s   1b
        pea     -1                                | the selected track's set
        move.l  %a2,-(%sp)
        move.l  %a2@,%a0
        move.l  %a0@(VT_PAGE_SET),%a0
        jsr     %a0@
        addq.l  #8,%sp
        move.l  %d0,%a0
        move.l  %a0@,%d0
        cmp.l   #SOUND_PARAM_SET_VT,%d0
        beq.s   2f
        cmp.l   #TRIG_PARAM_SET_VT,%d0
        bne.s   8f                                | FX or global parameters
2:      jmp     ctrl_all_each                     | the parked track still pushed
ctrl_all_done:
        addq.l  #4,%sp                            | the lookup's argument
        movem.l (%sp),%d2-%d3/%a2                 | param_apply_delta's epilogue
        lea     12(%sp),%sp
        rts
8:      move.l  (%sp)+,%d0                        | the selected track, where stock keeps it
9:      move.l  %a2@,%a0                          | displaced
        pea     -1                                | displaced
        jmp     param_apply_delta_dispatch_resume

        | ------------------------------------------------------------------
        | ctrl_all_typ: TRK + turn on FILTER TYP. The selected track takes the
        | turn through its set's delta handler, then every other sound track's
        | set is given the value it reached through param_set_value, the write
        | the delta handler ends in.
        |
        | Reached from ctrl_all_gate with the selected track parked on the stack
        | above the lookup's argument; registers as there.
        | ------------------------------------------------------------------
        .section .typ,"ax"

        | ctrl_all_each: the turn on every sound track, from ctrl_all_gate with
        | the selected track parked on the stack; FILTER TYP goes to
        | ctrl_all_typ instead.
        .align  2
ctrl_all_each:
        moveq   #ID_FLT_TYP,%d1
        cmp.l   %sp@(28),%d1
        beq.w   ctrl_all_typ
        addq.l  #4,%sp                            | the parked track
        moveq   #0,%d2
3:      move.l  %d2,-(%sp)                        | this track's set
        move.l  %a2,-(%sp)
        move.l  %a2@,%a0
        move.l  %a0@(VT_PAGE_SET),%a0
        jsr     %a0@
        addq.l  #8,%sp
        move.l  %d0,-(%sp)                        | the set, at %sp@(4)
        move.l  %sp@(28),-(%sp)                   | this track's id, at (%sp)
        jsr     param_is_machine
        tst.l   %d0
        beq.s   4f
        jsr     param_container_index             | the machine slot
        move.l  %d0,(%sp)
        move.l  %sp@(4),%a0
        move.l  %a0@(SET_SOUND),%d0
        beq.s   5f                                | no sound: stock writes nothing
        move.l  %d0,-(%sp)
        move.l  %d0,%a0
        move.l  %a0@,%a0
        move.l  %a0@(VT_SOUND_LIVE),%a0
        jsr     %a0@
        addq.l  #4,%sp
        tst.l   %d0
        beq.s   5f
        move.l  %d0,%a0
        moveq   #0,%d0
        move.b  %a0@(SOUND_MACHINE),%d0
        move.l  %d0,-(%sp)                        | this track's machine
        move.l  %sp@(4),-(%sp)                    | the slot
        jsr     sound_param_id_for_index
        addq.l  #8,%sp
        move.l  %d0,(%sp)
        beq.s   5f                                | its machine has no parameter there
4:      move.l  %sp@(44),-(%sp)                   | outFlag
        move.l  %d3,-(%sp)                        | funcHeld
        move.l  %d2,-(%sp)                        | track
        move.l  %sp@(48),-(%sp)                   | delta
        move.l  %sp@(16),-(%sp)                   | id
        move.l  %sp@(24),-(%sp)                   | set
        move.l  (%sp),%a0
        move.l  %a0@,%a0
        move.l  %a0@(VT_APPLY_DELTA),%a0
        jsr     %a0@
        lea     24(%sp),%sp
5:      addq.l  #8,%sp                            | the set and id
        addq.l  #1,%d2
        moveq   #TRACKS,%d0
        cmp.l   %d0,%d2
        blt.w   3b
        jmp     ctrl_all_done

        .align  2
ctrl_all_typ:
        move.l  (%sp)+,%d2                        | the selected track
        move.l  %d2,-(%sp)                        | its set
        move.l  %a2,-(%sp)
        move.l  %a2@,%a0
        move.l  %a0@(VT_PAGE_SET),%a0
        jsr     %a0@
        addq.l  #8,%sp
        move.l  %sp@(36),-(%sp)                   | outFlag
        move.l  %d3,-(%sp)                        | funcHeld
        move.l  %d2,-(%sp)                        | track
        move.l  %sp@(40),-(%sp)                   | delta
        move.l  %sp@(40),-(%sp)                   | id
        move.l  %d0,-(%sp)                        | set
        move.l  %d0,%a0
        move.l  %a0@,%a0
        move.l  %a0@(VT_APPLY_DELTA),%a0
        jsr     %a0@
        lea     24(%sp),%sp
        move.l  %d2,-(%sp)                        | its set again, for the value
        move.l  %a2,-(%sp)
        move.l  %a2@,%a0
        move.l  %a0@(VT_PAGE_SET),%a0
        jsr     %a0@
        addq.l  #8,%sp
        move.l  %sp@(24),-(%sp)                   | id
        move.l  %d0,-(%sp)                        | set
        move.l  %d0,%a0
        move.l  %a0@,%a0
        move.l  %a0@(VT_READ),%a0
        jsr     %a0@
        addq.l  #8,%sp
        move.l  %d0,-(%sp)                        | the type reached, at (%sp)
        moveq   #0,%d3                            | funcHeld no longer needed
1:      cmp.l   %d2,%d3
        beq.s   2f                                | the selected track has it
        move.l  %d3,-(%sp)                        | this track's set
        move.l  %a2,-(%sp)
        move.l  %a2@,%a0
        move.l  %a0@(VT_PAGE_SET),%a0
        jsr     %a0@
        addq.l  #8,%sp
        pea     1
        pea     1
        move.l  %d3,-(%sp)                        | track
        move.l  %sp@(12),-(%sp)                   | the type
        move.l  %sp@(44),-(%sp)                   | id
        move.l  %d0,-(%sp)                        | set
        jsr     param_set_value
        lea     24(%sp),%sp
2:      addq.l  #1,%d3
        moveq   #TRACKS,%d0
        cmp.l   %d0,%d3
        blt.s   1b
        addq.l  #4,%sp                            | the type
        jmp     ctrl_all_done
