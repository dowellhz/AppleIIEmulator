import Foundation

/// 65C02 instruction-level core. It deliberately models the processor
/// separately from Apple II hardware, allowing the same core to be exercised
/// with conformance ROMs and a simple test bus.
final class MOS6502: @unchecked Sendable {
    private let bus: AppleIIBus
    private(set) var a: UInt8 = 0
    private(set) var x: UInt8 = 0
    private(set) var y: UInt8 = 0
    private(set) var sp: UInt8 = 0xFD
    private(set) var pc: UInt16 = 0
    private(set) var p: UInt8 = 0x24
    private(set) var totalCycles = 0
    private(set) var lastOpcode: UInt8 = 0
    private(set) var lastInstructionAddress: UInt16 = 0
    private(set) var unsupportedOpcodes = Set<UInt8>()
    private(set) var lastUnsupportedInstructionAddress: UInt16 = 0
    private(set) var recentInstructions = [(UInt16, UInt8)]()
    private(set) var firstUnsupportedTrace = [(UInt16, UInt8)]()
    private(set) var hasExecutedRAMInstruction = false
    private var waitingForInterrupt = false
    private var stopped = false
    private var cyclePenalty = 0
    // Bus accesses within one instruction occur on distinct 6502 cycles.
    // Most software does not notice the distinction, but speaker PWM does:
    // its $C030 edge must be stamped at the access cycle, not at opcode fetch.
    private var instructionBusCycle = 0
    /// Number of instruction cycles already handed to the hardware while the
    /// current instruction is executing.  Disk II loaders poll $C0Ex in very
    /// tight loops, so deferring every device clock until instruction end
    /// shifts those accesses by several 6502 cycles and loses bit cells.
    private var advancedBusCycles = 0

    private let carry: UInt8 = 0x01, zero: UInt8 = 0x02, interrupt: UInt8 = 0x04
    private let decimal: UInt8 = 0x08, brk: UInt8 = 0x10, unused: UInt8 = 0x20
    private let overflow: UInt8 = 0x40, negative: UInt8 = 0x80

    private enum Mode { case immediate, zeroPage, zeroPageX, zeroPageY, absolute, absoluteX, absoluteY, indexedIndirect, indirectIndexed, zeroPageIndirect }

    init(bus: AppleIIBus) { self.bus = bus }

    func reset() {
        a = 0; x = 0; y = 0; sp = 0xFD; p = unused | interrupt
        pc = word(at: 0xFFFC)
        waitingForInterrupt = false
        stopped = false
        hasExecutedRAMInstruction = false
    }

    func start(at address: UInt16, x registerX: UInt8? = nil) {
        pc = address
        if let registerX { x = registerX }
    }


    func run(cycles budget: Int) {
        var elapsed = 0
        while elapsed < budget {
            let cost = step()
            elapsed += cost
            totalCycles += cost
            finishInstructionBusCycles(total: cost)
            if bus.irqPending {
                let cyclesBeforeIRQ = totalCycles
                irq()
                elapsed += totalCycles - cyclesBeforeIRQ
            }
        }
    }

    /// Assert the maskable interrupt input.  The IIc currently uses this for
    /// peripherals only; keeping it in the CPU rather than faking a BRK is
    /// essential for firmware that distinguishes the stacked B flag.
    func irq() {
        waitingForInterrupt = false
        guard !stopped, !flag(interrupt) else { return }
        beginInstructionBusTiming()
        bus.setSpeakerCycle(totalCycles)
        push(UInt8(truncatingIfNeeded: pc >> 8))
        push(UInt8(truncatingIfNeeded: pc))
        push((p | unused) & ~brk)
        set(interrupt, true)
        pc = word(at: 0xFFFE)
        totalCycles += 7
        finishInstructionBusCycles(total: 7)
    }

    /// Assert the non-maskable interrupt input.
    func nmi() {
        waitingForInterrupt = false
        guard !stopped else { return }
        beginInstructionBusTiming()
        bus.setSpeakerCycle(totalCycles)
        push(UInt8(truncatingIfNeeded: pc >> 8))
        push(UInt8(truncatingIfNeeded: pc))
        push((p | unused) & ~brk)
        set(interrupt, true)
        pc = word(at: 0xFFFA)
        totalCycles += 7
        finishInstructionBusCycles(total: 7)
    }

