import Foundation

/// Opt-in diagnostic state for the headless compatibility probes.  It exposes
/// observation only; normal emulation neither logs nor branches on it.
struct DiskIIDebugSnapshot {
    let motorOn: Bool
    let selectedDrive: Int
    let q6: Bool
    let q7: Bool
    let tracks: [Int]
    let readBits: [Int]
}

/// Slot 6 / IIc integrated IWM drive. It accepts 140 KB DOS-order
/// `.dsk/.do`, ProDOS-order `.po`, pre-nibblized 35-track `.nib`, common 2IMG
/// (`.2mg/.2img`) wrappers, and WOZ 1.x/2.x bitstreams, exposing the
/// same GCR byte stream that the original controller delivers to firmware.
/// IWM/P6 soft-switch state machine. Media container decoding is delegated to
/// `DiskImageCodec`; callers may keep using the historical `DiskII` alias.
final class IWMController {
    struct State {
        fileprivate let drives: [DiskDrive]
        fileprivate let q6: Bool
        fileprivate let q7: Bool
        fileprivate let motorOn: Bool
        fileprivate let motorOffDelay: Int
        fileprivate let selectedDrive: Int
        fileprivate let dataLatch: UInt8
        fileprivate let busData: UInt8
        fileprivate let sequencerState: UInt8
        fileprivate let sequencerPhase: UInt8
        fileprivate let writeLevel: UInt8
        fileprivate let nibbleReads: Int
        fileprivate let nibbleWrites: Int
        fileprivate let weakBitsGenerated: Int
        fileprivate let fluxBitReads: Int
        fileprivate let readBitsByDrive: [Int]
    }
    static let imageSize = 35 * 16 * 256
    static let thirteenSectorImageSize = 35 * 13 * 256
    static let nibImageSize = 35 * 6_656
    private static let gcr: [UInt8] = [
        0x96,0x97,0x9A,0x9B,0x9D,0x9E,0x9F,0xA6,0xA7,0xAB,0xAC,0xAD,0xAE,0xAF,0xB2,0xB3,
        0xB4,0xB5,0xB6,0xB7,0xB9,0xBA,0xBB,0xBC,0xBD,0xBE,0xBF,0xCB,0xCD,0xCE,0xCF,0xD3,
        0xD6,0xD7,0xD9,0xDA,0xDB,0xDC,0xDD,0xDE,0xDF,0xE5,0xE6,0xE7,0xE9,0xEA,0xEB,0xEC,
        0xED,0xEE,0xEF,0xF2,0xF3,0xF4,0xF5,0xF6,0xF7,0xF9,0xFA,0xFB,0xFC,0xFD,0xFE,0xFF
    ]
    private static let dosSectorOrder = [0, 7, 14, 6, 13, 5, 12, 4, 11, 3, 10, 2, 9, 1, 8, 15]
    private static let prodosSectorOrder = [0, 2, 4, 6, 8, 10, 12, 14, 1, 3, 5, 7, 9, 11, 13, 15]
    // DOS 3.2's physical on-track ordering.  Unlike 16-sector DOS 3.3,
    // these sector IDs are also the logical image offsets for a .d13 dump.
    private static let thirteenSectorOrder = [0, 10, 7, 4, 1, 11, 8, 5, 2, 12, 9, 6, 3]
    private static let gcr53: [UInt8] = [
        0xAB,0xAD,0xAE,0xAF,0xB5,0xB6,0xB7,0xBA,0xBB,0xBD,0xBE,0xBF,0xD6,0xD7,0xDA,0xDB,
        0xDD,0xDE,0xDF,0xEA,0xEB,0xED,0xEE,0xEF,0xF5,0xF6,0xF7,0xFA,0xFB,0xFD,0xFE,0xFF
    ]

    // P6A (341-0028) logic-state sequencer, expressed in BAPD logical
    // order.  P6 is hardware, not firmware: it advances independently of
    // CPU I/O accesses and selects its next state from Q6/Q7, the data
    // register's high bit, and the incoming flux pulse.
    private static let p6: [UInt8] = [
        0x18,0x18,0x18,0x18,0x0A,0x0A,0x0A,0x0A,0x18,0x18,0x18,0x18,0x18,0x18,0x18,0x18,
        0x2D,0x2D,0x38,0x38,0x0A,0x0A,0x0A,0x0A,0x28,0x28,0x28,0x28,0x28,0x28,0x28,0x28,
        0xD8,0x38,0x08,0x28,0x0A,0x0A,0x0A,0x0A,0x39,0x39,0x39,0x39,0x3B,0x3B,0x3B,0x3B,
        0xD8,0x48,0x48,0x48,0x0A,0x0A,0x0A,0x0A,0x48,0x48,0x48,0x48,0x48,0x48,0x48,0x48,
        0xD8,0x58,0xD8,0x58,0x0A,0x0A,0x0A,0x0A,0x58,0x58,0x58,0x58,0x58,0x58,0x58,0x58,
        0xD8,0x68,0xD8,0x68,0x0A,0x0A,0x0A,0x0A,0x68,0x68,0x68,0x68,0x68,0x68,0x68,0x68,
        0xD8,0x78,0xD8,0x78,0x0A,0x0A,0x0A,0x0A,0x78,0x78,0x78,0x78,0x78,0x78,0x78,0x78,
        0xD8,0x88,0xD8,0x88,0x0A,0x0A,0x0A,0x0A,0x08,0x08,0x88,0x88,0x08,0x08,0x88,0x88,
        0xD8,0x98,0xD8,0x98,0x0A,0x0A,0x0A,0x0A,0x98,0x98,0x98,0x98,0x98,0x98,0x98,0x98,
        0xD8,0x29,0xD8,0xA8,0x0A,0x0A,0x0A,0x0A,0xA8,0xA8,0xA8,0xA8,0xA8,0xA8,0xA8,0xA8,
        0xCD,0xBD,0xD8,0xB8,0x0A,0x0A,0x0A,0x0A,0xB9,0xB9,0xB9,0xB9,0xBB,0xBB,0xBB,0xBB,
        0xD9,0x59,0xD8,0xC8,0x0A,0x0A,0x0A,0x0A,0xC8,0xC8,0xC8,0xC8,0xC8,0xC8,0xC8,0xC8,
        0xD9,0xD9,0xD8,0xA0,0x0A,0x0A,0x0A,0x0A,0xD8,0xD8,0xD8,0xD8,0xD8,0xD8,0xD8,0xD8,
        0xD8,0x08,0xE8,0xE8,0x0A,0x0A,0x0A,0x0A,0xE8,0xE8,0xE8,0xE8,0xE8,0xE8,0xE8,0xE8,
        0xFD,0xFD,0xF8,0xF8,0x0A,0x0A,0x0A,0x0A,0xF8,0xF8,0xF8,0xF8,0xF8,0xF8,0xF8,0xF8,
        0xDD,0x4D,0xE0,0xE0,0x0A,0x0A,0x0A,0x0A,0x88,0x88,0x08,0x08,0x88,0x88,0x08,0x08
    ]

