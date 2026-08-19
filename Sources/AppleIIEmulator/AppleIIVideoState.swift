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

/// Immutable frame handed from the emulation worker to SwiftUI.  The renderer
/// never needs to read the mutable 6502 bus directly, which keeps display
/// work independent of CPU and disk-controller execution.
struct AppleIIVideoSnapshot: Equatable {
    let textMode: Bool
    let mixedMode: Bool
    let hires: Bool
    let doubleHires: Bool
    let column80: Bool
    let alternateCharset: Bool
    let text: [UInt8]
    let lores: [UInt8]
    let hgrMain: [UInt8]
    let hgrAuxiliary: [UInt8]

    static let blank = AppleIIVideoSnapshot(
        textMode: true, mixedMode: false, hires: false, doubleHires: false,
        column80: false, alternateCharset: false,
        text: [UInt8](repeating: 0, count: 80 * 24),
        lores: [UInt8](repeating: 0, count: 40 * 24),
        hgrMain: [UInt8](repeating: 0, count: 40 * 192),
        hgrAuxiliary: [UInt8](repeating: 0, count: 40 * 192)
    )

    func textByte(column: Int, row: Int) -> UInt8 {
        guard (0..<80).contains(column), (0..<24).contains(row) else { return 0 }
        return text[row * 80 + column]
    }

    func loresByte(column: Int, row: Int) -> UInt8 {
        guard (0..<40).contains(column), (0..<24).contains(row) else { return 0 }
        return lores[row * 40 + column]
    }

    func hgrByte(column: Int, row: Int, auxiliary: Bool) -> UInt8 {
        guard (0..<40).contains(column), (0..<192).contains(row) else { return 0 }
        return (auxiliary ? hgrAuxiliary : hgrMain)[row * 40 + column]
    }
}
