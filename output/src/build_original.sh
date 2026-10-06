#!/bin/bash
# Reassemble the ORIGINAL p-code card ROMs byte-identical from three linked pieces:
#   shared.s (>4000-4FFF, common) + c5.s (>5000-5FFF bank C) / d5.s (bank D).
# Verifies against PCardC.ROM / PCardD.ROM. This is the faithful baseline that the
# optimization+conversion work will edit.  Requires cov_boot.txt (sim coverage).
set -e
BIN=~/newtms9900-gcc/newgcc9900/bin
AS=$BIN/tms9900-as; LD=$BIN/tms9900-ld; OC=$BIN/tms9900-objcopy
cd "$(dirname "$0")"

# 1. slice original ROMs into the three regions
python3 - <<'PY'
C=open('../PCardC.ROM','rb').read(); D=open('../PCardD.ROM','rb').read()
open('shared.bin','wb').write(C[0:0x1000])
open('c5.bin','wb').write(C[0x1000:0x2000])
open('d5.bin','wb').write(D[0x1000:0x2000])
PY

# 2a. collect reference targets PER SECTION (banked halves must not cross-contaminate:
#     52xx in bank C is different code than 52xx in bank D).
rm -f refs_shared.txt refs_c5.txt refs_d5.txt
python3 reasm.py shared.bin 0x4000 C cov_boot.txt collect refs_shared.txt 0x4038 0x4044
python3 reasm.py c5.bin    0x5000 C cov_boot.txt collect refs_c5.txt
python3 reasm.py d5.bin    0x5000 D cov_boot.txt collect refs_d5.txt
# shared gets 4xxx refs from everyone; each banked half gets 5xxx refs from itself + shared.
cat refs_shared.txt refs_c5.txt refs_d5.txt | sort -u > lbl_shared.txt
cat refs_c5.txt refs_shared.txt | sort -u > lbl_c5.txt
cat refs_d5.txt refs_shared.txt | sort -u > lbl_d5.txt

# 2b. emit each region with its correct label set
python3 reasm.py shared.bin 0x4000 C cov_boot.txt emit lbl_shared.txt 0x4038 0x4044 > shared.s
python3 reasm.py c5.bin    0x5000 C cov_boot.txt emit lbl_c5.txt          > c5.s
python3 reasm.py d5.bin    0x5000 D cov_boot.txt emit lbl_d5.txt          > d5.s

# 3. assemble
$AS shared.s -o shared.o
$AS c5.s -o c5.o
$AS d5.s -o d5.o

# 4. link the two bank images (shared @4000, banked half @5000) and extract binary
$LD -Ttext=0x4000 shared.o c5.o -o imgC.elf 2>/dev/null
$LD -Ttext=0x4000 shared.o d5.o -o imgD.elf 2>/dev/null
$OC -O binary imgC.elf imgC.bin
$OC -O binary imgD.elf imgD.bin

# 5. verify byte-identical
python3 - <<'PY'
import sys
def chk(a,b,n):
    x=open(a,'rb').read(); y=open(b,'rb').read()
    if x==y: print("OK  %s == %s (byte-identical)"%(a,b))
    else: print("FAIL %s != %s"%(a,b)); sys.exit(1)
chk('imgC.bin','../PCardC.ROM','C')
chk('imgD.bin','../PCardD.ROM','D')
PY
echo "Original ROMs reassembled byte-identical."