    // The 13-sector controller has its own P6 (341-0010), not merely a
    // different P5 boot ROM. Its archival dump is a P5-socket linear read,
    // so normalize its crossed address/data pins before converting it to the
    // logical order used by `clockSequencer`.
    private static let thirteenSectorP6: [UInt8] = {
        guard let url = AppResources.bundle.url(forResource: "DiskII-13sector-341-0010", withExtension: "bin"),
              let raw = try? Data(contentsOf: url), raw.count == 256 else {
            return p6
        }
        return decodeP6PROM(normalizeThirteenSectorP6Dump(Array(raw)))
    }()

    private var drives = [DiskDrive(), DiskDrive()]
    private var q6 = false
    private var q7 = false
    private var motorOn = false
    private var motorOffDelay = 0
    private var selectedDrive = 0
    private var dataLatch: UInt8 = 0
    private var busData: UInt8 = 0
    private var sequencerState: UInt8 = 0
    private var sequencerPhase: UInt8 = 0
    private var writeLevel: UInt8 = 0
    private(set) var nibbleReads = 0
    private(set) var nibbleWrites = 0
    private(set) var weakBitsGenerated = 0
    private(set) var fluxBitReads = 0
    private var readBitsByDrive = [0, 0]

    var hasDisk: Bool { drives.contains { $0.hasDisk } }
    func hasDisk(in drive: Int) -> Bool { drives.indices.contains(drive) && drives[drive].hasDisk }
    /// Test-only observation of the drive-local MC3470 recovery state.
    var readAmplifierGainByDrive: [UInt8] { drives.map(\.readAmplifierGain) }

    func snapshot() -> State {
        State(
            drives: drives, q6: q6, q7: q7, motorOn: motorOn, motorOffDelay: motorOffDelay,
            selectedDrive: selectedDrive, dataLatch: dataLatch, busData: busData,
            sequencerState: sequencerState, sequencerPhase: sequencerPhase, writeLevel: writeLevel,
            nibbleReads: nibbleReads, nibbleWrites: nibbleWrites,
            weakBitsGenerated: weakBitsGenerated, fluxBitReads: fluxBitReads, readBitsByDrive: readBitsByDrive
        )
    }

    func restore(_ state: State) {
        drives = state.drives; q6 = state.q6; q7 = state.q7; motorOn = state.motorOn
        motorOffDelay = state.motorOffDelay; selectedDrive = state.selectedDrive
        dataLatch = state.dataLatch; busData = state.busData; sequencerState = state.sequencerState
        sequencerPhase = state.sequencerPhase; writeLevel = state.writeLevel
        nibbleReads = state.nibbleReads; nibbleWrites = state.nibbleWrites
        weakBitsGenerated = state.weakBitsGenerated; fluxBitReads = state.fluxBitReads
        readBitsByDrive = state.readBitsByDrive
    }

    func reset() {
        for index in drives.indices {
            drives[index].phaseStates = 0
            drives[index].quarterTrack = 0
            drives[index].bitPosition = 0
        }
        q6 = false; q7 = false
        motorOn = false; motorOffDelay = 0; selectedDrive = 0; dataLatch = 0; busData = 0; sequencerState = 0; writeLevel = 0; nibbleReads = 0; nibbleWrites = 0; weakBitsGenerated = 0; fluxBitReads = 0; readBitsByDrive = [0, 0]
    }

    func eject(drive: Int = 0) {
        guard drives.indices.contains(drive) else { return }
        drives[drive].eject()
    }

    func mountDSK(_ data: Data, drive: Int = 0, writeProtected: Bool = false) throws {
        if looksLikeThirteenSectorBootDisk(data) {
            try mountThirteenSectorImage(data, drive: drive, writeProtected: writeProtected)
            return
        }
        try mountSectorImage(data, sectorOrder: Self.dosSectorOrder, drive: drive, writeProtected: writeProtected)
    }

