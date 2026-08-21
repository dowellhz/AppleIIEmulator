import AppKit
import SwiftUI

struct EmulatorView: View {
    @ObservedObject var machine: AppleIIMachine
    @State private var isFullscreen = false
    @AppStorage("emulatorTheme") private var emulatorTheme = EmulatorTheme.classic.rawValue

    private var theme: EmulatorTheme {
        EmulatorTheme(rawValue: emulatorTheme) ?? .classic
    }

    var body: some View {
        Group {
            if isFullscreen {
                fullscreenDisplay
            } else {
                chassis
            }
        }
        .background(WindowTransparencyConfigurator(isFullscreen: $isFullscreen))
        .frame(
            minWidth: ChassisLayout.minimumWidth,
            idealWidth: ChassisLayout.preferredWidth,
            minHeight: ChassisLayout.minimumHeight,
            idealHeight: ChassisLayout.idealHeight
        )
        .preferredColorScheme(.dark)
        .overlay(alignment: .topLeading) {
            if machine.isDebuggerVisible {
                EmulatorDebuggerHUD(machine: machine)
            }
        }
    }

    private var chassis: some View {
        GeometryReader { proxy in
            // Fit the *entire* monitor-and-panel assembly in the available
            // height. Without this limit, stretching a window horizontally
            // could enlarge the monitor until the lower edge of the supplied
            // control-panel artwork was clipped offscreen.
            let heightLimitedWidth = ChassisLayout.maximumWidth(forAvailableHeight: proxy.size.height)
            let chassisWidth = min(proxy.size.width, ChassisLayout.preferredWidth, heightLimitedWidth)
            let panelHeight = ChassisLayout.panelHeight(for: chassisWidth)

            // The regenerated monitor/panel pairs include their own mating
            // lips. Seat each complete control-panel backdrop over that lip
            // so the chassis stays continuous; its live controls retain the
            // same coordinate system inside the panel.
            let chassisOverlap: CGFloat = theme == .modern ? -32 : (theme == .ivory ? -34 : -2)
            VStack(spacing: chassisOverlap) {
                monitor(width: chassisWidth)
                EmulatorControlsPanel(machine: machine, theme: theme)
                    .frame(width: chassisWidth, height: panelHeight)
            }
            .frame(width: chassisWidth)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    private var fullscreenDisplay: some View {
        GeometryReader { proxy in
            let available = proxy.size
            let displayWidth = min(available.width, available.height * 4 / 3)
            let displayHeight = displayWidth * 3 / 4

            ZStack {
                Color.black
                emulatedScreen(width: displayWidth, height: displayHeight)
            }
            .frame(width: available.width, height: available.height)
        }
        .ignoresSafeArea()
    }

    /// A deliberately new enclosure rather than a recolor of the reference
    /// photograph. It keeps the raster and hardware controls intact while
    /// presenting them as a compact, contemporary desktop instrument.
    private var modernChassis: some View {
        GeometryReader { proxy in
            let width = max(680, proxy.size.width)
            let contentWidth = min(width - 72, 1_140)
            let screenWidth = min(contentWidth * 0.70, (proxy.size.height - 330) * 4 / 3)
            let safeScreenWidth = max(440, screenWidth)

            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.025, green: 0.045, blue: 0.090),
                        Color(red: 0.045, green: 0.105, blue: 0.145),
                        Color(red: 0.018, green: 0.030, blue: 0.062)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                Canvas { context, size in
                    let spacing: CGFloat = 32
                    for x in stride(from: 0, through: size.width, by: spacing) {
                        context.stroke(Path(CGPath(rect: CGRect(x: x, y: 0, width: 1, height: size.height), transform: nil)), with: .color(.white.opacity(0.025)))
                    }
                    for y in stride(from: 0, through: size.height, by: spacing) {
                        context.stroke(Path(CGPath(rect: CGRect(x: 0, y: y, width: size.width, height: 1), transform: nil)), with: .color(.white.opacity(0.025)))
                    }
                }
                .allowsHitTesting(false)

                VStack(spacing: 20) {
                    modernHeader

                    HStack(alignment: .top, spacing: 20) {
                        modernScreen(width: safeScreenWidth)
                        modernStatusRail
                            .frame(width: min(260, contentWidth * 0.27))
                    }
                    .frame(maxWidth: contentWidth, alignment: .center)

                    modernControlDeck
                        .frame(maxWidth: contentWidth)
                }
                .padding(.horizontal, 36)
                .padding(.vertical, 30)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
    }

    private var modernHeader: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(LinearGradient(colors: [Color.cyan, Color.blue], startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "circle.grid.cross")
                    .font(.system(size: 21, weight: .bold))
                    .foregroundStyle(.black.opacity(0.78))
            }
            .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 3) {
                Text("APPLE II")
                    .font(.system(size: 22, weight: .black, design: .rounded))
                    .tracking(2.5)
                Text("MODERN EMULATION CONSOLE")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(1.2)
                    .foregroundStyle(.cyan.opacity(0.78))
            }

            Spacer()

            HStack(spacing: 7) {
                Circle()
                    .fill(machine.isRunning ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                    .shadow(color: machine.isRunning ? .green : .orange, radius: 6)
                Text(machine.isRunning ? "RUNNING" : "PAUSED")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.86))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(.black.opacity(0.28), in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.12), lineWidth: 1))
        }
        .frame(maxWidth: 1_140)
    }

    private func modernScreen(width: CGFloat) -> some View {
        let height = width * 3 / 4
        return ZStack {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(Color.black.opacity(0.42))
                .overlay {
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .stroke(LinearGradient(colors: [.cyan.opacity(0.8), .blue.opacity(0.22), .white.opacity(0.15)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1.2)
                }
                .shadow(color: .cyan.opacity(0.18), radius: 28, y: 12)

            emulatedScreen(width: width - 26, height: height - 26)
                .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))

            Text("6502  •  (machine.currentROMTitle.uppercased())")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .tracking(1)
                .foregroundStyle(.white.opacity(0.50))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(13)
                .allowsHitTesting(false)
        }
        .frame(width: width, height: height)
    }

    private var modernStatusRail: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("SYSTEM")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .tracking(1.4)
                .foregroundStyle(.cyan)

            modernStatusRow(title: "ROM", value: machine.currentROMTitle, icon: "memorychip")
            modernStatusRow(title: "DRIVE 1", value: machine.diskDescription, icon: "opticaldiscdrive")
            modernStatusRow(title: "DRIVE 2", value: machine.externalDiskDescription, icon: "opticaldiscdrive")
            modernStatusRow(title: "SMARTPORT", value: machine.hardDiskDescription, icon: "internaldrive")

            Spacer(minLength: 8)

            Text(machine.status)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.60))
                .lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 6)
        }
        .padding(16)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(.white.opacity(0.10), lineWidth: 1))
    }

    private func modernStatusRow(title: String, value: String, icon: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(value == "未插入" ? .white.opacity(0.32) : .cyan)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.40))
                Text(value)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.82))
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
        }
    }

    private var modernControlDeck: some View {
        HStack(spacing: 10) {
            modernAction(title: machine.isRunning ? "暂停" : "继续", subtitle: machine.isRunning ? "PAUSE CPU" : "RESUME CPU", icon: machine.isRunning ? "pause.fill" : "play.fill", color: .orange) {
                machine.toggleRunning()
            }
            modernAction(title: "重置", subtitle: "COLD BOOT", icon: "arrow.counterclockwise", color: .pink) {
                machine.reset()
            }
            modernAction(title: "装入磁盘", subtitle: "DRIVE 1", icon: "externaldrive.fill", color: .cyan) {
                machine.chooseDiskImage(drive: 0)
            }
            modernAction(title: "驱动器 2", subtitle: "HOT SWAP", icon: "opticaldiscdrive.fill", color: .purple) {
                machine.chooseDiskImage(drive: 1, resetsMachine: false)
            }
        }
        .padding(12)
        .background(.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(.white.opacity(0.10), lineWidth: 1))
    }

    private func modernAction(title: String, subtitle: String, icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .bold))
                    .frame(width: 30, height: 30)
                    .background(color.opacity(0.22), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .foregroundStyle(color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .bold))
                    Text(subtitle)
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .tracking(0.6)
                        .foregroundStyle(.white.opacity(0.48))
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(.white.opacity(0.92))
            .padding(10)
            .frame(maxWidth: .infinity)
            .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(color.opacity(0.28), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(title)
    }

    private func monitor(width chassisWidth: CGFloat) -> some View {
        let monitorHeight = ChassisLayout.monitorHeight(for: chassisWidth)
        let screenWidth = chassisWidth * 0.62
        let screenHeight = screenWidth * 0.75
        let screenCenter = CGPoint(
            x: chassisWidth * 0.473,
            y: monitorHeight * 0.50
        )

        return ZStack {
            MonitorArtwork(theme: theme)
                .frame(width: chassisWidth, height: monitorHeight)

            // The supplied photograph is 1448×1084.  These normalized bounds
            // place the emulated 4:3 raster over its CRT glass, leaving the
            // original bezel, power controls and side panel fully visible.
            RoundedRectangle(cornerRadius: screenWidth * 0.035, style: .continuous)
                .fill(Color(red: 0.008, green: 0.020, blue: 0.013))
                .frame(width: screenWidth, height: screenHeight)
                .position(screenCenter)
            emulatedScreen(width: screenWidth, height: screenHeight)
                // The photo includes the monitor's right-hand control column,
                // so its CRT center sits left of the full image centerline.
                .position(screenCenter)
        }
        .frame(width: chassisWidth, height: monitorHeight)
        // Keep the enclosure only subtly rounded.  The reference monitor has
        // nearly square corners, rather than the large modern-card radius.
        .clipShape(RoundedRectangle(cornerRadius: 7.5, style: .continuous))
    }

    private func emulatedScreen(width: CGFloat, height: CGFloat) -> some View {
        let cornerRadius = min(width, height) * 0.035
        return AppleIIScreen(video: machine.videoSnapshot, refreshToken: machine.refreshToken)
            .background(KeyboardCapture(
                keyDown: { machine.keyDown($0) },
                mouseMoved: { machine.mouseMoved($0) },
                mouseButton: { index, pressed in machine.mouseButton(index, pressed: pressed) }
            ))
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                LinearGradient(colors: [.white.opacity(0.07), .clear, .white.opacity(0.02)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    .allowsHitTesting(false)
            }
    }

}

