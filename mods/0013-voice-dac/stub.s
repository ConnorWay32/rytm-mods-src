        | Mod 0013 - every voice to MAIN through the DAC.
        |
        | All eight voices leave the analog main bus. Each audio interrupt the
        | voice slots of the receive buffer - the voices after their analog
        | filter and amp - are panned and summed here and added to the PRE
        | return pair of the output ring, which the DAC puts back into the
        | analog mix ahead of the master distortion and compressor. A voice
        | stock has off the main bus (ROUTE TO MAIN off) stays out of the sum.
        |
        | Switched at run time by DAC SUM, the last item of the AUDIO ROUTING
        | menu. OFF is stock's routing and no sum. It is saved with the
        | project's globals, beside the routing it overrides: stored bytes
        | +12 (tag) and +13 of projectGlobalsStorage_v2_t, which stock's load
        | and save never touch; a project without the tag loads as OFF.
        |
        | Each voice is filtered before the sum, set by its track's DAC FILTER
        | page (page 13, reached by pressing FILTER again while DAC SUM is on):
        | FRQ, RES, TYP and DEP. TYP runs OFF, LP2, LP1, BP, HP1, HP2, BS, PK -
        | stock's order, its glyph TYP - 1. LP1 and HP1 are one first-order
        | section, y = b0 x + b1 x1 + p y1, two slots at a time; the others a
        | biquad each, run after (bq_coef, bq_run, in cave11). FRQ is stock's
        | FRQ scale, a semitone a step with 440 Hz at 60; RES the 2-pole types'
        | Q; DEP the filtered share of a dry/filtered mix - 0 dB (none), then
        | 0.25 dB steps of cut to -31.5 dB, then FULL, the plain filter - or for
        | PK a boost to +6 dB. The page draws stock's TYP glyph and FILTER
        | graph. The values live in the live sound's spare bytes, with no tag:
        | +0x6d bits 0-2 TYP, +0x6e bits 0-6 FRQ ^ 0x7f, +0x6f bits 0-6
        | DEP ^ 0x7f, and RES in velocity route 0's amount low byte (the
        | routes' spare bytes, rte_*), so all zero is TYP OFF, FRQ 127, DEP
        | FULL, RES 0. The other bits are spare and zero, and any field put
        | there must read zero as its default. Every live sound gets its bytes
        | from sound_init_defaults (cleared), sound_load (from the stored
        | record, or cleared when the load fails) or a whole copy of another
        | sound. sound_save writes TYP, FRQ, DEP and POL, when not all zero, to
        | the stored record's spare slots 42 and 43 as (tag + TYP) << 8 + FRQ
        | and POL << 8 + DEP, and the route bytes to slots 44..47 (sound-storage.md); a tick
        | in the UI's idle routine copies every track's into hpf_track for the
        | audio interrupt.
        |
        | The page's bottom row is ATK, SUS and POL: a transient shaper after
        | the filters (shp_run, in cave23, skipped outright while no voice
        | track has ATK or SUS set) and the voice's polarity, folded into its
        | pan gains. ATK and SUS live in velocity routes 1's and 2's spare
        | bytes, signed, POL in +0x6d bit 3; shp_track holds each track's for
        | the audio interrupt.
        |
        | Three detours, and a fourth in the timing build:
        |   route_all     0x401212b6  the route mask store: every voice off main
        |   vs_main       0x40121364  after the receive buffer fills: the filter,
        |                             in place, and the sum
        |   vs_alt        0x4011fde2  the same on the interrupt's other path
        |   dac_menu_add  0x400d901c  the menu's item list: DAC SUM after USB TO MAIN
        |   t_emit        0x40121396  timing only: the timing words, before USB
        | and, for the page and its knobs, chained behind 0004's gates where 0004
        | is built and standing alone where it is not:
        |   hpf_page_info 0x400ff592  page_info's out-of-range return: page 13
        |   hpf_cycle     0x4003ab86  the page key's cycle: FILTER's page 2 only
        |                             while DAC SUM is on
        |   hpf_get       0x4003846a  page_get_value: the dials, ids 5, 11, 12
        |   hpf_delta     0x400378bc  param_apply_delta: the knobs
        |   hpf_text      0x400a85f8  param_value_text: the popups
        |   flt_glyph     0x400a8584  param_knob_draw: TYP as stock's TYP glyph
        |   flt_graph     0x400d2e42  sound_page_draw: stock's FILTER graph
        | and for keeping the values:
        |   hpf_save      0x40008492  sound_save, after its memset: slots 42, 43
        |   hpf_load      0x4000826a  sound_load, after its clear: the live bytes
        |   snd_load      0x400081f6  sound_load's entry: the live bytes cleared
        |                             when the load will fail
        |   snd_init      0x400122d0  sound_init_defaults: the live bytes cleared
        |   hpf_refresh   0x400a2aae  the screen's idle tick: hpf_track
        | and for the routes' spare bytes (rte_*, in cave12):
        |   rte_rload     0x40008364  sound_load after its routes: slots 44..47
        |   rte_pushv     0x4011f63c  the sound push, velocity amounts: low byte
        |   rte_pusha     0x4011f660  and aftertouch amounts: low byte cleared
        |   rte_get_at    0x40033a90  the aftertouch menu's amount getter: low
        |                             byte cleared, as its display rounds the word
        |   rte_set_at    0x40033a1c  its amount setter: low byte kept
        |   rte_setrte_at 0x4003391e  its whole-route setter: low byte kept
        |   rte_get_vel   0x400c52ba  and the velocity menu's,
        |   rte_set_vel   0x400c5246  the same code
        |   rte_setrte_vel 0x400c5148 at other addresses
        | and from vs_body, by jsr: bq_run (cave11) and shp_run (cave23).
        | and for keeping DAC SUM with the project:
        |   dac_load      0x40007660  projectGlobals_t's load, after its version check
        |   dac_save      0x40007bb0  projectGlobals_t's save, before its last fields
        |
        | Addresses and layouts: re/subsystems/compressor-hardware.md.

        .include "symbols.inc"
        .include "shared.inc"

        .equ    RXBUF,          0x80007440  | receive buffer, voice slot s at +8 + 4s
        .equ    RXSTRIDE,       48
        .equ    FRAMES,         32
        .equ    VCA_L,          0x800063ca  | uint16 per physical voice
        .equ    VCA_R,          0x800063da
        .equ    SLOT_MAP,       0x401ef1d0  | physical voice -> receive slot, longs
        .equ    VOICE_OWNER,    0x40290dd8  | physical voice -> owning track, bytes
        .equ    MAIN_OFF,       0x8000ed6c  | per-track main-disable bits, or
        .equ    MAIN_OFF_G,     0x8000ee58  | the global set when MAIN_OFF < 0

        | The output ring: four slots of 32 frames at 0x80000000 + idx * 2048,
        | idx at OUT_IDX, 16 channels a frame. The PRE consumer at 0x4010eb26
        | writes channels 12 and 13 as (acc >> 8), logical, so a word shifted
        | left 8 is its Q31 value again.
        .equ    OUT_RING,       0x80000000
        .equ    OUT_IDX,        0x42f92124
        .equ    OUT_PRE,        48          | channel 12's byte offset in a frame
        .equ    OUT_STRIDE,     64

        .equ    ROUTE_RESUME,   0x401212bc
        .equ    MAIN_RESUME,    0x4012136c        | after `lea 0x4013f56c,%a0`
        .equ    MAIN_LEA,       0x4013f56c
        .equ    ALT_FILL,       0x4010e944        | the other path's fill
        .equ    ALT_RESUME,     0x4011fde8
        .equ    FX_SENDS,       0x4010e650        | the timing build's emitter
        .equ    EMIT_RESUME,    0x401213a0
        .equ    DTCN0,          0xfc07000c        | DMA timer 0, about 130 MHz
        .equ    MUP_INT,        0x8000fbde        | compressor MUP's integer part, CC 81
        .equ    MIX_INT,        0x8000fbe0        | and MIX's, CC 84
        .equ    T_SLOT,         8 + 4 * 7         | voice slot 7, the timing build's channel
        | vs_body's stack table, above the saved MACSR and registers
        .equ    COEF,           64                | (cL, cR) per slot, and a spare word
        .equ    ENT,            132               | the owning track's hpf_track entry per slot

        | AudioRoutingMenuView's item list, 0x400d8cb6. Each item is four
        | std::function objects on the stack - label, an empty one, the value
        | drawer, the value changer - a 0x54-byte MenuItem, and an append
        | through the view's vtable +8. The label and drawer take USB OUT's
        | managers: its lambdas capture nothing, as those do. The changer
        | captures the view, for the redraw, and has a manager of its own.
        .equ    MENU_ITEM_CTOR, 0x40072f50
        .equ    MGR_LABEL,      0x400d8aca
        .equ    MGR_DRAW,       0x400d8b1c
        .equ    MENU_RESUME,    0x400d9022
        .equ    TEXT_WIDTH,     0x40071b86        | (font, -1, std::string *) -> px
        .equ    MENU_FONT,      0x4027a6c8
        .equ    VIEW_INVALIDATE, 0x40078514       | (view + 56), as 0x400d9038 does

        | Two tests: | begins a comment, so `a || b` would test a alone.
        .if     P_SNAP < 1
        .error  "0013-voice-dac: snap must be 1 or more"
        .endif
        .if     P_K < 1
        .error  "0013-voice-dac: k must be 1 .. 16384"
        .endif
        .if     P_BURN
        .if     P_TIMING == 0
        .error  "0013-voice-dac: burn needs timing"
        .endif
        .if     P_PROF
        .error  "0013-voice-dac: burn and prof both read MUP"
        .endif
        .endif
        .if     P_K > 16384
        .error  "0013-voice-dac: k must be 1 .. 16384"
        .endif

        | The DAC FILTER page and its knobs. The ids are dead Error records,
        | renamed; their container index stays -1.
        .equ    PAGE_FILTER,    6
        .equ    PAGE_HPF,       13
        .equ    ID_FRQ,         5
        .equ    ID_TYP,         11
        .equ    ID_DEP,         12
        .equ    ID_RES,         13
        .equ    ID_ATK,         7                 | Error, renamed
        .equ    ID_SUS,         14                | Error, renamed
        .equ    ID_POL,         457               | CB TEST's CB_OSC_SELECT, renamed: the
                                                  | TEST machines are hidden
        .equ    ID_STOCK_PAN,   62                | its encoder feel, for ATK and SUS
        .equ    ID_STOCK_FINE,  40                | SAMPLE FINE: its dial, dotted at 0
        .equ    PI_DRAW,        0x24              | RAM record: the knob's draw callback
        .equ    ID_STOCK_FRQ,   47                | stock's FRQ and TYP, whose popups,
        .equ    ID_STOCK_TYP,   49                | glyph and graph ours borrow
        .equ    ID_STOCK_RES,   48
        .equ    PARAM_INFO,     0x419a4888        | RAM records, 0x54 bytes an id: +4 and
        .equ    PI_STRIDE,      0x54              | +8 the encoder's range (8.8), +0x10
                                                  | its acceleration profile's pointer
        | TYP values: OFF, then stock's FILTER types in its order, each its
        | stock TYP index + 1. LP1 and HP1 are the 1-pole section; the others
        | a biquad each.
        .equ    TYP_OFF,        0
        .equ    TYP_LP2,        1
        .equ    TYP_LP1,        2
        .equ    TYP_BP,         3
        .equ    TYP_HP1,        4
        .equ    TYP_HP2,        5
        .equ    TYP_BS,         6
        .equ    TYP_PK,         7
        .equ    FRQ_MAX,        127
        .equ    DEP_FULL,       127               | DEP 0 is 0 dB, no filter
        .equ    OFF_FLT_TYP,    0x6d              | live sound: TYP, FRQ ^ 0x7f, DEP ^ 0x7f
        .equ    OFF_FLT_FRQ,    0x6e
        .equ    OFF_FLT_DEP,    0x6f
        .equ    FLT_TYP_BITS,   0x07              | +0x6d's TYP; the rest spare
        .equ    FLT_7_BITS,     0x7f              | +0x6e's FRQ, +0x6f's DEP; bit 7 spare
        .equ    FLT_TAG,        0xb8              | stored: 0xb8..0xbf; else untagged
        | The routes' spare bytes: each velocity and aftertouch route's amount
        | is a word stock only ever sets in whole steps (byte << 8), so its low
        | byte is free. Route i's is at +0x71 + 3i (velocity) and +0x8d + 3i
        | (aftertouch); stored, the eight are slots 44..47 in that order.
        .equ    OFF_RTE_VEL,    0x71
        .equ    OFF_RTE_AT,     0x8d
        .equ    OFF_FLT_RES,    OFF_RTE_VEL       | RES 0..127, in velocity route 0's
        .equ    OFF_SHP_ATK,    OFF_RTE_VEL + 3   | ATK, -64..63, in route 1's
        .equ    OFF_SHP_SUS,    OFF_RTE_VEL + 6   | SUS, -64..63, in route 2's
        .equ    FLT_POL_BIT,    3                 | +0x6d: POL, the voice inverted
        .equ    SHP_K_RF,       35494783        | Ef's release, 40 ms
        .equ    SHP_K_AS,       93353822        | Es's attack, 15 ms
        .equ    SHP_K_RS,       9523193        | Es's release, 150 ms
        .equ    SHP_K_RH,       4766887        | Eh's release, 300 ms
        .equ    SHP_GATE,       2147484        | -60 dBFS
        .equ    OFF_SLOT44,     0x1c + 2 * 44
        .equ    RTE_ENGINE,     0x8000ea3c        | engine route words, 32 bytes a track
        .equ    RLOAD_OK,       0x40008378        | sound_load's success exit
        .equ    RLOAD_RESUME,   0x4000836a        | its aftertouch routes' fallback call
        .equ    PUSHV_RESUME,   0x4011f642
        .equ    PUSHA_RESUME,   0x4011f666
        .equ    SLOAD_RESUME,   0x400081fe        | sound_load past its prologue
        .equ    INIT_RESUME,    0x400122d6        | sound_init_defaults past its first clear
        | All-zero live bytes' values, as a hpf_track entry: TYP << 24 + FRQ << 16
        | + DEP << 8 (| begins a comment here, so the fields are added). FRQ is
        | stock's default, 127.
        .equ    FLT_DEFAULT,    (FRQ_MAX << 16) + (DEP_FULL << 8)
        .equ    OFF_POLE,       0x7fff7fff        | an off slot's pole: 1 - 2^-16, HP1, FULL
        .equ    OFF_B0,         0x7fffbfff        | (1 + OFF_POLE) / 2
        .equ    SOUND_PAGE_FILTER, 0x400d2e4a     | sound_page_draw: FILTER's branch,
        .equ    SOUND_PAGE_OTHER, 0x400d3134      | and every other page's
        .equ    FILTER_GRAPH,   0x40038db6        | filter_graph_draw
        .equ    CLEAR_RECT,     0x400706ba        | (canvas, x0, y0, x1, y1, colour)
        .equ    GLYPH_RESUME,   0x400a858c
        .equ    PROJ_KIT,       352               | the active kit, as 0000-shared's
        .equ    VT_SOUND,       0x28              | the sound accessor's live sound
        .equ    VT_CONFIG_CHANGED, 16             | and its change notice
        .equ    SOUND_CONFIG_CHANGED, 0x401cb5dc  | SoundConfigChangedInfo's vtable
        .equ    VOICE_TRACKS,   12
        .equ    PROJ_TRACKSEL,  48                | as 0000-shared's
        .equ    VIEW_INVALIDATE, 0x40078514
        .equ    PAGE_DEFAULT,   0x401ec570        | page_info's answer above 11
        .equ    CYCLE_RESUME,   0x4003ab8c
        .equ    GET_RESUME,     0x40038472
        .equ    DELTA_RESUME,   0x400378c2
        .equ    DELTA_CALL,     0x400b68d2
        .equ    TEXT_RESUME,    0x400a8600
        .equ    TEXT_CALL,      0x400ff556
        .equ    OFF_SLOT42,     0x1c + 2 * 42     | stored record: spare slots 42
        .equ    OFF_SLOT43,     0x1c + 2 * 43     | and 43
        .equ    SLOT43_POL,     8                 | slot 43: POL, above DEP
        .equ    SAVE_MAP,       0x401c59cc        | sound_slot_map, the displaced lea
        .equ    SAVE_RESUME,    0x40008498
        .equ    LOAD_MAP,       0x401c5a74        | its inverse, the displaced lea
        .equ    LOAD_RESUME,    0x40008270
        .equ    IDLE_RESUME,    0x400a2ab6
        | DAC SUM in the project's globals (projectGlobalsStorage_v2_t, loaded
        | by 0x4000763c and saved by 0x40007a5c; stored bytes 12..24 are
        | touched by neither). ProjectGlobals is the project's member at +236;
        | its vtable +80, called with (object, 0), is the change notice stock's
        | routing setters end with.
        .equ    OFF_DAC_TAG,    12
        .equ    OFF_DAC_ON,     13
        .equ    DAC_TAG,        0xd5
        .equ    PROJ_GLOBALS,   236
        .equ    VT_CHANGED,     80
        .equ    DLOAD_RESUME,   0x40007666
        .equ    DSAVE_RESUME,   0x40007bb8

        .if     P_TIMING
        | tpeak(side): the timing build's headroom counters - the block's
        | largest |sum| in Q31, and how many side-frames reached full scale, the
        | saturating movclr's ceiling (0x7fffff00 and up). d0 is free here.
        .macro  tpeak r
        move.l  \r,%d0
        bpl.s   1f
        neg.l   %d0
1:      cmp.l   t_pk,%d0
        bls.s   2f
        move.l  %d0,t_pk
2:      cmp.l   #0x7fffff00,%d0
        bcs.s   3f
        addq.l  #1,t_clip
3:
        .endm
        .endif

        .text

        | ------------------------------------------------------------------
        | route_all: the interrupt's store of the main-disable mask, packed from
        | physical voices 7,6,5,4,0,1,2,3, MSB first. Every bit set takes every
        | voice off the analog main bus while DAC SUM is on; off, stock's mask
        | passes. d1 is reloaded straight after.
        | ------------------------------------------------------------------
        .align  2
route_all:
        tst.l   dac_on
        beq.s   1f
        moveq   #-1,%d1
