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

---

# Move Buffer feature — development log & design notes

This section documents the **Move Buffer** feature (`src/MoveBuffer.asm` + the `Move Buffer` gameplay toggle), how it was built and debugged, and a proposal for a more advanced version. It is intended both as a record and as a worked example of how to reverse-engineer and hook the SSB64 input/action pipeline.

## 1. What was done, and the reasoning behind it

The goal was to add a Smash Ultimate–style **input/move buffer** to Smash Remix: when you press an action button slightly before your character can act (e.g. during jumpsquat or landing lag), the press is remembered for a short window and the move comes out on the first frame the character becomes interruptible. Ultimate's buffer is **9 frames** (a 9-frame early-input window; people sometimes say "10" because that's the 9-frame window plus the first actionable frame). The feature was made **adjustable 0–9 frames** via a new gameplay toggle, placed next to `Z-Cancel`.

Chronology / key decisions:

- **Reference behavior.** Confirmed Ultimate's hit-buffer is 9 frames and that it has two mechanisms (a press/"hit" buffer and a hold buffer). We implemented the press-buffer style, made the window a 0–9 toggle.
- **Two independent parts.** (a) the menu toggle — well-understood, low risk; (b) the engine that actually persists the input — the hard part requiring reverse-engineering of where input is read and where a character becomes "actionable."
- **Engine reverse-engineering.** SSB64 has no single global "actionable" flag; actionability is per-action (IASA-style) and lives inside each action's update/interrupt logic. The per-player update is `ftMainProcUpdate` (RAM `0x800E1260`), dispatched per object per frame by the object-update dispatcher at `0x8000A518` (already hooked by `Speed.process_update_`). Player input lives in the player struct: `0x01BC` = buttons held, `0x01BE` = buttons **pressed** (the edge-triggered mask every move's interrupt logic reads), `0x000D` = port, `0x0020` = control type (0 = human), `0x0024` = current action id. The global controller struct is `Joypad.struct` = `0x80045228` (10 bytes/port: held `+0x00`, pressed `+0x02`, …).
- **Three implementation attempts** (the first two failed on hardware with "no buffer at all"):
  1. Hooked the object dispatcher (`Speed.process_update_`) and wrote the player struct's `0x01BE` *before* `ftMainProcUpdate`. **Failed:** `0x01BE` is rewritten at the start of `ftMainProcUpdate`, overwriting our injection.
  2. Same hook, but wrote the **global** controller struct's *pressed* field instead. **Failed:** the player's `0x01BE` is not copied from the global *pressed* field at all.
  3. **Disassembled the vanilla input routine from `original.z64`** (this was the turning point — see below) and discovered `0x01BE` is *recomputed every frame by edge detection on the held buttons*. Re-hooked at the exact instruction **after** `0x01BE` is finalized and **before** the action logic reads it (`0x800E134C`), injecting directly into `0x01BE`. **Worked.**
- **Verification by disassembly.** Since the environment can't run the emulator/hardware, the decisive debugging step was writing a small MIPS disassembler (RAM→ROM delta for this segment is `0x80084800`, i.e. ROM offset = RAM − `0x80084800`) and reading `ftMainProcUpdate`'s input block directly. The critical finding:
  ```
  800e12ec: lhu  a3,0x0000(a0)   // a3 = HELD buttons (controller +0x00), NOT pressed (+0x02)
  800e131c: xor  t7,a1,t6        // pressed = (cur_held ^ prev_held) & cur_held  (edge detect)
  800e1320: and  v1,t7,a1        //   prev_held read from player 0x01BC
  800e1334/44/48: sh ...,0x0002(v0)  // store computed pressed -> player 0x01BE
  800e134c: lhu  a0,0x0000(v0)   // first instruction AFTER 0x01BE is finalized  <-- our hook
  ```
  This is why writing the *pressed* field (player or global) before this point did nothing. It also showed `0x800E134C` is on the **control-type-0 (human) path only** (CPUs branch away at `0x800E12B4`), so a hook there never runs for CPUs.
