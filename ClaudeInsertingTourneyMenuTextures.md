# ClaudeInsertingTourneyMenuTextures.md

> ⚠️ **NOT what shipped.** E.1/E.2 were ultimately done with **font strings** (the game's built-in
> `Render` text system), NOT textures — so `roms/original.z64` is untouched. See the E.1/E.2
> sections of `claude-tournament.md`. This document is preserved as the **alternative** route to
> follow only if real pixel-art button/title textures are ever wanted.

How to add the texture assets needed to finish **Phase E.1** (real "Tournament" menu button
label) and **Phase E.2** (T1/T2 title banners) of Tournament Mode. Companion to
`claude-tournament.md`. This file captures both the reverse-engineered context **and** the
step-by-step directions, so it can be re-read later.

---

## TL;DR — what you need to do

Create **3 textures**, inject them into the base ROM files via the GE Editor / injector pipeline
(append only), then give Claude **3 offsets**. Claude then finishes the assembly with no further
input.

| # | Texture | Goes in ROM file | Match this existing texture | Used by |
|---|---------|------------------|-----------------------------|---------|
| 1 | "Tournament" button label | `0x006` (VS-menu button text) | "Tug of War" button label | E.1 |
| 2 | "Tournament 1" title banner | `0x0A06` ("CSS Images") | "12-Char. Battle" / "Smashketball 1" | E.2 |
| 3 | "Tournament 2" title banner | `0x0A06` ("CSS Images") | "Smashketball 2" | E.2 |

Then report back to Claude:
- Tournament button label → file `0x006`, offset `0x______`
- Tournament 1 title → file `0x0A06` (or actual), offset `0x______`
- Tournament 2 title → file `0x0A06` (or actual), offset `0x______`

---

## Context Claude figured out (the "why")

### These are file-offset textures, not ASM-embedded images
Every CSS/menu texture in Smash Remix (character name labels, series logos, mode title banners,
button labels) is stored **inside a base-ROM file** and referenced by a **byte offset** into that
file. New textures are added by appending them to the file (regenerating `roms/original.z64` via
the injector pipeline) and then referencing the new offset from assembly. Confirmed by how
`CharacterSelect.asm` declares `name_texture` / `series_logo` offset constants (a growing list of
byte offsets that gets longer as fighters are added) — there is no per-texture ASM `insert` for
these; the bytes live in the ROM files.

