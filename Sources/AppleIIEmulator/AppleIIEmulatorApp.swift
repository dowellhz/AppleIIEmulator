import SwiftUI
import Darwin

@main
struct AppleIIEmulatorApp: App {
    @StateObject private var machine: AppleIIMachine

    init() {
        let machine = AppleIIMachine()
        _machine = StateObject(wrappedValue: machine)
        if let status = HeadlessVerification.runIfRequested() {
            exit(status)
        }
        // Integration probe: unlike the headless CPU checks, this starts the
        // normal SwiftUI window and its Timer-driven execution path. It is
        // intentionally opt-in and leaves ordinary launches unchanged.
        if CommandLine.arguments.contains("--launch-wizardry") {
            DispatchQueue.main.async {
                machine.loadBundledGame(.wizardry)
            }
        }
        if CommandLine.arguments.contains("--trace-runtime-cycles") {
            Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
                Task { @MainActor in
                    print("AppleII runtime cycles=\(machine.presentedCPUCycles)")
                    fflush(stdout)
                }
            }
        }
        if CommandLine.arguments.contains("--trace-runtime-state") {
            Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
                Task { @MainActor in
                    let video = machine.videoSnapshot
                    let visible = video.hires
                        ? video.hgrMain.filter { $0 & 0x7F != 0 }.count
                        : video.text.filter { $0 & 0x7F != 0 && $0 & 0x7F != 0x20 }.count
                    let disk = machine.presentedDiskState
                    print("AppleII runtime pc=$\(String(machine.presentedProgramCounter, radix: 16)) visible=\(visible) text=\(video.textMode) hires=\(video.hires) motor=\(disk.motorOn) drive=\(disk.selectedDrive + 1) tracks=\(disk.tracks) readBits=\(disk.readBits)")
                    fflush(stdout)
                }
            }
        }
    }

    var body: some Scene {
        WindowGroup("Apple II Emulator") {
            EmulatorView(machine: machine)
                .frame(minWidth: 900, minHeight: 820)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands {
            CommandMenu("ROM") {
                ForEach(AppleIIMachine.BootROM.menuChoices) { rom in
                    Button(rom.title) { machine.selectROM(rom) }
                }
                Divider()
                Button("打开外部 ROM…") { machine.chooseExternalROM() }
            }
            CommandMenu("磁盘") {
                Button("装入磁盘映像…") { machine.chooseDiskImage(drive: 0) }
                    .keyboardShortcut("o", modifiers: .command)
                Button("仅装入驱动器 2 映像…") { machine.chooseDiskImage(drive: 1) }
                Divider()
                Button("运行中更换驱动器 1 磁盘…") { machine.chooseDiskImage(drive: 0, resetsMachine: false) }
                Button("运行中更换驱动器 2 磁盘…") { machine.chooseDiskImage(drive: 1, resetsMachine: false) }
                Button("Wizardry：将 Scenario 盘换入驱动器 1") { machine.swapWizardryScenarioIntoDriveOne() }
                    .disabled(!machine.canSwapWizardryScenarioIntoDriveOne)
                Button("插入测试启动盘") { machine.insertDiagnosticDisk() }
                Button("将驱动器 1 另存为 .nib…") { machine.saveDiskAsNIB(drive: 0) }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    // Menu construction occurs on the main actor. Asking the
                    // emulation queue for live controller state here can
                    // synchronously wait behind a disk-heavy CPU slice and
                    // freeze the entire window. These descriptions are
                    // published by every mount/eject operation on this actor.
                    .disabled(machine.diskDescription == "未插入")
                Button("将驱动器 2 另存为 .nib…") { machine.saveDiskAsNIB(drive: 1) }
                    .disabled(machine.externalDiskDescription == "未插入")
                Divider()
                Button("推出驱动器 1") { machine.ejectDisk(drive: 0) }
                    .disabled(machine.diskDescription == "未插入")
                Button("推出驱动器 2") { machine.ejectDisk(drive: 1) }
                    .disabled(machine.externalDiskDescription == "未插入")
            }
            CommandMenu("游戏") {
                if !machine.recentGames.isEmpty {
                    Menu("最近玩过") {
                        ForEach(machine.recentGames) { game in
                            Button(game.title) { machine.loadRecentGame(game) }
                        }
                    }
                    Divider()
                }
                if !machine.downloadedGames.isEmpty {
                    Menu("已下载游戏（\(machine.downloadedGames.count)）") {
                        ForEach(machine.downloadedGameInitials, id: \.self) { initial in
                            Menu(initial) {
                                ForEach(machine.downloadedGames(startingWith: initial)) { game in
                                    Button(game.title) { machine.loadDownloadedGame(game) }
                                }
                            }
                        }
                    }
                    Divider()
                }
                Button("从已下载游戏库打开…") { machine.chooseDownloadedGame() }
                Divider()
                ForEach(AppleIIMachine.BundledGame.defaultGameMenu) { game in
                    Button(game.title) { machine.loadBundledGame(game) }
                }
            }
            CommandMenu("软件") {
                ForEach(AppleIIMachine.BundledSoftware.allCases) { software in
                    Button(software.title) { machine.loadBundledSoftware(software) }
                }
            }
            CommandMenu("串口") {
                Button("刷新 macOS 串口") { machine.refreshSerialDevices() }
                Divider()
                serialPortMenu(title: "端口 1（打印机）", port: 1, connectedDevice: machine.serialPort1Device)
                serialPortMenu(title: "端口 2（调制解调器）", port: 2, connectedDevice: machine.serialPort2Device)
            }
            CommandGroup(after: .newItem) {
                Button("重置") { machine.reset() }
                    .keyboardShortcut("r", modifiers: .command)
            }
        }
    }

    @ViewBuilder
    private func serialPortMenu(title: String, port: Int, connectedDevice: String) -> some View {
        Menu(title) {
            Text(connectedDevice)
            Button("断开") { machine.disconnectSerialDevice(port: port) }
                .disabled(connectedDevice == "未连接")
            Divider()
            if machine.serialDevicePaths.isEmpty {
                Text("未发现 /dev/cu.* 设备")
            } else {
                ForEach(machine.serialDevicePaths, id: \.self) { path in
                    Button(path) { machine.connectSerialDevice(path, port: port) }
                }
            }
        }
        .disabled(!machine.supportsIIcSerial)
    }

}
