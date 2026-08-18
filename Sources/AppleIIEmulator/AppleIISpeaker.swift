import AVFoundation
import AppleIIRealtime
import Foundation

/// Apple II's speaker is a flip-flop, not a host-side click generator.  The
/// emulation thread converts its cycle-timestamped edges into a small PCM
/// FIFO; the real-time callback only dequeues already-prepared samples. This
/// mirrors the waveform-buffer architecture used by mature Apple II emulators
/// and prevents UI scheduling jitter from modulating the audible pitch.
final class AppleIISpeaker {
    private let engine = AVAudioEngine()
    private let sampleRate = 44_100.0
    private let appleIICyclesPerSecond = 1_021_800.0
    private let cyclesPerSample = 1_021_800.0 / 44_100.0
    private let amplitude: Float = 0.24
    private let queueCapacity = 32_768
    private let warmupSamples = 2_048
    private var source: AVAudioSourceNode?
    private let fifo: OpaquePointer

    // These are only used by the emulation (main) thread.
    private var edgeCycles = [Int]()
    private var nextEdge = 0
    private var renderedLevel: Float = -1
    private var renderCycle: Double?
    private var lastEdgeCycle: Int?

    // Single-producer (emulation) / single-consumer (Core Audio) storage is
    // implemented with C11 atomics. The realtime callback never takes a lock
    // or allocates, so an emulator slice cannot cause an audible callback
    // priority inversion.
    private var isPrimed = false
    // Audio-thread-only state. A small Apple II speaker and its C12
    // capacitor do not reproduce the ultrasonic PWM carrier as a harsh host
    // square wave; this clean-output reconstruction filter rolls off around
    // 2.5 kHz, close to the useful bandwidth of the small internal speaker.
    private var filteredOutput: Float = 0

    init() {
        guard let fifo = appleii_audio_fifo_create(queueCapacity) else {
            fatalError("Unable to allocate Apple II audio FIFO")
        }
        self.fifo = fifo
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let node = AVAudioSourceNode { [weak self] _, _, frameCount, audioBufferList in
            self?.dequeue(frameCount: Int(frameCount), into: audioBufferList)
            return 0
        }
        source = node
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        try? engine.start()
    }

    func toggle(atEmulatedCycle cycle: Int) {
        edgeCycles.append(cycle)
        lastEdgeCycle = cycle
    }

    /// Convert all fully elapsed Apple II cycles to PCM after each CPU slice.
    /// The output callback never inspects emulator state or waits for a lock
    /// per speaker edge.
    func advance(toEmulatedCycle cycle: Int) {
        guard cycle > 0 else { return }
        if renderCycle == nil {
            guard let first = edgeCycles.first else { return }
            renderCycle = Double(first)
        }
        guard var start = renderCycle else { return }
        let target = Double(cycle)
        var produced = [Float]()
        produced.reserveCapacity(max(0, Int((target - start) / cyclesPerSample)))

        while start + cyclesPerSample <= target {
            let end = start + cyclesPerSample
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

            // The real speaker is AC-coupled: after an isolated click its
            // coil settles instead of holding a host DAC at a DC level.
            let quietForTooLong = lastEdgeCycle.map { end - Double($0) > appleIICyclesPerSecond / 5 } ?? true
            produced.append(quietForTooLong ? 0 : Float(area / cyclesPerSample) * amplitude)
            start = end
        }
        renderCycle = start
        if nextEdge > 2_048 {
            edgeCycles.removeFirst(nextEdge)
            nextEdge = 0
        }
        enqueue(produced)
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
        guard let first = buffers.first, let rawData = first.mData else { return }
        let output = rawData.assumingMemoryBound(to: Float.self)

        if !isPrimed, appleii_audio_fifo_available(fifo) >= warmupSamples { isPrimed = true }
        for index in 0..<frameCount {
            let target: Float
            var sample: Float = 0
            if isPrimed, appleii_audio_fifo_read(fifo, &sample, 1) == 1 {
                target = sample
            } else {
                target = 0
                isPrimed = false
            }
            // alpha = 1 - exp(-2π × 2500 / 44100)
            filteredOutput += 0.300 * (target - filteredOutput)
            output[index] = abs(filteredOutput) < 0.012 ? 0 : filteredOutput
        }

        for buffer in buffers.dropFirst() {
            guard let rawData = buffer.mData else { continue }
            rawData.assumingMemoryBound(to: Float.self).initialize(from: output, count: frameCount)
        }
    }

    deinit {
        engine.stop()
        appleii_audio_fifo_destroy(fifo)
    }
}
