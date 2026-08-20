import Foundation

/// Reads immutable ROM resources before they cross into the cycle-driven
/// memory bus. Keeping resource I/O here prevents the hardware model from
/// reaching into the app bundle or blocking the main actor.
enum AppleIIROMImages {
    struct IIPlus {
        let systemROM: Data
        let diskROM: Data
    }

    struct IIe {
        let motherboardROM: Data
        let diskROM: Data
    }

    static func iiC(named name: String) throws -> Data {
        guard let url = AppResources.bundle.url(forResource: name, withExtension: "bin") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let data = try Data(contentsOf: url)
        guard data.count == 0x4000 || data.count == 0x8000 else { throw CocoaError(.fileReadCorruptFile) }
        return data
    }

    static func iiPlus(diskFirmware: AppleIIMemory.DiskIIFirmware) throws -> IIPlus {
        guard let systemURL = AppResources.bundle.url(forResource: "AppleIIPlus-Applesoft-Autostart", withExtension: "rom"),
              let diskURL = AppResources.bundle.url(forResource: diskFirmware.resourceName, withExtension: "rom") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let systemROM = try Data(contentsOf: systemURL)
        let diskROM = try Data(contentsOf: diskURL)
        guard systemROM.count == 0x3000, diskROM.count == 0x100 else { throw CocoaError(.fileReadCorruptFile) }
        return IIPlus(systemROM: systemROM, diskROM: diskROM)
    }

    static func iiE(_ choice: AppleIIMachine.BootROM) throws -> IIe {
        let names: [String]
        switch choice {
        case .appleIIeEnhanced:
            names = ["AppleIIe-CD-Enhanced-342-0304-A", "AppleIIe-EF-Enhanced-342-0303-A"]
        case .appleIIeUnenhanced:
            names = ["AppleIIe-CD-Unenhanced-342-0135-B", "AppleIIe-EF-Unenhanced-342-0134-A"]
        case .appleIIeCF:
            names = ["AppleIIe-CF-342-0349-B"]
        default:
            throw CocoaError(.fileReadCorruptFile)
        }
        var motherboardROM = Data()
        for name in names {
            guard let url = AppResources.bundle.url(forResource: name, withExtension: "bin") else {
                throw CocoaError(.fileNoSuchFile)
            }
            motherboardROM.append(try Data(contentsOf: url))
        }
        guard motherboardROM.count == 0x4000,
              let diskURL = AppResources.bundle.url(forResource: AppleIIMemory.DiskIIFirmware.sixteenSector.resourceName, withExtension: "rom") else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let diskROM = try Data(contentsOf: diskURL)
        guard diskROM.count == 0x100 else { throw CocoaError(.fileReadCorruptFile) }
        return IIe(motherboardROM: motherboardROM, diskROM: diskROM)
    }
}
