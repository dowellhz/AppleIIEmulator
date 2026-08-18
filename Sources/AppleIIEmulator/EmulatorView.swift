import AppKit
import SwiftUI

/// HGR colour is decoded in pairs of adjacent memory dots (140 effective
/// colour pixels per row). Bit 7 selects the blue/orange phase palette for
/// its seven-dot byte; two illuminated dots are white in either palette.
enum AppleIIHiResColor: Equatable {
    case black, green, purple, white, orange, blue
}

func appleIIHiResColors(bytes: [UInt8]) -> [AppleIIHiResColor] {
    let storedDotCount = bytes.count * 7
    let dotCount = storedDotCount + (storedDotCount.isMultiple(of: 2) ? 0 : 1)
    var dots = [Bool](repeating: false, count: dotCount)
    var phaseShifted = [Bool](repeating: false, count: dotCount)
    for (column, byte) in bytes.enumerated() {
        for bit in 0..<7 {
            let x = column * 7 + bit
            dots[x] = byte & (1 << bit) != 0
            phaseShifted[x] = byte & 0x80 != 0
        }
    }

    return stride(from: 0, to: dots.count, by: 2).map { x in
        let pair = (dots[x] ? 2 : 0) | (dots[x + 1] ? 1 : 0)
        switch (phaseShifted[x], pair) {
        case (_, 0): return .black
        case (false, 1): return .green
        case (false, 2): return .purple
        case (true, 1): return .orange
        case (true, 2): return .blue
        default: return .white
        }
    }
}

struct EmulatorView: View {
    @ObservedObject var machine: AppleIIMachine

    var body: some View {
        VStack(spacing: 0) {
            monitor
                .frame(maxWidth: .infinity)
            settingsPanel
                .padding(.horizontal, 18)
                .padding(.top, 12)
                .padding(.bottom, 18)
        }
        .background(WindowTransparencyConfigurator())
        .preferredColorScheme(.dark)
    }

    private var monitor: some View {
        GeometryReader { proxy in
            ZStack {
                MonitorArtwork()

                // The supplied photograph is 1448×1084.  These normalized
                // bounds place the emulated 4:3 raster over its CRT glass,
                // leaving the original bezel, power controls and side panel
                // fully visible.
                let screenWidth = proxy.size.width * 0.62
                let screenCenter = CGPoint(x: proxy.size.width * 0.473, y: proxy.size.height * 0.50)
                // The original photo contains a green demonstration image on
                // its tube.  An opaque underlay covers it even at the rounded
                // corners of the live 4:3 raster.
                RoundedRectangle(cornerRadius: screenWidth * 0.035, style: .continuous)
                    .fill(Color(red: 0.008, green: 0.020, blue: 0.013))
                    .frame(width: screenWidth, height: screenWidth * 0.75)
                    .position(screenCenter)
                AppleIIScreen(memory: machine.memory, refreshToken: machine.refreshToken)
                    .background(KeyboardCapture { machine.keyDown($0) })
                    .frame(width: screenWidth)
                    .clipShape(RoundedRectangle(cornerRadius: screenWidth * 0.035, style: .continuous))
                    .overlay {
                        LinearGradient(colors: [.white.opacity(0.07), .clear, .white.opacity(0.02)], startPoint: .topLeading, endPoint: .bottomTrailing)
                            .clipShape(RoundedRectangle(cornerRadius: screenWidth * 0.035, style: .continuous))
                            .allowsHitTesting(false)
                    }
                    // The photo includes the monitor's right-hand control
                    // column, so its CRT center sits left of the full image
                    // centerline.
                    .position(screenCenter)
            }
        }
        .aspectRatio(1448.0 / 1084.0, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
    }

    private var settingsPanel: some View {
        VStack(spacing: 10) {
            HStack {
                Label("SYSTEM SETTINGS", systemImage: "cpu")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                Spacer()
                Text(machine.status)
                    .lineLimit(1)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.black.opacity(0.72))
            }
            Divider().overlay(Color.black.opacity(0.24))
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("DRIVE 1  \(machine.diskDescription)").lineLimit(1)
                    Text("DRIVE 2  \(machine.externalDiskDescription)").lineLimit(1)
                }
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.black.opacity(0.72))
                Spacer(minLength: 0)
                // Use direct menu actions rather than a Picker binding.  On a
                // transparent SwiftUI window the native menu-style Picker can
                // show a checkmark yet fail to commit the clicked value.
                Menu {
                    ForEach(AppleIIMachine.BootROM.allCases) { rom in
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
                } label: {
                    HStack(spacing: 7) {
                        Text(machine.selectedBootROM.title)
                            .lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 9, weight: .bold))
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.90))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.black.opacity(0.18)))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(Color.white.opacity(0.18), lineWidth: 1))
                }
                .menuStyle(.borderlessButton)
                Menu {
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
                } label: {
                    HStack(spacing: 7) {
                        Text("GAME")
                        Image(systemName: "gamecontroller")
                            .font(.system(size: 10, weight: .bold))
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.90))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.black.opacity(0.18)))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(Color.white.opacity(0.18), lineWidth: 1))
                }
                .menuStyle(.borderlessButton)
                Button(machine.isRunning ? "PAUSE" : "RUN") { machine.toggleRunning() }
                    .buttonStyle(MetalButtonStyle())
                Button("RESET") { machine.reset() }
                    .buttonStyle(MetalButtonStyle())
            }
            Text("GAME CONTROLS  \u{2190}\u{2191}\u{2192}\u{2193}: JOYSTICK   \u{2318}/\u{2325}: BUTTONS")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.black.opacity(0.62))
        }
        .padding(14)
        .foregroundStyle(Color(red: 0.10, green: 0.10, blue: 0.08))
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.56, green: 0.50, blue: 0.40), Color(red: 0.38, green: 0.33, blue: 0.25)], startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.white.opacity(0.25), lineWidth: 1))
        )
        .accessibilityHint("选择游戏后会自动装入磁盘；方向键控制摇杆，Command 和 Option 对应两个游戏按钮")
    }
}

