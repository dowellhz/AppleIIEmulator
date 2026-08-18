import Foundation

/// HGR colour is decoded in pairs of adjacent memory dots (140 effective
/// colour pixels per row). Kept independent from SwiftUI so the renderer's
/// NTSC phase rules are directly testable.
enum AppleIIHiResColor: Equatable {
    case black, green, purple, white, orange, blue
}

func appleIIHiResColors(bytes: [UInt8]) -> [AppleIIHiResColor] {
    let storedDotCount = bytes.count * 7
    let dotCount = storedDotCount + (storedDotCount.isMultiple(of: 2) ? 0 : 1)
    var dots = [Bool](repeating: false, count: dotCount)
    var phaseShifted = [Bool](repeating: false, count: dotCount)
    for (column, byte) in bytes.enumerated() {
        for bit in 0..<7 {
            let x = column * 7 + bit
            dots[x] = byte & (1 << bit) != 0
            phaseShifted[x] = byte & 0x80 != 0
        }
    }
    return stride(from: 0, to: dots.count, by: 2).map { x in
        let pair = (dots[x] ? 2 : 0) | (dots[x + 1] ? 1 : 0)
        switch (phaseShifted[x], pair) {
        case (_, 0): return .black
        case (false, 1): return .green
        case (false, 2): return .purple
        case (true, 1): return .orange
        case (true, 2): return .blue
        default: return .white
        }
    }
}

/// Full 280-dot HGR raster.  Unlike the 140-colour-cell helper above, this
/// preserves the width of a white two-dot stroke, which is important for the
/// sharply drawn game menus that use HGR as a text mode.
func appleIIHiResDots(bytes: [UInt8]) -> [AppleIIHiResColor] {
    let count = bytes.count * 7
    var dots = [Bool](repeating: false, count: count)
    var phaseShifted = [Bool](repeating: false, count: count)
    for (column, byte) in bytes.enumerated() {
        for bit in 0..<7 {
            let x = column * 7 + bit
            dots[x] = byte & (1 << bit) != 0
            phaseShifted[x] = byte & 0x80 != 0
        }
    }
    return dots.indices.map { x in
        guard dots[x] else { return .black }
        if (x > 0 && dots[x - 1]) || (x + 1 < dots.count && dots[x + 1]) { return .white }
        switch (phaseShifted[x], x.isMultiple(of: 2)) {
        case (false, true): return .purple
        case (false, false): return .green
        case (true, true): return .blue
        case (true, false): return .orange
        }
    }
}
