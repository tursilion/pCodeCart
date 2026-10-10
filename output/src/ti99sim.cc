/*
 * Minimal TI-99/4A emulator for statically exercising the p-code card and its
 * paged-ROM cartridge conversion.  Reuses the validated TMS9900 core (cpu.cc).
 *
 * Devices: 32K expansion RAM, scratchpad, TMS9918A VDP (standard), console GROM,
 * p-code card (banked DSR ROM + special GROM ports at >5BFC/5BFE/5FFE),
 * paged cartridge ROM at >6000-7FFF (write-to-switch), minimal 9901 + VDP int.
 * Keyboard is faked via the ROM KSCAN hook at PC >0478.
 *
 * Not cycle-accurate; goal is functional boot + tracing to guide the conversion.
 */
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <cstdlib>
#include <cstdarg>
#include <vector>
#include <string>
#include "types.h"
#include "cpu.h"
#include <set>

// ---------------------------------------------------------------- memory
static uint8_t  conRom[0x2000];      // >0000-1FFF console ROM
static uint8_t  expRam[0x10000];     // full 64K backing; we use 2000-3FFF, A000-FFFF
static uint8_t  pad[0x100];          // scratchpad >8300-83FF (mirrored 8000-83FF)
static uint8_t  conGrom[0x6000];     // console GROM 24K (addr 0000-5FFF)
static uint8_t  pgGrom[0x10000];     // p-code GROM (up to 64K addr space)
static int      pgGromLen=0;
static uint8_t  dsr[0x4000];         // p-code DSR: 0-1FFF = bankC(8K), 2000-3FFF = bankD(8K)
static uint8_t  disk[0x2000];        // disk controller DSR (CRU >1100), maps at >4000-5FFF
static bool     diskOn=false;        // CRU >1100 bit0
static bool     noDisk=false;        // --nodisk: no disk controller at all
#include <vector>
#include <string>
static const int ROMDISK_BASE=3;         // EXPERIMENTAL: flat ROMdisk starts at this GROM base (="page 4")
static std::vector<uint8_t> romdisk;     // --romdisk flat_romdisk.bin: flat 512B-sector image served at base>=ROMDISK_BASE
static std::vector<uint8_t> diskImgs[4]; // --disk/--disk2/--disk3: raw 256-byte/sector images (TICC), indexed by drive 1-3
static std::string diskFile[4];          // diskFile[1]=DSK1, [2]=DSK2, [3]=DSK3
static std::string g_vdpliFile;
static std::vector<uint8_t> cart;    // paged cartridge ROM at >6000
static int      cartBankMask=0;

// ---------------------------------------------------------------- VDP
static uint8_t  vram[0x4000];
static uint8_t  vdpRegs[8];
static uint16_t vdpAddr=0;
static uint8_t  vdpPrefetch=0;
static uint8_t  vdpStatus=0;
static int      vdpLatched=0;        // 0 = expecting first (low) byte
static long     g_regtaint[16];      // per-reg: normalized PC of a `li rN,0x4xxx/5xxx`, else -1
static std::set<long> g_vdpli;       // normalized PCs of li's whose value flows to the VDP addr port (0x8C02) -> VDP addresses, must NOT relocate
static uint8_t  vdpFirst=0;
static bool     vdpIntPending=false;

// ---------------------------------------------------------------- GROM helper
static inline void gromInc(uint16_t &a){ uint16_t base=a&0xE000; a=((a+1)&0x1FFF)|base; }

// console GROM state
static uint16_t cgAddr=0, cgAccess=2; static uint8_t cgPre=0;
// p-code GROM state
static uint16_t pgAddr=0, pgAccess=2; static uint8_t pgPre=0;

// ---------------------------------------------------------------- p-code card
static bool     pcodeOn=false;   // CRU >1F00
static bool     noDsr=false;     // --nodsr: p-code card absent (test plain carts)
static bool     servePorts=false;// --ports: serve >5BFC GROM ports even without DSR (milestone A)
static bool     gromFromCart=false; // --gromfromcart: model the Milestone-B stub: serve GROM bytes from
                                    // cart banks 2+chip at offset HOFF instead of pgGrom[] (validates layout)
static const int GROM_HOFF=0x08;    // must match make_cartB.py HOFF
static bool     gromConsole=false;  // --gromconsole: Approach B — p-code GROM lives as real GROMs in
                                    // console GROM space (base0 @>9800 = pcode 0-0x9FFF, base1 @>9804 = pcode 0xA000+)
static bool     noVdpInt=false;  // --noint: never fire the VDP interrupt
static bool     catch4000=false; // --catch4000: stop on any read/exec of 4000-5FFF except GROM ports
static bool     g_catchexec=false; // --catchexec: stop only on EXEC of 4000-5FFF (not reads; avoids boot DSR-scan)
static int      pcodeBank=0;     // CRU >1F80 (0=C,1=D)

// ---------------------------------------------------------------- cart banking
static int      cartBank=0;

// ---------------------------------------------------------------- tracing
static bool trace_pcode_ports=false;   // trace >5BFC/5BFE/5FFE
static bool trace_dsr=false;            // trace reads/writes of >4000-5FFF
static bool trace_cru=false;
static bool trace_scratch=false;
static bool g_gromdrv=false;
static bool g_cr15=false;
static uint8_t scratchWritten[0x100];   // which pad bytes ever written
static bool trace_ram=false;            // record expansion RAM coverage
static uint8_t ramUsed[0x10000];        // which expansion RAM bytes ever touched (r/w)
static bool trace_cov=false;            // record executed opcode addresses in DSR space
static uint8_t covShared[0x1000];       // 4000-4FFF opcode-start map (both banks)
static uint8_t covBankC[0x1000];        // 5000-5FFF bank0 opcode-start map
static uint8_t covBankD[0x1000];        // 5000-5FFF bank1 opcode-start map
static const char*covOut=nullptr;
static FILE*exectrace=nullptr; static uint16_t lastexecpc=0; static const char*dumpsrcOut=nullptr;
static bool execStarted=false;   // exec trace begins only at the entry point (normalized 0x4038)
static bool intUntilEntry=false; // --int-until-entry: run OS boot with interrupts, then disable them at the entry point
static bool reachedEntry=false;  // set true once normalized PC 0x4038 (card/cart entry) is first reached
static uint16_t pcring[64]; static int pcringi=0;
static int gromSrc[0x10000]; static uint8_t gromCode[0x10000];
static int pendGromAddr=-1; static bool trace_gromcov=false; static const char*gromcovOut=nullptr;
static long insnCount=0;
static long g_kscanHits=0;
static int g_chipmask=0;
static int g_watch=-1;   // --watch ADDR: log writes into [ADDR, ADDR+8) with source GROM addr
static long g_cdSwitches=0;
static bool g_gromanalysis=false;      // --gromanalysis: tally GROM port accesses by active cart bank + PC region
static long g_gromAcc[2][2][3]={};     // [cartBank 0=C/1=D][0=data/1=addr][region 0=scratchpad/1=cartROM/2=other]
#include <set>
static std::set<int> g_gromPCs[2];     // distinct access PCs per cart bank (normalized)
static FILE*g_vdptrace=nullptr; // --vdptrace FILE: log every VRAM data write as addr=val pc
static long g_vdpafterkscan=0;  // --vdpafterkscan N: only log VDP once g_kscanHits>=N
static FILE*g_readlog=nullptr;  // --gromreadlog FILE: log each GROM data byte delivered post-entry (to diff baseline vs cart)
static FILE*g_setlog=nullptr;   // --gromsetlog FILE: log each cart-GROM address-set post-entry
static bool g_basewarn=false;   // --basewarn: warn on base2 console-GROM read of a base0 address (inconsistent base)
static std::set<long> g_screenkscan;    // --screenkscan N,N,..: dump the screen when kscan first reaches each N
static FILE*g_pcodelog=nullptr;         // --pcodelog FILE: log p-code PC (r8) + r0 at each interp dispatch (0x830C)
static long g_pcodeafter=0;             // --pcodeafter N: only log pcode once kscan>=N
static long g_snappcode=-1; static bool g_snapped2=false; static long g_snappcodeskip=0; // --snappcode HEX: dump RAM when p-code PC (r8)==HEX at 0x830C
static uint16_t g_pc=0;                 // current pc for trace context

