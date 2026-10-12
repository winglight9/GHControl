import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var model: GHControlModel

    private let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeading(
                    eyebrow: "RADEON GPU · 本机诊断",
                    title: "概览",
                    subtitle: model.snapshot?.scanMessage ?? (model.isRefreshing ? "正在通过 IOKit 读取 PCI 设备与驱动服务…" : "尚未读取本机硬件信息。")
                )

                HStack(spacing: 10) {
                    Button {
                        model.refresh()
                    } label: {
                        Label(model.isRefreshing ? "扫描中…" : "重新扫描", systemImage: "arrow.clockwise")
                    }
                    .disabled(model.isRefreshing)

                    if let capturedAt = model.snapshot?.capturedAt {
                        Spacer()
                        Text("读取于 \(capturedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                DeviceCard(device: model.snapshot?.primaryAMDDriverNode, isScanned: model.snapshot != nil)

                let device = model.snapshot?.primaryAMDDriverNode
                LazyVGrid(columns: columns, spacing: 14) {
                    EvidenceCard(title: "驱动公开 ROM 声明 ID", value: device?.vbiosPCIIdentity?.pciID ?? scanPlaceholder, symbol: "cpu")
                    EvidenceCard(title: "Registry compatible 注入线索", value: device?.registryCompatibleDeviceID.map { "1002:\($0)" } ?? scanPlaceholder, symbol: "point.3.connected.trianglepath.dotted")
                    EvidenceCard(title: "Registry device-id 注入线索", value: device?.registryDeviceID ?? scanPlaceholder, symbol: "cpu.fill")
                    EvidenceCard(title: "Registry 子系统线索", value: device.map(subsystemLabel) ?? scanPlaceholder, symbol: "memorychip")
                    EvidenceCard(title: "AMD9500 驱动服务", value: device.map { "\($0.driverServices.count) 项" } ?? scanPlaceholder, symbol: "point.3.connected.trianglepath.dotted")
                }

                HStack(alignment: .top, spacing: 16) {
                    PowerPlayEvidenceCard(properties: device?.powerPlayProperties ?? [:])
                        .frame(maxWidth: .infinity)
                    GPUTelemetryCard(telemetry: model.telemetry)
                        .frame(maxWidth: .infinity)
                }

                SafetyNotice(device: device, snapshot: model.snapshot)
            }
            .padding(28)
            .frame(maxWidth: 1180, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private func subsystemLabel(_ device: GPUDeviceEvidence?) -> String {
        guard let device, let vendor = device.subsystemVendorID, let subsystem = device.subsystemID else { return "未读取" }
        return "\(vendor):\(subsystem)"
    }

    private var scanPlaceholder: String { model.snapshot == nil ? "扫描中" : "未识别" }
}

struct PageHeading: View {
    let eyebrow: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(eyebrow.uppercased())
                .font(.caption.weight(.semibold))
                .tracking(1.1)
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.system(size: 30, weight: .bold, design: .rounded))
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 2)
    }
}

private struct DeviceCard: View {
    let device: GPUDeviceEvidence?
    let isScanned: Bool

    var body: some View {
        HStack(spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 17)
                    .fill(LinearGradient(colors: [.blue.opacity(0.9), .indigo.opacity(0.78)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 66, height: 66)
            Image(systemName: "cpu.fill")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(deviceTitle)
                    .font(.title3.weight(.semibold))
                Text(device?.registryPath ?? "扫描本机 I/O Registry 后显示 GPU 节点路径")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
                Text(identityLine)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 20)

            VStack(alignment: .trailing, spacing: 7) {
                StatusPill(
                    title: device == nil ? (isScanned ? "目标型号由用户确认 · 节点未唯一定位" : "扫描中") : "目标型号由用户确认 · AMD 驱动节点已定位",
                    tint: .orange,
                    symbol: device == nil ? "questionmark.circle.fill" : "info.circle.fill"
                )
                Text(device?.hasSoftPowerPlayTable == true ? "候选节点可见 sPPT 属性" : (device?.powerPlayTable != nil ? "已解析驱动公开镜像" : (isScanned ? "Registry 未见 sPPT 属性" : "正在读取属性")))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        }
    }

    private var identityLine: String {
        guard let device else { return "RX Vega M GH 是用户确认的项目目标。当前 IOKit 中没有唯一最具体的 AMD graphics accelerator 节点；不会用注入 ID 推断硬件型号。" }
        let rom = device.vbiosPCIIdentity.map { "驱动 ROM 声明 \($0.pciID)（checksum \($0.checksumValid ? "通过" : "未通过")）" } ?? "驱动 ROM PCIR 未解析"
        let compatible = device.registryCompatibleDeviceID.map { "Registry compatible 1002:\($0)" } ?? "Registry compatible 未读取"
        let deviceID = device.registryDeviceID.map { "device-id \($0)" } ?? "device-id 未读取"
        return "项目目标 RX Vega M GH 由用户确认。运行时线索：\(rom)、\(compatible)、\(deviceID)；这些值可被 OpenCore/ACPI/ROM 注入或替换，不作为硬件身份依据。"
    }

    private var deviceTitle: String {
        if device != nil { return "Radeon RX Vega M GH · 用户确认的项目目标" }
        return isScanned ? "目标 Radeon RX Vega M GH · AMD 驱动节点未唯一定位" : "正在扫描 AMD 驱动节点"
    }
}

struct StatusPill: View {
    let title: String
    let tint: Color
    let symbol: String

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .foregroundStyle(tint)
            .background(tint.opacity(0.12), in: Capsule())
    }
}