/// All visible parts of the emulator enclosure share these dimensions.  This
/// prevents a flexible SwiftUI child from making the control panel and monitor
/// negotiate different widths.
private enum ChassisLayout {
    static let preferredWidth: CGFloat = 960
    static let minimumWidth: CGFloat = 720
    // The supplied control-panel reference is 2672×494. Keep this in step
    // with `EmulatorControlsPanel` so the window never clips its artwork.
    static let panelHeight: CGFloat = panelHeight(for: preferredWidth)
    static let verticalSpacing: CGFloat = 30

    static func monitorHeight(for width: CGFloat) -> CGFloat {
        width / (1448.0 / 1084.0)
    }

    static func panelHeight(for width: CGFloat) -> CGFloat {
        width / EmulatorControlsPanel.artworkAspectRatio
    }

    static func maximumWidth(forAvailableHeight height: CGFloat) -> CGFloat {
        let usableHeight = max(0, height - verticalSpacing)
        let heightPerWidth = (1 / (1448.0 / 1084.0)) + (1 / EmulatorControlsPanel.artworkAspectRatio)
        return usableHeight / heightPerWidth
    }

    static let minimumHeight = monitorHeight(for: minimumWidth) + panelHeight(for: minimumWidth) + verticalSpacing
    static let idealHeight = monitorHeight(for: preferredWidth) + panelHeight + verticalSpacing
}

