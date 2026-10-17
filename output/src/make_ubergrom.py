#!/usr/bin/env python3
"""Package the cart for UberGROM hardware (see output/ubergrom/UBERGROM.md).

  PCODE_ROM_8.BIN  romcart.bin padded to 512K (cart ROM, banks 0-63)
  PCODE_AVR_FLASH.BIN  GROM pages 0-8 at page*8K, padded (0xFF) to 120K, + UberGROM_Program.bin = 128K
  PCODE_AVR_EEPROM.BIN  4K configuration EEPROM: bases enabled, GROM slot map, GRAM on base 3, flash controller
Run from build/ (build_cartB2.sh calls it last). Inputs: romcart.bin + cartgrom_b.bin from build/."""
import os
BIN='../output/bin'; EX='../ubergrom_example'; OUT='../output/ubergrom'
PAGE=0x2000
os.makedirs(OUT, exist_ok=True)

# 1. PCODE_ROM_8.BIN
rom=open('romcart.bin','rb').read()
assert len(rom)<=0x80000
open(OUT+'/PCODE_ROM_8.BIN','wb').write(rom+b'\xff'*(0x80000-len(rom)))

# 2. PCODE_AVR_FLASH.BIN
#    page 0    = boot header GROM (base 0/1 >6000; never addressed by the p-System)
#    pages 1-4 = p-code GROM >0000-7FFF (base 0 >8000-FFFF, console = pcode + >8000)
#    pages 5-8 = p-code GROM >8000-F7FF (base 2 >6000-D7FF, console = pcode - >2000; last page 0xFF padded)
#    The RAM helpers' XLAT split (ramhelp.s) must match this.
def boot_header():
    """GPL boot header at base 0 >6000. The console lists programs in reverse order, so
    the first record is the second menu entry. Each program's GPL clears the screen,
    stores >8302 (the code vector) at >8300, the cart bank to select at >8304 and its ROM
    entry at >8308, then branches to the common tail, which stores CLR @ (>04E0) at >8302
    and B @ (>0460) at >8306 and runs XML >F0 (the code at >8302):
        CLR @>6004 (bank 2) ; B @entry
    Entries: >6100 = the normal loader (40 columns), >6800 = LOAD80 (80 columns)."""
    BANK=0x6004
    progs=[(b'UCSD P-SYSTEM (80 COL)',0x6800), (b'UCSD P-SYSTEM',0x6100)]   # list order
    h=bytearray(PAGE); a=[0x600C]
    def put(addr,bs): h[addr-0x6000:addr-0x6000+len(bs)]=bytes(bs)
    def w(v): return [(v>>8)&0xff, v&0xff]
    recs=[]; 
    for nm,_ in progs: recs.append(a[0]); a[0]+=5+len(nm)       # program records
    starts=[];
    for _ in progs: starts.append(a[0]); a[0]+=18                # GPL stubs (18 bytes each)
    tail=a[0]
    def br(t): return [0x40|((t>>8)&0x1F), t&0xff]               # GPL BR within this GROM
    put(0x6000,[0xAA,0x01, len(progs),0x00]+w(0)+w(recs[0])+w(0)+w(0))   # ID, count, power-up, program list, DSR, sub
    for i,(nm,entry) in enumerate(progs):
        link=recs[i+1] if i+1<len(progs) else 0
        put(recs[i],w(link)+w(starts[i])+[len(nm)]+list(nm))
        put(starts[i],[0x07,0x20, 0xBF,0x00]+w(0x8302)+[0xBF,0x04]+w(BANK)+[0xBF,0x08]+w(entry)+br(tail)+br(tail))
        # ALL >20 ; DST >8302,@>8300 ; DST bank,@>8304 ; DST entry,@>8308 ; BR tail (twice: BR resets COND)
    put(tail,[0xBF,0x02]+w(0x04E0)+[0xBF,0x06]+w(0x0460)+[0x0F,0xF0, 0x0B, 0x00])   # DST x2 ; XML >F0 ; EXIT ; RTN
    return bytes(h)
