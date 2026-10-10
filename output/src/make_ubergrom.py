#!/usr/bin/env python3
"""Package the cart for UberGROM hardware (see output/ubergrom/UBERGROM.md).

  PCODE_ROM_8.BIN  romcart.bin padded to 512K (cart ROM, banks 0-63)
  PCODE_AVR_FLASH.BIN  GROM pages 0-7 at page*8K, padded (0xFF) to 120K, + UberGROM_Program.bin = 128K
  PCODE_AVR_EEPROM.BIN  4K configuration EEPROM: bases enabled, GROM slot map, flash controller
Run from build/ after build_cartB2.sh. Inputs from ../output/bin and ../ubergrom_example."""
import os
BIN='../output/bin'; EX='../ubergrom_example'; OUT='../output/ubergrom'
PAGE=0x2000
os.makedirs(OUT, exist_ok=True)

# 1. PCODE_ROM_8.BIN
rom=open(BIN+'/romcart.bin','rb').read()
assert len(rom)<=0x80000
open(OUT+'/PCODE_ROM_8.BIN','wb').write(rom+b'\xff'*(0x80000-len(rom)))

# 2. PCODE_AVR_FLASH.BIN: GROM pages 0-4 = base0/1 image (console >6000-FFFF),
#    pages 5-7 = base2 image (console >6000-BFFF; last page partial, 0xFF padded)
g01=open(BIN+'/grom_base0_base1.bin','rb').read(); assert len(g01)==5*PAGE
g2=open(BIN+'/grom_base2.bin','rb').read();       assert len(g2)<=3*PAGE
grom=g01+g2+b'\xff'*(3*PAGE-len(g2))
prog=open(EX+'/UberGROM_Program.bin','rb').read(); assert len(prog)==0x2000
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
flags(0x01)                            # bases enabled; recovery program left enabled; no rollover (as example)
for base in (0,1):                     # same pages on base 0 and 1 (also hides REVIEW MODULE LIBRARY)
    for i,addr in enumerate((0x6000,0x8000,0xA000,0xC000,0xE000)):
        mapslot(base,addr,0x10+i)      # GROM pages 0-4
for i,addr in enumerate((0x6000,0x8000,0xA000)):
    mapslot(2,addr,0x15+i)             # GROM pages 5-7
mapslot(15,0xE000,0x60)                # flash controller on base 15 >E000 (as example)
open(OUT+'/PCODE_AVR_EEPROM.BIN','wb').write(ee)
print("wrote %s: PCODE_ROM_8.BIN (%d), PCODE_AVR_FLASH.BIN (%d), PCODE_AVR_EEPROM.BIN (%d)"%(OUT,0x80000,len(avr),len(ee)))
