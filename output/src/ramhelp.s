; ---------------------------------------------------------------------------
; Approach B RAM helpers (loaded to 0x3F00 at boot; present in both bank contexts).
; They reproduce the two DSR GROM address-set routines (orig L4144 / L4178) but
; translate the p-code GROM address into console GROM space and select the GROM
; base register r13:
;   bank0 (pcode hi < 0xA0): console = pcode + 0x6000, r13 = >9800  (write-addr 9C02)
;   bank1 (pcode hi >= 0xA0): console = pcode - 0x4000, r13 = >9804  (write-addr 9C06)
; The high byte is written first (GROM sets MSB first), so only it is adjusted.
; Runs in the caller's WS (entered by a plain `b` trampoline from the DSR ROM, so
; r11 = the original caller's return). Saves r0/r11 to RAM temps; leaves r13 set
; (subsequent `movb *r13` data reads then hit the correct console GROM base).
; RAM temps: 0x3FF6 = r0 save, 0x3FF8 = r11 save.
; ---------------------------------------------------------------------------
        .text
        .global RAM_A, RAM_B, RAM_C, XLAT, RAM_59B4, RAM_584A, HELP584A, HELP584B, HELP4F70A, HELP4F70B, RAM_50B2, RAM_50C0, HALTRESET

; ---- shared: r0 MSB = pcode high byte -> translated high byte in r0 MSB, r13 = base ----
XLAT:
        andi r0, 0xff00          ; isolate the high byte (clear LSB garbage from movb)
        ci   r0, 0xa000
        jhe  XLAT_B1
        ai   r0, 0x6000          ; bank0: high += 0x60
        li   r13, 0x9800
        b    *r11
XLAT_B1:
        ai   r0, 0xc000          ; bank1: high -= 0x40  (0xC000 = -0x4000)
        li   r13, 0x9808         ; base2 (base1 is a duplicate of base0; base2 = the other GROM)
        b    *r11

; ---- reproduction of L4144: set GROM address from @8391 / r8 (order per r15) ----
RAM_A:
        mov  r11, @0x3ff8        ; save caller return
        mov  r0,  @0x3ff6        ; save scratch
        ci   r13, 0x8800         ; generic source: r13=8800 (VDP) -> reproduce L4144 w/o xlat
        jeq  RA_vdp
        mov  r15, r15
        jgt  RA_hir8             ; r15>0 : hi=r8, lo=@8391
        jeq  RA_done             ; r15==0: no address change
        ; r15<0 : hi=@8391, lo=r8
        movb @0x8391, r0
        bl   @XLAT               ; r0 = translated hi, r13 = base
        movb r0, @0x0402(r13)    ; write hi
        movb r8, @0x0402(r13)    ; write lo (unchanged)
        jmp  RA_done
RA_hir8:
        mov  r8, r0              ; hi byte = r8 (MSB)
        bl   @XLAT
        movb r0, @0x0402(r13)    ; write hi
        movb @0x8391, @0x0402(r13) ; write lo
RA_done:
        mov  @0x3ff6, r0         ; restore scratch
        mov  @0x3ff8, r11        ; restore return
        b    *r11
; VDP (r13=0x8800) address-set: reproduce L4144 with r13 as-is (no translation).
; r11/r0 still intact (3FF6/3FF8 saves were copies).
RA_vdp:
        mov  r15, r15
        jgt  RAV_hi8
        jeq  RAV_ret            ; r15==0: no address change
        movb @0x8391, @0x0402(r13)   ; r15<0: hi=@8391, lo=r8
        movb r8, @0x0402(r13)
        jmp  RAV_ret
RAV_hi8:
        movb r8, @0x0402(r13)        ; r15>0: hi=r8, lo=@8391
        movb @0x8391, @0x0402(r13)
RAV_ret:
        b    *r11

; ---- reproduction of L4178: set addr from @8383 / r1 then read 2 bytes ----
RAM_B:
        mov  r11, @0x3ff8
        mov  r0,  @0x3ff6
        mov  r15, r15
        jne  RB_set              ; r15!=0 : set+read path
        mov  *r1+, r2            ; r15==0 : plain pointer fetch (not GROM), return
        jmp  RB_done