    private func looksLikeThirteenSectorBootDisk(_ data: Data) -> Bool {
        // A 13-sector program's stage-one loader searches for this address
        // prologue itself.  Images are seen both in compact 113.75 KB .d13
        // form and as 140 KB files with three unused sectors per track.
        guard data.count == Self.thirteenSectorImageSize || data.count == Self.imageSize else { return false }
        let boot = Array(data.prefix(256))
        return boot.indices.dropLast(2).contains { index in
            boot[index] == 0xD5 && boot[index + 1] == 0xAA && boot[index + 2] == 0xB5
        }
    }

    func mountThirteenSectorImage(_ data: Data, drive: Int, writeProtected: Bool = false) throws {
        guard drives.indices.contains(drive),
              data.count == Self.thirteenSectorImageSize || data.count == Self.imageSize else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let image = Array(data)
        // Several archival tools pad compact 13-sector images to the newer
        // 140 KB DSK length.  Their tail is empty; retaining a fictitious
        // 14th–16th sector would shift every track after track zero.
        let compactImageIsPadded = data.count == Self.imageSize && image[Self.thirteenSectorImageSize...].allSatisfy { $0 == 0 }
        let sectorsPerTrack = data.count == Self.thirteenSectorImageSize || compactImageIsPadded ? 13 : 16
        let tracks = (0..<35).map { Self.nibblizeThirteenSectorTrack($0, image: image, sectorsPerTrack: sectorsPerTrack) }
        drives[drive].install(tracks: tracks.map(\.nibbles), bitTracks: tracks.map { Self.bitTrack(nibbles: $0.nibbles, sync: $0.sync, trailingZeros: $0.syncTrailingZeros) }, thirteenSector: true, writeProtected: writeProtected)
    }

    func mountProDOS(_ data: Data, drive: Int, writeProtected: Bool) throws {
        try mountSectorImage(data, sectorOrder: Self.prodosSectorOrder, drive: drive, writeProtected: writeProtected)
    }

    private func mountSectorImage(_ data: Data, sectorOrder: [Int], drive: Int, writeProtected: Bool) throws {
        let bytesPerTrack = 16 * 256
        let trackCount = data.count / bytesPerTrack
        // Most images are the standard 35 tracks, but archive images for
        // 5.25-inch 37/40-track mechanisms also occur.  Retain every sector
        // instead of rejecting software solely because it uses the outer
        // tracks of such a drive.
        guard drives.indices.contains(drive), data.count.isMultiple(of: bytesPerTrack),
              (35...40).contains(trackCount) else { throw CocoaError(.fileReadCorruptFile) }
        let image = Array(data)
        let tracks = (0..<trackCount).map { Self.nibblizeTrack($0, image: image, sectorOrder: sectorOrder) }
        drives[drive].install(tracks: tracks.map(\.nibbles), bitTracks: tracks.map { Self.bitTrack(nibbles: $0.nibbles, sync: $0.sync, trailingZeros: $0.syncTrailingZeros) }, thirteenSector: false, writeProtected: writeProtected)
    }

    func mountImage(_ data: Data, fileExtension: String, drive: Int = 0) throws {
        guard let format = DiskImageFormat(fileExtension: fileExtension) else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        try mount(DiskImageCodec.decode(data, format: format), drive: drive)
    }

    private func mount(_ payload: DiskImagePayload, drive: Int) throws {
        switch payload {
        case let .dos(data, writeProtected): try mountDSK(data, drive: drive, writeProtected: writeProtected)
        case let .thirteenSector(data, writeProtected): try mountThirteenSectorImage(data, drive: drive, writeProtected: writeProtected)
        case let .prodos(data, writeProtected): try mountProDOS(data, drive: drive, writeProtected: writeProtected)
        case let .nib(data, writeProtected):
            guard drives.indices.contains(drive), data.count == Self.nibImageSize else { throw CocoaError(.fileReadCorruptFile) }
            let bytes = Array(data)
            let tracks = (0..<35).map { index in
                let start = index * 6_656
                return Array(bytes[start..<(start + 6_656)])
            }
            let bitTracks = tracks.map { stream in
                // Raw NIB does not preserve an explicit sync map. $FF is the
                // canonical self-sync fill byte, so this remains compatible
                // with conventional NIB images while DSK conversion is exact.
                Self.bitTrack(nibbles: stream, sync: stream.map { $0 == 0xFF }, trailingZeros: 2)
            }
            drives[drive].install(tracks: tracks, bitTracks: bitTracks, thirteenSector: false, writeProtected: writeProtected)
        case let .woz(
            bitTracks, quarterTrackMap, thirteenSector, fluxTracks,
            fluxQuarterTrackMap, emulatesWeakBits, writeProtected, container
        ):
            guard drives.indices.contains(drive), quarterTrackMap.count == 160 else {
                throw CocoaError(.fileReadCorruptFile)
            }
            drives[drive].install(
                tracks: [], bitTracks: bitTracks, quarterTrackMap: quarterTrackMap,
                fluxTracks: fluxTracks, fluxQuarterTrackMap: fluxQuarterTrackMap,
                wozContainer: container,
                thirteenSector: thirteenSector, writeProtected: writeProtected,
                emulatesWeakBits: emulatesWeakBits
            )
        }
    }

    /// Decodes the 64-byte 2IMG envelope used by many Apple II archives.
    /// This is deliberately limited to 140 KB 5.25-inch payloads: larger
    /// ProDOS hard-disk images require SmartPort hardware, not the IIc IWM.
    private func mountTwoIMG(_ data: Data, drive: Int) throws {
        try mount(DiskImageCodec.decode(data, format: .twoIMG), drive: drive)
    }

