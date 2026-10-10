#!/bin/bash
# Regression smoke tests for the ROM-disk cart (romcart.bin + console GROMs) in ti99sim.
# Uses only one data disk (output/bin/DATA.DSK); all system files come from ROM drive #12.
# Run from build/ after ./build_cartB2.sh.  Prints the non-blank screen lines of each test.
cd "$(dirname "$0")"
DSK=${DSK:-../output/bin/DATA.DSK}
S="./ti99sim --cart romcart.bin --gromconsole --grom cartgrom_b.bin --disk $DSK --nodsr --int-until-entry --catchexec"
scr(){ grep -E "CATCH|HALT|APP STARTED|^ *[0-9]+\|" | grep -vE '^ *[0-9]+\| *$'; }
keys(){ K="$1"; t=$2; shift 2; for c in "$@"; do K="$K,$t:$c"; t=$((t+300)); done; echo "$K"; }
spell(){ echo "$1" | sed 's/./& /g'; }

echo "--- boot";        $S --keysched "50:_,100:2" --max 30000000 2>&1 | scr
echo "--- F V";         $S --keysched "50:_,100:2,300:F,700:V" --max 60000000 2>&1 | scr
echo "--- E";           $S --keysched "50:_,100:2,5000:E" --max 40000000 2>&1 | scr
echo "--- E,Enter,Q";   $S --keysched "50:_,100:2,5000:E,9000:~,13000:Q" --max 60000000 2>&1 | scr
echo "--- E,Enter,Q,E"; $S --keysched "50:_,100:2,5000:E,9000:~,13000:Q,17000:E" --max 70000000 2>&1 | scr | head -3
echo "--- E delete+left arrow (old crash), ESC, Q, E"
$S --keysched "50:_,100:2,5000:E,9000:~,13000:D,17000:x88,21000:x03,25000:Q,29000:E" --max 120000000 2>&1 | scr | head -5
echo "--- C #4:HELLO -> #4:HW"
K=$(keys "50:_,100:2,5000:C" 7000 '#' 4 : H E L L O '~'); K=$(keys "$K" 13000 '#' 4 : H W '~')
$S --keysched "$K" --max 400000000 2>&1 | scr
echo "--- X #4:HW"; $S --keysched "$(keys "50:_,100:2,5000:X" 7000 $(spell '#4:HW') '~')" --max 150000000 2>&1 | scr | head -8
echo "--- X #4:BM (needs SYSTEM.LIBRARY on root volume)"
$S --keysched "$(keys "50:_,100:2,5000:X" 7000 $(spell '#4:BM') '~')" --max 200000000 2>&1 | scr | head -8
for k in A L; do echo "--- $k"; $S --keysched "50:_,100:2,5000:$k" --max 60000000 2>&1 | scr | head -4; done
