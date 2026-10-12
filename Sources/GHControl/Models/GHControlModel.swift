import Combine
import Foundation

@MainActor
final class GHControlModel: ObservableObject {
    @Published private(set) var snapshot: HardwareSnapshot?
    @Published private(set) var isRefreshing = false
    @Published private(set) var telemetry: GPUTelemetry?
    @Published private(set) var packagePowerControlState: PackagePowerControlState?
    @Published private(set) var powerWriteMessage: String?
    @Published private(set) var isApplyingPowerLimit = false

    private var telemetryTask: Task<Void, Never>?
    private var didWriteTelemetrySnapshot = false

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        Task {
            let (result, powerState) = await Task.detached(priority: .utility) {
                let snapshot = HardwareDiscoveryService.discover()
                let powerState = AMDPackagePowerControlService.readState(
                    targetGPURegistryPath: snapshot.primaryAMDDriverNode?.registryPath
                )
                return (snapshot, powerState)
            }.value
            snapshot = result
            packagePowerControlState = powerState
            do {
                _ = try DiagnosticReport.writeLatest(
                    snapshot: result,
                    telemetry: telemetry,
                    packagePowerControlState: powerState
                )
            } catch {
                NSLog("GH Control could not write its local diagnostic cache: %@", error.localizedDescription)
            }
            isRefreshing = false
        }
    }

    func applyPackagePowerLimit(_ watts: Int) {
        guard !isApplyingPowerLimit,
              let currentSnapshot = snapshot,
              let targetPath = currentSnapshot.primaryAMDDriverNode?.registryPath else {
            powerWriteMessage = "没有唯一目标 AMD 驱动节点，未发送功耗写入。"
            return
        }
        isApplyingPowerLimit = true
        powerWriteMessage = "正在读取当前 last-set 缓存并设置 \(watts) W……"
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                AMDPackagePowerControlService.applyPackagePowerLimit(
                    targetGPURegistryPath: targetPath,
                    watts: watts
                )
            }.value
            powerWriteMessage = result.message
            telemetry = await Task.detached(priority: .utility) {
                GPUPerformanceService.sample()
            }.value
            if let refreshedState = result.state {
                packagePowerControlState = refreshedState
                do {
                    _ = try DiagnosticReport.writeLatest(
                        snapshot: currentSnapshot,
                        telemetry: telemetry,
                        packagePowerControlState: refreshedState
                    )
                } catch {
                    NSLog("GH Control could not save power-control result: %@", error.localizedDescription)
                }
            }
            isApplyingPowerLimit = false
        }
    }

    func startTelemetryPolling() {
        guard telemetryTask == nil else { return }
        telemetryTask = Task { [weak self] in
            while !Task.isCancelled {
                let reading = await Task.detached(priority: .utility) {
                    GPUPerformanceService.sample()
                }.value
                self?.telemetry = reading
                if let self, let reading, let snapshot = self.snapshot, !self.didWriteTelemetrySnapshot {
                    do {
                        _ = try DiagnosticReport.writeLatest(
                            snapshot: snapshot,
                            telemetry: reading,
                            packagePowerControlState: self.packagePowerControlState
                        )
                        self.didWriteTelemetrySnapshot = true
                    } catch {
                        NSLog("GH Control could not cache its first GPU telemetry sample: %@", error.localizedDescription)
                    }
                }
                do {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                } catch {
                    break
                }
            }
            self?.telemetryTask = nil
        }
    }
}