    @discardableResult
    func step() -> Int {
        guard !stopped, !waitingForInterrupt else { return 1 }
        cyclePenalty = 0
        beginInstructionBusTiming()
        lastInstructionAddress = pc
        if lastInstructionAddress < 0xC000 { hasExecutedRAMInstruction = true }
        let opcode = fetch()
        lastOpcode = opcode
        recentInstructions.append((lastInstructionAddress, opcode))
        if recentInstructions.count > 24 { recentInstructions.removeFirst() }
        switch opcode {
        // Arithmetic and logical read instructions.
        case 0x01, 0x05, 0x09, 0x0D, 0x11, 0x15, 0x19, 0x1D: a |= value(mode(for: opcode)); setZN(a)
        case 0x21, 0x25, 0x29, 0x2D, 0x31, 0x35, 0x39, 0x3D: a &= value(mode(for: opcode)); setZN(a)
        case 0x41, 0x45, 0x49, 0x4D, 0x51, 0x55, 0x59, 0x5D: a ^= value(mode(for: opcode)); setZN(a)
        case 0x61, 0x65, 0x69, 0x6D, 0x71, 0x75, 0x79, 0x7D: adc(value(mode(for: opcode)))
        case 0xE1, 0xE5, 0xE9, 0xED, 0xF1, 0xF5, 0xF9, 0xFD: sbc(value(mode(for: opcode)))
        case 0xA1, 0xA5, 0xA9, 0xAD, 0xB1, 0xB5, 0xB9, 0xBD: a = value(mode(for: opcode)); setZN(a)
        case 0xA2, 0xA6, 0xAE, 0xB6, 0xBE: x = value(mode(for: opcode)); setZN(x)
        case 0xA0, 0xA4, 0xAC, 0xB4, 0xBC: y = value(mode(for: opcode)); setZN(y)
        case 0xC1, 0xC5, 0xC9, 0xCD, 0xD1, 0xD5, 0xD9, 0xDD: compare(a, value(mode(for: opcode)))
        case 0xE0, 0xE4, 0xEC: compare(x, value(mode(for: opcode)))
        case 0xC0, 0xC4, 0xCC: compare(y, value(mode(for: opcode)))

        // Stores.
        case 0x81, 0x85, 0x8D, 0x91, 0x95, 0x99, 0x9D: write(address(mode(for: opcode)), a)
        case 0x86, 0x8E, 0x96: write(address(mode(for: opcode)), x)
        case 0x84, 0x8C, 0x94: write(address(mode(for: opcode)), y)

        // Shifts and rotates.
        case 0x0A: a = asl(a)
        case 0x06, 0x0E, 0x16, 0x1E: modify(mode(for: opcode), asl)
        case 0x2A: a = rol(a)
        case 0x26, 0x2E, 0x36, 0x3E: modify(mode(for: opcode), rol)
        case 0x4A: a = lsr(a)
        case 0x46, 0x4E, 0x56, 0x5E: modify(mode(for: opcode), lsr)
        case 0x6A: a = ror(a)
        case 0x66, 0x6E, 0x76, 0x7E: modify(mode(for: opcode), ror)
        case 0xC6, 0xCE, 0xD6, 0xDE: modify(mode(for: opcode), dec)
        case 0xE6, 0xEE, 0xF6, 0xFE: modify(mode(for: opcode), inc)

        // Branches.
        case 0x10: branch(!flag(negative))
        case 0x30: branch(flag(negative))
        case 0x50: branch(!flag(overflow))
        case 0x70: branch(flag(overflow))
        case 0x90: branch(!flag(carry))
        case 0xB0: branch(flag(carry))
        case 0xD0: branch(!flag(zero))
        case 0xF0: branch(flag(zero))

        // Control flow and stack.
        case 0x00: // BRK: vector through IRQ while preserving the break marker.
            _ = fetch(); push(UInt8((pc >> 8) & 0xFF)); push(UInt8(pc & 0xFF)); push(p | brk | unused); set(interrupt, true); pc = word(at: 0xFFFE)
        case 0x20:
            let target = fetchWord()
            let returnAddress = pc &- 1
            push(UInt8(truncatingIfNeeded: returnAddress >> 8))
            push(UInt8(truncatingIfNeeded: returnAddress))
            pc = target
        case 0x40: p = (pop() | unused) & ~brk; let lo = pop(); let hi = pop(); pc = UInt16(lo) | UInt16(hi) << 8
        case 0x60: let lo = pop(); let hi = pop(); pc = (UInt16(lo) | UInt16(hi) << 8) &+ 1
        case 0x4C: pc = fetchWord()
        case 0x6C: pc = indirectWord(fetchWord())
        case 0x48: push(a)
        case 0x68: a = pop(); setZN(a)
        case 0x08: push(p | brk | unused)
        case 0x28: p = (pop() | unused) & ~brk

        // Register and flag operations.
        case 0x18: set(carry, false)
        case 0x38: set(carry, true)
        case 0x58: set(interrupt, false)
        case 0x78: set(interrupt, true)
        case 0xB8: set(overflow, false)
        case 0xD8: set(decimal, false)
        case 0xF8: set(decimal, true)
        case 0x88: y &-= 1; setZN(y)
        case 0xC8: y &+= 1; setZN(y)
        case 0xCA: x &-= 1; setZN(x)
        case 0xE8: x &+= 1; setZN(x)
        case 0x8A: a = x; setZN(a)
        case 0x98: a = y; setZN(a)
        case 0xAA: x = a; setZN(x)
        case 0xA8: y = a; setZN(y)
        case 0xBA: x = sp; setZN(x)
        case 0x9A: sp = x
        case 0x24, 0x2C: let v = value(mode(for: opcode)); set(zero, a & v == 0); set(negative, v & 0x80 != 0); set(overflow, v & 0x40 != 0)
        case 0xEA: break

        // WDC 65C02 additions used by Apple IIc firmware.
        case 0x80: branch(true) // BRA
        case 0x89: set(zero, a & fetch() == 0) // BIT #imm does not alter N/V
        case 0x34, 0x3C: let v = value(mode(for: opcode)); set(zero, a & v == 0); set(negative, v & 0x80 != 0); set(overflow, v & 0x40 != 0)
        case 0x64, 0x74, 0x9C, 0x9E: write(address(mode(for: opcode)), 0) // STZ
        case 0x1A: a = inc(a)
        case 0x3A: a = dec(a)
        case 0x5A: push(y)
        case 0x7A: y = pop(); setZN(y)
        case 0xDA: push(x)
        case 0xFA: x = pop(); setZN(x)
        case 0x7C: pc = word(at: fetchWord() &+ UInt16(x)) // JMP (abs,X)
        case 0x04, 0x0C: let address = address(mode(for: opcode)); let v = read(address); set(zero, a & v == 0); write(address, v | a) // TSB
        case 0x14, 0x1C: let address = address(mode(for: opcode)); let v = read(address); set(zero, a & v == 0); write(address, v & ~a) // TRB
        case 0x12, 0x32, 0x52, 0x72: // ORA/AND/EOR/ADC (zp)
            let v = value(.zeroPageIndirect)
            switch opcode { case 0x12: a |= v; setZN(a); case 0x32: a &= v; setZN(a); case 0x52: a ^= v; setZN(a); default: adc(v) }
        case 0x92: write(address(.zeroPageIndirect), a) // STA (zp)
        case 0xB2: a = value(.zeroPageIndirect); setZN(a) // LDA (zp)
        case 0xD2: compare(a, value(.zeroPageIndirect)) // CMP (zp)
        case 0xF2: sbc(value(.zeroPageIndirect)) // SBC (zp)
        case 0xCB: waitingForInterrupt = true // WAI
        case 0xDB: stopped = true // STP; only reset restarts it
        // Rockwell/WDC bit instructions, present in the IIc's 65C02.
        case 0x07, 0x17, 0x27, 0x37, 0x47, 0x57, 0x67, 0x77: // RMB n,zp
            let bit = UInt8(1 << (opcode >> 4))
            let address = UInt16(fetch())
            write(address, read(address) & ~bit)
        case 0x87, 0x97, 0xA7, 0xB7, 0xC7, 0xD7, 0xE7, 0xF7: // SMB n,zp
            let bit = UInt8(1 << ((opcode >> 4) & 0x07))
            let address = UInt16(fetch())
            write(address, read(address) | bit)
        case 0x0F, 0x1F, 0x2F, 0x3F, 0x4F, 0x5F, 0x6F, 0x7F: // BBR n,zp,rel
            let bit = UInt8(1 << (opcode >> 4))
            let address = UInt16(fetch())
            branch(read(address) & bit == 0)
        case 0x8F, 0x9F, 0xAF, 0xBF, 0xCF, 0xDF, 0xEF, 0xFF: // BBS n,zp,rel
            let bit = UInt8(1 << ((opcode >> 4) & 0x07))
            let address = UInt16(fetch())
            branch(read(address) & bit != 0)

        // Stable undocumented NMOS 6502 composite operations.  Early Apple
        // II games use these in their compact loaders; a 65C02 would not
        // define them, but the Apple II+ compatibility motherboard does.
        case 0x03: // SLO (zp,X): ASL then ORA
            let address = address(.indexedIndirect)
            let result = asl(read(address))
            write(address, result)
            a |= result
            setZN(a)
        case 0x33: // RLA (zp),Y: ROL then AND
            let address = address(.indirectIndexed)
            let result = rol(read(address))
            write(address, result)
            a &= result
            setZN(a)
        case 0xFB: // ISC abs,Y: INC then SBC
            let address = address(.absoluteY)
            let result = inc(read(address))
            write(address, result)
            sbc(result)

        // The WDC 65C02 documents these operand-consuming NOP encodings.
        // Keeping their operands (and their timing below) matters because
        // loader code occasionally uses them as compact delay slots.
        case 0x02, 0x22, 0x42, 0x62, 0x82, 0xC2, 0xE2: _ = fetch()
        case 0x44: _ = fetch()
        case 0x54, 0xD4, 0xF4: _ = fetch()
        case 0x5C, 0xDC, 0xFC: _ = fetchWord()

        // The 65C02 replaces the NMOS processor's unused x3/xB encodings
        // with one-byte, one-cycle NOPs.  Apple IIe software (including the
        // compact Prince of Persia loader) deliberately uses them as delay
        // slots.  Treating them as the generic two-cycle fallback shifts the
        // disk/video timing and eventually turns following data into code.
        case 0x0B, 0x1B, 0x2B, 0x3B, 0x4B, 0x5B, 0x6B, 0x7B,
             0x8B, 0x9B, 0xAB, 0xBB, 0xEB,
             0x13, 0x23, 0x43, 0x53, 0x63, 0x73, 0x83, 0x93,
             0xA3, 0xB3, 0xC3, 0xD3, 0xE3, 0xF3:
            break
        default:
            if firstUnsupportedTrace.isEmpty { firstUnsupportedTrace = recentInstructions }
            unsupportedOpcodes.insert(opcode)
            lastUnsupportedInstructionAddress = lastInstructionAddress
            break // unsupported illegal opcode behaves as a one-byte NOP
        }
        return baseCycles(for: opcode) + cyclePenalty
    }

