import Foundation

/// Digital, cycle-driven state of the SSI-263A speech synthesizer.  The
/// chip's five attribute registers, power-down control and A/R request line
/// are modelled here independently from the Phasor's address decoder.
///
/// This deliberately represents the hardware's control plane only.  The
/// phoneme waveform ROM and vocal-tract filter are a separate analog/digital
/// synthesis task; this state machine must nevertheless provide the same bus
/// handshaking and interrupt timing that speech drivers use.
struct SSI263 {
    private enum TimingMode {
        case phonemeTransitioned
        case phonemeImmediate
        case frameImmediate
    }

    private static let frameCycles = 4_096

    private(set) var durationPhoneme: UInt8 = 0
    private(set) var inflection: UInt8 = 0
    private(set) var rateInflection: UInt8 = 0
    private(set) var controlArticulationAmplitude: UInt8 = 0x80
    private(set) var filterFrequency: UInt8 = 0xFF
    private(set) var requestAsserted = false

    private var timingMode: TimingMode = .phonemeTransitioned
    private var interruptsEnabled = false
    private var cyclesUntilRequest: Int?

    var irqPending: Bool {
        requestAsserted && interruptsEnabled && !isPoweredDown
    }

    var dataBusValue: UInt8 { requestAsserted ? 0x80 : 0 }

    mutating func reset() {
        self = Self()
    }

    mutating func write(_ register: Int, value: UInt8) {
        let index = register & 0x07
        if index <= 2 {
            // Writes to the first three attribute registers acknowledge the
            // A/R request line.  Drivers rely on this even when the chip is
            // installed on a Mockingboard rather than a native Phasor.
            requestAsserted = false
        }

        switch index {
        case 0:
            durationPhoneme = value
            if !isPoweredDown { beginPhoneme() }
        case 1:
            inflection = value
        case 2:
            rateInflection = value
        case 3:
            let wasPoweredDown = isPoweredDown
            controlArticulationAmplitude = value
            if isPoweredDown {
                requestAsserted = false
                cyclesUntilRequest = nil
            } else if wasPoweredDown {
                selectTimingMode()
                beginPhoneme()
            }
        default:
            // The SSI-263 decodes register-address bit two only, so 4...7
            // all select the filter-frequency attribute register.
            filterFrequency = value
        }
    }

    mutating func advance(by cycles: Int) {
        guard cycles > 0, !isPoweredDown, var remaining = cyclesUntilRequest else { return }
        remaining -= cycles
        while remaining <= 0 {
            requestAsserted = true
            remaining += requestPeriodCycles
        }
        cyclesUntilRequest = remaining
    }

    private var isPoweredDown: Bool {
        controlArticulationAmplitude & 0x80 != 0
    }

    private var requestPeriodCycles: Int {
        // SSI-263 frame timing is 4096 clock periods times (16 - R), where
        // R is the speech-rate nibble.  In phoneme timing modes DR1:DR0
        // extends that frame by (4 - D); frame mode requests every frame.
        let rate = Int(rateInflection >> 4)
        let frame = Self.frameCycles * max(1, 16 - rate)
        switch timingMode {
        case .frameImmediate:
            return frame
        case .phonemeImmediate:
            return frame * 2
        case .phonemeTransitioned:
            return frame
        }
    }

    private mutating func selectTimingMode() {
        switch durationPhoneme >> 6 {
        case 3:
            timingMode = .phonemeTransitioned
            interruptsEnabled = true
        case 2:
            timingMode = .phonemeImmediate
            interruptsEnabled = true
        case 1:
            timingMode = .frameImmediate
            interruptsEnabled = true
        default:
            // DR1:DR0 == 00 only disables the A/R output; it retains the
            // most recently selected timing response.
            interruptsEnabled = false
        }
    }

    private mutating func beginPhoneme() {
        cyclesUntilRequest = requestPeriodCycles
    }
}