    /// Returns the byte visible on the IWM data/status bus after a slot-six
    /// soft-switch access. This same routine handles conventional C0E0 I/O and
    /// the IIc firmware's indexed C080+X access.
    func access(_ address: Int, write value: UInt8?) -> UInt8 {
        let select = address & 0x0F
        switch select {
        case 0...7:
            setPhase(select / 2, enabled: select % 2 == 1)
        case 8:
            if motorOn { motorOffDelay = 1_023_000 }
        case 9:
            motorOn = true
            motorOffDelay = 0
        case 10: selectedDrive = 0
        case 11: selectedDrive = 1
        case 12: q6 = false
        case 13: q6 = true
        case 14: q7 = false
        case 15: q7 = true
        default: break
        }
        if let value { busData = value; return 0 }
        // An even soft-switch address drives the sequencer's data register
        // onto the CPU bus. Q6H in read mode is the write-protect sense line.
        if select == 13, !q7 { return drives[selectedDrive].isWriteProtected ? 0x80 : 0 }
        return select.isMultiple(of: 2) ? dataLatch : 0
    }

    /// Advances the physical controller. The CPU calls this for every elapsed
    /// instruction cycle; software reads never advance media directly.
    func advance(by cycles: Int) {
        guard cycles > 0 else { return }
        if motorOffDelay > 0 {
            motorOffDelay -= cycles
            if motorOffDelay <= 0 { motorOn = false; motorOffDelay = 0 }
        }
        guard motorOn else { return }
        // The P6 LSS is clocked at twice the CPU rate, eight ticks per 4 µs
        // bit cell. Sampling flux only on phase 4 gives one disk bit / 4 CPU
        // cycles, irrespective of how frequently software touches Q6.
        for _ in 0..<(cycles * 2) { clockSequencer() }
    }

    private func setPhase(_ phase: Int, enabled: Bool) {
        let mask = UInt8(1 << phase)
        let wasEnabled = drives[selectedDrive].phaseStates & mask != 0
        if enabled { drives[selectedDrive].phaseStates |= mask }
        else { drives[selectedDrive].phaseStates &= ~mask }
        // Advance only on a phase's rising edge. Looking at all active coils
        // makes the normal 0→1→2→3 stepping sequence cancel itself once more
        // than one magnet is energized. A newly selected adjacent phase moves
        // the head by one half-track (two quarter-track units).
        guard enabled, !wasEnabled else { return }
        let currentPhase = (drives[selectedDrive].quarterTrack >> 1) & 3
        let delta = (phase - currentPhase + 4) & 3
        if delta == 1 {
            let lastTrack = max(34, drives[selectedDrive].bitTracks.count - 1)
            drives[selectedDrive].quarterTrack = min(lastTrack * 4 + 3, drives[selectedDrive].quarterTrack + 2)
        } else if delta == 3 {
            drives[selectedDrive].quarterTrack = max(0, drives[selectedDrive].quarterTrack - 2)
        }
    }

    private func clockSequencer() {
        let pulse: UInt8 = sequencerPhase == 4 && !q7 ? readBit() : 0
        let qa = (dataLatch >> 7) & 1
        let address = Int((sequencerState << 4) | (q7 ? 0x08 : 0) | (q6 ? 0x04 : 0) | (qa << 1) | (pulse == 0 ? 1 : 0))
        let p6 = drives[selectedDrive].isThirteenSector ? Self.thirteenSectorP6 : Self.p6
        let operation = p6[address]
        switch operation & 0x0F {
        case 0...7: dataLatch = 0
        case 0x9: dataLatch <<= 1
        case 0xA, 0xE: dataLatch >>= 1 // writable media presents a low WP bit
        case 0xB, 0xF: dataLatch = busData
        case 0xD: dataLatch = (dataLatch << 1) | 1
        default: break
        }
        let nextState = operation >> 4
        if sequencerPhase == 4, q7 { writeBit((nextState >> 3) ^ writeLevel); writeLevel = nextState >> 3 }
        sequencerState = nextState
        sequencerPhase = (sequencerPhase + 1) & 7
    }

    private func readBit() -> UInt8 {
        readBitsByDrive[selectedDrive] &+= 1
        guard hasDisk(in: selectedDrive) else { return 0 }
        guard let selection = selectedTrack(in: selectedDrive) else {
            // WOZ's $FF map value is physically blank media, not a stream of
            // reliable zero pulses. Its read amplifier sees the same noise as
            // a weak-bit region.
            guard !drives[selectedDrive].quarterTrackMap.isEmpty else { return 0 }
            nibbleReads &+= 1
            weakBitsGenerated &+= 1
            return drives[selectedDrive].nextWeakBit()
        }
        let rawBit: UInt8
        if selection.isFlux {
            fluxBitReads &+= 1
            guard let bit = drives[selectedDrive].nextFluxBit(track: selection.index) else { return 0 }
            rawBit = bit
        } else {
            let stream = drives[selectedDrive].bitTracks[selection.index]
            guard stream.bitCount > 0 else { return 0 }
            let position = drives[selectedDrive].bitPosition % stream.bitCount
            rawBit = (stream.bytes[position / 8] >> UInt8(7 - (position & 7))) & 1
            drives[selectedDrive].bitPosition = (position + 1) % stream.bitCount
        }
        nibbleReads &+= 1
        guard drives[selectedDrive].emulatesWeakBits else { return rawBit }
        // MC3470 read path: the analog gain rises when flux transitions have
        // been absent for a while. WOZ's four-cell weak-bit delay keeps the
        // digital comparator from treating an ordinary GCR zero as noise;
        // once it is empty, the rising gain makes fake pulses progressively
        // more likely until a real transition resets the front end.
        let headWindow = ((drives[selectedDrive].readHeadWindow << 1) | rawBit) & 0x0F
        drives[selectedDrive].readHeadWindow = headWindow
        if rawBit == 0 {
            drives[selectedDrive].readAmplifierGain = min(15, drives[selectedDrive].readAmplifierGain &+ 1)
        } else {
            drives[selectedDrive].readAmplifierGain = 0
        }
        if headWindow == 0 {
            weakBitsGenerated &+= 1
            // Gain 4 is the first eligible weak-bit cell and preserves the
            // historical 30% probability. Continued silence raises the
            // comparator sensitivity but caps it below a permanently-high
            // stream, matching the MC3470's noisy recovery rather than a
            // synthetic clock pulse.
            let probability = min(191, 77 + max(0, Int(drives[selectedDrive].readAmplifierGain) - 4) * 12)
            return drives[selectedDrive].nextWeakBit(probability: UInt8(probability))
        }
        return (headWindow >> 1) & 1
    }

