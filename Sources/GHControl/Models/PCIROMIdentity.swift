import Foundation

/// Identity declared by the PCI data structure embedded in the GPU's ROM.
/// This is independent of OpenCore's `device-id` property, but it is still not
/// a direct read of PCI configuration space.
struct PCIROMIdentity: Codable, Equatable {
    let vendorID: String
    let deviceID: String
    let pcirOffset: Int
    let imageSize: Int
    let checksumValid: Bool

    var pciID: String { "\(vendorID):\(deviceID)" }

    static func parse(vbios: Data) -> PCIROMIdentity? {
        guard vbios.count >= 0x1A,
              vbios[0] == 0x55,
              vbios[1] == 0xAA,
              let pcirPointer = littleEndianUInt16(in: vbios, at: 0x18) else { return nil }

        let pcirOffset = Int(pcirPointer)
        guard hasBytes(vbios, at: pcirOffset, count: 0x16),
              Array(vbios[pcirOffset ..< pcirOffset + 4]) == Array("PCIR".utf8),
              let structureLength = littleEndianUInt16(in: vbios, at: pcirOffset + 0x0A),
              structureLength >= 0x16,
              hasBytes(vbios, at: pcirOffset, count: Int(structureLength)),
              let imageLengthUnits = littleEndianUInt16(in: vbios, at: pcirOffset + 0x10),
              imageLengthUnits > 0,
              let vendor = littleEndianUInt16(in: vbios, at: pcirOffset + 0x04),
              let device = littleEndianUInt16(in: vbios, at: pcirOffset + 0x06) else { return nil }

        let imageSize = Int(imageLengthUnits) * 512
        guard imageSize <= vbios.count else { return nil }
        let checksumValid = vbios.prefix(imageSize).reduce(UInt8(0)) { $0 &+ $1 } == 0

        return PCIROMIdentity(
            vendorID: String(format: "%04X", vendor),
            deviceID: String(format: "%04X", device),
            pcirOffset: pcirOffset,
            imageSize: imageSize,
            checksumValid: checksumValid
        )
    }

    private static func littleEndianUInt16(in data: Data, at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 1 < data.count else { return nil }
        return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func hasBytes(_ data: Data, at offset: Int, count: Int) -> Bool {
        offset >= 0 && count >= 0 && offset <= data.count && count <= data.count - offset
    }
}
