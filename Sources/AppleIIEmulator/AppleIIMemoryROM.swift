import Foundation

/// ROM installation belongs to the memory map, but resource reads stay in
/// `AppleIIROMImages`. These methods receive only validated bytes.
extension AppleIIMemory {
    func installIIcROM(_ data: Data) throws {
        guard data.count == 0x4000 || data.count == 0x8000 else { throw CocoaError(.fileReadCorruptFile) }
        model = .appleIIc
        supportsMouseText = true
        let bank = Array(data)
        iicROM = data.count == 0x4000 ? bank + bank : bank
        iicROMBank = 0
        iieROM = []
    }

    func installIIPlusROM(systemROM: Data, diskROM: Data, diskFirmware: DiskIIFirmware) throws {
        guard systemROM.count == 0x3000, diskROM.count == 0x100 else { throw CocoaError(.fileReadCorruptFile) }
        model = .appleIIPlus
        supportsMouseText = false
        iicROM = []
        iicROMBank = 0
        iieROM = []
        plusSlot6ROM = Array(diskROM)
        plusDiskFirmware = diskFirmware
        bytes = [UInt8](repeating: 0, count: 65_536)
        auxiliaryBytes = [UInt8](repeating: 0, count: 65_536)
        clearLanguageCard()
        bytes.replaceSubrange(0xD000..<0x10000, with: systemROM)
    }

    func installIIeROM(_ motherboardROM: Data, diskROM: Data, choice: AppleIIMachine.BootROM) throws {
        guard motherboardROM.count == 0x4000, diskROM.count == 0x100 else { throw CocoaError(.fileReadCorruptFile) }
        model = .appleIIe
        supportsMouseText = choice == .appleIIeEnhanced
        iicROM = []
        iicROMBank = 0
        iieROM = Array(motherboardROM)
        plusSlot6ROM = Array(diskROM)
        plusDiskFirmware = .sixteenSector
        bytes = [UInt8](repeating: 0, count: 65_536)
        auxiliaryBytes = [UInt8](repeating: 0, count: 65_536)
        clearLanguageCard()
    }
}