    private func writeBit(_ bit: UInt8) {
        guard hasDisk(in: selectedDrive), !drives[selectedDrive].isWriteProtected else { return }
        guard let initialSelection = selectedTrack(in: selectedDrive) else { return }
        if initialSelection.isFlux {
            guard drives[selectedDrive].materializeFluxTrack(initialSelection.index) else { return }
        }
        guard let selection = selectedTrack(in: selectedDrive), !selection.isFlux else { return }
        let track = selection.index
        guard drives[selectedDrive].bitTracks.indices.contains(track) else { return }
        let count = drives[selectedDrive].bitTracks[track].bitCount
        guard count > 0 else { return }
        let position = drives[selectedDrive].bitPosition % count
        let byte = position / 8
        let shift = UInt8(7 - (position & 7))
        drives[selectedDrive].bitTracks[track].bytes[byte] &= ~(UInt8(1) << shift)
        drives[selectedDrive].bitTracks[track].bytes[byte] |= (bit & 1) << shift
        drives[selectedDrive].surfaceModified = true
        // A standard NIB stream has eight source bits per byte, while a
        // physical self-sync byte also has trailing zero cells.  Only source
        // bits can be represented in a NIB export; retain writes to those
        // cells so saving a modified disk does not silently discard data.
        let sourceBit = drives[selectedDrive].bitTracks[track].nibbleBitOffsets[position]
        if sourceBit >= 0, drives[selectedDrive].tracks.indices.contains(track) {
            let sourceOffset = Int(sourceBit)
            let sourceByte = sourceOffset / 8
            let sourceShift = UInt8(7 - (sourceOffset & 7))
            drives[selectedDrive].tracks[track][sourceByte] &= ~(UInt8(1) << sourceShift)
            drives[selectedDrive].tracks[track][sourceByte] |= (bit & 1) << sourceShift
        }
        drives[selectedDrive].bitPosition = (position + 1) % count
        nibbleWrites &+= 1
    }

    private struct SelectedTrack {
        var index: Int
        var isFlux: Bool
    }

    private func selectedTrack(in drive: Int) -> SelectedTrack? {
        guard drives.indices.contains(drive) else { return nil }
        let mechanism = drives[drive]
        if !mechanism.fluxQuarterTrackMap.isEmpty,
           mechanism.fluxQuarterTrackMap.indices.contains(mechanism.quarterTrack) {
            let mappedTrack = mechanism.fluxQuarterTrackMap[mechanism.quarterTrack]
            if mappedTrack >= 0, mechanism.fluxTracks.indices.contains(mappedTrack), mechanism.fluxTracks[mappedTrack] != nil {
                return SelectedTrack(index: mappedTrack, isFlux: true)
            }
        }
        if !mechanism.quarterTrackMap.isEmpty {
            guard mechanism.quarterTrackMap.indices.contains(mechanism.quarterTrack) else { return nil }
            let mappedTrack = mechanism.quarterTrackMap[mechanism.quarterTrack]
            return mappedTrack >= 0 && mechanism.bitTracks.indices.contains(mappedTrack)
                ? SelectedTrack(index: mappedTrack, isFlux: false)
                : nil
        }
        let track = mechanism.quarterTrack / 4
        return mechanism.bitTracks.indices.contains(track) ? SelectedTrack(index: track, isFlux: false) : nil
    }

    private static func nibblizeTrack(_ track: Int, image: [UInt8], sectorOrder: [Int]) -> EncodedDiskTrack {
        var output = [UInt8]()
        var sync = [Bool]()
        func data(_ values: [UInt8]) { output += values; sync += Array(repeating: false, count: values.count) }
        func gap(_ count: Int) { output += Array(repeating: 0xFF, count: count); sync += Array(repeating: true, count: count) }
        for physicalSector in 0..<16 {
            let logicalSector = sectorOrder[physicalSector]
            let offset = (track * 16 + logicalSector) * 256
            let sector = Array(image[offset..<(offset + 256)])
            // 16 × 416 bytes is the conventional 6,656-byte NIB track.
            // Keeping this exact length means a rewritten DSK can be saved
            // and later mounted as an interoperable nibble image.
            gap(22)
            data([0xD5, 0xAA, 0x96])
            data(encode44(0xFE) + encode44(UInt8(track)) + encode44(UInt8(physicalSector)) + encode44(0xFE ^ UInt8(track) ^ UInt8(physicalSector)))
            data([0xDE, 0xAA, 0xEB])
            gap(7)
            data([0xD5, 0xAA, 0xAD])
            data(encode62(sector))
            data([0xDE, 0xAA, 0xEB])
            gap(24)
        }
        return EncodedDiskTrack(nibbles: output, sync: sync, syncTrailingZeros: 2)
    }

