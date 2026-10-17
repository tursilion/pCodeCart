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
        b    @FL_READ            ; >6108  FLASH: read  (ramhelp FLRD)
        b    @FL_WRITE           ; >610C  FLASH: write (ramhelp FLWR)

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

; =============================================================================
; FLASH: disk (unit #11) on the UberGROM flash, GROM pages 9-14 = 192 sectors.
; Entered from ramhelp FLRD/FLWR after DISKPAR, with WP = INTWS and bank 3 selected:
;   R1 = buffer, R2 = byte count (whole sectors), R3 = sector (unit #11 is a physical
;   drive, so DISKPAR doubled the block number), R4 = control word, R10 = IOCTRL.
; R13-R15 hold the BLWP return context; R0, R5-R7, R12 are scratch. Exits via RET_B1R.
; Buffer type, as DSKREAD/DSKWRIT (control bits 15/14): 0 = CPU RAM, >4000 = VDP (a fake
; VDP address >= >4000 is the GRAM code pool on base 3, G = V + >2000), >8000 = GRAM on
; base 9 (TOGRAM/GROMBUF). The UberGROM has ONE address counter for all bases, so the GRAM
; cases are staged through FLBUF (CPU RAM); CPU and VDP copy straight to/from the flash.
; Reads: flash page 9+p is mapped at >8000 of its own base (FLPORT), sector offset * 256.
; Writes: flash controller on base 15 >E000 (>983C read, >9C3C write, >9C3E address):
;   >E000-E0FF page buffer, >E100 page (0-31), >E101/E102 command + inverse
;   (31/CE erase, D2/2D program; the UberGROM holds the CPU until done), >E103 result
;   (0 idle, 1 busy, 2 write protected, 3 command error), >E104 slot (GROM page 0-14).
; Errors (IOCTRL+13): sector >= 192 -> 17 (as an out-of-volume GROM read), write
; protected -> 16, any other flash result -> 9 (via the SECTERR table >2CEE).
; =============================================================================
        .global FL_READ, FL_WRITE
        .set FLBUF, 0x3ef0
FLPORT:                          ; read-data port of the base holding flash page 9+p
        data 0x9810, 0x9814, 0x9818, 0x981c, 0x9820, 0x9828    ; bases 4-8, 10 (9 = GRAM buffers)

; r3 -> r12 = read-data port, GROM address >8000+(r3 & 31)*256 set on it
FL_RDADR:
        mov  r3, r5
        srl  r5, 5
        sla  r5, 1
        mov  @FLPORT(r5), r12
        mov  r3, r6
        andi r6, 0x001f
        swpb r6
        ori  r6, 0x8000
        movb r6, @0x0402(r12)
        swpb r6
        movb r6, @0x0402(r12)
        b    *r11

FL_READ:
FR_loop:
        ci   r3, 192
        jhe  FL_RANGE
        bl   @FL_RDADR
        li   r7, 256
        mov  r4, r0
        andi r0, 0xc000
        jeq  FR_cpu
        jlt  FR_stage            ; bit 15: GRAM base 9
        ci   r1, 0x4000
        jhe  FR_stage            ; GRAM code pool
        mov  r1, r0              ; real VDP
        ori  r0, 0x4000
        swpb r0
        movb r0, @0x8c02
        swpb r0
        movb r0, @0x8c02
FR_vdp:
        movb *r12, @0x8c00
        dec  r7
        jne  FR_vdp
        ai   r1, 256
        jmp  FR_next
FR_cpu:
        movb *r12, *r1+
        dec  r7
        jne  FR_cpu
        jmp  FR_next
FR_stage:
        li   r6, FLBUF
FR_st:
        movb *r12, *r6+
        dec  r7
        jne  FR_st
        li   r6, FLBUF
        li   r7, 256
        mov  r4, r0
        jlt  FR_g9
        mov  r1, r0              ; pool: G = V + >2000 on base 3
        ai   r0, 0x2000
        movb r0, @0x9c0e
        swpb r0
        movb r0, @0x9c0e
FR_pl:
        movb *r6+, @0x9c0c
        dec  r7
        jne  FR_pl
        ai   r1, 256
        jmp  FR_next
FR_g9:
        mov  r1, r0              ; base 9 GRAM, address - 1 as TOGRAM
        dec  r0
        movb r0, @0x9c26
        swpb r0
        movb r0, @0x9c26
FR_g:
        movb *r6+, @0x9c24
        dec  r7
        jne  FR_g
        ai   r1, 256
FR_next:
        inc  r3
        ai   r2, -256
        jgt  FR_loop
        b    @RET_B1R

FL_RANGE:
        movb @0x2cf1, @13(r10)   ; SECTERR[3] = 17
        b    @RET_B1R
FL_WP:
        movb @0x2cf3, @13(r10)   ; SECTERR[5] = 16
        b    @RET_B1R
FL_ERR:
        movb @0x2cef, @13(r10)   ; SECTERR[1] = 9
        b    @RET_B1R

; set the flash controller address r6 (base 15)
FC_ADR:
        movb r6, @0x9c3e
        swpb r6
        movb r6, @0x9c3e
        b    *r11
; r0 MSB = flash controller result (>E103)
FC_RES:
        mov  r11, r5
        li   r6, 0xe103
        bl   @FC_ADR
        movb @0x983c, r0
        b    *r5

FL_WRITE:
FW_loop:
        ci   r3, 192
        jhe  FL_RANGE
        mov  r4, r0              ; 1. GRAM sources first: they use the GROM address counter
        andi r0, 0xc000
        jeq  FW_flash
        jlt  FW_g9
        ci   r1, 0x4000
        jl   FW_flash            ; real VDP: read straight into the page buffer
        mov  r1, r0              ; pool: G = V + >2000 on base 3
        ai   r0, 0x2000
        movb r0, @0x9c0e
        swpb r0
        movb r0, @0x9c0e
        li   r12, 0x980c
        jmp  FW_stage
FW_g9:
        mov  r1, r0              ; base 9 GRAM, as GROMBUF
        movb r0, @0x9c26
        swpb r0
        movb r0, @0x9c26
        li   r12, 0x9824
FW_stage:
        li   r6, FLBUF
        li   r7, 256
FW_st:
        movb *r12, *r6+
        dec  r7
        jne  FW_st
FW_flash:
        bl   @FC_RES             ; 2. not write protected / busy
        cb   r0, @FC_TWO
        jeq  FL_WP
        cb   r0, @FC_ONE
        jeq  FL_ERR
        li   r6, 0xe104          ; 3. slot = GROM page 9 + sector/32
        bl   @FC_ADR
        mov  r3, r0
        srl  r0, 5
        ai   r0, 9
        swpb r0
        movb r0, @0x9c3c
        li   r6, 0xe100          ; 4. page = sector & 31, then erase (31/CE)
        bl   @FC_ADR
        mov  r3, r0
        andi r0, 0x001f
        swpb r0
        movb r0, @0x9c3c
        li   r0, 0x31ce
        movb r0, @0x9c3c
        swpb r0
        movb r0, @0x9c3c
        bl   @FC_RES
        movb r0, r0
        jne  FW_bad
        li   r6, 0xe000          ; 5. 256 bytes into the page buffer
        bl   @FC_ADR
        li   r7, 256
        mov  r4, r0
        andi r0, 0xc000
        jeq  FW_cpu
        jlt  FW_buf
        ci   r1, 0x4000
        jhe  FW_buf
        mov  r1, r0              ; real VDP read address
        swpb r0
        movb r0, @0x8c02
        swpb r0
        movb r0, @0x8c02
FW_vdp:
        movb @0x8800, @0x9c3c
        dec  r7
        jne  FW_vdp
        jmp  FW_prog
FW_cpu:
        mov  r1, r6
        jmp  FW_cp
FW_buf:
        li   r6, FLBUF
FW_cp:
        movb *r6+, @0x9c3c
        dec  r7
        jne  FW_cp
FW_prog:
        li   r6, 0xe101          ; 6. program (D2/2D)
        bl   @FC_ADR
        li   r0, 0xd22d
        movb r0, @0x9c3c
        swpb r0
        movb r0, @0x9c3c
        bl   @FC_RES
        movb r0, r0
        jne  FW_bad
        ai   r1, 256
        inc  r3
        ai   r2, -256
        jgt  FW_more             ; (signed: a short last write leaves r2 negative)
        b    @RET_B1R
FW_more:
        b    @FW_loop
FW_bad:
        cb   r0, @FC_TWO
        jne  FW_err
        b    @FL_WP
FW_err:
        b    @FL_ERR
FC_ONE: byte 1
FC_TWO: byte 2
        .even