1:      move.b  %d1,0x80006466                    | displaced
        jmp     ROUTE_RESUME

        | ------------------------------------------------------------------
        | vs_body: the voices, filtered in place, and their sum. It runs as
        | soon as the receive buffer holds this block's voices, before anything
        | else reads them - the sampler's meter, the FX sends, 0006's estimator,
        | USB - so all of them see the filtered voice, as they see the analog
        | filter's output; the DAC filter is part of the voice. The buffer is
        | on-chip SRAM: the data cache is write-through over DRAM (ACR0), so a
        | DRAM buffer cost a store through to memory and a line fill per read.
        | Two entries, one on each of the interrupt's paths:
        |   vs_main  0x40121364  after the fill and 0009's hook, over `moveq
        |                        #5,%d1` and the first four bytes of `lea
        |                        0x4013f56c,%a0`, both re-emitted after
        |   vs_alt   0x4011fde2  the other path (0x4011fd96), over its `jsr
        |                        0x4010e944`, the fill, re-emitted first
        | Both paths have run the PRE consumer (0x4010ede2) for this interrupt's
        | output slot by then; the sum is added to that slot. vs_body keeps
        | every register.
        |
        | Each slot is filtered first, one first-order section, two slots at a
        | time over the block with their state in registers:
        |   y = b0 * x + b1 * x1 + p * y1
        | the coefficients from its track's TYP, FRQ and DEP (flt_pole,
        | flt_gain), at the slot's own scale, so the readers downstream see
        | normal levels; an overshoot past full scale saturates. Three
        | multiply-accumulates a slot, the next x loaded during the third. x1
        | and y1 carry over between blocks in hpf_state; y replaces x in the
        | buffer. Then, frame by frame, for
        | physical voice p in slot s:
        |   f      = wL / (wL + wR), Q15, from the VCA words
        |   cL[s]  = f g[s]           } Q31
        |   cR[s]  = g[s] - cL[s]     }
        | both zero when p's owning track is off the main bus or both words are
        | zero. g[s] is the slot trim times K. The VCA words lead the audio by
        | four interrupts, so a p-locked pan change is briefly early.
        |
        | The sum costs the same every block, all eight slots multiplied
        | whatever their coefficients; the filter runs only for pairs of slots
        | with a filter on, so the worst case is every pair. timing = 1
        | measures it. MACSR is held at 0xa0 - fractional, saturating on
        | overflow, as stock's PRE consumer sets it (0x4010ede8) - and restored
        | after; the accumulators are left clear, as stock's loops leave them.
        | ------------------------------------------------------------------
        .align  2
vs_main:
        bsr.w   vs_body
        moveq   #5,%d1                            | displaced
        lea     MAIN_LEA,%a0                      | displaced
        jmp     MAIN_RESUME

        .align  2
vs_alt:
        jsr     ALT_FILL                          | displaced
        bsr.w   vs_body
        jmp     ALT_RESUME

        .align  2
vs_body:
        .if     P_TIMING
        jsr     t_start
        .endif
        .if     P_BURN
        jsr     t_burn
        .endif
        tst.l   dac_on
        bne.s   1f
        .if     P_TIMING
        jsr     t_end
        .endif
        rts                                       | DAC SUM off: no filter, no sum
1:      lea     -160(%sp),%sp
        movem.l %d0-%d7/%a0-%a6,(%sp)             | 60 B; (cL, cR) at +60, 68 B; entries at +128
        move.l  %macsr,%d0
        move.l  %d0,-(%sp)
        move.l  #0xa0,%macsr

        move.l  MAIN_OFF,%d6
        bge.s   1f
        move.l  MAIN_OFF_G,%d6
1:
        lea     COEF(%sp),%a4                     | above the saved MACSR
        lea     SLOT_MAP,%a3
        lea     VCA_L,%a1
        lea     VOICE_OWNER,%a0
        lea     gaintab,%a2
        lea     hpf_track,%a5
        moveq   #0,%d5                            | physical voice
2:      move.l  (%a3)+,%d3
        lsl.l   #3,%d3                            | slot * 8, one (cL, cR)
        move.l  %d3,%d0
        lsr.l   #1,%d0                            | slot * 4
        mvz.b   (%a0,%d5.l),%d2                   | owning track
        move.l  (%a5,%d2.l*4),%d1                 | its filter entry
        move.l  %d1,ENT-COEF(%a4,%d0.l)
        moveq   #0,%d0
        moveq   #0,%d1
        move.l  %d6,%d4
        asr.l   %d2,%d4
        btst    #0,%d4
        bne.s   3f                                | off the main bus
        mvz.w   (%a1),%d0                         | wL
        mvz.w   VCA_R-VCA_L(%a1),%d1              | wR
        add.l   %d0,%d1
        beq.s   3f                                | both zero, and so is d0
        moveq   #15,%d2
        lsl.l   %d2,%d0
        divu.l  %d1,%d0                           | f, Q15
        move.l  -4(%a3),%d1
        add.l   %d1,%d1                           | slot * 2
        mvz.w   (%a2,%d1.l),%d1                   | g, Q15
        mulu.l  %d1,%d0                           | f * g, Q30
        add.l   %d0,%d0                           | cL = f g, Q31
        swap    %d1
        clr.w   %d1                               | g, Q31
        sub.l   %d0,%d1                           | cR
3:      mvz.b   (%a0,%d5.l),%d2                   | owning track
        move.l  48(%a5,%d2.l*4),%d4               | its shp_track entry
        btst    #8,%d4
        beq.s   4f
        neg.l   %d0                               | POL: the voice inverted
        neg.l   %d1
4:      move.l  %d0,(%a4,%d3.l)
        move.l  %d1,4(%a4,%d3.l)
        addq.l  #2,%a1
        addq.l  #1,%d5
        moveq   #8,%d0
        cmp.l   %d0,%d5
        blt.s   2b

        .if     P_PROF
        mvz.b   MUP_INT,%d0
        btst    #0,%d0                            | profiling: no filter
        bne.w   9f
        .endif

        | The coefficients, a slot at a time, from its entry: (b0, b1, p) into
        | flt_coef. A slot is off when TYP is OFF or DEP is 0 dB: then it is a
        | high-pass at OFF_POLE at full depth, and a pair whose slots are both
        | off is skipped below. A 2-pole type (LP2..PK) is off here too, its
        | biquad's coefficients worked out by bq_coef and run by bq_run after
        | this pass. Otherwise, with p the pole at FRQ, h = (1 + p) / 2
        | for HP1 or (1 - p) / 2 for LP1, g the dry share and m = 1 - g,
        |   b0 = g + m h,   b1 = -(g p + m h) for HP1, m h - g p for LP1.
        | A slot whose TYP changed while FRQ did not takes the other mode's
        | state: with one pole LP1 = x - HP1, so its last output becomes
        | (1 + g) x1 - y1. Each slot keeps the entry its coefficients came from
        | in flt_key and is worked out again only when that changes; flt_key
        | starts at -1, which no entry is.
        lea     ENT(%sp),%a6
        lea     flt_coef,%a5
        lea     hpf_state,%a4
        lea     flt_key,%a3
        lea     flt_pole,%a2
        lea     flt_gain,%a1
        moveq   #7,%d7
13:     move.l  (%a6)+,%d5                        | TYP << 24 | FRQ << 16 | DEP << 8 | RES
        cmp.l   (%a3),%d5
        bne.s   20f
        lea     12(%a5),%a5                       | unchanged: as last block
        addq.l  #4,%a3
        bra.w   16f
20:     moveq   #7,%d0
        sub.l   %d7,%d0                           | the slot
        lea     bq_on,%a0
        clr.b   (%a0,%d0.l)                       | no biquad unless set again
        move.l  %d5,%d4
        clr.w   %d4
        swap    %d4                               | TYP << 8 | FRQ
        cmp.l   #(TYP_OFF + 1) << 8,%d4
        bcs.w   15f                               | TYP OFF
        move.l  %d5,%d3
        lsr.l   #8,%d3
        and.l   #0xff,%d3                         | DEP
        beq.w   15f                               | 0 dB
        move.l  %d4,%d2
        lsr.l   #8,%d2                            | TYP
        cmp.l   #TYP_LP1,%d2
        beq.s   21f
        cmp.l   #TYP_HP1,%d2
        beq.s   21f
        jsr     bq_coef                           | 2-pole: the biquad's, and off
        bra.w   15f                               | for this pass
21:     move.l  %d4,%d2
        and.l   #0xff,%d2                         | FRQ
        move.l  (%a2,%d2.l*4),%d6                 | p
        mvz.w   (%a1,%d3.l*2),%d1
        swap    %d1                               | g, Q31
        move.l  #0x7fffffff,%d0
        sub.l   %d1,%d0                           | m
        move.l  %d6,%d2
        cmp.l   #TYP_HP1 << 8,%d4
        bcc.s   14f
        neg.l   %d2
14:     add.l   #0x80000000,%d2
        lsr.l   #1,%d2                            | h, (1 + p) / 2 or (1 - p) / 2
        mac.l   %d0,%d2,%acc2
        movclr.l %acc2,%d2                        | m h
        mac.l   %d1,%d6,%acc2
        movclr.l %acc2,%d0                        | g p
        move.l  %d1,%d3
        add.l   %d2,%d3
        move.l  %d3,(%a5)+                        | b0
        cmp.l   #TYP_HP1 << 8,%d4
        bcs.s   17f
        add.l   %d2,%d0
        neg.l   %d0                               | b1, HP1
        bra.s   18f
17:     sub.l   %d0,%d2
        move.l  %d2,%d0                           | b1, LP1
18:     move.l  %d0,(%a5)+
        move.l  %d6,(%a5)+                        | p
        move.l  (%a3),%d0                         | the entry last worked out
        swap    %d0
        eor.l   %d4,%d0
        and.l   #0xffff,%d0
        tst.b   %d0
        bne.s   19f                               | FRQ moved: the pole differs
        tst.l   %d0
        beq.s   19f                               | TYP unchanged
        move.l  (%a3),%d0
        swap    %d0
        lsr.l   #8,%d0
        and.l   #0xff,%d0                         | its TYP
        cmp.l   #TYP_LP1,%d0
        beq.s   22f
        cmp.l   #TYP_HP1,%d0
        bne.s   19f                               | not 1-pole, or -1: no state
22:
        move.l  (%a3),%d0
        and.l   #0xff00,%d0
        beq.s   19f                               | it was at 0 dB, off
        move.l  (%a4),%d0                         | x1
        mac.l   %d0,%d1,%acc2
        movclr.l %acc2,%d2                        | g x1
        add.l   %d0,%d2
        sub.l   4(%a4),%d2
        move.l  %d2,4(%a4)                        | y1 = (1 + g) x1 - y1
19:     move.l  %d5,(%a3)+
        bra.s   16f
15:     move.l  #OFF_B0,(%a5)+
        move.l  #-OFF_B0,(%a5)+
        move.l  #OFF_POLE,(%a5)+
        move.l  %d5,(%a3)+
16:     addq.l  #8,%a4
        subq.l  #1,%d7
        bpl.w   13b

        | The filter, two slots at a time - A in acc2, B in acc3, skipping a
        | pair whose slots are both off, so the cost follows the filters in use
        | (about 0.4% of a block a pair): 32 frames in four runs of eight, a
        | slot's word 48 B apart and B 4 B after A, y written over the x
        | already read. The last run's loads read the words past the buffer,
        | unused. The pair's column base and the coefficient pointer are kept
        | on the stack across the run.
        .if     P_PROF
        mvz.b   MUP_INT,%d0
        btst    #2,%d0                            | profiling: a slot at a time
        bne.w   filter_single
        .endif
        lea     hpf_state,%a0
        lea     flt_coef,%a6
        lea     RXBUF+8,%a2
7:      move.l  (%a6)+,%d7                        | b0, A
        move.l  (%a6)+,%a1                        | b1, A
        move.l  (%a6)+,%d6                        | p, A
        move.l  (%a6)+,%a4                        | b0, B
        move.l  (%a6)+,%d0                        | b1, B
        move.l  (%a6)+,%a3                        | p, B
        lea     -8(%sp),%sp
        movem.l %a2/%a6,(%sp)
        move.l  %d0,%a6                           | b1, B
        cmp.l   #OFF_POLE,%d6
        bne.s   6f
        cmpa.l  #OFF_POLE,%a3
        bne.s   6f
        | Both off: the pair is skipped and its slots keep the voices as the
        | ADC gave them. The state follows the signal - x1 and y1 both the
        | slot's last sample - so turning a filter on starts from there.
        move.l  (FRAMES-1)*RXSTRIDE(%a2),%d1
        move.l  %d1,(%a0)+
        move.l  %d1,(%a0)+
        move.l  (FRAMES-1)*RXSTRIDE+4(%a2),%d1
        move.l  %d1,(%a0)+
        move.l  %d1,(%a0)+
        bra.w   5f
6:      move.l  (%a0),%d3                         | x1, A
        move.l  4(%a0),%d4                        | y1, A
        move.l  8(%a0),%d2                        | x1, B
        move.l  12(%a0),%d5                       | y1, B
        lea     FRAMES*RXSTRIDE(%a2),%a5          | the run's end
        move.l  (%a2),%d0                         | x, A
        move.l  4(%a2),%d1                        | x, B
8:      .irp    i,0,1,2,3,4,5,6,7
        mac.l   %d0,%d7,%acc2
        mac.l   %d1,%a4,%acc3
        mac.l   %d3,%a1,%acc2
        mac.l   %d2,%a6,%acc3
        move.l  %d0,%d3                           | x1 = x, A
        move.l  %d1,%d2                           | x1 = x, B
        mac.l   %d4,%d6,RXSTRIDE*(\i+1)(%a2),%d0,%acc2
        mac.l   %d5,%a3,RXSTRIDE*(\i+1)+4(%a2),%d1,%acc3
        movclr.l %acc2,%d4                        | y, A
        movclr.l %acc3,%d5                        | y, B
        move.l  %d4,RXSTRIDE*\i(%a2)
        move.l  %d5,RXSTRIDE*\i+4(%a2)
        .endr
        lea     8*RXSTRIDE(%a2),%a2
        cmpa.l  %a5,%a2
        bne.w   8b
        move.l  %d3,(%a0)+
        move.l  %d4,(%a0)+
        move.l  %d2,(%a0)+
        move.l  %d5,(%a0)+
5:      movem.l (%sp),%a2/%a6
        lea     8(%sp),%sp
        addq.l  #8,%a2
        cmpa.l  #hpf_state+64,%a0
        bne.w   7b
        jsr     bq_run                            | the 2-pole slots
        tst.l   shp_any
        beq.s   31f
        jsr     shp_run                           | the transient shaper
31:
        .if     P_PROF
        bra.w   9f

        | Profiling only: the same filter a slot at a time, for comparing
        | against the pair above on the in-place buffer.
filter_single:
        lea     hpf_state,%a0
        lea     flt_coef,%a6
        lea     RXBUF+8,%a5
        moveq   #7,%d5
11:     move.l  (%a6)+,%d7                        | b0
        move.l  (%a6)+,%a1                        | b1
        move.l  (%a6)+,%d6                        | p
        move.l  (%a0),%d3                         | x1
        move.l  4(%a0),%d4                        | y1
        move.l  %a5,%a2
        move.l  (%a2),%d0                         | x
        moveq   #3,%d2
12:     .irp    i,0,1,2,3,4,5,6,7
        mac.l   %d0,%d7,%acc2
        mac.l   %d3,%a1,%acc2
        move.l  %d0,%d3
        mac.l   %d4,%d6,RXSTRIDE*(\i+1)(%a2),%d0,%acc2
        movclr.l %acc2,%d4
        move.l  %d4,RXSTRIDE*\i(%a2)
        .endr
        lea     8*RXSTRIDE(%a2),%a2
        subq.l  #1,%d2
        bpl.w   12b
        move.l  %d3,(%a0)+
        move.l  %d4,(%a0)+
        addq.l  #4,%a5
        subq.l  #1,%d5
        bpl.w   11b
        .endif
9:
        .if     P_PROF
        mvz.b   MUP_INT,%d0
        btst    #1,%d0                        | profiling: no sum
        bne.w   10f
        .endif

        | The sum, frame by frame, into the PRE pair itself: each side's
        | accumulator starts from its PRE word (stored as acc >> 8, logical, so
        | << 8 is its Q31 value again), the voices are subtracted, and the
        | saturating movclr clamps the result at full scale. The voices are
        | subtracted because the PRE pair is inverted against the analog bus,
        | as the consumer's msac of the returns reflects (measured against
        | stock over USB, 2026-09-28). Each (cL, cR) loads during the multiply
        | before it; the last load reads the word past the table, unused.
        move.l  OUT_IDX,%d0
        moveq   #11,%d1
        lsl.l   %d1,%d0
        add.l   #OUT_RING+OUT_PRE,%d0
        move.l  %d0,%a1
        lea     RXBUF+8,%a3
        lea     COEF(%sp),%a4                     | the filter used a4
        moveq   #FRAMES-1,%d5
4:      move.l  %a4,%a2
        move.l  (%a1),%d0
        lsl.l   #8,%d0
        move.l  %d0,%acc0                         | PRE L, Q31
        move.l  4(%a1),%d0
        lsl.l   #8,%d0
        move.l  %d0,%acc1                         | PRE R, Q31
        move.l  (%a2)+,%d1                        | cL, slot 0
        .irp    i,0,1,2,3,4,5,6,7
        move.l  4*\i(%a3),%d0                     | y
        msac.l  %d0,%d1,(%a2)+,%d1,%acc0          | L; d1 = cR
        msac.l  %d0,%d1,(%a2)+,%d1,%acc1          | R; d1 = the next cL
        .endr
        movclr.l %acc0,%d2
        movclr.l %acc1,%d3
        .if     P_TIMING
        .irp    side,%d2,%d3
        tpeak   \side
        .endr
        .endif
        lsr.l   #8,%d2
        move.l  %d2,(%a1)+
        lsr.l   #8,%d3
        move.l  %d3,(%a1)+
        lea     OUT_STRIDE-8(%a1),%a1
        lea     RXSTRIDE(%a3),%a3
        subq.l  #1,%d5
        bpl.w   4b
10:

        move.l  (%sp)+,%d0
        move.l  %d0,%macsr
        movem.l (%sp),%d0-%d7/%a0-%a6
        lea     160(%sp),%sp
        .if     P_TIMING
        jsr     t_end
        .endif
        rts


        .if     P_TIMING
        .section .tim,"ax"
        | ------------------------------------------------------------------
        | The timing build, in cave11 to leave cave9 to the shipping code:
        | vs_body's run and the interval between
        | interrupts, in DMA timer 0 ticks, on voice slot 7's word - USB
        | channel 10 - as (tag << 24) | (data << 8):
        |   frames 0 mod 4  0xa5, vs_body's run
        |   frames 1 mod 4  0x5a, the interval since the last block, / 4
        |   frames 2 mod 4  0x3c, the block's largest |sum| on either side, Q31
        |                   >> 15 (65535 is full scale)
        |   frames 3 mod 4  0xc3, how many side-frames reached full scale
        | each held at 0xffff. t_end keeps the words, and t_emit - detoured after
        | the FX sends and before USB (0x40121396), on the main path only -
        | writes this block's over slot 7, which only USB, and the sampler,
        | read after the sends: a timing build is for timing. If the Mac loops
        | the Rytm's USB audio back, the words return into MAIN as clicks
        | (2026-09-28). t_start and t_end keep every register.
        | ------------------------------------------------------------------
        .align  2
t_start:
        move.l  %d0,-(%sp)
        move.l  DTCN0,%d0
        move.l  %d0,t_0
        sub.l   t_prev,%d0
        move.l  %d0,t_iv
        move.l  t_0,%d0
        move.l  %d0,t_prev
        move.l  (%sp)+,%d0
        rts

        .align  2
t_end:
        lea     -16(%sp),%sp
        movem.l %d0-%d2/%a0,(%sp)
        move.l  DTCN0,%d0
        sub.l   t_0,%d0                           | the run
        move.l  t_iv,%d1
        lsr.l   #2,%d1                            | the interval / 4
        .irp    r,%d0,%d1
        cmp.l   #0xffff,\r
        bls.s   1f
        move.l  #0xffff,\r
1:      lsl.l   #8,\r
        .endr
        or.l    #0xa5000000,%d0
        or.l    #0x5a000000,%d1
        move.l  %d0,t_w_run
        move.l  %d1,t_w_iv
        move.l  t_pk,%d0
        lsr.l   #8,%d0
        lsr.l   #7,%d0                            | Q31 >> 15, 16 bits
        lsl.l   #8,%d0
        or.l    #0x3c000000,%d0
        move.l  %d0,t_w_pk
        move.l  t_clip,%d0
        lsl.l   #8,%d0
        or.l    #0xc3000000,%d0
        move.l  %d0,t_w_clip
        clr.l   t_pk
        clr.l   t_clip
        movem.l (%sp),%d0-%d2/%a0
        lea     16(%sp),%sp
        rts

        | t_emit: reached by a jmp over `addql #4,%sp; movel %d2,%sp@` and the
        | first half of `jsr 0x4010e650`, all re-emitted.
        .align  2
