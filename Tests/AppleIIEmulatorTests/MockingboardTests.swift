import XCTest
@testable import AppleIIEmulator

final class MockingboardTests: XCTestCase {
    func testSlotFourLatchesWritesAndReadsAYRegister() {
        let memory = AppleIIMemory()
        writeAY(memory, base: 0xC0C0, register: 8, value: 0x1F)
        XCTAssertEqual(memory.mockingboardRegisterValue(chip: 0, register: 8), 0x1F)

        memory.write(0xC0C0, 0x05) // BDIR=0, BC1=1: PSG read
        XCTAssertEqual(memory.read(0xC0C1), 0x1F)
        memory.write(0xC0C0, 0x04) // return PSG bus to inactive
    }

    func testSlotFiveDrivesTheSecondAYChip() {
        let memory = AppleIIMemory()
        writeAY(memory, base: 0xC0D0, register: 0, value: 0x34)
        XCTAssertEqual(memory.mockingboardRegisterValue(chip: 1, register: 0), 0x34)
        XCTAssertEqual(memory.mockingboardRegisterValue(chip: 0, register: 0), 0)
    }

    func testVIAOneShotTimerRaisesAndClearsIRQFlag() {
        let memory = AppleIIMemory()
        memory.write(0xC0CE, 0xC0) // IER: enable Timer 1 interrupt
        memory.write(0xC0C4, 0x02)
        memory.write(0xC0C5, 0x00) // start Timer 1 at three cycles
        memory.advanceVideoClock(by: 3)
        XCTAssertEqual(memory.read(0xC0CD) & 0xC0, 0xC0)
        _ = memory.read(0xC0C4) // Timer 1 low counter read acknowledges it
        XCTAssertEqual(memory.read(0xC0CD) & 0x40, 0)
    }

    func testAYAudioIsSynthesizedFromTheCycleClock() {
        let memory = AppleIIMemory()
        writeAY(memory, base: 0xC0C0, register: 0, value: 0x08)
        writeAY(memory, base: 0xC0C0, register: 1, value: 0x00)
        writeAY(memory, base: 0xC0C0, register: 7, value: 0x3E) // channel A tone only
        writeAY(memory, base: 0xC0C0, register: 8, value: 0x0F)
        let samples = memory.renderMockingboardAudio(toEmulatedCycle: 2_000)
        XCTAssertFalse(samples.isEmpty)
        XCTAssertTrue(samples.contains { abs($0) > 0.01 })
    }

    func testAppleIIcKeepsSlotFourForItsBuiltInMouse() {
        let memory = AppleIIMemory()
        memory.loadROM(Data(repeating: 0, count: 0x8000))
        writeAY(memory, base: 0xC0C0, register: 8, value: 0x0F)
        XCTAssertEqual(memory.mockingboardRegisterValue(chip: 0, register: 8), 0)
    }

    private func writeAY(_ memory: AppleIIMemory, base: UInt16, register: UInt8, value: UInt8) {
        memory.write(base + 1, register) // VIA ORA
        memory.write(base, 0x07) // BDIR=1, BC1=1: latch register address
        memory.write(base, 0x04) // inactive
        memory.write(base + 1, value)
        memory.write(base, 0x06) // BDIR=1, BC1=0: write register
        memory.write(base, 0x04) // inactive
    }
}