private struct MetalButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(Color.white.opacity(0.92))
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color(red: 0.12, green: 0.12, blue: 0.10).opacity(configuration.isPressed ? 0.6 : 1)))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).stroke(Color.white.opacity(0.16), lineWidth: 1))
    }
}

private struct MonitorArtwork: View {
    var body: some View {
        if let url = Bundle.module.url(forResource: "AppleIIMonitorReference", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
        } else {
            // Kept as a visible fallback rather than silently drawing a
            // transparent window if a future app packaging change omits it.
            Color.black
        }
    }
}

/// SwiftUI's clear color alone is composited onto an opaque AppKit window.
/// Configure that host window once so the area around the monitor is truly
/// transparent rather than a black rectangle.
private struct WindowTransparencyConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> TransparentWindowHostView {
        TransparentWindowHostView(frame: .zero)
    }

    func updateNSView(_ nsView: TransparentWindowHostView, context: Context) {
        nsView.configureWindow()
    }

    final class TransparentWindowHostView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configureWindow()
        }

        func configureWindow() {
            guard let window else { return }
            window.isOpaque = false
            window.backgroundColor = .clear
            window.titlebarAppearsTransparent = true
            window.hasShadow = false
        }
    }
}

private struct AppleIIScreen: View {
    let memory: AppleIIMemory
    let refreshToken: Int
    private let green = Color(red: 0.40, green: 1.0, blue: 0.45)
    private let loresPalette: [Color] = [
        .black, Color(red: 0.88, green: 0.10, blue: 0.74), Color(red: 0.22, green: 0.10, blue: 0.62), Color(red: 0.92, green: 0.24, blue: 0.88),
        Color(red: 0.05, green: 0.45, blue: 0.10), .gray, Color(red: 0.10, green: 0.35, blue: 0.95), Color(red: 0.35, green: 0.55, blue: 1.0),
        Color(red: 0.48, green: 0.30, blue: 0.05), Color(red: 1.0, green: 0.45, blue: 0.12), .gray, Color(red: 1.0, green: 0.56, blue: 0.76),
        Color(red: 0.15, green: 0.82, blue: 0.22), Color(red: 0.95, green: 0.92, blue: 0.22), Color(red: 0.25, green: 0.95, blue: 0.52), .white
    ]
    private let doubleHiresPalette: [Color] = [
        .black, Color(red: 0.55, green: 0.05, blue: 0.55), Color(red: 0.10, green: 0.10, blue: 0.78), Color(red: 0.70, green: 0.18, blue: 0.82),
        Color(red: 0.05, green: 0.42, blue: 0.08), .gray, Color(red: 0.10, green: 0.38, blue: 0.98), Color(red: 0.38, green: 0.62, blue: 1.0),
        Color(red: 0.43, green: 0.28, blue: 0.05), Color(red: 0.96, green: 0.43, blue: 0.08), Color(red: 0.58, green: 0.58, blue: 0.58), Color(red: 1.0, green: 0.48, blue: 0.72),
        Color(red: 0.12, green: 0.78, blue: 0.18), Color(red: 0.92, green: 0.88, blue: 0.12), Color(red: 0.20, green: 0.96, blue: 0.48), .white
    ]

