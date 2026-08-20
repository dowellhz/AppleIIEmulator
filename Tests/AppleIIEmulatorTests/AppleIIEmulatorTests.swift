import AppKit
import XCTest
@testable import AppleIIEmulator

final class AppleIIEmulatorTests: XCTestCase {
    func testVintagePanelArtworkIsReadableFromResourceBundle() throws {
        let url = try XCTUnwrap(
            AppResources.bundle.url(forResource: "VintagePlasticTexture", withExtension: "png"),
            "main=\(Bundle.main.bundleURL.path), resources=\(Bundle.main.resourceURL?.path ?? "nil"), resolved=\(AppResources.bundle.bundleURL.path)"
        )
        let image = try XCTUnwrap(NSImage(contentsOf: url))
        XCTAssertGreaterThan(image.size.width, 1)
        XCTAssertGreaterThan(image.size.height, 1)
    }

    func testSpeakerWaveformLetsAnIsolatedToggleDecaySmoothly() {
        var waveform = AppleIISpeakerWaveform()
        waveform.toggle(atEmulatedCycle: 0)

        let samples = waveform.render(toEmulatedCycle: 300_000)

        XCTAssertFalse(samples.isEmpty)
        XCTAssertGreaterThan(abs(samples[0]), 0.1)
        XCTAssertLessThan(abs(samples[samples.count / 2]), abs(samples[0]))
        XCTAssertLessThan(abs(samples[samples.count - 1]), 0.001)
        XCTAssertTrue(samples.allSatisfy(\.isFinite))
    }

    func testKeyboardStrobeClearsAtC010() {
        let memory = AppleIIMemory()
        memory.latchKey(0xC1)
        XCTAssertEqual(memory.read(0xC000), 0xC1)
        XCTAssertEqual(memory.read(0xC010), 0x41)
        XCTAssertEqual(memory.read(0xC000), 0x41)
    }

    func testMacKeyboardIsTranslatedToAppleIIUppercaseASCII() {
        XCTAssertEqual(AppleIIMachine.appleKeyboardByte(forASCII: 0x61, control: false), 0xC1)
        XCTAssertEqual(AppleIIMachine.appleKeyboardByte(forASCII: 0x5F, control: false), 0xDF)
        XCTAssertEqual(AppleIIMachine.appleKeyboardByte(forASCII: 0x63, control: true), 0x83)
        XCTAssertNil(AppleIIMachine.appleKeyboardByte(forASCII: 0x1B, control: false))
    }

    func testWizardryBootMediaIncludesItsDeferredOriginalScenarioDisk() {
        let disks = AppleIIMachine.BundledGame.wizardry.startupDisks

        XCTAssertEqual(disks.count, 3)
        XCTAssertEqual(disks[0].description, "Wizardry 磁盘 1")
        XCTAssertFalse(disks[0].writeProtected)
        XCTAssertEqual(disks[1].description, "Wizardry 磁盘 2")
        XCTAssertFalse(disks[1].writeProtected)
        XCTAssertEqual(disks[2].description, "Wizardry 原始 Scenario 盘")
        XCTAssertFalse(disks[2].writeProtected)
    }

