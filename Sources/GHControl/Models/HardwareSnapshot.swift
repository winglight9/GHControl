import Foundation

struct HardwareSnapshot: Codable {
    let capturedAt: Date
    let macOSVersion: String
    let scanMessage: String
    let devices: [GPUDeviceEvidence]
    let loadedExtensions: [LoadedExtensionEvidence]
    let runtimePowerControl: RuntimePowerControlEvidence

    /// Returns the deepest unique AMD graphics accelerator node for collecting
    /// driver evidence. PCI/Registry/ROM values never assert physical identity.
    var primaryAMDDriverNode: GPUDeviceEvidence? {
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
}

struct RuntimePowerControlEvidence: Codable {
    let atiAppServicesInstanceCount: Int
    let framebufferNodes: [AMDFramebufferClientEvidence]
    let graphicsDeviceControlServices: [GraphicsDeviceControlEvidence]

    var hasAtiAppServices: Bool { atiAppServicesInstanceCount > 0 }
    var disabledFramebufferCount: Int {
        framebufferNodes.filter { $0.userClientEnabled == false }.count
    }
}

struct GraphicsDeviceControlEvidence: Codable, Identifiable {
    let registryPath: String
    let userClientClass: String?
    let openReturnCode: Int32

    var id: String { registryPath }
    var openReturnCodeHex: String {
        "0x\(String(UInt32(bitPattern: openReturnCode), radix: 16))"
    }
    var wasNotPermitted: Bool {
        UInt32(bitPattern: openReturnCode) == 0xe00002e2
    }
}

struct AMDFramebufferClientEvidence: Codable, Identifiable {
    let registryPath: String
    let userClientEnabled: Bool?

    var id: String { registryPath }
}

struct GPUDeviceEvidence: Codable, Identifiable {
    let id: String
    let registryPath: String
    let registryName: String
    let vendorID: String?
    let registryDeviceID: String?
    let subsystemVendorID: String?
    let subsystemID: String?
    let revisionID: String?
    let compatibleIDs: [String]
    let model: String?
    let driverServices: [String]
    let vbiosPCIIdentity: PCIROMIdentity?
    let powerPlayProperties: [String: String]
    let powerPlayTable: PowerPlayTableEvidence?
    let softPowerPlayTable: SoftPowerPlayTableEvidence?

    var registryCompatibleDeviceID: String? {
        compatibleIDs.first(where: { $0.lowercased() == "pci1002,694c" }) == nil ? nil : "694C"
    }

    var hasSoftPowerPlayTable: Bool {
        if softPowerPlayTable != nil { return true }
        return powerPlayProperties.keys.contains { key in
            let propertyName = key.split(separator: "·").last.map(String.init) ?? key
            let normalized = propertyName.trimmingCharacters(in: .whitespaces).lowercased()
            return normalized == "pp_phmsoftpowerplaytable"
                || normalized == "pp,pp_phmsoftpowerplaytable"
                || normalized == "pp_powerplaytable"
                || normalized == "powerplaytable"
        }
    }
}

struct LoadedExtensionEvidence: Codable, Identifiable {
    let bundleIdentifier: String
    let version: String?

    var id: String { bundleIdentifier }
}
