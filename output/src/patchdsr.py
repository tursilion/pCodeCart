#!/usr/bin/env python3
"""
Approach B: patch the linked DSR ROM bank images (bank0.bin/bank1.bin) for
console-GROM access.  All edits are in the shared region (6000-6FFF, identical in
both banks) and are size-neutral (no layout shift, GROM @6xxx refs still resolve):

  * startup GROM init (L4048/L4054): use the console bank-1 write-addr port and the
    translated address for the boot chip-7 access:
        li r4,>5FFE -> li r4,>9C06   (bank1 write-addr; @0xFBFE(r4)=9804 read)
        li r2,>E804 -> li r2,>A804   (pcode E804 -> console A804, bank1)
  * address-set routines (L4144/L4178): trampoline the entry to the RAM helpers,
    which reproduce the routine + translate the address + select the GROM base:
        L4144: mov r15,r15 ; ...  -> b @RAM_A   (0x3A1E)
        L4178: mov r15,r15 ; ...  -> b @RAM_B   (0x3A7C)

RAM_A/RAM_B addresses come from ramhelp.elf (loaded to 0x3A00 at boot).
"""
import sys, subprocess

# RAM helper entry addresses (must match ramhelp link @0x3A00)
def sym(name):
    out=subprocess.check_output(['bash','-c',
        "~/newtms9900-gcc/newgcc9900/bin/tms9900-objdump -t ramhelp.elf 2>/dev/null | grep -iw %s"%name]).decode()
    return int(out.split()[0],16)
RAM_A=sym('RAM_A'); RAM_B=sym('RAM_B'); RAM_C=sym('RAM_C'); RAM_59B4=sym('RAM_59B4'); HELP584A=sym('HELP584A'); HELP584B=sym('HELP584B'); HELP4F70A=sym('HELP4F70A'); HELP4F70B=sym('HELP4F70B'); RAM_50B2=sym('RAM_50B2'); RAM_50C0=sym('RAM_50C0')
print("RAM_A=%04X RAM_B=%04X RAM_59B4=%04X HELP584A=%04X"%(RAM_A,RAM_B,RAM_59B4,HELP584A))

def setw(b,o,v): b[o]=(v>>8)&0xff; b[o+1]=v&0xff
def patch(fn):
    b=bytearray(open(fn,'rb').read())
    assert len(b)==0x2000
    # sanity-check original bytes
    assert b[0x04A]==0x5F and b[0x04B]==0xFE, "startup li r4 operand mismatch in %s"%fn
    assert b[0x056]==0xE8 and b[0x057]==0x04, "startup li r2 operand mismatch"
    assert b[0x144]==0xC3 and b[0x145]==0xCF, "L4144 entry mismatch"
    assert b[0x166]==0xC3 and b[0x167]==0xCF, "L4166 entry mismatch"
    assert b[0x178]==0xC3 and b[0x179]==0xCF, "L4178 entry mismatch"
    setw(b,0x04A,0x9C0A)          # li r4 -> bank1 (base2) write-addr port 9C0A
    setw(b,0x056,0xA804)          # li r2 -> translated boot address
    setw(b,0x144,0x0460); setw(b,0x146,RAM_A)   # b @RAM_A
    setw(b,0x166,0x0460); setw(b,0x168,RAM_C)   # b @RAM_C
    setw(b,0x178,0x0460); setw(b,0x17A,RAM_B)   # b @RAM_B
    # L4F70 path A (off 0xF70) + path B (off 0xF7E): b @helper + nops, return -> L4F8C
    assert b[0xF70]==0xD8 and b[0xF71]==0x44, "L4F70 mismatch"
    setw(b,0xF70,0x0460); setw(b,0xF72,HELP4F70A)
    for o in range(0xF74,0xF7E,2): setw(b,o,0x1000)
    assert b[0xF7E]==0xD8 and b[0xF7F]==0x60, "L4F7E mismatch"
    setw(b,0xF7E,0x0460); setw(b,0xF80,HELP4F70B)
    for o in range(0xF82,0xF8C,2): setw(b,o,0x1000)
    open(fn,'wb').write(b)
    print("patched %s: startup ports + L4144->RAM_A + L4178->RAM_B"%fn)

patch('bank0.bin'); patch('bank1.bin')

