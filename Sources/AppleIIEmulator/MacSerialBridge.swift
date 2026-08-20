import Darwin
import Foundation

/// Moves bytes between a user-selected macOS serial device and one of the
/// IIc's ACIA ports. All host I/O stays outside the cycle-driven hardware.
final class MacSerialBridge: @unchecked Sendable {
    private enum BridgeError: LocalizedError {
        case unsupportedBaudRate(Int)

        var errorDescription: String? {
            switch self {
            case .unsupportedBaudRate(let value): return "macOS 串口不支持标准波特率 \(value)"
            }
        }
    }

    private final class Connection {
        let descriptor: Int32
        let source: DispatchSourceRead
        var baudRate: Int

        init(descriptor: Int32, source: DispatchSourceRead, baudRate: Int) {
            self.descriptor = descriptor
            self.source = source
            self.baudRate = baudRate
        }
    }

    private let queue = DispatchQueue(label: "AppleIIEmulator.MacSerial")
    private var connections = [Int: Connection]()

    /// All callbacks occur on `queue`; callers must hop to their own serial
    /// executor before changing UI or emulator state.
    var didReceiveByte: ((UInt8, Int) -> Void)?
    var didChangeConnection: ((Int, String?) -> Void)?
    var didFail: ((Int, Error) -> Void)?
    var didListDevices: (([String]) -> Void)?

    deinit {
        connections.values.forEach {
            $0.source.cancel()
            Darwin.close($0.descriptor)
        }
    }

    func refreshDevices() {
        queue.async { [weak self] in
            let devices = (try? FileManager.default.contentsOfDirectory(atPath: "/dev"))?
                .filter { $0.hasPrefix("cu.") }
                .map { "/dev/\($0)" }
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending } ?? []
            self?.didListDevices?(devices)
        }
    }

    func connect(path: String, port: Int, baudRate: Int) {
        queue.async { [weak self] in
            guard let self else { return }
            self.disconnectLocked(port: port, notify: false)
            do {
                let descriptor = try self.open(path: path, baudRate: baudRate)
                let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: self.queue)
                source.setEventHandler { [weak self] in
                    self?.readAvailable(from: descriptor, port: port)
                }
                self.connections[port] = Connection(descriptor: descriptor, source: source, baudRate: baudRate)
                source.resume()
                self.didChangeConnection?(port, path)
            } catch {
                self.didFail?(port, error)
            }
        }
    }

    func disconnect(port: Int) {
        queue.async { [weak self] in self?.disconnectLocked(port: port, notify: true) }
    }

    func setBaudRate(_ baudRate: Int, port: Int) {
        queue.async { [weak self] in
            guard let self, let connection = self.connections[port], connection.baudRate != baudRate else { return }
            do {
                try self.configure(descriptor: connection.descriptor, baudRate: baudRate)
                connection.baudRate = baudRate
            } catch {
                self.didFail?(port, error)
            }
        }
    }

    func send(_ bytes: [UInt8], port: Int) {
        guard !bytes.isEmpty else { return }
        queue.async { [weak self] in
            guard let self, let connection = self.connections[port] else { return }
            bytes.withUnsafeBytes { rawBuffer in
                guard var cursor = rawBuffer.baseAddress else { return }
                var remaining = rawBuffer.count
                while remaining > 0 {
                    let written = Darwin.write(connection.descriptor, cursor, remaining)
                    if written > 0 {
                        remaining -= written
                        cursor = cursor.advanced(by: written)
                    } else if written < 0, errno == EINTR {
                        continue
                    } else {
                        self.connectionFailed(port: port, error: self.posixError())
                        return
                    }
                }
            }
        }
    }

    private func disconnectLocked(port: Int, notify: Bool) {
        guard let connection = connections.removeValue(forKey: port) else { return }
        connection.source.cancel()
        Darwin.close(connection.descriptor)
        if notify { didChangeConnection?(port, nil) }
    }

    /// An unplugged USB adapter commonly appears as EOF or EIO.  Drop the
    /// stale descriptor before reporting it so a later menu selection can
    /// reconnect cleanly instead of writing into a dead connection.
    private func connectionFailed(port: Int, error: Error) {
        disconnectLocked(port: port, notify: true)
        didFail?(port, error)
    }

    private func readAvailable(from descriptor: Int32, port: Int) {
        // A cancelled source may already have an event queued when a user
        // reconnects the same ACIA port. Never let that old descriptor tear
        // down the replacement connection.
        guard connections[port]?.descriptor == descriptor else { return }
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while true {
            let count = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(descriptor, rawBuffer.baseAddress, rawBuffer.count)
            }
            if count > 0 {
                for byte in buffer.prefix(Int(count)) { didReceiveByte?(byte, port) }
            } else if count == 0 {
                connectionFailed(
                    port: port,
                    error: NSError(domain: NSPOSIXErrorDomain, code: Int(ENXIO))
                )
                return
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                return
            } else {
                connectionFailed(port: port, error: posixError())
                return
            }
        }
    }

    private func open(path: String, baudRate: Int) throws -> Int32 {
        let descriptor = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard descriptor >= 0 else { throw posixError() }
        do {
            try configure(descriptor: descriptor, baudRate: baudRate)
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private func configure(descriptor: Int32, baudRate: Int) throws {
        var attributes = termios()
        guard tcgetattr(descriptor, &attributes) == 0 else { throw posixError() }
        cfmakeraw(&attributes)
        attributes.c_cflag |= tcflag_t(CLOCAL | CREAD)
        attributes.c_cflag &= ~tcflag_t(CSIZE | PARENB | CSTOPB)
        attributes.c_cflag |= tcflag_t(CS8)
        withUnsafeMutableBytes(of: &attributes.c_cc) { values in
            values[Int(VMIN)] = 1
            values[Int(VTIME)] = 0
        }
        guard let speed = serialSpeed(for: baudRate) else {
            throw BridgeError.unsupportedBaudRate(baudRate)
        }
        guard cfsetspeed(&attributes, speed) == 0, tcsetattr(descriptor, TCSANOW, &attributes) == 0 else {
            throw posixError()
        }
    }

    private func serialSpeed(for baudRate: Int) -> speed_t? {
        switch baudRate {
        case 50: return speed_t(B50)
        case 75: return speed_t(B75)
        case 110: return speed_t(B110)
        case 134: return speed_t(B134)
        case 150: return speed_t(B150)
        case 300: return speed_t(B300)
        case 600: return speed_t(B600)
        case 1_200: return speed_t(B1200)
        case 1_800: return speed_t(B1800)
        case 2_400: return speed_t(B2400)
        // BSD termios has no B3600 constant. Do not silently choose a
        // different rate: an incorrect host bit clock corrupts real serial
        // traffic more severely than an explicit connection error.
        case 3_600: return nil
        case 4_800: return speed_t(B4800)
        case 7_200: return speed_t(B7200)
        case 19_200: return speed_t(B19200)
        case 9_600: return speed_t(B9600)
        default: return nil
        }
    }

    private func posixError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}
