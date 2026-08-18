import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

/// The text-video byte encodes its glyph in the low six bits and selects one
/// of three display attributes with bits 6–7.  Keeping this separate from the
/// renderer lets the IIc's ALTCHARSET soft switch affect both 40- and 80-column
/// output consistently.
enum AppleIITextCell: Equatable {
    case normal(UInt8)
    case inverse(UInt8)
    case alternate(UInt8)
}

func appleIITextCell(byte: UInt8, alternateCharset: Bool, flashOn: Bool) -> AppleIITextCell {
    let glyph = byte & 0x3F
    switch byte & 0xC0 {
    case 0x00:
        return .inverse(glyph)
    case 0x40:
        if alternateCharset { return .alternate(glyph) }
        return flashOn ? .normal(glyph) : .inverse(glyph)
    default:
        return .normal(glyph)
    }
}

/// Apple II+ motherboard model. The CPU owns no memory: every bus access goes
/// through this object, so soft switches remain observable and testable.
@MainActor
final class AppleIIMachine: ObservableObject {
    enum BootROM: String, CaseIterable, Identifiable, Hashable {
        case appleIIPlus
        case appleIIcROM00
        case appleIIcROM03
        case appleIIcROM04
        case appleIIcROMFF
        case diagnostic

        var id: Self { self }
        var title: String {
            switch self {
            case .appleIIPlus: return "Apple II+（游戏兼容）"
            case .appleIIcROM00: return "Apple IIc ROM 00"
            case .appleIIcROM03: return "Apple IIc ROM 03"
            case .appleIIcROM04: return "Apple IIc ROM 04"
            case .appleIIcROMFF: return "Apple IIc ROM FF"
            case .diagnostic: return "内置诊断 ROM"
            }
        }

        var resourceName: String? {
            switch self {
            case .appleIIPlus: return nil
            case .appleIIcROM00: return "AppleIIc-ROM00-342-0033-A"
            case .appleIIcROM03: return "AppleIIc-ROM03-341-0445-A"
            case .appleIIcROM04: return "AppleIIc-ROM04-341-0445-B"
            case .appleIIcROMFF: return "AppleIIc-ROMFF-342-0272-A"
            case .diagnostic: return nil
            }
        }
    }

    /// A small, deterministic set of games shown in the default GAME menu.
    /// They are packaged with the app so launching one never opens a file picker.
    enum BundledGame: String, CaseIterable, Identifiable {
        case galaxy
        case jBird
        case oceanNight

        var id: Self { self }

        var title: String {
            switch self {
            case .galaxy: return "Galaxy"
            case .jBird: return "J-Bird"
            case .oceanNight: return "Ocean Night"
            }
        }

        var resourceName: String {
            switch self {
            case .galaxy: return "galaxy"
            case .jBird: return "j-bird"
            case .oceanNight: return "Ocean Night (compatiboot)"
            }
        }

        var resourceExtension: String {
            switch self {
            case .galaxy: return "do"
            case .jBird, .oceanNight: return "dsk"
            }
        }

        var diskFirmware: AppleIIMemory.DiskIIFirmware {
            switch self {
            case .galaxy, .jBird, .oceanNight: return .sixteenSector
            }
        }

    }

    @Published private(set) var isRunning = true
    @Published private(set) var hasExternalROM = false
    @Published private(set) var status = "Apple II+（内置） · 未插入磁盘"
    @Published private(set) var refreshToken = 0
    @Published private(set) var selectedBootROM: BootROM = .appleIIPlus
    @Published private(set) var diskDescription = "未插入"
    @Published private(set) var externalDiskDescription = "未插入"

    private let gameLibrary = GameLibrary()
    /// Grouping keeps the in-app GAME menu navigable even with a large game
    /// collection rather than presenting hundreds of entries in one list.
    var downloadedGames: [GameLibrary.Game] { gameLibrary.games }

    let memory = AppleIIMemory()
    private var cpu: MOS6502!
    private let speaker = AppleIISpeaker()
    private var timer: Timer?
    private var keyboardMonitor: Any?
    private var keyboardReleaseMonitor: Any?
    private var modifierMonitor: Any?
    // The speaker is timed by CPU cycles, so the CPU must follow a monotonic
    // clock rather than assuming the UI timer always arrives at exactly 60 Hz.
    // A delayed SwiftUI/AppKit frame otherwise stretches every 1-bit waveform
    // and turns game audio into a burst of distorted clicks.
    private var lastEmulationTick = ProcessInfo.processInfo.systemUptime
    private var fractionalCPUCycles = 0.0
    private var inputState = AppleIIInputState()
    /// A diskless Apple II+ reaches ROM Applesoft through the Autostart ROM's
    /// warm-reset path after it has shown the power-on banner.
    private var applesoftWarmStartDeadline: TimeInterval?

