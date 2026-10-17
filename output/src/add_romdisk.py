#!/usr/bin/env python3
"""Append the ROM disk image to the cart.
cartB2.bin = banks 0-3 (existing cart). BigCombinedDsk.dsk is split into 8K banks starting
at bank 4 (bank n selected by a write to 0x6000+2n; RD2READ uses 0x6008 + 2*page).
32 x 256-byte sectors per bank. Padded to a power-of-2 bank count with copies of bank3 (ENTRY/STARTSTUB stubs).
No bank may start with >AA (the boot header is in GROM); checked below."""
BANKSZ=0x2000
cart=open('cartB2.bin','rb').read()
dsk=open('../BigCombinedDsk.dsk','rb').read()
assert len(cart)==4*BANKSZ
nd=(len(dsk)+BANKSZ-1)//BANKSZ
data=dsk+bytes(nd*BANKSZ-len(dsk))
banks=[cart[i*BANKSZ:(i+1)*BANKSZ] for i in range(4)]+[data[i*BANKSZ:(i+1)*BANKSZ] for i in range(nd)]
total=1
while total<len(banks): total<<=1
pad=total-len(banks)
banks+= [cart[3*BANKSZ:4*BANKSZ]]*pad
assert all(b[0]!=0xAA for b in banks), 'a ROM bank starts with >AA'
open('romcart.bin','wb').write(b''.join(banks))
print("wrote romcart.bin: %d bytes, %d banks (0-3 cart, 4-%d disk = %d sectors, %d pad)"%(
      total*BANKSZ,total,3+nd,len(dsk)//256,pad))
