import Foundation

/// Mutable state belonging to one physical 5¼-inch mechanism.  The IWM owns
/// controller latches and phase lines; this type owns only media and head
/// position, making two-drive behaviour explicit and independently testable.
struct DiskBitTrack {
    var bytes: [UInt8]
    var bitCount: Int
    /// Maps each physical bit cell to its source NIB bit.  Extra zero cells
    /// appended after an $FF self-sync byte have no NIB representation and
    /// are marked -1.  Keeping this hardware-to-container relationship lets
    /// a write through the IWM survive `nibImage()` export.
    var nibbleBitOffsets: [Int32]
}

/// A WOZ 2.1 flux stream.  Each byte is an elapsed count of 125 ns ticks;
/// consecutive $FF bytes extend a single interval.  Flux media uses the same
/// TRKS table as BITS media, but is selected through the separate FLUX map.
struct DiskFluxTrack {
    var bytes: [UInt8]
    var optimalBitTiming: Int
}

struct WOZPreservedChunk {
    var identifier: String
    var payload: [UInt8]
}

/// Container metadata that does not belong to the emulated magnetic surface.
/// Keeping it with the mounted drive lets Save As retain META and compatible
/// future chunks without ever overwriting a user's source image.
struct WOZContainerMetadata {
    var info: [UInt8]
    var preservedChunks: [WOZPreservedChunk]
}

struct EncodedDiskTrack {
    var nibbles: [UInt8]
    var sync: [Bool]
    var syncTrailingZeros: Int
}

struct DiskDrive {
    var tracks = [[UInt8]]()
    var bitTracks = [DiskBitTrack]()
    var fluxTracks = [DiskFluxTrack?]()
    /// Standard DOS/NIB media select `quarterTrack / 4`.  Bitstream images
    /// such as WOZ preserve the physical quarter-track map instead, including
    /// deliberately blank or overlapping tracks used by protected disks.
    var quarterTrackMap = [Int]()
    var fluxQuarterTrackMap = [Int]()
    /// Runtime writes use a recovered BITS working surface, while WOZ Save As
    /// must retain the original FLUX addressing and re-quantize that changed
    /// surface. This map is immutable media geometry, not a live head map.
    var originalFluxQuarterTrackMap = [Int]()
    var modifiedFluxTracks = [Bool]()
    var wozContainer: WOZContainerMetadata?
    var isThirteenSector = false
    var isWriteProtected = false
    /// Cleaned WOZ captures encode a weak-bit region as a run of zeroes.  The
    /// real MC3470 eventually amplifies noise there, so retain its tiny read
    /// head state with the physical drive rather than making it a UI effect.
    var emulatesWeakBits = false
    var readHeadWindow: UInt8 = 0
    var weakBitLFSR: UInt32 = 0xA2_5A_5A_01
    /// Flux decoder state lives in the drive because changing controller
    /// registers must never restart a physical revolution.
    var fluxBytePosition = 0
    var fluxTicksUntilTransition = 0
    var fluxCellTicks = 32
    var surfaceModified = false
    /// The Disk II controller selects one physical mechanism at a time.
    /// Each mechanism therefore retains its own energized stepper phases;
    /// selecting Drive 2 must not inherit Drive 1's coil state.
    var phaseStates: UInt8 = 0
    /// Quarter-track units preserve the Apple stepper's half-track movement.
    var quarterTrack = 0
    var bitPosition = 0

    var hasDisk: Bool { !bitTracks.isEmpty }

    mutating func eject() {
        tracks.removeAll()
        bitTracks.removeAll()
        fluxTracks.removeAll()
        quarterTrackMap.removeAll()
        fluxQuarterTrackMap.removeAll()
        originalFluxQuarterTrackMap.removeAll()
        modifiedFluxTracks.removeAll()
        wozContainer = nil
        isThirteenSector = false
        isWriteProtected = false
        emulatesWeakBits = false
        readHeadWindow = 0
        weakBitLFSR = 0xA2_5A_5A_01
        fluxBytePosition = 0
        fluxTicksUntilTransition = 0
        fluxCellTicks = 32
        surfaceModified = false
        phaseStates = 0
        quarterTrack = 0
        bitPosition = 0
    }

    mutating func install(
        tracks: [[UInt8]],
        bitTracks: [DiskBitTrack],
        quarterTrackMap: [Int] = [],
        fluxTracks: [DiskFluxTrack?] = [],
        fluxQuarterTrackMap: [Int] = [],
        wozContainer: WOZContainerMetadata? = nil,
        thirteenSector: Bool,
        writeProtected: Bool,
        emulatesWeakBits: Bool = false
    ) {
        self.tracks = tracks
        self.bitTracks = bitTracks
        self.fluxTracks = fluxTracks
        self.quarterTrackMap = quarterTrackMap
        self.fluxQuarterTrackMap = fluxQuarterTrackMap
        self.originalFluxQuarterTrackMap = fluxQuarterTrackMap
        self.modifiedFluxTracks = Array(repeating: false, count: fluxTracks.count)
        self.wozContainer = wozContainer
        self.isThirteenSector = thirteenSector
        self.isWriteProtected = writeProtected
        self.emulatesWeakBits = emulatesWeakBits
        readHeadWindow = 0
        weakBitLFSR = 0xA2_5A_5A_01
        fluxBytePosition = 0
        fluxTicksUntilTransition = 0
        fluxCellTicks = 32
        surfaceModified = false
        phaseStates = 0
        quarterTrack = 0
        bitPosition = 0
    }

    mutating func nextWeakBit() -> UInt8 {
        // A small deterministic noise source keeps runs reproducible in
        // regression tests while providing the approximately 30% pulse rate
        // recommended for MC3470 fake-bit recovery.
        weakBitLFSR = weakBitLFSR &* 1_664_525 &+ 1_013_904_223
        return UInt8((weakBitLFSR >> 24) < 77 ? 1 : 0)
    }