    init() {
        memory.speakerDidToggleAtCycle = { [weak speaker] cycle in
            speaker?.toggle(atEmulatedCycle: cycle)
        }
        cpu = MOS6502(bus: memory)
        // Start as an unmodified Apple II+: the real autostart ROM produces
        // its familiar `APPLE ][` power-on screen.  A diagnostic disk is an
        // explicit menu tool, never the user's default operating environment.
        selectROM(.appleIIPlus)
        // AppKit delivers this before the responder chain, so Apple II input
        // works even when Canvas is not the current first responder.
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.keyDown(event)
            return event
        }
        keyboardReleaseMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { [weak self] event in
            self?.keyUp(event)
            return event
        }
        modifierMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.modifierFlagsChanged(event.modifierFlags)
            return event
        }
        // `swift run` launches from Terminal, which otherwise remains the key
        // application on some macOS versions. Claim foreground activation once
        // SwiftUI has attached its window to the run loop.
        DispatchQueue.main.async {
            if let application = NSApp {
                application.setActivationPolicy(.regular)
                application.activate(ignoringOtherApps: true)
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    deinit {
        timer?.invalidate()
        if let keyboardMonitor { NSEvent.removeMonitor(keyboardMonitor) }
        if let keyboardReleaseMonitor { NSEvent.removeMonitor(keyboardReleaseMonitor) }
        if let modifierMonitor { NSEvent.removeMonitor(modifierMonitor) }
    }

    func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        defer { lastEmulationTick = now }
        guard isRunning else { return }
        // Audio output is clocked independently of the UI. Derive the work
        // budget from elapsed wall time so a slow frame does not slow the
        // emulated speaker and lower the pitch. Cap catch-up to avoid a long
        // foreground pause making the UI unresponsive.
        let elapsed = min(0.050, max(0, now - lastEmulationTick))
        fractionalCPUCycles += elapsed * 1_021_800.0
        let cycles = Int(fractionalCPUCycles)
        fractionalCPUCycles -= Double(cycles)
        if cycles > 0 { cpu.run(cycles: cycles) }
        if let deadline = applesoftWarmStartDeadline, now >= deadline {
            // This deliberately resets only the CPU. Resetting I/O hardware
            // would erase the ROM's cold-start marker and restart disk boot.
            cpu.reset()
            applesoftWarmStartDeadline = nil
            status = "Apple II+（内置） · Applesoft BASIC"
        }
        speaker.advance(toEmulatedCycle: cpu.totalCycles)
        refreshToken &+= 1
    }

    /// Narrow diagnostic seam for regression tests: it runs the same CPU and
    /// bus path as the display timer without needing an AppKit run loop.
    func runForVerification(cycles: Int) {
        cpu.run(cycles: cycles)
        speaker.advance(toEmulatedCycle: cpu.totalCycles)
        refreshToken &+= 1
    }

    var encounteredUnsupportedCPUOpcodes: Set<UInt8> { cpu.unsupportedOpcodes }
    var executedCPUCycles: Int { cpu.totalCycles }
    /// Current CPU location, exposed to the regression suite so a disk loader
    /// that silently falls back into BASIC cannot look like a successful boot.
    var programCounter: UInt16 { cpu.pc }
    var lastUnsupportedInstructionAddress: UInt16 { cpu.lastUnsupportedInstructionAddress }
    var recentInstructions: [(UInt16, UInt8)] { cpu.recentInstructions }
    /// Observable boot-progress seam: disk-loaded Apple II programs execute
    /// from RAM below $C000, whereas the reset firmware lives in ROM above it.
    var hasExecutedRAMCode: Bool { cpu.hasExecutedRAMInstruction }

    func reset() {
        applesoftWarmStartDeadline = nil
        memory.resetHardwareState()
        cpu.reset()
        isRunning = true
        fractionalCPUCycles = 0
        lastEmulationTick = ProcessInfo.processInfo.systemUptime
        refreshToken &+= 1
    }

    func toggleRunning() {
        isRunning.toggle()
        lastEmulationTick = ProcessInfo.processInfo.systemUptime
    }

    func keyDown(_ event: NSEvent) {
        updateJoystick(for: event.keyCode, pressed: true)
        let key: UInt8
        switch event.keyCode {
        case 51: key = 0x88 // Apple II backspace / left arrow
        case 36: key = 0x8D // return
        case 53: key = 0x9B // escape
        case 48: key = 0x89 // tab
        case 123: key = 0x88 // left arrow
        case 124: key = 0x95 // right arrow (Ctrl-U)
        case 125: key = 0x8A // down arrow (Ctrl-J)
        case 126: key = 0x8B // up arrow (Ctrl-K)
        default:
            let characters = event.modifierFlags.contains(.control) ? event.charactersIgnoringModifiers : event.characters
            guard let scalar = characters?.unicodeScalars.first,
                  let translated = Self.appleKeyboardByte(forASCII: scalar.value, control: event.modifierFlags.contains(.control)) else { return }
            key = translated
        }
        memory.latchKey(key)
    }

    func keyUp(_ event: NSEvent) {
        updateJoystick(for: event.keyCode, pressed: false)
    }

    private func updateJoystick(for keyCode: UInt16, pressed: Bool) {
        if let paddles = inputState.setJoystickKey(keyCode, pressed: pressed) {
            memory.setPaddles(paddles)
        }
    }

    /// The Apple II keyboard presents uppercase ASCII plus a strobe bit.  We
    /// take normal macOS shifted punctuation from `characters`, but normalize
    /// alphabetic keys here so entering `a` behaves exactly like a physical
    /// Apple II keyboard press of `A`.
    nonisolated static func appleKeyboardByte(forASCII value: UInt32, control: Bool) -> UInt8? {
        guard value >= 0x20 && value <= 0x7E else { return nil }
        var ascii = UInt8(value)
        if (0x61...0x7A).contains(ascii) { ascii &-= 0x20 }
        return control ? (ascii & 0x1F) | 0x80 : ascii | 0x80
    }

    func modifierFlagsChanged(_ flags: NSEvent.ModifierFlags) {
        // The IIc has no physical joystick buttons on the keyboard, but its
        // Open-Apple/Closed-Apple keys feed the standard PB0/PB1 softswitches.
        memory.setButtons(openApple: flags.contains(.command), closedApple: flags.contains(.option))
    }

    func selectROM(_ choice: BootROM) {
        selectedBootROM = choice
        switch choice {
        case .appleIIPlus:
            do {
                try memory.loadBundledAppleIIPlusROM(diskFirmware: .sixteenSector)
                hasExternalROM = true
                status = "Apple II+（内置） · \(diskDescription)"
            } catch {
                installDiagnosticROM()
                status = "内置诊断 ROM（Apple II+ ROM 未找到）"
            }
        case .appleIIcROM00, .appleIIcROM03, .appleIIcROM04, .appleIIcROMFF:
            do {
                try memory.loadBundledAppleIIcROM(named: choice.resourceName!)
                hasExternalROM = true
                status = "\(choice.title)（内置） · \(diskDescription)"
            } catch {
                installDiagnosticROM()
                status = "内置诊断 ROM（\(choice.title) 未找到）"
            }
        case .diagnostic:
            installDiagnosticROM()
            hasExternalROM = false
            status = "内置诊断 ROM"
        }
        reset()
        scheduleApplesoftWarmStartIfDiskless()
    }

    private func installDiagnosticROM() {
        memory.installDiagnosticProgram()
    }

    func insertDiagnosticDisk() {
        do {
            try memory.mountDSK(DiskII.diagnosticDSK())
            diskDescription = "测试启动盘（.dsk）"
            status = "\(selectedBootROM.title) · \(diskDescription)"
            reset()
        } catch {
            status = "无法插入测试启动盘"
        }
    }

    func loadBundledGame(_ game: BundledGame) {
        guard let url = AppResources.bundle.url(
            forResource: game.resourceName,
            withExtension: game.resourceExtension
        ) else {
            status = "未找到内置游戏：\(game.title)"
            return
        }

        do {
            try memory.loadBundledAppleIIPlusROM(diskFirmware: game.diskFirmware)
            // Legacy 13-sector archival images are often padded to the
            // modern 140 KB .dsk length, so their byte count alone cannot
            // identify the format. The bundled title declares its controller
            // firmware and mounts through the matching sector codec.
            if game.diskFirmware == .thirteenSector {
                try memory.mountThirteenSectorDisk(Data(contentsOf: url), drive: 0)
            } else {
                try memory.mountDiskImage(at: url, drive: 0)
            }
            selectedBootROM = .appleIIPlus
            diskDescription = game.title
            status = "Apple II+ · \(game.diskFirmware.title) · \(game.title)"
            reset()
        } catch {
            status = "无法装入内置游戏：\(game.title)"
        }
    }

    var downloadedGameInitials: [String] {
        gameLibrary.initials
    }

    func downloadedGames(startingWith initial: String) -> [GameLibrary.Game] {
        gameLibrary.games(startingWith: initial)
    }

    func loadDownloadedGame(_ game: GameLibrary.Game) {
        loadDownloadedGame(at: game.url, title: game.title)
    }

    /// Opens an image from the collection downloaded alongside this project.
    /// Keeping this collection outside the app bundle makes it possible to
    /// resume or extend the archive without rebuilding the application.
    func chooseDownloadedGame() {
        let panel = NSOpenPanel()
        panel.title = "从已下载游戏库装入游戏"
        panel.message = "选择一个 Apple II 5¼ 英寸游戏映像；将自动装入驱动器 1 并以 Apple II+ 启动"
        panel.allowedContentTypes = ["dsk", "do", "d13", "po", "nib", "2mg", "2img"].compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if let directory = Self.downloadedGamesDirectory() {
            panel.directoryURL = directory
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }

        loadDownloadedGame(at: url, title: url.lastPathComponent)
    }

    private func loadDownloadedGame(at url: URL, title: String) {
        do {
            try memory.loadBundledAppleIIPlusROM(diskFirmware: .sixteenSector)
            try memory.mountDiskImage(at: url, drive: 0)
            selectedBootROM = .appleIIPlus
            diskDescription = title
            status = "Apple II+ · Disk II 16 扇区 · \(title)"
            reset()
        } catch {
            status = "无法装入 \(title)：仅支持 .dsk/.do/.d13/.po/.nib/.2mg/.2img"
        }
    }

    /// `swift run` starts in the package root, while the packaged app is
    /// normally launched from `build/`. Check both forms so the picker opens
    /// directly in the collection whenever it is available.
    private static func downloadedGamesDirectory() -> URL? {
        let relativePath = "Downloads/AppleIIGames/ftp.apple.asimov.net/images/games/action"
        var roots = [URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)]
        for bundleURL in [Bundle.main.bundleURL, AppResources.bundle.bundleURL] {
            var ancestor = bundleURL
            for _ in 0..<8 {
                ancestor.deleteLastPathComponent()
                roots.append(ancestor)
            }
        }
        return roots
            .map { $0.appendingPathComponent(relativePath, isDirectory: true) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    func chooseDiskImage(drive: Int = 0) {
        let panel = NSOpenPanel()
        panel.title = "插入 Apple II 磁盘映像到驱动器 \(drive + 1)"
        panel.message = "支持 .dsk/.do、13 扇区 .d13、ProDOS .po、.nib，以及 5¼ 英寸 .2mg/.2img 映像"
        panel.allowedContentTypes = ["dsk", "do", "d13", "po", "nib", "2mg", "2img"].compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try memory.mountDiskImage(at: url, drive: drive)
            setDiskDescription(url.lastPathComponent, drive: drive)
            status = "\(selectedBootROM.title) · 驱动器 \(drive + 1)：\(url.lastPathComponent)"
            reset()
        } catch {
            status = "无法读取 \(url.lastPathComponent)：仅支持 .dsk/.do/.d13/.po/.nib/.2mg/.2img"
        }
    }

    func ejectDisk(drive: Int = 0) {
        memory.ejectDisk(drive: drive)
        setDiskDescription("未插入", drive: drive)
        status = "\(selectedBootROM.title) · 驱动器 \(drive + 1) 未插入磁盘"
        reset()
        scheduleApplesoftWarmStartIfDiskless()
    }

    func saveDiskAsNIB(drive: Int = 0) {
        guard let data = memory.nibImage(drive: drive) else {
            status = "驱动器 \(drive + 1) 的磁盘无法导出为 .nib"
            return
        }
        let panel = NSSavePanel()
        panel.title = "保存 Apple II 磁盘映像"
        panel.nameFieldStringValue = "AppleII-Drive\(drive + 1).nib"
        panel.allowedContentTypes = [.init(filenameExtension: "nib")!]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url, options: .atomic)
            setDiskDescription(url.lastPathComponent, drive: drive)
            status = "已保存驱动器 \(drive + 1)：\(url.lastPathComponent)"
        } catch {
            status = "无法保存 \(url.lastPathComponent)"
        }
    }

    private func setDiskDescription(_ description: String, drive: Int) {
        if drive == 0 { diskDescription = description }
        else { externalDiskDescription = description }
    }

    private func scheduleApplesoftWarmStartIfDiskless() {
        guard selectedBootROM == .appleIIPlus, !memory.hasDisk(in: 0) else { return }
        // The bundled ROM needs about half a million emulated cycles to set
        // its cold-start marker before a warm RESET can enter Applesoft.
        applesoftWarmStartDeadline = ProcessInfo.processInfo.systemUptime + 0.60
    }
}

