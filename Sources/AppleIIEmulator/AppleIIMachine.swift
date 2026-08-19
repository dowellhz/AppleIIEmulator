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
    /// The original IIe alternate character ROM has inverse lowercase in
    /// $60-$7F. It is distinct from the enhanced IIe/IIc MouseText bank.
    case alternateInverse(UInt8)
    /// The IIe 80-column firmware can store seven-bit ASCII with bit 7 set.
    /// Applications such as WordPerfect use this for mixed-case text.
    case ascii(UInt8)
}

func appleIITextCell(byte: UInt8, alternateCharset: Bool, flashOn: Bool, supportsMouseText: Bool = true) -> AppleIITextCell {
    let glyph = byte & 0x3F
    switch byte & 0xC0 {
    case 0x00:
        return .inverse(glyph)
    case 0x40:
        if alternateCharset { return supportsMouseText ? .alternate(glyph) : .alternateInverse(glyph) }
        return flashOn ? .normal(glyph) : .inverse(glyph)
    default:
        return .normal(glyph)
    }
}

/// Decode a IIe 80-column cell.  The high-bit text bank is ASCII rather than
/// the 40-column six-bit character encoding; the lower banks retain the
/// normal/flash/MouseText behavior used for WordPerfect's window borders.
func appleII80ColumnTextCell(byte: UInt8, alternateCharset: Bool, flashOn: Bool, supportsMouseText: Bool = true) -> AppleIITextCell {
    if byte & 0x80 != 0 { return .ascii(byte & 0x7F) }
    return appleIITextCell(byte: byte, alternateCharset: alternateCharset, flashOn: flashOn, supportsMouseText: supportsMouseText)
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
        case appleIIeEnhanced
        case appleIIeUnenhanced
        case appleIIeCF
        case diagnostic
        case external

        var id: Self { self }
        var title: String {
            switch self {
            case .appleIIPlus: return "Apple II+（游戏兼容）"
            case .appleIIcROM00: return "Apple IIc ROM 00"
            case .appleIIcROM03: return "Apple IIc ROM 03"
            case .appleIIcROM04: return "Apple IIc ROM 04"
            case .appleIIcROMFF: return "Apple IIc ROM FF"
            case .appleIIeEnhanced: return "Apple IIe 增强型"
            case .appleIIeUnenhanced: return "Apple IIe 非增强型"
            case .appleIIeCF: return "Apple IIe CF ROM"
            case .diagnostic: return "内置诊断 ROM"
            case .external: return "外部 ROM"
            }
        }

        var resourceName: String? {
            switch self {
            case .appleIIPlus: return nil
            case .appleIIcROM00: return "AppleIIc-ROM00-342-0033-A"
            case .appleIIcROM03: return "AppleIIc-ROM03-341-0445-A"
            case .appleIIcROM04: return "AppleIIc-ROM04-341-0445-B"
            case .appleIIcROMFF: return "AppleIIc-ROMFF-342-0272-A"
            case .appleIIeEnhanced, .appleIIeUnenhanced, .appleIIeCF, .diagnostic, .external: return nil
            }
        }

        static let menuChoices: [BootROM] = [.appleIIPlus, .appleIIcROM00, .appleIIcROM03, .appleIIcROM04, .appleIIcROMFF, .appleIIeEnhanced, .appleIIeUnenhanced, .appleIIeCF, .diagnostic]
    }

    /// A small, deterministic set of games shown in the default GAME menu.
    /// They are packaged with the app so launching one never opens a file picker.
    enum BundledGame: String, CaseIterable, Identifiable {
        case falcons
        case jBird
        case oceanNight

        var id: Self { self }

        var title: String {
            switch self {
            case .falcons: return "Falcons (4am crack)"
            case .jBird: return "J-Bird"
            case .oceanNight: return "Ocean Night"
            }
        }

        var resourceName: String {
            switch self {
            case .falcons: return "Falcons (4am crack)"
            case .jBird: return "j-bird"
            case .oceanNight: return "Ocean Night (compatiboot)"
            }
        }

        var resourceExtension: String {
            switch self {
            case .falcons, .jBird, .oceanNight: return "dsk"
            }
        }

        var diskFirmware: AppleIIMemory.DiskIIFirmware {
            switch self {
            case .falcons, .jBird, .oceanNight: return .sixteenSector
            }
        }

    }

    /// Productivity disks are deliberately kept separate from the game picker:
    /// the two menus describe different ways people used an Apple II.
    enum BundledSoftware: String, CaseIterable, Identifiable {
        case appleWriter10
        case appleWriter11
        case wordPerfect11
        case visiCalc137
        case systemUtilities32
        case copyIIPlus55
        case applePascal13Boot

        var id: Self { self }

        /// Media inserted when a bundled program starts.  Keeping the drive
        /// layout next to the software metadata makes multi-disk programs a
        /// single launch configuration rather than a collection of UI-only
        /// special cases.
        struct StartupDisk {
            let resourceName: String
            let resourceExtension: String
            let description: String
        }

        var title: String {
            switch self {
            case .appleWriter10: return "Apple Writer 1.0"
            case .appleWriter11: return "Apple Writer 1.1"
            case .wordPerfect11: return "WordPerfect 1.1（IIe/IIc）"
            case .visiCalc137: return "VisiCalc 1.37"
            case .systemUtilities32: return "Apple II System Utilities 3.2"
            case .copyIIPlus55: return "Copy II Plus 5.5"
            case .applePascal13Boot: return "Apple Pascal 1.3 启动盘（APPLE1）"
            }
        }

        private var primaryDisk: StartupDisk {
            switch self {
            case .appleWriter10: return .init(resourceName: "Apple Writer 1.0", resourceExtension: "dsk", description: "Apple Writer 1.0")
            case .appleWriter11: return .init(resourceName: "Apple Writer 1.1", resourceExtension: "do", description: "Apple Writer 1.1")
            case .wordPerfect11: return .init(resourceName: "WordPerfect 1.1 IIe-IIc", resourceExtension: "dsk", description: "WordPerfect 1.1（IIe/IIc）")
            case .visiCalc137: return .init(resourceName: "VisiCalc 1.37", resourceExtension: "dsk", description: "VisiCalc 1.37")
            case .systemUtilities32: return .init(resourceName: "Apple II System Utilities 3.2", resourceExtension: "dsk", description: "Apple II System Utilities 3.2")
            case .copyIIPlus55: return .init(resourceName: "Copy II Plus 5.5", resourceExtension: "dsk", description: "Copy II Plus 5.5")
            case .applePascal13Boot: return .init(resourceName: "Apple Pascal 1.3 APPLE1 Boot", resourceExtension: "dsk", description: "Apple Pascal 1.3 启动盘（APPLE1）")
            }
        }

        /// Drive 1 is always the boot volume. Apple Pascal's standard
        /// two-drive layout keeps APPLE2 available in Drive 2 for its filer,
        /// compiler and linker without exposing separate startup entries.
        var startupDisks: [StartupDisk] {
            switch self {
            case .applePascal13Boot:
                return [
                    primaryDisk,
                    .init(resourceName: "Apple Pascal 1.3 APPLE2", resourceExtension: "dsk", description: "Apple Pascal 1.3 工具盘（APPLE2）")
                ]
            default:
                return [primaryDisk]
            }
        }

        /// The productivity library uses IIe hardware. System Utilities 3.2
        /// and Apple Pascal 1.3 rely on the original IIe alternate character
        /// ROM; the other bundled titles require or benefit from the enhanced
        /// IIe firmware.
        var bootROM: BootROM {
            switch self {
            case .systemUtilities32: return .appleIIeUnenhanced
            default: return .appleIIeEnhanced
            }
        }
    }

    @Published private(set) var isRunning = true
    /// Runs the same 6502/bus path at twice the normal 1.0218 MHz rate.  This
    /// is deliberately a clock multiplier rather than a UI shortcut: every
    /// disk, paddle and speaker effect still observes its actual CPU cycle.
    @Published var isCPUAccelerated = false
    @Published private(set) var hasExternalROM = false
    @Published private(set) var status = "Apple II+（内置） · 未插入磁盘"
    @Published private(set) var refreshToken = 0
    @Published private(set) var videoSnapshot = AppleIIVideoSnapshot.blank
    @Published private(set) var selectedBootROM: BootROM = .appleIIPlus
    @Published private(set) var externalROMName: String?
    @Published private(set) var diskDescription = "未插入"
    @Published private(set) var externalDiskDescription = "未插入"
    @Published private(set) var hardDiskDescription = "未插入"

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
    private var terminationObserver: NSObjectProtocol?
    private var wordPerfectWorkDiskURL: URL?
    private let workDiskWriteQueue = DispatchQueue(label: "AppleIIEmulator.WordPerfectWorkDisk")
    /// CPU and bus execution are serialised away from SwiftUI.  UI work only
    /// receives immutable video snapshots after each slice, so an accelerated
    /// 6502 cannot monopolise the main actor.
    private let emulationQueue = DispatchQueue(label: "AppleIIEmulator.Execution", qos: .userInteractive)
    private let emulationLock = NSLock()
    private var cpuSliceQueued = false
    private var executionGeneration = 0
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

    var currentROMTitle: String { externalROMName ?? selectedBootROM.title }

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
        // works even when Canvas is not the current first responder.  Consume
        // the event after latching it: KeyboardCapture is also a first
        // responder and letting the event continue would latch every key
        // twice.  In particular, WordPerfect treats two RETURN strobes as an
        // immediate confirmation followed by an unexpected command.
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // macOS normally reserves Escape for transient UI, but the
            // emulator's display owns keyboard focus.  In full screen it must
            // retain the conventional macOS escape hatch rather than passing
            // the key through as Apple II Escape.
            if event.keyCode == 53, let window = event.window,
               window.styleMask.contains(.fullScreen) {
                window.toggleFullScreen(nil)
                return nil
            }
            self?.keyDown(event)
            return nil
        }
        keyboardReleaseMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { [weak self] event in
            self?.keyUp(event)
            return event
        }
        modifierMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.modifierFlagsChanged(event.modifierFlags)
            return event
        }
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.persistWordPerfectWorkDisk()
            }
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
        if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) }
    }

    func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        defer { lastEmulationTick = now }
        guard isRunning, !cpuSliceQueued else { return }
        // Audio output is clocked independently of the UI. Derive the work
        // budget from elapsed wall time so a slow frame does not slow the
        // emulated speaker and lower the pitch. Cap catch-up to avoid a long
        // foreground pause making the UI unresponsive.
        let elapsed = min(0.050, max(0, now - lastEmulationTick))
        let clockMultiplier = isCPUAccelerated ? 2.0 : 1.0
        fractionalCPUCycles += elapsed * 1_021_800.0 * clockMultiplier
        let cycles = Int(fractionalCPUCycles)
        fractionalCPUCycles -= Double(cycles)
        guard cycles > 0 else { return }
        cpuSliceQueued = true
        let generation = executionGeneration
        let warmStart = applesoftWarmStartDeadline.map { now >= $0 } ?? false
        let cpu = cpu!
        let memory = memory
        let speaker = speaker
        let lock = emulationLock
        emulationQueue.async { [weak self] in
            lock.lock()
            cpu.run(cycles: cycles)
            if warmStart { cpu.reset() }
            speaker.advance(toEmulatedCycle: cpu.totalCycles)
            let snapshot = memory.makeVideoSnapshot()
            lock.unlock()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.cpuSliceQueued = false
                guard self.executionGeneration == generation else { return }
                if warmStart {
                    self.applesoftWarmStartDeadline = nil
                    self.status = "Apple II+（内置） · Applesoft BASIC"
                }
                self.videoSnapshot = snapshot
                self.refreshToken &+= 1
            }
        }
    }

    private func withEmulationLock<T>(_ body: () throws -> T) rethrows -> T {
        try emulationQueue.sync {
            emulationLock.lock()
            defer { emulationLock.unlock() }
            return try body()
        }
    }

    /// Narrow diagnostic seam for regression tests: it runs the same CPU and
    /// bus path as the display timer without needing an AppKit run loop.
    func runForVerification(cycles: Int) {
        let snapshot = withEmulationLock {
            cpu.run(cycles: cycles)
            speaker.advance(toEmulatedCycle: cpu.totalCycles)
            return memory.makeVideoSnapshot()
        }
        videoSnapshot = snapshot
        refreshToken &+= 1
    }

    var encounteredUnsupportedCPUOpcodes: Set<UInt8> { withEmulationLock { cpu.unsupportedOpcodes } }
    var executedCPUCycles: Int { withEmulationLock { cpu.totalCycles } }
    /// Menu enablement is evaluated on the main actor while the CPU runs on
    /// the execution queue.  Keep even this small controller query behind
    /// the same lock: reading a Swift Array while the IWM advances its head
    /// position is a data race and can abort the process.
    func hasDisk(in drive: Int) -> Bool { withEmulationLock { memory.hasDisk(in: drive) } }
    /// Current CPU location, exposed to the regression suite so a disk loader
    /// that silently falls back into BASIC cannot look like a successful boot.
    var programCounter: UInt16 { withEmulationLock { cpu.pc } }
    var lastUnsupportedInstructionAddress: UInt16 { withEmulationLock { cpu.lastUnsupportedInstructionAddress } }
    var recentInstructions: [(UInt16, UInt8)] { withEmulationLock { cpu.recentInstructions } }
    /// Observable boot-progress seam: disk-loaded Apple II programs execute
    /// from RAM below $C000, whereas the reset firmware lives in ROM above it.
    var hasExecutedRAMCode: Bool { withEmulationLock { cpu.hasExecutedRAMInstruction } }

    func reset() {
        applesoftWarmStartDeadline = nil
        executionGeneration &+= 1
        let snapshot = withEmulationLock {
            memory.resetHardwareState()
            cpu.reset()
            return memory.makeVideoSnapshot()
        }
        isRunning = true
        fractionalCPUCycles = 0
        lastEmulationTick = ProcessInfo.processInfo.systemUptime
        videoSnapshot = snapshot
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
        applyInput { $0.latchKey(key) }
    }

    func keyUp(_ event: NSEvent) {
        updateJoystick(for: event.keyCode, pressed: false)
    }

    func mouseMoved(_ event: NSEvent) {
        // The IIc mouse reports relative quadrature motion. AppKit supplies
        // the same relative movement independent of window geometry.
        let deltaX = Int(event.deltaX.rounded())
        let deltaY = -Int(event.deltaY.rounded())
        applyInput { $0.moveMouse(deltaX: deltaX, deltaY: deltaY) }
    }

    func mouseButton(_ index: Int, pressed: Bool) { applyInput { $0.setMouseButton(index, pressed: pressed) } }

    private func updateJoystick(for keyCode: UInt16, pressed: Bool) {
        if let paddles = inputState.setJoystickKey(keyCode, pressed: pressed) {
            applyInput { $0.setPaddles(paddles) }
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
        let openApple = flags.contains(.command)
        let closedApple = flags.contains(.option)
        applyInput { $0.setButtons(openApple: openApple, closedApple: closedApple) }
    }

    /// Host input is queued at the next CPU boundary synchronously, so a
    /// physical key cannot be overtaken by another timer slice. The critical
    /// section is limited to one already-bounded emulation slice.
    private func applyInput(_ operation: (AppleIIMemory) -> Void) {
        withEmulationLock { operation(memory) }
    }

    func selectROM(_ choice: BootROM) {
        guard choice != .external else { return }
        selectedBootROM = choice
        externalROMName = nil
        switch choice {
        case .appleIIPlus:
            do {
                try withEmulationLock { try memory.loadBundledAppleIIPlusROM(diskFirmware: .sixteenSector) }
                hasExternalROM = true
                status = "Apple II+（内置） · \(diskDescription)"
            } catch {
                installDiagnosticROM()
                status = "内置诊断 ROM（Apple II+ ROM 未找到）"
            }
        case .appleIIcROM00, .appleIIcROM03, .appleIIcROM04, .appleIIcROMFF:
            do {
                try withEmulationLock { try memory.loadBundledAppleIIcROM(named: choice.resourceName!) }
                hasExternalROM = true
                status = "\(choice.title)（内置） · \(diskDescription)"
            } catch {
                installDiagnosticROM()
                status = "内置诊断 ROM（\(choice.title) 未找到）"
            }
        case .appleIIeEnhanced, .appleIIeUnenhanced, .appleIIeCF:
            do {
                try withEmulationLock { try memory.loadBundledAppleIIeROM(choice) }
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
        case .external:
            return
        }
        reset()
        scheduleApplesoftWarmStartIfDiskless()
    }

    /// Opens a ROM supplied by the user. Disk reads happen off the main actor;
    /// only the validated bytes are handed back to the emulated memory bus.
    func chooseExternalROM() {
        let panel = NSOpenPanel()
        panel.title = "打开 Apple II ROM"
        panel.message = "支持 Apple II/II+ 12 KB ROM，或 Apple IIc 16 KB / 32 KB ROM"
        // ROM dumps are often distributed without a standard extension. The
        // byte-length validator below is authoritative, so allow any binary
        // data file rather than hiding a valid dump because it is named .dat.
        panel.allowedContentTypes = [.data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        status = "正在读取 (url.lastPathComponent)…"
        Task { [weak self] in
            let result = await Task.detached { Result { try Data(contentsOf: url) } }.value
            guard let self else { return }
            switch result {
            case let .success(data): self.loadExternalROM(data, name: url.lastPathComponent)
            case .failure: self.status = "无法读取 (url.lastPathComponent)"
            }
        }
    }

    private func loadExternalROM(_ data: Data, name: String) {
        do {
            try withEmulationLock { try memory.loadCustomROM(data) }
            selectedBootROM = .external
            externalROMName = "外部 ROM：\(name)"
            hasExternalROM = true
            status = "\(currentROMTitle) · \(diskDescription)"
            reset()
        } catch {
            status = "ROM 格式无效：仅支持 12 KB Apple II/II+，或 16 KB / 32 KB Apple IIc ROM"
        }
    }

    private func installDiagnosticROM() {
        withEmulationLock { memory.installDiagnosticProgram() }
    }

    func insertDiagnosticDisk() {
        do {
            try withEmulationLock { try memory.mountDSK(DiskII.diagnosticDSK()) }
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
            try withEmulationLock { try memory.loadBundledAppleIIPlusROM(diskFirmware: game.diskFirmware) }
            // Legacy 13-sector archival images are often padded to the
            // modern 140 KB .dsk length, so their byte count alone cannot
            // identify the format. The bundled title declares its controller
            // firmware and mounts through the matching sector codec.
            if game.diskFirmware == .thirteenSector {
                try withEmulationLock { try memory.mountThirteenSectorDisk(Data(contentsOf: url), drive: 0) }
            } else {
                try withEmulationLock { try memory.mountDiskImage(at: url, drive: 0) }
            }
            selectedBootROM = .appleIIPlus
            diskDescription = game.title
            status = "Apple II+ · \(game.diskFirmware.title) · \(game.title)"
            reset()
        } catch {
            status = "无法装入内置游戏：\(game.title)"
        }
    }

    func loadBundledSoftware(_ software: BundledSoftware) {
        persistWordPerfectWorkDisk()
        wordPerfectWorkDiskURL = nil

        // Select the machine before mounting so the reset vector and the
        // controller firmware belong to the software's intended hardware.
        selectROM(software.bootROM)
        do {
            let startupMedia = try software.startupDisks.enumerated().map { drive, disk in
                guard let url = AppResources.bundle.url(
                    forResource: disk.resourceName,
                    withExtension: disk.resourceExtension
                ) else {
                    throw CocoaError(.fileNoSuchFile)
                }
                return (drive: drive, disk: disk, data: try Data(contentsOf: url))
            }
            try withEmulationLock {
                memory.ejectDisk(drive: 0)
                memory.ejectDisk(drive: 1)
                for (drive, disk, data) in startupMedia {
                    try memory.mountDiskImageData(
                        data,
                        fileExtension: disk.resourceExtension,
                        drive: drive
                    )
                }
            }
            diskDescription = startupMedia[0].disk.description
            externalDiskDescription = startupMedia.count > 1 ? startupMedia[1].disk.description : "未插入"
            if software == .wordPerfect11 {
                try mountWordPerfectWorkDisk()
                externalDiskDescription = "WordPerfect 工作盘（/WORK）"
            }
            status = "\(software.bootROM.title) · \(software.title)"
            reset()
        } catch {
            status = "无法装入内置软件：\(software.title)"
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
        panel.allowedContentTypes = ["dsk", "do", "d13", "po", "nib", "2mg", "2img", "woz"].compactMap { UTType(filenameExtension: $0) }
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
            try withEmulationLock {
                try memory.loadBundledAppleIIPlusROM(diskFirmware: .sixteenSector)
                try memory.mountDiskImage(at: url, drive: 0)
            }
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
        panel.allowedContentTypes = ["dsk", "do", "d13", "po", "nib", "2mg", "2img", "woz"].compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try withEmulationLock { try memory.mountDiskImage(at: url, drive: drive) }
            setDiskDescription(url.lastPathComponent, drive: drive)
            status = "\(currentROMTitle) · 驱动器 \(drive + 1)：\(url.lastPathComponent)"
            reset()
        } catch {
            status = "无法读取 \(url.lastPathComponent)：仅支持 .dsk/.do/.d13/.po/.nib/.2mg/.2img"
        }
    }

    /// Mounts a true SmartPort/ProDOS block image in slot 7.  Its media is
    /// intentionally kept separate from the two 5.25-inch Disk II drives.
    func chooseHardDiskImage() {
        let panel = NSOpenPanel()
        panel.title = "插入 SmartPort 硬盘映像"
        panel.message = "支持 ProDOS .po、.hdv/.img，以及硬盘格式的 .2mg/.2img（512 字节块）"
        panel.allowedContentTypes = ["po", "hdv", "img", "2mg", "2img"].compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        status = "正在读取 SmartPort 硬盘 \(url.lastPathComponent)…"
        Task { [weak self] in
            let result = await Task.detached { Result { try Data(contentsOf: url) } }.value
            guard let self else { return }
            switch result {
            case let .success(data):
                do {
                    let blocks = try self.withEmulationLock {
                        try self.memory.mountHardDiskImageData(data, fileExtension: url.pathExtension)
                        return self.memory.hardDiskBlockCount(in: 0)
                    }
                    self.hardDiskDescription = "\(url.lastPathComponent)（\(blocks) 块）"
                    self.status = "\(self.currentROMTitle) · SmartPort：\(url.lastPathComponent)"
                } catch {
                    self.status = "无法读取 \(url.lastPathComponent)：仅支持 512 字节块 .po/.hdv/.img/.2mg/.2img"
                }
            case .failure:
                self.status = "无法读取 SmartPort 硬盘 \(url.lastPathComponent)"
            }
        }
    }

    func ejectHardDisk() {
        withEmulationLock { memory.ejectHardDisk() }
        hardDiskDescription = "未插入"
        status = "\(currentROMTitle) · SmartPort 硬盘未插入"
    }

    func ejectDisk(drive: Int = 0) {
        if drive == 1 { persistWordPerfectWorkDisk() }
        withEmulationLock { memory.ejectDisk(drive: drive) }
        if drive == 1 { wordPerfectWorkDiskURL = nil }
        setDiskDescription("未插入", drive: drive)
        status = "\(currentROMTitle) · 驱动器 \(drive + 1) 未插入磁盘"
        reset()
        scheduleApplesoftWarmStartIfDiskless()
    }

    func saveDiskAsNIB(drive: Int = 0) {
        guard let data = withEmulationLock({ memory.nibImage(drive: drive) }) else {
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

    private func mountWordPerfectWorkDisk() throws {
        let persistentURL = try Self.wordPerfectWorkDiskStorageURL()
        wordPerfectWorkDiskURL = persistentURL
        if FileManager.default.fileExists(atPath: persistentURL.path) {
            try withEmulationLock { try memory.mountDiskImage(at: persistentURL, drive: 1) }
            return
        }
        guard let bundledURL = AppResources.bundle.url(
            forResource: "WordPerfect 1.1 Work Disk",
            withExtension: "dsk"
        ) else {
            throw CocoaError(.fileNoSuchFile)
        }
        try withEmulationLock { try memory.mountDiskImage(at: bundledURL, drive: 1) }
        persistWordPerfectWorkDisk()
    }

    private func persistWordPerfectWorkDisk() {
        guard let url = wordPerfectWorkDiskURL,
              let snapshot = withEmulationLock({ memory.nibImage(drive: 1) }) else { return }
        workDiskWriteQueue.async {
            try? snapshot.write(to: url, options: .atomic)
        }
    }

    private static func wordPerfectWorkDiskStorageURL() throws -> URL {
        let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || Bundle.allBundles.contains { $0.bundleURL.pathExtension == "xctest" }
        let base: URL
        if isRunningTests {
            base = FileManager.default.temporaryDirectory
        } else {
            base = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        }
        let directory = base.appendingPathComponent("AppleIIEmulator", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("WordPerfect Work Disk.nib")
    }

    private func scheduleApplesoftWarmStartIfDiskless() {
        guard selectedBootROM == .appleIIPlus,
              !withEmulationLock({ memory.hasDisk(in: 0) }) else { return }
        // The bundled ROM needs about half a million emulated cycles to set
        // its cold-start marker before a warm RESET can enter Applesoft.
        applesoftWarmStartDeadline = ProcessInfo.processInfo.systemUptime + 0.60
    }
}

final class AppleIIMemory: AppleIIBus, @unchecked Sendable {
    enum Model: Equatable { case appleIIPlus, appleIIc, appleIIe }
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
    // A 16 KB Language Card turns a 48 KB Apple II+ into the conventional
    // 64 KB configuration required by ProDOS and tools such as Copy II Plus.
    // $D000-$DFFF has two selectable 4 KB banks; $E000-$FFFF is the shared
    // 8 KB bank.  Keep it independent of IIc auxiliary RAM because its
    // $C080-$C08F access protocol is real, observable Apple II+ hardware.
    private var languageCardBank1 = [UInt8](repeating: 0, count: 0x1000)
    private var languageCardBank2 = [UInt8](repeating: 0, count: 0x1000)
    private var languageCardHigh = [UInt8](repeating: 0, count: 0x2000)
    // A 128 KB IIe has a second language-card window in auxiliary memory.
    // ALTZP selects which complete set of $D000-$FFFF RAM banks is visible.
    private var auxiliaryLanguageCardBank1 = [UInt8](repeating: 0, count: 0x1000)
    private var auxiliaryLanguageCardBank2 = [UInt8](repeating: 0, count: 0x1000)
    private var auxiliaryLanguageCardHigh = [UInt8](repeating: 0, count: 0x2000)
    private var languageCardRAMRead = false
    private var languageCardBank2Selected = true
    private var languageCardWriteArmed = false
    private var languageCardWriteEnabled = false
    private var iicROM = [UInt8]()
    private var iicROMBank = 0
    private var iieROM = [UInt8]()
    private var plusSlot6ROM = [UInt8]()
    private var plusDiskFirmware: DiskIIFirmware?
    private(set) var model: Model = .appleIIPlus
    private(set) var supportsMouseText = false
    var modelName: String {
        switch model {
        case .appleIIPlus: return "Apple II+"
        case .appleIIc: return "Apple IIc"
        case .appleIIe: return "Apple IIe"
        }
    }
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
    // Slot 7 is a separate block device. It must never share the Disk II
    // controller, whose GCR timing and 140 KB media geometry are unrelated.
    private let smartPortController = SmartPortController()
    private var serialPort1 = ACIA6551()
    private var serialPort2 = ACIA6551()
    private var mouseController = AppleIIMouseInterface()
    private(set) var speakerFlips = 0
    var speakerDidToggle: (() -> Void)?
    var speakerDidToggleAtCycle: ((Int) -> Void)?
    private var speakerCycle = 0
    private var cassetteInput = false
    private var cassetteOutput = false
    private var annunciators = [false, false, false, false]
    var cassetteOutputDidToggleAtCycle: ((Int, Bool) -> Void)?
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
            alternateCharset: alternateCharset, supportsMouseText: supportsMouseText,
            textByte: { [weak self] column, row in self?.textByte(column: column, row: row) ?? 0 },
            loresByte: { [weak self] column, row in self?.loresByte(column: column, row: row) ?? 0 },
            hgrByte: { [weak self] column, row, auxiliary in self?.hgrByte(column: column, row: row, auxiliary: auxiliary) ?? 0 }
        )
    }

    func makeVideoSnapshot() -> AppleIIVideoSnapshot {
        AppleIIVideoSnapshot(
            textMode: textMode,
            mixedMode: mixedMode,
            hires: hires,
            doubleHires: doubleHires,
            column80: column80,
            alternateCharset: alternateCharset,
            supportsMouseText: supportsMouseText,
            text: (0..<24).flatMap { row in (0..<80).map { textByte(column: $0, row: row) } },
            lores: (0..<24).flatMap { row in (0..<40).map { loresByte(column: $0, row: row) } },
            hgrMain: (0..<192).flatMap { row in (0..<40).map { hgrByte(column: $0, row: row) } },
            hgrAuxiliary: (0..<192).flatMap { row in (0..<40).map { hgrByte(column: $0, row: row, auxiliary: true) } }
        )
    }
    private static let cyclesPerLine = 65
    private static let linesPerFrame = 262
    var irqPending: Bool { serialPort1.irqPending || serialPort2.irqPending || mouseController.irqPending }

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
        case 0xC011: return status(model == .appleIIe && languageCardBank2Selected)
        case 0xC012: return status(model == .appleIIe && languageCardRAMRead)
        case 0xC013: return status(ramReadAuxiliary)
        case 0xC014: return status(ramWriteAuxiliary)
        // RDCXROM is high when the motherboard Cx ROM is selected.  The
        // write switches are C006 = slot ROM and C007 = internal ROM.
        case 0xC015: return status(internalCXROM)
        case 0xC016: return status(alternateZeroPage)
        case 0xC017: return status(slot3ROM)
        case 0xC018: return status(store80)
        case 0xC019: return model == .appleIIc ? status(iiCVBLFlag) : status(!verticalBlank)
        case 0xC020: toggleCassetteOutput(); return 0
        case 0xC060: return status(cassetteInput)
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
        case 0xC080...0xC08F:
            if model == .appleIIc { return accessIWM(a, write: nil) }
            accessLanguageCard(a)
            return 0
        case 0xC098...0xC09B where model == .appleIIc:
            return serialPort1.read(register: a - 0xC098)
        case 0xC0A8...0xC0AB where model == .appleIIc:
            return serialPort2.read(register: a - 0xC0A8)
        case 0xC0C0...0xC0C3 where model == .appleIIc:
            return mouseController.read(register: a - 0xC0C0)
        case 0xC0E0...0xC0EF:
            return accessIWM(a, write: nil)
        case 0xC0F0...0xC0FF:
            return smartPortController.access(a, write: nil, bus: self)
        case 0xC030: toggleSpeaker(); return 0
        case 0xC050: textMode = false; return 0
        case 0xC051: textMode = true; return 0
        case 0xC052: mixedMode = false; return 0
        case 0xC053: mixedMode = true; return 0
        case 0xC054: page2 = false; return 0
        case 0xC055: page2 = true; return 0
        case 0xC056: hires = false; return 0
        case 0xC057: hires = true; return 0
        case 0xC058...0xC05F where model == .appleIIPlus:
            setAnnunciator(index: (a - 0xC058) / 2, enabled: !a.isMultiple(of: 2))
            return 0
        case 0xC05E where model == .appleIIe: doubleHires = true; return 0
        case 0xC05F where model == .appleIIe: doubleHires = false; return 0
        case 0xC058...0xC05D where model == .appleIIe:
            setAnnunciator(index: (a - 0xC058) / 2, enabled: !a.isMultiple(of: 2))
            return 0
        case 0xC05A where model == .appleIIc: iicVBLEnabled = false; return 0
        case 0xC05B where model == .appleIIc: iicVBLEnabled = iicIOUDisabled; return 0
        // On an Apple II/II+, these are AN3 (annunciator 3) accesses. They
        // become the DHIRES switches only when the IIc IOU is disabled:
        // C05E enables double-hi-res and C05F disables it.
        case 0xC05E where model == .appleIIc && iicIOUDisabled || model == .appleIIe: doubleHires = true; return 0
        case 0xC05F where model == .appleIIc && iicIOUDisabled || model == .appleIIe: doubleHires = false; return 0
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
            if (model == .appleIIPlus || model == .appleIIe), (0xC600...0xC6FF).contains(a), !internalCXROM, plusSlot6ROM.count == 0x100 {
                return plusSlot6ROM[a - 0xC600]
            }
            if model != .appleIIc, a >= 0xD000, languageCardRAMRead {
                return languageCardByte(at: a)
            }
            if model == .appleIIe, a >= 0xC100, iieROM.count == 0x4000 {
                return iieROM[a - 0xC000]
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
        case 0xC080...0xC08F:
            if model == .appleIIc { _ = accessIWM(a, write: value) }
            else { accessLanguageCard(a) }
        case 0xC098...0xC09B where model == .appleIIc: serialPort1.write(value, register: a - 0xC098)
        case 0xC0A8...0xC0AB where model == .appleIIc: serialPort2.write(value, register: a - 0xC0A8)
        case 0xC0C0...0xC0C3 where model == .appleIIc: mouseController.write(value, register: a - 0xC0C0)
        case 0xC0E0...0xC0EF: _ = accessIWM(a, write: value)
        case 0xC0F0...0xC0FF: _ = smartPortController.access(a, write: value, bus: self)
        case 0xC030: toggleSpeaker()
        case 0xC020: toggleCassetteOutput()
        case 0xC050: textMode = false
        case 0xC051: textMode = true
        case 0xC052: mixedMode = false
        case 0xC053: mixedMode = true
        case 0xC054: page2 = false
        case 0xC055: page2 = true
        case 0xC056: hires = false
        case 0xC057: hires = true
        case 0xC058...0xC05F where model == .appleIIPlus:
            setAnnunciator(index: (a - 0xC058) / 2, enabled: !a.isMultiple(of: 2))
        case 0xC05E where model == .appleIIe: doubleHires = true
        case 0xC05F where model == .appleIIe: doubleHires = false
        case 0xC058...0xC05D where model == .appleIIe:
            setAnnunciator(index: (a - 0xC058) / 2, enabled: !a.isMultiple(of: 2))
        case 0xC05A where model == .appleIIc: iicVBLEnabled = false
        case 0xC05B where model == .appleIIc: iicVBLEnabled = iicIOUDisabled
        case 0xC05E where model == .appleIIc && iicIOUDisabled || model == .appleIIe: doubleHires = true
        case 0xC05F where model == .appleIIc && iicIOUDisabled || model == .appleIIe: doubleHires = false
        case 0xC05E, 0xC05F: break
        case 0xC070: iiCVBLFlag = false; paddleElapsedCycles = 0
        case 0xC07E where model == .appleIIc: iiCVBLFlag = false
        case 0xC07F where model == .appleIIc: iicIOUDisabled = true
        case 0xC028 where model == .appleIIc: iicROMBank ^= 1
        default:
            if model == .appleIIc, a >= 0xC100 { return }
            if (model == .appleIIPlus || model == .appleIIe), (0xC600...0xC6FF).contains(a), !internalCXROM { return }
            if model != .appleIIc, a >= 0xD000 {
                if languageCardWriteEnabled { setLanguageCardByte(value, at: a) }
                return
            }
            if model == .appleIIe, a >= 0xC100 { return }
            if useAuxiliaryWrite(for: a) { auxiliaryBytes[a] = value } else { bytes[a] = value }
        }
    }

    func latchKey(_ key: UInt8) { keyLatch = key }

    func loadROM(_ data: Data) {
        if data.count == 0x8000 {
            model = .appleIIc
            supportsMouseText = true
            iicROM = Array(data)
            iicROMBank = 0
            iieROM = []
        } else {
            model = .appleIIPlus
            supportsMouseText = false
            iicROM = []
            iieROM = []
            let start = 0x10000 - data.count
            bytes.replaceSubrange(start..<0x10000, with: data)
        }
    }

    /// Raw ROM container validation. Apple II/II+ maps 12 KB at $D000, while
    /// an IIc image is either one 16 KB ROM bank or both 16 KB banks.
    func loadCustomROM(_ data: Data) throws {
        switch data.count {
        case 0x3000:
            model = .appleIIPlus
            supportsMouseText = false
            iicROM = []
            iicROMBank = 0
            iieROM = []
            bytes = [UInt8](repeating: 0, count: 65_536)
            auxiliaryBytes = [UInt8](repeating: 0, count: 65_536)
            clearLanguageCard()
            bytes.replaceSubrange(0xD000..<0x10000, with: data)
        case 0x4000:
            model = .appleIIc
            supportsMouseText = true
            let bank = Array(data)
            iicROM = bank + bank
            iicROMBank = 0
            iieROM = []
        case 0x8000:
            model = .appleIIc
            supportsMouseText = true
            iicROM = Array(data)
            iicROMBank = 0
            iieROM = []
        default:
            throw CocoaError(.fileReadCorruptFile)
        }
    }

    func loadBundledAppleIIcROM(named name: String) throws {
        guard let url = AppResources.bundle.url(forResource: name, withExtension: "bin") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let data = try Data(contentsOf: url)
        guard data.count == 0x4000 || data.count == 0x8000 else { throw CocoaError(.fileReadCorruptFile) }
        model = .appleIIc
        supportsMouseText = true
        let bank = Array(data)
        iicROM = data.count == 0x4000 ? bank + bank : bank
        iicROMBank = 0
        iieROM = []
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
        supportsMouseText = false
        iicROM = []
        iicROMBank = 0
        iieROM = []
        plusSlot6ROM = Array(diskROM)
        plusDiskFirmware = diskFirmware
        bytes = [UInt8](repeating: 0, count: 65_536)
        auxiliaryBytes = [UInt8](repeating: 0, count: 65_536)
        clearLanguageCard()
        bytes.replaceSubrange(0xD000..<0x10000, with: systemROM)
    }

    /// The IIe keeps a 16 KB motherboard ROM at $C000-$FFFF, with I/O
    /// overlays in the $C0xx page and the Disk II controller ROM in slot 6.
    /// Paired 2764 dumps are stored in address order: CD ($C000-$DFFF), then
    /// EF ($E000-$FFFF). The CF 27128 dump contains that same 16 KB image.
    func loadBundledAppleIIeROM(_ choice: AppleIIMachine.BootROM) throws {
        let names: [String]
        switch choice {
        case .appleIIeEnhanced:
            names = ["AppleIIe-CD-Enhanced-342-0304-A", "AppleIIe-EF-Enhanced-342-0303-A"]
        case .appleIIeUnenhanced:
            names = ["AppleIIe-CD-Unenhanced-342-0135-B", "AppleIIe-EF-Unenhanced-342-0134-A"]
        case .appleIIeCF:
            names = ["AppleIIe-CF-342-0349-B"]
        default:
            throw CocoaError(.fileReadCorruptFile)
        }
        var image = Data()
        for name in names {
            guard let url = AppResources.bundle.url(forResource: name, withExtension: "bin") else {
                throw CocoaError(.fileNoSuchFile)
            }
            image.append(try Data(contentsOf: url))
        }
        guard image.count == 0x4000 else { throw CocoaError(.fileReadCorruptFile) }
        guard let diskURL = AppResources.bundle.url(forResource: DiskIIFirmware.sixteenSector.resourceName, withExtension: "rom") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let diskROM = try Data(contentsOf: diskURL)
        guard diskROM.count == 0x100 else { throw CocoaError(.fileReadCorruptFile) }
        model = .appleIIe
        supportsMouseText = choice == .appleIIeEnhanced
        iicROM = []
        iicROMBank = 0
        iieROM = Array(image)
        plusSlot6ROM = Array(diskROM)
        plusDiskFirmware = .sixteenSector
        bytes = [UInt8](repeating: 0, count: 65_536)
        auxiliaryBytes = [UInt8](repeating: 0, count: 65_536)
        clearLanguageCard()
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
        languageCardRAMRead = false
        languageCardBank2Selected = true
        languageCardWriteArmed = false
        languageCardWriteEnabled = false
        diskController.reset()
        smartPortController.reset()
        serialPort1.reset()
        serialPort2.reset()
        mouseController.reset()
        cassetteInput = false
        cassetteOutput = false
        annunciators = [false, false, false, false]
        videoClock = 0
        iiCVBLFlag = false
        iicIOUDisabled = false
        iicVBLEnabled = false
        paddleElapsedCycles = 0
    }

    private func useAuxiliaryRead(for address: Int) -> Bool {
        guard (model == .appleIIc || model == .appleIIe), address < 0xC000 else { return false }
        // RAMRD/RAMWRT cover $0200-$BFFF only.  The zero page and stack
        // remain in main memory unless the distinct ALTZP switch is set.
        if address < 0x0200 { return alternateZeroPage }
        if store80 && isVideoPage(address) { return page2 }
        return ramReadAuxiliary
    }

    /// Language Card soft switches.  Each group of eight addresses is mirrored
    /// at $C088-$C08F.  Low bits select the ROM/RAM read path and whether a
    /// write-enable access is being made:
    ///
    ///     $C080/$C083 = bank 2 RAM read; $C081/$C082 = ROM read
    ///     $C084/$C087 = bank 1 RAM read; $C085/$C086 = ROM read
    ///
    /// The odd addresses are the write-enable variants. Two successive
    /// accesses to one are required before writes reach card RAM. This
    /// protects the ROM area from a single accidental I/O touch, just as the
    /// original 16 KB card did.
    private func accessLanguageCard(_ address: Int) {
        // $C084-$C087 mirror the bank-2 controls at $C080-$C083, while
        // $C08C-$C08F mirror bank 1 at $C088-$C08B.
        languageCardBank2Selected = address & 0x08 == 0
        let selector = address & 0x03
        languageCardRAMRead = selector == 0 || selector == 3
        if address.isMultiple(of: 2) {
            languageCardWriteArmed = false
            languageCardWriteEnabled = false
        } else if languageCardWriteArmed {
            languageCardWriteEnabled = true
        } else {
            languageCardWriteArmed = true
            languageCardWriteEnabled = false
        }
    }

    private func languageCardByte(at address: Int) -> UInt8 {
        let bank1 = alternateZeroPage ? auxiliaryLanguageCardBank1 : languageCardBank1
        let bank2 = alternateZeroPage ? auxiliaryLanguageCardBank2 : languageCardBank2
        let high = alternateZeroPage ? auxiliaryLanguageCardHigh : languageCardHigh
        if address < 0xE000 {
            let offset = address - 0xD000
            return languageCardBank2Selected ? bank2[offset] : bank1[offset]
        }
        return high[address - 0xE000]
    }

    private func setLanguageCardByte(_ value: UInt8, at address: Int) {
        if address < 0xE000 {
            let offset = address - 0xD000
            if alternateZeroPage {
                if languageCardBank2Selected { auxiliaryLanguageCardBank2[offset] = value }
                else { auxiliaryLanguageCardBank1[offset] = value }
            } else {
                if languageCardBank2Selected { languageCardBank2[offset] = value }
                else { languageCardBank1[offset] = value }
            }
        } else {
            let offset = address - 0xE000
            if alternateZeroPage { auxiliaryLanguageCardHigh[offset] = value }
            else { languageCardHigh[offset] = value }
        }
    }

    private func clearLanguageCard() {
        languageCardBank1 = [UInt8](repeating: 0, count: 0x1000)
        languageCardBank2 = [UInt8](repeating: 0, count: 0x1000)
        languageCardHigh = [UInt8](repeating: 0, count: 0x2000)
        auxiliaryLanguageCardBank1 = [UInt8](repeating: 0, count: 0x1000)
        auxiliaryLanguageCardBank2 = [UInt8](repeating: 0, count: 0x1000)
        auxiliaryLanguageCardHigh = [UInt8](repeating: 0, count: 0x2000)
        languageCardRAMRead = false
        languageCardBank2Selected = true
        languageCardWriteArmed = false
        languageCardWriteEnabled = false
    }

    private func useAuxiliaryWrite(for address: Int) -> Bool {
        guard (model == .appleIIc || model == .appleIIe), address < 0xC000 else { return false }
        if address < 0x0200 { return alternateZeroPage }
        if store80 && isVideoPage(address) { return page2 }
        return ramWriteAuxiliary
    }

    private func isVideoPage(_ address: Int) -> Bool {
        // With 80STORE set, PAGE2 no longer chooses a displayed page. It
        // selects main versus auxiliary page-1 memory. Text page 1 is
        // *always* included; when HIRES is set, the HGR page-1 range is
        // included as well. Pascal keeps HIRES enabled while it draws text,
        // so omitting $0400-$07FF in that state sends every 80-column
        // character to main RAM and leaves the auxiliary columns blank.
        if (0x0400...0x07FF).contains(address) { return true }
        return hires && (0x2000...0x3FFF).contains(address)
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
        smartPortController.advance(by: cycles)
        serialPort1.advance(by: cycles)
        serialPort2.advance(by: cycles)
        if model == .appleIIc, iicVBLEnabled, oldLine < 192, (newLine >= 192 || newLine < oldLine) {
            iiCVBLFlag = true
        }
        if model == .appleIIc, oldLine < 192, (newLine >= 192 || newLine < oldLine) {
            mouseController.verticalBlank()
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

    func moveMouse(deltaX: Int, deltaY: Int) {
        guard model == .appleIIc else { return }
        mouseController.move(deltaX: deltaX, deltaY: deltaY)
    }

    func setMouseButton(_ index: Int, pressed: Bool) {
        guard model == .appleIIc else { return }
        mouseController.setButton(index, pressed: pressed)
    }

    func setCassetteInput(_ high: Bool) { cassetteInput = high }
    func annunciatorEnabled(_ index: Int) -> Bool {
        annunciators.indices.contains(index) && annunciators[index]
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

    func mountHardDiskImage(at url: URL, drive: Int = 0) throws {
        try smartPortController.mountImage(Data(contentsOf: url), fileExtension: url.pathExtension, drive: drive)
    }
    func mountHardDiskImageData(_ data: Data, fileExtension: String, drive: Int = 0) throws {
        try smartPortController.mountImage(data, fileExtension: fileExtension, drive: drive)
    }
    func ejectHardDisk(drive: Int = 0) { smartPortController.eject(drive: drive) }
    func hasHardDisk(in drive: Int) -> Bool { smartPortController.hasDisk(in: drive) }
    func hardDiskBlockCount(in drive: Int) -> Int { smartPortController.blockCount(in: drive) }
    func hardDiskImage(drive: Int = 0) -> Data? { smartPortController.imageData(drive: drive) }

    /// Host adapters can feed and drain this boundary without touching the
    /// 6502 bus. It also keeps serial tests focused on the real ACIA registers.
    func receiveSerialByte(_ byte: UInt8, port: Int) {
        if port == 1 { serialPort1.receive(byte) }
        else if port == 2 { serialPort2.receive(byte) }
    }

    func drainTransmittedSerialBytes(port: Int) -> [UInt8] {
        if port == 1 { return serialPort1.drainTransmittedBytes() }
        if port == 2 { return serialPort2.drainTransmittedBytes() }
        return []
    }

    /// The IIc's integrated IWM occupies slot-zero I/O ($C080-$C08F). This
    /// models its control latch and data path; the sector stream is attached
    /// to this same state machine by the disk-image layer.
    private func accessIWM(_ address: Int, write value: UInt8?) -> UInt8 {
        diskController.access(address, write: value)
    }

    private func toggleCassetteOutput() {
        cassetteOutput.toggle()
        cassetteOutputDidToggleAtCycle?(speakerCycle, cassetteOutput)
    }

    private func setAnnunciator(index: Int, enabled: Bool) {
        guard annunciators.indices.contains(index) else { return }
        annunciators[index] = enabled
    }

    func installDiagnosticProgram() {
        model = .appleIIPlus
        supportsMouseText = false
        iicROM = []
        iicROMBank = 0
        iieROM = []
        bytes = [UInt8](repeating: 0, count: 65_536)
        auxiliaryBytes = [UInt8](repeating: 0, count: 65_536)
        clearLanguageCard()
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
