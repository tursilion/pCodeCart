; ---------------------------------------------------------------------------
; Approach B RAM helpers (loaded to 0x3A00 at boot; present in both bank contexts).
; They reproduce the two DSR GROM address-set routines (orig L4144 / L4178) but
; translate the p-code GROM address into console GROM space and select the GROM
; base register r13:
;   pcode < >8000:  console base 0 = pcode + >8000 (>8000-FFFF), r13 = >9800 (write-addr 9C02)
;   pcode >= >8000: console base 2 = pcode - >2000 (>6000-D7FF), r13 = >9808 (write-addr 9C0A)
;   Base 0/1 >6000 is the cart's boot header GROM, never addressed by the p-System.
; The high byte is written first (GROM sets MSB first), so only it is adjusted.
; Runs in the caller's WS (entered by a plain `b` trampoline from the DSR ROM, so
; r11 = the original caller's return). Saves r0/r11 to RAM temps; leaves r13 set
; (subsequent `movb *r13` data reads then hit the correct console GROM base).
; RAM temps: 0x3FF4 = r0 save (HELP4F70*), 0x3FF6 = r0 save, 0x3FF8 = r11 save.
;
; Reserved low-memory map (0x3A00-0x3FFF):
;   0x3A00-0x3DFF  RAM helpers (this file, up to .org 0x400), incl. the GRAM code pool helpers
;   0x3E00-0x3EC1  ROM disk driver for unit #12 (ROMDISK2 table + RD2READ)
;   0x3EC2-0x3FF3  free
;   0x3FF4-0x3FF9  RAM temps (above)
;   0x3FFA-0x3FFB  r11 save for RAM_VMOV
;   0x3FFC-0x3FFF  free (4 bytes)
; ---------------------------------------------------------------------------
        .text
        .global RAM_A, RAM_B, RAM_C, XLAT, RAM_59B4, RAM_584A, HELP584A, HELP584B, HELP4F70A, HELP4F70B, RAM_50B2, RAM_50C0, HALTRESET
        .global RAM_VMOV, T_COMPACT, T_CONSTW, RET_B0, GRAMTOP, BOOTW, VTOPFIX

; ---- GRAM code pool (UberGROM base 3) ----
; The p-System still thinks the code pool is VDP (code type r15<0) but its "VDP"
; addresses are fake: INTMEM=>4000, TOPMEM=>7BFE. Pool address V lives in GRAM at
; G = V + >2000 (>6000-9BFF, base 3). Real VDP buffer addresses are always < >4000,
; so V >= >4000 means pool. Pool code reads through r13 = >980C (base 3 read data);
; @>0402(r13) = >9C0E is the base 3 write-address port (GROM order: high byte first).
GRAMTOP:
        data 0x7bfe              ; TOPMEM value, stored by the patched startup (RAM >221E)
BOOTW:
        data 40                  ; console WIDTH loaded by RESCON (patched `li r1,40` -> `mov @BOOTW,r1`);
                                 ; the 80 column boot entry (bank 2 LOAD80) sets it to 80

; ---- shared: r0 MSB = pcode high byte -> translated high byte in r0 MSB, r13 = base ----
XLAT:
        andi r0, 0xff00          ; isolate the high byte (clear LSB garbage from movb)
        ci   r0, 0x8000
        jhe  XLAT_B1
        ai   r0, 0x8000          ; base 0: high += 0x80
        li   r13, 0x9800
        b    *r11
XLAT_B1:
        ai   r0, 0xe000          ; base 2: high -= 0x20  (0xE000 = -0x2000)
        li   r13, 0x9808         ; base2 (base1 is a duplicate of base0; base2 = the other GROM)
        b    *r11