    var body: some View {
        Canvas { context, size in
            // Referencing this published refresh value invalidates Canvas at 60 Hz.
            _ = refreshToken
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(red: 0.018, green: 0.04, blue: 0.025)))
            if memory.textMode {
                drawText(in: &context, size: size)
            } else {
                let graphicRows = memory.mixedMode ? 160 : 192
                drawGraphics(in: &context, size: size, rows: graphicRows)
                if memory.mixedMode { drawText(in: &context, size: size, rows: 20..<24) }
            }
        }
        .aspectRatio(4.0 / 3.0, contentMode: .fit)
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(green.opacity(0.28), lineWidth: 1))
        .shadow(color: green.opacity(0.15), radius: 18)
        .accessibilityLabel("Apple II display")
    }

    private func drawText(in context: inout GraphicsContext, size: CGSize, rows: Range<Int> = 0..<24) {
        let columns = memory.column80 ? 80 : 40
        let cell = CGSize(width: size.width / CGFloat(columns), height: size.height / 24)
        // The hardware's character flasher alternates its $40-$7F bank while
        // ALTCHARSET is off.  A 60 Hz refresh counter gives its half-second
        // phase without an additional UI timer.
        let flashOn = (refreshToken / 30).isMultiple(of: 2)
        for row in rows {
            for col in 0..<columns {
                let byte = memory.textByte(column: col, row: row)
                guard byte != 0 else { continue }
                let presentation = appleIITextCell(byte: byte, alternateCharset: memory.alternateCharset, flashOn: flashOn)
                let (character, inverse) = appleCharacter(presentation)
                let rect = CGRect(x: CGFloat(col) * cell.width, y: CGFloat(row) * cell.height, width: cell.width, height: cell.height)
                if inverse { context.fill(Path(rect.insetBy(dx: 1, dy: 1)), with: .color(green)) }
                context.draw(
                    Text(character).font(.system(size: cell.height * 0.88, weight: .medium, design: .monospaced)).foregroundColor(inverse ? .black : green),
                    at: CGPoint(x: rect.midX, y: rect.midY)
                )
            }
        }
    }

    private func drawGraphics(in context: inout GraphicsContext, size: CGSize, rows: Int) {
        if memory.hires {
            if memory.doubleHires { drawDoubleHiRes(in: &context, size: size, rows: rows) }
            else { drawHiRes(in: &context, size: size, rows: rows) }
        } else {
            drawLoRes(in: &context, size: size, rows: rows)
        }
    }

    private func drawLoRes(in context: inout GraphicsContext, size: CGSize, rows: Int) {
        let displayRows = min(24, rows / 8)
        let width = size.width / 40
        let height = size.height / 48
        for row in 0..<displayRows {
            for column in 0..<40 {
                let value = memory.loresByte(column: column, row: row)
                let x = CGFloat(column) * width
                let y = CGFloat(row * 2) * height
                context.fill(Path(CGRect(x: x, y: y, width: width + 0.2, height: height + 0.2)), with: .color(loresPalette[Int(value & 0x0F)]))
                context.fill(Path(CGRect(x: x, y: y + height, width: width + 0.2, height: height + 0.2)), with: .color(loresPalette[Int(value >> 4)]))
            }
        }
    }

    private func drawHiRes(in context: inout GraphicsContext, size: CGSize, rows: Int) {
        let pixelWidth = size.width / 140
        let pixelHeight = size.height / 192
        let palette: [AppleIIHiResColor: Color] = [
            .green: Color(red: 0.20, green: 0.82, blue: 0.26),
            .purple: Color(red: 0.72, green: 0.20, blue: 0.82),
            .orange: Color(red: 0.96, green: 0.43, blue: 0.08),
            .blue: Color(red: 0.10, green: 0.42, blue: 0.96),
            .white: .white
        ]
        var paths = [AppleIIHiResColor: Path]()
        for row in 0..<rows {
            let bytes = (0..<40).map { memory.hgrByte(column: $0, row: row) }
            for (x, color) in appleIIHiResColors(bytes: bytes).enumerated() where color != .black {
                var path = paths[color, default: Path()]
                path.addRect(CGRect(x: CGFloat(x) * pixelWidth, y: CGFloat(row) * pixelHeight, width: pixelWidth + 0.1, height: pixelHeight + 0.15))
                paths[color] = path
            }
        }
        for (color, path) in paths {
            if let fill = palette[color] { context.fill(path, with: .color(fill)) }
        }
    }

    private func drawDoubleHiRes(in context: inout GraphicsContext, size: CGSize, rows: Int) {
        let pixelWidth = size.width / 560
        let pixelHeight = size.height / 192
        var paths = [Color: Path]()
        for row in 0..<rows {
            for column in 0..<40 {
                let aux = UInt16(memory.hgrByte(column: column, row: row, auxiliary: true) & 0x7F)
                let main = UInt16(memory.hgrByte(column: column, row: row) & 0x7F)
                let bits = aux | (main << 7)
                for group in 0..<7 {
                    let color = doubleHiresPalette[Int((bits >> UInt16(group * 2)) & 0x0F)]
                    let x = CGFloat((column * 7 + group) * 2) * pixelWidth
                    var path = paths[color, default: Path()]
                    path.addRect(CGRect(x: x, y: CGFloat(row) * pixelHeight, width: pixelWidth * 2.1, height: pixelHeight + 0.15))
                    paths[color] = path
                }
            }
        }
        for (color, path) in paths { context.fill(path, with: .color(color)) }
    }

    private func appleCharacter(_ presentation: AppleIITextCell) -> (String, Bool) {
        let code: UInt8
        let inverse: Bool
        switch presentation {
        case let .normal(value): code = value; inverse = false
        case let .inverse(value): code = value; inverse = true
        case let .alternate(value): return (alternateCharacter(value), false)
        }
        // Apple II text codes are six-bit values.  In particular $FF is
        // normal '?' ($3F), not an underscore as an ASCII mask would imply.
        if code < 0x20 { return (String(UnicodeScalar(code + 0x40)), inverse) }
        return (String(UnicodeScalar(code)), inverse)
    }

    private func alternateCharacter(_ code: UInt8) -> String {
        // $00-$1F is MouseText; $20-$3F is the IIe/IIc lowercase bank.
        let mouseText = ["◧", "◨", "▝", "▘", "▗", "▖", "▞", "▚",
                         "▐", "▔", "▏", "▕", "▁", "▂", "▃", "▇",
                         "◆", "◈", "◉", "▣", "↖", "↗", "↘", "↙",
                         "▌", "▐", "◀", "▶", "▲", "▼", "▤", "⌂"]
        if code < 0x20 { return mouseText[Int(code)] }
        if (0x21...0x3A).contains(code) { return String(UnicodeScalar(code + 0x60)) }
        return String(UnicodeScalar(code))
    }
}

private struct KeyboardCapture: NSViewRepresentable {
    let handler: (NSEvent) -> Void

    func makeNSView(context: Context) -> KeyView {
        let view = KeyView()
        view.handler = handler
        return view
    }
    func updateNSView(_ nsView: KeyView, context: Context) { nsView.handler = handler }

    final class KeyView: NSView {
        var handler: ((NSEvent) -> Void)?
        override var acceptsFirstResponder: Bool { true }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
                window.orderFrontRegardless()
                window.makeKeyAndOrderFront(nil)
                window.makeFirstResponder(self)
            }
        }
        override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }
        override func keyDown(with event: NSEvent) { handler?(event) }
    }
}
