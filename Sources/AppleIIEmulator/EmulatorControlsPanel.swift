import AppKit
import SwiftUI

/// Native controls kept separate from the monitor/raster view so changing a
/// menu never invalidates the display renderer.
struct EmulatorControlsPanel: View {
    @ObservedObject var machine: AppleIIMachine

    var body: some View {
        ZStack {
            VintagePlasticBackground()
            VStack(spacing: 10) {
                HStack {
                    Label("SYSTEM SETTINGS", systemImage: "cpu").font(.system(size: 11, weight: .bold, design: .monospaced))
                    Spacer()
                    Text(machine.status).lineLimit(1).font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(Color.black.opacity(0.72))
                }
                Divider().overlay(Color.black.opacity(0.24))
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("DRIVE 1  \(machine.diskDescription)").lineLimit(1)
                        Text("DRIVE 2  \(machine.externalDiskDescription)").lineLimit(1)
                    }.font(.system(size: 9, weight: .semibold, design: .monospaced)).foregroundStyle(Color.black.opacity(0.72))
                    Spacer(minLength: 0)
                    romMenu
                    gameMenu
                    Button(machine.isRunning ? "PAUSE" : "RUN") { machine.toggleRunning() }.buttonStyle(MetalButtonStyle())
                    Button("RESET") { machine.reset() }.buttonStyle(MetalButtonStyle())
                }
                Text("GAME CONTROLS  ←↑→↓: JOYSTICK   ⌘/⌥: BUTTONS").font(.system(size: 9, weight: .semibold, design: .monospaced)).foregroundStyle(Color.black.opacity(0.62))
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity)
        .foregroundStyle(Color(red: 0.12, green: 0.105, blue: 0.075))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityHint("选择游戏后会自动装入磁盘；方向键控制摇杆，Command 和 Option 对应两个游戏按钮")
    }

    private var romMenu: some View {
        Menu {
            ForEach(AppleIIMachine.BootROM.allCases) { rom in
                Button { machine.selectROM(rom) } label: {
                    if machine.selectedBootROM == rom {
                        Label(rom.title, systemImage: "checkmark")
                    } else {
                        Text(rom.title)
                    }
                }
            }
        } label: { controlLabel(machine.selectedBootROM.title, icon: "chevron.up.chevron.down") }
        .menuStyle(.borderlessButton)
    }

    private var gameMenu: some View {
        Menu {
            if !machine.downloadedGames.isEmpty {
                Menu("已下载游戏（\(machine.downloadedGames.count)）") {
                    ForEach(machine.downloadedGameInitials, id: \.self) { initial in
                        Menu(initial) { ForEach(machine.downloadedGames(startingWith: initial)) { game in Button(game.title) { machine.loadDownloadedGame(game) } } }
                    }
                }
                Divider()
            }
            Button("从已下载游戏库打开…") { machine.chooseDownloadedGame() }
            Divider()
            ForEach(AppleIIMachine.BundledGame.allCases) { game in Button(game.title) { machine.loadBundledGame(game) } }
        } label: { controlLabel("GAME", icon: "gamecontroller") }
        .menuStyle(.borderlessButton)
    }

    private func controlLabel(_ title: String, icon: String) -> some View {
        HStack(spacing: 7) { Text(title).lineLimit(1); Image(systemName: icon).font(.system(size: 10, weight: .bold)) }
            .font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.white.opacity(0.90)).padding(.horizontal, 12).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.black.opacity(0.18)))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(Color.white.opacity(0.18), lineWidth: 1))
    }

}

/// An AppKit image view avoids SwiftUI background proposal/cropping behaviour.
/// Its lack of an intrinsic size lets the controls define the panel height,
/// while AppKit scales the opaque texture into the exact panel bounds.
private struct VintagePlasticBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> TextureImageView {
        let imageView = TextureImageView()
        imageView.image = Bundle.module.url(forResource: "VintagePlasticTexture", withExtension: "png")
            .flatMap(NSImage.init(contentsOf:))
        return imageView
    }

    func updateNSView(_ nsView: TextureImageView, context: Context) {}

    final class TextureImageView: NSImageView {
        override var intrinsicContentSize: NSSize {
            NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
        }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            imageScaling = .scaleAxesIndependently
            imageAlignment = .alignCenter
            imageFrameStyle = .none
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
    }
}
