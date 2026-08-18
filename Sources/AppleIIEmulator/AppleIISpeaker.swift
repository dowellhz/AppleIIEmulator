import AVFoundation
import AppleIIRealtime
import Foundation

/// Cycle-timestamped Apple II speaker edges converted to PCM on the
/// emulation thread.  Keeping this separate from the Core Audio endpoint
/// makes the hardware timing deterministic and directly regression-testable.
struct AppleIISpeakerWaveform {
    private static let sampleRate = 44_100.0
    private static let appleIICyclesPerSecond = 1_021_800.0
    private static let cyclesPerSample = appleIICyclesPerSecond / sampleRate
    private static let amplitude: Float = 0.24

    private var edgeCycles = [Int]()
    private var nextEdge = 0
    private var renderedLevel: Float = -1
    private var renderCycle: Double?
    // Capacitor voltage in the AC-coupled speaker path.  It must be part of
    // the emulation-side renderer, never the real-time audio callback.
    private var dcEstimate: Float = 0

    mutating func toggle(atEmulatedCycle cycle: Int) {
        edgeCycles.append(cycle)
    }

    /// Convert every whole output sample ending at or before `cycle`.
    mutating func render(toEmulatedCycle cycle: Int) -> [Float] {
        guard cycle > 0 else { return [] }
        if renderCycle == nil {
            guard let first = edgeCycles.first else { return [] }
            renderCycle = Double(first)
        }
        guard var start = renderCycle else { return [] }
        let target = Double(cycle)
        var produced = [Float]()
        produced.reserveCapacity(max(0, Int((target - start) / Self.cyclesPerSample)))

        while start + Self.cyclesPerSample <= target {
            let end = start + Self.cyclesPerSample
            while nextEdge < edgeCycles.count, Double(edgeCycles[nextEdge]) <= start {
                renderedLevel = -renderedLevel
                nextEdge += 1
            }

            var cursor = start
            var area = 0.0
            var level = renderedLevel
            while nextEdge < edgeCycles.count, Double(edgeCycles[nextEdge]) < end {
                let edge = Double(edgeCycles[nextEdge])
                area += Double(level) * (edge - cursor)
                level = -level
                cursor = edge
                nextEdge += 1
            }
            area += Double(level) * (end - cursor)
            renderedLevel = level

            // The real speaker path is AC-coupled.  A 12 Hz one-pole DC
            // blocker gives an isolated C030 edge a natural decay without
            // inserting the abrupt 200 ms cut-off that caused audible ticks.
            let rawSample = Float(area / Self.cyclesPerSample) * Self.amplitude
            // alpha = 1 - exp(-2π × 12 / 44100)
            dcEstimate += 0.001_708 * (rawSample - dcEstimate)
            produced.append(rawSample - dcEstimate)
            start = end
        }
        renderCycle = start
        if nextEdge > 2_048 {
            edgeCycles.removeFirst(nextEdge)
            nextEdge = 0
        }
        return produced
    }
}

/// Apple II's speaker is a flip-flop, not a host-side click generator.  The
/// emulation thread converts its cycle-timestamped edges into a bounded PCM
/// FIFO; the real-time callback only dequeues prepared samples.
final class AppleIISpeaker {
    private let engine = AVAudioEngine()
    private let sampleRate = 44_100.0
    private let queueCapacity = 32_768
    // Keep roughly 93 ms of emulated audio ahead of Core Audio.  A display
    // refresh or disk-image operation can delay the main actor by more than a
    // 60 Hz tick; the old 46 ms buffer then underflowed and crackled.
    private let warmupSamples = 4_096
    private let recoveryRampSamples = 256
    private var source: AVAudioSourceNode?
    private let fifo: OpaquePointer
    private var waveform = AppleIISpeakerWaveform()

    // Single-producer (emulation) / single-consumer (Core Audio) storage is
    // implemented with C11 atomics. The realtime callback never takes a lock
    // or allocates, so an emulator slice cannot cause an audible callback
    // priority inversion.
    private var isPrimed = false
    // Audio-thread-only state. A small Apple II speaker and its C12 capacitor
    // do not reproduce the ultrasonic PWM carrier as a harsh host square
    // wave; this reconstruction filter rolls off around 2.5 kHz.
    private var filteredOutput: Float = 0
    private var recoveryRampRemaining = 0

    init() {
        guard let fifo = appleii_audio_fifo_create(queueCapacity) else {
            fatalError("Unable to allocate Apple II audio FIFO")
        }
        self.fifo = fifo
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let node = AVAudioSourceNode { [weak self] _, _, frameCount, audioBufferList in
            guard let self else {
                Self.fillWithSilence(frameCount: Int(frameCount), audioBufferList: audioBufferList)
                return 0
            }
            self.dequeue(frameCount: Int(frameCount), into: audioBufferList)
            return 0
        }
        source = node
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        try? engine.start()
    }

    func toggle(atEmulatedCycle cycle: Int) {
        waveform.toggle(atEmulatedCycle: cycle)
    }

    /// Convert all fully elapsed Apple II cycles to PCM after each CPU slice.
    func advance(toEmulatedCycle cycle: Int) {
        enqueue(waveform.render(toEmulatedCycle: cycle))
    }

    private func enqueue(_ produced: [Float]) {
        guard !produced.isEmpty else { return }
        produced.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            // A full FIFO means the host is already behind. Drop the newest
            // generated tail rather than ever blocking the emulation thread.
            _ = appleii_audio_fifo_write(fifo, base, buffer.count)
        }
    }

    private func dequeue(frameCount: Int, into audioBufferList: UnsafeMutablePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
        guard let first = buffers.first, let rawData = first.mData else {
            Self.fillWithSilence(frameCount: frameCount, audioBufferList: audioBufferList)
            return
        }
        let output = rawData.assumingMemoryBound(to: Float.self)

        if !isPrimed, appleii_audio_fifo_available(fifo) >= warmupSamples {
            isPrimed = true
            recoveryRampRemaining = recoveryRampSamples
        }
        let received = isPrimed ? appleii_audio_fifo_read(fifo, output, frameCount) : 0
        if received < frameCount {
            output.advanced(by: received).initialize(repeating: 0, count: frameCount - received)
            isPrimed = false
        }

        for index in 0..<frameCount {
            // alpha = 1 - exp(-2π × 2500 / 44100)
            filteredOutput += 0.300 * (output[index] - filteredOutput)
            if recoveryRampRemaining > 0 {
                let progress = Float(recoveryRampSamples - recoveryRampRemaining + 1) / Float(recoveryRampSamples)
                output[index] = filteredOutput * progress
                recoveryRampRemaining -= 1
            } else {
                output[index] = filteredOutput
            }
        }

        for buffer in buffers.dropFirst() {
            guard let rawData = buffer.mData else { continue }
            rawData.assumingMemoryBound(to: Float.self).initialize(from: output, count: frameCount)
        }
    }

    private static func fillWithSilence(frameCount: Int, audioBufferList: UnsafeMutablePointer<AudioBufferList>) {
        for buffer in UnsafeMutableAudioBufferListPointer(audioBufferList) {
            guard let rawData = buffer.mData else { continue }
            rawData.assumingMemoryBound(to: Float.self).initialize(repeating: 0, count: frameCount)
        }
    }

    deinit {
        engine.stop()
        appleii_audio_fifo_destroy(fifo)
    }
}