static void tlog(const char*fmt,...){ va_list ap; va_start(ap,fmt); vfprintf(stderr,fmt,ap); va_end(ap); }

// record a GROM port access for the Milestone-B bank analysis: which cart code bank
// (cartBank) is active, is it a data or address access, and where does the accessing
// PC live (scratchpad hot-path / cart ROM / other).
static void recordGrom(bool isData){
    int b = cartBank&1;
    int reg = (g_pc>=0x8300&&g_pc<0x8400)?0 : ((g_pc>=0x6000&&g_pc<0x8000)?1:2);
    g_gromAcc[b][isData?0:1][reg]++;
    int np = (g_pc>=0x6000&&g_pc<0x8000)?g_pc-0x2000:g_pc;
    g_gromPCs[b].insert(np);
}

// ---------------------------------------------------------------- keyboard
static std::string keyQueue;   // ASCII keys to feed
static size_t keyIdx=0;
static long  keyReleaseUntil=0; // insn count until which we "release" (no key)
static std::string postKeys;   // --postkeys: keys injected only after --postat (e.g. at the prompt)
static size_t postIdx=0;
static long  postAt=0;         // --postat N: don't inject postKeys before insn N
static long  postKscan=0;      // --postkscan N: inject postKeys after the Nth KSCAN hit (program-relative; fair cross-run comparison)
#include <map>
static std::map<long,char> keySched;  // --keysched "kscan:char,...": inject char exactly when g_kscanHits==kscan (program-relative, fully reproducible)

