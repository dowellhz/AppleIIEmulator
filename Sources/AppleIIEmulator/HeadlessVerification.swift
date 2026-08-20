import AppKit
import Foundation

/// A non-interactive verification entry point for the packaged application.
/// It is intentionally opt-in so ordinary launches remain a SwiftUI app, but
/// allows CI and local debugging to inspect the emulator's own raster without
/// using macOS screen-recording permission.
@MainActor
enum HeadlessVerification {
    static func runIfRequested() -> Int32? {
        if CommandLine.arguments.contains("--verify-prince-png") {
            return verifyPrince(writeTo: "AppleIIEmulator-prince-app.png", swapThirdDisk: false)
        }
        if CommandLine.arguments.contains("--verify-prince-third-disk-png") {
            return verifyPrince(writeTo: "AppleIIEmulator-prince-third-disk-app.png", swapThirdDisk: true)
        }
        if CommandLine.arguments.contains("--trace-prince-after-return") {
            return tracePrinceAfterReturn()
        }
        if CommandLine.arguments.contains("--verify-wizardry-png") {
            return verifyWizardry()
        }
        if CommandLine.arguments.contains("--verify-wizardry-key-png") {
            return verifyWizardryAfterReturn()
        }
        if CommandLine.arguments.contains("--verify-wizardry-swap-png") {
            return verifyWizardryAfterScenarioSwap()
        }
        if CommandLine.arguments.contains("--trace-wizardry-scenario") {
            return traceWizardryScenarioLoad()
        }
        if CommandLine.arguments.contains("--verify-wizardry-scenario-return-png") {
            return verifyWizardryAfterScenarioReturn()
        }
        if CommandLine.arguments.contains("--verify-wizardry-start-prompt-png") {
            return verifyWizardryStartPrompt()
        }
        if CommandLine.arguments.contains("--trace-wizardry-start-keys") {
            return traceWizardryStartKeys()
        }
        if CommandLine.arguments.contains("--trace-iie-startup") {
            return traceAppleIIeStartup()
        }
        if let argument = CommandLine.arguments.first(where: { $0.hasPrefix("--verify-software=") }) {
            let rawValue = String(argument.dropFirst("--verify-software=".count))
            guard let software = AppleIIMachine.BundledSoftware(rawValue: rawValue) else {
                fputs("Unknown bundled software: \(rawValue)\\n", stderr)
                return 2
            }
            return verifyBundledSoftware(software)
        }
        return nil
    }