private struct EvidenceCard: View {
    let title: String
    let value: String
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: symbol).foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 4) {
                Text(value)
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text(title).font(.callout.weight(.medium))
                Text("本机扫描结果")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.quaternary, lineWidth: 1) }
    }
}

private struct PowerPlayEvidenceCard: View {
    let properties: [String: String]

    private var visibleProperties: [(key: String, value: String)] {
        properties.map { (key: $0.key, value: $0.value) }
            .sorted { lhs, rhs in
                let lhsIsPolicy = lhs.key.hasSuffix(" · PP_WorkLoadPolicyMask")
                let rhsIsPolicy = rhs.key.hasSuffix(" · PP_WorkLoadPolicyMask")
                if lhsIsPolicy != rhsIsPolicy { return lhsIsPolicy }
                return lhs.key < rhs.key
            }
            .prefix(7)
            .map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("PowerPlay / DPM 属性")
                        .font(.headline)
                    Text("从 GPU 节点及其驱动子节点读取")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "doc.text.magnifyingglass").foregroundStyle(.blue)
            }

            if properties.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "doc.questionmark").font(.title2).foregroundStyle(.tertiary)
                    Text("未发现相关属性").font(.callout.weight(.medium))
                    Text("当前扫描范围内没有找到 PP_* 或 ATY 时钟属性。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, minHeight: 160)
            } else {
                ForEach(Array(visibleProperties.enumerated()), id: \.element.key) { index, item in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.key.components(separatedBy: " · ").last ?? item.key)
                            .font(.caption.weight(.semibold).monospaced())
                            .lineLimit(1)
                        Text(item.value)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if index != visibleProperties.count - 1 { Divider() }
                }
                if properties.keys.contains(where: { $0.hasSuffix(" · PP_WorkLoadPolicyMask") }) {
                    Text("WhateverGreen 将 0x04 映射为 PowerSaving workload；此处仅确认 Registry 值，未确认驱动已采用。")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                Text("可见属性不等于驱动实际采用或 GPU 已应用这些值。")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .padding(.top, 2)
            }
        }
        .padding(18)
        .background(.background, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.quaternary, lineWidth: 1) }
    }
}

private struct GPUTelemetryCard: View {
    let telemetry: GPUTelemetry?

    private let columns = [GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("GPU 实时状态").font(.headline)
                    Text(telemetry.map { "AMD 驱动 · 更新于 \($0.capturedAt.formatted(date: .omitted, time: .standard))" } ?? "等待 AMD 驱动提供 PerformanceStatistics")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "waveform.path").foregroundStyle(telemetry == nil ? Color.secondary : Color.blue)
            }

            if let telemetry {
                LazyVGrid(columns: columns, spacing: 12) {
                    TelemetryMetric(title: "GPU 功耗", value: formatted(telemetry.totalPowerW, unit: "W"), symbol: "bolt.fill")
                    TelemetryMetric(title: "温度", value: formatted(telemetry.temperatureC, unit: "°C"), symbol: "thermometer.medium")
                    TelemetryMetric(title: "核心频率", value: formatted(telemetry.coreClockMHz, unit: "MHz"), symbol: "cpu")
                    TelemetryMetric(title: "显存频率", value: formatted(telemetry.memoryClockMHz, unit: "MHz"), symbol: "memorychip")
                    TelemetryMetric(title: "GPU 活动", value: formatted(telemetry.gpuActivityPercent, unit: "%"), symbol: "chart.xyaxis.line")
                }
                Text("来源：AMDRadeonX4000 PerformanceStatistics。功耗为驱动报告值，不是外接电源计量。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "waveform.path").font(.title2).foregroundStyle(.tertiary)
                    Text("等待 GPU 遥测").font(.callout.weight(.medium))
                    Text("驱动未返回 PerformanceStatistics，或图形加速器尚未连接。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, minHeight: 188)
            }
        }
        .padding(18)
        .background(.background, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.quaternary, lineWidth: 1) }
    }

    private func formatted(_ value: Double?, unit: String) -> String {
        guard let value else { return "—" }
        return String(format: "%.0f %@", value, unit)
    }
}

private struct TelemetryMetric: View {
    let title: String
    let value: String
    let symbol: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.callout)
                .foregroundStyle(.blue)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(value).font(.title3.weight(.semibold).monospacedDigit())
                Text(title).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 66, alignment: .leading)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct SafetyNotice: View {
    let device: GPUDeviceEvidence?
    let snapshot: HardwareSnapshot?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "checkmark.shield.fill")
                .font(.title3)
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 4) {
                Text("运行时调节链路").font(.callout.weight(.semibold))
                Text(notice)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var notice: String {
        guard snapshot != nil else {
            return "应用目标型号是用户确认的 Radeon RX Vega M GH。驱动/Registry 报告值只用于定位运行时节点，不用于判定物理硬件。"
        }
        let identity = "物理目标 Radeon RX Vega M GH 由用户确认。"
        let node = device == nil ? "当前没有唯一最具体的 AMD graphics accelerator 节点。" : "当前最具体的 AMD graphics accelerator 节点路径为 \(device!.registryPath)；其 PCI ID、Registry 属性与驱动 ROM 均为可注入的运行时线索。"
        let table = device?.powerPlayTable.map { "驱动公开 ROM 镜像解析到 \($0.summary)；该镜像来源不能从 IOKit 单独验证。" } ?? "当前未能从唯一 AMD 驱动节点解析 PowerPlay 表。"
        return "\(identity) \(node) \(table) 遥测来自 AMD 驱动 PerformanceStatistics。当前版本没有功耗写入调用；AtiAppServices 与 0x96 缓存查询即使可用，也不能证明 SMU 已接受功耗上限。"
    }
}

