import Foundation

/// The original Mockingboard uses one 6522 VIA in each of slots 4 and 5,
/// each driving an AY-3-8913.  This deliberately keeps the card at its real
/// I/O addresses instead of treating music as a UI-side audio effect.
final class MockingboardController {
    struct State {
        fileprivate let vias: [VIA6522]
        fileprivate let chips: [AYChip]
        fileprivate let events: [AudioEvent]
        fileprivate let nextEvent: Int
        fileprivate let renderCycle: Double
        fileprivate let audioChips: [AudioChip]
        fileprivate let phasorMode: UInt8
        fileprivate init(
            vias: [VIA6522], chips: [AYChip], events: [AudioEvent], nextEvent: Int,
            renderCycle: Double, audioChips: [AudioChip], phasorMode: UInt8
        ) {
            self.vias = vias; self.chips = chips; self.events = events
            self.nextEvent = nextEvent; self.renderCycle = renderCycle; self.audioChips = audioChips
            self.phasorMode = phasorMode
        }
    }
    private static let sampleRate = 44_100.0
    private static let cyclesPerSecond = 1_021_800.0
    private static let ayClock = 1_021_800.0

    fileprivate struct VIA6522 {
        var ora: UInt8 = 0
        var orb: UInt8 = 0
        var ddra: UInt8 = 0
        var ddrb: UInt8 = 0
        var acr: UInt8 = 0
        var pcr: UInt8 = 0
        var ifr: UInt8 = 0
        var ier: UInt8 = 0
        var timer1Latch: UInt16 = 0
        var timer1Counter: Int?
        var timer2Latch: UInt16 = 0
        var timer2Counter: Int?
        var shiftRegister: UInt8 = 0
        var shiftBitsRemaining = 0
        var shiftCycles = 0

        var irqPending: Bool { ifr & ier & 0x7F != 0 }

        mutating func reset() { self = Self() }

        mutating func advance(by cycles: Int) {
            guard cycles > 0 else { return }
            let timer1Latch = timer1Latch
            let timer1Continuous = acr & 0x40 != 0
            var timer1Counter = timer1Counter
            advanceTimer(&timer1Counter, latch: timer1Latch, flag: 0x40, continuous: timer1Continuous, cycles: cycles)
            self.timer1Counter = timer1Counter
            let timer2Latch = timer2Latch
            var timer2Counter = timer2Counter
            advanceTimer(&timer2Counter, latch: timer2Latch, flag: 0x20, continuous: false, cycles: cycles)
            self.timer2Counter = timer2Counter
            advanceShiftRegister(by: cycles)
        }

        mutating func read(_ register: Int, portAInput: UInt8) -> UInt8 {
            switch register & 0x0F {
            case 0: return orb
            case 1, 15: return (ora & ddra) | (portAInput & ~ddra)
            case 2: return ddrb
            case 3: return ddra
            case 4:
                ifr &= ~0x40
                return UInt8(truncatingIfNeeded: timer1Counter ?? 0)
            case 5: return UInt8(truncatingIfNeeded: (timer1Counter ?? 0) >> 8)
            case 6: return UInt8(truncatingIfNeeded: timer1Latch)
            case 7: return UInt8(truncatingIfNeeded: timer1Latch >> 8)
            case 8:
                ifr &= ~0x20
                return UInt8(truncatingIfNeeded: timer2Counter ?? 0)
            case 9: return UInt8(truncatingIfNeeded: (timer2Counter ?? 0) >> 8)
            case 10:
                ifr &= ~0x04
                return shiftRegister
            case 11: return acr
            case 12: return pcr
            case 13: return ifr | (irqPending ? 0x80 : 0)
            case 14: return ier | 0x80
            default: return 0
            }
        }

        mutating func write(_ value: UInt8, register: Int) -> Bool {
            switch register & 0x0F {
            case 0: orb = value; return true
            case 1, 15: ora = value
            case 2: ddrb = value
            case 3: ddra = value
            case 4: timer1Latch = (timer1Latch & 0xFF00) | UInt16(value)
            case 5:
                timer1Latch = (timer1Latch & 0x00FF) | UInt16(value) << 8
                timer1Counter = Int(timer1Latch) + 1
                ifr &= ~0x40
            case 6: timer1Latch = (timer1Latch & 0xFF00) | UInt16(value)
            case 7: timer1Latch = (timer1Latch & 0x00FF) | UInt16(value) << 8
            case 8: timer2Latch = (timer2Latch & 0xFF00) | UInt16(value)
            case 9:
                timer2Latch = (timer2Latch & 0x00FF) | UInt16(value) << 8
                timer2Counter = Int(timer2Latch) + 1
                ifr &= ~0x20
            case 10:
                shiftRegister = value
                shiftBitsRemaining = 8
                shiftCycles = 0
                ifr &= ~0x04
            case 11: acr = value
            case 12: pcr = value
            case 13: ifr &= ~(value & 0x7F)
            case 14:
                if value & 0x80 != 0 { ier |= value & 0x7F }
                else { ier &= ~(value & 0x7F) }
            default: break
            }
            return false
        }

        private mutating func advanceTimer(
            _ counter: inout Int?, latch: UInt16, flag: UInt8, continuous: Bool, cycles: Int
        ) {
            guard var remaining = counter else { return }
            remaining -= cycles
            while remaining <= 0 {
                ifr |= flag
                guard continuous else {
                    counter = nil
                    return
                }
                remaining += max(1, Int(latch) + 1)
            }
            counter = remaining
        }

        private mutating func advanceShiftRegister(by cycles: Int) {
            // ACR bits 4...2 select the 6522 shift mode. External-clock
            // modes have no synthetic edge source; phi2 modes clock once per
            // CPU cycle and T2 modes clock from their programmed latch.
            let mode = (acr >> 2) & 0x07
            guard mode != 0, shiftBitsRemaining > 0 else { return }
            guard mode != 3, mode != 7 else { return }
            let period = (mode == 2 || mode == 6) ? 1 : max(1, Int(timer2Latch) + 1)
            shiftCycles += cycles
            while shiftCycles >= period, shiftBitsRemaining > 0 {
                shiftCycles -= period
                if mode >= 4 {
                    shiftRegister <<= 1 // shift-out serial data on CB2
                } else {
                    shiftRegister = (shiftRegister << 1) | 1 // idle-high CB2 input
                }
                shiftBitsRemaining -= 1
            }
            if shiftBitsRemaining == 0 { ifr |= 0x04 }
        }
    }

