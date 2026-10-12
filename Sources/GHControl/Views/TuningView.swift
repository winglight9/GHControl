import SwiftUI
import UniformTypeIdentifiers

enum TuningViewMode: Equatable {
    case control
    case advanced
}

struct TuningView: View {
    let mode: TuningViewMode

    init(mode: TuningViewMode = .advanced) {
        self.mode = mode
    }

    @EnvironmentObject private var model: GHControlModel
    @State private var selectedRuntimeLimitWatts = 65.0
    @State private var selectedLimitWatts = 70
    @State private var devicePath = PowerPlayPatchBuilder.defaultDevicePath
    @State private var exportMode: PowerPlayExportMode = .candidate
    @State private var isExporting = false
    @State private var exportMessage = ""
    @State private var isShowingExportMessage = false

    private var device: GPUDeviceEvidence? { model.snapshot?.primaryAMDDriverNode }
    private var table: PowerPlayTableEvidence? { device?.powerPlayTable }

    private var exportDocument: PowerPlayPlistDocument? {
        guard let table else { return nil }
        let limit = exportMode == .stock ? table.tdpWatts : selectedLimitWatts
        guard let tableData = try? table.tableData(powerLimitWatts: limit) else { return nil }
        return try? PowerPlayPlistDocument(tableData: tableData, devicePath: devicePath)
    }

