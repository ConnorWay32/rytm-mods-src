        | Mod 0002 - euclidean accents.
        |
        | Phase 1: storage and display only. The Bool Operator parameter reads and
        | writes a composite 0..7 value - operator in the low two bits, accent flag
        | in bit 2 - while the operator byte itself keeps its stock 0..3 range and
        | the accent flag lives in bit 1 of the euclid-enable byte. Playback is
        | untouched, so an accent variant behaves exactly like its base operator.
        |
        | Phase 2: playback and bake. trig_fire's grid arm gains an accent OR, and
        | euclid_bake gains an accent body that moves nothing.

        .include "symbols.inc"

        .equ    OFF_EUCLID_ENABLED, 0x2ca
        .equ    OFF_EUCLID_STEP_MAP, 0x2d1
        .equ    VT_STORAGE,         0x28          | vtable slot returning the storage ptr
        .equ    VT_BATCH,           0x3c          | begin/end a grouped change
        .equ    VT_NOTIFY,          0x10

        .text

        | ------------------------------------------------------------------
        | storage_ptr(Pattern *p) -> %a0, or 0
        |
        | Every accessor in this class reaches its data the same way: call
        | vtable[0x28] and use what comes back. Factored out because both entry
        | points below need it and a wrong vtable slot here is a wild call.
        | ------------------------------------------------------------------
        .align  2
storage_ptr:
        move.l  %d1,-(%sp)
        move.l  %a1,-(%sp)
        move.l  8+4(%sp),%a1                      | p  (two saves above the arg)
        move.l  %a1,-(%sp)                        | push p
        move.l  (%a1),%a0                         | vptr
        move.l  VT_STORAGE(%a0),%a0
        jsr     (%a0)
        addq.l  #4,%sp
        move.l  %d0,%a0
        move.l  (%sp)+,%a1
        move.l  (%sp)+,%d1
        rts

        | ------------------------------------------------------------------
        | boolop_get_ui(Pattern *p) -> composite 0..7
        |
        | Replaces the jsr target in the get-by-id switch arm. The caller sign
        | extends the low byte and shifts left 8, so only the byte matters.
        | euclid_bool_op_get itself is left alone: euclid_generate uses it as an
        | index into a four-entry combiner array and must keep seeing 0..3.
        | ------------------------------------------------------------------
        .align  2
boolop_get_ui:
        move.l  %a0,-(%sp)
        move.l  4+4(%sp),-(%sp)                   | p
        jsr     euclid_bool_op_get                | d0.b = operator, 0..3
        addq.l  #4,%sp
        moveq   #3,%d1
        and.l   %d1,%d0
        move.l  %d0,-(%sp)                        | keep the operator
        move.l  4+4+4(%sp),-(%sp)                 | p
        jsr     storage_ptr
        addq.l  #4,%sp
        move.l  (%sp)+,%d0
        move.l  %a0,%d1                           | null test; d1 is scratch
        beq.s     1f
        btst    #1,OFF_EUCLID_ENABLED(%a0)        | accent flag
        beq.s     1f
        bset    #2,%d0                            | composite = op | (accent << 2)
1:      move.l  (%sp)+,%a0
        rts

        | ------------------------------------------------------------------
        | boolop_set_ui(Pattern *p, int v)
        |
        | Replaces the jsr target in the set-by-id switch arm. Splits the
        | composite back into the two fields. The operator goes through the stock
        | setter so its clamp and its change notification still run; the accent
        | flag is written straight into bit 1, which no stock code touches.
        | ------------------------------------------------------------------
        .align  2
boolop_set_ui:
        move.l  %d2,-(%sp)
        move.l  %a0,-(%sp)
        move.l  8+8(%sp),%d2                      | v
        move.l  %d2,%d0
        moveq   #3,%d1
        and.l   %d1,%d0
        move.l  %d0,-(%sp)                        | operator
        move.l  8+4+4(%sp),-(%sp)                 | p
        jsr     euclid_bool_op_set
        addq.l  #8,%sp
        move.l  8+4(%sp),-(%sp)                   | p
        jsr     storage_ptr
        addq.l  #4,%sp
        move.l  %a0,%d1                           | null test; d1 is scratch
        beq.s     2f
        btst    #2,%d2                            | accent requested?
        beq.s     1f
        bset    #1,OFF_EUCLID_ENABLED(%a0)
        bra.s     2f