    mutating func nextFluxBit(track: Int) -> UInt8? {
        guard fluxTracks.indices.contains(track), let stream = fluxTracks[track], !stream.bytes.isEmpty else {
            return nil
        }
        if fluxTicksUntilTransition == 0 {
            fluxTicksUntilTransition = nextFluxInterval(from: stream)
            fluxCellTicks = max(16, stream.optimalBitTiming)
        }
        let cellTicks = max(16, fluxCellTicks)
        if fluxTicksUntilTransition > cellTicks {
            fluxTicksUntilTransition -= cellTicks
            return 0
        }

        // A first-order digital PLL keeps the nominal 4 µs cell clock tied
        // to the captured transition without letting a protected disk's
        // deliberate long gaps jerk the clock by an entire cell.
        let phaseError = fluxTicksUntilTransition - cellTicks
        fluxCellTicks = min(48, max(16, cellTicks + phaseError / 8))
        fluxTicksUntilTransition = nextFluxInterval(from: stream)
        return 1
    }

    /// A flux capture has no intrinsic writable bit cells.  Before the IWM
    /// changes one, recover a complete revolution into a BITS track and move
    /// each FLUX-mapped quarter track onto that new surface.  This is a
    /// The working copy is BITS so the IWM can address individual cells. A
    /// later WOZ export re-quantizes only this changed track back to FLUX.
    mutating func materializeFluxTrack(_ track: Int) -> Bool {
        guard fluxTracks.indices.contains(track), let stream = fluxTracks[track], !stream.bytes.isEmpty else {
            return false
        }
        let cellTicks = max(16, stream.optimalBitTiming)
        var sourcePosition = 0
        var cells = [UInt8]()
        repeat {
            var ticks = 0
            repeat {
                let byte = stream.bytes[sourcePosition]
                sourcePosition = (sourcePosition + 1) % stream.bytes.count
                ticks += Int(byte)
                if byte != 0xFF { break }
            } while true
            let cellCount = max(1, Int((Double(ticks) / Double(cellTicks)).rounded()))
            cells.append(contentsOf: repeatElement(0, count: cellCount - 1))
            cells.append(1)
        } while sourcePosition != 0
        guard !cells.isEmpty else { return false }

        var bytes = [UInt8](repeating: 0, count: (cells.count + 7) / 8)
        for (position, bit) in cells.enumerated() where bit != 0 {
            bytes[position / 8] |= UInt8(1) << UInt8(7 - (position & 7))
        }
        bitTracks[track] = DiskBitTrack(
            bytes: bytes,
            bitCount: cells.count,
            nibbleBitOffsets: Array(repeating: -1, count: cells.count)
        )
        if modifiedFluxTracks.indices.contains(track) { modifiedFluxTracks[track] = true }
        for quarterTrack in fluxQuarterTrackMap.indices where fluxQuarterTrackMap[quarterTrack] == track {
            fluxQuarterTrackMap[quarterTrack] = -1
            if quarterTrackMap.indices.contains(quarterTrack), quarterTrackMap[quarterTrack] < 0 {
                quarterTrackMap[quarterTrack] = track
            }
        }
        fluxBytePosition = 0
        fluxTicksUntilTransition = 0
        fluxCellTicks = cellTicks
        bitPosition = 0
        surfaceModified = true
        return true
    }

    /// FLUX records transition intervals in 125 ns ticks. A recovered BITS
    /// track has an explicit transition at every `1` cell, so its modified
    /// surface can be deterministically re-quantized for WOZ 2.1 Save As.
    func fluxSurfaceForExport() -> (tracks: [DiskFluxTrack?], map: [Int]) {
        guard modifiedFluxTracks.contains(true) else {
            return (fluxTracks, fluxQuarterTrackMap)
        }
        var tracks = fluxTracks
        for index in modifiedFluxTracks.indices where modifiedFluxTracks[index] {
            guard bitTracks.indices.contains(index) else { continue }
            let timing = fluxTracks.indices.contains(index) ? fluxTracks[index]?.optimalBitTiming ?? 32 : 32
            tracks[index] = Self.quantize(bitTrack: bitTracks[index], timing: timing)
        }
        return (tracks, originalFluxQuarterTrackMap)
    }

    private static func quantize(bitTrack: DiskBitTrack, timing: Int) -> DiskFluxTrack {
        guard bitTrack.bitCount > 0 else { return DiskFluxTrack(bytes: [1], optimalBitTiming: timing) }
        var intervals = [UInt8]()
        var cellsSinceTransition = 0
        for position in 0..<bitTrack.bitCount {
            cellsSinceTransition += 1
            let bit = (bitTrack.bytes[position / 8] >> UInt8(7 - (position & 7))) & 1
            guard bit != 0 else { continue }
            var ticks = max(1, cellsSinceTransition * max(16, timing))
            while ticks >= 255 {
                intervals.append(0xFF)
                ticks -= 255
            }
            intervals.append(UInt8(ticks))
            cellsSinceTransition = 0
        }
        if intervals.isEmpty { intervals = [UInt8(min(254, max(1, bitTrack.bitCount * max(16, timing))))] }
        return DiskFluxTrack(bytes: intervals, optimalBitTiming: timing)
    }

    private mutating func nextFluxInterval(from stream: DiskFluxTrack) -> Int {
        var ticks = 0
        repeat {
            let byte = stream.bytes[fluxBytePosition % stream.bytes.count]
            fluxBytePosition = (fluxBytePosition + 1) % stream.bytes.count
            ticks += Int(byte)
            if byte != 0xFF { break }
        } while true
        return max(1, ticks)
    }
}
