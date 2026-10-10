# TI-99/4A UCSD p-System "p-code card" → Cartridge port — Knowledge Dump

Status date: 2026-10-03. This document captures everything learned while converting
the TI p-code *card* (a PEB DSR card) into a plain paged-ROM *cartridge*, so it can be
shared / handed off. Working dir: `/mnt/d/work/ti/pcode_cart`, build artifacts in `build/`,
shareable binaries in `output/bin/`.

> **Checkpoint (2026-10-03):** the cart boots standalone, every command-menu option works,
> and — with disk images on DSK1/2/3 — the **Editor, Filer, AND the Pascal Compiler all run
> end-to-end**: the compiler compiles `#4:HELLO` to `#4:HW` → "3 lines compiled", matching
> the original card exactly. Multi-drive disk I/O (`--disk`/`--disk2`/`--disk3`) is wired in
> the sim. See §9 and §8 bug 9. Still to test: Assembler/Linker, editing+saving a real
> workfile, longer compiler sessions.

---

## 1. Goal

Turn the UCSD p-System p-code card into a cartridge that plugs into the console cartridge
port (no PEB, no DSR card). The original card is:

- **8 KB banked DSR ROM** at CPU `>4000–5FFF` (two 8 KB banks: `PCardC.ROM`, `PCardD.ROM`).
- **8 GROM chips** of p-System data, read through the card's **private GROM ports**
  `>5BFC` (read data, auto-increment), `>5BFE` (read addr), `>5FFE` (write addr),
  `>5FFC` (write data). These are NOT the console `>9800` GROM ports.
- Enabled/selected via **CRU**: `>1F00` bit0 = enable DSR+ports; `>1F80` bit0 = ROM bank
  select (SBO→D, SBZ→C).

A cartridge instead lives at `>6000–7FFF` with bank switching by **CPU write to `>600x`**
(write `6000+2N` selects bank N). There is no CRU, no PEB, no private GROM ports.

---

## 2. Two hard problems and the chosen approach

**Problem 1 — relocation.** Moving the DSR ROM from `>4000–5FFF` to `>6000–7FFF` means
every absolute address reference to `>4xxx/>5xxx` inside the ROM *and inside the GROM data*
(the GROM contains TMS9900 PME code with `b/bl @>4xxx` calls back into the ROM) must shift
by **+0x2000** (`4xxx→6xxx`, `5xxx→7xxx`). GROM-port / RAM / VDP references and relative
jumps stay unchanged. The ROM and GROM are coupled by absolute addresses **both ways**.

**Problem 2 — the GROM.** A cartridge can't present the card's private GROM ports. Two
approaches were explored:
- **Approach A / "Milestone A"**: keep GROM data in extra cart banks, read via a
  bank-switch stub. (Prototyped, then set aside.)
- **Approach B (CHOSEN, WORKING)**: put the p-code GROM data into **real GROM chips in the
  cartridge, addressed in console GROM space** (`>9800` ports). The console answers GROM
  `0x0000–0x5FFF` at *any* base; for `0x6000–0xFFFF` the CPU's port **base** selects which
  GROM set answers. So the p-code GROM is mapped into console `0x6000–0xFFFF`:
  - **base0** (`>9800`): p-code addr `0x0000–0x9FFF` at console `0x6000–0xFFFF`  (pcode = console − 0x6000)
  - **base2** (`>9808`): p-code addr `0xA000–0xF7FF` at console `0x6000–0xB7FF` (pcode = console + 0x4000)
  - base1 (`>9804`) is made a **duplicate of base0** to dodge a known console base0-vs-base1
    comparison bug (hence "3-base workaround").
  All GROMs share ONE 16-bit address counter (auto-increment wraps within an 8 KB chip).
  The DSR's GROM-access routines are rewritten to use the console write-addr / read-data
  ports with the address translated to console space and the right base selected.

**Key architectural fact:** p-code addresses used *inside* the firmware (program counters,
segment bases, dispatch pointers, e.g. register r8, RAM var `@0x2abe`, table `@0x2DB2`)
stay in **p-code space** (`0x0000–0xF7FF`). The translation to console GROM space happens
**only at the port access** (set address / read byte). This is why most of the firmware
didn't need changing — only the ~dozen routines that actually touch the GROM ports.

---

## 3. Cartridge image layout (`cartB2.bin`, 32 KB, 4 banks of 8 KB; shipped as the first 4 banks of `romcart.bin`, see §12)

```
bank0 = patched DSR bank C   (shared 6000-6FFF + banked 7000-7FFF, code)
bank1 = patched DSR bank D   (shared 6000-6FFF + banked 7000-7FFF, code)
bank2 = boot loader @6100 + the RAM-helper bytes @6118
bank3 = pad
```
Every bank carries a standard cartridge header so the console menu lists it:
- `>6000 = AA 01`; program-list pointer `@>6006 → record @>6008`; record entry `→ >7FF0`;
  name = "P".
