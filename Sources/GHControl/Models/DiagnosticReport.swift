import Foundation

struct DiagnosticReport: Codable {
    let generatedAt: Date
    let appVersion: String
    let hardwareSnapshot: HardwareSnapshot
    let gpuTelemetry: GPUTelemetry?
    let packagePowerControlState: PackagePowerControlState?
    let interpretation: String

    init(
        snapshot: HardwareSnapshot,
        telemetry: GPUTelemetry? = nil,
        packagePowerControlState: PackagePowerControlState? = nil
    ) {
        generatedAt = Date()
        appVersion = "0.7.1"
        hardwareSnapshot = snapshot
        gpuTelemetry = telemetry
        self.packagePowerControlState = packagePowerControlState
        let softTableEvidence = snapshot.primaryAMDDriverNode?.softPowerPlayTable
        let softTableStatus = softTableEvidence.map {
            "I/O Registry 中观察到 sPPT（\($0.summary)，SHA-256 \($0.sha256)）；这不证明 AMD 驱动已采用。"
        } ?? "运行中的 GPU 节点未观察到 sPPT 注入属性。"
        let agdcServices = snapshot.runtimePowerControl.graphicsDeviceControlServices
        let agdcStatus: String
        if agdcServices.isEmpty {
            agdcStatus = "目标 GPU 下未发现 AtiDeviceControl/AGDC user-client。"
        } else {
            agdcStatus = agdcServices.map { service in
                "目标 GPU 的 AtiDeviceControl 位于 \(service.registryPath)，IOUserClientClass=\(service.userClientClass ?? "未公布")；只尝试 IOServiceOpen(type 0)，返回 \(service.openReturnCodeHex)，没有调用 selector。"
            }.joined(separator: " ")
        }
        let runtimeStatus: String
        let writeStatus = packagePowerControlState?.lastWriteMessage.map {
            "本次 package-power 写入记录：\($0)"
        } ?? "报告生成时没有用户触发的 GPU 写入。"
        if snapshot.runtimePowerControl.hasAtiAppServices {
            runtimeStatus = "IORegistry 中有 AtiAppServices；应用通过 type 0x81 selector 2 调用 package-power setter 0x6e，当前仅开放本机负载验证过的 50–75 W。固定负载对照下 50 W 设置使驱动实时功耗读数中位数约从 67 W 降至 58 W。0x96 是 last-set 软件缓存，不是 SMU 上限读回；OD6 百分比与 VID offset 尚未开放。\(writeStatus) \(agdcStatus)"
        } else {
            runtimeStatus = "IORegistry 中没有 AtiAppServices；目标 GPU 下的 Radeon HWServices 子服务是否 attach 见 devices[].driverServices。当前没有 CWDDE 通道，因此未调用 0x6e。\(agdcStatus) selector 5 的策略索引路径仍未闭合，且没有确认的 SMU 生效上限读回。"
        }
        let identityStatus = snapshot.primaryAMDDriverNode.map { device in
            "物理目标 Radeon RX Vega M GH 由用户确认。当前最具体的 AMD graphics accelerator / PowerPlay 节点位于 \(device.registryPath)。该节点的 PCI/Registry 属性和 ATY,bin_image 都可能由 OpenCore、ACPI 或驱动路径注入/替换；仅用于描述当前驱动呈现，不用于确认实体硬件。"
        } ?? "物理目标 Radeon RX Vega M GH 由用户确认；当前没有唯一最具体的 AMD graphics accelerator / PowerPlay 节点，因此不使用 PCI ID、Registry model 或 ROM 字段反推实体硬件。"
        interpretation = telemetry == nil
            ? "\(identityStatus) PowerPlay 表从 AMD 驱动公开的 ATY,bin_image 镜像解析，不能据此确认实体卡 ROM 来源。\(softTableStatus) \(runtimeStatus) GPU PerformanceStatistics 在应用界面持续只读采集；报告生成时没有遥测快照。应用未修改 EFI，也未发起重启。"
            : "\(identityStatus) GPU PerformanceStatistics 是 AMD 驱动实时只读遥测；PowerPlay 表从 AMD 驱动公开的 ATY,bin_image 镜像解析，不能据此确认实体卡 ROM 来源。\(softTableStatus) \(runtimeStatus) 应用未修改 EFI，也未发起重启。"
    }

    static func writeLatest(
        snapshot: HardwareSnapshot,
        telemetry: GPUTelemetry? = nil,
        packagePowerControlState: PackagePowerControlState? = nil
    ) throws -> URL {
        let fileManager = FileManager.default
        let cacheRoot = try fileManager.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = cacheRoot.appendingPathComponent("GHControl", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let destination = directory.appendingPathComponent("LatestDiagnostic.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(DiagnosticReport(
            snapshot: snapshot,
            telemetry: telemetry,
            packagePowerControlState: packagePowerControlState
        )).write(to: destination, options: .atomic)
        return destination
    }
}
