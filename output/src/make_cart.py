#!/usr/bin/env python3
"""
Assemble the final paged-cart image from the relocated bank images.
 - bank0.bin = shared@6000 + c5@7000 (8K)   -> cart bank 0 (code C)
 - bank1.bin = shared@6000 + d5@7000 (8K)   -> cart bank 1 (code D)
Adds a cartridge program-chain header so the console menu lists & starts it:
 - header program-ptr (offset 6, in shared -> present in both banks) -> record
 - record + entry stub placed at the shared tail free space (identical in both
   banks) so boot works from either power-on bank; entry does clr @>6000 then
   b @>6038 (the relocated startup, was >4038).
Output: cartA.bin (16K, 2 banks).  (Milestone A: GROM data still via ports.)
"""
import sys
b0=bytearray(open('bank0.bin','rb').read())
b1=bytearray(open('bank1.bin','rb').read())
assert len(b0)==0x2000 and len(b1)==0x2000

# free tail region present (zero) in BOTH banks' c5/d5 halves: 0x1FEC-0x1FFF
# (c5 tail 7FEC-7FFF=20B free; d5 tail 7FD2-7FFF=46B free). Use 0x1FEC..0x1FFF.
REC=0x1FEC   # offset of program record (addr 0x7FEC)
def setw(buf,off,v): buf[off]=(v>>8)&0xff; buf[off+1]=v&0xff
def layout(buf):
    a=0x7FEC
    setw(buf,REC+0,0x0000)      # next program = none
    setw(buf,REC+2,0x7FF8)      # entry point -> stub
    buf[REC+4]=6                # name length
    buf[REC+5:REC+11]=b'PASCAL'
    buf[REC+11]=0               # pad
    # entry stub at 0x7FF8
    setw(buf,0x1FF8,0x04E0); setw(buf,0x1FFA,0x6000)   # clr @>6000  (select bank0)
    setw(buf,0x1FFC,0x0460); setw(buf,0x1FFE,0x6038)   # b   @>6038  (relocated startup)
    # header program-chain pointer at 6006 (offset 6) -> record
    setw(buf,0x0006,0x7FEC)
    setw(buf,0x0004,0x0000)   # zero stale powerup ptr (cart uses program chain)
for buf in (b0,b1):
    # sanity: tail must be free (zero) where we write
    if any(buf[REC:0x2000]):
        sys.stderr.write("WARN cart tail 0x1FEC-1FFF not all zero; overwriting\n")
    layout(buf)

open('cartA.bin','wb').write(bytes(b0)+bytes(b1))
print("wrote cartA.bin (%d bytes, 2 banks)"%(len(b0)+len(b1)))
print("  header@6006 -> record@7FEC -> entry@7FF8 (clr @6000; b @6038)")