- `ENTRY    @>7FF0`: `clr @>6004` (select bank2) ; `b @>6100` (loader)
- `STARTSTUB@>7FF8`: `clr @>6000` (select bank0) ; `b @>6038` (real DSR startup)

**Boot flow:** console title → user presses a key → menu → user presses **2** to select
cart "P" → console runs record entry `>7FF0` → loader (bank2) copies the RAM helpers to
`0x3A00` → `b >7FF8` → `clr >6000` (bank0) → `b >6038` (real startup) → "Command:" prompt.

The console starts the cart from the **menu**, NOT via DSR takeover (the cart has no CRU).
This is why the sim must inject the title/menu keypresses (see §6).

---

## 4. The RAM helpers (`ramhelp.s`, loaded to 0x3A00 at boot)

The DSR's GROM-access routines can't be patched in place (a console GROM access is longer
than the original private-port access, and needs address translation + base select). The
loader copies a block of helper routines into low RAM `0x3A00–0x3Cxx` at boot (this RAM is
free during boot). The in-ROM routines are replaced by a 4-byte `b @<helper>` trampoline
(size-neutral, no layout shift). Helpers run in the caller's workspace, save/restore any
scratch they clobber to RAM temps `0x3FF4/0x3FF6/0x3FF8`, and return via the original `b *r11`.

Translation core:
- `XLAT` (r0 MSB = pcode high byte): bank0 → high += 0x60, r13 = `>9800`; bank1 (pcode ≥ 0xA0)
  → high += 0xC0 (i.e. −0x40), r13 = `>9808` (base2). (write-addr base 9C02 / 9C0A for the
  r5-based variant `XLATW`.)

Converted routines (each a RAM helper + trampoline), found one at a time by trace-diffing:
`startup`, `L4144`→RAM_A, **`L4166`→RAM_C**, `L4178`→RAM_B, `L59B4`→RAM_59B4,
`L584A/L5864`→HELP584A/B, `L4F70`→HELP4F70A/B, **`L50B2`→RAM_50B2 (GROM path only)**.
One more RAM helper, `HALTRESET`, is **not** an address-set conversion but the H(alt) fix
(§8 bug 8): the GROM's reset-routine `BLWP @0000` is re-pointed at it so it clears the
"don't boot" flag before resetting.
(`L4166`/`L4178` are **sibling entry points** sharing one address-set tail `L4180`; both
had to be converted — missing `L4166` was a menu-path bug, see §8.)

**IMPORTANT — the L50A8 device address-set dispatcher is NOT all-GROM.** It selects the
device by the **sign of r0**: `r0>0` → GROM (`L50B2`), `r0<0` → **VDP** (`L50C0`), `r0==0`
→ CPU RAM. r1 holds the device port base (VDP `>8800`→`>8C02`; GROM `>9800`→`>9C02`). Only
the **GROM** path needs address translation → `L50B2`→RAM_50B2. The **VDP** path (`L50C0`)
writes a VRAM address **verbatim** and must be **left untouched** — trampolining it to a
GROM helper corrupts the VDP write-address (see §8 bug 5). This is the general rule: a
value destined for the VDP address port (`>8C02`) is a screen address, never a p-code/ROM
address, and must never be relocated or GROM-translated.

---

## 5. Build pipeline (`build/build_cartB2.sh`)

Tooling: a real TMS9900 toolchain at `~/newtms9900-gcc/newgcc9900/bin`
(`tms9900-as`, `tms9900-ld`, `tms9900-objcopy`, `tms9900-objdump`).

1. **`reasm.py`** — a *byte-identical symbolic reassembler*. Disassembles each ROM half to
   assembly with labels; linking the result at `0x4000` reproduces the ROM byte-for-byte,
   and linking at `0x6000` performs the +0x2000 relocation automatically (labels `L4xxx`→
   `0x6xxx`, `L5xxx`→`0x7xxx`). Uses a **coverage file** (`cov_boot.txt`: which addresses are
   executed opcode-starts, captured from the sim) to know what is code vs data. Uncovered
   regions are emitted as raw `byte`/`data` (**"demoted"**). Takes a coverage column arg
   (shared vs bankC vs bankD). Build is configurable: `COV=<file> bash build_cartB2.sh`
   (default `cov_boot.txt`).
