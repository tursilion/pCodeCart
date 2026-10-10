# TI‑99/4A UCSD p‑System — Card → Cartridge conversion: key findings

Snapshot of the important, hard‑won findings from converting the TI p‑code **PEB
card** (banked DSR ROM at `>4000‑5FFF` + 8 custom GROM chips on private ports
`>5BFC/5BFE/5FFE`) into a **cartridge** at `>6000‑7FFF`. Two approaches were built;
**Approach B boots.**

---

## 0. TL;DR / current state  (updated 2026‑10‑10)

* **Approach B (CHOSEN, WORKING):** the 8 p‑code GROMs live as **real GROM in the
  console GROM address space** (`>9800` ports); the DSR ROM is relocated to
  `>6000‑7FFF`. `cartB2.bin` + `cartgrom_b.bin`. This is the recommended path (§5).
* **Milestone reached:** the cart **boots standalone to the `Command:` prompt**,
  **every command‑menu option works**, and — with disk images on DSK1/2/3 — the
  **Editor, Filer, AND the Pascal Compiler all run end‑to‑end**: the compiler compiles
  `#4:HELLO` → `#4:HW` → "3 lines compiled", matching the original card exactly.
  User‑confirmed on the target. The old "editor loads then crashes into `>50xx`" is
  resolved. **H(alt)** reboots cleanly and the cart can be re‑entered (it clears the
  p‑System "don't boot" flag at `0x38FA` before the reset — see §7a).
* **ROM disk (2026‑10‑10):** the system programs (Editor, Filer, Compiler,
  Assembler, Linker, SYSTEM.LIBRARY) now ship on the cart as read‑only unit **`#12
  PSYS:`** (cart banks 4‑48, driver at RAM `0x3E00`), so only a data disk is needed.
  Deliverable is `romcart.bin` (512 KB). Only known gap: SYSTEM.LIBRARY is looked up
  on the root volume, not `#12`. Details in `PORT_KNOWLEDGE.md` §12.
* **Approach A (paged‑ROM in cart banks):** prototype only — Milestone‑A boots to the
  prompt but the full paged‑GROM version hit the interpreter‑core "WALL" (§4) and was
  superseded by B.
* **Next:** deeper testing (compiler/assembler/linker, real workfile save), plus
  real‑hardware validation (the sim is functional, not cycle‑accurate).

Build/test: see §7. Full narrative + all bug fixes: see `PORT_KNOWLEDGE.md`.

---

## 1. Hardware / ROM facts (verified)

* DSR ROM: `PCardC.ROM` (bank0) / `PCardD.ROM` (bank1), 8 KB each. `>4000‑4FFF`
  byte‑identical between banks (shared); only `>5000‑5FFF` differs (banked half).
* Card header at `>4000`: `AA 01`, program‑ptr `>7FF0` (bogus). The original card
  takes over via the console **DSR power‑up scan** (CRU `>1F00` polled), *not* the
  program chain. The cart drives startup from the program chain instead.
* CRU `>1F00` bit0 = enable DSR+GROM ports; CRU `>1F80` bit0 = ROM bank select
  (SBO→D, SBZ→C). Both become ROM‑write banking / no‑ops on the cart.
* Custom p‑code GROM: 8 chips × `0x2000`, each uses `0x0000‑0x17FF` (6 KB) + 2 KB
  zero pad. Ports (odd byte ignored): `>5BFC` read data (auto‑inc, 1‑byte
  prefetch), `>5BFE` read addr, `>5FFE` write addr (2 writes), `>5FFC` write data
  (unused). Auto‑increment **wraps within the 8 KB chip**: `adr=((adr+1)&0x1FFF)|
  (adr&0xE000)`. p‑code steps chip→chip by re‑setting the address (≈ `+0x0802` at
  offset `0x17FE`); the top 2 KB of each chip is never read.
* **Boot uses all 8 chips** (`--gromanalysis` chip mask = `0xFF`). Disk and
  interrupts are **not** required to reach the prompt.

## 2. Simulator (build/ti99sim.cc)

A minimal TI‑99/4A that boots the card to the prompt; the workhorse for this whole
project. Key flags added:

* `--int-until-entry` — **the enabling test trick.** Run the GPL OS/console boot
  *with* interrupts, then disable CPU‑interrupt delivery at the card/cart entry
  point (normalized PC `0x4038`, cart `0x6038`). This makes the original (auto‑DSR
  takeover) and the cart (console‑menu launch) comparable, and matches "the card
  runs interrupt‑free."  NOTE: the VDP vblank *status* bit must still set each frame
  even with CPU ints masked (real HW behavior) — separate from int delivery.
