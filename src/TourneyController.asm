// TourneyController.asm
if !{defined __TOURNEYCONTROLLER__} {
define __TOURNEYCONTROLLER__()
print "included TourneyController.asm\n"

include "OS.asm"
include "Global.asm"
include "TourneyMode.asm"

// @ Description
// Phase 2 of Tournament Mode: the MATCH-LOOP controller. It detects when a
// tournament match ends, determines the winner, and advances the bracket engine
// (TourneyMode). It does NOT yet set up / launch the next match's fighters or draw
// the bracket - those are Phase 3 (CSS integration) and Phase 4 (UI).
//
// SAFETY (why this can't affect normal VS / 12CB / other modes):
//   - Everything is gated behind `tourney_active` (default 0). With it 0, the
//     match-end hook calls record_match_result_, which returns immediately, so
//     behavior is byte-identical to vanilla. `tourney_active` is only set while a
//     tournament is actually running (Phase 3 will set/clear it), and a tournament
//     can't run at the same time as 12CB.
//   - The hook reproduces the two overwritten vanilla instructions, so the inactive
//     path is unchanged.
//   - The hook address (GAMESET, 0x80114C80) is not patched by any other feature
//     (verified); other modes only jal/j to it.
//
// WINNER DETECTION (verified by disassembling original.z64):
//   The vanilla stock-score routine at 0x80137334 reads each player's LIVE remaining
//   stock count as a byte from the VS player-config structs:
//     p1 = 0x800A4D35, p2 = 0x800A4DA9, p3 = 0x800A4E1D, p4 = 0x800A4E91
//   i.e. remaining stocks = byte at (Global.vs.p1 + port*0x74 + 0x0D).
//   For a 1v1 bracket match the winner is simply the participating port still alive
//   (most stocks remaining).
scope TourneyController {

    // Live remaining-stock count of port 0, and the per-port stride (see header).
    constant STOCKS_P1(0x800A4D35)
    constant STOCK_STRIDE(0x0074)

    // @ Description
    // Non-zero while a tournament is running. Default 0 = fully inert.
    tourney_active:
    dw 0

    // @ Description
    // Set when a tournament match is underway and its result has not yet been
    // recorded. Prevents the bracket from being advanced more than once for the same
    // match if the GAMESET routine runs more than once.
    result_pending:
    dw 0

    // @ Description
    // Set once the bracket has been seeded for the current tournament, so re-entering
    // the CSS between matches doesn't reseed. Cleared on fresh entry from the VS menu.
    bracket_seeded:
    dw 0

    // @ Description
    // Arms the controller for a match in progress. Phase 3 (match launch) calls this
    // when it starts a tournament match.
    scope begin_match_: {
        li      t0, result_pending
        lli     t1, 0x0001
        jr      ra
        sw      t1, 0x0000(t0)             // result_pending = 1 (delay slot)
    }

    // @ Description
    // Reads the live remaining stock count for a port.
    // @ Arguments
    // a0 - port (0-3)
    // @ Returns
    // v0 - remaining stocks
    scope get_port_stocks_: {
        li      t0, STOCKS_P1
        lli     t1, STOCK_STRIDE
        multu   a0, t1                      // ~
        mflo    t1                          // t1 = port * 0x74
        addu    t0, t0, t1                  // t0 = &stocks[port]
        jr      ra
        lbu     v0, 0x0000(t0)             // v0 = remaining stocks (delay slot)
    }

    // @ Description
    // Maps an entrant index to its controller port.
    // @ Arguments
    // a0 - entrant index (EMPTY_SLOT allowed)
    // @ Returns
    // v0 - port (0 for an empty entrant; caller won't use it)
    scope entrant_port_: {
        lli     v0, 0x0000                 // default port 0
        lli     t0, TourneyMode.EMPTY_SLOT
        beq     a0, t0, _ret               // empty entrant -> port 0
        nop
        sll     t1, a0, 0x0002             // entrant index * 4
        li      t2, TourneyMode.entrant_data
        addu    t2, t2, t1                 // &entrant_data[idx]
        lbu     v0, 0x0003(t2)             // port field

        _ret:
        jr      ra
        nop
    }

    // @ Description
    // Determines the winner of the current tournament match and advances the bracket.
    // Winner = the match's participating port with the most remaining stocks (the
    // survivor in a 1v1). On a tie (e.g. a double-KO) side A is taken; this is rare
    // and can be refined later (sudden death / replay). No-op unless a tournament is
    // active and a result is pending.
    scope record_match_result_: {
        addiu   sp, sp, -0x0020            // allocate stack space
        sw      ra, 0x0004(sp)             // ~
        sw      s0, 0x0008(sp)             // ~
        sw      s1, 0x000C(sp)             // ~
        sw      s2, 0x0010(sp)             // ~
        sw      s3, 0x0014(sp)             // save registers

        // gate: active and pending
        li      t0, tourney_active
        lw      t0, 0x0000(t0)
        beqz    t0, _ret                   // inactive -> do nothing
        nop
        li      t0, result_pending
        lw      t0, 0x0000(t0)
        beqz    t0, _ret                   // already recorded / not armed -> nothing
        nop

        // must have a current match
        jal     TourneyMode.get_current_match_ // v0 = 1 if a match is ready
        nop
        beqz    v0, _ret                   // tournament over -> nothing
        nop

        // entrant indices for the two sides
        li      t0, TourneyMode.current_match_a
        lw      s0, 0x0000(t0)             // s0 = entrant A
        li      t0, TourneyMode.current_match_b
        lw      s1, 0x0000(t0)             // s1 = entrant B

        // A's stocks
        or      a0, r0, s0                 // a0 = entrant A
        jal     entrant_port_              // v0 = A's port
        nop
        or      a0, r0, v0                 // a0 = A's port
        jal     get_port_stocks_           // v0 = A's stocks
        nop
        or      s2, r0, v0                 // s2 = A's stocks

        // B's stocks
        or      a0, r0, s1                 // a0 = entrant B
        jal     entrant_port_              // v0 = B's port
        nop
        or      a0, r0, v0                 // a0 = B's port
        jal     get_port_stocks_           // v0 = B's stocks
        nop
        or      s3, r0, v0                 // s3 = B's stocks

        // winning side: 1 (B) if B has strictly more stocks, else 0 (A; A-wins or tie)
        sltu    a0, s2, s3                 // a0 = 1 if A_stocks < B_stocks
        jal     TourneyMode.report_winner_ // advance bracket
        nop

        li      t0, result_pending
        sw      r0, 0x0000(t0)             // result recorded -> clear pending

        _ret:
        lw      ra, 0x0004(sp)             // ~
        lw      s0, 0x0008(sp)             // ~
        lw      s1, 0x000C(sp)             // ~
        lw      s2, 0x0010(sp)             // ~
        lw      s3, 0x0014(sp)             // restore registers
        jr      ra
        addiu   sp, sp, 0x0020             // deallocate stack space
    }

    // @ Description
    // One-shot hook at the GAMESET routine (runs when a match ends). Records the
    // tournament result (inert by default), then reproduces the two overwritten
    // vanilla instructions and returns into GAMESET's prologue at 0x80114C88.
    scope on_match_end_: {
        OS.patch_start(0x90480, 0x80114C80)
        j       on_match_end_
        nop
        _return:
        OS.patch_end()

        OS.save_registers()
        jal     record_match_result_
        nop
        OS.restore_registers()

        lui     v0, 0x800a                 // original line 1 (0x80114C80)
        j       _return                     // back into GAMESET prologue (0x80114C88)
        lw      v0, 0x50e8(v0)             // original line 2 (0x80114C84, delay slot)
    }

    // @ Description
    // VS-mode dispatch hooks, called from VsRemixMenu when vs_mode_flag == mode.TOURNEY
    // (mirrors the KingOfTheHill before/leave/start pattern). For now these activate
    // the tournament and force a STOCK match; bracket seeding and the per-match launch
    // loop are added in the next step. NOTE: not reachable until a Tournament menu
    // button sets vs_mode_flag = mode.TOURNEY (the Remix Modes menu page is currently
    // full, so menu integration is a separate task).

    // @ Description
    // Entering the CSS for Tournament mode: force a stock match and mark active.
    scope before_css_setup_: {
        li      at, Global.vs.game_mode    // at = game_mode (0x800A4D0B)
        lli     t0, 0x0002                 // 2 = stock
        sb      t0, 0x0000(at)             // game mode = stock
        li      at, 0x8013BDAC             // at = CSS game_mode mirror
        sw      t0, 0x0000(at)             // game mode = stock
        li      t0, tourney_active
        lli     t1, 0x0001
        sw      t1, 0x0000(t0)             // tourney_active = 1

        // Reseed only on a fresh entry from the VS menu, not on between-match CSS
        // re-entries (those keep the existing, already-advanced bracket).
        OS.read_byte(Global.previous_screen, t0)   // t0 = previous screen id
        lli     t1, Global.screen.VS_GAME_MODE_MENU
        bne     t0, t1, _ret               // not from the menu -> keep the bracket
        nop
        li      t0, bracket_seeded
        sw      r0, 0x0000(t0)             // fresh tournament -> force reseed at start

        _ret:
        jr      ra
        nop
    }

    // @ Description
    // Returning from the CSS to the menu (tournament cancelled): mark inactive.
    // VsRemixMenu's dispatcher restores game_mode after this returns.
    scope leave_css_setup_: {
        li      t0, tourney_active
        jr      ra
        sw      r0, 0x0000(t0)             // tourney_active = 0 (delay slot)
    }

    // ------------------------------------------------------------------
    // Phase 3 match-loop, part 1: seed the bracket from the CSS picks and
    // program the current match's fighters into the VS player structs.
    // (Part 2 -- the relaunch loop between matches -- is not implemented yet,
    // so only the FIRST match is set up; later matches won't auto-start.)
    // ------------------------------------------------------------------

    // VS player config structs (see Spawn.asm): per-port stride 0x74.
    //   +0x02 type (0=man, 1=cpu, 2=n/a)   +0x03 character   +0x04 team
    constant VS_P1(0x800A4D28)
    constant VS_STRIDE(0x0074)
    constant TYPE_MAN(0x0000)
    constant TYPE_CPU(0x0001)
    constant TYPE_NA(0x0002)
    // Target bracket size. PLACEHOLDER until a size-select UI exists.
    constant TOURNEY_TARGET_ENTRANTS(8)
    // Random CPU characters drawn from the 12 always-valid vanilla ids (0..0xB).
    constant NUM_RANDOM_CHARS(12)

    // @ Description
    // a0 = port (0-3) -> v0 = &vs.p[port]
    scope port_to_vs_: {
        li      v0, VS_P1
        lli     t0, VS_STRIDE
        multu   a0, t0                      // ~
        mflo    t0                          // t0 = port * 0x74
        jr      ra
        addu    v0, v0, t0                 // v0 = &vs.p[port] (delay slot)
    }

    // @ Description
    // Seeds the bracket from the CSS panels: every active panel (type != n/a) becomes
    // an entrant (human if type==man), then random-character CPU entrants fill the
    // bracket up to TOURNEY_TARGET_ENTRANTS, then the bracket is seeded.
    scope seed_from_css_: {
        addiu   sp, sp, -0x0018            // allocate stack space
        sw      ra, 0x0004(sp)             // ~
        sw      s0, 0x0008(sp)             // save registers

        jal     TourneyMode.reset_         // fresh bracket
        nop

        lli     s0, 0x0000                 // s0 = port index
        _add_loop:
        jal     port_to_vs_                // v0 = &vs.p[s0]
        or      a0, r0, s0                 // a0 = port (delay slot)
        lbu     t0, 0x0002(v0)             // t0 = type
        lli     t1, TYPE_NA
        beq     t0, t1, _next_port         // skip inactive panels
        nop
        lbu     a0, 0x0003(v0)             // a0 = character
        lli     a1, 0x0000                 // a1 = costume
        sltiu   a2, t0, 0x0001             // a2 = 1 if man (human), else 0
        jal     TourneyMode.add_entrant_
        or      a3, r0, s0                 // a3 = port (delay slot)
        _next_port:
        addiu   s0, s0, 0x0001             // next port
        sltiu   t0, s0, 0x0004             // while port < 4
        bnez    t0, _add_loop
        nop

        _fill_loop:
        li      t0, TourneyMode.entrant_count
        lw      t1, 0x0000(t0)             // t1 = entrant count
        sltiu   t2, t1, TOURNEY_TARGET_ENTRANTS
        beqz    t2, _seed                  // reached target -> seed
        nop
        jal     Global.get_random_int_safe_ // v0 = random in [0, N)
        lli     a0, NUM_RANDOM_CHARS       // a0 = N (delay slot)
        or      a0, r0, v0                 // a0 = random character
        lli     a1, 0x0000                 // a1 = costume
        lli     a2, 0x0000                 // a2 = CPU
        jal     TourneyMode.add_entrant_
        lli     a3, 0x00FF                 // a3 = no fixed port (delay slot)
        b       _fill_loop
        nop

        _seed:
        jal     TourneyMode.seed_bracket_
        nop
        lw      ra, 0x0004(sp)             // ~
        lw      s0, 0x0008(sp)             // restore registers
        jr      ra
        addiu   sp, sp, 0x0018             // deallocate stack space
    }

    // @ Description
    // Programs the current bracket match into the VS player structs: all ports set to
    // n/a, then humans placed at their own controller ports, then CPUs at free ports
    // (two passes so a CPU never steals a human's port).
    scope setup_current_match_: {
        addiu   sp, sp, -0x0018            // allocate stack space
        sw      ra, 0x0004(sp)             // ~
        sw      s0, 0x0008(sp)             // ~
        sw      s1, 0x000C(sp)             // save registers

        jal     TourneyMode.get_current_match_ // v0 = 1 if a match is ready
        nop
        beqz    v0, _ret                   // tournament over -> nothing
        nop

        // all ports -> n/a
        lli     s0, 0x0000
        _na_loop:
        jal     port_to_vs_
        or      a0, r0, s0                 // a0 = port (delay slot)
        lli     t0, TYPE_NA
        sb      t0, 0x0002(v0)             // type = n/a
        addiu   s0, s0, 0x0001
        sltiu   t0, s0, 0x0004
        bnez    t0, _na_loop
        nop

        // entrant indices for the two sides
        li      t0, TourneyMode.current_match_a
        lw      s0, 0x0000(t0)             // s0 = entrant A
        li      t0, TourneyMode.current_match_b
        lw      s1, 0x0000(t0)             // s1 = entrant B

        // pass 1: humans at their own ports
        jal     place_if_human_
        or      a0, r0, s0                 // (delay slot) a0 = A
        jal     place_if_human_
        or      a0, r0, s1                 // (delay slot) a0 = B
        // pass 2: CPUs at free ports
        jal     place_if_cpu_
        or      a0, r0, s0                 // (delay slot) a0 = A
        jal     place_if_cpu_
        or      a0, r0, s1                 // (delay slot) a0 = B

        _ret:
        lw      ra, 0x0004(sp)             // ~
        lw      s0, 0x0008(sp)             // ~
        lw      s1, 0x000C(sp)             // restore registers
        jr      ra
        addiu   sp, sp, 0x0018             // deallocate stack space
    }

    // @ Description
    // a0 = entrant index; if it is a human entrant, write it into vs.p[its own port].
    scope place_if_human_: {
        sll     t0, a0, 0x0002
        li      t1, TourneyMode.entrant_data
        addu    t1, t1, t0                 // &entrant_data[a0]
        lbu     t2, 0x0002(t1)             // flags
        andi    t3, t2, 0x0002             // human bit
        beqz    t3, _ret                   // not human -> skip
        nop
        lbu     t4, 0x0000(t1)             // character
        lbu     t5, 0x0003(t1)             // port
        li      t6, VS_P1
        lli     t7, VS_STRIDE
        multu   t5, t7                      // ~
        mflo    t7                          // t7 = port * 0x74
        addu    t6, t6, t7                 // &vs.p[port]
        lli     t8, TYPE_MAN
        sb      t8, 0x0002(t6)             // type = man
        sb      t4, 0x0003(t6)             // character
        sb      t5, 0x0004(t6)             // team = port (distinct color)
        _ret:
        jr      ra
        nop
    }

    // @ Description
    // a0 = entrant index; if it is a CPU entrant, write it into the first free port.
    scope place_if_cpu_: {
        sll     t0, a0, 0x0002
        li      t1, TourneyMode.entrant_data
        addu    t1, t1, t0                 // &entrant_data[a0]
        lbu     t2, 0x0002(t1)             // flags
        andi    t3, t2, 0x0002             // human bit
        bnez    t3, _ret                   // human -> already placed
        nop
        lbu     t4, 0x0000(t1)             // character

        lli     t5, 0x0000                 // candidate port
        _scan:
        li      t6, VS_P1
        lli     t7, VS_STRIDE
        multu   t5, t7                      // ~
        mflo    t7                          // t7 = port * 0x74
        addu    t6, t6, t7                 // &vs.p[t5]
        lbu     t7, 0x0002(t6)             // type
        lli     t8, TYPE_NA
        beq     t7, t8, _found             // free port found
        nop
        addiu   t5, t5, 0x0001
        slti    t7, t5, 0x0004
        bnez    t7, _scan
        nop
        lli     t5, 0x0000                 // fallback: port 0
        li      t6, VS_P1

        _found:
        lli     t8, TYPE_CPU
        sb      t8, 0x0002(t6)             // type = cpu
        sb      t4, 0x0003(t6)             // character
        sb      t5, 0x0004(t6)             // team = port
        sb      t5, 0x0003(t1)             // record assigned port in entrant_data (for winner lookup)
        _ret:
        jr      ra
        nop
    }

    // @ Description
    // Starting a match (dispatched from VsRemixMenu): just force a stock match. The
    // bracket seeding + per-match fighter programming happens in post_commit_setup_,
    // which runs AFTER mnBattleSaveMatchInfo commits the CSS picks into vs.pN (this
    // routine runs BEFORE that commit, so any vs.pN writes here would be clobbered).
    scope start_match_setup_: {
        li      at, 0x8013BDAC             // CSS game_mode mirror
        lli     t0, 0x0002                 // 2 = stock
        jr      ra
        sw      t0, 0x0000(at)             // game mode = stock (delay slot)
    }

    // @ Description
    // Runs from VsRemixMenu.mode_specific_setup_start_ AFTER mnBattleSaveMatchInfo has
    // committed the CSS panels into vs.pN. Seeds the bracket once (reading the committed
    // picks), then overrides vs.pN with the current bracket match's 1v1 pairing and arms
    // result recording. Because this is post-commit, the override is the last write and
    // sticks.
    scope post_commit_setup_: {
        addiu   sp, sp, -0x0010            // allocate stack space
        sw      ra, 0x0004(sp)             // save ra

        // seed the bracket only once per tournament
        li      t0, bracket_seeded
        lw      t1, 0x0000(t0)
        bnez    t1, _skip_seed             // already seeded -> keep advancing bracket
        nop
        jal     seed_from_css_             // build bracket from committed CSS picks + CPU fill
        nop
        li      t0, bracket_seeded
        lli     t1, 0x0001
        sw      t1, 0x0000(t0)             // mark seeded

        _skip_seed:
        jal     setup_current_match_       // override vs.pN with the current bracket match
        nop
        jal     begin_match_               // arm result recording
        nop
        lw      ra, 0x0004(sp)             // restore ra
        jr      ra
        addiu   sp, sp, 0x0010             // deallocate stack space
    }
}

} // __TOURNEYCONTROLLER__