2. Link bank0 = shared+c5 @0x6000, bank1 = shared+d5 @0x6000; truncate to 8 KB each.
3. **`ramhelp.s`** assembled/linked at `0x3A00` → `ramhelp.bin`.
4. **`patchdsr.py`** — installs the startup port patch and the `b @<helper>` trampolines
   over the GROM-access routines (addresses read from `ramhelp.elf`), plus a
   `reloc_demoted` pass that relocates `bl(06a0)/b(0460)` operands still pointing at
   `0x4000–0x5FFF` inside demoted regions (+0x2000).
5. **`patchgrom.py`** (run with `GROMCONSOLE=1`) — relocates the GROM-resident PME code's
   `>4xxx/>5xxx` refs (+0x2000), neutralizes the embedded CRU bank/on/off byte sequences,
   re-seeds the GROM-fetch base (`5BFC→9800`), and emits `cartgrom_b.bin`. It carefully
   separates GROM7 code from dispatch-tables from OS/p-code data (p-code is portable data,
   must NOT be relocated).
6. **`make_cartB2.py`** — assembles the 4-bank image + loader + headers → `cartB2.bin`.

Output GROM for the user's emulator/hardware is split by base:
`grom_base0_base1.bin` = `cartgrom_b.bin[0 : 0xA000]` (p-code 0x0000–0x9FFF),
`grom_base2.bin` = `cartgrom_b.bin[0xA000 : 0xF800]` (p-code 0xA000–0xF7FF).

---

## 6. The simulator (`build/ti99sim.cc` + `cpu.cc`, build `g++ -O2 -o ti99sim ti99sim.cc cpu.cc`)

A TI-99/4A sim just complete enough to boot the p-System: console ROM (`994AROM.BIN`),
console GROM (`994AGROM.BIN`), VDP, CRU, scratchpad, the p-code DSR (either via private
ports or, for the cart, console GROM), the disk DSR stub (`DISK.BIN`), and paged cart ROM.

Important flags:
- `--cart FILE` paged cart; `--grom FILE` p-code GROM data; `--gromconsole` serve the
  p-code GROM in console space (Approach B); `--nodsr` remove the original p-code DSR
  entirely (REQUIRED for a true standalone cart test — otherwise the sim keeps the
  original DSR live at `>4000` and the cart just rides its private ports).
- `--nodisk` no disk present (so loads fail with "Can't find SYSTEM.xxx"); `--noint`,
  `--int-until-entry` (enable CPU interrupts only until the cart entry `>6038` is reached,
  then mask — the p-System does not need interrupts to reach the prompt).
- **`--disk FILE`** mount a raw-sector disk image (e.g. `EDT-FIL.DSK`, 256-byte sectors,
  sector N at byte offset N·256). The sim services the TICC sector I/O by **hooking the
  disk DSR at PC `0x40e8`** when the disk CRU base `>1100` is active: it reads the
  scratchpad request block (`@>834A`=sector word, `@>834C`=drive 1–3, `@>834D`=0:write
  else read, `@>834E`=VDP buffer) and copies 256 bytes between the image and VRAM, then
  returns success→`0x4676` / error→`0x42a0`. This is what lets the Editor/Filer load from
  disk. (Flags added while wiring this: `--snapmem`, `--vdpafterkscan N`, `--basewarn`.)
- Key injection: `--keys STR` (immediate), `--postkeys STR --postat N` (after insn N),
  `--postkscan N` (after the Nth KSCAN hit — *program-relative*, reproducible),
  **`--keysched "kscan:char,..."`** (inject a specific char at a specific KSCAN-hit count;
  `_` means space). KSCAN hook is at PC `0x0478`; `@0x8375` is the returned key.
- Diagnostics: `--exectrace FILE` (normalizes cart `6xxx/7xxx → 4xxx/5xxx` so cart and
  baseline traces diff directly; format `PC:opcode`), `--gromreadlog`, `--vdptrace`,
  `--cov FILE` + `--gromcov FILE` (capture coverage), `--watch ADDR` (log writes to an
  8-byte window, works for `0x2000–0x3FFF` and `0x8300–0x83FF`), `--snap HEX`
  `--snapkscan N` `--snapskip N` (dump registers + key RAM/scratchpad at the Nth hit of a
  PC after a KSCAN count), `--catch4000` (trap any exec in dead DSR space).

**To run the standalone cart, boot to the prompt, and load the Editor from disk:**
```
./ti99sim --cart cartB2.bin --gromconsole --grom cartgrom_b.bin --nodsr \
          --int-until-entry --disk EDT-FIL.DSK \
          --keysched "50:_,100:2,5000:E,9000:~,13000:Q,17000:E"
```
(space@50 leaves the title, 2@100 selects the cart, E@5000 enters the editor, `~`=Enter@9000
opens the editor menu, Q@13000 opens the Quit menu, E@17000 exits back to Command.)
Use `--nodisk` instead for the no-disk menu tests (loads then stop at "Can't find …").

