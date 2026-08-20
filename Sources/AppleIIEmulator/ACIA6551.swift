import Foundation

/// Synertek/MOS 6551 ACIA as used by the Apple IIc's built-in printer and
/// modem ports.  It models register-visible state and shifts one framed byte
/// from the transmitter using the emulator's 6502 cycle clock; it deliberately
/// has no AppKit or host-serial dependency.
struct ACIA6551 {
    private static let receiverDataFull: UInt8 = 0x08
    private static let transmitterDataEmpty: UInt8 = 0x10
    private static let interruptRequest: UInt8 = 0x80

    private(set) var command: UInt8 = 0
    private(set) var control: UInt8 = 0
    private var receiveData: UInt8?
    private var transmitData: UInt8?
    private var transmitCyclesRemaining = 0
    private var transmittedBytes = [UInt8]()

    private var receiverInterruptEnabled: Bool { command & 0x02 != 0 }
    private var transmitterEnabled: Bool { (command >> 2) & 0x03 != 0 }
    var irqPending: Bool { receiveData != nil && receiverInterruptEnabled }
    var baudRate: Int { selectedBaudRate }

    mutating func reset() {
        command = 0
        control = 0
        receiveData = nil
        transmitData = nil
        transmitCyclesRemaining = 0
        transmittedBytes.removeAll(keepingCapacity: true)
    }

    mutating func read(register: Int) -> UInt8 {
        switch register & 0x03 {
        case 0:
            let value = receiveData ?? 0
            receiveData = nil
            return value
        case 1:
            // RDRF (and therefore receive IRQ) remains set until software
            // consumes the data register, as on the level-sensitive ACIA.
            return status
        case 2: return command
        default: return control
        }
    }

    mutating func write(_ value: UInt8, register: Int) {
        switch register & 0x03 {
        case 0:
            guard transmitterEnabled, transmitData == nil else { return }
            transmitData = value
            transmitCyclesRemaining = cyclesPerCharacter
        case 2:
            command = value
        case 3:
            control = value
        default:
            break // status is read-only
        }
    }

    mutating func advance(by cycles: Int) {
        guard cycles > 0, transmitData != nil else { return }
        transmitCyclesRemaining -= cycles
        guard transmitCyclesRemaining <= 0, let byte = transmitData else { return }
        transmittedBytes.append(byte)
        transmitData = nil
        transmitCyclesRemaining = 0
    }

    mutating func receive(_ byte: UInt8) {
        // A one-byte receive data register is faithful to the software-visible
        // hardware. If it is full, a subsequent byte is dropped; overrun
        // reporting can be added without changing the bus surface.
        guard receiveData == nil else { return }
        receiveData = byte
    }

    mutating func drainTransmittedBytes() -> [UInt8] {
        defer { transmittedBytes.removeAll(keepingCapacity: true) }
        return transmittedBytes
    }

    private var status: UInt8 {
        var value: UInt8 = transmitData == nil ? Self.transmitterDataEmpty : 0
        if receiveData != nil {
            value |= Self.receiverDataFull
            if receiverInterruptEnabled { value |= Self.interruptRequest }
        }
        return value
    }

    private var cyclesPerCharacter: Int {
        // Control-register low nibble is the 6551's baud selector. A serial
        // frame is modelled as start + 8 data + stop bits, which is the common
        // IIc 8-N-1 configuration. External-clock mode falls back to 9600 so
        // an unconfigured virtual port never stalls CPU-driven firmware.
        let baud = selectedBaudRate
        return max(1, (1_021_800 * 10 + baud - 1) / baud)
    }

    private var selectedBaudRate: Int {
        switch control & 0x0F {
        case 0x01: return 50
        case 0x02: return 75
        case 0x03: return 110
        case 0x04: return 134
        case 0x05: return 150
        case 0x06: return 300
        case 0x07: return 600
        case 0x08: return 1_200
        case 0x09: return 1_800
        case 0x0A: return 2_400
        case 0x0B: return 3_600
        case 0x0C: return 4_800
        case 0x0D: return 7_200
        case 0x0F: return 19_200
        default: return 9_600
        }
    }
}
