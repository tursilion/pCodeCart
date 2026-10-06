#!/usr/bin/env python3
"""
Patch the p-code GROM for the cartridge conversion (from the UNTOUCHED original):
  1. Convert GROM-embedded CRU sequences to paged-ROM equivalents:
       020C 1F00 1D00/1E00  (card on/off)  -> 1000 1000 1000  (nops; cart always live)
       020C 1F80 1E00       (bank C / 0)    -> 04E0 6000 1000  (clr @>6000 -> bank0)
       020C 1F80 1D00       (bank D / 1)    -> 04E0 6002 1000  (clr @>6002 -> bank1)
  2. Relocate GROM's hardcoded references INTO the DSR ROM by +0x2000
     (>4xxx->>6xxx, >5xxx->>7xxx), because the ROM moves to >6000-7FFF.
     Conservative: only b/bl (>0460/>06A0) with in-range operand for now; the sim
     boot test reveals any other forms (li/mov) to add.
Outputs cartgrom.bin. Reports all edits.
"""
import sys
g=bytearray(open('../p1f00g_0000_f800.GRM','rb').read())
def w(i): return (g[i]<<8)|g[i+1]
def setw(i,v): g[i]=(v>>8)&0xff; g[i+1]=v&0xff

# Hardware I/O ports living in the >4000-5FFF window that must NEVER be relocated:
# the p-code GROM data/address ports (>5BFC/>5BFE/>5FFC/>5FFE) are fixed device
# addresses, not DSR-ROM references (e.g. `li r13,>5BFC` sets the GROM read port).
PORTS={0x5bfc,0x5bfe,0x5ffc,0x5ffe}

# --- 1. CRU sequences (word-aligned scan) ---
# ONLY convert the p-code card's OWN bank switching (CRU >1F80) to ROM writes.
# Do NOT touch >1F00 (card on/off): those bytes are ALSO used by the DSR-scan loop
# as its CRU-base setup (li r12,>1F00; sbz 0), and on a cart the 1F00 CRU ops are
# harmless no-ops anyway (no card there). Neutralizing them breaks the scan.
CRU={
 (0x020C,0x1F80,0x1E00):(0x04E0,0x6000,0x1000,'bankC/0->clr @6000'),
 (0x020C,0x1F80,0x1D00):(0x04E0,0x6002,0x1000,'bankD/1->clr @6002'),
}
cru_hits={}
i=0
while i<len(g)-5:
    key=(w(i),w(i+2),w(i+4))
    if key in CRU:
        a,b,c,desc=CRU[key]
        setw(i,a); setw(i+2,b); setw(i+4,c)
        cru_hits[desc]=cru_hits.get(desc,0)+1
        i+=6
    else:
        i+=2
print("CRU sequence edits:",cru_hits)

# --- 2. relocate ROM-refs +0x2000 ---
# Properly decode each instruction's operand extension-word positions and relocate
# EVERY symbolic @operand (incl. 2nd operand of dual-op) that targets [4000,5fff].
# Restricted to the GROM7 code region (>=0xE000) to avoid p-code data false positives.
def extpositions(op, i):
    """return (length, [ext_word_offsets]) for the instruction at offset i."""
    top4=op>>12
    if top4>=4:  # format I dual
        Ts=(op>>4)&3; S=op&0xF; Td=(op>>10)&3; D=(op>>6)&0xF
        pos=[]; p=i+2
        if Ts==2 and S==0: pos.append(p); p+=2
        if Td==2 and D==0: pos.append(p); p+=2
        return p-i, pos
    top6=op>>10
    if top6 in (0x08,0x09,0x0a,0x0b,0x0c,0x0d,0x0e,0x0f):  # iii/iv/mpy/div/xop
        Ts=(op>>4)&3; S=op&0xF
        if Ts==2 and S==0: return 4,[i+2]
        return 2,[]
    top8=op>>8
    if 0x10<=top8<=0x1f: return 2,[]      # jumps / cru single-bit
    top12=op>>4
    if top12 in (0x020,0x022,0x024,0x026,0x028,0x02e,0x030): return 4,[i+2]  # imm
    if top12 in (0x02a,0x02c): return 2,[]  # stwp/stst
    if op in (0x0340,0x0360,0x0380,0x03a0,0x03c0,0x03e0): return 2,[]  # format VII
    top8b=op>>8
    if top8b in (0x08,0x09,0x0a,0x0b): return 2,[]  # shifts
    top10=op>>6
    if top10 in range(0x10,0x1e):  # single-operand
        Ts=(op>>4)&3; S=op&0xF
        if Ts==2 and S==0: return 4,[i+2]
        return 2,[]
    return 2,[]