**Baseline (original card, for comparison):** no `--cart`, default DSR + private ports,
auto-starts via DSR: `./ti99sim --int-until-entry --nodisk --postkeys E --postkscan 5000`.

---

## 7. How bugs were found: the diagnosis method

The cart runs the SAME (relocated) firmware as the original card, so a normalized
exec-trace of the cart and the baseline should match. Procedure:
1. Capture both traces (cart with `--nodsr`, baseline with the original card), same key
   injected at the same KSCAN count.
2. Filter out the known-different helper/trampoline lines, align at a landmark (first
   `41CA` = key detected, then `50F0` = command dispatch), and diff forward to the **first
   real divergence**.
3. At a divergence, snapshot registers + RAM/scratchpad in both and see exactly what value
   differs; trace it to its source (a wrong byte, an unrelocated pointer, an unconverted
   routine, a clobbered register).

**Gotchas that cost time:**
- *Cursor-blink red herring:* the prompt's input loop (`L53D4`) blinks the cursor by
  toggling `@0x83C4` (0x0020↔0x2000) on an `li r3,0x01F4` delay. Registers r2/r3 and the
  prompt's trailing cursor character differ **purely by blink phase** at the instant the
  key lands. Not a bug.
- *Input timing:* inject keys by KSCAN count, not instruction count — the two runs reach a
  given instruction count at different program points, so insn-gated injection lands the
  key at different logical passes.
- *Matching dispatch-loop PCs mask data divergence:* the p-code interpreter's inner loop
  has the same PC pattern (`0x8300–0x830C`) regardless of what p-code it runs, so "identical
  PCs" did NOT mean "identical state." Bisect on the p-code program counter (register r8),
  not on PC equality.
- *Stale artifacts:* earlier traces made with the DSR left active (not `--nodsr`) are
  misleading; discard them.

---

## 8. Bugs found and fixed (this is the heart of the port)

Everything reduces to **"an address reference that should have been relocated/converted
wasn't, and it was only exercised on a code path we hadn't run yet."** Boot exercised one
set of paths; each menu option and (next) each loaded program exercises more.

1. **reasm odd-offset pointer false-positive.** `reasm.py`'s demoted-region pointer
   detector scanned byte-by-byte and matched a "pointer" at an **odd byte offset**,
   splitting a real instruction. Concretely at shared offset 0x944 the code
   `C0 43 06 A0 41 66` = `mov r3,r1 ; bl @4166` had its `43 06`=0x4306 matched as a pointer
   to label `L4306`; byte-identical at the `0x4000` link, but at the cart link it relocated
   `0x4306→0x6306`, corrupting `mov r3,r1`→garbage. This only ran on the editor path, so
   boot was fine. **Fix:** require pointer candidates to be word-aligned (TMS9900 pointers
   always are; an odd-offset match is always an instruction straddle).
2. **`L4166` left unconverted.** `L4166` and `L4178` are sibling entries that share the
   `L4180` GROM-address-set tail (which writes the address through register r13).
   `patchdsr` had converted `L4178`→`RAM_B` but not `L4166`, so `bl @4166` on the editor/
   command path set the console GROM counter via the raw, **untranslated** path → wrong
   console address → the p-code opcode stream read garbage → the interpreter eventually
   branched through a bad dispatch pointer into dead DSR space (`~>5E8C`) and crashed.
   **Fix:** added `RAM_C` to `ramhelp.s` (= `RAM_B` plus `L4166`'s `r15==0` quirk: swap r2
   if `@0x2ae8==0`) and `patchdsr` now converts `L4166` (offset 0x166)→`b @RAM_C`.
3. (earlier, Approach-A / Milestone-A era) several relocation bugs: a bitmask `ori r9,>4000`
   wrongly relocated; a DSR-scan probe `li r3,>4000` wrongly relocated; the GROM port
   `>5BFC` wrongly relocated; a missed dispatch table. All resolved by precise code/data
   separation and no-relocate windows in `reasm.py` / `patchgrom.py`.
4. **Demoted-region `li`/pointer references unrelocated (editor load path).** Beyond the
   `bl/b` relocation (§5 step 4), demoted (uncovered) regions also contain `li rN,>4xxx/5xxx`
   immediates and raw data **pointers** that are real code/data addresses. On the editor
   load path an unrelocated `li r3,>40B4` read dead space → "Segment EDITOR not found" and
   a p-System **stack-overflow** (the p-System's generic symptom for *any* error — do not
   read "stack overflow" literally). **Fix:** `patchdsr.reloc_demoted` now also relocates
   `li` immediates in `0x4001–0x5FFF`, but **only** when the target is a real code/data
   label (`realtgt` = labels referenced by non-`li` instructions + covered code-starts),
   so data constants that merely look like addresses are left alone.
