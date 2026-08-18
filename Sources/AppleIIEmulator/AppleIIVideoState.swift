import Foundation

/// Read-only video-facing view of the memory bus.  The renderer depends on
/// this narrow interface instead of the full set of Apple II soft switches.
struct AppleIIVideoState {
    let textMode: Bool
    let mixedMode: Bool
    let hires: Bool
    let doubleHires: Bool
    let column80: Bool
    let alternateCharset: Bool
    let textByte: (Int, Int) -> UInt8
    let loresByte: (Int, Int) -> UInt8
    let hgrByte: (Int, Int, Bool) -> UInt8
}