    private var exportFilename: String {
        switch exportMode {
        case .candidate: "GHControl-VegaMGH-\(selectedLimitWatts)W-Candidate"
        case .stock: "GHControl-VegaMGH-ImageBaseline-PowerPlay-Restore"
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageHeading(
                    eyebrow: mode == .control ? "RADEON RX VEGA M GH · POWER CONTROL" : "RADEON RX VEGA M GH · DRIVER DIAGNOSTICS",
                    title: mode == .control ? "功耗调节" : "高级诊断",
                    subtitle: mode == .control ? "调整功耗上限并查看 AMD 驱动实时状态" : "详细驱动状态、只读诊断和启动配置候选"
                )

                if mode == .control {
                    livePackagePowerLimitCard
                    liveTelemetryCard
                    driverControlNotice
                    powerLimitGuideCard
                } else {
                    liveStatusCard
                    softPowerPlayStatusCard
                    runtimeControlStatusCard
                    powerPercentDiagnostics(model.packagePowerControlState?.powerPercentReadOnlyState)
                    voltageOffsetDiagnostics(model.packagePowerControlState?.voltageOffsetReadOnlyState)
                    if let table {
                        factoryTableCard(table)
                        candidateCard(table)
                    } else {
                        unavailableCard
                    }
                    implementationNotes
                }

            }
            .padding(28)
            .frame(maxWidth: 1000, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .fileExporter(
            isPresented: $isExporting,
            document: exportDocument,
            contentType: .propertyList,
            defaultFilename: exportFilename,
            onCompletion: { result in
                switch result {
                case .success(let url):
                    exportMessage = "已生成 OpenCore plist 片段：\(url.lastPathComponent)。它尚未写入 EFI，也尚未在驱动中验证。"
                case .failure(let error):
                    exportMessage = "导出失败：\(error.localizedDescription)"
                }
                isShowingExportMessage = true
            }
        )
        .alert("PowerPlay 配置文件", isPresented: $isShowingExportMessage) {
            Button("好", role: .cancel) {}
        } message: {
            Text(exportMessage)
        }
        .onAppear {
            if let cachedLimit = model.packagePowerControlState?.cachedLimitReportedValue,
               (50...75).contains(cachedLimit) {
                selectedRuntimeLimitWatts = Double(cachedLimit)
            }
            if let table, !table.supports70WCandidate {
                selectedLimitWatts = table.tdpWatts
            }
        }
        .onChange(of: model.packagePowerControlState?.cachedLimitReportedValue) { cachedLimit in
            if let cachedLimit, (50...75).contains(cachedLimit) {
                selectedRuntimeLimitWatts = Double(cachedLimit)
            }
        }
    }

    private var livePackagePowerLimitCard: some View {
        let state = model.packagePowerControlState
        let cachedValue = state?.cachedLimitReportedValue
        let canControl = (state?.serviceCount ?? 0) > 0 && cachedValue != nil
        let boundedSelection = min(max(selectedRuntimeLimitWatts, 50), 75)
        return VStack(alignment: .leading, spacing: 15) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "bolt.horizontal.circle.fill")
                    .font(.title2)
                    .foregroundStyle(canControl ? .green : .orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text("GPU 功耗上限")
                        .font(.headline)
                    Text("滑动设置高负载时的功耗目标；不需要重启")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                StatusPill(
                    title: canControl ? "运行时控制已连接" : "等待驱动连接",
                    tint: canControl ? .green : .orange,
                    symbol: canControl ? "checkmark.circle.fill" : "clock"
                )
            }

            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(Int(boundedSelection.rounded()))")
                        .font(.system(size: 58, weight: .bold, design: .rounded).monospacedDigit())
                    Text("当前设置 · W")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 5) {
                    Text("GPU 实时功耗")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(display(model.telemetry?.totalPowerW, suffix: " W"))
                        .font(.system(size: 27, weight: .semibold, design: .rounded).monospacedDigit())
                    Text(model.telemetry?.totalPowerW == nil ? "等待 AMD 驱动" : "AMD 驱动报告")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 5) {
                    Text("驱动记录")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(cachedValue.map { "\($0) W" } ?? "—")
                        .font(.system(size: 27, weight: .semibold, design: .rounded).monospacedDigit())
                    Text("不是硬件上限回读")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Slider(value: $selectedRuntimeLimitWatts, in: 50...75, step: 5)
                .disabled(!canControl || model.isApplyingPowerLimit)
                .controlSize(.large)

            HStack {
                ForEach([50, 55, 60, 65, 70, 75], id: \.self) { tick in
                    Text(tick == 50 || tick == 75 ? "\(tick) W" : "\(tick)")
                    if tick != 75 { Spacer(minLength: 0) }
                }
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Button(model.isApplyingPowerLimit ? "正在应用…" : "应用 \(Int(boundedSelection.rounded())) W") {
                    model.applyPackagePowerLimit(Int(boundedSelection.rounded()))
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canControl || model.isApplyingPowerLimit)

                Button("恢复 75 W") {
                    selectedRuntimeLimitWatts = 75
                    model.applyPackagePowerLimit(75)
                }
                .buttonStyle(.bordered)
                .disabled(!canControl || model.isApplyingPowerLimit)

                Spacer()
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("功耗目标不等于固定耗电值；降低功耗可能影响高负载性能。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("较低设置可能导致性能下降或卡顿；如有卡顿，请提高功耗上限。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Label(
                canControl ? "运行时功耗控制已连接" : "功耗控制尚不可用；请重新扫描查看连接状态",
                systemImage: canControl ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
            )
            .font(.callout.weight(.medium))
            .foregroundStyle(canControl ? .green : .yellow)
            if let writeMessage = model.powerWriteMessage ?? state?.lastWriteMessage {
                Text(writeMessage)
                    .font(.callout)
                    .foregroundStyle(writeMessage.contains("失败") ? .orange : .green)
                    .fixedSize(horizontal: false, vertical: true)
            }

        }
        .padding(24)
        .background(.background, in: RoundedRectangle(cornerRadius: 20))
        .overlay { RoundedRectangle(cornerRadius: 20).strokeBorder(.quaternary, lineWidth: 1) }
    }

    private var liveTelemetryCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("GPU 实时状态")
                    .font(.headline)
                Spacer()
                Text("AMD 驱动报告 · 实际值以采集为准")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                telemetryMetric(title: "GPU 温度", value: display(model.telemetry?.temperatureC, suffix: " °C"), symbol: "thermometer.medium")
                telemetryMetric(title: "核心频率", value: display(model.telemetry?.coreClockMHz, suffix: " MHz"), symbol: "cpu")
                telemetryMetric(title: "显存频率", value: display(model.telemetry?.memoryClockMHz, suffix: " MHz"), symbol: "memorychip")
            }
        }
        .padding(20)
        .background(.background, in: RoundedRectangle(cornerRadius: 18))
        .overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(.quaternary, lineWidth: 1) }
    }

    private func telemetryMetric(title: String, value: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: symbol)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 25, weight: .semibold, design: .rounded).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(model.telemetry == nil ? "等待驱动读取" : "实时只读值")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .leading)
        .padding(16)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
    }

    private var driverControlNotice: some View {
        HStack(spacing: 12) {
            Image(systemName: "info.circle.fill")
                .font(.title3)
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 4) {
                Text("AMD 驱动继续动态调节电压和频率")
                    .font(.callout.weight(.semibold))
                Text("本页只设置功耗上限，不提供手动电压曲线或频率曲线。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 16))
    }

    private var powerLimitGuideCard: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 14) {

            VStack(alignment: .leading, spacing: 6) {
                Text("微调建议")
                    .font(.subheadline.weight(.semibold))
                Text("先以 75 W 为对照，从 70 W 开始，每次下调 5 W。应用后用平时的视频或工作负载观察流畅度、实时功耗和温度；尽量用相同场景比较。70、65、55 W 等中间档位尚未逐档压力测试；滑杆最低为 50 W。如果出现掉帧或卡顿，就恢复 75 W，或往上加 5 W。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("它能做什么")
                    .font(.subheadline.weight(.semibold))
                Text("功耗限制是向 AMD 驱动请求 GPU 的 package power 上限，不是固定耗电值、电压值或风扇曲线。GPU 忙时它可能通过降低频率来减少功耗与发热，因此也可能牺牲性能；空闲时实际功耗本来就可能低于设置值。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("本机请求 50 W 的压力负载测试中，驱动报告的当前功耗约 58 W；所以旋钮数值不保证等于传感器读数，也不代表精确硬件上限读回。减少 GPU 热量可能间接减轻风扇升速，但整机风扇仍由系统固件控制。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            }
            .padding(.top, 10)
        } label: {
            Label("功耗限制是什么？怎么微调？", systemImage: "questionmark.circle.fill")
                .font(.headline)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 18))
    }

    @ViewBuilder
    private func powerPercentDiagnostics(_ state: PowerPercentReadOnlyState?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("功率限制百分比（OD6）")
                .font(.subheadline.weight(.semibold))
            if let state {
                if let parameters = state.parameters {
                    Text("0x6d 范围：\(parameters.minimumPercent)% … \(parameters.maximumPercent)% · 默认 \(parameters.defaultPercent)% · 步进 \(parameters.stepPercent)% · 驱动报告 TDP raw \(parameters.driverReportedTDP)")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
                Text(state.parametersMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let capabilities = state.capabilities {
                    Text("0x54 标志：0x\(String(capabilities.capabilityFlags, radix: 16)) · state 0x\(String(capabilities.supportedStates, radix: 16)) · power-control \(capabilities.reportsPowerControl ? "支持" : "未报告") · 百分比调节 \(capabilities.reportsPercentAdjustment ? "支持" : "未报告") · performance \(capabilities.reportsPerformanceState ? "支持" : "未报告")")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                    Text("0x54 功率范围：\(capabilities.powerControlMinimumPercent)% … \(capabilities.powerControlMaximumPercent)% · 步进 \(capabilities.powerControlStepPercent)%")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
                Text(state.capabilitiesMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let cachedPercent = state.cachedPercent {
                    Text("0x46 驱动缓存调节值：\(cachedPercent)%")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
                Text(state.settingMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let writeMessage = model.powerWriteMessage {
                    Text(writeMessage)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("当前启动未连接 AtiAppServices，尚未读取 0x6d 范围或 0x46 缓存。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("OD6 百分比命令 0x47 的 ABI/能力门槛尚未在本机打通，因此不提供百分比控件。当前可用的是独立的 package power limit 命令 0x6e（瓦数）；电压命令 0x51 仍只做只读诊断。")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func voltageOffsetDiagnostics(_ state: VoltageOffsetReadOnlyState?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("VID offset 驱动诊断 · 只读")
                .font(.subheadline.weight(.semibold))
            if let state {
                if let parameters = state.parameters {
                    Text("0x4f 原始范围：min \(parameters.minimumRaw) · max \(parameters.maximumRaw) · step \(parameters.stepRaw) · default \(parameters.defaultRaw) · mask \(parameters.extensionMaskRaw)")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
                Text(state.parametersMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let setting = state.cachedSetting {
                    Text("0x50 驱动缓存：\(setting.increaseVoltage ? "增加" : "降低")电压 · raw \(setting.valueRaw)")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
                Text(state.settingMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("当前启动未连接 AtiAppServices，尚未读取 0x4f 范围或 0x50 缓存。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("驱动返回的 raw 数值不代表 mV，也不证明 GPU 已采用该偏移；本应用没有发送 0x51 写入命令。")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
    }

    private var liveStatusCard: some View {
        HStack(spacing: 14) {
            Image(systemName: "waveform.path.ecg.rectangle")
                .font(.title2)
                .foregroundStyle(model.telemetry == nil ? Color.orange : Color.green)
            VStack(alignment: .leading, spacing: 4) {
                Text(model.telemetry == nil ? "等待驱动遥测" : "AMD 驱动遥测已连接")
                    .font(.callout.weight(.semibold))
                if let telemetry = model.telemetry {
                    Text("功耗 \(display(telemetry.totalPowerW, suffix: " W")) · 温度 \(display(telemetry.temperatureC, suffix: " °C")) · 核心 \(display(telemetry.coreClockMHz, suffix: " MHz")) · 显存 \(display(telemetry.memoryClockMHz, suffix: " MHz"))")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    Text("页面每 2 秒尝试读取 AMDRadeonX4000 的 PerformanceStatistics。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            StatusPill(
                title: model.telemetry == nil ? "未读到" : "只读实时值",
                tint: model.telemetry == nil ? .orange : .green,
                symbol: model.telemetry == nil ? "clock" : "checkmark.circle.fill"
            )
        }
        .padding(18)
        .background(.background, in: RoundedRectangle(cornerRadius: 18))
    }

    private var softPowerPlayStatusCard: some View {
        let injectedTable = device?.softPowerPlayTable
        let propertyDetected = device?.hasSoftPowerPlayTable == true
        let imageBaselineLimit = table.map { "\($0.tdpWatts) W" } ?? "未读取"
        return HStack(alignment: .top, spacing: 14) {
            Image(systemName: propertyDetected ? "info.circle.fill" : "exclamationmark.triangle.fill")
                .font(.title2)
                .foregroundStyle(Color.orange)
            VStack(alignment: .leading, spacing: 5) {
                    Text(propertyDetected ? "候选节点的 Registry 中可见 sPPT 属性" : "当前 Registry 未见 sPPT 属性")
                    .font(.callout.weight(.semibold))
                if let injectedTable {
                    Text("实读 \(injectedTable.summary) · SHA-256 \(injectedTable.sha256)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Text("这证明表已进入 I/O Registry；还需验证 AMD 驱动是否采用，以及负载下功耗是否受限。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if propertyDetected {
                    Text("发现同名属性，但格式无法按当前驱动公开镜像中的 PowerPlay v7.1 表解析。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("当前驱动公开镜像中的基准表声明为 \(imageBaselineLimit)。仅生成候选，不会改动正在运行的 GPU。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            StatusPill(
                title: propertyDetected ? "属性可见" : "尚未应用",
                tint: .orange,
                symbol: propertyDetected ? "info.circle.fill" : "clock"
            )
        }
        .padding(18)
        .background(.background, in: RoundedRectangle(cornerRadius: 18))
    }

    private var runtimeControlStatusCard: some View {
        let evidence = model.snapshot?.runtimePowerControl
        let exposed = evidence?.hasAtiAppServices == true
        let agdc = evidence?.graphicsDeviceControlServices.first
        let title: String
        let detail: String
        if let evidence {
            if exposed {
                title = "AMD 运行时功耗接口已连接"
                detail = "目标 GPU 子树中发现 \(evidence.atiAppServicesInstanceCount) 个 AtiAppServices 实例。应用通过 type 0x81 selector 2 调用 CWDDE 0x6e；本机负载对照显示 50 W 设置降低了驱动报告的实时功耗。"
            } else if let agdc {
                title = agdc.wasNotPermitted ? "发现 AGDC 管理服务，但应用无权打开" : "发现 AGDC 管理服务，user-client 尚不可用"
                let access = agdc.wasNotPermitted ? "系统返回 kIOReturnNotPermitted" : "打开结果为 \(agdc.openReturnCodeHex)"
                detail = "AtiDeviceControl 路径：\(agdc.registryPath) · user-client：\(agdc.userClientClass ?? "未公布") · IOServiceOpen(type 0)：\(agdc.openReturnCodeHex)。\(access)；没有调用其 selector。另有 \(evidence.disabledFramebufferCount) 个 AMDFramebuffer 节点显示 UserClientEnabled=No。"
            } else {
                title = "当前启动未暴露可用的 AMD 调节 user-client"
                detail = "AtiAppServices 实例数为 0，目标 GPU 下未发现 AtiDeviceControl；\(evidence.disabledFramebufferCount) 个 AMDFramebuffer 节点显示 UserClientEnabled=No。"
            }
        } else {
            title = "等待扫描 AMD runtime 接口"
            detail = "等待刷新 I/O Registry 中的 AtiAppServices 和 UserClientEnabled 状态。"
        }
        return HStack(alignment: .top, spacing: 14) {
            Image(systemName: exposed ? "bolt.circle.fill" : (agdc == nil ? "lock.fill" : "hand.raised.fill"))
                .font(.title2)
                .foregroundStyle(exposed ? Color.green : Color.orange)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.callout.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
                Text("已静态闭合并在本机负载下验证：type 0x81 selector 2 → CWDDE 0x6e → PHM → Polaris 22 setter → SMU 消息 0x187。驱动缓存读回不等于硬件上限读回；滑杆限定为 50–75 W，负载对照点为 50、60、75 W。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("若 bit 0x4 已置位，setter 会先更新 last-set 软件缓存再发消息；消息失败时缓存也可能改变。命令 0x96 只读缓存，不是 GPU 当前功耗上限的独立硬件读回。selector 5 是另一条未闭合路径，不能拿它的策略表索引当瓦数。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("type 0x81 selector 2 是 CWDDE 转发通道，既能读也能写。0x96 只读 last-set 软件缓存；本页实时功耗来自驱动遥测。0x7e/0x92 不能证明 SMU 当前生效上限。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("概览的 Total Power(W) 是驱动报告的实时功耗，不是功耗上限。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("当前正常启动下，目标 GPU 子树发现 6 个 AtiAppServices；程序使用排序第一项。0x6e 已在本机实测，50 W 设置下负载功耗读数约从 67 W 降至 58 W；0x96 返回的 75 W 仅是驱动缓存。OD6 百分比和电压偏移尚未开放。EFI 未修改。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            StatusPill(
                title: exposed ? "控制通道已连通" : "等待控制通道",
                tint: exposed ? .green : .orange,
                symbol: exposed ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
            )
        }
        .padding(18)
        .background(.background, in: RoundedRectangle(cornerRadius: 18))
    }

    private func factoryTableCard(_ table: PowerPlayTableEvidence) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("驱动公开镜像中的 PowerPlay 基准表")
                        .font(.headline)
                    Text("从最具体的 AMD graphics accelerator 节点暴露的 ATY,bin_image 读取；ROM 可被启动配置替换，只作为驱动呈现线索解析。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                StatusPill(title: "结构校验通过", tint: .green, symbol: "checkmark.seal.fill")
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                TableValue(title: "TDP", value: "\(table.tdpWatts) W")
                TableValue(title: "最大供电限制", value: "\(table.maximumPowerDeliveryLimitWatts) W")
                TableValue(title: "Boost 限制", value: "\(table.boostPowerLimitWatts) W")
                TableValue(title: "TDC", value: "\(table.tdcAmps) A")
                TableValue(title: "PowerControlLimit", value: "\(table.powerControlLimit) · 原样保留")
                TableValue(title: "温度上限", value: "\(table.tjMaxC) °C")
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("VBIOS \(table.vbiosByteCount) B · PowerPlay offset 0x\(String(table.tableOffset, radix: 16, uppercase: true))")
                Text("VBIOS SHA-256  \(table.vbiosSHA256)")
                Text("PowerPlay SHA-256  \(table.tableSHA256)")
            }
            .font(.caption2.monospaced())
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        }
        .padding(20)
        .background(.background, in: RoundedRectangle(cornerRadius: 20))
        .overlay { RoundedRectangle(cornerRadius: 20).strokeBorder(.quaternary, lineWidth: 1) }
    }

    private func candidateCard(_ table: PowerPlayTableEvidence) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("功耗上限候选", systemImage: "bolt.badge.clock")
                .font(.headline)

                Text("这个候选只改驱动公开 ROM 镜像表里的 TDP、Battery、Small、Maximum Delivery 和 Boost 字段至 70 W；TDC、电压曲线、频率表、温控阈值和其他字节保持原样。ROM 来源和驱动是否采用尚未验证。实时 50–75 W package power limit 控制见本页上方。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 0) {
                ForEach(Array(candidateChanges(for: table).enumerated()), id: \.offset) { index, change in
                    HStack {
                        Text(change.name).font(.callout)
                        Spacer()
                        Text("\(change.before) W").foregroundStyle(.secondary)
                        Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                        Text("\(change.after) W").fontWeight(.semibold).foregroundStyle(.blue)
                    }
                    .padding(.vertical, 9)
                    if index != candidateChanges(for: table).count - 1 { Divider() }
                }
            }
            .padding(.horizontal, 12)
            .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))

            HStack(spacing: 12) {
                Text("方案")
                    .font(.callout.weight(.medium))
                Picker("功耗方案", selection: $selectedLimitWatts) {
                    if table.supports70WCandidate {
                        Text("70 W · 降功耗候选").tag(70)
                    }
                        Text("\(table.tdpWatts) W · 镜像基准表").tag(table.tdpWatts)
                }
                .labelsHidden()
                .frame(width: 230)
                Spacer()
                Button {
                    exportMode = .candidate
                    isExporting = true
                } label: {
                    Label("生成 OpenCore plist", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedLimitWatts == 70 && !table.supports70WCandidate)
                Button {
                    exportMode = .stock
                    isExporting = true
                } label: {
                    Label("导出镜像基准回退表", systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(.bordered)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("OpenCore GPU 设备路径")
                    .font(.caption.weight(.semibold))
                TextField("PciRoot(...)", text: $devicePath)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption.monospaced())
                Text("从这台机器现存配置副本中读到的路径；导入当前 EFI 前，请先对照正在使用的 config.plist。导出文件只包含 DeviceProperties 合并片段。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Label("配置型控制，需要修改 OpenCore 配置并重启；本应用不会写当前 EFI，也不会自动重启。", systemImage: "restart")
                .font(.callout.weight(.medium))
                .foregroundStyle(.orange)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        }
        .padding(20)
        .background(.background, in: RoundedRectangle(cornerRadius: 20))
        .overlay { RoundedRectangle(cornerRadius: 20).strokeBorder(.quaternary, lineWidth: 1) }
    }

    private var implementationNotes: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("当前控制边界")
                .font(.headline)
            Label("本机负载对照验证了 0x6e 的 50 W 设置会降低驱动报告的实时功耗；当前安全开放范围为 50–75 W。", systemImage: "info.circle")
            Label("命令 0x96 只回报 last-set 软件缓存；若 SMU 消息失败，缓存仍可能变化。0x7e、0x92 也不是已证实的 SMU 生效上限读回。", systemImage: "lock.doc")
            Label("selector 5 是独立的策略表索引路径，其 SW-SMU 间接槽仍未解析；不把索引显示或解释成瓦数。", systemImage: "point.3.connected.trianglepath.dotted")
            Label("0x96 返回 last-set 软件缓存，不是硬件功耗上限读回。0x51 是 VID offset 候选 setter，但单位、运行时范围和 GH 固件效果未验证。", systemImage: "waveform.path.ecg")
            Label("本应用走 Apple 私有 type 0x81/CWDDE 接口；它不是稳定或公开的 macOS API，需逐台驱动验证。", systemImage: "lock.fill")
            Label("WEG 会剥掉 PP, 前缀并将 PP_PhmSoftPowerPlayTable 合入 aty_properties。当前节点没有该属性；驱动解析器存在不代表 67DF 匹配路径会采用这张表。", systemImage: "arrow.turn.down.right")
            Label("OpenCore 候选表是启动时注入，需重启后才可能加载；本应用不会改 EFI 或发起重启。", systemImage: "restart")
            Label("没有已验证的恢复启动路径前，不要把候选表写到唯一启动盘。", systemImage: "externaldrive.badge.exclamationmark")
            Label("50 W 是已验证控制值，但 GPU 瞬时功耗可能超过设置值；风扇策略由整机固件控制，应用不承诺风扇转速变化。", systemImage: "exclamationmark.triangle")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 18))
    }

    private var unavailableCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("尚未取得可解析的驱动公开 VBIOS 镜像", systemImage: "exclamationmark.triangle")
                .font(.headline)
                .foregroundStyle(.orange)
            Text("导出按钮保持关闭。物理目标型号 Radeon RX Vega M GH 由用户确认；应用只从驱动/Registry 线索匹配的节点读取 ATY,bin_image。黑苹果可能注入或替换这些属性，因此它们只用于定位驱动节点，不能作为实体卡身份的来源。")
                .font(.callout)
                .foregroundStyle(.secondary)
            if let device {
                Text("GPU 节点：\(device.registryPath)")
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 20))
    }

    private func display(_ value: Double?, suffix: String) -> String {
        guard let value else { return "—" }
        return String(format: "%.0f%@", value, suffix)
    }

    private func candidateChanges(for table: PowerPlayTableEvidence) -> [(name: String, before: Int, after: Int)] {
        [
            ("TDP", table.tdpWatts),
            ("BatteryPowerLimit", table.batteryPowerLimitWatts),
            ("SmallPowerLimit", table.smallPowerLimitWatts),
            ("MaximumPowerDeliveryLimit", table.maximumPowerDeliveryLimitWatts),
            ("BoostPowerLimit", table.boostPowerLimitWatts)
        ]
        .filter { $0.1 > selectedLimitWatts }
        .map { (name: $0.0, before: $0.1, after: selectedLimitWatts) }
    }
}

private struct TableValue: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(value)
                .font(.headline.monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
        .padding(12)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
    }
}

private enum PowerPlayExportMode {
    case candidate
    case stock
}

private enum PowerPlayPatchBuilder {
    static let defaultDevicePath = "PciRoot(0x0)/Pci(0x1,0x0)/Pci(0x0,0x0)"
    private static let propertyName = "PP,PP_PhmSoftPowerPlayTable"

    static func makePlist(tableData: Data, devicePath: String) throws -> Data {
        let path = devicePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("PciRoot("), path.contains("/Pci("), !path.contains("\n") else {
            throw PowerPlayPatchError.invalidDevicePath
        }
        let fragment: [String: Any] = [
            "DeviceProperties": [
                "Add": [
                    path: [propertyName: tableData]
                ]
            ]
        ]
        return try PropertyListSerialization.data(fromPropertyList: fragment, format: .xml, options: 0)
    }
}

private enum PowerPlayPatchError: LocalizedError {
    case invalidDevicePath

    var errorDescription: String? { "OpenCore 设备路径格式无效。" }
}

private struct PowerPlayPlistDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.propertyList] }
    let data: Data

    init(tableData: Data, devicePath: String) throws {
        data = try PowerPlayPatchBuilder.makePlist(tableData: tableData, devicePath: devicePath)
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