    /// Captures the ordinary IIe power-on path without a mounted disk.  This
    /// uses the same ROM selection, reset vector and video snapshot that the
    /// visible application uses, so character-set regressions cannot hide
    /// behind a unit test that only reads ROM bytes.
    private static func traceAppleIIeStartup() -> Int32 {
        let machine = AppleIIMachine()
        machine.selectROM(.appleIIeEnhanced)
        machine.runForVerification(cycles: 2_000_000)
        let video = machine.videoSnapshot
        let rows = (0..<24).map { row in
            (0..<40).map { column -> String in
                let byte = video.textByte(column: column, row: row)
                let cell = appleIITextCell(
                    byte: byte,
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
        }.joined(separator: "|")
        let firstRowBytes = (0..<40).map { String(format: "%02X", video.textByte(column: $0, row: 0)) }.joined(separator: " ")
        fputs("pc=$\(String(machine.programCounter, radix: 16)) text=$\(video.textMode) col80=$\(video.column80) alt=$\(video.alternateCharset) raw=$\(firstRowBytes) rows=\(rows)\n", stderr)
        return 0
    }

    /// Exercises the same `AppleIIMachine` launcher used by the SOFTWARE
    /// panel, instead of mounting a disk directly in a unit-test memory bus.
    private static func verifyBundledSoftware(_ software: AppleIIMachine.BundledSoftware) -> Int32 {
        let machine = AppleIIMachine()
        machine.loadBundledSoftware(software)
        guard !machine.status.hasPrefix("无法装入") else {
            fputs("\(software.title) did not mount through the application launcher: \(machine.status)\\n", stderr)
            return 1
        }

        machine.runForVerification(cycles: 25_000_000)
        let video = machine.videoSnapshot
        let visibleCells = video.text.filter { byte in
            let glyph = byte & 0x7F
            return glyph != 0 && glyph != 0x20
        }.count
        guard machine.hasExecutedRAMCode,
              machine.encounteredUnsupportedCPUOpcodes.isEmpty,
              machine.memory.diskNibbleReads > 0,
              visibleCells > 0 else {
            fputs("\(software.title) did not reach a visible software screen. pc=$\(String(machine.programCounter, radix: 16)) reads=\(machine.memory.diskNibbleReads) visible=\(visibleCells) unsupported=\(machine.encounteredUnsupportedCPUOpcodes)\\n", stderr)
            return 1
        }
        return 0
    }

    private static func verifyPrince(writeTo filename: String, swapThirdDisk: Bool) -> Int32 {
        let machine = AppleIIMachine()
        machine.loadBundledGame(.princeOfPersia)
        machine.runForVerification(cycles: 18_000_000)
        machine.memory.latchKey(0x8D) // Return with the Apple II key-ready bit.
        machine.runForVerification(cycles: 12_000_000)

        if swapThirdDisk {
            let cyclesBeforeSwap = machine.executedCPUCycles
            let pcBeforeSwap = machine.programCounter
            do {
                guard let diskURL = AppResources.bundle.url(forResource: "Prince of Persia (1989) Disk 3", withExtension: "dsk") else {
                    throw CocoaError(.fileNoSuchFile)
                }
                try machine.replaceDiskImageData(
                    Data(contentsOf: diskURL),
                    fileExtension: "dsk",
                    description: "Prince of Persia 磁盘 3",
                    drive: 1
                )
                guard machine.executedCPUCycles == cyclesBeforeSwap,
                      machine.programCounter == pcBeforeSwap else {
                    fputs("Prince of Persia third-disk swap reset the emulated machine.\n", stderr)
                    return 1
                }
            } catch {
                fputs("Unable to mount Prince of Persia disk 3: \(error)\n", stderr)
                return 1
            }
        }
        machine.runForVerification(cycles: 18_000_000)

        let video = machine.videoSnapshot
        guard video.hires,
              machine.encounteredUnsupportedCPUOpcodes.isEmpty else {
            fputs("Prince of Persia verification did not reach the game screen.\n", stderr)
            return 1
        }

        do {
            try writePNG(video, to: URL(fileURLWithPath: "/private/tmp/\(filename)"))
            return 0
        } catch {
            fputs("Unable to write Prince of Persia verification PNG: \(error)\n", stderr)
            return 1
        }
    }

    /// Diagnostic probe for the exact transition that follows the title-page
    /// key press. It is intentionally separate from normal app startup so no
    /// client session receives synthetic input or console logging.
    private static func tracePrinceAfterReturn() -> Int32 {
        let machine = AppleIIMachine()
        machine.loadBundledGame(.princeOfPersia)
        machine.runForVerification(cycles: 18_000_000)
        printPrinceTrace(machine, label: "before-return")
        machine.memory.latchKey(0x8D)
        for elapsed in stride(from: 1_000_000, through: 45_000_000, by: 1_000_000) {
            if elapsed == 5_000_000 || elapsed == 12_000_000 {
                // The crack/title page has several visible wait-for-button
                // transitions. Exercise each Return only after the prior
                // transition has settled, as a player would.
                machine.memory.latchKey(0x8D)
            }
            machine.runForVerification(cycles: 1_000_000)
            let phase: String
            if elapsed >= 12_000_000 { phase = "after-third-return" }
            else if elapsed >= 5_000_000 { phase = "after-second-return" }
            else { phase = "after-first-return" }
            printPrinceTrace(machine, label: "\(phase)+\(elapsed / 1_000_000)s")
        }
        return machine.encounteredUnsupportedCPUOpcodes.isEmpty ? 0 : 1
    }

    private static func printPrinceTrace(_ machine: AppleIIMachine, label: String) {
        let video = machine.videoSnapshot
        let disk = machine.memory.diskDebugSnapshot
        let rows = (0..<3).map { row -> String in
            let codes = (0..<40).map { video.text[row * 80 + $0] & 0x7F }
            let characters = codes.map { code -> Character in
                guard code >= 0x20, code < 0x7F else { return " " }
                return Character(UnicodeScalar(code))
            }
            return String(characters).trimmingCharacters(in: .whitespaces)
        }.joined(separator: " | ")
        let unsupported = machine.encounteredUnsupportedCPUOpcodes
            .map { String(format: "%02X", $0) }
            .sorted()
            .joined(separator: ",")
        let pc = machine.programCounter
        let instructionBytes = (0..<12).map { offset in
            machine.memory.read(pc &+ UInt16(offset))
        }.map { String(format: "%02X", $0) }.joined(separator: " ")
        fputs(
            "PRINCE \(label) pc=$\(String(pc, radix: 16)) code=[\(instructionBytes)] text=\(video.textMode) hires=\(video.hires) dhires=\(video.doubleHires) motor=\(disk.motorOn) drive=\(disk.selectedDrive + 1) q6=\(disk.q6) q7=\(disk.q7) tracks=\(disk.tracks) readBits=\(disk.readBits) unsupported=[\(unsupported)] rows=\(rows)\\n",
            stderr
        )
    }

    private static func verifyWizardry() -> Int32 {
        let machine = AppleIIMachine()
        machine.loadBundledGame(.wizardry)
        var video = machine.videoSnapshot
        var bestVideo = video
        var bestVisibleCount = 0
        for _ in 0..<500 {
            machine.runForVerification(cycles: 100_000)
            video = machine.videoSnapshot
            let visibleCount: Int
            if video.textMode {
                visibleCount = video.text.filter { $0 & 0x7F != 0 }.count
            } else if video.hires {
                visibleCount = video.hgrMain.filter { $0 & 0x7F != 0 }.count
            } else {
                visibleCount = video.lores.filter { $0 & 0x7F != 0 }.count
            }
            if visibleCount > bestVisibleCount {
                bestVisibleCount = visibleCount
                bestVideo = video
            }
        }
        let textInkCount = bestVideo.text.filter {
            let glyph = $0 & 0x7F
            return glyph != 0 && glyph != 0x20
        }.count
        guard machine.hasExecutedRAMCode,
              machine.encounteredUnsupportedCPUOpcodes.isEmpty,
              bestVisibleCount > 0,
              (!bestVideo.textMode || textInkCount > 0) else {
            fputs("Wizardry verification did not reach a visible game screen.\n", stderr)
            return 1
        }
        do {
            try writePNG(bestVideo, to: URL(fileURLWithPath: "/private/tmp/AppleIIEmulator-wizardry-app.png"))
            try writePNG(video, to: URL(fileURLWithPath: "/private/tmp/AppleIIEmulator-wizardry-final-app.png"))
            return 0
        } catch {
            fputs("Unable to write Wizardry verification PNG: \(error)\n", stderr)
            return 1
        }
    }

    private static func verifyWizardryAfterReturn() -> Int32 {
        let machine = AppleIIMachine()
        machine.loadBundledGame(.wizardry)
        machine.runForVerification(cycles: 50_000_000)
        machine.memory.latchKey(0x8D)
        machine.runForVerification(cycles: 15_000_000)
        do {
            try writePNG(machine.videoSnapshot, to: URL(fileURLWithPath: "/private/tmp/AppleIIEmulator-wizardry-after-return.png"))
            return 0
        } catch {
            fputs("Unable to write Wizardry post-return PNG: \(error)\n", stderr)
            return 1
        }
    }

    private static func verifyWizardryAfterScenarioSwap() -> Int32 {
        let machine = AppleIIMachine()
        machine.loadBundledGame(.wizardry)
        machine.runForVerification(cycles: 50_000_000)
        do {
            guard let scenarioURL = AppResources.bundle.url(forResource: "Wizardry (1981) Disk 2", withExtension: "dsk") else {
                return 1
            }
            try machine.replaceDiskImageData(
                Data(contentsOf: scenarioURL),
                fileExtension: "dsk",
                description: "Wizardry 磁盘 2",
                drive: 0
            )
            machine.runForVerification(cycles: 25_000_000)
            try writePNG(machine.videoSnapshot, to: URL(fileURLWithPath: "/private/tmp/AppleIIEmulator-wizardry-after-swap.png"))
            return 0
        } catch {
            fputs("Unable to verify Wizardry scenario swap: \(error)\n", stderr)
            return 1
        }
    }

    private static func traceWizardryScenarioLoad() -> Int32 {
        let machine = AppleIIMachine()
        machine.loadBundledGame(.wizardry)
        machine.runForVerification(cycles: 50_000_000)
        do {
            guard let scenarioURL = AppResources.bundle.url(forResource: "Wizardry (1981) Disk 2", withExtension: "dsk") else {
                return 1
            }
            try machine.replaceDiskImageData(
                Data(contentsOf: scenarioURL),
                fileExtension: "dsk",
                description: "Wizardry Scenario 磁盘",
                drive: 0
            )
            for elapsedAfterSwap in stride(from: 0, through: 120_000_000, by: 10_000_000) {
                if elapsedAfterSwap > 0 { machine.runForVerification(cycles: 10_000_000) }
                let video = machine.videoSnapshot
                let text = video.text.map { byte -> Character in
                    let code = byte & 0x7F
                    return code >= 0x20 && code < 0x7F ? Character(UnicodeScalar(code)) : " "
                }
                let firstRows = stride(from: 0, to: 120, by: 40).map { start in
                    String(text[start..<(start + 40)]).trimmingCharacters(in: .whitespaces)
                }.joined(separator: " | ")
                let visible = video.hires
                    ? video.hgrMain.filter { $0 & 0x7F != 0 }.count
                    : video.text.filter { $0 & 0x7F != 0 }.count
                try? writePNG(video, to: URL(fileURLWithPath: "/private/tmp/Wizardry-scenario-\(elapsedAfterSwap / 1_000_000)s.png"))
                fputs("after=\(elapsedAfterSwap) pc=$\(String(machine.programCounter, radix: 16)) hires=\(video.hires) text=\(video.textMode) visible=\(visible) rows=\(firstRows)\n", stderr)
            }
            return 0
        } catch {
            fputs("Unable to trace Wizardry Scenario load: \(error)\n", stderr)
            return 1
        }
    }

    private static func verifyWizardryAfterScenarioReturn() -> Int32 {
        let machine = AppleIIMachine()
        machine.loadBundledGame(.wizardry)
        machine.runForVerification(cycles: 50_000_000)
        do {
            guard let scenarioURL = AppResources.bundle.url(forResource: "Wizardry (1981) Disk 2", withExtension: "dsk") else {
                return 1
            }
            try machine.replaceDiskImageData(
                Data(contentsOf: scenarioURL),
                fileExtension: "dsk",
                description: "Wizardry Scenario 磁盘",
                drive: 0
            )
            machine.runForVerification(cycles: 2_000_000)
            machine.memory.latchKey(0x8D)
            machine.runForVerification(cycles: 25_000_000)
            try writePNG(machine.videoSnapshot, to: URL(fileURLWithPath: "/private/tmp/AppleIIEmulator-wizardry-scenario-return.png"))
            return 0
        } catch {
            fputs("Unable to verify Wizardry Scenario return: \(error)\n", stderr)
            return 1
        }
    }

    private static func verifyWizardryStartPrompt() -> Int32 {
        let machine = AppleIIMachine()
        machine.loadBundledGame(.wizardry)
        machine.runForVerification(cycles: 50_000_000)
        machine.memory.latchKey(0xA0) // Space ends the splash screen.
        var reachedStartMenu = false
        for _ in 0..<150 {
            machine.runForVerification(cycles: 100_000)
            let screen = String(machine.videoSnapshot.text.map { byte in
                let code = byte & 0x7F
                return code >= 0x20 && code < 0x7F ? Character(UnicodeScalar(code)) : " "
            })
            if screen.contains("S)TART GAME") {
                reachedStartMenu = true
                break
            }
        }
        guard reachedStartMenu else {
            fputs("Wizardry did not reach its start menu after splash input.\\n", stderr)
            return 1
        }
        machine.memory.latchKey(0xD3) // S starts the game after the menu is visible.
        machine.runForVerification(cycles: 10_000_000)
        do {
            try writePNG(machine.videoSnapshot, to: URL(fileURLWithPath: "/private/tmp/AppleIIEmulator-wizardry-start-prompt.png"))
            return 0
        } catch {
            fputs("Unable to verify Wizardry start prompt: \(error)\n", stderr)
            return 1
        }
    }

    private static func traceWizardryStartKeys() -> Int32 {
        let machine = AppleIIMachine()
        machine.loadBundledGame(.wizardry)
        for step in 0..<90 {
            if step.isMultiple(of: 5) { machine.memory.latchKey(0xA0) }
            machine.runForVerification(cycles: 1_000_000)
            let video = machine.videoSnapshot
            let screen = String(video.text.map { byte in
                let code = byte & 0x7F
                return code >= 0x20 && code < 0x7F ? Character(UnicodeScalar(code)) : " "
            })
            if screen.contains("S)TART GAME") {
                fputs("Wizardry start menu at \(step + 1)M cycles\\n", stderr)
                machine.memory.latchKey(0xD3)
                machine.runForVerification(cycles: 5_000_000)
                try? writePNG(machine.videoSnapshot, to: URL(fileURLWithPath: "/private/tmp/AppleIIEmulator-wizardry-after-start-menu.png"))
                return 0
            }
        }
        fputs("Wizardry start menu was not reached.\\n", stderr)
        return 1
    }

    private static func writePNG(_ video: AppleIIVideoSnapshot, to url: URL) throws {
        let size = NSSize(width: 800, height: 480)
        guard let image = NSBitmapImageRep(
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
        ), let context = NSGraphicsContext(bitmapImageRep: image) else {
            throw CocoaError(.fileWriteUnknown)
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        defer { NSGraphicsContext.restoreGraphicsState() }

        NSColor(red: 0.01, green: 0.04, blue: 0.02, alpha: 1).setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()

        if video.textMode {
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
                    case let .normal(value), let .inverse(value): glyph = String(UnicodeScalar(value < 0x20 ? value + 0x40 : value))
                    case let .alternate(value), let .alternateInverse(value): glyph = value < 0x20 ? "•" : String(UnicodeScalar(value))
                    case let .ascii(value): glyph = value >= 0x20 ? String(UnicodeScalar(value)) : " "
                    }
                    (glyph as NSString).draw(at: NSPoint(x: CGFloat(column) * cell.width, y: size.height - CGFloat(row + 1) * cell.height), withAttributes: attributes)
                }
            }
        } else if video.hires {
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
                let bytes = (0..<40).map { video.hgrByte(column: $0, row: row, auxiliary: false) }
                for (column, color) in appleIIHiResDots(bytes: bytes).enumerated() where color != .black {
                    palette[color]?.setFill()
                    NSBezierPath(rect: NSRect(
                        x: CGFloat(column) * dotSize.width,
                        y: size.height - CGFloat(row + 1) * dotSize.height,
                        width: dotSize.width + 0.1,
                        height: dotSize.height + 0.1
                    )).fill()
                }
            }
        } else {
            let palette: [NSColor] = [
                .black,
                NSColor(red: 0.70, green: 0.12, blue: 0.70, alpha: 1),
                NSColor(red: 0.12, green: 0.12, blue: 0.70, alpha: 1),
                NSColor(red: 0.72, green: 0.24, blue: 0.82, alpha: 1),
                NSColor(red: 0.10, green: 0.48, blue: 0.18, alpha: 1),
                NSColor(red: 0.46, green: 0.46, blue: 0.46, alpha: 1),
                NSColor(red: 0.12, green: 0.42, blue: 0.90, alpha: 1),
                NSColor(red: 0.36, green: 0.62, blue: 0.95, alpha: 1),
                NSColor(red: 0.48, green: 0.28, blue: 0.10, alpha: 1),
                NSColor(red: 0.95, green: 0.30, blue: 0.12, alpha: 1),
                NSColor(red: 0.60, green: 0.60, blue: 0.60, alpha: 1),
                NSColor(red: 0.98, green: 0.55, blue: 0.22, alpha: 1),
                NSColor(red: 0.14, green: 0.80, blue: 0.30, alpha: 1),
                NSColor(red: 0.96, green: 0.96, blue: 0.30, alpha: 1),
                NSColor(red: 0.35, green: 0.82, blue: 0.82, alpha: 1),
                .white
            ]
            let cell = NSSize(width: size.width / 40, height: size.height / 48)
            for row in 0..<24 {
                for column in 0..<40 {
                    let value = video.loresByte(column: column, row: row)
                    palette[Int(value & 0x0F)].setFill()
                    NSBezierPath(rect: NSRect(x: CGFloat(column) * cell.width, y: size.height - CGFloat(row * 2 + 1) * cell.height, width: cell.width + 0.1, height: cell.height + 0.1)).fill()
                    palette[Int(value >> 4)].setFill()
                    NSBezierPath(rect: NSRect(x: CGFloat(column) * cell.width, y: size.height - CGFloat(row * 2 + 2) * cell.height, width: cell.width + 0.1, height: cell.height + 0.1)).fill()
                }
            }
        }

        guard let png = image.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try png.write(to: url)
    }
}
