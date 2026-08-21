import Foundation

/// A slot-seven SmartPort/ProDOS block device.  Unlike Disk II, this is not a
/// flux controller: it transfers contiguous 512-byte ProDOS blocks through
/// the card's C0n0 register window.  Keeping the two devices separate avoids
/// accepting a hard-disk image as a fictional 5.25-inch floppy.
final class SmartPortController {
    static let blockSize = 512
    static let maximumBlocks = 65_535

    fileprivate struct Drive {
        var blocks: [UInt8]
        var writeProtected: Bool

        var blockCount: Int { blocks.count / SmartPortController.blockSize }
    }

    struct State {
        fileprivate let drives: [Drive?]
        fileprivate let command: UInt8
        fileprivate let unit: UInt8
        fileprivate let bufferAddress: UInt16
        fileprivate let blockNumber: UInt32
        fileprivate let statusCode: UInt8
        fileprivate let error: UInt8
        fileprivate let emulatedCycle: Int
        fileprivate let busyUntilCycle: Int
    }

    private var drives: [Drive?] = [nil, nil]
    private var command: UInt8 = 0
    private var unit: UInt8 = 0
    private var bufferAddress: UInt16 = 0
    private var blockNumber: UInt32 = 0
    private var statusCode: UInt8 = 0
    private var error: UInt8 = 0
    private var emulatedCycle = 0
    private var busyUntilCycle = 0

    /// A minimal slot-seven boot ROM. It uses this card's real C0F0 register
    /// window to load ProDOS block zero into $0800, then transfers control to
    /// that block. Apple II+/IIe software can therefore enter via `PR#7` /
    /// `$C700` instead of a UI-side program-counter shortcut.
    private static let bootROM: [UInt8] = {
        var rom = [UInt8](repeating: 0x60, count: 256) // RTS for unused probes
        let code: [UInt8] = [
            0xA9, 0x01,             // LDA #$01: SmartPort block read
            0x8D, 0xF2, 0xC0,       // STA $C0F2
            0xA9, 0x70,             // LDA #$70: slot 7, drive 1
            0x8D, 0xF3, 0xC0,       // STA $C0F3
            0xA9, 0x00,             // LDA #$00: buffer low
            0x8D, 0xF4, 0xC0,       // STA $C0F4
            0xA9, 0x08,             // LDA #$08: buffer high ($0800)
            0x8D, 0xF5, 0xC0,       // STA $C0F5
            0xA9, 0x00,             // LDA #$00: ProDOS block zero
            0x8D, 0xF6, 0xC0,       // STA $C0F6: block 0 low
            0x8D, 0xF7, 0xC0,       // STA $C0F7: block 0 high
            0x8D, 0xF8, 0xC0,       // STA $C0F8: block 0 bank
            0xAD, 0xF0, 0xC0,       // LDA $C0F0: execute command
            0x29, 0x01,             // AND #$01: SmartPort error bit
            0xD0, 0x03,             // BNE failure
            0x4C, 0x00, 0x08,       // JMP $0800
            0x60                    // failure: RTS
        ]
        rom.replaceSubrange(0..<code.count, with: code)
        return rom
    }()

    var hasDisk: Bool { drives.contains { $0 != nil } }
    func hasDisk(in drive: Int) -> Bool { drives.indices.contains(drive) && drives[drive] != nil }
    func blockCount(in drive: Int) -> Int { drives.indices.contains(drive) ? drives[drive]?.blockCount ?? 0 : 0 }

    func snapshot() -> State {
        State(
            drives: drives, command: command, unit: unit, bufferAddress: bufferAddress,
            blockNumber: blockNumber, statusCode: statusCode, error: error,
            emulatedCycle: emulatedCycle, busyUntilCycle: busyUntilCycle
        )
    }

    func restore(_ state: State) {
        drives = state.drives; command = state.command; unit = state.unit
        bufferAddress = state.bufferAddress; blockNumber = state.blockNumber
        statusCode = state.statusCode; error = state.error
        emulatedCycle = state.emulatedCycle; busyUntilCycle = state.busyUntilCycle
    }

    func reset() {
        command = 0
        unit = 0
        bufferAddress = 0
        blockNumber = 0
        statusCode = 0
        error = 0
        busyUntilCycle = emulatedCycle
    }

