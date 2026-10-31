@testable import Collectors
import RecorderCore
import Testing

private func probe(_ signing: SigningKind, _ entitlement: Bool?) -> SystemProbe {
    SystemProbe(signing: { signing }, hasEntitlement: { _ in entitlement })
}

private func state(_ id: String, in report: [CapabilityStatus]) -> CapabilityState? {
    report.first { $0.id == id }?.state
}

@Test(arguments: [SigningKind.adHoc, .unsigned, .unknown], [false, nil] as [Bool?])
func absentOrUncheckableCapabilitiesAreNeverReportedAsObserved(signing: SigningKind, entitlement: Bool?) {
    let report = SystemCapabilities.report(probe(signing, entitlement))
    #expect(report.allSatisfy { $0.state != .observed })
}

@Test func missingEntitlementIsReportedMissing() {
    #expect(state("endpoint-security", in: SystemCapabilities.report(probe(.adHoc, false))) == .missing)
}

@Test func failedEntitlementCheckIsUnverifiedNotMissingOrObserved() {
    #expect(state("endpoint-security", in: SystemCapabilities.report(probe(.adHoc, nil))) == .unverified)
}

@Test func signingKindsMapToHonestStates() {
    #expect(SystemCapabilities.signingStatus(.adHoc).state == .missing)
    #expect(SystemCapabilities.signingStatus(.unsigned).state == .missing)
    #expect(SystemCapabilities.signingStatus(.unknown).state == .unverified)
    #expect(SystemCapabilities.signingStatus(.developer(teamID: "ABCDE12345")).state == .observed)
}

@Test func liveProbeDoesNotClaimEndpointSecurityInTestRunner() {
    // The test runner has no Endpoint Security entitlement, so the real Security.framework check must not report one.
    #expect(state("endpoint-security", in: SystemCapabilities.report()) != .observed)
}
