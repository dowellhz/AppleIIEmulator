import XCTest
@testable import AppleIIEmulator

final class ROMLoadingTests: XCTestCase {
    func testCustomAppleIIPlusROMMapsAtD000() throws {
        var rom = [UInt8](repeating: 0, count: 0x3000)
        rom[0] = 0xA9
        rom[0x2FFF] = 0xD0
        let memory = AppleIIMemory()
        try memory.loadCustomROM(Data(rom))
        XCTAssertEqual(memory.model, .appleIIPlus)
        XCTAssertEqual(memory.read(0xD000), 0xA9)
        XCTAssertEqual(memory.read(0xFFFF), 0xD0)
    }

    func testCustom16KBIIcROMMirrorsBothBanks() throws {
        var rom = [UInt8](repeating: 0, count: 0x4000)
        rom[0x0100] = 0x42
        let memory = AppleIIMemory()
        try memory.loadCustomROM(Data(rom))
        XCTAssertEqual(memory.model, .appleIIc)
        XCTAssertEqual(memory.read(0xC100), 0x42)
        _ = memory.read(0xC028)
        XCTAssertEqual(memory.read(0xC100), 0x42)
    }

    func testCustomROMRejectsUnsupportedLength() {
        XCTAssertThrowsError(try AppleIIMemory().loadCustomROM(Data(repeating: 0, count: 0x2000)))
    }

    func testBundledProductivitySoftwareUsesAnAppleIIeROM() {
        for software in AppleIIMachine.BundledSoftware.allCases {
            XCTAssertTrue([.appleIIeEnhanced, .appleIIeUnenhanced].contains(software.bootROM), software.title)
        }
        XCTAssertEqual(AppleIIMachine.BundledSoftware.systemUtilities32.bootROM, .appleIIeUnenhanced)
        XCTAssertEqual(AppleIIMachine.BundledSoftware.applePascal13Boot.bootROM, .appleIIeEnhanced)
    }

    @MainActor
    func testApplePascalBootLoadsFromItsBundledDSK() throws {
        let memory = AppleIIMemory()
        try memory.loadBundledAppleIIeROM(.appleIIeEnhanced)
        let url = try XCTUnwrap(AppResources.bundle.url(forResource: "Apple Pascal 1.3 APPLE1 Boot", withExtension: "dsk"))
        try memory.mountDiskImageData(Data(contentsOf: url), fileExtension: "dsk")
        let cpu = MOS6502(bus: memory)
        cpu.reset()
        cpu.run(cycles: 25_000_000)
        let video = memory.makeVideoSnapshot()
        XCTAssertTrue(video.column80)
        XCTAssertTrue(video.alternateCharset)
        XCTAssertGreaterThan(memory.diskNibbleReads, 100_000)
        XCTAssertGreaterThanOrEqual(cpu.pc, 0xC000)
        XCTAssertTrue(cpu.unsupportedOpcodes.isEmpty)
        let firstRow = (0..<80).map { video.textByte(column: $0, row: 0) }
        XCTAssertTrue(stride(from: 0, to: 80, by: 2).contains { firstRow[$0] != 0 && firstRow[$0] != 0xA0 })
        XCTAssertTrue(stride(from: 1, to: 80, by: 2).contains { firstRow[$0] != 0 && firstRow[$0] != 0xA0 })
    }

    @MainActor
    func testApplePascalMountsItsStandardTwoDriveStartupSet() {
        let machine = AppleIIMachine()
        machine.loadBundledSoftware(.applePascal13Boot)

        XCTAssertTrue(machine.hasDisk(in: 0))
        XCTAssertTrue(machine.hasDisk(in: 1))
        XCTAssertEqual(machine.diskDescription, "Apple Pascal 1.3 启动盘（APPLE1）")
        XCTAssertEqual(machine.externalDiskDescription, "Apple Pascal 1.3 工具盘（APPLE2）")
    }