    private func mode(for opcode: UInt8) -> Mode {
        switch opcode {
        case 0x01,0x21,0x41,0x61,0x81,0xA1,0xC1,0xE1: return .indexedIndirect
        case 0x05,0x25,0x45,0x65,0x85,0xA5,0xC5,0xE5,0xA4,0xA6,0xC4,0xE4,0x24,0x06,0x26,0x46,0x66,0xC6,0xE6,0x04,0x14,0x64,0x84,0x86: return .zeroPage
        case 0x09,0x29,0x49,0x69,0xA9,0xA2,0xA0,0xC9,0xE9,0xC0,0xE0: return .immediate
        case 0x0D,0x2D,0x4D,0x6D,0x8D,0xAD,0xAE,0xAC,0xCD,0xED,0xCC,0xEC,0x2C,0x0E,0x2E,0x4E,0x6E,0xCE,0xEE,0x8C,0x8E,0x0C,0x9C: return .absolute
        case 0x11,0x31,0x51,0x71,0x91,0xB1,0xD1,0xF1: return .indirectIndexed
        case 0x15,0x35,0x55,0x75,0x95,0xB5,0xD5,0xF5,0xB4,0x94,0x16,0x36,0x56,0x76,0xD6,0xF6,0x34,0x74: return .zeroPageX
        case 0x19,0x39,0x59,0x79,0x99,0xB9,0xD9,0xF9,0xBE: return .absoluteY
        case 0x1D,0x3D,0x5D,0x7D,0x9D,0xBD,0xBC,0xDD,0xFD,0x1E,0x3E,0x5E,0x7E,0xDE,0xFE,0x1C,0x3C,0x9E: return .absoluteX
        case 0x96,0xB6: return .zeroPageY
        default: return .immediate
        }
    }