final class AppleIIMemory: AppleIIBus {
    enum Model: Equatable { case appleIIPlus, appleIIc }
    enum DiskIIFirmware: Equatable {
        case thirteenSector, sixteenSector

        var resourceName: String {
            switch self {
            case .thirteenSector: return "DiskII-13sector-341-0009"
            case .sixteenSector: return "DiskII-16sector-341-0027"
            }
        }

        var title: String { self == .thirteenSector ? "Disk II 13 扇区" : "Disk II 16 扇区" }
    }
    private(set) var bytes = [UInt8](repeating: 0, count: 65_536)
    private var auxiliaryBytes = [UInt8](repeating: 0, count: 65_536)
    private var iicROM = [UInt8]()
    private var iicROMBank = 0
    private var plusSlot6ROM = [UInt8]()
    private var plusDiskFirmware: DiskIIFirmware?
    private(set) var model: Model = .appleIIPlus
    var modelName: String { model == .appleIIc ? "Apple IIc" : "Apple II+" }
    private var keyLatch: UInt8 = 0
    private(set) var textMode = true
    private(set) var mixedMode = false
    private(set) var page2 = false
    private(set) var hires = false
    private(set) var column80 = false
    private(set) var store80 = false
    private(set) var ramReadAuxiliary = false
    private(set) var ramWriteAuxiliary = false
    private(set) var internalCXROM = false
    private(set) var slot3ROM = false
    private(set) var doubleHires = false
    private(set) var alternateZeroPage = false
    private(set) var alternateCharset = false
    private let diskController = IWMController()
    private(set) var speakerFlips = 0
    var speakerDidToggle: (() -> Void)?
    var speakerDidToggleAtCycle: ((Int) -> Void)?
    private var speakerCycle = 0
    // NTSC Apple II timing: 65 CPU cycles × 262 scan lines per frame.  The
    // display renderer does not require every scanline, but software polling
    // $C019 absolutely does.
    private var videoClock = 0
    private var iiCVBLFlag = false
    private var iicIOUDisabled = false
    private var iicVBLEnabled = false
    private var paddleElapsedCycles = 0
    private var paddles: [UInt8] = [127, 127, 127, 127]
    private var openAppleDown = false
    private var closedAppleDown = false
    var videoState: AppleIIVideoState {
        AppleIIVideoState(
            textMode: textMode, mixedMode: mixedMode, hires: hires,
            doubleHires: doubleHires, column80: column80,
            alternateCharset: alternateCharset,
            textByte: { [weak self] column, row in self?.textByte(column: column, row: row) ?? 0 },
            loresByte: { [weak self] column, row in self?.loresByte(column: column, row: row) ?? 0 },
            hgrByte: { [weak self] column, row, auxiliary in self?.hgrByte(column: column, row: row, auxiliary: auxiliary) ?? 0 }
        )
    }
    private static let cyclesPerLine = 65
    private static let linesPerFrame = 262