### E.1 — the menu button label lives in ROM file `0x006`
The render path in `VsRemixMenu.asm` (~line 282-288):
```
lw   t8, 0x4A4C(t8)   // t8 = file 0x006 start (RAM 0x80134A4C holds the pointer)
lw   t9, 0x000C(at)   // t9 = button text offset (the dw in the table row)
addu a1, t8, t9       // a1 = RAM address of the text texture
jal  Render.TEXTURE_INIT_
```
So the button label = `file_0x006_start + offset`. The table row that supplies the offset is in
`remix_menu_button_table` (`VsRemixMenu.asm` ~line 101):
```
dw 0; db 0x10, mode.TOURNEY, 0x1, 0x1; dh 0x4260, 0x433E; dw 0x000093B8 // Tournament
```
That trailing `dw 0x000093B8` is the **Tug of War** label (the placeholder). Field layout (from
the table's header comment, ~line 79-84): `0x0C = (word) offset to button text texture`.

### E.2 — the CSS title banners live in the "CSS Images" file (`0x0A06`)
`update_css_header_` (`TwelveCharBattle.asm` ~line 1991) chooses a title-banner offset by mode and
hands it to the vanilla header-draw, which indexes a CSS images file (file pointer at
`0x8013C4B0`). Existing offsets in that file:
- `0x2048` = "12-Char. Battle"  (Tournament currently borrows this as a placeholder)
- `0x2738` = "Tag Team"
- `0x29A8` = "King of the Hill"
- `0x30F0` = "Tug of War"
- `0x2C18` = "Smashketball 1"
- `0x2E88` = "Smashketball 2"

The **Smashketball pattern is exactly what E.2 copies**: it branches on `Smashketball.type` to pick
`0x2C18` vs `0x2E88`. E.2 will branch on `TwelveCharBattle.tournament_type` to pick the new
"Tournament 1" vs "Tournament 2" offsets, in **both** the `_vs` and `_results` sub-routines.

`0x0A06` = "CSS Images" per `roms/filename_overrides.txt`. (If GE Editor shows the "12-Char.
Battle"/"Smashketball" banners in a different file, use whatever file actually contains them and
tell Claude the file ID.)

### The injector pipeline (how files get rebuilt)
- Workflow doc: `build/original/readme.md`.
- Manifest: `build/master.csv` (committed file list) and `build/incremental.csv` (work-in-progress).
  Columns: `Mode,FileNumberHex,NewFilePath,Compressed,InternalFileTableOffsetBytes,InternalFileResourceOffsetBytes,ReqFilesFile,CompressionLevel`.
- Confirmed both target files are already in `master.csv`:
  - `MODIFY,0006,.\original\0006.bin,1,00538,3FFFC,,2`
  - `ADD,,.\original\0A06.bin,1,00210,3FFFC,,2`
- `build/SSBFileInjector.exe` + the `.bat` files rebuild `original.z64` from the exported files in
  `build/original/`. `roms/original.z64` is git-ignored and generated locally.

### Why "append only" matters
Offsets like `0x2048`, `0x93B8`, and every `name_texture`/`series_logo` constant are **hardcoded
byte offsets** into these files. If you insert a texture in the *middle* of a file, everything
after it shifts and silently breaks. **Always append new textures at the end** so existing offsets
stay valid.

---

## Directions (step by step)

### 1. Make sure you have `roms/original.z64`
If it doesn't exist yet:
```
xdelta - apply original.bat       // applies original.xdelta -> roms/original.z64
```

### 2. Export the ROM files (GE Editor / SSB Toolkit)
1. Open `roms/original.z64` in GE Editor.
2. Export all files to `build/original/`. Choose **No** when prompted to use the VPK extension.

### 3. Create the 3 textures (match the existing ones)
Match the **size and format** of the equivalent existing texture so it just works:
- **Tournament button label** — like the "Tug of War" button label in file `0x006`.
- **Tournament 1 title banner** — like "12-Char. Battle" / "Smashketball 1" in file `0x0A06`.
- **Tournament 2 title banner** — like "Smashketball 2" in file `0x0A06`.

(Menu text in SSB64 is typically a small white IA-format texture; copying the existing banner's
dimensions/format in GE Editor avoids guessing.)

### 4. Inject — APPEND, never insert mid-file
- Add each new texture to the **end** of its file (`0x006` for the button label, `0x0A06` for the
  two banners). Record the **byte offset** GE Editor reports for each new texture.
- Track the edited files in `build/incremental.csv`.
- Run `build/create_original_from_incremental.bat` to rebuild `roms/original.z64`.
- When satisfied, update `build/master.csv` accordingly and commit a new `original.xdelta`
  (readme steps 4-5).

### 5. Report back to Claude
Paste these three (and the file IDs if they differ from the guesses):
```
Tournament button label : file 0x006 , offset 0x______
Tournament 1 title       : file 0x0A06, offset 0x______
Tournament 2 title       : file 0x0A06, offset 0x______
```

---

## What Claude does after you provide the offsets (no further input needed)

### E.1 (one-line edit)
In `src/VsRemixMenu.asm`, change the Tournament row's trailing `dw 0x000093B8` to your
**button-label** offset.

### E.2 (code + uses your two banner offsets)
In `src/TwelveCharBattle.asm` `update_css_header_`:
- In `_vs`: replace the Tournament placeholder (`lli t9, 0x2048`) with a branch on
  `tournament_type` → load "Tournament 1" offset (type 0) or "Tournament 2" offset (type 1).
- In `_results`: same treatment (currently also routes Tournament to the 12CB placeholder).
- Remove the temporary Phase D top-center label: the `Render.draw_string_pointer` +
  `update_tournament_type_pointer_` registration in `setup_` (and optionally the now-unused
  `tournament_type_pointer` / `string_tournament_1`/`_2` strings).

Then Claude rebuilds with the full sequence (`bass` → `chksum64` → `rn64crc`), runs the two CI
linters + the overlap checker, and you HW-test.

---

## Alternative (if you'd rather not run the injector)
Hand Claude the raw texture **binaries** in the game's native texture format (the exact bytes GE
Editor would inject, header included). Claude can `insert` them into the custom code region and
repoint the render calls to those RAM addresses — no `original.z64` regeneration. This is more
experimental (the exact texture-struct format has to be nailed down first), so the pipeline route
above is recommended because it matches how every other Remix CSS texture was added.
