import XCTest
@testable import AppleIIEmulator

final class LanguageCardTests: XCTestCase {
    func testAppleIIPlusLanguageCardSuppliesBanked64KRAM() throws {
        let memory = AppleIIMemory()
        try memory.loadCustomROM(Data(repeating: 0xEA, count: 0x3000))

        // Bank 2 RAM at $D000 and the shared high 8 KB. C083 selects RAM
        // reads and is a write-enable switch: the first access arms writes,
        // and the second one actually enables them.
        _ = memory.read(0xC083)
        _ = memory.read(0xC083)
        memory.write(0xD000, 0x22)
        memory.write(0xE000, 0x44)

        // Switch to bank 1: its $D000 RAM must be independent, while $E000
        // remains the shared half of the 16 KB card.
        _ = memory.read(0xC08B)
        _ = memory.read(0xC08B)
        memory.write(0xD000, 0x11)
        memory.write(0xE000, 0x55)
        XCTAssertEqual(memory.read(0xD000), 0x11)
        XCTAssertEqual(memory.read(0xE000), 0x55)

        _ = memory.read(0xC080)
        XCTAssertEqual(memory.read(0xD000), 0x22)
        XCTAssertEqual(memory.read(0xE000), 0x55)

        // C082 restores ROM reads and clears write enable.
        _ = memory.read(0xC082)
        XCTAssertEqual(memory.read(0xD000), 0xEA)
        memory.write(0xD000, 0x99)
        _ = memory.read(0xC080)
        XCTAssertEqual(memory.read(0xD000), 0x22)
    }

    func testLanguageCardMirrorsKeepTheirOriginalBankSelection() throws {
        let memory = AppleIIMemory()
        try memory.loadCustomROM(Data(repeating: 0xEA, count: 0x3000))

        // $C084-$C087 repeat the bank-2 controls, not the bank-1 controls.
        _ = memory.read(0xC087)
        _ = memory.read(0xC087)
        memory.write(0xD000, 0x22)

        _ = memory.read(0xC08B)
        _ = memory.read(0xC08B)
        memory.write(0xD000, 0x11)

        _ = memory.read(0xC084)
        XCTAssertEqual(memory.read(0xD000), 0x22)
        _ = memory.read(0xC08C)
        XCTAssertEqual(memory.read(0xD000), 0x11)
    }

    func testLanguageCardSoftSwitchReadAndWriteModesMatchHardwareTable() throws {
        let memory = AppleIIMemory()
        try memory.loadCustomROM(Data(repeating: 0xEA, count: 0x3000))

        // C081 is deliberately a ROM-read, write-enable access. It must not
        // expose the RAM written through C083, even after its second access.
        _ = memory.read(0xC083)
        _ = memory.read(0xC083)
        memory.write(0xD000, 0x42)
        _ = memory.read(0xC081)
        _ = memory.read(0xC081)
        XCTAssertEqual(memory.read(0xD000), 0xEA)
        memory.write(0xD000, 0x24)

        _ = memory.read(0xC080)
        XCTAssertEqual(memory.read(0xD000), 0x24)

        // $C088-$C08F mirrors the same four bank/mode combinations.
        _ = memory.read(0xC08F)
        _ = memory.read(0xC08F)
        memory.write(0xD000, 0x66)
        _ = memory.read(0xC08C)
        XCTAssertEqual(memory.read(0xD000), 0x66)
    }

    func testAppleIIeAlternateZeroPageSelectsAuxiliaryLanguageCard() throws {
        let memory = AppleIIMemory()
        try memory.loadBundledAppleIIeROM(.appleIIeEnhanced)

        _ = memory.read(0xC083)
        _ = memory.read(0xC083)
        memory.write(0xD000, 0x11)

        _ = memory.read(0xC009) // ALTZP: select auxiliary language-card RAM.
        _ = memory.read(0xC083)
        _ = memory.read(0xC083)
        memory.write(0xD000, 0x22)
        XCTAssertEqual(memory.read(0xD000), 0x22)

        _ = memory.read(0xC008)
        XCTAssertEqual(memory.read(0xD000), 0x11)
    }

    @MainActor
    func testCopyIIPlusBootsPast64KRequirement() {
        let machine = AppleIIMachine()
        machine.loadBundledSoftware(.copyIIPlus55)
        machine.runForVerification(cycles: 5_000_000)

        let text = (0..<24).map { row in
            String((0..<40).map { machine.memory.textByte(column: $0, row: row) & 0x7F }
                .map(UnicodeScalar.init).map(Character.init))
        }.joined(separator: "|")
        XCTAssertFalse(text.contains("YOU NEED AT LEAST 64K"), text)
        XCTAssertTrue(machine.hasExecutedRAMCode)
    }

}