    /// Nibblizes a DOS 3.1/3.2 13-sector track.  The earlier controller's
    /// stricter timing rule requires 5-and-3 rather than the 16-sector
    /// 6-and-2 packing used above.  Early games commonly ship as padded
    /// 140 KB .dsk files, so `sectorsPerTrack` is intentionally independent
    /// from the 13 sectors actually emitted to the floppy stream.
    private static func nibblizeThirteenSectorTrack(_ track: Int, image: [UInt8], sectorsPerTrack: Int) -> EncodedDiskTrack {
        var output = [UInt8]()
        var sync = [Bool]()
        func data(_ values: [UInt8]) { output += values; sync += Array(repeating: false, count: values.count) }
        func gap(_ count: Int) { output += Array(repeating: 0xFF, count: count); sync += Array(repeating: true, count: count) }
        // DOS 3.2 lays out a 50,202-bit track. Its self-sync cell is nine
        // bits (eight ones followed by zero), unlike DOS 3.3's ten-bit cell.
        // These exact gaps keep a 5-and-3 boot ROM aligned through a full
        // revolution.
        gap(40)
        for physicalSector in thirteenSectorOrder {
            let offset = (track * sectorsPerTrack + physicalSector) * 256
            let sector = Array(image[offset..<(offset + 256)])
            data([0xFF, 0xD5, 0xAA, 0xB5])
            data(encode44(0xFE) + encode44(UInt8(track)) + encode44(UInt8(physicalSector)) + encode44(0xFE ^ UInt8(track) ^ UInt8(physicalSector)))
            data([0xDE, 0xAA, 0xEB])
            gap(14)
            data([0xD5, 0xAA, 0xAD])
            data(encode53(sector))
            data([0xDE, 0xAA, 0xEB])
            gap(28)
        }
        return EncodedDiskTrack(nibbles: output, sync: sync, syncTrailingZeros: 1)
    }

    private static func bitTrack(nibbles: [UInt8], sync: [Bool], trailingZeros: Int) -> DiskBitTrack {
        precondition(nibbles.count == sync.count)
        precondition(trailingZeros >= 0)
        let bitCount = zip(nibbles, sync).reduce(0) { $0 + ($1.1 ? 8 + trailingZeros : 8) }
        var bytes = [UInt8](repeating: 0, count: (bitCount + 7) / 8)
        var nibbleBitOffsets = [Int32]()
        nibbleBitOffsets.reserveCapacity(bitCount)
        var position = 0
        for (nibbleIndex, pair) in zip(nibbles, sync).enumerated() {
            let (value, isSync) = pair
            for bitOffset in 0..<8 {
                if value & (UInt8(1) << UInt8(7 - bitOffset)) != 0 {
                    bytes[position / 8] |= UInt8(1) << UInt8(7 - (position & 7))
                }
                nibbleBitOffsets.append(Int32(nibbleIndex * 8 + bitOffset))
                position += 1
            }
            if isSync {
                nibbleBitOffsets.append(contentsOf: repeatElement(-1, count: trailingZeros))
                position += trailingZeros
            }
        }
        return DiskBitTrack(bytes: bytes, bitCount: bitCount, nibbleBitOffsets: nibbleBitOffsets)
    }

    private static func decodeP6PROM(_ raw: [UInt8]) -> [UInt8] {
        precondition(raw.count == 256)
        return (0..<256).map { logicalAddress in
            // Raw PROM pins are wired as A5,A1,A2,A3,A0,A4,A6,A7.  This
            // mapping is verified against the supplied 341-0028 dump and its
            // published BAPD table before being applied to 341-0010.
            let physicalAddress =
                ((logicalAddress & 0x01) << 4) |
                ((logicalAddress & 0x02) << 0) |
                ((logicalAddress & 0x04) << 0) |
                ((logicalAddress & 0x08) << 0) |
                ((logicalAddress & 0x10) << 1) |
                ((logicalAddress & 0x20) >> 5) |
                ((logicalAddress & 0x40) << 0) |
                ((logicalAddress & 0x80) << 0)
            return raw[physicalAddress]
        }
    }

    private static func normalizeThirteenSectorP6Dump(_ dump: [UInt8]) -> [UInt8] {
        precondition(dump.count == 256)
        func swapBits(_ value: UInt8, _ first: Int, _ second: Int) -> UInt8 {
            let a = (value >> UInt8(first)) & 1
            let b = (value >> UInt8(second)) & 1
            return value ^ ((a ^ b) << UInt8(first)) ^ ((a ^ b) << UInt8(second))
        }
        var normalized = [UInt8](repeating: 0, count: 256)
        for address in 0..<256 {
            let correctedAddress = Int(swapBits(UInt8(address), 7, 5))
            let correctedData = swapBits(swapBits(dump[address], 4, 7), 5, 6)
            normalized[correctedAddress] = correctedData
        }
        return normalized
    }

    private static func encode44(_ value: UInt8) -> [UInt8] {
        [0xAA | ((value >> 1) & 0x55), 0xAA | (value & 0x55)]
    }