1:      bclr    #1,OFF_EUCLID_ENABLED(%a0)
2:      move.l  (%sp)+,%a0
        move.l  (%sp)+,%d2
        rts


        | ------------------------------------------------------------------
        | Bool Operator labels, eight entries.
        |
        | These feed euclid_bool_op_format, which is NOT the icon renderer - it
        | fills the transient text popup that names the value as you turn the
        | encoder. An earlier revision removed these patches on the grounds that
        | the page draws icons; the popup then showed ERR for the four new
        | values, which is how the text path announced itself.
        |
        | The first four entries reuse the stock strings so the base operators
        | read identically.
        | ------------------------------------------------------------------
        .align  2
boolop_labels:
        .long   0x40242cdf                        | OR
        .long   0x402587e4                        | XOR
        .long   0x4024887d                        | AND
        .long   0x40241c97                        | SUB
        .long   lbl_or_a
        .long   lbl_xor_a
        .long   lbl_and_a
        .long   lbl_sub_a

lbl_or_a:       .asciz  "OR*"
lbl_xor_a:      .asciz  "XOR*"
lbl_and_a:      .asciz  "AND*"
lbl_sub_a:      .asciz  "SUB*"

        | ==================================================================
        | Phase 2
        | ==================================================================

        | ------------------------------------------------------------------
        | trig_fire's grid arm, with the accent OR.
        |
        | Reached by a jmp that replaced `mvzw %a2@(0,%d0:l),%d2` and the `bras`
        | after it. On arrival a2 is the pattern base, a3 the track offset, d3 the
        | step and d0 = a3 + step*2. d0 is dead once we leave - the join reloads it
        | from d2 - but it is saved anyway so nothing here rests on that.
        |
        | An accent track carries raw & 3 == 3, so the euclid test at 0x4009aaca
        | (masked to bits 0..1 by trig_fire_euclid_masked) sends it down this arm.
        | ------------------------------------------------------------------
        .align  2
trig_fire_accent:
        mvzw    %a2@(0,%d0:l),%d2                 | displaced: d2 = trigword[step]
        move.l  %a0,-(%sp)
        move.l  %d0,-(%sp)
        lea     %a2@(0,%a3:l),%a0                 | a0 = track base
        move.b  OFF_EUCLID_ENABLED(%a0),%d0
        and.l   #3,%d0                            | BOTH bits: euclid on AND accent
        cmp.l   #3,%d0
        bne.s     1f                                | with euclid off the map is stale
        lea     OFF_EUCLID_STEP_MAP(%a0),%a0      | 0x2d1 is past an 8-bit displacement
        move.b  %a0@(0,%d3:l),%d0                 | map[step]
        tst.b   %d0
        bmi.s     1f                                | < 0, no euclidean hit here
        bset    #3,%d2                            | TRIG_BIT_ACCENT; the join resets the flags
1:      move.l  (%sp)+,%d0
        move.l  (%sp)+,%a0
        jmp     trig_fire_flags_join

        | ------------------------------------------------------------------
        | euclid_bake gate.
        |
        | Entered by a jmp at the function entry, so the stack is untouched:
        | (%sp) is the return address and 4(%sp) the Pattern *.
        |
        | In accent mode the bake must freeze what was being heard, which is the
        | pattern's own trigs with accents added - so nothing moves and nothing is
        | cleared. Otherwise re-emit the displaced prologue and fall into stock.
        | ------------------------------------------------------------------
        .align  2
