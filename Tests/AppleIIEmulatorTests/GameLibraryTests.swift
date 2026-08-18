import XCTest
@testable import AppleIIEmulator

final class GameLibraryTests: XCTestCase {
    func testKnownDiskExtensionsAreRecognised() {
        XCTAssertEqual(DiskImageFormat(fileExtension: "DSK"), .dosOrder)
        XCTAssertEqual(DiskImageFormat(fileExtension: "2img"), .twoIMG)
        XCTAssertNil(DiskImageFormat(fileExtension: "zip"))
    }

    func testAdjacentHiResDotsBecomeTwoSharpWhiteDots() {
        let dots = appleIIHiResDots(bytes: [0x06])
        XCTAssertEqual(dots[1], .white)
        XCTAssertEqual(dots[2], .white)
        XCTAssertEqual(dots[0], .black)
    }
}
