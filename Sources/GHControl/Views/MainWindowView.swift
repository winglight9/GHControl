import AppKit
import SwiftUI

private enum MainDestination {
    case power
    case connection
}

private enum ConnectionDestination: String, CaseIterable, Identifiable {
    case overview
    case driver
    case advanced
    case profiles

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "本机概览"
        case .driver: "驱动连接"
        case .advanced: "高级诊断"
        case .profiles: "配置方案"
        }
    }
}

struct MainWindowView: View {
    @EnvironmentObject private var model: GHControlModel
    @Environment(\.openWindow) private var openWindow
    @AppStorage("showDockIcon") private var showDockIcon = true
    @State private var destination: MainDestination = .power

    private var isPowerControlConnected: Bool {
        guard let state = model.packagePowerControlState else { return false }
        return state.serviceCount > 0 && state.cachedLimitReportedValue != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch destination {
                case .power:
                    TuningView(mode: .control)
                case .connection:
                    GPUConnectionHubView {
                        destination = .power
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            footer
        }
        .frame(minWidth: 900, minHeight: 670)
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            if model.snapshot == nil && !model.isRefreshing {
                model.refresh()
            }
            model.startTelemetryPolling()
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    model.refresh()
                } label: {
                    Label("重新扫描", systemImage: model.isRefreshing ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
                }
                .disabled(model.isRefreshing)
                .help("重新读取显卡连接和功耗状态")
            }
        }
        .onAppear {
            GHControlAppDelegate.shared?.setOpenMainWindowAction {
                openWindow(id: "main")
            }
            GHControlAppDelegate.shared?.setRestorePowerLimitAction { [weak model] in
                guard let model else {
                    return (false, "GPU 功耗控制状态不可用，无法恢复默认值。")
                }
                return model.restoreDefaultPowerLimitForExit()
            }
            GHControlAppDelegate.shared?.setDockIconVisible(showDockIcon)
        }
        .onChange(of: showDockIcon) { visible in
            GHControlAppDelegate.shared?.setDockIconVisible(visible)
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Button {
                destination = .connection
            } label: {
                HStack(spacing: 10) {
                    Circle()
                        .fill(isPowerControlConnected ? Color.green : Color.yellow)
                        .frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(isPowerControlConnected ? "GPU 已连接" : connectionStatus)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text("点击查看显卡连接详情")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
                .contentShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .help("打开显卡连接与技术诊断")

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Toggle("在 Dock 中显示", isOn: $showDockIcon)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                Text("不提供开机自启动")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var connectionStatus: String {
        if model.isRefreshing { return "正在读取 GPU" }
        if model.packagePowerControlState == nil { return "GPU 连接待确认" }
        return "GPU 连接待确认"
    }
}

private struct GPUConnectionHubView: View {
    let onReturnToPower: () -> Void
    @State private var selection: ConnectionDestination = .driver

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Button(action: onReturnToPower) {
                    Label("功耗调节", systemImage: "chevron.left")
                }
                .buttonStyle(.plain)

                Spacer(minLength: 12)

                Picker("显卡连接栏目", selection: $selection) {
                    ForEach(ConnectionDestination.allCases) { destination in
                        Text(destination.title).tag(destination)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 520)

                Spacer(minLength: 12)
                Text("显卡连接")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(.bar)

            Divider()

            Group {
                switch selection {
                case .overview:
                    DashboardView()
                case .driver:
                    DriverConnectionView()
                case .advanced:
                    TuningView(mode: .advanced)
                case .profiles:
                    ProfilesView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
