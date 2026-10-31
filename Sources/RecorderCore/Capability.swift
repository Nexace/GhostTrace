/// Outcome of checking one capability. Only `.observed` means "present", and only a runtime check may produce it.
public enum CapabilityState: String, Sendable, Codable, CaseIterable {
    /// Confirmed present by a runtime check.
    case observed
    /// Checked at runtime and not present.
    case missing
    /// Not checked yet, or no public API can check it.
    case unverified
    /// Out of scope or not obtainable in this build.
    case unavailable
}

public struct CapabilityStatus: Sendable, Equatable, Identifiable, Codable {
    public let id: String
    public let name: String
    public let state: CapabilityState
    public let detail: String

    public init(id: String, name: String, state: CapabilityState, detail: String) {
        self.id = id
        self.name = name
        self.state = state
        self.detail = detail
    }
}
