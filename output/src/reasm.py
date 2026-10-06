#!/usr/bin/env python3
"""
Reassembler front-end: decode a p-code ROM bank to tms9900-as (GNU) source,
emitting real instructions for reachable code (sim coverage + recursive descent)
and raw `byte` directives for everything else.  Target: byte-identical rebuild.

Usage: reasm.py <romfile> <base_hex> <covcol> <cov.txt> <entries...> > out.s
  covcol: which coverage column to use (1=shared/full-at-4000, or for 5000 region
          pass the bank col). We just OR any column==1 for addresses in file range.
"""
import sys, os
DROPNOPS = os.environ.get('DROPNOPS')=='1'   # step-1: delete jmp $+2 no-ops, pad region

def signed8(b): return b-256 if b>=128 else b

FMT1={0x4:'szc',0x5:'szcb',0x6:'s',0x7:'sb',0x8:'c',0x9:'cb',0xA:'a',0xB:'ab',
      0xC:'mov',0xD:'movb',0xE:'soc',0xF:'socb'}
# op>>10 -> (mnemonic, kind): iii=src+reg, iv=src+count, mpy/div=src+reg, ix=xop src+num
FMT_3459={0x08:('coc','r'),0x09:('czc','r'),0x0A:('xor','r'),0x0B:('xop','n'),
          0x0C:('ldcr','c'),0x0D:('stcr','c'),0x0E:('mpy','r'),0x0F:('div','r')}
FMT2={0x10:'jmp',0x11:'jlt',0x12:'jle',0x13:'jeq',0x14:'jhe',0x15:'jgt',0x16:'jne',
      0x17:'jnc',0x18:'joc',0x19:'jno',0x1A:'jl',0x1B:'jh',0x1C:'jop',
      0x1D:'sbo',0x1E:'sbz',0x1F:'tb'}
JUMPS=set(range(0x10,0x1D))
SHIFTS={0x08:'sra',0x09:'srl',0x0A:'sla',0x0B:'src'}
FMT6={0x10:'blwp',0x11:'b',0x12:'x',0x13:'clr',0x14:'neg',0x15:'inv',0x16:'inc',
      0x17:'inct',0x18:'dec',0x19:'dect',0x1A:'bl',0x1B:'swpb',0x1C:'seto',0x1D:'abs'}
FMT8I={0x020:'li',0x022:'ai',0x024:'andi',0x026:'ori',0x028:'ci'}
FMT8R={0x02A:'stwp',0x02C:'stst'}
FMT8N={0x02E:'lwpi',0x030:'limi'}
FMT7={0x0340:'idle',0x0360:'rset',0x0380:'rtwp',0x03A0:'ckon',0x03C0:'ckof',0x03E0:'lrex'}

PORTS={0x5bfc,0x5bfe,0x5ffc,0x5ffe}
LBL=set()   # addresses to render as L%04x labels (set before emit pass)