euclid_bake_gate:
        move.l  %a0,-(%sp)
        move.l  8(%sp),-(%sp)                     | p
        jsr     storage_ptr
        addq.l  #4,%sp
        move.l  %a0,%d1                           | null test; d1 is scratch at entry
        beq.s     1f
        btst    #1,OFF_EUCLID_ENABLED(%a0)
        beq.s     1f
        move.l  (%sp)+,%a0
        move.l  4(%sp),-(%sp)                     | p
        jsr     bake_accents
        addq.l  #4,%sp
        rts
1:      move.l  (%sp)+,%a0                        | stock path, stack as at entry
        lea     %sp@(-120),%sp                    | displaced
        moveml  %d2-%d7/%a2-%fp,%sp@              | displaced
        jmp     euclid_bake_body

        | ------------------------------------------------------------------
        | bake_accents(Pattern *p)
        |
        | For every step the euclidean map hits that already has a trig, set
        | ACCENT. Bracketed the way microtiming_change brackets its bulk edit, so
        | the change is grouped and notified once.
        | ------------------------------------------------------------------
        .align  2
bake_accents:
        lea     -16(%sp),%sp                      | ColdFire movem has no -(An)
        movem.l %d2-%d4/%a2,(%sp)
        move.l  20(%sp),%a2                       | p

        pea     1
        pea     1
        move.l  %a2,-(%sp)
        move.l  (%a2),%a0
        move.l  VT_BATCH(%a0),%a0
        jsr     (%a0)                             | begin batch
        lea     12(%sp),%sp

        move.l  %a2,-(%sp)
        jsr     pattern_length
        addq.l  #4,%sp
        move.l  %d0,%d3                           | len
        moveq   #0,%d2                            | step

2:      cmp.l   %d3,%d2
        bge.s     4f

        move.l  %d2,-(%sp)
        move.l  %a2,-(%sp)
        jsr     euclid_step_map_get
        addq.l  #8,%sp
        ext.w   %d0                               | the map byte is signed
        ext.l   %d0
        bmi.s     3f                                | no euclidean hit

        move.l  %d2,-(%sp)
        move.l  %a2,-(%sp)
        jsr     pattern_step_has_trig
        addq.l  #8,%sp
        tst.b   %d0
        beq.s     3f                                | nothing here to accent

        pea     1                                 | on
        pea     TRIG_BIT_ACCENT                   | mask
        move.l  %d2,-(%sp)                        | step
        move.l  %a2,-(%sp)                        | p
        jsr     trig_flags_set
        lea     16(%sp),%sp

3:      addq.l  #1,%d2
        bra.s     2b

4:      clr.l   -(%sp)
        clr.l   -(%sp)
        move.l  %a2,-(%sp)
        move.l  (%a2),%a0
        move.l  VT_BATCH(%a0),%a0
        jsr     (%a0)                             | end batch
        lea     12(%sp),%sp

        clr.l   -(%sp)
        move.l  %a2,-(%sp)
        move.l  (%a2),%a0
        move.l  VT_NOTIFY(%a0),%a0
        jsr     (%a0)
        addq.l  #8,%sp

        movem.l (%sp),%d2-%d4/%a2
        lea     16(%sp),%sp
        rts

        | ------------------------------------------------------------------
        | euclid_enabled_get / _set, reimplemented.
        |
        | Bit 1 of the euclid-enable byte carries the accent flag and bits 2..5 are
        | free for other mods, so stock's two accessors have to stop trampling them:
        |
        |   get  must return raw & 1, or euclid_generate - which tests for exactly
        |        1 - would stop running on an accent track carrying raw == 3
        |   set  must preserve bits 1..7, or every turn-off would clear them.
        |        The toggle handler calls set(p, 0) on EVERY turn-off, FUNC or not.
        |
        | Both are small enough to reimplement outright rather than patch in place.
        | The notify call is replicated exactly: stock puts a pointer to the change
        | descriptor in a stack local and passes that local's address.
        | ------------------------------------------------------------------
        .equ    EUCLID_CHANGE_INFO, 0x401e0898

        .align  2