    func read(_ address: UInt16) -> UInt8 {
        let a = Int(address)
        switch a {
        case 0xC000: return keyLatch
        case 0xC001: store80 = true; return 0
        case 0xC002: ramReadAuxiliary = false; return 0
        case 0xC003: ramReadAuxiliary = true; return 0
        case 0xC004: ramWriteAuxiliary = false; return 0
        case 0xC005: ramWriteAuxiliary = true; return 0
        case 0xC006: internalCXROM = false; return 0
        case 0xC007: internalCXROM = true; return 0
        case 0xC008: alternateZeroPage = false; return 0
        case 0xC009: alternateZeroPage = true; return 0
        case 0xC00A: slot3ROM = false; return 0
        case 0xC00B: slot3ROM = true; return 0
        case 0xC00C: column80 = false; return 0
        case 0xC00D: column80 = true; return 0
        case 0xC00E: alternateCharset = false; return 0
        case 0xC00F: alternateCharset = true; return 0
        case 0xC010: keyLatch &= 0x7F; return keyLatch
        case 0xC011: return status(false) // IIc's bank-2 language-card status
        case 0xC012: return status(false) // ROM selected at $D000-$FFFF
        case 0xC013: return status(ramReadAuxiliary)
        case 0xC014: return status(ramWriteAuxiliary)
        case 0xC015: return status(internalCXROM)
        case 0xC016: return status(alternateZeroPage)
        case 0xC017: return status(slot3ROM)
        case 0xC018: return status(store80)
        case 0xC019: return model == .appleIIc ? status(iiCVBLFlag) : status(!verticalBlank)
        case 0xC061: return status(openAppleDown)
        case 0xC062: return status(closedAppleDown)
        case 0xC063: return 0
        case 0xC064...0xC067: return status(paddleElapsedCycles < (Int(paddles[a - 0xC064]) + 1) * 11)
        case 0xC070: iiCVBLFlag = false; paddleElapsedCycles = 0; return 0 // PTRIG also clears the IIc VBL latch
        case 0xC07E where model == .appleIIc:
            iiCVBLFlag = false // RDIOUDIS also clears the VBL latch
            return status(iicIOUDisabled)
        case 0xC07F where model == .appleIIc:
            iicIOUDisabled = true
            return 0
        case 0xC01A: return status(textMode)
        case 0xC01B: return status(mixedMode)
        case 0xC01C: return status(page2)
        case 0xC01D: return status(hires)
        case 0xC01E: return status(alternateCharset)
        case 0xC01F: return status(column80)
        case 0xC080...0xC08F where model == .appleIIc:
            return accessIWM(a, write: nil)
        case 0xC0E0...0xC0EF:
            return accessIWM(a, write: nil)
        case 0xC030: toggleSpeaker(); return 0
        case 0xC050: textMode = false; return 0
        case 0xC051: textMode = true; return 0
        case 0xC052: mixedMode = false; return 0
        case 0xC053: mixedMode = true; return 0
        case 0xC054: page2 = false; return 0
        case 0xC055: page2 = true; return 0
        case 0xC056: hires = false; return 0
        case 0xC057: hires = true; return 0
        case 0xC05A where model == .appleIIc: iicVBLEnabled = false; return 0
        case 0xC05B where model == .appleIIc: iicVBLEnabled = iicIOUDisabled; return 0
        // On an Apple II/II+, these are AN3 (annunciator 3) accesses. They
        // become the DHIRES switches only when the IIc IOU is disabled:
        // C05E enables double-hi-res and C05F disables it.
        case 0xC05E where model == .appleIIc && iicIOUDisabled: doubleHires = true; return 0
        case 0xC05F where model == .appleIIc && iicIOUDisabled: doubleHires = false; return 0
        case 0xC05E, 0xC05F: return 0
        case 0xC028 where model == .appleIIc:
            iicROMBank ^= 1
            return 0
        default:
            // IIc uses two 16 KB ROM banks. $C000-$C0FF remains I/O;
            // $C100-$FFFF exposes the selected bank of the 32 KB ROM.
            if model == .appleIIc, a >= 0xC100, iicROM.count == 0x8000 {
                return iicROM[iicROMBank * 0x4000 + (a - 0xC000)]
            }
            if model == .appleIIPlus, (0xC600...0xC6FF).contains(a), plusSlot6ROM.count == 0x100 {
                return plusSlot6ROM[a - 0xC600]
            }
            return useAuxiliaryRead(for: a) ? auxiliaryBytes[a] : bytes[a]
        }
    }