    private static func encode62(_ sector: [UInt8]) -> [UInt8] {
        var work = [UInt8](repeating: 0, count: 342)
        // DOS 3.3 writes the low two bits into an 86-byte buffer in reverse
        // groups of 86.  This ordering is part of the on-disk 6-and-2
        // format, not an implementation detail: the ROM/ProDOS decoder
        // expects byte 0 of the buffer to contain source bytes 85, 171, and
        // (when present) 257.  Keeping the buffer in source order happens to
        // round-trip through our own decoder but produces sectors a real
        // Disk II reader decodes incorrectly.
        for index in 0..<256 {
            let auxiliaryIndex = 85 - (index % 86)
            let shift = UInt8((index / 86) * 2)
            work[auxiliaryIndex] |= swappedPair(sector[index]) << shift
        }
        for index in 0..<256 { work[index + 86] = sector[index] >> 2 }
        // The auxiliary bytes are stored in reverse order on disk, followed
        // by the 256 high-six-bit bytes.  GCR's running XOR operates over
        // that *on-disk* order, rather than the in-memory auxiliary buffer.
        var previous: UInt8 = 0
        var encoded = [UInt8]()
        for index in stride(from: 85, through: 0, by: -1) {
            let value = work[index]
            encoded.append(gcr[Int(previous ^ value)])
            previous = value
        }
        for index in 86..<342 {
            let value = work[index]
            encoded.append(gcr[Int(previous ^ value)])
            previous = value
        }
        encoded.append(gcr[Int(previous)])
        return encoded
    }

    /// DOS 3.2's 5-and-3 pre-nibblization.  The packing order is the one
    /// consumed by the original 13-sector stage-two loaders; changing it
    /// would make an apparently valid GCR stream fail once the boot sector
    /// starts reading game data.
    private static func encode53(_ sector: [UInt8]) -> [UInt8] {
        precondition(sector.count == 256)
        var nibbles = [UInt8](repeating: 0, count: 0x19A)
        for group in 0..<0x33 {
            let offset = group * 5
            let a = sector[offset], b = sector[offset + 1], c = sector[offset + 2]
            let d = sector[offset + 3], e = sector[offset + 4]
            nibbles[0x0CC - group] = a >> 3
            nibbles[0x0FF - group] = b >> 3
            nibbles[0x132 - group] = c >> 3
            nibbles[0x165 - group] = d >> 3
            nibbles[0x198 - group] = e >> 3
            nibbles[0x067 + group] = ((a & 0x07) << 2) | ((d & 0x04) >> 1) | ((e & 0x04) >> 2)
            nibbles[0x034 + group] = ((b & 0x07) << 2) | (d & 0x02) | ((e & 0x02) >> 1)
            nibbles[0x001 + group] = ((c & 0x07) << 2) | ((d & 0x01) << 1) | (e & 0x01)
        }
        nibbles[0x000] = sector[0xFF] & 0x07
        nibbles[0x199] = sector[0xFF] >> 3

        var previous: UInt8 = 0
        var encoded = [UInt8]()
        for index in 0..<0x19A {
            let value = nibbles[index]
            encoded.append(gcr53[Int(previous ^ value)])
            previous = value
        }
        encoded.append(gcr53[Int(previous)])
        return encoded
    }

    private static func swappedPair(_ value: UInt8) -> UInt8 { ((value & 0x01) << 1) | ((value & 0x02) >> 1) }

    /// Testable readback of the raw GCR stream.  It is also useful when
    /// diagnosing third-party images: a `.dsk` must survive this same 6-and-2
    /// transformation before the ROM can ever load it.
    func decodedSector(track: Int, physicalSector: Int, drive: Int = 0) -> [UInt8]? {
        guard drives.indices.contains(drive), drives[drive].tracks.indices.contains(track), (0..<16).contains(physicalSector) else { return nil }
        let stream = drives[drive].tracks[track]
        guard stream.count >= 3 else { return nil }
        for header in 0..<(stream.count - 2) where stream[header] == 0xD5 && stream[header + 1] == 0xAA && stream[header + 2] == 0x96 {
            guard header + 11 < stream.count else { continue }
            let decodedTrack = decode44(stream[header + 5], stream[header + 6])
            let decodedSector = decode44(stream[header + 7], stream[header + 8])
            guard decodedTrack == UInt8(track), decodedSector == UInt8(physicalSector) else { continue }
            var data = header + 11
            while data + 345 < stream.count {
                if stream[data] == 0xD5, stream[data + 1] == 0xAA, stream[data + 2] == 0xAD {
                    return decode62(Array(stream[(data + 3)..<(data + 346)]))
                }
                data += 1
            }
            return nil
        }
        return nil
    }

    func decodedThirteenSector(track: Int, physicalSector: Int, drive: Int = 0) -> [UInt8]? {
        guard drives.indices.contains(drive), drives[drive].tracks.indices.contains(track), (0..<13).contains(physicalSector) else { return nil }
        let stream = drives[drive].tracks[track]
        for header in 0..<(stream.count - 2) where stream[header] == 0xD5 && stream[header + 1] == 0xAA && stream[header + 2] == 0xB5 {
            guard header + 11 < stream.count,
                  decode44(stream[header + 5], stream[header + 6]) == UInt8(track),
                  decode44(stream[header + 7], stream[header + 8]) == UInt8(physicalSector) else { continue }
            var data = header + 11
            while data + 413 < stream.count {
                if stream[data] == 0xD5, stream[data + 1] == 0xAA, stream[data + 2] == 0xAD {
                    return decode53(Array(stream[(data + 3)..<(data + 414)]))
                }
                data += 1
            }
        }
        return nil
    }

    func nibImage(drive: Int = 0) -> Data? {
        guard drives.indices.contains(drive), drives[drive].tracks.count == 35, drives[drive].tracks.allSatisfy({ $0.count == 6_656 }) else { return nil }
        return Data(drives[drive].tracks.flatMap { $0 })
    }