; ---- reproduction of L4144: set GROM address from @8391 / r8 (order per r15) ----
RAM_A:
        mov  r11, @0x3ff8        ; save caller return
        mov  r0,  @0x3ff6        ; save scratch
        ci   r13, 0x980c         ; GRAM code pool -> set G = r8 + >2000
        jeq  RA_gram
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
RA_gram:
        mov  r15, r15
        jeq  RA_done             ; r15==0: no address change
        mov  r8, r0
        ai   r0, 0x2000
        movb r0, @0x0402(r13)    ; hi
        swpb r0
        movb r0, @0x0402(r13)    ; lo
        jmp  RA_done
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
        ci   r13, 0x980c         ; GRAM code pool -> set G = r1 + >2000, then read
        jeq  RB_gram
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
RB_gram:
        mov  r1, r0
        ai   r0, 0x2000
        movb r0, @0x0402(r13)    ; hi
        swpb r0
        movb r0, @0x0402(r13)    ; lo
        jmp  RB_read

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
; +0x80 base 0 / -0x20 base 2), r5 = console WRITE-ADDR base (9C02 base0 / 9C0A base2).
; r6 is preserved (routines like L584A do pcode arithmetic on it). Uses R11 (bl).
XLATW:
        mov  r6, r0
        ci   r0, 0x8000
        jhe  XW_B1
        ai   r0, 0x8000
        li   r5, 0x9c02
        b    *r11
XW_B1:
        ai   r0, 0xe000
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
        ci   r0, 0x8000
        jhe  H4A_b1
        ai   r0, 0x8000
        li   r5, 0x9c02
        jmp  H4A_w
H4A_b1:
        ai   r0, 0xe000
        li   r5, 0x9c0a
H4A_w:
        movb r0, *r5
        swpb r0
        movb r0, *r5
        b    @0x7852             ; return -> L5852 (the block read)
HELP584B:
        mov  r6, r0
        ci   r0, 0x8000
        jhe  H4B_b1
        ai   r0, 0x8000
        li   r5, 0x9c02
        jmp  H4B_w
H4B_b1:
        ai   r0, 0xe000
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
        ci   r0, 0x8000
        jhe  H70A_b1
        ai   r4, 0x8000
        li   r1, 0x9800
        jmp  H70A_w
H70A_b1:
        ai   r4, 0xe000
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
        ci   r0, 0x8000
        jhe  H70B_b1
        ai   r0, 0x8000
        li   r1, 0x9800
        jmp  H70B_w
H70B_b1:
        ai   r0, 0xe000
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
        ci   r0, 0x8000
        jhe  R50_b1
        ai   r4, 0x8000
        li   r1, 0x9800
        jmp  R50_w
R50_b1:
        ai   r4, 0xe000
        li   r1, 0x9808
R50_w:
        movb r4, @0x0402(r1)
        movb @0x8389, @0x0402(r1)
        mov  @0x3ff4, r0
        b    *r6
; L50C0 = VDP1 path of the ADDRCOP dispatcher (code type <0, port base r1, address r4,
; return b *r6). r1=>980C: the E_Rec's segment is in the GRAM pool -> G = r4 + >2000,
; GROM order. Otherwise the exact original VDP writes (low byte first, untranslated) --
; menu strings etc. read from real VRAM must keep working (the old Quit-menu bug).
; WP is PASCALWS, so @>8389 is r4's low byte (unchanged by +>2000).
RAM_50C0:
        ci   r1, 0x980c
        jeq  R50C_g
        movb @0x8389, @0x0402(r1)
        movb r4, @0x0402(r1)
        b    *r6
R50C_g:
        ai   r4, 0x2000
        movb r4, @0x0402(r1)     ; hi
        movb @0x8389, @0x0402(r1) ; lo
        ai   r4, -0x2000
        b    *r6

; VDPMOV (bank D >592C): copy r7 bytes, r0 = from, r1 = to, r8 = VDPWA (>8C02). BIOS
; disk reads land each sector in DSKBUF (real VDP) and call this to move it to the
; caller's buffer. Pool side (>= >4000) goes to/from GRAM with each address set once.
; Contract kept: r0/r1 advance by r7, r7 = 0, r5 clobbered. Entered by `b`, returns b *r11.
; Pool test is >4000 <= addr < TOPMEM: the original starts with `ori r1,>4000` and returns
; with that write bit still set, and the BIOS feeds r1 straight back in for the next
; sector, so a REAL VDP destination arrives as >41xx.. from the 2nd sector on (and the disk
; write path passes DSKBUF|>4000 = >7F00). The real path therefore runs the original loop
; via bl and clears the stray >4000 bit from r1 afterwards. r11 is saved at >3FFA.
RAM_VMOV:
        ci   r1, 0x4000
        jl   VM_r1real
        c    r1, @0x2782         ; TOPMEM
        jl   VM_tog
