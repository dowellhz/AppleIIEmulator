import Foundation

/// Hardware-facing contract used by the CPU.  It intentionally contains only
/// bus traffic and cycle-sensitive hooks: ROM loading, UI state and video
/// rendering remain outside the processor core.
protocol AppleIIBus: AnyObject {
    func read(_ address: UInt16) -> UInt8
    func write(_ address: UInt16, _ value: UInt8)
    func setSpeakerCycle(_ cycle: Int)
    func advanceVideoClock(by cycles: Int)
    /// Level-sensitive maskable interrupt line sampled between instructions.
    /// Peripherals assert this through the same emulated cycle path as all
    /// other bus effects; it is never driven from a render-frame callback.
    var irqPending: Bool { get }
}