reloc=0; samples=[]
# Load GROM code-start coverage (from copy-provenance) and valid ROM targets.
gromcode=set(int(x,16) for x in open('gromcov_boot.txt'))
romtgt=set(int(x,16) for x in open('rom_targets.txt'))

# mark the DSR-SCAN code region as NO-RELOCATE: its `cb @2cac,@4000` / `mov @400c`
# read EXTERNAL cards via CRU selection, and its `li r12,1F00; sbz` is scan setup.
noreloc=[False]*len(g)
scansig=bytes([0x1e,0x00,0x02,0x2c,0xff,0x00,0x02,0x8c,0x0f,0x00])
si=g.find(scansig)
while si>=0:
    for k in range(si-8, si+0x22):        # cover li r12,1F00;sbz .. cb@4000 .. mov@400c
        if 0<=k<len(g): noreloc[k]=True
    si=g.find(scansig, si+1)

# The DSR-scan compares each candidate card's first ROM byte against the expected
# header value >AA held at RAM >2CAC.  Every >4xxx/>5xxx reference feeding such a
# compare (`cb @2cac,@4000`, or `li rX,>4000; cb *rX,@2cac`) points at the EXTERNAL
# PEB card window selected via CRU, NOT the p-code card's own ROM, so it must stay
# at >4000.  Protecting a small window around each @>2CAC operand catches all scan
# loop variants (the fixed scansig above only matched one of them).
HDRCONST=0x2CAC
for i in range(0xE000,len(g)-1,2):
    if w(i)==HDRCONST:                     # >2CAC used as an instruction operand
        for k in range(i-8, i+4):          # cover a preceding `li rX,>4000` + the compare
            if 0<=k<len(g): noreloc[k]=True

# The compiler's reserved-word (keyword) table at GROM 0xF30C-0xF4CB is ASCII strings
# (loaded to RAM 0x30xx-0x32xx): a dummy "@@@@@@@@" then AND, ARRAY, .. PROGRAM .. WITH,
# each an 8-char space-padded name + a value byte, 0x0F-separated. Those bytes form words
# in 0x4000-0x5FFF (e.g. "PR"=0x5052, "OG"=0x4F47) that the table/code relocation passes
# wrongly treat as ROM pointers and +0x2000 -> "PROGRAM" becomes "pRoGrAm", so the lexer
# can't recognise any keyword and every compile fails with "'PROGRAM' or 'UNIT' expected".
# This is DATA, never relocated.  (Bounds verified against the expert disassembly: pointer
# table ends at 0xF30B pointing into RAM 0x30xx; real code resumes at 0xF4CC.)
KWLO,KWHI=0xF30C,0xF4CC
for k in range(KWLO,KWHI):
    if 0<=k<len(g): noreloc[k]=True

# 2a. detect VALID dispatch-table regions (pointer runs whose entries are valid ROM
#     targets or RAM/zero) and relocate their in-range entries. Mark istable.
def ptrish(x): return x==0 or (0x2000<=x<=0x3fff) or (0x4000<=x<=0x5fff and x in romtgt and x not in PORTS)
# Loose table-pointer test: any DSR-ROM code pointer (excl the >4000-403F header and
# ports) or RAM pointer or 0 (table gap).  Used only for LONG runs, where a run of
# many consecutive pointer-like words is unambiguously a dispatch table even if the
# individual handler entry points are not otherwise-referenced ROM targets.
def tblptr(x): return x==0 or (0x2000<=x<=0x3fff) or (0x4040<=x<=0x5fff and x not in PORTS)
CLO,CHI=0xE808,0xF7FA          # GROM7 code+table region (from gromcov E809..F7F9)
istable=[False]*len(g); tblc=0
i=CLO
while i<CHI:
    if ptrish(w(i)) and w(i)!=0 and not noreloc[i] and (ptrish(w(i+2)) or (i>=2 and ptrish(w(i-2)))):
        s=i
        while i<CHI and ptrish(w(i)) and not noreloc[i]: i+=2
        if (i-s)>=6:                       # >=3 words (avoids flagging instr operands)
            for p in range(s,i,2): istable[p]=True
        # else not a table
    else: i+=2
