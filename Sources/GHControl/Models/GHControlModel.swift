import Combine
import Foundation
import IOKit

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
    private var didCheckStalePowerLimit = false

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        let shouldCheckStalePowerLimit = !didCheckStalePowerLimit
        Task {
            let (result, powerState, recoveryMessage, didReadPowerLimit) = await Task.detached(priority: .utility) {
                let snapshot = HardwareDiscoveryService.discover()
                let targetPath = snapshot.primaryAMDDriverNode?.registryPath
                var powerState = AMDPackagePowerControlService.readState(
                    targetGPURegistryPath: targetPath
                )
                var recoveryMessage: String?
                if shouldCheckStalePowerLimit,
                   let cachedWatts = powerState.cachedLimitReportedValue,
                   cachedWatts != 75,
                   let targetPath {
                    let recovery = AMDPackagePowerControlService.applyPackagePowerLimit(
                        targetGPURegistryPath: targetPath,
                        watts: 75
                    )
                    if let recoveredState = recovery.state {
                        powerState = recoveredState
                    }
                    if recovery.writeIOReturn == KERN_SUCCESS,
                       recovery.state?.cachedLimitReportedValue == 75 {
                        recoveryMessage = "检测到上次运行遗留的 \(cachedWatts) W 设置，已在启动时恢复到 75 W。此读数是驱动缓存，不是 SMU 硬件上限读回。"
                    } else {
                        recoveryMessage = "检测到上次运行遗留的 \(cachedWatts) W 设置，但启动时未能确认恢复到 75 W。请检查驱动连接并手动恢复。\(recovery.message)"
                    }
                }
                return (snapshot, powerState, recoveryMessage, powerState.cachedLimitReportedValue != nil)
            }.value
            snapshot = result
            packagePowerControlState = powerState
            if didReadPowerLimit {
                didCheckStalePowerLimit = true
            }
            if let recoveryMessage {
                powerWriteMessage = recoveryMessage
            }
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

    func restoreDefaultPowerLimitForExit() -> (success: Bool, detail: String) {
        guard !isApplyingPowerLimit else {
            return (false, "功耗设置仍在执行，请稍后再退出。")
        }
        guard let targetPath = packagePowerControlState?.targetGPUPath
                ?? snapshot?.primaryAMDDriverNode?.registryPath else {
            return (false, "没有可用的目标 GPU 驱动路径，无法发送 75 W 恢复值。")
        }

        let result = AMDPackagePowerControlService.applyPackagePowerLimit(
            targetGPURegistryPath: targetPath,
            watts: 75
        )
        if let state = result.state {
            packagePowerControlState = state
        }
        guard result.writeIOReturn == KERN_SUCCESS,
              result.state?.cachedLimitReportedValue == 75 else {
            return (false, "75 W 恢复写入未得到驱动 last-set 缓存确认。\(result.message)")
        }
        powerWriteMessage = "退出前已发送 75 W 默认值；AMD 驱动 last-set 缓存读回 75 W。"
        return (true, "已恢复到 75 W 默认值。")
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
