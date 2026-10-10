# How to load the working p‑System cartridge (Approach B)

This is a **ROM cartridge + real GROMs** in console GROM space. Load the three
files as described, then boot. The cart includes a **ROM disk** (unit `#12`, volume
`PSYS:`) holding the Editor, Filer, Compiler, Assembler, Linker and SYSTEM.LIBRARY,
so only a data disk is needed.

## Load map

| File | Size | Load as | Address / ports |
|------|------|---------|-----------------|
| `romcart.bin` | 512 KB | **Cartridge ROM** (banked / paged) | CPU `>6000‑7FFF`, 64 banks of 8 KB |
| `grom_base0_base1.bin` | 40 KB | **GROM** (loaded twice — see note) | GROM addr `>6000`, on **base 0** *and* **base 1** |
| `grom_base2.bin` | 22.5 KB | **GROM** | GROM addr `>6000`, on **base 2** |

### 1. `romcart.bin` — cartridge ROM at `>6000‑7FFF`
* 64 banks × 8 KB, paged. **Bank select = a CPU *write* to `>6000‑>607F`**: writing
  any value to address `>6000 + 2·N` selects bank N (N = 0..63). Power‑on/reset
  should map **bank 0** (banks 49‑63 are copies of bank 3, which also carries the
  header and entry stub, so they boot as well).
* Bank 0 = DSR code C, bank 1 = DSR code D, bank 2 = boot loader + RAM helpers,
  bank 3 = pad/stubs, banks 4‑48 = ROM disk image (`BigCombinedDsk.dsk`, 1440
  sectors, 32 × 256‑byte sectors per bank), banks 49‑63 = pad.
* Standard cartridge: header `AA` at `>6000`; it appears in the console cartridge
  menu.

### 2. GROM — real GROM chips in console GROM space
The p‑code GROM lives on the GROM bus using the console GROM ports, **only in the
address range `>6000‑FFFF`** (the console's own GROMs own `>0000‑5FFF` on every
base). GROM "base" = which port group the CPU uses:

| base | read data / read addr | write addr |
|------|----------------------|-----------|
| base 0 | `>9800` / `>9802` | `>9C02` |
| base 1 | `>9804` / `>9806` | `>9C06` |
| base 2 | `>9808` / `>980A` | `>9C0A` |

* **`grom_base0_base1.bin`** loads at GROM address **`>6000`** on **base 0 AND
  base 1** — the *same 40 KB image on both bases* (5 chips at GROM
  `>6000,>8000,>A000,>C000,>E000`). The duplicate is deliberate: it works around a
  known console power‑up bug that diffs base 0 vs base 1. No extra hardware — it's
  the same data mapped to two ports.
* **`grom_base2.bin`** loads at GROM address **`>6000`** on **base 2** (3 chips at
  GROM `>6000,>8000,>A000`; the last is partial).

All GROMs share **one** 16‑bit address counter (standard GROM behavior).

## Boot

Title screen → press a key → choose the cartridge from the menu (it lists after
TI BASIC). The p‑System comes up to:

```
Command: E(dit, R(un,? [IV.0 B3h]
...
U.C.S.D.  p-System  IV.0
```

Notes:
* The GROMs are **not** a bootable GROM module — their first byte is `0xFA` (not
  `AA`), so the console ignores them as a cartridge; they are pure p‑code data. The
  bootable entry is the ROM cart (`romcart.bin`).
* Disk controller and interrupts are **not** required to reach the prompt.
* **H(alt)** from the Command prompt reboots the console cleanly; just re‑select the
  cartridge from the menu to get back into the p‑System. (The cart clears the
  p‑System "don't boot" flag on halt so re‑entry works — without it, halt would strand
  you at the title screen.)

## ROM disk (`#12 PSYS:`) and data disks

The system programs are loaded from the read‑only ROM disk, installed as unit `#12`
(which was physical DSK6). The Editor, Filer, Compiler, Assembler and Linker
all load from it, so the only floppy you need is one to keep your own files on
(`DATA.DSK` in this folder is a small example: HELLO.TEXT, HW.CODE, BENCH.TEXT,
BM.CODE). A disk controller is only needed for that data disk.

`F`iler `V`olumes with `DATA.DSK` in DSK1 shows:
`4 # DATA:`, `12 # PSYS:`, `14 # OS:` (root/prefix = DATA).

**Caveat — SYSTEM.LIBRARY:** the p‑System looks for `*SYSTEM.LIBRARY` on the
**root volume**, which is DSK1 whenever a disk is mounted (else `#14 OS:`), not
`#12`. Programs that use library units (e.g. SPRITE) fail with "Unit … not found"
unless a copy of SYSTEM.LIBRARY is on the root (data) disk.

## One caveat to be aware of

At boot, the cart copies its RAM helpers and the ROM‑disk driver into **RAM
`0x3A00‑0x3E97`** and uses scratch words at `0x3FF4/0x3FF6/0x3FF8`
(`0x3E98‑0x3FF3` is still free, 348 bytes). Per the p‑code expert
this `STRTBUF` area (`0x3900‑0x3FFF`) is unused, and it was verified **untouched**
by the Editor and Filer runs — so it is safe in practice. It is still not *formally*
reserved from the p‑System, so if a later subsystem grabs very high/low memory this
block should be reserved via the p‑System memory config.
