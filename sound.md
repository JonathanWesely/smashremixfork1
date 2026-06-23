# sound.md — Custom sound when opening Tournament mode

Companion to `claude-tournament.md`. Covers the one open task of giving **Tournament mode** its own
"open" announcer sound (distinct from 12-Char. Battle), via Smash Remix's FGM/`add_sound` system.

## Context / goal

Opening Tournament mode currently plays the **12-Char. Battle** announcer voice. Tournament is a
gated extension of 12CB (sets `twelve_cb_flag`), and `TwelveCharBattle.update_announcer_on_entry_`
(TCB ~2178) has **no Tournament branch** — it falls through to the 12cb path and plays
`FGM.announcer.css.TWELVECB` (FGM id 1016 = `src/sounds/Twelve_Character_Battle.aifc`). Goal: play a
new, distinct sound when opening Tournament while 12CB keeps `TWELVECB`, and every other VS mode is
untouched.

## The audio file (the blocker)

The new sound must be an **AIFF-C (`.aifc`) file with Nintendo VADPCM compression** — the *exact same
format* as the existing `src/sounds/*.aifc` (e.g. `Twelve_Character_Battle.aifc`, `KoTH.aifc`). The
`add_sound` macro (`src/FGM.asm`) reads a fixed VADPCM layout:

- `0x04` — FORM/total size (word)
- `0x70` — `VADPCMCODES` predictor codebook (read as 0x80 bytes)
- `0xF4` — sample-data size (word)
- `0x100` — raw VADPCM (ADPCM) sample frames

A valid file's header looks like: `FORM…AIFC`, `COMM` compression type **`VAPC`** ("VADPCM ~4-1"),
an `APPL`/`stoc`/`VADPCMCODES` chunk, then `SSND`. Reference codebook params (from
`Twelve_Character_Battle.aifc`): order 2, 4 predictors.

**Specs:** mono, **16000 Hz** (32000 Hz also supported).

**Location / name:** `src/sounds/tournament.aifc` (the mode-announcer folder; matches `sounds/KoTH`,
`sounds/Smashketball`, `sounds/twelve_character_battle`). Lowercase `.aifc` (the macro appends
`.aifc`).

### Common mistake (seen during this task)
A plain PCM file does **not** work, and **just rewrapping the container is not enough**:
- A plain `.aiff` (`FORM…AIFF`, `COMM` with no compression, raw 16-bit PCM) — wrong: no AIFC, no
  codebook.
- An AIFF-C with compression type **`NONE`** ("not compressed") — still wrong: it's an AIFF-C
  *container* but the audio is uncompressed PCM with no `VADPCMCODES` codebook, so the macro reads
  PCM at `0x70`/`0xF4` as garbage.

The audio must be truly VADPCM-**encoded**, e.g. with the N64 SDK tools:
```
tabledesign -s 1 -f 16000 tournament.aiff > tournament.table
vadpcm_enc -c tournament.table tournament.aiff tournament.aifc
```
Verify the result's header shows `AIFC` + `VAPC` + `VADPCMCODES` (like the existing sounds) before
using it. (The repo ships **no** aiff→aifc/VADPCM converter; the existing `.aifc` were made with
external N64 tools.)

## Code changes (apply once a valid VADPCM `src/sounds/tournament.aifc` exists)

### 1. Register the sound — `src/FGM.asm`
- Add, as the **last** entry of the `add_sound` list (after the final
  `add_sound(sounds/stadium/PUMPED,…)` ~line 1838) so no existing FGM ids shift:
  ```
  add_sound(sounds/tournament, SAMPLE_RATE_16000, FGM_TYPE_VOICE, 0, -1)
  ```
  (Matches the 12cb sound's params; rate/reverb are easy to tweak. The macro `print`s the assigned
  FGM id at build time.)
- In the `FGM.announcer.css` scope (near `TWELVECB(1016)`), add a constant for the new id
  (auto-computed because the new sound is added last):
  ```
  constant TOURNAMENT(ORIGINAL_FGM_COUNT - 1 + new_fgm_count)
  ```

### 2. Play it on Tournament open — `src/TwelveCharBattle.asm`
In `update_announcer_on_entry_`, add a Tournament branch right after the Tug-of-War check and before
the `twelve_cb_flag` check, mirroring how 12cb routes to `_return` with `TWELVECB`:
```
lli     a0, VsRemixMenu.mode.TOURNEY
beql    t0, a0, _return                 // Tournament -> play the tournament announcer
lli     a0, FGM.announcer.css.TOURNAMENT
```
`t0` already holds `vs_mode_flag`, and `_return` is `jr ra` returning the chosen FGM in `a0` — so
Tournament plays the new sound, 12cb still plays `TWELVECB`, and all other modes are unchanged.
(Branching to `_return` like the 12cb path avoids the secondary `_default`/`_j` team announcer.)

## Verification

1. Validate the `.aifc` header first (`AIFC` + `VAPC` + `VADPCMCODES`).
2. Build: `assembler/bass.exe -o ssb64asm.z64 main.asm -sym logfile.log` — confirm the `add_sound`
   `print` shows a new FGM id for `sounds/tournament` and that `FGM.announcer.css.TOURNAMENT` equals
   it; then `chksum64` + `rn64crc`.
3. Lints + overlap: `sequential_branches.py`, `check_duplicate_action_edit.py`, `-d DEBUG` build +
   `overlapping_patches.py` (expect only the 3 known conflicts).
4. HW test: open Tournament → new sound; open 12-Char. Battle → still `TWELVECB`; Tag Team / KOTH /
   Smashketball / Tug of War unchanged.

## Status
**Blocked on a valid VADPCM `src/sounds/tournament.aifc`.** The code changes above are ready to apply
as soon as the file is correctly encoded. (Latest attempt was an AIFF-C with `NONE` compression —
needs real VADPCM encoding.)