VM_r1real:
        ci   r0, 0x4000
        jl   VM_real
        c    r0, @0x2782
        jl   VM_fromg
VM_real:
        mov  r11, @0x3ffa
        ori  r1, 0x4000          ; original first instruction
        bl   @0x7930             ; rest of the original byte loop (bank 1 still mapped), ends b *r11
        andi r1, 0xbfff          ; drop the write bit so the next sector isn't taken for the pool
        mov  @0x3ffa, r11
        b    *r11
VM_tog:                          ; real VDP r0 -> GRAM r1 (segment load)
        swpb r0
        movb r0, *r8             ; VDP read address, low byte
        swpb r0
        movb r0, *r8             ; high byte (read mode)
        a    r7, r0
        mov  r1, r5
        ai   r5, 0x2000
        movb r5, @0x9c0e         ; GRAM address hi
        swpb r5
        movb r5, @0x9c0e         ; lo
        a    r7, r1
VM_tg1:
        movb @0x8800, @0x9c0c
        dec  r7
        jgt  VM_tg1
        b    *r11
VM_fromg:                        ; GRAM r0 -> real VDP r1
        mov  r0, r5
        ai   r5, 0x2000
        movb r5, @0x9c0e
        swpb r5
        movb r5, @0x9c0e
        a    r7, r0
        mov  r1, r5
        ori  r5, 0x4000
        swpb r5
        movb r5, *r8             ; VDP write address, low byte
        swpb r5
        movb r5, *r8             ; high byte | >40
        a    r7, r1
VM_fg1:
        movb @0x980c, @0x8c00
        dec  r7
        jgt  VM_fg1
        b    *r11

; Trampolines into bank 3 (gram.s, entry table at >6100) for the segment loader's
; compactor (>5B56) and real-constant write-back (>5DCC), both in bank 0. The bank-3
; code returns through RET_B0 with r11 intact.
T_COMPACT:
        clr  @0x6006             ; bank 3
        b    @0x6100
T_CONSTW:
        clr  @0x6006
        b    @0x6104
RET_B0:
        clr  @0x6000             ; back to bank 0
        b    *r11

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

; ---- INITCOD VDP top fix -----------------------------------------------------
; At startup INITCOD (RAM >20F2) shrinks the VDP buffer block of the first >10 disk
; card (CRU from VDP >0004) to 283 bytes, so VDPTOP ends below DSKBUF (>3F00), which
; lies in what is left of that block. If no block with that CRU is found (NOTVAL,
; RAM >21C0) -- e.g. TIPI at a CRU other than >1100 is the only disk card, and it only
; reserves VDP when it stands in for the TI controller at >1100 -- VDPTOP stays >3FFF
; and the disk PCB lands at >3FED, inside DSKBUF: the first sector read overwrites it.
; patchgrom turns NOTVAL's `mov @VDPTOP,r7` into `bl @VTOPFIX`. If VDPTOP is not
; already below DSKBUF, reserve the buffer exactly like INITCOD's no-disk path:
; DSKBUF = VDPTOP-255, header >AA,old VDPTOP,>00 at DSKBUF-4, VDPTOP = DSKBUF-5.
; Returns r7 = VDPTOP (the replaced instruction). Uses r1,r2 (reloaded after NOTVAL).
VTOPFIX:
        mov  @0x8370, r7         ; VDPTOP (the replaced instruction)
        c    r7, @0x2cea         ; below DSKBUF: buffer already reserved
        jl   vtok
        mov  r7, r1
        ai   r1, -255
        mov  r1, @0x2cea         ; DSKBUF = VDPTOP-255
        ai   r1, -4              ; header address
        ori  r1, 0x4000          ; VDP write
        swpb r1
        movb r1, @0x8c02
        swpb r1
        movb r1, @0x8c02
        li   r2, 0xaa00
        movb r2, @0x8c00         ; >AA valid
        movb r7, @0x8c00         ; old VDPTOP
        swpb r7
        movb r7, @0x8c00
        clr  r2
        movb r2, @0x8c00         ; CRU 0
        andi r1, 0x3fff
        dec  r1
        mov  r1, r7
        mov  r1, @0x8370         ; VDPTOP = DSKBUF-5
