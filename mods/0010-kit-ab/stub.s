        | Mod 0010 - NO + PLAY toggles between the edited kit and the saved one.
        |
        | The first press keeps the working kit (the edits) in a stash, then runs
        | stock's reload: the saved kit plays, under stock's own popup - "KIT 1
        | RELOADED!" from NO + PLAY. The next press copies the stash back and
        | applies it as reload applies a kit: "EDITS RESTORED!".
        |
        | Editing the original ends the A/B: the edits there become the version
        | kept, and the stashed ones are dropped. That is noticed lazily - a
        | checksum of the working kit is taken after each press, and a press that
        | finds it changed while the original plays (an edit, another kit, any
        | other reload) stashes the kit as it now is and reloads, as a first press.
        |
        | A press that finds the kit already as saved - the checksum the same after
        | the reload as before it - leaves no A/B armed, so NO + PLAY stays a plain
        | reload until something is edited.
        |
        | The stash, one 0x9e3-byte kit, is allocated from the firmware's heap on
        | the first press and kept. If that fails, the press is a plain reload.

        .include "symbols.inc"

        .equ    KIT_SIZE,       0x9e3
        .equ    WORKING,        352               | the working kit, in the project
        .equ    PROJECT_READY,  40                | project vtable: false and reload does nothing
        .equ    STOCK_MSG,      0x402578ae        | "KIT RELOADED!", kit_reload_key's
        .equ    STOCK_MSG_KEY,  0x40255ea6        | "KIT %d RELOADED!", NO + PLAY's
        .equ    FROM_KEY,       0x400cd4b4        | the return address from NO + PLAY's call

        .text

        | ------------------------------------------------------------------
        | kit_ab_toggle(project): in place of kit_reload, called at 0x400dd5de.
        | The popup that follows prints kab_msg, which this fills.
        |
        | a2 the project, a3 its working kit, a4 kit_working_data, a5 this mod's
        | data; d3 the working kit's data, d5 the message.
        | ------------------------------------------------------------------
        .align  2
kit_ab_toggle:
        lea     -32(%sp),%sp
        movem.l %d2-%d5/%a2-%a5,(%sp)
        move.l  36(%sp),%a2
        lea     WORKING(%a2),%a3
        lea     kit_working_data,%a4
        lea     kab,%a5
        move.l  %a3,-(%sp)
        jsr     (%a4)
        addq.l  #4,%sp
        move.l  %d0,%d3
        move.l  %d3,%a0
        jsr     checksum
        move.l  %d0,%d4                           | the working kit's checksum on entry

        | Stock's own text for a reload: NO + PLAY's passes the kit's number to the
        | formatter, kit_reload_key's passes something else, so %d only for the first.
        move.l  #STOCK_MSG_KEY,%d5
        move.l  32(%sp),%d1
        cmp.l   #FROM_KEY,%d1
        beq.s   5f
        move.l  #STOCK_MSG,%d5
5:      tst.l   MODE(%a5)
        beq.s   original                          | the edits play: keep them, reload
        cmp.l   SUM(%a5),%d4
        bne.s   original                          | the original was edited: rule (a)

        | The original plays and is unchanged: put the edits back.
restore:
        move.l  (%a2),%a0
        move.l  %a2,-(%sp)
        move.l  PROJECT_READY(%a0),%a0
        jsr     (%a0)
        addq.l  #4,%sp
        tst.l   %d0
        beq     finish                            | as kit_reload: nothing to do
        pea     KIT_SIZE
        move.l  STASH(%a5),-(%sp)
        move.l  %d3,-(%sp)
        jsr     memcpy
        lea     12(%sp),%sp
        clr.l   -(%sp)                            | as kit_reload does after its copy
        move.l  %a3,-(%sp)
        jsr     kit_mark
        addq.l  #8,%sp
        move.l  %a3,-(%sp)
        jsr     kit_apply
        addq.l  #4,%sp
        move.l  %a3,-(%sp)                        | pushed afresh: a callee may reuse its slot
        jsr     (%a4)
        addq.l  #4,%sp
        move.l  %d0,-(%sp)
        jsr     kit_push
        addq.l  #4,%sp
        clr.l   MODE(%a5)
        lea     MSG_EDITED(%a5),%a0
        move.l  %a0,%d5
        bra.s   finish

        | Keep the working kit in the stash, then reload the saved one. With no
        | stash to be had, a plain reload.
original:
        move.l  STASH(%a5),%d0
        bne.s   1f
        pea     KIT_SIZE
        jsr     mem_new
        addq.l  #4,%sp
        move.l  %d0,STASH(%a5)
        beq.s   2f
1:      pea     KIT_SIZE
        move.l  %d3,-(%sp)
        move.l  %d0,-(%sp)
        jsr     memcpy
        lea     12(%sp),%sp
        moveq   #1,%d0
        move.l  %d0,MODE(%a5)
2:      move.l  %a2,-(%sp)
        jsr     kit_reload
        addq.l  #4,%sp

        | The working kit as it now stands, for the next press; and the message.
finish:
        move.l  %a3,-(%sp)
        jsr     (%a4)
        addq.l  #4,%sp
        move.l  %d0,%a0
        jsr     checksum
        move.l  %d0,SUM(%a5)
        cmp.l   %d4,%d0                           | unchanged by the press: it held no edits
        bne.s   6f
        clr.l   MODE(%a5)
6:      move.l  %d5,%a0
        lea     MSG(%a5),%a1
4:      move.b  (%a0)+,(%a1)+
        bne.s   4b
        movem.l (%sp),%d2-%d5/%a2-%a5
        lea     32(%sp),%sp
        rts

        | ------------------------------------------------------------------
        | The data, in its own claim: the checksum, the message, and what is
        | written at runtime. Code runs from RAM anywhere; cave7 had no room left.
        | ------------------------------------------------------------------
        .section .kab,"awx"
        .align  2
kab:
kab_stash:
        .long   0                                 | the stash, once allocated
kab_mode:
        .long   0                                 | 1 while the original plays
kab_sum:
        .long   0                                 | the working kit's checksum after the last press
kab_msg:
        .asciz  "KIT RELOADED!"                   | the popup's text
        .space  3                                 | room for the longest, stock's "KIT %d RELOADED!"
msg_edited:
        .asciz  "EDITS RESTORED!"

        .align  2
        | checksum(a0 = a kit's data) -> d0: h = 33h + b over its KIT_SIZE bytes.
        | Clobbers d1, d2 and a0.
checksum:
        moveq   #0,%d0
        move.l  #KIT_SIZE,%d1
3:      move.l  %d0,%d2
        lsl.l   #5,%d2
        add.l   %d2,%d0
        mvz.b   (%a0)+,%d2
        add.l   %d2,%d0
        subq.l  #1,%d1
        bne.s   3b
        rts

        .equ    STASH,          kab_stash - kab
        .equ    MODE,           kab_mode - kab
        .equ    SUM,            kab_sum - kab
        .equ    MSG,            kab_msg - kab
        .equ    MSG_EDITED,     msg_edited - kab
