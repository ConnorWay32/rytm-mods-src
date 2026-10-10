        | Mod 0006 - compressor gain-reduction preview.
        |
        | One more compressor page carrying a scrolling estimate of the compressor's
        | gain reduction, in two layouts FUNC + the page key switches between: the
        | level, threshold and GR together, or GR alone with 0 dB at the top. It is
        | stock page 11, listed twice in the view's page vector rather than a new
        | page id, so stock's parameter lookup, title and encoder mapping are
        | inherited and the entries are told apart by the view's selected index at
        | +0x8c, in the draw slot.
        |
        | The estimate, twinned offline by tools/comp/stub_model.py, which reads
        | its constants from this file: the eight voices summed with the gain law
        | recovered in re/subsystems/compressor-hardware.md, a peak
        | detector with a 5 ms decay, a static curve that THR slides along the
        | level axis (static_gr), and one attack / release pole. It is an
        | estimate of GR, not a measurement: there is no readback of the analog
        | compressor's actual gain.
        |
        | The input model: each voice split by
        | its pan and dropped when off the main bus, the per-slot trims, the PRE
        | delay and reverb returns, and the master distortion, summed per side.
        | The detector takes the louder side, as the compressor does.
        |
        | Known departures from the model:
        |   - the returns are paired with the voices of the same block, about
        |     six blocks (4 ms) early. Aligning them needs about 2 KB of return
        |     history. It shows only where a sustained tone overlaps its echo.
        |   - POST returns are not modelled. DIST symmetry is, as a bias and a
        |     gain, except near SYM 0 and 127 with DIST near 0, where the
        |     hardware all but mutes (calibration.toml, [distortion]).
        |   - each SEQ setting's sidechain response is two first-order sections
        |     (sidech, in cave3), fitted to the hardware's own response swept 35
        |     Hz to 9 kHz (calibration.toml, [sidechain]): within 0.1 to 0.4 dB
        |     rms. The sample path's 24 kHz rate leaves nothing above 12 kHz.
        |     Past the filter, each SEQ is only a level offset.
        |   - the static curve is evaluated once a block against the detector, and
        |     the pole is stepped once a block with the closed form for 32 samples.
        |     That is exact while the target is steady and lags a little when it is
        |     not.
        |   - the estimate holds reduction too long into quiet passages.

        | Every calibrated constant and table: generated from calibration.toml by
        | tools/comp/calib_tables.py. Each table below is a macro from it.
        .include "mods/0006-comp-preview/calib.inc"

        .equ    RXBUF,          0x80007440  | receive buffer, voice p at +8 + 4p
        .equ    RXSTRIDE,       48

        | The per-side input model (compressor-hardware.md, "Voices: level, pan
        | and routing"). The VCA words are uint16 per PHYSICAL voice, written by
        | 0x401098d4 earlier in this same interrupt; SLOT_MAP takes a physical
        | voice to its receive slot. VOICE_OWNER takes it to the track that owns
        | it, and that track's bit in MAIN_OFF (or the global set, when MAIN_OFF
        | is negative) takes the voice off the main bus - the bits stock packs
        | the route byte at 0x80006466 from.
        .equ    VCA_L,          0x800063ca
        .equ    VCA_R,          0x800063da
        .equ    MAIN_OFF,       0x8000ed6c  | per-track main-disable bits, or
        .equ    MAIN_OFF_G,     0x8000ee58  | the global set when MAIN_OFF < 0
        .equ    VOICE_OWNER,    0x40290dd8  | physical voice -> owning track, bytes
        .equ    SLOT_MAP,       0x401ef1d0  | eight longs

        | The PRE returns. Each buffer is 32 interleaved L/R long frames,
        | written by the effects call just before the detour, so they hold this
        | block's output. The PRE gains are (2 * return level * FX track level)^2
        | in Q31, built at 0x4010e8a0; a return set to POST clears its PRE word,
        | so a POST return drops out here on its own. The consumer at 0x4010eb26
        | sends -(gain * return) >> 8 to the DAC, so the return reaches the
        | analog bus in voice-slot units only through a constant, measured with
        | MAIN carrying returns alone (calibrate.py input). The constants start
        | at the firmware's negation and the sum's 1/8 headroom.
        .equ    FX_REVERB,      0x80007b44
        .equ    FX_DELAY,       0x80007c44  | FX_REVERB + 256
        .equ    G_DELAY,        0x42fb4ab4
        .equ    G_REVERB,       0x42fb4ab8
        | The gain word follows the (2*vol*level)^2 law exactly (read back on the
        | device). CAL_DELAY and CAL_REVERB, -1/8 * 10^(dB/20), are in calib.inc
        | ([input]).

        | The master distortion, from the voice-path probe of
        | 2026-09-21, refit by calibrate.py dist. It is a gain set by DIST and
        | then an asymmetric saturation, present at DIST 0 as well, applied to
        | each side of voices plus PRE returns. DIST's amount is 0x8000fbce,
        | 8.8, which the interrupt doubles into the analog control block at
        | 0x40121306; read back on the device at 0 and 64 against CC 70.
        | Its symmetry is 0x8000fbd0, 64 at centre, and the saturation below
        | was measured at 64 only.
        |
        | disttab is the gain against DIST 0 at DIST 0, 32, 64, 96 and 128, Q12;
        | 128 extends the 96..127 slope so 127 lands on its measured 7.127. It is
        | applied as g/8 in Q31, and DIST_HEADROOM takes the 8 back out.
        |
        | The saturation after the gain: analog, y = x / (1 + |x/c|^12)^(1/12),
        | c = +0.68 / -0.72 in MAIN units at the model's calibration. Fitted on
        | the peak-detector metric through the pre-saturation tap at MIX 0, where
        | MAIN is the dry signal the compressor receives (2026-09-22): the same
        | curve at every DIST from 16 to 127 on a kick, a tonal and a hat
        | pattern, the hats about 1 dB earlier. DIST is drive
        | into it. Here c is over 90.49, in Q31, as the side sum carries it.
        | Fitted at DIST symmetry 64; away from 64, satur_sym adds a bias before
        | it and a gain after it.
        .equ    DIST,           0x8000fbce
        .equ    DIST_HEADROOM,  4624        | 18.06 dB
        | 2^38 / c, for u = ((|x| >> 9) * R) >> 17 = |x| * 4096 / c without a
        | divide: within 1.5 of the exact u (Q12) over c/4 .. 4c, where the
        | product stays under 2^32. SAT_CP, SAT_CN (c) and SAT_RP, SAT_RN are in
        | calib.inc ([distortion]).

        | The live compressor parameters, 8.8, eight words at 0x8000fbd4:
        |   +0 THR  +2 ATK  +4 REL  +6 RAT  +8 SEQ  +10 MUP  +12 MIX  +14 VOL
        |
        | Confirmed on hardware 2026-09-21 by reading the block back on the
        | device against eight distinct known values; the cal build's record
        | reads it back on every block.
        |
        | The firmware agrees. 0x8000fbd4 is passed as a pointer to 0x4010e1a0
        | beside the analog control block; that consumer reads +0 as a threshold
        | (12288 - v/2 into a DAC), +10 through an exponential as a gain, and +12
        | and +14 as two multipliers into it - MUP, MIX and VOL. It never touches
        | +2..+8, which is why the order within those four needed measuring.
        |
        | Only the first five are read here. MUP, MIX and VOL are downstream of
        | the gain computer and cannot change gain reduction: VOL is measured at
        | a 0.15 dB spread across its entire range (compressor-hardware.md). MUP
        | and MIX being outside it is modelled, not measured.
        .equ    P_THR,          0x8000fbd4
        .equ    P_ATK,          0x8000fbd6
        .equ    P_REL,          0x8000fbd8
        .equ    P_RAT,          0x8000fbda
        .equ    P_SEQ,          0x8000fbdc

        .equ    NCOLS,          128         | one column a pixel, the screen's width
        .equ    CHUNK,          32          | columns expanded per blit
        .equ    BARH,           32          | rows; one 32-bit word per column
        .equ    TRACE_X,        0
        .equ    TRACE_Y,        16
        | The trace sits in a band of the 32-row bitmap, between the two encoder
        | label rows: TRACE_ROWS rows from bit TRACE_R0.
        .equ    TRACE_R0,       2
        .equ    TRACE_ROWS,     28
        | The threshold's row, dotted, 74% of the way up: the level fill is
        | centred on it and the GR line starts from it at 0 dB and goes down.
        .equ    TRACE_THR,      7

        | The sample path - the voice sum, the saturation, the SEQ sidechain and
        | the peak detector - runs on every DECIM-th frame, 24 kHz. That halves
        | the path's interrupt time, which at full rate starved the UI on a busy
        | pattern (UI_QUEUE below), for 0.01 to 0.09 dB rms of accuracy; quarter
        | rate would fold the highs under a 6 kHz band. The per-block curve and
        | ballistics are unchanged; the sidechain rows are fitted at 24 kHz.
        .equ    DECIM,          2
        | DET_ALPHA_H, the 5 ms decay at 24 kHz, is in calib.inc ([detector]).
        | Level calibration, Q8 dB. Both parts are arithmetic:
        |   +18.06  undoes the 1/8 the sum carries for headroom.
        |   +3.01   K = sqrt(2), a voice's gL+gR as fitted on track 1. It is
        |           the same at every pan and on six slots; slots 5 and 6
        |           read 0.85 dB hot (compressor-hardware.md).
        |   -3.01   the detector reports a peak while the curve is calibrated
        |           against a sine's RMS, which is 3.01 dB below its peak.
        | Nothing here is measured: an on-device null against MAIN reads near
        | zero at MIX 0 with no trim.
        | The curve's own reference, held at zero: the knees of rattab carry it,
        | with SEQ OFF's sidechain offset, so the level at SEQ OFF is the louder
        | side in MAIN dBFS on the convention below.
        .equ    CURVE_REF,      0
        | The level is the louder side in MAIN dBFS, through VOICE_CAL and
        | DIST_HEADROOM, where the curve was fitted to an
        | L+R convention 6.02 dB above either side at centre. +3.01 is that
        | 6.02 less the 3.01 of peak against RMS above, so a hard-panned voice
        | reads 6.02 dB over a centred one. The knees are fitted on top of this
        | convention.
        .equ    CAL_Q8,         VOICE_CAL+VOICE_TRIM+DIST_HEADROOM+771+CURVE_REF

        | Below this the estimate is forced to zero. The gate is load-bearing: at
        | low THR the static curve's knee sits below the converter floor, so the
        | idle noise of the voice sum would read as reduction.
        |
        | -70 dB. The eight voice slots carry independent converter noise, which
        | the sum adds in power - 9.03 dB over one slot - so with nothing playing
        | the reconstruction reads about -79.3 dBFS. -70 clears that by 9 dB and
        | is 24 dB below the lowest level the curve is fitted at, -46 dBFS, so it
        | cannot gate anything real. SILENCE_Q8 is in calib.inc ([gate]).

        | VOICE_CAL undoes the sum's 1/8 headroom and applies K, as in CAL_Q8
        | above.
        .equ    VOICE_CAL,      5394        | 18.06 + 3.01 dB
        | Zero, and it should stay zero: if the input model needs a global trim,
        | something is wrong with the model, not with this constant.
        .equ    VOICE_TRIM,     0
        .equ    DB_FLOOR,       -24576      | a zero peak reads as -96 dB
        .equ    COLSEED,        0           | the column keeps its deepest reduction

        | The saturation is reached through a5, which picks the path without
        | DIST symmetry's bias at SYM 64 (satur_sym): a memory add and subtract a
        | sample costs 1.7% of a block even when the bias is zero. The profiling
        | build uses a5 itself, so takes the path with the bias.
        .if     P_PROF
        .equ    SYMSEL,         0
        .else
        .equ    SYMSEL,         1
        .endif
        | The calibration build (mod.toml `cal`): estimating on every block
        | whether or not the page is up, with USB channels 10 and 11 carrying
        | the model's sides on the frames the sample path uses and a tagged
        | record of the block on the others (cal_out). Which side it carries is
        | chosen at run time by MUP's integer part, which the estimator never
        | reads and which cannot matter at MIX 0, where the distortion stages
        | record: 0 the side after the saturation, anything else the side
        | before it. It owns those two channels and the path, so it excludes the
        | telemetry, profiling and noest.
        .if     P_CAL
        .if     P_TELEM
        .error  "cal and telem both write USB channel 11"
        .endif
        .if     P_PROF
        .error  "cal records the whole estimator; prof skips stages of it"
        .endif
        .if     P_NOEST
        .error  "cal records the estimator; noest switches it off"
        .endif
        .endif
        .equ    VIEW_SELPAGE,   0x8c
        .equ    VIEW_PAGEKEY,   0x88              | the view's own page key's id
        | Set on a page key's press when it is the view's own; its release cycles
        | the page only while it is set (0x4003ab08, 0x4003a834).
        .equ    CYCLE_ARMED,    0x417e32b9
        | DMA timer 0's counter, free-running; stock reads it as a time base at
        | 0x40069d6a and 0x40083496. Times the enumeration labels, and the cal
        | and telem builds' interrupt interval and run time.
        .equ    DTCN0,          0xfc07000c
        | The UI task's event queue, which the UI loop at 0x400a4684 takes one
        | event from each pass; +4 is the events waiting (0x40001444 shows the
        | layout). The estimator's interrupt time comes out of the UI task's
        | share: at about 10% of every block it let this queue run away on a
        | busy pattern - 7 events to 2089 in two minutes, keys and pattern
        | changes answered seconds late, kit loads stalled (hardware,
        | 2026-09-23, tools/comp/telemetry/pc_timing.py). So the estimator stands aside
        | for any block that finds more than QUEUE_MAX waiting. It rests at 2
        | to 4 with the estimator idle and 4 to 7 with it running on a light
        | pattern.
        |
        | That alone is not enough. Below the UI runs BgWorker (priority 2),
        | which takes the sample jobs a pattern change queues - the loading
        | icon - and only runs while the UI is idle. A valve that holds the UI
        | queue just under its limit never lets it idle: with QUEUE_MAX at 16
        | the queue sat at 17 and BgWorker's backlog grew to about 800 jobs in
        | a minute, then cleared in 4 s once the estimator stopped. So the
        | estimator also stands aside once BgWorker has had work waiting for
        | BG_WAIT blocks, a quarter of a second - long enough that its usual
        | single jobs, handled at once, never trip it. BgWorker is the
        | singleton at *0x419f2898; its job deque's start and finish cursors
        | are at +44 and +60 (its base's destructor, 0x4017f478).
        |
        | BG_WAIT alone still costs a quarter of a second each time. After a
        | pattern change the UI can settle with the queue at 6 to 9 while the
        | estimator runs, never idle, so BgWorker's periodic jobs (PeriodicTasks
        | and a Project one, each 1.6 to 1.8 s) stalled until BG_WAIT tripped:
        | half a second a job, half of it stood aside (hardware, 2026-09-28,
        | tools/comp/telemetry/bg_jobs.py). Calm, the same jobs take 0.05 to
        | 0.15 s with the queue at 5 or less. So once BgWorker has waited
        | BG_NUDGE blocks, the estimator also stands aside while the queue
        | holds QUEUE_BUSY or more, and the job finishes at its own pace. The
        | cal build keeps the earlier rules alone: its .text has no room.
        .equ    UI_QUEUE,       0x41943f54
        .equ    QUEUE_MAX,      8
        .equ    QUEUE_BUSY,     6
        .equ    BGWORKER_P,     0x419f2898
        .equ    BG_WAIT,        375
        .equ    BG_NUDGE,       30
        .equ    BITMAP_CTOR,    0x4006f9c2
        .equ    BITMAP_BLIT,    0x40071674
        .equ    PARAM_DRAW,     0x40039782
        .equ    AUDIO_RESUME,   0x401213aa

        .text

        | ------------------------------------------------------------------
        | comp_probe - the producer, detoured at 0x401213a0, just after the effects
        | call at 0x4012139a returns. That is the window where the receive buffer
        | holds this block's voices and 0x4009ef40 at 0x4012143a has not yet been
        | able to overwrite them. Six bytes of jmp displace `addql #4,%sp`,
        | `clrl %d1` and the first half of `lea 0x8000e508,%a1`; all three are
        | re-emitted before rejoining at 0x401213aa.
        |
        | Interrupt context: no allocation and no call. MACSR rests at 0x20 -
        | signed, fractional, truncating, accumulator saturation off - which is what
        | the mac.l instructions below assume, and it is left untouched.
        | ------------------------------------------------------------------
        .align  2
