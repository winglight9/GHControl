import Foundation
import IOKit

struct PackagePowerControlState: Codable, Equatable {
    let serviceCount: Int
    let servicePath: String?
    let controllerPath: String?
    let targetGPUPath: String?
    let cachedLimitReportedValue: Int?
    let message: String
    let lastWriteMessage: String?
    let powerPercentReadOnlyState: PowerPercentReadOnlyState?
    let voltageOffsetReadOnlyState: VoltageOffsetReadOnlyState?

    init(
        serviceCount: Int,
        servicePath: String?,
        controllerPath: String?,
        targetGPUPath: String?,
        cachedLimitReportedValue: Int?,
        message: String,
        lastWriteMessage: String? = nil,
        powerPercentReadOnlyState: PowerPercentReadOnlyState? = nil,
        voltageOffsetReadOnlyState: VoltageOffsetReadOnlyState? = nil
    ) {
        self.serviceCount = serviceCount
        self.servicePath = servicePath
        self.controllerPath = controllerPath
        self.targetGPUPath = targetGPUPath
        self.cachedLimitReportedValue = cachedLimitReportedValue
        self.message = message
        self.lastWriteMessage = lastWriteMessage
        self.powerPercentReadOnlyState = powerPercentReadOnlyState
        self.voltageOffsetReadOnlyState = voltageOffsetReadOnlyState
    }
}

struct PowerPercentReadOnlyState: Codable, Equatable {
    struct Capabilities: Codable, Equatable {
        let capabilityFlags: UInt32
        let supportedStates: UInt32
        let powerControlMinimumPercent: Int32
        let powerControlMaximumPercent: Int32
        let powerControlStepPercent: Int32

        var reportsPowerControl: Bool { capabilityFlags & 0x08 != 0 }
        var reportsPercentAdjustment: Bool { capabilityFlags & 0x20 != 0 }
        var reportsPerformanceState: Bool { supportedStates & 0x01 != 0 }
        var permitsGuardedWrite: Bool {
            reportsPowerControl && reportsPercentAdjustment && reportsPerformanceState
        }
    }

    struct Parameters: Codable, Equatable {
        let minimumPercent: Int32
        let maximumPercent: Int32
        let defaultPercent: Int32
        let stepPercent: Int32
        let driverReportedTDP: UInt16
    }

    let parameters: Parameters?
    let parametersIOReturn: Int32
    let parametersMessage: String
    let capabilities: Capabilities?
    let capabilitiesIOReturn: Int32
    let capabilitiesMessage: String
    let cachedPercent: Int32?
    let settingIOReturn: Int32
    let settingMessage: String

    var isGuardedWriteAvailable: Bool {
        guard let parameters, let capabilities else { return false }
        return capabilities.permitsGuardedWrite
            && parameters.driverReportedTDP > 0
            && parameters.minimumPercent <= 0
            && parameters.maximumPercent >= 0
            && parameters.minimumPercent < parameters.maximumPercent
            && parameters.stepPercent > 0
            && capabilities.powerControlMinimumPercent == parameters.minimumPercent
            && capabilities.powerControlMaximumPercent == parameters.maximumPercent
            && capabilities.powerControlStepPercent == parameters.stepPercent
    }

    var effectiveMinimumPercent: Int32? {
        parameters?.minimumPercent
    }

    var effectiveMaximumPercent: Int32? {
        parameters?.maximumPercent
    }
}

struct PackagePowerLimitApplyResult {
    let state: PackagePowerControlState?
    let message: String
    let writeIOReturn: Int32?
}

struct VoltageOffsetReadOnlyState: Codable, Equatable {
    struct Parameters: Codable, Equatable {
        let minimumRaw: Int32
        let maximumRaw: Int32
        let stepRaw: Int32
        let defaultRaw: Int32
        let extensionMaskRaw: Int32
    }

    struct CachedSetting: Codable, Equatable {
        let increaseVoltage: Bool
        let valueRaw: Int32
    }

    let parameters: Parameters?
    let parametersIOReturn: Int32
    let parametersMessage: String
    let cachedSetting: CachedSetting?
    let settingIOReturn: Int32
    let settingMessage: String
}

