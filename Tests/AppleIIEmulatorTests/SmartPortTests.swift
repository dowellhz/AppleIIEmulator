import XCTest
@testable import AppleIIEmulator

final class SmartPortTests: XCTestCase {
    func testSmartPortReadsAndWritesA512ByteBlockThroughSlotSeven() throws {
        let memory = AppleIIMemory()
        var image = [UInt8](repeating: 0, count: SmartPortController.blockSize * 2)
        for index in 0..<SmartPortController.blockSize { image[SmartPortController.blockSize + index] = UInt8(truncatingIfNeeded: index) }
        try memory.mountHardDiskImageData(Data(image), fileExtension: "hdv")

        // ProDOS block read: C0F2..C0F7 set command, unit, RAM buffer and
        // block number; a read of C0F0 executes at that bus cycle.
        memory.write(0xC0F2, 0x01)
        memory.write(0xC0F3, 0x70) // slot 7, drive 1
        memory.write(0xC0F4, 0x00)
        memory.write(0xC0F5, 0x08)
        memory.write(0xC0F6, 0x01)
        memory.write(0xC0F7, 0x00)
        _ = memory.read(0xC0F0)
        XCTAssertEqual(memory.read(0x0800), 0x00)
        XCTAssertEqual(memory.read(0x08FF), 0xFF)

        memory.write(0x0800, 0xA5)
        memory.write(0xC0F2, 0x02)
        _ = memory.read(0xC0F0)
        XCTAssertEqual(memory.hardDiskImage()?[SmartPortController.blockSize], 0xA5)
    }

    func testSmartPortControllerStatusReportsAttachedDevices() throws {
        let memory = AppleIIMemory()
        try memory.mountHardDiskImageData(Data(repeating: 0, count: SmartPortController.blockSize), fileExtension: "po")
        memory.write(0xC0F2, 0x80)
        memory.write(0xC0F3, 0x00) // SmartPort controller unit
        memory.write(0xC0F4, 0x00)
        memory.write(0xC0F5, 0x09)
        memory.write(0xC0F6, 0x00)
        _ = memory.read(0xC0F0)
        XCTAssertEqual(memory.read(0x0900), 1)
    }

    func testSlotSevenROMLoadsBlockZeroBeforeEnteringIt() throws {
        let memory = AppleIIMemory()
        memory.loadROM(Data(repeating: 0, count: 0x3000)) // Apple II+
        var image = [UInt8](repeating: 0xEA, count: SmartPortController.blockSize)
        image[0] = 0xA9 // LDA #$42, proves execution transferred into RAM
        image[1] = 0x42
        try memory.mountHardDiskImageData(Data(image), fileExtension: "hdv")
        let cpu = MOS6502(bus: memory)
        cpu.start(at: 0xC700)
        cpu.run(cycles: 80)
        XCTAssertEqual(memory.read(0x0800), 0xA9)
        XCTAssertEqual(cpu.a, 0x42)
        XCTAssertGreaterThanOrEqual(cpu.pc, 0x0802)
    }
}