comp_probe:
        lea     -60(%sp),%sp
        movem.l %d0-%d7/%a0-%a6,(%sp)
        .if     P_CAL
        move.l  DTCN0,%d0
        move.l  %d0,%d1
        sub.l   cal_t0,%d1
        move.l  %d1,cal_iv                        | interrupt to interrupt
        move.l  %d0,cal_t0
        addq.l  #1,cal_blk
        clr.l   cal_ran                           | set once the level is made
        mvz.b   P_THR+10,%d0
        move.l  %d0,cal_mup                       | nonzero: the sides before the saturation
        .endif
        .if     P_TELEM
        jsr     telem_in                          | before the idle check
        .endif
        | Idle while the page is not on screen: the draw slot re-arms `seen`
        | whenever the page draws, and past about a second without a draw the
        | whole estimate is skipped. The trace and the ballistics then resume
        | from where they stopped.
        .if     P_CAL == 0
        subq.l  #1,seen
        bmi     probe_out
        .endif
        .if     P_NOEST
        bra     probe_out                         | the estimator switched off
        .endif
        move.l  UI_QUEUE+4,%d0
        moveq   #QUEUE_MAX,%d1
        cmp.l   %d1,%d0
        bgt     probe_out                         | the UI is behind: stand aside
        move.l  BGWORKER_P,%a0
        moveq   #0,%d0
        cmp.l   %d0,%a0
        beq.s   1f
        move.l  60(%a0),%d1
        cmp.l   44(%a0),%d1
        beq.s   1f                                | BgWorker has nothing waiting
        move.l  bg_wait,%d0
        addq.l  #1,%d0
1:      move.l  %d0,bg_wait
        cmp.l   #BG_WAIT,%d0
        bgt     probe_out                         | BgWorker is starved: stand aside
        .if     P_CAL == 0
        moveq   #BG_NUDGE,%d1
        cmp.l   %d1,%d0
        ble.s   2f
        move.l  UI_QUEUE+4,%d0
        moveq   #QUEUE_BUSY,%d1
        cmp.l   %d1,%d0
        bge     probe_out                         | the UI is too busy to idle: stand aside
2:
        .endif

        | Level, VOL, velocity and accent are all already in the voice slot; only
        | pan and a per-voice gain are applied after the tap. Hardware, 2026-09-20:
        | the twelve-channel USB stream is this same receive buffer, so the slots
        | were fitted against the MAIN pair offline.
        |
        | Pan keeps gL + gR = S for every pan, where S is a per-slot constant:
        | equal on six slots, 0.85 dB lower on slots 5 and 6, which read that much
        | hot (compressor-hardware.md). So a voice's contribution to L+R does not
        | depend on pan, and K = S of track 1 is folded into CAL_Q8.
        |
        | The compressor does not see L+R. It applies one gain to both sides,
        | driven by max(|L|,|R|). So the two sides are built separately, from the
        | split p = wL/(wL+wR) of the VCA words and the trim on slots 5 and 6,
        | and the louder feeds the gain computer.
        | Per-slot side coefficients, rebuilt every block because pan and routing
        | can change at any time. For physical voice p in slot s:
        |   f      = wL / (wL + wR), Q15
        |   cL[s]  = f * trim[s]            } Q28, which is 1/8 in Q31: the
        |   cR[s]  = trim[s] - cL[s]        } eight-voice sum's headroom
        | and both zero when the voice is off the main bus or both words are zero.
        | The words lead the audio by four ticks, so a p-locked pan change is
        | briefly early.
        |
        | Whether a voice is on the main bus comes from its owning track's
        | main-disable bit, the source stock packs the route byte at 0x80006466
        | from, not from that byte: with 0013's DAC SUM on the byte takes every
        | voice off the analog bus while the voices still reach MAIN, through
        | the DAC. Without 0013, or with DAC SUM off, the two agree.
        lea     coef,%a4
        lea     SLOT_MAP,%a3
        lea     VCA_L,%a1
        lea     VOICE_OWNER,%a0
        move.l  MAIN_OFF,%d4
        bge.s   19f
        move.l  MAIN_OFF_G,%d4
19:     lea     trimtab,%a2
        moveq   #0,%d5                            | physical voice
20:     move.l  (%a3)+,%d3
        lsl.l   #3,%d3                            | slot * 8, one (cL, cR) pair
        moveq   #0,%d0
        moveq   #0,%d1
        mvz.b   (%a0,%d5.l),%d2                   | owning track
        btst    %d2,%d4
        bne.s   22f                               | off the main bus
        mvz.w   (%a1),%d0                         | wL
        mvz.w   VCA_R-VCA_L(%a1),%d1              | wR
        add.l   %d0,%d1
        beq.s   22f                               | both zero, and so is d0
        moveq   #15,%d2
        lsl.l   %d2,%d0
        divu.l  %d1,%d0                           | f, Q15
        move.l  %d3,%d1
        lsr.l   #2,%d1                            | slot * 2
        mvz.w   (%a2,%d1.l),%d1                   | trim, Q15
        mulu.l  %d1,%d0
        lsr.l   %d2,%d0                           | f * trim, Q15
        sub.l   %d0,%d1                           | trim - f * trim
        moveq   #13,%d2
        lsl.l   %d2,%d0
        lsl.l   %d2,%d1
22:     move.l  %d0,(%a4,%d3.l)
        move.l  %d1,4(%a4,%d3.l)
        addq.l  #2,%a1
        addq.l  #1,%d5
        moveq   #8,%d0
        cmp.l   %d0,%d5
        blt.s   20b

        | The block: two sums per sample, L in acc0 and R in acc1. The PRE
        | returns join the sums from this same block; they lead the voices by
        | about six blocks (compressor-hardware.md), which is accepted.
        | The voice loop is unrolled so the two return gains can stay in
        | registers.
        .macro  track p
        tst.l   %d0
        bpl.s   6f
        neg.l   %d0
6:      sub.l   \p,%d0
        bmi.s   7f
        add.l   %d0,\p                            | rising: straight to the new peak
        bra.s   8f
7:      mac.l   %d0,%d6,%acc0                     | falling: decay towards it
        movclr.l %acc0,%d0
        add.l   %d0,\p
8:
        .endm

        | The distortion on one side's sum in d0: the gain, then the analog
        | saturation (satur, in cave6). The manual's path puts the distortion in
        | front of the compressor, so the estimate saturates before its detector.
        | In the cal build the side after the gain and before the saturation goes
        | to the AUDIO IN word at \cal, times 8 - DIST 127 would wrap at 64; with
        | MUP at 0 the sidechain's entry then overwrites it with the side after
        | the saturation (calw). Clobbers d1.
        | The profiling build (prof = 1): each set bit of MUP's integer part
        | skips one stage, so the telemetry's run time can be read per stage
        | over MIDI in one session - MUP, which the estimator never reads.
        | Clobbers d1.
        .macro  pskip bit, to, near=0
        .if     P_PROF
        move.l  %a5,%d1
        btst    #\bit,%d1
        .if     \near
        bne.s   \to
        .else
        bne     \to
        .endif
        .endif
        .endm

        .macro  shape cal=0
        mac.l   %d0,%a1,%acc0
        movclr.l %acc0,%d0
        .if     P_CAL
        .if     \cal
        move.l  %d0,%d1
        asl.l   #3,%d1                            | x8
        move.l  %d1,\cal(%a0)
        .endif
        .endif
        pskip   1, 61f, 1
        .if     SYMSEL
        jsr     (%a5)                             | satur, or satur_sym away from SYM 64
        .else
        add.l   sym_b,%d0                         | DIST symmetry's bias
        jsr     satur
        sub.l   sym_sb,%d0
        .endif