RB_set:
        ci   r13, 0x8800         ; L4178/L4166 are generic (r13 = GROM / VDP / RAM source).
        jeq  RB_vdp              ;   r13=8800 (VDP read port) -> original passthrough, NO xlat
        mov  r15, r15            ; re-establish r15 status (ci clobbered it)
        jgt  RB_hir1             ; r15>0 : hi=r1, lo=@8383
        ; r15<0 : hi=@8383, lo=r1
        movb @0x8383, r0
        bl   @XLAT
        movb r0, @0x0402(r13)
        movb r1, @0x0402(r13)
        jmp  RB_read
RB_hir1:
        mov  r1, r0             ; hi = r1 (MSB)
        bl   @XLAT
        movb r0, @0x0402(r13)
        movb @0x8383, @0x0402(r13)
RB_read:
        mov  @0x2ae8, r2
        jne  RB_r2first
        ; @2ae8==0
        movb *r13, @0x8385
        inct r1
        movb *r13, r2
        jmp  RB_done
RB_r2first:
        movb *r13, r2
        inct r1
        movb *r13, @0x8385
RB_done:
        mov  @0x3ff6, r0
        mov  @0x3ff8, r11
        b    *r11
; VDP source (r13=0x8800): fall back to the intact original shared tail L4180 in cart
; ROM (0x6180), which writes the (untranslated) address via @0x0402(r13)=0x8C02 and reads
; *r13=0x8800. r0/r11 are still intact here (the 3FF6/3FF8 saves were copies), and L4180
; ends with `b *r11` to the original caller.
RB_vdp:
        b    @0x6180

; ---- reproduction of L4166: same as L4178 (shares L4180 set+read tail) but its
; r15==0 path is `mov *r1+,r2 ; if @2ae8==0 then swpb r2`. r15!=0 path is IDENTICAL
; to RAM_B, so reuse RB_set / RB_done. L4166 was left unconverted (only its sibling
; L4178 was trampolined), so `bl @4166` on the editor/branch path set the GROM
; address via the raw (untranslated) r13 path -> wrong console counter. ----
RAM_C:
        mov  r11, @0x3ff8
        mov  r0,  @0x3ff6
        mov  r15, r15
        jne  RB_set              ; r15!=0 : identical to RAM_B (set console addr + read)
        mov  *r1+, r2            ; r15==0 : plain pointer fetch
        mov  @0x2ae8, @0x2ae8    ; test @2ae8
        jne  RB_done             ; @2ae8!=0 : no swap
        swpb r2                  ; @2ae8==0 : swap bytes
        jmp  RB_done

; ==== r5-based d5 GROM routines (console-space conversion) ====
; XLATW: input r6 = pcode GROM addr. Output r0 = translated console addr (hi byte
; +0x60 bank0 / -0x40 bank1), r5 = console WRITE-ADDR base (9C02 base0 / 9C0A base2).
; r6 is preserved (routines like L584A do pcode arithmetic on it). Uses R11 (bl).
XLATW:
        mov  r6, r0
        ci   r0, 0xa000
        jhe  XW_B1
        ai   r0, 0x6000
        li   r5, 0x9c02
        b    *r11
XW_B1:
        ai   r0, 0xc000
        li   r5, 0x9c0a
        b    *r11

; reproduction of L59B4: set GROM addr from r6, read 2 bytes into r0, return.
RAM_59B4:
        mov  r11, @0x3ff8        ; save caller return (bl @XLATW clobbers r11)
        bl   @XLATW              ; r0=translated addr, r5=write-addr base
        movb r0, *r5             ; write hi
        swpb r0
        movb r0, *r5             ; write lo
        swpb r0
        movb @0xfbfe(r5), r0     ; read data byte -> r0 (hi)
        swpb r0
        movb @0xfbfe(r5), r0     ; read data byte -> r0 (lo)
        swpb r0
        mov  @0x3ff8, r11
        b    *r11

; reproduction of L584A: block copy w/ chip-step. r6 stays PCODE (arithmetic on it);
; translate to r0 only at each port write.
RAM_584A:
        mov  r11, @0x3ff8
        bl   @XLATW              ; initial set: r0=translated(r6), r5=base
        movb r0, *r5
        swpb r0
        movb r0, *r5
R4_loop:
        movb @0xfbfe(r5), @0xfffe(r8)
        inc  r6
        coc  @0x2cde, r6
        jne  R4_skip
        a    @0x2ce0, r6
        bl   @XLATW              ; chip-step re-set (r6 crossed a chip)
        movb r0, *r5
        swpb r0
        movb r0, *r5
        swpb r0
R4_skip:
        dec  r7
        jne  R4_loop
        mov  @0x3ff8, r11
        b    *r11

