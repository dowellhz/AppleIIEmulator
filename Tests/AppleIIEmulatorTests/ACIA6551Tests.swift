import XCTest
@testable import AppleIIEmulator

final class ACIA6551Tests: XCTestCase {
    func testIIcSerialPort1TransmitsOnCPUCycleClock() {
        let memory = AppleIIMemory()
        memory.loadROM(Data(repeating: 0, count: 0x8000))
        memory.write(0xC09B, 0x0E) // 9600 baud
        memory.write(0xC09A, 0x04) // transmitter enabled
        memory.write(0xC098, 0x41)
        XCTAssertEqual(memory.read(0xC099) & 0x10, 0)

        memory.advanceVideoClock(by: 1_065)
        XCTAssertEqual(memory.read(0xC099) & 0x10, 0x10)
        XCTAssertEqual(memory.drainTransmittedSerialBytes(port: 1), [0x41])
    }

    func testIIcSerialPort2ReceiveRegisterAndIRQ() {
        let memory = AppleIIMemory()
        memory.loadROM(Data(repeating: 0, count: 0x8000))
        memory.write(0xC0AA, 0x02) // receiver interrupt enable
        memory.receiveSerialByte(0x5A, port: 2)
        XCTAssertEqual(memory.read(0xC0A9) & 0x88, 0x88)
        XCTAssertEqual(memory.read(0xC0A8), 0x5A)
        XCTAssertEqual(memory.read(0xC0A9) & 0x08, 0)
    }

    func testIIcSerialPortReportsConfiguredHostBaudRate() {
        let memory = AppleIIMemory()
        memory.loadROM(Data(repeating: 0, count: 0x8000))

        XCTAssertEqual(memory.serialBaudRate(port: 1), 9_600)
        memory.write(0xC09B, 0x0D)
        XCTAssertEqual(memory.serialBaudRate(port: 1), 7_200)
        memory.write(0xC0AB, 0x0F)
        XCTAssertEqual(memory.serialBaudRate(port: 2), 19_200)
    }

    func testAppleIIPlusDoesNotExposeIIcACIARegisters() {
        let memory = AppleIIMemory()
        memory.loadROM(Data(repeating: 0, count: 0x3000))
        memory.write(0xC09A, 0x04)
        memory.write(0xC098, 0x41)
        memory.advanceVideoClock(by: 2_000)
        XCTAssertEqual(memory.drainTransmittedSerialBytes(port: 1), [])
    }

    func testIIcSerialReceiveInterruptUses6502IRQVector() {
        var rom = [UInt8](repeating: 0, count: 0x8000)
        rom[0x3FFE] = 0x00 // IRQ vector: $0900
        rom[0x3FFF] = 0x09
        let memory = AppleIIMemory()
        memory.loadROM(Data(rom))
        memory.write(0x0800, 0x58) // CLI
        let cpu = MOS6502(bus: memory)
        cpu.start(at: 0x0800)

        memory.write(0xC0AA, 0x02) // receiver interrupt enable, port 2
        memory.receiveSerialByte(0x42, port: 2)
        cpu.run(cycles: 2)
        XCTAssertEqual(cpu.pc, 0x0900)
    }
}