61:
        .endm

        jsr     sc_block                          | a6 = this SEQ's sctab row

        | DIST symmetry (0x8000fbd0, 8.8, 64 centred) as a bias before the
        | saturation and a gain after it: y = gain * (sat(x + bias) - sat(bias)),
        | from calibration.toml's [distortion] sym_bias and sym_gain_db, SYM 0, 8
        | .. 128. The gain only scales what the detector sees, so it is a level
        | offset here rather than a multiply a sample. At SYM 64 both are zero
        | and the path is the one without symmetry, sample for sample.
        mvz.w   DIST+2,%d0
        lea     symbias,%a1
        moveq   #11,%d1                           | spans of 8 in 8.8
        bsr     interp                            | bias, Q12 MAIN units
        move.l  #SYM_K,%d1
        muls.l  %d1,%d0                           | side units, Q31
        move.l  %d0,sym_b
        jsr     satur
        move.l  %d0,sym_sb
        mvz.w   DIST+2,%d0
        lea     symgain,%a1
        moveq   #11,%d1
        bsr     interp
        move.l  %d0,sym_g                         | Q8 dB

        lea     DIST,%a1
        mvz.w   (%a1),%d0
        lea     disttab,%a1
        moveq   #13,%d1                           | spans of 32 in 8.8
        bsr     interp                            | g, Q12
        swap    %d0
        clr.w   %d0                               | g/8, Q31
        move.l  %d0,%d4                           | parked until the peaks load
        move.l  G_DELAY,%d0
        move.l  #CAL_DELAY,%d1
        mac.l   %d0,%d1,%acc0
        movclr.l %acc0,%d5                        | delay gain
        move.l  G_REVERB,%d0
        move.l  #CAL_REVERB,%d1
        mac.l   %d0,%d1,%acc0
        movclr.l %acc0,%d0
        move.l  %d0,%a4                           | reverb gain
        lea     FX_REVERB,%a3
        lea     RXBUF+8,%a0
        | One detector on max(|L|,|R|) after each side's sidechain,
        | which is what the compressor does (compressor-hardware.md): one gain for
        | both sides, driven by the louder.
        move.l  peak,%d7
        move.l  %d4,%a1                           | DIST gain, g/8
        moveq   #32/DECIM-1,%d4
        move.l  #DET_ALPHA_H,%d6
        .if     SYMSEL
        | The saturation, through a5: satur itself at SYM 64, where the bias is
        | zero, so the loop costs what it did without symmetry, and satur_sym
        | with the bias away from it.
        lea     satur,%a5
        tst.l   sym_b
        beq.s   1f
        lea     satur_sym,%a5
1:
        .endif
        .if     P_PROF
        mvz.b   P_THR+10,%d1                      | MUP, the stage selector
        move.l  %d1,%a5
        .endif
23:
        pskip   0, 60f
        | Each voice's (cL, cR) loads during the multiply before it (EMAC
        | multiply with load), through a2, which the sidechain then takes over
        | for its state; the last load reads the word past the table, unused.
        lea     coef,%a2
        move.l  (%a2)+,%d1                        | cL, voice 0
        .irp    i,0,1,2,3,4,5,6,7
        move.l  4*\i(%a0),%d0
        mac.l   %d0,%d1,(%a2)+,%d1,%acc0          | L; d1 = cR
        mac.l   %d0,%d1,(%a2)+,%d1,%acc1          | R; d1 = the next cL
        .endr
60:
        move.l  (%a3),%d0                         | reverb
        mac.l   %d0,%a4,%acc0
        move.l  4(%a3),%d0
        mac.l   %d0,%a4,%acc1
        move.l  FX_DELAY-FX_REVERB(%a3),%d0       | delay
        mac.l   %d0,%d5,%acc0
        move.l  FX_DELAY-FX_REVERB+4(%a3),%d0
        mac.l   %d0,%d5,%acc1
        lea     8*DECIM(%a3),%a3
        movclr.l %acc0,%d0
        shape   cal=32
        pskip   2, 62f, 1
        jsr     sidech_l
        .if     P_PROF
        bra.s   63f
62:     tst.l   %d0
        bpl.s   63f
        neg.l   %d0
63:
        .endif
        move.l  %d0,%d3                           | |L|
        movclr.l %acc1,%d0
        shape   cal=36
        pskip   2, 62f, 1
        jsr     sidech                            | a2 follows on to R's state
        .if     P_PROF
        bra.s   63f
62:     tst.l   %d0
        bpl.s   63f
        neg.l   %d0
63:
        .endif
        cmp.l   %d3,%d0
        bcc.s   24f
        move.l  %d3,%d0                           | the louder side
24:     pskip   3, 64f, 1
        track   %d7
64:
        lea     DECIM*RXSTRIDE(%a0),%a0
        subq.l  #1,%d4
        bpl     23b
        move.l  %d7,peak
        pskip   4, probe_out

        | Level in Q8 dB, through to_db below.
        move.l  %d7,%d0
        bsr     to_db
        add.l   #CAL_Q8,%d3
        add.l   sc_off,%d3                        | the sidechain's own gain
        add.l   sym_g,%d3                         | DIST symmetry's gain
        jsr     lvl_track                         | the column's loudest level
        .if     P_CAL
        move.l  %d3,cal_lvl
        addq.l  #1,cal_ran
        .endif

        | Below the floor there is no signal, so there is no reduction. The static
        | curve cannot answer this itself: at low THR its knee sits below the
        | converter floor, and the idle noise would read as reduction.
        | No ceiling on the level: a hot drum mix goes past 0 dB after the
        | sidechain's lift, and a ceiling there would cap the demand at whatever
        | THR gives at 0 dB. static_gr's products stay inside 32 bits past +30 dB.
11:     cmp.l   #SILENCE_Q8,%d3
        ble.s   14f
        bsr     static_gr                         | d3 = level -> d0 = GR, Q8
        bra.s   15f
14:     moveq   #0,%d0
15:

        | One attack/release pole, its coefficient the 32-sample closed form, so one
        | step a block is exact while the target holds. The demand is first
        | scaled by atkscale, per ATK, REL and RAT: a slow attack settles at less
        | reduction as well as later. Then less seqatk, per SEQ and ATK: the HPF
        | and HIT sidechains are more transient, so a slow attack loses more there.
        lea     P_ATK,%a1
        mvz.w   (%a1),%d1
        lsr.l   #8,%d1                            | atk 0..6
        lea     P_RAT,%a1
        mvz.w   (%a1),%d2
        lsr.l   #8,%d2                            | rat 0..3
        move.l  %d1,%d3
        lsl.l   #3,%d3                            | atk * 8
        lea     P_REL,%a1
        mvz.w   (%a1),%d4
        lsr.l   #8,%d4
        add.l   %d4,%d3                           | + rel
        lsl.l   #2,%d3                            | * 4
        add.l   %d2,%d3                           | + rat
        lea     atkscale,%a1
        mvz.b   (%a1,%d3.l),%d2
        addq.l  #1,%d2
        muls.l  %d2,%d0
        asr.l   #8,%d0                            | demand * the slow-attack scale
        jsr     seqatk_loss                       | less the SEQ's, in .sc
        .if     P_CAL
        move.l  %d0,cal_dem
        .endif

        | Attack and release are different rules, not one pole with two
        | coefficients. Rising is a pole towards the demand as before. Falling
        | decays towards ZERO gain reduction and is clamped so it never drops
        | below the current demand, developed against level steps whose release
        | recovers much faster than one pole can. reltab is the decay
        | coefficient, the step rounded up so the state reaches zero.
        move.l  grstate,%d2
        cmp.l   %d2,%d0
        ble.s   14f
        lea     atktab,%a1                        | rising: a pole to the demand
        add.l   %d1,%d1
        move.w  (%a1,%d1.l),%d1
        mvz.w   %d1,%d1                           | alpha, Q16
        sub.l   %d2,%d0                           | target - state
        muls.l  %d1,%d0
        asr.l   #8,%d0
        asr.l   #8,%d0
        add.l   %d0,%d2
        bra.s   15f
14:     lea     reltab,%a1                        | falling: towards zero
        lea     P_REL,%a2
        mvz.w   (%a2),%d1
        lsr.l   #8,%d1                            | rel 0..7
        add.l   %d1,%d1
        move.w  (%a1,%d1.l),%d1
        mvz.w   %d1,%d1                           | alpha, Q16
        move.l  %d2,%d3
        muls.l  %d1,%d3
        add.l   #0xffff,%d3                       | rounded up, so the state
        asr.l   #8,%d3                            | reaches zero rather than
        asr.l   #8,%d3                            | stalling where state * alpha < 1
        sub.l   %d3,%d2
        cmp.l   %d0,%d2
        bge.s   15f
        move.l  %d0,%d2                           | never below the demand
15:     move.l  %d2,grstate

        | Peak GR within the column, so a brief reduction is not stepped over.
        move.l  colmax,%d0
        cmp.l   %d0,%d2
        ble.s   16f
        move.l  %d2,colmax
16:
        | The time axis: one column every hrestab[hres] blocks.
        move.l  phase,%d0
        addq.l  #1,%d0
        lea     hres,%a1                          | FUNC + LEFT / RIGHT
        mvz.b   (%a1),%d1
        lea     hrestab,%a1
        mvz.b   (%a1,%d1.l),%d1
        cmp.l   %d1,%d0
        blt     19f
        moveq   #0,%d0
        move.l  colmax,%d1
        clr.l   colmax
        | Quarter dB, to 63.75: rows are taken at draw time, so a change of
        | scale (FUNC + UP / DOWN) redraws the whole history at the new scale.
        | A byte a column caps what is stored; deeper reduction draws at 63.75.
        lsr.l   #6,%d1
        move.l  #255,%d2
        cmp.l   %d2,%d1
        ble.s   17f
        move.l  %d2,%d1
17:     lea     trace_idx,%a1
        move.l  (%a1),%d2
        lea     trace_ring,%a2
        move.b  %d1,(%a2,%d2.l)
        jsr     lvl_close                         | the level ring, same column
        addq.l  #1,%d2
        move.l  #NCOLS,%d1
        cmp.l   %d1,%d2
        blt.s   18f
        clr.l   %d2
18:     move.l  %d2,(%a1)
19:     move.l  %d0,phase

probe_out:
        .if     P_TELEM
        jsr     telem_out
        .endif
        .if     P_CAL
        jsr     cal_out
        .endif
        movem.l (%sp),%d0-%d7/%a0-%a6
        lea     60(%sp),%sp
        addq.l  #4,%sp                            | displaced
        clr.l   %d1                               | displaced
        lea     0x8000e508,%a1                    | displaced
        jmp     AUDIO_RESUME

        | ------------------------------------------------------------------
        | static_gr(d3 = level, Q8 dB) -> d0 = gain reduction, Q8 dB
        |
        | The device's threshold slides one curve per ratio along the level axis:
        |     GR = min(slope * width * softplus((level - k*(thr-64) - knee) / width), cap)
        | Every point of a steady-tone grid falls on it against level - k*thr to
        | about 0.3 dB, with one k for every ratio. SEQ enters only as a level
        | offset, which the sctab rows carry. The reciprocal of the width is
        | tabulated so the run time carries no division: u * 256 / width becomes a
        | multiply by 2^22 / width. Clobbers d1/d2/d4/d5/a0/a1.
        |
        | Fitted by tools/comp/fit_shift.py; the integer steps are within 0.03 dB
        | of its float fit. THR_K and GR_CAP are in calib.inc ([curve]).
        | ------------------------------------------------------------------

        .if     SYMSEL
        | satur_sym(d0) -> d0: the saturation with DIST symmetry's bias, sat(x +
        | bias) - sat(bias), for the blocks where SYM is away from 64. As satur,
        | it keeps everything but d0 and d1.
        .align  2