    fileprivate struct AYChip {
        var registers = [UInt8](repeating: 0, count: 16)
        var selectedRegister: Int?
        var busState: UInt8 = 0

        mutating func reset() { self = Self() }

        mutating func update(portA: UInt8, portB: UInt8) -> Bool {
            // BDIR/BC1 are PB1/PB0.  A PSG action is sampled only when the
            // bus leaves inactive, matching the 6522-driven board protocol.
            let nextState = portB & 0x03
            defer { busState = nextState }
            guard busState == 0 else { return false }
            switch nextState {
            case 0x03:
                selectedRegister = portA <= 0x0F ? Int(portA) : nil
            case 0x02:
                guard let selectedRegister else { return false }
                registers[selectedRegister] = Self.masked(portA, register: selectedRegister)
                return true
            default: break
            }
            return false
        }

        func portAInput() -> UInt8 {
            guard busState == 0x01, let selectedRegister else { return 0xFF }
            return registers[selectedRegister]
        }

        private static func masked(_ value: UInt8, register: Int) -> UInt8 {
            switch register {
            case 1, 3, 5: return value & 0x0F
            case 6: return value & 0x1F
            case 8...10: return value & 0x1F
            case 13: return value & 0x0F
            default: return value
            }
        }
    }

    fileprivate struct AudioChip {
        var registers = [UInt8](repeating: 0, count: 16)
        var tonePhase = [Double](repeating: 0, count: 3)
        var noisePhase = 0.0
        var noiseLFSR: UInt32 = 0x1FFFF
        var envelopePhase = 0.0
        var envelopeStep = 0

        mutating func apply(_ registers: [UInt8]) {
            if registers[13] != self.registers[13] {
                envelopePhase = 0
                envelopeStep = 0
            }
            self.registers = registers
        }

        mutating func nextSample() -> Float {
            let mixer = registers[7]
            var total = 0.0
            for channel in 0..<3 {
                let period = max(1, Int(registers[channel * 2]) | (Int(registers[channel * 2 + 1] & 0x0F) << 8))
                let increment = MockingboardController.ayClock / (16.0 * Double(period) * MockingboardController.sampleRate)
                tonePhase[channel] += increment
                if tonePhase[channel] >= 1 { tonePhase[channel] -= floor(tonePhase[channel]) }
                let toneHigh = tonePhase[channel] < 0.5
                let toneEnabled = mixer & (1 << channel) == 0
                let noiseEnabled = mixer & (1 << (channel + 3)) == 0
                let tone = !toneEnabled || toneHigh
                let noise = !noiseEnabled || (noiseLFSR & 1 != 0)
                guard tone && noise else { continue }
                let volumeRegister = registers[8 + channel]
                let volume: Double
                if volumeRegister & 0x10 != 0 {
                    volume = Double(envelopeLevel) / 15.0
                } else {
                    volume = Double(volumeRegister & 0x0F) / 15.0
                }
                total += volume
            }

            let noisePeriod = max(1, Int(registers[6] & 0x1F))
            noisePhase += MockingboardController.ayClock / (16.0 * Double(noisePeriod) * MockingboardController.sampleRate)
            while noisePhase >= 1 {
                noisePhase -= 1
                let feedback = (noiseLFSR ^ (noiseLFSR >> 3)) & 1
                noiseLFSR = (noiseLFSR >> 1) | (feedback << 16)
            }
            let envelopePeriod = max(1, Int(registers[11]) | Int(registers[12]) << 8)
            envelopePhase += MockingboardController.ayClock / (256.0 * Double(envelopePeriod) * MockingboardController.sampleRate)
            while envelopePhase >= 1 {
                envelopePhase -= 1
                envelopeStep = (envelopeStep + 1) & 31
            }
            return Float((total / 3.0) * 2.0 - 1.0)
        }

        private var envelopeLevel: Int {
            let shape = registers[13] & 0x0F
            let descending = shape & 0x04 == 0
            let saw = envelopeStep & 15
            return descending ? 15 - saw : saw
        }
    }

