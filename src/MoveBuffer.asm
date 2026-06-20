// MoveBuffer.asm
if !{defined __MOVEBUFFER__} {
define __MOVEBUFFER__()
print "included MoveBuffer.asm\n"

include "OS.asm"
include "Global.asm"
include "Toggles.asm"
include "Joypad.asm"

// @ Description
// Adds an adjustable input/move buffer, similar to Smash Ultimate's hit-buffer.
// The buffer window is controlled by the "Move Buffer" gameplay toggle
// (Toggles.entry_move_buffer): 0 = disabled, 1-9 = number of frames an
// action-initiating button press is remembered after it could not be acted on.
//
// Strategy (input persistence):
//   When an action-relevant button is pressed while the character is in a state
//   that can't act on it yet (jumpsquat, landing lag, shield, hitstun, etc.),
//   the press is remembered and re-asserted on each later frame for up to N
//   frames. The vanilla per-action interrupt logic then triggers the move on
//   the first frame the character becomes interruptible.
//
// Where we inject (important):
//   The player struct's "buttons pressed" field (+0x01BE) is recomputed every
//   frame inside ftMainProcUpdate by edge-detection on the *held* buttons:
//       pressed = (current_held ^ previous_held) & current_held
//   (see vanilla code at 0x800E12E8-0x800E1348). So injecting into the global
//   controller struct's pressed field does nothing - it gets recomputed. We
//   instead hook 0x800E134C, which is immediately AFTER 0x01BE is finalized and
//   BEFORE the action/transition logic reads it, and OR our buffered press into
//   0x01BE directly. This hook sits on the control-type-0 (human) path only, so
//   it never runs for CPUs.
//
// Consumption / actionability:
//   We keep buffering only while the player is in a non-attack action
//   (action id < Action.Grab / 0xA6: idle, walk, run, jump, fall, landing,
//   shield, rolls, hitstun, etc.). Once an attack/grab/special action begins
//   (action id >= 0xA6) the buffered input is considered consumed and cleared,
//   which prevents the move from re-triggering. The move itself fires the frame
//   the character becomes interruptible (still in the < 0xA6 state at our hook),
//   so the transition INTO the attack is not clobbered.
//
// Known limitations (intended for emulator tuning):
//   - A press made while already in an attack/grab/special action (id >= 0xA6)
//     is not buffered, so chaining "the next move during your current move" is
//     not covered. The common cases (buffer out of jumpsquat, landing, shield,
//     hitstun) are covered.
//   - Only the "pressed" mask is re-asserted, not "held" (0x01BC).
scope MoveBuffer {

    // Action-initiating buttons that should be buffered. Tunable.
    // A | B | Z | L | R | C-Up | C-Down | C-Left | C-Right  (= 0xE03F)
    constant BUFFER_MASK(Joypad.A | Joypad.B | Joypad.Z | Joypad.L | Joypad.R | Joypad.CU | Joypad.CD | Joypad.CL | Joypad.CR)

    // First "attack" action id (Action.Grab). Action ids at or above this are
    // attacks/grabs/throws/specials/captured states; below are non-attack states
    // we are allowed to buffer through.
    constant ATTACK_THRESHOLD(0x00A6)

    // @ Description
    // Per-port buffer state. 4 bytes per port:
    //   0x00 (halfword) - buffered "pressed" button mask
    //   0x02 (byte)     - frames remaining in the buffer window
    //   0x03 (byte)     - padding
    buffer_table:
    fill (4 * 4)
    OS.align(4)

    // @ Description
    // Hook into the human input routine (inside ftMainProcUpdate), immediately
    // after the per-frame "buttons pressed" field (0x01BE) is finalized and
    // before the action logic reads it. We capture this frame's new presses and
    // re-assert any buffered press into 0x01BE.
    //   a2 = player struct
    //   v0 = a2 + 0x01BC (input field pointer)
    //   a0, a1, a3 must be preserved for the continuation; t3-t6/v1 are clobbered
    //   by it, so we only use t0,t1,t2,t7,t8,t9,at here.
    scope inject_: {
        OS.patch_start(0x5CB4C, 0x800E134C)
        j       inject_
        nop
        _return:
        OS.patch_end()

        // Read the toggle (0 = off, 1-9 = window length in frames).
        OS.read_word(Toggles.entry_move_buffer + 0x4, t0)   // t0 = N
        beqz    t0, _orig                   // disabled -> original behavior
        nop

        lbu     t7, 0x000D(a2)              // t7 = player port
        li      t8, buffer_table            // ~
        sll     t9, t7, 0x0002              // t9 = port * 4
        addu    t8, t8, t9                  // t8 = this port's buffer entry

        // Consumption: if an attack/grab/special action is active, clear buffer.
        lw      t1, 0x0024(a2)              // t1 = current action id
        sltiu   t2, t1, ATTACK_THRESHOLD    // t2 = 1 if action < 0xA6 (non-attack)
        beqz    t2, _clear                  // action >= 0xA6 -> clear and continue
        nop

        // Non-attack state: capture a new press, or inject the buffered one.
        lhu     t7, 0x0002(v0)              // t7 = this frame's pressed buttons (0x01BE)
        andi    t9, t7, BUFFER_MASK         // t9 = new action-relevant presses

        beqz    t9, _inject                 // no new press -> try to inject buffer
        nop
        // A new action-relevant button was pressed this frame (already in 0x01BE),
        // so just record it for future frames.
        sh      t9, 0x0000(t8)              // buffered mask = new presses
        b       _orig
        sb      t0, 0x0002(t8)              // frames remaining = N (delay slot)

        _inject:
        lbu     t9, 0x0002(t8)              // t9 = frames remaining
        beqz    t9, _orig                   // nothing buffered -> done
        nop
        lhu     t1, 0x0000(t8)              // t1 = buffered mask
        or      t7, t7, t1                  // add buffered press to this frame
        sh      t7, 0x0002(v0)              // inject into 0x01BE
        addiu   t9, t9, -0x0001             // frames remaining--
        sb      t9, 0x0002(t8)              // store updated frames remaining
        bnez    t9, _orig                   // window not expired -> done
        nop
        sh      r0, 0x0000(t8)              // window expired -> clear buffered mask
        b       _orig
        nop

        _clear:
        sh      r0, 0x0000(t8)              // clear buffered mask
        sb      r0, 0x0002(t8)              // clear frames remaining

        _orig:
        lhu     a0, 0x0000(v0)              // original line 1 (lhu a0, 0x01BC(a2))
        j       _return
        lw      t4, 0x0040(a2)              // original line 2 (delay slot)
    }
}

} // __MOVEBUFFER__