# c5 (bank0) banked-region address-set dispatcher (L5094..L50CC):
#   R0>0 -> GROM1 (L50B2): GROM access, needs pcode->console translation + base select
#   R0<0 -> VDP1  (L50C0): VDP access, writes a VRAM address VERBATIM to R1's port
#                          (R1=0x8800 -> 0x8C02). NO translation.
# Only GROM1 is trampolined. L50C0 (VDP1) must NOT be trampolined: translating a VDP
# address corrupts the VDP write-address, so the original VDP code runs in place.
# (Trampolining VDP1 was a regression: it diverted the menu-string VDP SETADDR to the
#  GROM port, so menus that read their text from VRAM drew garbage -- e.g. editor Quit.)
b=bytearray(open('bank0.bin','rb').read())
assert b[0x10B2]==0xD8 and b[0x10B3]==0x44, "L50B2 mismatch"
assert b[0x10C0]==0xD8 and b[0x10C1]==0x60, "L50C0 (VDP1) mismatch -- must stay original"
setw(b,0x10B2,0x0460); setw(b,0x10B4,RAM_50B2)
open('bank0.bin','wb').write(b)
print("patched bank0.bin c5: L50B2(GROM1)->RAM_50B2 ; L50C0(VDP1) left original")

# --- relocate demoted-region bl/b refs + fix li immediates ---
# reasm emits some code regions as raw `byte` data (label landed mid-body); their embedded
# `bl @4xxx`/`b @4xxx` refs were NOT relocated -> relocate +0x2000.
# `li rN,0x4xxx` is ambiguous: a code/data pointer (relocate) OR a VDP write-address
# (0x4000|screen_pos, must NOT relocate - reasm/linker wrongly relocates these -> garble).
# Discriminators:
#   vdpli.txt = PCs of li's whose value is written to the VDP addr port 0x8C02 (captured by
#               the sim's register-taint = definitely VDP addresses -> un-relocate).
#   realtgt   = real code/data target addresses (labels used by non-li instrs + covered code
#               starts) -> a demoted li to one of these is a real pointer -> relocate.
PORTS=(0x5bfc,0x5bfe,0x5ffc,0x5ffe)
vdpli=set(int(x,16) for x in open('vdpli.txt').read().split()) if __import__('os').path.exists('vdpli.txt') else set()
import re
realtgt=set()
for fn in ('shared.s','c5.s','d5.s'):
    for ln in open(fn):
        if ln.strip().startswith('li '): continue
        for m in re.findall(r'L([0-9a-f]{4})', ln): realtgt.add(int(m,16))
for ln in open('cov_ptr.txt' if __import__('os').path.exists('cov_ptr.txt') else 'cov_boot.txt'):
    if ln.startswith('#'): continue
    p=ln.split()
    if len(p)==4 and (int(p[1])|int(p[2])|int(p[3])): realtgt.add(int(p[0],16))
# Also treat COMPILER-run code-starts as real targets: the compiler exercises DSR code
# the boot/editor traces never hit, with demoted `li rN,<continuation>` in shared ROM
# (e.g. CXI @0x4D12 does `li r2,0x4D1A` then `b @LDUBB` which `b *r2`s to the continuation).
# These continuations are referenced ONLY by that li, so they're not otherwise in realtgt
# and would be left unrelocated -> `b *r2` jumps into dead 0x4Dxx space and the compile
# stalls. Adding the compile coverage's code-starts lets reloc_demoted relocate them --
# a post-link operand patch only; the (boot-coverage) disassembly is unchanged, so HALT and
# the other boot/editor/filer paths are unaffected.
if __import__('os').path.exists('cov_comp.txt'):
    for ln in open('cov_comp.txt'):
        if ln.startswith('#'): continue
        p=ln.split()
        if len(p)==4 and (int(p[1])|int(p[2])|int(p[3])): realtgt.add(int(p[0],16))