satur_sym:
        add.l   sym_b,%d0
        jsr     satur
        sub.l   sym_sb,%d0
        rts
        .endif

        | thr_point() -> d0 = the threshold, knee + k*(thr-64), Q8 dB on the level's
        | scale, and a0 = the ratio's rattab row. The page draws the same point
        | on its threshold row, TRACE_THR. Clobbers d1/a1.
        .align  2
thr_point:
        lea     P_RAT,%a0
        mvz.w   (%a0),%d1
        lsr.l   #8,%d1                            | rat 0..3
        lsl.l   #3,%d1
        lea     rattab,%a0
        lea     (%a0,%d1.l),%a0                   | knee, width, recip, slope
        lea     P_THR,%a1
        mvz.w   (%a1),%d0
        lsr.l   #8,%d0                            | thr 0..127
        moveq   #64,%d1
        sub.l   %d1,%d0                           | about the middle, so the
        muls.w  #THR_K,%d0                        | knees sit mid-word
        asr.l   #4,%d0                            | k * (thr - 64), Q8
        move.w  (%a0),%d1
        ext.l   %d1
        add.l   %d1,%d0                           | + knee
        rts

        .align  2
static_gr:
        bsr.s   thr_point
        move.l  %d3,%d4
        sub.l   %d0,%d4                           | u = level - k*thr - knee, Q8
        mvz.w   4(%a0),%d0                        | 2^22 / width
        muls.l  %d4,%d0
        asr.l   #7,%d0
        asr.l   #7,%d0                            | u / width, Q8

        bsr     softplus
        mvz.w   2(%a0),%d4                        | width, Q8
        muls.l  %d4,%d0
        asr.l   #8,%d0                            | width * softplus, Q8
        mvz.w   6(%a0),%d4                        | slope, Q12
        muls.l  %d4,%d0
        asr.l   #8,%d0
        asr.l   #4,%d0                            | GR, Q8, never below 0

        | The device's reduction stops growing at about 36 dB.
        cmp.l   #GR_CAP,%d0
        ble.s   1f
        move.l  #GR_CAP,%d0
1:      rts

        | ------------------------------------------------------------------
        | softplus(d0 = x, Q8) -> d0 = log(1+exp(x)) * 256, Q8
        |
        | Three linear spans over |x|, from the nine-entry Q12 table; beyond 8 dB
        | the correction is below half a Q8 step and max(x,0) is exact.
        | Clobbers d1/d2/d5/a1.
        | ------------------------------------------------------------------
        .align  2
softplus:
        move.l  %d0,%d5                           | keep x
        tst.l   %d0
        bpl.s   1f
        neg.l   %d0
1:      cmp.l   #2048,%d0
        blt.s   2f
        tst.l   %d5                               | saturated: max(x,0)
        bpl.s   3f
        moveq   #0,%d5
        bra.s   3f
2:      lea     softtab,%a1
        moveq   #8,%d1                            | uniform spans of 256
        bsr     interp                            | d0 = correction, Q12
        addq.l  #8,%d0
        asr.l   #4,%d0                            | -> Q8
        tst.l   %d5
        bpl.s   4f
        moveq   #0,%d5
4:      add.l   %d0,%d5
3:      move.l  %d5,%d0
        rts


        | ------------------------------------------------------------------
        | to_db(d0 = peak, a Q31 magnitude) -> d3 = level, Q8 dB, uncalibrated.
        |
        | Normalise to [0.5,1), interpolate log2(1+f) from the nine-entry table,
        | then 20*log10 as 6.0206 dB per octave: 6.0206*256 is 1541 in Q8.
        | Clobbers d0/d1/d2/d5/a1; d4 survives.
        | ------------------------------------------------------------------
        .align  2
to_db:
        tst.l   %d0
        beq.s   9f
        moveq   #0,%d5                            | the exponent
        move.l  #0x40000000,%d2
5:      cmp.l   %d2,%d0
        bcc.s   6f
        add.l   %d0,%d0
        addq.l  #1,%d5
        bra.s   5b
6:      sub.l   %d2,%d0
        lsr.l   #8,%d0
        lsr.l   #6,%d0                            | f, Q16
        lea     log2tab,%a1
        moveq   #13,%d1                           | uniform spans of 8192
        jbsr    interp                            | d0 = log2(1+f), Q12
        addq.l  #1,%d5
        lsl.l   #8,%d5
        lsl.l   #4,%d5
        sub.l   %d5,%d0                           | log2 of the peak, Q12
        move.l  #1541,%d1
        muls.l  %d1,%d0
        asr.l   #8,%d0
        asr.l   #4,%d0
        move.l  %d0,%d3
        rts
9:      move.l  #DB_FLOOR,%d3
        rts


        | Per-slot trim on the side coefficients, Q15. Slots 5 and 6 read 0.85 dB
        | hot against MAIN and the other six agree to within 0.05 dB
        | (compressor-hardware.md, per-voice S).
        .align  2
trimtab:
        cal_trimtab
disttab:
        cal_disttab
        | DIST symmetry's tables sit in cave3 beside the sidechain's: .text is
        | full in the profiling build.
        .pushsection .sc,"awx"
        .align  2
symbias:
        cal_symbias
symgain:
        cal_symgain
        .popsection

        | ------------------------------------------------------------------
        | interp(a1 = nine-entry Q12 table, d0 = x, d1 = log2 of the span) -> d0
        |
        | Both the softplus correction and log2(1+f) are nine points over eight
        | uniform spans, so they share this. A uniform softplus costs 0.031 dB
        | against the three-span form's 0.012 - both far under the one dB a row of
        | the trace is worth. Clobbers d1/d2/d3.
        | ------------------------------------------------------------------
        .align  2
interp:
        move.l  %d0,%d2
        lsr.l   %d1,%d2                           | span index
        move.l  %d2,%d3
        lsl.l   %d1,%d3
        sub.l   %d3,%d0                           | offset within the span
        add.l   %d2,%d2
        move.w  (%a1,%d2.l),%d3
        ext.l   %d3
        move.w  2(%a1,%d2.l),%d2
        ext.l   %d2
        sub.l   %d3,%d2
        muls.l  %d2,%d0
        asr.l   %d1,%d0
        add.l   %d3,%d0
        rts

        | ------------------------------------------------------------------
        | comp_draw - the compressor vtable's draw slot, +0x10. 4(%sp) is the view
        | and 8(%sp) the canvas, as the stock renderer's own blit at 0x400397c8
        | shows. Page index 0 falls through to stock; 1 is the preview, drawn as the
        | full page, or with grmode set as the GR page, which is the same trace
        | without the level fill and the threshold, its 0 dB on the band's top row.
        |
        | The ring holds one row count per column, so a chunk is expanded into a
        | stack buffer of CHUNK words and blitted. Expanding by logical column index
        | absorbs the ring wrap, so the chunks are simply drawn left to right.
        | ------------------------------------------------------------------
        .align  2
        | A ring entry in d0 to its row. The ring stores quarter dB; one
        | row per 2^vres quarter dB here, down from gr_row0 - the threshold's row
        | on the full page, the top of the band on the GR page - clamped to the
        | band. Clobbers d1.
        .macro  rowof
        mvz.b   vres,%d1
        lsr.l   %d1,%d0
        add.l   gr_row0,%d0                       | 0 dB of GR
        moveq   #TRACE_ROWS-1,%d1
        cmp.l   %d1,%d0
        ble.s   8f
        move.l  %d1,%d0
8:
        .endm

comp_draw:
        .if     P_TELEM
        addq.l  #1,tm_draws                       | either compressor page
        .endif
        move.l  4(%sp),%a0
        move.l  VIEW_SELPAGE(%a0),%d0
        bne.s   1f
        jmp     PARAM_DRAW

1:
        moveq   #TRACE_THR,%d1
        tst.b   grmode
        beq.s   2f
        moveq   #0,%d1                            | the GR page
2:      move.l  %d1,gr_row0
        moveq   #47,%d0
        lsl.l   #5,%d0                            | 1504 blocks, about 1 s
        move.l  %d0,seen
        lea     -32(%sp),%sp
        movem.l %d2-%d7/%a2-%a3,(%sp)
        move.l  40(%sp),%a2                       | the canvas
        move.l  %a2,-(%sp)
        move.l  40(%sp),-(%sp)                    | the view, past the push
        bsr     draw_labels
        addq.l  #8,%sp
        bsr     thr_point
        move.l  %d0,thr_mid                       | the level fill's threshold row
        lea     trace_idx,%a0
        move.l  (%a0),%d4                         | oldest column
        moveq   #0,%d5                            | chunk origin
        lea     trace_ring,%a0
        mvz.b   (%a0,%d4.l),%d0
        rowof
        move.l  %d0,%d6                           | the previous column's row

2:      lea     -CHUNK*4(%sp),%sp
        move.l  %sp,%a3
        moveq   #CHUNK-1,%d2
        move.l  %d4,%d3
        add.l   %d5,%d3
3:      move.l  #NCOLS,%d1
        cmp.l   %d1,%d3
        blt.s   4f
        sub.l   %d1,%d3
4:      lea     trace_ring,%a0
        mvz.b   (%a0,%d3.l),%d0
        rowof
        | A vertical segment a column, from the previous column's row to this
        | one's, so the trace reads as a line. No reduction sits on the
        | threshold's row and the line dips below it as GR bites. One column a
        | pixel, 128 of them: the screen's own resolution. Bit 0 of the column word is the TOP row
        | (hardware, 2026-09-20), so the band's row v is bit TRACE_R0 + v, and
        | the segment from lo to hi is ((2 << hi) - 1) ^ ((1 << lo) - 1). The
        | previous column's own row is left out when the value moves, so a slope
        | stays one pixel thick: the segment runs from one row past the previous
        | value to this one, inclusive.
        move.l  %d6,%d1                           | previous
        move.l  %d0,%d6                           | becomes this one
        cmp.l   %d1,%d0
        beq.s   6f                                | flat: lo = hi = this row
        blt.s   5f
        addq.l  #1,%d1                            | rising: previous + 1 .. this
        move.l  %d0,%d7
        move.l  %d1,%d0
        move.l  %d7,%d1                           | d0 = lo, d1 = hi
        bra.s   6f
5:      subq.l  #1,%d1                            | falling: this .. previous - 1
6:      .if     TRACE_R0
        addq.l  #TRACE_R0,%d0
        addq.l  #TRACE_R0,%d1
        .endif
        moveq   #2,%d7
        lsl.l   %d1,%d7
        subq.l  #1,%d7
        moveq   #1,%d1
        lsl.l   %d0,%d1
        subq.l  #1,%d1
        eor.l   %d1,%d7
        tst.l   gr_row0
        beq.s   7f                                | the GR page: the line alone
        lea     lvl_ring,%a0
        mvz.w   (%a0,%d3.l*2),%d0
        jsr     lvl_fill                          | the level, XOR'd under the line
        eor.l   %d0,%d7
        | The threshold, dotted on even screen columns: d5 is a multiple of
        | CHUNK and the column is d5 + CHUNK-1 - d2, so the dots hold still
        | while the trace scrolls. XOR'd, so a dot shows inside the fill too.
        btst    #0,%d2
        beq.s   7f
        bchg    #TRACE_R0+TRACE_THR,%d7
