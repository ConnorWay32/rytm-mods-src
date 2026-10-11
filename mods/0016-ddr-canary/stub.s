        | Mod 0016 - DDR canary: fill the candidate elemod mod area at boot.
        |
        | Detours the OS entry's third call (jsr to the VBR setter at 0x400014cc,
        | the site an elemod core would boot from), fills 0x47BE0000-0x47C00000 with
        | address XOR PATTERN_KEY, then makes the displaced call and rejoins. This
        | runs before the OS copies its SRAM images, clears its BSS or enables the
        | caches, so every later write to the area shows in 0003's mode 4 count.
        |
        | Only d0, d1 and a0 are used, and all three are saved: nothing the stock
        | entry routine holds in a register is disturbed.

        .equ    REGION,         0x47be0000        | first word filled
        .equ    REGION_END,     0x47c00000        | exclusive
        .equ    PATTERN_KEY,    0xc0def00d        | word at a holds a ^ PATTERN_KEY
        .equ    SET_VBR,        0x400014cc        | the boot site's callee
        .equ    BOOT_RESUME,    0x400008c6        | after the boot site

        .text

        .align  2
ddr_canary_fill:
        lea     -12(%sp),%sp
        movem.l %d0-%d1/%a0,(%sp)
        lea     REGION,%a0
        move.l  #PATTERN_KEY,%d1
1:      move.l  %a0,%d0
        eor.l   %d1,%d0
        move.l  %d0,(%a0)+
        cmpa.l  #REGION_END,%a0
        bne.s   1b
        movem.l (%sp),%d0-%d1/%a0
        lea     12(%sp),%sp
        jsr     SET_VBR                           | displaced
        jmp     BOOT_RESUME