t_emit:
        addq.l  #4,%sp                            | displaced
        move.l  %d2,(%sp)                         | displaced
        jsr     FX_SENDS                          | displaced
        lea     -16(%sp),%sp
        movem.l %d0-%d2/%a0,(%sp)
        lea     RXBUF+T_SLOT,%a0
        moveq   #FRAMES/4-1,%d2
2:      move.l  t_w_run,%d0
        move.l  %d0,(%a0)
        move.l  t_w_iv,%d0
        move.l  %d0,RXSTRIDE(%a0)
        move.l  t_w_pk,%d0
        move.l  %d0,2*RXSTRIDE(%a0)
        move.l  t_w_clip,%d0
        move.l  %d0,3*RXSTRIDE(%a0)
        lea     4*RXSTRIDE(%a0),%a0
        subq.l  #1,%d2
        bpl.s   2b
        movem.l (%sp),%d0-%d2/%a0
        lea     16(%sp),%sp
        jmp     EMIT_RESUME

        .if     P_BURN
        | t_burn: the burn build's added load, after t_start in every
        | interrupt: while MIX's integer part (CC 84) is 0, it spins on DMA
        | timer 0 until MUP's integer part (CC 81) times 0.5% of the last
        | interval has passed since t_start, so 0..63.5% of a block. MIX 0 is
        | the dry path, where MUP has no effect and which a kit does not sit at
        | with MUP raised, so a kit's own makeup gain leaves it idle. vs_body's
        | run, and so the timing words, include it. Keeps every register.
        .align  2
t_burn:
        lea     -8(%sp),%sp
        movem.l %d0-%d1,(%sp)
        tst.b   MIX_INT
        bne.s   9f
        mvz.b   MUP_INT,%d1
        beq.s   9f
        move.l  t_iv,%d0
        mulu.l  %d0,%d1
        move.l  #200,%d0
        divu.l  %d0,%d1                           | the ticks to spend
1:      move.l  DTCN0,%d0
        sub.l   t_0,%d0
        cmp.l   %d1,%d0
        bcs.s   1b
9:      movem.l (%sp),%d0-%d1
        lea     8(%sp),%sp
        rts
        .endif

        .align  2
t_prev: .long   0
t_0:    .long   0
t_iv:   .long   0
t_w_run: .long  0
t_w_iv: .long   0
t_w_pk: .long   0
t_w_clip: .long 0
t_pk:   .long   0
t_clip: .long   0
        .text
        .endif

        | ------------------------------------------------------------------
        | page_info's answer for ids above 11, `movel #0x401ec570,%d0` before its
        | rts: page 13 answers the DAC FILTER page. Reached with d0 the page id, from the
        | range compare 0004 rejoins at when it is built.
        | ------------------------------------------------------------------
        .align  2
hpf_page_info:
        moveq   #PAGE_HPF,%d1
        cmp.l   %d1,%d0
        bne.s   1f
        move.l  #page_hpf,%d0
        rts
1:      move.l  #PAGE_DEFAULT,%d0                 | displaced
        rts                                       | as stock's, after it

        | The DAC FILTER page: FRQ, RES, TYP and DEP along the top row, the
        | first three in stock's FILTER order, the graph drawn over FRQ and
        | RES; the transient shaper's ATK and SUS and POL along the bottom.
        .align  2
page_hpf:
        .long   txt_page
        .long   ID_FRQ, ID_RES, ID_TYP, ID_DEP, ID_ATK, ID_SUS, ID_POL, 0
        | The FILTER view's page vector, FILTER and then DAC FILTER.
filter_pages:
        .long   PAGE_FILTER, PAGE_HPF

        | ------------------------------------------------------------------
        | The page key's cycle, `movel %a2@(140),%d1; addql #1,%d1`, re-emitted,
        | before `remsl %d0,%d2,%d1` makes it the new index. On the FILTER view -
        | its first page is 6 - while DAC SUM is off the index stays 0, so the
        | DAC FILTER page is never shown. d2 is overwritten by the remsl and a0 reloaded
        | after, so both are free.
        | ------------------------------------------------------------------
        .align  2
hpf_cycle:
        move.l  140(%a2),%d1                      | displaced
        addq.l  #1,%d1                            | displaced
        tst.l   dac_on
        bne.s   9f
        move.l  124(%a2),%a0
        moveq   #PAGE_FILTER,%d2
        cmp.l   (%a0),%d2
        bne.s   9f
        moveq   #0,%d1
9:      jmp     CYCLE_RESUME

        | ------------------------------------------------------------------
        | A knob's values as one hpf_track entry: TYP << 24 | FRQ << 16 | DEP
        | << 8 | RES.
        |   flt_entry(a0 = live sound) -> d0, with RES in the low byte.
        |                                 Clobbers d0/d1.
        |   flt_cur() -> d0, the selected track's; FLT_DEFAULT with no sound.
        |                Clobbers d0/d1/a0/a1.
        |   flt_ours(d0 = id) -> Z set for ID_FRQ, ID_RES, ID_TYP and ID_DEP.
        |   flt_shift(d1 = one of those) -> d1 = its field's shift.
        |   flt_set(d0 = entry): the selected track's sound, its spare bits
        |                        kept, and its
        |                        hpf_track entry, then the change notice stock's
        |                        own sound settings setters send (ENV RESET's,
        |                        0x400bcee4): SoundConfigChangedInfo, kind 1,
        |                        through the track's sound accessor's vtable
        |                        +16. Without it the change is lost at a reboot
        |                        unless the kit is saved. Clobbers d0/d1/a0/a1.
        |   flt_put7(d0 = 0..127, a1 = +0x6e or +0x6f): the field, stored as
        |                        d0 ^ 0x7f, bit 7 kept. Clobbers d0/d1.
        | ------------------------------------------------------------------
        .align  2
flt_entry:
        mvz.b   OFF_FLT_TYP(%a0),%d0
        and.l   #FLT_TYP_BITS,%d0
        lsl.l   #8,%d0
        mvz.b   OFF_FLT_FRQ(%a0),%d1
        and.l   #FLT_7_BITS,%d1
        eor.l   #FLT_7_BITS,%d1
        or.l    %d1,%d0
        lsl.l   #8,%d0
        mvz.b   OFF_FLT_DEP(%a0),%d1
        and.l   #FLT_7_BITS,%d1
        eor.l   #FLT_7_BITS,%d1
        or.l    %d1,%d0
        lsl.l   #8,%d0
        mvz.b   OFF_FLT_RES(%a0),%d1
        and.l   #FLT_7_BITS,%d1
        or.l    %d1,%d0
        rts

        .align  2
flt_put7:
        and.l   #FLT_7_BITS,%d0
        eor.l   #FLT_7_BITS,%d0
        mvz.b   (%a1),%d1
        and.l   #0x80,%d1
        or.l    %d1,%d0
        move.b  %d0,(%a1)
        rts

        .align  2
flt_cur:
        jsr     shared_cur_sound
        bne.s   flt_entry
        move.l  #FLT_DEFAULT,%d0
        rts

        .align  2
flt_ours:
        cmp.l   #ID_FRQ,%d0
        beq.s   9f
        cmp.l   #ID_TYP,%d0
        beq.s   9f
        cmp.l   #ID_RES,%d0
        beq.s   9f
        cmp.l   #ID_DEP,%d0
9:      rts

        .align  2
flt_shift:
        cmp.l   #ID_TYP,%d1
        bne.s   1f
        moveq   #24,%d1
        rts
1:      cmp.l   #ID_FRQ,%d1
        bne.s   2f
        moveq   #16,%d1
        rts
2:      cmp.l   #ID_RES,%d1
        bne.s   3f
        moveq   #0,%d1
        rts
3:      moveq   #8,%d1
        rts

        .align  2
flt_set:
        move.l  %d2,-(%sp)
        move.l  %d0,-(%sp)                        | the entry, at (%sp)
        jsr     project_singleton
        move.l  %d0,%d2                           | the project
        move.l  %d0,%a0
        pea     PROJ_TRACKSEL(%a0)
        jsr     track_index_of
        addq.l  #4,%sp
        moveq   #VOICE_TRACKS,%d1
        cmp.l   %d1,%d0
        bcc.w   9f                                | the FX track has no voice
        lea     hpf_track,%a0
        move.l  (%sp),%d1
        move.l  %d1,(%a0,%d0.l*4)
        move.l  %d0,-(%sp)                        | the track
        add.l   #PROJ_KIT,%d2
        move.l  %d2,-(%sp)                        | the active kit
        jsr     kit_track_sound
        addq.l  #8,%sp
        move.l  %d0,%d2                           | the track's sound accessor
        beq.s   9f
        move.l  %d2,-(%sp)
        move.l  %d2,%a0
        move.l  (%a0),%a0
        move.l  VT_SOUND(%a0),%a0
        jsr     (%a0)
        addq.l  #4,%sp
        tst.l   %d0
        beq.s   9f
        move.l  %d0,%a0                           | the live sound
        move.l  (%sp),%d0
        swap    %d0                               | TYP << 8 | FRQ
        lea     OFF_FLT_FRQ(%a0),%a1
        bsr.w   flt_put7
        move.l  (%sp),%d0
        lsr.l   #8,%d0                            | DEP
        lea     OFF_FLT_DEP(%a0),%a1
        bsr.w   flt_put7
        mvz.b   OFF_FLT_RES(%a0),%d1
        and.l   #0x80,%d1
        move.l  (%sp),%d0
        and.l   #FLT_7_BITS,%d0                   | RES
        or.l    %d1,%d0
        move.b  %d0,OFF_FLT_RES(%a0)
        move.l  (%sp),%d0
        moveq   #24,%d1
        lsr.l   %d1,%d0                           | TYP
        mvz.b   OFF_FLT_TYP(%a0),%d1
        and.l   #0xff-FLT_TYP_BITS,%d1
        or.l    %d1,%d0
        move.b  %d0,OFF_FLT_TYP(%a0)
        lea     -8(%sp),%sp                       | SoundConfigChangedInfo, kind 1
        move.l  #SOUND_CONFIG_CHANGED,(%sp)
        move.b  #1,4(%sp)
        move.l  %sp,-(%sp)
        move.l  %d2,-(%sp)
        move.l  %d2,%a0
        move.l  (%a0),%a0
        move.l  VT_CONFIG_CHANGED(%a0),%a0
        jsr     (%a0)
        lea     16(%sp),%sp
9:      addq.l  #4,%sp
        move.l  (%sp)+,%d2
        rts


        | ------------------------------------------------------------------
        | sound_save, after its memset of the stored parameter block, over
        | `lea 0x401c59cc,%a0`: a2 the stored record, a3 the live sound. Slots
        | 42 (+0x70) and 43 (+0x72), which stock zeroes and never reads, carry
        | (FLT_TAG + TYP) << 8 + FRQ and POL << 8 + DEP, or stay 0 when the live bytes are
        | all zero, so an untouched sound saves as stock would save it. Slots
        | 44..47 carry the routes' spare bytes (rte_save). d0/d1 and a0/a1 are
        | set again straight after.
        | ------------------------------------------------------------------
        .align  2
hpf_save:
        move.l  %a3,%a0
        move.l  %a2,%a1
        jsr     rte_save
        mvz.b   OFF_FLT_TYP(%a3),%d0
        mvz.w   OFF_FLT_FRQ(%a3),%d1
        or.l    %d1,%d0
        beq.s   1f                                | all zero: the defaults
        move.l  %a3,%a0
        bsr.w   flt_entry
        move.l  %d0,%d1
        lsr.l   #8,%d1
        and.l   #0xff,%d1
        btst    #FLT_POL_BIT,OFF_FLT_TYP(%a3)
        beq.s   2f
        bset    #SLOT43_POL,%d1
2:      move.w  %d1,OFF_SLOT43(%a2)               | DEP, POL in bit 8
        swap    %d0                               | TYP << 8 | FRQ
        add.l   #FLT_TAG << 8,%d0
        move.w  %d0,OFF_SLOT42(%a2)
1:      lea     SAVE_MAP,%a0                      | displaced
        jmp     SAVE_RESUME

        | ------------------------------------------------------------------
        | sound_load, after it clears the live parameter array, over `lea
        | 0x401c5a74,%a0`: a2 the live sound, a3 the stored record. The live
        | bytes, POL included, from slots 42 and 43 when slot 42 holds the tag,
        | or all zero, so
        | a sound saved without them - or by stock, which zeroes the slots -
        | reads the defaults rather than whatever the object held. d0/d1 and
        | a0/a1 are set again straight after.
        | ------------------------------------------------------------------
        .align  2
hpf_load:
        mvz.w   OFF_SLOT42(%a3),%d0
        move.l  %d0,%d1
        lsr.l   #8,%d1
        sub.l   #FLT_TAG,%d1
        cmp.l   #TYP_PK,%d1
        bhi.s   1f                                | untagged
        move.b  %d1,OFF_FLT_TYP(%a2)
        lea     OFF_FLT_FRQ(%a2),%a1
        clr.w   (%a1)
        bsr.w   flt_put7                          | FRQ, the low byte
        mvz.w   OFF_SLOT43(%a3),%d0
        lea     OFF_FLT_DEP(%a2),%a1
        bsr.w   flt_put7
        mvz.w   OFF_SLOT43(%a3),%d0
        btst    #SLOT43_POL,%d0
        beq.s   2f
        bset    #FLT_POL_BIT,OFF_FLT_TYP(%a2)     | POL
        bra.s   2f
1:      clr.b   OFF_FLT_TYP(%a2)
        clr.w   OFF_FLT_FRQ(%a2)
2:      lea     LOAD_MAP,%a0                      | displaced
        jmp     LOAD_RESUME

        | ------------------------------------------------------------------
        | sound_load's entry, over `lea %sp@(-24),%sp; moveml
        | %d2-%d3/%a2-%a5,%sp@`: 4(%sp) the live sound, 8(%sp) the stored
        | record. Stock returns false, writing nothing, when the record is
        | null or not version 4, and one caller (0x4018cb98) uses the object
        | anyway; the live bytes and the routes' spare bytes are cleared first
        | in that case, so a fresh object reads the defaults. d0/d1 and a0/a1
        | are free at a call.
        | ------------------------------------------------------------------
        .align  2
snd_load:
        move.l  4(%sp),%d0
        beq.s   9f                                | no sound: nothing to clear
        move.l  %d0,%a0
        move.l  8(%sp),%d0
        beq.s   1f                                | no record: the load fails
        move.l  %d0,%a1
        moveq   #4,%d0
        cmp.l   4(%a1),%d0
        beq.s   9f                                | version 4: hpf_load sets them
1:      clr.b   OFF_FLT_TYP(%a0)
        clr.w   OFF_FLT_FRQ(%a0)
        jsr     rte_clear
9:      lea     -24(%sp),%sp                      | displaced
        movem.l %d2-%d3/%a2-%a5,(%sp)             | displaced
        jmp     SLOAD_RESUME

        | ------------------------------------------------------------------
        | sound_init_defaults, past its null test, over `moveal %a2,%a0;
        | moveal %a2,%a3; clrl %a0@+`: a2 the sound. Stock's defaults never
        | reach +0x6d..+0x6f, so a new sound would hold whatever the allocator
        | left there; they are cleared, the defaults. A sound reset through
        | this (0x400bd756) loses its DAC FILTER values with the rest.
        | ------------------------------------------------------------------
        .align  2
snd_init:
        clr.b   OFF_FLT_TYP(%a2)
        clr.w   OFF_FLT_FRQ(%a2)
        move.l  %a2,%a0                           | displaced
        move.l  %a2,%a3                           | displaced
        clr.l   (%a0)+                            | displaced
        jmp     INIT_RESUME

        | ------------------------------------------------------------------
        | The screen's idle tick (0x400a2aaa, about 20 a second, UI context),
        | past its link, over `moveml %d2/%a2-%a4,%sp@` and the first half of
        | `moveal %fp@(8),%a2`, both re-emitted. Every voice track's filter
        | entry, from the sound its active kit holds, into hpf_track, so the audio
        | interrupt follows kit loads, pattern changes and sound loads within a
        | tick without looking up a sound itself. Then DAC SUM, from the
        | active globals record's entry, so it follows a project load.
        | ------------------------------------------------------------------
        .align  2
hpf_refresh:
        movem.l %d2/%a2-%a4,(%sp)                 | displaced
        move.l  8(%fp),%a2                        | displaced
        lea     -8(%sp),%sp
        movem.l %d2-%d3,(%sp)
        moveq   #0,%d2                            | track
1:      move.l  %d2,%d0
        jsr     shared_sound_of
        beq.s   3f                                | no sound: off
        .if     P_DBG
        bsr.w   dbg_check
        jsr     rte_probe
        .endif
        bsr.w   flt_entry
        move.l  %d0,%d3
        jsr     shp_entry
        bra.s   4f
3:      moveq   #0,%d0
        moveq   #0,%d3
4:      lea     hpf_track,%a0
        move.l  %d3,(%a0,%d2.l*4)
        move.l  %d0,48(%a0,%d2.l*4)               | shp_track
        addq.l  #1,%d2
        moveq   #VOICE_TRACKS,%d1
        cmp.l   %d1,%d2
        blt.s   1b
        lea     shp_track,%a0                     | shp_any: any ATK or SUS
        moveq   #0,%d0
        moveq   #VOICE_TRACKS-1,%d1
5:      or.l    (%a0)+,%d0
        subq.l  #1,%d1
        bpl.s   5b
        and.l   #0xffff0000,%d0
        move.l  %d0,shp_any
        jsr     flt_knobs
        bsr.w   dac_active                        | DAC SUM: the active record's
        bsr.w   dac_find
        tst.l   %d0
        bmi.s   5f
        lea     dac_rec,%a1
        mvz.b   (%a1,%d0.l),%d0
        move.l  %d0,dac_on
5:      movem.l (%sp),%d2-%d3
        lea     8(%sp),%sp
        jmp     IDLE_RESUME                       | a2 kept: calls clobber d0/d1/a0/a1

        | ------------------------------------------------------------------
        | projectGlobals_t's load (0x4000763c), after its version check, over
        | `mvsb %a2@(4),%d1; moveq #1,%d2`, both re-emitted: a2 the stored
        | record, a3 the live one. The boot loop loads four (0x4000ce1c), so
        | the value goes to that live record's entry in dac_rec - stored +13
        | under the tag at +12, or OFF - and hpf_refresh picks the active
        | record's. A single flag, set by every load, took the last record's
        | and lost the active one's (hardware, 2026-09-28); an untouched record
        | can hold leftovers there (the fourth read 00 01), which the tag keeps
        | out. d0 is written again before it is read.
        | ------------------------------------------------------------------
        .align  2
