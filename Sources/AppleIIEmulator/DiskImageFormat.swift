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
    case woz = "woz"

    init?(fileExtension: String) {
        switch fileExtension.lowercased() {
        case "dsk", "do": self = .dosOrder
        case "d13": self = .thirteenSector
        case "po": self = .prodosOrder
        case "nib": self = .nibble
        case "2mg", "2img": self = .twoIMG
        case "woz": self = .woz
        default: return nil
        }
    }
}

/// Decoded image payload handed to the drive.  Container parsing lives here;
/// `DiskII` only turns a known 5¼-inch payload into magnetic bit tracks.
enum DiskImagePayload {
    case dos(Data, writeProtected: Bool)
    case thirteenSector(Data, writeProtected: Bool)
    case prodos(Data, writeProtected: Bool)
    case nib(Data, writeProtected: Bool)
    case woz(
        tracks: [DiskBitTrack], quarterTrackMap: [Int], thirteenSector: Bool,
        emulatesWeakBits: Bool, writeProtected: Bool
    )
}

enum DiskImageCodec {
    static func decode(_ data: Data, format: DiskImageFormat) throws -> DiskImagePayload {
        switch format {
        case .dosOrder: return .dos(data, writeProtected: false)
        case .thirteenSector: return .thirteenSector(data, writeProtected: false)
        case .prodosOrder: return .prodos(data, writeProtected: false)
        case .nibble: return .nib(data, writeProtected: false)
        case .twoIMG: return try decodeTwoIMG(data)
        case .woz: return try decodeWOZ(data)
        }
    }

    /// Writes a self-contained WOZ 2 bitstream container.  Export always
    /// emits the canonical INFO/TMAP/TRKS core and recalculates its CRC; it
    /// deliberately does not copy opaque source chunks, whose semantics can
    /// depend on a capture device rather than on the emulated disk surface.
    static func encodeWOZ2(
        tracks: [DiskBitTrack],
        quarterTrackMap: [Int],
        thirteenSector: Bool,
        writeProtected: Bool
    ) throws -> Data {
        guard quarterTrackMap.count == 160,
              tracks.count <= 160,
              quarterTrackMap.allSatisfy({ $0 == -1 || tracks.indices.contains($0) }) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }

        var info = [UInt8](repeating: 0, count: 60)
        info[0] = 3 // WOZ INFO v3 carries the 5.25-inch timing fields below.
        info[1] = 1 // 5.25-inch disk
        info[2] = writeProtected ? 1 : 0
        info[3] = 1 // bitstream was synchronized by the controller
        info[38] = thirteenSector ? 2 : 1
        info[39] = 32 // 4 µs nominal bit cell in 125 ns units

        var trackChunk = [UInt8](repeating: 0, count: 160 * 8)
        var bitData = [UInt8]()
        var nextBlock = 3
        var largestTrackBlocks = 0
        for (index, track) in tracks.enumerated() {
            guard track.bitCount >= 0, track.bitCount <= track.bytes.count * 8 else {
                throw CocoaError(.fileWriteUnknown)
            }
            guard track.bitCount > 0 else { continue }
            let byteCount = (track.bitCount + 7) / 8
            let blockCount = (byteCount + 511) / 512
            guard nextBlock + blockCount <= Int(UInt16.max) else {
                throw CocoaError(.fileWriteOutOfSpace)
            }
            let entry = index * 8
            trackChunk[entry] = UInt8(nextBlock & 0xFF)
            trackChunk[entry + 1] = UInt8((nextBlock >> 8) & 0xFF)
            trackChunk[entry + 2] = UInt8(blockCount & 0xFF)
            trackChunk[entry + 3] = UInt8((blockCount >> 8) & 0xFF)
            for byte in 0..<4 {
                trackChunk[entry + 4 + byte] = UInt8((track.bitCount >> (byte * 8)) & 0xFF)
            }
            bitData += track.bytes.prefix(byteCount)
            bitData += repeatElement(0, count: blockCount * 512 - byteCount)
            nextBlock += blockCount
            largestTrackBlocks = max(largestTrackBlocks, blockCount)
        }
        info[44] = UInt8(min(largestTrackBlocks, 255))
        info[45] = UInt8(min(largestTrackBlocks >> 8, 255))