struct MetalButtonStyle: ButtonStyle {
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
    let theme: EmulatorTheme

    private var resourceName: String {
        switch theme {
        case .classic: "AppleIIMonitorReference"
        case .modern: "AppleIIMonitorNewReference"
        case .ivory: "AppleIIMonitorIvoryReference"
        }
    }

    var body: some View {
        if let url = AppResources.bundle.url(forResource: resourceName, withExtension: "png"),
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
    @Binding var isFullscreen: Bool

    func makeNSView(context: Context) -> TransparentWindowHostView {
        let view = TransparentWindowHostView(frame: .zero)
        view.fullscreenChanged = { isFullscreen = $0 }
        return view
    }

    func updateNSView(_ nsView: TransparentWindowHostView, context: Context) {
        nsView.fullscreenChanged = { isFullscreen = $0 }
        nsView.configureWindow()
    }

    final class TransparentWindowHostView: NSView {
        var fullscreenChanged: ((Bool) -> Void)?
        private weak var observedWindow: NSWindow?
        private var fullscreenObservers = [NSObjectProtocol]()

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configureWindow()
            observeFullscreenState()
        }

        func configureWindow() {
            guard let window else { return }
            window.isOpaque = false
            window.backgroundColor = .clear
            window.titlebarAppearsTransparent = true
            window.hasShadow = false

            // A previously saved window frame can predate a taller panel
            // asset. Set a real AppKit minimum here as well as SwiftUI's view
            // minimum, otherwise the monitor grows while the controls are
            // silently clipped below the window.
            let minimum = NSSize(
                width: ChassisLayout.minimumWidth,
                height: ChassisLayout.minimumHeight
            )
            window.contentMinSize = minimum
            if let contentView = window.contentView,
               (contentView.bounds.width < minimum.width || contentView.bounds.height < minimum.height) {
                window.setContentSize(NSSize(
                    width: ChassisLayout.preferredWidth,
                    height: ChassisLayout.idealHeight
                ))
            }
        }

        private func observeFullscreenState() {
            guard let window, observedWindow !== window else { return }
            removeFullscreenObservers()
            observedWindow = window
            let center = NotificationCenter.default
            fullscreenObservers = [
                center.addObserver(forName: NSWindow.didEnterFullScreenNotification, object: window, queue: .main) { [weak self] _ in
                    self?.fullscreenChanged?(true)
                },
                center.addObserver(forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main) { [weak self] _ in
                    self?.fullscreenChanged?(false)
                }
            ]
            fullscreenChanged?(window.styleMask.contains(.fullScreen))
        }

        private func removeFullscreenObservers() {
            let center = NotificationCenter.default
            fullscreenObservers.forEach(center.removeObserver)
            fullscreenObservers.removeAll()
        }

        deinit { removeFullscreenObservers() }
    }
}