    private func value(_ mode: Mode) -> UInt8 { mode == .immediate ? fetch() : read(address(mode)) }
    private func address(_ mode: Mode) -> UInt16 {
        switch mode {
        case .zeroPage: return UInt16(fetch())
        case .zeroPageX: return UInt16(fetch() &+ x)
        case .zeroPageY: return UInt16(fetch() &+ y)
        case .absolute: return fetchWord()
        case .absoluteX:
            let base = fetchWord()
            let result = base &+ UInt16(x)
            if pageCrossed(base, result), indexedReadAddsCycle(lastOpcode) { cyclePenalty += 1 }
            return result
        case .absoluteY:
            let base = fetchWord()
            let result = base &+ UInt16(y)
            if pageCrossed(base, result), indexedReadAddsCycle(lastOpcode) { cyclePenalty += 1 }
            return result
        case .indexedIndirect: let zp = fetch() &+ x; return UInt16(read(UInt16(zp))) | UInt16(read(UInt16(zp &+ 1))) << 8
        case .indirectIndexed:
            let zp = fetch()
            let base = UInt16(read(UInt16(zp))) | UInt16(read(UInt16(zp &+ 1))) << 8
            let result = base &+ UInt16(y)
            if pageCrossed(base, result), indexedReadAddsCycle(lastOpcode) { cyclePenalty += 1 }
            return result
        case .zeroPageIndirect: let zp = fetch(); return UInt16(read(UInt16(zp))) | UInt16(read(UInt16(zp &+ 1))) << 8
        case .immediate: return pc
        }
    }
    private func modify(_ mode: Mode, _ transform: (UInt8) -> UInt8) { let a = address(mode); write(a, transform(read(a))) }
    private func read(_ a: UInt16) -> UInt8 {
        advanceHardwareToCurrentBusAccess()
        return bus.read(a)
    }

