import XCTest
@testable import AppleIIEmulator

final class IWMControllerTests: XCTestCase {
    func testIWMWriteDataRegisterWritesNibbleStream() throws {
        let disk = IWMController()
        try disk.mountDSK(DiskII.diagnosticDSK())
        _ = disk.access(0x09, write: nil)
        _ = disk.access(0x0F, write: nil)
        _ = disk.access(0x0D, write: 0xA5)
        disk.advance(by: 64)
        XCTAssertGreaterThan(disk.nibbleWrites, 0)
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
}
