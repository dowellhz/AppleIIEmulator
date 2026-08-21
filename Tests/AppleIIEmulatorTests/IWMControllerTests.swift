import XCTest
@testable import AppleIIEmulator

final class IWMControllerTests: XCTestCase {
    func testDSKUsesDOS33StandardSixAndTwoAuxiliaryOrdering() throws {
        var image = [UInt8](repeating: 0, count: IWMController.imageSize)
        image.replaceSubrange(0..<256, with: (0..<256).map(UInt8.init))

        let disk = IWMController()
        try disk.mountDSK(Data(image))
        let nibbles = try XCTUnwrap(disk.nibImage())

        // Track 0 / physical sector 0 begins after its 22-byte sync gap,
        // address field, and seven-byte inter-field gap.  For source bytes
        // 00...FF, the first three translated GCR bytes are the published
        // DOS 3.3 auxiliary-buffer sequence: 9D E6 FF.  The auxiliary
        // buffer is written from offset 85 down to zero before the high-six
        // bit portion of the sector.
        XCTAssertEqual(Array(nibbles[46..<49]), [0x9D, 0xE6, 0xFF])
    }

    func testIWMDeliversSectorPrologueThroughP6() throws {
        let disk = IWMController()
        try disk.mountDSK(DiskII.diagnosticDSK())
        _ = disk.access(0x09, write: nil) // motor on
        _ = disk.access(0x0C, write: nil) // Q6 low, read mode

        var visibleBytes = [UInt8]()
        var previous: UInt8?
        for _ in 0..<20_000 {
            disk.advance(by: 1)
            let value = disk.access(0x0C, write: nil)
            if value & 0x80 != 0, previous.map({ $0 & 0x80 == 0 }) ?? true {
                visibleBytes.append(value)
            }
            previous = value
        }

        XCTAssertTrue(visibleBytes.indices.dropLast(2).contains { index in
            Array(visibleBytes[index..<(index + 3)]) == [0xD5, 0xAA, 0x96]
        })
        let dataField = try XCTUnwrap(visibleBytes.indices.first { index in
            index + 346 <= visibleBytes.count && Array(visibleBytes[index..<(index + 3)]) == [0xD5, 0xAA, 0xAD]
        })
        let nibbles = try XCTUnwrap(disk.nibImage())
        XCTAssertEqual(
            Array(visibleBytes[dataField..<(dataField + 346)]),
            Array(nibbles[43..<389]),
            "P6 must preserve the complete GCR data field seen by boot loaders"
        )
    }

    func testIWMWriteDataRegisterWritesNibbleStream() throws {
        let disk = IWMController()
        try disk.mountDSK(DiskII.diagnosticDSK())
        let original = try XCTUnwrap(disk.nibImage())
        _ = disk.access(0x09, write: nil)
        _ = disk.access(0x0F, write: nil)
        _ = disk.access(0x0D, write: 0xA5)
        disk.advance(by: 64)
        XCTAssertGreaterThan(disk.nibbleWrites, 0)
        XCTAssertNotEqual(disk.nibImage(), original, "IWM writes must be retained by NIB export")
    }

    func testIWMSelectsIndependentSecondDrive() throws {
        let disk = IWMController()
        try disk.mountDSK(DiskII.diagnosticDSK(), drive: 0)
        try disk.mountDSK(DiskII.diagnosticDSK(), drive: 1)
        _ = disk.access(0x09, write: nil)
        _ = disk.access(0x0B, write: nil)
        _ = disk.access(0x0C, write: nil)
        _ = disk.access(0x0E, write: nil)
        disk.advance(by: 1_024)
        XCTAssertGreaterThan(disk.nibbleReads, 0)
        disk.eject(drive: 1)
        XCTAssertFalse(disk.hasDisk(in: 1))
        XCTAssertTrue(disk.hasDisk(in: 0))
    }

    func testIWMStepperPhasesDoNotLeakAcrossDriveSelect() throws {
        let disk = IWMController()
        try disk.mountDSK(DiskII.diagnosticDSK(), drive: 0)
        try disk.mountDSK(DiskII.diagnosticDSK(), drive: 1)

        // Seek Drive 1 by energizing phases 0, 1 and 2.
        _ = disk.access(0x01, write: nil)
        _ = disk.access(0x03, write: nil)
        _ = disk.access(0x05, write: nil)
        XCTAssertEqual(disk.currentTrack(in: 0), 1)

        // The same phase accesses must be rising edges for Drive 2 as well.
        // A controller-global phase latch leaves Drive 2 at track zero here.
        _ = disk.access(0x0B, write: nil)
        _ = disk.access(0x01, write: nil)
        _ = disk.access(0x03, write: nil)
        _ = disk.access(0x05, write: nil)
        XCTAssertEqual(disk.currentTrack(in: 1), 1)
        XCTAssertEqual(disk.currentTrack(in: 0), 1)
    }