    func write(_ address: UInt16, _ value: UInt8) {
        let a = Int(address)
        switch a {
        case 0xC000: store80 = false
        case 0xC001: store80 = true
        case 0xC002: ramReadAuxiliary = false
        case 0xC003: ramReadAuxiliary = true
        case 0xC004: ramWriteAuxiliary = false
        case 0xC005: ramWriteAuxiliary = true
        case 0xC006: internalCXROM = false
        case 0xC007: internalCXROM = true
        case 0xC008: alternateZeroPage = false
        case 0xC009: alternateZeroPage = true
        case 0xC00A: slot3ROM = false
        case 0xC00B: slot3ROM = true
        case 0xC00C: column80 = false
        case 0xC00D: column80 = true
        case 0xC00E: alternateCharset = false
        case 0xC00F: alternateCharset = true
        case 0xC010...0xC01F: keyLatch &= 0x7F
        case 0xC080...0xC08F where model == .appleIIc: _ = accessIWM(a, write: value)
        case 0xC0E0...0xC0EF: _ = accessIWM(a, write: value)
        case 0xC030: toggleSpeaker()
        case 0xC050: textMode = false
        case 0xC051: textMode = true
        case 0xC052: mixedMode = false
        case 0xC053: mixedMode = true
        case 0xC054: page2 = false
        case 0xC055: page2 = true
        case 0xC056: hires = false
        case 0xC057: hires = true
        case 0xC05A where model == .appleIIc: iicVBLEnabled = false
        case 0xC05B where model == .appleIIc: iicVBLEnabled = iicIOUDisabled
        case 0xC05E where model == .appleIIc && iicIOUDisabled: doubleHires = true
        case 0xC05F where model == .appleIIc && iicIOUDisabled: doubleHires = false
        case 0xC05E, 0xC05F: break
        case 0xC070: iiCVBLFlag = false; paddleElapsedCycles = 0
        case 0xC07E where model == .appleIIc: iiCVBLFlag = false
        case 0xC07F where model == .appleIIc: iicIOUDisabled = true
        case 0xC028 where model == .appleIIc: iicROMBank ^= 1
        default:
            if model == .appleIIc, a >= 0xC100 { return }
            if model == .appleIIPlus, (0xC600...0xC6FF).contains(a) { return }
            if model == .appleIIPlus, a >= 0xD000 { return }
            if useAuxiliaryWrite(for: a) { auxiliaryBytes[a] = value } else { bytes[a] = value }
        }
    }