    fileprivate struct AudioEvent {
        let cycle: Int
        let registers: [[UInt8]]
    }

    private var vias = [VIA6522(), VIA6522()]
    // In Mockingboard mode each VIA drives one AY. Phasor-native mode uses
    // the same two VIA buses, with each one selecting a pair of AY-3-8913s.
    private var chips = [AYChip(), AYChip(), AYChip(), AYChip()]
    private var events = [AudioEvent(cycle: 0, registers: Array(repeating: [UInt8](repeating: 0, count: 16), count: 4))]
    private var nextEvent = 0
    private var renderCycle = 0.0
    private var audioChips = [AudioChip(), AudioChip(), AudioChip(), AudioChip()]
    /// The Phasor's device-select latch is controlled by the low address
    /// bits in its $C0n0 device-select window. Mode 000 remains fully
    /// Mockingboard compatible; 101 exposes both AY chips behind each VIA.
    private var phasorMode: UInt8 = 0

    var irqPending: Bool { vias.contains { $0.irqPending } }

    func snapshot() -> State {
        State(
            vias: vias, chips: chips, events: events, nextEvent: nextEvent,
            renderCycle: renderCycle, audioChips: audioChips, phasorMode: phasorMode
        )
    }

    func restore(_ state: State) {
        vias = state.vias; chips = state.chips; events = state.events
        nextEvent = state.nextEvent; renderCycle = state.renderCycle; audioChips = state.audioChips
        phasorMode = state.phasorMode
    }

    func reset() {
        vias.indices.forEach { vias[$0].reset() }
        chips.indices.forEach { chips[$0].reset() }
        events = [AudioEvent(cycle: 0, registers: chips.map(\.registers))]
        nextEvent = 0
        renderCycle = 0
        audioChips = [AudioChip(), AudioChip(), AudioChip(), AudioChip()]
        phasorMode = 0
    }

    func advance(by cycles: Int) {
        guard cycles > 0 else { return }
        vias.indices.forEach { vias[$0].advance(by: cycles) }
    }