    func testIWMAllowsExtended37TrackSectorImage() throws {
        // WordPerfect 1.1 is distributed as a 37-track 5.25-inch DOS-order
        // image.  It must not be silently truncated to a normal 35-track disk.
        let image = Data(repeating: 0, count: 37 * 16 * 256)
        let disk = IWMController()
        try disk.mountImage(image, fileExtension: "dsk")
        XCTAssertTrue(disk.hasDisk)
        XCTAssertEqual(disk.currentTrack(), 0)
    }

    func testBundledWordPerfect37TrackImageMounts() throws {
        let url = try XCTUnwrap(AppResources.bundle.url(
            forResource: "WordPerfect 1.1 IIe-IIc", withExtension: "dsk"
        ))
        let disk = IWMController()
        try disk.mountImage(Data(contentsOf: url), fileExtension: "dsk")
        XCTAssertTrue(disk.hasDisk)
    }

    func testBundledSoftwareImagesMount() throws {
        let images = [
            ("VisiCalc 1.37", "dsk", "dsk"),
            ("Apple II System Utilities 3.2", "dsk", "dsk"),
            ("Copy II Plus 5.5", "dsk", "dsk"),
            ("Apple Pascal 1.3 APPLE0", "dsk", "dsk"),
            ("Apple Pascal 1.3 APPLE1 Boot", "dsk", "dsk"),
            ("Apple Pascal 1.3 APPLE2", "dsk", "dsk"),
            ("Apple Pascal 1.3 APPLE3", "dsk", "dsk")
        ]
        for (name, fileExtension, formatHint) in images {
            let url = try XCTUnwrap(AppResources.bundle.url(forResource: name, withExtension: fileExtension))
            let disk = IWMController()
            try disk.mountImage(Data(contentsOf: url), fileExtension: formatHint)
            XCTAssertTrue(disk.hasDisk, "\(name) should mount")
        }
    }

    func testIWMStepperUsesQuarterTrackState() throws {
        let disk = IWMController()
        try disk.mountDSK(DiskII.diagnosticDSK())
        _ = disk.access(0x09, write: nil)
        _ = disk.access(0x01, write: nil)
        _ = disk.access(0x03, write: nil)
        XCTAssertEqual(disk.currentTrack(), 0)
        _ = disk.access(0x05, write: nil)
        _ = disk.access(0x07, write: nil)
        XCTAssertEqual(disk.currentTrack(), 1)
    }

    func testWriteProtected2IMGSignalsIWMAndRejectsWrites() throws {
        var image = [UInt8](repeating: 0, count: 64)
        image.replaceSubrange(0..<4, with: [0x32, 0x49, 0x4D, 0x47]) // 2IMG
        image[8] = 64 // header length
        image[19] = 0x80 // flags bit 31: write-protected
        image[24] = 64 // data offset
        let payload = Array(DiskII.diagnosticDSK())
        let payloadLength = payload.count
        for byte in 0..<4 { image[28 + byte] = UInt8((payloadLength >> (byte * 8)) & 0xFF) }
        image += payload

        let disk = IWMController()
        try disk.mountImage(Data(image), fileExtension: "2mg")
        XCTAssertTrue(disk.isWriteProtected())
        _ = disk.access(0x09, write: nil) // motor on
        XCTAssertEqual(disk.access(0x0D, write: nil), 0x80) // Q6H write-protect sense

        let original = try XCTUnwrap(disk.nibImage())
        _ = disk.access(0x0F, write: nil) // Q7H: write mode
        _ = disk.access(0x0D, write: 0xA5)
        disk.advance(by: 64)
        XCTAssertEqual(disk.nibbleWrites, 0)
        XCTAssertEqual(disk.nibImage(), original)
    }

    func testWOZ2UsesQuarterTrackMapAndMountsReadOnly() throws {
        let disk = IWMController()
        try disk.mountImage(woz2Image(), fileExtension: "woz")
        XCTAssertTrue(disk.hasDisk)
        XCTAssertTrue(disk.isWriteProtected())
        XCTAssertNil(disk.nibImage(), "raw WOZ tracks must not be exported as a fabricated NIB image")

        _ = disk.access(0x09, write: nil) // motor on
        _ = disk.access(0x0C, write: nil) // Q6L: read data
        disk.advance(by: 64)
        XCTAssertGreaterThan(disk.nibbleReads, 0)
        XCTAssertEqual(disk.access(0x0D, write: nil), 0x80) // Q6H: write-protect sense

        _ = disk.access(0x0F, write: nil)
        _ = disk.access(0x0D, write: 0xA5)
        disk.advance(by: 64)
        XCTAssertEqual(disk.nibbleWrites, 0)
    }

