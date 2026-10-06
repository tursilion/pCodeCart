# How to load the working p‑System cartridge (Approach B)

This is a **ROM cartridge + real GROMs** in console GROM space. Load all three
files as described, then boot.

## Load map

| File | Size | Load as | Address / ports |
|------|------|---------|-----------------|
| `cartB2.bin` | 32 KB | **Cartridge ROM** (banked / paged) | CPU `>6000‑7FFF`, 4 banks of 8 KB |
| `grom_base0_base1.bin` | 40 KB | **GROM** (loaded twice — see note) | GROM addr `>6000`, on **base 0** *and* **base 1** |
| `grom_base2.bin` | 22.5 KB | **GROM** | GROM addr `>6000`, on **base 2** |

### 1. `cartB2.bin` — cartridge ROM at `>6000‑7FFF`
* 4 banks × 8 KB, paged. **Bank select = a CPU *write* to `>600x`**: writing any
  value to address `>6000 + 2·N` selects bank N (N = 0..3). Power‑on/reset must map
  **bank 0**.
* Bank 0 = DSR code C, bank 1 = DSR code D, bank 2 = boot loader, bank 3 = pad.
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
  bootable entry is the ROM cart (`cartB2.bin`).
* Disk controller and interrupts are **not** required to reach the prompt.
* **H(alt)** from the Command prompt reboots the console cleanly; just re‑select the
  cartridge from the menu to get back into the p‑System. (The cart clears the
  p‑System "don't boot" flag on halt so re‑entry works — without it, halt would strand
  you at the title screen.)

## Running programs from disk

With a disk controller + a p‑System disk present, this cart **loads and runs the
Editor and Filer end‑to‑end** (as of the 2026‑10‑01 build): `E` loads SYSTEM.EDITOR
(edit/menu/quit all clean), and the Filer loads with working volume list, directory
listing, and quit. Compiler / Assembler / Linker and workfile save are not yet
deep‑tested but are expected to work on the same firmware. Without a disk, the menu
options stop at "Can't find SYSTEM.xxx", exactly like the original card.

## One caveat to be aware of

At boot, the cart copies a small block of translation code into **RAM `0x3A00‑
0x3FF5`** (and uses scratch words at `0x3FF4/0x3FF6/0x3FF8`). Per the p‑code expert
this `STRTBUF` area (`0x3900‑0x3FFF`) is unused, and it was verified **untouched**
by the Editor and Filer runs — so it is safe in practice. It is still not *formally*
reserved from the p‑System, so if a later subsystem grabs very high/low memory this
block should be reserved via the p‑System memory config.
