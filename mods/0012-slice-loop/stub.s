        | Mod 0012 - SLICE LOOP in the track menu (FUNC + CHRO).
        |
        | For a one-bar loop sample padded so the bar is 96/120 of it: sixteen trigs
        | on steps 1..16, trig n locked to sample START 6(n-1) and END 6n, and the
        | track's TRIG page defaults set to SYN off, SMP on. Swing, accents and
        | micro timing then move each slice as they would a drum hit.
        |
        | Refuses, changing nothing, on the FX track, on a track shorter than 16
        | steps, and on a track with any trig. Every write goes through stock's own
        | setter: trig_place, track_lock_set and param_set_value.

        .include "symbols.inc"

        .equ    ID_SYN,         34                | TRIG page Synthesis Trig
        .equ    ID_SMP,         35                | TRIG page Sample Trig
        .equ    IDX_STA,        21                | sound index of sample START
        .equ    IDX_END,        22                | sound index of sample END
        .equ    SLICE,          0x600             | 6, in 8.8
        .equ    STEPS,          16
        .equ    FX_TRACK,       12
        .equ    TRIG_KIND,      1                 | param_target_for_track: the trig set

        | SAVE TRACK's std::function managers, reused: the label and icon
        | lambdas capture nothing and the action captures the menu, as ours do.
        .equ    MGR_LABEL,      0x400f9a38
        .equ    MGR_ACTION,     0x400f9a8a
        .equ    MGR_ICON,       0x400f9ae6
        .equ    SP_COUNTED_VT,  0x401ccab4        | shared_ptr control block, as SAVE TRACK's
        .equ    MSG_FX,         0x40241249        | stock's "ONLY ON SOUND TRACKS"
        .equ    CTOR_REJOIN,    0x400f9e9c        | the constructor's `lea %sp@(128),%sp; rts`

        .text

        | ------------------------------------------------------------------
        | slice_menu_add: TrackMenuView's constructor, after SAVE TRACK.
        |
        | Reached by a jmp over its epilogue's moveml. SAVE TRACK's item sequence
        | follows unchanged but for three invokers and the allocator, which a4 no
        | longer holds. The registers it uses still hold what it needs - a3 the
        | menu, fp the item constructor, a5 the append, a2 the std::function
        | destructor, d2..d5 the four function slots - and the stack is at the
        | depth every item starts at, so its offsets hold.
        | ------------------------------------------------------------------
        .align  2
slice_menu_add:
        clr.l   %sp@(72)
        pea     0x1
        jsr     mem_new
        clr.l   %sp@(92)
        lea     MGR_LABEL,%a0
        move.l  %d0,%sp@(68)
        move.l  #slice_label,%d0
        move.l  %a0,%sp@(76)
        move.l  %d0,%sp@(80)
        pea     0x4
        jsr     mem_new
        move.l  %d0,%a0
        move.l  %a3,%a0@                          | the action captures the menu
        move.l  %d0,%sp@(88)
        move.l  #slice_action,%d0
        lea     MGR_ACTION,%a0
        move.l  %a0,%sp@(96)
        move.l  %d0,%sp@(100)
        clr.l   %sp@(112)                         | the fourth function, empty
        lea     %sp@(32),%sp
        pea     0x1
        jsr     mem_new
        clr.l   %sp@(100)
        lea     MGR_ICON,%a0
        move.l  %d0,%sp@(76)
        move.l  #slice_icon,%d0
        move.l  %a0,%sp@(84)
        move.l  %d0,%sp@(88)
        pea     0x54
        jsr     mem_new
        pea     0x8
        pea     0xffffffff
        move.l  %d2,%sp@-
        move.l  %d3,%sp@-
        move.l  %d5,%sp@-
        move.l  %d4,%sp@-
        move.l  %d0,%a4
        move.l  %d0,%sp@-
        jsr     %fp@                              | menu_item_ctor
        lea     %sp@(32),%sp
        move.l  %a4,%sp@
        move.l  %a3,%sp@-
        jsr     %a5@                              | append to the menu
        move.l  %d2,%sp@-
        jsr     %a2@
        move.l  %d3,%sp@-
        jsr     %a2@
        move.l  %d5,%sp@-
        jsr     %a2@
        move.l  %d4,%sp@-
        jsr     %a2@
        movem.l %sp@(24),%d2-%d6/%a2-%fp          | displaced
        jmp     CTOR_REJOIN

        | The label: returns the item's text as a std::string, built in place at
        | a0, as SAVE TRACK's does.
slice_label:
        link    %fp,#-4
        move.l  %d2,%sp@-
        pea     %fp@(-1)
        pea     name
        move.l  %a0,%d2
        move.l  %a0,%sp@-
        jsr     std_string_from_cstr
        lea     %sp@(12),%sp
        move.l  %d2,%d0
        move.l  %fp@(-8),%d2
        unlk    %fp
        rts

        | The icon: none. An empty std::function would be called all the same.
slice_icon:
        rts

        | ------------------------------------------------------------------
        | slice_action: the item's action, SAVE TRACK's in shape.
        |
        | a5 the functor (it holds the menu), a4 the project, a3 the track block,
        | d7 the track, d6 the popup's text, d5 the track length, d4 the step,
        | d3 the lock value.
        | ------------------------------------------------------------------