    func testWOZ1LoadsFixedTrackBitstream() throws {
        let disk = IWMController()
        try disk.mountImage(woz1Image(), fileExtension: "woz")
        XCTAssertTrue(disk.hasDisk)
        XCTAssertFalse(disk.isWriteProtected(), "WOZ INFO write-protect bit must be honoured")
        _ = disk.access(0x09, write: nil)
        _ = disk.access(0x0C, write: nil)
        disk.advance(by: 64)
        XCTAssertGreaterThan(disk.nibbleReads, 0)
    }

    func testWOZ2SaveAsRoundTripsBitTracksAndWriteProtectSense() throws {
        let original = woz2Image(writeProtected: false)
        let disk = IWMController()
        try disk.mountImage(original, fileExtension: "woz")
        XCTAssertFalse(disk.isWriteProtected())

        let saved = try XCTUnwrap(disk.wozImage())
        XCTAssertEqual(Array(saved.prefix(4)), Array("WOZ2".utf8))
        XCTAssertNotEqual(Array(saved[8..<12]), [0, 0, 0, 0], "export must include a CRC")

        let restored = IWMController()
        try restored.mountImage(saved, fileExtension: "woz")
        XCTAssertFalse(restored.isWriteProtected())
        _ = restored.access(0x09, write: nil)
        _ = restored.access(0x0C, write: nil)
        restored.advance(by: 64)
        XCTAssertGreaterThan(restored.nibbleReads, 0)
    }

    func testWOZ21FluxMapDrivesIWMAndRoundTrips() throws {
        let disk = IWMController()
        try disk.mountImage(woz21FluxImage(), fileExtension: "woz")
        XCTAssertTrue(disk.hasDisk)

        _ = disk.access(0x09, write: nil) // motor on
        _ = disk.access(0x0C, write: nil) // Q6L: read data
        disk.advance(by: 128)
        XCTAssertGreaterThan(disk.fluxBitReads, 0)
        XCTAssertGreaterThan(disk.nibbleReads, 0)

        let saved = try XCTUnwrap(disk.wozImage())
        let restored = IWMController()
        try restored.mountImage(saved, fileExtension: "woz")
        _ = restored.access(0x09, write: nil)
        _ = restored.access(0x0C, write: nil)
        restored.advance(by: 128)
        XCTAssertGreaterThan(restored.fluxBitReads, 0)
    }

    func testWOZ21FluxWriteRequantizesChangedTrackAsFLUX() throws {
        let disk = IWMController()
        try disk.mountImage(woz21FluxImage(), fileExtension: "woz")
        _ = disk.access(0x09, write: nil) // motor on
        _ = disk.access(0x0F, write: nil) // Q7H: write mode
        _ = disk.access(0x0D, write: 0xA5)
        disk.advance(by: 64)
        XCTAssertGreaterThan(disk.nibbleWrites, 0)

        let saved = try XCTUnwrap(disk.wozImage())
        XCTAssertNotNil(saved.range(of: Data("FLUX".utf8)), "the modified flux track must remain a FLUX surface")
        let restored = IWMController()
        try restored.mountImage(saved, fileExtension: "woz")
        _ = restored.access(0x09, write: nil)
        _ = restored.access(0x0C, write: nil)
        restored.advance(by: 64)
        XCTAssertGreaterThan(restored.nibbleReads, 0)
        XCTAssertGreaterThan(restored.fluxBitReads, 0)
    }

    func testWOZSaveAsRetainsExtensionsUntilSurfaceChanges() throws {
        let disk = IWMController()
        try disk.mountImage(woz2Image(writeProtected: false, includeExtensions: true), fileExtension: "woz")
        let untouched = try XCTUnwrap(disk.wozImage())
        XCTAssertNotNil(untouched.range(of: Data("META".utf8)))
        XCTAssertNotNil(untouched.range(of: Data("WRIT".utf8)))

        _ = disk.access(0x09, write: nil) // motor on
        _ = disk.access(0x0F, write: nil) // Q7H: write mode
        _ = disk.access(0x0D, write: 0xA5)
        disk.advance(by: 64)
        XCTAssertGreaterThan(disk.nibbleWrites, 0)

        let modified = try XCTUnwrap(disk.wozImage())
        XCTAssertNotNil(modified.range(of: Data("META".utf8)))
        XCTAssertNil(modified.range(of: Data("WRIT".utf8)), "WRIT checksums describe the old BITS surface")
    }

