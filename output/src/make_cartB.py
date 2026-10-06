#!/usr/bin/env python3
"""
MILESTONE B cart image: 16 banks x 8KB = 128KB.
  bank 0      = shared@6000 + c5@7000  (code C)      [from bank0.bin]
  bank 1      = shared@6000 + d5@7000  (code D)      [from bank1.bin]
  bank 2+N    = p-code GROM chip N data (6KB, 0x0000-0x17FF), shifted to offset
                HOFF so the >6000 cart header survives   [from cartgrom.bin]
  bank 10-15  = padding (header+entry only, bootable)

Every bank carries an identical cart header at >6000 (AA + program-list ptr) and
an identical "shared tail" at the top of the bank (program record + entry stub;
the GROM read/set bank-switch stubs will also live here later).  The GROM read
stub reads a data byte from  6000 + HOFF + (PGADDR & 0x1FFF)  after switching the
window to bank 2+(PGADDR>>13); HOFF must clear the header.

For now (foundation step) the code banks keep their Milestone-A header/record/entry
(make_cart.py already placed those in bank0/bank1.bin); we only add the GROM data
banks and padding.  The read/set stubs + tail replication come next.
"""
import sys

HOFF = 0x08          # GROM data shift: header occupies 6000-6007, data starts 6008
NBANKS = 16
BANKSZ = 0x2000

b0=bytearray(open('bank0.bin','rb').read())
b1=bytearray(open('bank1.bin','rb').read())
grom=open('cartgrom.bin','rb').read()      # relocated GROM (data <E000 identical to original)
assert len(b0)==BANKSZ and len(b1)==BANKSZ

def setw(buf,off,v): buf[off]=(v>>8)&0xff; buf[off+1]=v&0xff
def add_header_and_tail(buf):
    # cart program-chain header + record + entry stub (same as make_cart.py, Milestone A)
    REC=0x1FEC
    setw(buf,REC+0,0x0000)            # next program = none
    setw(buf,REC+2,0x7FF8)            # entry point -> stub
    buf[REC+4]=6; buf[REC+5:REC+11]=b'PASCAL'; buf[REC+11]=0
    setw(buf,0x1FF8,0x04E0); setw(buf,0x1FFA,0x6000)   # clr @>6000 (select bank0)
    setw(buf,0x1FFC,0x0460); setw(buf,0x1FFE,0x6038)   # b   @>6038 (relocated startup)
    setw(buf,0x0006,0x7FEC)           # header program-list ptr -> record
    setw(buf,0x0004,0x0000)           # zero stale powerup ptr
    buf[0]=0xAA; buf[1]=0x01          # valid header

banks=[bytearray(BANKSZ) for _ in range(NBANKS)]
banks[0][:]=b0
banks[1][:]=b1
add_header_and_tail(banks[0]); add_header_and_tail(banks[1])
TAIL=banks[0][0x1FEC:0x2000]          # record + entry stub, replicate into every bank

# GROM chips 0..7 -> banks 2..9, 6KB data at offset HOFF
CHIP=0x2000; USED=0x1800
for n in range(8):
    src=grom[n*CHIP : n*CHIP+USED]
    dst=banks[2+n]
    dst[HOFF:HOFF+len(src)]=src
    # minimal cart header so any bank is a valid bootable cart (AA + program-list ptr)
    dst[0]=0xAA; dst[1]=0x01
    setw(dst,6,0x7FEC)                 # program-list ptr -> record in tail
    dst[0x1FEC:0x2000]=TAIL            # replicate record+entry stub (survives bank switch, bootable)

# padding banks 10..15: header + a copy of the code-bank tail so power-on is safe
for n in range(10,NBANKS):
    dst=banks[n]
    dst[0]=0xAA; dst[1]=0x01; setw(dst,6,0x7FEC)
    dst[0x1FEC:0x2000]=TAIL                 # replicate record+entry stub from bank0 tail

out=b''.join(bytes(x) for x in banks)
open('cartB.bin','wb').write(out)
print("wrote cartB.bin (%d bytes, %d banks, HOFF=0x%X)"%(len(out),NBANKS,HOFF))
print("  banks: 0=codeC 1=codeD 2-9=GROM chips0-7@HOFF 10-15=pad")
