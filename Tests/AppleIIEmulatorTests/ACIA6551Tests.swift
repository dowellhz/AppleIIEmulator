import XCTest
import Darwin
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

    func testMacSerialBridgeTransfersBytesThroughAPseudoTerminal() throws {
        var master: Int32 = -1
        var slave: Int32 = -1
        XCTAssertEqual(openpty(&master, &slave, nil, nil, nil), 0)
        defer {
            if master >= 0 { Darwin.close(master) }
            if slave >= 0 { Darwin.close(slave) }
        }
        guard let deviceName = ttyname(slave) else {
            return XCTFail("openpty did not provide a slave device name")
        }
        let path = String(cString: deviceName)
        let bridge = MacSerialBridge()
        let connected = expectation(description: "bridge connected")
        let inbound = expectation(description: "host bytes reached bridge")
        inbound.expectedFulfillmentCount = 2
        let outbound = expectation(description: "bridge bytes reached host")

        bridge.didChangeConnection = { port, connectedPath in
            if port == 1, connectedPath == path { connected.fulfill() }
        }
        bridge.didReceiveByte = { byte, port in
            if port == 1, [0x41, 0x42].contains(byte) { inbound.fulfill() }
        }

        let hostRead = DispatchSource.makeReadSource(fileDescriptor: master, queue: .global())
        hostRead.setEventHandler {
            var bytes = [UInt8](repeating: 0, count: 16)
            let count = bytes.withUnsafeMutableBytes { Darwin.read(master, $0.baseAddress, $0.count) }
            if count > 0, Array(bytes.prefix(Int(count))).contains(0x5A) {
                outbound.fulfill()
            }
        }
        hostRead.resume()
        defer { hostRead.cancel() }

        bridge.connect(path: path, port: 1, baudRate: 9_600)
        wait(for: [connected], timeout: 2)

        let hostBytes: [UInt8] = [0x41, 0x42]
        let written = hostBytes.withUnsafeBytes { Darwin.write(master, $0.baseAddress, $0.count) }
        XCTAssertEqual(written, hostBytes.count)
        wait(for: [inbound], timeout: 2)

        bridge.send([0x5A], port: 1)
        wait(for: [outbound], timeout: 2)
        bridge.disconnect(port: 1)
    }
}
