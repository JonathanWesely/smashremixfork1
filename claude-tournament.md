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
- Eliminated-character **darken/lock in Tournament** bugfix — DONE, HW-confirmed (the previously
  noted "minor bugs to chase later" did NOT reproduce in the latest HW pass — see that bugfix
  section).
- **E.3** (Tournament doesn't touch Stocks Remaining / Best Character stats) — DONE, HW-confirmed.
- **E.4** (save-on-exit / mode-aware `config` reset via `last_owner_mode`) — DONE, HW-confirmed.
- **Phase B Stage 1** (MAX_SLOTS, runtime `slot_count`, grown buffers) — DONE, HW-confirmed inert.
- **Phase B Stage 2a** (parameterized table macro, extended `layout.u` to 32, grew `p1`/`p2`, added
  32-distinct `layout.t` + tables) — DONE, HW-confirmed.
- **Phase B Stage 2b** (live tables → `layout.t`, `update_character_set_` no-op for Tournament,
  loop conversions to `slot_count`, `get_character_id_` bounds to 32) — DONE, HW-confirmed.
  Tournament shows **32 distinct selectable portraits**.
- **Phase B Stage 2b bugfixes** (HW-found) — DONE, HW-confirmed:
  - *Inverted `slot_count` branch.* `before_css_setup_` used `bnel` (branch-likely) where it
    needed `beql`, so the 32-slot override fired for **12CB** and was skipped for **Tournament**.
    This caused BOTH reported HW bugs: Tournament showed only 24 icons, and 12CB crashed (TLB load
    at a wild VA) after a Tournament visit because its grid loops ran 32 wide over uninitialized
    table tails. One-char fix (`bnel`→`beql`); matches the working idiom at `get_character_id_`.
  - *Extra 8 unselectable.* `CharacterSelect.get_character_id_` rejected any cursor with
    `ypos >= START_Y + 85` (3-row cutoff) before reaching the 12CB mapper, so the 4th row was
    never hit-tested. Raised the cutoff to `START_Y + 165` **for Tournament only** (12CB keeps 85).
- **Phase B Stage 2c — centered block (render + hit-test)** — DONE, HW-confirmed. The 8 extra
  slots (ids 24-31) render as a centered `CENTER_COLS x CENTER_ROWS` (4x2) block below the 24-slot
  grid, and a dedicated cursor hit-test selects them there. See the Stage 2c section for the
  geometry constants.

**Status: feature-complete and HW-confirmed. Tournament Mode is DONE.** The current `tourney-mode`
build has been hardware-tested end to end: all 32 Tournament portraits show (24-slot grid + centered
4x2 block), all are selectable by both players, 12CB remains identical (no post-Tournament crash),
E.3/E.4 behave correctly (stats not corrupted; save-on-exit works), the font-string "Tournament"
button + "Tournament 1/2" title render (E.1/E.2, including the initial-frame banner-flash fix), the
round-bracket overlay works for all 5 rounds with the icons aligned to the boxes, and matchup setup
after a match is unrestricted (CPU token re-grab + free re-selection). Opening Tournament also plays
its own **distinct announcer voice** (see the **Tournament announcer sound** note below and the full
`sound.md` log). See the **Feature summary** and **Round-bracket overlay** sections below.

### Tournament announcer sound (DONE, HW-confirmed) — see `sound.md`
Opening Tournament plays a distinct "open" announcer clip (`src/sounds/tournament.aifc`) instead of
12CB's `TWELVECB`. Registered via `add_sound` in `src/FGM.asm` (FGM id `0x609`, constant
`FGM.announcer.css.TOURNAMENT`) and played by a new Tournament branch in
`TwelveCharBattle.update_announcer_on_entry_`. The `.aifc` was produced by a self-contained Python
VADPCM codec, `scripts/vadpcm_encode.py` (no N64 SDK tools), then length-fixed (explicit
`fgm_length`, since the auto formula assumes the reference files' inflated FORM size) and loudened
+5 dB (tanh soft-limit `louder` subcommand). Full design/debug log is in **`sound.md`**.

**Resolved follow-ups (kept for history — all HW-confirmed):**
1. **Phase B Stage 2b + 2c** — HW-confirmed: all 32 portraits show with the 8 extras as a centered
   4x2 block, selectable by both players; 12CB still identical (no longer crashing after a
   Tournament visit); E.3/E.4 confirmed (stats not corrupted; save-on-exit works). The `CENTER_*`
   geometry constants are HW-tuned.
2. **Phase B Stage 2c — token auto-position for center slots (DONE, HW-confirmed):** all four
   slot↔screen mappings are center-aware — render, cursor hit-test, and the
   two token auto-position paths (`token_autoposition_._vs_x_position` + `token_autoposition_y_fix_`,
   and `place_token_from_id_`). This fixed the HW bug where a token placed on a center character
   snapped to the old uniform 4th-row spot (just below the 3 rows) instead of onto the center
   portrait — i.e. "markers can't be moved below the 3 rows." Each token path computes
   `ccol/crow` for ids >= NUM_SLOTS and positions at `CENTER_X + ccol*W` / effective row
   `CENTER_ROW_BASE + crow` (matching render, plus each site's existing token offset).
3. **Phase B — in-game custom editing (DONE, HW-confirmed):** Tournament now
   defaults to the per-slot "custom" character set, with shared scroll-only editing (user's choice:
   one shared grid, not per-player; no randomize/copy/preset). No toggle widget re-added (Stage 3
   removed it). How it works: hold a slot's token and hold Z/R to scroll that slot through all
   characters; both players edit the one shared grid; edits persist across CSS entries (until the
   E.4 mode-change reset). Implementation (all gated to `vs_mode_flag == TOURNEY`, in
   `src/TwelveCharBattle.asm`):
   - `force_ffa_and_stock_`: point BOTH custom `character_set_table` entries (NUM_PRESETS+0/+1) at the
     shared `id_table_t`/`portrait_offset_table_t`/`portrait_id_table_t`, and set
     `config.p1/p2.character_set = NUM_PRESETS`. 12CB restores those entries to its per-port
     `id_table_p1/p2` (so 12CB's own custom mode is untouched).
   - In-game cycler (the `character_set == custom` Z/R handler): for Tournament, skip the 12CB extras
     (L set-all, D-pad randomize/copy, preset cycle) and skip the per-half +/-4 mirror, so only the
     single hovered slot of the shared 32-distinct grid is edited.
   - Redraw: `update_character_set_` for Tournament now skips the per-port repopulate but still runs
     the `_portraits` re-render (jumps to `_portraits` instead of returning); its loop bound and
     `update_portrait_id_table_`'s bound changed from `NUM_SLOTS` to runtime `slot_count` (24 vs 32)
     so all 32 slots redraw/remap.
4. **Phase B Stage 3 (DONE, HW-confirmed):** the "Character Set" selector is no
   longer drawn for Tournament (it overlapped the new center block, and the roster is the fixed
   `layout.t`, not a cycleable preset). Both the display (`setup_` `_skip_character_set`) and the
   arrow press-checks (`handle_custom_presses_` `_check_character_set_p1` Tournament early-out) are
   gated off; `update_character_set_` was already a no-op for Tournament. RESET/BACK unaffected.
**Remaining work:**
- **E.1 + E.2 — DONE via font strings (build-verified, needs HW test).** Implemented WITHOUT
  textures / without touching `roms/original.z64` (user's choice — every existing Remix CSS texture
  is a base-ROM file-offset added via the injector pipeline, so the texture route would require
  modifying `original.z64`). The font-string route uses the game's built-in `Render` string system.
  See the **Phase E** section for details. (A texture-injection alternative was considered and
  rejected; it would require regenerating `roms/original.z64`. The font route avoids that entirely.)
  - **E.1:** the Remix Modes "Tournament" button renders a font-string "Tournament" label instead
    of the Tug-of-War placeholder texture, via a custom creation routine
    (`VsRemixMenu.create_tourney_button_`) wired through the `menu_button_table` `0x00` field.
  - **E.2:** the placeholder title banner is hidden for Tournament on both the CSS
    (`hide_tourney_banner_`) and results (`hide_tourney_results_banner_`) screens, and the
    repurposed "Tournament 1/2" font label (formerly the temp Phase D center label, now top-left,
    left-aligned) is the title. Results screen has no title text yet (possible follow-up).
    - **E.2 initial-frame flash fix (DONE, HW-confirmed).** `hide_tourney_banner_` hooks the banner's
      *creation* (`sw v0,0xBDB0(at)` at `0x80134518`) and sets render flags to hide — which only works
      at creation (the object is then never added to the render list). But the **initial** CSS build
      creates the banner with the flag unset, so "12-Char. Battle" showed until the first redraw (any
      button press) recreated+hid it; writing `0x24=0x0205` to an *already-live* object does NOT pull
      it from the render list. Fix: a per-frame routine `force_hide_tourney_banner_` (registered in
      `setup_`, Tournament-only) that **moves the banner off-screen every frame** — the banner display
      struct is at `[obj+0x74]`, x float at `+0x58` (vanilla sets `27.0`); writing a far off-screen x
      (`1200.0`) reliably hides a live object. It also still writes the hide flag so a freshly-created
      banner is hidden instantly. Banner object-pointer global = `0x8013BDB0`. (Disassembled from
      `original.z64`; **the CSS header routine `0x80134xxx` segment delta is `0x80001D80`**, NOT the
      `0x7FFE0E60` used for the `0x80137xxx` scoring overlay.)
  - HW-tunables: button label X/alignment/scale; CSS title X/Y/scale/color; the button string does
    not inherit the texture buttons' selected-highlight color swap.
  - **Post-HW tweaks (build-verified):** button label scale bumped +80% (`0x3F600000` → `0x3FC9999A`
    = 1.575) so "Tournament" isn't too small.

**Post-HW bug fixes (build-verified, needs HW test):**
- **T1 subsequent-match stocks** — a T1 winner was starting later matches with reduced stocks (only
  the CSS count was reset). Fixed in `set_initial_stock_count_` — see the Phase D "RESOLVED" note.
- **RESET didn't clear Tournament's 8 center icons** — `update_stock_fields_` (TCB ~1912, called by
  `handle_reset_`) looped a hardcoded 24 portraits (6×4), so slots 24–31 stayed darkened/locked on
  RESET. Fixed to loop the runtime `slot_count`/4 (24 for 12CB → unchanged; 32 for Tournament → all
  icons cleared).
- **Leftover 12CB control legends on the Tournament hover indicator** — when holding a token over a
  slot, `draw_custom_portrait_indicators_` (TCB ~5247) draws the on-hover control legend. It runs in
  the "custom" character-set state, and Tournament IS custom (`character_set == NUM_PRESETS`), so it
  was drawing the 12CB-only prompts whose *functions* are already disabled for Tournament (the
  in-game cycler skips L set-all / D-pad randomize/copy / preset cycle). Removed the 5 unused visuals
  for Tournament — **L : Set All**, **D-pad : Presets/Random/Copy** (legend strings + their button
  icons), and the **3 yellow/white indicator rectangles** — while keeping the left/right arrows and
  the **Z/R** scroll-prompt icons (the actual scroll control). Done with three `vs_mode_flag ==
  TOURNEY` gates in the existing free-region routine (no new `OS.patch_start`): skip the **creation**
  block (`_skip_extra_create`, jumps to the register-restore), skip those 5's **P2 X-position
  adjustment** (`_skip_extra_adjust`), and skip their **teardown** (`_skip_extra_destroy`). Safe
  because the arrows/Z/R live in a separate `0x0008` sibling chain that the main-object destroy still
  cascades, and the removed objects' reference slots (`0x0030/0x0040/0x0044/0x0048/0x004C/0x0050/
  0x0054` of the indicator object) are never written *or* read for Tournament. 12CB byte-identical.
  Both linters pass; overlap checker shows only the 3 known conflicts; full build (bass → chksum64 →
  rn64crc) clean.

---

## Feature summary — what Tournament Mode is, and how each piece was built

### Tournament 1 vs Tournament 2
`TwelveCharBattle.tournament_type` (0 = Tournament 1, 1 = Tournament 2; default 0). Toggled with the
top FFA/Team button (repurposed via `Smashketball.enable_toggling_mode_`) and shown as the top-left
CSS title ("Tournament 1" / "Tournament 2"). Both modes play a manually-arranged single-elimination
bracket of 1v1 matches; the difference is how stocks carry between matches:

- **Tournament 1** — every match starts all surviving characters at **full** stocks. Characters lose
  stocks during a match, but a winner (and any non-eliminated character) begins its next bracket
  match back at `num_stocks`. Implemented in two places that have to agree: the CSS-visible per-slot
  count (`update_stocks_remaining_` resets every survivor's `stocks_by_portrait_id` to `num_stocks`
  the moment a fighter is eliminated) **and** the real per-match stock count
  (`set_initial_stock_count_` uses the per-portrait count instead of carrying over the previous
  match's remaining stocks).
- **Tournament 2** — survivors **retain** their remaining stocks between matches (vanilla 12CB
  carry-over); a character whittled down stays whittled down.
- **Both** — losing all stocks **eliminates** a character: that slot darkens and locks (unselectable)
  for the rest of the session, tracked per-slot via `stocks_by_portrait_id` (`0xFF` = eliminated).

### How each feature was built (all gated to `vs_mode_flag == TOURNEY`; 12CB stays byte-identical)
- **Reuse the whole 12CB CSS + engine** — selecting Tournament sets `twelve_cb_flag`, so 12CB's
  character-select, match engine, and darken-on-elimination are reused wholesale. (Phase A)
- **Any character for either player** — lifted 12CB's per-side grid-half restriction
  (`get_character_id_`, `get_portrait_id_`, `is_character_valid_for_port_`). (Phase C)
- **32 distinct selectable characters** — a dedicated 32-slot layout (`layout.t`): the 24-slot grid
  un-mirrored plus an 8-icon centered 4×2 block (where the stats text used to be), with a runtime
  `slot_count` (24 vs 32), a center-block render + cursor hit-test + token auto-position, and in-game
  per-slot editing (hold a token + Z/R to scroll a slot through every character). (Phase B)
- **No corrupted 12CB stats / proper save-on-exit** — Tournament shares 12CB's `config`, so it's
  stopped from writing the per-side "Stocks Remaining"/"Best Character" stats, and the shared-state
  reset was made mode-aware (`last_owner_mode`) so re-entering a mode preserves its session. (E.3/E.4)
- **"Tournament" button label + "Tournament 1/2" title** — done with the game's built-in **font**, NOT
  textures (so `roms/original.z64` is never modified): `VsRemixMenu.create_tourney_button_` draws the
  menu button's label, and the placeholder CSS/results title banner is hidden
  (`hide_tourney_banner_` / `hide_tourney_results_banner_`) while a repurposed font label is the title.
  (E.1/E.2 — see also the deleted texture-injection doc, replaced by this font route.)
- **Round-bracket overlay** — a clickable "Round 1–5" button above RESET draws white matchup-outline
  boxes between the icons per round (see the dedicated section below).
- **Icons aligned to the bracket boxes** — Tournament renders from a contiguous portrait-X table
  (`portrait_x_position_t`, without 12CB's ±8 P1-left/P2-right half-gap) so the single unified grid
  lines up with the boxes; the render pointer is switched per-mode in `force_ffa_and_stock_`.
- **Free matchup setup after a match** — removed two 12CB "keep your character" restrictions for
  Tournament: P1 can re-grab the CPU's selector token (`prevent_token_pickup_`) and assign it **any**
  live (non-eliminated) character (`prevent_defeated_char_select_`).

---

## Round-bracket overlay (TCB)

A clickable **"Round 1–5"** font label sits just above RESET on the Tournament CSS; clicking it
cycles the displayed round and redraws white **matchup-outline boxes** between the character icons,
so you can lay out and read the bracket.

- **Button + label**: `tournament_round` (0–4 = Round 1–5), `round_pointer` + `string_round_1..5` drive
  a live `draw_string_pointer` label in `setup_` (GROUP_ALWAYS, above RESET). The click is detected in
  `handle_custom_presses_` via `CharacterSelect.check_press_` (clickable any time on the Tournament
  CSS) → `cycle_round_` advances the round (mod 5), updates the label pointer, plays a click FGM, and
  redraws the lines. The round resets to 1 on every CSS entry.
- **Lines are orthogonal** (the engine's `Render.draw_rectangle` is axis-aligned). `icon_coords` holds
  the 32 icon centers — the single, HW-tunable source of truth for all line positions. Per-round group
  tables (`round_1_pairs`…`round_5_pairs`, dispatched via `round_pairs_table` = {pointer, count} per
  round) list each group as its **first,last** icon; `draw_box_` outlines the bounding box of those two
  corners (so the same routine boxes a pair, a group of 4, 8, …). `add_line_` draws each white 2px
  rectangle and records its object pointer; `redraw_round_lines_` `DESTROY_OBJECT_`s the previous
  round's lines before drawing the new round's.
- **The five rounds** (single-elim over 32 icons): **R1** = 16 pair boxes · **R2** = 8 boxes of 4 ·
  **R3** = 4 boxes of 8 · **R4** = 2 boxes of 16 · **R5** = no lines.
- **L-shaped group (R4, icons 17–32)**: row 3 is full-width (8 icons) but the center block beneath it
  is narrower (4, centered), so a plain bounding box would spill into the side panels. `draw_tee_17_32_`
  instead draws an 8-segment "T" outline — full-width across row 3, stepping inward to wrap the center
  block — with all edges derived from `icon_coords` so it tracks any icon-position tuning.

---

## Shuffle / random re-seed (TCB — DONE, HW-confirmed)

Two clickable font buttons on the same row as the round button (`[Round 1] [Shuffle] [N]`, y≈186 above
RESET) let players randomly re-seed the 32-slot bracket after laying out the roster. Tournament-only;
12CB untouched. All in `src/TwelveCharBattle.asm`. (The "Round 1" label + its click region were later
nudged left ~15px — X 136→121, click ulx 114→99 — to make room in the row; Shuffle/count unchanged.)

- **State/data** (declared by `slot_count`, *before* `setup_` — `Render.draw_number` evaluates its
  pointer arg at macro-expansion time, so a forward label fails): `shuffle_count` (dw, 1..MAX_SLOTS,
  reset to `MAX_SLOTS` on every CSS entry) and `shuffle_temp` (`fill MAX_SLOTS`, scratch for the
  permutation). `string_shuffle` lives by the round strings.
- **Draw** (in `setup_`'s Tournament round-UI block): `Render.draw_string(string_shuffle, …)` +
  `Render.draw_number(shuffle_count, Render.update_live_string_, …)` (live-updates from the word).
  Button X/Y are HW-tunable (Shuffle ≈ X 184, count ≈ X 224, same y as Round).
- **Click** (in `handle_custom_presses_`, chained off the round button's "not pressed" path so the
  Tournament gate is shared): two more `CharacterSelect.check_press_` regions → `do_shuffle_` and
  `cycle_shuffle_count_`. Regions are HW-tunable; keep them clear of the centered 4×2 block and RESET.
- **`cycle_shuffle_count_`** (template = `cycle_round_`): `N = (N % MAX_SLOTS) + 1`; plays the click FGM
  (`jal 0x800269C0; a0=0x9E`). The live `draw_number` reflects it.
- **`do_shuffle_`**: copies `id_table[0..N-1]` (Tournament's shared `id_table_t`, via
  `character_set_table[NUM_PRESETS].id_table`) into `shuffle_temp`, **Fisher-Yates** permutes it
  (`Global.get_random_int_safe_(a0=i+1) → j∈[0,i]`; `s0..s2` hold loop state, preserved across the
  call), then writes each slot back with `set_portrait_(a0=slot, a1=0, a2=char)` and re-renders via
  `update_character_set_(a0=0, a1=FALSE, a2=TRUE)` (Tournament → `_portraits`) — the exact reuse
  pattern from `handle_reset_`. Plain permutation (a char may keep its slot by chance; the guarantee is
  the bijection). Setup-time action: it permutes only the grid's character assignments; per-slot
  `stocks_by_portrait_id` is left alone.
- No new `OS.patch_start` (pure free-region routines), so the overlap checker still shows only the 3
  known conflicts. Build clean; both linters pass.

### Related re-seed / selection tweaks (DONE, HW-confirmed)
- **RESET clears the grid to RANDOM.** `handle_reset_` (TCB) now, for Tournament only, loops all
  `MAX_SLOTS` slots and `set_portrait_(slot, port 0, Character.id.RANDOM /*0x1B = "?" icon*/)` before
  its existing `update_character_set_` re-render — so hitting RESET (which appears once a game starts)
  also blanks every icon back to the random "?" for a fresh re-seed. 12CB's match-struct reset is
  unchanged.
- **Select by the selector's CENTER, not its right edge.** In the CSS cursor hit-test
  (`CharacterSelect.asm`, the `twelve_cb_flag` path that adjusts `a1` before
  `TwelveCharBattle.get_character_id_`), Tournament now shifts the hit point left by
  `TwelveCharBattle.PORTRAIT_WIDTH / 2` (15px) so a press grabs the icon under the selector's center.
  Gated to Tournament; 12CB selection is byte-identical. The 15px amount is HW-tunable.

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

RESOLVED (was OPEN RISK, HW-confirmed bug): the per-match fighter stock did NOT come from
`stocks_by_portrait_id` for a *continuing* fighter — `set_initial_stock_count_` (TCB ~3841, patches
`0x8018D4AC`) returns the **previous match's remaining** ending-stocks (`0x0002(prev_match)`) via
`bgtz t8, _end` whenever the fighter wasn't defeated. So the T1 survivor-reset (which only fixed
`stocks_by_portrait_id`, the CSS-visible count) never reached the actual match — a T1 winner kept
the reduced count. **Fix:** in `set_initial_stock_count_`, for Tournament + T1 only, skip the
"keep previous remaining" branch and use the **per-portrait** stock count (`stocks_by_portrait_id`,
already reset to `num_stocks` for survivors by `update_stocks_remaining_`). T2/12CB unchanged
(still retain remaining). Same encoding on both paths (match-struct `0x0002` and
`stocks_by_portrait_id` are both written from the same `t5`), so no off-by-one.

## Bug fix — eliminated-character darken/lock in Tournament (DONE, HW-confirmed)

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

Both build-verified; linters pass; overlap checker shows only the 3 known conflicts. The minor
darken/lock glitches that were flagged "for later" did **not** reproduce in the latest HW pass —
considered resolved.

---

## Phase B — 32 slots + remove stats (DONE, HW-confirmed)

**Design locked (user):** Tournament gets a **dedicated 32-distinct layout** (the 24 grid slots
un-mirrored + 8 more in the center); 12CB keeps its shared 24-mirror layout untouched. All
Tournament slots default to the per-side **custom** state (editable to any character). Claude
auto-fills the roster; user tweaks later. Implemented in stages (all **DONE, HW-confirmed**):

- **Stage 1 — foundation (DONE, HW-confirmed):**
  - `constant MAX_SLOTS(32)` (TCB ~32) + runtime `slot_count` word (default 24).
  - `before_css_setup_` sets `slot_count` = 32 for Tournament / 24 for 12CB on every CSS entry.
  - Grew shared buffers to MAX_SLOTS: `config.stocks_by_portrait_id` (`fill 24`→`fill MAX_SLOTS`),
    the live `id_table` (`fill MAX_SLOTS`) and `portrait_offset_table` (`fill MAX_SLOTS * 4`).
  - **Inert/behavior-preserving:** nothing reads `slot_count` yet and 24-slot code ignores the
    extra buffer space, so 12CB **and** Tournament still run as 24-slot. Pure groundwork.

- **Stage 2a — data (DONE, HW-confirmed):**
  - Parameterized `create_portrait_tables(layout_type, layout, count)` (3-arg worker + 2-/1-arg
    delegates passing NUM_SLOTS); `while {count}` instead of `while NUM_SLOTS`.
  - Extended `layout.u` to 32 (slots 25-32 placeholders); grew `p1`/`p2` via
    `create_portrait_tables(p1/p2, u, MAX_SLOTS)` (12CB still reads first 24 = unchanged).
  - Added dedicated 32-DISTINCT `layout.t` + `create_portrait_tables(t, t, MAX_SLOTS)`:
    id_table_t / portrait_offset_table_t / portrait_id_table_t. Roster: base12 + remix12 +
    SONIC/SHEIK/MARINA/DEDEDE/GOEMON/BANJO/CRASH/PEACH. Builds clean (all symbols valid).
  - Still inert: nothing reads the 32-tables/`slot_count` at runtime yet.

- **Stage 2b — runtime wiring (DONE, HW-confirmed). Approach taken:** point the
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

- **Stage 2c — centered block (render + hit-test DONE, HW-confirmed):** the 8
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

- **Stage 3 — cleanup (DONE, HW-confirmed):** removed the "Character Set" selector
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

## Phase E — Cleanup (4 independent parts; all DONE — E.1/E.2 build-verified+needs HW test, E.3/E.4 HW-confirmed)

> **E.1/E.2 were done with font strings, NOT textures** (user's choice — see below). A
> texture-injection route was considered but rejected because it would require regenerating
> `roms/original.z64`; the font route avoids touching the base ROM entirely.

### E.1 — "Tournament" button label — DONE via font string (build-verified, needs HW test)
**Why no texture:** every existing Remix CSS texture is a byte-offset into a base-ROM file (added
via the injector pipeline), so a real button texture would require appending to / regenerating
`roms/original.z64`. The user wanted to keep a clean `original.z64`, so the label is rendered from
the game's built-in font instead.

Implementation (`src/VsRemixMenu.asm`): the VS-mode menu is built from `TEXTURE_INIT_` image
objects (no `draw_string` path), and `create_button_generic_` lives in a size-constrained patch
region with no room to add a per-row branch. So the Tournament row routes through the
`menu_button_table` **`0x00` "creation routine" field** to a new free-region routine
**`create_tourney_button_`**, which mirrors generic button creation (`CREATE_OBJECT_` →
`DISPLAY_INIT_` → `mnVSModeMakeButton` → `mnVSModeUpdateButton`) but draws a
`Render.draw_string("Tournament")` in the menu's own **group `0x04` / room `0x02`** (so it renders
and cleans up with the buttons) instead of a texture. The row's trailing text-offset (was the
Tug-of-War placeholder `0x000093B8`) is zeroed/unused. HW-tunables: label X/alignment/scale; the
string doesn't inherit the texture buttons' selected-highlight color swap.

### E.2 — T1/T2 title via repurposed font label + hidden placeholder — DONE (build-verified, needs HW test)
**Why no texture:** same reason as E.1 (would require modifying `original.z64`). Instead of driving
a title *image*, the temp Phase D "Tournament 1/2" font label is **repurposed as the title** and the
placeholder banner is hidden.

Implementation (`src/TwelveCharBattle.asm`):
- **Hide the placeholder banner for Tournament.** Vanilla draws the mode title banner from
  `update_css_header_`'s chosen offset. New patches set the banner object's render flags to hide
  (`0x0205` → `0x0024`, the standard hide idiom) for `vs_mode_flag == TOURNEY` only:
  - `hide_tourney_banner_` — CSS (`_vs`): patches `0x80134518` (right after vanilla saves the banner
    object pointer to `0x8013BDB0`), reproduces the two overwritten instructions.
  - `hide_tourney_results_banner_` — results (`_results`): patches the results header routine's
    epilogue at `0x80136820` (the results path doesn't save the pointer globally), reproduces the
    epilogue. Results has no title text yet (possible follow-up; only the placeholder is removed).
- **Repurpose the label as the title.** In `setup_` the existing
  `Render.draw_string_pointer(... tournament_type_pointer ...)` moved from center (X=160/Y=36,
  CENTER) to the title slot (X≈27/Y≈24, LEFT), still driven by `update_tournament_type_pointer_` →
  `string_tournament_1`/`_2` (now permanent, not temporary).
- The `update_css_header_` Tournament arms still pick `0x2048`, but that offset is now irrelevant
  since the banner object is hidden. HW-tunables: title X/Y/scale/color.

Build clean; both linters pass; overlap checker shows only the 3 known pre-existing conflicts.

### E.3 — Tournament must not touch the "Stocks Remaining" / "Best Character" stats — DONE, HW-confirmed
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

### E.4 — Fix: exiting to main menu no longer saves data (12CB AND Tournament) — DONE, HW-confirmed
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
  (RAM→ROM deltas in the `ssb64-rom-deltas` memory). Note deltas differ **per overlay** even for
  nearby RAM: the CSS *header* routine at `0x80134xxx` uses delta `0x80001D80`, while the CSS
  *scoring* code at `0x80137xxx` uses `0x7FFE0E60`. Derive the delta from a known
  `OS.patch_start(rom, ram)` pair in that exact range, don't assume.
- **Hiding a render object:** setting its render flags (`0x24 = 0x0205`) only takes effect **at
  creation** (it keeps the object off the render list). Writing that flag to an **already-live**
  object does nothing. To hide a live object reliably, move it off-screen (write a far x to its
  display struct, `[obj+0x74]+0x58`) every frame — see `force_hide_tourney_banner_`.
