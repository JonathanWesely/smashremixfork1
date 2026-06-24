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
**DONE — HW-confirmed.** Tournament plays its own announcer voice on open; it plays in full and at the
desired (louder) level; 12CB and all other VS modes are unchanged. Unblocked by writing a
self-contained Python VADPCM codec (`scripts/vadpcm_encode.py`) — no N64 SDK tools needed.
(See the three sub-sections below for the two follow-up fixes after the first HW test: the half-clip
length fix and the +5 dB loudness pass.)

- Source audio was a 32 kHz mono 16-bit PCM `.wav` (the user's `TournamentVADPCM.aifc` was actually a
  WAV, not VADPCM). The codec encodes it to a real AIFF-C/VADPCM file whose chunk framing byte-matches
  `Twelve_Character_Battle.aifc` (codebook@0x70, SSND size@0xF4, frames@0x100, FORM size@0x4).
- **Codec correctness was anchored empirically:** the decoder was validated against the shipped
  reference sounds (they decode to smooth, ~0%-saturated speech). This revealed the predictor row
  order — the SECOND stored codebook row is the response to the most-recent sample `l1`, the FIRST
  to `l2` (`pred1 = book[p][1]`, `pred2 = book[p][0]`); the other order saturates/roughens.
- The codebook is **reused from `Twelve_Character_Battle.aifc`** (same announcer-speech domain); no
  custom `tabledesign` was needed — round-trip SNR is **43.8 dB** with the borrowed book.
- Final asset: `src/sounds/tournament.aifc`, 32 kHz, 36848 samples / 2303 frames, registered with
  `SAMPLE_RATE_32000`. Build prints `FGM_ID: 0x609 (1545)` for `sounds/tournament`, which is what
  `FGM.announcer.css.TOURNAMENT` resolves to.
- Code changes applied as described above (FGM.asm `add_sound` + `TOURNAMENT` constant;
  TwelveCharBattle.asm `update_announcer_on_entry_` Tournament branch).
- Verified: full build (`bass` → `chksum64` → `rn64crc`) succeeds and ROM is bootable; both CI lints
  pass; `-d DEBUG` build + `overlapping_patches.py` shows only the 3 known pre-existing conflicts;
  and HW-confirmed by the user (Tournament → new sound; 12CB → still `TWELVECB`; all other modes
  unchanged).

### Fix: playback was cutting off at ~half
First HW test played only ~half the phrase. Cause: `add_sound` auto length (`fgm_length = -1`) is
`SOUND_SIZE/177` read from the FORM-size word at `0x4`, but the reference `.aifc` files store an
**inflated** FORM size there (≈ uncompressed PCM bytes, ~3.5× the real file size) and the `177`
divisor is calibrated for 16 kHz. Our encoder writes the *truthful* FORM size and the sound is 32 kHz,
so auto length came out 118 ticks ≈ 0.645 s of the 1.15 s clip (~56%). **Fix:** pass an explicit
`fgm_length` (`224`, ≈1.15 s @ ~183 ticks/s with margin) in the tournament `add_sound` instead of
`-1`. No re-encode needed; the audio file already holds the full clip. (Future note: any sound made by
`scripts/vadpcm_encode.py` should use an explicit length, since its FORM size won't match the auto
formula's expectation.)

### Louder mix (+5 dB)
The clip was raised ~+5 dB RMS (−14 → −9 dBFS) at the user's request. The per-sound FGM volume is
already maxed in the microcode (`0xD5FF`), so loudness must come from the sample data. Used a tanh
**soft limiter** (`louder` subcommand in `scripts/vadpcm_encode.py`, `drive=2.6`) which boosts the body
of the clip while compressing the few peaks smoothly to full scale (no hard clipping); round-trip SNR
stayed ~42.8 dB. To re-tune, re-run from the pristine pre-boost copy, e.g.
`python scripts/vadpcm_encode.py louder <original.aifc> src/sounds/Twelve_Character_Battle.aifc src/sounds/tournament.aifc <drive>`
(higher drive = louder + more compression; ~2.6 ≈ +5 dB).

### Re-encoding the sound later
To swap in different audio: drop a mono 16-bit PCM `.wav` and run
`python scripts/vadpcm_encode.py encode <in.wav> src/sounds/Twelve_Character_Battle.aifc src/sounds/tournament.aifc 32000`
(the 2nd arg supplies the codebook). The script prints round-trip SNR and verifies the header
offsets. Then rebuild with the full `bass`→`chksum64`→`rn64crc` sequence.