/// Private Apple AMD user-client bridge verified against the macOS 15.5
/// AMDFramebuffer/AMDHWLibs binaries. AtiAppServices is attached below each
/// framebuffer branch, while AMD9500Controller is a sibling under the GPU
/// node; therefore discovery is constrained by the confirmed live GFX0 path.
/// The lexicographically first endpoint is used for CWDDE. The package-power
/// setter is restricted to 50...75 W; the live test points were 50, 60, and
/// 75 W. Its cached-value response is never presented as an SMU cap readback.
enum AMDPackagePowerControlService {
    private static let userClientType: UInt32 = 0x81
    private static let openSelector: UInt32 = 0
    private static let closeSelector: UInt32 = 1
    private static let cwddeSelector: UInt32 = 2

    /// Fixed getter allowlist. No caller-supplied command reaches selector 2.
    private enum ReadOnlyCWDDECommand: UInt32 {
        case getPowerControlSetting = 0x46
        case getPowerControlParametersV2 = 0x6d
        case getOD6CapabilitiesEx = 0x54
        case getVoltageControlParameters = 0x4f
        case getVoltageControlSetting = 0x50
        case getLastSetPackagePowerLimit = 0x96

        var outputByteCount: Int {
            switch self {
            case .getPowerControlSetting: return 12
            case .getPowerControlParametersV2: return 24
            case .getOD6CapabilitiesEx: return 64
            case .getVoltageControlParameters: return 24
            case .getVoltageControlSetting: return 16
            case .getLastSetPackagePowerLimit: return 8
            }
        }
    }

    private struct CWDDEReadResponse {
        let result: kern_return_t
        let bytes: [UInt8]
        let outputByteCount: Int
    }

    private struct Endpoint {
        let service: io_service_t
        let path: String
        let controllerPath: String?
    }

    static func readState(targetGPURegistryPath: String?) -> PackagePowerControlState {
        guard let targetGPURegistryPath else {
            return PackagePowerControlState(
                serviceCount: 0,
                servicePath: nil,
                controllerPath: nil,
                targetGPUPath: nil,
                cachedLimitReportedValue: nil,
                message: "没有唯一的 AMD 图形驱动节点可用于关联功耗服务；保持只读，不枚举写入目标。"
            )
        }

        let endpoints = matchingEndpoints(targetGPURegistryPath: targetGPURegistryPath)
        guard let endpoint = endpoints.first else {
            return PackagePowerControlState(
                serviceCount: 0,
                servicePath: nil,
                controllerPath: nil,
                targetGPUPath: targetGPURegistryPath,
                cachedLimitReportedValue: nil,
                message: "目标 GPU 子树下没有 AtiAppServices；当前启动没有开放与目标显卡关联的 Apple AMD 调节 user-client。"
            )
        }
        defer { endpoints.forEach { IOObjectRelease($0.service) } }
        let endpointCount = endpoints.count

        var connection: io_connect_t = 0
        let openResult = IOServiceOpen(endpoint.service, mach_task_self_, userClientType, &connection)
        guard openResult == KERN_SUCCESS else {
            return PackagePowerControlState(
                serviceCount: endpointCount,
                servicePath: endpoint.path,
                controllerPath: endpoint.controllerPath,
                targetGPUPath: targetGPURegistryPath,
                cachedLimitReportedValue: nil,
                message: "AtiAppServices 存在，但打开 user-client type 0x81 失败（IOReturn 0x\(String(openResult, radix: 16))）。"
            )
        }
        defer { closeConnection(connection) }

        let userOpenResult = callScalar(connection, selector: openSelector)
        guard userOpenResult == KERN_SUCCESS else {
            return PackagePowerControlState(
                serviceCount: endpointCount,
                servicePath: endpoint.path,
                controllerPath: endpoint.controllerPath,
                targetGPUPath: targetGPURegistryPath,
                cachedLimitReportedValue: nil,
                message: "user-client 已连接，但 AMD open selector 0 失败（IOReturn 0x\(String(userOpenResult, radix: 16))）。"
            )
        }
        defer { _ = callScalar(connection, selector: closeSelector) }

        let (readResult, reportedValue) = readLastSetLimitResponse(connection)
        let powerPercentState = readPowerPercentState(connection)
        let voltageOffsetState = readVoltageOffsetState(connection)
        switch (readResult, reportedValue) {
        case (KERN_SUCCESS, let reportedValue?):
            return PackagePowerControlState(
                serviceCount: endpointCount,
                servicePath: endpoint.path,
                controllerPath: endpoint.controllerPath,
                targetGPUPath: targetGPURegistryPath,
                cachedLimitReportedValue: reportedValue,
                message: "功耗接口已连接。目标 GPU 下有 \(endpointCount) 个按 framebuffer 分支创建的 AtiAppServices；本程序按路径选择第一项。0x96 返回驱动 last-set 软件缓存值，不是 SMU 上限读回。滑杆范围为 50–75 W；负载对照点为 50、60、75 W。其他功率/电压 getter 仍未闭合。",
                powerPercentReadOnlyState: powerPercentState,
                voltageOffsetReadOnlyState: voltageOffsetState
            )
        default:
            return PackagePowerControlState(
                serviceCount: endpointCount,
                servicePath: endpoint.path,
                controllerPath: endpoint.controllerPath,
                targetGPUPath: targetGPURegistryPath,
                cachedLimitReportedValue: nil,
                message: "已连接 AMD user-client，但 CWDDE 0x96 只读缓存查询失败（IOReturn 0x\(String(readResult, radix: 16))）。目标 GPU 下共找到 \(endpointCount) 个 framebuffer endpoint。",
                powerPercentReadOnlyState: powerPercentState,
                voltageOffsetReadOnlyState: voltageOffsetState
            )
        }
    }

