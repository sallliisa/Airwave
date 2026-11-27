import AppKit
import Combine
import ServiceManagement
import SwiftUI

@main
@MainActor
struct Airwave3App: App {
    @NSApplicationDelegateAdaptor(HostAppDelegate.self) private var delegate
    @ObservedObject private var shell = HostAppDelegate.environment.shell

    var body: some Scene {
        MenuBarExtra(isInserted: Binding(get: { shell.showsMenuBar }, set: { visible in
            Task { @MainActor in shell.setMenuBarVisible(visible) }
        })) {
            HostMenuPopover(
                host: delegate.host, shell: shell, openWindow: delegate.openWindow,
                openMixer: delegate.openMixer, openSetup: delegate.openSetup, quit: delegate.quit
            )
        } label: {
            Label("Airwave", image: "MenuBarIcon")
                .accessibilityIdentifier("hostMenu")
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class HostAppDelegate: NSObject, NSApplicationDelegate {
    static let environment = HostLaunchEnvironment()
    let host = HostController(store: environment.store, defaults: environment.defaults,
                              presetLibrary: environment.presetLibrary, migrationWarning: environment.migrationWarning)

    private var shell: ShellModel { Self.environment.shell }
    private let windows = HostWindowLifecycle()
    private var launchRouting = HostLaunchRouting()
    private var termination: HostTermination?
    private var settingsWindow: NSWindowController?
    private var captureSubscription: AnyCancellable?
    private weak var captureRequestWindow: NSWindow?

    private lazy var updates = HostUpdateManager(onRelaunch: { [weak self] in
        self?.termination = .updateRelaunch
    })

    func applicationWillFinishLaunching(_ notification: Notification) {
        let manager = NSAppleEventManager.shared()
        for event in [kAEOpenApplication, kAEReopenApplication] {
            manager.setEventHandler(
                self,
                andSelector: #selector(handleOpenEvent(_:reply:)),
                forEventClass: AEEventClass(kCoreEventClass),
                andEventID: AEEventID(event)
            )
        }
        windows.start()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(sessionEnding), name: NSWorkspace.willPowerOffNotification, object: nil)
        workspace.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)

        shell.applyInitialLoginPreference()
        trackCaptureWindow()
        updates.start()
        if let page = launchRouting.finishLaunching(setupComplete: shell.setupCompleted) { present(page) }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        shell.refreshLoginItem()
    }

    func applicationWillResignActive(_ notification: Notification) {
        windows.willResignActive()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if HostTermination.isSystemQuit(NSAppleEventManager.shared().currentAppleEvent) {
            termination = .sessionEnding
        }
        let reply = HostTermination.reply(for: termination)
        if reply == .terminateCancel { windows.closeUserWindows() }
        return reply
    }

    func applicationWillTerminate(_ notification: Notification) {
        let manager = NSAppleEventManager.shared()
        for event in [kAEOpenApplication, kAEReopenApplication] {
            manager.removeEventHandler(forEventClass: AEEventClass(kCoreEventClass), andEventID: AEEventID(event))
        }
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        windows.stop()
        host.shutdown()
    }

    func openWindow() {
        windows.closeMenuBarPopover()
        route(.manual)
    }

    func openMixer() {
        windows.closeMenuBarPopover()
        present(shell.setupCompleted ? .mixer : .setup)
    }

    func openSetup() {
        windows.closeMenuBarPopover()
        shell.showSetup()
        present(.setup)
    }

    func quit() {
        termination = .explicit
        NSApp.terminate(nil)
    }

    @objc private func sessionEnding() { termination = .sessionEnding }
    @objc private func willSleep() { host.suspendForSleep() }
    @objc private func didWake() { host.resumeAfterWake() }

    @objc private func handleOpenEvent(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        handleOpen(event)
    }

    private func handleOpen(_ event: NSAppleEventDescriptor) {
        let pid = event.attributeDescriptor(forKeyword: AEKeyword(keySenderPIDAttr))?.int32Value ?? 0
        let sender = pid > 0 ? NSRunningApplication(processIdentifier: pid)?.bundleIdentifier : nil
        guard let intent = HostOpenIntent(event: event, sender: sender) else { return }
        route(intent)
    }

    private func route(_ intent: HostOpenIntent) {
        if let page = launchRouting.receive(intent, setupComplete: shell.setupCompleted) { present(page) }
    }

    private func present(_ page: ShellPage) {
        if page == .effects, settingsWindow?.window?.isVisible != true {
            host.selectCurrentOutputForEditing()
        }
        shell.page = page
        if settingsWindow == nil {
            let content = HostWindow(host: host, shell: shell, updates: updates) { [weak self] in
                self?.quit()
            }
            let frame = NSRect(origin: .zero, size: HostWindow.contentSize)
            let window = NSWindow(
                contentRect: frame,
                styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = "Airwave"
            window.identifier = HostWindowLifecycle.settingsID
            window.isReleasedWhenClosed = false
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            window.appearance = NSAppearance(named: .darkAqua)
            window.backgroundColor = NSColor(srgbRed: 17 / 255, green: 17 / 255, blue: 17 / 255, alpha: 1)
            window.isMovableByWindowBackground = true
            window.backgroundColor = NSColor(HostAppearance.canvas)
            window.collectionBehavior.insert(.moveToActiveSpace)
            window.standardWindowButton(.zoomButton)?.isEnabled = false
            window.contentViewController = NSHostingController(rootView: content)
            window.setContentSize(frame.size)
            window.contentMinSize = frame.size
            window.contentMaxSize = frame.size
            window.center()
            if !Self.environment.isIsolated {
                window.setFrameAutosaveName("SystemAudioHostWindow")
            }
            settingsWindow = NSWindowController(window: window)
        }
        if let window = settingsWindow?.window { windows.front(window) }
    }

    private func trackCaptureWindow() {
        captureSubscription = host.$captureCheck.sink { [weak self] status in
            guard let self else { return }
            switch status {
            case .checking:
                self.captureRequestWindow = self.settingsWindow?.window
            case .verified, .failed:
                let window = self.captureRequestWindow
                self.captureRequestWindow = nil
                if let window, window.isVisible, !window.isMiniaturized { self.windows.front(window) }
            case .idle:
                self.captureRequestWindow = nil
            }
        }
    }
}

@MainActor
struct HostLaunchEnvironment {
    let defaults: UserDefaults
    let store: ProfileStore
    let presetLibrary: HostPresetLibrary
    let migrationWarning: String?
    let shell: ShellModel
    let isIsolated: Bool

    init() {
#if DEBUG
        let environment = ProcessInfo.processInfo.environment
        let profile = environment["SYSTEM_AUDIO_HOST_TEST_PROFILE"].map { URL(filePath: $0) }
        let hostedByXCTest = ["XCTestConfigurationFilePath", "XCTestSessionIdentifier", "XCInjectBundleInto"]
            .contains { environment[$0] != nil }
        if profile != nil || hostedByXCTest {
            let defaults = FixtureDefaults(file: profile?.appendingPathExtension("preferences"))
            if hostedByXCTest, environment["SYSTEM_AUDIO_HOST_LIVE"] == "1" {
                // The live tests own the route. Keep the test runner's normal mixer off.
                defaults.set(false, forKey: "ProcessingEnabled")
            }
            self.defaults = defaults
            let testProfile = profile ?? FileManager.default.temporaryDirectory
                .appending(path: "system-audio-host-xctest-\(UUID()).plist")
            store = ProfileStore(url: testProfile)
            presetLibrary = HostPresetLibrary(url: testProfile.appendingPathExtension("presets"))
            migrationWarning = nil
            isIsolated = true
            shell = ShellModel(
                defaults: defaults,
                loginItem: FixtureLoginItem(defaults: defaults),
                initialSetupCompleted: environment["SYSTEM_AUDIO_HOST_TEST_SETUP"] != "pending"
            )
            return
        }
#endif
        let preferences = UserDefaults.standard
        store = ProfileStore()
        presetLibrary = HostPresetLibrary(url: HostPresetLibrary.defaultURL)
        defaults = preferences
        isIsolated = false
        do {
            try LegacyAirwaveUpgrade.migrate(defaults: preferences, store: store, presetLibrary: presetLibrary) {
                try LegacyAirwaveUpgrade.installedSource(defaults: preferences)
            }
            migrationWarning = nil
        } catch {
            let failure = error as? LegacyAirwaveUpgrade.Failure
                ?? .init(reason: "Your old settings are preserved. Reopen Airwave to retry.")
            migrationWarning = failure.localizedDescription
            ShellModel.applyUpgradePreferences(to: preferences, completed: nil, showsMenuBar: nil)
        }
        shell = ShellModel(defaults: preferences, loginItem: SMAppService.mainApp,
                           initialSetupCompleted: migrationWarning != nil)
    }
}

#if DEBUG
@MainActor
private final class FixtureLoginItem: HostLoginItem {
    private static let key = "Host.Fixture.LaunchAtLogin"
    private let defaults: UserDefaults

    init(defaults: UserDefaults) { self.defaults = defaults }

    var status: SMAppService.Status { defaults.bool(forKey: Self.key) ? .enabled : .notRegistered }
    func register() throws { defaults.set(true, forKey: Self.key) }
    func unregister() throws { defaults.set(false, forKey: Self.key) }
}

private final class FixtureDefaults: UserDefaults {
    private let file: URL?
    private let arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
    private var values: [String: Any]

    init(file: URL?) {
        self.file = file
        if let file, let data = try? Data(contentsOf: file),
           let stored = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            values = stored
        } else {
            values = [:]
        }
        super.init(suiteName: nil)!
    }

    override func object(forKey defaultName: String) -> Any? {
        arguments[defaultName] ?? values[defaultName]
    }

    override func string(forKey defaultName: String) -> String? { object(forKey: defaultName) as? String }

    override func bool(forKey defaultName: String) -> Bool {
        let value = object(forKey: defaultName)
        if let number = value as? NSNumber { return number.boolValue }
        return (value as? NSString)?.boolValue ?? false
    }

    override func set(_ value: Any?, forKey defaultName: String) {
        values[defaultName] = value
        guard let file, let data = try? PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    override func set(_ value: Bool, forKey defaultName: String) { set(value as Any, forKey: defaultName) }
}
#endif
