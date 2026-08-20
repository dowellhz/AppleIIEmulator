import AppKit
import SwiftUI

/// The controls sit directly on the supplied Apple II reference panel. The
/// artwork supplies the physical enclosure; SwiftUI adds live labels, LEDs,
/// and the interactive hit areas.
struct EmulatorControlsPanel: View {
    @ObservedObject var machine: AppleIIMachine
    @State private var menuPress: PanelControl?
    @State private var presentedMenu: PanelControl?
    @State private var resetIndicator = false

    private enum PanelControl {
        case game, software, rom

        var accessibilityLabel: String {
            switch self {
            case .game: "游戏"
            case .software: "软件"
            case .rom: "Apple ROM"
            }
        }
    }

    /// Source-pixel anchors from `ControlPanelReference.png` (2672×494).
    /// Keeping these in the artwork's own coordinate system prevents a
    /// resized window from introducing independent percentage approximations.
    private enum PanelAnchor {
        case drive1LED, drive2LED
        case gameLED, softwareLED, hardDiskLED, pauseLED, resetLED

        var pixel: CGPoint {
            switch self {
            case .drive1LED: CGPoint(x: 284, y: 208)
            case .drive2LED: CGPoint(x: 284, y: 294)
            case .gameLED: CGPoint(x: 1765, y: 160)
            case .softwareLED: CGPoint(x: 1966, y: 159)
            case .hardDiskLED: CGPoint(x: 2165, y: 159)
            case .pauseLED: CGPoint(x: 2366, y: 158)
            case .resetLED: CGPoint(x: 2533, y: 158)
            }
        }

        var buttonPixel: CGPoint {
            let led = pixel
            return CGPoint(x: led.x, y: 267)
        }
    }

    static let artworkAspectRatio = 2672.0 / 494.0
    private static let physicalButtonWidth: CGFloat = 145
    private static let physicalButtonHeight: CGFloat = 132

    var body: some View {
        ZStack {
            // The reference PNG has transparent, broadly rounded corners.
            // Fill those pixels first so the smaller SwiftUI mask below is
            // the sole visible corner radius of the assembled panel.
            Color(red: 0.43, green: 0.37, blue: 0.27)
            ControlPanelArtwork()

            GeometryReader { proxy in
                let width = proxy.size.width
                let height = proxy.size.height

                driveDescriptions(width: width, height: height)
                panelInformation(width: width, height: height)
                controls(width: width, height: height)
            }
        }
        // `EmulatorView` supplies this view's exact width and height from the
        // monitor chassis. Keeping the panel free of an aspect-ratio proposal
        // prevents SwiftUI from shrinking it to whatever vertical space is
        // left below the display.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 2.25, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityHint("选择游戏后会自动装入磁盘；方向键控制摇杆，Command 和 Option 对应两个游戏按钮")
    }

    @ViewBuilder
    private func driveDescriptions(width: CGFloat, height: CGFloat) -> some View {
        driveRow(description: machine.diskDescription, active: machine.diskDescription != "未插入", drive: 0, anchor: .drive1LED, width: width, height: height)
        driveRow(description: machine.externalDiskDescription, active: machine.externalDiskDescription != "未插入", drive: 1, anchor: .drive2LED, width: width, height: height)
    }

    @ViewBuilder
    private func driveRow(description: String, active: Bool, drive: Int, anchor: PanelAnchor, width: CGFloat, height: CGFloat) -> some View {
        let ledPosition = position(for: anchor, width: width, height: height)

        if active {
            PanelLED(onColor: .red)
                .frame(width: width * 0.011, height: width * 0.011)
                .position(ledPosition)
        }
        Button {
            // A live drive change preserves the CPU, controller and video
            // state; it is the on-panel equivalent of physically replacing a
            // Disk II disk while the program is waiting for it.
            machine.chooseDiskImage(drive: drive, resetsMachine: false)
        } label: {
            Text(description)
                // These are recessed black display windows in the artwork,
                // so live disk names need a light engraved-label colour.
                .font(.system(size: width * 0.0105, weight: .medium, design: .monospaced))
                .foregroundStyle(Color(red: 0.76, green: 0.68, blue: 0.51))
                .shadow(color: .black.opacity(0.96), radius: 1, x: 1, y: 1)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: width * 0.132, alignment: .leading)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .position(x: width * 0.202, y: ledPosition.y)
        .accessibilityLabel("驱动器 \(drive + 1)：\(description)")
        .accessibilityHint("点击以在运行中更换磁盘，不重置 Apple II")
        .help("点击以更换驱动器 \(drive + 1) 磁盘")
    }

