# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Smash Remix is a romhack of *Super Smash Bros.* (N64). The entire mod is MIPS assembly that patches and extends a base ROM. It is **not** compiled from a high-level language — everything is hand-written assembly assembled with `bass` (byuu's assembler), plus binary asset files (movesets, textures, audio) that get injected into the ROM's file system.

## Building

The build runs on Windows via batch files in the repo root:

- `patch.bat` — builds the NTSC ROM: `assembler/bass.exe -o "ssb64asm.z64" main.asm -sym logfile.log`, then fixes the checksum (`chksum64.exe`) and CRC (`rn64crc.exe`).
- `patch-pal.bat` — same, but defines `MAKE_PAL` (`bass -d MAKE_PAL ...`) to produce a PAL ROM. The `MAKE_PAL` define is consumed by `src/PAL.asm`.

To assemble directly (e.g. on the command line):
```
assembler/bass.exe -o "ssb64asm.z64" main.asm -sym logfile.log
```
There is no incremental build — `main.asm` is reassembled in full every time. Assembly errors and `print` diagnostics go to stdout; `logfile.log` is the symbol map.

### Required: `roms/original.z64`

The build **cannot run without `roms/original.z64`**, a pre-modified base ROM (file table expanded, key files decompressed) that the assembly is written against. A vanilla Smash 64 ROM will not work. It is git-ignored and must be generated locally:

1. Place a legally acquired NTSC Smash 64 ROM at `roms/ssb.rom`.
2. Run `xdelta - apply original.bat` (applies `original.xdelta` → `roms/original.z64`).

`main.asm` `insert`s this file at offset 0, and many macros `read32`/`insert` from `../roms/original.z64` **at assembly time** to look up vanilla pointers and copy original code segments. Note the path differences: `main.asm` (run from repo root) references `roms/...`, while files under `src/` reference `../roms/...` because bass resolves includes relative to the including file.

## Tests

CI (`.github/workflows/run_tests.yml`) runs on any push touching `src/**`. Both checks are pure-Python static analysis (no ROM/build needed):

```
python scripts/test/sequential_branches.py
python scripts/test/check_duplicate_action_edit.py
```

- **sequential_branches.py** — flags two MIPS branch/jump instructions in a row. MIPS has a *branch delay slot*: the instruction after a branch always executes. Two consecutive branches is almost always a bug. Keep this in mind when writing/editing assembly.
- **check_duplicate_action_edit.py** — flags duplicate `Character.edit_action_parameters(character, action, ...)` calls for the same `(character, action)` pair, which would silently clobber each other.

`scripts/test/overlapping_patches.py` is a related local-only checker for overlapping `OS.patch_start` regions.

## Architecture

### Assembly layout and the patch model

`main.asm` is the single entry point. It copies `original.z64`, renames the ROM, then sets `origin 0x02C00000` / `base 0x80400000` and `include`s every file in `src/`. **All new custom code lives in this free ROM region (`0x02C00000`+) at RAM base `0x80400000`.**

To hook into *existing* vanilla code, files use the `OS.patch_start(rom_origin, ram_base)` / `OS.patch_end()` pair (defined in `src/OS.asm`). These `pushvar`/`pullvar` the current `origin` and `base`, let you overwrite a specific vanilla ROM location (usually with a jump to new code in the custom region), then restore the cursor. This is the dominant pattern for modifying game behavior — search for `OS.patch_start` to find every vanilla hook.

`src/OS.asm` is the foundational macro library: `align`, `copy_segment`/`move_segment` (pull bytes from the original ROM), `routine_begin`/`routine_end`, `print_hex`, etc. Most files begin with an include-guard (`if !{defined __NAME__}`) so they can be included redundantly.

### Feature files

Each gameplay feature, mode, or system is its own `src/*.asm` (e.g. `Hitstun.asm`, `AirDodge.asm`, `Toggles.asm`, `Stages.asm`, `Training.asm`). Most are independent and register themselves into the game via patches. `src/Toggles.asm` is the central registry for the in-game settings menu — most features expose a toggle there.

### Characters

Characters are the largest subsystem. `src/Character.asm` defines the `define_character(name, parent, ...)` macro: every added fighter is **cloned from a vanilla parent** (parent id must be ≤ 0xB) and overrides files, action arrays, and attributes. Character IDs are assigned dynamically as characters are defined.

- Each added fighter has a folder under `src/<Name>/` (e.g. `src/Falco/`, `src/Marth/`, `src/Bowser/`), included near the bottom of `main.asm`. Many have a `<Name>Special.asm` (special moves) plus `<Name>.asm` (definition/attributes), and some an `AI/Attacks.asm`.
- Per-move animation/data is stored as binary `.bin` files under `src/<Name>/Moveset/` or similar, referenced by the character's file table.
- Vanilla characters that share logic use `src/*shared.asm` (e.g. `nessshared.asm`, `linkshared.asm`).
- `src/CharacterSelect.asm` builds the character select screen: a 30-slot grid defined in the `layout` scope (`slot_1`..`slot_30`), from which `id_table` / `portrait_offset_table` / `portrait_id_table` are auto-generated by `while` loops. The `add_to_css` macro registers Remix-added fighters' metadata (fgm, series logo, name texture, portraits). Vanilla fighters appear purely via their `layout` slot, not `add_to_css`.

### Binary assets and the file system

SSB64 stores assets in an internal file table. New/modified files (textures `.rgba8888`/`.rgba5551`/`.ia8`, audio `.aifc`, index tables `.req`, raw `.bin`) are committed as binary (see `.gitattributes`) and injected into the file table. The `build/` directory holds the tooling for regenerating `roms/original.z64` itself (not the day-to-day ASM build):

- `build/SSBFileInjector.exe` + `master.csv`/`incremental.csv` rebuild the base ROM's file table from exported files in `build/original/`.
- Workflow is documented in `build/original/readme.md`: original.xdelta → original.z64 → export files in GE Editor → track changes in `incremental.csv` → `create_original_from_incremental.bat` → update `master.csv` and commit a new `original.xdelta`.
- `scripts/` contains Python helpers (`SSB.py`, `gen_editable_rom.py`, `attributes_dump.py`) for working with the ROM file system and character attribute tables. `roms/filename_overrides.txt` maps file IDs to human-readable names.

## Conventions

- Comments use `//` (bass syntax). Register/value annotations are conventionally aligned in a trailing comment column (`// t0 = ...`).
- Hex constants are `0x`-prefixed; the codebase mixes RAM addresses (`0x80...`) and ROM offsets freely — be careful which a given value is. `origin` = ROM offset, `base` = RAM address.
- The full user-facing feature list and settings-profile defaults live in `readme.md`; consult it to understand what a toggle/feature is supposed to do before changing it.
