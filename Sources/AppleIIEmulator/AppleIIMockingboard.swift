import Foundation

/// The original Mockingboard uses one 6522 VIA in each of slots 4 and 5,
/// each driving an AY-3-8913.  This deliberately keeps the card at its real
/// I/O addresses instead of treating music as a UI-side audio effect.
final class MockingboardController {
    private static let sampleRate = 44_100.0
    private static let cyclesPerSecond = 1_021_800.0
    private static let ayClock = 1_021_800.0

    private struct VIA6522 {
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
    }

    private struct AYChip {
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

    private struct AudioChip {
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

    private struct AudioEvent {
        let cycle: Int
        let registers: [[UInt8]]
    }

    private var vias = [VIA6522(), VIA6522()]
    private var chips = [AYChip(), AYChip()]
    private var events = [AudioEvent(cycle: 0, registers: [[UInt8](repeating: 0, count: 16), [UInt8](repeating: 0, count: 16)])]
    private var nextEvent = 0
    private var renderCycle = 0.0
    private var audioChips = [AudioChip(), AudioChip()]

    var irqPending: Bool { vias.contains { $0.irqPending } }

    func reset() {
        vias.indices.forEach { vias[$0].reset() }
        chips.indices.forEach { chips[$0].reset() }
        events = [AudioEvent(cycle: 0, registers: chips.map(\.registers))]
        nextEvent = 0
        renderCycle = 0
        audioChips = [AudioChip(), AudioChip()]
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
        let index = address & 0x10 == 0 ? 0 : 1
        let register = address & 0x0F
        if let value {
            let affectsPSG = vias[index].write(value, register: register)
            if affectsPSG {
                let via = vias[index]
                if via.orb & 0x04 == 0 {
                    chips[index].reset()
                    appendAudioEvent(at: cycle)
                } else if chips[index].update(portA: via.ora, portB: via.orb) {
                    appendAudioEvent(at: cycle)
                }
            }
            return 0
        }
        return vias[index].read(register, portAInput: chips[index].portAInput())
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
            let left = audioChips[0].nextSample()
            let right = audioChips[1].nextSample()
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
}
