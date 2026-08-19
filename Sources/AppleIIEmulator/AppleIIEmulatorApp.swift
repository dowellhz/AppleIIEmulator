import SwiftUI

@main
struct AppleIIEmulatorApp: App {
    @StateObject private var machine = AppleIIMachine()

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
                Button("插入驱动器 1 映像…") { machine.chooseDiskImage(drive: 0) }
                    .keyboardShortcut("o", modifiers: .command)
                Button("插入驱动器 2 映像…") { machine.chooseDiskImage(drive: 1) }
                Button("插入测试启动盘") { machine.insertDiagnosticDisk() }
                Button("将驱动器 1 另存为 .nib…") { machine.saveDiskAsNIB(drive: 0) }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(!machine.memory.hasDisk(in: 0))
                Button("将驱动器 2 另存为 .nib…") { machine.saveDiskAsNIB(drive: 1) }
                    .disabled(!machine.memory.hasDisk(in: 1))
                Divider()
                Button("推出驱动器 1") { machine.ejectDisk(drive: 0) }
                    .disabled(!machine.memory.hasDisk(in: 0))
                Button("推出驱动器 2") { machine.ejectDisk(drive: 1) }
                    .disabled(!machine.memory.hasDisk(in: 1))
            }
            CommandMenu("游戏") {
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
                ForEach(AppleIIMachine.BundledGame.allCases) { game in
                    Button(game.title) { machine.loadBundledGame(game) }
                }
            }
            CommandMenu("软件") {
                ForEach(AppleIIMachine.BundledSoftware.allCases) { software in
                    Button(software.title) { machine.loadBundledSoftware(software) }
                }
            }
            CommandGroup(after: .newItem) {
                Button("重置") { machine.reset() }
                    .keyboardShortcut("r", modifiers: .command)
            }
        }
    }
}