    private func write(_ a: UInt16, _ v: UInt8) {
        advanceHardwareToCurrentBusAccess()
        bus.write(a, v)
    }

    private func beginInstructionBusTiming() {
        instructionBusCycle = 0
        advancedBusCycles = 0
    }

    /// Advances devices to the exact cycle of this memory transaction.  The
    /// instruction model intentionally stays separate from the bus, but this
    /// makes I/O effects observable at their access cycle rather than after
    /// the instruction's remaining internal cycles have elapsed.
    private func advanceHardwareToCurrentBusAccess() {
        let accessCycle = instructionBusCycle
        if accessCycle > advancedBusCycles {
            bus.advanceVideoClock(by: accessCycle - advancedBusCycles)
            advancedBusCycles = accessCycle
        }
        bus.setSpeakerCycle(totalCycles + accessCycle)
        instructionBusCycle += 1
    }

    private func finishInstructionBusCycles(total cost: Int) {
        guard cost > advancedBusCycles else { return }
        bus.advanceVideoClock(by: cost - advancedBusCycles)
        advancedBusCycles = cost
    }
    private func fetch() -> UInt8 { defer { pc &+= 1 }; return read(pc) }
    private func fetchWord() -> UInt16 { let lo = fetch(); return UInt16(lo) | UInt16(fetch()) << 8 }
    private func word(at a: UInt16) -> UInt16 { UInt16(read(a)) | UInt16(read(a &+ 1)) << 8 }
    /// Unlike the original NMOS 6502, the 65C02 does *not* wrap the high-byte
    /// fetch within a page for `JMP ($xxFF)`.  IIc code may rely on this
    /// corrected silicon behaviour, especially in compact dispatch tables.
    private func indirectWord(_ a: UInt16) -> UInt16 { word(at: a) }
    private func push(_ v: UInt8) { write(0x0100 | UInt16(sp), v); sp &-= 1 }
    private func pop() -> UInt8 { sp &+= 1; return read(0x0100 | UInt16(sp)) }
    private func flag(_ bit: UInt8) -> Bool { p & bit != 0 }
    private func set(_ bit: UInt8, _ on: Bool) { p = on ? p | bit : p & ~bit }
    private func setZN(_ v: UInt8) { set(zero, v == 0); set(negative, v & 0x80 != 0) }
    private func asl(_ v: UInt8) -> UInt8 { set(carry, v & 0x80 != 0); let r = v << 1; setZN(r); return r }
    private func lsr(_ v: UInt8) -> UInt8 { set(carry, v & 1 != 0); let r = v >> 1; setZN(r); return r }
    private func rol(_ v: UInt8) -> UInt8 { let c: UInt8 = flag(carry) ? 1 : 0; set(carry, v & 0x80 != 0); let r = (v << 1) | c; setZN(r); return r }
    private func ror(_ v: UInt8) -> UInt8 { let c: UInt8 = flag(carry) ? 0x80 : 0; set(carry, v & 1 != 0); let r = (v >> 1) | c; setZN(r); return r }
    private func inc(_ v: UInt8) -> UInt8 { let r = v &+ 1; setZN(r); return r }
    private func dec(_ v: UInt8) -> UInt8 { let r = v &- 1; setZN(r); return r }
    private func compare(_ lhs: UInt8, _ rhs: UInt8) { let r = lhs &- rhs; set(carry, lhs >= rhs); setZN(r) }
    private func branch(_ condition: Bool) {
        let offset = Int8(bitPattern: fetch())
        guard condition else { return }
        let before = pc
        pc = UInt16(bitPattern: Int16(bitPattern: pc) &+ Int16(offset))
        cyclePenalty += 1
        if before & 0xFF00 != pc & 0xFF00 { cyclePenalty += 1 }
    }

