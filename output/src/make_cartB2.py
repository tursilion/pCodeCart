#!/usr/bin/env python3
"""
Approach B cart image (32KB, 4 banks). GROM is REAL hardware in console space
(served by the sim's --gromconsole); the cart ROM is just the 2 DSR code banks
plus a small loader bank that stages the RAM helper at boot.

  bank0 = patched DSR bank C   bank1 = patched DSR bank D
  bank2 = boot loader @6100 + ramhelp bytes @6118 (copied to 0x3A00)
  bank3 = pad

Every bank carries: header (AA + program-list ptr @6006 -> record @6008),
record @6008 (free DSR header zeros), and the tail stubs:
  ENTRY    @7FF0 : clr @6004 (select bank2) ; b @6100 (loader)
  STARTSTUB@7FF8 : clr @6000 (select bank0) ; b @6038 (real startup)
Boot flow: console -> record -> ENTRY -> (bank2) loader copies ramhelp->3A00 ->
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
    buf[0]=0xAA; buf[1]=0x01                 # header
    setw(buf,0x0006,0x6008)                  # program-list ptr -> record
    # record @6008
    setw(buf,0x0008,0x0000)                  # next = none
    setw(buf,0x000A,0x7FF0)                  # entry -> ENTRY stub
    nm=b'PSYS'; buf[0x000C]=len(nm); buf[0x000D:0x000D+len(nm)]=nm   # name "PSYS" (fits in the
    # free zero padding 0x400C-0x4011; next used word is the 0x6038 ptr at 0x6012)
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

for bk in banks: add_common(bk)

open('cartB2.bin','wb').write(b''.join(bytes(x) for x in banks))
print("wrote cartB2.bin (%d bytes, %d banks); ramhelp=%d bytes @bank2:6118 -> 3A00"%(BANKSZ*NB,NB,len(rh)))