* `--gromconsole` — Approach B model: serve the p‑code GROM as **real GROM in
  console space** (see §5), one shared address counter, base‑selected.
* `--gromreadlog FILE` — log every GROM **data byte** delivered post‑entry. Diffing
  this between a known‑good cart and a candidate is **the** debugging oracle: the
  first differing byte pinpoints the exact broken GROM address op.
* `--gromfromcart` — Approach‑A model (serve GROM from paged cart banks at `HOFF`).
* `--snap PC`, `--watch ADDR`, `--vdptrace`, `--gromanalysis`, `--exectrace`
  (entry‑gated, normalizes cart `6xxx/7xxx → 4xxx/5xxx`).

Debug method that repeatedly worked: capture entry‑gated exec traces / read‑byte
streams for baseline vs candidate, `diff`, land on the first divergence, then
`--snap`/`--watch` the registers/RAM there.

## 3. The four relocation bugs that caused the Milestone‑A crash

The cart crashed ("Bad optype", system restart). Root causes, all found by
trace‑diff + snapshots, all in the relocation tooling:

1. **`reasm.py` relocated bitmask immediates.** `ori r9,>4000` (the VDP
   write‑enable bit) got its `>4000` symbolized as a label and relocated to
   `>6000`, so every VDP access went `+0x2000` → structure read back as spaces →
   crash. Fix: never relocate `andi`/`ori` immediates (they are masks, not
   addresses). `li`/`ai`/`ci` may still relocate. Latent in the byte‑identical
   original build (labels resolve to the same address at `0x4000`).
2. **`patchgrom.py` relocated a DSR‑scan probe.** `li r3,>4000; cb *r3,@2cac` (GROM
   `F604`) — `>4000` is the **external PEB card window** (compared against the
   expected header `>AA` at RAM `>2CAC`), not the p‑code card's own ROM. Fix: mark
   a no‑reloc window around every `@>2CAC` operand. `@4000` means **both** "my own
   header → 6000" and "external card window → stay 4000" depending on context.
3. **`patchgrom.py` relocated GROM/VDP ports.** `>5BFC` (GROM data port at GROM
   `EF7A`) → `>7BFC`, so GROM reads hit cart ROM. Fix: exclude
   `>5BFC/5BFE/5FFC/5FFE` from all relocation paths (`reasm.py` already did).
4. **`patchgrom.py` never relocated the opcode dispatch table.** The 256‑entry
   p‑code opcode table at GROM `F02E‑F22C` (copied to RAM `~2DB2`, indexed by
   opcode) held DSR‑ROM handler pointers that aren't in `rom_targets` so the strict
   detector skipped them → `b *r0` where `r0=@4CDE=0` → wild jump. Fix: also treat a
   run of ≥6 consecutive pointer‑like words as a dispatch table.

After these, the Milestone‑A cart boots. The **only** remaining exec difference vs
the original is a benign 6‑instruction DSR self‑scan block (`33A4‑33AE`): the
original finds the p‑code card on CRU `1F00` and reads its (empty) DSR‑list
pointer; the cart has no CRU DSR so it skips it. Confirmed inconsequential.

## 4. Why paged‑GROM (full Approach A) was hard — "THE WALL"

* The p‑code interpreter's hot path is a set of scratchpad fetch primitives at
  `>8300` (loaded from GROM by the loader at `>4FC2`) doing `movb *r13` where
  `r13` = the GROM data port. ~240 K reads rely on the **persistent hardware
  auto‑increment counter**; address‑set is a separate, less‑frequent op.
* To page GROM into cart ROM banks, each `movb *r13` must become a bank‑switch +
  read + persistent‑PGADDR update. A `bl` is 4 bytes vs `movb` 2, and the primitive
  segments end in a **dispatch** (`b *r2`/`b *r0`), not a return — so they can be
  reproduced in ROM and reached by a plain `b @` trampoline, but the read core must
  survive a cart‑ROM bank switch (replicated tail or RAM).
* Blocking issue: the code banks are **95 % full dense live code** with essentially
  no reclaimable CRU/dead code (bank C had 0 CRU ops), so there was no in‑place
  room for the ~106‑byte read core. RAM placement is possible but B avoids the
  whole problem.

## 5. Approach B — real GROM in console GROM space (BOOTS)

**Idea:** put the p‑code GROMs on the cart as real GROM chips in the **console GROM
address space**. Then `movb *r13` with `r13 = >9800` reads them via real hardware —
the entire interpreter hot path is untouched (no WALL). The cart ROM is just the
2 DSR code banks + a small loader bank.

