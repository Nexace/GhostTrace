# Troubleshooting

Start with `ghosttrace status` and `ghosttrace logs --last 1h`.

| Symptom | Cause | Fix |
|---|---|---|
| `Recorder: stopped`, exit 3 | Record in Background is off, or launchd refused the recorder | Turn on Record in Background in the menu. Check `launchctl print gui/$(id -u)/com.amoghkhairate.GhostTrace.recorder` shows `state = running`. |
| `permission denied`, exit 4, from the CLI | The CLI isn't signed by the GhostTrace team, so the recorder won't answer it | Use the CLI from `scripts/sign-cli.sh` (or the one in the release zip). |
| The CLI talks to the wrong recorder | `GHOSTTRACE_HOME` is set, so it uses that folder's socket | `unset GHOSTTRACE_HOME`. |
| After reinstalling, the recorder doesn't start | launchd remembers the previous build's signature | Open the app once; it registers the new recorder. |
| `permission_limited` | A collector couldn't start; its row under Capabilities says why | Follow that row. For a watched folder in Desktop, Documents or Downloads, macOS may need to grant access. |
| A wake has no reason | powerd logged none, the power log had rolled over, or the recorder wasn't running | `investigate wake --detail` lists what was missing. |
| Nothing for a time you expected | The recorder was stopped or paused, or the time is past the 30-day retention | Look for `event_gap` events in `ghosttrace events`. |
| A file change isn't listed | The path isn't under a watched folder, or was added later | `ghosttrace watch` lists watches and since when. |
| An agent says GhostTrace access is off | Agent access starts off | `ghosttrace mcp allow`. `ghosttrace mcp deny` revokes it. |
| An agent can't start `ghosttrace mcp` | The agent's config points at an unsigned or moved CLI | Register the signed CLI's absolute path, e.g. `claude mcp add ghosttrace -- /path/to/ghosttrace mcp`. |
| `This recorder predates …` | The app and the CLI are from different builds | Reinstall the app and re-sign the CLI from the same build. |
| Gatekeeper refuses the app on another Mac | The release zip is signed for development and not notarized | See README, Packaging. Notarization needs a Developer ID. |
| No alert banners | Notifications for GhostTrace are off in System Settings, Show Alerts is off in the menu, or the menu bar app isn't running | Allow notifications for GhostTrace and tick Show Alerts. Alerts are stored either way: `ghosttrace events --kind alert`, or the Timeline. |
| A System tile says Not available | macOS doesn't give that reading on this Mac (for example no battery on a desktop), or no check has run yet | The tile shows the reason, and `ghosttrace status` lists the capability rows. Nothing is guessed or shown as zero. |
| The System pane or `ghosttrace system` is empty or says "not recorded" | Record System Activity is off (menu, the pane toggle, or `ghosttrace config --system on`) | Turn it on. The off span appears as a `system_monitor_off` gap, and investigators call it missing data. |
