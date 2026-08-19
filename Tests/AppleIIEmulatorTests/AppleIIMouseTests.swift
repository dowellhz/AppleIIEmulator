import XCTest
@testable import AppleIIEmulator

final class AppleIIMouseTests: XCTestCase {
    func testIIcMousePIAReadsRelativeHostMotionAndAssertsIRQ() {
        let memory = AppleIIMemory()
        memory.loadROM(Data(repeating: 0, count: 0x8000))
        configureMousePIA(memory)

        sendMouseCommand(0x03, memory: memory) // mouse on + movement IRQ
        memory.moveMouse(deltaX: 0x34, deltaY: 0x12)
        XCTAssertTrue(memory.irqPending)

        sendMouseCommand(0x10, memory: memory) // READMOUSE
        makeMousePortAInput(memory)
        XCTAssertEqual(memory.read(0xC0C0), 0x34)
        memory.write(0xC0C2, 0x10) // PB4 rising edge
        memory.write(0xC0C2, 0x00) // PB4 falling edge: next response byte
        XCTAssertEqual(memory.read(0xC0C0), 0x00)
        memory.write(0xC0C2, 0x10)
        memory.write(0xC0C2, 0x00)
        XCTAssertEqual(memory.read(0xC0C0), 0x12)
    }

    func testMousePIAIsOnlyPresentOnIIc() {
        let memory = AppleIIMemory()
        memory.loadROM(Data(repeating: 0, count: 0x3000))
        // Slot-4 addresses remain ordinary expansion-space bytes on an II+;
        // they must not activate the IIc's integrated mouse IRQ source.
        memory.write(0xC0C1, 0x04)
        memory.write(0xC0C0, 0xFF)
        memory.moveMouse(deltaX: 20, deltaY: 10)
        XCTAssertFalse(memory.irqPending)
    }

    func testIIcMouseButtonTransitionRaisesConfiguredIRQ() {
        let memory = AppleIIMemory()
        memory.loadROM(Data(repeating: 0, count: 0x8000))
        configureMousePIA(memory)
        sendMouseCommand(0x05, memory: memory) // mouse on + button IRQ

        memory.setMouseButton(0, pressed: true)
        XCTAssertTrue(memory.irqPending)
        sendMouseCommand(0x20, memory: memory) // SERVE clears asserted reason
        XCTAssertFalse(memory.irqPending)
        memory.setMouseButton(0, pressed: false)
        XCTAssertTrue(memory.irqPending)
    }

    private func configureMousePIA(_ memory: AppleIIMemory) {
        memory.write(0xC0C1, 0x00) // CRA: select DDRA
        memory.write(0xC0C0, 0xFF)
        memory.write(0xC0C3, 0x00) // CRB: select DDRB
        memory.write(0xC0C2, 0x30) // PB4/PB5 outputs are controller strobes
        memory.write(0xC0C1, 0x04) // CRA: select port A data register
        memory.write(0xC0C3, 0x04) // CRB: select port B data register
    }

    private func makeMousePortAInput(_ memory: AppleIIMemory) {
        memory.write(0xC0C1, 0x00)
        memory.write(0xC0C0, 0x00)
        memory.write(0xC0C1, 0x04)
    }

    private func sendMouseCommand(_ command: UInt8, memory: AppleIIMemory) {
        memory.write(0xC0C0, command)
        memory.write(0xC0C2, 0x20) // PB5 high
        memory.write(0xC0C2, 0x00) // PB5 falling edge clocks command
    }
}
