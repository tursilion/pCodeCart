; ---------------------------------------------------------------------------
; GRAM code pool routines in cart bank 3 (free space >6100-7FEF), entered from the
; RAM trampolines in ramhelp.s (T_COMPACT / T_CONSTW) with bank 3 selected, and
; returning through RET_B0 (re-selects bank 0, then b *r11). Both are called from the
; segment loader in bank 0 with WP = PASCALWS (>8380), so SP = r10.
; Pool address V (fake VDP, >4000-7BFF) lives in GRAM at G = V + >2000 on base 3:
; >980C read data, >9C0C write data, >9C0E write address (high byte first).
; Linked at >6100. RET_B0 (RAM) is passed in by build_cartB2.sh as an assembler --defsym.
; ---------------------------------------------------------------------------
        .text
        .global G_COMPACT, G_CONSTW
        b    @G_COMPACT          ; >6100  T_COMPACT
        b    @G_CONSTW           ; >6104  T_CONSTW

; Compactor (replaces SEGLOAD >5B56-5BA4): move r5 bytes of a segment down the pool
; from V=r2 to V=r0 (r0 < r2, so a forward chunked copy is safe), 35 bytes at a time
; through FAC (>834A), as the original did through VDP. On return r0 and r2 have
; advanced by the count and r5 = 0; r1, r3, r4, r7 are scratch (the original
; overwrote them too). The caller continues at >5BA6.
G_COMPACT:
CP_loop:
        mov  r5, r7
        ci   r7, 35
        jle  CP_n
        li   r7, 35
CP_n:
        s    r7, r5
        mov  r2, r1              ; read chunk from GRAM r2
        ai   r1, 0x2000
        movb r1, @0x9c0e
        swpb r1
        movb r1, @0x9c0e
        li   r3, 0x834a
        mov  r7, r4
CP_rd:
        movb @0x980c, *r3+
        dec  r4
        jne  CP_rd
        a    r7, r2
        mov  r0, r1              ; write chunk to GRAM r0
        ai   r1, 0x2000
        movb r1, @0x9c0e
        swpb r1
        movb r1, @0x9c0e
        li   r3, 0x834a
        mov  r7, r4
CP_wr:
        movb *r3+, @0x9c0c
        dec  r4
        jne  CP_wr
        a    r7, r0
        mov  r5, r5
        jne  CP_loop
        b    @RET_B0

; Real-constant write-back (replaces SEGLOAD >5DCC-5DF2): write the 8-byte native real
; on the stack back over the canonical constant at REALPNT (>2A44, a pool address).
; Same logic as the original: when REALSIZ (>2A42) still equals 4 (@>2D96) the fourth
; mantissa word was never fetched, so r7 skips it. The caller continues at >5DF4.
G_CONSTW:
        mov  @0x2a44, r0
        ai   r0, 0x2000
        movb r0, @0x9c0e
        swpb r0
        movb r0, @0x9c0e
        li   r2, 8
        c    @0x2d96, @0x2a42
        jne  CW_loop
        inct r7
CW_loop:
        movb *r10+, @0x9c0c
        dec  r2
        jgt  CW_loop
        b    @RET_B0
