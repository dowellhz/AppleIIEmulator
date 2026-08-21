import Foundation

/// Cycle-clocked cassette input. File decoders turn sampled media into pulse
/// durations before mounting it here; the memory bus then sees only the
/// cassette comparator's level at `$C060`.
struct AppleIICassetteInput {
    struct State {
        fileprivate let cassette: AppleIICassetteInput
        fileprivate init(cassette: AppleIICassetteInput) { self.cassette = cassette }
    }
    private var pulseDurations = [Int]()
    private var pulseIndex = 0
    private var cyclesUntilEdge = 0
    private(set) var level = false

    var isMounted: Bool { !pulseDurations.isEmpty }

    func snapshot() -> State { State(cassette: self) }
    mutating func restore(_ snapshot: State) { self = snapshot.cassette }

    mutating func mount(pulseDurations: [Int], initialLevel: Bool = false) {
        self.pulseDurations = pulseDurations.filter { $0 > 0 }
        pulseIndex = 0
        level = initialLevel
        cyclesUntilEdge = self.pulseDurations.first ?? 0
    }

    mutating func eject() {
        pulseDurations.removeAll(keepingCapacity: true)
        pulseIndex = 0
        cyclesUntilEdge = 0
        level = false
    }

    mutating func advance(by cycles: Int) {
        guard cycles > 0, !pulseDurations.isEmpty else { return }
        var remaining = cycles
        while remaining >= cyclesUntilEdge {
            remaining -= cyclesUntilEdge
            level.toggle()
            pulseIndex = (pulseIndex + 1) % pulseDurations.count
            cyclesUntilEdge = pulseDurations[pulseIndex]
        }
        cyclesUntilEdge -= remaining
    }
}

enum AppleIICassetteCodec {
    private static let cyclesPerSecond = 1_021_800.0

    static func decodeWAV(_ data: Data) throws -> [Int] {
        let bytes = Array(data)
        guard bytes.count >= 12,
              Array(bytes[0..<4]) == Array("RIFF".utf8),
              Array(bytes[8..<12]) == Array("WAVE".utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        func little16(_ offset: Int) -> Int { Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 }
        func little32(_ offset: Int) -> Int {
            Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 | Int(bytes[offset + 2]) << 16 | Int(bytes[offset + 3]) << 24
        }
        var format: (channels: Int, sampleRate: Int, bits: Int)?
        var samples: Range<Int>?
        var offset = 12
        while offset + 8 <= bytes.count {
            let length = little32(offset + 4)
            let start = offset + 8
            guard length <= bytes.count - start else { throw CocoaError(.fileReadCorruptFile) }
            let identifier = Array(bytes[offset..<(offset + 4)])
            if identifier == Array("fmt ".utf8), length >= 16 {
                guard little16(start) == 1 else { throw CocoaError(.fileReadUnsupportedScheme) }
                format = (little16(start + 2), little32(start + 4), little16(start + 14))
            } else if identifier == Array("data".utf8) {
                samples = start..<(start + length)
            }
            offset = start + length + length % 2
        }
        guard let format, let samples,
              format.channels > 0, format.sampleRate > 0,
              format.bits == 8 || format.bits == 16 else { throw CocoaError(.fileReadCorruptFile) }
        let bytesPerSample = format.bits / 8
        let frameSize = bytesPerSample * format.channels
        guard samples.count.isMultiple(of: frameSize) else { throw CocoaError(.fileReadCorruptFile) }
        var crossings = [Int]()
        var previous = 0
        var havePrevious = false
        let frames = samples.count / frameSize
        for frame in 0..<frames {
            let base = samples.lowerBound + frame * frameSize
            let sample = format.bits == 8 ? Int(bytes[base]) - 128 : Int(Int16(bitPattern: UInt16(little16(base))))
            if havePrevious, (sample >= 0) != (previous >= 0) { crossings.append(frame) }
            previous = sample; havePrevious = true
        }
        guard crossings.count >= 2 else { throw CocoaError(.fileReadCorruptFile) }
        return zip(crossings.dropFirst(), crossings).map { later, earlier in
            max(1, Int((Double(later - earlier) * cyclesPerSecond / Double(format.sampleRate)).rounded()))
        }
    }

    static func encodeWAV(pulseDurations: [Int], sampleRate: Int = 44_100) -> Data {
        let pulses = pulseDurations.filter { $0 > 0 }
        var samples = [UInt8]()
        var totalCycles = 0
        var emittedSamples = 0
        var high = false
        for pulse in pulses {
            totalCycles += pulse
            let targetSamples = Int((Double(totalCycles) * Double(sampleRate) / cyclesPerSecond).rounded())
            samples.append(contentsOf: repeatElement(high ? 0xFF : 0x00, count: max(0, targetSamples - emittedSamples)))
            emittedSamples = targetSamples
            high.toggle()
        }
        func little32(_ value: Int) -> [UInt8] { (0..<4).map { UInt8((value >> ($0 * 8)) & 0xFF) } }
        var bytes = Array("RIFF".utf8) + little32(36 + samples.count) + Array("WAVEfmt ".utf8)
        bytes += little32(16) + [1, 0, 1, 0] + little32(sampleRate) + little32(sampleRate) + [1, 0, 8, 0]
        bytes += Array("data".utf8) + little32(samples.count) + samples
        return Data(bytes)
    }
}
