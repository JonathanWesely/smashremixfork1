# claude-tournament.md — Tournament Mode dev log & roadmap

Companion to `CLAUDE.md`. Covers the **Tournament Mode** feature only. Read `CLAUDE.md`
first for the build model, the `OS.patch_start` patch pattern, and MIPS delay-slot rules.

## TL;DR

Tournament Mode is **not** a standalone mode — it is a **gated extension of 12-Character
Battle (12CB)**. Selecting Tournament sets 12CB's master switch `twelve_cb_flag` (so the
entire 12CB CSS + engine + darken-on-elimination is reused) and is distinguished everywhere
by `VsRemixMenu.vs_mode_flag == VsRemixMenu.mode.TOURNEY (0x6)`. Every Tournament-specific
change is an `if vs_mode_flag == TOURNEY` branch; **12CB must behave identically when the
flag is off.** A literal fork is impossible: 12CB's CSS is ~40 `OS.patch_start` hooks at
fixed ROM addresses and `NUM_SLOTS` is a compile-time constant.

Almost all code lives in **`src/TwelveCharBattle.asm`** (TCB below). Menu wiring is in
`src/VsRemixMenu.asm`; the T1/T2 toggle reuses `src/Smashketball.asm`.

### Build & verify (run after every change)
```
python scripts/test/sequential_branches.py        # no two branches in a row (delay slots)
python scripts/test/check_duplicate_action_edit.py
assembler/bass.exe -d DEBUG -o ssb64asm_dbg.z64 main.asm   # then overlap check:
python scripts/test/overlapping_patches.py         # expect ONLY the 3 known pre-existing conflicts
assembler/bass.exe -o ssb64asm.z64 main.asm -sym logfile.log
assembler/chksum64.exe ssb64asm.z64                # REQUIRED or ROM won't boot
assembler/rn64crc.exe -u ssb64asm.z64              # REQUIRED
```
Known pre-existing overlaps (NOT caused by us): WaddleDee.asm:131, BGM.asm:1419/Cheats.asm:38,
Stamina.asm:303/Rage.asm:45. The dev environment cannot run the ROM — **all behavior is
hardware-tested by the user.** Smoke-test 12CB after every Tournament change.

### Status
Phases **A, C, D = DONE** (build-verified + HW-confirmed). Phase **B** (32 slots) and Phase
**E** (cleanup, 4 parts) remain. Branch: **`tourney-mode`** (off `master`, with
`movebufferoption` merged so it also carries Move Buffer). `master` is the clean fallback.

---

## Gating model & key references

- **Master switch:** `TwelveCharBattle.twelve_cb_flag` (TCB ~20). Set by the menu button's
  `0x07` field. Reuses the whole 12CB CSS.
- **Mode discriminator:** `VsRemixMenu.vs_mode_flag == VsRemixMenu.mode.TOURNEY (0x6)`.
- **Toggle state:** `TwelveCharBattle.tournament_type` (after `twelve_cb_flag`): `0` =
  `TOURNAMENT_1`, `1` = `TOURNAMENT_2`. Default 0.
- **Shared per-mode state:** `TwelveCharBattle.config` scope (TCB ~50–90): `status`,
  `num_stocks`, `current_game`, `p1`/`p2` sub-structs (each has `stocks_remaining` +
  `best_character_pointer` + TKO fields), and `stocks_by_portrait_id` (`fill 24`). **12CB and
  Tournament share this one struct** — the root of the carryover/save issues (see Phase E.4).
- **Slot count:** `constant NUM_SLOTS(24)` (TCB 89), compile-time. Phase B makes the effective
  count runtime (24 vs 32).
- **Title image picker:** `update_css_header_` (TCB 1946) — `_vs` and `_results` choose a
  title texture offset by mode. Smashketball picks between two images by its `type`
  (0x2C18/0x2E88) — the exact pattern to copy for Phase E.2.

---

## Phase A — Route Tournament through the 12CB CSS (DONE, HW-confirmed)

- `VsRemixMenu`: added `constant mode.TOURNEY(0x6)`; added the "Tournament" row to
  `remix_menu_button_table` (6th button on Remix Modes page 2) with the `0x07` field = 1 so it
  sets `twelve_cb_flag`. Page-2 layout uses `button_positions_p2`. **Texture is still the Tug
  of War placeholder (0x000093B8) — fixed in Phase E.1.**
- Dispatch tables `mode_setup_table` / `_returning_` / `_start_`: Tournament entries point at
  `TwelveCharBattle.before_css_setup_` / `leave_css_setup_` / `start_match_setup_`.
- `update_css_header_` (TCB 1946): Tournament uses placeholder title image `0x2048`
  ("12-Char. Battle") in both `_vs` and `_results` — **replaced in Phase E.2.**
- Old custom bracket engine removed: `src/TourneyMode.asm` + `src/TourneyController.asm`
  un-included from `main.asm` (files remain on disk, dead). `GameEnd.update_screen_`
  tournament routing reverted to vanilla.