7:
        move.l  %d7,(%a3)+
        addq.l  #1,%d3
        subq.l  #1,%d2
        bpl.s   3b

        move.l  %d5,%d0
        add.l   #TRACE_X,%d0
        move.l  %sp,%a0
        bsr     draw_seg
        lea     CHUNK*4(%sp),%sp

        add.l   #CHUNK,%d5
        move.l  #NCOLS,%d0
        cmp.l   %d0,%d5
        blt     2b

        movem.l (%sp),%d2-%d7/%a2-%a3
        lea     32(%sp),%sp
        rts

        | ------------------------------------------------------------------
        | draw_seg(a0 = CHUNK columns, d0 = x) with a2 = the canvas.
        |
        | One 32-bit big-endian word per column, MSB the top row, which is the
        | format the expansion above writes. Pixels serve as their own mask, so
        | only the bar is drawn.
        | ------------------------------------------------------------------
        .align  2
draw_seg:
        move.l  %d0,%d3
        lea     -28(%sp),%sp
        move.l  %sp,%a1
        move.l  %a0,-(%sp)                        | mask
        move.l  %a0,-(%sp)                        | pixels
        pea     BARH
        pea     CHUNK
        move.l  %a1,-(%sp)
        jsr     BITMAP_CTOR
        lea     20(%sp),%sp
        clr.l   -(%sp)                            | centre = 0
        pea     TRACE_Y
        move.l  %d3,-(%sp)
        move.l  %a1,-(%sp)
        move.l  %a2,-(%sp)
        jsr     BITMAP_BLIT
        lea     20(%sp),%sp
        lea     28(%sp),%sp
        rts

        | ------------------------------------------------------------------
        | comp_keys - the compressor vtable's key slot, +0x08. On the preview
        | page, FUNC + an arrow sets the trace's scale and FUNC + the page key
        | switches the layout; everything else, and the stock page, goes to the
        | stock handler at 0x4003a544.
        |
        | The event's code is at +12 (0x40 LEFT, 0x41 RIGHT, 0x42 UP, 0x43 DOWN,
        | as the list handler at 0x400d5986 steps on UP and DOWN; the page keys
        | 0x30..0x35) and the word at +16 its state: bit 0 down, bit 3 a long
        | hold. is_key_held(0x80) is FUNC. The page key's press is taken whole; clearing CYCLE_ARMED leaves
        | its release, which goes to stock, doing nothing.
        |   LEFT / RIGHT  slower / faster scrolling, through hrestab
        |   UP / DOWN     more / less on screen: 2^vres quarter dB a row, 0.25
        |                 to 4 dB, so 7 dB over the band at the finest. The
        |                 GR ring caps what it holds at 63.75 dB; both scale
        |                 about the threshold's row, TRACE_THR
        | ------------------------------------------------------------------
        .equ    STOCK_KEYS,     0x4003a544
        .equ    IS_KEY_HELD,    0x40081bbc
        .equ    HRES_MAX,       5
        .equ    VRES_MAX,       4
        .align  2
comp_keys:
        move.l  4(%sp),%a0
        tst.l   VIEW_SELPAGE(%a0)
        beq.s   9f
        move.l  8(%sp),%a1
        btst    #0,19(%a1)
        beq.s   9f                                | not a press
        move.l  12(%a1),%d0
        cmp.l   VIEW_PAGEKEY(%a0),%d0
        bne.s   4f
        moveq   #4,%d0                            | the page key, after the arrows
        bra.s   5f
4:      sub.l   #0x40,%d0
        moveq   #3,%d1
        cmp.l   %d1,%d0
        bhi.s   9f                                | not an arrow
5:      move.l  %d0,-(%sp)
        pea     0x80
        jsr     IS_KEY_HELD
        addq.l  #4,%sp
        move.l  (%sp)+,%d1                        | 0 LEFT, 1 RIGHT, 2 UP, 3 DOWN, 4 page
        tst.l   %d0
        beq.s   9f                                | FUNC is not held
        | Only the scratch registers from here: d0, d1, a0, a1.
        moveq   #4,%d0
        cmp.l   %d0,%d1
        bne.s   6f
        move.l  8(%sp),%a1
        moveq   #8,%d0
        and.l   16(%a1),%d0
        bne.s   8f                                | a long hold: taken, no switch
        lea     grmode,%a0
        bchg    #0,(%a0)
        clr.b   CYCLE_ARMED
        bra.s   8f
9:      jmp     STOCK_KEYS
6:      lea     hres,%a0
        move.w  #HRES_MAX,%a1
        cmp.l   #2,%d1
        bcs.s   1f
        lea     vres,%a0
        move.w  #VRES_MAX,%a1
        subq.l  #2,%d1                            | 0 UP, 1 DOWN
        bchg    #0,%d1                            | UP adds, as RIGHT does
1:      mvz.b   (%a0),%d0
        tst.l   %d1
        bne.s   2f
        tst.l   %d0
        beq.s   3f
        subq.l  #1,%d0
        bra.s   3f
2:      cmp.l   %a1,%d0
        bcc.s   3f
        addq.l  #1,%d0
3:      move.b  %d0,(%a0)
8:      moveq   #1,%d0                            | handled
        rts

        | ------------------------------------------------------------------
        | comp_setsel - the compressor vtable's set-sub-page slot, +0x60. The FX
        | page code at 0x400cbcd4 shows the view and then, when the page shown
        | before it was a different one, sets its sub-page to 0 - so coming back
        | drew the preview for a frame and then dropped to the stock page. A
        | request for 0 is taken as a request for the current sub-page; stock's
        | setter still runs, with its redraw.
        | ------------------------------------------------------------------
        .equ    STOCK_SETSEL,   0x4003762e
        .align  2
comp_setsel:
        tst.l   8(%sp)
        bne.s   1f
        move.l  4(%sp),%a0                        | the view
        move.l  VIEW_SELPAGE(%a0),8(%sp)
1:      jmp     STOCK_SETSEL
        .align  2


        | ------------------------------------------------------------------
        | satur(d0 = a side after the DIST gain, Q31) -> d0 saturated.
        |
        | y = c * f(|x| / c) with the sign of x, f(u) = u / (1 + u^12)^(1/12),
        | c = SAT_CP or SAT_CN by sign. Below c/2 it returns x unchanged, within
        | 0.0002 dB of the curve there. On the SYM-64 drum captures at DIST 64
        | and 96, 52 to 61% of samples take that path. Above, u =
        | |x| * 4096 / c in Q12 by a multiply (SAT_RP, SAT_RN), 4 and past it
        | taken as 4 without one, and f from a 33-point Q14 table at
        | u = 0, 0.125 .. 4 - past 4 f is 1 to 1e-8. The knee is sharp, hence
        | the eighth steps: quarter steps were 0.13 dB out near u = 1. Called once per
        | side per sample from the audio interrupt, so it preserves everything
        | but d0 and d1. In cave6: cave4 is full.
        | ------------------------------------------------------------------
        .section .sat,"ax"
        .align  2
satur:
        | Most samples are below c/2 and leave unchanged, so that test comes
        | before anything is saved: unsigned |x| < c/2, c by sign.
        move.l  %d0,%d1
        bpl.s   3f
        neg.l   %d1
        cmp.l   #SAT_CN>>1,%d1
        bcs.s   4f
        bra.s   5f
3:      cmp.l   #SAT_CP>>1,%d1
        bcc.s   5f
4:      rts
5:      lea     -16(%sp),%sp
        movem.l %d2-%d4/%a2,(%sp)
        move.l  #SAT_CP,%d4
        move.l  #SAT_RP,%d2
        moveq   #0,%d3
        tst.l   %d0
        bpl.s   1f
        neg.l   %d0
        move.l  #SAT_CN,%d4
        move.l  #SAT_RN,%d2
        moveq   #1,%d3
1:      move.l  %d4,%d1
        lsl.l   #2,%d1
        cmp.l   %d1,%d0
        bcs.s   6f
        move.l  #16383,%d0                        | 4c and past: the table's end
        bra.s   2f
6:      moveq   #9,%d1
        lsr.l   %d1,%d0
        mulu.l  %d2,%d0
        moveq   #17,%d1
        lsr.l   %d1,%d0                           | u, Q12
        cmp.l   #16383,%d0
        bls.s   2f
        move.l  #16383,%d0
2:      move.l  %d0,%d1
        moveq   #9,%d2
        lsr.l   %d2,%d1
        add.l   %d1,%d1                           | the table entry, bytes
        and.l   #511,%d0                          | the fraction, over 512
        lea     sattab(%pc),%a2
        mvz.w   (%a2,%d1.l),%d2
        mvz.w   2(%a2,%d1.l),%d1
        sub.l   %d2,%d1
        muls.l  %d0,%d1
        asr.l   #8,%d1
        asr.l   #1,%d1
        add.l   %d2,%d1                           | f, Q14
        move.l  %d4,%d0
        lsr.l   #8,%d0
        mulu.l  %d1,%d0
        lsr.l   #6,%d0                            | c * f
8:      tst.l   %d3
        beq.s   9f
        neg.l   %d0
9:      movem.l (%sp),%d2-%d4/%a2
        lea     16(%sp),%sp
        rts
        | f(u) = u / (1 + u^12)^(1/12) at u = 0, 0.125 .. 4, Q14.
sattab:
        cal_sattab
        .text

        | ------------------------------------------------------------------
        | Tables, computed at 48 kHz and a 32-sample block, or fitted as their
        | own comments say. rattab, fitted to the measured reduction, is in
        | .state: this pool is full.
        | ------------------------------------------------------------------
        | The release decay per block, Q16, per REL 0.1, 0.2, 0.4, 0.6, 1, 2 s,
        | A1, A2: fitted, not 1 - exp(-32/(fs*tau)), since the release recovers
        | more slowly than one pole (calibration.toml, [ballistics]). A1 and A2
        | are program-dependent auto-release modes; theirs are the best fixed
        | stand-ins, not a model of them.
reltab:
        cal_reltab


        | ------------------------------------------------------------------
        | Read-only tables and the page vector. All of them are constant, so
        | they live here in cave4 with the code, which leaves cave1 and cave2
        | holding only what is written at runtime.
        | ------------------------------------------------------------------
        .balign 4
        | log2(1+f) in Q12 at f = 0,1/8..1
log2tab:
        .word   0,696,1319,1882,2396,2869,3307,3715,4096
        | 1 - exp(-32/(fs*tau)) in Q16, per ATK setting. The nominal pole: the
        | slow-attack loss is carried by atkscale, not by slowing this.
atktab:
        cal_atktab
        | log(1+exp(-x)) in Q12 at x = 0,1,2..8 dB, eight uniform spans
softtab:
        .word   2839,1283,520,199,74,28,10,4,1

        | The text routines run from cave5 (.ui): cave4 has no room left.
        .section .ui,"ax"
        .align  2

        .align  2

        | ------------------------------------------------------------------
        | draw_labels(view, canvas) - the eight encoders' labels, as the stock
        | page draws them but with no dials, like the sample page's second page.
        |
        | This is the loop of the stock page draw at 0x40039782 with one
        | argument changed. Per knob k (0..3 the top row, 4..7 the bottom):
        |   id    = view vt +156 (view, k); none -> nothing drawn
        |   a6    = 0x40039608(view, id, &b0, &b1)
        |   a9    = 0x4006f378(view + 144, k), low byte
        |   a7    = 0x4006f166(view + 144, k), the value
        |   a8    = b1 ? 1 : b0
        |   draw  = b0 ? view vt +152 : view vt +148
        |   draw(view, canvas, x, y, id, a6, a7, a8, a9, 1)
        | with x = 16 + 32 * column. The last argument is where stock passes a
        | per-parameter flag (bit 17 of the record at 0x400ff556(id)); set, the
        | knob draw at 0x40037a56 skips its dial and draws only the text, 13
        | px from y, centred on x. The text is the short name, or the value
        | while the knob is being turned, as on the stock page.
        |
        | Frame: b0 and b1 at 0 and 1, the knob showing its value at 4, a string
        | object at 8, its map entry at 12, ten saved registers at 16 ending at
        | 56.
        | ------------------------------------------------------------------
        | The stock page's knob rows are 46 and 24; the top row is raised to
        | clear the trace band, which sits between the two label rows.
        .equ    LBL_Y_TOP,      61
        .equ    LBL_Y_BOTTOM,   24
        | DMA timer 0 runs at about 130 MHz (87,000 ticks a 667 us block).
        .equ    SHOW_TICKS,     130000000   | about 1 s
        .align  2
