#!/bin/bash
# MILESTONE A: relocate DSR ROM to >6000-7FFF (paged cart), patch GROM ROM-refs
# +0x2000 and its CRU sequences -> ROM writes. GROM DATA still served via ports
# (sim --ports). Verify boots to the Command: prompt via the cart menu.
set -e
BIN=~/newtms9900-gcc/newgcc9900/bin
AS=$BIN/tms9900-as; LD=$BIN/tms9900-ld; OC=$BIN/tms9900-objcopy
cd "$(dirname "$0")"

# 1. symbolic sources + collect refs (reuse the byte-identical pipeline's outputs)
python3 - <<'PY'
C=open('../PCardC.ROM','rb').read(); D=open('../PCardD.ROM','rb').read()
open('shared.bin','wb').write(C[0:0x1000]); open('c5.bin','wb').write(C[0x1000:0x2000]); open('d5.bin','wb').write(D[0x1000:0x2000])
PY
rm -f refs_shared.txt refs_c5.txt refs_d5.txt
python3 reasm.py shared.bin 0x4000 C cov_boot.txt collect refs_shared.txt 0x4038 0x4044
python3 reasm.py c5.bin 0x5000 C cov_boot.txt collect refs_c5.txt
python3 reasm.py d5.bin 0x5000 D cov_boot.txt collect refs_d5.txt
cat refs_shared.txt refs_c5.txt refs_d5.txt | sort -u > lbl_shared.txt
cat refs_c5.txt refs_shared.txt | sort -u > lbl_c5.txt
cat refs_d5.txt refs_shared.txt | sort -u > lbl_d5.txt
python3 reasm.py shared.bin 0x4000 C cov_boot.txt emit lbl_shared.txt 0x4038 0x4044 > shared.s
python3 reasm.py c5.bin 0x5000 C cov_boot.txt emit lbl_c5.txt > c5.s
python3 reasm.py d5.bin 0x5000 D cov_boot.txt emit lbl_d5.txt > d5.s
$AS shared.s -o shared.o; $AS c5.s -o c5.o; $AS d5.s -o d5.o

# 2. RELOCATE: link shared@0x6000 (0x1000 long) then banked half at 0x7000.
#    Symbols L4xxx -> 6xxx, L5xxx -> 7xxx automatically.
$LD -Ttext=0x6000 shared.o c5.o -o bank0.elf 2>/dev/null
$LD -Ttext=0x6000 shared.o d5.o -o bank1.elf 2>/dev/null
$OC -O binary bank0.elf bank0.full; $OC -O binary bank1.elf bank1.full
# extract the 0x2000 image (linked binary starts at offset 0 == addr 0x6000)
python3 -c "open('bank0.bin','wb').write(open('bank0.full','rb').read()[:0x2000])"
python3 -c "open('bank1.bin','wb').write(open('bank1.full','rb').read()[:0x2000])"

# 3. patch GROM (CRU->ROM writes, ROM-refs +0x2000)
python3 patchgrom.py >/dev/null

# 4. assemble cart image with header/entry
python3 make_cart.py
echo "Milestone A cart built: cartA.bin + cartgrom.bin"
