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
        _ = machine.memory.read(0xC070)
        machine.memory.advanceVideoClock(by: 1_408)
        XCTAssertEqual(machine.memory.read(0xC064), 0x80) // PDL0: right
        XCTAssertEqual(machine.memory.read(0xC066), 0x80) // PDL2: second port

        machine.keyUp(release)
        _ = machine.memory.read(0xC070)
        machine.memory.advanceVideoClock(by: 1_408)
        XCTAssertEqual(machine.memory.read(0xC064), 0) // released: centre
        XCTAssertEqual(machine.memory.read(0xC066), 0)
    }

    func testIIcTextAttributesHonorInverseFlashAndAlternateCharset() {
        XCTAssertEqual(appleIITextCell(byte: 0x01, alternateCharset: false, flashOn: true), .inverse(0x01))
        XCTAssertEqual(appleIITextCell(byte: 0x41, alternateCharset: false, flashOn: true), .normal(0x01))
        XCTAssertEqual(appleIITextCell(byte: 0x41, alternateCharset: false, flashOn: false), .inverse(0x01))
        XCTAssertEqual(appleIITextCell(byte: 0x41, alternateCharset: true, flashOn: false), .alternate(0x01))
        XCTAssertEqual(appleIITextCell(byte: 0x41, alternateCharset: true, flashOn: false, supportsMouseText: false), .inverse(0x01))
        XCTAssertEqual(appleIITextCell(byte: 0xC1, alternateCharset: true, flashOn: false), .normal(0x01))
        XCTAssertEqual(appleIITextCell(byte: 0xFF, alternateCharset: false, flashOn: true), .normal(0x3F))
        XCTAssertEqual(appleII80ColumnTextCell(byte: 0xEF, alternateCharset: true, flashOn: false), .ascii(0x6F))
        XCTAssertEqual(appleII80ColumnTextCell(byte: 0x41, alternateCharset: true, flashOn: false), .alternate(0x01))
        XCTAssertEqual(appleII80ColumnTextCell(byte: 0x41, alternateCharset: true, flashOn: false, supportsMouseText: false), .inverse(0x01))
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
            ["Falcons (4am crack)", "J-Bird", "Ocean Night"]
        )
        let machine = AppleIIMachine()
        for game in AppleIIMachine.BundledGame.allCases {
            machine.loadBundledGame(game)
            XCTAssertEqual(machine.diskDescription, game.title)
            XCTAssertTrue(machine.memory.hasDisk(in: 0), game.title)
        }
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
    func testBundledGamesExecuteThroughAppleIIPlusBootPath() {
        let machine = AppleIIMachine()
        for game in AppleIIMachine.BundledGame.allCases {
            machine.loadBundledGame(game)
            XCTAssertEqual(machine.memory.model, .appleIIPlus, game.title)
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
