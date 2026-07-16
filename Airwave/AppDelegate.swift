import AppKit
import Combine
import SwiftUI

@MainActor
protocol ApplicationLifecycleApplication: ApplicationActivationPolicyApplying {
    var windows: [NSWindow] { get }
    func terminate(_ sender: Any?)
}

extension NSApplication: ApplicationLifecycleApplication {}

@MainActor
final class ApplicationLifecycleCoordinator: NSObject {
    static let shared = ApplicationLifecycleCoordinator(
        application: NSApplication.shared
    )

    static let aboutWindowIdentifier = NSUserInterfaceItemIdentifier("com.southneuhof.Airwave.about")

    private let application: ApplicationLifecycleApplication
    private var explicitQuitRequested = false
    private var systemTerminationRequested = false
    private var observesWindows = false
    private var appliedActivationPolicy: NSApplication.ActivationPolicy?
    private var pendingFocusedSpaceDeparture = false
    private var restoreFocusOnSpaceReturn = false
    private var focusDepartureGeneration = 0

    init(
        application: ApplicationLifecycleApplication,
        observeWindows: Bool = true
    ) {
        self.application = application
        super.init()
        guard observeWindows else { return }
        observesWindows = true
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(windowStateChanged), name: NSWindow.willCloseNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(activeSpaceDidChange),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )
    }

    deinit {
        if observesWindows {
            NotificationCenter.default.removeObserver(self)
            NSWorkspace.shared.notificationCenter.removeObserver(self)
        }
    }

    static func activationPolicy(hasVisibleUserWindow: Bool) -> NSApplication.ActivationPolicy {
        hasVisibleUserWindow ? .regular : .accessory
    }

    func prepareToPresentUserWindow() {
        apply(.regular)
    }

    func updateActivationPolicy() {
        let hasVisibleWindow = application.windows.contains(where: Self.isUserFacingWindow)
        updateActivationPolicy(hasVisibleUserWindow: hasVisibleWindow)
    }

    func updateActivationPolicy(hasVisibleUserWindow: Bool) {
        apply(Self.activationPolicy(hasVisibleUserWindow: hasVisibleUserWindow))
    }

    func closeAllUserWindows() {
        application.windows.filter {
            Self.isUserFacingWindow($0) || Self.isMenuBarPopover($0)
        }.forEach { $0.close() }
        updateActivationPolicy(hasVisibleUserWindow: false)
    }

    func requestExplicitQuit() {
        explicitQuitRequested = true
        application.terminate(nil)
    }

    func beginSystemTermination() {
        systemTerminationRequested = true
    }

    func applicationWillResignActive() {
        guard let window = settingsWindow, window.isKeyWindow, !window.isMiniaturized else {
            pendingFocusedSpaceDeparture = false
            return
        }
        pendingFocusedSpaceDeparture = true
        focusDepartureGeneration += 1
        let generation = focusDepartureGeneration
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard generation == focusDepartureGeneration, !restoreFocusOnSpaceReturn else { return }
            pendingFocusedSpaceDeparture = false
        }
    }

    func terminationReply() -> NSApplication.TerminateReply {
        if explicitQuitRequested || systemTerminationRequested {
            explicitQuitRequested = false
            return .terminateNow
        }
        closeAllUserWindows()
        return .terminateCancel
    }

    private func apply(_ policy: NSApplication.ActivationPolicy) {
        guard appliedActivationPolicy != policy else { return }
        guard application.setActivationPolicy(policy) else {
            Logger.log("[Application] Could not apply \(policy == .regular ? "regular" : "accessory") activation policy")
            return
        }
        appliedActivationPolicy = policy
        Logger.log("[Application] Activation policy is \(policy == .regular ? "regular" : "accessory")")
    }

    static func isUserFacingWindow(_ window: NSWindow) -> Bool {
        guard window.isVisible || window.isMiniaturized else { return false }
        if window.identifier == SettingsWindowPresenter.windowIdentifier
            || window.identifier == aboutWindowIdentifier {
            return true
        }
        guard !isMenuBarPopover(window) else { return false }
        return window.canBecomeMain && window.styleMask.contains(.titled) && !window.title.isEmpty
    }

    private static func isMenuBarPopover(_ window: NSWindow) -> Bool {
        guard window.isVisible else { return false }
        let className = window.className.lowercased()
        return className.contains("menubar") || className.contains("popover")
    }

    private var settingsWindow: NSWindow? {
        application.windows.first { $0.identifier == SettingsWindowPresenter.windowIdentifier }
    }

    @objc private func activeSpaceDidChange() {
        guard let window = settingsWindow, !window.isMiniaturized else {
            pendingFocusedSpaceDeparture = false
            restoreFocusOnSpaceReturn = false
            return
        }

        if pendingFocusedSpaceDeparture, !window.isOnActiveSpace {
            pendingFocusedSpaceDeparture = false
            restoreFocusOnSpaceReturn = true
            return
        }

        guard restoreFocusOnSpaceReturn, window.isOnActiveSpace else { return }
        restoreFocusOnSpaceReturn = false
        prepareToPresentUserWindow()
        NSApp.activate(ignoringOtherApps: true)
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func windowStateChanged() {
        Task { @MainActor in
            await Task.yield()
            updateActivationPolicy()
        }
    }
}

@MainActor
enum SettingsPage: String, CaseIterable {
    case general
    case equalizer
    case devices
    case application

    var title: String {
        switch self {
        case .general: "General"
        case .equalizer: "Equalizer"
        case .devices: "Registered Devices"
        case .application: "Application"
        }
    }
}

@MainActor
final class SettingsWindowContentState: ObservableObject {
    enum Mode: Equatable {
        case setup
        case settings
    }