draw_labels:
        lea     -56(%sp),%sp
        movem.l %d2-%d7/%a2-%a5,16(%sp)
        move.l  60(%sp),%a2                       | view
        move.l  64(%sp),%a4                       | canvas

        | The four enumerations - ATK, REL, RAT, SEQ - have no text formatter:
        | the stock page shows their value graphically in the dial, which this
        | page does not draw, and param_value_text leaves its buffer untouched
        | for them. So an edit is detected here, as a change of the value since
        | the last draw, and for SHOW_TICKS after it that knob shows the value
        | from the firmware's own label table in place of its name.
        lea     P_THR,%a0
        lea     enum_last,%a1
        lea     enum_map,%a3
        moveq   #3,%d2
10:     mvz.b   (%a3),%d0                         | offset in the parameter block
        move.b  (%a0,%d0.l),%d1                   | the 8.8 value's integer part
        cmp.b   (%a1),%d1
        beq.s   11f
        move.b  %d1,(%a1)
        move.l  %a3,enum_k
        move.l  DTCN0,%d0
        move.l  %d0,enum_t
11:     addq.l  #1,%a1
        addq.l  #8,%a3
        subq.l  #1,%d2
        bpl.s   10b
        moveq   #-1,%d1                           | no knob showing a value
        move.l  enum_k,%d0
        beq.s   13f
        move.l  %d0,%a0
        move.l  DTCN0,%d0
        sub.l   enum_t,%d0
        cmp.l   #SHOW_TICKS,%d0
        bcs.s   12f
        clr.l   enum_k                            | expired; the counter wraps
        bra.s   13f
12:     mvz.b   1(%a0),%d1                        | the knob
        move.l  %a0,12(%sp)                       | and its map entry
13:     move.l  %d1,4(%sp)

        move.l  %a2,%d7
        add.l   #144,%d7
        moveq   #0,%d2                            | knob
1:      move.l  (%a2),%a0
        move.l  %d2,-(%sp)
        move.l  %a2,-(%sp)
        move.l  156(%a0),%a0
        jsr     (%a0)
        addq.l  #8,%sp
        move.l  %d0,%d5                           | id
        beq     9f
        clr.w   (%sp)
        pea     1(%sp)                            | &b1
        pea     4(%sp)                            | &b0
        move.l  %d5,-(%sp)
        move.l  %a2,-(%sp)
        jsr     0x40039608
        lea     16(%sp),%sp
        move.l  %d0,%a3
        move.l  %d2,-(%sp)
        move.l  %d7,-(%sp)
        jsr     0x4006f378
        addq.l  #8,%sp
        mvz.b   %d0,%d6
        move.l  %d2,-(%sp)
        move.l  %d7,-(%sp)
        jsr     0x4006f166
        addq.l  #8,%sp
        move.l  %d0,%d4
        moveq   #1,%d3
        tst.b   1(%sp)
        bne.s   2f
        mvz.b   (%sp),%d3
2:      moveq   #3,%d0
        and.l   %d2,%d0
        lsl.l   #5,%d0
        add.l   #16,%d0
        move.l  %d0,%a5                           | x
        moveq   #LBL_Y_TOP,%d0
        btst    #2,%d2
        beq.s   3f
        moveq   #LBL_Y_BOTTOM,%d0
