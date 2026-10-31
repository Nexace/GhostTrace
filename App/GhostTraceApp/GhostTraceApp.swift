import AppKit
import Collectors
import GhostTraceIPC
import RecorderCore
import ServiceManagement
import SwiftUI
import UserNotifications
import notify

/// One bundle, two roles, so the part that is always running stays small:
/// - the menu bar instance (default): plain AppKit, no Dock icon, never loads SwiftUI views;
/// - the window instance (`--window`), started by "Open GhostTrace": a regular app that quits when its window closes.
/// Recording itself runs in the bundled RecorderAgent, which launchd keeps running (`RecorderService`).
@main
@MainActor
enum GhostTraceApp {
    static let windowArgument = "--window"
    /// Followed by an event id: the window opens on the Timeline with that event selected.
    static let selectEventArgument = "--select-event"

    static func main() {
        let app = NSApplication.shared
        let controller: any NSApplicationDelegate = CommandLine.arguments.contains(windowArgument) ? WindowController() : MenuBarController()
        app.delegate = controller
        withExtendedLifetime(controller) { app.run() }
    }
}

/// The window instance. Quitting with the window frees all of its memory.
@MainActor
final class WindowController: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.mainMenu = Self.mainMenu()
        let arguments = CommandLine.arguments
        let selected = arguments.firstIndex(of: GhostTraceApp.selectEventArgument).flatMap { arguments[safe: $0 + 1] }.flatMap(UUID.init)
        let host = NSHostingController(rootView: MainView(selecting: selected))
        // The window is AppKit's, so SwiftUI's toolbar and navigation titles are bridged into it.
        host.sceneBridgingOptions = [.toolbars, .title]
        // The window can't shrink below what the sidebar, table and inspector need, so nothing is clipped.
        host.sizingOptions = [.minSize]
        let window = NSWindow(contentViewController: host)
        window.title = "GhostTrace"
        window.styleMask.insert(.fullSizeContentView)
        window.toolbarStyle = .unified
        window.setContentSize(NSSize(width: 1180, height: 740))
        window.setFrameAutosaveName("GhostTraceMainWindow")
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window?.makeKeyAndOrderFront(nil)
        return false
    }

    /// Quit, the standard Edit commands (copy and paste in text fields need them), and Close.
    private static func mainMenu() -> NSMenu {
        let main = NSMenu()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Close GhostTrace", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        for submenu in [appMenu, edit, window] {
            let item = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
            item.submenu = submenu
            main.addItem(item)
        }
        return main
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

struct MainView: View {
    @State private var model: RecorderModel
    private let selecting: UUID?

    init(selecting: UUID? = nil) {
        self.selecting = selecting
        // Set before the State is installed: a change made through `model` in init is lost.
        let model = RecorderModel()
        if selecting != nil { model.pane = .timeline }
        _model = State(initialValue: model)
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $model.pane) {
                Section("Recorder") {
                    ForEach([Pane.overview, .timeline]) { pane in Label { Text(pane.rawValue) } icon: { IconTile(symbol: pane.symbol, color: pane.color) } }
                }
                Section("Investigate") {
                    ForEach([Pane.wakes, .memory, .system]) { pane in Label { Text(pane.rawValue) } icon: { IconTile(symbol: pane.symbol, color: pane.color) } }
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
            .safeAreaInset(edge: .bottom) { RecordingFooter(status: model.status) }
        } detail: {
            switch model.pane ?? .overview {
            case .overview: OverviewView()
            case .timeline: EventTimelineView(selecting: selecting)
            case .wakes: WakesView()
            case .memory: MemoryView().navigationTitle("Memory")
            case .system: SystemView()
            }
        }
        .environment(model)
        .task { await model.poll() }
        .frame(minWidth: 980, minHeight: 560)
    }
}

/// The sidebar's last line: whether anything is being recorded right now.
private struct RecordingFooter: View {
    let status: RecorderStatus?

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(tint).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        switch status?.state {
        case .running: "Recording"
        case .permissionLimited: "Recording, some sources off"
        case .paused: "Paused"
        case nil: "Not recording"
        }
    }

    private var detail: String {
        guard let status else { return "The recorder isn't running" }
        if let pausedAt = status.pausedAt { return "Since \(pausedAt.formatted(date: .omitted, time: .shortened))" }
        return "In the background since \(status.startedAt.formatted(date: .omitted, time: .shortened))"
    }

    private var tint: Color {
        switch status?.state {
        case .running: .green
        case .permissionLimited, .paused: .orange
        case nil: .red
        }
    }
}

