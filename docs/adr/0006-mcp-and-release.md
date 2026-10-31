# ADR 0006: Read-only MCP adapter, Endpoint Security, packaging (Phase 5)

Date: 2026-10-28. Status: accepted.

## MCP: `ghosttrace mcp`, a stdio server inside the signed CLI

**Checked.** The MCP specification's current revision is 2026-07-28 (Context7, modelcontextprotocol.io). It replaces the `initialize` handshake with per-request `_meta` (`io.modelcontextprotocol/protocolVersion`) and a required `server/discover`; a server may also answer `initialize` for older clients. Unsupported versions get error -32022 with the supported list. stdio is newline-delimited JSON-RPC.

**Decision.**
- The server is the `MCPBridge` library, run by `ghosttrace mcp`. It is a client of the recorder like the CLI: every tool becomes one IPC `Request`, sent through `RecorderClient`. No database access, no second store. Running inside the signed CLI means it reaches the launchd recorder over XPC under the same-team rule (ADR 0005) without a new binary to sign.
- Both eras: `server/discover` advertises 2026-07-28; `initialize` negotiates 2025-11-25, 2025-06-18 or 2025-03-26. Every result carries `resultType: "complete"`, which older clients ignore. Hand-written (about 200 lines) rather than the Swift MCP SDK: the project has no package dependencies and the surface is seven tools.
- Tools: `get_recording_status`, `list_events`, `get_event`, `get_resource_usage`, `investigate_wake`, `investigate_memory`, `investigate_file_change`. All carry `readOnlyHint`. Arguments are checked against each schema (unknown names refused) before anything reaches the recorder; time windows use the CLI's parser (`TimeArgument.window`), and the recorder still enforces each investigator's maximum window. `list_events` returns at most 200 events per page.
- Results: the IPC response JSON as one text block. No `structuredContent` (optional without an output schema): it would double every result, and a day of wake evidence is already about 150 KB. Investigations already cite event ids and carry confidence labels, and the server's `instructions` tell the agent to keep both and not to present correlation as a cause. Recorder errors become tool results with `isError`, so the agent can relay "access is off" to the user.
- **Consent switch, off by default.** `ghosttrace mcp allow` / `deny` set `mcp_access` in the recorder's state (`configure` with `mcpAccess`), shown in `status`. Requests from the bridge carry `client: mcp`; the recorder refuses them with `permission_denied` unless access is on, and refuses any non-read-only method from them regardless (`Request.mcpRefusal`). Revocation applies to the next request of an already running bridge. Each change is stored as a `collector_status` event (`mcp_access_allowed` / `_denied`) and each MCP request is logged (method only) in the unified log.
- This switch is consent, not an access boundary: any program signed by the team can already read the recording through the CLI, and `client` is self-declared. The boundary remains same-team signing.
- A pre-Phase 5 recorder ignores `client`, so the bridge checks that `status` reports `mcpAccess` before each call and refuses otherwise.
- **Privacy.** `list_events` and `get_event` apply the export redaction (watched paths hashed). `investigate_file_change` returns the paths under the one the agent asked about, because answering is the point. What the agent does with results (including sending them to a cloud model) is outside GhostTrace's control; `docs/privacy.md` says so.

## Endpoint Security: not built

The `com.apple.developer.endpoint-security.client` entitlement needs Apple's approval and a distribution profile; this free Personal Team has neither. The capability row already reports it as missing ("reduced-capability mode"), and every investigator says the writer of a file and the launcher of an app are unknown. Nothing in Phase 5 claims more.

## Packaging and notarization

`scripts/package.sh` builds the Release app into `.build/xcode`, signs the CLI, verifies all three signatures carry the team, and zips the app, the CLI and the docs into `dist/`. Notarization needs a Developer ID Application certificate (paid program), so the zip is not notarized and Gatekeeper on another Mac will refuse it after download. With a Developer ID: change the signing identity, add the hardened runtime, then `xcrun notarytool submit dist/… --wait` and `xcrun stapler staple` on the app. Not tried.