5. **VDP address constants wrongly relocated / VDP dispatcher path wrongly converted.** The
   single hardest class, because a VDP **write-address** is numerically `0x4000 | screen_pos`
   — i.e. it *looks* like a DSR-ROM address in `0x4000–0x5FFF`. Two distinct bugs here:
   * **`li rN,>4BC0` relocated to `>6BC0`** (0x4BC0 = VDP addr for screen pos 0x0BC0): the
     SETADDR then pointed at VRAM `0x2BC0` → text drawn in the wrong place. **Fix:** a sim
     **register-taint pass** (`--taintvdp`) tags any `li rN,>4xxx` whose value is later
     written to the VDP addr port `>8C02`, and records that `li`'s PC in `vdpli.txt`;
     `patchdsr` then **un-relocates** exactly those. (User's rule: "a VDP address is written
     to `>8C02`; a relocated address never would be.")
   * **The L50C0 VDP dispatcher path over-trampolined** (the Editor/Filer "Quit menu drew
     garbage" bug). As noted in §4, the L50A8 address-set dispatcher routes `r0<0` to a
     **VDP** address write (`L50C0`) that needs *no* translation. It had been trampolined to
     a GROM helper, so every menu/prompt that stores its text in VRAM and reads it back
     through this dispatcher had its source VDP SETADDR diverted to the GROM port → garbage
     on screen. **Fix:** `patchdsr` no longer trampolines `L50C0`; the original VDP code
     runs in place. (Found by capturing the first 100 VDP writes *after* the keypress with
     `--vdpafterkscan` and diffing baseline vs cart — the first divergence was the cart
     skipping baseline's `SETADDR 1B44 pc=50C8`.) Fixing this one dispatcher cleared the
     garble on **both** the Editor and Filer quit/menus — a shared primitive.
6. **Disk-load entry-point tables — verified correct.** The expert's commented disassembly
   (`pCode Disassembly p-system.pdf`) documents three RAM tables of native entry points that
   hold DSR-space addresses and are loaded from GROM: the **unit-I/O ops** table (RAM
   `>2C68`, GROM src `0xEEE4`), the **p-code opcode dispatch** table (RAM `>2DB2`, GROM
   `0xF02E`), and the **KERNPROC** table (RAM `>2FB2`, GROM `0xF24A`). All three were
   checked in `cartgrom_b.bin` and are **correctly relocated** (DSR entries `+0x2000`; the
   KERNPROC table's **mixed** RAM-vs-ROM entries are handled correctly — RAM addresses left
   alone). `patchgrom.py` relocates GROM region `0xE808–0xF7FA` and these fall inside it.
7. **Demoted PME-handler dispatch pointers (`.WORD self+2`) unrelocated.** The p-code
   interpreter's arithmetic/logic opcode handlers (ABI, ADI, NGI, LAND, LOR, LDP, … — 57 of
   them across `0x48xx–0x5Fxx`) each sit behind a **self-relative dispatch word**: a `.WORD`
   at address `A` holding `A+2`, i.e. a pointer to the handler code immediately after it. The
   GROM opcode table points at `A`; the fetch loop reads the word at `A` and branches to it.
   reasm relocates these words (`+0x2000`) when the handler is **covered**, but an opcode
   whose handler wasn't exercised in the boot trace gets **demoted to a raw `byte` run**, so
   its pointer keeps the stale `0x5xxx` value. Executing that opcode then branches into dead
   DSR space — e.g. the editor's **delete + left-arrow** path hit `ABI` and jumped to
   `0x51F4` (should be `0x71F4`) and crashed. **Fix:** `patchdsr.reloc_demoted` now relocates
   any word at cart address `CA` whose value equals `CA+2-0x2000` (an un-relocated self+2
   pointer) by `+0x2000`. The signature is unique per position, so it never matches a
   correctly-relocated pointer (`CA+2`) or ordinary code/data — it recovered 38 demoted
   handler pointers (26 in bank0, 12 in bank1) in one pass, pre-empting the same crash for
   every other uncovered opcode, not just `ABI`.
8. **H(alt) "don't boot" flag — cart-specific behavioral fix.** The p-System reset
   routine (RAM `0x2FFE`, copied from GROM `0xF27A`) ends in `BLWP @0000` (console reset).
   On **H(alt)** the firmware first stamps a "don't boot" flag (`'NO'`, `0x4E4F`) at RAM
   `0x38FA` so the p-System won't auto-re-enter after the reboot. On the original *card*
   that is harmless (you power-cycle), but on the *cart* it strands the user: after H the
   console reboots to the title, and re-selecting the cart (space,2) sees the flag still set
   and bounces straight back to the title — no way back into the p-System. **Fix:** rewrite
   that final `BLWP @0000` (GROM `0xF290` → RAM `0x3014`; size-neutral `0420 0000` →
   `0460 <HALTRESET>`) into a branch to a new RAM helper `HALTRESET` that does
   `CLR @>38FA` (clear the flag) then the original `BLWP @0000`. Now H reboots cleanly and
   space,2 re-enters the p-System. (The GROM→RAM copy re-establishes the patched branch on
   every boot; `HALTRESET` lives with the other RAM helpers at `0x3A00`.) Verified in the
   sim: on H, `0x38FA` goes `0x4E4F` → `0x0000` before the reset. The full reboot+re-entry
   is confirmed on the target emulator (the minimal sim doesn't re-run a console power-up
   after a soft reset).

---

9. **Pascal COMPILER fails ("'PROGRAM' or 'UNIT' expected") — three distinct bugs.** The
   compiler loads and runs but rejects valid source. Found by diffing the p-code PC stream
   (register r8, logged at the interp fetch loop 0x830C) between the cart and the ORIGINAL
   card running the same compile (the baseline compiles correctly, so it's a reference +
   proves the disk emulation is sound). Three root causes, all the familiar relocation
   class, on compiler-only code paths:
   * **(a) Identifier buffer zero-filled instead of space-filled.** The lexer blanks its
     8-char id buffer with `MOV @40A2,*R4+` (@0x40A2 = `0x2020`, two spaces) then overwrites
     with the identifier, leaving space padding to match the space-padded reserved words.
     reasm had *demoted* this scanner (bank-C code, uncovered by boot) to raw bytes, so the
     `@40A2` operand wasn't relocated to `@60A2` -> read dead 0x40A2 = 0 -> buffer zero-
     padded -> "PROGRAM\0" != "PROGRAM " -> fail. **Fix:** feed reasm the compiler's coverage
     (see below) so the scanner disassembles as code and the operand relocates.
   * **(b) Reserved-word table relocated as if it were code pointers.** The keyword strings
     live in GROM at 0xF30C-0xF4CB ("@@@@@@@@", AND, .. PROGRAM, .. WITH; 8-char space-padded
     names + value byte). patchgrom's table/code relocation saw the ASCII words in
     0x4000-0x5FFF (e.g. "PR"=0x5052) as ROM pointers and +0x2000'd them -> "PROGRAM" became
     "pRoGrAm", so NO keyword was recognisable. **Fix:** mark GROM 0xF30C-0xF4CB no-reloc in
     patchgrom (it's ASCII data). [generalise: ASCII/data tables in the GROM-7 region must be
     excluded from pointer relocation.]
   * **(c) Demoted `li rN,<continuation>` in shared ROM unrelocated.** The call-external
     handler CXI (0x4D12) does `li r2,0x4D1A` (a continuation addr) then `b @LDUBB` which
     `b *r2`s to it. 0x4D1A is referenced ONLY by that li, so it wasn't a known target and
     reloc_demoted's li pass (which requires the target be a real code/data label) skipped
     it -> `b *r2` jumped to dead 0x4D1A and the compile stalled after "<2 >". **Fix:**
     extend reloc_demoted's `realtgt` allow-list with the compiler-run coverage's code-starts
     (so 0x4D1A is recognised as real code and the li relocates). This is a post-link operand
     patch; it does NOT change the disassembly, so no other path regresses.
   **Coverage strategy (important):** a FULL boot|compile coverage as the disassembly input
   fixes (a) but re-disassembles the whole ROM and REGRESSED the HALT path and shared-region
   blwp vectors (dual-use bytes). The safe split used in `cov_bc.txt`: SHARED column =
   boot-only (keeps vectors/HALT as data), BANK columns = boot|compile (adds the compiler's
   bank-C/D scanner). Shared-region demoted operands like (c) are then recovered surgically
   via the realtgt extension, not by changing shared disassembly. RESULT: `#4:HELLO` compiles
   to `#4:HW` -> "3 lines compiled", matching the original card exactly.
## 9. CURRENT STATUS — what works (2026-10-01 checkpoint)

Standalone cart (`--nodsr`). **All of the following match the original card** (only cosmetic
difference anywhere: the phase-dependent cursor-blink character at the prompt).

**Command menu (no disk):** every option works —
`E/R/C/F/L/A` → "Can't find SYSTEM.xxx", `X` → "What file?", `I` → re-initialize,
`U` → "U not allowed", `M` → Monitor menu, `?` → cycles the list, `D/S` match.
`H(alt)` now reboots **cleanly** and the cart can be re-entered (space,2) — see §8 bug 8;
previously H left the "don't boot" flag set and bounced back to the title.

**With disk images (DSK1/2/3): the Editor, Filer AND Pascal Compiler run end-to-end.**
Mount with `--disk EDT-FIL.DSK --disk2 COMPILER.DSK --disk3 ASM-LNK.DSK` (TICC drive byte
at `@>834C` selects drive 1-3; each image is raw 256-byte sectors, sector N at N*256).
- **Editor** (`EDT-FIL.DSK`): `E` loads SYSTEM.EDITOR → `>Edit: No workfile, File?`; Enter
  → editor menu; `Q` → Quit menu (character-identical to original); `E` exits to `Command:`.
  Delete + cursor-move works. (User-confirmed on the target.)
- **Filer**: loads; `V` lists the on-line **volumes** (shows units 4 EDT/FLR, 5 COMPILR,
  9 ASM/LNK); directory listing and quit all clean. (User-confirmed.)
- **Compiler**: `C` → "Compiling..." → "Compile?" → `#4:HELLO` → "To what codefile?" →
  `#4:HW` → compiles: `Pascal compiler - release 99/4 IV.0 C1a-` / `<0 >..` / `HELLO` /
  `<2 >.` / `3 lines compiled` — **matching the original card exactly** (§8 bug 9).

The earlier "editor loads then jumps into `>50xx` and crashes" is **resolved**; it was the
same class of bug as everything in §8 (unrelocated/over-converted references on paths that
only run once real p-code executes).

**Still to verify (deeper testing):** Assembler / Linker, editing and saving a real
workfile, and larger compiles. May surface a few more of the same finite class of fixes.

**Deliverables in `output/bin/`:** `romcart.bin` (512 KB cart incl. ROM disk, §12),
`grom_base0_base1.bin`, `grom_base2.bin`, plus `DATA.DSK` (example data disk).

---

## 10. Loading real programs from disk — feasibility (CONFIRMED tractable)

**This question is now answered in practice.** The earlier worry was: "SYSTEM.EDITOR loads
then jumps into `>50xx` and crashes — are all 500 KB of disk programs linked with hardcoded
card-ROM addresses that would each need porting?" The answer predicted below (**no — it's a
finite set of firmware fixes, not a data port**) has been **borne out**: wiring the disk
sector I/O (§6) and fixing a handful more firmware spots (§8 bugs 4–5) got the Editor and
Filer loading and running cleanly from disk, with **zero changes to the disk data**. The
reasoning that held:

- UCSD p-code is **portable bytecode**. The disk `.code` files (SYSTEM.EDITOR, .COMPILER,
  etc.) are p-code plus **relocation tables**, not raw TMS9900 machine code with card-ROM
  addresses baked in. Calls from loaded code into the OS / interpreter go through the
  p-System's **segment/procedure linkage** (segment number + proc number, resolved at run
  time via the segment dictionary) — these are *location-independent*, not absolute
  addresses.
