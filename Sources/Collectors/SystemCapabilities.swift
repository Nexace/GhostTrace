import Foundation
import RecorderCore
import Security

public enum SigningKind: Equatable, Sendable {
    case developer(teamID: String)
    case adHoc
    case unsigned
    case unknown
}

/// Runtime checks, injectable so tests can force each outcome.
public struct SystemProbe: Sendable {
    public var signing: @Sendable () -> SigningKind
    /// `nil` means the check itself failed, which is not the same as "absent".
    public var hasEntitlement: @Sendable (String) -> Bool?

    public init(signing: @escaping @Sendable () -> SigningKind, hasEntitlement: @escaping @Sendable (String) -> Bool?) {
        self.signing = signing
        self.hasEntitlement = hasEntitlement
    }

    public static let live = SystemProbe(signing: liveSigning, hasEntitlement: liveEntitlement)
}

public enum SystemCapabilities {
    public static let endpointSecurityEntitlement = "com.apple.developer.endpoint-security.client"

    /// Collectors report their own rows (`Collector.status()`); this covers the process itself.
    public static func report(_ probe: SystemProbe = .live) -> [CapabilityStatus] {
        [
            signingStatus(probe.signing()),
            endpointSecurityStatus(probe.hasEntitlement(endpointSecurityEntitlement)),
            CapabilityStatus(id: "full-disk-access", name: "Full Disk Access", state: .unverified,
                             detail: "No public API reports this. GhostTrace does not request it."),
        ]
    }

    static func signingStatus(_ kind: SigningKind) -> CapabilityStatus {
        let (state, detail): (CapabilityState, String) = switch kind {
        case .developer(let team): (.observed, "Signed by team \(team).")
        case .adHoc: (.missing, "Ad-hoc signed. No Apple signing identity is installed, so this is a local development build.")
        case .unsigned: (.missing, "This build is unsigned.")
        case .unknown: (.unverified, "The code signature could not be read.")
        }
        return CapabilityStatus(id: "code-signing", name: "Apple code signing", state: state, detail: detail)
    }

    static func endpointSecurityStatus(_ granted: Bool?) -> CapabilityStatus {
        let (state, detail): (CapabilityState, String) = switch granted {
        case true?: (.observed, "Entitlement present.")
        case false?: (.missing, "Not granted. Exact process and file attribution is unavailable; GhostTrace runs in reduced-capability mode.")
        case nil: (.unverified, "The entitlement check failed.")
        }
        return CapabilityStatus(id: "endpoint-security", name: "Endpoint Security entitlement", state: state, detail: detail)
    }
}

// Security.framework/Headers/SecCode.h: SecCodeCopySelf, SecCodeCopyStaticCode, SecCodeCopySigningInformation.
private func liveSigning() -> SigningKind {
    var code: SecCode?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return .unknown }
    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return .unknown }
    var info: CFDictionary?
    let status = SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
    if status == errSecCSUnsigned { return .unsigned }
    guard status == errSecSuccess, let dict = info as? [String: Any] else { return .unknown }
    guard dict[kSecCodeInfoIdentifier as String] != nil else { return .unsigned }
    if let team = dict[kSecCodeInfoTeamIdentifier as String] as? String { return .developer(teamID: team) }
    let flags = (dict[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
    return flags & SecCodeSignatureFlags.adhoc.rawValue != 0 ? .adHoc : .unknown
}

// Security.framework/Headers/SecTask.h: SecTaskCreateFromSelf, SecTaskCopyValueForEntitlement.
private func liveEntitlement(_ name: String) -> Bool? {
    guard let task = SecTaskCreateFromSelf(nil) else { return nil }
    var error: Unmanaged<CFError>?
    let value = SecTaskCopyValueForEntitlement(task, name as CFString, &error)
    if let error {
        _ = error.takeRetainedValue()
        return nil
    }
    return (value as? Bool) == true
}