    private func pageCrossed(_ lhs: UInt16, _ rhs: UInt16) -> Bool { lhs & 0xFF00 != rhs & 0xFF00 }

    private func indexedReadAddsCycle(_ opcode: UInt8) -> Bool {
        switch opcode {
        case 0x11, 0x19, 0x1D, 0x31, 0x39, 0x3D, 0x51, 0x59, 0x5D,
             0x71, 0x79, 0x7D, 0xB1, 0xB9, 0xBC, 0xBD, 0xBE,
             0xD1, 0xD9, 0xDD, 0xF1, 0xF9, 0xFD, 0x3C:
            return true
        default: return false
        }
    }

    /// Base WDC 65C02 timing in CPU cycles.  Indexed read page-cross penalties
    /// are intentionally added only where branch timing matters today; the
    /// table still gives the scheduler and video clock real instruction-scale
    /// time rather than treating every opcode as a two-cycle NOP.
    private func baseCycles(for opcode: UInt8) -> Int {
        switch opcode {
        case 0x00: return 7
        case 0x01, 0x21, 0x41, 0x61, 0x81, 0xA1, 0xC1, 0xE1: return 6
        case 0x05, 0x25, 0x45, 0x65, 0x85, 0xA5, 0xA4, 0xA6, 0xC5, 0xC4, 0xE4, 0x24: return 3
        case 0x06, 0x26, 0x46, 0x66, 0xC6, 0xE6: return 5
        case 0x08, 0x48, 0x5A, 0xDA: return 3
        case 0x28, 0x68, 0x7A, 0xFA: return 4
        case 0x09, 0x29, 0x49, 0x69, 0x89, 0xA9, 0xA2, 0xA0, 0xC9, 0xE9, 0xC0, 0xE0: return 2
        case 0x0A, 0x2A, 0x4A, 0x6A, 0x1A, 0x3A: return 2
        case 0x0C, 0x1C: return 6
        case 0x0D, 0x2D, 0x4D, 0x6D, 0x8D, 0xAD, 0xAE, 0xAC, 0xCD, 0xED, 0xCC, 0xEC, 0x2C: return 4
        case 0x0E, 0x2E, 0x4E, 0x6E, 0xCE, 0xEE: return 6
        case 0x10, 0x30, 0x50, 0x70, 0x80, 0x90, 0xB0, 0xD0, 0xF0: return 2
        case 0x11, 0x31, 0x51, 0x71, 0xB1, 0xD1, 0xF1: return 5
        case 0x12, 0x32, 0x52, 0x72, 0x92, 0xB2, 0xD2, 0xF2: return 5
        case 0x14, 0x04: return 5
        case 0x15, 0x35, 0x55, 0x75, 0x95, 0xB5, 0xB4, 0x94, 0xD5, 0xF5, 0x34: return 4
        case 0x16, 0x36, 0x56, 0x76, 0xD6, 0xF6: return 6
        case 0x19, 0x39, 0x59, 0x79, 0xB9, 0xD9, 0xF9, 0xBE: return 4
        case 0x1D, 0x3D, 0x5D, 0x7D, 0xBD, 0xBC, 0xDD, 0xFD, 0x3C: return 4
        case 0x1E, 0x3E, 0x5E, 0x7E, 0xDE, 0xFE: return 7
        // WDC/Rockwell bit memory operations and bit branches.  Branch() adds
        // the documented taken/page-cross penalties to BBR/BBS below.
        case 0x07, 0x17, 0x27, 0x37, 0x47, 0x57, 0x67, 0x77,
             0x87, 0x97, 0xA7, 0xB7, 0xC7, 0xD7, 0xE7, 0xF7:
            return 5
        case 0x0F, 0x1F, 0x2F, 0x3F, 0x4F, 0x5F, 0x6F, 0x7F,
             0x8F, 0x9F, 0xAF, 0xBF, 0xCF, 0xDF, 0xEF, 0xFF:
            return 5
        case 0x20: return 6
        case 0x40, 0x60: return 6
        case 0x4C: return 3
        case 0x6C: return 5
        case 0x7C: return 6
        case 0x44: return 3
        case 0x54, 0xD4, 0xF4: return 4
        case 0x5C: return 8
        case 0xDC, 0xFC: return 4
        case 0x64: return 3
        case 0x74: return 4
        case 0x9C: return 4
        case 0x9E: return 5
        case 0x91: return 6
        case 0x99, 0x9D: return 5
        case 0x84, 0x86: return 3
        case 0x8C, 0x8E: return 4
        case 0x96: return 4
        case 0xA8, 0xAA, 0x8A, 0x98, 0xBA, 0x9A, 0x88, 0xC8, 0xCA, 0xE8, 0x18, 0x38, 0x58, 0x78, 0xB8, 0xD8, 0xF8, 0xEA: return 2
        case 0xCB, 0xDB: return 3
        case 0x0B, 0x1B, 0x2B, 0x3B, 0x4B, 0x5B, 0x6B, 0x7B,
             0x8B, 0x9B, 0xAB, 0xBB, 0xEB,
             0x13, 0x23, 0x43, 0x53, 0x63, 0x73, 0x83, 0x93,
             0xA3, 0xB3, 0xC3, 0xD3, 0xE3, 0xF3:
            return 1
        default: return 2
        }
    }