- Where native addresses *do* appear (native-code segments, or the base/interp relocation
  lists in a `.code` file), they are fixed up **at load time by the p-System loader**, which
  lives in the **card firmware we control** — not in the disk bytes. If the loader applies
  the relocation relative to a base that still assumes the ROM is at `>4000`, every loaded
  program lands `0x2000` low. Fixing that base in the firmware fixes **all** programs at once.
- The far more likely cause of the `>50xx` jump is the same thing we've been fixing: a
  **remaining unrelocated reference inside the card firmware itself** (the PME / interpreter
  / loader), on a path that only executes once you actually *run* loaded p-code (segment
  load, native-call linkage, the full opcode set). The built-in menu paths didn't exercise
  it; running the editor does. That is a **finite set of firmware spots**, found and fixed
  the same way we found `L4166` — trace the `>50xx` jump back to the instruction/table/
  routine that produced the address and relocate/convert it.

**Bottom line (confirmed):** this was tractable firmware work, not a 500 KB data port. The
disk data is portable p-code and is relocated by the (fixable) loader in firmware we
control. Each remaining crash was an "unconverted routine / unrelocated pointer / VDP
address mis-handled" fix, discoverable by tracing the specific divergence — the same method
that got the menu options working. The Editor and Filer now load and run clean from disk
with the stock disk image.