vtok:
        b    *r11

; =============================================================================
; ROM-based disk device, installed as unit #12 (replaces physical DSK6).
; Translated from romdrive.txt. Placed at a FIXED address 0x3E00
; (ramhelp is linked at 0x3A00, so .org 0x400 -> 0x3E00) for easy debugging.
; patchgrom points UNITPNT[#12] (RAM 0x2C38, GROM 0xEEB4) at ROMDISK2.
; Disk image lives in cart banks 4.. (32 x 256-byte sectors per 8K bank).
; =============================================================================
        .global ROMDISK2, RD2READ
        .org 0x400
ROMDISK2:
        data RD2READ             ; read function
        data 0                   ; no write
        data 0                   ; no init
        data 0                   ; no status

; Actual read function. Called (B *R2 from FNDBIOS) with WP=INTWS, R10=IOCTRL, ROM page 2
; (bank1) active. Running in RAM, so banks can be switched freely; restore before RTWP.
; After DISKPAR: R1=buffer, R2=byte count, R3=block/sector, R4=control word,
;                R8=drive number, R9=physical drive number
RD2READ:
        sb   @0x29c4, @0x29c4     ; zero SERBUF+12 (our unit's previous-error byte)
        seto @0x834c              ; FAC+2 read flag
        clr  @0x2ce2              ; GRMADDR
        bl   @0x76f4              ; DISKPAR (orig >56F4, relocated +0x2000 in the cart)

; source: 32 sectors per 8K page
        mov  r3, r6               ; to calculate page and offset
        andi r6, 0x1f             ; 0-31 sector index inside page
        swpb r6                   ; *256 -> offset
        ai   r6, 0x6000           ; R6 = source address
        srl  r3, 5                ; /32 -> page index
        sla  r3, 1                ; *2 for bank-select address
        ai   r3, 0x6008           ; first data page = bank 4 (>6008)

; pick copy loop
        andi r4, 0xc000           ; control word bits 14,15
        jeq  COPYRAM
        jlt  COPYGRAM             ; bit 15 -> GRAM

; ---- copy to VRAM: src R6, page R3, dest R1, count R2
        ci   r1, 0x4000           ; fake VDP address in the GRAM code pool?
        jhe  COPYPOOL
        ori  r1, 0x4000
        swpb r1
        movb r1, @0x8c02
        swpb r1
        movb r1, @0x8c02
VDPOUT:
        clr  *r3+                 ; select page, advance to next
VDPIN:
        movb *r6+, @0x8c00        ; write byte
        dec  r2
        jeq  cpdone
        ci   r6, 0x8000
        jne  VDPIN
        li   r6, 0x6000
        jmp  VDPOUT

; ---- copy to the GRAM code pool: G = R1 + >2000 on base 3, address set once
COPYPOOL:
        ai   r1, 0x2000
        movb r1, @0x9c0e
        swpb r1
        movb r1, @0x9c0e
POOLOUT:
        clr  *r3+                 ; select page, advance to next
POOLIN:
        movb *r6+, @0x9c0c
        dec  r2
        jeq  cpdone
        ci   r6, 0x8000
        jne  POOLIN
        li   r6, 0x6000
        jmp  POOLOUT

; ---- copy to CPU RAM
COPYRAM:
RAMOUT:
        clr  *r3+
RAMIN:
        movb *r6+, *r1+
        dec  r2
        jeq  cpdone
        ci   r6, 0x8000
        jne  RAMIN
        li   r6, 0x6000
        jmp  RAMOUT

; ---- copy to GRAM (base 0x9C26 set / 0x981D data, per original firmware)
COPYGRAM:
        dec  r1
        movb r1, @0x9c26
        swpb r1
        movb r1, @0x9c26
GRAMOUT:
        clr  *r3+
GRAMIN:
        movb *r6+, @0x981d
        dec  r2
        jeq  cpdone
        ci   r6, 0x8000
        jne  GRAMIN               ; (romdrive.txt had VDPIN here - fixed)
        li   r6, 0x6000
        jmp  GRAMOUT              ; (romdrive.txt had VDPOUT here - fixed)

cpdone:
        clr  @0x6002              ; p-code expects page 2 (bank1) active
        rtwp