- **Consumption / double-trigger avoidance.** An early version cleared the buffer on *any* action-id change, which killed the buffer exactly at the jumpsquat→airborne transition (where the move should fire). The final design keeps buffering through **non-attack** actions (id `< 0xA6` = `Action.Grab`) and clears once an **attack/grab/special** action (id `≥ 0xA6`) actually begins.
- **Build gotcha learned.** Running `bass` alone produces an **unbootable** ROM (bad header checksum → emulator throws `N64System.cpp Line 680` on start). Always run the full sequence: `bass` → `chksum64.exe ssb64asm.z64` → `rn64crc.exe -u ssb64asm.z64` (this is what `patch.bat` does).

## 2. File changes and how each helped

- **`src/Toggles.asm`** — added the `entry_move_buffer` menu entry (type INT, range 0–9, default 0/off for all four profiles) immediately after `entry_z_cancel_opts`, and repointed Z-Cancel's `next` field at it. Reuses the existing `string_table_volume` so it displays `0`–`9`. *Why it helped:* exposes the adjustable window in Gameplay Settings; the entry macro auto-handles profiles/save/load/rendering, and other code reads the value at `Toggles.entry_move_buffer + 0x4`.
- **`src/MoveBuffer.asm`** (new) — the engine. Final version hooks `0x800E134C` (`OS.patch_start(0x5CB4C, 0x800E134C)`), reproducing the two overwritten instructions (`lhu a0,0x0000(v0)` and `lw t4,0x0040(a2)`). Per port it keeps a 4-byte state (`buf_mask` halfword + `buf_timer` byte). Each frame, in a non-attack state: it captures the frame's new action-relevant presses (overwriting `buf_mask`, resetting timer to N) or, on frames with no new press, ORs `buf_mask` back into `0x01BE` and decrements the timer; it clears once an attack action (id ≥ `0xA6`) starts or the timer expires. `BUFFER_MASK` (currently A|B|Z|L|R|C) selects which buttons are buffered. *Why it helped:* this is the actual buffering, and hooking at `0x800E134C` is what made injection land **after** the engine computes `0x01BE` but **before** action logic reads it — the fix that made it work.
- **`main.asm`** — added `include "src/MoveBuffer.asm"` (before `src/Speed.asm`). *Why it helped:* gets the new file assembled into the ROM, with `Toggles`/`Joypad` already included earlier so its references resolve.
- **`src/Speed.asm`** — *temporarily* hooked (attempt #1/#2 added a `jal MoveBuffer.process_` inside `process_update_`) and then **reverted** to its original form once the dispatcher approach proved wrong. It currently carries no Move Buffer code; this is noted only so the dead-end isn't re-attempted.

Composition note: `0x800E134C` is also the address that `css/DpadFunctions.asm` jumps back to (`j 0x800E134C`) after its dpad-macro processing, *with `0x01BE` already stored*. So the two hooks compose: DpadFunctions finalizes `0x01BE`, jumps to `0x800E134C` (now our `j inject_`), we read/inject `0x01BE`, then reproduce the original instructions and continue at `0x800E1354`. No address overlap (DpadFunctions owns `0x800E1330`/`0x800E1378`; we own `0x800E134C`).

### Current limitations (of the FIRST shipped version)

> ⚠️ Several of these were changed by later work — see **§4 (Iteration log)** for the current behavior. This list documents the original single-slot version for history.

- Single buffer slot per port; **most-recent press-frame wins** (a new press overwrites the stored mask and resets the timer). It is **not** a priority queue and does not retain the full window of inputs — see the proposal below.
- Same-frame simultaneous presses are all injected together; which move results is decided by the **vanilla engine's** native input precedence, not by us.
- A press made while *already inside* an attack/grab/special action (id ≥ `0xA6`) is not buffered, so "chain the next move during your current move" is not covered (would need true per-action IASA data).
- Only the pressed mask (`0x01BE`) is re-asserted, not held (`0x01BC`).

## 3. Proposal — priority-queue buffer with an Ultimate-style priority list

The shipped version is "latest press wins." A more faithful Ultimate-style buffer would **retain every buffered frame's input across the window** and, on the actionable frame, **choose the highest-priority option present anywhere in the window** — so a defensive option (e.g. shield/dodge) input *earlier* still beats an attack input *later*, instead of recency deciding.

> Note: the exact Ultimate priority ordering should be verified against documented behavior before shipping; the ordering below is a reasonable starting point and is meant to live in a single, easily-reordered table.

### Data structures (per port)

Replace the single `buf_mask`/`buf_timer` slot with a small ring buffer of the last N frames of input:

```
buffer_window[port]: N entries (N = max window = 9), each:
    0x00 (halfword) - action-relevant pressed bitmask for that frame (pressed & BUFFER_MASK)
    0x02 (byte)     - stick X for that frame   (optional, for directional moves)
    0x03 (byte)     - stick Y for that frame   (optional)
write_index[port]   - rolling index, advances each frame
```

(Stick X/Y are stored because dodge vs. roll vs. spot-dodge, and tilt vs. smash, depend on stick direction; storing them lets the chosen option be injected with the correct direction. If kept simple, omit them and rely on the live stick.)

### Per-frame record

At the same `0x800E134C` hook, while in a non-attack state (id `< 0xA6`):
- Read `0x01BE` (this frame's freshly-computed pressed mask) and the stick (`0x01C2`/`0x01C3`).
- Store `{pressed & BUFFER_MASK, stickX, stickY}` into `buffer_window[port][write_index]`; advance `write_index` (mod N). Entries older than the current window length N (the toggle value) are treated as expired.

### Priority resolution + injection

Each frame, compute the **single highest-priority action category** present in the live window (newest N entries), then inject only that category's buttons (plus its stored stick if used) into `0x01BE`. The engine then performs that move on the first interruptible frame. Proposed priority table (highest first), keyed by SSB64 buttons:

| Priority | Category        | Buttons (SSB64)             | Notes |
|----------|-----------------|-----------------------------|-------|
| 1        | Shield / Dodge  | `L` (0x20), `R` (0x10)      | roll/spot-dodge/air-dodge with stick dir |
| 2        | Grab            | `Z` (0x2000)                | |
| 3        | Jump            | C-buttons (0x000F)          | SSB64/Remix C = jump |
| 4        | Special         | `B` (0x4000)                | |
| 5        | Attack          | `A` (0x8000)                | jab/tilt/smash/aerial resolved by stick+engine |

Resolution algorithm: iterate the priority table top-to-bottom; for the first category whose button mask appears in **any** live window entry, inject that category's buttons and stop. This yields "earlier dodge beats later attack," matching the described Ultimate behavior. The specific *variant* of an attack (jab vs tilt vs smash vs aerial) is still left to the engine + stick, as today.

### Consumption / clearing

Same as the shipped version: clear the whole window once an attack/grab/special action (id `≥ 0xA6`) begins, or let entries age out past the N-frame window.

### Implementation notes & risks

- Hook stays at `0x800E134C` (verified correct injection point); only the per-port state and the resolution step change.
- Register budget at that hook is tight (must preserve `a0`,`a1`,`a2`,`a3`,`v0`; `t0`-`t9`/`at` are usable, `t3`-`t6`/`v1` are clobbered by the continuation). A ring-buffer scan + priority lookup may want a small subroutine (save/restore registers) rather than inline code.
- The category-by-button mapping cleanly distinguishes the cross-button priorities (dodge vs grab vs jump vs special vs attack); it cannot by itself distinguish within-`A` variants — that's fine, the engine resolves those.
- Verify the priority order against actual Ultimate behavior and play-test; keep the table isolated so it can be reordered without touching the scan logic.

## 4. Iteration log — changes after the first working version

Everything below happened **after** §1–§3 were written. The single-slot version described in §1/§2 has been substantially reworked in `src/MoveBuffer.asm`; the priority-queue idea in §3 is still a proposal, though its "store the full controller frame" notion was partially adopted (a single captured frame, not the whole window). Use this section as the source of truth for current behavior.

### 4.0 Clarifying Q&A (no code; informed the changes below)
- **Not a priority queue.** Confirmed the design is a single per-port slot where the most-recent press-frame wins (overwrite + timer reset). Same-frame simultaneous presses are all injected and the **vanilla engine's** native precedence resolves them — we impose no ordering.
- **When the buffer "updates."** The hook runs every frame, but it only *captures/arms* on a frame with a new action-relevant press; on no-input frames it *ticks down and re-injects*. Holding a button does not re-capture (pressed is edge-triggered), so holding doesn't keep resetting the timer.
- **Dodges weren't being cleared.** Rolls/spot-dodge/air-dodge have action ids **below** `0xA6` (`RollF`/`RollB` = `0x9C`/`0x9D`; Remix spot-dodge reuses `DamageHigh2` `0x26`, air-dodge reuses `DamageLow3` `0x2D`), so the original "clear when action ≥ 0xA6" never treated them as consumed. This observation later drove the roll fix in §4.2.

### 4.1 DK Giant Punch bug → capture-anywhere + full-frame + `used`/`seen` consumption
**Problem reported:** buffering a normal attack during the last frames of DK's neutral special did nothing, even though jump→aerial worked. **Cause:** the special's action id is ≥ `0xA6`, and the original rule cleared (and blocked capture) whenever action ≥ `0xA6`. **Why "just clear when the move is used" isn't trivial:** there's no "move came out" event — it can only be inferred from the action id changing (seen a frame late), and the buffer can't know which action id its buttons will resolve to (depends on stick/state/character). So consumption is necessarily heuristic.

**Implemented redesign** (`process_` in `src/MoveBuffer.asm`):
- **Capture in any state** (removed the "don't buffer while ≥ 0xA6" block) → lets you buffer during an attack/special's recovery (DK Giant Punch).
- **Store the full controller frame**, not just buttons: per-port state grew to **16 bytes** — `mask`(h, 0x00), `timer`(b, 0x02), `used`(b, 0x03), `stickX`(b, 0x04), `stickY`(b, 0x05), `seen`(b, 0x06), pad(0x07), `buf_action`(w, 0x08). On inject, both the buttons **and** the stick are replayed so the buffered move resolves to the intended variant/direction (e.g. a forward-air stays forward-air even if the stick returned to neutral). The held mask (`0x01BC`) is deliberately **not** replayed (avoids buffered charge/hold).
- **`used` flag + `buf_action` + `seen` flag** drive consumption. `seen` is set once an "actionable-ish" state is observed since capture. Consumption (`used` → clear) fires when the action becomes an attack-type action (≥ `0xA6`, **excluding** landing-lag) that is **either different from `buf_action` OR reached after `seen`**. The `seen` term handles "buffer the same move you were already in" (e.g. jab during jab), which a pure "different action" test misses.
- **Edge-case fix A — landing lag excluded.** `LandingAir` actions (`0xD6`–`0xDB`) are ≥ `0xA6` but are not "a move came out", so they're excluded from `used` and treated as bufferable. This lets a move buffer out of an aerial's landing lag.
- **Edge-case fix B — same-move via `seen`** (above).
- **Hook mechanism updated:** `inject_` now wraps the call in `OS.save_registers()` / `OS.restore_registers()` and `jal process_` (so `process_` can use any register), then reproduces the two overwritten vanilla instructions (`lhu a0,0x0000(v0)`, `lw t4,0x0040(a2)`). Still at `0x800E134C`.

### 4.2 Roll regression → peak-deflection stick tracking + roll consumption
**Problem reported:** at higher buffer values, sideways **rolls** would sometimes come out as a plain **shield** (inconsistent vs. 0 buffer). **Two causes:** (1) replaying the **frozen press-frame stick** — often only partway through its travel — can fall below the roll deflection threshold → shield; (2) rolls are `< 0xA6`, so they weren't marked `used`, and the buffer kept re-asserting "R pressed" every frame, disrupting the shield→roll transition.

**Implemented fixes:**
- **Peak-deflection stick tracking.** On each inject frame, the stored stick is updated toward the **strongest deflection seen during the window**, per axis (branchless `abs` + magnitude compare), and that peak is replayed. So a buffered roll keeps full deflection (→ roll) while still surviving the stick returning to neutral (keeps the §4.1 directional fix).
- **Roll consumption.** Added explicit detection of `RollF`/`RollB` (`0x9C`/`0x9D`) to the `used` check (constants `ROLL_F`/`ROLL_B`), so the buffer stops re-injecting once a sideways dodge starts. Scoped to rolls only, so buffering a move *out of* shield still works. (Spot/air dodge can't be added cleanly because they reuse damage action ids.)

### 4.2b Double-jump on a single C press → jump consumption
**Problem reported:** with the buffer on, pressing the jump (C) button **once produced two jumps** (a normal jump + an extra midair jump). **Not a re-capture** — `0x01BE` ("pressed") is edge-triggered, so frame 2 (still holding C) has `pressed == 0` and does not re-capture. **Cause = missing consumption**, the same class as the §4.2 roll regression: after the real C press starts the jump, the buffer keeps re-asserting C every frame (because a jump action is `< 0xA6` and was never marked `used`), so once the character becomes airborne the still-asserted C triggers a midair jump. (Stacks further on multi-jump characters.)

**Implemented fix** (`_check_used` in `src/MoveBuffer.asm`): consume when a buffered input **newly** produces a jump action `JumpSquat..JumpAerialB` (`0x014–0x019`; constants `JUMP_MIN`/`JUMP_COUNT`), **gated on `buf_action` NOT already being a jump action**. The `buf_action` gate (rather than gating on the C button) is button-agnostic *and* preserves the cases that legitimately pass *through* a jump action while buffering something else — e.g. buffering a rising aerial or a second jump during jumpsquat (`buf_action == JumpSquat`) is not consumed. Verified-correct traces: standing C press → consume on JumpSquat → one jump; jump buffered out of landing-lag/shield → one jump; rising aerial buffered in jumpsquat still fires; airborne C on a multi-jump char → one midair jump.

**Consumption coverage now** (the requested set): attacks/grabs/specials all `>= 0xA6` (`Grab = 0xA6`) → already consumed by the attack check; rolls (`0x9C/0x9D`) and jumps (`0x014–0x019`) consumed explicitly. **Shield deliberately NOT consumed**: `ShieldOn 0x098`/`Shield 0x099` are a passthrough hub to buffered roll / spot-/air-dodge / shield-grab / jump-out-of-shield, so consuming there would break the §4.2 buffered-roll behavior; shield is also held-driven (`0x01BC`, never replayed), so a single shield press doesn't double-fire. Spot/air-dodge (`0x26/0x2D`) still can't be cleanly consumed (shared damage ids).

### 4.3 Current behavior & remaining limitations (supersedes §2's list)
Working: buffer out of jumpsquat/landing/shield/hitstun; buffer during attack/special recovery (DK Giant Punch); correct directional moves (stick replay + peak tracking); buffer out of aerial landing lag; same-move buffering; consistent rolls at high buffer. Toggle `0` is fully inert.

Remaining limitations / things to watch:
- Still a **single slot**, recency-wins (the §3 priority-queue is still unbuilt). Same-frame ties resolved by the engine.
- **Spot-dodge / air-dodge** reuse damage action ids (`0x26`/`0x2D`), so they can't be cleanly detected as `used` like rolls can.
- **Held mask** is not replayed (no buffered smash-charge / special-hold).
- **Same-move with no actionable pass-through** (result == `buf_action` and `seen` never set) could re-fire within the ≤N-frame window — rare, bounded by the timer.
- Possible residual: repeated shield-press during the `ShieldOn` frames *before* a roll triggers; if rolls still occasionally drop to shield, the next step is to gate injection while already in shield.
- Peak stick tracking may favor the stronger/earlier deflection if the player deliberately changes direction within the window.

### 4.4 Process notes
- Every rebuild used the full sequence (`bass` → `chksum64 ssb64asm.z64` → `rn64crc -u ssb64asm.z64`) so the ROM stays bootable; both CI linters (`sequential_branches.py`, `check_duplicate_action_edit.py`) were run after each change and pass. All testing of *behavior* was done by the user on N64 hardware (the dev environment can't run a controller).
- Debugging the "no effect" failures was ultimately solved by **disassembling `original.z64`** (RAM→ROM delta `0x80084800` for this segment) to read the vanilla input routine directly — the lesson being to verify engine assumptions against the actual ROM rather than inferring from comments.