# Long-run detector: the interpreter's opcode dispatch tables (e.g. the 256-entry
# main table at >F02E) are runs of handler pointers whose entries are NOT in romtgt,
# so the strict pass above misses them.  A run of >=6 consecutive pointer-like words
# is a dispatch table; mark it so its DSR-range entries relocate (and so the code
# linear-decoder below skips over it rather than mis-decoding pointers as opcodes).
i=CLO
while i<CHI:
    if tblptr(w(i)) and not noreloc[i]:
        s=i
        while i<CHI and tblptr(w(i)) and not noreloc[i]: i+=2
        if (i-s)>=12:                      # >=6 words
            for p in range(s,i,2): istable[p]=True
    else: i+=2
for p in range(CLO,CHI,2):
    if istable[p]:
        v=w(p)
        if 0x4000<=v<=0x5fff and v!=w(p)+0x2000:
            setw(p,v+0x2000); reloc+=1; tblc+=1

# 2b. b/bl anywhere with in-range operand (safe).
blc=0
i=0
while i<len(g)-3:
    op=w(i); tgt=w(i+2)
    if op in (0x0460,0x06a0) and 0x4000<=tgt<=0x5fff and tgt not in PORTS:
        setw(i+2,tgt+0x2000); reloc+=1; blc+=1; i+=4
    else: i+=2

# 2c. linear-decode the CODE region (skipping tables) and relocate @operand refs.
opc=0; i=CLO
while i<CHI-1:
    if istable[i]: i+=2; continue
    op=w(i); L,exts=extpositions(op,i)
    for p in exts:
        if p+1<len(g) and not istable[p]:
            v=w(p)
            # Relocate @operand refs to p-code CODE/DATA (>=0x4040), but NOT the
            # header region 4000-403F: those reads (AA/subprog-list/etc.) are the
            # DSR-scan probing EXTERNAL cards via CRU selection, not the p-code's
            # own header, so they must stay at >4000.
            if 0x4000<=v<=0x5fff and v not in PORTS and not noreloc[p] and op not in (0x0460,0x06a0):
                setw(p,v+0x2000); reloc+=1; opc+=1
                if len(samples)<10: samples.append((i,op,v,v+0x2000,'op'))
    i+=L
print("ROM-ref relocations +0x2000: total=%d (b/bl=%d, table=%d, code-op=%d)"%(reloc,blc,tblc,opc))
for t in samples: print("  >%04X op=%04X @>%04X -> @>%04X [%s]"%t)

# Approach B: reseed the GROM read-data base register (r13) from the custom-card
# port >5BFC to the console GROM base0 port >9800 (GROM EF7A). Bank selection to
# >9804 for pcode>=0xA000 is done at address-set time by the RAM helpers.
import os, subprocess
def ramsym(name):
    out=subprocess.check_output(['bash','-c',
        "~/newtms9900-gcc/newgcc9900/bin/tms9900-objdump -t ramhelp.elf 2>/dev/null | grep -iw %s"%name]).decode()
    return int(out.split()[0],16)
if os.environ.get('GROMCONSOLE')=='1':
    if w(0xEF7A)==0x5BFC:
        setw(0xEF7A,0x9800); print("Approach B: GROM EF7A r13-seed 5BFC -> 9800")
    else:
        print("WARN: GROM EF7A != 5BFC (=%04X), r13-seed not reseeded"%w(0xEF7A))
    # HALT reset fix: the p-System reset routine (RAM 0x2FFE, from GROM 0xF27A) ends in
    # `BLWP @0000` at RAM 0x3014 (GROM 0xF290). On H(alt) a "don't boot" flag ('NO') is
    # stamped at RAM 0x38FA so the p-System won't re-enter -> on the cart that strands the
    # user at the title. Rewrite that `BLWP @0000` into `B @HALTRESET`, a RAM helper that
    # clears 0x38FA then does the original `BLWP @0000`, so re-selecting the cart re-enters.
    if w(0xF290)==0x0420 and w(0xF292)==0x0000:
        hr=ramsym('HALTRESET')
        setw(0xF290,0x0460); setw(0xF292,hr)
        print("HALT fix: GROM F290 BLWP @0000 -> B @HALTRESET (0x%04X)"%hr)
    else:
        print("WARN: GROM F290 != BLWP @0000 (=%04X %04X), HALT fix not applied"%(w(0xF290),w(0xF292)))

outname = 'cartgrom_b.bin' if os.environ.get('GROMCONSOLE')=='1' else 'cartgrom.bin'
open(outname,'wb').write(g)
print("wrote %s (%d bytes)"%(outname,len(g)))
