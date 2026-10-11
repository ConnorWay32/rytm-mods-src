        | Mod 0017 - render probe: hook the elemod audio-render sites and gate the
        | effect returns from them.
        |
        | render_in  0x4011fb02  `move.l #0x7fffffff,%d0`, the first instruction after
        |                        the audio interrupt's register save. Arms rp_armed.
        | render_out 0x40121656  `movem.l -0xb4(%a6),%d0-%d7/%a0-%a5`, the handler's
        |                        only exit. Clears the return buffers when armed and
        |                        the gate is open, then restores and rejoins.
        |
        | Every register is saved on entry to the interrupt and restored at its exit,
        | so both stubs may use any of them. Neither touches the EMAC unit or MACSR.

        .equ    DLY_OUT,        0x80007c44        | delay output, 32 L/R long frames
        .equ    REV_BUF,        0x80007b44        | reverb send, then output in place
        .equ    FX_LONGS,       64                | 32 frames x 2 channels
        .equ    BLOCK_COUNT,    0x419ca2ac        | incremented once per main-path block
        .equ    GATE_BIT,       10                | on/off every 1024 blocks
        .equ    IN_RESUME,      0x4011fb08        | after render_in's 6 bytes
        .equ    OUT_RESUME,     0x4012165c        | after render_out's 6 bytes: unlk, rte

        .text

        .align  2
render_in_probe:
        moveq   #1,%d0
        move.l  %d0,rp_armed
        move.l  #0x7fffffff,%d0                   | displaced
        jmp     IN_RESUME

        .align  2
render_out_probe:
        tst.l   rp_armed
        beq.s   9f                                | render_in did not run: change nothing
        clr.l   rp_armed
        move.l  BLOCK_COUNT,%d0
        btst    #GATE_BIT,%d0
        beq.s   9f
        .if     P_WHICH & 1
        lea     DLY_OUT,%a0
        moveq   #FX_LONGS,%d1
1:      clr.l   (%a0)+
        subq.l  #1,%d1
        bne.s   1b
        .endif
        .if     P_WHICH & 2
        lea     REV_BUF,%a0
        moveq   #FX_LONGS,%d1
2:      clr.l   (%a0)+
        subq.l  #1,%d1
        bne.s   2b
        .endif
9:      movem.l -0xb4(%a6),%d0-%d7/%a0-%a5        | displaced
        jmp     OUT_RESUME

        .align  2
rp_armed:
        .long   0
