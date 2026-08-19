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

struct EncodedDiskTrack {
    var nibbles: [UInt8]
    var sync: [Bool]
    var syncTrailingZeros: Int
}

struct DiskDrive {
    var tracks = [[UInt8]]()
    var bitTracks = [DiskBitTrack]()
    /// Standard DOS/NIB media select `quarterTrack / 4`.  Bitstream images
    /// such as WOZ preserve the physical quarter-track map instead, including
    /// deliberately blank or overlapping tracks used by protected disks.
    var quarterTrackMap = [Int]()
    var isThirteenSector = false
    var isWriteProtected = false
    /// Cleaned WOZ captures encode a weak-bit region as a run of zeroes.  The
    /// real MC3470 eventually amplifies noise there, so retain its tiny read
    /// head state with the physical drive rather than making it a UI effect.
    var emulatesWeakBits = false
    var readHeadWindow: UInt8 = 0
    var weakBitLFSR: UInt32 = 0xA2_5A_5A_01
    /// Quarter-track units preserve the Apple stepper's half-track movement.
    var quarterTrack = 0
    var bitPosition = 0

    var hasDisk: Bool { !bitTracks.isEmpty }

    mutating func eject() {
        tracks.removeAll()
        bitTracks.removeAll()
        quarterTrackMap.removeAll()
        isThirteenSector = false
        isWriteProtected = false
        emulatesWeakBits = false
        readHeadWindow = 0
        weakBitLFSR = 0xA2_5A_5A_01
        quarterTrack = 0
        bitPosition = 0
    }

    mutating func install(
        tracks: [[UInt8]],
        bitTracks: [DiskBitTrack],
        quarterTrackMap: [Int] = [],
        thirteenSector: Bool,
        writeProtected: Bool,
        emulatesWeakBits: Bool = false
    ) {
        self.tracks = tracks
        self.bitTracks = bitTracks
        self.quarterTrackMap = quarterTrackMap
        self.isThirteenSector = thirteenSector
        self.isWriteProtected = writeProtected
        self.emulatesWeakBits = emulatesWeakBits
        readHeadWindow = 0
        weakBitLFSR = 0xA2_5A_5A_01
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
}
