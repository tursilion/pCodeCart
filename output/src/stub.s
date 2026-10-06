; ---------------------------------------------------------------------------
; Milestone-B GROM bank-switch read/set core.  MUST live in the replicated tail
; of EVERY cart bank: it is the only code that executes while the window is
; flipped to a data bank, so identical bytes must be present at this address in
; every bank for execution to continue across the switch.
;
; 8 GROM chips live in cart banks 2..9; for GROM address A: chip=A>>13,
; data byte at window offset  0x6000 + HOFF + (A & 0x1FFF)  of bank 2+chip.
; Persistent RAM state: PGADDR (next byte to prefetch) + PREBYTE (prefetched
; byte returned by the next data read) -> matches the hardware prefetch so an
; address read-back is one past the last-returned byte.
;
; Entry points (call via BL; R11 = return):
;   RDGROMC : return next GROM data byte in MSB of R1, restore code bank C.
;   RDGROMD : same, restore code bank D (for the two d5 GROM routines).
;   SETADDR : R1 = 16-bit GROM address; set PGADDR, prefetch, restore bank C.
;   SETADRD : same, restore bank D.
; Scratch R0/R2/R3 are saved/restored to a small RAM block so the caller's
; workspace is untouched except R1.
; RAM: 0x3FF6 SAVE2  0x3FF8 SAVE3  0x3FFA RESTB  0x3FFC PGADDR  0x3FFE PREBYTE
; ---------------------------------------------------------------------------
        .text
        .global RDGROMC, RDGROMD, SETADDR, SETADRD

RDGROMC:
        li   r0, 0x6000          ; restore-bank switch address (C)
        jmp  RDCOM
RDGROMD:
        li   r0, 0x6002          ; restore-bank switch address (D)
RDCOM:
        mov  r0, @0x3ffa         ; RESTB = restore-bank address
        mov  r2, @0x3ff6         ; save scratch
        mov  r3, @0x3ff8
        movb @0x3ffe, r1         ; R1 msb = prefetched byte (returned)
        jmp  PFETCH

SETADDR:
        li   r0, 0x6000
        jmp  STCOM
SETADRD:
        li   r0, 0x6002
STCOM:
        mov  r0, @0x3ffa
        mov  r2, @0x3ff6
        mov  r3, @0x3ff8
        mov  r1, @0x3ffc         ; PGADDR = requested address
        ; fall into PFETCH

; --- common: prefetch GROM[PGADDR] into PREBYTE, PGADDR++, restore bank, return ---
PFETCH:
        mov  @0x3ffc, r2         ; r2 = PGADDR
        mov  r2, r3
        srl  r3, 13              ; chip 0..7
        ai   r3, 2               ; data bank 2..9
        sla  r3, 1               ; 2*bank
        ai   r3, 0x6000          ; 6000 + 2*bank
        clr  *r3                 ; window -> data bank (tail replicated: keep running)
        andi r2, 0x1fff
        ai   r2, 0x6008          ; 6000 + HOFF(0x08) + offset
        movb *r2, @0x3ffe        ; PREBYTE = GROM data byte
        inc  @0x3ffc             ; PGADDR++ (top-2K wrap never hit)
        mov  @0x3ffa, r3         ; restore-bank switch address
        clr  *r3                 ; restore code bank (C or D)
        mov  @0x3ff6, r2         ; restore scratch
        mov  @0x3ff8, r3
        b    *r11
