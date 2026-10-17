#!/bin/bash
# Regression smoke tests for the UberGROM cart in ti99sim.
# No p-System files on floppy: everything comes from ROM drive #12. The disk controller is
# always present. Most tests run with no disk inserted; the edit/compile/run tests use a blank
# p-System disk (build/BLANK.DSK, volume BLANK:, no files) to save and compile code.
# Disk writes stay in sim memory, so BLANK.DSK is never changed.
# Run from build/ after ./build_cartB2.sh.  Prints the non-blank screen lines of each test.
cd "$(dirname "$0")"
set -f                 # keysched strings contain '*' etc.
U=../output/ubergrom   # the UberGROM package (512K ROM + AVR flash + EEPROM), decoded like the firmware
S="./ti99sim --cart $U/PCODE_ROM_8.BIN --ubergrom $U/PCODE_AVR_FLASH.BIN $U/PCODE_AVR_EEPROM.BIN --nodsr --int-until-entry --catchexec"
B="$S --disk BLANK.DSK"
scr(){ grep -E "CATCH|HALT|APP STARTED|flash controller|^ *[0-9]+\|" | grep -vE '^ *[0-9]+\| *$'; }
keys(){ K="$1"; t=$2; shift 2; for c in "$@"; do K="$K,$t:$c"; t=$((t+300)); done; echo "$K"; }
typ(){ echo "$1" | sed 's/ /_/g; s/./& /g; s/,/x2C/g'; }   # ',' separates keysched entries

echo "=== no disk"
echo "--- boot";        $S --keysched "50:_,100:2" --max 30000000 2>&1 | scr
echo "--- F V";         $S --keysched "50:_,100:2,300:F,700:V" --max 60000000 2>&1 | scr
echo "--- E";           $S --keysched "50:_,100:2,5000:E" --max 40000000 2>&1 | scr
echo "--- E,Enter,Q";   $S --keysched "50:_,100:2,5000:E,9000:~,13000:Q" --max 60000000 2>&1 | scr
echo "--- E,Enter,Q,E"; $S --keysched "50:_,100:2,5000:E,9000:~,13000:Q,17000:E" --max 70000000 2>&1 | scr | head -3
echo "--- E delete+left arrow (old crash), ESC, Q, E"
$S --keysched "50:_,100:2,5000:E,9000:~,13000:D,17000:x88,21000:x03,25000:Q,29000:E" --max 120000000 2>&1 | scr | head -5
echo "--- F G Ctrl-C G A B (READLN EOF fix; hung before)"
$S --keysched "50:_,100:2,3000:F,6000:G,9000:x03,12000:G,15000:A,15300:B" --max 80000000 2>&1 | scr | head -2
for k in A L; do echo "--- $k"; $S --keysched "50:_,100:2,5000:$k" --max 60000000 2>&1 | scr | head -4; done
echo "--- charset (pattern table >0000-07FF; the screen dump above can't see font loss)"
$S --keysched "50:_,100:2" --snap 478 --snapkscan 400 --max 30000000 >/dev/null 2>&1
python3 -c "
v=open('snap_vram.bin','rb').read()
print(' A=%s 0=%s nonzero=%d/2048'%(v[0x208:0x210].hex(),v[0x180:0x188].hex(),sum(1 for b in v[:0x800] if b)))"
rm -f snap_vram.bin snap_ram.bin snap_hram.bin

echo "=== 80 column boot (menu 3; --vdp80 = F18A/V9938-style registers)"
echo "--- menu";        $S --keysched "50:_" --screenkscan 90 --max 30000000 2>&1 | scr | sed -n 5,7p
echo "--- F V (80)";    $S --vdp80 --keysched "50:_,100:3,300:F,700:V" --max 60000000 2>&1 | grep -E "nametable" ; $S --vdp80 --keysched "50:_,100:3,300:F,700:V" --max 60000000 2>&1 | scr
K=$(keys "50:_,100:3,5000:E,9000:~,13000:I" 15000 $(typ "PROGRAM WIDE;BEGIN WRITELN('OVER FORTY COLUMNS, ENDS AT COL 70') END.{"))
echo "--- E, type a 70 column line (80)"; $S --vdp80 --keysched "$K" --max 150000000 2>&1 | scr