dac_load:
        lea     -8(%sp),%sp
        movem.l %a0-%a1,(%sp)
        move.l  %a3,%a0
        bsr.w   dac_slot                          | d0 = this live record's entry
        moveq   #0,%d1
        mvz.b   OFF_DAC_TAG(%a2),%d2              | d2 is set again after
        cmp.l   #DAC_TAG,%d2
        bne.s   1f
        tst.b   OFF_DAC_ON(%a2)
        sne     %d1
        and.l   #1,%d1                            | 1 or 0
1:      lea     dac_rec,%a1
        move.b  %d1,(%a1,%d0.l)
        .if     P_DBG
        addq.l  #1,dbg_loads
        lea     dbg_tags,%a1
        mvz.b   OFF_DAC_TAG(%a2),%d1
        move.b  %d1,(%a1,%d0.l)                   | the tag each record's load found
        .endif
        movem.l (%sp),%a0-%a1
        lea     8(%sp),%sp
        mvs.b   4(%a2),%d1                        | displaced
        moveq   #1,%d2                            | displaced
        jmp     DLOAD_RESUME

        | ------------------------------------------------------------------
        | projectGlobals_t's save (0x40007a5c), over `moveq #2,%d0` and the
        | first four bytes of `moveb %a3@(211),%a2@(70)`, both re-emitted: a2
        | the stored record. The tag at +12 and DAC SUM at +13. d1 is not read
        | again.
        | ------------------------------------------------------------------
        .align  2
dac_save:
        .if     P_DBG
        addq.l  #1,dbg_saves
        .endif
        lea     -8(%sp),%sp
        movem.l %a0-%a1,(%sp)
        move.l  #DAC_TAG,%d1
        move.b  %d1,OFF_DAC_TAG(%a2)
        move.l  dac_on,%d1                        | a record never loaded: DAC SUM
        move.l  %a3,%a0
        bsr.w   dac_find
        tst.l   %d0
        bmi.s   1f
        lea     dac_rec,%a1
        mvz.b   (%a1,%d0.l),%d1                   | this record's