**Method that worked:** mount the disk image (`--disk`), run the load under `--exectrace`
/ `--vdptrace` (+`--vdpafterkscan` to isolate per-keypress output), and bisect the first
divergence from the baseline. The expert's commented disassembly (`pCode Disassembly
p-system.pdf`) is the authority for *which* routine/table a bad address belongs to — verify
every DSR-space entry-point table against it (§8 bug 6) rather than guessing. Expect the
remaining subsystems (compiler/assembler/linker, workfile save) to need, at most, a few
more fixes of the same finite class.

---

## 11. Files

- `build/ti99sim.cc`, `cpu.cc` — simulator.
- `build/reasm.py` — byte-identical symbolic reassembler (relocation engine).
- `build/patchdsr.py` — ROM port patch + GROM-access trampolines + demoted-ref relocation.
- `build/patchgrom.py` — GROM PME-code relocation + CRU neutralization (console mode).
- `build/ramhelp.s` — RAM helper routines (console GROM access), loaded to 0x3A00.
- `build/make_cartB2.py`, `build/build_cartB2.sh` — assemble the cart.
- `build/add_romdisk.py` — append `BigCombinedDsk.dsk` as the ROM disk (banks 4+) → `romcart.bin`.
- `build/regress.sh` — regression smoke tests in the sim (single data disk).
- `build/cov_boot.txt` — boot opcode-start coverage (feeds reasm code/data separation).
- `output/bin/` — `romcart.bin`, `grom_base0_base1.bin`, `grom_base2.bin`, `DATA.DSK`.
- `BigCombinedDsk.dsk` — ROM disk contents (volume PSYS:); `romdrive.txt` — original ROM disk driver source.
- Original ROMs: `PCardC.ROM`, `PCardD.ROM`; GROM: `p1f00g_0000_f800.GRM`;
  console: `994AROM.BIN`, `994AGROM.BIN`; disk DSR: `DISK.BIN`; disk image: `EDT-FIL.DSK`.
- `pCode Disassembly p-system.pdf` — the system expert's **commented disassembly** (154 pp).
  Strong (not 100 %) ground truth; the authority for identifying routines and for verifying
  that every DSR-space entry-point table is correctly relocated (§8 bug 6). Extract text
  with `pypdf` (no `pdftotext` in the build env).

---

## 12. ROM disk — system files on the cartridge (unit `#12`, 2026-10-10)

