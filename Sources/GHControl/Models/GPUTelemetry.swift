import Foundation

struct GPUTelemetry: Codable {
    let capturedAt: Date
    let serviceName: String
    let coreClockMHz: Double?
    let memoryClockMHz: Double?
    let temperatureC: Double?
    let totalPowerW: Double?
    let gpuActivityPercent: Double?
    let fanSpeedRPM: Double?
    let fanSpeedPercent: Double?

    var hasAnyReading: Bool {
        coreClockMHz != nil || memoryClockMHz != nil || temperatureC != nil || totalPowerW != nil
    }
}
