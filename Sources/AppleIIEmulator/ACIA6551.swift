import Foundation

struct SerialLineConfiguration: Equatable {
    enum Parity: Equatable { case none, odd, even }

    let baudRate: Int
    let dataBits: Int
    let stopBits: Int
    let parity: Parity
}

/// Synertek/MOS 6551 ACIA as used by the Apple IIc's built-in printer and
/// modem ports.  It models register-visible state and shifts one framed byte
/// from the transmitter using the emulator's 6502 cycle clock; it deliberately
/// has no AppKit or host-serial dependency.
struct ACIA6551 {
    struct State {
        fileprivate let acia: ACIA6551
        fileprivate init(acia: ACIA6551) { self.acia = acia }
    }
    private static let receiverDataFull: UInt8 = 0x08
    private static let transmitterDataEmpty: UInt8 = 0x10
    private static let interruptRequest: UInt8 = 0x80
    private static let overrun: UInt8 = 0x04
    private static let framingError: UInt8 = 0x02
    private static let parityError: UInt8 = 0x01

    private(set) var command: UInt8 = 0
    private(set) var control: UInt8 = 0
    private var receiveData: UInt8?
    private var receiveOverrun = false
    private var receiveFramingError = false
    private var receiveParityError = false
    // The 6551 has a one-byte transmit data register behind its shift
    // register. TDRE therefore becomes high once the first byte enters the
    // shifter, allowing firmware to queue the following byte mid-frame.
    private var transmitHoldingData: UInt8?
    private var transmitShiftData: UInt8?
    private var transmitCyclesRemaining = 0
    private var transmittedBytes = [UInt8]()

    private var receiverInterruptEnabled: Bool { command & 0x02 != 0 }
    private var transmitterEnabled: Bool { command & 0x0C == 0x04 }
    private var transmitterBreakActive: Bool { command & 0x0C == 0x0C }
    var irqPending: Bool { receiveData != nil && receiverInterruptEnabled }
    var baudRate: Int { selectedBaudRate }
    var lineConfiguration: SerialLineConfiguration {
        SerialLineConfiguration(
            baudRate: selectedBaudRate,
            dataBits: selectedDataBits,
            stopBits: control & 0x80 == 0 ? 1 : 2,
            parity: selectedParity
        )
    }

    func snapshot() -> State { State(acia: self) }
    mutating func restore(_ snapshot: State) { self = snapshot.acia }

    mutating func reset() {
        command = 0
        control = 0
        receiveData = nil
        receiveOverrun = false
        receiveFramingError = false
        receiveParityError = false
        transmitHoldingData = nil
        transmitShiftData = nil
        transmitCyclesRemaining = 0
        transmittedBytes.removeAll(keepingCapacity: true)
    }

    mutating func read(register: Int) -> UInt8 {
        switch register & 0x03 {
        case 0:
            let value = receiveData ?? 0
            receiveData = nil
            receiveOverrun = false
            receiveFramingError = false
            receiveParityError = false
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
            guard transmitterEnabled, !transmitterBreakActive else { return }
            if transmitShiftData == nil {
                startTransmission(value)
            } else if transmitHoldingData == nil {
                transmitHoldingData = value
            }
        case 2:
            command = value
        case 3:
            control = value
        default:
            break // status is read-only
        }
    }

    mutating func advance(by cycles: Int) {
        guard cycles > 0, transmitShiftData != nil else { return }
        var remainingCycles = cycles
        while remainingCycles > 0, let byte = transmitShiftData {
            if remainingCycles < transmitCyclesRemaining {
                transmitCyclesRemaining -= remainingCycles
                return
            }
            remainingCycles -= transmitCyclesRemaining
            transmittedBytes.append(byte)
            if let nextByte = transmitHoldingData {
                transmitHoldingData = nil
                startTransmission(nextByte)
            } else {
                transmitShiftData = nil
                transmitCyclesRemaining = 0
            }
        }
    }

    mutating func receive(_ byte: UInt8, framingError: Bool = false, parityError: Bool = false) {
        // A one-byte receive data register is faithful to the software-visible
        // hardware. If it is full, a subsequent byte is dropped and the
        // software-visible overrun flag remains latched until data is read.
        guard receiveData == nil else {
            receiveOverrun = true
            return
        }
        receiveData = byte
        receiveFramingError = framingError
        receiveParityError = parityError
    }

    mutating func drainTransmittedBytes() -> [UInt8] {
        defer { transmittedBytes.removeAll(keepingCapacity: true) }
        return transmittedBytes
    }

    private var status: UInt8 {
        var value: UInt8 = transmitHoldingData == nil ? Self.transmitterDataEmpty : 0
        if receiveData != nil {
            value |= Self.receiverDataFull
            if receiverInterruptEnabled { value |= Self.interruptRequest }
        }
        if receiveOverrun { value |= Self.overrun }
        if receiveFramingError { value |= Self.framingError }
        if receiveParityError { value |= Self.parityError }
        return value
    }

    private mutating func startTransmission(_ byte: UInt8) {
        transmitShiftData = byte
        transmitCyclesRemaining = cyclesPerCharacter
    }

    private var cyclesPerCharacter: Int {
        // Control-register low nibble is the 6551's baud selector. Frame
        // duration reflects its visible word-length, parity and stop-bit
        // controls so software polling TDRE remains tied to 6502 cycles.
        let baud = selectedBaudRate
        let frameBits = 1 + selectedDataBits + (command & 0x03 == 0 ? 0 : 1) + (control & 0x80 == 0 ? 1 : 2)
        return max(1, (1_021_800 * frameBits + baud - 1) / baud)
    }

    private var selectedDataBits: Int {
        switch (control >> 5) & 0x03 {
        case 0x01: return 7
        case 0x02: return 6
        case 0x03: return 5
        default: return 8
        }
    }

    private var selectedParity: SerialLineConfiguration.Parity {
        // Mark/space parity has no portable macOS termios representation.
        // Keep their emulated framing distinct from a silently wrong host mode.
        switch command & 0x03 {
        case 0x01: return .odd
        case 0x02: return .even
        default: return .none
        }
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
