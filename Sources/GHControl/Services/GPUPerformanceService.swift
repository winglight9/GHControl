import Foundation
import IOKit

enum GPUPerformanceService {
    private static let acceleratorClass = "AMDRadeonX4000_AMDEllesmereGraphicsAccelerator"

    static func sample() -> GPUTelemetry? {
        var iterator: io_iterator_t = 0
        let matching = IOServiceMatching(acceleratorClass)
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { return nil }
            defer { IOObjectRelease(service) }

            guard let unmanaged = IORegistryEntryCreateCFProperty(
                service,
                "PerformanceStatistics" as CFString,
                kCFAllocatorDefault,
                0
            ), let statistics = unmanaged.takeRetainedValue() as? [String: Any] else { continue }

            let reading = GPUTelemetry(
                capturedAt: Date(),
                serviceName: acceleratorClass,
                coreClockMHz: number("Core Clock(MHz)", in: statistics),
                memoryClockMHz: number("Memory Clock(MHz)", in: statistics),
                temperatureC: number("Temperature(C)", in: statistics),
                totalPowerW: number("Total Power(W)", in: statistics),
                gpuActivityPercent: number("GPU Activity(%)", in: statistics) ?? number("Device Utilization %", in: statistics),
                fanSpeedRPM: number("Fan Speed(RPM)", in: statistics),
                fanSpeedPercent: number("Fan Speed(%)", in: statistics)
            )
            if reading.hasAnyReading { return reading }
        }
    }

    private static func number(_ key: String, in values: [String: Any]) -> Double? {
        guard let number = values[key] as? NSNumber else { return nil }
        return number.doubleValue.isFinite ? number.doubleValue : nil
    }
}