    /// Text is placed only in the intentionally clear regions of the supplied
    /// artwork: the right half of the centre nameplate and the space after
    /// the fixed "GAME CONTROLS" engraving.
    @ViewBuilder
    private func panelInformation(width: CGFloat, height: CGFloat) -> some View {
        Text(panelStatusLines.rom)
            .panelText(size: width * 0.0095, weight: .semibold)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(width: width * 0.255, alignment: .leading)
            .position(position(x: 1_335, y: 257, width: width, height: height))

        Text(panelStatusLines.software)
            .panelText(size: width * 0.0095, weight: .semibold)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(width: width * 0.255, alignment: .leading)
            // Keep the running software/game name in the former one-line
            // status location; the ROM and controller line sits above it.
            .position(position(x: 1_335, y: 300, width: width, height: height))

        Text("← ↑ → ↓: JOYSTICK    ⌘ / ⌥: BUTTONS")
            .panelText(size: width * 0.0088, weight: .semibold)
            .lineLimit(1)
            // Starts after the engraved GAME CONTROLS label (x≈440).
            .frame(width: width * 0.250, alignment: .leading)
            .position(position(x: 830, y: 438, width: width, height: height))
    }

    @ViewBuilder
    private func controls(width: CGFloat, height: CGFloat) -> some View {
        panelMenuButton(.game, isActive: machine.activeMediaKind == .game, anchor: .gameLED, width: width, height: height) {
            gameMenu
        }
        panelMenuButton(.software, isActive: machine.activeMediaKind == .software, anchor: .softwareLED, width: width, height: height) {
            softwareMenu
        }
        panelMenuButton(.rom, isActive: machine.selectedBootROM != .appleIIPlus, anchor: .hardDiskLED, width: width, height: height) {
            romMenu
        }

        activeLED(!machine.isRunning, color: .red, anchor: .pauseLED, width: width, height: height)
        Button {
            machine.toggleRunning()
        } label: {
            PanelPushSurface()
        }
        .buttonStyle(PanelPushButtonStyle())
        .frame(width: width * Self.physicalButtonWidth / 2672, height: height * Self.physicalButtonHeight / 494)
        .position(position(for: .pauseLED, button: true, width: width, height: height))
        .accessibilityLabel(machine.isRunning ? "暂停" : "运行")

        activeLED(resetIndicator, color: .red, anchor: .resetLED, width: width, height: height)
        Button {
            machine.reset()
            flashResetIndicator()
        } label: {
            PanelPushSurface()
        }
        .buttonStyle(PanelPushButtonStyle())
        .frame(width: width * Self.physicalButtonWidth / 2672, height: height * Self.physicalButtonHeight / 494)
        .position(position(for: .resetLED, button: true, width: width, height: height))
        .accessibilityLabel("重置")

        cpuSpeedSwitch(width: width, height: height)
    }

    private func panelMenuButton<MenuContent: View>(
        _ control: PanelControl,
        isActive: Bool,
        anchor: PanelAnchor,
        width: CGFloat,
        height: CGFloat,
        @ViewBuilder content: @escaping () -> MenuContent
    ) -> some View {
        ZStack {
            // Status LED is deliberately outside the control's hit-testing
            // bounds. Only the illustrated rectangular button below accepts
            // the click.
            activeLED(isActive, color: .green, anchor: anchor, width: width, height: height)
            Button {
                flashMenu(control)
            } label: {
                PanelPushSurface(isPressed: menuPress == control)
            }
            .buttonStyle(.plain)
            // Covers the complete physical button face, matching PAUSE and
            // RESET rather than only a small menu-label target.
            .frame(width: width * Self.physicalButtonWidth / 2672, height: height * Self.physicalButtonHeight / 494)
            .position(position(for: anchor, button: true, width: width, height: height))
            .popover(
                isPresented: Binding(
                    get: { presentedMenu == control },
                    set: { if !$0 { presentedMenu = nil } }
                ),
                arrowEdge: .bottom
            ) {
                VStack(alignment: .leading, spacing: 4) {
                    content()
                }
                .padding(10)
            }
        }
        .accessibilityLabel(control.accessibilityLabel)
    }

    @ViewBuilder
    private func activeLED(_ isOn: Bool, color: Color, anchor: PanelAnchor, width: CGFloat, height: CGFloat) -> some View {
        if isOn {
            PanelLED(onColor: color)
                .frame(width: width * 0.011, height: width * 0.011)
                .position(position(for: anchor, width: width, height: height))
        }
    }

    private func position(for anchor: PanelAnchor, button: Bool = false, width: CGFloat, height: CGFloat) -> CGPoint {
        let pixel = button ? anchor.buttonPixel : anchor.pixel
        return position(x: pixel.x, y: pixel.y, width: width, height: height)
    }

    private func position(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) -> CGPoint {
        CGPoint(x: x * width / 2672, y: y * height / 494)
    }