slice_action:
        link    %fp,#-80
        movem.l %d2-%d7/%a2-%a5,(%sp)
        move.l  %fp@(8),%a0
        move.l  (%a0),%a5
        jsr     project_singleton
        move.l  %d0,%a4
        move.l  %d0,%sp@-
        jsr     track_selection
        move.l  %d0,(%sp)
        jsr     track_index_of
        addq.l  #4,%sp
        move.l  %d0,%d7

        move.l  #MSG_FX,%d6
        moveq   #FX_TRACK,%d0
        cmp.l   %d0,%d7
        bge     show
        move.l  %a4,%sp@-
        jsr     current_track_pattern
        move.l  %d0,%a3
        move.l  %d0,(%sp)
        jsr     pattern_length
        addq.l  #4,%sp
        move.l  %d0,%d5
        move.l  #msg_short,%d6
        moveq   #STEPS,%d0
        cmp.l   %d0,%d5
        blt     show

        | Refuse a track that has any trig, lock trigs included.
        move.l  #msg_busy,%d6
        moveq   #0,%d4
1:      pea     0x1
        move.l  %d4,%sp@-
        move.l  %a3,%sp@-
        jsr     trig_flag_get
        lea     %sp@(12),%sp
        tst.b   %d0
        bne     show
        addq.l  #1,%d4
        cmp.l   %d5,%d4
        blt.s   1b

        | The track's TRIG page defaults: SYN off, SMP on.
        pea     TRIG_KIND
        move.l  %d7,%sp@-
        move.l  %a4,%sp@-
        jsr     param_target_for_track
        lea     %sp@(12),%sp
        move.l  %d0,%d3
        pea     0x1
        pea     0x1
        move.l  %d7,%sp@-
        clr.l   %sp@-                             | off
        pea     ID_SYN
        move.l  %d3,%sp@-
        jsr     param_set_value
        lea     %sp@(24),%sp
        pea     0x1
        pea     0x1
        move.l  %d7,%sp@-
        pea     0x100                             | on, in 8.8
        pea     ID_SMP
        move.l  %d3,%sp@-
        jsr     param_set_value
        lea     %sp@(24),%sp

        | Sixteen trigs, trig n locked to START 6(n-1), END 6n.
        moveq   #0,%d4
        moveq   #0,%d3
2:      pea     0x1
        move.l  %d4,%sp@-
        move.l  %a3,%sp@-
        jsr     trig_place
        lea     %sp@(12),%sp
        pea     0x1
        move.l  %d3,%sp@-
        pea     IDX_STA
        move.l  %d4,%sp@-
        move.l  %a3,%sp@-
        jsr     track_lock_set
        lea     %sp@(20),%sp
        add.l   #SLICE,%d3
        pea     0x1
        move.l  %d3,%sp@-
        pea     IDX_END
        move.l  %d4,%sp@-
        move.l  %a3,%sp@-
        jsr     track_lock_set
        lea     %sp@(20),%sp
        addq.l  #1,%d4
        moveq   #STEPS,%d0
        cmp.l   %d0,%d4
        blt.s   2b
        move.l  #msg_done,%d6

        | The popup, as SAVE TRACK shows its own, then close the menu as it does.
show:
        pea     %fp@(-17)                         | the allocator argument
        move.l  %d6,%sp@-
        pea     %fp@(-8)                          | the std::string
        jsr     std_string_from_cstr
        lea     %sp@(12),%sp
        pea     0xa0
        jsr     mem_new
        addq.l  #4,%sp
        move.l  %d0,%d3
        pea     %fp@(-8)
        move.l  %d3,%sp@-
        jsr     popup_ctor
        addq.l  #8,%sp
        move.l  %d3,%fp@(-16)                     | shared_ptr: the popup
        clr.l   %fp@(-12)                         |             and its control block
        pea     0x10
        jsr     mem_new
        addq.l  #4,%sp
        move.l  %d0,%a0
        moveq   #1,%d0
        move.l  #SP_COUNTED_VT,(%a0)
        move.l  %d0,%a0@(4)
        move.l  %d0,%a0@(8)
        move.l  %d3,%a0@(12)
        move.l  %a0,%fp@(-12)
        clr.l   %sp@-
        pea     %fp@(-16)
        move.l  (%a5),%a0                         | the menu
        move.l  %a0@(100),%sp@-                   | its view manager
        jsr     view_show_popup
        lea     %sp@(12),%sp
        pea     %fp@(-12)
        jsr     shared_ptr_release
        addq.l  #4,%sp
        pea     %fp@(-8)
        jsr     std_string_dtor
        addq.l  #4,%sp
        move.l  (%a5),%a0
        move.l  (%a0),%a1
        move.l  %a0,%sp@-
        move.l  %a1@(128),%a1
        jsr     (%a1)                             | close the menu
        addq.l  #4,%sp
        movem.l (%sp),%d2-%d7/%a2-%a5
        unlk    %fp
        rts

name:
        .asciz  "SLICE LOOP"
msg_done:
        .asciz  "LOOP SLICED"
msg_busy:
        .asciz  "TRACK NOT EMPTY"
msg_short:
        .asciz  "NEEDS 16 STEPS"