The system programs are served from cart ROM, so only a data disk is needed.

- **Image:** `BigCombinedDsk.dsk` (360 KB, 1440 × 256-byte sectors, volume `PSYS:` with
  SYSTEM.EDITOR/FILER/COMPILER/ASSEMBLER/LINKER/LIBRARY etc.) is split into 8 KB banks
  starting at **bank 4** (32 sectors/bank; bank n selected by writing `>6000+2n`).
  `add_romdisk.py` appends it to `cartB2.bin` and pads to 64 banks (512 KB) with copies
  of bank 3 → `romcart.bin`.
- **Driver:** `ROMDISK2`/`RD2READ` at the end of `ramhelp.s`, fixed at **RAM `0x3E00`**
  (`.org 0x400` from the `0x3A00` link). `ROMDISK2` is a 4-word driver table
  (read, write, init, status; only read is implemented). `RD2READ` mirrors DSKREAD:
  clears SERBUF+12, sets FAC+2, clears GRMADDR, calls DISKPAR (`>56F4`, relocated to
  **`>76F4`** in cart bank 1) to get R1=buffer, R2=count, R3=sector, R4=control. It
  then copies from bank `4 + sector/32`, offset `(sector%32)*256`, to CPU RAM, VDP
  (control bit 14) or GRAM (bit 15), crossing banks as needed, and restores bank 1
  (`clr @>6002`) before `RTWP`.
- **Install:** `patchgrom.py` (console mode) sets **UNITPNT[#12]** (RAM `0x2C38`,
  from GROM `0xEEB4`; this chunk copies with GROM = RAM + `0xC27C`) from 0 to `ROMDISK2`. FNDBIOS then
  dispatches `B *(UNITPNT[u]+opcode)`, so `#12` uses this driver instead of BLOCKED.
  DRVNUM/PCBPNT are untouched; no PCB or DSR is involved.
- **Reserved RAM map:** `0x3A00-0x3DFF` helpers, `0x3E00-0x3E97` ROM disk driver,
  `0x3E98-0x3FF3` free (348 bytes), `0x3FF4-0x3FF9` temps, `0x3FFA-0x3FFF` free.
- **Verified in the sim** (`build/regress.sh`, only `DATA.DSK` mounted): boot; Filer
  `V` lists `4 DATA`, `12 PSYS`, `14 OS`; Editor/Quit menu; delete+left-arrow; the
  compiler builds `#4:HELLO` → `#4:HW` ("3 lines compiled") and `X #4:HW` prints HELLO WORLD;
  the Assembler and Linker load.
- **Known limitation:** `*SYSTEM.LIBRARY` is looked up on the **root volume** (DSK1 if
  mounted, else `#14`), never `#12`. `X #4:BM` therefore reports "Unit SPRITE not found"
  unless SYSTEM.LIBRARY is copied onto the data disk. The fix would be to make `#12`
  the root volume or redirect the library lookup.