    /// Accesses a slot-four/five Mockingboard register at the current CPU
    /// cycle. Slot 4 is the first VIA/AY, slot 5 is the second.
    func access(_ address: Int, write value: UInt8?, atCycle cycle: Int) -> UInt8 {
        // Apple II slot I/O uses the high nibble of the low address byte:
        // $C0C0-$C0CF is slot 4 and $C0D0-$C0DF is slot 5.
        updatePhasorDeviceSelect(address)
        let index = address & 0x10 == 0 ? 0 : 1
        let register = address & 0x0F
        if let value {
            let affectsPSG = vias[index].write(value, register: register)
            if affectsPSG {
                let via = vias[index]
                if via.orb & 0x04 == 0 {
                    resetPSGChips(forVIA: index)
                    appendAudioEvent(at: cycle)
                } else if updatePSGChips(forVIA: index, portA: via.ora, portB: via.orb) {
                    appendAudioEvent(at: cycle)
                }
            }
            return 0
        }
        return vias[index].read(register, portAInput: psgPortAInput(forVIA: index))
    }

    /// Generates chip PCM on the emulation thread. The audio endpoint only
    /// dequeues the mixed samples, just as it does for the one-bit speaker.
    func renderAudio(toEmulatedCycle cycle: Int) -> [Float] {
        guard cycle > Int(renderCycle) else { return [] }
        let cyclesPerSample = Self.cyclesPerSecond / Self.sampleRate
        var samples = [Float]()
        samples.reserveCapacity(Int((Double(cycle) - renderCycle) / cyclesPerSample))
        while renderCycle + cyclesPerSample <= Double(cycle) {
            while nextEvent < events.count, Double(events[nextEvent].cycle) <= renderCycle {
                let event = events[nextEvent]
                for index in audioChips.indices { audioChips[index].apply(event.registers[index]) }
                nextEvent += 1
            }
            // Phasor routes two AYs to each stereo channel. In ordinary
            // Mockingboard mode chips 2/3 stay silent, retaining the old
            // two-chip output exactly.
            let left = (audioChips[0].nextSample() + audioChips[2].nextSample()) * 0.5
            let right = (audioChips[1].nextSample() + audioChips[3].nextSample()) * 0.5
            samples.append((left + right) * 0.075)
            renderCycle += cyclesPerSample
        }
        if nextEvent > 1_024 {
            events.removeFirst(nextEvent - 1)
            nextEvent = 1
        }
        return samples
    }

    func registerValue(chip: Int, register: Int) -> UInt8? {
        guard chips.indices.contains(chip), (0..<16).contains(register) else { return nil }
        return chips[chip].registers[register]
    }

    private func appendAudioEvent(at cycle: Int) {
        let event = AudioEvent(cycle: max(0, cycle), registers: chips.map(\.registers))
        if let last = events.last, last.cycle == event.cycle {
            events[events.count - 1] = event
        } else {
            events.append(event)
        }
    }

    private func updatePhasorDeviceSelect(_ address: Int) {
        let selector = UInt8(address & 0x0F)
        if selector & 0x08 != 0 { phasorMode = 0 }
        phasorMode |= selector & 0x07
    }

    private var usesPhasorNativeAYSelection: Bool { phasorMode == 0x05 }

    private func selectedPSGChips(forVIA via: Int, portB: UInt8? = nil) -> [Int] {
        guard usesPhasorNativeAYSelection else { return [via] }
        let base = via * 2
        let chipSelect = ((portB ?? vias[via].orb) >> 3) & 0x03
        // PB3/PB4 are active-low selects for AY1/AY2. Selecting both is
        // meaningful for mirrored register setup and is sampled by both
        // chips at the same emulated bus cycle.
        switch chipSelect {
        case 0: return [base, base + 1]
        case 1: return [base + 1]
        case 2: return [base]
        default: return []
        }
    }

    private func resetPSGChips(forVIA via: Int) {
        let targets = usesPhasorNativeAYSelection ? [via * 2, via * 2 + 1] : [via]
        for target in targets { chips[target].reset() }
    }

    private func updatePSGChips(forVIA via: Int, portA: UInt8, portB: UInt8) -> Bool {
        var changed = false
        for target in selectedPSGChips(forVIA: via, portB: portB) {
            changed = chips[target].update(portA: portA, portB: portB) || changed
        }
        return changed
    }

    private func psgPortAInput(forVIA via: Int) -> UInt8 {
        selectedPSGChips(forVIA: via).reduce(UInt8.max) { $0 & chips[$1].portAInput() }
    }
}