// ============================================================ TI99 class
class TI99 : public TMS9900 {
public:
    bool running=true;
    // fetch one p-code GROM byte at absolute GROM address a. Default: from pgGrom[].
    // --gromfromcart models the Milestone-B bank-switch stub: byte lives in cart bank
    // 2+(a>>13) at offset HOFF+(a&0x1FFF).
    uint8_t gromByte(uint16_t a){
        if(gromFromCart && !cart.empty()){
            int chip=(a>>13)&7; size_t off=(size_t)(2+chip)*0x2000 + GROM_HOFF + (a&0x1FFF);
            uint8_t v = off<cart.size()?cart[off]:0;
            static int nmis=0;
            uint8_t ref=pgGrom[a%(pgGromLen?pgGromLen:1)];
            if(v!=ref && nmis<20){ fprintf(stderr,"GROMMISMATCH a=%04X chip=%d off=%zX cart=%02X pgGrom=%02X pc=%04X\n",a,chip,off,v,ref,g_pc); nmis++; }
            return v;
        }
        return pgGrom[a%(pgGromLen?pgGromLen:1)];
    }
    // ---- p-code GROM port ----
    uint8_t pcodeRead(uint16_t x){
        if (x>=0x5ffc) return 0;           // write ports read as 0
        if (x&0x0002){ // read address
            if(g_readlog&&reachedEntry) fprintf(g_readlog,"RDADDR pa=%04X pc=%04X\n",pgAddr,g_pc);
            cgAccess=2; uint8_t z=(pgAddr>>8)&0xff; pgAddr=((pgAddr&0xff)<<8)|(pgAddr&0xff); return z;
        } else {       // read data
            if(trace_gromcov) pendGromAddr=pgAddr;   // provenance: this data byte came from pgAddr
            if(reachedEntry) g_chipmask|=1<<((pgAddr>>13)&7); pgAccess=2; uint8_t z=pgPre; pgPre=gromByte(pgAddr); gromInc(pgAddr); if(g_readlog&&reachedEntry) fprintf(g_readlog,"%02X\n",z); return z;
        }
    }
    void pcodeWrite(uint16_t x,uint8_t c){
        if (x<0x5ffc) return;              // read ports ignore writes
        if (x&0x0002){ // write address
            pgAddr=(pgAddr<<8)|c; pgAccess--; if(pgAccess==0){pgAccess=2; pgPre=gromByte(pgAddr); gromInc(pgAddr);}
        } else { pgAccess=2; pgPre=gromByte(pgAddr); gromInc(pgAddr); }
    }
    // ---- console GROM port ----
    // Real HW: one SHARED 16-bit address counter across all GROMs. Console GROMs
    // answer for addr 0x0000-0x5FFF at ANY base; for 0x6000-0xFFFF the BASE selects
    // which cart GROM chip-set answers.  Base = (port>>2)&0x3F  (>9800=base0, >9804=base1).
    // Approach B (--gromconsole): the p-code GROM is on the cart in console space:
    //   base0 covers p-code addr 0x0000-0x9FFF at console 0x6000-0xFFFF (pcode = C-0x6000)
    //   base1 covers p-code addr 0xA000-0xF7FF at console 0x6000-0xB7FF (pcode = C+0x4000)
    uint8_t cgromByte(int base, uint16_t a){
        if (a < 0x6000) return a<sizeof(conGrom)?conGrom[a]:0;   // console GROMs, any base
        if (gromConsole){
            // base0 & base1 = SAME GROM (chips 0-4, pcode 0-0x9FFF); base1 is a duplicate
            // of base0 to work around the console's base0-vs-base1 diff bug. base2 = the
            // other GROM (chips 5-7, pcode 0xA000-0xF7FF). p-code banks via base0 / base2.
            int p = (base==0||base==1) ? (a-0x6000) : (base==2) ? (a+0x4000) : -1;
            if (p>=0 && p<pgGromLen) return pgGrom[p];
        }
        // EXPERIMENTAL flat ROMdisk at pages base>=ROMDISK_BASE: console 0x6000-0xFFFF of each
        // base is 40K (0xA000) of flat sector data; page = base-ROMDISK_BASE.
        if (!romdisk.empty() && base>=ROMDISK_BASE && a>=0x6000){
            size_t fa = (size_t)(base-ROMDISK_BASE)*0xA000 + (a-0x6000);
            static int rdcnt=0; if(reachedEntry && rdcnt<60){ rdcnt++; fprintf(stderr,"[RD base%d cons=%04X flat=%04X byte=%02X pc=%04X wp=%04X]\n",base,a,(unsigned)fa,fa<romdisk.size()?romdisk[fa]:0,getPC(),getWP()); }
            if (fa < romdisk.size()) return romdisk[fa];
        }
        return 0;
    }
    uint8_t cgromRead(uint16_t x){
        int base=(x&0x3C)>>2;
        if (x&0x0002){ cgAccess=2; uint8_t z=(cgAddr>>8)&0xff; cgAddr=((cgAddr&0xff)<<8)|(cgAddr&0xff); return z; }
        else { cgAccess=2; uint8_t z=cgPre; bool cart=(cgAddr>=0x6000);
            if(reachedEntry && cgAddr>=0x6010 && cgAddr<0x6150){ uint16_t np=(g_pc>=0x6000&&g_pc<0x8000)?g_pc-0x2000:g_pc; fprintf(stderr,"[ROMDISK-META read cg=%04X pc=%04X]\n",cgAddr,np); }
            if(g_basewarn && reachedEntry && base==2 && cgAddr>=0xB800)
                fprintf(stderr,"[BASEWARN base2 read of base0 addr cg=%04X (pcode0=%04X) pc=%04X]\n",cgAddr,(uint16_t)(cgAddr-0x6000),g_pc);
            cgPre=cgromByte(base,cgAddr); gromInc(cgAddr); if(g_readlog&&reachedEntry&&cart) fprintf(g_readlog,"%02X\n",z); return z; }
    }
    void cgromWrite(uint16_t x,uint8_t c){
        int base=(x&0x3C)>>2;
        if (x&0x0002){ if(g_readlog&&reachedEntry) fprintf(g_readlog,"CW base=%d c=%02X cg=%04X pc=%04X\n",base,c,cgAddr,g_pc); cgAddr=(cgAddr<<8)|c; cgAccess--; if(cgAccess==0){cgAccess=2;
            if(reachedEntry && base<=1 && cgAddr>=0x6010 && cgAddr<0x60E0){ uint16_t np=(g_pc>=0x6000&&g_pc<0x8000)?g_pc-0x2000:g_pc; fprintf(stderr,"[IDX base%d cg=%04X nativePC=%04X]\n",base,cgAddr,np); }
            cgPre=cgromByte(base,cgAddr);
            if(g_setlog && reachedEntry && cgAddr>=0x6000){ static int sc=0; if(sc<200){sc++; fprintf(g_setlog,"SET base=%d cg=%04X val=%02X\n",base,cgAddr,cgPre);} }
            gromInc(cgAddr);} }
    }
    // ---- VDP ----
    uint8_t vdpRead(uint16_t x){
        if (x&2){ uint8_t s=vdpStatus; vdpStatus&=~0x80; vdpIntPending=false; vdpLatched=0; return s; }
        else { uint8_t z=vdpPrefetch; vdpPrefetch=vram[vdpAddr&0x3fff]; vdpAddr=(vdpAddr+1)&0x3fff; vdpLatched=0; return z; }
    }
    void vdpWrite(uint16_t x,uint8_t c){
        if (x&2){ // address/register port
            if (!vdpLatched){ vdpFirst=c; vdpLatched=1; }
            else { vdpLatched=0; int hi=c;
                if ((hi&0xC0)==0x80){ int _r=hi&7; uint8_t _ov=vdpRegs[_r]; vdpRegs[_r]=vdpFirst;
                    if(_r==1 && reachedEntry && _ov!=vdpFirst){ uint16_t np=(g_pc>=0x6000&&g_pc<0x8000)?g_pc-0x2000:g_pc; fprintf(stderr,"[VDP reg1 %02X->%02X pc=%04X insn=%ld kscan=%ld]%s\n",_ov,vdpFirst,np,insnCount,g_kscanHits,vdpFirst==0xE1?"  <<< APP STARTED":""); } }
                else { vdpAddr=(((hi&0x3f)<<8)|vdpFirst)&0x3fff;
                       // VDP-address-li detection: the value written here came from a register;
                       // if that reg was loaded by a `li rN,0x4xxx` (tainted), that li is a VDP
                       // address (not a code pointer) and must NOT be relocated.
                       if(reachedEntry){ uint16_t op=_memReadW(g_pc); if((op&0xF000)==0xD000 && ((op>>4)&3)==0){ int src=op&0xF; if(g_regtaint[src]>=0) g_vdpli.insert(g_regtaint[src]); } }
                       if(g_vdptrace&&reachedEntry&&g_kscanHits>=g_vdpafterkscan){uint16_t np=(g_pc>=0x6000&&g_pc<0x8000)?g_pc-0x2000:g_pc; fprintf(g_vdptrace,"SETADDR %04X (raw hi=%02X lo=%02X) pc=%04X\n",vdpAddr,hi,vdpFirst,np);}
                       if((hi&0xC0)==0x00){ vdpPrefetch=vram[vdpAddr&0x3fff]; vdpAddr=(vdpAddr+1)&0x3fff; } }
            }
        } else { if(g_vdptrace&&reachedEntry&&g_kscanHits>=g_vdpafterkscan){uint16_t np=(g_pc>=0x6000&&g_pc<0x8000)?g_pc-0x2000:g_pc; fprintf(g_vdptrace,"%04X=%02X pc=%04X\n",vdpAddr&0x3fff,c,np);} vram[vdpAddr&0x3fff]=c; vdpPrefetch=c; vdpAddr=(vdpAddr+1)&0x3fff; vdpLatched=0; }
    }
    // ---- memory dispatch (byte) ----
    uint8_t rb(uint16_t a){
        switch(a&0xE000){
        case 0x0000: return conRom[a];
        case 0x2000: if(trace_ram) ramUsed[a]|=1; if(trace_gromcov&&gromSrc[a]>=0){uint16_t wp=getWP(); if(a<wp||a>=wp+32) pendGromAddr=gromSrc[a];} return expRam[a];
        case 0x4000: { // DSR / p-code / disk
            if(diskOn) return disk[a-0x4000];
            if(trace_dsr) tlog("[%06ld pc%04X] rd DSR %04X\n",insnCount,g_pc,a);
            if((a&1)==0 && (servePorts||pcodeOn) && (a==0x5bfc||a==0x5bfe||a==0x5ffc||a==0x5ffe)){
                if(g_gromanalysis&&reachedEntry) recordGrom(a==0x5bfc);
                if(trace_pcode_ports){ uint16_t before=pgAddr; uint8_t r=pcodeRead(a);
                    tlog("R %04X pc=%04X bank=%d pgAddr=%04X val=%02X\n",a,g_pc,pcodeBank,before,r); return r; }
                return pcodeRead(a);
            }
            if(catch4000 && g_pc>=0x2000){ fprintf(stderr,"\n*** CATCH: read >%04X from pc >%04X ***\n  code@pc:",a,g_pc); for(int k=-4;k<=8;k+=2){uint16_t p=g_pc+k; fprintf(stderr," %04X",(rb(p)<<8)|rb(p+1));} fprintf(stderr,"\n"); running=false; return 0; }
            if(!pcodeOn) return 0;
            return dsr[(pcodeBank?0x2000:0)+(a-0x4000)];
        }
        case 0x6000: { // cartridge paged ROM
            if(cart.empty()) return 0;
            size_t off=(size_t)cartBank*0x2000 + (a-0x6000);
            return off<cart.size()?cart[off]:0;
        }
        case 0x8000:
            if(a>=0x8800&&a<0x8C00) return vdpRead(a);           // 8800 read
            if(a>=0x9800&&a<0x9C00) return cgromRead(a);         // 9800 read
            if(a>=0x9000&&a<0x9800) return 0;                    // speech
            if(trace_scratch && a>=0x8300) scratchWritten[a&0xff]|=1; // mark read
            if(trace_gromcov){uint16_t wp=getWP(); int si=0x8000|(a&0xff); if(gromSrc[si]>=0 && (a<wp||a>=wp+32)) pendGromAddr=gromSrc[si];}
            return pad[a&0xff];                                  // scratchpad (8000-83FF mirror) + write-only regs read
        default: // A000-FFFF
            if(trace_ram) ramUsed[a]|=1; if(trace_gromcov&&gromSrc[a]>=0){uint16_t wp=getWP(); if(a<wp||a>=wp+32) pendGromAddr=gromSrc[a];} return expRam[a];
        }
    }
    void wb(uint16_t a,uint8_t c){
        switch(a&0xE000){
        case 0x0000: return; // ROM
        case 0x2000: if(g_cr15&&a==0x2D01&&g_pc==0x608A) c=0x0C; // redirect boot fill: CODREAD[#15] 9800->980C (base3)
                     if(trace_ram) ramUsed[a]|=1; if(trace_gromcov&&pendGromAddr>=0){uint16_t wp=getWP(); if(a<wp||a>=wp+32){gromSrc[a]=pendGromAddr; pendGromAddr=-1;}} if((a==0x200C||a==0x200D)&&expRam[a]!=c) fprintf(stderr,"W200C a=%04X=%02X pc=%04X pgAddr=%04X\n",a,c,g_pc,pgAddr); if(g_watch>=0&&a>=g_watch&&a<g_watch+8) fprintf(stderr,"WATCH wr %04X=%02X pc=%04X pgAddr=%04X insn=%ld\n",a,c,g_pc,pgAddr,insnCount); expRam[a]=c; return;
        case 0x4000:
            if(trace_dsr) tlog("[%06ld pc%04X] wr DSR %04X=%02X\n",insnCount,g_pc,a,c);
            if((servePorts||pcodeOn) && (a&1)==0 && (a==0x5ffc||a==0x5ffe)){
                if(g_gromanalysis&&reachedEntry) recordGrom(false);  // address-port write
                if(trace_pcode_ports) tlog("W %04X pc=%04X bank=%d val=%02X pgAddr=%04X\n",a,g_pc,pcodeBank,c,pgAddr);
                pcodeWrite(a,c);
            }
            return; // ROM otherwise
        case 0x6000: { // write => bank switch
            int nb=(a>>1)&cartBankMask;
            if(g_gromanalysis && reachedEntry && nb!=cartBank && nb<2 && cartBank<2) g_cdSwitches++; // count C<->D code-bank switches
            cartBank=nb;
            return; }
        case 0x8000:
            if(a>=0x8C00&&a<0x9000){ vdpWrite(a,c); return; }    // 8C00 write
            if(a>=0x9C00){ cgromWrite(a,c); return; }            // 9C00 grom write
            if(a>=0x8400&&a<0x8800) return;                      // sound
            if(a>=0x9000&&a<0x9C00) return;                      // speech write
            if(trace_scratch && a>=0x8300 && a<=0x8341 && pad[a&0xff]!=c)
                tlog("SCODE wr %04X=%02X from pc=%04X insn=%ld pgAddr=%04X\n",a,c,g_pc,insnCount,pgAddr);
            if(g_watch>=0 && (g_watch&0xff00)==0x8300 && reachedEntry && (a&0xff00)==0x8300 && (a&0xff)>=(g_watch&0xff) && (a&0xff)<(g_watch&0xff)+8){ uint16_t np=(g_pc>=0x6000&&g_pc<0x8000)?g_pc-0x2000:g_pc; fprintf(stderr,"PADWR %04X=%02X pc=%04X insn=%ld kscan=%ld\n",a,c,np,insnCount,g_kscanHits); }
            if(trace_gromcov&&pendGromAddr>=0){uint16_t wp=getWP(); if(a<wp||a>=wp+32){gromSrc[0x8000|(a&0xff)]=pendGromAddr; pendGromAddr=-1;}} pad[a&0xff]=c; if(trace_scratch && a>=0x8300) scratchWritten[a&0xff]|=1; return;
        default:
            if(g_watch>=0 && (g_watch&0xE000)>=0xA000 && reachedEntry && a>=g_watch && a<g_watch+8){ uint16_t np=(g_pc>=0x6000&&g_pc<0x8000)?g_pc-0x2000:g_pc; fprintf(stderr,"HWATCH wr %04X=%02X pc=%04X cartBank=%d insn=%ld\n",a,c,np,cartBank,insnCount); }
            if(trace_ram) ramUsed[a]|=1; expRam[a]=c; return;
        }
    }
    // ---- required overrides ----
    uint16_t _memReadW(uint16_t a){ a&=~1; return (rb(a)<<8)|rb(a+1); }
    uint16_t peekW(uint16_t a){ return (rb(a)<<8)|rb(a+1); }
    uint8_t  _memReadB(uint16_t a){ return rb(a); }
    void _memWriteW(uint16_t a,uint16_t d){ a&=~1; wb(a,d>>8); wb(a+1,d&0xff); }
    void _memWriteB(uint16_t a,uint8_t d){ wb(a,d); }
    // ---- interrupts ----
    int _interruptLevel(int mask){
        if(vdpIntPending && (vdpRegs[1]&0x20) && mask>=1) return 1;
        return -1;
    }
    void _halt(const char*s){ fprintf(stderr,"HALT: %s (pc~%04X)\n  recent PCs:",s,getPC()); for(int k=1;k<=24;k++) fprintf(stderr," %04X",pcring[(pcringi-k)&63]); fprintf(stderr,"\n"); running=false; }
    // ---- CRU ----
    void _cruBitOutput(uint16_t base, uint16_t offset, uint8_t state){
        int fam=(base + ((int16_t)offset)*2)&0xFFFF;
        if(trace_cru) tlog("[%06ld pc%04X] CRU %s fam=%04X\n",insnCount,g_pc,state?"SBO":"SBZ",fam);
        if((fam&0xFF00)==0x1100){ if((fam&0xFF)==0x00) diskOn=state && !noDisk; }
        if((fam&0xFF00)==0x1F00){
            if((fam&0xFF)==0x00){ pcodeOn=state && !noDsr; }
            else if((fam&0xFF)==0x80){ pcodeBank=state?1:0; }
        }
    }
    uint8_t _cruBitGet(uint16_t base, int8_t offset){
        int cruBit=((base>>1)+offset)&0xFFF;
        if(cruBit==2){ return vdpIntPending?0:1; } // INT2 active low
        return 1; // no key / inactive
    }
    void _cruMultiBitSet(uint16_t base,uint16_t data,int nBits){}
    uint16_t _cruMultiBitGet(uint16_t base,uint16_t offset){ return 0xFFFF; }
};

