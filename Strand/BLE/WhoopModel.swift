import CoreBluetooth
import WhoopProtocol

/// Which strap the user is pairing. The user pick remains the preferred scan
/// target, and reconnect can rotate to the other family if that preference is
/// stale after an update or restore.
public enum WhoopModel: String, CaseIterable, Identifiable, Hashable {
    case whoop4   = "WHOOP 4.0"
    case whoop5mg = "WHOOP 5.0 / MG"

    public var id: String { rawValue }
    public var displayName: String { rawValue }

    var fallbackScanModel: WhoopModel {
        switch self {
        case .whoop4:   return .whoop5mg
        case .whoop5mg: return .whoop4
        }
    }

    /// The protocol-layer device family this model maps to — drives framing (CRC8 vs CRC16),
    /// characteristic UUIDs, and the CLIENT_HELLO handshake.
    public var deviceFamily: DeviceFamily {
        switch self {
        case .whoop4:   return .whoop4
        case .whoop5mg: return .whoop5
        }
    }

    /// The model the user last chose, read from the same key the pickers write
    /// (`@AppStorage("selectedWhoopModel")`). Used as the default for scans the user
    /// didn't directly trigger — BLE state restoration, power-on reconnect — so those
    /// look for the right strap after a relaunch instead of falling back to WHOOP 4.0.
    public static var persisted: WhoopModel {
        UserDefaults.standard.string(forKey: "selectedWhoopModel").flatMap(WhoopModel.init(rawValue:)) ?? .whoop4
    }

    /// The BLE service to scan for, and to discover after connecting, for this model.
    /// These mirror `BLEManager.customService` / `BLEManager.whoop5Service` (kept inline
    /// here so the enum stays nonisolated — `BLEManager` is `@MainActor`). CBUUID compares
    /// by value, so these match the manager's constants in every `switch`/scan filter.
    public var scanService: CBUUID {
        switch self {
        case .whoop4:   return CBUUID(string: "61080001-8d6d-82b8-614a-1c8cb0f8dcc6")
        case .whoop5mg: return CBUUID(string: "fd4b0001-cce1-4033-93ce-002d5875f58a")
        }
    }
}