euclid_enabled_get_masked:
        move.l  %a0,-(%sp)
        move.l  8(%sp),-(%sp)                     | p
        jsr     storage_ptr
        addq.l  #4,%sp
        clr.l   %d0
        move.l  %a0,%d1                           | null test; d1 is scratch
        beq.s     1f
        move.b  OFF_EUCLID_ENABLED(%a0),%d0
        moveq   #1,%d1
        and.l   %d1,%d0
1:      move.l  (%sp)+,%a0
        rts

        .align  2
euclid_enabled_set_keep:
        move.l  %d2,-(%sp)
        move.l  %a0,-(%sp)
        move.l  16(%sp),%d2                       | v
        move.l  12(%sp),-(%sp)                    | p
        jsr     storage_ptr
        addq.l  #4,%sp
        move.l  %a0,%d1                           | null test; d1 is scratch
        beq.s     3f
        mvzb    OFF_EUCLID_ENABLED(%a0),%d0
        bclr    #0,%d0                            | keep accent and the free bits
        tst.l   %d2
        ble.s     1f
        bset    #0,%d0                            | stock clamps anything > 0 to 1
1:      move.b  %d0,OFF_EUCLID_ENABLED(%a0)

        lea     -4(%sp),%sp                       | the stack local stock uses
        move.l  #EUCLID_CHANGE_INFO,(%sp)
        move.l  %sp,%d0
        move.l  %d0,-(%sp)                        | &local
        move.l  20(%sp),%a0                       | p
        move.l  %a0,-(%sp)
        move.l  (%a0),%a0
        move.l  VT_NOTIFY(%a0),%a0
        jsr     (%a0)
        lea     12(%sp),%sp

3:      move.l  (%sp)+,%a0
        move.l  (%sp)+,%d2
        rts

        | ------------------------------------------------------------------
        | Persistence of the euclid-enable byte's spare bits.
        |
        | pattern_track_save packs the euclid-enable byte into storage +0x279 as
        | (raw << 7) in a single byte, so only bit 0 survives, and
        | pattern_track_load unpacks bit 7 alone. Bits 2..6 of that storage byte
        | are ignored by the load and written as zero by the save, so live bits
        | 1..5 ride there, shifted up by one:
        |
        |   live +0x2ca   bit 0 enable | bit 1 accent | bits 2..5 free for mods
        |   storage +0x279 bit 7 enable | bit 2 accent | bits 3..6   | bits 0..1 operator
        |
        | save: reached by a jmp over `mvsb %a2@(714),%d0; lsll #7,%d0`. a2 is the
        |       live track, d0 the packed byte under construction, d1 the operator.
        | load: reached by a jmp over `addl %d0,%d0; subxl %d0,%d0; negl %d0`, with
        |       d0 = storage[+0x279] sign-extended and a3 the storage track. The
        |       result is stored to live +0x2ca at the resume point.
        | ------------------------------------------------------------------
        .equ    OFF_STORAGE_EUCLID, 0x279

        .align  2
pattern_save_accent:
        mvsb    %a2@(714),%d0                     | displaced
        lsll    #7,%d0                            | displaced
        move.l  %d3,-(%sp)
        move.b  OFF_EUCLID_ENABLED(%a2),%d3
        and.l   #0x3e,%d3                         | live bits 1..5
        lsl.l   #1,%d3                            | -> storage bits 2..6
        or.l    %d3,%d0
        move.l  (%sp)+,%d3
        jmp     pattern_track_save_euclid_resume

        .align  2
pattern_load_accent:
        addl    %d0,%d0                           | displaced: d0 = bit 7 ? 1 : 0
        subxl   %d0,%d0                           | displaced
        negl    %d0                               | displaced
        move.l  %d1,-(%sp)
        move.b  OFF_STORAGE_EUCLID(%a3),%d1
        and.l   #0x7c,%d1                         | storage bits 2..6
        lsr.l   #1,%d1                            | -> live bits 1..5
        or.l    %d1,%d0
        move.l  (%sp)+,%d1
        jmp     pattern_track_load_euclid_resume

        | ------------------------------------------------------------------
        | trig_fire's euclid test.
        |
        | Stock takes the euclidean path when the enable byte is exactly 1. Accent
        | tracks carry 3 and must take the grid path, which that test already
        | gives. Other mods' bits 2..5 must not change the outcome, so the byte is
        | masked to bits 0..1 first. Reached by a jmp over `moveb %a0@(714),%d0;
        | lea %a3@(0,%d7:l:2),%a1`; the eorl/tstb/seq that follow run unchanged.
        | ------------------------------------------------------------------
        .align  2
