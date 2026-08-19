import AppKit
import SwiftUI

struct EmulatorView: View {
    @ObservedObject var machine: AppleIIMachine
    @State private var isFullscreen = false

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
    }

    private var chassis: some View {
        GeometryReader { proxy in
            let chassisWidth = min(proxy.size.width, ChassisLayout.preferredWidth)

            VStack(spacing: 0) {
                monitor(width: chassisWidth)
                EmulatorControlsPanel(machine: machine)
                    .frame(width: chassisWidth)
                    .padding(.top, 12)
                    .padding(.bottom, 18)
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

    private func monitor(width chassisWidth: CGFloat) -> some View {
        let monitorHeight = ChassisLayout.monitorHeight(for: chassisWidth)
        let screenWidth = chassisWidth * 0.62
        let screenHeight = screenWidth * 0.75
        let screenCenter = CGPoint(
            x: chassisWidth * 0.473,
            y: monitorHeight * 0.50
        )

        return ZStack {
            MonitorArtwork()
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
    static let panelHeight: CGFloat = 118
    static let verticalSpacing: CGFloat = 30

    static func monitorHeight(for width: CGFloat) -> CGFloat {
        width / (1448.0 / 1084.0)
    }

    static let minimumHeight = monitorHeight(for: minimumWidth) + panelHeight + verticalSpacing
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
    var body: some View {
        if let url = AppResources.bundle.url(forResource: "AppleIIMonitorReference", withExtension: "png"),
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
                    : appleIITextCell(byte: byte, alternateCharset: video.alternateCharset, flashOn: flashOn, supportsMouseText: video.supportsMouseText)
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
