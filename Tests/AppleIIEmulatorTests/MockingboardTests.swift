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

    func testPhasorNativeDeviceSelectAddressesAllFourAYChips() {
        let memory = AppleIIMemory()
        _ = memory.read(0xC0C5) // device select: Phasor-native mode (101)
        XCTAssertEqual(memory.mockingboardAYClockScale, 2)

        writePhasorAY(memory, base: 0xC0C0, chipSelect: 0x01, register: 8, value: 0x0C)
        writePhasorAY(memory, base: 0xC0D0, chipSelect: 0x02, register: 8, value: 0x0A)

        XCTAssertEqual(memory.mockingboardRegisterValue(chip: 0, register: 8), 0)
        XCTAssertEqual(memory.mockingboardRegisterValue(chip: 1, register: 8), 0x0C)
        XCTAssertEqual(memory.mockingboardRegisterValue(chip: 2, register: 8), 0x0A)
        XCTAssertEqual(memory.mockingboardRegisterValue(chip: 3, register: 8), 0)

        _ = memory.read(0xC0C8) // reset Device Select back to Mockingboard mode
        XCTAssertEqual(memory.mockingboardAYClockScale, 1)
    }

    func testPhasorNativeSecondVIAProducesCycleClockedAudio() {
        let memory = AppleIIMemory()
        _ = memory.read(0xC0C5)
        let base: UInt16 = 0xC0D0
        writePhasorAY(memory, base: base, chipSelect: 0x02, register: 0, value: 0x08)
        writePhasorAY(memory, base: base, chipSelect: 0x02, register: 1, value: 0x00)
        writePhasorAY(memory, base: base, chipSelect: 0x02, register: 7, value: 0x3E)
        writePhasorAY(memory, base: base, chipSelect: 0x02, register: 8, value: 0x0F)

        let samples = memory.renderMockingboardAudio(toEmulatedCycle: 2_000)
        XCTAssertFalse(samples.isEmpty)
        XCTAssertTrue(samples.contains { abs($0) > 0.01 })
    }

    func testPhasorNativeAY2LatchAlsoSetsAY1RegisterAddress() {
        let memory = AppleIIMemory()
        _ = memory.read(0xC0C5)

        memory.write(0xC0C1, 3)
        memory.write(0xC0C0, 0x0F) // AY2 LATCH; native GAL also latches AY1
        memory.write(0xC0C0, 0x0C)
        memory.write(0xC0C1, 0x0E)
        memory.write(0xC0C0, 0x16) // AY1 WRITE
        memory.write(0xC0C0, 0x14)

        XCTAssertEqual(memory.mockingboardRegisterValue(chip: 0, register: 3), 0x0E)
        XCTAssertEqual(memory.mockingboardRegisterValue(chip: 1, register: 3), 0)
    }

    func testEchoPlusMapsItsMirroredCardPageToTheSecondVIAPair() {
        let memory = AppleIIMemory()
        _ = memory.read(0xC0C2) // Echo+ device-select encoding

        writePhasorAY(memory, base: 0xC400, chipSelect: 0x01, register: 8, value: 0x0D)
        writePhasorAY(memory, base: 0xC4F0, chipSelect: 0x02, register: 8, value: 0x0B)

        XCTAssertEqual(memory.mockingboardRegisterValue(chip: 0, register: 8), 0)
        XCTAssertEqual(memory.mockingboardRegisterValue(chip: 1, register: 8), 0)
        XCTAssertEqual(memory.mockingboardRegisterValue(chip: 2, register: 8), 0x0B)
        XCTAssertEqual(memory.mockingboardRegisterValue(chip: 3, register: 8), 0x0D)
    }

    func testPhasorNativeSSI263DrivesRequestLineAndIRQFromCycles() {
        let memory = AppleIIMemory()
        _ = memory.read(0xC0C5) // Phasor-native mode
        configureSSI263(memory, base: 0xC440, durationPhoneme: 0xC2, rate: 0xF0)

        XCTAssertEqual(memory.mockingboardSpeechRegisterValue(chip: 1, register: 0), 0xC2)
        memory.advanceVideoClock(by: 4_095)
        XCTAssertEqual(memory.read(0xC440) & 0x80, 0)
        XCTAssertFalse(memory.irqPending)
        memory.advanceVideoClock(by: 1)
        XCTAssertEqual(memory.read(0xC440) & 0x80, 0x80)
        XCTAssertTrue(memory.irqPending)

        memory.write(0xC440, 0xC3) // attribute write acknowledges A/R
        XCTAssertEqual(memory.read(0xC440) & 0x80, 0)
        XCTAssertFalse(memory.irqPending)
    }

    func testMockingboardSpeechRequestsCA1Interrupt() {
        let memory = AppleIIMemory()
        memory.write(0xC0DE, 0x82) // enable VIA B CA1 (the primary SSI-263 socket)
        configureSSI263(memory, base: 0xC440, durationPhoneme: 0xC2, rate: 0xF0)
        memory.advanceVideoClock(by: 4_096)

        XCTAssertEqual(memory.read(0xC0DD) & 0x82, 0x82)
        _ = memory.read(0xC0D1) // VIA ORA acknowledgement clears CA1
        XCTAssertEqual(memory.read(0xC0DD) & 0x02, 0)
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

    func testVIAShiftRegisterRaisesIRQAfterPhi2Transfer() {
        let memory = AppleIIMemory()
        memory.write(0xC0CB, 0x18) // ACR: shift out under phi2
        memory.write(0xC0CE, 0x84) // IER: enable shift-register interrupt
        memory.write(0xC0CA, 0xA5)
        memory.advanceVideoClock(by: 8)
        XCTAssertEqual(memory.read(0xC0CD) & 0x84, 0x84)
        _ = memory.read(0xC0CA)
        XCTAssertEqual(memory.read(0xC0CD) & 0x04, 0)
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

    private func writePhasorAY(
        _ memory: AppleIIMemory, base: UInt16, chipSelect: UInt8, register: UInt8, value: UInt8
    ) {
        let select = (chipSelect & 0x03) << 3
        memory.write(base + 1, register)
        memory.write(base, select | 0x07) // BDIR=1, BC1=1: latch
        memory.write(base, select | 0x04) // inactive
        memory.write(base + 1, value)
        memory.write(base, select | 0x06) // BDIR=1, BC1=0: write
        memory.write(base, select | 0x04) // inactive
    }

    private func configureSSI263(
        _ memory: AppleIIMemory, base: UInt16, durationPhoneme: UInt8, rate: UInt8
    ) {
        memory.write(base, durationPhoneme)
        memory.write(base + 2, rate)
        memory.write(base + 3, 0x80) // enter power-down / standby
        memory.write(base + 3, 0x00) // CTL high-to-low starts the selected phoneme mode
    }
}