Result: selecting Tournament shows and plays exactly like 12CB.

## Phase C — Any character selectable by either player (DONE, HW-confirmed)

12CB restricts P1 to the left grid half (portraits 0–11) and P2 to the right half (12–23).
Three gated changes (all `vs_mode_flag == TOURNEY`) lift this:

- `get_character_id_` (TCB ~1023, token→portrait mapper): the real restriction. Per-port grid
  bounds clamp P1 to LEFT_GRID and P2 to RIGHT_GRID and add a +4 portrait shift for the right
  side. Fix: for Tournament use full-grid bounds for **both** players and **skip the +4 shift**
  → grid columns 0–7 map to portraits 0–23 for either player.
- `is_character_valid_for_port_` (TCB ~1394): return TRUE early for Tournament (removes the
  per-side validity restriction).
- `get_portrait_id_` (TCB ~1143, char→portrait auto-position): HW bug — P1 picking a right
  slot snapped back to its left twin because the preset path remaps to the port's half. Fix:
  for Tournament on the VS CSS, return the **actually-selected slot** from CSS struct `+0x00B4`
  instead of remapping. (If other per-port snap quirks appear, `get_valid_portrait_id_` ~1221
  may need the same `+0x00B4`-first treatment.)

NOTE: the 24 grid slots currently show the same 12 characters mirrored on each side (left 12 ==
right 12 by `layout`). Making all slots unique/editable-to-any is Phase B.

## Phase D — Tournament 1/2 toggle, display, stock behavior, carryover fix (DONE, HW-confirmed)

