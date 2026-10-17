#!/usr/bin/env python3
"""
Approach B cart image (32KB, 4 banks). GROM is REAL hardware in console space
(served by the sim's --gromconsole); the cart ROM is just the 2 DSR code banks
plus a small loader bank that stages the RAM helper at boot.

  bank0 = patched DSR bank C   bank1 = patched DSR bank D
  bank2 = boot loader @6100 + ramhelp bytes @6118 (copied to 0x3A00) + 80 column loader LOAD80 @6800
  bank3 = GRAM code pool routines @6100 (gram.s)

No bank carries a cartridge header: the console finds the cart through the boot
GROM at base 0 >6000 (see make_ubergrom.py), whose GPL stub runs CLR @>6004 ; B @>6100.
Byte 0 of every bank is forced to >00 so the console never sees >AA in ROM.
Every bank carries the tail stubs:
  ENTRY    @7FF0 : clr @6004 (select bank2) ; b @6100 (loader)   (old ROM-header entry, unused)
  STARTSTUB@7FF8 : clr @6000 (select bank0) ; b @6038 (real startup)
Boot flow: console -> GROM header -> GPL stub -> (bank2) loader copies ramhelp->3A00 ->
           b @7FF8 (STARTSTUB, replicated) -> clr @6000 ; b @6038.
"""
BANKSZ=0x2000; NB=4
b0=bytearray(open('bank0.bin','rb').read())
b1=bytearray(open('bank1.bin','rb').read())
rh=open('ramhelp.bin','rb').read()
assert len(b0)==BANKSZ and len(b1)==BANKSZ
assert len(rh)%2==0 and len(rh)<=0x5F0, "ramhelp too big: %d"%len(rh)

def setw(b,o,v): b[o]=(v>>8)&0xff; b[o+1]=v&0xff

def add_common(buf):
    buf[0]=0x00                              # no >AA header (bank 0/1 keep the rest of the old DSR header bytes)
    # tail stubs
    setw(buf,0x1FF0,0x04E0); setw(buf,0x1FF2,0x6004)   # ENTRY: clr @6004 (bank2)
    setw(buf,0x1FF4,0x0460); setw(buf,0x1FF6,0x6100)   #        b @6100 (loader)
    setw(buf,0x1FF8,0x04E0); setw(buf,0x1FFA,0x6000)   # STARTSTUB: clr @6000
    setw(buf,0x1FFC,0x0460); setw(buf,0x1FFE,0x6038)   #            b @6038

banks=[bytearray(BANKSZ) for _ in range(NB)]
banks[0][:]=b0; banks[1][:]=b1

# bank2: loader @0x100 then ramhelp @0x118
L=banks[2]
setw(L,0x100,0x0201); setw(L,0x102,0x6118)   # li r1,0x6118  (ramhelp source)
setw(L,0x104,0x0202); setw(L,0x106,0x3A00)   # li r2,0x3A00  (dest)
setw(L,0x108,0x0200); setw(L,0x10A,len(rh)//2)  # li r0,wordcount
setw(L,0x10C,0xCCB1)                          # loop: mov *r1+,*r2+
setw(L,0x10E,0x0600)                          # dec r0
setw(L,0x110,0x16FD)                          # jne loop (-3)
setw(L,0x112,0x0460); setw(L,0x114,0x7FF8)   # b @7FF8 (STARTSTUB)
L[0x118:0x118+len(rh)]=rh                     # ramhelp source bytes

# bank2 >6800: LOAD80, the 80 column boot entry (GROM header program 1). Same copy as the
# loader, then BOOTW := 80 (RESCON loads WIDTH from it), then the VDP registers for 80
# columns on F18A / V9938: R8-R15 first (on a 9918A or a locked F18A those writes land in
# R0-R7), then all of R0-R7: R0=>04 (80 columns), R2=>04 (screen image table >1000), the
# rest the normal p-System values. RESCON later rewrites only R1-R7, so R0 survives.
import subprocess
def ramsym(name):
    out=subprocess.check_output(['bash','-c',"~/newtms9900-gcc/newgcc9900/bin/tms9900-nm ramhelp.elf"]).decode()
    return next(int(l.split()[0],16) for l in out.splitlines() if l.split()[-1]==name)
L80=0x800; assert 0x118+len(rh)<=L80
REGS80=[(8,0x08)]+[(r,0) for r in range(9,16)]+list(enumerate((0x04,0xF0,0x04,0x2F,0x00,0x18,0x00,0x17)))
code=[0x0201,0x6118, 0x0202,0x3A00, 0x0200,len(rh)//2,   # li r1,src ; li r2,>3A00 ; li r0,words
      0xCCB1, 0x0600, 0x16FD,                            # mov *r1+,*r2+ ; dec r0 ; jne
      0x0200,80, 0xC800,ramsym('BOOTW'),                 # li r0,80 ; mov r0,@BOOTW
      0x0201,0, 0x0202,len(REGS80),                      # li r1,REGS ; li r2,16
      0xD831,0x8C02, 0xD831,0x8C02, 0x0602, 0x16FA,      # movb *r1+,@>8C02 (value) ; movb *r1+,@>8C02 (>80+reg) ; dec r2 ; jne
      0x0460,0x7FF8]                                     # b @7FF8 (STARTSTUB)
code[14]=0x6000+L80+2*len(code)                          # REGS follow the code
for i,v in enumerate(code): setw(L,L80+2*i,v)
o=L80+2*len(code)
for r,v in REGS80: L[o]=v; L[o+1]=0x80|r; o+=2

# bank3: GRAM code pool routines (gram.s, linked at >6100) after the header/record
g3=open('gram.bin','rb').read()
assert len(g3)<=0x1FF0-0x100, "gram.bin too big: %d"%len(g3)
banks[3][0x100:0x100+len(g3)]=g3

for bk in banks: add_common(bk)

open('cartB2.bin','wb').write(b''.join(bytes(x) for x in banks))
print("wrote cartB2.bin (%d bytes, %d banks); ramhelp=%d bytes @bank2:6118 -> 3A00"%(BANKSZ*NB,NB,len(rh)))