    func latchKey(_ key: UInt8) { keyLatch = key }

    func loadROM(_ data: Data) {
        if data.count == 0x8000 {
            model = .appleIIc
            iicROM = Array(data)
            iicROMBank = 0
        } else {
            model = .appleIIPlus
            iicROM = []
            let start = 0x10000 - data.count
            bytes.replaceSubrange(start..<0x10000, with: data)
        }
    }

    func loadBundledAppleIIcROM(named name: String) throws {
        guard let url = AppResources.bundle.url(forResource: name, withExtension: "bin") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let data = try Data(contentsOf: url)
        guard data.count == 0x4000 || data.count == 0x8000 else { throw CocoaError(.fileReadCorruptFile) }
        model = .appleIIc
        let bank = Array(data)
        iicROM = data.count == 0x4000 ? bank + bank : bank
        iicROMBank = 0
    }

    func loadBundledAppleIIPlusROM(diskFirmware: DiskIIFirmware) throws {
        guard let systemURL = AppResources.bundle.url(forResource: "AppleIIPlus-Applesoft-Autostart", withExtension: "rom"),
              let diskURL = AppResources.bundle.url(forResource: diskFirmware.resourceName, withExtension: "rom") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let systemROM = try Data(contentsOf: systemURL)
        let diskROM = try Data(contentsOf: diskURL)
        guard systemROM.count == 0x3000, diskROM.count == 0x100 else { throw CocoaError(.fileReadCorruptFile) }
        model = .appleIIPlus
        iicROM = []
        iicROMBank = 0
        plusSlot6ROM = Array(diskROM)
        plusDiskFirmware = diskFirmware
        bytes = [UInt8](repeating: 0, count: 65_536)
        auxiliaryBytes = [UInt8](repeating: 0, count: 65_536)
        bytes.replaceSubrange(0xD000..<0x10000, with: systemROM)
    }

