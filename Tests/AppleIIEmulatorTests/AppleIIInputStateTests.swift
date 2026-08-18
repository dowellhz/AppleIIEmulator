import XCTest
@testable import AppleIIEmulator

final class AppleIIInputStateTests: XCTestCase {
    func testOppositeDirectionsReturnPaddleToCentre() {
        var input = AppleIIInputState()
        XCTAssertEqual(input.setJoystickKey(123, pressed: true), [0, 127, 0, 127])
        XCTAssertEqual(input.setJoystickKey(124, pressed: true), [127, 127, 127, 127])
        XCTAssertEqual(input.setJoystickKey(123, pressed: false), [255, 127, 255, 127])
    }

    func testReleasingLastDirectionKeepsJoystickAtLastPosition() {
        var input = AppleIIInputState()
        XCTAssertEqual(input.setJoystickKey(126, pressed: true), [127, 0, 127, 0])
        XCTAssertEqual(input.setJoystickKey(126, pressed: false), [127, 0, 127, 0])
    }

    func testNonJoystickKeyDoesNotChangePaddles() {
        var input = AppleIIInputState()
        XCTAssertNil(input.setJoystickKey(0, pressed: true))
    }

    @MainActor
    func testMacArrowKeysAlsoReachTheAppleIIKeyboardLatch() throws {
        let machine = AppleIIMachine()
        let left = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 123))
        let right = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 124))
        machine.keyDown(left)
        XCTAssertEqual(machine.memory.read(0xC000), 0x88) // Apple II left arrow
        machine.keyDown(right)
        XCTAssertEqual(machine.memory.read(0xC000), 0x95) // Apple II Ctrl-U/right arrow
    }
}