    @Published private(set) var mode: Mode = .settings
    @Published private(set) var canReturnToSettings = false
    @Published private(set) var settingsPage: SettingsPage = .general

    func selectSettingsPage(_ page: SettingsPage) {
        settingsPage = page
    }

    func show(_ mode: Mode, canReturnToSettings: Bool = false) {
        let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.12 : 0.2
        withAnimation(.easeOut(duration: duration)) {
            self.mode = mode
            self.canReturnToSettings = mode == .setup && canReturnToSettings
            if mode == .settings {
                self.settingsPage = .general
            }
        }
    }
}

@MainActor
enum SettingsWindowPresenter {
    static let windowIdentifier = NSUserInterfaceItemIdentifier("com.southneuhof.Airwave.settings")
    static let contentSize = NSSize(width: 900, height: 600)
    private static var settingsWindow: NSWindow?
    private static var settingsWindowController: NSWindowController?
    private static let contentState = SettingsWindowContentState()

    static func register(_ window: NSWindow) {
        settingsWindow = window
        window.identifier = windowIdentifier
        window.collectionBehavior.insert(.moveToActiveSpace)
        configureCustomChrome(window)
        window.styleMask.remove(.resizable)
        let fixedSize = contentSize
        window.contentMinSize = fixedSize
        window.contentMaxSize = fixedSize
        window.standardWindowButton(.zoomButton)?.isEnabled = false
        ApplicationLifecycleCoordinator.shared.prepareToPresentUserWindow()
    }

    private static func configureCustomChrome(_ window: NSWindow) {
        window.styleMask.insert(.fullSizeContentView)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = true
        window.backgroundColor = NSColor(red: 17 / 255, green: 17 / 255, blue: 17 / 255, alpha: 1)
    }

    static func presentExistingWindow() {
        ApplicationLifecycleCoordinator.shared.prepareToPresentUserWindow()
        WindowFronting.present(identifier: windowIdentifier, title: "Settings")
    }

    static func present(_ mode: SettingsWindowContentState.Mode = .settings) {
        contentState.show(
            mode,
            canReturnToSettings: mode == .setup && OnboardingViewModel.shared.isComplete
        )
        if settingsWindow == nil {
            let content = SettingsWindowContent(state: contentState)
                .environmentObject(MenuBarViewModel.shared)
            let controller = NSHostingController(rootView: content)
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: contentSize),
                styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = "Settings"
            window.isReleasedWhenClosed = false
            window.contentViewController = controller
            window.setFrameAutosaveName("com.southneuhof.Airwave.settings.frame")
            let windowController = NSWindowController(window: window)
            windowController.shouldCascadeWindows = true
            settingsWindowController = windowController
            register(window)
            windowController.showWindow(nil)
        }
        presentExistingWindow()
    }
}

@MainActor
private enum WindowFronting {
    static func present(
        identifier: NSUserInterfaceItemIdentifier,
        title: String,
        retriesRemaining: Int = 5
    ) {
        if let window = NSApp.windows.first(where: { $0.identifier == identifier || $0.title == title }) {
            window.identifier = identifier
            window.collectionBehavior.insert(.moveToActiveSpace)
            window.hidesOnDeactivate = false
            if window.isMiniaturized { window.deminiaturize(nil) }

            NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])
            NSApp.activate(ignoringOtherApps: true)
            window.orderFrontRegardless()
            window.makeKeyAndOrderFront(nil)

            Task { @MainActor in
                await Task.yield()
                guard window.isVisible else { return }
                NSApp.activate(ignoringOtherApps: true)
                window.orderFrontRegardless()
                window.makeKeyAndOrderFront(nil)
            }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(150))
                guard window.isVisible else { return }
                NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])
                NSApp.activate(ignoringOtherApps: true)
                window.orderFrontRegardless()
                window.makeKeyAndOrderFront(nil)
            }
            return
        }

        guard retriesRemaining > 0 else { return }
        Task { @MainActor in
            await Task.yield()
            present(identifier: identifier, title: title, retriesRemaining: retriesRemaining - 1)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidBecomeActive(_ notification: Notification) {
        AudioRuntimeController.shared.refreshSystemAudioAccess()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Logger.log("[AppDelegate] Airwave safe shell launched")
        ApplicationLifecycleCoordinator.shared.updateActivationPolicy()
        DeviceProfileRuntimeCoordinator.shared.launch()
        OutputDeviceDiscoveryCoordinator.shared.launch()

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(willSleep),
            name: NSWorkspace.willSleepNotification, object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(didWake),
            name: NSWorkspace.didWakeNotification, object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(willPowerOff),
            name: NSWorkspace.willPowerOffNotification, object: nil
        )

        DispatchQueue.main.async {
            if OnboardingViewModel.shared.shouldPresentAutomatically {
                OnboardingViewModel.shared.prepareForPresentation(.automaticFirstSetup)
                SettingsWindowPresenter.present(.setup)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        AudioRuntimeController.shared.terminate()
        Logger.log("[AppDelegate] Airwave safe shell terminating")
    }

    func applicationWillResignActive(_ notification: Notification) {
        ApplicationLifecycleCoordinator.shared.applicationWillResignActive()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        ApplicationLifecycleCoordinator.shared.terminationReply()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }


    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !MenuBarVisibilityManager.shared.isVisible { SettingsWindowPresenter.present() }
        return true
    }

    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        guard !MenuBarVisibilityManager.shared.isVisible else { return false }
        SettingsWindowPresenter.present()
        return true
    }

    @objc private func willSleep() { AudioRuntimeController.shared.willSleep() }
    @objc private func didWake() { AudioRuntimeController.shared.didWake() }
    @objc private func willPowerOff() { ApplicationLifecycleCoordinator.shared.beginSystemTermination() }
}