    func resetROMBank() { iicROMBank = 0 }

    func resetHardwareState() {
        iicROMBank = 0
        keyLatch = 0
        textMode = true
        mixedMode = false
        page2 = false
        hires = false
        column80 = false
        store80 = false
        ramReadAuxiliary = false
        ramWriteAuxiliary = false
        internalCXROM = false
        slot3ROM = false
        doubleHires = false
        alternateZeroPage = false
        alternateCharset = false
        diskController.reset()
        videoClock = 0
        iiCVBLFlag = false
        iicIOUDisabled = false
        iicVBLEnabled = false
        paddleElapsedCycles = 0
    }

    private func useAuxiliaryRead(for address: Int) -> Bool {
        guard model == .appleIIc, address < 0xC000 else { return false }
        if alternateZeroPage && address < 0x0200 { return true }
        if store80 && isVideoPage(address) { return page2 }
        return ramReadAuxiliary
    }

    private func useAuxiliaryWrite(for address: Int) -> Bool {
        guard model == .appleIIc, address < 0xC000 else { return false }
        if alternateZeroPage && address < 0x0200 { return true }
        if store80 && isVideoPage(address) { return page2 }
        return ramWriteAuxiliary
    }

    private func isVideoPage(_ address: Int) -> Bool {
        // With 80STORE set, PAGE2 no longer chooses a displayed page.  It
        // redirects CPU accesses to the auxiliary *page 1* window: text/
        // lo-res at $0400-$07FF, or HGR at $2000-$3FFF.  Page 2 remains
        // normal RAM in this mode.
        if hires { return (0x2000...0x3FFF).contains(address) }
        return (0x0400...0x07FF).contains(address)
    }

    private func status(_ enabled: Bool) -> UInt8 { enabled ? 0x80 : 0x00 }

    private func toggleSpeaker() {
        speakerFlips &+= 1
        speakerDidToggle?()
        speakerDidToggleAtCycle?(speakerCycle)
    }

    /// The CPU updates this immediately before executing each instruction,
    /// which gives soft-switch edges a stable emulated-time coordinate before
    /// the instruction's final cycle count is known.
    func setSpeakerCycle(_ cycle: Int) {
        speakerCycle = cycle
    }

    func advanceVideoClock(by cycles: Int) {
        let frameCycles = Self.cyclesPerLine * Self.linesPerFrame
        let oldLine = videoClock / Self.cyclesPerLine
        videoClock = (videoClock + cycles) % frameCycles
        let newLine = videoClock / Self.cyclesPerLine
        paddleElapsedCycles = min(Int.max - cycles, paddleElapsedCycles) + cycles
        // Disk II hardware is clocked by the machine, not by reads of its
        // soft switches.  Keeping it on the same cycle source as video and
        // paddles preserves the timing expected by boot loaders.
        diskController.advance(by: cycles)
        if model == .appleIIc, iicVBLEnabled, oldLine < 192, (newLine >= 192 || newLine < oldLine) {
            iiCVBLFlag = true
        }
    }

    private var verticalBlank: Bool { videoClock / Self.cyclesPerLine >= 192 }

    func setButtons(openApple: Bool, closedApple: Bool) {
        openAppleDown = openApple
        closedAppleDown = closedApple
    }

    func setPaddles(_ values: [UInt8]) {
        for index in paddles.indices where values.indices.contains(index) { paddles[index] = values[index] }
    }

