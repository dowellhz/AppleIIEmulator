import Foundation

/// File-format boundary for the 5¼-inch media codec.  The IWM controller
/// consumes only bit tracks; format detection and container parsing belong to
/// this value type rather than to soft-switch handling.
enum DiskImageFormat: String, CaseIterable {
    case dosOrder = "dsk"
    case thirteenSector = "d13"
    case prodosOrder = "po"
    case nibble = "nib"
    case twoIMG = "2mg"

    init?(fileExtension: String) {
        switch fileExtension.lowercased() {
        case "dsk", "do": self = .dosOrder
        case "d13": self = .thirteenSector
        case "po": self = .prodosOrder
        case "nib": self = .nibble
        case "2mg", "2img": self = .twoIMG
        default: return nil
        }
    }
}

/// Decoded image payload handed to the drive.  Container parsing lives here;
/// `DiskII` only turns a known 5¼-inch payload into magnetic bit tracks.
enum DiskImagePayload {
    case dos(Data)
    case thirteenSector(Data)
    case prodos(Data)
    case nib(Data)
}

enum DiskImageCodec {
    static func decode(_ data: Data, format: DiskImageFormat) throws -> DiskImagePayload {
        switch format {
        case .dosOrder: return .dos(data)
        case .thirteenSector: return .thirteenSector(data)
        case .prodosOrder: return .prodos(data)
        case .nibble: return .nib(data)
        case .twoIMG: return try decodeTwoIMG(data)
        }
    }

    private static func decodeTwoIMG(_ data: Data) throws -> DiskImagePayload {
        let bytes = Array(data)
        guard bytes.count >= 64, Array(bytes[0..<4]) == [0x32, 0x49, 0x4D, 0x47] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        func little16(_ offset: Int) -> Int { Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 }
        func little32(_ offset: Int) -> Int {
            Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 | Int(bytes[offset + 2]) << 16 | Int(bytes[offset + 3]) << 24
        }
        let headerLength = little16(8)
        let format = little32(12)
        let dataOffset = little32(24)
        let dataLength = little32(28)
        guard headerLength >= 64, dataOffset >= headerLength, dataOffset <= bytes.count,
              dataLength <= bytes.count - dataOffset else { throw CocoaError(.fileReadCorruptFile) }
        let payload = Data(bytes[dataOffset..<(dataOffset + dataLength)])
        switch format {
        case 0: return .dos(payload)
        case 1: return .prodos(payload)
        case 2: return .nib(payload)
        default: throw CocoaError(.fileReadUnsupportedScheme)
        }
    }
}