/// The background services, registered with SMAppService. Both show in System Settings > General > Login Items.
@MainActor
enum RecorderService {
    /// The recorder, run by launchd at login and restarted if it exits.
    static let recorder = SMAppService.agent(plistName: "com.amoghkhairate.GhostTrace.recorder.plist")
    /// This app, so the menu bar icon is back after login.
    static let app = SMAppService.mainApp
    private static let setUpKey = "didRegisterLoginItems"
    private static let registeredBuildKey = "registeredRecorderBuild"

    /// On first launch, turn both on. Afterwards the user's choices in the menu stand.
    static func registerOnFirstLaunch() {
        guard !UserDefaults.standard.bool(forKey: setUpKey) else { return }
        UserDefaults.standard.set(true, forKey: setUpKey)
        try? register(recorder)
        try? app.register()
    }

    /// launchd remembers the recorder's code signature when it is registered. An ad-hoc signature changes with every
    /// build, and launchd then refuses to start the new binary (OS_REASON_CODESIGNING), so a new build is registered again.
    /// Registers only after launchd has removed the old job: registering while it still exists keeps the old signature
    /// (seen intermittently). If the recorder still doesn't answer 45 s later, the whole step is retried once.
    static func reregisterIfRebuilt(retry: Bool = true) {
        guard recorder.status == .enabled, recorderBuild() != UserDefaults.standard.double(forKey: registeredBuildKey) else { return }
        recorder.unregister { error in
            Task { @MainActor in
                if let error { NSLog("GhostTrace: unregistering the old recorder failed: %@", "\(error)") }
                for _ in 0..<50 where recorder.status == .enabled { try? await Task.sleep(for: .milliseconds(100)) }
                do { try register(recorder) } catch { NSLog("GhostTrace: registering the rebuilt recorder failed: %@", "\(error)") }
                guard retry else { return }
                try? await Task.sleep(for: .seconds(45))
                guard (try? RecorderClient(timeout: 2).status()) == nil else { return }
                NSLog("GhostTrace: the rebuilt recorder didn't start; registering it again")
                UserDefaults.standard.removeObject(forKey: registeredBuildKey)
                reregisterIfRebuilt(retry: false)
            }
        }
    }

    static func toggle(_ service: SMAppService) throws {
        if service.status == .enabled || service.status == .requiresApproval {
            try service.unregister()
        } else if service == recorder {
            try register(recorder)
        } else {
            try service.register()
        }
    }

    /// For uninstalling: turns both services off, then waits for the recorder to exit so its data can be moved safely.
    static func turnOff() async throws {
        // Unregistering a service that isn't registered throws, so only the registered ones are touched.
        for service in [recorder, app] where service.status == .enabled || service.status == .requiresApproval {
            try await service.unregister()
        }
        for _ in 0..<40 {
            if (try? RecorderClient(timeout: 1).status()) == nil { return }
            try? await Task.sleep(for: .milliseconds(250))
        }
        throw RecorderStillRunning()
    }

    private struct RecorderStillRunning: LocalizedError {
        var errorDescription: String? { "The recorder is still running, so GhostTrace was not uninstalled. Background recording is off; try again in a moment." }
    }

    private static func register(_ service: SMAppService) throws {
        try service.register()
        UserDefaults.standard.set(recorderBuild(), forKey: registeredBuildKey)
    }

    /// The bundled recorder's modification time, which changes whenever the app is rebuilt or reinstalled.
    private static func recorderBuild() -> Double {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/RecorderAgent")
        return (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate?.timeIntervalSince1970) ?? 0
    }
}

