import AppKit
import Combine
import OSLog
import ServiceManagement

enum ShellPage: Equatable {
    case setup
    case effects
    case mixer
    case settings
}

@MainActor
protocol HostLoginItem: AnyObject {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

extension SMAppService: HostLoginItem {}

@MainActor
final class ShellModel: ObservableObject {
    @Published var page: ShellPage
    @Published private(set) var setupCompleted: Bool
    @Published var setupCheckpoint: String {
        didSet { defaults.set(setupCheckpoint, forKey: Self.setupCheckpointKey) }
    }
    @Published private(set) var showsMenuBar: Bool
    @Published private(set) var launchesAtLogin = false
    @Published private(set) var loginItemError: String?

    private static let setupCompletedKey = "Host.Application.SetupCompleted"
    private static let setupCheckpointKey = "Host.Application.SetupCheckpoint"
    private static let menuBarKey = "Host.Application.ShowInMenuBar"
    private static let initialLoginPreferenceKey = "Host.Application.InitialLoginPreferenceApplied"

    private let defaults: UserDefaults
    private let loginItem: any HostLoginItem
    private var setupReturnPage: ShellPage = .effects

    init(defaults: UserDefaults, loginItem: any HostLoginItem, initialSetupCompleted: Bool = false) {
        self.defaults = defaults
        self.loginItem = loginItem
        let complete = defaults.object(forKey: Self.setupCompletedKey) == nil
            ? initialSetupCompleted
            : defaults.bool(forKey: Self.setupCompletedKey)
        setupCompleted = complete
        page = complete ? .effects : .setup
        let checkpoint = defaults.string(forKey: Self.setupCheckpointKey)
        setupCheckpoint = ["welcome", "capture", "effect", "finish"].first { $0 == checkpoint } ?? "welcome"
        showsMenuBar = defaults.bool(forKey: Self.menuBarKey)
        refreshLoginItem()
    }

    func showSetup() {
        if setupCompleted, page != .setup {
            setupReturnPage = page
            setupCheckpoint = "welcome"
        }
        page = .setup
    }

    func returnFromSetup() {
        if setupCompleted { page = setupReturnPage }
    }

    func finishSetup() {
        setupCompleted = true
        defaults.set(true, forKey: Self.setupCompletedKey)
        showEffects()
    }

    func showEffects() {
        page = setupCompleted ? .effects : .setup
    }

    func setMenuBarVisible(_ value: Bool) {
        guard showsMenuBar != value else { return }
        showsMenuBar = value
        defaults.set(value, forKey: Self.menuBarKey)
    }

    static func applyUpgradePreferences(to defaults: UserDefaults, completed: Bool?, showsMenuBar: Bool?) {
        if let completed, defaults.object(forKey: setupCompletedKey) == nil {
            defaults.set(completed, forKey: setupCompletedKey)
        }
        if let showsMenuBar, defaults.object(forKey: menuBarKey) == nil {
            defaults.set(showsMenuBar, forKey: menuBarKey)
        }
        defaults.set(true, forKey: initialLoginPreferenceKey)
    }

    func applyInitialLoginPreference() {
        guard !defaults.bool(forKey: Self.initialLoginPreferenceKey) else { return }
        setLaunchAtLogin(true)
        if launchesAtLogin {
            defaults.set(true, forKey: Self.initialLoginPreferenceKey)
        }
    }

    func setLaunchAtLogin(_ enable: Bool) {
        refreshLoginItem()
        guard launchesAtLogin != enable else { return }
        do {
            if enable { try loginItem.register() }
            else { try loginItem.unregister() }
            refreshLoginItem()
        } catch {
            refreshLoginItem()
            loginItemError = "Could not change Launch at Login. \(error.localizedDescription)"
        }
    }

    func refreshLoginItem() {
        let status = loginItem.status
        launchesAtLogin = status == .enabled || status == .requiresApproval
        loginItemError = status == .requiresApproval
            ? "Allow Airwave under Login Items in System Settings."
            : nil
    }
}

enum HostOpenIntent: Equatable {
    case login
    case manual

    init?(event: NSAppleEventDescriptor, sender: String?) {
        guard event.eventClass == AEEventClass(kCoreEventClass),
              [AEEventID(kAEOpenApplication), AEEventID(kAEReopenApplication)].contains(event.eventID) else {
            return nil
        }
        let hasLoginMarker = event.paramDescriptor(forKeyword: AEKeyword(keyAELaunchedAsLogInItem)) != nil
        self = hasLoginMarker || sender == "com.apple.loginwindow" ? .login : .manual
    }
}

struct HostLaunchRouting {
    private enum Phase {
        case starting(pendingOpen: Bool)
        case running
    }

    private var phase = Phase.starting(pendingOpen: false)

    mutating func receive(_ intent: HostOpenIntent, setupComplete: Bool) -> ShellPage? {
        guard intent == .manual else { return nil }
        if case .starting = phase {
            phase = .starting(pendingOpen: true)
            return nil
        }
        return setupComplete ? .effects : .setup
    }