    func advance(by cycles: Int) {
        guard cycles > 0 else { return }
        emulatedCycle &+= cycles
    }

    func eject(drive: Int = 0) {
        guard drives.indices.contains(drive) else { return }
        drives[drive] = nil
    }

    func mountImage(_ data: Data, fileExtension: String, drive: Int = 0) throws {
        guard drives.indices.contains(drive) else { throw CocoaError(.fileReadCorruptFile) }
        let image = try Self.decodeImage(data, fileExtension: fileExtension)
        guard !image.bytes.isEmpty,
              image.bytes.count.isMultiple(of: Self.blockSize),
              image.bytes.count / Self.blockSize <= Self.maximumBlocks else {
            throw CocoaError(.fileReadCorruptFile)
        }
        drives[drive] = Drive(blocks: image.bytes, writeProtected: image.writeProtected)
    }

    func imageData(drive: Int = 0) -> Data? {
        guard drives.indices.contains(drive), let drive = drives[drive] else { return nil }
        return Data(drive.blocks)
    }

    func romByte(at offset: Int) -> UInt8 {
        Self.bootROM[offset & 0xFF]
    }

    /// C0F0-C0FF for slot 7.  The CPU has already performed the bus access at
    /// the exact emulated cycle, so DMA and busy signalling share that clock.
    func access(_ address: Int, write value: UInt8?, bus: AppleIIBus) -> UInt8 {
        let register = address & 0x0F
        if let value {
            write(value, register: register)
            return 0
        }
        switch register {
        case 0:
            let result = execute(using: bus)
            // SmartPort firmware treats following C0n0 reads as a status
            // poll, rather than accidentally repeating a DMA command.
            command = command & 0x80 == 0 ? 0 : 0xBF
            return result
        case 1: return statusByte
        case 2: return command
        case 3: return unit
        case 4: return UInt8(truncatingIfNeeded: bufferAddress)
        case 5: return UInt8(truncatingIfNeeded: bufferAddress >> 8)
        case 6: return UInt8(truncatingIfNeeded: blockNumber)
        case 7: return UInt8(truncatingIfNeeded: blockNumber >> 8)
        case 8: return UInt8(truncatingIfNeeded: blockNumber >> 16)
        case 9: return UInt8(truncatingIfNeeded: selectedDrive?.blockCount ?? 0)
        case 10: return UInt8(truncatingIfNeeded: (selectedDrive?.blockCount ?? 0) >> 8)
        default: return 0
        }
    }

    private var statusByte: UInt8 {
        var result: UInt8 = error == 0 ? 0 : (error << 1) | 1
        if emulatedCycle <= busyUntilCycle { result |= 0x80 }
        return result
    }

    private var selectedDriveIndex: Int? {
        if command & 0x80 != 0 {
            guard unit >= 1, unit <= UInt8(drives.count) else { return nil }
            return Int(unit - 1)
        }
        // A ProDOS block device encodes the slot in bits 6...4 and drive in
        // bit 7.  The card owns slot 7, but accepting both legacy aliases is
        // useful to slot-independent ProDOS drivers.
        return unit & 0x80 == 0 ? 0 : 1
    }

    private var selectedDrive: Drive? {
        guard let index = selectedDriveIndex, drives.indices.contains(index) else { return nil }
        return drives[index]
    }

    private func write(_ value: UInt8, register: Int) {
        switch register {
        case 2: command = value
        case 3: unit = value
        case 4: bufferAddress = (bufferAddress & 0xFF00) | UInt16(value)
        case 5: bufferAddress = (bufferAddress & 0x00FF) | UInt16(value) << 8
        case 6:
            if command == 0x80 { statusCode = value }
            else { blockNumber = (blockNumber & 0xFFFF00) | UInt32(value) }
        case 7: blockNumber = (blockNumber & 0xFF00FF) | UInt32(value) << 8
        case 8 where command & 0x80 != 0:
            blockNumber = (blockNumber & 0x00FFFF) | UInt32(value) << 16
        default: break
        }
    }