def reloc_demoted(fn):
    b=bytearray(open(fn,'rb').read()); n=0; nli=0; nvdp=0; nsp=0
    for i in range(0,len(b)-3,2):
        op=(b[i]<<8)|b[i+1]; tgt=(b[i+2]<<8)|b[i+3]
        # Self-relative PME-handler dispatch pointer: `.WORD self+2` (a word at cart addr
        # CA=0x6000+i holding CA+2). The PME opcode table (in GROM) points at CA; the fetch
        # reads this word and branches to the handler code right after it. reasm relocates
        # these when the handler is covered, but demotes uncovered ones to a raw byte run,
        # leaving the pointer at 0x5xxx -> jump into dead DSR space (e.g. ABI @0x51F2->0x51F4
        # crashed the editor's delete/left-arrow path). An un-relocated self+2 pointer has
        # value exactly 0x4002+i; relocate it +0x2000. Signature is unique per position, so
        # it never matches a correctly-relocated pointer (those are 0x6002+i) or real code.
        if op == 0x4002+i and op not in PORTS:
            setw(b,i,op+0x2000); nsp+=1; continue
        # bl @ (06a0), b @ (0460), blwp @ (0420) -- all format-VI symbolic (@addr) ops whose
        # operand is a DSR-ROM address that moved +0x2000.  blwp targets a 2-word vector in
        # ROM (e.g. the GROM-read vector @4774->6774, whose PC word reasm already relocated);
        # demoted blwp instrs kept stale 0x4xxx/5xxx operands -> blwp into dead space -> crash.
        if op in (0x06a0,0x0460,0x0420) and 0x4000<=tgt<=0x5fff and tgt not in PORTS:
            setw(b,i+2,tgt+0x2000); n+=1; continue
        if 0x0200<=op<=0x020f:   # li rN,imm
            naddr = (0x4000+i) if i<0x1000 else (0x5000+(i-0x1000))   # normalized addr of this li
            if naddr in vdpli:                 # VDP address -> must be literal (un-relocate)
                if 0x6000<=tgt<=0x7fff: setw(b,i+2,tgt-0x2000); nvdp+=1
            elif 0x4001<=tgt<=0x5fff and tgt not in PORTS and tgt in realtgt:  # real code/data ptr
                setw(b,i+2,tgt+0x2000); nli+=1
    open(fn,'wb').write(b); print("reloc_demoted %s: %d bl/b, %d li reloc, %d VDP-li un-reloc, %d self+2 ptr"%(fn,n,nli,nvdp,nsp))
reloc_demoted('bank0.bin'); reloc_demoted('bank1.bin')

# d5 (bank1) banked-region trampolines: L59B4 (79B4 -> file off 0x19B4)
b=bytearray(open('bank1.bin','rb').read())
assert b[0x19B4]==0xD5 and b[0x19B5]==0x46, "L59B4 entry mismatch: %02X%02X"%(b[0x19B4],b[0x19B5])
setw(b,0x19B4,0x0460); setw(b,0x19B6,RAM_59B4)   # b @RAM_59B4
# L584A / L5864 inline address-write blocks (8B) -> bl @HELP584 + 2 nops
for off,hlp in ((0x184A,HELP584A),(0x1864,HELP584B)):
    assert b[off]==0xD5 and b[off+1]==0x46, "584A/5864 block mismatch @%X"%off
    setw(b,off,0x0460); setw(b,off+2,hlp); setw(b,off+4,0x1000); setw(b,off+6,0x1000)
# Dispatch table at L5F8C (bankD): 4 word-pointer entries -> code just after the table.
# Entry0 (->5F94) is covered so reasm relocated it (to 7F94); entries 1-3 point to
# UNCOVERED code (5F96/5F9A/5FA8, only reached on a math-fault path) so they stayed at
# 0x5xxx -> dispatching through them jumps into dead 0x5Fxx space and crashes.  Relocate
# the three demoted entries +0x2000.  (Found on the user's real run; targets verified as
# the code bytes immediately following the table.)
for off,want in ((0x1F8E,0x5F96),(0x1F90,0x5F9A),(0x1F92,0x5FA8)):
    assert (b[off]<<8|b[off+1])==want, "L5F8C table entry @%X = %04X (want %04X)"%(off,b[off]<<8|b[off+1],want)
    setw(b,off,want+0x2000)
print("patched bank1.bin d5: L5F8C dispatch-table entries 5F96/5F9A/5FA8 -> +0x2000")
open('bank1.bin','wb').write(b)
print("patched bank1.bin d5: L59B4->RAM_59B4, L584A/L5864->HELP584A/B")
