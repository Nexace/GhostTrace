# GhostTrace privacy model

GhostTrace records on this Mac, for you, and sends nothing anywhere on its own.

## What is recorded

| Source | Kept | Never kept |
|---|---|---|
| NSWorkspace | App launches and quits (name, bundle id, pid, path), sleep and wake | Window titles, documents, what you did in an app |
| `pmset -g log` | Sleep, wake and wake-request lines | The rest of the power log |
| Process sampling | Memory and CPU of your own processes, system memory and pressure | Process arguments, environment, other users' processes |
| System activity (Record System Activity) | System CPU, GPU, memory, network bytes (Wi-Fi and Ethernet totals), disk bytes read and written, free space, battery charge and power source; energy and disk I/O of your own processes; alerts (rule, values, process names). On a network spike the recorder runs `nettop` and stores a snapshot that **names processes** with their pid and bytes in and out. It lists every process that moved bytes then, including system daemons (for example syslogd, mDNSResponder) | Network destinations, addresses or contents (only process name, pid, bytes in and bytes out are stored) |
| FSEvents | Path and change flags, only under paths you chose with `ghosttrace watch add` | File contents, file names outside watched paths |
| The recorder | Its own starts, stops, pauses, gaps, setting changes | — |

No keystrokes, screen content, clipboard, browser history, messages, microphone, camera or location. GhostTrace does not request Full Disk Access, Accessibility or Endpoint Security.

## Where it is stored and who can read it

- `~/Library/Application Support/GhostTrace` (folder 0700, database files 0600). Kept 30 days, at most 1,000,000 rows.
- Only the recorder opens the database. Under launchd it answers over XPC only to programs signed by the same Apple team (the app, the signed CLI). A terminal recorder uses a socket that only your user can open.
- No network listener, no telemetry, no update checks.

## Leaving the Mac

Data leaves only when you make it:
- `ghosttrace export` writes a file. Watched paths are replaced by a short hash unless you add `--include-sensitive`.
- `--json` output goes wherever you send it.
- **AI agents (MCP).** `ghosttrace mcp` lets an agent you configured read the recording. It is off until you run `ghosttrace mcp allow`, and `ghosttrace mcp deny` turns it off again, also for agents already connected. Agents can only read: they cannot pause, change settings or watches, or delete anything. Event listings hide watched paths as exports do; a file-change investigation returns the paths under the one the agent asked about. Each agent request is logged (`ghosttrace logs`), and allowing or denying is recorded as an event. **What the agent does with the answers is up to the agent:** most send them to a cloud model. System data (battery, network totals, `nettop` process names, energy and disk I/O) is part of what an allowed agent can read. Allow access only for agents you'd trust with your app usage, wake times and watched paths.

## Turning system recording off

Choose **Record System Activity** in the menu, use the toggle in the System pane, or run `ghosttrace config --system off`. Off stops system readings, per-process energy and disk I/O, alerts and `nettop` snapshots; memory, app launches and file changes keep recording. The off span is stored as a gap. System data already recorded stays until the 30-day retention removes it; deleting the data folder erases it now. **Show Alerts** in the menu turns off the macOS banners only.

## Pausing and deleting

- Pause (menu or `ghosttrace pause`) stops every collector. The paused span is stored as a gap; nothing from it is read back later.
- Uninstall (menu) stops the recorder and can move the data folder to the Trash. Deleting `~/Library/Application Support/GhostTrace` erases everything.