    private var panelStatusLines: (rom: String, software: String) {
        let components = machine.status
            .components(separatedBy: " · ")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard components.count > 1 else {
            return (machine.currentROMTitle, machine.status)
        }
        return (components.dropLast().joined(separator: " · "), components[components.count - 1])
    }

    @ViewBuilder
    private func cpuSpeedSwitch(width: CGFloat, height: CGFloat) -> some View {
        // In the supplied artwork the ON position (right) is already drawn.
        // When switched off, cover only that existing thumb and place a
        // matching thumb into the left half of the original black well. This
        // deliberately does not draw a new track, so OFF, ON, and CPU 2X
        // remain the source artwork's pixel-perfect lettering.
        if !machine.isCPUAccelerated {
            // The supplied OFF artwork exactly covers the left button and
            // well. The source ON thumb continues 54 source pixels past that
            // crop, so hide only this residual portion underneath.
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Color(red: 0.105, green: 0.093, blue: 0.064))
                .frame(width: width * 54 / 2672, height: height * 58 / 494)
                .position(position(x: 2_517, y: 414, width: width, height: height))
            CPUSwitchOffArtwork()
                // This asset is the supplied 101×53 visual at the current
                // reference scale. Its 177×93 source-pixel footprint covers
                // the complete original ON switch before rendering the OFF
                // version, without touching OFF/ON lettering.
                .frame(width: width * 177 / 2672, height: height * 93 / 494)
                .position(position(x: 2_460, y: 414, width: width, height: height))
        }

        Button {
            withAnimation(.easeInOut(duration: 0.16)) {
                machine.isCPUAccelerated.toggle()
            }
        } label: {
            Color.clear.contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Exact hit area of the switch well: source x=2,369…2,551.
        .frame(width: width * 181 / 2672, height: height * 72 / 494)
        .position(position(x: 2_460, y: 414, width: width, height: height))
        .accessibilityLabel("CPU 两倍速度")
        .accessibilityValue(machine.isCPUAccelerated ? "开" : "关")
    }

    private var gameMenu: some View {
        Group {
            if !machine.recentBundledGames.isEmpty {
                Text("最近玩过")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(machine.recentBundledGames) { game in
                    Button(game.title) { machine.loadBundledGame(game) }
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
    }

    private var softwareMenu: some View {
        Group {
            ForEach(AppleIIMachine.BundledSoftware.allCases) { software in
                Button(software.title) { machine.loadBundledSoftware(software) }
            }
        }
    }

    private var romMenu: some View {
        Group {
            ForEach(AppleIIMachine.BootROM.menuChoices) { rom in
                Button {
                    machine.selectROM(rom)
                } label: {
                    if machine.selectedBootROM == rom {
                        Label(rom.title, systemImage: "checkmark")
                    } else {
                        Text(rom.title)
                    }
                }
            }
            Divider()
            Button("打开外部 ROM…") { machine.chooseExternalROM() }
        }
    }

    private func flashMenu(_ control: PanelControl) {
        guard menuPress != control else { return }
        withAnimation(.easeOut(duration: 0.08)) { menuPress = control }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
            guard menuPress == control else { return }
            withAnimation(.easeIn(duration: 0.12)) { menuPress = nil }
            presentedMenu = control
        }
    }

    private func flashResetIndicator() {
        resetIndicator = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { resetIndicator = false }
    }

}

private struct ControlPanelArtwork: View {
    var body: some View {
        if let url = AppResources.bundle.url(forResource: "ControlPanelReference", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
        } else {
            Color(red: 0.40, green: 0.34, blue: 0.24)
        }
    }
}

private struct PanelPushSurface: View {
    var isPressed = false

    var body: some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(Color.black.opacity(isPressed ? 0.36 : 0.001))
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(Color.black.opacity(isPressed ? 0.58 : 0), lineWidth: 2)
            }
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(Color.black.opacity(isPressed ? 0.30 : 0))
                    .frame(height: 3)
            }
            .scaleEffect(isPressed ? 0.955 : 1)
            .offset(y: isPressed ? 2 : 0)
            .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

private struct PanelPushButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.965 : 1)
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.black.opacity(configuration.isPressed ? 0.28 : 0.001))
            }
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

private struct PanelLED: View {
    let onColor: Color

    var body: some View {
        Circle()
            .fill(onColor)
            .overlay(Circle().stroke(Color.black.opacity(0.72), lineWidth: 1))
            .shadow(color: onColor.opacity(0.88), radius: 4)
            .transition(.opacity)
    }
}

private struct CPUSwitchOffArtwork: View {
    var body: some View {
        if let url = AppResources.bundle.url(forResource: "CPUSwitchOff", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
        }
    }
}

private extension View {
    func panelText(size: CGFloat, weight: Font.Weight) -> some View {
        font(.system(size: size, weight: weight, design: .monospaced))
            .foregroundStyle(Color.black.opacity(0.78))
    }
}