**Console GROM hardware model (from the card's author):**
* One **shared** 16‑bit GROM address counter across all GROMs.
* Console GROMs answer for addr `0x0000‑0x5FFF` at **any** base; you can only use
  `0x6000‑0xFFFF` for cart GROMs (40 KB per base).
* The **base** = which port group: `>9800` = base0, `>9804` = base1, `>9808` =
  base2 (add 4 per base). For `0x6000‑0xFFFF` the base selects which chip‑set
  answers.
* **3‑base workaround for a known console bug:** the console diffs base0 vs base1
  at power‑up. Load the *same* GROM into base0 **and** base1 (a duplicate, no extra
  hardware), and the *other* GROM into base2. p‑code banks via base0 / base2.
  Because `pgGrom[0]=0xFA` (≠`AA`) the console ignores the cart GROM as a
  bootable module, and the base0==base1 duplicate dodges the diff bug — the menu
  works with the cart GROMs visible.

**Address translation (the only software change needed):** p‑code GROM addr → console:
* bank0 (`pcode < 0xA000`, chips 0‑4): `console = pcode + 0x6000`, base `>9800`
  (write‑addr `>9C02`). High byte `+= 0x60`.
* bank2 (`pcode >= 0xA000`, chips 5‑7): `console = pcode − 0x4000`, base `>9808`
  (write‑addr `>9C0A`). High byte `−= 0x40`.
Chip boundaries align with the `0xA000` bank boundary, so no chip straddles banks;
the base only ever changes at an address‑set. **Data reads are unchanged** (real
GROM does auto‑inc/prefetch). Address read‑back is not used by the p‑code
(`RDADDR` count = 0), so no reverse translation was needed.

**Where it goes:** the translation helpers live in **RAM at `0x3A00`** (534 bytes,
inside the boot‑free `3906‑3FFF` region; scratch temps at `3FF6/3FF8`), copied
there at boot by a tiny loader in cart bank 2. Boot flow:
`record@6008 → ENTRY@7FF0 (clr @6004=bank2; b @6100) → loader copies ramhelp→3A00
→ b @7FF8 (STARTSTUB, replicated: clr @6000; b @6038)`.

**Converted GROM address‑set operations** (there is *one* seed `li r4,>5FFE` plus
the `@2cfa` source‑ptr table, feeding base regs `r1/r4/r5/r13`; `EF7A` reseeded
`5BFC→9800`):
| site | base | how | file/entry |
|------|------|-----|-----------|
| startup `L4048` | r4 | literals → `9C0A`/`A804` | patchdsr |
| `L4144` / `L4178` | r13 | trampoline → `RAM_A`/`RAM_B` (XLAT) | patchdsr/ramhelp |
| `L59B4` | r5 | trampoline → `RAM_59B4` (clean bl entry) | patchdsr/ramhelp |
| `L584A`/`L5864` | r5 | in‑place 8B block → `b @HELP584A/B` + nops (r6 stays PCODE for the chip‑step arithmetic) | patchdsr/ramhelp |
| `L4F70` A/B | r1 | in‑place 14B blocks → `b @HELP4F70A/B`, return `L4F8C` | patchdsr/ramhelp |
| `L50B2`/`L50C0` | r1 | trampoline (return `b *r6`) → `RAM_50B2/50C0` | patchdsr/ramhelp |

**Result:** `cartB2.bin` reads the same 293,018 GROM bytes as the reference; only
the reseeded r13‑port constant differs (`9800` vs `5BFC`, read ~36×). Boots to the
identical prompt.

Two conversion patterns worth remembering:
* **Clean bl/dispatch entry** → replace the entry with a plain `b @RAM_helper`; the
  helper reproduces the routine + translation and ends in the routine's own
  dispatch/return (r11 untouched because entry was a plain branch).
* **Mid‑routine inline write** (reached by fall‑through/`jne`) → replace the 8/14‑byte
  write block *in place* with `b @HELPxxx` + `1000` nops; the helper translates,
  writes, and **hard‑codes** the return address (no `bl`, so the routine's r11 is
  never clobbered). Keep any address register the routine does arithmetic on in
  **pcode space** — translate to a scratch only at the port write.

## 6. Files in this folder

* **`bin/`** — exactly the working cartridge to load (see `bin/LOAD.md` for the
  load map): `romcart.bin` (512 KB paged ROM at `>6000‑7FFF`, incl. ROM disk), `grom_base0_base1.bin`
  (40 KB GROM at `>6000` on base0+base1), `grom_base2.bin` (22.5 KB GROM at `>6000`
  on base2). These three files boot to the `Command:` prompt. `DATA.DSK` is an
  example data disk. (The two GROM images
  are the console‑space halves of the relocated GROM: chips 0‑4 and chips 5‑7.)
* `src/` — `ramhelp.s` (RAM helpers), `patchdsr.py` (in‑place DSR patches),
  `patchgrom.py` (GROM reloc + reseed), `make_cartB2.py`/`build_cartB2.sh`
  (Approach‑B build), `add_romdisk.py` (ROM disk → `romcart.bin`), `regress.sh`
  (sim regression tests), `reasm.py` (byte‑identical symbolic reassembler),
  `shared.s`/`c5.s`/`d5.s` (reassembled DSR sources), `ti99sim.cc`/`cpu.*`
  (simulator), plus the Milestone‑A build (`make_cart.py`/`build_cartA.sh`) and
  coverage inputs (`cov_boot.txt`, `gromcov_boot.txt`, `rom_targets.txt`).

## 7. Build & test

Requires the original dumps (`PCardC.ROM`, `PCardD.ROM`, `p1f00g_0000_f800.GRM`,
`994AROM.BIN`, `994AGROM.BIN`, `DISK.BIN`) one level up, and the tms9900 toolchain
at `~/newtms9900-gcc/newgcc9900/bin`.

```
# simulator
g++ -w -O2 ti99sim.cc cpu.cc -o ti99sim

# Approach B (build the cartA reference first; it produces cartgrom.bin):
bash build_cartA.sh          # -> cartA.bin  + cartgrom.bin   (EF7A=5BFC)
bash build_cartB2.sh         # -> cartB2.bin + cartgrom_b.bin (EF7A=9800) + romcart.bin
./regress.sh                 # regression smoke tests (romcart.bin + DATA.DSK)

# boot Approach B to the Command: prompt
./ti99sim --cart cartB2.bin --grom cartgrom_b.bin --nodsr --gromconsole \
          --nodisk --int-until-entry --keys "  2" --max 8000000

# baseline (original card) for comparison
./ti99sim --nodisk --int-until-entry --max 6000000
```

## 7a. Editor / Filer from disk — the path that got them working

Pressing `E` at the prompt originally jumped into `>40xx`/`>50xx` and crashed, because
reasm emits **coverage‑gap code** (paths not run during boot — editor/disk routines)
as raw `byte`/`data`, so their embedded address references were never relocated
`+0x2000`. Getting the Editor and Filer to load and run clean took, in order:

1. **`patchdsr.reloc_demoted` for `bl`/`b`:** relocate `bl(06a0)`/`b(0460)` operands
   still in `0x4000‑0x5FFF` inside demoted regions `+0x2000`. (Stops the `>40xx` jump.)
2. **reasm word‑alignment fix:** the demoted‑region pointer detector matched a
   "pointer" at an **odd** byte offset and split a real instruction (corrupting
   `mov r3,r1` on the editor path). Require pointer candidates to be word‑aligned.
3. **`L4166` converted** (sibling of `L4178`, shares the `L4180` address‑set tail) →
   `RAM_C`. Missing it set the GROM counter untranslated on the menu/editor path.
4. **Disk sector I/O wired in the sim** (`--disk`): hook the disk DSR at PC `0x40e8`
   when CRU base `>1100` is active, service the scratchpad request block, copy 256‑byte
   sectors between the raw image and VRAM, return success `0x4676`/error `0x42a0`.
   This is what actually lets `SYSTEM.EDITOR`/`SYSTEM.FILER` load.
5. **`reloc_demoted` extended to `li` immediates** (real code/data targets only, via a
   `realtgt` allow‑list) — fixed "Segment EDITOR not found" (an unrelocated
   `li r3,>40B4`). Note: the p‑System **stack‑overflows on *any* error**, so a
   "stack overflow" is a generic error symptom, not a literal stack bug.
6. **VDP address handling** (the subtle, highest‑value class — a VDP write‑address is
   `0x4000 | screen_pos`, so it *looks* like a ROM address):
   - un‑relocate `li rN,>4xxx` values that are actually written to the VDP addr port
     `>8C02`, detected by a sim register‑taint pass (`--taintvdp` → `vdpli.txt`);
   - **do not trampoline the VDP path of the L50A8 address‑set dispatcher.** That
     dispatcher picks device by the sign of r0 (`>0` GROM, `<0` VDP, `0` CPU); only the
     GROM path (`L50B2`) needs translation. `L50C0` (VDP) writes a VRAM address verbatim
     — trampolining it to a GROM helper diverted every VRAM‑sourced menu string's read
     address to the GROM port, drawing garbage. Fix: leave `L50C0` original. **This one
     fix cleared the garbled Quit/menu display on both the Editor and the Filer.**

Each was found by trace‑diffing cart vs original baseline and landing on the first
divergence (for the VDP garble: capture the first 100 VDP writes *after* the keypress
via `--vdpafterkscan` and diff). The three native entry‑point tables the expert's
disassembly flags (unit‑I/O `>2C68`, opcode `>2DB2`, KERNPROC `>2FB2`) were verified
correctly relocated in the GROM. **Shipped state: Editor and Filer load and run clean
from disk.**

**Demoted PME‑handler dispatch pointers (editor delete/left‑arrow crash).** The p‑code
interpreter's arithmetic/logic opcode handlers (ABI, ADI, LAND, …) each sit behind a
*self‑relative* dispatch word — a `.WORD` at address `A` holding `A+2` (pointer to the
handler right after it); the GROM opcode table points at `A`, the fetch reads it and
branches. reasm relocates these when the handler is covered, but demotes uncovered ones to
a raw `byte` run, leaving the pointer at `0x5xxx`. Executing that opcode then jumps into
dead DSR space — the editor's **D**elete + **left‑arrow** path hit ABI and branched to
`0x51F4` (should be `0x71F4`). Fix: `patchdsr.reloc_demoted` relocates any word at cart
addr `CA` whose value is `CA+2−0x2000` (an un‑relocated self+2 pointer); the signature is
unique per position so it never touches correct pointers or real code. Recovered 38 such
pointers in one pass — pre‑empting the same crash on every other uncovered opcode.

**H(alt) fix (cart‑specific behavior).** On H the firmware stamps a "don't boot" flag
(`'NO'`) at RAM `0x38FA` then software‑resets via `BLWP @0000` (RAM `0x3014`, from GROM
`0xF290`). On the cart that flag survives the reboot and bounces the user back to the
title with no way back in. Fix: patchgrom rewrites that `BLWP @0000` (size‑neutral
`0420 0000`→`0460 <HALTRESET>`) to branch into a new RAM helper `HALTRESET` =
`CLR @>38FA` ; `BLWP @0000`, clearing the flag just before the reset. H now reboots
clean and space,2 re‑enters the p‑System. (Verified in sim: `0x38FA` `0x4E4F`→`0x0000`
before reset; full reboot/re‑entry confirmed on the target.)

## 8. Open items / caveats

* **RAM helpers at `0x3A00`** + temps `3FF4/3FF6/3FF8`. The p‑code expert confirmed
  `STRTBUF` `3900‑3FFF` is a 1790‑byte unused area (only `3900` is cleared at
  startup), and the user independently verified it is **untouched** by the Editor
  and Filer tests — so `0x3A00` is **safe** (no longer treated as high‑risk). Still
  worth re‑confirming once the compiler/assembler run (they consume high‑mem).
* **Deeper testing still pending:** Compiler / Assembler / Linker, editing + saving a
  real workfile, longer sessions exercising the full opcode set and segment loader.
  Expect at most a few more fixes of the same finite class (unrelocated ref /
  unconverted routine / VDP address mis‑handled).
* **Real‑hardware validation** is the user's; the sim is functional, not
  cycle‑accurate. (The Editor/Filer "clean" results above are user‑confirmed on the
  target.)
* GROM address‑set routines outside the boot path (`r8`/`r10`‑based:
  `d5:1829/2047/2081`, `shared:1699/2170`) were in the scope list but did **not**
  break boot/editor/filer. Convert them with the same patterns if a later subsystem
  exercises them.
* The 3‑base console workaround depends on `base0==base1` **and**
  `pgGrom[0]=0xFA (≠AA)` so the console skips the cart GROM as a bootable module.
* `reasm.py` produces the DSR ROM **byte‑identical** to the originals when linked at
  `0x4000` (`build_original.sh` verifies), which is why relocation is trustworthy.
* **The VDP‑address rule** (bit the port twice): anything written to the VDP address
  port `>8C02` is a *screen* address and must **never** be relocated `+0x2000` or
  GROM‑translated — even though `0x4000|screen_pos` looks exactly like a DSR‑ROM
  address. This is the single trickiest ambiguity in the whole port (see §7a step 6).
