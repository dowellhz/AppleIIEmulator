import Foundation

/// Decoded text-cell attributes shared by the 40- and 80-column renderers.
enum AppleIITextCell: Equatable {
    case normal(UInt8), inverse(UInt8), alternate(UInt8), alternateInverse(UInt8), ascii(UInt8)
}

func appleIITextCell(byte: UInt8, alternateCharset: Bool, flashOn: Bool, supportsMouseText: Bool = true, usesSevenBitASCII: Bool = false) -> AppleIITextCell {
    if usesSevenBitASCII, byte & 0x80 != 0 {
        let ascii = byte & 0x7F
        if ascii >= 0x20, ascii <= 0x7E { return .ascii(ascii) }
    }
    let glyph = byte & 0x3F
    switch byte & 0xC0 {
    case 0x00: return .inverse(glyph)
    case 0x40:
        if alternateCharset { return supportsMouseText ? .alternate(glyph) : .alternateInverse(glyph) }
        return flashOn ? .normal(glyph) : .inverse(glyph)
    default: return .normal(glyph)
    }
}

func appleII80ColumnTextCell(byte: UInt8, alternateCharset: Bool, flashOn: Bool, supportsMouseText: Bool = true) -> AppleIITextCell {
    if byte & 0x80 != 0 { return .ascii(byte & 0x7F) }
    return appleIITextCell(byte: byte, alternateCharset: alternateCharset, flashOn: flashOn, supportsMouseText: supportsMouseText)
}
