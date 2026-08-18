import Foundation

/// Mutable state belonging to one physical 5¼-inch mechanism.  The IWM owns
/// controller latches and phase lines; this type owns only media and head
/// position, making two-drive behaviour explicit and independently testable.
struct DiskBitTrack {
    var bytes: [UInt8]
    var bitCount: Int
}

struct EncodedDiskTrack {
    var nibbles: [UInt8]
    var sync: [Bool]
    var syncTrailingZeros: Int
}

struct DiskDrive {
    var tracks = [[UInt8]]()
    var bitTracks = [DiskBitTrack]()
    var isThirteenSector = false
    /// Quarter-track units preserve the Apple stepper's half-track movement.
    var quarterTrack = 0
    var bitPosition = 0

    var hasDisk: Bool { !tracks.isEmpty }

    mutating func eject() {
        tracks.removeAll()
        bitTracks.removeAll()
        isThirteenSector = false
        quarterTrack = 0
        bitPosition = 0
    }

    mutating func install(tracks: [[UInt8]], bitTracks: [DiskBitTrack], thirteenSector: Bool) {
        self.tracks = tracks
        self.bitTracks = bitTracks
        self.isThirteenSector = thirteenSector
        quarterTrack = 0
        bitPosition = 0
    }
}