    static func applyPackagePowerLimit(
        targetGPURegistryPath: String?,
        watts: Int
    ) -> PackagePowerLimitApplyResult {
        guard let targetGPURegistryPath else {
            return PackagePowerLimitApplyResult(state: nil, message: "没有唯一目标 GPU 节点；没有发送写入。", writeIOReturn: nil)
        }
        guard (50...75).contains(watts) else {
            return PackagePowerLimitApplyResult(
                state: readState(targetGPURegistryPath: targetGPURegistryPath),
                message: "仅开放 50–75 W 限定范围（负载实测点：50、60、75 W）；没有发送写入。",
                writeIOReturn: nil
            )
        }

        let endpoints = matchingEndpoints(targetGPURegistryPath: targetGPURegistryPath)
        defer { endpoints.forEach { IOObjectRelease($0.service) } }
        guard let endpoint = endpoints.first else {
            let count = endpoints.count
            return PackagePowerLimitApplyResult(
                state: readState(
                    targetGPURegistryPath: targetGPURegistryPath
                ),
                message: count == 0 ? "目标 GPU 子树下没有 AtiAppServices；没有发送写入。" : "目标 GPU 子树下没有可用 AtiAppServices endpoint；没有发送写入。",
                writeIOReturn: nil
            )
        }

        var connection: io_connect_t = 0
        let openResult = IOServiceOpen(endpoint.service, mach_task_self_, userClientType, &connection)
        guard openResult == KERN_SUCCESS else {
            return PackagePowerLimitApplyResult(
                state: readState(
                    targetGPURegistryPath: targetGPURegistryPath
                ),
                message: "打开目标 AMD user-client 失败（IOReturn 0x\(String(openResult, radix: 16))）；没有发送写入。",
                writeIOReturn: openResult
            )
        }
        defer { closeConnection(connection) }

        let userOpenResult = callScalar(connection, selector: openSelector)
        guard userOpenResult == KERN_SUCCESS else {
            return PackagePowerLimitApplyResult(
                state: readState(
                    targetGPURegistryPath: targetGPURegistryPath
                ),
                message: "AMD open selector 0 失败（IOReturn 0x\(String(userOpenResult, radix: 16))）；没有发送写入。",
                writeIOReturn: userOpenResult
            )
        }
        defer { _ = callScalar(connection, selector: closeSelector) }

        let (beforeResult, beforeLimit) = readLastSetLimitResponse(connection)
        guard beforeResult == KERN_SUCCESS, beforeLimit != nil else {
            return PackagePowerLimitApplyResult(
                state: readState(targetGPURegistryPath: targetGPURegistryPath),
                message: "无法读取 0x96 当前 last-set 缓存；为避免盲写，本次没有发送功耗设置。",
                writeIOReturn: beforeResult
            )
        }

        let writeResult = callSetPackagePowerLimit(connection, watts: watts)
        let (afterResult, afterLimit) = readLastSetLimitResponse(connection)
        let message: String
        if writeResult != KERN_SUCCESS {
            message = "CWDDE 0x6e 写入失败（IOReturn 0x\(String(UInt32(bitPattern: writeResult), radix: 16))）。"
        } else if afterResult == KERN_SUCCESS, afterLimit == watts {
            message = "已向 AMD 驱动发送 \(watts) W；0x96 last-set 缓存读回 \(watts) W。缓存不是 SMU 上限读回，实时功耗请看本页遥测；本机已在 GPU 负载下验证 50 W 设置会降低功耗。"
        } else {
            message = "CWDDE 0x6e 已返回，但 0x96 缓存读回为 \(afterLimit.map(String.init) ?? "未读到") W；没有把它当作硬件上限确认。"
        }
        let percentState = readPowerPercentState(connection)
        let updatedState = PackagePowerControlState(
            serviceCount: endpoints.count,
            servicePath: endpoint.path,
            controllerPath: endpoint.controllerPath,
            targetGPUPath: targetGPURegistryPath,
            cachedLimitReportedValue: afterResult == KERN_SUCCESS ? afterLimit : nil,
            message: "CWDDE 0x6e package-power 写入通道已通过本机负载对照；0x96 仍只表示驱动缓存。",
            lastWriteMessage: message,
            powerPercentReadOnlyState: percentState,
            voltageOffsetReadOnlyState: readVoltageOffsetState(connection)
        )
        return PackagePowerLimitApplyResult(
            state: updatedState,
            message: message,
            writeIOReturn: writeResult
        )
    }