class Bank:
    def __init__(self, data, base):
        self.d=data; self.base=base; self.end=base+len(data)
    def w(self,a): i=a-self.base; return (self.d[i]<<8)|self.d[i+1]
    def inr(self,a): return self.base<=a<self.end-1

    def sym(self,val):
        """render an address value: label if in LBL else absolute hex"""
        return 'L%04x'%val if val in LBL else '0x%04x'%val

    def operand(self, T, R, extaddr):
        """return (gnu_text, extlen, romref_or_None). romref = in-ROM-range non-port target."""
        if T==0: return ('r%d'%R,0,None)
        if T==1: return ('*r%d'%R,0,None)
        if T==3: return ('*r%d+'%R,0,None)
        val=self.w(extaddr)
        ref = val if (0x4000<=val<=0x5fff and val not in PORTS) else None
        if R==0: return ('@%s'%self.sym(val),2,ref)
        return ('@%s(r%d)'%(self.sym(val),R),2,ref)

    def decode(self,a):
        """return (length, gnu_text, jump_target_or_None, [romrefs], li_target_or_None)"""
        op=self.w(a); refs=[]
        top4=op>>12
        if top4>=4:
            m=FMT1[top4]; Td=(op>>10)&3; D=(op>>6)&0xF; Ts=(op>>4)&3; S=op&0xF
            ext=a+2; st,sl,sr=self.operand(Ts,S,ext); ext+=sl
            dt,dl,dr=self.operand(Td,D,ext); L=2+sl+dl
            for t in (sr,dr):
                if t is not None: refs.append(t)
            return L,'%s %s, %s'%(m,st,dt),None,refs,None
        top6=op>>10
        if top6 in FMT_3459:
            m,kind=FMT_3459[top6]; D=(op>>6)&0xF; Ts=(op>>4)&3; S=op&0xF
            st,sl,sr=self.operand(Ts,S,a+2); L=2+sl
            if sr is not None: refs.append(sr)
            right=('r%d'%D) if kind=='r' else ('%d'%D)
            return L,'%s %s, %s'%(m,st,right),None,refs,None
        top8=op>>8
        if 0x10<=top8<=0x1F:
            m=FMT2[top8]
            if top8 in JUMPS:
                disp=signed8(op&0xFF); tgt=a+2+disp*2
                return 2,'%s L%04x'%(m,tgt),tgt,[],None
            else:
                return 2,'%s %d'%(m,signed8(op&0xFF)),None,[],None
        top12=op>>4
        if top12 in FMT8I:
            m=FMT8I[top12]; R=op&0xF; imm=self.w(a+2)
            # Bitwise-logical immediates (andi/ori) are MASKS, never addresses, so they
            # must NOT be symbolized/relocated (e.g. `ori r9,>4000` sets the VDP write bit;
            # relocating it to >6000 misdirects every VDP access by +0x2000). li/ai/ci
            # immediates can be address pointers and are symbolized so they track the shift.
            reloc_ok = m not in ('andi','ori')
            litgt = imm if (reloc_ok and 0x4000<=imm<=0x5fff and imm not in PORTS) else None
            rhs = self.sym(imm) if (litgt is not None) else '0x%04x'%imm
            return 4,'%s r%d, %s'%(m,R,rhs),None,[],litgt
        if top12 in FMT8N:
            m=FMT8N[top12]; imm=self.w(a+2)
            return 4,'%s 0x%04x'%(m,imm),None,[],None
        if top12 in FMT8R:
            m=FMT8R[top12]; R=op&0xF
            return 2,'%s r%d'%(m,R),None,[],None
        if op in FMT7:
            return 2,FMT7[op],None,[],None
        top8b=op>>8
        if top8b in SHIFTS:
            m=SHIFTS[top8b]; C=(op>>4)&0xF; W=op&0xF
            return 2,'%s r%d, %d'%(m,W,C),None,[],None
        top10=op>>6
        if top10 in FMT6:
            m=FMT6[top10]; Ts=(op>>4)&3; S=op&0xF
            st,sl,sr=self.operand(Ts,S,a+2); L=2+sl
            if sr is not None: refs.append(sr)
            return L,'%s %s'%(m,st),None,refs,None
        return None

    def flow(self,a):
        """for recursive descent: (length, [successors to follow], stop_straightline).
        Follow fall-through, conditional-jump targets, direct B/BL @addr targets.
        Do NOT follow computed (*Rn) branches, BLWP vectors, or into obvious data."""
        op=self.w(a); r=self.decode(a)
        if r is None: return None
        L=r[0]
        top8=op>>8
        # unconditional jmp
        if top8==0x10:
            tgt=a+2+signed8(op&0xFF)*2
            return L,[tgt] if self.inr(tgt) else [], True
        # conditional jumps
        if 0x11<=top8<=0x1c:
            tgt=a+2+signed8(op&0xFF)*2
            nx=[a+L]+([tgt] if self.inr(tgt) else [])
            return L,nx,False
        top10=op>>6
        if top10 in FMT6:
            m=FMT6[top10]; Ts=(op>>4)&3; S=op&0xF
            if m=='b':
                if Ts==2 and S==0 and self.inr(self.w(a+2)): return L,[self.w(a+2)],True
                return L,[],True         # b *Rn / indexed -> stop, no follow
            if m=='bl':
                nx=[a+L]
                if Ts==2 and S==0 and self.inr(self.w(a+2)): nx.append(self.w(a+2))
                return L,nx,False
            if m=='blwp': return L,[a+L],False
            if m=='x': return L,[a+L],False
        if op in FMT7 and FMT7[op] in ('rtwp','idle','lrex'):
            return L,[],True
        return L,[a+L],False

