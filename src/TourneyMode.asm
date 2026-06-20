// TourneyMode.asm
if !{defined __TOURNEYMODE__} {
define __TOURNEYMODE__()
print "included TourneyMode.asm\n"

include "OS.asm"
include "Global.asm"

// @ Description
// Tournament mode for VS - a Brawl/Ultimate style single-elimination bracket.
//
// SCOPE / STATUS:
//   This file currently implements ONLY the bracket ENGINE (Phase 1 of the
//   planned feature): the data structures and the logic for seeding a bracket,
//   advancing winners, auto-resolving byes, and detecting the champion. It is
//   self-contained and has NO dependencies on the menu, character select, match
//   results, or rendering yet. Those are later phases:
//     Phase 2 - match-loop integration (read winner from results, launch next match)
//     Phase 3 - human + CPU-fill port assignment per match
//     Phase 4 - scrollable visual bracket UI
//   Nothing calls into this engine yet; it is included so it assembles with the
//   rest of the build and so the logic can be reviewed/iterated independently.
//
// DESIGN - binary-heap bracket:
//   The bracket is stored as a 1-indexed binary tree in `tree` (a byte array).
//   For a bracket of `bracket_size` (a power of two, 2..32):
//     - Leaves occupy indices [bracket_size, 2*bracket_size) and hold the seeded
//       entrants (one entrant index per leaf, or EMPTY_SLOT for a bye).
//     - Internal nodes occupy [1, bracket_size) and hold the WINNER of the match
//       between their two children (node i's children are 2i and 2i+1).
//     - Node 1 is the final/champion slot.
//   A match at internal node i is "entrant at tree[2i]" vs "entrant at tree[2i+1]".
//   Processing matches in DESCENDING node order (bracket_size-1 .. 1) naturally
//   plays round 1 first (highest indices), then round 2, etc., and guarantees a
//   node's children are already resolved before the node itself is reached.
//
//   Byes: any internal node where exactly one child is EMPTY_SLOT auto-advances
//   the occupied child with no match played. The advance routine skips past these.
//
//   Entrant data (character/costume/human/port) lives in `entrant_data`, indexed
//   by entrant index. The tree only stores entrant indices, never raw characters,
//   so the same entrant can be tracked as it advances.
scope TourneyMode {

    // Maximum entrants supported (Brawl/Ultimate scale).
    constant MAX_ENTRANTS(32)
    // Sentinel for an empty bracket slot / bye / no champion yet.
    constant EMPTY_SLOT(0xFF)
    // tree node count: index 0 unused, 1..(2*MAX_ENTRANTS - 1) used. Round up to 64.
    constant TREE_BYTES(MAX_ENTRANTS * 2)

    // @ Description
    // Number of entrants registered for the current tournament.
    entrant_count:
    dw 0

    // @ Description
    // Power-of-two bracket size (>= entrant_count). Set by seed_bracket_.
    bracket_size:
    dw 0

    // @ Description
    // Internal node index of the match currently awaiting a result. 0 once the
    // tournament is over (champion decided).
    current_node:
    dw 0

    // @ Description
    // Entrant index of the champion once the tournament is over (else EMPTY_SLOT).
    champion:
    dw EMPTY_SLOT

    // @ Description
    // Cached entrant indices of the two sides of the current match, filled by
    // get_current_match_ for convenience of callers/UI.
    current_match_a:
    dw 0
    current_match_b:
    dw 0

    // @ Description
    // The bracket tree (see DESIGN above). One byte per node = entrant index or
    // EMPTY_SLOT. Initialized to EMPTY_SLOT at seed time.
    tree:
    fill TREE_BYTES

    // @ Description
    // Per-entrant data, MAX_ENTRANTS entries of 4 bytes each:
    //   0x00 (byte) - character id
    //   0x01 (byte) - costume id
    //   0x02 (byte) - flags: bit0 = occupied, bit1 = human
    //   0x03 (byte) - controller port (valid when human), else don't-care
    entrant_data:
    fill (MAX_ENTRANTS * 4)
    OS.align(4)

    // @ Description
    // Clears all tournament state. Call before registering entrants for a new run.
    scope reset_: {
        li      t0, entrant_count
        sw      r0, 0x0000(t0)              // entrant_count = 0
        li      t0, bracket_size
        sw      r0, 0x0000(t0)              // bracket_size = 0
        li      t0, current_node
        sw      r0, 0x0000(t0)              // current_node = 0
        li      t0, champion
        lli     t1, EMPTY_SLOT
        sw      t1, 0x0000(t0)              // champion = EMPTY_SLOT

        // clear entrant_data (flags in particular)
        li      t0, entrant_data
        lli     t1, MAX_ENTRANTS            // t1 = entries to clear
        _clear_loop:
        sw      r0, 0x0000(t0)              // clear one entry (4 bytes)
        addiu   t1, t1, -0x0001             // t1--
        bnez    t1, _clear_loop             // loop until all cleared
        addiu   t0, t0, 0x0004              // advance to next entry (delay slot)

        jr      ra
        nop
    }

    // @ Description
    // Registers one entrant. No-op if the bracket is already full.
    // @ Arguments
    // a0 - character id
    // a1 - costume id
    // a2 - is_human (0 = CPU, non-zero = human)
    // a3 - controller port (used when human)
    scope add_entrant_: {
        li      t0, entrant_count
        lw      t1, 0x0000(t0)              // t1 = current count
        sltiu   t2, t1, MAX_ENTRANTS        // t2 = 1 if there is room
        beqz    t2, _full                   // if full, do nothing
        sll     t2, t1, 0x0002             // t2 = count * 4 (entry offset, delay slot)

        li      t3, entrant_data
        addu    t3, t3, t2                  // t3 = address of new entry
        sb      a0, 0x0000(t3)             // char id
        sb      a1, 0x0001(t3)             // costume id
        lli     t4, 0x0001                 // t4 = occupied bit
        sll     t5, a2, 0x0001             // t5 = is_human << 1
        or      t4, t4, t5                 // t4 = flags (occupied | human<<1)
        sb      t4, 0x0002(t3)             // flags
        sb      a3, 0x0003(t3)             // port
        addiu   t1, t1, 0x0001             // count++
        sw      t1, 0x0000(t0)             // store updated count

        _full:
        jr      ra
        nop
    }

    // @ Description
    // Seeds the bracket from the registered entrants: chooses the power-of-two
    // bracket size, randomly distributes entrants across the leaves (remaining
    // leaves become byes), then advances to the first real match.
    // Assumes entrant_count >= 2.
    scope seed_bracket_: {
        addiu   sp, sp, -0x0020            // allocate stack space
        sw      ra, 0x0004(sp)             // ~
        sw      s0, 0x0008(sp)             // ~
        sw      s1, 0x000C(sp)             // ~
        sw      s2, 0x0010(sp)             // save registers

        li      t0, entrant_count
        lw      s0, 0x0000(t0)             // s0 = entrant_count

        // bracket_size = smallest power of two >= entrant_count (min 2)
        lli     s1, 0x0002                 // s1 = size = 2
        _size_loop:
        sltu    t1, s1, s0                 // t1 = 1 if size < count
        beqz    t1, _size_done             // stop once size >= count
        nop
        sll     s1, s1, 0x0001             // size *= 2
        b       _size_loop
        nop

        _size_done:
        li      t0, bracket_size
        sw      s1, 0x0000(t0)             // save bracket_size

        // initialize the whole tree to EMPTY_SLOT
        li      t0, tree
        lli     t1, TREE_BYTES             // t1 = bytes to clear
        lli     t2, EMPTY_SLOT
        _tree_clear:
        sb      t2, 0x0000(t0)             // tree[k] = EMPTY_SLOT
        addiu   t1, t1, -0x0001            // t1--
        bnez    t1, _tree_clear            // loop
        addiu   t0, t0, 0x0001             // next byte (delay slot)

        // place entrants 0..count-1 into the first `count` leaves
        li      t0, tree
        addu    t0, t0, s1                 // t0 = &leaf[0] (= &tree[bracket_size])
        lli     t1, 0x0000                 // t1 = i = 0
        _leaf_fill:
        sltu    t2, t1, s0                 // while i < count
        beqz    t2, _shuffle
        nop
        addu    t3, t0, t1                 // &leaf[i]
        sb      t1, 0x0000(t3)             // leaf[i] = entrant index i
        addiu   t1, t1, 0x0001             // i++
        b       _leaf_fill
        nop

        // Fisher-Yates shuffle of leaves[0 .. bracket_size-1]
        //   for i = bracket_size-1 down to 1: j = rand(i+1); swap leaf[i], leaf[j]
        _shuffle:
        addiu   s2, s1, -0x0001            // s2 = i = bracket_size - 1
        _shuffle_loop:
        blez    s2, _seed_done             // stop when i <= 0
        nop
        jal     Global.get_random_int_safe_ // v0 = rand in [0, i]
        addiu   a0, s2, 0x0001             // a0 = i + 1 (range N, delay slot)

        li      t0, tree
        addu    t0, t0, s1                 // t0 = leaf base
        addu    t1, t0, s2                 // &leaf[i]
        addu    t2, t0, v0                 // &leaf[j]
        lbu     t3, 0x0000(t1)             // leaf[i]
        lbu     t4, 0x0000(t2)             // leaf[j]
        sb      t4, 0x0000(t1)             // leaf[i] = leaf[j]
        sb      t3, 0x0000(t2)             // leaf[j] = leaf[i]
        addiu   s2, s2, -0x0001            // i--
        b       _shuffle_loop
        nop

        _seed_done:
        // current_node = highest internal node; advance resolves byes to match 1
        li      t0, current_node
        addiu   t1, s1, -0x0001            // bracket_size - 1
        sw      t1, 0x0000(t0)             // current_node = bracket_size - 1
        jal     advance_to_next_match_     // resolve byes, land on first real match
        nop

        lw      ra, 0x0004(sp)             // ~
        lw      s0, 0x0008(sp)             // ~
        lw      s1, 0x000C(sp)             // ~
        lw      s2, 0x0010(sp)             // restore registers
        jr      ra
        addiu   sp, sp, 0x0020             // deallocate stack space
    }

    // @ Description
    // Scans downward from current_node, auto-resolving byes, until it lands on a
    // real match (both children occupied) or runs out of nodes (champion decided).
    // Leaf routine (no jal): may clobber t0-t9.
    scope advance_to_next_match_: {
        li      t9, current_node
        lw      t0, 0x0000(t9)             // t0 = i (current internal node)

        _scan:
        blez    t0, _over                  // if i <= 0, tournament is over
        nop
        li      t3, tree
        sll     t1, t0, 0x0001             // t1 = 2i (left child index)
        addu    t4, t3, t1                 // t4 = &tree[2i]
        lbu     t6, 0x0000(t4)             // t6 = child a (tree[2i])
        lbu     t7, 0x0001(t4)             // t7 = child b (tree[2i+1])
        lli     t8, EMPTY_SLOT

        bne     t6, t8, _a_filled          // is child a occupied?
        nop
        // child a empty
        bne     t7, t8, _take_b            // a empty, b filled -> bye to b
        nop
        // both empty -> this node is empty too; keep scanning down
        b       _set_and_next
        or      t5, t8, r0                 // winner = EMPTY_SLOT (delay slot)

        _a_filled:
        bne     t7, t8, _real_match        // both filled -> real match
        nop
        // b empty, a filled -> bye to a
        b       _set_and_next
        or      t5, t6, r0                 // winner = a (delay slot)

        _take_b:
        or      t5, t7, r0                 // winner = b

        _set_and_next:
        addu    t2, t3, t0                 // &tree[i]
        sb      t5, 0x0000(t2)             // tree[i] = winner (or EMPTY_SLOT)
        addiu   t0, t0, -0x0001            // i--
        b       _scan                      // keep scanning down
        nop

        _real_match:
        jr      ra
        sw      t0, 0x0000(t9)             // current_node = i (match to play, delay slot)

        _over:
        sw      r0, 0x0000(t9)             // current_node = 0
        li      t1, champion
        li      t3, tree
        lbu     t2, 0x0001(t3)             // tree[1] = champion entrant index
        jr      ra
        sw      t2, 0x0000(t1)             // save champion (delay slot)
    }

    // @ Description
    // Reads the current match into current_match_a / current_match_b.
    // @ Returns
    // v0 - 1 if a match is ready, 0 if the tournament is over (see champion)
    scope get_current_match_: {
        li      t9, current_node
        lw      t0, 0x0000(t9)             // t0 = i
        blez    t0, _over                  // if no current match, tournament over
        nop
        li      t3, tree
        sll     t1, t0, 0x0001             // 2i
        addu    t4, t3, t1                 // &tree[2i]
        lbu     t5, 0x0000(t4)             // entrant a
        lbu     t6, 0x0001(t4)             // entrant b
        li      t7, current_match_a
        sw      t5, 0x0000(t7)             // cache side a
        li      t7, current_match_b
        sw      t6, 0x0000(t7)             // cache side b
        jr      ra
        lli     v0, 0x0001                 // status = ready (delay slot)

        _over:
        jr      ra
        lli     v0, 0x0000                 // status = over (delay slot)
    }

    // @ Description
    // Records the winner of the current match and advances the bracket.
    // @ Arguments
    // a0 - winning side: 0 = side A (tree[2i]), 1 = side B (tree[2i+1])
    scope report_winner_: {
        addiu   sp, sp, -0x0010            // allocate stack space
        sw      ra, 0x0004(sp)             // save ra

        li      t9, current_node
        lw      t0, 0x0000(t9)             // t0 = i
        blez    t0, _ret                   // safety: no match in progress
        nop
        li      t3, tree
        sll     t1, t0, 0x0001             // 2i
        addu    t1, t1, a0                 // 2i + which (winning child index)
        addu    t4, t3, t1                 // &winning child
        lbu     t5, 0x0000(t4)             // winner entrant index
        addu    t6, t3, t0                 // &tree[i]
        sb      t5, 0x0000(t6)             // tree[i] = winner
        addiu   t0, t0, -0x0001            // move to next lower node
        sw      t0, 0x0000(t9)             // current_node = i - 1
        jal     advance_to_next_match_     // resolve byes, land on next real match
        nop

        _ret:
        lw      ra, 0x0004(sp)             // restore ra
        jr      ra
        addiu   sp, sp, 0x0010             // deallocate stack space
    }

    // @ Description
    // Looks up the character id for an entrant index.
    // @ Arguments
    // a0 - entrant index (EMPTY_SLOT allowed)
    // @ Returns
    // v0 - character id, or EMPTY_SLOT if the entrant slot is empty
    scope get_entrant_char_: {
        lli     v0, EMPTY_SLOT             // default = EMPTY_SLOT
        lli     t0, EMPTY_SLOT
        beq     a0, t0, _ret               // empty entrant -> return EMPTY_SLOT
        nop
        sll     t1, a0, 0x0002             // entrant index * 4
        li      t2, entrant_data
        addu    t2, t2, t1                 // &entrant_data[idx]
        lbu     v0, 0x0000(t2)             // v0 = character id

        _ret:
        jr      ra
        nop
    }
}

} // __TOURNEYMODE__
