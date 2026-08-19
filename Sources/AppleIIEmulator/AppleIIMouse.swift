import Foundation

/// Slot-4-compatible Apple Mouse Interface.  The IIc maps this hardware into
/// its built-in mouse port; its ROM communicates through an MC6821 PIA rather
/// than reading host coordinates directly.
struct AppleIIMouseInterface {
    private struct PIA6821 {
        var portAOutput: UInt8 = 0
        var portBOutput: UInt8 = 0
        var portAInput: UInt8 = 0
        var portBInput: UInt8 = 0x40
        var directionA: UInt8 = 0
        var directionB: UInt8 = 0
        var controlA: UInt8 = 0
        var controlB: UInt8 = 0

        mutating func read(_ register: Int) -> UInt8 {
            switch register & 0x03 {
            case 0: return controlA & 0x04 == 0 ? directionA : merged(portAOutput, portAInput, directionA)
            case 1: return controlA
            case 2: return controlB & 0x04 == 0 ? directionB : merged(portBOutput, portBInput, directionB)
            default: return controlB
            }
        }

        mutating func write(_ value: UInt8, register: Int) {
            switch register & 0x03 {
            case 0:
                if controlA & 0x04 == 0 { directionA = value } else { portAOutput = value }
            case 1: controlA = value
            case 2:
                if controlB & 0x04 == 0 { directionB = value } else { portBOutput = value }
            default: controlB = value
            }
        }

        private func merged(_ output: UInt8, _ input: UInt8, _ direction: UInt8) -> UInt8 {
            (output & direction) | (input & ~direction)
        }
    }

    private var pia = PIA6821()
    private var latchedPortB: UInt8 = 0x40
    private var buffer = [UInt8](repeating: 0, count: 7)
    private var bufferPosition = 0
    private var commandLength = 1
    private var mode: UInt8 = 0
    private var state: UInt8 = 0
    private var x = 0
    private var y = 0
    private var minimumX = 0
    private var maximumX = 1_023
    private var minimumY = 0
    private var maximumY = 1_023
    private var previousButton0 = false
    private var previousButton1 = false
    private var button0 = false
    private var button1 = false

    // Apple Mouse protocol status and mode bits.
    private static let interruptMovement: UInt8 = 0x02
    private static let interruptButton: UInt8 = 0x04
    private static let interruptVBlank: UInt8 = 0x08
    private static let movementSinceRead: UInt8 = 0x20
    private static let interruptMask: UInt8 = 0x0E

    var irqPending: Bool { state & Self.interruptMask != 0 }

    mutating func reset() {
        pia = PIA6821()
        latchedPortB = 0x40
        buffer = [UInt8](repeating: 0, count: 7)
        bufferPosition = 0
        commandLength = 1
        mode = 0
        state = 0
        x = 0; y = 0
        minimumX = 0; maximumX = 1_023
        minimumY = 0; maximumY = 1_023
        previousButton0 = false; previousButton1 = false
        button0 = false; button1 = false
    }

    mutating func read(register: Int) -> UInt8 { pia.read(register) }

    mutating func write(_ value: UInt8, register: Int) {
        let oldB = pia.portBOutput
        pia.write(value, register: register)
        if pia.portBOutput != oldB { portBChanged(pia.portBOutput) }
    }

    mutating func move(deltaX: Int, deltaY: Int) {
        guard deltaX != 0 || deltaY != 0 else { return }
        x = min(maximumX, max(minimumX, x + deltaX))
        y = min(maximumY, max(minimumY, y + deltaY))
        guard mode & 0x01 != 0 else { return }
        state |= Self.movementSinceRead
        if mode & 0x02 != 0 { state |= Self.interruptMovement }
    }

    mutating func setButton(_ index: Int, pressed: Bool) {
        guard index == 0 || index == 1 else { return }
        let changed = (index == 0 ? button0 : button1) != pressed
        if index == 0 { button0 = pressed } else { button1 = pressed }
        guard mode & 0x01 != 0, mode & 0x04 != 0 else { return }
        if changed {
            state |= Self.interruptButton
        }
    }

    mutating func verticalBlank() {
        if mode & 0x08 != 0 { state |= Self.interruptVBlank }
    }