    func testBundledAppleIIeROMsMapSystemAndSlotSixROM() throws {
        for choice in [
            AppleIIMachine.BootROM.appleIIeEnhanced,
            .appleIIeUnenhanced,
            .appleIIeCF
        ] {
            let memory = AppleIIMemory()
            try memory.loadBundledAppleIIeROM(choice)
            XCTAssertEqual(memory.model, .appleIIe, choice.title)
            // All supplied IIe revisions reset through their motherboard ROM.
            XCTAssertEqual(memory.read(0xFFFC), 0x62, choice.title)
            XCTAssertEqual(memory.read(0xFFFD), 0xFA, choice.title)
            // Slot 6 remains visible by default, overlaying the IIe ROM.
            XCTAssertEqual(memory.read(0xC600), 0xA2, choice.title)
        }
    }

    func testEnhancedAppleIIeBootsSlotSixDSK() throws {
        let memory = AppleIIMemory()
        try memory.loadBundledAppleIIeROM(.appleIIeEnhanced)
        try memory.mountDSK(DiskII.diagnosticDSK())
        let cpu = MOS6502(bus: memory)
        cpu.reset()
        cpu.run(cycles: 5_000_000)
        let text = (0..<24).map { row in
            String((0..<40).map { memory.textByte(column: $0, row: row) & 0x7F }.map(UnicodeScalar.init).map(Character.init))
        }.joined(separator: "|")
        XCTAssertTrue(cpu.unsupportedOpcodes.isEmpty)
        XCTAssertGreaterThan(memory.diskNibbleReads, 0)
        XCTAssertTrue(text.contains("DISK BOOT OK"), text)
    }

    func testEnhancedAppleIIePowerOnBannerUsesSevenBitText() throws {
        let memory = AppleIIMemory()
        try memory.loadBundledAppleIIeROM(.appleIIeEnhanced)
        let cpu = MOS6502(bus: memory)
        cpu.reset()
        cpu.run(cycles: 2_000_000)

        let video = memory.makeVideoSnapshot()
        XCTAssertTrue(video.usesSevenBitASCII)
        let row = (0..<40).map { column -> String in
            let cell = appleIITextCell(
                byte: video.textByte(column: column, row: 0),
                alternateCharset: video.alternateCharset,
                flashOn: true,
                supportsMouseText: video.supportsMouseText,
                usesSevenBitASCII: video.usesSevenBitASCII
            )
            switch cell {
            case let .normal(value), let .inverse(value):
                return String(UnicodeScalar(value < 0x20 ? value + 0x40 : value))
            case let .alternate(value), let .alternateInverse(value):
                return value < 0x20 ? "•" : String(UnicodeScalar(value))
            case let .ascii(value):
                return value >= 0x20 ? String(UnicodeScalar(value)) : " "
            }
        }.joined()
        XCTAssertTrue(row.contains("Apple //e"), row)
    }

    func testAppleIIeAuxiliaryMemorySoftSwitches() throws {
        let memory = AppleIIMemory()
        try memory.loadBundledAppleIIeROM(.appleIIeEnhanced)
        XCTAssertEqual(memory.read(0xC015), 0x00)
        _ = memory.read(0xC007)
        XCTAssertEqual(memory.read(0xC015), 0x80)
        _ = memory.read(0xC080)
        XCTAssertEqual(memory.read(0xC012), 0x80)
        _ = memory.read(0xC082)
        XCTAssertEqual(memory.read(0xC012), 0x00)
        memory.write(0x0200, 0x11)
        _ = memory.read(0xC005) // RAMWRT on
        memory.write(0x0200, 0x22)
        _ = memory.read(0xC002) // RAMRD main
        XCTAssertEqual(memory.read(0x0200), 0x11)
        _ = memory.read(0xC003) // RAMRD auxiliary
        XCTAssertEqual(memory.read(0x0200), 0x22)

        // RAMRD/RAMWRT must not move the CPU's zero page or stack; that is
        // exclusively controlled by ALTZP.
        memory.write(0x008C, 0x33)
        _ = memory.read(0xC009) // ALTZP on
        memory.write(0x008C, 0x44)
        _ = memory.read(0xC008) // ALTZP off
        XCTAssertEqual(memory.read(0x008C), 0x33)
        _ = memory.read(0xC009)
        XCTAssertEqual(memory.read(0x008C), 0x44)
    }