private struct AppleIIScreen: View {
    let video: AppleIIVideoSnapshot
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
            if video.textMode {
                drawText(in: &context, size: size, video: video)
            } else {
                let graphicRows = video.mixedMode ? 160 : 192
                drawGraphics(in: &context, size: size, rows: graphicRows, video: video)
                if video.mixedMode { drawText(in: &context, size: size, rows: 20..<24, video: video) }
            }
        }
        .aspectRatio(4.0 / 3.0, contentMode: .fit)
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(green.opacity(0.28), lineWidth: 1))
        .shadow(color: green.opacity(0.15), radius: 18)
        .accessibilityLabel("Apple II display")
    }

    private func drawText(in context: inout GraphicsContext, size: CGSize, rows: Range<Int> = 0..<24, video: AppleIIVideoSnapshot) {
        let columns = video.column80 ? 80 : 40
        let cell = CGSize(width: size.width / CGFloat(columns), height: size.height / 24)
        // A 7×8 Apple glyph becomes half as wide in 80-column mode.  Font
        // size cannot be based on row height alone or adjacent glyphs overlap
        // and appear as corrupted text.
        let fontSize = min(cell.height * 0.88, cell.width * 1.45)
        // The hardware's character flasher alternates its $40-$7F bank while
        // ALTCHARSET is off.  A 60 Hz refresh counter gives its half-second
        // phase without an additional UI timer.
        let flashOn = (refreshToken / 30).isMultiple(of: 2)
        for row in rows {
            for col in 0..<columns {
                let byte = video.textByte(column: col, row: row)
                guard byte != 0 else { continue }
                let presentation = video.column80
                    ? appleII80ColumnTextCell(byte: byte, alternateCharset: video.alternateCharset, flashOn: flashOn, supportsMouseText: video.supportsMouseText)
                    : appleIITextCell(byte: byte, alternateCharset: video.alternateCharset, flashOn: flashOn, supportsMouseText: video.supportsMouseText, usesSevenBitASCII: video.usesSevenBitASCII)
                let (character, inverse) = appleCharacter(presentation)
                let rect = CGRect(x: CGFloat(col) * cell.width, y: CGFloat(row) * cell.height, width: cell.width, height: cell.height)
                if inverse { context.fill(Path(rect.insetBy(dx: 1, dy: 1)), with: .color(green)) }
                context.draw(
                    Text(character).font(.system(size: fontSize, weight: .medium, design: .monospaced)).foregroundColor(inverse ? .black : green),
                    at: CGPoint(x: rect.midX, y: rect.midY)
                )
            }
        }
    }

    private func drawGraphics(in context: inout GraphicsContext, size: CGSize, rows: Int, video: AppleIIVideoSnapshot) {
        if video.hires {
            if video.doubleHires { drawDoubleHiRes(in: &context, size: size, rows: rows, video: video) }
            else { drawHiRes(in: &context, size: size, rows: rows, video: video) }
        } else {
            drawLoRes(in: &context, size: size, rows: rows, video: video)
        }
    }

    private func drawLoRes(in context: inout GraphicsContext, size: CGSize, rows: Int, video: AppleIIVideoSnapshot) {
        let displayRows = min(24, rows / 8)
        let width = size.width / 40
        let height = size.height / 48
        for row in 0..<displayRows {
            for column in 0..<40 {
                let value = video.loresByte(column: column, row: row)
                let x = CGFloat(column) * width
                let y = CGFloat(row * 2) * height
                context.fill(Path(CGRect(x: x, y: y, width: width + 0.2, height: height + 0.2)), with: .color(loresPalette[Int(value & 0x0F)]))
                context.fill(Path(CGRect(x: x, y: y + height, width: width + 0.2, height: height + 0.2)), with: .color(loresPalette[Int(value >> 4)]))
            }
        }
    }

    private func drawHiRes(in context: inout GraphicsContext, size: CGSize, rows: Int, video: AppleIIVideoSnapshot) {
        let pixelWidth = size.width / 280
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
            let bytes = (0..<40).map { video.hgrByte(column: $0, row: row, auxiliary: false) }
            for (x, color) in appleIIHiResDots(bytes: bytes).enumerated() where color != .black {
                var path = paths[color, default: Path()]
                path.addRect(CGRect(x: CGFloat(x) * pixelWidth, y: CGFloat(row) * pixelHeight, width: pixelWidth + 0.1, height: pixelHeight + 0.15))
                paths[color] = path
            }
        }
        for (color, path) in paths {
            if let fill = palette[color] { context.fill(path, with: .color(fill)) }
        }
    }

    private func drawDoubleHiRes(in context: inout GraphicsContext, size: CGSize, rows: Int, video: AppleIIVideoSnapshot) {
        let pixelWidth = size.width / 560
        let pixelHeight = size.height / 192
        var paths = [Color: Path]()
        for row in 0..<rows {
            for column in 0..<40 {
                let aux = UInt16(video.hgrByte(column: column, row: row, auxiliary: true) & 0x7F)
                let main = UInt16(video.hgrByte(column: column, row: row, auxiliary: false) & 0x7F)
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
        case let .alternateInverse(value): return (legacyAlternateCharacter(value), true)
        case let .ascii(value):
            guard value >= 0x20, value <= 0x7E else { return (" ", false) }
            return (String(UnicodeScalar(value)), false)
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

    private func legacyAlternateCharacter(_ code: UInt8) -> String {
        // On an unenhanced IIe, the alternate bank retains inverse uppercase
        // at $40-$5F and contributes inverse lowercase at $60-$7F.
        // The renderer has already reduced the screen byte to six glyph bits,
        // so both ranges are restored by adding $40: $01 -> "A" and
        // $21 -> "a". Adding $60 to the latter would address a C1 control
        // character rather than a lowercase letter.
        return String(UnicodeScalar(code + 0x40))
    }
}

private struct KeyboardCapture: NSViewRepresentable {
    let keyDown: (NSEvent) -> Void
    let mouseMoved: (NSEvent) -> Void
    let mouseButton: (Int, Bool) -> Void

    func makeNSView(context: Context) -> KeyView {
        let view = KeyView()
        view.keyDownHandler = keyDown
        view.mouseMovedHandler = mouseMoved
        view.mouseButtonHandler = mouseButton
        return view
    }
    func updateNSView(_ nsView: KeyView, context: Context) {
        nsView.keyDownHandler = keyDown
        nsView.mouseMovedHandler = mouseMoved
        nsView.mouseButtonHandler = mouseButton
    }

    final class KeyView: NSView {
        var keyDownHandler: ((NSEvent) -> Void)?
        var mouseMovedHandler: ((NSEvent) -> Void)?
        var mouseButtonHandler: ((Int, Bool) -> Void)?
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
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil))
        }
        override func keyDown(with event: NSEvent) { keyDownHandler?(event) }
        override func mouseMoved(with event: NSEvent) { mouseMovedHandler?(event) }
        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
            mouseButtonHandler?(0, true)
        }
        override func mouseUp(with event: NSEvent) { mouseButtonHandler?(0, false) }
        override func rightMouseDown(with event: NSEvent) { mouseButtonHandler?(1, true) }
        override func rightMouseUp(with event: NSEvent) { mouseButtonHandler?(1, false) }
    }
}