    private func adc(_ value: UInt8) {
        let c: UInt16 = flag(carry) ? 1 : 0
        let sum = UInt16(a) + UInt16(value) + c
        let binary = UInt8(truncatingIfNeeded: sum)
        set(overflow, ~(a ^ value) & (a ^ binary) & 0x80 != 0)
        if flag(decimal) {
            var lo = (a & 0x0F) + (value & 0x0F) + UInt8(c)
            var hi = (a >> 4) + (value >> 4)
            if lo > 9 { lo &+= 6; hi &+= 1 }
            set(carry, hi > 9)
            if hi > 9 { hi &+= 6 }
            a = (hi << 4) | (lo & 0x0F)
        } else { set(carry, sum > 0xFF); a = binary }
        setZN(a)
    }
    private func sbc(_ value: UInt8) {
        let borrow = flag(carry) ? 0 : 1
        let difference = Int(a) - Int(value) - borrow
        let binary = UInt8(truncatingIfNeeded: difference)
        set(overflow, (a ^ binary) & (a ^ value) & 0x80 != 0)
        set(carry, difference >= 0)
        if flag(decimal) {
            var low = Int(a & 0x0F) - Int(value & 0x0F) - borrow
            var high = Int(a >> 4) - Int(value >> 4)
            if low < 0 { low -= 6; high -= 1 }
            if high < 0 { high -= 6 }
            a = UInt8(truncatingIfNeeded: (high << 4) | (low & 0x0F))
        } else {
            a = binary
        }
        setZN(a)
    }
}