    /// Exports the magnetic surface, including quarter-track aliases, as a
    /// checksummed WOZ 2 container.  The UI always performs an explicit
    /// Save As action; mounting a disk never changes its original file.
    func wozImage(drive: Int = 0) -> Data? {
        guard drives.indices.contains(drive), drives[drive].quarterTrackMap.count == 160 else { return nil }
        let fluxSurface = drives[drive].fluxSurfaceForExport()
        return try? DiskImageCodec.encodeWOZ2(
            tracks: drives[drive].bitTracks,
            quarterTrackMap: drives[drive].quarterTrackMap,
            thirteenSector: drives[drive].isThirteenSector,
            writeProtected: drives[drive].isWriteProtected,
            container: drives[drive].wozContainer,
            fluxTracks: fluxSurface.tracks,
            fluxQuarterTrackMap: fluxSurface.map,
            preserveWriteHints: !drives[drive].surfaceModified
        )
    }


    /// Current full data-track selection; retained as a small observable for
    /// hardware regression tests of the quarter-track stepper state machine.
    func currentTrack(in drive: Int = 0) -> Int {
        guard drives.indices.contains(drive) else { return 0 }
        return drives[drive].quarterTrack / 4
    }

    var debugSnapshot: DiskIIDebugSnapshot {
        DiskIIDebugSnapshot(
            motorOn: motorOn,
            selectedDrive: selectedDrive,
            q6: q6,
            q7: q7,
            tracks: drives.map { $0.quarterTrack / 4 },
            readBits: readBitsByDrive
        )
    }


    func isWriteProtected(in drive: Int = 0) -> Bool {
        drives.indices.contains(drive) && drives[drive].isWriteProtected
    }

    private func decode44(_ high: UInt8, _ low: UInt8) -> UInt8 { ((high << 1) | 1) & low }

    private func decode62(_ encoded: [UInt8]) -> [UInt8]? {
        guard encoded.count == 343 else { return nil }
        var inverse = [UInt8](repeating: 0xFF, count: 256)
        for (index, value) in Self.gcr.enumerated() { inverse[Int(value)] = UInt8(index) }
        var work = [UInt8](repeating: 0, count: 342)
        var previous: UInt8 = 0
        for index in 0..<343 {
            let value = inverse[Int(encoded[index])]
            guard value != 0xFF else { return nil }
            let decoded = previous ^ value
            if index < 86 { work[85 - index] = decoded }
            else if index < 342 { work[index] = decoded }
            else if decoded != 0 { return nil }
            previous = decoded
        }
        var sector = [UInt8](repeating: 0, count: 256)
        for index in 0..<256 {
            let auxiliaryIndex = 85 - (index % 86)
            let shift = UInt8((index / 86) * 2)
            let pair = (work[auxiliaryIndex] >> shift) & 0x03
            sector[index] = (work[index + 86] << 2) | Self.swappedPair(pair)
        }
        return sector
    }

    private func decode53(_ encoded: [UInt8]) -> [UInt8]? {
        guard encoded.count == 0x19B else { return nil }
        var inverse = [UInt8](repeating: 0xFF, count: 256)
        for (index, value) in Self.gcr53.enumerated() { inverse[Int(value)] = UInt8(index) }
        var nibbles = [UInt8](repeating: 0, count: 0x19A)
        var previous: UInt8 = 0
        for index in 0..<0x19A {
            let encodedValue = inverse[Int(encoded[index])]
            guard encodedValue != 0xFF else { return nil }
            nibbles[index] = previous ^ encodedValue
            previous = nibbles[index]
        }
        let checksum = inverse[Int(encoded[0x19A])]
        guard checksum != 0xFF, previous ^ checksum == 0 else { return nil }

        var sector = [UInt8](repeating: 0, count: 256)
        for group in 0..<0x33 {
            let lowA = nibbles[0x067 + group]
            let lowB = nibbles[0x034 + group]
            let lowC = nibbles[0x001 + group]
            let offset = group * 5
            sector[offset] = (nibbles[0x0CC - group] << 3) | ((lowA >> 2) & 0x07)
            sector[offset + 1] = (nibbles[0x0FF - group] << 3) | ((lowB >> 2) & 0x07)
            sector[offset + 2] = (nibbles[0x132 - group] << 3) | ((lowC >> 2) & 0x07)
            sector[offset + 3] = (nibbles[0x165 - group] << 3) | ((lowA & 0x02) << 1) | (lowB & 0x02) | ((lowC & 0x02) >> 1)
            sector[offset + 4] = (nibbles[0x198 - group] << 3) | ((lowA & 0x01) << 2) | ((lowB & 0x01) << 1) | (lowC & 0x01)
        }
        sector[0xFF] = (nibbles[0x199] << 3) | (nibbles[0x000] & 0x07)
        return sector
    }

    static func diagnosticDSK() -> Data {
        var image = [UInt8](repeating: 0, count: imageSize)
        // The IIc ROM loads T0/S0 at $0800. This independent sector proves
        // the entire Slot-6 data path before users mount licensed software.
        let boot: [UInt8] = [
            0x01,                   // boot firmware loads one sector and enters $0801
            0xA2, 0x00, 0xBD, 0x12, 0x08, 0xF0, 0x07, 0x9D, 0x00, 0x04,
            0xE8, 0x4C, 0x03, 0x08, 0x4C, 0x0F, 0x08
        ] + Array("DISK BOOT OK".utf8).map { $0 | 0x80 } + [0]
        image.replaceSubrange(0..<boot.count, with: boot)
        return Data(image)
    }
}

/// Source-compatible name for the original 5¼-inch controller API.
typealias DiskII = IWMController
