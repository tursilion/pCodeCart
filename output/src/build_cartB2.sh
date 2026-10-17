#!/bin/bash
# APPROACH B: real GROM in console space. Cart = 2 DSR code banks + loader bank.
# DSR GROM-access converted to console ports via patchdsr + RAM helpers (ramhelp).
set -e
# COV = disassembly coverage (cov_bc.txt = boot shared-col + boot|compile bank-cols, so the
#   compiler's bank-C/D scanner code disassembles as code & relocates its operands, while
#   the shared region stays boot-only to keep its blwp vectors / HALT path as data).
#   Regenerate: cov_bc.txt from cov_boot.txt + cov_comp.txt (baseline compile coverage).
# PTRCOV = cov_ptr.txt (boot+editor) for reasm data-pointer validation.
export PTRCOV=${PTRCOV:-cov_ptr.txt}
BIN=~/newtms9900-gcc/newgcc9900/bin
AS=$BIN/tms9900-as; LD=$BIN/tms9900-ld; OC=$BIN/tms9900-objcopy
cd "$(dirname "$0")"

# 1. reasm + link the two DSR code banks (same pipeline as cartA)
python3 - <<'PY'
C=open('../PCardC.ROM','rb').read(); D=open('../PCardD.ROM','rb').read()
open('shared.bin','wb').write(C[0:0x1000]); open('c5.bin','wb').write(C[0x1000:0x2000]); open('d5.bin','wb').write(D[0x1000:0x2000])
PY
rm -f refs_shared.txt refs_c5.txt refs_d5.txt
python3 reasm.py shared.bin 0x4000 C ${COV:-cov_bc.txt} collect refs_shared.txt 0x4038 0x4044
python3 reasm.py c5.bin 0x5000 C ${COV:-cov_bc.txt} collect refs_c5.txt
python3 reasm.py d5.bin 0x5000 D ${COV:-cov_bc.txt} collect refs_d5.txt
cat refs_shared.txt refs_c5.txt refs_d5.txt | sort -u > lbl_shared.txt
cat refs_c5.txt refs_shared.txt | sort -u > lbl_c5.txt
cat refs_d5.txt refs_shared.txt | sort -u > lbl_d5.txt
python3 reasm.py shared.bin 0x4000 C ${COV:-cov_bc.txt} emit lbl_shared.txt 0x4038 0x4044 > shared.s
python3 reasm.py c5.bin 0x5000 C ${COV:-cov_bc.txt} emit lbl_c5.txt > c5.s
python3 reasm.py d5.bin 0x5000 D ${COV:-cov_bc.txt} emit lbl_d5.txt > d5.s
$AS shared.s -o shared.o; $AS c5.s -o c5.o; $AS d5.s -o d5.o
$LD -Ttext=0x6000 shared.o c5.o -o bank0.elf 2>/dev/null
$LD -Ttext=0x6000 shared.o d5.o -o bank1.elf 2>/dev/null
$OC -O binary bank0.elf bank0.full; $OC -O binary bank1.elf bank1.full
python3 -c "open('bank0.bin','wb').write(open('bank0.full','rb').read()[:0x2000])"
python3 -c "open('bank1.bin','wb').write(open('bank1.full','rb').read()[:0x2000])"

# 2. RAM helper (loaded to 0x3A00 at boot)
$AS ramhelp.s -o ramhelp.o
$LD -Ttext=0x3A00 ramhelp.o -o ramhelp.elf 2>/dev/null
$OC -O binary ramhelp.elf ramhelp.bin
# 2b. GRAM code pool routines for cart bank 3 (uses RAM helper symbols)
# (an undefined symbol silently assembles as 0 with this toolchain, so pass RET_B0 in)
RET_B0=0x$($BIN/tms9900-nm ramhelp.elf | awk '$3=="RET_B0"{print $1}')
$AS --defsym RET_B0=$RET_B0 gram.s -o gram.o
$LD -Ttext=0x6100 gram.o -o gram.elf 2>/dev/null
$OC -O binary gram.elf gram.bin

# 3. patch DSR banks (startup ports + address-set trampolines to RAM helpers)
python3 patchdsr.py

# 4. GROM: ROM-refs relocate +0x2000 (DSR at 6000-7FFF) + reseed r13 5BFC->9800
GROMCONSOLE=1 python3 patchgrom.py >/dev/null

# 5. assemble the cart image + loader
python3 make_cartB2.py
python3 add_romdisk.py
# 6. UberGROM package (the only build target): ../output/ubergrom/PCODE_*.BIN
python3 make_ubergrom.py
echo "cart built: romcart.bin + cartgrom_b.bin -> ../output/ubergrom"