    func testEnhancedAppleIIeClearsWordPerfectATINITStage() throws {
        let memory = AppleIIMemory()
        try memory.loadBundledAppleIIeROM(.appleIIeEnhanced)
        guard let url = AppResources.bundle.url(forResource: "WordPerfect 1.1 IIe-IIc", withExtension: "dsk") else {
            throw CocoaError(.fileNoSuchFile)
        }
        try memory.mountDiskImage(at: url)
        let cpu = MOS6502(bus: memory)
        cpu.reset()
        cpu.run(cycles: 20_000_000)
        let text = (0..<24).map { row in
            String((0..<80).map { memory.textByte(column: $0, row: row) & 0x7F }.map(UnicodeScalar.init).map(Character.init))
        }.joined(separator: "|")
        XCTAssertTrue(cpu.unsupportedOpcodes.isEmpty)
        XCTAssertGreaterThan(memory.diskNibbleReads, 0)
        XCTAssertTrue(cpu.hasExecutedRAMInstruction)
        XCTAssertTrue(memory.videoState.column80)
        XCTAssertTrue(text.contains("WordPerfect"), text)
        XCTAssertFalse(text.contains("UNABLE TO LOAD PRODOS"), text)
        XCTAssertFalse(text.contains("UNABLE TO LOAD ATINIT FILE"), text)
    }

    func testWordPerfectInitialReturnDoesNotTriggerSystemDeath() throws {
        let memory = AppleIIMemory()
        try memory.loadBundledAppleIIeROM(.appleIIeEnhanced)
        let url = try XCTUnwrap(AppResources.bundle.url(forResource: "WordPerfect 1.1 IIe-IIc", withExtension: "dsk"))
        try memory.mountDiskImage(at: url)
        let workDiskURL = try XCTUnwrap(AppResources.bundle.url(forResource: "WordPerfect 1.1 Work Disk", withExtension: "dsk"))
        try memory.mountDiskImage(at: workDiskURL, drive: 1)
        let cpu = MOS6502(bus: memory)
        cpu.reset()
        cpu.run(cycles: 20_000_000)
        memory.latchKey(0x8D) // Return, with keyboard strobe set.
        cpu.run(cycles: 10_000_000)
        let text = (0..<24).map { row in
            String((0..<80).map { memory.textByte(column: $0, row: row) & 0x7F }.map(UnicodeScalar.init).map(Character.init))
        }.joined(separator: "|")
        XCTAssertTrue(cpu.unsupportedOpcodes.isEmpty)
        XCTAssertTrue(memory.videoState.column80)
        XCTAssertTrue(text.contains("WordPerfect"), text)
        XCTAssertFalse(text.contains("INSERT SYSTEM DISK AND RESTART"), text)
    }

    func testSystemUtilitiesUsesTheStandardCharsetForItsMenuHighlight() throws {
        let memory = AppleIIMemory()
        try memory.loadBundledAppleIIeROM(.appleIIeUnenhanced)
        let url = try XCTUnwrap(AppResources.bundle.url(forResource: "Apple II System Utilities 3.2", withExtension: "dsk"))
        try memory.mountDiskImage(at: url)
        let cpu = MOS6502(bus: memory)
        cpu.reset()
        cpu.run(cycles: 20_000_000)

        XCTAssertTrue(memory.videoState.column80)
        XCTAssertFalse(memory.videoState.supportsMouseText)
    }

    @MainActor
    func testWordPerfectMountsItsWorkDiskInDriveTwo() {
        let machine = AppleIIMachine()
        machine.loadBundledSoftware(.wordPerfect11)
        // Production mounting reads the bundled media away from the main
        // actor.  Give the execution queue a run-loop turn rather than
        // racing the two drive assertions against that legitimate I/O.
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, !(machine.hasDisk(in: 0) && machine.hasDisk(in: 1)) {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(machine.hasDisk(in: 0))
        XCTAssertTrue(machine.hasDisk(in: 1))
    }

}