; In-place helpers for the L584A/L5864 inline address-writes (entered via plain
; `b`, so r11 = the routine's own return is UNTOUCHED). r6=pcode addr (preserved,
; the loop does arithmetic on it), r5 already console; translate r6->r0, write via
; r5, then hardcoded-branch back to the instruction after the 8-byte block.
HELP584A:
        mov  r6, r0
        ci   r0, 0xa000
        jhe  H4A_b1
        ai   r0, 0x6000
        li   r5, 0x9c02
        jmp  H4A_w
H4A_b1:
        ai   r0, 0xc000
        li   r5, 0x9c0a
H4A_w:
        movb r0, *r5
        swpb r0
        movb r0, *r5
        b    @0x7852             ; return -> L5852 (the block read)
HELP584B:
        mov  r6, r0
        ci   r0, 0xa000
        jhe  H4B_b1
        ai   r0, 0x6000
        li   r5, 0x9c02
        jmp  H4B_w
H4B_b1:
        ai   r0, 0xc000
        li   r5, 0x9c0a
H4B_w:
        movb r0, *r5
        swpb r0
        movb r0, *r5
        b    @0x786c             ; return -> L586C (dec r7 ; loop)

; In-place helpers for L4F70 (r1-based address-set, 2 byte-order paths). r1 is
; already console base0 (from the EF7A reseed feeding @2cfa); translate the addr +
; select bank, write hi/lo, return to L4F8C (6F8C). Entered via plain `b`.
HELP4F70A:                       ; path A: hi=r4, lo=@8389 (r0 preserved: L4FA8 needs it)
        mov  r0, @0x3ff4
        mov  r4, r0
        andi r0, 0xff00
        ci   r0, 0xa000
        jhe  H70A_b1
        ai   r4, 0x6000
        li   r1, 0x9800
        jmp  H70A_w
H70A_b1:
        ai   r4, 0xc000
        li   r1, 0x9808
H70A_w:
        movb r4, @0x0402(r1)
        movb @0x8389, @0x0402(r1)
        mov  @0x3ff4, r0
        b    @0x6f8c
HELP4F70B:                       ; path B: hi=@8389, lo=r4 (r0 preserved)
        mov  r0, @0x3ff4
        movb @0x8389, r0
        andi r0, 0xff00
        ci   r0, 0xa000
        jhe  H70B_b1
        ai   r0, 0x6000
        li   r1, 0x9800
        jmp  H70B_w
H70B_b1:
        ai   r0, 0xc000
        li   r1, 0x9808
H70B_w:
        movb r0, @0x0402(r1)
        movb r4, @0x0402(r1)
        mov  @0x3ff4, r0
        b    @0x6f8c

; L50B2 (r1-based address-set, returns b *r6). path A: hi=r4 lo=@8389; path B swap.
RAM_50B2:
        mov  r0, @0x3ff4
        mov  r4, r0
        andi r0, 0xff00
        ci   r0, 0xa000
        jhe  R50_b1
        ai   r4, 0x6000
        li   r1, 0x9800
        jmp  R50_w
R50_b1:
        ai   r4, 0xc000
        li   r1, 0x9808
R50_w:
        movb r4, @0x0402(r1)
        movb @0x8389, @0x0402(r1)
        mov  @0x3ff4, r0
        b    *r6
RAM_50C0:
        mov  r0, @0x3ff4
        movb @0x8389, r0
        andi r0, 0xff00
        ci   r0, 0xa000
        jhe  R50C_b1
        ai   r0, 0x6000
        li   r1, 0x9800
        jmp  R50C_w
R50C_b1:
        ai   r0, 0xc000
        li   r1, 0x9808
R50C_w:
        movb r0, @0x0402(r1)
        movb r4, @0x0402(r1)
        mov  @0x3ff4, r0
        b    *r6

; ---- HALT reset fix ----------------------------------------------------------
; The p-System reset routine (RAM 0x2FFE) ends in `BLWP @0000` (console reset).
; On H(alt) the firmware first stamps a "don't boot" flag ('NO') at 0x38FA so the
; p-System won't re-enter after the reboot -- but on the cart that just drops the
; user back to the title screen with no way back in. patchgrom rewrites that final
; `BLWP @0000` (GROM 0xF290 -> RAM 0x3014) into `B @HALTRESET`, which clears the
; flag first so re-selecting the cart (space,2) re-enters the p-System cleanly.
HALTRESET:
        clr  @0x38fa             ; clear the 'NO' don't-boot flag (-> 0x0000)
        blwp @0x0000             ; original console reset