    private func execute(using bus: AppleIIBus) -> UInt8 {
        error = 0
        switch command {
        case 0, 0x80:
            return executeStatus(using: bus)
        case 1, 0x81:
            return transfer(reading: true, bus: bus)
        case 2, 0x82:
            return transfer(reading: false, bus: bus)
        case 3, 0x83:
            return format()
        case 0xBF:
            return statusByte
        default:
            error = 0x21 // invalid control code
            return statusByte
        }
    }

    private func executeStatus(using bus: AppleIIBus) -> UInt8 {
        if command & 0x80 != 0, unit == 0 {
            var status = [UInt8](repeating: 0, count: 8)
            status[0] = UInt8(drives.compactMap { $0 }.count)
            return writeStatus(status, using: bus)
        }
        guard let drive = selectedDrive else {
            error = 0x28 // device not connected
            return statusByte
        }
        // Device status: block, write/read/online/format-capable; followed by
        // a 24-bit size. This is the SmartPort status-list representation.
        let flags: UInt8 = drive.writeProtected ? 0xFC : 0xF8
        let count = drive.blockCount
        return writeStatus([
            flags,
            UInt8(truncatingIfNeeded: count),
            UInt8(truncatingIfNeeded: count >> 8),
            UInt8(truncatingIfNeeded: count >> 16)
        ], using: bus)
    }

    private func writeStatus(_ bytes: [UInt8], using bus: AppleIIBus) -> UInt8 {
        guard transferRangeIsRAM(count: bytes.count) else {
            error = 0x21
            return statusByte
        }
        for (offset, byte) in bytes.enumerated() {
            bus.write(UInt16(truncatingIfNeeded: Int(bufferAddress) + offset), byte)
        }
        busyUntilCycle = emulatedCycle + bytes.count
        return statusByte
    }

    private func transfer(reading: Bool, bus: AppleIIBus) -> UInt8 {
        guard let index = selectedDriveIndex,
              drives.indices.contains(index),
              var drive = drives[index] else {
            error = 0x28
            return statusByte
        }
        guard blockNumber < UInt32(drive.blockCount), transferRangeIsRAM(count: Self.blockSize) else {
            error = blockNumber < UInt32(drive.blockCount) ? 0x21 : 0x27
            return statusByte
        }
        let start = Int(blockNumber) * Self.blockSize
        if reading {
            for offset in 0..<Self.blockSize {
                bus.write(UInt16(truncatingIfNeeded: Int(bufferAddress) + offset), drive.blocks[start + offset])
            }
        } else {
            guard !drive.writeProtected else {
                error = 0x2B
                return statusByte
            }
            for offset in 0..<Self.blockSize {
                drive.blocks[start + offset] = bus.read(UInt16(truncatingIfNeeded: Int(bufferAddress) + offset))
            }
            drives[index] = drive
        }
        busyUntilCycle = emulatedCycle + Self.blockSize
        return statusByte
    }

    private func format() -> UInt8 {
        guard let index = selectedDriveIndex,
              drives.indices.contains(index),
              var drive = drives[index] else {
            error = 0x28
            return statusByte
        }
        guard !drive.writeProtected else {
            error = 0x2B
            return statusByte
        }
        drive.blocks = [UInt8](repeating: 0, count: drive.blocks.count)
        drives[index] = drive
        busyUntilCycle = emulatedCycle + drive.blocks.count / 4
        return statusByte
    }

    private func transferRangeIsRAM(count: Int) -> Bool {
        for offset in 0..<count {
            let address = (Int(bufferAddress) + offset) & 0xFFFF
            if address >= 0xC000 { return false }
        }
        return true
    }

    private static func decodeImage(_ data: Data, fileExtension: String) throws -> (bytes: [UInt8], writeProtected: Bool) {
        switch fileExtension.lowercased() {
        case "po", "hdv", "img":
            return (Array(data), false)
        case "2mg", "2img":
            let bytes = Array(data)
            guard bytes.count >= 64, Array(bytes[0..<4]) == Array("2IMG".utf8) else {
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
            guard format == 1, headerLength >= 64, dataOffset >= headerLength,
                  dataOffset <= bytes.count, dataLength <= bytes.count - dataOffset else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return (Array(bytes[dataOffset..<(dataOffset + dataLength)]), flags & 0x8000_0000 != 0)
        default:
            throw CocoaError(.fileReadUnsupportedScheme)
        }
    }
}