// ============================================================ helpers
static int loadFile(const char*name,uint8_t*buf,int max){
    FILE*f=fopen(name,"rb"); if(!f){fprintf(stderr,"cannot open %s\n",name);exit(1);}
    int n=fread(buf,1,max,f); fclose(f); return n;
}

static void dumpNameTable(TI99&cpu){
    int nt=(vdpRegs[2]&0x0f)*0x400;
    fprintf(stderr,"--- VDP nametable @%04X regs:",nt);
    for(int i=0;i<8;i++) fprintf(stderr," %02X",vdpRegs[i]);
    fprintf(stderr," (mode reg0=%02X reg1=%02X)\n",vdpRegs[0],vdpRegs[1]);
    // print 24 rows of 32 (or 40 if text mode)
    int cols=(vdpRegs[1]&0x10)?40:32;
    for(int r=0;r<24;r++){
        char line[64]; int p=0;
        for(int c=0;c<cols;c++){ int v=vram[(nt+r*cols+c)&0x3fff];
            // best-effort: TI title uses pattern index; printable if 0x20-0x7E after +0x00 or -0x60
            int ch=v; if(ch<0x20||ch>0x7e){ int alt=v+0x60; if(alt>=0x20&&alt<=0x7e) ch=alt; else ch='.'; }
            line[p++]=ch; }
        line[p]=0; fprintf(stderr,"%2d|%s\n",r,line);
    }
}

