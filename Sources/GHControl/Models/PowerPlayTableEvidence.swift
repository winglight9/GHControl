import CryptoKit
import Foundation

struct PowerPlayTableEvidence: Codable {
    let tableData: Data
    let vbiosSHA256: String
    let tableSHA256: String
    let vbiosByteCount: Int
    let tableOffset: Int
    let formatRevision: Int
    let contentRevision: Int
    let tableSize: Int
    let powerControlLimit: Int
    let powerTuneOffset: Int
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
        "PowerPlay v\(formatRevision).\(contentRevision) · \(tableSize) B · PowerTune rev \(powerTuneRevision)"
    }

    var supports70WCandidate: Bool {
        formatRevision == 7 && contentRevision == 1 && tableSize == 701 && powerTuneRevision == 4
            && tdpWatts == 75 && batteryPowerLimitWatts == 75 && smallPowerLimitWatts == 75
            && maximumPowerDeliveryLimitWatts == 75 && boostPowerLimitWatts == 75
    }

    func tableData(powerLimitWatts: Int) throws -> Data {
        guard powerLimitWatts == tdpWatts || (powerLimitWatts == 70 && supports70WCandidate) else {
            throw PowerPlayTableError.unsupportedTarget
        }
        guard powerLimitWatts <= tdpWatts else { throw PowerPlayTableError.targetExceedsStock }

        var candidate = tableData
        let fields: [(name: String, offset: Int, currentValue: Int)] = [
            ("TDP", 1, tdpWatts),
            ("BatteryPowerLimit", 7, batteryPowerLimitWatts),
            ("SmallPowerLimit", 9, smallPowerLimitWatts),
            ("MaximumPowerDeliveryLimit", 15, maximumPowerDeliveryLimitWatts),
            ("BoostPowerLimit", 46, boostPowerLimitWatts)
        ]

        for field in fields where field.currentValue > powerLimitWatts {
            let localOffset = powerTuneOffset + field.offset
            guard localOffset >= 0, localOffset + 1 < candidate.count else { throw PowerPlayTableError.invalidField }
            candidate[localOffset] = UInt8(powerLimitWatts & 0xFF)
            candidate[localOffset + 1] = UInt8((powerLimitWatts >> 8) & 0xFF)
        }
        return candidate
    }

    static func parse(vbios: Data) -> PowerPlayTableEvidence? {
        guard vbios.count >= 0x4A, vbios[0] == 0x55, vbios[1] == 0xAA,
              let romHeaderOffsetValue = littleEndianUInt16(in: vbios, at: 0x48) else { return nil }
        let romHeaderOffset = Int(romHeaderOffsetValue)
        guard hasBytes(vbios, at: romHeaderOffset, count: 40),
              Array(vbios[romHeaderOffset + 4 ..< romHeaderOffset + 8]) == Array("ATOM".utf8),
              let masterDataTableOffsetValue = littleEndianUInt16(in: vbios, at: romHeaderOffset + 32) else { return nil }
        let masterDataTableOffset = Int(masterDataTableOffsetValue)
        guard hasBytes(vbios, at: masterDataTableOffset, count: 74) else { return nil }

        let powerPlayPointerOffset = masterDataTableOffset + 4 + 15 * 2
        guard let powerPlayOffsetValue = littleEndianUInt16(in: vbios, at: powerPlayPointerOffset),
              powerPlayOffsetValue > 0 else { return nil }
        let powerPlayOffset = Int(powerPlayOffsetValue)
        guard let tableSizeValue = littleEndianUInt16(in: vbios, at: powerPlayOffset) else { return nil }
        let tableSize = Int(tableSizeValue)
        guard tableSize >= 64, hasBytes(vbios, at: powerPlayOffset, count: tableSize),
              vbios[powerPlayOffset + 2] == 7, vbios[powerPlayOffset + 3] == 1,
              let embeddedTableSize = littleEndianUInt16(in: vbios, at: powerPlayOffset + 5),
              embeddedTableSize >= 77, Int(embeddedTableSize) <= tableSize,
              let powerControlLimitValue = littleEndianUInt16(in: vbios, at: powerPlayOffset + 31),
              let relativePowerTuneOffsetValue = littleEndianUInt16(in: vbios, at: powerPlayOffset + 57) else { return nil }

        let relativePowerTuneOffset = Int(relativePowerTuneOffsetValue)
        let absolutePowerTuneOffset = powerPlayOffset + relativePowerTuneOffset
        guard relativePowerTuneOffset >= 0,
              relativePowerTuneOffset + 53 <= tableSize,
              hasBytes(vbios, at: absolutePowerTuneOffset, count: 53),
              vbios[absolutePowerTuneOffset] == 4 else { return nil }
        let values = [1, 3, 5, 7, 9, 15, 17, 46].compactMap {
            littleEndianUInt16(in: vbios, at: absolutePowerTuneOffset + $0)
        }
        guard values.count == 8 else { return nil }

        let tableEnd = powerPlayOffset + tableSize
        let table = Data(vbios[powerPlayOffset ..< tableEnd])
        let vbiosDigest = sha256(vbios)
        let tableDigest = sha256(table)
        let tdp = Int(values[0])
        let configurableTDP = Int(values[1])
        let tdc = Int(values[2])
        let battery = Int(values[3])
        let small = Int(values[4])
        let maximumDelivery = Int(values[5])
        let tjMax = Int(values[6])
        let boost = Int(values[7])
        let powerControlLimit = Int(powerControlLimitValue)
        return PowerPlayTableEvidence(
            tableData: table,
            vbiosSHA256: vbiosDigest,
            tableSHA256: tableDigest,
            vbiosByteCount: vbios.count,
            tableOffset: powerPlayOffset,
            formatRevision: Int(vbios[powerPlayOffset + 2]),
            contentRevision: Int(vbios[powerPlayOffset + 3]),
            tableSize: tableSize,
            powerControlLimit: powerControlLimit,
            powerTuneOffset: relativePowerTuneOffset,
            powerTuneRevision: Int(vbios[absolutePowerTuneOffset]),
            tdpWatts: Int(tdp),
            configurableTDPWatts: Int(configurableTDP),
            tdcAmps: Int(tdc),
            batteryPowerLimitWatts: Int(battery),
            smallPowerLimitWatts: Int(small),
            maximumPowerDeliveryLimitWatts: Int(maximumDelivery),
            boostPowerLimitWatts: Int(boost),
            tjMaxC: Int(tjMax)
        )
    }

    private static func littleEndianUInt16(in data: Data, at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 1 < data.count else { return nil }
        return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func hasBytes(_ data: Data, at offset: Int, count: Int) -> Bool {
        offset >= 0 && count >= 0 && offset <= data.count && count <= data.count - offset
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

enum PowerPlayTableError: LocalizedError {
    case unsupportedTarget
    case targetExceedsStock
    case invalidField

    var errorDescription: String? {
        switch self {
        case .unsupportedTarget: "首版只生成 70 W 候选和当前镜像基准表回退片段。"
        case .targetExceedsStock: "候选功耗上限不能高于当前驱动公开镜像的基准表字段。"
        case .invalidField: "PowerTune 字段越过表边界，已拒绝生成。"
        }
    }
}