cg=open('cartgrom_b.bin','rb').read()            # p-code GROM image >0000-F7FF
lo=cg[:4*PAGE]; hi=cg[4*PAGE:];                  assert len(lo)==4*PAGE and len(hi)<=4*PAGE
grom=boot_header()+lo+hi+b'\xff'*(4*PAGE-len(hi))
open('bootgrom.bin','wb').write(grom[:PAGE])
if os.path.exists(EX+'/UberGROM_Program.bin'):
    prog=open(EX+'/UberGROM_Program.bin','rb').read()
else:                                  # example folder gone: reuse the program block already in the shipped flash image
    prog=open(OUT+'/PCODE_AVR_FLASH.BIN','rb').read()[0x1E000:]
    print("note: %s/UberGROM_Program.bin not found, reusing the last 8K of %s/PCODE_AVR_FLASH.BIN"%(EX,OUT))
assert len(prog)==0x2000
# FLASH: disk (unit #11, ramhelp FLASHDSK + gram.s FL_READ/FL_WRITE): GROM pages 9-14 hold
# a 96-block p-System volume, shipped empty. Blocks 0-1 zero, directory (blocks 2-5) from the
# blank volume with name FLASH and end-of-volume 96, the rest erased (>FF).
FLPAGES=6
vol=bytearray(b'\xff'*(FLPAGES*PAGE)); vol[:1024]=bytes(1024)
d=bytearray(open('BLANK.DSK','rb').read()[1024:3072])
assert d[6]==5 and d[7:12]==b'BLANK' and d[16:18]==b'\0\0', "BLANK.DSK directory"
d[6:14]=bytes([5])+b'FLASH  '; d[14:16]=(FLPAGES*PAGE//512).to_bytes(2,'big')
vol[1024:3072]=d
grom=grom+bytes(vol)
assert len(grom)==15*PAGE
avr=grom+b'\xff'*(120*1024-len(grom))+prog
assert len(avr)==128*1024
open(OUT+'/PCODE_AVR_FLASH.BIN','wb').write(avr)

# 3. PCODE_AVR_EEPROM.BIN. Firmware (main.c): flags @0 with inverse @1; with bases enabled the
#    map byte for (base,slot) is at 2+base*16+slot (slot = GROM addr>>13) and its
#    inverse is 8 bytes later. Map byte = (device<<4)|page; device 1=GROM, 6=Flash.
ee=bytearray(4096)                     # 0x00 fill like the example; 00/00 pairs are invalid = unmapped
def flags(v): ee[0]=v; ee[1]=v^0xff
def mapslot(base,addr,val):
    o=2+base*16+(addr>>13); ee[o]=val; ee[o+8]=val^0xff
flags(0x05)                            # bases enabled; recovery program left enabled; rollover ON (the 15K GRAM code pool runs >7FFF->8000)
for base in (0,1):                     # same pages on base 0 and 1 (also hides REVIEW MODULE LIBRARY)
    for i,addr in enumerate((0x6000,0x8000,0xA000,0xC000,0xE000)):
        mapslot(base,addr,0x10+i)      # GROM pages 0-4 (page 0 = boot header)
for i,addr in enumerate((0x6000,0x8000,0xA000,0xC000)):
    mapslot(2,addr,0x15+i)             # GROM pages 5-8
mapslot(3,0x6000,0x00)                 # GRAM: RAM page 0 (8K) on base 3 >6000-7FFF
mapslot(3,0x8000,0x01)                 # GRAM: RAM page 1 (7K) on base 3 >8000-9BFF (>9C00-9FFF reads undriven)
mapslot(15,0xE000,0x60)                # flash controller on base 15 >E000 (as example)
for i,base in enumerate((4,5,6,7,8,10)):  # FLASH: disk: page 9+i alone at >8000 of its own base
    mapslot(base,0x8000,0x19+i)        # (not >6000: no cartridge-header scan; not base 9: GRAM buffers)
open(OUT+'/PCODE_AVR_EEPROM.BIN','wb').write(ee)
print("wrote %s: PCODE_ROM_8.BIN (%d), PCODE_AVR_FLASH.BIN (%d), PCODE_AVR_EEPROM.BIN (%d)"%(OUT,0x80000,len(avr),len(ee)))
