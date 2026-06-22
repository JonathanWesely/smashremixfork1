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
Branch: **`tourney-mode`** (off `master`, with `movebufferoption` merged so it also carries Move
Buffer). `master` is the clean fallback. Build with the full sequence (`bass` → `chksum64` →
`rn64crc`); run both linters + overlap checker after each change (see "Build & verify" above).

**Done:**
- Phases **A, C, D** — DONE, HW-confirmed.
- Eliminated-character **darken/lock in Tournament** bugfix — DONE, HW-confirmed (user notes minor
  bugs remain to chase later — see that bugfix section).
- **E.3** (Tournament doesn't touch Stocks Remaining / Best Character stats) — DONE, build-verified,
  **needs HW confirm**.
- **E.4** (save-on-exit / mode-aware `config` reset via `last_owner_mode`) — DONE, build-verified,
  **needs HW confirm**.
- **Phase B Stage 1** (MAX_SLOTS, runtime `slot_count`, grown buffers) — DONE, HW-confirmed inert.
- **Phase B Stage 2a** (parameterized table macro, extended `layout.u` to 32, grew `p1`/`p2`, added
  32-distinct `layout.t` + tables) — DONE, build-verified.
- **Phase B Stage 2b** (live tables → `layout.t`, `update_character_set_` no-op for Tournament,
  loop conversions to `slot_count`, `get_character_id_` bounds to 32) — DONE, build-verified,
  **needs HW test**. Tournament should now show **32 distinct selectable portraits**.
- **Phase B Stage 2b bugfixes** (HW-found) — DONE, build-verified, **needs HW test**:
  - *Inverted `slot_count` branch.* `before_css_setup_` used `bnel` (branch-likely) where it
    needed `beql`, so the 32-slot override fired for **12CB** and was skipped for **Tournament**.
    This caused BOTH reported HW bugs: Tournament showed only 24 icons, and 12CB crashed (TLB load
    at a wild VA) after a Tournament visit because its grid loops ran 32 wide over uninitialized
    table tails. One-char fix (`bnel`→`beql`); matches the working idiom at `get_character_id_`.
  - *Extra 8 unselectable.* `CharacterSelect.get_character_id_` rejected any cursor with
    `ypos >= START_Y + 85` (3-row cutoff) before reaching the 12CB mapper, so the 4th row was
    never hit-tested. Raised the cutoff to `START_Y + 165` **for Tournament only** (12CB keeps 85).
- **Phase B Stage 2c — centered block (render + hit-test)** — DONE, build-verified, **needs HW
  test**. The 8 extra slots (ids 24-31) now render as a centered `CENTER_COLS x CENTER_ROWS`
  (4x2) block below the 24-slot grid, and a dedicated cursor hit-test selects them there. See the
  Stage 2c section for the geometry constants and the **deferred** token auto-position polish.

**Known follow-ups (where to resume — details in each phase section below):**
1. **HW-test Phase B Stage 2b + 2c**: do all 32 portraits show, with the 8 extras as a centered
   4x2 block, and are they selectable by both players (hover/cursor)? Is 12CB still identical
   (and no longer crashing after a Tournament visit)? Are E.3/E.4 confirmed (stats not corrupted;
   save-on-exit works)? HW-tune the block geometry via the `CENTER_*` constants (see Stage 2c).
2. **Phase B Stage 2c — token auto-position for center slots (DONE, build-verified, needs HW
   test):** all four slot↔screen mappings are now center-aware — render, cursor hit-test, and the
   two token auto-position paths (`token_autoposition_._vs_x_position` + `token_autoposition_y_fix_`,
   and `place_token_from_id_`). This fixed the HW bug where a token placed on a center character
   snapped to the old uniform 4th-row spot (just below the 3 rows) instead of onto the center
   portrait — i.e. "markers can't be moved below the 3 rows." Each token path computes
   `ccol/crow` for ids >= NUM_SLOTS and positions at `CENTER_X + ccol*W` / effective row
   `CENTER_ROW_BASE + crow` (matching render, plus each site's existing token offset).
3. **Phase B — in-game custom editing (deferred):** grid is the fixed auto-filled roster; cycling a
   slot to a different character in-game needs `set_portrait_` redirect (write to the `layout.t`
   live tables) + default-to-custom for Tournament. (User wanted all slots editable.)
4. **Phase B Stage 3 (DONE, build-verified, needs HW test):** the "Character Set" selector is no
   longer drawn for Tournament (it overlapped the new center block, and the roster is the fixed
   `layout.t`, not a cycleable preset). Both the display (`setup_` `_skip_character_set`) and the
   arrow press-checks (`handle_custom_presses_` `_check_character_set_p1` Tournament early-out) are
   gated off; `update_character_set_` was already a no-op for Tournament. RESET/BACK unaffected.
5. **E.1** (real "Tournament" button texture) and **E.2** (T1/T2 title banners) — **asset tasks**;
   workflow + exact offsets-to-report in **`ClaudeInsertingTourneyMenuTextures.md`**. E.2 also needs
   the `update_css_header_` `tournament_type` branch + removal of the temp Phase D top-center label.
6. **Minor elimination-darken/lock bugs** the user flagged for "later".

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

## Bug fix — eliminated-character darken/lock in Tournament (DONE, HW-confirmed; minor bugs remain)

Reported: a beaten fighter stayed selectable (not darkened/locked) in BOTH Tournament modes,
while 12CB works. Decision: track elimination **per-slot** (only the exact slot played darkens)
and lock that slot for **both** players.

Root causes (two):
1. **Selection-lock looked up the wrong slot.** `prevent_defeated_char_select_` (TCB ~2963) and
   `treat_selected_defeated_chars_as_unselected_` (~3526) call `get_stocks_remaining_for_char_`
   → `get_valid_portrait_id_` (~1309). That mapper still used 12CB's per-side `+4/-4` half-grid
   shift and was the one Phase C never updated. In Tournament (full grid) it returned a half-grid
   twin slot, whose stock was never the one that took the loss, so the fighter was never seen as
   defeated. **Fix:** prepend a Tournament branch to `get_valid_portrait_id_` that returns the
   actually-selected slot from CSS struct `0x00B4` (identical to the Phase C block in
   `get_portrait_id_`), gated to `vs_mode_flag == TOURNEY` on the VS CSS. Darkening itself
   (`draw_disabled_rectangle_` ~2891) already keys off the rendered slot's own stock, so the
   played slot was darkening correctly — the lock was the broken half.
2. **T1 survivor-reset used the wrong stock encoding.** `stocks_by_portrait_id` is 0-based:
   `0xFF` (= -1) = eliminated, `0` = 1 stock left. The Phase D T1 loop (~5559) triggered on
   `t5 == 0` and treated `0` as "eliminated", so it (a) fired a stock too early and (b) reset
   `0xFF` slots back to full — **un-eliminating** previously darkened/locked fighters in T1.
   **Fix:** trigger on `t5 == -1` (real elimination) and skip slots equal to `0xFF` in the
   refill loop. T2/12CB paths unchanged.

Both build-verified; linters pass; overlap checker shows only the 3 known conflicts.

---

## Phase B — 32 slots + remove stats (IN PROGRESS; hardest, heavy HW iteration)

**Design locked (user):** Tournament gets a **dedicated 32-distinct layout** (the 24 grid slots
un-mirrored + 8 more in the center); 12CB keeps its shared 24-mirror layout untouched. All
Tournament slots default to the per-side **custom** state (editable to any character). Claude
auto-fills the roster; user tweaks later. Implemented in **build-verified stages**:

- **Stage 1 — foundation (DONE, build-verified):**
  - `constant MAX_SLOTS(32)` (TCB ~32) + runtime `slot_count` word (default 24).
  - `before_css_setup_` sets `slot_count` = 32 for Tournament / 24 for 12CB on every CSS entry.
  - Grew shared buffers to MAX_SLOTS: `config.stocks_by_portrait_id` (`fill 24`→`fill MAX_SLOTS`),
    the live `id_table` (`fill MAX_SLOTS`) and `portrait_offset_table` (`fill MAX_SLOTS * 4`).
  - **Inert/behavior-preserving:** nothing reads `slot_count` yet and 24-slot code ignores the
    extra buffer space, so 12CB **and** Tournament still run as 24-slot. Pure groundwork.

- **Stage 2a — data (DONE, build-verified):**
  - Parameterized `create_portrait_tables(layout_type, layout, count)` (3-arg worker + 2-/1-arg
    delegates passing NUM_SLOTS); `while {count}` instead of `while NUM_SLOTS`.
  - Extended `layout.u` to 32 (slots 25-32 placeholders); grew `p1`/`p2` via
    `create_portrait_tables(p1/p2, u, MAX_SLOTS)` (12CB still reads first 24 = unchanged).
  - Added dedicated 32-DISTINCT `layout.t` + `create_portrait_tables(t, t, MAX_SLOTS)`:
    id_table_t / portrait_offset_table_t / portrait_id_table_t. Roster: base12 + remix12 +
    SONIC/SHEIK/MARINA/DEDEDE/GOEMON/BANJO/CRASH/PEACH. Builds clean (all symbols valid).
  - Still inert: nothing reads the 32-tables/`slot_count` at runtime yet.

- **Stage 2b — runtime wiring (DONE, build-verified; needs HW test). Approach taken:** point the
  live tables directly at the dedicated 32-distinct `layout.t` tables for Tournament (single shared
  full grid), rather than copying per-port. Specifics:
  - `force_ffa_and_stock_` (TCB ~1889): for Tournament set `id_table_pointer`/
    `portrait_id_table_pointer`/`portrait_offset_table_pointer` → `id_table_t`/`portrait_id_table_t`/
    `portrait_offset_table_t`. 12CB still uses the standalone tables. `portrait_x_position` shared.
  - `update_character_set_` (TCB ~2654): **no-op for Tournament** (early-return) so preset-cycle /
    redraw callers never overwrite the static `t` grid. Also skipped its two calls in `setup_`.
  - Loop conversions to `slot_count`: `before_css_setup_` stock refill, the T1 survivor refill, and
    `CharacterSelect.draw_portraits_` count (restructured out of the delay slot; uses
    `TwelveCharBattle.slot_count` for 12cb/Tournament, `CharacterSelect.NUM_SLOTS` otherwise).
  - `get_character_id_` grid bounds: raised to MAX_SLOTS for Tournament (uses the existing `t3`
    Tournament flag) so slots 24-31 are clickable.
  - **No stale-`slot_count` risk in non-Tournament CSS:** draw uses it only when the 12cb flag is
    set; bounds only when the Tournament flag is set; refills only run in 12cb/Tournament paths.
  - **Works now:** Tournament shows 32 distinct, selectable-by-either-player portraits with stocks/
    elimination across all 32. **Deferred:** in-game custom editing of slots (live points at `t`, so
    `set_portrait_` redirect + default-to-custom still needed) — the grid is currently the fixed
    auto-filled roster.

- **Stage 2c — centered block (render + hit-test DONE, build-verified, needs HW test):** the 8
  extra slots (ids `NUM_SLOTS`..`MAX_SLOTS-1`) now render as a centered **`CENTER_COLS x CENTER_ROWS`
  = 4x2** block below the 24-slot grid (where the stats were), instead of a full-width 4th row.

  - **Geometry constants (single source of truth, in `TwelveCharBattle.asm` by the layout
    constants):** `CENTER_COLS(4)`, `CENTER_ROWS(2)`, `CENTER_X(100)` (screen X of the leftmost
    center portrait), `CENTER_ROW_BASE(3)` (effective grid row of the first center row; uly =
    `row*PORTRAIT_HEIGHT + START_Y + START_VISUAL`). `CENTER_COLS*CENTER_ROWS` must equal
    `MAX_SLOTS - NUM_SLOTS`. **HW-tune the block position by editing only these.**
  - **Render** (`CharacterSelect.draw_portraits_`): for a center slot it remaps the slide-in
    `column` index to `NUM_COLUMNS + ccol` (so the animation reads the center X from new entries
    appended to `TwelveCharBattle.portrait_x_position`/`portrait_velocity` at indices 8-11) and the
    effective row to `CENTER_ROW_BASE + crow` (drives uly). `ccol = (id-24) % CENTER_COLS`,
    `crow = (id-24) / CENTER_COLS`. Center columns slide in from the right (negative velocity).
  - **Cursor hit-test** (`TwelveCharBattle.get_character_id_`): a Tournament-gated block maps a
    cursor inside the centered region directly to id `NUM_SLOTS + crow*CENTER_COLS + ccol`
    (jumps to new label `_have_index`). The 24-slot grid path's bound was **reverted to
    `NUM_PORTRAITS`** (the Stage 2b raise to `MAX_SLOTS` is gone) so center ids come *only* from the
    hit-test, not from clicking empty cells in the grid's row 3.
  - **Y-cutoff:** `CharacterSelect.get_character_id_`'s pre-filter cutoff was raised to
    `START_Y + 165` for Tournament (12CB keeps `+85`) so the lower block is reachable.
  - **HW bug found + fixed (center slots could not be selected -- the REAL blocker, took two tries):**
    the vanilla cursor-state routine (`0x80137D4C`, VS overlay) decides the per-port cursor state
    (+0x54 of the cursor struct `0x8013BA88 + port*188`) from the cursor's render Y. `38 <= Y <= 124`
    -> the **hover path** (`0x80137E04`): sets state 2 when free, but PRESERVES state 1 while holding
    a token (it checks the held-token field +0x80). `Y > 124` (below the 3 grid rows) -> the
    **pointer path** (`0x80137DC4`): UNCONDITIONALLY forces state 0 every frame. The 8 center slots
    render below Y 124, so the pointer path wiped the cursor state every frame -- not only no hover,
    but an in-progress grab (state 1) was reset before it could commit. (State drives grab-vs-menu;
    the grab/commit reads it. The graphic handler `0x80134D54` is purely cosmetic -- writes neither
    +0x54 nor +0x84.)
    - **First try (WRONG): wrap the routine's caller and force state=2 after it ran.** This made the
      hover marker appear, but A still couldn't drop the marker: by the time the wrapper ran, the
      vanilla pointer path had already clobbered the holding state to 0, and forcing 2 each frame
      also clobbered any in-progress grab. (HW: "marker appears on the hand but won't place.")
    - **Fix (RIGHT): internal patch at the `bc1t` Y>124 branch.** `OS.patch_start(0x00136018,
      0x80137D98)` replaces the branch (its delay slot `sll t7,t7,4` is reproduced so `t7` stays
      valid for the pointer path; the `c.lt.s 124,Y` flag is still live). In
      `TwelveCharBattle.tourney_cursor_state_`: `Y<=124` -> vanilla fall-through (`0x80137DA0`);
      `Y>124` + Tournament + cursor inside the center block -> jump to the vanilla **hover path**
      (`0x80137E04`, after setting `t9=port*188`, `t0=0x80140000`); otherwise -> vanilla pointer
      path (`0x80137DC4`). So the center block runs the exact same hover machinery as a normal grid
      slot (hover when free, keep holding while grabbing), and L/R panels / RESET (outside the center
      rectangle) still take the pointer path. Center region matches `get_character_id_`'s hit-test
      (cursor render X base `CENTER_X-13`, Y base `CENTER_ROW_BASE*H + START_Y`). Verified in the
      built ROM that `0x80137D98` jumps to the wrapper.
  - **Earlier center hit-test coordinate-frame fix:** the center hit-test in
    `get_character_id_` was written in the **render** coordinate frame, but `a1`/`v1` arrive in the
    **cursor (hit)** frame. The grid hit-test proves the relationship: portraits drawn at
    `START_VISUAL+START_X-8` (=32) are selected from base `LEFT_GRID_START_X` (=19) -> cursor x =
    render x - 13; and `v1 = ypos - START_Y` maps row r to `[r*H, r*H+H)`, so the row base is just
    `CENTER_ROW_BASE*H` (no extra START_VISUAL). The block's hit region was therefore ~13px right and
    ~10px low, so the cursor was never inside it (token-autoposition never even ran -> "nothing
    changed"). Fixed: x base `CENTER_X - 13` (expressed via the grid constants), y base
    `CENTER_ROW_BASE*PORTRAIT_HEIGHT`. Verified in the built ROM: `addiu t0,a1,-87` / `addiu t1,v1,-90`.
  - **HW bug found + fixed (selecting the bottom-right 2 center slots crashed):** after the cursor
    fixes, 6 of the 8 center slots selected fine but the bottom-right two (portrait ids **30 and
    31**) crashed. Root cause: `CharacterSelect` reserves two portrait ids for the bonus/random
    "bookend" buttons -- `BOOKEND_BONUS_PORTRAIT = NUM_PORTRAITS (3*10 = 30)` and
    `BOOKEND_RANDOM_PORTRAIT = 31`. Tournament's 32-slot grid reuses the same portrait-id space, so
    its slots 30/31 (CRASH/PEACH) collided with those sentinels; selecting them ran bookend code
    (e.g. `set_white_flash_texture` combined the character's large portrait offset with the wrong
    base file -> wild pointer -> crash). This is why exactly 30 ids (0-29) worked and only 30/31
    crashed, and why the chars selected fine in normal VS (different ids there). Fix (2 spots in
    `CharacterSelect.asm`, chosen over gating ~8 individual bookend checks): move the sentinels past
    the largest grid -- `BOOKEND_BONUS_PORTRAIT = TwelveCharBattle.MAX_SLOTS (32)`,
    `BOOKEND_RANDOM_PORTRAIT = 33` -- and pad `portrait_offset_table` so the bookend offsets sit at
    ids 32/33 (the VS grid is 0-29 and never indexes the 30/31 gap; 12CB/Tournament use their own
    tables). All bookend checks reference the constants, so this corrects them uniformly; the
    bookend portrait id is constant-derived (not hardcoded in objects), so VS bookends still work.
    Verified in the built ROM: offset table entries [32]=BONUS, [33]=RANDOM.
  - **Follow-on VS regression found + fixed (selecting RANDOM in VS crashed):** moving the bookend
    ids to 32/33 exposed a latent bug. `set_white_flash_texture` finds a portrait's object by
    walking room 0x1B's object list and COUNTING positions until the count == portrait id. VS only
    has 32 objects (30 portraits + 2 bookends at list positions 30/31), so when the random bookend's
    id became 33 the walk ran off the end of the list -> crash. (12CB random works because it scrolls
    a per-mode table rather than selecting a dedicated bookend slot.) Fix: match the object by its
    STORED portrait id (`0x0030`) instead of by list position (the only position-counting walk in the
    CSS -- grep-verified), and set the bookend objects' `0x0030` to BOOKEND_BONUS/RANDOM_PORTRAIT in
    `draw_portraits_` so they're findable. This is id-based and robust for all modes/grid sizes.
  - **Token auto-position (DONE):** `_vs_x_position`, `token_autoposition_y_fix_`, and
    `place_token_from_id_` are center-aware for ids >= NUM_SLOTS, so a placed/recalled token lands
    on the center portrait instead of the uniform 4th-row spot. The token-grab itself is gated by
    "char-under-cursor != NONE" (verified by disassembly at `0x80138a98`), already satisfied by the
    Tournament y-cutoff raise. Together these fix the "markers can't be moved below the 3 rows" bug.
  - **HW bug found + fixed (center X was 0 → block rendered far left, behind the P1 panel):** the
    appended center X entries were written as `float32 (CENTER_X + PORTRAIT_WIDTH * {cn})`, which
    **bass emitted as 0.0** (a parenthesized arithmetic expression as the `float32` operand did not
    evaluate). Fixed by matching the grid loop's pattern: `evaluate cx(...)` then `float32 {cx}`.
    Verified in the built ROM that `portrait_x_position[8..11]` = 100/130/160/190 (block spans
    100-220, centered on screen-center 160). General bass gotcha: compute numeric table values with
    `evaluate` into a variable, then emit `float32 {var}` — don't pass an arithmetic expression
    directly to `float32`.

### (superseded) earlier Stage 2b plan / KEY DESIGN FINDING:
  12CB's custom model is **per-port halves**: `p1` table = left half (cols 0-3), `p2` = right half
  (cols 4-7). `update_character_set_` (TCB ~2573) copies a set into the live tables **per-port in
  fixed top/mid/bottom 4-portrait chunks** — hardwired to the 24-slot half-grid. `set_portrait_` /
  `get_portrait_id_` likewise pick p1/p2 by port. **Tournament (Phase C) is ONE shared full grid
  both players pick from**, so it does NOT fit the per-port-halves model. Plan for 2b:
  1. Treat Tournament's grid as a **single shared 32-slot table** (use `p1`'s custom table as the
     grid for both ports). Add a Tournament population path that copies all 32 (from `layout.t` /
     `id_table_t` + `portrait_offset_table_t`) into the live `id_table`/`portrait_offset_table`
     and builds `portrait_id_table` (32) — bypassing the per-half `update_character_set_` chunk copy.
  2. On **mode change** (reuse E.4 `last_owner_mode`): entering Tournament copy `layout.t` → p1
     (and set default to custom); entering 12CB restore p1/p2 to `u` so 12CB custom is unchanged.
  3. Convert the runtime slot loops `NUM_SLOTS`/`-1`/`NUM_PORTRAITS` → `slot_count` (TCB ~410,
     1272/1393/1541/1597, 2514, 2708, 4445/4469/4498, 5633, 1147; plus CharacterSelect
     `draw_portraits_` ~3653/3655 `TwelveCharBattle.NUM_SLOTS`). Do this together with 1-2 so
     Tournament never iterates past populated data.
  4. Default Tournament to custom (`config.p1/p2.character_set` = custom index = NUM_PRESETS).

- **Stage 2c — positions/render (after 2b; HW-tuned):** give slots 24-31 coordinates (the 8
  "center" portraits where stats were). `portrait_x_position` is per-column; center slots need
  explicit coords. Expect HW tuning.

- **Stage 3 — cleanup (DONE, build-verified, needs HW test):** removed the "Character Set" selector
  for Tournament (E.3 already removed Stocks Remaining + Best Character display/writes). The selector
  overlapped the new center block and is meaningless for Tournament (fixed `layout.t` roster, no
  preset cycling). Three gated changes (all `vs_mode_flag == TOURNEY`):
  - `setup_`: `_skip_character_set` skips the "Character Set" label, the p1/p2 set-name strings, and
    the 4 arrow textures.
  - `handle_custom_presses_`: `_check_character_set_p1` early-outs to `_end` for Tournament so the
    arrow press hit-regions (y ~172, which overlap the center block's bottom row) don't fire. RESET
    (started-path) and BACK (`_end`) are unaffected.
  - `update_character_set_` was already a no-op for Tournament (Stage 2b), so cycling is inert.

### Original Phase B notes (reference)

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

> **Asset workflow for E.1 + E.2:** see `ClaudeInsertingTourneyMenuTextures.md` (the 3 textures
> to create, which ROM files they go in — `0x006` button label, `0x0A06` title banners — the
> append-only injector steps, and the offsets to report back so Claude can finish the ASM).

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

### E.3 — Tournament must not touch the "Stocks Remaining" / "Best Character" stats — DONE (build-verified, needs HW confirm)
These per-side stats belong to 12CB and Tournament shares `config`, so a tournament session was
corrupting them. All gated to `vs_mode_flag == TOURNEY`:
- **Writes (the actual fix):**
  - `update_stocks_remaining_` (TCB ~5562): the per-side `stocks_remaining` decrement + the
    `STATUS_COMPLETE` set are now skipped for Tournament (new `_skip_side_total` branch). The
    per-slot `stocks_by_portrait_id` write below it is **kept** — that's the elimination data
    Tournament needs. Side effect: Tournament's `config.status` never reaches COMPLETE (fine; it
    has no "whole-match-complete" concept). Note `update_stock_fields_` still *initializes*
    `stocks_remaining`, but 12CB re-initializes it on entry (status NOT_STARTED), so it self-heals.
  - `set_best_characters_` (TCB ~3998): early-return for Tournament right after the status check,
    so none of the `best_character`/TKO fields are written.
- **Display (done together, since a null `best_character_pointer` draw would be unsafe; also
  pre-satisfies part of Phase B's display removal):** in `setup_` the "Stocks Remaining" draws
  (`_skip_stocks_remaining`) and the "Best Character" block incl. the `set_best_characters_` call
  (`_skip_best_character`) are skipped for Tournament. The "Character Set" selector is **kept**
  (it's a selection control, not a 12CB stat; Phase B reworks it with the 32-slot layout).
- **Left alone:** `handle_reset_` (the RESET button Phase B keeps) still resets these to defaults —
  it's a deliberate user reset, not the scoring-path corruption E.3 targets.

Build clean; linters pass; overlap checker shows only the 3 known conflicts.

### E.4 — Fix: exiting to main menu no longer saves data (12CB AND Tournament) — DONE (build-verified, needs HW confirm)
Regression cause confirmed: the Phase D carryover fix in `before_css_setup_` reset the shared
`config` on **every** fresh entry from the VS menu (`previous_screen == VS_GAME_MODE_MENU`),
regardless of mode. Because 12CB and Tournament **share** `config`, backing out to the VS menu
and returning to the *same* mode wiped that mode's session data (stocks/eliminations/stats) — i.e.
it didn't "save".

**Fix taken** (the "narrow the reset" option, not a full state split): added a new word
`TwelveCharBattle.last_owner_mode` (init `-1`) that records which `VsRemixMenu.vs_mode_flag`
currently owns `config`. In `before_css_setup_`, on a fresh menu entry we now read the mode being
entered, store it as the new owner, and **only reset `config` when the mode actually changed**
(`beq current, last_owner -> skip reset`). So:
- Re-entering the SAME mode (12CB→12CB or Tournament→Tournament) preserves its session data (save). 
- Switching modes (12CB↔Tournament) still resets, so no carryover between the two.
- Re-entries between matches (`previous_screen != VS_GAME_MODE_MENU`) are still left alone.

Registers: the new check uses `t4`/`t5` (plus reusing `t0`) ahead of the existing `t0`-`t3` reset
block; branches are followed by `nop` (delay-slot safe). Build clean, both linters pass, overlap
checker shows only the 3 known pre-existing conflicts.

**Still open (broader implication):** 12CB and Tournament remain entangled via the shared `config`
(stocks/eliminations/stats). This fix makes the *reset* mode-aware but does not give Tournament a
truly separate persistent state — revisit if deeper separation is needed (e.g. independent
best-character/stat history per mode). E.3 (stop Tournament writing the 12CB stats) is the next
step toward that separation.

---

## Pitfalls (learned)
- Running `bass` alone yields an **unbootable** ROM — always `chksum64` + `rn64crc` after.
- The two CI linters + the overlap checker must pass after every change. Watch for `li` (a
  pseudo-op that can expand to 2 instructions) in a branch delay slot, and for two
  branches/jumps in a row.
- When debugging "no effect", verify engine assumptions by **disassembling `original.z64`**
  (RAM→ROM deltas in the `ssb64-rom-deltas` memory).