    func testCleanedWOZGeneratesWeakBits() throws {
        let disk = IWMController()
        try disk.mountImage(woz2Image(cleaned: true, blankTrack: true), fileExtension: "woz")
        _ = disk.access(0x09, write: nil)
        _ = disk.access(0x0C, write: nil)
        disk.advance(by: 128)
        XCTAssertGreaterThan(disk.weakBitsGenerated, 0)
    }

    private func woz2Image(
        cleaned: Bool = false,
        blankTrack: Bool = false,
        writeProtected: Bool = true,
        includeExtensions: Bool = false
    ) -> Data {
        var image = [UInt8]("WOZ2".utf8) + [0xFF, 0x0A, 0x0D, 0x0A] + [0, 0, 0, 0]
        func appendChunk(_ identifier: String, _ payload: [UInt8]) {
            image += Array(identifier.utf8)
            let count = payload.count
            image += (0..<4).map { UInt8((count >> ($0 * 8)) & 0xFF) }
            image += payload
        }
        var info = [UInt8](repeating: 0, count: 60)
        info[0] = 2 // INFO version
        info[1] = 1 // 5.25-inch
        info[2] = writeProtected ? 1 : 0
        info[4] = cleaned ? 1 : 0
        appendChunk("INFO", info)

        var map = [UInt8](repeating: 0xFF, count: 160)
        map[0] = 0 // Track 0.00 uses TRKS entry 0.
        map[1] = 0 // Track 0.25 shares it; no forced track restart.
        appendChunk("TMAP", map)

        var tracks = [UInt8](repeating: 0, count: 160 * 8 + 512)
        tracks[0] = 3 // first BITS block starts at file offset 3 * 512
        tracks[2] = 1 // one 512-byte BITS block
        tracks[4] = 16 // sixteen valid bits
        tracks[1_280] = blankTrack ? 0x00 : 0xAA
        tracks[1_281] = blankTrack ? 0x00 : 0x55
        appendChunk("TRKS", tracks)
        if includeExtensions {
            appendChunk("META", Array("title\tFixture\n".utf8))
            appendChunk("WRIT", [0x01, 0x00, 0x00, 0x00])
        }
        return Data(image)
    }

    private func woz21FluxImage() -> Data {
        var image = [UInt8]("WOZ2".utf8) + [0xFF, 0x0A, 0x0D, 0x0A] + [0, 0, 0, 0]
        func appendChunk(_ identifier: String, _ payload: [UInt8]) {
            image += Array(identifier.utf8)
            image += (0..<4).map { UInt8((payload.count >> ($0 * 8)) & 0xFF) }
            image += payload
        }
        var info = [UInt8](repeating: 0, count: 60)
        info[0] = 3 // WOZ 2.1
        info[1] = 1 // 5.25-inch
        info[39] = 32 // 4 µs nominal bit cell
        info[46] = 4 // FLUX chunk begins at byte 4 * 512
        info[48] = 1 // largest flux track is one block
        appendChunk("INFO", info)

        appendChunk("TMAP", [UInt8](repeating: 0xFF, count: 160))
        var tracks = [UInt8](repeating: 0, count: 160 * 8 + 512)
        tracks[0] = 3 // first TRKS payload block
        tracks[2] = 1
        tracks[4] = 4 // flux byte count (not a BITS bit count)
        tracks[1_280..<1_284] = [32, 64, 32, 96]
        appendChunk("TRKS", tracks)

        var fluxMap = [UInt8](repeating: 0xFF, count: 160)
        fluxMap[0] = 0
        appendChunk("FLUX", fluxMap)
        return Data(image)
    }

    private func woz1Image() -> Data {
        var image = [UInt8]("WOZ1".utf8) + [0xFF, 0x0A, 0x0D, 0x0A] + [0, 0, 0, 0]
        func appendChunk(_ identifier: String, _ payload: [UInt8]) {
            image += Array(identifier.utf8)
            let count = payload.count
            image += (0..<4).map { UInt8((count >> ($0 * 8)) & 0xFF) }
            image += payload
        }
        var info = [UInt8](repeating: 0, count: 60)
        info[0] = 1
        info[1] = 1
        appendChunk("INFO", info)

        var map = [UInt8](repeating: 0xFF, count: 160)
        map[0] = 0
        appendChunk("TMAP", map)

        var track = [UInt8](repeating: 0, count: 6_656)
        track[0] = 0xAA
        track[1] = 0x55
        track[6_646] = 2 // bytes used, little-endian
        track[6_648] = 16 // bits used, little-endian
        appendChunk("TRKS", track)
        return Data(image)
    }
}
