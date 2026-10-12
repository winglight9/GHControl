import Foundation
import IOKit
import CryptoKit

enum HardwareDiscoveryService {
    static func discover() -> HardwareSnapshot {
        var iterator: io_iterator_t = 0
        let matching = IOServiceMatching("IOPCIDevice")
        let result = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
        guard result == KERN_SUCCESS else {
            return HardwareSnapshot(
                capturedAt: Date(),
                macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                scanMessage: "IOKit PCI 枚举失败（代码 \(result)）",
                devices: [],
                loadedExtensions: loadedExtensions(),
                runtimePowerControl: runtimePowerControlEvidence(targetGPURegistryPath: nil)
            )
        }
        defer { IOObjectRelease(iterator) }

        var devices: [GPUDeviceEvidence] = []
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            if let device = inspect(service) {
                devices.append(device)
            }
            IOObjectRelease(service)
        }

        let message = "项目目标 Radeon RX Vega M GH 已由用户确认。IOKit 枚举到 \(devices.count) 个 AMD 属性/驱动服务相关节点；PCI ID、Registry 属性与驱动 ROM 都可能被启动配置注入或替换，不用于推断实体型号。"
        let targetPath = primaryAMDDriverNode(in: devices)?.registryPath

        return HardwareSnapshot(
            capturedAt: Date(),
            macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            scanMessage: message,
            devices: devices,
            loadedExtensions: loadedExtensions(),
            runtimePowerControl: runtimePowerControlEvidence(targetGPURegistryPath: targetPath)
        )
    }

    private static func primaryAMDDriverNode(in devices: [GPUDeviceEvidence]) -> GPUDeviceEvidence? {
        let nodes = devices.filter { device in
            device.powerPlayTable != nil && device.driverServices.contains {
                $0.localizedCaseInsensitiveContains("AMDRadeonX4000_AMDEllesmereGraphicsAccelerator")
            }
        }
        guard !nodes.isEmpty,
              let mostSpecific = nodes.max(by: { $0.registryPath.count < $1.registryPath.count }) else { return nil }
        let nestedOnly = nodes.allSatisfy { node in
            node.id == mostSpecific.id || mostSpecific.registryPath.hasPrefix(node.registryPath + "/")
        }
        return nestedOnly ? mostSpecific : nil
    }

    private static func runtimePowerControlEvidence(targetGPURegistryPath: String?) -> RuntimePowerControlEvidence {
        let atiAppServicesCount = serviceCount(named: "AtiAppServices")
        let framebuffers = services(named: "AMDFramebuffer").map { service in
            defer { IOObjectRelease(service) }
            let properties = copyProperties(service)
            let enabled = properties["UserClientEnabled"] as? NSNumber
            return AMDFramebufferClientEvidence(
                registryPath: path(for: service) ?? "路径不可读取",
                userClientEnabled: enabled.map { $0.boolValue }
            )
        }
        let graphicsDeviceControl = graphicsDeviceControlEvidence(targetGPURegistryPath: targetGPURegistryPath)
        return RuntimePowerControlEvidence(
            atiAppServicesInstanceCount: atiAppServicesCount,
            framebufferNodes: framebuffers,
            graphicsDeviceControlServices: graphicsDeviceControl
        )
    }

    /// Probe only the matching GPU's AGDC user-client open gate. No external
    /// method or selector is invoked, so this cannot change GPU state.
    private static func graphicsDeviceControlEvidence(targetGPURegistryPath: String?) -> [GraphicsDeviceControlEvidence] {
        guard let targetGPURegistryPath else { return [] }
        let matches = services(named: "AtiDeviceControl")
        return matches.compactMap { service in
            defer { IOObjectRelease(service) }
            guard let registryPath = path(for: service),
                  isSameOrDescendant(registryPath, of: targetGPURegistryPath) else { return nil }

            let properties = copyProperties(service)
            let userClientClass = stringValue(properties["IOUserClientClass"])
            var connection: io_connect_t = 0
            let openResult = IOServiceOpen(service, mach_task_self_, 0, &connection)
            if openResult == KERN_SUCCESS {
                IOServiceClose(connection)
            }
            return GraphicsDeviceControlEvidence(
                registryPath: registryPath,
                userClientClass: userClientClass,
                openReturnCode: Int32(openResult)
            )
        }
    }

    private static func isSameOrDescendant(_ candidatePath: String, of targetPath: String) -> Bool {
        candidatePath == targetPath || candidatePath.hasPrefix(targetPath + "/")
    }

    private static func serviceCount(named className: String) -> Int {
        services(named: className).reduce(into: 0) { count, service in
            count += 1
            IOObjectRelease(service)
        }
    }

    private static func services(named className: String) -> [io_service_t] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching(className),
            &iterator
        ) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var matches: [io_service_t] = []
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            matches.append(service)
        }
        return matches
    }

    private static func inspect(_ service: io_registry_entry_t) -> GPUDeviceEvidence? {
        let properties = copyProperties(service)
        let compatible = stringArray(properties["compatible"])
        let vendor = pciValue(properties["vendor-id"])
        let registryDevice = pciValue(properties["device-id"])
        let compatibleHasAMD = compatible.contains { $0.lowercased().hasPrefix("pci1002,") }
        let childEvidence = driverServices(under: service)
        guard compatibleHasAMD || vendor == "1002"
                || childEvidence.contains(where: { $0.localizedCaseInsensitiveContains("AMD9500Controller") }) else { return nil }

        let registryPath = path(for: service) ?? "路径不可读取"
        let registryName = stringValue(properties["IOName"]) ?? stringValue(properties["name"]) ?? "IOPCIDevice"
        let model = stringValue(properties["model"])
        var powerPlayProperties = relevantPowerPlayProperties(in: properties, nodePath: registryPath)
        var vbios = dataValue(properties["ATY,bin_image"])
        var softPowerPlayData = softPowerPlayTableData(in: properties)
        var visited = 0
        collectPowerPlayProperties(
            under: service,
            depth: 0,
            visited: &visited,
            into: &powerPlayProperties,
            vbios: &vbios,
            softPowerPlayData: &softPowerPlayData
        )

        return GPUDeviceEvidence(
            id: registryPath,
            registryPath: registryPath,
            registryName: registryName,
            vendorID: vendor,
            registryDeviceID: registryDevice,
            subsystemVendorID: pciValue(properties["subsystem-vendor-id"]),
            subsystemID: pciValue(properties["subsystem-id"]),
            revisionID: pciValue(properties["revision-id"]),
            compatibleIDs: compatible,
            model: model,
            driverServices: childEvidence,
            vbiosPCIIdentity: vbios.flatMap { PCIROMIdentity.parse(vbios: $0) },
            powerPlayProperties: powerPlayProperties,
            powerPlayTable: vbios.flatMap(PowerPlayTableEvidence.parse(vbios:)),
            softPowerPlayTable: softPowerPlayData.flatMap(SoftPowerPlayTableEvidence.parse(_:))
        )
    }

    private static func softPowerPlayTableData(in properties: [String: Any]) -> Data? {
        for (key, value) in properties where isSoftPowerPlayTableProperty(key) {
            if let data = dataValue(value) { return data }
        }
        return nil
    }

    private static func isSoftPowerPlayTableProperty(_ key: String) -> Bool {
        let normalized = key.lowercased().replacingOccurrences(of: "pp,", with: "")
        return normalized == "pp_phmsoftpowerplaytable"
            || normalized == "pp_powerplaytable"
            || normalized == "powerplaytable"
    }

    private static func copyProperties(_ entry: io_registry_entry_t) -> [String: Any] {
        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(entry, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dictionary = unmanaged?.takeRetainedValue() else {
            return [:]
        }
        return dictionary as NSDictionary as? [String: Any] ?? [:]
    }

    private static func stringArray(_ value: Any?) -> [String] {
        if let values = value as? [String] { return values }
        if let data = value as? Data {
            return String(decoding: data, as: UTF8.self)
                .split(separator: "\0")
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        if let string = stringValue(value) {
            return string.split(separator: "\0").map(String.init).filter { !$0.isEmpty }
        }
        return []
    }

    private static func stringValue(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let string = value as? String { return string.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let data = value as? Data {
            let bytes = data.prefix(256).prefix(while: { $0 != 0 })
            let string = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return string.isEmpty ? nil : string
        }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private static func dataValue(_ value: Any?) -> Data? {
        if let data = value as? Data, !data.isEmpty { return data }
        return nil
    }

    private static func pciValue(_ value: Any?) -> String? {
        if let data = value as? Data, !data.isEmpty {
            let number = data.prefix(4).enumerated().reduce(UInt32(0)) { partial, item in
                partial | (UInt32(item.element) << UInt32(item.offset * 8))
            }
            return String(format: "%04X", number & 0xFFFF)
        }
        if let number = value as? NSNumber {
            return String(format: "%04X", number.uint32Value & 0xFFFF)
        }
        if let integer = value as? UInt32 {
            return String(format: "%04X", integer & 0xFFFF)
        }
        return nil
    }

    private static func path(for entry: io_registry_entry_t) -> String? {
        var bytes = [CChar](repeating: 0, count: 1024)
        let result = bytes.withUnsafeMutableBufferPointer { buffer in
            IORegistryEntryGetPath(entry, kIOServicePlane, buffer.baseAddress!)
        }
        guard result == KERN_SUCCESS else { return nil }
        return String(cString: bytes)
    }

    private static func relevantPowerPlayProperties(in properties: [String: Any], nodePath: String) -> [String: String] {
        let names = properties.keys.filter { key in
            let normalized = key.lowercased()
            return normalized.hasPrefix("pp_") || normalized.hasPrefix("pp,") || key == "ATY,SCLK" || key == "ATY,MCLK"
        }
        return Dictionary(uniqueKeysWithValues: names.sorted().map { key in
            ("\(nodePath) · \(key)", valueSummary(properties[key], propertyName: key))
        })
    }

    private static func collectPowerPlayProperties(
        under entry: io_registry_entry_t,
        depth: Int,
        visited: inout Int,
        into result: inout [String: String],
        vbios: inout Data?,
        softPowerPlayData: inout Data?
    ) {
        guard depth < 4, visited < 256 else { return }
        visited += 1
        let properties = copyProperties(entry)
        if vbios == nil { vbios = dataValue(properties["ATY,bin_image"]) }
        if softPowerPlayData == nil { softPowerPlayData = softPowerPlayTableData(in: properties) }
        if let nodePath = path(for: entry) {
            for (key, value) in relevantPowerPlayProperties(in: properties, nodePath: nodePath) {
                result[key] = value
            }
        }

        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(entry, kIOServicePlane, &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        while visited < 256 {
            let child = IOIteratorNext(iterator)
            guard child != 0 else { break }
            collectPowerPlayProperties(
                under: child,
                depth: depth + 1,
                visited: &visited,
                into: &result,
                vbios: &vbios,
                softPowerPlayData: &softPowerPlayData
            )
            IOObjectRelease(child)
        }
    }

    private static func valueSummary(_ value: Any?, propertyName: String) -> String {
        guard let value else { return "值不可读取" }
        if let data = value as? Data {
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let sample = data.prefix(8).map { String(format: "%02X", $0) }.joined(separator: " ")
            let decoded = decodedPowerPlayValue(data, propertyName: propertyName)
            return "Data · \(data.count) 字节 · SHA-256 \(digest) · 头部 \(sample)\(decoded.map { " · \($0)" } ?? "")"
        }
        return stringValue(value) ?? String(describing: value)
    }

    private static func decodedPowerPlayValue(_ data: Data, propertyName: String) -> String? {
        guard propertyName == "PP_WorkLoadPolicyMask", data.count == 4 else { return nil }
        let value = data.enumerated().reduce(UInt32(0)) { partial, item in
            partial | (UInt32(item.element) << UInt32(item.offset * 8))
        }
        let label = value == 0x04 ? "PowerSaving 工作负载候选值" : "未映射的工作负载掩码"
        return "UInt32 LE 0x\(String(format: "%08X", value)) · \(label)"
    }

    private static func driverServices(under entry: io_registry_entry_t) -> [String] {
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(entry, kIOServicePlane, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var evidence = Set<String>()
        var visited = 0
        while true {
            let child = IOIteratorNext(iterator)
            guard child != 0 else { break }
            scanDriverService(child, depth: 0, visited: &visited, evidence: &evidence)
            IOObjectRelease(child)
        }
        return evidence.sorted()
    }

    private static func scanDriverService(
        _ entry: io_registry_entry_t,
        depth: Int,
        visited: inout Int,
        evidence: inout Set<String>
    ) {
        guard depth <= 2, visited < 128 else { return }
        visited += 1
        let properties = copyProperties(entry)
        let `class` = stringValue(properties["IOClass"])
        let bundle = stringValue(properties["CFBundleIdentifier"]) ?? stringValue(properties["CFBundleIdentifierKernel"])
        let name = `class` ?? stringValue(properties["IOName"]) ?? stringValue(properties["name"])
        let combined = [name, bundle].compactMap { $0 }.joined(separator: " · ")
        if combined.localizedCaseInsensitiveContains("AMD") || combined.localizedCaseInsensitiveContains("Accelerator") {
            evidence.insert(combined)
        }

        var iterator: io_iterator_t = 0
        guard depth < 2, IORegistryEntryGetChildIterator(entry, kIOServicePlane, &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        while true {
            let child = IOIteratorNext(iterator)
            guard child != 0 else { break }
            scanDriverService(child, depth: depth + 1, visited: &visited, evidence: &evidence)
            IOObjectRelease(child)
            if visited >= 128 { break }
        }
    }

    private static func loadedExtensions() -> [LoadedExtensionEvidence] {
        let executable = URL(fileURLWithPath: "/usr/bin/kmutil")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { return [] }

        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = ["showloaded"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard let text = String(data: data, encoding: .utf8) else { return [] }
            let relevant = [
                "com.apple.kext.AMD9500Controller",
                "com.apple.kext.AMDRadeonX4000",
                "as.vit9696.Lilu",
                "WhateverGreen",
                "Polaris22Fixup"
            ]
            return text.split(whereSeparator: \.isNewline).compactMap { line in
                let value = String(line)
                guard let bundle = relevant.first(where: { value.localizedCaseInsensitiveContains($0) }) else { return nil }
                let version: String?
                if let open = value.firstIndex(of: "("), let close = value[open...].firstIndex(of: ")") {
                    version = String(value[value.index(after: open)..<close])
                } else {
                    version = nil
                }
                return LoadedExtensionEvidence(bundleIdentifier: bundle, version: version)
            }
        } catch {
            return []
        }
    }
}