    func mountDSK(_ data: Data, drive: Int = 0) throws { try diskController.mountDSK(data, drive: drive) }
    func mountThirteenSectorDisk(_ data: Data, drive: Int = 0) throws { try diskController.mountThirteenSectorImage(data, drive: drive) }
    func mountDiskImage(at url: URL, drive: Int = 0) throws { try diskController.mountImage(Data(contentsOf: url), fileExtension: url.pathExtension, drive: drive) }
    func mountDiskImageData(_ data: Data, fileExtension: String, drive: Int = 0) throws { try diskController.mountImage(data, fileExtension: fileExtension, drive: drive) }
    func nibImage(drive: Int = 0) -> Data? { diskController.nibImage(drive: drive) }
    func ejectDisk(drive: Int = 0) { diskController.eject(drive: drive) }
    var hasDisk: Bool { diskController.hasDisk }
    func hasDisk(in drive: Int) -> Bool { diskController.hasDisk(in: drive) }
    var diskNibbleReads: Int { diskController.nibbleReads }
    var diskNibbleWrites: Int { diskController.nibbleWrites }
    var diskTrack: Int { diskController.currentTrack() }

    /// The IIc's integrated IWM occupies slot-zero I/O ($C080-$C08F). This
    /// models its control latch and data path; the sector stream is attached
    /// to this same state machine by the disk-image layer.
    private func accessIWM(_ address: Int, write value: UInt8?) -> UInt8 {
        diskController.access(address, write: value)
    }

    func installDiagnosticProgram() {
        model = .appleIIPlus
        iicROM = []
        iicROMBank = 0
        bytes = [UInt8](repeating: 0, count: 65_536)
        auxiliaryBytes = [UInt8](repeating: 0, count: 65_536)
        // A tiny non-Apple ROM used solely to prove that CPU, RAM and video
        // wiring work before the user supplies their own legally obtained ROM.
        let program: [UInt8] = [
            0xA2, 0x00,             // LDX #0
            0xBD, 0x25, 0x08,       // LDA $0825,X
            0xF0, 0x07,             // BEQ $080E
            0x9D, 0x00, 0x04,       // STA $0400,X
            0xE8,                   // INX
            0x4C, 0x02, 0x08,       // JMP $0802
            0xA2, 0x00,             // LDX #0
            0xAD, 0x00, 0xC0,       // LDA $C000 (keyboard latch)
            0x10, 0xFB,             // BPL $0810 (wait for strobe bit)
            0x9D, 0x00, 0x04,       // STA $0400,X (echo key)
            0xE8,                   // INX
            0xE0, 0x28,             // CPX #40
            0xD0, 0x02,             // BNE $081F
            0xA2, 0x00,             // LDX #0
            0xAD, 0x10, 0xC0,       // LDA $C010 (clear strobe)
            0x4C, 0x10, 0x08        // JMP $0810
        ] + Array("APPLE II READY - TYPE KEYS".utf8).map { $0 | 0x80 } + [0]
        bytes.replaceSubrange(0x0800..<(0x0800 + program.count), with: program)
        bytes[0xFFFC] = 0x00
        bytes[0xFFFD] = 0x08
    }

    func textByte(column: Int, row: Int) -> UInt8 {
        // 80STORE repurposes PAGE2 for CPU bank selection; the video
        // generator continues to scan page 1 in that configuration.
        let base = !store80 && page2 ? 0x0800 : 0x0400
        let memoryColumn = column80 ? column / 2 : column
        let offset = (row & 0x07) * 0x80 + (row >> 3) * 0x28 + memoryColumn
        if column80 && column.isMultiple(of: 2) { return auxiliaryBytes[base + offset] }
        return bytes[base + offset]
    }

    /// Raw video bytes deliberately bypass RAMRD/RAMWRT: the video generator
    /// sees the selected display bank, not the CPU's currently selected bank.
    func loresByte(column: Int, row: Int) -> UInt8 {
        let base = !store80 && page2 ? 0x0800 : 0x0400
        let offset = (row & 0x07) * 0x80 + (row >> 3) * 0x28 + column
        return bytes[base + offset]
    }

    func hgrByte(column: Int, row: Int, auxiliary: Bool = false) -> UInt8 {
        let base = !store80 && page2 ? 0x4000 : 0x2000
        // HGR scan lines are interleaved in three independent groups.  The
        // middle group uses only bits 3–5 of the row; without that mask rows
        // 64+ walk into the wrong 1 KB band and turn full-screen artwork into
        // vertical garbage.
        let offset = (row & 0x07) * 0x400 + ((row >> 3) & 0x07) * 0x80 + (row >> 6) * 0x28 + column
        return auxiliary ? auxiliaryBytes[base + offset] : bytes[base + offset]
    }
}