        func chunk(_ identifier: String, _ payload: [UInt8]) -> [UInt8] {
            let length = payload.count
            return Array(identifier.utf8) + (0..<4).map { UInt8((length >> ($0 * 8)) & 0xFF) } + payload
        }
        let map = quarterTrackMap.map { $0 < 0 ? UInt8(0xFF) : UInt8($0) }
        var bytes = Array("WOZ2".utf8) + [0xFF, 0x0A, 0x0D, 0x0A] + [0, 0, 0, 0]
        bytes += chunk("INFO", info)
        bytes += chunk("TMAP", map)
        bytes += chunk("TRKS", trackChunk + bitData)
        let checksum = crc32(bytes[12...])
        for byte in 0..<4 { bytes[8 + byte] = UInt8((checksum >> (byte * 8)) & 0xFF) }
        return Data(bytes)
    }

    private static func crc32(_ bytes: ArraySlice<UInt8>) -> UInt32 {
        var value: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            value ^= UInt32(byte)
            for _ in 0..<8 {
                value = value & 1 == 0 ? value >> 1 : (value >> 1) ^ 0xEDB8_8320
            }
        }
        return ~value
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
        let flags = little32(16)
        let dataOffset = little32(24)
        let dataLength = little32(28)
        guard headerLength >= 64, dataOffset >= headerLength, dataOffset <= bytes.count,
              dataLength <= bytes.count - dataOffset else { throw CocoaError(.fileReadCorruptFile) }
        let payload = Data(bytes[dataOffset..<(dataOffset + dataLength)])
        // 2IMG flags bit 31 is the media write-protect switch.  It belongs to
        // the mounted disk, not the host file, so the IWM can expose it on
        // Q6H even when the image is kept entirely in memory.
        let writeProtected = flags & 0x8000_0000 != 0
        switch format {
        case 0: return .dos(payload, writeProtected: writeProtected)
        case 1: return .prodos(payload, writeProtected: writeProtected)
        case 2: return .nib(payload, writeProtected: writeProtected)
        default: throw CocoaError(.fileReadUnsupportedScheme)
        }
    }

    /// Decodes WOZ 1.x and 2.x 5¼-inch bitstream layouts.
    private static func decodeWOZ(_ data: Data) throws -> DiskImagePayload {
        let bytes = Array(data)
        let signature = bytes.count >= 4 ? Array(bytes[0..<4]) : []
        let isWOZ2 = signature == Array("WOZ2".utf8)
        guard bytes.count >= 12,
              isWOZ2 || signature == Array("WOZ1".utf8),
              Array(bytes[4..<8]) == [0xFF, 0x0A, 0x0D, 0x0A] else {
            throw CocoaError(.fileReadCorruptFile)
        }

        func little16(_ offset: Int) -> Int {
            Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
        }
        func little32(_ offset: Int) -> Int {
            Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 |
            Int(bytes[offset + 2]) << 16 | Int(bytes[offset + 3]) << 24
        }

        // Older hand-built test fixtures sometimes leave this field zero;
        // accept those as an explicitly unchecked legacy image, but reject a
        // present checksum that does not describe the complete container.
        let declaredCRC = UInt32(little32(8))
        guard declaredCRC == 0 || declaredCRC == crc32(bytes[12...]) else {
            throw CocoaError(.fileReadCorruptFile)
        }

        var chunks = [String: Range<Int>]()
        var offset = 12
        while offset + 8 <= bytes.count {
            guard let identifier = String(bytes: bytes[offset..<(offset + 4)], encoding: .ascii) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let length = little32(offset + 4)
            let dataStart = offset + 8
            guard length <= bytes.count - dataStart else { throw CocoaError(.fileReadCorruptFile) }
            chunks[identifier] = dataStart..<(dataStart + length)
            offset = dataStart + length
        }

        guard let infoRange = chunks["INFO"], infoRange.count >= 3,
              bytes[infoRange.lowerBound + 1] == 1,
              let mapRange = chunks["TMAP"], mapRange.count >= 160,
              let tracksRange = chunks["TRKS"], tracksRange.count >= 160 * 8 else {
            throw CocoaError(.fileReadCorruptFile)
        }

        // A 5¼-inch WOZ map is indexed in quarter tracks.  Keep every entry
        // (rather than collapsing to 35 whole tracks) for protected disks
        // which intentionally overlap or leave tracks blank.
        let quarterTrackMap = (0..<160).map { index -> Int in
            let value = bytes[mapRange.lowerBound + index]
            return value == 0xFF ? -1 : Int(value)
        }
        let trackCount: Int
        if isWOZ2 {
            trackCount = 160
        } else {
            guard tracksRange.count.isMultiple(of: 6_656) else { throw CocoaError(.fileReadCorruptFile) }
            trackCount = tracksRange.count / 6_656
        }
        guard trackCount > 0, quarterTrackMap.allSatisfy({ $0 < trackCount }) else {
            throw CocoaError(.fileReadCorruptFile)
        }

        var bitTracks = [DiskBitTrack]()
        bitTracks.reserveCapacity(trackCount)
        if isWOZ2 {
            for index in 0..<trackCount {
                let entry = tracksRange.lowerBound + index * 8
                let startBlock = little16(entry)
                let blockCount = little16(entry + 2)
                let bitCount = little32(entry + 4)
                if startBlock == 0 && blockCount == 0 && bitCount == 0 {
                    bitTracks.append(DiskBitTrack(bytes: [], bitCount: 0, nibbleBitOffsets: []))
                    continue
                }
                let byteCount = (bitCount + 7) / 8
                let dataOffset = startBlock * 512
                guard startBlock >= 3, blockCount > 0,
                      byteCount <= blockCount * 512,
                      dataOffset <= bytes.count, byteCount <= bytes.count - dataOffset else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                bitTracks.append(DiskBitTrack(
                    bytes: Array(bytes[dataOffset..<(dataOffset + byteCount)]),
                    bitCount: bitCount,
                    nibbleBitOffsets: Array(repeating: -1, count: bitCount)
                ))
            }
        } else {
            for index in 0..<trackCount {
                let entry = tracksRange.lowerBound + index * 6_656
                let byteCount = little16(entry + 6_646)
                let bitCount = little16(entry + 6_648)
                guard byteCount <= 6_646, bitCount <= byteCount * 8 else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                bitTracks.append(DiskBitTrack(
                    bytes: Array(bytes[entry..<(entry + byteCount)]),
                    bitCount: bitCount,
                    nibbleBitOffsets: Array(repeating: -1, count: bitCount)
                ))
            }
        }
        guard quarterTrackMap.contains(where: { $0 >= 0 && bitTracks[$0].bitCount > 0 }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let thirteenSector = isWOZ2 && infoRange.count > 38 && bytes[infoRange.lowerBound + 38] == 2
        // Applesauce records original weak-bit regions as zero runs once
        // cleaned.  The IWM will reconstruct the MC3470's noisy output.
        let emulatesWeakBits = bytes[infoRange.lowerBound + 4] != 0
        return .woz(
            tracks: bitTracks, quarterTrackMap: quarterTrackMap,
            thirteenSector: thirteenSector, emulatesWeakBits: emulatesWeakBits,
            writeProtected: bytes[infoRange.lowerBound + 2] != 0
        )
    }
}
