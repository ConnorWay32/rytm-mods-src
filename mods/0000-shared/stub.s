        | Mod 0000 - the shared runtime.
        |
        | Everything here is called from other mods' stubs through build/shared.inc,
        | which tools/build.py generates from the shared_ labels below. Nothing here
        | detours anything, and nothing here reads mod state: each caller passes what
        | it needs and owns its own LCG word, so the streams stay independent.

        .include "symbols.inc"

        .equ    RND_LCG_A,      1103515245        | Numerical Recipes' multiplier
        .equ    VT_STORAGE,     0x28              | the accessor's live-sound getter
        .equ    PROJ_TRACKSEL,  48
        .equ    PROJ_KIT,       352

        .text

        | ------------------------------------------------------------------
        | shared_amounts - the sixteen settings a random depth can take, and
        | shared_stops - where those sixteen sit on a 0..127 knob.
        |
        | The stops are what make a knob read as a sixteen-position selector: they
        | are the settings spread evenly over the travel, so each step moves the
        | needle the same distance. Callers reach both with one pc-relative lea, so
        | the order matters: amounts first.
        | ------------------------------------------------------------------
        .align  2
shared_amounts:
        .byte   0, 1, 2, 3, 4, 6, 8, 10, 12, 16, 20, 24, 32, 40, 48, 64
shared_stops:
        .byte   0, 8, 17, 25, 34, 42, 51, 59, 68, 76, 85, 93, 102, 110, 119, 127

        | ------------------------------------------------------------------
        | shared_fmt_u8(d0 = 0..99, a1 = output) - writes it as decimal, terminated
        |
        | Leading zero suppressed, so 0 prints as "0" and not "00". Advances a1 past
        | the digits and leaves the terminator at (a1). Clobbers d0/d1/a1.
        | ------------------------------------------------------------------
        .align  2
shared_fmt_u8:
        divu.w  #10,%d0                           | low word tens, high word units
        tst.w   %d0
        beq.s   1f
        moveq   #0x30,%d1
        add.l   %d0,%d1
        move.b  %d1,(%a1)+
1:      swap    %d0
        moveq   #0x30,%d1
        add.l   %d0,%d1
        move.b  %d1,(%a1)+
        clr.b   (%a1)
        rts

        | ------------------------------------------------------------------
        | shared_rnd(a0 = the caller's LCG word, d1 = N) -> d0 = -N..N
        |
        | One step of a 32-bit LCG, x = x * 1103515245 + 1, reduced to the range by
        | the high half: the low bits of an LCG are famously short-period, so the
        | word is swapped before the remainder is taken. N = 0 answers 0. The state
        | word belongs to the caller, so two callers never share a stream.
        | Clobbers d0/d1.
        | ------------------------------------------------------------------
        .align  2
shared_rnd:
        move.l  %d1,-(%sp)                        | N
        move.l  (%a0),%d0
        move.l  #RND_LCG_A,%d1
        mulsl   %d1,%d0
        addq.l  #1,%d0
        move.l  %d0,(%a0)                         | the next state
        swap    %d0                               | the high bits are the good ones
        move.l  (%sp),%d1
        add.l   %d1,%d1
        addq.l  #1,%d1                            | 2N + 1
        remul   %d1,%d1,%d0                       | d1 = d0 % (2N + 1)
        move.l  %d1,%d0
        sub.l   (%sp)+,%d0                        | -N..N
        rts

        | ------------------------------------------------------------------
        | shared_cur_sound() -> d0 = a0 = the selected track's live sound, or 0
        | shared_sound_of(d0 = track) -> the same for one track
        |
        | project -> the track (its own selection, or the one passed) -> active kit
        | -> kit_track_sound -> the accessor's vtable +0x28. Pure lookups, no state.
        | Both clobber d0/d1/a0/a1, like any call, and return with the flags set from
        | d0 so a caller can branch on "no sound" straight away.
        | ------------------------------------------------------------------
        .align  2
shared_cur_sound:
        jsr     project_singleton
        move.l  %d0,%a0
        pea     PROJ_TRACKSEL(%a0)
        jsr     track_index_of
        addq.l  #4,%sp                            | d0 = the selected track
shared_sound_of:
        move.l  %d0,-(%sp)                        | track, as the second argument
        jsr     project_singleton
        move.l  %d0,%a0
        pea     PROJ_KIT(%a0)                     | the active kit
        jsr     kit_track_sound
        addq.l  #8,%sp
        move.l  %d0,-(%sp)                        | the accessor is the argument
        move.l  %d0,%a0
        move.l  (%a0),%a1
        move.l  VT_STORAGE(%a1),%a1
        jsr     (%a1)
        addq.l  #4,%sp
        move.l  %d0,%a0
        tst.l   %d0
        rts

        | ------------------------------------------------------------------
        | shared_mark_changed(a2 = the page view)
        | shared_mark_changed_set(a1 = the parameter set)
        |   both with (%sp) the parameter id and 4(%sp) the value
        |
        | The sound that gets saved is the storage record, and that record is only
        | refreshed from the changed bitmap the kit's parameter bank carries: the
        | dirty byte wakes the thread that drains it, and each set bit becomes a
        | record for the track's sound mirror. Writing the live sound alone leaves
        | the project holding the previous value.
        |
        | This is the call stock's own sound parameter setter makes for the parameter
        | it has just written - value, changed bit and dirty byte in one place - on
        | the accessor the view hands out for the track it is on.
        | ------------------------------------------------------------------
        .align  2
shared_mark_changed:
        move.l  (%a2),%a0                         | the view's vtable
        move.l  160(%a0),%a0
        move.l  #-1,-(%sp)                        | its own track
        move.l  %a2,-(%sp)
        jsr     (%a0)
        addq.l  #8,%sp
        move.l  %d0,%a1
shared_mark_changed_set:
        move.l  %a1,%d0
        beq.s   9f
        move.l  %d0,%a0
        move.l  4(%sp),%a1                        | the id
        move.l  8(%sp),%d0                        | the value
        move.l  8(%a0),%d1                        | the track
        move.l  4(%a0),%a0                        | the kit's parameter bank
        move.l  %d0,-(%sp)                        | value
        move.l  %a1,-(%sp)                        | id
        move.l  %d1,-(%sp)                        | track
        move.l  %a0,-(%sp)                        | bank
        jsr     kit_param_changed
        lea     16(%sp),%sp
9:      rts

        | ------------------------------------------------------------------
        | shared_func_held() -> d0 non-zero while FUNC is down
        |
        | The one modifier every mod tests. Clobbers d0/d1/a0/a1, like the call it
        | wraps, so a caller whose fall-through still needs those must park them.
        | ------------------------------------------------------------------
        .align  2
shared_func_held:
        pea     KEY_FUNC
        jsr     is_key_held
        addq.l  #4,%sp
        tst.l   %d0
        rts