    private static func callSetPackagePowerLimit(
        _ connection: io_connect_t,
        watts: Int
    ) -> kern_return_t {
        // CWDDE outer header (16 B) plus an 8-byte SetPackagePowerLimit
        // payload: inner size dword at +16 and integer watts at +20.
        var input = [UInt8](repeating: 0, count: 24)
        writeUInt32(24, into: &input, at: 0)
        writeUInt32(0x6e, into: &input, at: 4)
        writeUInt32(8, into: &input, at: 16)
        writeUInt32(UInt32(watts), into: &input, at: 20)
        var outputSize = 0
        return input.withUnsafeBufferPointer { inputBuffer in
            IOConnectCallStructMethod(
                connection,
                cwddeSelector,
                inputBuffer.baseAddress.map(UnsafeRawPointer.init),
                inputBuffer.count,
                nil,
                &outputSize
            )
        }
    }

    private static func matchingEndpoints(targetGPURegistryPath: String) -> [Endpoint] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("AtiAppServices"),
            &iterator
        ) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        let controllerPath = matchingControllerPath(targetGPURegistryPath: targetGPURegistryPath)
        var endpoints: [Endpoint] = []
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            guard let servicePath = path(for: service),
                  isSameOrDescendant(servicePath, of: targetGPURegistryPath),
                  servicePath != targetGPURegistryPath else {
                IOObjectRelease(service)
                continue
            }
            endpoints.append(Endpoint(service: service, path: servicePath, controllerPath: controllerPath))
        }
        return endpoints.sorted { $0.path < $1.path }
    }

    private static func matchingControllerPath(targetGPURegistryPath: String) -> String? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("AMD9500Controller"),
            &iterator
        ) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { return nil }
            defer { IOObjectRelease(service) }
            guard let servicePath = path(for: service),
                  isSameOrDescendant(servicePath, of: targetGPURegistryPath),
                  servicePath != targetGPURegistryPath else { continue }
            return servicePath
        }
    }

    private static func isSameOrDescendant(_ candidatePath: String, of targetPath: String) -> Bool {
        candidatePath == targetPath || candidatePath.hasPrefix(targetPath + "/")
    }

    private static func path(for entry: io_registry_entry_t) -> String? {
        var bytes = [CChar](repeating: 0, count: 1024)
        let result = bytes.withUnsafeMutableBufferPointer { buffer in
            IORegistryEntryGetPath(entry, kIOServicePlane, buffer.baseAddress!)
        }
        guard result == KERN_SUCCESS else { return nil }
        return String(cString: bytes)
    }

    private static func callScalar(_ connection: io_connect_t, selector: UInt32) -> kern_return_t {
        var outputCount: UInt32 = 0
        return IOConnectCallScalarMethod(connection, selector, nil, 0, nil, &outputCount)
    }

    private static func closeConnection(_ connection: io_connect_t) {
        IOServiceClose(connection)
    }

    private static func readLastSetLimitResponse(_ connection: io_connect_t) -> (kern_return_t, Int?) {
        let response = callReadOnlyCWDDE(connection, command: .getLastSetPackagePowerLimit)
        guard response.result == KERN_SUCCESS else { return (response.result, nil) }
        // On the live macOS 15.5 client the 8-byte response is
        // [zero/reserved dword, cached package-power value]. The first dword
        // is not a response length: treating it as one discarded valid data.
        guard response.outputByteCount == 8,
              readUInt32(response.bytes, at: 0) == 0 else { return (kIOReturnUnderrun, nil) }
        return (KERN_SUCCESS, Int(readUInt32(response.bytes, at: 4)))
    }

    private static func readVoltageOffsetState(_ connection: io_connect_t) -> VoltageOffsetReadOnlyState {
        let parametersResponse = callReadOnlyCWDDE(connection, command: .getVoltageControlParameters)
        let parameters: VoltageOffsetReadOnlyState.Parameters?
        let parametersMessage: String
        if parametersResponse.result != KERN_SUCCESS {
            parameters = nil
            parametersMessage = "0x4f 查询失败：IOReturn 0x\(String(UInt32(bitPattern: parametersResponse.result), radix: 16))。"
        } else if parametersResponse.outputByteCount != 24
                    || readUInt32(parametersResponse.bytes, at: 0) != 24 {
            parameters = nil
            parametersMessage = "0x4f 响应长度或结构头不匹配，未解析。"
        } else {
            parameters = VoltageOffsetReadOnlyState.Parameters(
                minimumRaw: readInt32(parametersResponse.bytes, at: 4),
                maximumRaw: readInt32(parametersResponse.bytes, at: 8),
                stepRaw: readInt32(parametersResponse.bytes, at: 12),
                defaultRaw: readInt32(parametersResponse.bytes, at: 16),
                extensionMaskRaw: readInt32(parametersResponse.bytes, at: 20)
            )
            parametersMessage = "0x4f 只读范围响应成功；保留驱动原始值，不推断单位。"
        }

        let settingResponse = callReadOnlyCWDDE(connection, command: .getVoltageControlSetting)
        let cachedSetting: VoltageOffsetReadOnlyState.CachedSetting?
        let settingMessage: String
        if settingResponse.result != KERN_SUCCESS {
            cachedSetting = nil
            settingMessage = "0x50 查询失败：IOReturn 0x\(String(UInt32(bitPattern: settingResponse.result), radix: 16))。"
        } else if settingResponse.outputByteCount != 16
                    || readUInt32(settingResponse.bytes, at: 0) != 12 {
            cachedSetting = nil
            settingMessage = "0x50 响应长度或结构头不匹配，未解析。"
        } else {
            cachedSetting = VoltageOffsetReadOnlyState.CachedSetting(
                increaseVoltage: readInt32(settingResponse.bytes, at: 4) != 0,
                valueRaw: readInt32(settingResponse.bytes, at: 8)
            )
            settingMessage = "0x50 只读驱动缓存成功；它不是 SMU 实际电压偏移回读。"
        }

        return VoltageOffsetReadOnlyState(
            parameters: parameters,
            parametersIOReturn: parametersResponse.result,
            parametersMessage: parametersMessage,
            cachedSetting: cachedSetting,
            settingIOReturn: settingResponse.result,
            settingMessage: settingMessage
        )
    }

    private static func readPowerPercentState(_ connection: io_connect_t) -> PowerPercentReadOnlyState {
        let parametersResponse = callReadOnlyCWDDE(connection, command: .getPowerControlParametersV2)
        let parameters: PowerPercentReadOnlyState.Parameters?
        let parametersMessage: String
        if parametersResponse.result != KERN_SUCCESS {
            parameters = nil
            parametersMessage = "0x6d 查询失败：IOReturn 0x\(String(UInt32(bitPattern: parametersResponse.result), radix: 16))。"
        } else if parametersResponse.outputByteCount != 24
                    || readUInt32(parametersResponse.bytes, at: 0) != 24 {
            parameters = nil
            parametersMessage = "0x6d 响应长度或结构头不匹配，未解析。"
        } else {
            parameters = PowerPercentReadOnlyState.Parameters(
                minimumPercent: readInt32(parametersResponse.bytes, at: 4),
                maximumPercent: readInt32(parametersResponse.bytes, at: 8),
                defaultPercent: readInt32(parametersResponse.bytes, at: 12),
                stepPercent: readInt32(parametersResponse.bytes, at: 16),
                driverReportedTDP: readUInt16(parametersResponse.bytes, at: 20)
            )
            parametersMessage = "0x6d 驱动报告的百分比调节范围和 PowerPlay TDP；不是 SMU 实际限值读回。"
        }

        let capabilitiesResponse = callReadOnlyCWDDE(connection, command: .getOD6CapabilitiesEx)
        let capabilities: PowerPercentReadOnlyState.Capabilities?
        let capabilitiesMessage: String
        if capabilitiesResponse.result != KERN_SUCCESS {
            capabilities = nil
            capabilitiesMessage = "0x54 能力查询失败：IOReturn 0x\(String(UInt32(bitPattern: capabilitiesResponse.result), radix: 16))；OD6 百分比写入 0x47 保持禁用。瓦数控制使用独立的 0x6e 通道。"
        } else if capabilitiesResponse.outputByteCount != 64
                    || readUInt32(capabilitiesResponse.bytes, at: 0) != 64 {
            capabilities = nil
            capabilitiesMessage = "0x54 响应长度或结构头不匹配；OD6 百分比写入 0x47 保持禁用。瓦数控制使用独立的 0x6e 通道。"
        } else {
            capabilities = PowerPercentReadOnlyState.Capabilities(
                capabilityFlags: readUInt32(capabilitiesResponse.bytes, at: 4),
                supportedStates: readUInt32(capabilitiesResponse.bytes, at: 8),
                powerControlMinimumPercent: readInt32(capabilitiesResponse.bytes, at: 44),
                powerControlMaximumPercent: readInt32(capabilitiesResponse.bytes, at: 48),
                powerControlStepPercent: readInt32(capabilitiesResponse.bytes, at: 52)
            )
            capabilitiesMessage = "0x54 返回 OD6 capability/state 和功率百分比范围；其范围需与 0x6d 一致。"
        }

        let settingResponse = callReadOnlyCWDDE(connection, command: .getPowerControlSetting)
        let cachedPercent: Int32?
        let settingMessage: String
        if settingResponse.result != KERN_SUCCESS {
            cachedPercent = nil
            settingMessage = "0x46 查询失败：IOReturn 0x\(String(UInt32(bitPattern: settingResponse.result), radix: 16))。"
        } else if settingResponse.outputByteCount != 12
                    || readUInt32(settingResponse.bytes, at: 0) != 12 {
            cachedPercent = nil
            settingMessage = "0x46 响应长度或结构头不匹配，未解析。"
        } else {
            cachedPercent = readInt32(settingResponse.bytes, at: 4)
            settingMessage = "0x46 为驱动缓存的百分比调节值，不是硬件当前功率限制读回。"
        }

        return PowerPercentReadOnlyState(
            parameters: parameters,
            parametersIOReturn: parametersResponse.result,
            parametersMessage: parametersMessage,
            capabilities: capabilities,
            capabilitiesIOReturn: capabilitiesResponse.result,
            capabilitiesMessage: capabilitiesMessage,
            cachedPercent: cachedPercent,
            settingIOReturn: settingResponse.result,
            settingMessage: settingMessage
        )
    }

    private static func callReadOnlyCWDDE(
        _ connection: io_connect_t,
        command: ReadOnlyCWDDECommand
    ) -> CWDDEReadResponse {
        // Selector 2 can dispatch setters. Only the fixed getter enum above is
        // accepted here, and each request has an empty payload.
        var input = [UInt8](repeating: 0, count: 16)
        writeUInt32(UInt32(input.count), into: &input, at: 0)
        writeUInt32(command.rawValue, into: &input, at: 4)
        var output = [UInt8](repeating: 0, count: command.outputByteCount)
        writeUInt32(UInt32(output.count), into: &output, at: 0)
        var outputSize = output.count
        let result = input.withUnsafeBufferPointer { inputBuffer in
            output.withUnsafeMutableBufferPointer { outputBuffer in
                IOConnectCallStructMethod(
                    connection,
                    cwddeSelector,
                    inputBuffer.baseAddress.map(UnsafeRawPointer.init),
                    inputBuffer.count,
                    outputBuffer.baseAddress.map(UnsafeMutableRawPointer.init),
                    &outputSize
                )
            }
        }
        return CWDDEReadResponse(result: result, bytes: output, outputByteCount: outputSize)
    }

    private static func readUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }

    private static func readInt32(_ bytes: [UInt8], at offset: Int) -> Int32 {
        Int32(bitPattern: readUInt32(bytes, at: offset))
    }

    private static func readUInt16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private static func writeUInt32(_ value: UInt32, into bytes: inout [UInt8], at offset: Int) {
        bytes[offset] = UInt8(truncatingIfNeeded: value)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
        bytes[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
        bytes[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
    }
}
