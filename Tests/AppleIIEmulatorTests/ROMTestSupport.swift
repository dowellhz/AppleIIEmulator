import Foundation
@testable import AppleIIEmulator

/// Test-only conveniences retain the concise hardware tests without allowing
/// the production memory bus to perform bundle file I/O.
extension AppleIIMemory {
    func loadBundledAppleIIcROM(named name: String) throws {
        try installIIcROM(AppleIIROMImages.iiC(named: name))
    }

    func loadBundledAppleIIPlusROM(diskFirmware: DiskIIFirmware) throws {
        let images = try AppleIIROMImages.iiPlus(diskFirmware: diskFirmware)
        try installIIPlusROM(systemROM: images.systemROM, diskROM: images.diskROM, diskFirmware: diskFirmware)
    }

    func loadBundledAppleIIeROM(_ choice: AppleIIMachine.BootROM) throws {
        let images = try AppleIIROMImages.iiE(choice)
        try installIIeROM(images.motherboardROM, diskROM: images.diskROM, choice: choice)
    }
}