3:      cmp.l   4(%sp),%d2
        bne     5f

        | This knob's value, drawn the way the knob draw at 0x40037a56 draws its
        | text: formatted "%.7s" into a string object (0x4002b0ac, a0 = the
        | object), measured (0x40071d36), centred on x within the screen, drawn
        | at y - 13 (0x4007126c with the object's character pointer) and the
        | object destroyed (0x401bb29c).
        move.l  %d0,%d3
        sub.l   #13,%d3                           | text y
        move.l  12(%sp),%a0                       | map entry
        lea     P_THR,%a1
        mvz.b   (%a0),%d0
        mvz.b   (%a1,%d0.l),%d0                   | value
        tst.b   2(%a0)
        beq.s   6f
        neg.l   %d0
        addq.l  #3,%d0                            | a table that runs against the value
6:      move.l  4(%a0),%a1
        lsl.l   #2,%d0
        move.l  (%a1,%d0.l),-(%sp)                | the value's string
        pea     0x4023f777                        | "%.7s"
        pea     16
        lea     20(%sp),%a0                       | the object at 8
        jsr     0x4002b0ac
        lea     12(%sp),%sp
        pea     -1
        pea     12(%sp)
        pea     0x417e389c                        | text_ctx
        jsr     0x40071d36
        lea     12(%sp),%sp
        move.l  %d0,%d4                           | width
        move.l  %a5,%d1
        move.l  %d4,%d0
        asr.l   #1,%d0
        sub.l   %d0,%d1
        bpl.s   7f
        moveq   #0,%d1
7:      move.l  #128,%d0
        sub.l   %d4,%d0
        cmp.l   %d0,%d1
        ble.s   8f
        move.l  %d0,%d1
8:      move.l  %d1,%d4                           | x
        pea     0x417e389c
        jsr     0x40071b7c                        | text_font
        addq.l  #4,%sp
        move.l  8(%sp),-(%sp)                     | the object's characters
        pea     -1
        move.l  %d3,-(%sp)
        move.l  %d4,-(%sp)
        move.l  %d0,-(%sp)
        move.l  %a4,-(%sp)
        jsr     0x4007126c
        lea     24(%sp),%sp
        pea     8(%sp)
        jsr     0x401bb29c
        addq.l  #4,%sp
        bra.s   9f

5:      move.l  (%a2),%a0
        move.l  148(%a0),%a1
        tst.b   (%sp)
        beq.s   4f
        move.l  152(%a0),%a1
4:      pea     1                                 | no dial
        move.l  %d6,-(%sp)
        move.l  %d3,-(%sp)
        move.l  %d4,-(%sp)
        move.l  %a3,-(%sp)
        move.l  %d5,-(%sp)
        move.l  %d0,-(%sp)                        | y
        move.l  %a5,-(%sp)                        | x
        move.l  %a4,-(%sp)                        | canvas
        move.l  %a2,-(%sp)                        | view
        jsr     (%a1)
        lea     40(%sp),%sp
9:      addq.l  #1,%d2
        moveq   #8,%d0
        cmp.l   %d0,%d2
        blt     1b
        movem.l 16(%sp),%d2-%d7/%a2-%a5
        lea     56(%sp),%sp
        rts
        | Per enumeration: offset in the parameter block, knob, 1 if the table
        | runs against the value, a pad, and the firmware's label table. RAT's
        | table is indexed by the value as stored: the device labels value 0
        | "1:2" (hardware, 2026-09-22), although value 0 is the hardest ratio -
        | the display runs against the behaviour, not the table against the
        | value.
        .align  2
enum_map:
        .byte   2,1,0,0
        .long   0x401ec430                        | ATK .03 .. 30
        .byte   4,2,0,0
        .long   0x401ec410                        | REL .1 .. A2
        .byte   6,4,0,0
        .long   0x401ec45c                        | RAT, as the device labels it
        .byte   8,5,0,0
        .long   0x401ec44c                        | SEQ OFF .. HIT


        | The slow-attack scale on the demand, (byte + 1) / 256, per ATK, REL
        | and RAT: index (ATK * 8 + REL) * 4 + RAT, RAT the stored value 0..3,
        | hardest first (the device labels 0..3 1:2, 1:4, 1:8, MAX). A
        | slow attack does not only slow the reduction, it settles at less of it,
        | by ratio and by how the attack compares with the release. Generated
        | from the coupling form (compressor-model.md, stage 8),
        |   s = (1 + C * (0.03 ms / rel)^p) / (1 + C * (atk / rel)^p),
        | with C and p per stored ratio and rel each REL's effective release
        | time (calibration.toml, [ballistics] coupling and rel_eff_s). The
        | attack pole keeps its nominal coefficients; the whole loss is here.
        .section .tab,"a"
atkscale:
        cal_atkscale
        .text

        | ------------------------------------------------------------------
        | State, written at runtime, in its own sections. The code and the tables
        | fill cave3; the pools cannot merge, so the state lives in what cave2 and
        | cave1 have left. Each section has its own claim in the registry.
        | ------------------------------------------------------------------
        .section .state,"aw"
        .align  2
        | DIST symmetry for this block: the bias before the saturation and
        | sat(bias) after it, side units Q31, and the gain after it as a level,
        | Q8 dB.
sym_b:
        .long   0
sym_sb:
        .long   0
sym_g:
        .long   0
peak:
        .long   0
grstate:
        .long   0
        | Blocks BgWorker has had work waiting; the valve stands aside past
        | BG_WAIT.
bg_wait:
        .long   0
colmax:
        .long   COLSEED
phase:
        .long   0
trace_idx:
        .long   0
        | The trace's scales, set by FUNC + the arrows: hres indexes hrestab,
        | vres is log2 of the quarter dB a row, for the level fill and the GR
        | line alike; they start at 1/2 bar across the screen and 1 dB a row.
        | The GR line hangs from the top row, the fill is centred on the
        | threshold.
hres:
        .byte   3
vres:
        .byte   2
        | The preview's layout, FUNC + the page key: 0 the full page, 1 GR alone.
grmode:
        .byte   0

        | Read-only, here for the room cave4 lacks.
        | Blocks per column, slowest first: 4, 2, 1, 1/2, 1/4 and 1/8 of a bar
        | at 130 BPM across the 128 columns (1/8 rounds 2.7 up to 3). hres
        | starts at 1/2 bar.
hrestab:
        .byte   86,43,22,11,5,3
        .balign 4
        | The page vector source: stock page 11 twice, stock and the preview,
        | read once by the constructor.
comp_pages:
        .long   11
        .long   11
        .align  2
        | Per ratio, indexed by the stored RAT value, hardest first (the device
        | labels 0..3 1:2, 1:4, 1:8, MAX): knee Q8 dB, width Q8 dB, 2^22 / width,
        | slope Q12. From tools/comp/fit_shift.py. The width is held at 0.5 dB
        | or more so its reciprocal fits a word; RAT 0..2 sit on that floor, and
        | a floor of 0.25 dB fits no better. The knee is where the curve bends at
        | THR 64, on the level's scale at SEQ OFF: a signed word, and near the middle of
        | its range at any THR it could be fitted at. The values, in dB and as
        | ratios, are calibration.toml's [curve].
rattab:
        cal_rattab

        | cave3, whole and free since 0005 was retired: the trace's 128 columns,
        | a byte each, which no other pool has room for.
        .section .ring,"aw"
trace_ring:
        .space  NCOLS, 0

        | ------------------------------------------------------------------
        | The SEQ sidechain, after the ring in cave3: the only pool with room.
        |
        | sc_block, once a block: a6 = the sctab row for SEQ and sc_off = its
        | level offset. Clobbers d0.
        |
        | sidech(d0 = one side's shaped sum, Q31) -> d0 = |filtered|. Two
        | first-order sections, each
        |     y = k*x - k*r*x[-1] + P*y[-1]
        | from the row at a6, the state (x[-1], y[-1] per section) at a2, which
        | it steps past. sidech_l starts at L's state, and the R call that
        | follows it carries on into R's. acc0 must be clear on entry and is
        | left clear; clobbers d1, d2 and a2.
        | ------------------------------------------------------------------
        .section .sc,"awx"
        .align  2
        .equ    SCSEC,          12                | bytes a section
        .equ    SCROW,          28                | bytes a row
sc_block:
        mvz.w   P_SEQ,%d0
        lsr.l   #8,%d0                            | seq 0..3
        mulu.w  #SCROW,%d0
        lea     sctab,%a6
        add.l   %d0,%a6
        move.l  2*SCSEC(%a6),%d0
        move.l  %d0,sc_off
        rts

        | The demand in d0 (Q8 dB) less seqatk's byte (1/16 dB) for this SEQ and
        | the ATK in d1, which is kept, not below zero. Clobbers d2, d3 and a1.
        | Here rather than inline for the room: the estimator's pool is full.
seqatk_loss:
        mvz.w   P_SEQ,%d3
        lsr.l   #8,%d3                            | seq 0..3
        move.l  %d3,%d2
        lsl.l   #3,%d2
        sub.l   %d3,%d2                           | seq * 7
        add.l   %d1,%d2                           | + atk
        lea     seqatk,%a1
        mvz.b   (%a1,%d2.l),%d2
        lsl.l   #4,%d2                            | 1/16 dB -> Q8
        sub.l   %d2,%d0
        bpl.s   1f
        moveq   #0,%d0
1:      rts
seqatk:
        cal_seqatk
        .align  2

        | Direct form, one accumulator read a section: reading acc0 waits for
        | every multiply in flight, and the transposed form, with two reads a
        | section, measured slower (1.95% of a block against 1.46). Each state
        | word loads during the multiply before it (EMAC multiply with load;
        | the multiply takes the register's old value).
        |
        | Three state words a side, not four: section 2's input is section
        | 1's output, so its x[-1] is section 1's y[-1], which the load for
        | section 1's P term has just left in d1. The same products go into
        | acc0 in the same order, so the result is unchanged. Profiled
        | (hardware, 2026-09-28): the sidechain went from 1.06% of a block to
        | 0.60%. Keeping the state in on-chip SRAM instead (frame 31's voice
        | slots) measured slower, 0.82%, so it stays in DRAM.

sidech_l:
        lea     sc_st,%a2
        .if     P_CAL
        moveq   #32,%d1                           | channel 10's word in this frame
        bra.s   2f
        .endif
sidech:
        .if     P_CAL
        moveq   #36,%d1                           | channel 11's
2:      bsr.s   calw
        .endif
        move.l  (%a6),%d1                         | k, section 1
        mac.l   %d0,%d1,(%a2),%d1,%acc0           | k*x; d1 = x[-1]
        move.l  %d0,(%a2)+
        move.l  4(%a6),%d2                        | -k*r
        mac.l   %d1,%d2,(%a2),%d1,%acc0           | -k*r*x[-1]; d1 = y1[-1]
        move.l  8(%a6),%d2                        | P
        mac.l   %d1,%d2,%acc0
        movclr.l %acc0,%d0                        | y1
        move.l  %d0,(%a2)+
        move.l  SCSEC(%a6),%d2                    | k, section 2: x = y1,
        mac.l   %d0,%d2,%acc0                     | x[-1] = y1[-1], in d1
        move.l  SCSEC+4(%a6),%d2
        mac.l   %d1,%d2,(%a2),%d1,%acc0           | -k*r*x[-1]; d1 = y2[-1]
        move.l  SCSEC+8(%a6),%d2
        mac.l   %d1,%d2,%acc0
        movclr.l %acc0,%d0                        | y2
        move.l  %d0,(%a2)+
        tst.l   %d0
        bpl.s   1f
        neg.l   %d0
1:      rts

        .if     P_CAL
        | calw(d0 = the side after the saturation, d1 = its word's offset from
        | a0): with MUP at 0, the side times 64 into that AUDIO IN word, over
        | the side before the saturation shape put there. Clobbers d2.
calw:
        tst.l   cal_mup
        bne.s   1f
        move.l  %d0,%d2
        asl.l   #6,%d2
        move.l  %d2,(%a0,%d1.l)
1:      rts
        .endif

        | Per SEQ: (k, -k*r, P) for each section, Q31, then a Q8 dB level
        | offset. The sections are written by tools/comp/fit_sidechain.py
        | --fs 24000, the rate the sample path runs at (DECIM). Every
        | section's peak gain is 1, so none can take a side past its input's
        | headroom. The sections are fitted to the hardware's own response,
        | minimum phase (calibration.toml, [sidechain]).
        |
        | The offset is the SEQ's level relative to OFF, where the knees are
        | placed: the one that puts the cascade back to unity at 1 kHz, less
        | OFF's, plus [sidechain] level_db. calib_tables.py computes it.
sctab:
        cal_sctab
        | Written at runtime: (x[-1], y1[-1], y2[-1]) for L, then for R, and
        | this block's level offset.
sc_st:
        .space  24, 0
sc_off:
        .long   0

        | ------------------------------------------------------------------
        | The level fill: the detector level after SEQ, the signal the static
        | curve is driven by, as a solid fill up from the bottom of the trace
        | band on the GR line's dB a row. Row TRACE_THR, 74% of the way up, is
        | the threshold, knee + k*thr for the ratio set (thr_point), dotted; fill
        | above it is level the compressor is reducing, and the GR line starts on
        | it at 0 dB and falls from it. FUNC + UP / DOWN scales about it.
        | Columns are stored as absolute levels, so a change of THR, RAT or scale
        | redraws the whole history against the new threshold.
        |
        | lvl_track, once a block from the producer with d3 = the level, Q8
        | curve dB: keeps the column's loudest. Changes nothing else.
        | lvl_close, from the producer as a column closes, with d2 = its ring
        | index: stores the column as quarter dB above LVL_FLOOR, a word,
        | 0xffff at or below it, and restarts the maximum. Clobbers d1.
        | lvl_fill(d0 = a stored word) -> d0 = its column mask, the band's rows
        | from the level down to the bottom, against thr_mid. Clobbers d1.
        | ------------------------------------------------------------------
        | The silence gate: nothing under it is reduced. Quarter dB, the GR
        | line's own step, so the fill resolves a row at the finest scale.
        .equ    LVL_FLOOR,      SILENCE_Q8
lvl_track:
        cmp.l   lvlcol,%d3
        ble.s   1f
        move.l  %d3,lvlcol
1:      rts

lvl_close:
        move.l  %a1,-(%sp)
        move.l  %d0,-(%sp)
        move.l  lvlcol,%d0
        sub.l   #LVL_FLOOR,%d0                    | above the floor, Q8
        bgt.s   1f
        move.l  #0xffff,%d0                       | silent
        bra.s   2f
1:      asr.l   #6,%d0                            | quarter dB
2:      lea     lvl_ring,%a1
        move.w  %d0,(%a1,%d2.l*2)
        move.l  #0x80000000,%d0
        move.l  %d0,lvlcol
        move.l  (%sp)+,%d0
        move.l  (%sp)+,%a1
        rts

lvl_fill:
        cmp.l   #0xffff,%d0
        beq.s   8f
        lsl.l   #6,%d0
        add.l   #LVL_FLOOR,%d0                    | the level, Q8
        sub.l   thr_mid,%d0                       | above the threshold, Q8
        asr.l   #6,%d0                            | quarter dB
        mvz.b   vres,%d1
        asr.l   %d1,%d0                           | rows above the middle
        neg.l   %d0
        add.l   #TRACE_THR,%d0                    | the level's row from the top
        bpl.s   1f
        moveq   #0,%d0                            | above the band: all of it
1:      moveq   #TRACE_ROWS,%d1
        cmp.l   %d1,%d0
        bge.s   8f                                | below the band: none
        addq.l  #TRACE_R0,%d0
        moveq   #1,%d1
        lsl.l   %d0,%d1
        subq.l  #1,%d1                            | the rows above the level
        move.l  #(2<<(TRACE_R0+TRACE_ROWS-1))-1,%d0
        eor.l   %d1,%d0
        rts
8:      moveq   #0,%d0
        rts

        | Written at runtime: the column's loudest level so far, Q8, the
        | threshold the draw in progress is using, Q8, and one word a column in
        | step with trace_ring.
lvlcol:
        .long   0x80000000
thr_mid:
        .long   0
        | The GR line's 0 dB row, set by the draw slot for the page it draws.
gr_row0:
        .long   TRACE_THR
        .align  2
lvl_ring:
        .space  NCOLS*2, 0xff

        .if     P_TELEM
        | ------------------------------------------------------------------
        | Telemetry for tools/comp/telemetry/monitor.py, one frame a block on USB
        | channel 11 - the receive buffer's AUDIO IN R word, which nothing
        | plays (compressor-hardware.md, "The receive buffer"). Word k of the block's 32 is
        | (0x5A ^ k) << 24 | data << 8: USB carries the top 24 bits, and the
        | tag checks every word arrived bit for bit. Fields, 16 bits each, in
        | order: block count lo/hi; stock's display idle counter lo/hi and its
        | stage (screen manager +0x748/+0x74c, 0 before the manager exists);
        | DMA timer 0 ticks between interrupts lo/hi, and this stub's run in
        | the previous one lo/hi; the parameter block's eight words, THR to
        | VOL; DIST; the analog control words the interrupt builds from them at
        | 0x800063c2 (the THR DAC value), c6 and c8; `seen`, the preview page's
        | draw budget; the compressor pages' draw count; the stack pointer
        | lo/hi at entry; the UI event queue's depth; the background worker's
        | job queue, as finish.cur - start.cur and finish.node - start.node
        | of its deque (0 and 0 when empty); the on-chip ADC's result slots
        | 0..3 as read (left-justified, bits 14..3), or with telem = 2 the
        | first 8 characters of BgWorker's front job's name (tw_job), or with
        | telem = 3 the UI event queue's write index and the types of its two
        | newest and two head events (tw_ev).
        | The rest are zero.
        |
        | The ADC slots are for compressor-hardware.md, "Gain-reduction
        | readback": the MK1's meter read AN1, which ADLST1 maps to slot 0 here.
        |
        | The queue is the one the UI loop at 0x400a4684 takes an event from
        | each pass; 0x40001444 shows its layout: +4 the events waiting, +16
        | the index mask, +20 the buffer, +28 the read index.
        |
        | BgWorker - the task behind verify_samples_in_bgworker and
        | sample_loader_load_sample, created at priority 2 by 0x40033384 - is a
        | singleton at *0x419f2898. Its base's destructor 0x4017f478 walks a
        | std::deque of jobs at +36: start iterator (cur, first, last, node) at
        | +44, finish at +60.
        |
        | telem_in, first thing in the interrupt; telem_out, last. Both keep
        | every register. The routines are in cave6 (.sat) - cave3 has no room
        | for them beside the level ring - and their counters stay here.
        | ------------------------------------------------------------------
        .equ    SCREEN_MGR_P,   0x419f28f8
        .equ    ADRSLT0,        0xfc094012        | ADC result slot 0; 1..3 follow
        .section .sat,"ax"
telem_in:
        lea     -24(%sp),%sp
        movem.l %d0-%d3/%a0-%a1,(%sp)
        move.l  DTCN0,%d0
        move.l  %d0,%d1
        sub.l   tm_entry,%d1                      | interval
        move.l  %d0,tm_entry
        addq.l  #1,tm_blk
        lea     RXBUF+44,%a0
        moveq   #0,%d2                            | word index
        move.l  %d1,%d3
        move.l  tm_blk,%d0
        bsr     tw_long
        move.l  SCREEN_MGR_P,%a1
        moveq   #0,%d0
        moveq   #0,%d1
        cmp.l   %d0,%a1
        beq.s   1f
        move.l  0x748(%a1),%d0
        move.l  0x74c(%a1),%d1
1:      bsr     tw_long                           | idle counter
        move.l  %d1,%d0
        bsr     tw_word                           | idle stage
        move.l  %d3,%d0
        bsr     tw_long                           | interval
        move.l  tm_run,%d0
        bsr     tw_long                           | the last run
        lea     P_THR,%a1
        moveq   #7,%d3
2:      mvz.w   (%a1)+,%d0
        bsr     tw_word                           | THR .. VOL
        subq.l  #1,%d3
        bpl.s   2b
        mvz.w   DIST,%d0
        bsr     tw_word
        mvz.w   0x800063c2,%d0
        bsr     tw_word                           | THR DAC
        mvz.w   0x800063c6,%d0
        bsr     tw_word
        mvz.w   0x800063c8,%d0
        bsr     tw_word
        move.l  seen,%d0
        bsr     tw_word
        move.l  tm_draws,%d0
        bsr     tw_word
        move.l  %sp,%d0
        add.l   #28,%d0                           | as the interrupt had it
        bsr     tw_long
        move.l  UI_QUEUE+4,%d0
        bsr     tw_word                           | events waiting
        move.l  BGWORKER_P,%a1
        moveq   #0,%d0
        moveq   #0,%d3
        cmp.l   %d0,%a1
        beq.s   4f
        move.l  60(%a1),%d0
        sub.l   44(%a1),%d0                       | finish.cur - start.cur
        move.l  72(%a1),%d3
        sub.l   56(%a1),%d3                       | finish.node - start.node
4:      bsr     tw_word
        move.l  %d3,%d0
        bsr     tw_word
        .if     P_TELEM >= 2
        .if     P_TELEM == 2
        jsr     tw_job
        .else
        jsr     tw_ev
        .endif
        bra.s   6f
        .else
        lea     ADRSLT0,%a1
        moveq   #3,%d3
5:      mvz.w   (%a1)+,%d0
        bsr     tw_word                           | ADC result slots 0..3
        subq.l  #1,%d3
        bpl.s   5b
        bra.s   6f
        .endif
3:      moveq   #0,%d0
        bsr     tw_word
6:      moveq   #32,%d0
        cmp.l   %d0,%d2
        blt.s   3b
        movem.l (%sp),%d0-%d3/%a0-%a1
        lea     24(%sp),%sp
        rts

        | tw_long(d0) writes its low half then its high half; tw_word(d0)
        | writes its low 16 bits as word d2 at a0, then steps both. Clobber
        | d0 and d1 (tw_long keeps d1 for its caller's next field).
tw_long:
        move.l  %d1,-(%sp)
        move.l  %d0,-(%sp)
        bsr.s   tw_word
        move.l  (%sp)+,%d0
        swap    %d0
        bsr.s   tw_word
        move.l  (%sp)+,%d1
        rts
tw_word:
        and.l   #0xffff,%d0
        lsl.l   #8,%d0
        moveq   #0x5a,%d1
        eor.l   %d2,%d1
        swap    %d1
        lsl.l   #8,%d1
        or.l    %d1,%d0
        move.l  %d0,(%a0)
        lea     RXSTRIDE(%a0),%a0
        addq.l  #1,%d2
        rts

telem_out:
        move.l  %d0,-(%sp)
        move.l  DTCN0,%d0
        sub.l   tm_entry,%d0
        move.l  %d0,tm_run
        move.l  (%sp)+,%d0
        rts

        .section .sc,"awx"
        .if     P_TELEM == 2
        | tw_job(a0, d2 as tw_word): the first 8 characters of the name of
        | BgWorker's front job as four words, 2 characters a word, high byte
        | first, or nothing when its deque is empty. The front job is the one
        | running: the worker loop at 0x400330c4 runs the record at start.cur
        | and only then steps past it. A record is 36 bytes, its name the
        | std::string at +32, a pointer to the characters (the enqueue at
        | 0x40033224 takes the name as its second argument). The caller fills
        | the frame's remaining words. Clobbers d0, d1, d3 and a1.
        .align  2
tw_job:
        move.l  BGWORKER_P,%a1
        move.l  %a1,%d0
        beq.s   9f
        move.l  44(%a1),%d0
        cmp.l   60(%a1),%d0
        beq.s   9f                                | nothing queued
        move.l  %d0,%a1
        move.l  32(%a1),%d0                       | the name's characters
        cmp.l   #0x40000000,%d0
        bcs.s   9f
        cmp.l   #0x42000000,%d0
        bcc.s   9f
        move.l  %d0,%a1
        moveq   #3,%d3
1:      mvz.w   (%a1)+,%d0
        jsr     tw_word
        subq.l  #1,%d3
        bpl.s   1b
9:      rts
        .endif
        .if     P_TELEM == 3
        | tw_ev(a0, d2 as tw_word): the UI event queue as three words - its
        | write index (+24); the types of the two newest entries; and the types
        | of the entry at the read index (+28) and the one after it. Each pair
        | holds the earlier entry in the low byte. An entry is a pointer to the
        | event, whose first byte is the type the UI loop at 0x400a4684 switches
        | on, 0..41; 0xff stands for a pointer outside RAM. Entries behind the
        | read index have been taken already: the write index says how many
        | are new. Posting and taking both run with interrupts masked, so the
        | indices are coherent. Clobbers d0, d1, d3 and a1.
        .align  2
tw_ev:
        move.l  %a2,-(%sp)
        lea     UI_QUEUE,%a1
        move.l  24(%a1),%d0
        jsr     tw_word                           | write index
        move.l  24(%a1),%d3
        subq.l  #2,%d3
        bsr.s   ev_pair                           | the two newest
        move.l  28(%a1),%d3
        bsr.s   ev_pair                           | the head and the next
        move.l  (%sp)+,%a2
        rts

        | ev_pair(a1 = the queue, d3 = an index): the types of entries d3 and
        | d3 + 1 as one word, the first in the low byte. Steps d3 by one;
        | clobbers d0, d1 and a2.
ev_pair:
        bsr.s   ev_type
        move.l  %d0,-(%sp)
        addq.l  #1,%d3
        bsr.s   ev_type
        lsl.l   #8,%d0
        or.l    (%sp)+,%d0
        jmp     tw_word

        | ev_type(a1, d3) -> d0 = entry d3's type, 0xff outside RAM. Clobbers a2.
ev_type:
        move.l  %d3,%d0
        and.l   16(%a1),%d0
        move.l  20(%a1),%a2
        move.l  (%a2,%d0.l*4),%d0
        cmp.l   #0x40000000,%d0
        bcs.s   1f
        cmp.l   #0x42000000,%d0
        bcc.s   1f
        move.l  %d0,%a2
        mvz.b   (%a2),%d0
        rts
1:      move.l  #0xff,%d0
        rts
        .endif
        .align  2
tm_entry:
        .long   0
tm_blk:
        .long   0
tm_run:
        .long   0
tm_draws:
        .long   0
        .endif

        .if     P_CAL
        | ------------------------------------------------------------------
        | cal_out - the calibration build's record of the block, on every block,
        | from probe_out, so a gap in its count is a lost USB block and never an
        | idle estimator. The sample path uses frames 0, 2 .. 30 and carries the
        | model's sides there on USB channels 10 (L) and 11 (R); the record takes
        | the other sixteen frames, word k on frame 2*(k/2) + 1, channel 10 for
        | even k and 11 for odd. Each word is (0x5A ^ k) << 24 | data << 8, as the
        | telemetry's: USB carries the top 24 bits and the tag checks each word.
        | Longs go low half first. Fields, 16 bits a word:
        |    0- 1  block count
        |    2- 9  the parameter block, THR ATK REL RAT SEQ MUP MIX VOL (8.8)
        |   10-11  DIST (8.8), DIST symmetry
        |   12-13  the detector's peak, Q31
        |   14     the level, Q8 dB
        |   15     the demand after the slow-attack scale, Q8 dB
        |   16     the gain reduction, Q8 dB
        |   17     flags: bit 0 the estimator did not run this block
        |   18-19  this block's run to here, DMA timer 0 ticks
        |   20-21  the interval since the last interrupt, ticks
        |   22     the UI event queue's depth
        |   23     BgWorker's backlog, finish.cur - start.cur
        |   24     what the sides carry: 1 after the saturation, x64 (MUP 0);
        |          2 before it, x8 (MUP set)
        |   25-26  CAL_HASH, the fingerprint of the calib.inc it was built from
        |   27-31  zero
        | Called with nothing live: probe_out restores every register after.
        | ------------------------------------------------------------------
        .section .sat,"ax"
cal_out:
        move.l  DTCN0,%d3
        sub.l   cal_t0,%d3                        | the run to here
        | Channels 10 and 11 are the AUDIO IN words at +40 and +44 of a frame. The
        | sample loop's 32 and 36 are from its pointer at the voices, +8.
        lea     RXBUF+RXSTRIDE+40,%a0             | frame 1, channel 10
        moveq   #0,%d2                            | word index
        move.l  cal_blk,%d0
        bsr     cw_long
        lea     P_THR,%a1
        moveq   #7,%d4
1:      mvz.w   (%a1)+,%d0
        bsr     cw_word                           | THR .. VOL
        subq.l  #1,%d4
        bpl.s   1b
        mvz.w   DIST,%d0
        bsr     cw_word
        mvz.w   DIST+2,%d0
        bsr     cw_word                           | symmetry, 0x8000fbd0
        move.l  peak,%d0
        bsr     cw_long
        move.l  cal_lvl,%d0
        bsr     cw_word
        move.l  cal_dem,%d0
        bsr     cw_word
        move.l  grstate,%d0
        bsr     cw_word
        moveq   #0,%d0
        tst.l   cal_ran
        bne.s   2f
        moveq   #1,%d0                            | the estimator stood aside
2:      bsr     cw_word
        move.l  %d3,%d0
        bsr     cw_long
        move.l  cal_iv,%d0
        bsr     cw_long
        move.l  UI_QUEUE+4,%d0
        bsr     cw_word
        move.l  BGWORKER_P,%a1
        moveq   #0,%d0
        cmp.l   %d0,%a1
        beq.s   3f
        move.l  60(%a1),%d0
        sub.l   44(%a1),%d0                       | finish.cur - start.cur
3:      bsr     cw_word
        moveq   #1,%d0
        tst.l   cal_mup
        beq.s   5f
        moveq   #2,%d0
5:      bsr     cw_word                           | what the sides carry
        move.l  #CAL_HASH,%d0
        bsr     cw_long                           | the calibration it runs
4:      moveq   #0,%d0
        bsr     cw_word
        moveq   #32,%d0
        cmp.l   %d0,%d2
        blt.s   4b
        rts

        | cw_long(d0): its low half, then its high half. cw_word(d0): its low
        | 16 bits as word d2, at a0 for even d2 and 4(a0) for odd, stepping a0
        | two frames after an odd one. Clobber d0 and d1.
cw_long:
        move.l  %d0,-(%sp)
        bsr.s   cw_word
        move.l  (%sp)+,%d0
        swap    %d0
cw_word:
        and.l   #0xffff,%d0
        lsl.l   #8,%d0
        moveq   #0x5a,%d1
        eor.l   %d2,%d1
        swap    %d1
        lsl.l   #8,%d1
        or.l    %d1,%d0
        btst    #0,%d2
        bne.s   1f
        move.l  %d0,(%a0)                         | channel 10
        addq.l  #1,%d2
        rts
1:      move.l  %d0,4(%a0)                        | channel 11
        lea     2*RXSTRIDE(%a0),%a0
        addq.l  #1,%d2
        rts

        .section .sc,"awx"
        .align  2
cal_t0:
        .long   0
cal_iv:
        .long   0
cal_blk:
        .long   0
cal_ran:
        .long   0
cal_lvl:
        .long   0
cal_dem:
        .long   0
cal_mup:
        .long   0
        .endif


        | cave1's tail: runtime data only, every table being in .text.
        .section .aux,"aw"
        .align  2
        | The side coefficients, (cL, cR) per receive slot, Q31, rebuilt every
        | block by the producer.
coef:
        .space  64, 0
        | Blocks left before the producer idles; re-armed by the draw slot.
seen:
        .long   0
        | The enumerations' last drawn values, the map entry last changed (0
        | when none is showing) and when.
enum_last:
        .byte   0,0,0,0
enum_k:
        .long   0
enum_t:
        .long   0