trig_fire_euclid_masked:
        moveb   %a0@(714),%d0                     | displaced
        lea     %a3@(0,%d7:l:2),%a1               | displaced
        and.l   #0xffffff03,%d0                   | low byte to bits 0..1; moveb left the rest
        jmp     trig_fire_euclid_flag_resume

        | ------------------------------------------------------------------
        | Accent icons: the four stock gate glyphs with a dot in the top right.
        |
        | Column-major, one 32-bit word per column, 17 wide. For a bitmap of
        | height h the rows occupy the TOP h bits with the LOWEST of those bits as
        | the top row - so for h = 12, bit 20 is row 0 and bit 31 is row 11. That
        | is the opposite of the obvious reading, and it was established on
        | hardware: a mark written to bit 20 appeared above the glyph, not below.
        |
        | The mark is a 2x2 dot at rows 0..1, columns 15..16. Row 0 is empty in all
        | four glyphs and row 1 is clear at the right edge; the only thing near
        | that corner is the output line at row 6, well below it.
        | ------------------------------------------------------------------
        .align  2
accent_pixels:
        | OR*
        .long   0x20800000, 0x20800000, 0x20800000, 0xa0a00000, 0xe0e00000, 0x9f200000
        .long   0x80200000, 0x40400000, 0x40400000, 0x40400000, 0x20800000, 0x20800000
        .long   0x11000000, 0x0e000000, 0x04000000, 0x04300000, 0x04300000
        | XOR*
        .long   0xa0a00000, 0x60c00000, 0x3f800000, 0xa0a00000, 0xe0e00000, 0x9f200000
        .long   0x80200000, 0x40400000, 0x40400000, 0x40400000, 0x20800000, 0x20800000
        .long   0x11000000, 0x0e000000, 0x04000000, 0x04300000, 0x04300000
        | AND*
        .long   0x20800000, 0x20800000, 0x20800000, 0x20800000, 0xffe00000, 0x80200000
        .long   0x80200000, 0x80200000, 0x80200000, 0x80200000, 0x40400000, 0x40400000
        .long   0x20800000, 0x1f000000, 0x04000000, 0x04300000, 0x04300000
        | SUB*
        .long   0x00000000, 0x3f800000, 0x2d800000, 0x20800000, 0x2f800000, 0x3f800000
        .long   0x00000000, 0x04000000, 0x04000000, 0x04000000, 0x00000000, 0x3f800000
        .long   0x22800000, 0x2a800000, 0x28800000, 0x3fb00000, 0x00300000

        | Eight Bitmap objects, 28 bytes each: the four copied from stock
        | plus the four built above.
        .align  2
boolop_bitmaps:
        .space  224

        | ------------------------------------------------------------------
        | bitmapset8(set, first4, count, arg4)
        |
        | Replaces the bitmap_set_make call that builds the Bool Operator icon
        | set with four icons. Copies the four stock Bitmap objects - which the
        | caller has just constructed on its stack - into our array, builds four
        | more from the accent pixel data, and calls through with eight.
        |
        | The stock objects are copied rather than rebuilt so the base four stay
        | byte-identical to what the machine shipped with.
        | ------------------------------------------------------------------
        .equ    ICON_MASK, 0x402bec94             | shared full-height mask
        .equ    ICON_W,    17
        .equ    ICON_H,    12

        .align  2
bitmapset8:
        lea     -16(%sp),%sp
        movem.l %d2-%d3/%a2-%a3,(%sp)
        .ifeq   P_DIAG_ICONS
        move.l  24(%sp),%a2                       | first4
        lea     boolop_bitmaps,%a3
        moveq   #28,%d2                           | 4 objects * 28 bytes / 4
