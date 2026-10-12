import SwiftUI

struct DriverConnectionView: View {
    @EnvironmentObject private var model: GHControlModel

    private var device: GPUDeviceEvidence? { model.snapshot?.primaryAMDDriverNode }

    private var checks: [(String, String, String, Color, String, String)] {
        let device = self.device
        let registryCandidate = model.snapshot?.devices.first { $0.registryCompatibleDeviceID == "694C" }
        let pciText: String
        if let device {
            let subsystem = [device.subsystemVendorID, device.subsystemID].compactMap { $0 }.joined(separator: ":")
            let romID = device.vbiosPCIIdentity?.pciID ?? "未解析"
            let romChecksum = device.vbiosPCIIdentity?.checksumValid == true ? "校验通过" : "校验失败"
            let compatible = device.registryCompatibleDeviceID.map { "1002:\($0)" } ?? "未确认"
            pciText = "项目目标 Radeon RX Vega M GH 由用户确认。当前最具体的 AMD graphics accelerator / PowerPlay 节点路径为 \(device.registryPath)。驱动 ROM 声明 \(romID)（镜像 checksum \(romChecksum)），Registry compatible 为 \(compatible)，子系统 \(subsystem.isEmpty ? "未读取" : subsystem)，vendor-id \(device.vendorID ?? "未读取")，device-id \(device.registryDeviceID ?? "未读取")。这些值可被 OpenCore/ACPI 注入或 ROM 替换，不用于判断实体型号；没有读取原始 PCI config space。"
        } else if registryCandidate != nil {
            pciText = "项目目标 Radeon RX Vega M GH 由用户确认；当前没有唯一最具体的 AMD graphics accelerator / PowerPlay 节点。注入 ID 不用于补齐硬件或驱动身份。"
        } else {
            pciText = model.snapshot == nil ? "物理目标型号 Radeon RX Vega M GH 由用户确认；等待 IOKit 扫描对应驱动节点。" : "物理目标型号 Radeon RX Vega M GH 由用户确认；当前扫描没有建立对应的驱动呈现节点线索。"
        }

        let driverText: String
        if let services = device?.driverServices, !services.isEmpty {
            driverText = services.joined(separator: "\n")
        } else {
            driverText = "当前没有在目标 GPU 节点下识别到 AMD 或 IOAccelerator 子服务。"
        }

        let extensionText: String
        if let extensions = model.snapshot?.loadedExtensions, !extensions.isEmpty {
            extensionText = extensions.map { "\($0.bundleIdentifier)\($0.version.map { " · \($0)" } ?? "")" }.joined(separator: "\n")
        } else {
            extensionText = "未从 kmutil showloaded 输出中识别到匹配扩展。"
        }

        let propertyCount = device?.powerPlayProperties.count ?? 0
        let powerPlayText = device == nil ? "尚未扫描到目标 GPU。" : "在 GPU 服务节点及最多四层子节点中找到 \(propertyCount) 项 PP / ATY 时钟属性。"
        let hasPowerPlayHWService = device?.driverServices.contains {
            $0.localizedCaseInsensitiveContains("HWServices")
        } ?? false
        let runtimeEvidence = model.snapshot?.runtimePowerControl
        let runtimeText: String
        let runtimeStatus: String
        let runtimeColor: Color
        let agdc = runtimeEvidence?.graphicsDeviceControlServices.first
        if let runtimeEvidence, runtimeEvidence.hasAtiAppServices {
            runtimeText = "IORegistry 中有 \(runtimeEvidence.atiAppServicesInstanceCount) 个 AtiAppServices 实例。GH Control 已通过 type 0x81 selector 2 调用 CWDDE 0x6e；在同一 GPU 负载对照中，50 W 设置使 0x69 驱动功耗读数中位数约从 67 W 降至 58 W。0x96 仍只是 last-set 软件缓存，不是硬件上限读回。\(agdc.map { "目标 GPU 的 AtiDeviceControl user-client 打开结果：\($0.openReturnCodeHex)。" } ?? "目标 GPU 下未发现 AtiDeviceControl。")"
            runtimeStatus = "0x6e 已实测"
            runtimeColor = .green
        } else if let agdc {
            let accessText: String
            if agdc.openReturnCode == 0 {
                accessText = "IOServiceOpen(type 0) 成功；这只证明 client 可打开，尚未调用任何 selector，也未验证读取或写入。"
            } else if agdc.wasNotPermitted {
                accessText = "IOServiceOpen(type 0) 返回 \(agdc.openReturnCodeHex)（kIOReturnNotPermitted）；系统拒绝 GH Control 进程访问该私有 user-client。未调用 selector。"
            } else {
                accessText = "IOServiceOpen(type 0) 返回 \(agdc.openReturnCodeHex)；未调用 selector。"
            }
            runtimeText = "目标 GPU 的 AtiDeviceControl 位于 \(agdc.registryPath)，user-client 类为 \(agdc.userClientClass ?? "未公布")。\(accessText) 同时 AtiAppServices 数为 0，所以目前没有可用的 CWDDE package-watt 通道。"
            runtimeStatus = agdc.openReturnCode == 0 ? "AGDC 尚未验证" : (agdc.wasNotPermitted ? "AGDC 被系统拒绝" : "AGDC 打开失败")
            runtimeColor = .orange
        } else if let runtimeEvidence {
            let hwServiceText = hasPowerPlayHWService
                ? "目标 GPU 下已发现 Radeon HWServices 子服务，说明硬件服务已 attach；"
                : "目标 GPU 下尚未发现 Radeon HWServices 子服务；"
            runtimeText = "\(hwServiceText)AtiAppServices 实例数为 0，\(runtimeEvidence.disabledFramebufferCount) 个 AMDFramebuffer 节点报告 UserClientEnabled=No，目标 GPU 下也未发现 AtiDeviceControl。当前未发现可供应用打开的 AMD 调节 user-client。Linux VEGAM 上游支持将静态 CWDDE 命令 0x6e 参数解释为整数瓦数的 Q8 编码；但本机没有调用通道，ATY,intrev=80 不是已确认的 PPLIB ATI revision，命令 0x96 只读软件 last-set 缓存。"
            runtimeStatus = hasPowerPlayHWService ? "硬件服务已连接" : "未暴露"
            runtimeColor = .orange
        } else {
            runtimeText = "等待扫描 AtiAppServices 与 AMDFramebuffer 的 UserClientEnabled 属性。"
            runtimeStatus = "等待扫描"
            runtimeColor = .secondary
        }
        let tableText = device?.powerPlayTable.map { "已从驱动公开的 VBIOS 镜像解析 \($0.summary)，该镜像表声明 TDP \($0.tdpWatts) W；来源可能被替换。" } ?? "当前未能从驱动公开的 VBIOS 镜像解析完整 PowerPlay 表。"
        let softTableText: String
        if let softTable = device?.softPowerPlayTable {
            softTableText = "I/O Registry 实时读到 sPPT：\(softTable.summary)，SHA-256 \(softTable.sha256)。这只证明属性进入 GPU 节点，不证明驱动采用或实际功耗已改变。"
        } else if device?.hasSoftPowerPlayTable == true {
            softTableText = "发现 sPPT 同名属性，但无法按本机表结构解析。"
        } else {
            softTableText = "运行中的 GPU 节点没有 sPPT 属性；目前没有应用候选功耗表。"
        }

        return [
            ("用户确认目标与驱动节点", pciText, device == nil ? "目标已知 · 节点未唯一定位" : "目标已知 · 驱动栈已定位", .orange, "info.circle.fill", "RX Vega M GH 型号来自用户确认；系统 ID 只作运行时线索"),
            ("AMD 驱动服务", driverText, device?.driverServices.isEmpty == false ? "发现服务" : "未确认", device?.driverServices.isEmpty == false ? .green : .orange, device?.driverServices.isEmpty == false ? "checkmark.circle.fill" : "exclamationmark.circle.fill", "子服务存在不等于调节接口可用"),
            ("已加载扩展", extensionText, model.snapshot == nil ? "等待扫描" : "只读清单", .blue, "doc.text.magnifyingglass", "kext 出现在列表不等于补丁按预期执行"),
            ("PowerPlay / DPM", "\(powerPlayText) \(tableText) \(softTableText)", device?.powerPlayTable == nil ? "未解析" : (device?.hasSoftPowerPlayTable == true ? "候选属性可见" : "镜像表已解析"), .orange, "slider.horizontal.3", "表解析/属性可见不代表驱动采用候选值或改变功耗"),
            ("运行时调节接口", runtimeText, runtimeStatus, runtimeColor, "lock.fill", "HWServices 存在不等于 user-client 或 setter 已验证；没有发送 selector 或写请求"),
            ("遥测", model.telemetry.map { "驱动实时数据：功耗 \($0.totalPowerW.map { String(format: "%.0f W", $0) } ?? "—")、温度 \($0.temperatureC.map { String(format: "%.0f °C", $0) } ?? "—")、核心 \($0.coreClockMHz.map { String(format: "%.0f MHz", $0) } ?? "—")。" } ?? "等待 AMD 驱动返回 PerformanceStatistics。", model.telemetry == nil ? "等待中" : "实时只读", model.telemetry == nil ? .orange : .green, "waveform.path", "数据来自 AMD 驱动，不是外接功率计"),
            ("恢复启动路径", "当前内置 EFI 分区未挂载，OpenCore 的实际启动来源无法确证。工作区有完整 EFI 文件备份，但没有独立且已验证可启动的恢复介质。", "未验证", .orange, "externaldrive.badge.exclamationmark", "不对唯一 EFI 做启动实验")
        ]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeading(
                    eyebrow: "KERNEL LINK",
                    title: "驱动连接",
                    subtitle: model.snapshot == nil ? "读取本机 I/O Registry 和已加载扩展；扫描结果只说明链路证据。" : "最近扫描：\(model.snapshot!.macOSVersion) · \(model.snapshot!.capturedAt.formatted(date: .abbreviated, time: .shortened))"
                )

                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(checks.enumerated()), id: \.offset) { index, check in
                        HStack(alignment: .top, spacing: 14) {
                            ZStack {
                                Circle().fill(check.3.opacity(0.12))
                                Image(systemName: check.4)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(check.3)
                            }
                            .frame(width: 32, height: 32)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(check.0).font(.callout.weight(.semibold))
                                Text(check.1)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                            }
                            Spacer(minLength: 10)
                            VStack(alignment: .trailing, spacing: 3) {
                                Text(check.2).font(.caption.weight(.semibold)).foregroundStyle(check.3)
                                Text(check.5).font(.caption2).foregroundStyle(.tertiary).multilineTextAlignment(.trailing)
                            }
                            .frame(maxWidth: 150, alignment: .trailing)
                        }
                        .padding(.vertical, 15)
                        if index != checks.count - 1 { Divider().padding(.leading, 46) }
                    }
                }
                .padding(.horizontal, 18)
                .background(.background, in: RoundedRectangle(cornerRadius: 20))

                VStack(alignment: .leading, spacing: 10) {
                    Text("内核层原则").font(.headline)
                    PrincipleRow(symbol: "1.circle.fill", text: "本页把 VBIOS PCIR ID、Registry compatible、Registry device-id 分开显示；只有原始 PCI config-space 才能最终确认硬件寄存器身份。")
                    PrincipleRow(symbol: "2.circle.fill", text: "WhateverGreen 的 PP 属性属于启动注入线索；属性到达驱动不代表参数已采用。")
                    PrincipleRow(symbol: "3.circle.fill", text: "Polaris22Fixup 解决 Vega M / Polaris 22 的图形兼容问题，不是功耗控制器。")
                    PrincipleRow(symbol: "4.circle.fill", text: "没有 GH 专用表语义、驱动读回和实际状态变化证据时，不执行 PCI、MMIO 或 SMU 写入。")
                    PrincipleRow(symbol: "5.circle.fill", text: "后续启动配置实验必须保持当前 EFI 原样，并先具备可启动的独立恢复介质。")
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.background, in: RoundedRectangle(cornerRadius: 20))
            }
            .padding(28)
            .frame(maxWidth: 1000, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }
}

private struct PrincipleRow: View {
    let symbol: String
    let text: String

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 3)
    }
}
