import AVFoundation
import Foundation

/// Apple II's speaker is a flip-flop, not a host-side click generator.  The
/// emulation thread converts its cycle-timestamped edges into a small PCM
/// FIFO; the real-time callback only dequeues already-prepared samples. This
/// mirrors the waveform-buffer architecture used by mature Apple II emulators
/// and prevents UI scheduling jitter from modulating the audible pitch.
final class AppleIISpeaker {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private let sampleRate = 44_100.0
    private let appleIICyclesPerSecond = 1_021_800.0
    private let cyclesPerSample = 1_021_800.0 / 44_100.0
    private let amplitude: Float = 0.24
    private let queueCapacity = 32_768
    private let warmupSamples = 2_048
    private var source: AVAudioSourceNode?

    // These are only used by the emulation (main) thread.
    private var edgeCycles = [Int]()
    private var nextEdge = 0
    private var renderedLevel: Float = -1
    private var renderCycle: Double?
    private var lastEdgeCycle: Int?

    // These are shared solely by producer and audio callback.
    private var samples = [Float](repeating: 0, count: 32_768)
    private var readIndex = 0
    private var writeIndex = 0
    private var sampleCount = 0
    private var isPrimed = false
    // Audio-thread-only state. A small Apple II speaker and its C12
    // capacitor do not reproduce the ultrasonic PWM carrier as a harsh host
    // square wave; this clean-output reconstruction filter rolls off around
    // 2.5 kHz, close to the useful bandwidth of the small internal speaker.
    private var filteredOutput: Float = 0

    init() {
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
        lock.lock()
        for sample in produced {
            // Keeping a modest latency is preferable to blocking emulation;
            // if the host stalls for more than 0.7 s, discard oldest audio.
            if sampleCount == queueCapacity {
                readIndex = (readIndex + 1) % queueCapacity
                sampleCount -= 1
            }
            samples[writeIndex] = sample
            writeIndex = (writeIndex + 1) % queueCapacity
            sampleCount += 1
        }
        lock.unlock()
    }

    private func dequeue(frameCount: Int, into audioBufferList: UnsafeMutablePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
        guard let first = buffers.first, let rawData = first.mData else { return }
        let output = rawData.assumingMemoryBound(to: Float.self)

        lock.lock()
        if !isPrimed, sampleCount >= warmupSamples { isPrimed = true }
        for index in 0..<frameCount {
            let target: Float
            if isPrimed, sampleCount > 0 {
                target = samples[readIndex]
                readIndex = (readIndex + 1) % queueCapacity
                sampleCount -= 1
            } else {
                target = 0
                isPrimed = false
            }
            // alpha = 1 - exp(-2π × 2500 / 44100)
            filteredOutput += 0.300 * (target - filteredOutput)
            output[index] = abs(filteredOutput) < 0.012 ? 0 : filteredOutput
        }
        lock.unlock()

        for buffer in buffers.dropFirst() {
            guard let rawData = buffer.mData else { continue }
            rawData.assumingMemoryBound(to: Float.self).initialize(from: output, count: frameCount)
        }
    }

    deinit { engine.stop() }
}