1:      move.l  (%a2)+,(%a3)+
        subq.l  #1,%d2
        bne.s     1b
        lea     accent_pixels,%a2
        lea     boolop_bitmaps+112,%a3
        moveq   #0,%d2
        .else
        | DIAGNOSTIC: build slots 0..3 from the accent artwork too, so the four
        | values you can already reach visibly gain an underline. If they do, this
        | set is what the page draws and the build is live; if they do not, it is
        | neither, and the range is not the only thing wrong.
        lea     accent_pixels,%a2
        lea     boolop_bitmaps,%a3
        moveq   #0,%d2
        .endif
2:      move.l  #ICON_MASK,-(%sp)
        move.l  %a2,-(%sp)
        pea     ICON_H
        pea     ICON_W
        move.l  %a3,-(%sp)
        jsr     bitmap_ctor
        lea     20(%sp),%sp
        lea     68(%a2),%a2                       | 17 columns * 4 bytes
        lea     28(%a3),%a3
        addq.l  #1,%d2
        .ifeq   P_DIAG_ICONS
        moveq   #4,%d0                            | d0 is dead after bitmap_ctor
        cmp.l   %d0,%d2
        .else
        moveq   #4,%d0
        cmp.l   %d0,%d2                           | four slots, starting at 0
        .endif
        bne.s     2b

        move.l  32(%sp),-(%sp)                    | arg4
        pea     8                                 | count, was 4
        pea     boolop_bitmaps
        move.l  32(%sp),-(%sp)                    | set
        jsr     bitmap_set_make
        lea     16(%sp),%sp

        movem.l (%sp),%d2-%d3/%a2-%a3
        lea     16(%sp),%sp
        rts

        | ------------------------------------------------------------------
        | Range probe.
        |
        | Four attempts to find the encoder's clamp by reading code have failed:
        | param_info+4/+8 are step sizes, param_info+0x10 is the acceleration
        | triple, and the icon set's count does not drive it either. So ask the
        | machine instead.
        |
        | On every param_info call for Bool Operator, walk its 84-byte record and
        | rewrite any long equal to 3 or 0x300 - the plausible spellings of "max
        | is four values" - into 7 or 0x700. If the encoder then runs past SUB,
        | the range does live in this record and the next build narrows down
        | which word it was. If nothing changes, it is somewhere else entirely
        | and no amount of further reading of this table is worth it.
        | ------------------------------------------------------------------
        .if     P_PROBE_RANGE
        .align  2
param_info_probe:
        move.l  %d0,-(%sp)
        move.l  %sp@(8),%d0                       | id, one save above the arg
        cmp.l   #PARAM_ID_BOOL_OP,%d0
        bne.s     9f
        move.l  %d2,-(%sp)
        move.l  %a0,-(%sp)
        lea     (PARAM_INFO_BASE + PARAM_ID_BOOL_OP*84),%a0
        moveq   #21,%d2                           | 84 bytes / 4
1:      move.l  %a0@,%d0                          | ColdFire cmpi needs a register
        cmp.l   #3,%d0
        bne.s     2f
        move.l  #7,%a0@
        bra.s     3f
2:      cmp.l   #0x300,%d0
        bne.s     3f
        move.l  #0x700,%a0@
3:      lea     %a0@(4),%a0
        subq.l  #1,%d2
        bne.s     1b
        move.l  (%sp)+,%a0
        move.l  (%sp)+,%d2
