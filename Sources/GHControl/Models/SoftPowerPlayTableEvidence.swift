import CryptoKit
import Foundation

/// Read-only evidence that an sPPT reached the live GPU registry node.
/// This does not claim that the AMD driver adopted the table.
struct SoftPowerPlayTableEvidence: Codable {
    let byteCount: Int
    let sha256: String
    let formatRevision: Int
    let contentRevision: Int
    let powerTuneRevision: Int
    let tdpWatts: Int
    let configurableTDPWatts: Int
    let tdcAmps: Int
    let batteryPowerLimitWatts: Int
    let smallPowerLimitWatts: Int
    let maximumPowerDeliveryLimitWatts: Int
    let boostPowerLimitWatts: Int
    let tjMaxC: Int

    var summary: String {
        "PowerPlay v\(formatRevision).\(contentRevision) · \(byteCount) B · TDP \(tdpWatts) W · Boost \(boostPowerLimitWatts) W"
    }

    static func parse(_ data: Data) -> SoftPowerPlayTableEvidence? {
        guard data.count >= 64,
              let declaredSize = littleEndianUInt16(in: data, at: 0),
              Int(declaredSize) == data.count,
              data[2] == 7, data[3] == 1,
              let embeddedSize = littleEndianUInt16(in: data, at: 5),
              embeddedSize >= 77, Int(embeddedSize) <= data.count,
              let powerTuneOffsetValue = littleEndianUInt16(in: data, at: 57) else { return nil }

        let powerTuneOffset = Int(powerTuneOffsetValue)
        guard powerTuneOffset + 48 <= data.count,
              data[powerTuneOffset] == 4 else { return nil }

        let fieldOffsets = [1, 3, 5, 7, 9, 15, 17, 46]
        let values = fieldOffsets.compactMap { littleEndianUInt16(in: data, at: powerTuneOffset + $0) }
        guard values.count == fieldOffsets.count else { return nil }

        return SoftPowerPlayTableEvidence(
            byteCount: data.count,
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            formatRevision: Int(data[2]),
            contentRevision: Int(data[3]),
            powerTuneRevision: Int(data[powerTuneOffset]),
            tdpWatts: Int(values[0]),
            configurableTDPWatts: Int(values[1]),
            tdcAmps: Int(values[2]),
            batteryPowerLimitWatts: Int(values[3]),
            smallPowerLimitWatts: Int(values[4]),
            maximumPowerDeliveryLimitWatts: Int(values[5]),
            boostPowerLimitWatts: Int(values[7]),
            tjMaxC: Int(values[6])
        )
    }

    private static func littleEndianUInt16(in data: Data, at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 1 < data.count else { return nil }
        return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }
}