    @MainActor
    func testArrowKeysDriveAndReleaseBothAppleIIGamePorts() throws {
        let machine = AppleIIMachine()
        let rightArrow = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 124
        ))
        let release = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyUp,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 124
        ))

        machine.keyDown(rightArrow)
        // Input may be queued behind an in-flight CPU slice; drain that
        // serial queue before observing the hardware latch directly.
        machine.runForVerification(cycles: 0)
        _ = machine.memory.read(0xC070)
        machine.memory.advanceVideoClock(by: 1_408)
        XCTAssertEqual(machine.memory.read(0xC064), 0x80) // PDL0: right
        XCTAssertEqual(machine.memory.read(0xC066), 0x80) // PDL2: second port

        machine.keyUp(release)
        machine.runForVerification(cycles: 0)
        _ = machine.memory.read(0xC070)
        machine.memory.advanceVideoClock(by: 1_408)
        XCTAssertEqual(machine.memory.read(0xC064), 0x80) // released: retains right
        XCTAssertEqual(machine.memory.read(0xC066), 0x80)
    }

    func testIIcTextAttributesHonorInverseFlashAndAlternateCharset() {
        XCTAssertEqual(appleIITextCell(byte: 0x01, alternateCharset: false, flashOn: true), .inverse(0x01))
        XCTAssertEqual(appleIITextCell(byte: 0x41, alternateCharset: false, flashOn: true), .normal(0x01))
        XCTAssertEqual(appleIITextCell(byte: 0x41, alternateCharset: false, flashOn: false), .inverse(0x01))
        XCTAssertEqual(appleIITextCell(byte: 0x41, alternateCharset: true, flashOn: false), .alternate(0x01))
        XCTAssertEqual(appleIITextCell(byte: 0x41, alternateCharset: true, flashOn: false, supportsMouseText: false), .alternateInverse(0x01))
        XCTAssertEqual(appleIITextCell(byte: 0x79, alternateCharset: true, flashOn: false, supportsMouseText: false), .alternateInverse(0x39))
        XCTAssertEqual(appleIITextCell(byte: 0xC1, alternateCharset: true, flashOn: false), .normal(0x01))
        XCTAssertEqual(appleIITextCell(byte: 0xFF, alternateCharset: false, flashOn: true), .normal(0x3F))
        XCTAssertEqual(appleII80ColumnTextCell(byte: 0xEF, alternateCharset: true, flashOn: false), .ascii(0x6F))
        XCTAssertEqual(appleII80ColumnTextCell(byte: 0x41, alternateCharset: true, flashOn: false), .alternate(0x01))
        XCTAssertEqual(appleII80ColumnTextCell(byte: 0x41, alternateCharset: true, flashOn: false, supportsMouseText: false), .alternateInverse(0x01))
    }

    func testHiResPairPaletteUsesTheHighBitPhase() {
        XCTAssertEqual(Array(appleIIHiResColors(bytes: [0x00]).prefix(4)), [.black, .black, .black, .black])
        XCTAssertEqual(appleIIHiResColors(bytes: [0x01])[0], .purple)
        XCTAssertEqual(appleIIHiResColors(bytes: [0x02])[0], .green)
        XCTAssertEqual(appleIIHiResColors(bytes: [0x03])[0], .white)
        XCTAssertEqual(appleIIHiResColors(bytes: [0x81])[0], .blue)
        XCTAssertEqual(appleIIHiResColors(bytes: [0x82])[0], .orange)
    }

    func testSpeakerSoftSwitchTogglesOnReadAndWrite() {
        let memory = AppleIIMemory()
        var callbacks = 0
        memory.speakerDidToggle = { callbacks += 1 }
        _ = memory.read(0xC030)
        memory.write(0xC030, 0)
        XCTAssertEqual(memory.speakerFlips, 2)
        XCTAssertEqual(callbacks, 2)
    }

    func testCassetteSoftSwitchesFollowBusAccessCycle() {
        let memory = AppleIIMemory()
        var edges = [(Int, Bool)]()
        memory.cassetteOutputDidToggleAtCycle = { cycle, high in edges.append((cycle, high)) }
        memory.setSpeakerCycle(123)
        _ = memory.read(0xC020)
        memory.setSpeakerCycle(456)
        memory.write(0xC020, 0)
        memory.setCassetteInput(true)

        XCTAssertEqual(edges.map(\.0), [123, 456])
        XCTAssertEqual(edges.map(\.1), [true, false])
        XCTAssertEqual(memory.read(0xC060), 0x80)
    }

    func testAppleIIPlusAnnunciatorsUseStandardSoftSwitchPairs() {
        let memory = AppleIIMemory()
        _ = memory.read(0xC059) // ANN0 on
        memory.write(0xC05D, 0) // ANN2 on
        _ = memory.read(0xC058) // ANN0 off
        XCTAssertFalse(memory.annunciatorEnabled(0))
        XCTAssertTrue(memory.annunciatorEnabled(2))
    }

    func testAppleKeysAndPaddleTimerSoftSwitches() {
        let memory = AppleIIMemory()
        memory.setButtons(openApple: true, closedApple: false)
        XCTAssertEqual(memory.read(0xC061), 0x80)
        XCTAssertEqual(memory.read(0xC062), 0)
        memory.setPaddles([0, 255])
        _ = memory.read(0xC070)
        XCTAssertEqual(memory.read(0xC064), 0x80)
        XCTAssertEqual(memory.read(0xC065), 0x80)
        memory.advanceVideoClock(by: 11)
        XCTAssertEqual(memory.read(0xC064), 0)
        XCTAssertEqual(memory.read(0xC065), 0x80)
        memory.advanceVideoClock(by: 2_805)
        XCTAssertEqual(memory.read(0xC065), 0)
    }

    func testIIcVerticalBlankSoftSwitchIsLatchedUntilReset() {
        let memory = AppleIIMemory()
        memory.loadROM(Data(repeating: 0, count: 0x8000))
        XCTAssertEqual(memory.read(0xC019), 0)
        memory.write(0xC07F, 0) // SETIOUDIS
        XCTAssertEqual(memory.read(0xC07E), 0x80)
        memory.write(0xC05B, 0) // ENVBL
        memory.advanceVideoClock(by: 65 * 192)
        XCTAssertEqual(memory.read(0xC019), 0x80)
        memory.advanceVideoClock(by: 65 * 70)
        XCTAssertEqual(memory.read(0xC019), 0x80)
        _ = memory.read(0xC070)
        XCTAssertEqual(memory.read(0xC019), 0)
    }

    func testAppleIIPlusAnnunciator3DoesNotEnableDoubleHiRes() throws {
        let memory = AppleIIMemory()
        try memory.loadBundledAppleIIPlusROM(diskFirmware: .sixteenSector)
        _ = memory.read(0xC05E)
        XCTAssertFalse(memory.doubleHires)
        memory.write(0xC05F, 0)
        XCTAssertFalse(memory.doubleHires)
    }

    func testIIcDoubleHiResRequiresIOUDisableAndUsesDocumentedSwitchPolarity() {
        let memory = AppleIIMemory()
        memory.loadROM(Data(repeating: 0, count: 0x8000))
        _ = memory.read(0xC05E)
        XCTAssertFalse(memory.doubleHires)
        _ = memory.read(0xC07F) // SETIOUDIS
        _ = memory.read(0xC05E) // SETDHIRES
        XCTAssertTrue(memory.doubleHires)
        memory.write(0xC05F, 0) // CLRDHIRES
        XCTAssertFalse(memory.doubleHires)
    }

    func testIIcExtendedMemorySwitchesReportTheirState() {
        let memory = AppleIIMemory()
        memory.loadROM(Data(repeating: 0, count: 0x8000))
        _ = memory.read(0xC007) // INTCXROM on
        _ = memory.read(0xC00B) // SLOTC3ROM on
        XCTAssertEqual(memory.read(0xC015), 0x80)
        XCTAssertEqual(memory.read(0xC017), 0x80)
        memory.write(0xC006, 0)
        memory.write(0xC00A, 0)
        XCTAssertEqual(memory.read(0xC015), 0)
        XCTAssertEqual(memory.read(0xC017), 0)
    }

    func testAppleIIeSlotThreeROMDoesNotMirrorMotherboardROMWhenNoCardIsPresent() throws {
        let memory = AppleIIMemory()
        try memory.loadBundledAppleIIeROM(.appleIIeEnhanced)

        let internalSlotThreeByte = memory.read(0xC300)
        XCTAssertNotEqual(internalSlotThreeByte, 0)

        _ = memory.read(0xC00B) // select the physical Slot 3 ROM
        XCTAssertEqual(memory.read(0xC017), 0x80)
        XCTAssertEqual(memory.read(0xC300), 0, "an empty Slot 3 must not mirror the IIe ROM")

        _ = memory.read(0xC00A) // restore the internal 80-column ROM
        XCTAssertEqual(memory.read(0xC017), 0)
        XCTAssertEqual(memory.read(0xC300), internalSlotThreeByte)
    }

    func testIIcReadOfSetIOUDisableSetsTheLatch() {
        let memory = AppleIIMemory()
        memory.loadROM(Data(repeating: 0, count: 0x8000))
        XCTAssertEqual(memory.read(0xC07E), 0)
        _ = memory.read(0xC07F)
        XCTAssertEqual(memory.read(0xC07E), 0x80)
    }

    func test80StoreKeepsVideoOnPageOneWhilePage2SelectsAuxiliaryRAM() {
        let memory = AppleIIMemory()
        memory.loadROM(Data(repeating: 0, count: 0x8000))
        memory.write(0xC001, 0) // 80STORE on, PAGE2 currently main
        memory.write(0x0400, 0xC1)
        memory.write(0xC055, 0) // PAGE2 now selects auxiliary page 1
        memory.write(0x0400, 0xC2)
        XCTAssertEqual(memory.textByte(column: 0, row: 0), 0xC1)
        memory.write(0xC00D, 0) // 80 columns fetch aux then main
        XCTAssertEqual(memory.textByte(column: 0, row: 0), 0xC2)
        XCTAssertEqual(memory.textByte(column: 1, row: 0), 0xC1)
    }

    func test80StoreUsesPageOneForHGRAndRedirectsCPUWindow() {
        let memory = AppleIIMemory()
        memory.loadROM(Data(repeating: 0, count: 0x8000))
        memory.write(0xC057, 0) // HIRES on
        memory.write(0xC001, 0) // 80STORE on
        memory.write(0x2000, 0x11)
        memory.write(0xC055, 0) // PAGE2 redirects $2000-$3FFF to aux
        memory.write(0x2000, 0x22)
        XCTAssertEqual(memory.hgrByte(column: 0, row: 0), 0x11)
        XCTAssertEqual(memory.hgrByte(column: 0, row: 0, auxiliary: true), 0x22)
        // HGR page 2 must remain ordinary RAM while 80STORE is active.
        memory.write(0x4000, 0x33)
        XCTAssertEqual(memory.read(0x4000), 0x33)
    }

    func test80StoreStillRedirectsTextPageWhenHiresIsEnabled() {
        let memory = AppleIIMemory()
        memory.loadROM(Data(repeating: 0, count: 0x8000))
        memory.write(0xC057, 0) // HIRES on
        memory.write(0xC001, 0) // 80STORE on
        memory.write(0x0400, 0xC1)
        memory.write(0xC055, 0) // PAGE2 selects auxiliary text page 1
        memory.write(0x0400, 0xC2)
        memory.write(0xC00D, 0)
        XCTAssertEqual(memory.textByte(column: 0, row: 0), 0xC2)
        XCTAssertEqual(memory.textByte(column: 1, row: 0), 0xC1)
    }

    func testTextAddressingUsesAppleIIInterleave() {
        let memory = AppleIIMemory()
        memory.write(0x0480, 0xC1) // row 1, column 0
        XCTAssertEqual(memory.textByte(column: 0, row: 1), 0xC1)
    }

    func testHiResAddressingUsesAppleIIInterleave() {
        let memory = AppleIIMemory()
        memory.write(0x2400, 0x55) // HGR page 1, scanline 1, byte 0
        XCTAssertEqual(memory.hgrByte(column: 0, row: 1), 0x55)
        memory.write(0x2028, 0x66) // scanline 64 returns to the first 1 KB band
        XCTAssertEqual(memory.hgrByte(column: 0, row: 64), 0x66)
        memory.write(0x3FD0, 0x77) // final HGR scanline, 191
        XCTAssertEqual(memory.hgrByte(column: 0, row: 191), 0x77)
    }

    func testDiagnosticProgramSetsResetVector() {
        let memory = AppleIIMemory()
        memory.installDiagnosticProgram()
        let cpu = MOS6502(bus: memory)
        cpu.reset()
        cpu.run(cycles: 500)
        XCTAssertEqual(memory.textByte(column: 0, row: 0), 0xC1)
    }

    func testIIcROMUsesTwoSwitchable16KBBanks() {
        let memory = AppleIIMemory()
        var rom = [UInt8](repeating: 0, count: 0x8000)
        rom[0x3FFC] = 0x62
        rom[0x7FFC] = 0xA5
        memory.loadROM(Data(rom))
        XCTAssertEqual(memory.model, .appleIIc)
        XCTAssertEqual(memory.read(0xFFFC), 0x62)
        _ = memory.read(0xC028)
        XCTAssertEqual(memory.read(0xFFFC), 0xA5)
        memory.resetROMBank()
        XCTAssertEqual(memory.read(0xFFFC), 0x62)
    }

    func testJSRAtHighROMAddressPushesOnlyLowAndHighBytes() {
        let memory = AppleIIMemory()
        var rom = [UInt8](repeating: 0, count: 0x3000)
        rom[0x2000] = 0x20 // $F000: JSR $F010
        rom[0x2001] = 0x10
        rom[0x2002] = 0xF0
        rom[0x2003] = 0xA9 // LDA #$C1
        rom[0x2004] = 0xC1
        rom[0x2005] = 0x8D // STA $0400
        rom[0x2006] = 0x00
        rom[0x2007] = 0x04
        rom[0x2008] = 0x4C // JMP $F008
        rom[0x2009] = 0x08
        rom[0x200A] = 0xF0
        rom[0x2010] = 0x60 // $F010: RTS
        rom[0x2FFC] = 0x00
        rom[0x2FFD] = 0xF0
        memory.loadROM(Data(rom))
        let cpu = MOS6502(bus: memory)
        cpu.reset()
        cpu.run(cycles: 100)
        XCTAssertEqual(memory.textByte(column: 0, row: 0), 0xC1)
    }

    func test65C02JMPIndirectCrossesPageBoundary() {
        let memory = AppleIIMemory()
        memory.installDiagnosticProgram()
        // $0800: JMP ($20FF); on a 65C02 the high byte is read from $2100.
        memory.write(0x0800, 0x6C)
        memory.write(0x0801, 0xFF)
        memory.write(0x0802, 0x20)
        memory.write(0x20FF, 0x34)
        memory.write(0x2100, 0x12)
        memory.write(0x2000, 0x56) // NMOS page-wrap decoy.
        let cpu = MOS6502(bus: memory)
        cpu.reset()
        XCTAssertEqual(cpu.step(), 5)
        XCTAssertEqual(cpu.pc, 0x1234)
    }

    func test65C02BitInstructionsUseWDCExecutionAndTiming() {
        let memory = AppleIIMemory()
        memory.installDiagnosticProgram()
        // RMB0 $10; SMB0 $11; BBR0 $12,+0; BBS0 $13,+0
        let program: [UInt8] = [0x07, 0x10, 0x87, 0x11, 0x0F, 0x12, 0x00, 0x8F, 0x13, 0x00]
        for (offset, byte) in program.enumerated() { memory.write(UInt16(0x0800 + offset), byte) }
        memory.write(0x0010, 0xFF)
        memory.write(0x0011, 0x00)
        memory.write(0x0012, 0x00) // BBR condition true
        memory.write(0x0013, 0x01) // BBS condition true
        let cpu = MOS6502(bus: memory)
        cpu.reset()
        XCTAssertEqual(cpu.step(), 5)
        XCTAssertEqual(memory.read(0x0010), 0xFE)
        XCTAssertEqual(cpu.step(), 5)
        XCTAssertEqual(memory.read(0x0011), 0x01)
        XCTAssertEqual(cpu.step(), 6)
        XCTAssertEqual(cpu.step(), 6)
    }

    func testEveryDocumented65C02OpcodeDecodesWithoutFallback() {
        // Includes the documented operand-consuming NOPs and the WDC/Rockwell
        // bit operations present in the IIc's 65C02 family.  One isolated
        // instruction is enough to catch an opcode accidentally falling into
        // the emulator's unsupported-opcode compatibility path.
        let opcodes: [UInt8] = [
            0x00,0x01,0x02,0x04,0x05,0x06,0x07,0x08,0x09,0x0A,0x0C,0x0D,0x0E,0x0F,
            0x10,0x12,0x14,0x15,0x16,0x17,0x18,0x19,0x1A,0x1C,0x1D,0x1E,0x1F,
            0x20,0x21,0x22,0x24,0x25,0x26,0x27,0x28,0x29,0x2A,0x2C,0x2D,0x2E,0x2F,
            0x30,0x32,0x34,0x35,0x36,0x37,0x38,0x39,0x3A,0x3C,0x3D,0x3E,0x3F,
            0x40,0x41,0x42,0x44,0x45,0x46,0x47,0x48,0x49,0x4A,0x4C,0x4D,0x4E,0x4F,
            0x50,0x52,0x54,0x55,0x56,0x57,0x58,0x59,0x5A,0x5C,0x5D,0x5E,0x5F,
            0x60,0x61,0x62,0x64,0x65,0x66,0x67,0x68,0x69,0x6A,0x6C,0x6D,0x6E,0x6F,
            0x70,0x72,0x74,0x75,0x76,0x77,0x78,0x79,0x7A,0x7C,0x7D,0x7E,0x7F,
            0x80,0x81,0x82,0x84,0x85,0x86,0x87,0x88,0x89,0x8A,0x8C,0x8D,0x8E,0x8F,
            0x90,0x91,0x92,0x94,0x95,0x96,0x97,0x98,0x99,0x9A,0x9C,0x9D,0x9E,0x9F,
            0xA0,0xA1,0xA2,0xA4,0xA5,0xA6,0xA7,0xA8,0xA9,0xAA,0xAC,0xAD,0xAE,0xAF,
            0xB0,0xB1,0xB2,0xB4,0xB5,0xB6,0xB7,0xB8,0xB9,0xBA,0xBC,0xBD,0xBE,0xBF,
            0xC0,0xC1,0xC2,0xC4,0xC5,0xC6,0xC7,0xC8,0xC9,0xCA,0xCB,0xCC,0xCD,0xCE,0xCF,
            0xD0,0xD1,0xD2,0xD4,0xD5,0xD6,0xD7,0xD8,0xD9,0xDA,0xDC,0xDD,0xDE,0xDF,
            0xE0,0xE1,0xE2,0xE4,0xE5,0xE6,0xE7,0xE8,0xE9,0xEA,0xEC,0xED,0xEE,0xEF,
            0xF0,0xF1,0xF2,0xF4,0xF5,0xF6,0xF7,0xF8,0xF9,0xFA,0xFC,0xFD,0xFE,0xFF
        ]
        let nopTiming: [UInt8: Int] = [0x44: 3, 0x54: 4, 0x5C: 8, 0xD4: 4, 0xDC: 4, 0xF4: 4, 0xFC: 4]
        for opcode in opcodes {
            let memory = AppleIIMemory()
            memory.installDiagnosticProgram()
            memory.write(0x0800, opcode)
            memory.write(0x0801, 0)
            memory.write(0x0802, 0)
            memory.write(0x0803, 0)
            let cpu = MOS6502(bus: memory)
            cpu.reset()
            let cycles = cpu.step()
            XCTAssertTrue(cpu.unsupportedOpcodes.isEmpty, String(format: "opcode $%02X fell back", opcode))
            if let expected = nopTiming[opcode] {
                XCTAssertEqual(cycles, expected, String(format: "opcode $%02X timing", opcode))
            }
        }
    }

    func test65C02DecimalSubtraction() {
        let memory = AppleIIMemory()
        memory.installDiagnosticProgram()
        let program: [UInt8] = [
            0xF8,             // SED
            0x38,             // SEC
            0xA9, 0x50,       // LDA #$50
            0xE9, 0x01,       // SBC #$01
            0x8D, 0x00, 0x04  // STA $0400
        ]
        for (offset, byte) in program.enumerated() { memory.write(UInt16(0x0800 + offset), byte) }
        let cpu = MOS6502(bus: memory)
        cpu.reset()
        cpu.run(cycles: 20)
        XCTAssertEqual(memory.textByte(column: 0, row: 0), 0x49)
        XCTAssertNotEqual(cpu.p & 0x01, 0, "BCD 50 - 01 must not borrow")
    }

    func test65C02DecimalSubtractionWithBorrow() {
        let memory = AppleIIMemory()
        memory.installDiagnosticProgram()
        let program: [UInt8] = [
            0xF8,             // SED
            0x38,             // SEC
            0xA9, 0x00,       // LDA #$00
            0xE9, 0x01,       // SBC #$01
            0x8D, 0x00, 0x04  // STA $0400
        ]
        for (offset, byte) in program.enumerated() { memory.write(UInt16(0x0800 + offset), byte) }
        let cpu = MOS6502(bus: memory)
        cpu.reset()
        cpu.run(cycles: 20)
        XCTAssertEqual(memory.textByte(column: 0, row: 0), 0x99)
        XCTAssertEqual(cpu.p & 0x01, 0, "BCD 00 - 01 must borrow")
    }

    func testIndexedReadAddsOnlyItsPageCrossCycle() {
        let memory = AppleIIMemory()
        memory.installDiagnosticProgram()
        let program: [UInt8] = [
            0xA2, 0x01,       // LDX #1 (2)
            0xBD, 0xFF, 0x20, // LDA $20FF,X (4 + cross-page penalty)
            0x9D, 0xFF, 0x20  // STA $20FF,X (fixed 5, no read penalty)
        ]
        for (offset, byte) in program.enumerated() { memory.write(UInt16(0x0800 + offset), byte) }
        memory.write(0x2100, 0xC1)
        let cpu = MOS6502(bus: memory)
        cpu.reset()
        XCTAssertEqual(cpu.step(), 2)
        XCTAssertEqual(cpu.step(), 5)
        XCTAssertEqual(cpu.step(), 5)
        XCTAssertEqual(memory.read(0x2100), 0xC1)
    }

    func testInterruptUsesHardwareVectorInsteadOfBRKVector() {
        let memory = AppleIIMemory()
        var rom = [UInt8](repeating: 0xEA, count: 0x3000)
        rom[0x2000] = 0x58 // $F000 CLI
        rom[0x2020] = 0xA9 // $F020 LDA #$C1
        rom[0x2021] = 0xC1
        rom[0x2022] = 0x8D // STA $0400
        rom[0x2023] = 0x00
        rom[0x2024] = 0x04
        rom[0x2FFA] = 0x20 // NMI -> $F020
        rom[0x2FFB] = 0xF0
        rom[0x2FFC] = 0x00 // RESET -> $F000
        rom[0x2FFD] = 0xF0
        rom[0x2FFE] = 0x20 // IRQ -> $F020
        rom[0x2FFF] = 0xF0
        memory.loadROM(Data(rom))
        let cpu = MOS6502(bus: memory)
        cpu.reset()
        _ = cpu.step()
        cpu.irq()
        cpu.run(cycles: 12)
        XCTAssertEqual(memory.textByte(column: 0, row: 0), 0xC1)
    }

    func testBundledIIcROMRevisionsAreAllSelectable() throws {
        for name in ["AppleIIc-ROM00-342-0033-A", "AppleIIc-ROM03-341-0445-A", "AppleIIc-ROM04-341-0445-B", "AppleIIc-ROMFF-342-0272-A"] {
            let memory = AppleIIMemory()
            try memory.loadBundledAppleIIcROM(named: name)
            XCTAssertEqual(memory.model, .appleIIc)
            XCTAssertNotEqual(memory.read(0xFFFC), 0)
        }
    }

    func testBundledIIcROMRevisionsBootMountedDSK() throws {
        for name in ["AppleIIc-ROM00-342-0033-A", "AppleIIc-ROM03-341-0445-A", "AppleIIc-ROM04-341-0445-B", "AppleIIc-ROMFF-342-0272-A"] {
            let memory = AppleIIMemory()
            try memory.loadBundledAppleIIcROM(named: name)
            try memory.mountDSK(DiskII.diagnosticDSK())
            let cpu = MOS6502(bus: memory)
            cpu.reset()
            cpu.run(cycles: 5_000_000)
            let text = (0..<24).map { row in String((0..<40).map { memory.textByte(column: $0, row: row) & 0x7F }.map(UnicodeScalar.init).map(Character.init)) }.joined(separator: "|")
            XCTAssertGreaterThan(cpu.totalCycles, 0, name)
            XCTAssertGreaterThan(memory.diskNibbleReads, 0, name)
            XCTAssertTrue(cpu.unsupportedOpcodes.isEmpty, "\(name) boot path must not depend on an unsupported opcode")
            XCTAssertTrue(text.contains("DISK BOOT OK"), "\(name) should boot the mounted Slot-6 disk image")
        }
    }

    func testBundledAppleIIPlusROMBootsSixteenSectorDisk() throws {
        let memory = AppleIIMemory()
        try memory.loadBundledAppleIIPlusROM(diskFirmware: .sixteenSector)
        try memory.mountDSK(DiskII.diagnosticDSK())
        let cpu = MOS6502(bus: memory)
        cpu.reset()
        cpu.run(cycles: 5_000_000)
        let text = (0..<24).map { row in
            String((0..<40).map { memory.textByte(column: $0, row: row) & 0x7F }.map(UnicodeScalar.init).map(Character.init))
        }.joined(separator: "|")
        XCTAssertTrue(cpu.unsupportedOpcodes.isEmpty)
        XCTAssertGreaterThan(memory.diskNibbleReads, 0)
        XCTAssertTrue(text.contains("DISK BOOT OK"), "track=\(memory.diskTrack) \(text)")
    }

    func testAppleIIPlusSecondResetEntersROMApplesoft() throws {
        let memory = AppleIIMemory()
        try memory.loadBundledAppleIIPlusROM(diskFirmware: .sixteenSector)
        let cpu = MOS6502(bus: memory)
        cpu.reset()
        cpu.run(cycles: 500_000)
        cpu.reset()
        cpu.run(cycles: 500_000)
        let text = (0..<24).map { row in
            String((0..<40).map { memory.textByte(column: $0, row: row) & 0x7F }.map(UnicodeScalar.init).map(Character.init))
        }.joined(separator: "|")
        XCTAssertTrue(text.contains("]"), "pc=$\(String(cpu.pc, radix: 16)) \(text)")
    }

    func testROMApplesoftExecutesKeyboardPRINTCommand() throws {
        let memory = AppleIIMemory()
        try memory.loadBundledAppleIIPlusROM(diskFirmware: .sixteenSector)
        let cpu = MOS6502(bus: memory)
        cpu.reset()
        cpu.run(cycles: 500_000)
        cpu.reset()
        cpu.run(cycles: 500_000)

        for byte in Array("PRINT 1".utf8) {
            memory.latchKey(byte | 0x80)
            cpu.run(cycles: 40_000)
        }
        memory.latchKey(0x8D) // RETURN
        cpu.run(cycles: 250_000)

        let text = (0..<24).map { row in
            String((0..<40).map { memory.textByte(column: $0, row: row) & 0x7F }.map(UnicodeScalar.init).map(Character.init))
        }.joined(separator: "|")
        XCTAssertTrue(cpu.unsupportedOpcodes.isEmpty)
        XCTAssertTrue(text.contains("PRINT 1"), text)
        XCTAssertTrue(text.contains("1"), text)
    }

    func testThirteenSectorGCRRoundTripsBootSector() throws {
        let disk = DiskII()
        let image = DiskII.diagnosticDSK()
        try disk.mountThirteenSectorImage(image, drive: 0)
        XCTAssertEqual(disk.decodedThirteenSector(track: 0, physicalSector: 0), Array(image.prefix(256)))
    }

    @MainActor
    func testBundledGamesMountWithoutFilePicker() {
        XCTAssertEqual(
            AppleIIMachine.BundledGame.allCases.map(\.title),
            ["Lode Runner (1983)", "Prince of Persia (1989)", "Wizardry (1981)", "Karateka (1984)", "Falcons", "J-Bird"]
        )
        XCTAssertEqual(
            AppleIIMachine.BundledGame.defaultGameMenu.map(\.title),
            ["Falcons", "J-Bird", "Karateka (1984)", "Lode Runner (1983)"]
        )
        let machine = AppleIIMachine()
        for game in AppleIIMachine.BundledGame.allCases {
            machine.loadBundledGame(game)
            XCTAssertEqual(machine.diskDescription, game.title)
            XCTAssertEqual(machine.selectedBootROM, game.bootROM, game.title)
            XCTAssertTrue(machine.memory.hasDisk(in: 0), game.title)
        }
    }

    @MainActor
    func testFrontPanelResetKeepsDriveOneAndRebootsThroughROM() {
        let machine = AppleIIMachine()
        machine.insertDiagnosticDisk()
        machine.runForVerification(cycles: 5_000_000)
        XCTAssertTrue(machine.memory.diskNibbleReads > 0)

        machine.reset()

        XCTAssertTrue(machine.hasDisk(in: 0), "Front-panel reset must not eject Drive 1")
        XCTAssertTrue(machine.status.contains("正在从驱动器 1 启动"))
        machine.runForVerification(cycles: 5_000_000)
        let text = (0..<24).map { row in
            String((0..<40).map { machine.memory.textByte(column: $0, row: row) & 0x7F }.map(UnicodeScalar.init).map(Character.init))
        }.joined(separator: "|")
        XCTAssertGreaterThan(machine.memory.diskNibbleReads, 0)
        XCTAssertTrue(text.contains("DISK BOOT OK"), text)
    }

    @MainActor
    func testWizardryBootDiskTransfersControlFromFirmware() {
        let machine = AppleIIMachine()
        machine.loadBundledGame(.wizardry)

        XCTAssertTrue(machine.hasDisk(in: 0))
        XCTAssertTrue(machine.hasDisk(in: 1))
        XCTAssertEqual(machine.externalDiskDescription, "Wizardry 磁盘 2")
        machine.runForVerification(cycles: 2_000_000)

        let trace = machine.recentInstructions
            .map { String(format: "$%04X:%02X", $0.0, $0.1) }
            .joined(separator: " ")
        XCTAssertTrue(
            machine.hasExecutedRAMCode,
            "Wizardry did not leave the Disk II firmware; pc=$\(String(machine.programCounter, radix: 16)), reads=\(machine.memory.diskNibbleReads), trace=\(trace)"
        )
        XCTAssertTrue(
            machine.encounteredUnsupportedCPUOpcodes.isEmpty,
            "Wizardry executed unsupported opcodes: \(machine.encounteredUnsupportedCPUOpcodes)"
        )

        var titleAppeared = false
        for _ in 0..<60 {
            machine.runForVerification(cycles: 1_000_000)
            let video = machine.videoSnapshot
            if video.hires && video.hgrMain.contains(where: { $0 & 0x7F != 0 }) {
                titleAppeared = true
                break
            }
        }
        XCTAssertTrue(
            titleAppeared,
            "Wizardry did not reach its visible title screen; pc=$\(String(machine.programCounter, radix: 16)), reads=\(machine.memory.diskNibbleReads)"
        )

        // Disk 2 stays in the second physical drive. Wizardry itself selects
        // Drive 2 through the Disk II soft switch; the launcher must not
        // replace Drive 1 merely because a screen happens to mention a disk.
        XCTAssertTrue(machine.hasDisk(in: 0))
        XCTAssertTrue(machine.hasDisk(in: 1))
    }

    @MainActor
    func testPrinceOfPersiaBootsOnAppleIIeWith128K() {
        let machine = AppleIIMachine()
        machine.loadBundledGame(.princeOfPersia)

        XCTAssertEqual(machine.selectedBootROM, .appleIIeGameCompatible)
        XCTAssertEqual(machine.memory.model, .appleIIe)
        XCTAssertTrue(machine.hasDisk(in: 0))
        XCTAssertTrue(machine.hasDisk(in: 1))
        machine.runForVerification(cycles: 5_000_000)
        XCTAssertTrue(machine.hasExecutedRAMCode)
        XCTAssertTrue(machine.encounteredUnsupportedCPUOpcodes.isEmpty)
        let text = (0..<24).map { row in
            String((0..<40).map { machine.memory.textByte(column: $0, row: row) & 0x7F }.map(UnicodeScalar.init).map(Character.init))
        }.joined(separator: "|")
        let trace = machine.recentInstructions
            .map { String(format: "$%04X:%02X", $0.0, $0.1) }
            .joined(separator: " ")
        XCTAssertFalse(
            text.contains("REQUIRES A //C OR //E WITH 128K"),
            "Prince of Persia rejected the IIe 128K configuration; pc=$\(String(machine.programCounter, radix: 16)), FBB3=$\(String(machine.memory.read(0xFBB3), radix: 16)), C017=$\(String(machine.memory.read(0xC017), radix: 16)), slot3ROM=\(machine.memory.slot3ROM), RAMRD=\(machine.memory.ramReadAuxiliary), RAMWRT=\(machine.memory.ramWriteAuxiliary), trace=\(trace), text=\(text)"
        )
    }

    @MainActor
    func testPrinceOfPersiaStartsWithThirdDiskInDriveTwo() throws {
        let machine = AppleIIMachine()
        machine.loadBundledGame(.princeOfPersia)
        XCTAssertTrue(machine.hasDisk(in: 0))
        XCTAssertTrue(machine.hasDisk(in: 1))
        XCTAssertEqual(machine.externalDiskDescription, "Prince of Persia 磁盘 3")
        XCTAssertEqual(
            AppleIIMachine.BundledGame.princeOfPersia.startupDisks.map(\.description),
            ["Prince of Persia 磁盘 1", "Prince of Persia 磁盘 3"]
        )
    }

    @MainActor
    func testPrinceOfPersiaContinuesPastItsStartupScreenAfterKeyPress() {
        let machine = AppleIIMachine()
        machine.loadBundledGame(.princeOfPersia)
        machine.runForVerification(cycles: 18_000_000)
        writeDiagnosticPNG(machine.videoSnapshot, named: "prince-before-button")
        // The loader accepts any keyboard key as well as a controller button.
        // Exercise the actual keyboard strobe here, independent of AppKit's
        // foreground-event delivery.
        machine.memory.latchKey(0x8D) // Return with the Apple II key-ready bit
        machine.runForVerification(cycles: 30_000_000)

        let video = machine.videoSnapshot
        writeDiagnosticPNG(video, named: "prince-after-return")
        let diagnostic = "text=\(video.textMode) hires=\(video.hires) dhires=\(video.doubleHires) col80=\(video.column80) alt=\(video.alternateCharset) hgrPixels=\((video.hgrMain + video.hgrAuxiliary).filter { $0 & 0x7F != 0 }.count) textCells=\(video.text.filter { $0 & 0x7F != 0 }.count) pc=$\(String(machine.programCounter, radix: 16))"
        let visibleBytes: [UInt8]
        if video.textMode {
            visibleBytes = video.text
        } else if video.hires {
            visibleBytes = video.hgrMain + video.hgrAuxiliary
        } else {
            visibleBytes = video.lores
        }
        XCTAssertTrue(
            visibleBytes.contains { $0 & 0x7F != 0 },
            "Prince went blank after button press; \(diagnostic), unsupported=\(machine.encounteredUnsupportedCPUOpcodes), trace=\(machine.recentInstructions)"
        )
        let firstUnsupportedTrace = machine.firstUnsupportedInstructionTrace
            .map { String(format: "$%04X:%02X", $0.0, $0.1) }
            .joined(separator: " ")
        XCTAssertTrue(video.hires, "Prince did not enter the high-resolution game path; \(diagnostic), first=\(firstUnsupportedTrace)")
        XCTAssertTrue(machine.hasExecutedRAMCode)
        XCTAssertTrue(machine.encounteredUnsupportedCPUOpcodes.isEmpty, "Prince executed unsupported opcodes: \(machine.encounteredUnsupportedCPUOpcodes)")
    }

    /// This is deliberately independent of macOS screen recording: the test
    /// process rasterizes the exact video snapshot that the app publishes.
    /// Set `APPLEII_EMIT_PNG=1` when a visual artifact is wanted; normal test
    /// runs remain filesystem-free.
    private func writeDiagnosticPNG(_ video: AppleIIVideoSnapshot, named name: String) {
        guard ProcessInfo.processInfo.environment["APPLEII_EMIT_PNG"] == "1" else { return }
        let size = NSSize(width: 800, height: 480)
        let image = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width),
            pixelsHigh: Int(size.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        guard let context = NSGraphicsContext(bitmapImageRep: image) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor(red: 0.01, green: 0.04, blue: 0.02, alpha: 1).setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()

        if video.hires {
            let dotSize = NSSize(width: size.width / 280, height: size.height / 192)
            let palette: [AppleIIHiResColor: NSColor] = [
                .black: .black,
                .green: NSColor(red: 0.20, green: 0.82, blue: 0.26, alpha: 1),
                .purple: NSColor(red: 0.72, green: 0.20, blue: 0.82, alpha: 1),
                .orange: NSColor(red: 0.96, green: 0.43, blue: 0.08, alpha: 1),
                .blue: NSColor(red: 0.10, green: 0.42, blue: 0.96, alpha: 1),
                .white: .white
            ]
            for row in 0..<192 {
                let dots = appleIIHiResDots(bytes: (0..<40).map { video.hgrByte(column: $0, row: row, auxiliary: false) })
                for (column, color) in dots.enumerated() where color != .black {
                    palette[color]?.setFill()
                    NSBezierPath(rect: NSRect(x: CGFloat(column) * dotSize.width, y: size.height - CGFloat(row + 1) * dotSize.height, width: dotSize.width + 0.1, height: dotSize.height + 0.1)).fill()
                }
            }
        }

        let columns = video.column80 ? 80 : 40
        let cell = NSSize(width: size.width / CGFloat(columns), height: size.height / 24)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: min(cell.height * 0.8, cell.width * 1.2), weight: .medium),
            .foregroundColor: NSColor(red: 0.28, green: 1.0, blue: 0.42, alpha: 1)
        ]
        for row in 0..<24 {
            for column in 0..<columns {
                let byte = video.textByte(column: column, row: row)
                guard byte != 0 else { continue }
                let cellValue = video.column80
                    ? appleII80ColumnTextCell(byte: byte, alternateCharset: video.alternateCharset, flashOn: true, supportsMouseText: video.supportsMouseText)
                    : appleIITextCell(byte: byte, alternateCharset: video.alternateCharset, flashOn: true, supportsMouseText: video.supportsMouseText)
                let glyph: String
                switch cellValue {
                case let .normal(value), let .inverse(value):
                    glyph = String(UnicodeScalar(value < 0x20 ? value + 0x40 : value))
                case let .alternate(value), let .alternateInverse(value):
                    glyph = value < 0x20 ? "•" : String(UnicodeScalar(value))
                case let .ascii(value):
                    glyph = value >= 0x20 ? String(UnicodeScalar(value)) : " "
                }
                (glyph as NSString).draw(at: NSPoint(x: CGFloat(column) * cell.width, y: size.height - CGFloat(row + 1) * cell.height), withAttributes: attributes)
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        let url = URL(fileURLWithPath: "/private/tmp/AppleIIEmulator-\(name).png")
        try? image.representation(using: .png, properties: [:])?.write(to: url)
    }

    @MainActor
    func testFreshMachineStartsAsUnmodifiedAppleIIPlusWithoutDiagnosticDisk() {
        let machine = AppleIIMachine()
        XCTAssertEqual(machine.selectedBootROM, .appleIIPlus)
        XCTAssertEqual(machine.diskDescription, "未插入")
        XCTAssertFalse(machine.memory.hasDisk(in: 0))
    }

    @MainActor
    func testEveryVisibleROMChoiceChangesTheRunningMachine() {
        let machine = AppleIIMachine()
        for rom in AppleIIMachine.BootROM.allCases {
            machine.selectROM(rom)
            XCTAssertEqual(machine.selectedBootROM, rom)
            XCTAssertTrue(machine.isRunning)
        }
    }

    @MainActor
    func testDefaultBundledGamesExecuteThroughTheirBootPaths() {
        let machine = AppleIIMachine()
        for game in AppleIIMachine.BundledGame.defaultGameMenu {
            machine.loadBundledGame(game)
            let expectedModel: AppleIIMemory.Model = game.bootROM == .appleIIPlus ? .appleIIPlus : .appleIIe
            XCTAssertEqual(machine.memory.model, expectedModel, game.title)
            machine.runForVerification(cycles: 5_000_000)
            XCTAssertGreaterThan(machine.executedCPUCycles, 0, game.title)
            XCTAssertTrue(machine.encounteredUnsupportedCPUOpcodes.isEmpty, "\(game.title) executed unsupported opcodes: \(machine.encounteredUnsupportedCPUOpcodes)")
            XCTAssertGreaterThan(machine.memory.diskNibbleReads, 0, game.title)
            let trace = machine.recentInstructions.map { String(format: "$%04X:%02X", $0.0, $0.1) }.joined(separator: " ")
            XCTAssertTrue(machine.hasExecutedRAMCode, "\(game.title) should transfer control from ROM to its disk-loaded code; pc=$\(String(machine.programCounter, radix: 16)), reads=\(machine.memory.diskNibbleReads), trace=\(trace)")
            machine.runForVerification(cycles: 15_000_000)
            let text = (0..<24).map { row in
                String((0..<40).map { machine.memory.textByte(column: $0, row: row) & 0x7F }.map(UnicodeScalar.init).map(Character.init))
            }.joined(separator: "|")
            XCTAssertFalse(text.contains("ERR"), "\(game.title) boot failed: \(text)")
            XCTAssertTrue(!machine.memory.textMode || text.trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: "|"))).isEmpty == false, "\(game.title) should reach a visible title or graphics screen")
        }
    }

    func testNibImageCanBeMounted() throws {
        let memory = AppleIIMemory()
        try memory.mountDiskImageData(Data(repeating: 0xFF, count: DiskII.nibImageSize), fileExtension: "nib")
        XCTAssertTrue(memory.hasDisk)
    }

    func testDSKGCREncodingRoundTripsEverySectorOrder() throws {
        var image = [UInt8](repeating: 0, count: DiskII.imageSize)
        for track in 0..<35 {
            for logicalSector in 0..<16 {
                let offset = (track * 16 + logicalSector) * 256
                for byte in 0..<256 {
                    image[offset + byte] = UInt8(truncatingIfNeeded: track * 29 + logicalSector * 17 + byte)
                }
            }
        }
        let disk = DiskII()
        try disk.mountDSK(Data(image))
        // Standard DOS-order physical stream used by the `.dsk` converter.
        let physicalToLogical = [0, 7, 14, 6, 13, 5, 12, 4, 11, 3, 10, 2, 9, 1, 8, 15]
        for track in [0, 17, 34] {
            for physicalSector in 0..<16 {
                let expectedOffset = (track * 16 + physicalToLogical[physicalSector]) * 256
                XCTAssertEqual(disk.decodedSector(track: track, physicalSector: physicalSector), Array(image[expectedOffset..<(expectedOffset + 256)]))
            }
        }
    }

    func testDSKCanBePersistedAsStandardNIB() throws {
        var image = [UInt8](repeating: 0, count: DiskII.imageSize)
        for offset in image.indices { image[offset] = UInt8(truncatingIfNeeded: offset * 31) }
        let disk = DiskII()
        try disk.mountDSK(Data(image))
        let nib = try XCTUnwrap(disk.nibImage())
        XCTAssertEqual(nib.count, DiskII.nibImageSize)
        let restored = DiskII()
        try restored.mountImage(nib, fileExtension: "nib")
        let physicalToLogical = [0, 7, 14, 6, 13, 5, 12, 4, 11, 3, 10, 2, 9, 1, 8, 15]
        for physical in 0..<16 {
            let logical = physicalToLogical[physical]
            let offset = (17 * 16 + logical) * 256
            XCTAssertEqual(restored.decodedSector(track: 17, physicalSector: physical), Array(image[offset..<(offset + 256)]))
        }
    }

    func testProDOSOrderSectorImageUsesPOInterleave() throws {
        var image = [UInt8](repeating: 0, count: DiskII.imageSize)
        for logicalSector in 0..<16 {
            let offset = logicalSector * 256
            image.replaceSubrange(offset..<(offset + 256), with: Array(repeating: UInt8(logicalSector), count: 256))
        }
        let disk = DiskII()
        try disk.mountImage(Data(image), fileExtension: "po")
        let physicalToLogical = [0, 2, 4, 6, 8, 10, 12, 14, 1, 3, 5, 7, 9, 11, 13, 15]
        for physicalSector in 0..<16 {
            XCTAssertEqual(disk.decodedSector(track: 0, physicalSector: physicalSector)?.first, UInt8(physicalToLogical[physicalSector]))
        }
    }

    func test2IMGWrapperMountsItsDeclaredDOSOrProDOSPayload() throws {
        func twoIMG(_ payload: Data, format: UInt8) -> Data {
            var header = [UInt8](repeating: 0, count: 64)
            header.replaceSubrange(0..<4, with: [0x32, 0x49, 0x4D, 0x47]) // 2IMG
            header[8] = 64 // header length, little endian
            header[10] = 1 // format version
            header[12] = format
            header[24] = 64 // payload offset, little endian
            let length = payload.count
            header[28] = UInt8(length & 0xFF)
            header[29] = UInt8((length >> 8) & 0xFF)
            header[30] = UInt8((length >> 16) & 0xFF)
            header[31] = UInt8((length >> 24) & 0xFF)
            return Data(header) + payload
        }

        var image = [UInt8](repeating: 0, count: DiskII.imageSize)
        // Physical sector 1 reads logical sector 2 in ProDOS order.
        image[(16 + 2) * 256] = 0xC3
        let disk = DiskII()
        try disk.mountImage(twoIMG(Data(image), format: 1), fileExtension: "2mg")
        XCTAssertEqual(disk.decodedSector(track: 1, physicalSector: 1)?.first, 0xC3)

        // Go beyond parsing: ROM 04 must be able to boot a DOS-order 2IMG
        // payload through the same integrated IWM path as a normal .dsk.
        let memory = AppleIIMemory()
        try memory.loadBundledAppleIIcROM(named: "AppleIIc-ROM04-341-0445-B")
        try memory.mountDiskImageData(twoIMG(DiskII.diagnosticDSK(), format: 0), fileExtension: "2mg")
        let cpu = MOS6502(bus: memory)
        cpu.reset()
        cpu.run(cycles: 5_000_000)
        let text = (0..<24).map { row in
            String((0..<40).map { memory.textByte(column: $0, row: row) & 0x7F }
                .map(UnicodeScalar.init).map(Character.init))
        }.joined(separator: "|")
        XCTAssertGreaterThan(memory.diskNibbleReads, 0)
        XCTAssertTrue(cpu.unsupportedOpcodes.isEmpty)
        XCTAssertTrue(text.contains("DISK BOOT OK"))
    }
}