9:      move.l  (%sp)+,%d0
        move.l  %sp@(4),%d1                       | displaced, kept adjacent
        cmp.l   #469,%d1                          | displaced; its flags feed the scs
        jmp     param_info_resume
        .endif

        | ------------------------------------------------------------------
        | Bool Operator's encoder, handled outright.
        |
        | Five attempts to find the stock clamp failed, so this stops looking for
        | it. param_apply_delta is confirmed on the page's value path - forcing
        | boolop_get_ui to a constant pinned the icon on hardware - and it
        | receives the encoder delta BEFORE the target dispatch that clamps. So
        | for this one parameter we apply the delta ourselves and return, and the
        | stock clamp is never reached rather than being widened.
        |
        | Entered by a jmp at the function's entry, so the stack is untouched:
        | (%sp) return, 4 view, 8 id, 12 delta, 16 funcHeld, 20 outFlag.
        | The delta is 8.8, as everywhere on this path.
        | ------------------------------------------------------------------
        .equ    BOOLOP_MAX, 7

        .align  2
param_delta_gate:
        move.l  %sp@(8),%d0                       | parameter id
        cmp.l   #PARAM_ID_BOOL_OP,%d0
        bne.s     9f

        move.l  %d2,-(%sp)
        move.l  %a2,-(%sp)
        move.l  %sp@(20),%d2                      | delta, 8.8
        asr.l   #8,%d2                            | -> whole steps, sign preserved
        beq.s     8f                                | a sub-step nudge changes nothing
        jsr     project_singleton
        move.l  %d0,-(%sp)
        jsr     current_track_pattern
        addq.l  #4,%sp
        move.l  %d0,%a2                           | the track's pattern
        move.l  %a2,-(%sp)
        jsr     boolop_get_ui
        addq.l  #4,%sp
        mvzb    %d0,%d0                           | it returns a byte
        add.l   %d2,%d0
        bpl.s     1f
        clr.l   %d0                               | clamp low
        bra.s     2f
1:      moveq   #BOOLOP_MAX,%d1
        cmp.l   %d1,%d0
        ble.s     2f
        move.l  %d1,%d0                           | clamp high
2:      move.l  %d0,-(%sp)
        move.l  %a2,-(%sp)
        jsr     boolop_set_ui
        addq.l  #8,%sp
8:      move.l  (%sp)+,%a2
        move.l  (%sp)+,%d2
        rts

9:      lea     %sp@(-12),%sp                     | displaced
        moveml  %d2-%d3/%a2,%sp@                  | displaced
        jmp     param_apply_delta_resume

        | ------------------------------------------------------------------
        | Bool Operator's value text.
        |
        | The transient popup that names the value does NOT go through
        | euclid_bool_op_format. Its caller first asks obj->vtable[0x24] to turn
        | the value into text, and prints ERR when that reports failure - which
        | is what the four new values were doing. Widening the label table alone
        | never touched this path.
        |
        | So the same treatment as the encoder: intercept above the virtual and
        | answer for parameter 467 ourselves, mirroring exactly what the stock
        | ERR path does - overwrite the first two argument slots and tail-call
        | the formatter, but with our label instead of "ERR".
        |
        | Entered by a jmp at the entry, so the stack is untouched:
        | (%sp) return, 4 obj, 8 id, 12 value, 16 the formatter's own first arg.
        | d0/a0 are scratch under this ABI, so nothing needs saving.
        | ------------------------------------------------------------------
        .align  2
boolop_text_gate:
        move.l  %sp@(8),%d0                       | parameter id
        cmp.l   #PARAM_ID_BOOL_OP,%d0
        bne.s     9f

        move.l  %sp@(12),%d0                      | value
        moveq   #BOOLOP_MAX,%d1
        cmp.l   %d1,%d0
        ble.s     1f                                | already a plain index
        asr.l   #8,%d0                            | otherwise it is 8.8
1:      bpl.s     2f
        clr.l   %d0
2:      cmp.l   %d1,%d0
        ble.s     3f
        moveq   #BOOLOP_MAX,%d0
3:      lea     boolop_labels,%a0
        move.l  %a0@(0,%d0:l:4),%d0               | our label for this value
        move.l  %sp@(16),%sp@(4)                  | mirror the stock ERR tail
        move.l  %d0,%sp@(8)
        jmp     param_text_format

9:      lea     %sp@(-20),%sp                     | displaced
        moveml  %d2-%d4/%a2-%a3,%sp@              | displaced
        jmp     param_value_text_resume
