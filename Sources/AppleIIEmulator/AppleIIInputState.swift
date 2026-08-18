import Foundation

/// Host-input state converted into the Apple II's digital keyboard and
/// analogue paddle interface.  It deliberately contains no AppKit types so
/// it can be unit-tested without a window or run loop.
struct AppleIIInputState {
    private var heldJoystickKeys = Set<UInt16>()
    private var paddles: [UInt8] = [127, 127, 127, 127]

    mutating func setJoystickKey(_ keyCode: UInt16, pressed: Bool) -> [UInt8]? {
        guard [123, 124, 125, 126].contains(keyCode) else { return nil }
        if pressed { heldJoystickKeys.insert(keyCode) }
        else { heldJoystickKeys.remove(keyCode) }

        let left = heldJoystickKeys.contains(123)
        let right = heldJoystickKeys.contains(124)
        let down = heldJoystickKeys.contains(125)
        let up = heldJoystickKeys.contains(126)
        // The keyboard acts as a digital position setter, not a spring-loaded
        // physical stick. When the last key on an axis is released, retain its
        // previous paddle position. Holding opposite directions cancels back
        // to centre; releasing either one then adopts the still-held side.
        if left || right {
            let horizontal: UInt8 = left == right ? 127 : (left ? 0 : 255)
            paddles[0] = horizontal
            paddles[2] = horizontal
        }
        if up || down {
            let vertical: UInt8 = up == down ? 127 : (up ? 0 : 255)
            paddles[1] = vertical
            paddles[3] = vertical
        }
        return paddles
    }
}
