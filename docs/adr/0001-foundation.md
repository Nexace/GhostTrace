# ADR 0001: Phase 0 foundation

Date: 2026-10-27. Status: accepted.

## Environment (observed)
Xcode 27.1 (27A9275), macOS SDK 27.0, Swift 6.4, arm64, macOS 27.0.1 (26A434). `security find-identity -v -p codesigning`: 0 valid identities.

## Decisions

1. **Swift package for all modules, thin Xcode project for the app.** Library modules, the CLI and the agent build and test with `swift test` with no Xcode project edits. `App/GhostTrace.xcodeproj` holds only the SwiftUI app target, which links the package's `GhostTraceKit` product through a local package reference. A real `.app` bundle is needed later for XPC and ServiceManagement packaging (Phase 1/4). The project uses a file-system-synchronized group, so adding app source files needs no project edits.
2. **Deployment target macOS 14.0.** Covers Apple Silicon Macs on Sonoma and later, and provides the Observation framework and current SwiftUI APIs. Only macOS 27.0.1 has been run; availability below that is enforced by the compiler, not tested.
3. **SQLite through the SDK `SQLite3` module, no Swift package.** Available without adding a dependency (adding one needs approval). SDK header and runtime library both report 3.54.0. A thin internal wrapper will be written in Phase 1; revisit GRDB only if the wrapper grows large, and only with approval.
4. **Ad-hoc signing.** No signing identity is installed, so the plan's "signed local debug build" criterion is unmet. Do not create certificates or change keychain settings.
5. **Swift 6 language mode, Swift Testing.** Strict concurrency from the start.
6. **App is not sandboxed.** Later phases read `pmset -g log` and the unified log. Revisit before distribution.
7. **Capability states.** `observed` only from a positive runtime check, `missing` when checked and absent, `unverified` when not checked or not checkable, `unavailable` when out of scope. A failed check is `unverified`, never `missing` or `observed`.

## Deferred
IPC mechanism (XPC vs. Unix socket fallback) is a Phase 1 decision. In Phase 0 the app calls the capability probe in-process; Phase 1 moves status behind the recorder's service contract.