def main():
    rom=open(sys.argv[1],'rb').read()
    base=int(sys.argv[2],16)
    bank=sys.argv[3].upper()       # 'C' or 'D' : which column to use for >=5000
    covfile=sys.argv[4]
    mode=sys.argv[5]               # 'collect' or 'emit'
    reffile=sys.argv[6]            # collect: append targets here; emit: read all targets
    entries=[int(x,16) for x in sys.argv[7:]]
    B=Bank(rom,base)

    # coverage cols: addr shared bankC bankD.  Use shared for <5000, bank col for >=5000.
    bankcol = 1 if bank=='C' else 2   # index into cols list [shared,bankC,bankD]
    covstarts=set()
    for line in open(covfile):
        line=line.strip()
        if not line or line.startswith('#'): continue
        parts=line.split()
        a=int(parts[0],16); cols=[int(x) for x in parts[1:]]
        if not (B.base<=a<B.end): continue
        use = cols[0] if a<0x5000 else cols[bankcol]
        if use: covstarts.add(a)

    # Optional extra coverage (env PTRCOV, e.g. editor-run coverage) used ONLY to validate
    # data-pointer relocation targets -- NOT for disassembly. Lets handler/jump-table
    # pointers into not-boot-covered code (e.g. 0x50D0) relocate, without disturbing the
    # (stable) boot-coverage disassembly (which keeps blwp vectors etc. as data).
    ptrok=set()
    import os as _os
    _pc=_os.environ.get('PTRCOV')
    if _pc:
        for line in open(_pc):
            line=line.strip()
            if not line or line.startswith('#'): continue
            parts=line.split()
            a=int(parts[0],16); cols=[int(x) for x in parts[1:]]
            if not (B.base<=a<B.end): continue
            if (cols[0] if a<0x5000 else cols[bankcol]): ptrok.add(a)

    # Trusted instruction starts = sim coverage opcode-starts + covered entries.
    trusted=set(a for a in covstarts if B.inr(a))|set(e for e in entries if B.inr(e))

    # Build authoritative covered spans first.
    covered_occ={}   # byte addr -> owning covered start
    for a in trusted:
        r=B.decode(a)
        if r is None: continue
        for j in range(r[0]): covered_occ[a+j]=a

    # Recursive descent from trusted starts to reach uncovered code (fall-through +
    # conditional targets + direct B/BL). Only ADD instructions that don't collide
    # with covered spans (coverage is ground truth).
    seen=set(); stack=list(trusted)
    descent=set()
    while stack:
        a=stack.pop()
        if a in seen or not B.inr(a): continue
        seen.add(a)
        f=B.flow(a)
        if f is None: continue
        L,succ,stop=f
        if covered_occ.get(a,a)==a:
            descent.add(a)
        for s in succ:
            if s not in seen and B.inr(s): stack.append(s)

    # --- pass 1: decode. Covered starts are AUTHORITATIVE (decode first, own their
    # spans). Descent instructions are added ONLY if their span doesn't overlap a
    # covered instruction span (else discard: descent misdecoded data/misaligned). ---
    global LBL; LBL=set()
    insns={}; jtargets=set(); romrefs=set(); litargets=set()
    occ={}   # byte addr -> owning start (covered first, then accepted descent)
    def take(a, allow_overlap_check):
        r=B.decode(a)
        if r is None: return
        L,txt,jtgt,refs,litgt=r
        if allow_overlap_check:
            for j in range(L):
                o=occ.get(a+j)
                if o is not None and o!=a: return   # would overlap another instr -> discard
        insns[a]=L
        for j in range(L): occ[a+j]=a
        if jtgt is not None: jtargets.add(jtgt)
        for t in refs: romrefs.add(t)
        if litgt is not None: litargets.add(litgt)
    for a in sorted(trusted):
        if a not in occ or occ[a]==a: take(a, False)   # covered: authoritative
    for a in sorted(descent):
        if a in insns: continue
        if occ.get(a) is not None and occ[a]!=a: continue  # starts mid a kept instr
        take(a, True)

    # instruction-start set
    istart=set(insns)
    # LI targets: symbolize ALL in-range non-port immediates (they're address
    # pointers used for b *rN / copy sources etc.). A label is placed at each
    # target (data or code); demotion handles mid-instruction landings.
    li_ok=set(litargets)

    # collect mode: dump all in-ROM-range reference targets (for cross-section labeling)
    if mode=='collect':
        with open(reffile,'a') as f:
            for t in sorted(jtargets|romrefs|li_ok):
                if 0x4000<=t<=0x5fff: f.write('%04x\n'%t)
        return

    # emit mode: labels = own istarts/refs PLUS any target (from any section) in our range
    extra=set()
    try:
        for ln in open(reffile):
            ln=ln.strip()
            if ln: extra.add(int(ln,16))
    except FileNotFoundError: pass
    LBL = (istart | jtargets | romrefs | li_ok | set(t for t in extra if B.inr(t)))

    # Demote any instruction that CONTAINS a label mid-body to raw data bytes.
    # (Label lands cleanly in a data run; byte-identical preserved. Handles
    # data-in-code and coverage-gap misdecodes uniformly.)
    owner={}
    for a in insns:
        for j in range(insns[a]): owner[a+j]=a
    demote=set()
    for la in LBL:
        if B.inr(la) and owner.get(la)!=None and owner[la]!=la:
            demote.add(owner[la])
    for s in demote:
        del insns[s]
    if demote:
        sys.stderr.write('  demoted %d instrs to data (labels landed mid-body): %s\n'%(
            len(demote),' '.join('%04x'%s for s in sorted(demote))))

    # --- pass 2: emit with labels ---
    kind=['.']*len(rom)
    for a in insns:
        for j in range(insns[a]):
            idx=a-base+j
            if 0<=idx<len(rom):
                if kind[idx]!='.': sys.stderr.write('WARN overlap at %04x\n'%(base+idx))
                kind[idx]='C' if j==0 else 'x'
    # detect data-region pointer tables: runs of >=2 word-aligned in-range non-port
    # words sitting in data ('.') bytes -> emit as `data L####` so they track shifts.
    dataptr=set()
    a=base
    while a<base+len(rom)-1:
        w=B.w(a)
        if ((a-base)&1)==0 \
           and kind[a-base]=='.' and kind[a-base+1]=='.' and 0x4000<=w<=0x5fff \
           and w not in PORTS and (w&1)==0 and (w in istart or w in jtargets or w in ptrok):
            # only symbolize a data word as a pointer when it targets a KNOWN even
            # code address (avoids false positives on text/data like 'NO'/'GO').
            dataptr.add(a); LBL.add(w); a+=2
        else: a+=1

    print('\t.text')
    for la in sorted(LBL):
        if B.inr(la): print('\t.global L%04x'%la)
    a=base; dropped=0
    while a<base+len(rom):
        idx=a-base
        if a in LBL and B.inr(a): print('L%04x:'%a)
        if kind[idx]=='C':
            r=B.decode(a); L=r[0]; txt=r[1]
            if DROPNOPS and B.w(a)==0x1000 and a in trusted:  # drop only sim-covered no-ops
                dropped+=2; a+=insns[a]; continue
            print('\t%s'%txt); a+=insns[a]
        elif a in dataptr:
            print('\tdata L%04x'%B.w(a)); a+=2
        else:
            run=[]
            while a<base+len(rom):
                idx=a-base
                if kind[idx]=='C': break
                if a in dataptr: break
                if run and (a in LBL): break
                run.append(rom[idx]); a+=1
            for i in range(0,len(run),8):
                print('\tbyte '+', '.join('0x%02x'%b for b in run[i:i+8]))
    if DROPNOPS and dropped:
        for i in range(0,dropped,8):
            print('\tbyte '+', '.join('0x00' for _ in range(min(8,dropped-i))))
        sys.stderr.write('  DROPPED %d nop bytes (padded to region size)\n'%dropped)
    nc=sum(1 for k in kind if k in('C','x'))
    sys.stderr.write('reasm %s: %d/%d code, %d instrs, %d labels (%d romrefs,%d li)\n'%(
        sys.argv[1],nc,len(rom),len(insns),len([x for x in LBL if B.inr(x)]),len(romrefs),len(li_ok)))

if __name__=='__main__':
    main()