int main(int argc,char**argv){
    const char*mode="orig";
    long maxInsns=20000000;
    const char*cartFile=nullptr;
    const char*dsrCfile=nullptr,*dsrDfile=nullptr,*gromFile=nullptr;
    int dumpAt=-1; long snapPc=-1; bool snapped=false; long snapKscan=0; long snapSkip=0; long snapInsn=0; long snapMem=-1;
    for(int i=1;i<argc;i++){
        std::string a=argv[i];
        if(a=="--cart"&&i+1<argc){ cartFile=argv[++i]; mode="cart"; }
        else if(a=="--max"&&i+1<argc) maxInsns=atol(argv[++i]);
        else if(a=="--trace-ports") trace_pcode_ports=true;
        else if(a=="--trace-dsr") trace_dsr=true;
        else if(a=="--trace-cru") trace_cru=true;
        else if(a=="--trace-scratch") trace_scratch=true;
        else if(a=="--trace-ram") trace_ram=true;
        else if(a=="--cov"&&i+1<argc){ trace_cov=true; covOut=argv[++i]; }
        else if(a=="--exectrace"&&i+1<argc){ exectrace=fopen(argv[++i],"w"); }
        else if(a=="--keys"&&i+1<argc) keyQueue=argv[++i];
        else if(a=="--postkeys"&&i+1<argc) postKeys=argv[++i];
        else if(a=="--postat"&&i+1<argc) postAt=atol(argv[++i]);
        else if(a=="--postkscan"&&i+1<argc) postKscan=atol(argv[++i]);
        else if(a=="--keysched"&&i+1<argc){ std::string s=argv[++i]; size_t p=0;
            while(p<s.size()){ size_t c=s.find(':',p), e=s.find(',',p); if(e==std::string::npos)e=s.size();
                long k=atol(s.substr(p,c-p).c_str()); std::string v=s.substr(c+1,e-(c+1)); uint8_t ch;
                if(v.size()>1&&(v[0]=='x'||v[0]=='X'||v[0]=='$')) ch=(uint8_t)strtol(v.c_str()+1,0,16); // raw hex byte, e.g. x88 left-arrow, x03 esc (needs digits; a bare 'X' stays a literal key)
                else { ch=v.empty()?0:(uint8_t)v[0]; if(ch=='_')ch=' '; else if(ch=='~')ch='\r'; }
                keySched[k]=(char)ch; p=e+1; } }
        else if(a=="--dsrc"&&i+1<argc) dsrCfile=argv[++i];
        else if(a=="--dsrd"&&i+1<argc) dsrDfile=argv[++i];
        else if(a=="--nodsr") noDsr=true;
        else if(a=="--ports") servePorts=true;
        else if(a=="--catch4000") catch4000=true;
        else if(a=="--catchexec") g_catchexec=true;
        else if(a=="--noint") noVdpInt=true;
        else if(a=="--int-until-entry") intUntilEntry=true;
        else if(a=="--snap"&&i+1<argc) snapPc=strtol(argv[++i],0,16);
        else if(a=="--snapkscan"&&i+1<argc) snapKscan=atol(argv[++i]);
        else if(a=="--snapskip"&&i+1<argc) snapSkip=atol(argv[++i]);
        else if(a=="--snapinsn"&&i+1<argc) snapInsn=atol(argv[++i]);
        else if(a=="--snapmem"&&i+1<argc) snapMem=strtol(argv[++i],0,16);
        else if(a=="--watch"&&i+1<argc) g_watch=strtol(argv[++i],0,16);
        else if(a=="--vdptrace"&&i+1<argc) g_vdptrace=fopen(argv[++i],"w");
        else if(a=="--vdpafterkscan"&&i+1<argc) g_vdpafterkscan=atol(argv[++i]);
        else if(a=="--screenkscan"&&i+1<argc){ std::string s=argv[++i]; size_t p=0; while(p<s.size()){ size_t e=s.find(',',p); if(e==std::string::npos)e=s.size(); g_screenkscan.insert(atol(s.substr(p,e-p).c_str())); p=e+1; } }
        else if(a=="--pcodelog"&&i+1<argc) g_pcodelog=fopen(argv[++i],"w");
        else if(a=="--pcodeafter"&&i+1<argc) g_pcodeafter=atol(argv[++i]);
        else if(a=="--snappcode"&&i+1<argc) g_snappcode=strtol(argv[++i],0,16);
        else if(a=="--snappcodeskip"&&i+1<argc) g_snappcodeskip=atol(argv[++i]);
        else if(a=="--gromanalysis") g_gromanalysis=true;
        else if(a=="--gromfromcart") gromFromCart=true;
        else if(a=="--gromconsole") gromConsole=true;
        else if(a=="--gromreadlog"&&i+1<argc) g_readlog=fopen(argv[++i],"w");
        else if(a=="--gromsetlog"&&i+1<argc) g_setlog=fopen(argv[++i],"w");
        else if(a=="--gromdrv") g_gromdrv=true;
        else if(a=="--cr15") g_cr15=true;
        else if(a=="--basewarn") g_basewarn=true;
        else if(a=="--nodisk") noDisk=true;
        else if(a=="--disk"&&i+1<argc) diskFile[1]=argv[++i];
        else if(a=="--romdisk"&&i+1<argc){ FILE*rf=fopen(argv[++i],"rb"); if(rf){ fseek(rf,0,SEEK_END); long n=ftell(rf); fseek(rf,0,SEEK_SET); romdisk.resize(n); fread(romdisk.data(),1,n,rf); fclose(rf); fprintf(stderr,"romdisk: %ld bytes (%ld sectors) at base>=%d\n",n,n/512,ROMDISK_BASE); } }
        else if(a=="--disk2"&&i+1<argc) diskFile[2]=argv[++i];
        else if(a=="--disk3"&&i+1<argc) diskFile[3]=argv[++i];
        else if(a=="--taintvdp"&&i+1<argc) g_vdpliFile=argv[++i];
        else if(a=="--grom"&&i+1<argc) gromFile=argv[++i];
        else if(a=="--gromcov"&&i+1<argc){ trace_gromcov=true; gromcovOut=argv[++i]; }
        else if(a=="--dumpsrc"&&i+1<argc){ trace_gromcov=true; dumpsrcOut=argv[++i]; }
        else if(a=="--dumpat"&&i+1<argc) dumpAt=atoi(argv[++i]);
    }
    // load roms
    loadFile("../994AROM.BIN",conRom,0x2000);
    loadFile("../994AGROM.BIN",conGrom,0x6000);
    pgGromLen=loadFile(gromFile?gromFile:"../p1f00g_0000_f800.GRM",pgGrom,0x10000);
    loadFile(dsrCfile?dsrCfile:"../PCardC.ROM",dsr,0x2000);
    loadFile(dsrDfile?dsrDfile:"../PCardD.ROM",dsr+0x2000,0x2000);
    loadFile("../DISK.BIN",disk,0x2000);
    for(int d=1;d<=3;d++){ if(diskFile[d].empty()) continue;
        FILE*df=fopen(diskFile[d].c_str(),"rb"); if(!df){fprintf(stderr,"cannot open disk %s\n",diskFile[d].c_str());return 1;}
        fseek(df,0,SEEK_END); long dn=ftell(df); fseek(df,0,SEEK_SET); diskImgs[d].resize(dn); fread(diskImgs[d].data(),1,dn,df); fclose(df);
        fprintf(stderr,"DSK%d %s: %ld bytes = %ld sectors (TICC)\n",d,diskFile[d].c_str(),dn,dn/256); }
    if(cartFile){ FILE*f=fopen(cartFile,"rb"); if(!f){fprintf(stderr,"no cart %s\n",cartFile);return 1;}
        fseek(f,0,SEEK_END); long n=ftell(f); fseek(f,0,SEEK_SET); cart.resize(n); fread(cart.data(),1,n,f); fclose(f);
        int banks=n/0x2000; int m=1; while(m<banks) m<<=1; cartBankMask=m-1;
        fprintf(stderr,"cart %s: %ld bytes, %d banks, mask %X\n",cartFile,n,banks,cartBankMask);
    }
    fprintf(stderr,"mode=%s pgGromLen=%d\n",mode,pgGromLen);

    for(int i=0;i<0x10000;i++) gromSrc[i]=-1;
    TI99 cpu;
    cpu.boot();               // load WP/PC from >0000
    fprintf(stderr,"boot: pc=%04X wp=%04X\n",cpu.getPC(),cpu.getWP());

    const long FRAME=3000;    // approx instructions per vsync
    long lastDump=0;
    bool enteredDsr=false, enteredCart=false;
    for(int _t=0;_t<16;_t++) g_regtaint[_t]=-1;
    for(insnCount=0; insnCount<maxInsns && cpu.running; insnCount++){
        g_pc=cpu.getPC();
        if(reachedEntry){ uint16_t top=cpu.peekW(g_pc);
            if((top&0xFFF0)==0x0200){ int reg=top&0xF; uint16_t imm=cpu.peekW(g_pc+2); uint16_t np=(g_pc>=0x6000&&g_pc<0x8000)?g_pc-0x2000:g_pc; g_regtaint[reg]=(0x4000<=imm&&imm<=0x5fff)?(long)np:-1; }
            else if(top==0x0380 || top==0x02E0 || (top&0xFFC0)==0x0400){ for(int _t=0;_t<16;_t++) g_regtaint[_t]=-1; } }
        if(!reachedEntry){ uint16_t np=(g_pc>=0x6000&&g_pc<0x8000)?g_pc-0x2000:g_pc; if(np==0x4038){ reachedEntry=true; fprintf(stderr,">>> reached ENTRY (normalized 4038) at insn %ld pc=%04X\n",insnCount,g_pc); } }
        if(snapPc>=0 && !snapped && g_kscanHits>=snapKscan && insnCount>=snapInsn){ uint16_t np=(g_pc>=0x6000&&g_pc<0x8000)?g_pc-0x2000:g_pc; if(np==(uint16_t)snapPc && snapSkip-->0){} else if(np==(uint16_t)snapPc){ snapped=true;
            uint16_t wp=cpu.getWP(); fprintf(stderr,"=== SNAP at np=%04lX (pc=%04X insn=%ld) WP=%04X cgAddr=%04X pgAddr=%04X ===\n",snapPc,g_pc,insnCount,wp,cgAddr,pgAddr);
            for(int r=0;r<16;r++) fprintf(stderr,"  R%-2d=%04X%s",r,cpu.peekW(wp+2*r),(r&3)==3?"\n":"");
            fprintf(stderr,"  RAM 2CA0-2CC0:"); for(int x=0x2CA0;x<0x2CC0;x+=2) fprintf(stderr," %04X",cpu.peekW(x)); fprintf(stderr,"\n");
            fprintf(stderr,"  RAM 2AB0-2AD0:"); for(int x=0x2AB0;x<0x2AD0;x+=2) fprintf(stderr," %04X",cpu.peekW(x)); fprintf(stderr,"\n");
            fprintf(stderr,"  RAM 2DA0-2DC0:"); for(int x=0x2DA0;x<0x2DC0;x+=2) fprintf(stderr," %04X",cpu.peekW(x)); fprintf(stderr,"\n");
            fprintf(stderr,"  RAM 3380-33B0:"); for(int x=0x3380;x<0x33B0;x+=2) fprintf(stderr," %04X",cpu.peekW(x)); fprintf(stderr,"\n");
            fprintf(stderr,"  MEM 4000-4010:"); for(int x=0x4000;x<0x4010;x+=2) fprintf(stderr," %04X",cpu.peekW(x)); fprintf(stderr,"\n");
            fprintf(stderr,"  PAD 8300-83E0:"); for(int x=0x8300;x<0x83E0;x+=2){ if((x&0xf)==0)fprintf(stderr,"\n    %04X:",x); fprintf(stderr," %04X",cpu.peekW(x)); } fprintf(stderr,"\n");
            { FILE*vf=fopen("snap_vram.bin","wb"); fwrite(vram,1,sizeof(vram),vf); fclose(vf); fprintf(stderr,"  dumped VRAM to snap_vram.bin\n"); }
            { FILE*rf=fopen("snap_ram.bin","wb"); fwrite(expRam+0x2000,1,0x2000,rf); fclose(rf); fprintf(stderr,"  dumped RAM 2000-3FFF to snap_ram.bin\n"); }
            if(snapMem>=0){ fprintf(stderr,"  MEM %04lX:",snapMem); for(int x=0;x<0x40;x+=2) fprintf(stderr," %04X",cpu.peekW((uint16_t)(snapMem+x))); fprintf(stderr,"\n"); }
            { FILE*hf=fopen("snap_hram.bin","wb"); for(int x=0xA000;x<0x10000;x++){uint8_t v=expRam[x]; fwrite(&v,1,1,hf);} fclose(hf); fprintf(stderr,"  dumped RAM A000-FFFF to snap_hram.bin\n"); }
        } }
        if(g_pc==0x830C){ uint16_t wp=cpu.getWP(); uint16_t r0=cpu.peekW(wp), r2=cpu.peekW(wp+4), r8=cpu.peekW(wp+16);
            if(r0>=0x4000 && r0<0x6000) fprintf(stderr,"[BAD DISPATCH r0=%04X (dead) r2=%04X entry@%04X pcodePC r8=%04X]\n",r0,r2,r2-2,r8);
            if(g_pcodelog&&reachedEntry&&g_kscanHits>=g_pcodeafter) fprintf(g_pcodelog,"%04X %04X\n",r8,r0);
            if(g_snappcode>=0 && !g_snapped2 && r8==(uint16_t)g_snappcode && g_kscanHits>=g_pcodeafter && g_snappcodeskip-->0){}
            else if(g_snappcode>=0 && !g_snapped2 && r8==(uint16_t)g_snappcode && g_kscanHits>=g_pcodeafter){ g_snapped2=true;
                fprintf(stderr,"=== SNAPPCODE r8=%04X insn=%ld WP=%04X ===\n",r8,insnCount,wp);
                for(int r=0;r<16;r++) fprintf(stderr," R%-2d=%04X%s",r,cpu.peekW(wp+2*r),(r&3)==3?"\n":"");
                FILE*rf=fopen("snap_ram.bin","wb"); fwrite(expRam+0x2000,1,0x2000,rf); fclose(rf);
                FILE*hf=fopen("snap_hram.bin","wb"); fwrite(expRam+0xA000,1,0x6000,hf); fclose(hf);
                fprintf(stderr,"  dumped RAM 2000-3FFF (snap_ram.bin) + A000-FFFF (snap_hram.bin)\n"); } }
        if(diskOn && g_pc==0x40e8){ // TICC sector access: 834A=sector, 834C=drive(1-3), 834D=0:write/else:read, 834E=VDP buffer
            // The real TI disk-controller sector wrapper CLEARS the error-status byte at
            // 0x8350 on entry (it's zero unless an error occurs).  The p-code leaves stale
            // data there (e.g. the sector's high byte), so without this clear the loader
            // reads a phantom error -> "Bad file" / partial reads on higher sectors.
            cpu._memWriteB(0x8350, 0);
            int nDrive=cpu._memReadB(0x834C);
            uint16_t sector=cpu.peekW(0x834A), buf=cpu.peekW(0x834E);
            uint8_t isRead=cpu._memReadB(0x834D);
            bool ok=false;
            if(nDrive>=1 && nDrive<=3 && !diskImgs[nDrive].empty() && (buf+256)<=0x4000){
                std::vector<uint8_t>& img=diskImgs[nDrive];
                size_t off=(size_t)sector*256;
                if(off+256<=img.size()){
                    if(isRead){ memset(&vram[buf],0,256); memcpy(&vram[buf],&img[off],256); }
                    else      { memcpy(&img[off],&vram[buf],256); }
                    ok=true;
                }
            }
            if(ok){ cpu.branch(0x4676); g_pc=0x4676; }     // DSR success return (post read/write-verify)
            else  { cpu.branch(0x42a0); g_pc=0x42a0; }     // error 31 (not found)
        }
        if(g_pc==0x40D6){ uint16_t wp=cpu.getWP(); fprintf(stderr,"@40D6 WP=%04X R11=%04X\n",wp,cpu.peekW(wp+22)); }
        if(g_cr15&&reachedEntry&&g_kscanHits>=800){ static uint16_t ul=0; uint16_t nn=(g_pc>=0x6000&&g_pc<0x8000)?g_pc-0x2000:g_pc; if((nn==0x34AC||nn==0x34EE||nn==0x34DC||nn==0x5652||nn==0x58FC||nn==0x5796)&&nn!=ul){ul=nn; fprintf(stderr,"[UNITCALL %04X kscan=%ld]\n",nn,g_kscanHits);} }
        pcring[pcringi++&63]=g_pc;
        if(g_gromdrv&&reachedEntry){ uint16_t np=(g_pc>=0x6000&&g_pc<0x8000)?g_pc-0x2000:g_pc; if(np==0x58FC){ uint16_t wp=cpu.getWP(); fprintf(stderr,"[GROMUST R9(drive)=%d kscan=%ld]\n",cpu.peekW(wp+18),g_kscanHits); } else if(np==0x56F4||np==0x5796||np==0x5652||np==0x5736||np==0x5268||np==0x5818||np==0x5924){ static uint16_t last=0; if(np!=last){last=np; fprintf(stderr,"[GROMDRV %04X kscan=%ld]\n",np,g_kscanHits);} } }
        if(trace_gromcov){ int idx=(g_pc>=0x8300&&g_pc<0x8400)?(0x8000|(g_pc&0xff)):g_pc; if((g_pc>=0x2000&&g_pc<0x4000)||(g_pc>=0x8300&&g_pc<0x8400)||(g_pc>=0xa000)){ if(gromSrc[idx]>=0) gromCode[gromSrc[idx]]=1; } }
        if(trace_cov){
            if(g_pc>=0x4000&&g_pc<0x5000) covShared[g_pc-0x4000]=1;
            else if(g_pc>=0x5000&&g_pc<0x6000) (pcodeBank?covBankD:covBankC)[g_pc-0x5000]=1;
        }
        if(exectrace && g_pc!=lastexecpc && g_kscanHits>=g_pcodeafter){
            uint16_t np=g_pc;
            if(g_pc>=0x6000 && g_pc<0x8000) np=g_pc-0x2000;   // cart ROM -> DSR-equiv
            if(!execStarted && np==0x4038) execStarted=true;  // align both traces at the entry point
            if((execStarted||g_pcodeafter>0) && (np<0x2000||(np>=0x2000&&np<0x6000)||(np>=0x8300&&np<0x8400)||(np>=0xa000))){
                fprintf(exectrace,"%04X:%04X\n",np,cpu.peekW(g_pc)); lastexecpc=g_pc;
            }
        }
        if((catch4000||g_catchexec) && !diskOn && g_pc>=0x4000 && g_pc<0x6000){ fprintf(stderr,"\n*** CATCH: EXEC at >%04X ***\n  recent PCs:",g_pc); for(int k=1;k<=24;k++){ fprintf(stderr," %04X",pcring[(pcringi-k)&63]); } fprintf(stderr,"\n"); break; }
        if(!enteredDsr && g_pc>=0x4000 && g_pc<0x6000){ enteredDsr=true; fprintf(stderr,">>> executing p-code DSR ROM at insn %ld pc=%04X (bank=%d)\n",insnCount,g_pc,pcodeBank); }
        if(!enteredCart && !cart.empty() && g_pc>=0x6000 && g_pc<0x8000){ enteredCart=true; fprintf(stderr,">>> executing CART ROM at insn %ld pc=%04X (cartBank=%d)\n",insnCount,g_pc,cartBank); }
        // KSCAN hook
        if(g_pc==0x0478){ g_kscanHits++;
            if(!g_screenkscan.empty()){ auto si=g_screenkscan.find(g_kscanHits); if(si!=g_screenkscan.end()){ fprintf(stderr,"--- screen @kscan %ld (insn %ld) ---\n",g_kscanHits,insnCount); dumpNameTable(cpu); g_screenkscan.erase(si); } }
            uint16_t wp=cpu.getWP();
            if(!keySched.empty()){
                auto it=keySched.find(g_kscanHits);
                if(it!=keySched.end()){ uint8_t ch=it->second;
                    cpu._memWriteB(wp, ch);
                    uint8_t st=cpu._memReadB(0x837C);
                    cpu._memWriteB(wp+12,(st|0x20));
                    fprintf(stderr,"[sched key '%c'(%02X) at kscan %ld insn %ld]\n",ch>=0x20?ch:'?',ch,g_kscanHits,insnCount);
                }
            }
            else if(keyIdx<keyQueue.size() && insnCount>=keyReleaseUntil){
                uint8_t ch=keyQueue[keyIdx];
                cpu._memWriteB(wp, ch);
                uint8_t st=cpu._memReadB(0x837C);
                cpu._memWriteB(wp+12,(st|0x20));
                fprintf(stderr,"[inject key #%zu '%c'(%02X) at insn %ld kscanHits=%ld]\n",keyIdx,ch>=0x20?ch:'?',ch,insnCount,g_kscanHits);
                keyIdx++;
                keyReleaseUntil=insnCount+FRAME*4; // release for a few frames
            }
            else if(keyIdx>=keyQueue.size() && postIdx<postKeys.size() && (postKscan>0 ? g_kscanHits>=postKscan : insnCount>=postAt) && insnCount>=keyReleaseUntil){
                uint8_t ch=postKeys[postIdx];
                cpu._memWriteB(wp, ch);
                uint8_t st=cpu._memReadB(0x837C);
                cpu._memWriteB(wp+12,(st|0x20));
                fprintf(stderr,"[inject POSTkey #%zu '%c'(%02X) at insn %ld kscanHits=%ld]\n",postIdx,ch>=0x20?ch:'?',ch,insnCount,g_kscanHits);
                postIdx++;
                keyReleaseUntil=insnCount+FRAME*4;
            }
        }
        uint16_t op=cpu.fetch();
        cpu.execute(op);
        if((insnCount%FRAME)==0){
            vdpStatus|=0x80;                       // VDP vblank flag: hardware sets it every frame, even with CPU ints masked
            bool intsOff = noVdpInt || (intUntilEntry && reachedEntry);  // --int-until-entry: cut CPU ints at the entry point
            if(!intsOff && (vdpRegs[1]&0x20)) vdpIntPending=true;  // only DELIVER a CPU interrupt when enabled
        }
        if(dumpAt>0 && insnCount==(long)dumpAt*FRAME){ dumpNameTable(cpu); }
    }
    fprintf(stderr,"stopped after %ld insns, pc=%04X, pcodeOn=%d bank=%d cartBank=%d\n",
            insnCount,cpu.getPC(),pcodeOn,pcodeBank,cartBank);
    { fprintf(stderr,"recent PCs:"); for(int k=1;k<=32;k++) fprintf(stderr," %04X",pcring[(pcringi-k)&63]); fprintf(stderr,"\n"); }
    if(!g_vdpliFile.empty()){ FILE*vf=fopen(g_vdpliFile.c_str(),"w"); for(long p:g_vdpli) fprintf(vf,"%04lx\n",p); fclose(vf); fprintf(stderr,"VDP-address li's (feed 0x8C02): %zu -> %s\n",g_vdpli.size(),g_vdpliFile.c_str()); }
    fprintf(stderr,"GROM chips accessed (bitmask, bit N=chip N): %02X\n",g_chipmask);
    fprintf(stderr,"total KSCAN hits=%ld, keys consumed=%zu/%zu, consoleGROM cgAddr=%04X\n",g_kscanHits,keyIdx,keyQueue.size(),cgAddr);
    if(g_gromanalysis){
        const char*rn[3]={"scratchpad(8300-83FF)","cartROM(6000-7FFF)","other"};
        fprintf(stderr,"=== GROM ACCESS BY ACTIVE CART BANK (Milestone-B analysis) ===\n");
        for(int b=0;b<2;b++){
            long tot=0; for(int t=0;t<2;t++)for(int r=0;r<3;r++)tot+=g_gromAcc[b][t][r];
            fprintf(stderr,"  cartBank %d (%s): total=%ld\n",b,b?"D":"C",tot);
            for(int t=0;t<2;t++)for(int r=0;r<3;r++) if(g_gromAcc[b][t][r])
                fprintf(stderr,"      %s from %s: %ld\n",t?"ADDR":"DATA",rn[r],g_gromAcc[b][t][r]);
            fprintf(stderr,"      distinct access PCs (normalized): ");
            int n=0; for(int p:g_gromPCs[b]){ fprintf(stderr,"%04X ",p); if(++n>=40){fprintf(stderr,"...");break;} }
            fprintf(stderr,"\n");
        }
        fprintf(stderr,"  C<->D code-bank switches after entry: %ld\n",g_cdSwitches);
    }
    if(trace_gromcov&&gromcovOut){ FILE*f=fopen(gromcovOut,"w"); int n=0; for(int i=0;i<pgGromLen;i++){ if(gromCode[i]){fprintf(f,"%04X\n",i); n++;} } fclose(f); fprintf(stderr,"gromcov: %d GROM code bytes -> %s\n",n,gromcovOut); }
    { fprintf(stderr,"RAM 2050-2090:"); for(int a=0x2050;a<0x2090;a+=2) fprintf(stderr," %02x%02x",expRam[a],expRam[a+1]); fprintf(stderr,"\n"); }
    { fprintf(stderr,"CODREAD 2CFA (port per (drive-15)*2):"); for(int a=0x2CFA;a<0x2D1C;a+=2) fprintf(stderr," %02x%02x",expRam[a],expRam[a+1]); fprintf(stderr,"\n");
      fprintf(stderr,"ADDROFS 2D6C (addr per unit):"); for(int a=0x2D6C;a<0x2D8E;a+=2) fprintf(stderr," %02x%02x",expRam[a],expRam[a+1]); fprintf(stderr,"\n");
      fprintf(stderr,"per-unit tables  unit: SERBUF PCBPNT  UNITPNT DRVNUM CODREAD ADDROFS\n");
      for(int u=13;u<=20;u++){ int drv=expRam[0x2BFC+u]; int off=(drv-15)*2;
        fprintf(stderr,"  #%2d: %02x    %02x%02x    %02x%02x    %02x     %02x%02x    %02x%02x\n",u,
          expRam[0x29B8+u], expRam[0x29DC+u*2],expRam[0x29DD+u*2],
          expRam[0x2C20+u*2],expRam[0x2C21+u*2], drv,
          (off>=0&&off<0x22)?expRam[0x2CFA+off]:0,(off>=0&&off<0x22)?expRam[0x2CFB+off]:0,
          (off>=0&&off<0x22)?expRam[0x2D6C+off]:0,(off>=0&&off<0x22)?expRam[0x2D6D+off]:0); } }
    if(dumpsrcOut){ FILE*f=fopen(dumpsrcOut,"w"); for(int i=0;i<0x10000;i++) if(gromSrc[i]>=0) fprintf(f,"%04X %04X\n",i,gromSrc[i]); fclose(f); fprintf(stderr,"dumped RAM->GROM provenance to %s\n",dumpsrcOut);}
    dumpNameTable(cpu);
    if(trace_scratch){
        fprintf(stderr,"--- scratchpad 8300-83FF usage map (X=touched, .=free) ---\n");
        for(int i=0;i<0x100;i++){
            if((i&0x0f)==0) fprintf(stderr,"83%02X: ",i);
            fprintf(stderr,"%c",scratchWritten[i]?'X':'.');
            if((i&0x0f)==0x0f) fprintf(stderr,"\n");
        }
        // report contiguous free runs
        fprintf(stderr,"free runs: ");
        int run=0,start=0;
        for(int i=0;i<=0x100;i++){
            bool free=(i<0x100)&&!scratchWritten[i];
            if(free){ if(run==0)start=i; run++; }
            else { if(run>=2) fprintf(stderr,"83%02X-83%02X(%d) ",start,start+run-1,run); run=0; }
        }
        fprintf(stderr,"\n");
    }
    if(trace_ram){
        auto report=[&](int lo,int hi,const char*nm){
            fprintf(stderr,"--- %s free 2+ byte runs (never touched in this run) ---\n",nm);
            int run=0,start=0,total=0;
            for(int i=lo;i<=hi;i++){
                bool free=(i<hi)&&!ramUsed[i];
                if(free){ if(run==0)start=i; run++; total++; }
                else { if(run>=2) fprintf(stderr,"  %04X-%04X (%d bytes)\n",start,start+run-1,run); run=0; }
            }
            fprintf(stderr,"  [%s total free bytes: %d]\n",nm,total);
        };
        report(0x2000,0x4000,"2000-3FFF");
        report(0xA000,0x10000,"A000-FFFF");
    }
    if(trace_cov && covOut){
        FILE*f=fopen(covOut,"w");
        int ns=0,nc=0,nd=0;
        for(int i=0;i<0x1000;i++){ ns+=covShared[i]; nc+=covBankC[i]; nd+=covBankD[i]; }
        fprintf(f,"# opcode-start coverage. cols: addr shared bankC bankD (1=executed opcode start)\n");
        fprintf(f,"# executed opcode starts: shared=%d bankC=%d bankD=%d\n",ns,nc,nd);
        for(int i=0;i<0x1000;i++)
            fprintf(f,"%04X %d %d %d\n",0x4000+i,covShared[i],0,0);
        for(int i=0;i<0x1000;i++)
            fprintf(f,"%04X %d %d %d\n",0x5000+i,0,covBankC[i],covBankD[i]);
        fclose(f);
        fprintf(stderr,"coverage written to %s (shared=%d bankC=%d bankD=%d opcode starts)\n",covOut,ns,nc,nd);
    }
    return 0;
}