@MainActor
final class MenuBarController: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {
    private static let showAlertsKey = "showAlerts", lastAlertKey = "lastShownAlert"
    private var item: NSStatusItem?
    private var launchedAtLogin = false
    /// A window instance is starting (or being restarted on an event); a second request waits for it.
    private var launchingWindow = false
    /// An event to select that arrived while a window instance was starting; the window is restarted on it once started.
    private var pendingSelection: UUID?
    /// macOS won't show GhostTrace's banners: refused, alerts style None, or asking or posting failed. The menu says so.
    private var bannersBlocked = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        // The launch event says whether macOS opened the app as a login item (only readable before launch finishes).
        let event = NSAppleEventManager.shared().currentAppleEvent
        launchedAtLogin = event?.eventID == AEEventID(kAEOpenApplication)
            && event?.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // 28 pt: the outlined 18 pt ghost then sits at the same spacing as the system's icons.
        let item = NSStatusBar.system.statusItem(withLength: 28)
        item.button?.image = Self.ghost
        item.button?.toolTip = "GhostTrace"
        item.button?.setAccessibilityLabel("GhostTrace menu")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        self.item = item
        UserDefaults.standard.register(defaults: [Self.showAlertsKey: true])
        UNUserNotificationCenter.current().delegate = self
        var token: Int32 = 0
        notify_register_dispatch(GhostTracePaths.alertNotification, &token, .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.deliverAlerts() }
        }
        RecorderService.registerOnFirstLaunch()
        RecorderService.reregisterIfRebuilt()
        // A banner click that launched the app opens the window on its event (didReceive), not a plain one first.
        if !launchedAtLogin, notification.userInfo?[NSApplication.launchUserNotificationUserInfoKey] == nil { openWindow() }
    }

    /// Opening the app again (Finder, Spotlight) shows the window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openWindow()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Rebuilt each time the menu opens, so the recording state is current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        Task { await refreshBanners() }
        menu.removeAllItems()
        let status = try? RecorderClient(timeout: 1).status()
        let state = switch status?.state {
        case .running: "Recording"
        case .paused: "Paused"
        case .permissionLimited: "Recording (some sources unavailable)"
        case nil: "Recorder not running"
        }
        // Two lines with a coloured dot: the state, then how much is stored and since when.
        let dotColor: NSColor = status == nil ? .systemRed : status?.state == .running ? .systemGreen : .systemOrange
        let title = NSMutableAttributedString(string: "● ", attributes: [.foregroundColor: dotColor, .font: NSFont.systemFont(ofSize: NSFont.systemFontSize)])
        title.append(NSAttributedString(string: state, attributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)]))
        if let status {
            let since = (status.pausedAt ?? status.startedAt).formatted(date: .omitted, time: .shortened)
            title.append(NSAttributedString(string: "\n\(status.eventCount.formatted()) events · since \(since)",
                                            attributes: [.font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize), .foregroundColor: NSColor.secondaryLabelColor]))
        }
        // An action keeps it enabled, so the state isn't drawn dimmed; clicking it opens the Overview.
        let stateItem = action(state, #selector(openWindow))
        stateItem.attributedTitle = title
        menu.addItem(stateItem)
        menu.addItem(.separator())
        menu.addItem(action("Open GhostTrace", #selector(openWindow), key: "o"))
        if let status {
            menu.addItem(action(status.state == .paused ? "Resume Recording" : "Pause Recording", #selector(togglePause)))
        }
        if let allowed = status?.mcpAccess {
            let agents = action("Allow AI Agents to Read (MCP)", #selector(toggleAgentAccess))
            agents.state = allowed ? .on : .off
            agents.toolTip = "Lets agents connected through `ghosttrace mcp` read the recording. They can't change anything; what they read may go to their model provider."
            menu.addItem(agents)
        }
        if let on = status?.systemMonitor {
            let system = action("Record System Activity", #selector(toggleSystemMonitor))
            system.state = on ? .on : .off
            system.toolTip = "CPU, GPU, network, disk and battery readings, and alerts. Memory, wakes, launches and file changes are recorded either way."
            menu.addItem(system)
        }
        let alerts = action("Show Alerts", #selector(toggleShowAlerts))
        alerts.state = UserDefaults.standard.bool(forKey: Self.showAlertsKey) ? .on : .off
        alerts.toolTip = "Notifies you when the battery drains fast, the disk or memory runs low, or the Mac stays busy while you're away."
        menu.addItem(alerts)
        if alerts.state == .on, bannersBlocked {
            let blocked = action("Banners Are Off: Open Notification Settings…", #selector(openNotificationSettings))
            blocked.toolTip = "macOS isn't showing GhostTrace's banners. Alerts are still recorded in the Timeline."
            menu.addItem(blocked)
        }
        menu.addItem(.separator())
        menu.addItem(toggle("Record in Background", RecorderService.recorder, #selector(toggleRecorder)))
        menu.addItem(toggle("Open at Login", RecorderService.app, #selector(toggleLoginItem)))
        menu.addItem(.separator())
        menu.addItem(action("Uninstall GhostTrace…", #selector(uninstall)))
        menu.addItem(.separator())
        let quit = action("Quit GhostTrace", #selector(NSApplication.terminate(_:)), key: "q")
        quit.target = NSApp
        quit.toolTip = RecorderService.recorder.status == .enabled ? "Recording continues in the background." : nil
        menu.addItem(quit)
    }

    /// Brings the window instance forward, or starts one.
    @objc func openWindow() { showWindow(selecting: nil) }

    /// With an event, the window is restarted on that event: an open window can't be told to move to it.
    /// Restarting is tried once; if the old window doesn't quit, it is brought forward instead.
    private func showWindow(selecting event: UUID?, retry: Bool = true) {
        // A reopen and a banner click can arrive together, in either order: one launch, then the selection.
        guard !launchingWindow else {
            pendingSelection = event ?? pendingSelection
            return
        }
        if let window = otherInstances.first {
            guard let event, retry else {
                window.activate()
                return
            }
            let others = otherInstances
            others.forEach { $0.terminate() }
            launchingWindow = true
            Task {
                for _ in 0..<20 where others.contains(where: { !$0.isTerminated }) { try? await Task.sleep(for: .milliseconds(100)) }
                launchingWindow = false
                showWindow(selecting: pendingSelection ?? event, retry: false)
                pendingSelection = nil
            }
            return
        }
        launchingWindow = true
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.arguments = [GhostTraceApp.windowArgument] + (event.map { [GhostTraceApp.selectEventArgument, $0.uuidString] } ?? [])
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            Task { @MainActor in
                self.launchingWindow = false
                if let error { self.show(error) }
                guard let pending = self.pendingSelection else { return }
                self.pendingSelection = nil
                self.showWindow(selecting: pending)
            }
        }
    }

    @objc private func togglePause() {
        let client = RecorderClient(timeout: 2)
        do {
            _ = try client.status().state == .paused ? client.resume() : client.pause()
        } catch {
            show(error)
        }
    }

    @objc private func toggleAgentAccess() {
        let client = RecorderClient(timeout: 2)
        do { _ = try client.configure(mcpAccess: try client.status().mcpAccess != true) } catch { show(error) }
    }

    /// The client blocks on IPC for up to 4 s, so it runs off the main actor. The menu reads the new state when next opened.
    @objc private func toggleSystemMonitor() {
        Task {
            let result = await Task.detached {
                Result { let client = RecorderClient(timeout: 2); return try client.configure(systemMonitor: try client.status().systemMonitor != true) }
            }.value
            if case .failure(let error) = result { show(error) }
        }
    }

    @objc private func toggleShowAlerts() {
        let on = !UserDefaults.standard.bool(forKey: Self.showAlertsKey)
        UserDefaults.standard.set(on, forKey: Self.showAlertsKey)
        // Asks right away (the first time only) so the menu can say banners are off before the first alert.
        if on { Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert]); await refreshBanners() } }
    }

    /// Posts a banner for each alert that started since the last one shown (ended alerts only move the marker). Alerts are fetched, not carried by the notification,
    /// so a missed signal is made up at the next one. Remembered even when alerts are off, so turning them on isn't a flood.
    private func deliverAlerts() {
        Task {
            let now = Date()
            let query = EventQuery(from: now.addingTimeInterval(-15 * 60), to: now, kind: .alert)
            let events = await Task.detached { try? RecorderClient(timeout: 2).events(query).events }.value ?? []
            let defaults = UserDefaults.standard
            let lastShown = defaults.string(forKey: Self.lastAlertKey).flatMap(UUID.init)
            let fresh = lastShown.flatMap { id in events.firstIndex { $0.id == id } }.map { Array(events[($0 + 1)...]) } ?? events
            guard let newest = fresh.last else { return }
            defaults.set(newest.id.uuidString, forKey: Self.lastAlertKey)
            let started = fresh.filter { $0.payload["state"] == "started" }
            guard defaults.bool(forKey: Self.showAlertsKey), !started.isEmpty else { return }
            let center = UNUserNotificationCenter.current()
            // Asks the first time only; afterwards macOS answers from the user's earlier choice.
            // A refusal still moves the marker: the alerts are in the Timeline, and the menu says banners are off.
            guard (try? await center.requestAuthorization(options: [.alert])) == true else { return await refreshBanners(failed: true) }
            var failed = false
            for event in started {
                let content = UNMutableNotificationContent()
                content.title = AlertMonitor.Rule(rawValue: event.payload["rule"] ?? "")?.title ?? "GhostTrace alert"
                content.body = event.payload["message"] ?? ""
                content.userInfo = ["eventID": event.id.uuidString]
                do { try await center.add(UNNotificationRequest(identifier: event.id.uuidString, content: content, trigger: nil)) } catch { failed = true }
            }
            await refreshBanners(failed: failed)
        }
    }

    /// Asks macOS whether banners can show; only on a delivery or when the menu opens, never on a timer.
    /// "Not determined" counts as blocked only once asking failed, so the menu doesn't complain before the first alert.
    private func refreshBanners(failed: Bool = false) async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        let allowed = [.authorized, .provisional].contains(settings.authorizationStatus) && settings.alertSetting != .disabled && settings.alertStyle != .none
        let blocked = failed || (settings.authorizationStatus == .notDetermined ? bannersBlocked : !allowed)
        guard blocked != bannersBlocked else { return }
        bannersBlocked = blocked
        if let menu = item?.menu { menuNeedsUpdate(menu) }
    }

    @objc private func openNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") { NSWorkspace.shared.open(url) }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let id = (response.notification.request.content.userInfo["eventID"] as? String).flatMap(UUID.init) else { return }
        await MainActor.run { showWindow(selecting: id) }
    }

    @objc private func toggleRecorder() {
        do { try RecorderService.toggle(RecorderService.recorder) } catch { show(error) }
    }

    @objc private func toggleLoginItem() {
        do { try RecorderService.toggle(RecorderService.app) } catch { show(error) }
    }

    @objc private func openLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// The window instance, if one is open.
    private var otherInstances: [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "").filter { $0 != .current }
    }

    /// An app can't delete itself, so this turns everything off and shows it in Finder for the user to trash.
    /// The recorded data is only moved to the Trash if asked, and never while the recorder could still be writing it.
    @objc private func uninstall() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Uninstall GhostTrace?"
        alert.informativeText = "Background recording and Open at Login will be turned off. GhostTrace will then be shown in Finder so you can move it to the Trash."
        alert.addButton(withTitle: "Uninstall")
        alert.addButton(withTitle: "Cancel")
        let trashData = NSButton(checkboxWithTitle: "Also move recorded data to the Trash", target: nil, action: nil)
        trashData.sizeToFit()
        alert.accessoryView = trashData
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let moveData = trashData.state == .on
        Task {
            do {
                try await RecorderService.turnOff()
                if moveData, FileManager.default.fileExists(atPath: GhostTracePaths.home.path) {
                    try FileManager.default.trashItem(at: GhostTracePaths.home, resultingItemURL: nil)
                }
                // The window instance saves its frame when it quits, so it goes before the defaults are cleared.
                let others = otherInstances
                others.forEach { $0.terminate() }
                for _ in 0..<20 where others.contains(where: { !$0.isTerminated }) { try? await Task.sleep(for: .milliseconds(100)) }
                UserDefaults.standard.removePersistentDomain(forName: Bundle.main.bundleIdentifier!)
                NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                NSApp.terminate(nil)
            } catch {
                show(error)
            }
        }
    }

    private func action(_ title: String, _ selector: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        return item
    }

    /// A checkmark item for a login service. If macOS needs the user's approval, the item opens Login Items instead.
    private func toggle(_ title: String, _ service: SMAppService, _ selector: Selector) -> NSMenuItem {
        guard service.status != .requiresApproval else {
            return action("\(title): Allow in Login Items…", #selector(openLoginItems))
        }
        let item = action(title, selector)
        item.state = service.status == .enabled ? .on : .off
        return item
    }

    private func show(_ error: any Error) {
        NSApp.activate()
        NSAlert(error: error).runModal()
    }

    /// An outlined ghost (1.5 pt stroke, matching the regular-weight system menu bar icons), drawn as a template
    /// image so macOS tints it for light and dark menu bars.
    static let ghost: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            let body = NSBezierPath()
            body.lineWidth = 1.5
            body.lineJoinStyle = .round
            body.move(to: NSPoint(x: 3.5, y: 16))
            body.line(to: NSPoint(x: 3.5, y: 8.5))
            body.appendArc(withCenter: NSPoint(x: 9, y: 8.5), radius: 5.5, startAngle: 180, endAngle: 0, clockwise: false)
            body.line(to: NSPoint(x: 14.5, y: 16))
            // Wavy hem: three scallops back to the left edge.
            for step in 0..<3 {
                let x = 14.5 - Double(step) * 11.0 / 3
                body.curve(to: NSPoint(x: x - 11.0 / 3, y: 16), controlPoint1: NSPoint(x: x - 0.6, y: 13.6), controlPoint2: NSPoint(x: x - 3.1, y: 13.6))
            }
            body.close()
            NSColor.black.set()
            body.stroke()
            NSBezierPath(ovalIn: NSRect(x: 6.3, y: 7, width: 1.8, height: 2.6)).fill()
            NSBezierPath(ovalIn: NSRect(x: 9.9, y: 7, width: 1.8, height: 2.6)).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "GhostTrace"
        return image
    }()
}