echo "=== blank disk #4:BLANK"
echo "--- F V";         $B --keysched "50:_,100:2,300:F,700:V" --max 60000000 2>&1 | scr
# Type the program in the editor (ETX = accept), Q W #4:HELLO, E(xit)
K=$(keys "50:_,100:2,5000:E,9000:~,13000:I" 15000 $(typ "PROGRAM HELLO;BEGIN WRITELN('HELLO WORLD');WRITELN(1.5*2.0) END."))
K="$K,35500:x03,37000:Q,39000:W"; K=$(keys "$K" 41000 $(typ "#4:HELLO") '~')
echo "--- E, type HELLO, Q W #4:HELLO"; $B --keysched "$K" --max 120000000 2>&1 | scr
K="$K,46000:E,50000:C"; K=$(keys "$K" 52000 $(typ "#4:HELLO") '~'); K=$(keys "$K" 58000 $(typ "#4:HW") '~')
echo "--- C #4:HELLO -> #4:HW"; $B --keysched "$K" --max 450000000 2>&1 | scr
K="$K,86000:X"; K=$(keys "$K" 88000 $(typ "#4:HW") '~')
echo "--- X #4:HW (string + real constant)"; $B --keysched "$K" --max 550000000 2>&1 | scr | head -8

echo "=== TIPI present (DSR built from ../tipi_dsr, Pi handshake waits NOPed: the card answers but no Pi)"
T=../tipi_dsr/bin/tipi_src_nowait.bin
if [ -f $T ]; then
echo "--- TIPI >1800, no TI controller: E (crashed before the INITCOD VTOPFIX)"
$S --nodisk --tipi $T 1800 --keysched "50:_,100:2,5000:E" --max 40000000 2>&1 | scr
echo "--- TIPI >1800, no TI controller: F V (no Pi: disk units offline, no crash)"
$S --nodisk --tipi $T 1800 --keysched "50:_,100:2,300:F,700:V" --max 60000000 2>&1 | scr
echo "--- TIPI >1800 + TI controller (BLANK): F V"
$B --tipi $T 1800 --keysched "50:_,100:2,300:F,700:V" --max 60000000 2>&1 | scr
else echo "(skipped: $T not found)"; fi

echo "=== FLASH: #11 (UberGROM flash pages 9-14, no floppy; the sim keeps flash writes in memory)"
K=$(keys "50:_,100:2,5000:E,9000:~,13000:I" 15000 $(typ "PROGRAM HELLO;BEGIN WRITELN('HELLO WORLD');WRITELN(1.5*2.0) END."))
K="$K,35500:x03,37000:Q,39000:W"; K=$(keys "$K" 41000 $(typ "#11:HELLO") '~')
echo "--- E, type HELLO, Q W #11:HELLO";  $S --keysched "$K" --max 120000000 2>&1 | scr
echo "--- same, flash write-protected (--ugwp)"; $S --ugwp --keysched "$K" --max 120000000 2>&1 | scr
K="$K,46000:E,50000:C"; K=$(keys "$K" 52000 $(typ "#11:HELLO") '~'); K=$(keys "$K" 58000 $(typ "#11:HW") '~')
echo "--- C #11:HELLO -> #11:HW"; $S --keysched "$K" --max 450000000 2>&1 | scr
K="$K,86000:X"; K=$(keys "$K" 88000 $(typ "#11:HW") '~')
echo "--- X #11:HW"; $S --keysched "$K" --max 550000000 2>&1 | scr | head -3
K="$K,95000:F,98000:L"; K=$(keys "$K" 100000 $(typ "#11:") '~')
echo "--- F L #11:"; $S --keysched "$K" --max 650000000 2>&1 | scr