- **Toggle state:** added `tournament_type` (0=T1, 1=T2) + constants `TOURNAMENT_1/2`.
- **Toggle control:** extended `Smashketball.enable_toggling_mode_` (Smashketball.asm ~1354
  toggle-action + ~1378 `_skip_to_end`): for `vs_mode_flag == TOURNEY` it sets
  `a2 = TwelveCharBattle.tournament_type` (so the generic FFA/Team toggle flips it) and skips
  the teams logic. `disable_mode_toggle_` only disables the toggle for `TWELVE_CB`, so it stays
  **enabled** for Tournament. (Template: Smashketball's own 1/2 type toggle.)
- **Display (TEMPORARY — replaced in Phase E.2):** added `string_tournament_1`/`_2`,
  `tournament_type_pointer`, a per-frame routine `update_tournament_type_pointer_`
  (registered in `setup_`, Tournament-gated) that points it at the right string, and a
  `Render.draw_string_pointer` at ~(0x4320, 0x4210) top-center in `setup_`. This draws a NEW
  label that **overlaps** the placeholder title — Phase E.2 removes it and instead drives the
  top-left title image.
- **Stock behavior** — `update_stocks_remaining_` (TCB ~5538, the per-stock-loss hook at
  0x8013BEF0 / 0x8013BF48): `stocks_by_portrait_id[portrait]` is written normally so stocks
  **drop during the match** for all modes; THEN when the written count is 0 (a fighter
  eliminated = 12CB 1v1 match end), for **Tournament + T1 only**, it loops all `NUM_SLOTS`
  entries and resets every **survivor** (>0) back to `num_stocks` (eliminated stay 0). T2/12CB
  skip the reset (retain remaining). So T1 = lose stocks in-match, survivors reset to full next
  match; T2 = retain (12CB behavior).
- **Carryover fix:** `before_css_setup_` (TCB 376) — on fresh entry from the VS menu
  (`Global.previous_screen == Global.screen.VS_GAME_MODE_MENU`) it resets `config.status=0`,
  `current_game=-1`, and refills `stocks_by_portrait_id` from `num_stocks`. ⚠️ **This change is
  the suspected cause of the Phase E.4 save bug** — revisit it there.

OPEN RISK (verify on HW): the per-match fighter stock might come from `vs.pN+0x0B` /
game-struct `starting_stocks` (set from `vs.pN+0x0B`, ~TCB 5292) rather than being re-read from
`stocks_by_portrait_id`. If a T1 winner does NOT start the next match at full, trace where the
continuing fighter's `vs.pN+0x0B` is set for 12CB and reset it to `num_stocks` for T1 there.

---

## Phase B — 32 slots + remove stats (NOT STARTED; hardest, heavy HW iteration)

Goal: 32-character tournament. Keep the 24 grid slots, add **8 more portraits in the center**
where the stats text currently is, and remove all stats text (keep the RESET button). Per the
user, Tournament should default **all** icons to the per-side **"custom"** state (each slot
freely set to any character), not the mirrored default 12 — address this here.

What needs doing (all gated to Tournament; 12CB keeps 24 slots, stats, side restriction):

1. **Runtime slot count.** Replace compile-time `NUM_SLOTS` (24) reliance with a runtime count
   (24 for 12CB, 32 for Tournament) in every loop that iterates slots/portraits — there are
   ~9: the `before_css_setup_` refill loop (TCB ~393), the darken/stock loops (e.g. ~1554,
   ~1671), the new Phase D `_t1_refill` loop (~5538 region must use the runtime count too),
   render/select loops, etc. Grep `NUM_SLOTS` and `stocks_by_portrait_id` to find them all.
2. **Grow shared structures to 32 (max).** `config.stocks_by_portrait_id` (`fill 24` → 32) and
   the `layout` scopes (`u`/`j`/`r`/`pv`) + auto-generated `id_table`/`portrait_offset_table`/
   `portrait_id_table` (CharacterSelect-style `while` loops) need 8 more entries. 12CB only
   touches the first 24, so growing them is safe for 12CB.
3. **8 center coordinates.** The 8 extra portraits need explicit positions in the area the
   stats occupied (center). These are visual — expect tuning on HW.
4. **Remove the stats draws for Tournament.** In `setup_` (TCB 5137+): the "Stocks Remaining"
   (~5180), "Character Set" (~5185), and "Best Character" (~5196–5208) draws must be gated OFF
   for Tournament, and the 8 center portraits drawn instead. (See also Phase E.3 — Tournament
   must not even *write* those stats.)
5. **All slots default to "custom".** Make Tournament initialize every slot to the editable
   per-side "custom" `character_set` state so all 32 icons can be set to any character.

Reuse: `handle_reset_` (TCB 2209, the RESET button's full reset) and `update_stock_fields_`
(~1616, refills stocks, skips if `num_stocks` unchanged). Main risk = a 12CB regression from
the shared code; mitigate with the per-phase 12CB smoke test + overlap checker.

---

## Phase E — Cleanup (NOT STARTED; 4 independent parts)

### E.1 — Real "Tournament" button texture
The Remix Modes "Tournament" button still shows the **Tug of War** placeholder texture
(`remix_menu_button_table` Tournament row references offset `0x000093B8`). Create/inject a
"Tournament" button texture and point the row at it. This is a **binary asset task** (texture
injection into the file table — see `CLAUDE.md` "Binary assets and the file system"), plus the
one-line table edit in `VsRemixMenu.asm`.

### E.2 — T1/T2 toggle drives the top-left title (not a separate label)
Remove the temporary Phase D label (the `draw_string_pointer` + `update_tournament_type_pointer_`
registration in `setup_`, and optionally the `tournament_type_pointer`/strings if unused).
Instead make the **top-left title image** itself show Tournament 1 vs Tournament 2, exactly
like Smashketball does: in `update_css_header_` (TCB 1946), the Smashketball branch picks
between two title textures (`0x2C18` "Smashketball 1" / `0x2E88` "Smashketball 2") based on
`Smashketball.type`. Mirror that for Tournament: branch on `tournament_type` to choose a
"Tournament 1" vs "Tournament 2" title image in both `_vs` and `_results` (currently both use
the `0x2048` placeholder). **Requires creating the two title textures** (asset task, like E.1).

### E.3 — Tournament must not touch the "Stocks Remaining" / "Best Character" stats
These stats (per side) belong to 12CB and we are not using them in Tournament; Tournament must
not write or corrupt them. They live in `config.p1`/`config.p2` (`stocks_remaining`,
`best_character_pointer` + TKO counters, TCB ~50–90) and are updated by 12CB's scoring path
(e.g. `update_stocks_remaining_` decrements the per-side total; `set_best_characters_` in
`setup_` ~5194). Gate every such write so it is **skipped for Tournament** (`vs_mode_flag ==
TOURNEY`), for **both** sides, so 12CB's stats are never affected by a tournament session.
(Phase B removes the stat *display*; E.3 removes the stat *writes* — do both.)

### E.4 — Fix: exiting to main menu no longer saves data (12CB AND Tournament)
Regression: exiting to the main menu now fails to save data for **both** 12CB and Tournament.
**Likely cause:** the Phase D carryover fix in `before_css_setup_` (the
`previous_screen == VS_GAME_MODE_MENU` reset of `config`) — added to stop Tournament state
from bleeding into 12CB. This revealed that 12CB and Tournament are **not actually separate**
(they share `config`), so the reset also clobbers data that should persist/save.
Investigate the 12CB save/persist path and the exact entry conditions under which `config` is
reset; make the reset narrow enough to not destroy saved data, OR give Tournament its own state
separate from 12CB's `config`. **Broader implication to verify later:** 12CB and Tournament
sharing `config` means stock/elimination/stat/save state is entangled — confirm true separation
of the two modes' persistent data as part of this fix.

---

## Pitfalls (learned)
- Running `bass` alone yields an **unbootable** ROM — always `chksum64` + `rn64crc` after.
- The two CI linters + the overlap checker must pass after every change. Watch for `li` (a
  pseudo-op that can expand to 2 instructions) in a branch delay slot, and for two
  branches/jumps in a row.
- When debugging "no effect", verify engine assumptions by **disassembling `original.z64`**
  (RAM→ROM deltas in the `ssb64-rom-deltas` memory).