    mutating func finishLaunching(setupComplete: Bool) -> ShellPage? {
        guard case .starting(let pendingOpen) = phase else { return nil }
        phase = .running
        guard pendingOpen else { return nil }
        return receive(.manual, setupComplete: setupComplete)
    }
}

enum HostTermination {
    case explicit
    case sessionEnding
    case updateRelaunch

    static func isSystemQuit(_ event: NSAppleEventDescriptor?) -> Bool {
        guard let event, event.eventClass == AEEventClass(kCoreEventClass),
              event.eventID == AEEventID(kAEQuitApplication),
              let reason = event.paramDescriptor(forKeyword: AEKeyword(kAEQuitReason)) else {
            return false
        }
        return [OSType(kAEQuitAll), OSType(kAEShutDown), OSType(kAERestart), OSType(kAEReallyLogOut)]
            .contains(reason.enumCodeValue)
    }

    static func reply(for reason: HostTermination?) -> NSApplication.TerminateReply {
        reason == nil ? .terminateCancel : .terminateNow
    }
}

@MainActor
final class HostWindowLifecycle: NSObject {
    static let settingsID = NSUserInterfaceItemIdentifier("com.southneuhof.SystemAudioHost.settings")
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "SystemAudioHost", category: "Windows")

    private enum SpaceFocus {
        case idle
        case leaving
        case away
    }

    private weak var departingWindow: NSWindow?
    private var focus = SpaceFocus.idle
    private var focusTimeout: Task<Void, Never>?

    func start() {
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(windowWillClose(_:)), name: NSWindow.willCloseNotification, object: nil)
        center.addObserver(self, selector: #selector(windowMiniaturized(_:)), name: NSWindow.didMiniaturizeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(activeSpaceChanged),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )
        updateActivationPolicy()
    }

    func stop() {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        clearSpaceFocus()
    }

    static func activationPolicy(windowIsOpen: Bool) -> NSApplication.ActivationPolicy {
        windowIsOpen ? .regular : .accessory
    }

    func updateActivationPolicy() {
        let policy = Self.activationPolicy(windowIsOpen: NSApp.windows.contains(where: Self.isUserWindow))
        apply(policy)
    }

    func front(_ window: NSWindow) {
        apply(.regular)
        if window.isMiniaturized { window.deminiaturize(nil) }
        focusWindow(window)
        Task { @MainActor [weak window] in
            await Task.yield()
            guard let window, window.isVisible, !window.isMiniaturized else { return }
            self.focusWindow(window)
        }
    }

    func closeMenuBarPopover() {
        NSApp.windows.first(where: Self.isMenuBarPopover)?.close()
    }

    func closeUserWindows() {
        NSApp.windows.filter { Self.isUserWindow($0) || Self.isMenuBarPopover($0) }.forEach { $0.close() }
        apply(.accessory)
    }

    func willResignActive() {
        guard let window = NSApp.keyWindow, window.identifier == Self.settingsID, !window.isMiniaturized else {
            return
        }
        clearSpaceFocus()
        departingWindow = window
        focus = .leaving
        focusTimeout = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(500)) }
            catch { return }
            guard let self, self.focus == .leaving else { return }
            self.clearSpaceFocus()
        }
    }

    @objc private func activeSpaceChanged() {
        guard let window = departingWindow, window.isVisible, !window.isMiniaturized else {
            clearSpaceFocus()
            return
        }
        switch (focus, window.isOnActiveSpace) {
        case (.leaving, false):
            focus = .away
            focusTimeout?.cancel()
            focusTimeout = nil
        case (.away, true):
            clearSpaceFocus()
            front(window)
        default:
            break
        }
    }

    @objc private func windowWillClose(_ notification: Notification) {
        windowMiniaturized(notification)
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.updateActivationPolicy()
        }
    }

    @objc private func windowMiniaturized(_ notification: Notification) {
        if notification.object as? NSWindow === departingWindow { clearSpaceFocus() }
    }

    private func clearSpaceFocus() {
        departingWindow = nil
        focus = .idle
        focusTimeout?.cancel()
        focusTimeout = nil
    }

    private func apply(_ policy: NSApplication.ActivationPolicy) {
        guard NSApp.activationPolicy() != policy else { return }
        if !NSApp.setActivationPolicy(policy) { Self.logger.error("Could not change the activation policy") }
    }

    private func focusWindow(_ window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
    }

    private static func isUserWindow(_ window: NSWindow) -> Bool {
        guard window.isVisible || window.isMiniaturized, !isMenuBarPopover(window) else { return false }
        return window.identifier == settingsID
            || (window.canBecomeMain && window.styleMask.contains(.titled) && !window.title.isEmpty)
    }

    static func isMenuBarPopover(_ window: NSWindow) -> Bool {
        guard window.isVisible else { return false }
        let name = window.className.lowercased()
        return name.contains("menubar") || name.contains("popover")
    }
}