    private mutating func portBChanged(_ value: UInt8) {
        let changed = (latchedPortB ^ value) & 0x30
        latchedPortB = (latchedPortB & ~0x3E) | (value & 0x3E)

        // PB5 strobes a byte from the 6502 to the mouse controller. PB7 is
        // the ready acknowledgement driven back through the PIA input pins.
        if changed & 0x20 != 0 {
            if value & 0x20 != 0 {
                pia.portBInput |= 0x80
            } else {
                receiveCommandByte(pia.portAOutput)
                pia.portBInput &= ~0x80
            }
        }

        // PB4 clocks a response byte from the controller to the 6502. PB6
        // acknowledges availability, with the data travelling on port A.
        if changed & 0x10 != 0 {
            if value & 0x10 != 0 {
                pia.portBInput &= ~0x40
            } else {
                advanceResponseByte()
            }
        }
    }

    private mutating func receiveCommandByte(_ byte: UInt8) {
        guard bufferPosition < buffer.count else { bufferPosition = 0; return }
        buffer[bufferPosition] = byte
        if bufferPosition == 0 { prepareCommand(byte) }
        bufferPosition += 1
        if bufferPosition >= commandLength {
            commitCommand()
            bufferPosition = 0
        }
    }

    private mutating func prepareCommand(_ command: UInt8) {
        switch command & 0xF0 {
        case 0x00:
            commandLength = 1
            mode = command & 0x0F
        case 0x10: // READMOUSE
            commandLength = 6
            state &= Self.movementSinceRead
            if previousButton1 { state |= 0x01 }
            if previousButton0 { state |= 0x40 }
            previousButton0 = button0; previousButton1 = button1
            if button0 { state |= 0x80 }
            if button1 { state |= 0x10 }
            buffer[1] = UInt8(truncatingIfNeeded: x)
            buffer[2] = UInt8(truncatingIfNeeded: x >> 8)
            buffer[3] = UInt8(truncatingIfNeeded: y)
            buffer[4] = UInt8(truncatingIfNeeded: y >> 8)
            buffer[5] = state
            state &= ~Self.movementSinceRead
        case 0x20: // SERVE
            commandLength = 2
            buffer[1] = state & ~Self.movementSinceRead
            state &= ~Self.interruptMask
        case 0x30: commandLength = 1
        case 0x40, 0x60: commandLength = 5
        case 0x50:
            commandLength = 3
            buffer[1] = 0xFF
        case 0x70:
            commandLength = 1
            x = minimumX; y = minimumY
        default:
            commandLength = 1
        }
        pia.portAInput = buffer[1]
        pia.portBInput |= 0x40
    }

    private mutating func commitCommand() {
        switch buffer[0] & 0xF0 {
        case 0x30:
            x = minimumX; y = minimumY
            state = 0
        case 0x40:
            x = clamped(Int(buffer[1]) | Int(buffer[2]) << 8, minimumX, maximumX)
            y = clamped(Int(buffer[3]) | Int(buffer[4]) << 8, minimumY, maximumY)
        case 0x50:
            minimumX = 0; maximumX = 1_023
            minimumY = 0; maximumY = 1_023
            x = 0; y = 0
        case 0x60:
            let minimum = Int(buffer[1]) | Int(buffer[3]) << 8
            let maximum = Int(buffer[2]) | Int(buffer[4]) << 8
            if buffer[0] & 0x01 == 0 {
                minimumX = min(minimum, maximum); maximumX = max(minimum, maximum)
                x = clamped(x, minimumX, maximumX)
            } else {
                minimumY = min(minimum, maximum); maximumY = max(minimum, maximum)
                y = clamped(y, minimumY, maximumY)
            }
        default: break
        }
    }

    private mutating func advanceResponseByte() {
        guard bufferPosition > 0 else { return }
        bufferPosition += 1
        if bufferPosition >= commandLength || bufferPosition >= buffer.count {
            bufferPosition = 0
        } else {
            pia.portAInput = buffer[bufferPosition]
            pia.portBInput |= 0x40
        }
    }

    private func clamped(_ value: Int, _ minimum: Int, _ maximum: Int) -> Int {
        min(maximum, max(minimum, value))
    }
}