1:      move.b  %d1,OFF_DAC_ON(%a2)
        movem.l (%sp),%a0-%a1
        lea     8(%sp),%sp
        moveq   #2,%d0                            | displaced
        move.b  211(%a3),70(%a2)                  | displaced
        jmp     DSAVE_RESUME

        | ------------------------------------------------------------------
        | The four globals records' DAC SUM, keyed by live record: dac_live
        | holds each record's address as its load saw it, dac_rec its value.
        |   dac_find(a0 = live record) -> d0 = its entry, or -1
        |   dac_slot(a0 = live record) -> d0 = its entry, taking the next one
        |                                 round when it has none
        |   dac_active() -> a0 = the active live record (ProjectGlobals'
        |                   vtable +52, as stock's routing getters ask)
        | dac_find and dac_slot clobber d0/a1, dac_active d0/d1/a0/a1.
        | ------------------------------------------------------------------
        .align  2
dac_find:
        lea     dac_live,%a1
        moveq   #0,%d0
1:      cmpa.l  (%a1)+,%a0
        beq.s   2f
        addq.l  #1,%d0
        cmp.l   #4,%d0
        bne.s   1b
        moveq   #-1,%d0
2:      rts

        .align  2
dac_slot:
        bsr.s   dac_find
        tst.l   %d0
        bpl.s   9f
        move.l  dac_next,%d0
        lea     dac_live,%a1
        move.l  %a0,(%a1,%d0.l*4)
        move.l  %d0,-(%sp)
        addq.l  #1,%d0
        and.l   #3,%d0
        move.l  %d0,dac_next
        move.l  (%sp)+,%d0
9:      rts

        .align  2
dac_active:
        jsr     project_singleton
        add.l   #PROJ_GLOBALS,%d0
        move.l  %d0,%a0
        move.l  %a0,-(%sp)
        move.l  (%a0),%a0
        move.l  52(%a0),%a0
        jsr     (%a0)
        addq.l  #4,%sp
        move.l  %d0,%a0
        rts

        .if     P_DBG
        | ------------------------------------------------------------------
        | The debug build: DAC SUM's value reads "R<m>m<n>": dbg_rte in three
        | hex digits and dbg_marks in one, F for 15 and more; then E when
        | dbg_eng is set and B when dbg_bad is not 0. Short, to clear the label
        | it is right-aligned against.
        | Clobbers d0/d1/a0/a1.
        | ------------------------------------------------------------------
        .align  2
dbg_fmt:
        lea     dbg_txt,%a1
        move.b  #'R',(%a1)+
        move.l  dbg_rte,%d1
        lsr.l   #8,%d1
        bsr.w   dbg_nib
        move.l  dbg_rte,%d0
        bsr.w   dbg_hex
        move.b  #'m',(%a1)+
        move.l  dbg_marks,%d1
        moveq   #15,%d0
        cmp.l   %d0,%d1
        bls.s   3f
        move.l  %d0,%d1
3:      bsr.w   dbg_nib
        tst.l   dbg_eng
        beq.s   1f
        move.b  #'E',(%a1)+
1:      tst.l   dbg_bad
        beq.s   2f
        move.b  #'B',(%a1)+
2:      clr.b   (%a1)
        rts
        | dbg_check(a0 = track d2's live sound): sets bit d2 of dbg_bad, and
        | keeps it, when the sound's bytes hold what nothing writes - a spare
        | bit: a sound that reached a track without sound_init_defaults,
        | sound_load or a copy. Clobbers d0/d1.
dbg_check:
        mvz.b   OFF_FLT_TYP(%a0),%d0
        and.l   #0xff-FLT_TYP_BITS-(1 << FLT_POL_BIT),%d0
        bne.s   1f                                | a spare bit
        mvz.b   OFF_FLT_FRQ(%a0),%d0
        mvz.b   OFF_FLT_DEP(%a0),%d1
        or.l    %d1,%d0
        and.l   #0x80,%d0
        beq.s   9f                                | bit 7 of neither
1:      move.l  dbg_bad,%d0
        bset    %d2,%d0
        move.l  %d0,dbg_bad
9:      rts
        | dbg_dec(d0, a1): 0..99, two digits, wrapping
dbg_dec:
        divu.w  #100,%d0
        swap    %d0
        and.l   #0xffff,%d0
        divu.w  #10,%d0
        moveq   #'0',%d1
        add.l   %d0,%d1
        move.b  %d1,(%a1)+
        swap    %d0
        moveq   #'0',%d1
        add.l   %d0,%d1
        move.b  %d1,(%a1)+
        rts
        | dbg_hex(d0 = a byte, a1): two hex digits
dbg_hex:
        move.l  %d0,%d1
        lsr.l   #4,%d1
        bsr.s   dbg_nib
        move.l  %d0,%d1
        | dbg_nib(d1, a1): its low four bits, one hex digit
dbg_nib:
        and.l   #15,%d1
        cmp.l   #10,%d1
        bcs.s   2f
        addq.l  #7,%d1
2:      add.l   #'0',%d1
        move.b  %d1,(%a1)+
        rts
        .endif

txt_page:
        .asciz  "DAC FILTER"
txt_frq_long:
        .asciz  "Frequency"
txt_frq_short:
        .asciz  "FRQ"
txt_typ_long:
        .asciz  "Filter Type"
txt_typ_short:
        .asciz  "TYP"
txt_dep_long:
        .asciz  "Depth"
txt_dep_short:
        .asciz  "DEP"
txt_res_long:
        .asciz  "Resonance"
txt_res_short:
        .asciz  "RES"
txt_atk_long:
        .asciz  "Transient Attack"
txt_atk_short:
        .asciz  "ATK"
txt_sus_long:
        .asciz  "Transient Sustain"
txt_sus_short:
        .asciz  "SUS"
txt_pol_long:
        .asciz  "Polarity"
txt_pol_short:
        .asciz  "POL"
txt_full:
        .asciz  "FULL"
txt_db:
        .asciz  "dB"

        | Per-slot gain g, Q15: the slot trim times K. The trims are 0006's
        | (mods/0006-comp-preview/calibration.toml, slot_trim_db): slots 5 and 6
        | read hot against their contribution to MAIN. Slot 6's is 0.53 dB, not
        | 0006's 1.10: at 1.10 it read 0.57 dB low against the analog path, DAC
        | SUM on against off over USB, A02 and A04 (build/mix/20260928_114438,
        | _114542), 2026-09-28.
        .align  2
gaintab:
        .irp    t,32767,32757,32767,32637,32469,29460,30828,32037
        .word   (\t * P_K) / 32768
        .endr

        | ------------------------------------------------------------------
        | dac_menu_add: AudioRoutingMenuView's item list, after USB TO MAIN.
        |
        | Reached by a jmp over `moveal %a4@,%a0; pea 0x2`, re-emitted after.
        | USB OUT's item sequence follows unchanged but for its three invokers
        | and the allocator: USB TO MAIN's sequence left its item in a3, where
        | the others keep mem_new. The changer's storage holds the view itself
        | rather than an allocation. The registers it uses still hold what it
        | needs - a4 the view, a5 the MenuItem constructor, a2 the std::function
        | destructor, d2..d5 the four functions' slots - and the stack is at
        | the depth each item starts at. d6 is free; d7 is kept.
        | ------------------------------------------------------------------
        .align  2
dac_menu_add:
        move.l  (%a4),%a0
        move.l  8(%a0),%fp                        | append
        clr.l   76(%sp)
        pea     0x1
        jsr     mem_new
        clr.l   96(%sp)
        clr.l   112(%sp)
        move.l  %d0,72(%sp)
        move.l  #dac_label,%d0
        move.l  %d0,84(%sp)
        move.l  #MGR_LABEL,%d0
        move.l  %d0,80(%sp)
        pea     0x1
        jsr     mem_new
        clr.l   132(%sp)
        move.l  %d0,108(%sp)
        move.l  #dac_draw,%d0
        move.l  %d0,120(%sp)
        move.l  #MGR_DRAW,%d0
        move.l  %d0,116(%sp)
        lea     32(%sp),%sp
        pea     0x1
        move.l  %a4,%d0                           | the view, stored in place
        move.l  %d0,96(%sp)
        move.l  #dac_change,%d0
        move.l  %d0,108(%sp)
        move.l  #dac_mgr,%d0
        move.l  %d0,104(%sp)
        pea     0x54
        jsr     mem_new
        pea     0x8
        pea     -1
        move.l  %d5,-(%sp)
        move.l  %d4,-(%sp)
        move.l  %d3,-(%sp)
        move.l  %d2,-(%sp)
        move.l  %d0,-(%sp)
        move.l  %d0,%d6
        jsr     (%a5)
        lea     32(%sp),%sp
        move.l  %d6,(%sp)
        move.l  %a4,-(%sp)
        jsr     (%fp)
        move.l  %d5,-(%sp)
        jsr     (%a2)
        move.l  %d4,-(%sp)
        jsr     (%a2)
        move.l  %d3,-(%sp)
        jsr     (%a2)
        move.l  %d2,-(%sp)
        jsr     (%a2)
        move.l  (%a4),%a0                         | displaced
        pea     0x2                               | displaced
        jmp     MENU_RESUME

        | dac_label(a0 = the std::string to construct) -> d0 = a0, as stock's
        | label invokers.
        .align  2
dac_label:
        link.w  %fp,#-4
        move.l  %d2,-(%sp)
        pea     -1(%fp)
        pea     txt_label
        move.l  %a0,%d2
        move.l  %a0,-(%sp)
        jsr     std_string_from_cstr
        lea     12(%sp),%sp
        move.l  %d2,%d0
        move.l  -8(%fp),%d2
        unlk    %fp
        rts

        | dac_draw(functor, -, canvas, x, y): ON or OFF, right-aligned at
        | x + 19 as USB IN's value is - measured, then drawn from x less its
        | width.
        .align  2
dac_draw:
        lea     -32(%sp),%sp
        movem.l %d2-%d7,(%sp)                     | the string at +24, its allocator +28
        move.l  44(%sp),%d5                       | canvas
        move.l  48(%sp),%d6
        add.l   #19,%d6                           | right edge
        move.l  52(%sp),%d7
        addq.l  #2,%d7                            | y
        lea     24(%sp),%a0
        move.l  %a0,%d3
        lea     28(%sp),%a0
        move.l  %a0,%d4
        move.l  #txt_off,%d2
        tst.l   dac_on
        beq.s   1f
        move.l  #txt_on,%d2
1:
        .if     P_DBG
        bsr.w   dbg_fmt
        move.l  #dbg_txt,%d2
        .endif
        move.l  %d4,-(%sp)
        move.l  %d2,-(%sp)
        move.l  %d3,-(%sp)
        jsr     std_string_from_cstr
        move.l  %d3,-(%sp)
        pea     -1
        pea     MENU_FONT
        jsr     TEXT_WIDTH
        sub.l   %d0,%d6
        move.l  %d3,-(%sp)
        jsr     std_string_dtor
        move.l  %d2,-(%sp)                        | the text as format, no %
        move.l  %d2,-(%sp)                        | and as width
        clr.l   -(%sp)
        pea     -1
        move.l  %d7,-(%sp)
        move.l  %d6,-(%sp)
        pea     MENU_FONT
        move.l  %d5,-(%sp)
        jsr     text_draw
        lea     60(%sp),%sp
        movem.l (%sp),%d2-%d7
        lea     32(%sp),%sp
        rts

        | dac_change(functor, -, delta): up turns DAC SUM on, down off, marks
        | the project's globals changed, then invalidates the view the functor
        | holds. The value is not a stock
        | setting, so no setter's notification redraws it.
        .align  2
dac_change:
        move.l  12(%sp),%d0
        beq.s   2f
        bmi.s   1f
        moveq   #1,%d0
        bra.s   3f
1:      moveq   #0,%d0
3:      move.l  %d0,dac_on
        move.l  %d0,-(%sp)
        bsr.w   dac_active
        bsr.w   dac_find
        tst.l   %d0
        bmi.s   4f
        lea     dac_rec,%a1
        move.l  (%sp),%d1
        move.b  %d1,(%a1,%d0.l)                   | the active record's entry
4:      addq.l  #4,%sp
        jsr     project_singleton                 | the project's globals changed,
        add.l   #PROJ_GLOBALS,%d0                 | so they are saved with it, as
        move.l  %d0,%a0                           | a routing change is
        clr.l   -(%sp)
        move.l  %a0,-(%sp)
        move.l  (%a0),%a0
        move.l  VT_CHANGED(%a0),%a0
        jsr     (%a0)
        addq.l  #8,%sp
        move.l  4(%sp),%a0
        move.l  (%a0),%a0                         | the view
        pea     56(%a0)
        jsr     VIEW_INVALIDATE
        addq.l  #4,%sp
2:      rts

        | dac_mgr(dest, source, op): the changer's std::function manager, for a
        | functor stored in place - the view pointer. 0 names the type (this
        | routine's address stands in for its typeinfo), 1 answers the
        | functor's address, 2 copies the pointer, 3 has nothing to free.
        .align  2
dac_mgr:
        move.l  4(%sp),%a0                        | dest
        move.l  12(%sp),%d0                       | op
        bne.s   1f
        move.l  #dac_mgr,(%a0)
        bra.s   9f
1:      subq.l  #1,%d0
        bne.s   2f
        move.l  8(%sp),(%a0)
        bra.s   9f
2:      subq.l  #1,%d0
        bne.s   9f
        move.l  8(%sp),%a1
        move.l  (%a1),(%a0)
9:      moveq   #0,%d0
        rts

txt_label:
        .asciz  "DAC SUM"
txt_on:
        .asciz  "ON"
txt_off:
        .asciz  "OFF"

        | Written at run time, as 0010's data in cave6 is: 0 until the project
        | loads, then as its globals were saved.
        .align  2
dac_on:
        .long   0
        | The globals records' DAC SUM (dac_find, dac_slot).
dac_live: .long 0, 0, 0, 0
dac_next: .long 0
dac_rec: .byte  0, 0, 0, 0
        | Each voice track's filter entry, TYP << 24 | FRQ << 16 | DEP << 8, as
        | flt_set and hpf_refresh leave it. 0, off, at power-on.
        .balign 4
hpf_track:
        .space  VOICE_TRACKS * 4
        | Each voice track's shaper entry, ATK << 24 | SUS << 16 | POL << 8
        | (ATK and SUS signed), as shp_entry and shp_set leave it; it follows
        | hpf_track, at hpf_track + 48, as the pan loop reads it.
shp_track:
        .space  VOICE_TRACKS * 4
        | Whether any voice track's ATK or SUS is set, from the idle tick: 0
        | skips the shaper outright, so off it costs a test a block.
shp_any:
        .long   0
        | Per slot: the coefficients the filter runs with, (b0, b1, p), and
        | the entry they were worked out from.
flt_coef:
        .space  8 * 12
flt_key:
        .rept   8
        .long   -1
        .endr
        .if     P_DBG
dbg_loads: .long 0
dbg_saves: .long 0
dbg_tags: .byte 0, 0, 0, 0
dbg_txt: .space 20
        .align  2
dbg_bad: .long  0                                 | per voice track, a bit
        .align  2
        .endif
hpf_state:
        .rept   8
        .long   0, 0                              | x1, y1, per slot
        .endr


        | ------------------------------------------------------------------
        | cave11 (after the timing build's routines) and cave16: the 2-pole
        | types, LP2, HP2, BP, BS and PK, each a biquad on its slot after the
        | 1-pole pass. With H the RBJ cookbook's section at FRQ's w0 and RES's
        | Q - LP2 and HP2 the low- and high-pass, BP the band-pass with 0 dB
        | at the centre, BS the notch - the slot runs
        |   y = g x + m H(x)
        | with g DEP's dry share and m = 1 - g, so DEP is the same cut-only
        | depth as LP1's and HP1's (BS below FULL a bell cut, LP2 and HP2
        | shelves), and for PK g = 1 and m = 10^(B / 20) - 1, B = 6 DEP / 127
        | dB, a bell boost up to +6 dB built on BP. RES sets Q: 0.707 to 2.0
        | for LP2 and HP2 (a resonant peak up to +6.3 dB), 0.5 to 8 for BP, BS
        | and PK (width only); exponential in RES, 0 the gentlest.
        |
        | Coefficients are Q30 (|c| < 2). The EMAC's fractional multiply of a
        | Q30 operand comes out at half the other's scale; the coefficient
        | routine doubles each such product, and the filter sums its five at
        | half scale and doubles the sum, saturating, so no partial sum nears
        | full scale. The EMAC's << scale factor is not used: with it the
        | first build's BP was silent and LP2 and HP2 wrong on the device
        | (2026-10-06), as if it were ignored in fractional mode. Modelled against floating point
        | over every TYP and FRQ and a spread of RES and DEP (2026-10-06): no
        | set unstable, every coefficient within 4e-5 of its float design and
        | under 2, LP2 and HP2 at -3.01 dB at FRQ with RES 0.
        | ------------------------------------------------------------------
        .section .bq,"ax"

        | bq_coef(d0 = slot, d5 = the entry): the slot's biquad coefficients,
        | (b0, b1, b2, -a1, -a2), into bq_coefs, and bq_on set. From the
        | vs_body's coefficient pass, in the audio interrupt, when the slot's
        | entry changes; keeps every register. alpha = sin(w0) kq with kq =
        | 1 / (2 Q) by RES; a0 = 1 + alpha, whose reciprocal is a 16-bit
        | estimate from divu.l and one Newton step, inv += inv (1 - a0 inv).
        | Each product with a Q30 operand is doubled after its movclr.
        .align  2
bq_coef:
        lea     -40(%sp),%sp
        movem.l %d0-%d7/%a0-%a1,(%sp)
        move.l  %d0,%d7                           | the slot
        move.l  %d5,%d1
        lsr.l   #8,%d1
        and.l   #0xff,%d1
        move.l  %d1,%a1                           | DEP
        move.l  %d5,%d3
        swap    %d3
        and.l   #0xff,%d3                         | FRQ
        move.l  %d5,%d4
        moveq   #24,%d0
        lsr.l   %d0,%d4                           | TYP
        lea     bq_cos,%a0
        move.l  (%a0,%d3.l*4),%d6                 | c, Q31
        lea     bq_sin,%a0
        move.l  (%a0,%d3.l*4),%d2                 | s, Q31
        lea     bq_kq_lh,%a0
        cmp.l   #TYP_LP2,%d4
        beq.s   1f
        cmp.l   #TYP_HP2,%d4
        beq.s   1f
        lea     bq_kq_bp,%a0
1:      move.l  %d5,%d0
        and.l   #FLT_7_BITS,%d0                   | RES
        mvz.w   (%a0,%d0.l*2),%d0
        swap    %d0                               | kq, Q31
        mac.l   %d2,%d0,%acc2
        movclr.l %acc2,%d5                        | alpha, Q31
        move.l  %d5,%d2
        asr.l   #1,%d2
        add.l   #0x40000000,%d2                   | a0, Q30
        move.l  %d2,%d3
        moveq   #15,%d0
        lsr.l   %d0,%d3
        move.l  #0x7fffffff,%d0
        divu.l  %d3,%d0
        moveq   #14,%d3
        lsl.l   %d3,%d0                           | 1 / a0, about 16 bits
        mac.l   %d2,%d0,%acc2
        movclr.l %acc2,%d3                        | a0 inv
        add.l   %d3,%d3
        move.l  #0x40000000,%d1
        sub.l   %d3,%d1                           | 1 - a0 inv
        mac.l   %d0,%d1,%acc2
        movclr.l %acc2,%d3
        add.l   %d3,%d3
        add.l   %d3,%d0                           | inv, Q30
        lea     bq_coefs,%a0
        move.l  %d7,%d3
        lsl.l   #2,%d3
        add.l   %d3,%a0
        lsl.l   #2,%d3
        add.l   %d3,%a0                           | the slot's five, 20 B
        mac.l   %d6,%d0,%acc2
        movclr.l %acc2,%d3
        add.l   %d3,%d3
        move.l  %d3,12(%a0)                       | -a1 = 2 c / a0
        move.l  #0x40000000,%d1
        move.l  %d5,%d3
        asr.l   #1,%d3
        sub.l   %d3,%d1                           | 1 - alpha, Q30
        mac.l   %d1,%d0,%acc2
        movclr.l %acc2,%d3
        add.l   %d3,%d3
        neg.l   %d3
        move.l  %d3,16(%a0)                       | -a2 = -(1 - alpha) / a0
        | H's numerator, over a0, into d1 (b0), d2 (b1), d3 (b2)
        cmp.l   #TYP_LP2,%d4
        bne.s   2f
        move.l  #0x40000000,%d1
        asr.l   #1,%d6
        sub.l   %d6,%d1                           | 1 - c, Q30
        mac.l   %d1,%d0,%acc2
        movclr.l %acc2,%d2                        | b1 = (1 - c) / a0
        add.l   %d2,%d2
        move.l  %d2,%d1
        asr.l   #1,%d1                            | b0
        move.l  %d1,%d3                           | b2
        bra.s   6f
2:      cmp.l   #TYP_HP2,%d4
        bne.s   3f
        move.l  #0x40000000,%d1
        asr.l   #1,%d6
        add.l   %d6,%d1                           | 1 + c, Q30
        mac.l   %d1,%d0,%acc2
        movclr.l %acc2,%d2
        add.l   %d2,%d2
        move.l  %d2,%d1
        asr.l   #1,%d1                            | b0 = (1 + c) / 2 a0
        move.l  %d1,%d3                           | b2
        neg.l   %d2                               | b1
        bra.s   6f
3:      cmp.l   #TYP_BS,%d4
        bne.s   4f
        move.l  %d0,%d1                           | b0 = 1 / a0
        move.l  %d0,%d3                           | b2
        move.l  12(%a0),%d2
        neg.l   %d2                               | b1 = -2 c / a0
        bra.s   6f
4:      asr.l   #1,%d5                            | BP and PK: alpha, Q30
        mac.l   %d5,%d0,%acc2
        movclr.l %acc2,%d1                        | b0 = alpha / a0
        add.l   %d1,%d1
        moveq   #0,%d2
        move.l  %d1,%d3
        neg.l   %d3                               | b2
        | the mix: g (d5) and m (d6), Q31
6:      move.l  %a1,%d0                           | DEP
        cmp.l   #TYP_PK,%d4
        bne.s   7f
        move.l  #0x7fffffff,%d5
        lea     bq_pk,%a1
        mvz.w   (%a1,%d0.l*2),%d6
        swap    %d6
        bra.s   8f
7:      lea     flt_gain,%a1
        mvz.w   (%a1,%d0.l*2),%d5
        swap    %d5
        move.l  #0x7fffffff,%d6
        sub.l   %d5,%d6
8:      move.l  %d5,%d0
        asr.l   #1,%d0
        move.l  %d0,%acc2                         | g, Q30
        mac.l   %d6,%d1,%acc2
        movclr.l %acc2,%d0
        move.l  %d0,(%a0)                         | b0' = g + m b0
        move.l  12(%a0),%d0
        neg.l   %d0                               | a1
        mac.l   %d5,%d0,%acc2
        mac.l   %d6,%d2,%acc2
        movclr.l %acc2,%d0
        move.l  %d0,4(%a0)                        | b1' = g a1 + m b1
        move.l  16(%a0),%d0
        neg.l   %d0                               | a2
        mac.l   %d5,%d0,%acc2
        mac.l   %d6,%d3,%acc2
        movclr.l %acc2,%d0
        move.l  %d0,8(%a0)                        | b2' = g a2 + m b2
        lea     bq_on,%a0
        moveq   #1,%d0
        move.b  %d0,(%a0,%d7.l)
        movem.l (%sp),%d0-%d7/%a0-%a1
        lea     40(%sp),%sp
        rts

        | bq_run: after the 1-pole pass, each slot with bq_on set through its
        | biquad, in place, direct form I:
        |   y = b0 x + b1 x1 + b2 x2 - a1 y1 - a2 y2
        | five multiplies a frame, summed at half scale and doubled, 32 frames in four runs of eight; the last
        | run's loads read the words past the buffer, unused. A slot without
        | one keeps its state on the signal, every term its last sample, so
        | turning one on starts from there. From vs_body, which saved every
        | register; clobbers all but sp.
        .align  2
bq_run:
        lea     bq_on,%a6
        lea     bq_state,%a0
        lea     bq_coefs,%a1
        lea     RXBUF+8,%a2
1:      move.l  %a2,-(%sp)                        | the slot's column
        tst.b   (%a6)
        bne.s   2f
        move.l  (FRAMES-1)*RXSTRIDE(%a2),%d0
        move.l  %d0,(%a0)
        move.l  %d0,4(%a0)
        move.l  %d0,8(%a0)
        move.l  %d0,12(%a0)
        bra.w   5f
2:      move.l  (%a1),%d5                         | b0
        move.l  4(%a1),%d6                        | b1
        move.l  8(%a1),%d7                        | b2
        move.l  12(%a1),%a3                       | -a1
        move.l  16(%a1),%a4                       | -a2
        move.l  (%a0),%d1                         | x1
        move.l  4(%a0),%d2                        | x2
        move.l  8(%a0),%d3                        | y1
        move.l  12(%a0),%d4                       | y2
        lea     FRAMES*RXSTRIDE(%a2),%a5          | the column's end
        move.l  (%a2),%d0                         | x
3:      .irp    i,0,1,2,3,4,5,6,7
        mac.l   %d0,%d5,%acc2
        mac.l   %d1,%d6,%acc2
        mac.l   %d2,%d7,%acc2
        move.l  %d1,%d2                           | x2 = x1
        move.l  %d0,%d1                           | x1 = x
        mac.l   %d3,%a3,%acc2
        mac.l   %d4,%a4,RXSTRIDE*(\i+1)(%a2),%d0,%acc2
        move.l  %d3,%d4                           | y2 = y1
        movclr.l %acc2,%d3                        | y / 2
        add.l   %d3,%d3
        sats.l  %d3                               | y1 = y, saturated
        move.l  %d3,RXSTRIDE*\i(%a2)
        .endr
        lea     8*RXSTRIDE(%a2),%a2
        cmpa.l  %a5,%a2
        bne.w   3b
        move.l  %d1,(%a0)
        move.l  %d2,4(%a0)
        move.l  %d3,8(%a0)
        move.l  %d4,12(%a0)
5:      move.l  (%sp)+,%a2
        addq.l  #4,%a2                            | the next slot's column
        lea     16(%a0),%a0
        lea     20(%a1),%a1
        addq.l  #1,%a6
        cmpa.l  #bq_on+8,%a6
        bne.w   1b
        rts

        | Written at run time: per slot, bq_on, the coefficients bq_coef left
        | and the biquad's state (x1, x2, y1, y2).
        .align  2
bq_coefs:
        .space  8 * 20
bq_state:
        .space  8 * 16
bq_on:
        .space  8
        .align  2

        | cave16: the tables, generated from the formulas above (the assembler
        | has no trigonometry). bq_cos and bq_sin: cos and sin of w0 = 2 pi fc
        | / 48000 at FRQ's fc = 13.75 * 2^(FRQ / 12), Q31. bq_kq_lh and
        | bq_kq_bp: 1 / (2 Q), Q15, Q = 0.707 (2 / 0.707)^(RES / 127) and
        | 0.5 * 16^(RES / 127). bq_pk: 10^(B / 20) - 1, Q15, B = 6 DEP / 127.
        .section .bqt,"a"
        .align  2
bq_cos:
        .long   2147480170, 2147479744, 2147479265, 2147478729
        .long   2147478126, 2147477450, 2147476691, 2147475839
        .long   2147474883, 2147473810, 2147472605, 2147471252
        .long   2147469734, 2147468030, 2147466118, 2147463971
        .long   2147461561, 2147458857, 2147455821, 2147452413
        .long   2147448588, 2147444294, 2147439475, 2147434065
        .long   2147427993, 2147421178, 2147413528, 2147404941
        .long   2147395302, 2147384483, 2147372339, 2147358708
        .long   2147343408, 2147326234, 2147306957, 2147285320
        .long   2147261033, 2147233771, 2147203172, 2147168825
        .long   2147130272, 2147086998, 2147038425, 2146983904
        .long   2146922707, 2146854017, 2146776915, 2146690372
        .long   2146593233, 2146484199, 2146361816, 2146224447
        .long   2146070260, 2145897195, 2145702941, 2145484906
        .long   2145240178, 2144965492, 2144657181, 2144311132
        .long   2143922726, 2143486784, 2142997490, 2142448321
        .long   2141831955, 2141140178, 2140363773, 2139492400
        .long   2138514457, 2137416931, 2136185222, 2134802957
        .long   2133251770, 2131511069, 2129557760, 2127365953
        .long   2124906624, 2122147244, 2119051360, 2115578130
        .long   2111681806, 2107311157, 2102408830, 2096910639
        .long   2090744774, 2083830935, 2076079365, 2067389793
        .long   2057650268, 2046735880, 2034507373, 2020809627
        .long   2005470023, 1988296680, 1969076582, 1947573589
        .long   1923526358, 1896646205, 1866614931, 1833082687
        .long   1795665933, 1753945605, 1707465613, 1655731854
        .long   1598211939, 1534335947, 1463498527, 1385062817
        .long   1298366713, 1202732155, 1097478245, 981939146
        .long   855487897, 717567443, 567730340, 405688735
        .long   231376285, 45023663, -152750937, -360835345
        .long   -577500917, -800265346, -1025744258, -1249498244
        .long   -1465886336, -1667942828, -1847301861, -1994203459
bq_sin:
        .long   3865191, 4095027, 4338530, 4596512
        .long   4869834, 5159409, 5466203, 5791239
        .long   6135603, 6500444, 6886979, 7296499
        .long   7730369, 8190039, 8677042, 9193002
        .long   9739643, 10318788, 10932370, 11582436
        .long   12271156, 13000829, 13773888, 14592914
        .long   15460639, 16379959, 17353941, 18385836
        .long   19479085, 20637337, 21864456, 23164535
        .long   24541912, 26001181, 27547209, 29185153
        .long   30920476, 32758965, 34706749, 36770324
        .long   38956568, 41272769, 43726646, 46326375
        .long   49080619, 51998550, 55089885, 58364916
        .long   61834542, 65510306, 69404433, 73529867
        .long   77900315, 82530291, 87435161, 92631189
        .long   98135597, 103966608, 110143510, 116686712
        .long   123617807, 130959635, 138736353, 146973504
        .long   155698089, 164938644, 174725318, 185089948
        .long   196066150, 207689392, 219997084, 233028657
        .long   246825651, 261431789, 276893057, 293257773
        .long   310576654, 328902862, 348292049, 368802378
        .long   390494519, 413431621, 437679253, 463305290
        .long   490379760, 518974617, 549163444, 581021050
        .long   614622970, 650044811, 687361453, 726646041
        .long   767968753, 811395299, 856985082, 904788999
        .long   954846777, 1007183792, 1061807288, 1118701873
        .long   1177824212, 1239096782, 1302400552, 1367566469
        .long   1434365579, 1502497660, 1571578213, 1641123704
        .long   1710534974, 1779078802, 1845867688, 1909838091
        .long   1969727513, 2024051132, 2071079013, 2108815466
        .long   2134982678, 2147011618, 2142044157, 2116951552
        .long   2068375863, 1992802397, 1886672927, 1746550932
        .long   1569351226, 1352646569, 1095062488, 796767583
bq_kq_lh:
        .word   23170, 22982, 22794, 22608, 22424, 22241, 22060, 21880
        .word   21702, 21525, 21349, 21175, 21002, 20831, 20661, 20493
        .word   20326, 20160, 19996, 19833, 19671, 19511, 19351, 19194
        .word   19037, 18882, 18728, 18575, 18424, 18274, 18125, 17977
        .word   17830, 17685, 17541, 17398, 17256, 17115, 16976, 16837
        .word   16700, 16564, 16429, 16295, 16162, 16030, 15899, 15770
        .word   15641, 15514, 15387, 15262, 15137, 15014, 14892, 14770
        .word   14650, 14530, 14412, 14294, 14178, 14062, 13947, 13834
        .word   13721, 13609, 13498, 13388, 13279, 13171, 13063, 12957
        .word   12851, 12746, 12642, 12539, 12437, 12336, 12235, 12135
        .word   12036, 11938, 11841, 11744, 11649, 11554, 11459, 11366
        .word   11273, 11181, 11090, 11000, 10910, 10821, 10733, 10645
        .word   10559, 10473, 10387, 10303, 10219, 10135, 10053, 9971
        .word   9889, 9809, 9729, 9649, 9571, 9493, 9415, 9339
        .word   9262, 9187, 9112, 9038, 8964, 8891, 8818, 8746
        .word   8675, 8604, 8534, 8465, 8396, 8327, 8259, 8192
bq_kq_bp:
        .word   32767, 32060, 31368, 30691, 30028, 29379, 28745, 28124
        .word   27517, 26923, 26341, 25772, 25216, 24671, 24139, 23617
        .word   23107, 22608, 22120, 21642, 21175, 20718, 20270, 19833
        .word   19404, 18985, 18575, 18174, 17782, 17398, 17022, 16654
        .word   16295, 15943, 15599, 15262, 14932, 14610, 14294, 13986
        .word   13684, 13388, 13099, 12816, 12539, 12269, 12004, 11744
        .word   11491, 11243, 11000, 10762, 10530, 10303, 10080, 9862
        .word   9649, 9441, 9237, 9038, 8842, 8652, 8465, 8282
        .word   8103, 7928, 7757, 7589, 7425, 7265, 7108, 6955
        .word   6805, 6658, 6514, 6373, 6236, 6101, 5969, 5840
        .word   5714, 5591, 5470, 5352, 5236, 5123, 5013, 4904
        .word   4798, 4695, 4593, 4494, 4397, 4302, 4209, 4118
        .word   4029, 3942, 3857, 3774, 3693, 3613, 3535, 3458
        .word   3384, 3311, 3239, 3169, 3101, 3034, 2968, 2904
        .word   2842, 2780, 2720, 2661, 2604, 2548, 2493, 2439
        .word   2386, 2335, 2284, 2235, 2187, 2139, 2093, 2048
bq_pk:
        .word   0, 179, 358, 539, 721, 903, 1087, 1272
        .word   1457, 1644, 1832, 2020, 2210, 2401, 2593, 2786
        .word   2979, 3174, 3370, 3568, 3766, 3965, 4165, 4367
        .word   4569, 4773, 4978, 5184, 5391, 5599, 5808, 6018
        .word   6230, 6443, 6656, 6871, 7088, 7305, 7524, 7743
        .word   7964, 8186, 8410, 8634, 8860, 9087, 9315, 9545
        .word   9776, 10008, 10241, 10476, 10712, 10949, 11187, 11427
        .word   11668, 11910, 12154, 12399, 12645, 12893, 13142, 13392
        .word   13644, 13897, 14152, 14408, 14665, 14924, 15184, 15445
        .word   15708, 15973, 16238, 16506, 16774, 17045, 17316, 17589
        .word   17864, 18140, 18418, 18697, 18978, 19260, 19544, 19829
        .word   20116, 20404, 20694, 20986, 21279, 21574, 21870, 22168
        .word   22468, 22769, 23072, 23377, 23683, 23991, 24300, 24612
        .word   24924, 25239, 25556, 25874, 26193, 26515, 26838, 27163
        .word   27490, 27819, 28149, 28482, 28816, 29152, 29489, 29829
        .word   30170, 30513, 30859, 31206, 31555, 31905, 32258, 32613

        .text


        | ------------------------------------------------------------------
        | cave23 and cave17: the transient shaper, after the filters and before
        | the sum, a slot at a time for each voice whose track has ATK or SUS
        | set; a slot with both 0 costs a few instructions a block. Modelled
        | in tools/voice_dac_shaper.py (block mode, --lag 0) and tuned by ear
        | on captured voices there. Once a block, from the block's peak level:
        |   Ef  instant attack, 40 ms release    Es  15 ms attack, 150 ms release
        |   Eh  instant attack, 300 ms release
        | t = dB(Ef / Es) and s = dB(Eh / Ef), each clipped to 0..12 dB, and
        |   gain = ATK / 64 * 12 dB * t / 12 dB + SUS / 64 * 12 dB * s / 12 dB
        | capped at +6 dB and -24 dB, 0 dB below -60 dBFS on Eh. A block's own
        | peak sets its gain (two passes: the peak, then the scaling), ramped
        | from the last block's across the 32 frames, or stepping there at the
        | block's start when it moves more than 3 dB, as at an onset. A voice
        | turned on starts its followers at its first block's peak, so it does
        | not take the start as a hit. Levels in dB are 1/16 dB steps from
        | shp_log, a normalisation and a 128-entry table; the gain is the
        | 0.25 dB table shp_gain, -24..+6 dB, Q30, applied at half scale and
        | doubled with saturation. From vs_body, which saved every register;
        | clobbers all but sp.
        | ------------------------------------------------------------------
        .section .shp,"ax"
        .align  2
shp_run:
        moveq   #0,%d7                            | physical voice
1:      lea     SLOT_MAP,%a0
        move.l  (%a0,%d7.l*4),%d6                 | its slot
        lea     VOICE_OWNER,%a0
        mvz.b   (%a0,%d7.l),%d0                   | its track
        lea     shp_track,%a0
        move.l  (%a0,%d0.l*4),%d5                 | ATK << 24 | SUS << 16 | POL << 8
        lea     shp_state,%a3
        move.l  %d6,%d0
        lsl.l   #3,%d0
        add.l   %d0,%a3
        add.l   %d0,%a3
        add.l   %d0,%a3                           | the slot's state, 24 B
        move.l  %d5,%d3
        moveq   #24,%d0
        asr.l   %d0,%d3                           | ATK
        move.l  %d5,%d4
        lsl.l   #8,%d4
        asr.l   %d0,%d4                           | SUS
        move.l  %d3,%d0
        or.l    %d4,%d0
        bne.s   2f
        clr.l   20(%a3)                           | off: primed again when on
        bra.w   9f
2:      lea     RXBUF+8,%a2
        move.l  %d6,%d0
        lsl.l   #2,%d0
        add.l   %d0,%a2                           | the slot's column
        | the block's peak
        moveq   #0,%d1
        move.l  %a2,%a4
        lea     FRAMES*RXSTRIDE(%a2),%a5
3:      .irp    i,0,1,2,3,4,5,6,7
        move.l  RXSTRIDE*\i(%a4),%d0
        bpl.s   10f
        neg.l   %d0
10:     cmp.l   %d0,%d1
        bcc.s   11f
        move.l  %d0,%d1
11:
        .endr
        lea     8*RXSTRIDE(%a4),%a4
        cmpa.l  %a5,%a4
        bne.s   3b
        tst.l   %d1
        bpl.s   4f
        move.l  #0x7fffffff,%d1                   | -1.0 negated
4:      tst.l   20(%a3)
        bne.s   5f
        move.l  %d1,(%a3)                         | turned on: the followers at
        move.l  %d1,4(%a3)                        | this block's peak, unity gain
        move.l  %d1,8(%a3)
        move.l  #0x40000000,%d0
        move.l  %d0,12(%a3)
        moveq   #96,%d0
        move.l  %d0,16(%a3)
        moveq   #1,%d0
        move.l  %d0,20(%a3)
        | Ef: instant attack, its release
5:      move.l  (%a3),%d0
        cmp.l   %d0,%d1
        ble.s   6f
        move.l  %d1,%d0
        bra.s   7f
6:      move.l  %d0,%d2
        sub.l   %d1,%d2
        move.l  #SHP_K_RF,%a1
        mac.l   %d2,%a1,%acc2
        movclr.l %acc2,%d2
        sub.l   %d2,%d0
7:      move.l  %d0,(%a3)
        | Es: its attack and release
        move.l  4(%a3),%d0
        move.l  %d1,%d2
        sub.l   %d0,%d2                           | peak - Es
        bmi.s   12f
        move.l  #SHP_K_AS,%a1
        bra.s   13f
12:     move.l  #SHP_K_RS,%a1
13:     mac.l   %d2,%a1,%acc2
        movclr.l %acc2,%d2
        add.l   %d2,%d0
        move.l  %d0,4(%a3)
        | Eh: instant attack, its release
        move.l  8(%a3),%d0
        cmp.l   %d0,%d1
        ble.s   14f
        move.l  %d1,%d0
        bra.s   15f
14:     move.l  %d0,%d2
        sub.l   %d1,%d2
        move.l  #SHP_K_RH,%a1
        mac.l   %d2,%a1,%acc2
        movclr.l %acc2,%d2
        sub.l   %d2,%d0
15:     move.l  %d0,8(%a3)
        | the gain's index in shp_gain, 96 for 0 dB
        moveq   #96,%d2
        cmp.l   #SHP_GATE,%d0
        blt.w   20f                               | below the gate: unity
        move.l  (%a3),%d0
        bsr.w   shp_log
        move.l  %d0,%d5                           | dB(Ef)
        move.l  4(%a3),%d0
        bsr.w   shp_log
        move.l  %d5,%d2
        sub.l   %d0,%d2                           | t, dB(Ef / Es)
        bpl.s   16f
        moveq   #0,%d2
16:     cmp.l   #192,%d2
        ble.s   17f
        move.l  #192,%d2
17:     move.l  8(%a3),%d0
        bsr.w   shp_log
        sub.l   %d5,%d0                           | s, dB(Eh / Ef)
        bpl.s   18f
        moveq   #0,%d0
18:     cmp.l   #192,%d0
        ble.s   19f
        move.l  #192,%d0
19:     muls.w  %d3,%d2                           | ATK t
        muls.w  %d4,%d0                           | SUS s
        add.l   %d0,%d2
        asr.l   #6,%d2                            | the gain, 1/16 dB
        moveq   #96,%d0
        cmp.l   %d0,%d2
        ble.s   21f
        move.l  %d0,%d2                           | +6 dB at most
21:     move.l  #-384,%d0
        cmp.l   %d0,%d2
        bge.s   22f
        move.l  %d0,%d2                           | -24 dB at least
22:     asr.l   #2,%d2
        add.l   #96,%d2                           | 0.25 dB steps from -24 dB
        | the gain: ramped, or a step at an onset
20:     lea     shp_gain,%a1
        move.l  (%a1,%d2.l*4),%d1                 | this block's
        move.l  16(%a3),%d0
        sub.l   %d2,%d0
        bpl.s   23f
        neg.l   %d0
23:     moveq   #12,%d5
        cmp.l   %d5,%d0
        ble.s   24f
        move.l  %d1,%d0                           | over 3 dB: step
        bra.s   25f
24:     move.l  12(%a3),%d0                       | else from the last block's
25:     move.l  %d2,16(%a3)
        move.l  %d1,12(%a3)
        move.l  %d1,%d2
        sub.l   %d0,%d2
        asr.l   #5,%d2                            | a frame's step
        add.l   %d2,%d0
        move.l  %a2,%a4
26:     .irp    i,0,1,2,3,4,5,6,7
        move.l  RXSTRIDE*\i(%a4),%d1
        mac.l   %d1,%d0,%acc2
        movclr.l %acc2,%d1
        add.l   %d1,%d1
        sats.l  %d1
        move.l  %d1,RXSTRIDE*\i(%a4)
        add.l   %d2,%d0
        .endr
        lea     8*RXSTRIDE(%a4),%a4
        cmpa.l  %a5,%a4
        bne.w   26b
9:      addq.l  #1,%d7
        moveq   #8,%d0
        cmp.l   %d0,%d7
        blt.w   1b
        rts

        | shp_log(d0 = x > 0): d0 = 20 log10(x) in 1/16 dB, less a constant;
        | x <= 0 a value far below any real one. Clobbers d1/a1.
        .align  2
shp_log:
        tst.l   %d0
        bgt.s   1f
        move.l  #-4000,%d0
        rts
1:      moveq   #0,%d1                            | the shift
        cmp.l   #0xffff,%d0
        bhi.s   2f
        swap    %d0
        moveq   #16,%d1
2:      cmp.l   #0xffffff,%d0
        bhi.s   3f
        lsl.l   #8,%d0
        addq.l  #8,%d1
3:      cmp.l   #0xfffffff,%d0
        bhi.s   4f
        lsl.l   #4,%d0
        addq.l  #4,%d1
4:      cmp.l   #0x3fffffff,%d0
        bhi.s   5f
        lsl.l   #2,%d0
        addq.l  #2,%d1
5:      tst.l   %d0
        bmi.s   6f
        lsl.l   #1,%d0
        addq.l  #1,%d1
6:      lsr.l   #8,%d0
        lsr.l   #8,%d0
        lsr.l   #8,%d0
        and.l   #0x7f,%d0                         | the mantissa's top 7 bits
        lea     shp_db,%a1
        mvz.w   (%a1,%d0.l*2),%d0
        muls.w  #-1541,%d1
        asr.l   #4,%d1                            | 6.02 dB a shift, 1/16 dB
        add.l   %d1,%d0
        rts

        | Written at run time: per slot Ef, Es, Eh, the gain (Q30), its index
        | and whether the shaper ran on the last block.
        .align  2
shp_state:
        .space  8 * 24

        | cave17: 20 log10(1 + m / 128) in 1/16 dB, m 0..127; and the gain
        | for -24..+6 dB in 0.25 dB steps, Q30.
        .section .shpt,"a"
        .align  2
shp_db:
        .word   0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15
        .word   16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 27, 28, 29, 30
        .word   31, 32, 33, 34, 34, 35, 36, 37, 38, 39, 39, 40, 41, 42, 43, 43
        .word   44, 45, 46, 47, 47, 48, 49, 50, 50, 51, 52, 53, 53, 54, 55, 56
        .word   56, 57, 58, 59, 59, 60, 61, 61, 62, 63, 63, 64, 65, 65, 66, 67
        .word   67, 68, 69, 69, 70, 71, 71, 72, 73, 73, 74, 75, 75, 76, 77, 77
        .word   78, 78, 79, 80, 80, 81, 81, 82, 83, 83, 84, 84, 85, 86, 86, 87
        .word   87, 88, 89, 89, 90, 90, 91, 91, 92, 92, 93, 94, 94, 95, 95, 96
shp_gain:
        .long   67748529, 69726822, 71762882, 73858396, 76015100, 78234781
        .long   80519278, 82870483, 85290345, 87780868, 90344115, 92982211
        .long   95697341, 98491754, 101367765, 104327757, 107374182, 110509565
        .long   113736503, 117057669, 120475814, 123993771, 127614455, 131340864
        .long   135176087, 139123300, 143185773, 147366874, 151670064, 156098910
        .long   160657080, 165348352, 170176611, 175145857, 180260209, 185523902
        .long   190941298, 196516884, 202255281, 208161242, 214239660, 220495571
        .long   226934158, 233560755, 240380852, 247400099, 254624313, 262059477
        .long   269711752, 277587477, 285693178, 294035569, 302621563, 311458272
        .long   320553018, 329913335, 339546978, 349461929, 359666402, 370168850
        .long   380977976, 392102733, 403552340, 415336281, 427464319, 439946503
        .long   452793173, 466014972, 479622855, 493628095, 508042296, 522877399
        .long   538145694, 553859832, 570032831, 586678091, 603809400, 621440953
        .long   639587356, 658263644, 677485290, 697268218, 717628817, 738583957
        .long   760150998, 782347808, 805192776, 828704830, 852903448, 877808678
        .long   903441154, 929822112, 956973408, 984917536, 1013677647, 1043277569
        .long   1073741824, 1105095651, 1137365027, 1170576685, 1204758142, 1239937715
        .long   1276144550, 1313408643, 1351760868, 1391232998, 1431857735, 1473668736
        .long   1516700640, 1560989098, 1606570803, 1653483517, 1701766107, 1751458575
        .long   1802602089, 1855239020, 1909412977, 1965168843, 2022552809, 2081612417
        .long   2142396597

        .text

        | ------------------------------------------------------------------
        | cave12: the page's glyph and graph gates, which the audio interrupt
        | never reaches, and the filter's read-only tables.
        | ------------------------------------------------------------------
        .section .flt,"ax"

        | The knob gates: page_get_value, param_apply_delta and
        | param_value_text for the page's ids, in cave12 with the other UI code.
        | ------------------------------------------------------------------
        | page_get_value for ids 5, 11 and 12, the dials: after the prologue,
        | over `moveal %sp@(16),%a2; movel %sp@(20),%d2`, where 0004's gate
        | rejoins. The frame holds d2/d3/a2; 20(%sp) is the id. The value in
        | 8.8: TYP 0..2, FRQ and DEP 0..127.
        | ------------------------------------------------------------------
        .align  2
hpf_get:
        move.l  20(%sp),%d0
        jsr     flt_ours
        bne.s   10f
        move.l  20(%sp),%d1
        jsr     flt_shift
        move.l  %d1,%d2
        jsr     flt_cur
        lsr.l   %d2,%d0
        and.l   #0xff,%d0
        lsl.l   #8,%d0
        movem.l (%sp),%d2-%d3/%a2                 | page_get_value's epilogue
        lea     12(%sp),%sp
        rts
10:     move.l  20(%sp),%d0
        jsr     shp_ours
        bne.s   9f
        move.l  20(%sp),%d0
        jsr     shp_get
        movem.l (%sp),%d2-%d3/%a2                 | page_get_value's epilogue
        lea     12(%sp),%sp
        rts
9:      move.l  16(%sp),%a2                       | displaced
        move.l  20(%sp),%d2                       | displaced
        jmp     GET_RESUME

        | ------------------------------------------------------------------
        | param_apply_delta for ids 5, 11 and 12, the knobs: over `jsr
        | 0x400b68d2`, where 0004's gate rejoins, with a2@(116) already pushed
        | as its argument. The frame holds d2/d3/a2 above that; 24(%sp) is the
        | id, 28(%sp) the delta in 8.8, a2 the view. A step a whole unit of
        | delta - for TYP, whose encoder range is stock TYP's (flt_knobs) and so
        | its deltas fractions, a sum carried in flt_typ_acc, as stock keeps
        | its 8.8 value's fraction - clamped to 0..7 for TYP and 0..127 for FRQ, RES and DEP; stock never
        | sees the id, so no lock is made. The view is invalidated after, as
        | nothing stock does redraws it.
        | ------------------------------------------------------------------
        .align  2
hpf_delta:
        move.l  24(%sp),%d0
        jsr     flt_ours
        bne.w   10f
        move.l  28(%sp),%d2
        moveq   #ID_TYP,%d0
        cmp.l   24(%sp),%d0
        bne.s   4f
        add.l   flt_typ_acc,%d2                   | TYP: whole steps toward zero,
        move.l  %d2,%d0                           | the fraction kept for the next
        bpl.s   5f
        neg.l   %d0
        lsr.l   #8,%d0
        neg.l   %d0
        bra.s   6f
5:      lsr.l   #8,%d0
6:      move.l  %d0,%d1
        lsl.l   #8,%d1
        sub.l   %d1,%d2
        move.l  %d2,flt_typ_acc
        move.l  %d0,%d2
        bra.s   8f
4:      asr.l   #8,%d2                            | whole steps, sign preserved
8:      tst.l   %d2
        beq.w   7f
        move.l  24(%sp),%d1
        jsr     flt_shift
        move.l  %d1,%d3
        jsr     flt_cur
        move.l  %d0,%a0                           | the entry
        lsr.l   %d3,%d0
        and.l   #0xff,%d0
        add.l   %d2,%d0
        bpl.s   1f
        moveq   #0,%d0
1:      moveq   #FRQ_MAX,%d1
        cmp.l   #24,%d3
        bne.s   3f
        moveq   #TYP_PK,%d1
3:      cmp.l   %d1,%d0
        ble.s   2f
        move.l  %d1,%d0
2:      lsl.l   %d3,%d0                           | the field, in place
        move.l  #0xff,%d1
        lsl.l   %d3,%d1
        not.l   %d1
        move.l  %a0,%d2
        and.l   %d1,%d2
        or.l    %d2,%d0
        jsr     flt_set
        move.l  %a2,-(%sp)
        jsr     VIEW_INVALIDATE
        addq.l  #4,%sp
7:      addq.l  #4,%sp                            | the pushed argument
        movem.l (%sp),%d2-%d3/%a2                 | param_apply_delta's epilogue
        lea     12(%sp),%sp
        rts
10:     move.l  24(%sp),%d0
        jsr     shp_ours
        bne.s   9f
        move.l  24(%sp),%d0
        move.l  28(%sp),%d1
        move.l  32(%sp),%d2
        and.l   #0xff,%d2                         | funcHeld
        jsr     shp_delta
        move.l  %a2,-(%sp)
        jsr     VIEW_INVALIDATE
        addq.l  #4,%sp
        bra.w   7b
9:      jsr     DELTA_CALL                        | displaced
        jmp     DELTA_RESUME

        | ------------------------------------------------------------------
        | param_value_text for ids 5, 11 and 12, the popups: over `movel
        | %d4,%sp@-` and the first half of `jsr 0x400ff556`, where 0004's gate
        | rejoins. The frame holds d2-d4/a2-a3; d4 is the id, d3 the output
        | buffer. The value is read from the selected track's sound into d2,
        | in 8.8, as stock's value argument is not ours for these ids (it read
        | 0 on the device). FRQ goes on as stock's FRQ, id 47, so it
        | reads as stock's does - in hertz where 0008 is built, whose gate
        | follows. RES goes on as stock's RES, id 48. TYP goes on as stock's
        | TYP, id 49, at its index for ours (flt_stock_typ); OFF is written
        | here. DEP is written here: "0.0dB", "-0.3dB" .. "-31.5dB" to the
        | tenth, then "FULL"; for PK, a boost, "+0.0dB" .. "+6.0dB". d4 and d2
        | are the frame's and restored by the epilogue.
        | ------------------------------------------------------------------
        .align  2
hpf_text:
        move.l  %d4,%d0
        jsr     flt_ours
        bne.w   11f
        move.l  %d4,%d1
        jsr     flt_shift
        move.l  %d1,%d2
        jsr     flt_cur
        lsr.l   %d2,%d0
        and.l   #0xff,%d0
        lsl.l   #8,%d0
        move.l  %d0,%d2                           | the value, 8.8
        cmp.l   #ID_FRQ,%d4
        bne.s   8f
        moveq   #ID_STOCK_FRQ,%d4
        bra.w   9f
8:      cmp.l   #ID_RES,%d4
        bne.s   1f
        moveq   #ID_STOCK_RES,%d4
        bra.w   9f
1:      move.l  %d3,%a1
        move.l  %d2,%d0
        asr.l   #8,%d0
        cmp.l   #ID_TYP,%d4
        bne.s   3f
        tst.l   %d0
        bne.s   2f
        lea     txt_off,%a0
        bra.w   5f
2:      lea     flt_stock_typ,%a0
        mvz.b   (%a0,%d0.l),%d0                   | stock's TYP index
        lsl.l   #8,%d0
        move.l  %d0,%d2
        moveq   #ID_STOCK_TYP,%d4
        bra.w   9f
3:      move.l  %d0,%d4                           | DEP; the id is not needed again
        jsr     flt_cur
        moveq   #24,%d1
        lsr.l   %d1,%d0
        move.l  %d3,%a1
        cmp.l   #TYP_PK,%d0
        bne.s   10f
        move.l  %d4,%d0                           | PK: DEP is a boost, 0..+6 dB
        mulu.w  #120,%d0
        add.l   #127,%d0
        divu.w  #254,%d0
        and.l   #0xffff,%d0                       | tenths of a dB, 0..60
        move.b  #'+',(%a1)+
        bra.s   6f
10:     move.l  %d4,%d0
        cmp.l   #DEP_FULL,%d0
        blt.s   4f
        lea     txt_full,%a0
        bra.s   5f
4:      mulu.w  #25,%d0
        addq.l  #5,%d0
        divu.w  #10,%d0
        and.l   #0xffff,%d0                       | tenths of a dB, 0..315
        beq.s   6f
        move.b  #'-',(%a1)+
6:      divu.w  #10,%d0                           | whole dB, the tenth above
        move.l  %d0,%d2
        and.l   #0xffff,%d0
        moveq   #10,%d1
        cmp.l   %d1,%d0
        bcs.s   7f
        divu.w  #10,%d0                           | tens, units above
        moveq   #'0',%d1
        add.l   %d0,%d1                           | the low byte is the digit
        move.b  %d1,(%a1)+
        swap    %d0
        and.l   #0xffff,%d0
7:      moveq   #'0',%d1
        add.l   %d0,%d1
        move.b  %d1,(%a1)+
        move.b  #'.',(%a1)+
        swap    %d2
        and.l   #0xffff,%d2
        moveq   #'0',%d1
        add.l   %d2,%d1
        move.b  %d1,(%a1)+
        lea     txt_db,%a0
5:      move.b  (%a0)+,(%a1)+
        bne.s   5b
        movem.l (%sp),%d2-%d4/%a2-%a3             | param_value_text's epilogue
        lea     20(%sp),%sp
        rts
11:     move.l  %d4,%d0
        jsr     shp_ours
        bne.s   9f
        move.l  %d4,%d0
        move.l  %d3,%a1
        jsr     shp_text
        movem.l (%sp),%d2-%d4/%a2-%a3             | param_value_text's epilogue
        lea     20(%sp),%sp
        rts
9:      move.l  %d4,-(%sp)                        | displaced
        jsr     TEXT_CALL                         | displaced
        jmp     TEXT_RESUME

        | ------------------------------------------------------------------
        | param_knob_draw past its prologue, where 0004's gate rejoins
        | (param_knob_draw_body): over `movel %sp@(28),%d2; movel %sp@(40),%d3`,
        | both re-emitted, rejoining at 0x400a858c. The frame holds d2-d5;
        | 24(%sp) is the id and 28(%sp) the value, the caller's argument slots,
        | which stock overwrites itself for its tail call; 40, 44 and 48(%sp)
        | are the canvas, x and y. TYP is read from the selected track's sound,
        | as the value argument is not ours. LP1 and HP1 draw as stock's TYP
        | (filter_type_knob_draw), its glyphs 1 and 3. OFF draws "OFF" as LFO
        | DST draws its name (lfo_dst_knob_draw), and returns. d0 is set by the
        | call that follows.
        | ------------------------------------------------------------------
        .align  2
flt_glyph:
        moveq   #ID_TYP,%d0
        cmp.l   24(%sp),%d0
        bne.s   9f
        jsr     flt_cur
        swap    %d0
        lsr.l   #8,%d0
        and.l   #0xff,%d0                         | TYP
        beq.s   1f
        lea     flt_stock_typ,%a0
        mvz.b   (%a0,%d0.l),%d0                   | stock's TYP index
        lsl.l   #8,%d0
        move.l  %d0,28(%sp)
        moveq   #ID_STOCK_TYP,%d0
        move.l  %d0,24(%sp)
9:      move.l  28(%sp),%d2                       | displaced
        move.l  40(%sp),%d3                       | displaced
        jmp     GLYPH_RESUME
1:      pea     text_ctx
        jsr     text_font
        addq.l  #4,%sp
        pea     txt_off
        pea     str_fmt_s
        pea     str_width_xxx
        clr.l   -(%sp)
        pea     0x1
        move.l  48+20(%sp),%d1
        subq.l  #2,%d1
        move.l  %d1,-(%sp)                        | y - 2
        move.l  44+24(%sp),-(%sp)                 | x
        move.l  %d0,-(%sp)                        | the font
        move.l  40+32(%sp),-(%sp)                 | the canvas
        jsr     text_draw
        lea     36(%sp),%sp
        movem.l (%sp),%d2-%d5                     | param_knob_draw's epilogue
        lea     16(%sp),%sp
        rts

        | ------------------------------------------------------------------
        | sound_page_draw at its page compare, `moveq #6,%d1; cmpl %d0,%d1` and
        | the first half of `bnew 0x400d3134`, d0 the view's page and the
        | knobs already drawn; the stack is at the frame. FILTER and every
        | other page go on as stock's. DAC FILTER draws stock's FILTER graph
        | (filter_graph_draw) in the top row, over FRQ and RES - the box at x
        | 6..58, y 40..52 - from the selected track's FRQ, TYP and, for the
        | 2-pole types, RES, then returns through sound_page_draw's epilogue. TYP OFF
        | draws as HP1 at FRQ 0: the corner at the box's left edge, the line
        | flat across it. The rise stock draws before the corner, x -4..5,
        | outside the box, is cleared after. a2 is the view and d2 the canvas.
        | ------------------------------------------------------------------
        .align  2
flt_graph:
        moveq   #PAGE_FILTER,%d1
        cmp.l   %d0,%d1
        bne.s   1f
        jmp     SOUND_PAGE_FILTER
1:      moveq   #PAGE_HPF,%d1
        cmp.l   %d0,%d1
        beq.s   2f
        jmp     SOUND_PAGE_OTHER
2:      jsr     flt_cur
        move.l  %d0,%d1
        swap    %d1
        lsr.l   #8,%d1
        and.l   #0xff,%d1                         | TYP
        move.l  %d1,%d3                           | kept: sound_page_draw's frame
        beq.s   3f
        moveq   #0,%d4                            | RES: none for LP1 and HP1
        cmp.l   #TYP_LP1,%d1
        beq.s   6f
        cmp.l   #TYP_HP1,%d1
        beq.s   6f
        move.l  %d0,%d4
        and.l   #FLT_7_BITS,%d4
        lsl.l   #8,%d4
6:      lea     flt_stock_typ,%a0
        mvz.b   (%a0,%d1.l),%d1                   | stock's TYP index
        swap    %d0
        and.l   #0xff,%d0
        lsl.l   #8,%d0                            | FRQ
        bra.s   4f
3:      moveq   #3,%d1                            | OFF: HP1
        moveq   #0,%d0                            | at FRQ 0
        moveq   #0,%d4
4:      lsl.l   #8,%d1
        move.l  %d1,-(%sp)                        | TYP
        move.l  %d4,-(%sp)                        | RES
        move.l  %d0,-(%sp)                        | FRQ
        clr.l   -(%sp)                            | the top row
        clr.l   -(%sp)
        pea     0x6
        move.l  %d2,-(%sp)
        move.l  %a2,-(%sp)
        jsr     FILTER_GRAPH
        lea     32(%sp),%sp
        tst.l   %d3
        bne.s   5f
        clr.l   -(%sp)
        pea     53
        pea     5
        pea     39
        clr.l   -(%sp)
        move.l  %d2,-(%sp)
        jsr     CLEAR_RECT                        | the rise left of the box
        lea     24(%sp),%sp
5:      movem.l (%sp),%d2-%d5/%a2-%a4/%fp         | sound_page_draw's epilogue
        lea     36(%sp),%sp
        rts


        | flt_knobs: each idle tick, the encoder's range and acceleration for
        | TYP and RES as stock's TYP and RES have them, and for ATK and SUS as
        | stock's PAN has them, from their RAM records; with dial = 1 (off:
        | see mod.toml), SAMPLE FINE's +0x24 functor copied into ATK's and
        | SUS's, which drew them 0 until turned:
        | the Error records ours reuse are filled from one template, a wide
        | range that made TYP's knob skip types. TYP's maximum is ours, 7.
        | Clobbers d0/a0/a1.
        .align  2
flt_knobs:
        lea     PARAM_INFO+ID_STOCK_TYP*PI_STRIDE,%a0
        lea     PARAM_INFO+ID_TYP*PI_STRIDE,%a1
        move.l  4(%a0),4(%a1)
        move.l  #TYP_PK << 8,%d0
        move.l  %d0,8(%a1)
        move.l  16(%a0),16(%a1)
        lea     PARAM_INFO+ID_STOCK_RES*PI_STRIDE,%a0
        lea     PARAM_INFO+ID_RES*PI_STRIDE,%a1
        move.l  4(%a0),4(%a1)
        move.l  8(%a0),8(%a1)
        move.l  16(%a0),16(%a1)
        lea     PARAM_INFO+ID_STOCK_PAN*PI_STRIDE,%a0
        lea     PARAM_INFO+ID_ATK*PI_STRIDE,%a1
        move.l  4(%a0),4(%a1)
        move.l  8(%a0),8(%a1)
        move.l  16(%a0),16(%a1)
        lea     PARAM_INFO+ID_SUS*PI_STRIDE,%a1
        move.l  4(%a0),4(%a1)
        move.l  8(%a0),8(%a1)
        move.l  16(%a0),16(%a1)
        .if     P_DIAL
        lea     PARAM_INFO+ID_STOCK_FINE*PI_STRIDE+PI_DRAW,%a0
        lea     PARAM_INFO+ID_ATK*PI_STRIDE+PI_DRAW,%a1
        bsr.s   1f
        lea     PARAM_INFO+ID_SUS*PI_STRIDE+PI_DRAW,%a1
1:      move.l  (%a0),(%a1)                       | the std::function, 16 B
        move.l  4(%a0),4(%a1)
        move.l  8(%a0),8(%a1)
        move.l  12(%a0),12(%a1)
        .endif
        rts
flt_typ_acc:
        .long   0
shp_snap_acc:                                     | FUNC + turn's sum, 8.8
        .long   0
shp_snap_id:                                      | and the knob it is for
        .long   0

        | ------------------------------------------------------------------
        | The transient shaper's and POL's knobs, ATK, SUS and POL. Their values
        | live outside the entry word hpf_track holds: ATK and SUS signed,
        | -64..63, in velocity routes 1's and 2's spare bytes (the dials 0..127,
        | 64 the centre), POL in +0x6d bit 3. All 0 is no shaping, not
        | inverted.
        |   shp_ours(d0 = id) -> Z set for ID_ATK, ID_SUS and ID_POL.
        |   shp_entry(a0 = live sound) -> d0 = ATK << 24 | SUS << 16 | POL << 8,
        |                                 ATK and SUS clamped. Clobbers d1.
        |   shp_value(d0 = id, a0 = live sound) -> d0, the field: ATK and SUS
        |                                 signed and clamped, POL 0 or 1.
        |                                 Keeps d1 = id.
        |   shp_get(d0 = id) -> d0, the selected track's dial value, 8.8.
        |   shp_delta(d0 = id, d1 = delta, 8.8, d2 = FUNC held): ATK and SUS
        |                                 by whole steps, clamped, or with FUNC
        |                                 held to the next of -64, 0 and +63 in
        |                                 the turn's direction, as stock's FINE,
        |                                 once the turn has added up to snap
        |                                 (mod.toml) steps that way;
        |                                 POL on for a delta up, off for one
        |                                 down.
        |   shp_set(d0 = id, d1 = value): the selected track's sound and its
        |                                 shp_track entry, then the change
        |                                 notice, as flt_set.
        |   shp_text(d0 = id, a1 = buffer): "+12", "0", "-30"; POL "+" or "-".
        | The last four clobber d0/d1/a0/a1.
        | ------------------------------------------------------------------
        .align  2
shp_ours:
        cmp.l   #ID_ATK,%d0
        beq.s   9f
        cmp.l   #ID_SUS,%d0
        beq.s   9f
        cmp.l   #ID_POL,%d0
9:      rts

        | shp_clamp(d0): -64..63, as ATK and SUS read, so a stray byte (such as
        | the route-byte probe's marker, 90, in kits saved while it ran)
        | reads as the nearest value the knob can set. Keeps the rest.
        .align  2
shp_clamp:
        cmp.l   #63,%d0
        ble.s   1f
        moveq   #63,%d0
1:      cmp.l   #-64,%d0
        bge.s   2f
        moveq   #-64,%d0
2:      rts

        .align  2
shp_entry:
        mvs.b   OFF_SHP_SUS(%a0),%d0
        bsr.s   shp_clamp
        and.l   #0xff,%d0
        move.l  %d0,%d1
        mvs.b   OFF_SHP_ATK(%a0),%d0
        bsr.s   shp_clamp
        lsl.l   #8,%d0
        or.l    %d1,%d0
        lsl.l   #8,%d0
        mvz.b   OFF_FLT_TYP(%a0),%d1
        lsr.l   #FLT_POL_BIT,%d1
        and.l   #1,%d1
        or.l    %d1,%d0
        lsl.l   #8,%d0
        rts

        .align  2
shp_value:
        move.l  %d0,%d1
        cmp.l   #ID_ATK,%d1
        bne.s   1f
        mvs.b   OFF_SHP_ATK(%a0),%d0
        bra.s   shp_clamp
1:      cmp.l   #ID_SUS,%d1
        bne.s   2f
        mvs.b   OFF_SHP_SUS(%a0),%d0
        bra.s   shp_clamp
2:      mvz.b   OFF_FLT_TYP(%a0),%d0
        lsr.l   #FLT_POL_BIT,%d0
        and.l   #1,%d0
        rts

        .align  2
shp_get:
        move.l  %d0,-(%sp)
        jsr     shared_cur_sound
        move.l  (%sp)+,%d1
        tst.l   %d0
        beq.s   8f
        move.l  %d1,%d0
        bsr.s   shp_value
        cmp.l   #ID_POL,%d1
        beq.s   7f
        add.l   #64,%d0
7:      lsl.l   #8,%d0
        rts
8:      moveq   #0,%d0                            | no sound: the defaults
        cmp.l   #ID_POL,%d1
        beq.s   9f
        move.l  #64 << 8,%d0
9:      rts

        .align  2
shp_delta:
        lea     -8(%sp),%sp
        movem.l %d3-%d4,(%sp)
        move.l  %d0,%d3                           | the id
        move.l  %d1,%d4                           | the delta
        jsr     shared_cur_sound
        tst.l   %d0
        beq.w   9f
        move.l  %d3,%d0
        bsr.w   shp_value                         | the field now
        cmp.l   #ID_POL,%d3
        bne.w   1f
        tst.l   %d4
        beq.w   9f
        moveq   #1,%d0
        tst.l   %d4
        bpl.w   3f
        moveq   #0,%d0
        bra.w   3f
1:      tst.l   %d2
        beq.w   4f
        tst.l   %d4                               | FUNC: snap, once the turn adds
        beq.w   9f                                | up to P_SNAP steps one way
        move.l  shp_snap_acc,%d1
        cmp.l   shp_snap_id,%d3
        beq.w   10f
        moveq   #0,%d1                            | another knob: start again
10:     move.l  %d3,shp_snap_id
        move.l  %d1,%d2
        eor.l   %d4,%d2
        bpl.w   11f
        moveq   #0,%d1                            | the other way: start again
11:     add.l   %d4,%d1
        move.l  %d1,%d2
        bpl.w   12f
        neg.l   %d2
12:     cmp.l   #P_SNAP << 8,%d2
        bcc.w   13f
        move.l  %d1,shp_snap_acc                  | not far enough yet
        bra.w   9f
13:     clr.l   shp_snap_acc
        tst.l   %d4
        bmi.w   5f
        moveq   #63,%d1                           | up: 0, then +63
        tst.l   %d0
        bpl.w   6f
        moveq   #0,%d1
6:      move.l  %d1,%d0
        bra.w   3f
5:      moveq   #-64,%d1                          | down: 0, then -64
        tst.l   %d0
        ble.w   7f
        moveq   #0,%d1
7:      move.l  %d1,%d0
        bra.w   3f
4:      clr.l   shp_snap_acc                      | no FUNC: a snap starts afresh
        move.l  %d4,%d1
        asr.l   #8,%d1                            | whole steps
        beq.w   9f
        add.l   %d1,%d0
        moveq   #63,%d1
        cmp.l   %d1,%d0
        ble.w   2f
        move.l  %d1,%d0
2:      moveq   #-64,%d1
        cmp.l   %d1,%d0
        bge.w   3f
        move.l  %d1,%d0
3:      move.l  %d0,%d1
        move.l  %d3,%d0
        bsr.w   shp_set
9:      movem.l (%sp),%d3-%d4
        lea     8(%sp),%sp
        rts

        .align  2
shp_set:
        lea     -16(%sp),%sp
        movem.l %d2-%d5,(%sp)
        move.l  %d0,%d4                           | the id
        move.l  %d1,%d5                           | the value
        jsr     project_singleton
        move.l  %d0,%d2                           | the project
        move.l  %d0,%a0
        pea     PROJ_TRACKSEL(%a0)
        jsr     track_index_of
        addq.l  #4,%sp
        moveq   #VOICE_TRACKS,%d1
        cmp.l   %d1,%d0
        bcc.w   9f                                | the FX track has no voice
        move.l  %d0,%d3                           | the track
        move.l  %d3,-(%sp)
        add.l   #PROJ_KIT,%d2
        move.l  %d2,-(%sp)                        | the active kit
        jsr     kit_track_sound
        addq.l  #8,%sp
        move.l  %d0,%d2                           | the track's sound accessor
        beq.w   9f
        move.l  %d2,-(%sp)
        move.l  %d2,%a0
        move.l  (%a0),%a0
        move.l  VT_SOUND(%a0),%a0
        jsr     (%a0)
        addq.l  #4,%sp
        tst.l   %d0
        beq.s   9f
        move.l  %d0,%a0                           | the live sound
        cmp.l   #ID_ATK,%d4
        bne.s   1f
        move.b  %d5,OFF_SHP_ATK(%a0)
        bra.s   3f
1:      cmp.l   #ID_SUS,%d4
        bne.s   2f
        move.b  %d5,OFF_SHP_SUS(%a0)
        bra.s   3f
2:      mvz.b   OFF_FLT_TYP(%a0),%d0
        bclr    #FLT_POL_BIT,%d0
        tst.l   %d5
        beq.s   4f
        bset    #FLT_POL_BIT,%d0
4:      move.b  %d0,OFF_FLT_TYP(%a0)
3:      bsr.w   shp_entry
        lea     shp_track,%a1
        move.l  %d0,(%a1,%d3.l*4)
        lea     -8(%sp),%sp                       | SoundConfigChangedInfo, kind 1
        move.l  #SOUND_CONFIG_CHANGED,(%sp)
        move.b  #1,4(%sp)
        move.l  %sp,-(%sp)
        move.l  %d2,-(%sp)
        move.l  %d2,%a0
        move.l  (%a0),%a0
        move.l  VT_CONFIG_CHANGED(%a0),%a0
        jsr     (%a0)
        lea     16(%sp),%sp
9:      movem.l (%sp),%d2-%d5
        lea     16(%sp),%sp
        rts

        .align  2
shp_text:
        lea     -8(%sp),%sp
        move.l  %d0,(%sp)
        move.l  %a1,4(%sp)
        jsr     shared_cur_sound
        move.l  (%sp),%d1                         | the id
        move.l  4(%sp),%a1                        | the buffer
        addq.l  #8,%sp
        tst.l   %d0
        bne.s   1f
        moveq   #0,%d0
        bra.s   2f
1:      move.l  %d1,%d0
        bsr.w   shp_value
2:      cmp.l   #ID_POL,%d1
        bne.s   3f
        moveq   #'+',%d1
        tst.l   %d0
        beq.s   4f
        moveq   #'-',%d1
4:      move.b  %d1,(%a1)+
        clr.b   (%a1)
        rts
3:      tst.l   %d0
        beq.s   6f
        bpl.s   5f
        move.b  #'-',(%a1)+
        neg.l   %d0
        bra.s   6f
5:      move.b  #'+',(%a1)+
6:      divu.w  #10,%d0                           | tens, units above
        move.l  %d0,%d1
        and.l   #0xffff,%d1
        beq.s   7f
        add.l   #'0',%d1
        move.b  %d1,(%a1)+
7:      swap    %d0
        and.l   #0xffff,%d0
        add.l   #'0',%d0
        move.b  %d0,(%a1)+
        clr.b   (%a1)
        rts

        | stock's TYP index for each of ours, TYP - 1; OFF's, unused, is
        | stock's blank glyph.
flt_stock_typ:
        .byte   7, 0, 1, 2, 3, 4, 5, 6
        .align  2

        | ------------------------------------------------------------------
        | The routes' spare bytes. Each velocity and aftertouch route's amount
        | word holds the amount in its high byte; stock writes the low byte
        | only as 0 (sound_load's byte << 8, the defaults, the route menu's
        | whole steps) and saves only the high byte, but the engine, the menu's
        | display and its setter all take the whole word. So the low byte
        | carries data here only with: the sound push clearing it on the way
        | to the engine (rte_pushv, rte_pusha), the menus' getters clearing it
        | (rte_get_*) and their setters keeping it (rte_set_*, rte_setrte_*),
        | and the eight saved in slots 44..47 (rte_save, rte_rload) - route
        | i's velocity byte at +0x74 + i, its aftertouch byte at +0x78 + i, so
        | a sound saved without them loads them as 0.
        |   rte_save(a0 = live sound, a1 = stored record): slots 44..47.
        |   rte_load(a0 = live sound, a1 = stored record): the live bytes.
        |   rte_clear(a0 = live sound): the live bytes 0.
        | None touches a register but those named.
        | ------------------------------------------------------------------
        .align  2
rte_save:
        .irp    i,0,1,2,3
        move.b  OFF_RTE_VEL+3*\i(%a0),OFF_SLOT44+\i(%a1)
        move.b  OFF_RTE_AT+3*\i(%a0),OFF_SLOT44+4+\i(%a1)
        .endr
        rts

        .align  2
rte_load:
        .irp    i,0,1,2,3
        move.b  OFF_SLOT44+\i(%a1),OFF_RTE_VEL+3*\i(%a0)
        move.b  OFF_SLOT44+4+\i(%a1),OFF_RTE_AT+3*\i(%a0)
        .endr
        rts

        .align  2
rte_clear:
        .irp    i,0,1,2,3
        clr.b   OFF_RTE_VEL+3*\i(%a0)
        clr.b   OFF_RTE_AT+3*\i(%a0)
        .endr
        rts

        | sound_load once both route sets are loaded, over `tstb %d2; bnes
        | 0x40008378; movel %d3,%sp@-`, reimplemented: d2 is whether every
        | aftertouch route loaded. The frame holds six registers, so 28(%sp)
        | is the live sound and 32(%sp) the stored record. The spare bytes go
        | in after the routes, which stock writes whole. d0/d1 and a0/a1 are
        | not read again.
        .align  2
rte_rload:
        move.l  28(%sp),%a0
        move.l  32(%sp),%a1
        bsr.s   rte_load
        tst.b   %d2
        beq.s   1f
        jmp     RLOAD_OK
1:      move.l  %d3,-(%sp)
        jmp     RLOAD_RESUME                      | the fallback, which clears them

        | The sound push's route loops, each over its amount word's copy,
        | reimplemented to clear the low byte: velocity `movew
        | %a1@(112),%a0@(1216)` with d3 free (set again two instructions on),
        | aftertouch `movew %a2@(140),%a0@` with d2 free (likewise), its next
        | instruction re-emitted.
        .align  2
rte_pushv:
        move.w  112(%a1),%d3
        and.l   #0xffffff00,%d3
        move.w  %d3,1216(%a0)
        jmp     PUSHV_RESUME

        .align  2
rte_pusha:
        move.w  140(%a2),%d2
        and.l   #0xffffff00,%d2
        move.w  %d2,(%a0)
        move.l  %d0,%a1                           | displaced
        jmp     PUSHA_RESUME

        | The route menus' models, ModSetupView's, are two instances of one
        | template over a sound's modTarget_t[4]: SoundModConf (aftertouch,
        | 0x40033xxx) and Velocity (0x400c5xxx), the same code at different
        | addresses. Each gets the same three stubs, by rte_model:
        |   rte_get<s>    getAmount, over `lea %a3@(0,%a3:l:2),%a0; addql
        |                 #4,%sp`, re-emitted, and the read and branch after,
        |                 reimplemented: the word with its low byte cleared, as
        |                 the menu's display rounds the whole word.
        |   rte_set<s>    setAmount, over the clamped value's store and the
        |                 load after, both re-emitted: d1 the value, a0 + d0
        |                 the route; the route's low byte goes back into the
        |                 value first. d2 is the caller's.
        |   rte_setrte<s> setRoute, which writes a whole route from a copy
        |                 (amount word at a1, destination after): over the
        |                 amount's store and the lea after, re-emitted; only
        |                 the amount's high byte is stored, so the route keeps
        |                 its low byte whatever the copy came from.
        | ControlInputParam (0x40137xxx) is a third instance, over the
        | project's control inputs rather than a sound, and is left alone.
        .macro  rte_model s, get_resume, set_resume, setrte_resume
        .align  2
rte_get\s:
        lea     (0,%a3,%a3.l*2),%a0               | displaced
        addq.l  #4,%sp                            | displaced
        mvs.w   (%a0,%d0.l),%d0
        and.l   #0xffffff00,%d0
        jmp     \get_resume

        .align  2
rte_set\s:
        move.l  %d2,-(%sp)
        mvz.b   1(%a0,%d0.l),%d2
        and.l   #0xffffff00,%d1
        or.l    %d2,%d1
        move.l  (%sp)+,%d2
        move.w  %d1,(%a0,%d0.l)                   | displaced
        move.l  #SOUND_CONFIG_CHANGED,%d0         | displaced
        jmp     \set_resume

        .align  2
rte_setrte\s:
        move.b  (%a1),(%a0,%d0.l)
        lea     19(%fp),%a1                       | displaced
        jmp     \setrte_resume
        .endm

        rte_model _at, 0x40033a9e, 0x40033a26, 0x40033926
        rte_model _vel, 0x400c52c8, 0x400c5250, 0x400c5150

        .if     P_DBG
        | rte_probe(a0 = track d2's live sound): the debug build's test of the
        | routes' spare bytes not yet in use - all but velocity routes 0..2's,
        | RES, ATK and SUS: velocity route 3's and the four aftertouch routes'.
        | A sound whose five are all 0 gets the marker RTE_MARK in each; one
        | holding some markers and some zeros, or any other value, has
        | something writing them that is not ours, and sets bit d2 of
        | dbg_rte, kept; its markers are put back, so a sound saved in that
        | state flags once a session rather than hiding a new write.
        | dbg_marks counts the sounds marked: a kit saved with its markers and
        | loaded again should add none. Any engine route word for the track
        | with a low byte set means the push let one through, and sets
        | dbg_eng. Clobbers d0/d1/d3/a1.
        .equ    RTE_MARK,       0x5a
        .align  2
rte_probe:
        moveq   #0,%d3                            | markers seen
        moveq   #0,%d1                            | anything else seen
        .irp    off,OFF_RTE_VEL+9,OFF_RTE_AT,OFF_RTE_AT+3,OFF_RTE_AT+6,OFF_RTE_AT+9
        mvz.b   \off(%a0),%d0
        beq.s   2f
        cmp.l   #RTE_MARK,%d0
        bne.s   1f
        addq.l  #1,%d3
        bra.s   2f
1:      moveq   #1,%d1
2:
        .endr
        tst.l   %d1
        bne.s   2f
        tst.l   %d3
        beq.s   1f
        moveq   #5,%d0
        cmp.l   %d0,%d3
        beq.s   3f                                | all five: as left
        bra.s   2f
1:      addq.l  #1,dbg_marks
        bra.s   6f
2:      move.l  dbg_rte,%d0
        bset    %d2,%d0
        move.l  %d0,dbg_rte
6:      .irp    off,OFF_RTE_VEL+9,OFF_RTE_AT,OFF_RTE_AT+3,OFF_RTE_AT+6,OFF_RTE_AT+9
        move.b  #RTE_MARK,\off(%a0)
        .endr
3:      move.l  %d2,%d0
        lsl.l   #5,%d0
        add.l   #RTE_ENGINE+1,%d0                 | route 0's low byte
        move.l  %d0,%a1
        moveq   #7,%d0
4:      tst.b   (%a1)
        bne.s   5f
        addq.l  #4,%a1
        subq.l  #1,%d0
        bpl.s   4b
        rts
5:      moveq   #1,%d0
        move.l  %d0,dbg_eng
        rts
        .align  2
dbg_rte: .long  0                                 | per voice track, a bit
dbg_eng: .long  0
dbg_marks: .long 0
        .endif

        | ------------------------------------------------------------------
        | The filter's tables.
        |
        | flt_pole: FRQ's pole, Q31, for stock's FRQ scale, a semitone a step
        | with 440 Hz at 60: fc = 13.75 * 2^(FRQ / 12), K = tan(pi fc / 48000),
        | p = (1 - K) / (1 + K), the bilinear one-pole's, exactly -3 dB at fc
        | for LP1 and HP1 at full depth. Generated from that formula (the
        | assembler has no tan); p falls below 0 above about 12 kHz.
        |
        | flt_gain: DEP's dry share g, Q15: g = 10^(-DEP / 80), a 0.25 dB step
        | of cut each, -31.5 dB at 126; 0 at 127, FULL. 0's entry, 0 dB, is
        | never read: that DEP is off.
        | ------------------------------------------------------------------
        .balign 4
flt_pole:
        .long   2143621929, 2143392518, 2143149492, 2142892045
        .long   2142619323, 2142330422, 2142024385, 2141700197
        .long   2141356785, 2140993013, 2140607677, 2140199503
        .long   2139767142, 2139309167, 2138824066, 2138310239
        .long   2137765992, 2137189533, 2136578964, 2135932279
        .long   2135247352, 2134521936, 2133753651, 2132939981
        .long   2132078264, 2131165684, 2130199263, 2129175848
        .long   2128092111, 2126944527, 2125729373, 2124442712
        .long   2123080382, 2121637986, 2120110877, 2118494145
        .long   2116782604, 2114970777, 2113052878, 2111022802
        .long   2108874103, 2106599978, 2104193250, 2101646349
        .long   2098951293, 2096099664, 2093082593, 2089890733
        .long   2086514241, 2082942753, 2079165359, 2075170580
        .long   2070946347, 2066479969, 2061758110, 2056766767
        .long   2051491238, 2045916097, 2040025170, 2033801508
        .long   2027227356, 2020284136, 2012952413, 2005211879
        .long   1997041322, 1988418610, 1979320669, 1969723464
        .long   1959601981, 1948930218, 1937681169, 1925826819
        .long   1913338137, 1900185078, 1886336582, 1871760588
        .long   1856424037, 1840292898, 1823332181, 1805505969
        .long   1786777447, 1767108934, 1746461929, 1724797146
        .long   1702074566, 1678253478, 1653292528, 1627149764
        .long   1599782671, 1571148211, 1541202838, 1509902510
        .long   1477202673, 1443058227, 1407423455, 1370251914
        .long   1331496274, 1291108108, 1249037598, 1205233160
        .long   1159640969, 1112204356, 1062863062, 1011552314
        .long   958201696, 902733762, 845062350, 785090529
        .long   722708094, 657788503, 590185132, 519726656
        .long   446211330, 369399857, 289006403, 204687194
        .long   116025848, 22514306, -76472319, -181709410
        .long   -294168668, -415081646, -546029630, -689073759
        .long   -846948289, -1023356197, -1223436884, -1454535970
flt_gain:
        .word   32767, 31838, 30935, 30057, 29205, 28376, 27571, 26789
        .word   26029, 25290, 24573, 23875, 23198, 22540, 21900, 21279
        .word   20675, 20089, 19519, 18965, 18427, 17904, 17396, 16902
        .word   16423, 15957, 15504, 15064, 14637, 14222, 13818, 13426
        .word   13045, 12675, 12315, 11966, 11627, 11297, 10976, 10665
        .word   10362, 10068, 9783, 9505, 9235, 8973, 8719, 8471
        .word   8231, 7997, 7771, 7550, 7336, 7128, 6925, 6729
        .word   6538, 6353, 6172, 5997, 5827, 5662, 5501, 5345
        .word   5193, 5046, 4903, 4764, 4629, 4497, 4370, 4246
        .word   4125, 4008, 3894, 3784, 3677, 3572, 3471, 3372
        .word   3277, 3184, 3093, 3006, 2920, 2838, 2757, 2679
        .word   2603, 2529, 2457, 2388, 2320, 2254, 2190, 2128
        .word   2068, 2009, 1952, 1896, 1843, 1790, 1740, 1690
        .word   1642, 1596, 1550, 1506, 1464, 1422, 1382, 1343
        .word   1305, 1268, 1232, 1197, 1163, 1130, 1098, 1066
        .word   1036, 1007, 978, 950, 924, 897, 872, 0
