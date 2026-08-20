import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

/// Apple II+ motherboard model. The CPU owns no memory: every bus access goes
/// through this object, so soft switches remain observable and testable.
@MainActor
final class AppleIIMachine: ObservableObject {
    enum BootROM: String, CaseIterable, Identifiable, Hashable {
        case appleIIPlus
        case appleIIeGameCompatible
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
            case .appleIIPlus: return "Apple II+"
            case .appleIIeGameCompatible: return "Apple IIe（游戏兼容）"
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
            case .appleIIPlus, .appleIIeGameCompatible: return nil
            case .appleIIcROM00: return "AppleIIc-ROM00-342-0033-A"
            case .appleIIcROM03: return "AppleIIc-ROM03-341-0445-A"
            case .appleIIcROM04: return "AppleIIc-ROM04-341-0445-B"
            case .appleIIcROMFF: return "AppleIIc-ROMFF-342-0272-A"
            case .appleIIeEnhanced, .appleIIeUnenhanced, .appleIIeCF, .diagnostic, .external: return nil
            }
        }

        static let menuChoices: [BootROM] = [.appleIIeGameCompatible, .appleIIPlus, .appleIIcROM00, .appleIIcROM03, .appleIIcROM04, .appleIIcROMFF, .appleIIeEnhanced, .appleIIeUnenhanced, .appleIIeCF, .diagnostic]
    }

    /// A small, deterministic set of games shown in the default GAME menu.
    /// They are packaged with the app so launching one never opens a file picker.
    enum BundledGame: String, CaseIterable, Identifiable {
        case lodeRunner
        case princeOfPersia
        case wizardry
        case karateka
        case falcons
        case jBird

        var id: Self { self }

        struct StartupDisk {
            let resourceName: String
            let resourceExtension: String
            let description: String
            /// The physical write-protect notch is part of the disk's
            /// observable hardware state. Some original games verify it
            /// before continuing past their title sequence.
            let writeProtected: Bool

            init(
                resourceName: String,
                resourceExtension: String,
                description: String,
                writeProtected: Bool = false
            ) {
                self.resourceName = resourceName
                self.resourceExtension = resourceExtension
                self.description = description
                self.writeProtected = writeProtected
            }
        }

        var title: String {
            switch self {
            case .lodeRunner: return "Lode Runner (1983)"
            case .princeOfPersia: return "Prince of Persia (1989)"
            case .wizardry: return "Wizardry (1981)"
            case .karateka: return "Karateka (1984)"
            case .falcons: return "Falcons"
            case .jBird: return "J-Bird"
            }
        }

        /// The default GAME menu is deliberately limited to games that boot
        /// and play from one disk. Multi-disk titles remain loadable by code
        /// and from their files, but do not make a fresh installation stop at
        /// a media-change prompt.
        var appearsInDefaultGameMenu: Bool {
            switch self {
            case .princeOfPersia, .wizardry: return false
            case .lodeRunner, .karateka, .falcons, .jBird: return true
            }
        }

        static var defaultGameMenu: [Self] {
            allCases
                .filter(\.appearsInDefaultGameMenu)
                .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        }

        /// The two Disk II drives are real physical drives. Multi-disk games
        /// boot with their first two disks inserted; any later disk change is
        /// performed through the normal Drive 1/Drive 2 media controls.
        var startupDisks: [StartupDisk] {
            switch self {
            case .lodeRunner:
                return [.init(resourceName: "Lode Runner (1983)", resourceExtension: "dsk", description: title)]
            case .princeOfPersia:
                // The two-drive crack's boot page reads Disk 1 from Drive 1,
                // then immediately switches to Drive 2 and expects Disk 3.
                // Disk 2 is only used for its later, explicit disk-change
                // prompt; mounting it here lets the title appear but corrupts
                // the load that starts after the player presses a key.
                return [
                    .init(resourceName: "Prince of Persia (1989) Disk 1", resourceExtension: "dsk", description: "Prince of Persia 磁盘 1"),
                    .init(resourceName: "Prince of Persia (1989) Disk 3", resourceExtension: "dsk", description: "Prince of Persia 磁盘 3")
                ]
            case .wizardry:
                return [
                    // The bundled v2.1 image is a sector-level release that
                    // starts with its companion disk in Drive 2. The original
                    // Scenario Master is the later, explicit Drive 1 change.
                    // All three images are writable DSK media.
                    .init(resourceName: "Wizardry (1981) Disk 1", resourceExtension: "dsk", description: "Wizardry 磁盘 1"),
                    .init(resourceName: "Wizardry (1981) Disk 2", resourceExtension: "dsk", description: "Wizardry 磁盘 2"),
                    .init(resourceName: "Wizardry (1981) Original Scenario", resourceExtension: "dsk", description: "Wizardry 原始 Scenario 盘")
                ]
            case .karateka:
                return [.init(resourceName: "Karateka (1984)", resourceExtension: "dsk", description: title)]
            case .falcons:
                return [.init(resourceName: "Falcons (4am crack)", resourceExtension: "dsk", description: title)]
            case .jBird:
                return [.init(resourceName: "j-bird", resourceExtension: "dsk", description: title)]
            }
        }

        var diskFirmware: AppleIIMemory.DiskIIFirmware {
            switch self {
            case .lodeRunner, .princeOfPersia, .wizardry, .karateka, .falcons, .jBird: return .sixteenSector
            }
        }

        /// The game launcher uses a 128 KB enhanced IIe. This retains Apple
        /// II+ game compatibility while also satisfying titles such as Prince
        /// of Persia that explicitly require a IIc or IIe with 128 KB.
        var bootROM: BootROM {
            switch self {
            case .wizardry:
                // The original Wizardry 1.1 boot chain is an Apple II+
                // Pascal loader. Use the machine it was authored for; its
                // Scenario disk is a later physical replacement, not a ROM.
                return .appleIIPlus
            case .lodeRunner, .princeOfPersia, .karateka, .falcons, .jBird:
                return .appleIIeGameCompatible
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

    enum ActiveMediaKind {
        case none
        case game
        case software
    }

    /// A playable item in the recent-games menu. Disk games retain every
    /// image selected for their initial boot, so a two-disk game reopens with
    /// the same drive layout instead of silently losing its second disk.
    enum RecentGame: Hashable, Identifiable {
        case bundled(BundledGame)
        case diskImages([URL])

        var id: String {
            switch self {
            case let .bundled(game): return "bundled:\(game.rawValue)"
            case let .diskImages(urls):
                return "disks:" + urls.map { $0.standardizedFileURL.path }.joined(separator: "\u{1F}")
            }
        }

        var title: String {
            switch self {
            case let .bundled(game): return game.title
            case let .diskImages(urls):
                guard let first = urls.first else { return "磁盘映像" }
                let name = first.deletingPathExtension().lastPathComponent
                return urls.count == 1 ? name : "\(name) 等 \(urls.count) 张盘"
            }
        }

        var storageRecord: [String] {
            switch self {
            case let .bundled(game): return ["bundled", game.rawValue]
            case let .diskImages(urls): return ["disks"] + urls.map(\.path)
            }
        }

        init?(storageRecord: [String]) {
            guard let kind = storageRecord.first else { return nil }
            switch kind {
            case "bundled":
                guard storageRecord.count == 2,
                      let game = BundledGame(rawValue: storageRecord[1]) else { return nil }
                self = .bundled(game)
            case "disks":
                let urls = storageRecord.dropFirst().map { URL(fileURLWithPath: $0).standardizedFileURL }
                guard !urls.isEmpty else { return nil }
                self = .diskImages(urls)
            default:
                return nil
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
    /// The most recently presented CPU position. This is published alongside
    /// the video frame, so runtime integration probes can observe progress
    /// without synchronously querying the emulation queue from the UI.
    @Published private(set) var presentedCPUCycles = 0
    @Published private(set) var presentedProgramCounter: UInt16 = 0
    @Published private(set) var presentedDiskState = DiskIIDebugSnapshot(
        motorOn: false,
        selectedDrive: 0,
        q6: false,
        q7: false,
        tracks: [0, 0],
        readBits: [0, 0]
    )
    @Published private(set) var videoSnapshot = AppleIIVideoSnapshot.blank
    @Published private(set) var selectedBootROM: BootROM = .appleIIPlus
    @Published private(set) var externalROMName: String?
    @Published private(set) var diskDescription = "未插入"
    @Published private(set) var externalDiskDescription = "未插入"
    @Published private(set) var hardDiskDescription = "未插入"
    @Published private(set) var serialDevicePaths = [String]()
    @Published private(set) var serialPort1Device = "未连接"
    @Published private(set) var serialPort2Device = "未连接"
    /// Drives the physical GAME/SOFTWARE LEDs in the panel without making a
    /// UI choice alter the emulated hardware state.
    @Published private(set) var activeMediaKind: ActiveMediaKind = .none
    /// The recent menu remembers built-in games and the exact set of images
    /// selected for a local game. Entries are persisted as identifiers and
    /// paths, never as cached image bytes.
    @Published private(set) var recentGames: [RecentGame] = []

    private let gameLibrary = GameLibrary()
    /// Grouping keeps the in-app GAME menu navigable even with a large game
    /// collection rather than presenting hundreds of entries in one list.
    var downloadedGames: [GameLibrary.Game] { gameLibrary.games }

    let memory = AppleIIMemory()
    private var cpu: MOS6502!
    private let speaker = AppleIISpeaker()
    private let serialBridge = MacSerialBridge()
    private let recentGameStore: RecentGameStore
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
    /// Wizardry's boot disk finishes by explicitly asking for its Scenario
    /// Master in Drive 1.  Keep the already-loaded image here so responding
    /// to that *game-visible* prompt never performs host file I/O on the UI
    /// thread.
    private var wizardryScenarioDiskData: Data?
    private var wizardryScenarioPromptHandled = false
    /// A diskless Apple II+ reaches ROM Applesoft through the Autostart ROM's
    /// warm-reset path after it has shown the power-on banner.
    private var applesoftWarmStartDeadline: TimeInterval?

    var currentROMTitle: String { externalROMName ?? selectedBootROM.title }
    var supportsIIcSerial: Bool {
        switch selectedBootROM {
        case .appleIIcROM00, .appleIIcROM03, .appleIIcROM04, .appleIIcROMFF: return true
        default: return false
        }
    }

    init(defaults: UserDefaults = .standard, startsRuntimeTimer: Bool? = nil) {
        recentGameStore = RecentGameStore(defaults: defaults)
        recentGames = recentGameStore.restore()
        recentGameStore.save(recentGames)
        serialBridge.didReceiveByte = { [weak self] byte, port in
            guard let self else { return }
            self.emulationQueue.async { [weak self] in
                guard let self else { return }
                self.emulationLock.lock()
                self.memory.receiveSerialByte(byte, port: port)
                self.emulationLock.unlock()
            }
        }
        serialBridge.didListDevices = { [weak self] paths in
            DispatchQueue.main.async { self?.serialDevicePaths = paths }
        }
        serialBridge.didChangeConnection = { [weak self] port, path in
            DispatchQueue.main.async {
                guard let self else { return }
                if port == 1 { self.serialPort1Device = path ?? "未连接" }
                else if port == 2 { self.serialPort2Device = path ?? "未连接" }
            }
        }
        serialBridge.didFail = { [weak self] port, error in
            DispatchQueue.main.async {
                self?.status = "串口 \(port) 错误：\(error.localizedDescription)"
            }
        }
        refreshSerialDevices()
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
        if startsRuntimeTimer ?? !Self.isAutomatedRun {
            timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
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
        guard isRunning else {
            lastEmulationTick = now
            return
        }
        // Do not discard elapsed emulated time while a prior slice is still
        // executing. Disk-heavy loaders can legitimately take longer than a
        // UI frame; updating this timestamp here would make the machine fall
        // permanently behind its 1.0218 MHz clock despite using a full CPU.
        guard !cpuSliceQueued else { return }
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
        lastEmulationTick = now
        cpuSliceQueued = true
        let generation = executionGeneration
        let warmStart = applesoftWarmStartDeadline.map { now >= $0 } ?? false
        let cpu = cpu!
        let memory = memory
        let speaker = speaker
        let serialBridge = serialBridge
        let lock = emulationLock
        emulationQueue.async { [weak self] in
            lock.lock()
            cpu.run(cycles: cycles)
            if warmStart { cpu.reset() }
            speaker.advance(toEmulatedCycle: cpu.totalCycles)
            let serialPort1Bytes = memory.drainTransmittedSerialBytes(port: 1)
            let serialPort2Bytes = memory.drainTransmittedSerialBytes(port: 2)
            let serialPort1Baud = memory.serialBaudRate(port: 1)
            let serialPort2Baud = memory.serialBaudRate(port: 2)
            let totalCycles = cpu.totalCycles
            let programCounter = cpu.pc
            let diskState = memory.diskDebugSnapshot
            let snapshot = memory.makeVideoSnapshot()
            lock.unlock()
            serialBridge.setBaudRate(serialPort1Baud, port: 1)
            serialBridge.setBaudRate(serialPort2Baud, port: 2)
            serialBridge.send(serialPort1Bytes, port: 1)
            serialBridge.send(serialPort2Bytes, port: 2)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.cpuSliceQueued = false
                guard self.executionGeneration == generation else { return }
                if warmStart {
                    self.applesoftWarmStartDeadline = nil
                    self.status = "Apple II+（内置） · Applesoft BASIC"
                }
                self.videoSnapshot = snapshot
                self.presentedCPUCycles = totalCycles
                self.presentedProgramCounter = programCounter
                self.presentedDiskState = diskState
                self.advanceWizardryScenarioPromptIfNeeded(snapshot)
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

    private func coldBootLocked() -> (snapshot: AppleIIVideoSnapshot, bootsDriveOne: Bool) {
        let bootsDriveOne = memory.hasDisk(in: 0)
        memory.coldBootSystemState()
        cpu.reset()
        return (memory.makeVideoSnapshot(), bootsDriveOne)
    }

    private func publishColdBoot(_ result: (snapshot: AppleIIVideoSnapshot, bootsDriveOne: Bool), idleStatus: String) {
        isRunning = true
        fractionalCPUCycles = 0
        lastEmulationTick = ProcessInfo.processInfo.systemUptime
        videoSnapshot = result.snapshot
        status = result.bootsDriveOne
            ? "\(currentROMTitle) · 正在从驱动器 1 启动：\(diskDescription)"
            : idleStatus
        refreshToken &+= 1
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
        advanceWizardryScenarioPromptIfNeeded(snapshot)
        refreshToken &+= 1
    }

    /// This is intentionally driven by Wizardry's actual text-mode media
    /// request, rather than an elapsed-time guess.  The action below is still
    /// a normal Disk II media change and a keyboard strobe; no CPU or disk
    /// controller state is skipped.
    private func advanceWizardryScenarioPromptIfNeeded(_ snapshot: AppleIIVideoSnapshot) {
        guard !wizardryScenarioPromptHandled,
              case .game = activeMediaKind,
              diskDescription == BundledGame.wizardry.title,
              let scenarioData = wizardryScenarioDiskData,
              wizardryScenarioPromptIsVisible(in: snapshot) else {
            return
        }

        wizardryScenarioPromptHandled = true
        do {
            try installWizardryScenarioDisk(scenarioData, pressReturn: true)
            status = "Wizardry · 已将 Scenario 盘移入驱动器 1 并按 Return"
        } catch {
            wizardryScenarioPromptHandled = false
            status = "无法换入 Wizardry Scenario 磁盘"
        }
    }

    private func wizardryScenarioPromptIsVisible(in snapshot: AppleIIVideoSnapshot) -> Bool {
        let visibleText = String(snapshot.text.map { byte in
            let ascii = byte & 0x7F
            return ascii >= 0x20 && ascii < 0x7F ? Character(UnicodeScalar(ascii)) : " "
        })
        return visibleText.contains("SCENARIO MASTER IN DRV 1")
    }

    /// Move the physical Scenario Master from Drive 2 to Drive 1.  Leaving
    /// Drive 2 empty mirrors the instruction shown by the original game,
    /// rather than silently keeping two copies mounted.
    private func installWizardryScenarioDisk(_ data: Data, pressReturn: Bool) throws {
        try withEmulationLock {
            try memory.mountDSK(data, drive: 0)
            memory.ejectDisk(drive: 1)
            if pressReturn { memory.latchKey(0x8D) }
        }
        setDiskDescription("Wizardry Scenario 磁盘", drive: 0)
        setDiskDescription("未插入", drive: 1)
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
    var firstUnsupportedInstructionTrace: [(UInt16, UInt8)] { withEmulationLock { cpu.firstUnsupportedTrace } }
    var recentInstructions: [(UInt16, UInt8)] { withEmulationLock { cpu.recentInstructions } }
    /// Observable boot-progress seam: disk-loaded Apple II programs execute
    /// from RAM below $C000, whereas the reset firmware lives in ROM above it.
    var hasExecutedRAMCode: Bool { withEmulationLock { cpu.hasExecutedRAMInstruction } }

    func reset() {
        applesoftWarmStartDeadline = nil
        executionGeneration &+= 1
        // The front-panel RESET is a system restart, not a pause/resume or a
        // UI-level program jump. Disk II keeps its media inserted, while RAM
        // is returned to its cold-start state so the Apple II+ ROM cannot
        // interpret a reset as an Applesoft warm start and skip Drive 1.
        let result = withEmulationLock { coldBootLocked() }
        publishColdBoot(result, idleStatus: status)
    }

    func toggleRunning() {
        isRunning.toggle()
        lastEmulationTick = ProcessInfo.processInfo.systemUptime
    }

    func refreshSerialDevices() { serialBridge.refreshDevices() }

    func connectSerialDevice(_ path: String, port: Int) {
        guard supportsIIcSerial else {
            status = "串口仅适用于 Apple IIc ROM"
            return
        }
        // The next CPU slice applies the ACIA's current control-register
        // rate. Start at the reset-default 9600 to avoid waiting on the UI.
        serialBridge.connect(path: path, port: port, baudRate: 9_600)
    }

    func disconnectSerialDevice(port: Int) { serialBridge.disconnect(port: port) }

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

    /// Host input is immediate while no CPU slice is in flight, which keeps
    /// paused machines and input tests responsive. During a CPU slice it is
    /// queued after that slice instead: the main actor must never wait behind
    /// a disk-heavy loader merely to update a paddle or keyboard latch.
    private func applyInput(_ operation: @escaping @Sendable (AppleIIMemory) -> Void) {
        if !cpuSliceQueued, emulationLock.try() {
            operation(memory)
            emulationLock.unlock()
            return
        }

        let queue = emulationQueue
        let lock = emulationLock
        let memory = memory
        queue.async {
            lock.lock()
            operation(memory)
            lock.unlock()
        }
    }

    /// The app must never wait for resource I/O on its main actor.  The
    /// headless verifier is different: it needs a completed machine state at
    /// each assertion boundary, and it has no run-loop turn in which an
    /// asynchronous load can publish itself.  Keep that deterministic seam
    /// here instead of making production media loading synchronous again.
    private func submitEmulationTask(_ operation: @escaping @Sendable () -> Void) {
        if Self.isAutomatedRun {
            emulationQueue.sync(execute: operation)
        } else {
            emulationQueue.async(execute: operation)
        }
    }

    func selectROM(_ choice: BootROM) {
        guard choice != .external else { return }
        selectedBootROM = choice
        externalROMName = nil
        activeMediaKind = .none
        if choice == .diagnostic {
            installDiagnosticROM()
            hasExternalROM = false
            status = "内置诊断 ROM"
            reset()
            return
        }
        status = "正在装入 \(choice.title) ROM…"

        let lock = emulationLock
        let memory = memory
        let cpu = cpu!
        submitEmulationTask { [weak self] in
            var lockHeld = false
            do {
                // Bundle reads happen on the execution queue, before the
                // hardware lock is held. The UI and CPU bus stay responsive.
                switch choice {
                case .appleIIPlus:
                    let images = try AppleIIROMImages.iiPlus(diskFirmware: .sixteenSector)
                    lock.lock()
                    lockHeld = true
                    try memory.installIIPlusROM(systemROM: images.systemROM, diskROM: images.diskROM, diskFirmware: .sixteenSector)
                case .appleIIcROM00, .appleIIcROM03, .appleIIcROM04, .appleIIcROMFF:
                    let image = try AppleIIROMImages.iiC(named: choice.resourceName!)
                    lock.lock()
                    lockHeld = true
                    try memory.installIIcROM(image)
                case .appleIIeGameCompatible, .appleIIeEnhanced, .appleIIeUnenhanced, .appleIIeCF:
                    let iiEROM: BootROM = choice == .appleIIeGameCompatible ? .appleIIeEnhanced : choice
                    let images = try AppleIIROMImages.iiE(iiEROM)
                    lock.lock()
                    lockHeld = true
                    try memory.installIIeROM(images.motherboardROM, diskROM: images.diskROM, choice: iiEROM)
                case .diagnostic, .external:
                    return
                }
                let bootsDriveOne = memory.hasDisk(in: 0)
                memory.coldBootSystemState()
                cpu.reset()
                let result = (snapshot: memory.makeVideoSnapshot(), bootsDriveOne: bootsDriveOne)
                lock.unlock()
                lockHeld = false
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.selectedBootROM == choice else { return }
                    self.hasExternalROM = true
                    self.publishColdBoot(result, idleStatus: "\(choice.title)（内置） · \(self.diskDescription)")
                    self.scheduleApplesoftWarmStartIfDiskless()
                }
            } catch {
                if lockHeld { lock.unlock() }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.selectedBootROM == choice else { return }
                    self.installDiagnosticROM()
                    self.hasExternalROM = false
                    self.status = "内置诊断 ROM（\(choice.title) 未找到）"
                    self.reset()
                }
            }
        }
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
        status = "正在读取 \(url.lastPathComponent)…"
        Task { [weak self] in
            let result = await Task.detached { Result { try Data(contentsOf: url) } }.value
            guard let self else { return }
            switch result {
            case let .success(data): self.loadExternalROM(data, name: url.lastPathComponent)
            case .failure: self.status = "无法读取 \(url.lastPathComponent)"
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
        wizardryScenarioDiskData = nil
        wizardryScenarioPromptHandled = false
        if Self.isAutomatedRun {
            // These are requested-media facts, not results inferred from the
            // disk bus.  Publish them before the synchronous verifier task so
            // test callers retain the historical immediate API contract.
            selectedBootROM = game.bootROM
            hasExternalROM = true
            activeMediaKind = .game
            diskDescription = game.title
            externalDiskDescription = game.startupDisks.count > 1
                ? game.startupDisks[1].description
                : "未插入"
        }
        status = "正在读取内置游戏：\(game.title)…"
        let lock = emulationLock
        let memory = memory
        let cpu = cpu!
        submitEmulationTask { [weak self] in
            var lockHeld = false
            do {
                let startupMedia = try game.startupDisks.enumerated().map { index, disk in
                guard let url = AppResources.bundle.url(
                    forResource: disk.resourceName,
                    withExtension: disk.resourceExtension
                ) else {
                    throw CocoaError(.fileNoSuchFile)
                }
                return (drive: index, disk: disk, data: try Data(contentsOf: url))
                }
                let rom: AppleIIROMImages.IIPlus?
                let iiEROM: AppleIIROMImages.IIe?
                switch game.bootROM {
                case .appleIIPlus:
                    rom = try AppleIIROMImages.iiPlus(diskFirmware: game.diskFirmware)
                    iiEROM = nil
                case .appleIIeGameCompatible, .appleIIeEnhanced:
                    rom = nil
                    iiEROM = try AppleIIROMImages.iiE(.appleIIeEnhanced)
                default:
                    throw CocoaError(.fileReadCorruptFile)
                }
                // Legacy 13-sector archival images are often padded to the
                // modern 140 KB .dsk length, so their byte count alone cannot
                // identify the format. The bundled title declares its controller
                // firmware and mounts through the matching sector codec.
                lock.lock()
                lockHeld = true
                switch game.bootROM {
                case .appleIIPlus:
                    try memory.installIIPlusROM(systemROM: rom!.systemROM, diskROM: rom!.diskROM, diskFirmware: game.diskFirmware)
                case .appleIIeGameCompatible, .appleIIeEnhanced:
                    try memory.installIIeROM(iiEROM!.motherboardROM, diskROM: iiEROM!.diskROM, choice: .appleIIeEnhanced)
                default:
                    throw CocoaError(.fileReadCorruptFile)
                }
                memory.ejectDisk(drive: 0)
                memory.ejectDisk(drive: 1)
                for (drive, disk, data) in startupMedia.prefix(2) {
                    if game.diskFirmware == .thirteenSector {
                        try memory.mountThirteenSectorDisk(data, drive: drive, writeProtected: disk.writeProtected)
                    } else if ["dsk", "do"].contains(disk.resourceExtension.lowercased()) {
                        try memory.mountDSK(data, drive: drive, writeProtected: disk.writeProtected)
                    } else {
                        try memory.mountDiskImageData(
                            data,
                            fileExtension: disk.resourceExtension,
                            drive: drive,
                            writeProtected: disk.writeProtected
                        )
                    }
                }
                let bootsDriveOne = memory.hasDisk(in: 0)
                memory.coldBootSystemState()
                cpu.reset()
                let result = (snapshot: memory.makeVideoSnapshot(), bootsDriveOne: bootsDriveOne)
                lock.unlock()
                lockHeld = false
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.selectedBootROM = game.bootROM
                    self.hasExternalROM = true
                    self.activeMediaKind = .game
                    self.diskDescription = game.title
                    self.externalDiskDescription = startupMedia.count > 1 ? startupMedia[1].disk.description : "未插入"
                    self.wizardryScenarioDiskData = game == .wizardry ? startupMedia.dropFirst(2).first?.data : nil
                    let extraDiskNotice = startupMedia.count > 2 ? " · 已装入前两张盘" : ""
                    self.publishColdBoot(result, idleStatus: "\(game.bootROM.title) · \(game.diskFirmware.title) · \(game.title)\(extraDiskNotice)")
                    self.recordRecentGame(.bundled(game))
                }
            } catch {
                if lockHeld { lock.unlock() }
                DispatchQueue.main.async { [weak self] in self?.status = "无法装入内置游戏：\(game.title)" }
            }
        }
    }

    private func recordRecentGame(_ game: RecentGame) {
        recentGames = recentGameStore.record(game, after: recentGames)
    }

    private func removeRecentGame(_ game: RecentGame) {
        recentGames = recentGameStore.remove(game, from: recentGames)
    }

    func loadRecentGame(_ game: RecentGame) {
        switch game {
        case let .bundled(bundledGame):
            loadBundledGame(bundledGame)
        case let .diskImages(urls):
            loadDownloadedGame(at: urls, recentGame: game, preservesDriveOrder: true)
        }
    }

    var canSwapWizardryScenarioIntoDriveOne: Bool {
        guard case .game = activeMediaKind else { return false }
        return diskDescription == BundledGame.wizardry.title
    }

    /// Wizardry boots from its program disk, then expects its Scenario disk
    /// in the *same* physical drive. This performs the normal live-media
    /// action—no reset and no CPU shortcut—using the bundled Scenario image.
    func swapWizardryScenarioIntoDriveOne() {
        guard canSwapWizardryScenarioIntoDriveOne,
              let scenarioData = wizardryScenarioDiskData else {
            return
        }
        do {
            try installWizardryScenarioDisk(scenarioData, pressReturn: false)
            wizardryScenarioPromptHandled = true
            status = "Wizardry · 已将 Scenario 盘移入驱动器 1"
        } catch {
            status = "无法换入 Wizardry Scenario 磁盘"
        }
    }

    func loadBundledSoftware(_ software: BundledSoftware) {
        wordPerfectWorkDiskURL = nil
        if Self.isAutomatedRun {
            selectedBootROM = software.bootROM
            hasExternalROM = true
            activeMediaKind = .software
            diskDescription = software.startupDisks[0].description
            externalDiskDescription = software.startupDisks.count > 1
                ? software.startupDisks[1].description
                : "未插入"
        }
        status = "正在读取内置软件：\(software.title)…"
        let lock = emulationLock
        let memory = memory
        let cpu = cpu!
        submitEmulationTask { [weak self] in
            var lockHeld = false
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
                let rom = try AppleIIROMImages.iiE(software.bootROM)
                let wordPerfectWorkDisk: (url: URL, data: Data)?
                if software == .wordPerfect11 {
                    let persistentURL = try Self.wordPerfectWorkDiskStorageURL()
                    if FileManager.default.fileExists(atPath: persistentURL.path) {
                        wordPerfectWorkDisk = (persistentURL, try Data(contentsOf: persistentURL))
                    } else {
                        guard let bundledURL = AppResources.bundle.url(forResource: "WordPerfect 1.1 Work Disk", withExtension: "dsk") else {
                            throw CocoaError(.fileNoSuchFile)
                        }
                        wordPerfectWorkDisk = (persistentURL, try Data(contentsOf: bundledURL))
                    }
                } else {
                    wordPerfectWorkDisk = nil
                }
                lock.lock()
                lockHeld = true
                try memory.installIIeROM(rom.motherboardROM, diskROM: rom.diskROM, choice: software.bootROM)
                memory.ejectDisk(drive: 0)
                memory.ejectDisk(drive: 1)
                for (drive, disk, data) in startupMedia {
                    try memory.mountDiskImageData(
                        data,
                        fileExtension: disk.resourceExtension,
                        drive: drive
                    )
                }
                if let workDisk = wordPerfectWorkDisk {
                    try memory.mountDiskImageData(workDisk.data, fileExtension: workDisk.url.pathExtension, drive: 1)
                }
                let bootsDriveOne = memory.hasDisk(in: 0)
                memory.coldBootSystemState()
                cpu.reset()
                let result = (snapshot: memory.makeVideoSnapshot(), bootsDriveOne: bootsDriveOne)
                lock.unlock()
                lockHeld = false
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.selectedBootROM = software.bootROM
                    self.hasExternalROM = true
                    self.diskDescription = startupMedia[0].disk.description
                    self.activeMediaKind = .software
                    self.externalDiskDescription = wordPerfectWorkDisk == nil
                        ? (startupMedia.count > 1 ? startupMedia[1].disk.description : "未插入")
                        : "WordPerfect 工作盘（/WORK）"
                    self.wordPerfectWorkDiskURL = wordPerfectWorkDisk?.url
                    self.publishColdBoot(result, idleStatus: "\(software.bootROM.title) · \(software.title)")
                    if wordPerfectWorkDisk != nil { self.persistWordPerfectWorkDisk() }
                }
            } catch {
                if lockHeld { lock.unlock() }
                DispatchQueue.main.async { [weak self] in self?.status = "无法装入内置软件：\(software.title)" }
            }
        }
    }

    var downloadedGameInitials: [String] {
        gameLibrary.initials
    }

    func downloadedGames(startingWith initial: String) -> [GameLibrary.Game] {
        gameLibrary.games(startingWith: initial)
    }

    func loadDownloadedGame(_ game: GameLibrary.Game) {
        loadDownloadedGame(at: [game.url])
    }

    /// Opens additional local images. The packaged game menu is independent
    /// of the workspace; this picker only provides an explicit user choice.
    func chooseDownloadedGame() {
        let panel = NSOpenPanel()
        panel.title = "从已下载游戏库装入游戏"
        panel.message = "可选择多张 Apple II 5¼ 英寸游戏映像；将按路径名称顺序把前两张装入驱动器 1 和 2，并以 Apple II+ 启动"
        panel.allowedContentTypes = ["dsk", "do", "d13", "po", "nib", "2mg", "2img", "woz"].compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if let directory = Self.downloadedGamesDirectory() {
            panel.directoryURL = directory
        }
        guard panel.runModal() == .OK else { return }
        let urls = Self.sortedDiskURLs(panel.urls)
        guard !urls.isEmpty else { return }

        loadDownloadedGame(at: urls)
    }

    private func loadDownloadedGame(
        at urls: [URL],
        recentGame: RecentGame? = nil,
        preservesDriveOrder: Bool = false
    ) {
        let orderedURLs = preservesDriveOrder ? urls : Self.sortedDiskURLs(urls)
        guard !orderedURLs.isEmpty else { return }
        let mountedURLs = Array(orderedURLs.prefix(2))
        let queuedDiskCount = orderedURLs.count - mountedURLs.count

        status = "正在读取 \(mountedURLs.count) 张游戏磁盘…"
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result { (try AppleIIROMImages.iiE(.appleIIeEnhanced), try mountedURLs.map { ($0, try Data(contentsOf: $0)) }) }
            }.value
            guard let self else { return }

            switch result {
            case let .success((rom, images)):
                do {
                    self.persistWordPerfectWorkDisk()
                    self.wordPerfectWorkDiskURL = nil
                    try self.withEmulationLock {
                        try self.memory.installIIeROM(rom.motherboardROM, diskROM: rom.diskROM, choice: .appleIIeEnhanced)
                        self.memory.ejectDisk(drive: 0)
                        self.memory.ejectDisk(drive: 1)
                        for (drive, image) in images.enumerated() {
                            try self.memory.mountDiskImageData(
                                image.1,
                                fileExtension: image.0.pathExtension,
                                drive: drive
                            )
                        }
                    }
                    self.selectedBootROM = .appleIIeGameCompatible
                    self.activeMediaKind = .game
                    self.diskDescription = images[0].0.lastPathComponent
                    self.externalDiskDescription = images.count == 2 ? images[1].0.lastPathComponent : "未插入"
                    if queuedDiskCount > 0 {
                        self.status = "Apple IIe（游戏兼容） · 已按路径顺序装入前两张盘；其余 \(queuedDiskCount) 张需在需要时换盘"
                    } else {
                        self.status = images.count == 1
                            ? "Apple IIe（游戏兼容） · Disk II 16 扇区 · \(images[0].0.lastPathComponent)"
                            : "Apple IIe（游戏兼容） · 已按路径顺序装入驱动器 1 和 2"
                    }
                    self.reset()
                    self.recordRecentGame(.diskImages(images.map(\.0)))
                } catch {
                    self.status = "无法装入所选磁盘：仅支持 .dsk/.do/.d13/.po/.nib/.2mg/.2img"
                }
            case .failure:
                if let recentGame {
                    self.removeRecentGame(recentGame)
                    self.status = "最近游戏文件已不可用，已从记录中移除"
                } else {
                    self.status = "无法读取所选游戏磁盘"
                }
            }
        }
    }

    private static func sortedDiskURLs(_ urls: [URL]) -> [URL] {
        urls.sorted {
            $0.path.localizedStandardCompare($1.path) == .orderedAscending
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

    /// Opens media for an initial boot or a live disk swap.  Swapping media
    /// deliberately leaves the CPU running: a Disk II has no reset line, and
    /// multi-disk software depends on retaining all RAM state while the user
    /// changes disks.
    func chooseDiskImage(drive: Int = 0, resetsMachine: Bool = true) {
        let panel = NSOpenPanel()
        let availableDriveCount = 2 - drive
        panel.title = resetsMachine
            ? (availableDriveCount == 2 ? "装入 Apple II 磁盘映像" : "插入 Apple II 磁盘映像到驱动器 \(drive + 1)")
            : (availableDriveCount == 2 ? "运行中更换 Apple II 磁盘" : "运行中更换驱动器 \(drive + 1) 磁盘")
        panel.message = resetsMachine
            ? (availableDriveCount == 2
                ? "可同时选择一或两张映像，将依次装入驱动器 1 和 2"
                : "支持 .dsk/.do、13 扇区 .d13、ProDOS .po、.nib，以及 5¼ 英寸 .2mg/.2img 映像")
            : "更换不会重置 Apple II；多盘游戏会从当前运行状态继续读取新磁盘"
        panel.allowedContentTypes = ["dsk", "do", "d13", "po", "nib", "2mg", "2img", "woz"].compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = availableDriveCount > 1
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        guard !urls.isEmpty else { return }
        guard urls.count <= availableDriveCount else {
            status = "Apple II 只有两台 Disk II 驱动器；请一次选择最多 \(availableDriveCount) 张磁盘"
            return
        }
        status = "正在读取 \(urls.count) 张磁盘映像…"
        Task { [weak self] in
            let result = await Task.detached { Result { try urls.map { ($0, try Data(contentsOf: $0)) } } }.value
            guard let self else { return }
            switch result {
            case let .success(images):
                do {
                    if resetsMachine && (drive == 0 && images.count > 1 || drive == 1) {
                        self.persistWordPerfectWorkDisk()
                        self.wordPerfectWorkDiskURL = nil
                    }
                    if resetsMachine {
                        try self.withEmulationLock {
                            for (offset, image) in images.enumerated() {
                                try self.memory.mountDiskImageData(image.1, fileExtension: image.0.pathExtension, drive: drive + offset)
                            }
                        }
                        for (offset, image) in images.enumerated() {
                            self.setDiskDescription(image.0.lastPathComponent, drive: drive + offset)
                        }
                        self.activeMediaKind = .none
                        self.status = images.count == 1
                            ? "\(self.currentROMTitle) · 驱动器 \(drive + 1)：\(images[0].0.lastPathComponent)"
                            : "\(self.currentROMTitle) · 已装入驱动器 1 和 2"
                        self.reset()
                        if drive == 0 {
                            self.recordRecentGame(.diskImages(images.map(\.0)))
                        }
                    } else {
                        for (offset, image) in images.enumerated() {
                            try self.replaceDiskImageData(
                                image.1,
                                fileExtension: image.0.pathExtension,
                                description: image.0.lastPathComponent,
                                drive: drive + offset
                            )
                        }
                    }
                } catch {
                    self.status = "无法读取磁盘映像：仅支持 .dsk/.do/.d13/.po/.nib/.2mg/.2img"
                }
            case .failure:
                self.status = "无法读取所选磁盘映像"
            }
        }
    }

    /// Inserts a replacement disk without disturbing the emulated CPU. This
    /// is the programmatic half of the live media controls, and keeps disk
    /// swaps testable without an AppKit file picker.
    func replaceDiskImageData(
        _ data: Data,
        fileExtension: String,
        description: String,
        drive: Int
    ) throws {
        guard (0...1).contains(drive) else { throw CocoaError(.fileReadCorruptFile) }
        if drive == 1 {
            persistWordPerfectWorkDisk()
            wordPerfectWorkDiskURL = nil
        }
        try withEmulationLock {
            try memory.mountDiskImageData(data, fileExtension: fileExtension, drive: drive)
        }
        setDiskDescription(description, drive: drive)
        status = "\(currentROMTitle) · 已更换驱动器 \(drive + 1)：\(description)"
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
        if drive == 0 { activeMediaKind = .none }
        status = "\(currentROMTitle) · 驱动器 \(drive + 1) 未插入磁盘"
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

    func saveDiskAsWOZ(drive: Int = 0) {
        guard let data = withEmulationLock({ memory.wozImage(drive: drive) }) else {
            status = "驱动器 \(drive + 1) 的磁盘无法导出为 .woz"
            return
        }
        let panel = NSSavePanel()
        panel.title = "保存 Apple II WOZ 磁盘映像"
        panel.nameFieldStringValue = "AppleII-Drive\(drive + 1).woz"
        panel.allowedContentTypes = [.init(filenameExtension: "woz")!]
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

    private func persistWordPerfectWorkDisk() {
        guard let url = wordPerfectWorkDiskURL,
              let snapshot = withEmulationLock({ memory.nibImage(drive: 1) }) else { return }
        workDiskWriteQueue.async {
            try? snapshot.write(to: url, options: .atomic)
        }
    }

    nonisolated private static var isAutomatedRun: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || Bundle.allBundles.contains { $0.bundleURL.pathExtension == "xctest" }
            || CommandLine.arguments.contains { argument in
                argument.hasPrefix("--verify-") || argument.hasPrefix("--trace-")
            }
    }

    nonisolated private static func wordPerfectWorkDiskStorageURL() throws -> URL {
        let isRunningTests = isAutomatedRun
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
    var bytes = [UInt8](repeating: 0, count: 65_536)
    var auxiliaryBytes = [UInt8](repeating: 0, count: 65_536)
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
    var iicROM = [UInt8]()
    var iicROMBank = 0
    var iieROM = [UInt8]()
    var plusSlot6ROM = [UInt8]()
    var plusDiskFirmware: DiskIIFirmware?
    var model: Model = .appleIIPlus
    var supportsMouseText = false
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
            usesSevenBitASCII: model != .appleIIPlus,
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
            usesSevenBitASCII: model != .appleIIPlus,
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
            // With the external Slot 3 ROM selected, a machine without a
            // card in that slot must not mirror the IIe motherboard ROM.
            // The firmware uses this open slot response while probing cards;
            // returning the internal bytes here makes it believe a card is
            // installed and leaves SLOTC3ROM enabled after reset.
            if model == .appleIIe, (0xC300...0xC3FF).contains(a), slot3ROM, !internalCXROM {
                return 0
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

    /// Reset the volatile machine state for a user-requested system restart
    /// while preserving removable media. This differs from a 6502-only RESET:
    /// the Apple II+ ROM checks RAM to decide whether to enter Applesoft on a
    /// warm reset, so clearing RAM is necessary to restart the boot disk.
    func coldBootSystemState() {
        bytes.replaceSubrange(0..<0xC000, with: repeatElement(0, count: 0xC000))
        auxiliaryBytes.replaceSubrange(0..<0xC000, with: repeatElement(0, count: 0xC000))
        clearLanguageCard()
        resetHardwareState()
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

    func clearLanguageCard() {
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

    func mountDSK(_ data: Data, drive: Int = 0, writeProtected: Bool = false) throws {
        try diskController.mountDSK(data, drive: drive, writeProtected: writeProtected)
    }
    func mountThirteenSectorDisk(_ data: Data, drive: Int = 0, writeProtected: Bool = false) throws {
        try diskController.mountThirteenSectorImage(data, drive: drive, writeProtected: writeProtected)
    }
    func mountDiskImage(at url: URL, drive: Int = 0) throws { try diskController.mountImage(Data(contentsOf: url), fileExtension: url.pathExtension, drive: drive) }
    func mountDiskImageData(_ data: Data, fileExtension: String, drive: Int = 0, writeProtected: Bool? = nil) throws {
        if let writeProtected {
            switch DiskImageFormat(fileExtension: fileExtension) {
            case .dosOrder:
                try diskController.mountDSK(data, drive: drive, writeProtected: writeProtected)
            case .thirteenSector:
                try diskController.mountThirteenSectorImage(data, drive: drive, writeProtected: writeProtected)
            case .prodosOrder:
                try diskController.mountProDOS(data, drive: drive, writeProtected: writeProtected)
            default:
                try diskController.mountImage(data, fileExtension: fileExtension, drive: drive)
            }
        } else {
            try diskController.mountImage(data, fileExtension: fileExtension, drive: drive)
        }
    }
    func nibImage(drive: Int = 0) -> Data? { diskController.nibImage(drive: drive) }
    func wozImage(drive: Int = 0) -> Data? { diskController.wozImage(drive: drive) }
    func ejectDisk(drive: Int = 0) { diskController.eject(drive: drive) }
    var hasDisk: Bool { diskController.hasDisk }
    func hasDisk(in drive: Int) -> Bool { diskController.hasDisk(in: drive) }
    var diskNibbleReads: Int { diskController.nibbleReads }
    var diskNibbleWrites: Int { diskController.nibbleWrites }
    var diskTrack: Int { diskController.currentTrack() }
    var diskDebugSnapshot: DiskIIDebugSnapshot { diskController.debugSnapshot }

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

    func serialBaudRate(port: Int) -> Int {
        if port == 1 { return serialPort1.baudRate }
        if port == 2 { return serialPort2.baudRate }
        return 9_600
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
