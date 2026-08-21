import XCTest
@testable import AppleIIEmulator

final class DebuggerTests: XCTestCase {
    func testSingleInstructionUsesTheNormalBusCyclePath() {
        let memory = AppleIIMemory()
        memory.write(0x0200, 0xA9) // LDA #$42
        memory.write(0x0201, 0x42)
        memory.write(0x0202, 0x8D) // STA $C030
        memory.write(0x0203, 0x30)
        memory.write(0x0204, 0xC0)
        let cpu = MOS6502(bus: memory)
        cpu.start(at: 0x0200)

        XCTAssertEqual(cpu.runOneInstruction(), 2)
        XCTAssertEqual(cpu.debugSnapshot.a, 0x42)
        XCTAssertEqual(cpu.debugSnapshot.pc, 0x0202)
        XCTAssertEqual(cpu.runOneInstruction(), 4)
        XCTAssertEqual(memory.speakerFlips, 1)
        XCTAssertEqual(cpu.debugSnapshot.pc, 0x0205)
    }

    @MainActor
    func testQuickStateRestoresMemory() {
        let suiteName = "AppleIIEmulator.DebuggerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let machine = AppleIIMachine(defaults: defaults, startsRuntimeTimer: false)
        machine.memory.write(0x0400, 0x11)
        machine.saveQuickState()
        machine.memory.write(0x0400, 0x22)

        machine.restoreQuickState()

        XCTAssertTrue(machine.hasQuickState)
        XCTAssertEqual(machine.memory.read(0x0400), 0x11)
        XCTAssertTrue(machine.status.hasPrefix("已恢复快速状态"))
    }

    func testCoreStateSnapshotRestoresCPUAndBusSideEffects() {
        let memory = AppleIIMemory()
        memory.write(0x0200, 0xA9) // LDA #$7E
        memory.write(0x0201, 0x7E)
        memory.write(0x0202, 0x8D) // STA $C030
        memory.write(0x0203, 0x30)
        memory.write(0x0204, 0xC0)
        let cpu = MOS6502(bus: memory)
        cpu.start(at: 0x0200)
        let cpuState = cpu.snapshot()
        let memoryState = memory.snapshot()

        _ = cpu.runOneInstruction()
        _ = cpu.runOneInstruction()
        memory.write(0x0400, 0x55)
        XCTAssertEqual(memory.speakerFlips, 1)

        memory.restore(memoryState)
        cpu.restore(cpuState)
        XCTAssertEqual(cpu.debugSnapshot.pc, 0x0200)
        XCTAssertEqual(memory.read(0x0400), 0)
        XCTAssertEqual(memory.speakerFlips, 0)
        _ = cpu.runOneInstruction()
        _ = cpu.runOneInstruction()
        XCTAssertEqual(memory.speakerFlips, 1)
    }
}
