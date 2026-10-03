import AppKit
import Foundation

@MainActor
final class ApplicationLifecycleCoordinator: NSObject {
    static let shared = ApplicationLifecycleCoordinator(
        application: NSApplication.shared
    )

    static let aboutWindowIdentifier = NSUserInterfaceItemIdentifier("com.southneuhof.Airwave.about")

    private let application: ApplicationLifecycleApplication
    private var explicitQuitRequested = false
    private var systemTerminationRequested = false
    private var updateRelaunchTerminationRequested = false
    private var observesWindows = false
    private var appliedActivationPolicy: NSApplication.ActivationPolicy?
    private var pendingFocusedSpaceDeparture = false
    private var restoreFocusOnSpaceReturn = false
    private var focusDepartureGeneration = 0
    private weak var departingFocusWindow: NSWindow?
    private let focusWindowState: (NSWindow) -> FocusWindowState
    private let activateApplication: () -> Void
    private let restoreWindow: (NSWindow) -> Void

    struct FocusWindowState {
        let isKeyWindow: Bool
        let isMiniaturized: Bool
        let isOnActiveSpace: Bool
    }

    init(
        application: ApplicationLifecycleApplication,
        observeWindows: Bool = true,
        focusWindowState: @escaping (NSWindow) -> FocusWindowState = { window in
            FocusWindowState(
                isKeyWindow: window.isKeyWindow,
                isMiniaturized: window.isMiniaturized,
                isOnActiveSpace: window.isOnActiveSpace
            )
        },
        activateApplication: @escaping () -> Void = {
            NSApp.activate(ignoringOtherApps: true)
        },
        restoreWindow: @escaping (NSWindow) -> Void = { window in
            window.orderFrontRegardless()
            window.makeKeyAndOrderFront(nil)
        }
    ) {
        self.application = application
        self.focusWindowState = focusWindowState
        self.activateApplication = activateApplication
        self.restoreWindow = restoreWindow
        super.init()
        guard observeWindows else { return }
        observesWindows = true
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(trackedWindowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(trackedWindowDidMiniaturize(_:)),
            name: NSWindow.didMiniaturizeNotification,
            object: nil
        )
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

    func beginUpdateRelaunchTermination() {
        updateRelaunchTerminationRequested = true
    }

    func applicationWillResignActive() {
        guard let window = focusTrackedWindow else {
            if !restoreFocusOnSpaceReturn {
                clearFocusDeparture()
            }
            return
        }
        restoreFocusOnSpaceReturn = false
        departingFocusWindow = window
        pendingFocusedSpaceDeparture = true
        focusDepartureGeneration += 1
        let generation = focusDepartureGeneration
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard generation == focusDepartureGeneration, !restoreFocusOnSpaceReturn else { return }
            pendingFocusedSpaceDeparture = false
            departingFocusWindow = nil
        }
    }

    /// Handles active-space notifications using the window that was key when
    /// Airwave lost focus. The seam lets tests model Spaces without activating
    /// or ordering real application windows.
    func handleActiveSpaceDidChange() {
        guard let window = departingFocusWindow else {
            clearFocusDeparture()
            return
        }
        let state = focusWindowState(window)
        guard !state.isMiniaturized else {
            clearFocusDeparture()
            return
        }

        if pendingFocusedSpaceDeparture, !state.isOnActiveSpace {
            pendingFocusedSpaceDeparture = false
            restoreFocusOnSpaceReturn = true
            return
        }

        guard restoreFocusOnSpaceReturn, state.isOnActiveSpace else { return }
        clearFocusDeparture()
        prepareToPresentUserWindow()
        activateApplication()
        restoreWindow(window)
    }

    func handleTrackedWindowInvalidation(_ window: NSWindow) {
        guard departingFocusWindow === window else { return }
        clearFocusDeparture()
    }

    func terminationReply() -> NSApplication.TerminateReply {
        if explicitQuitRequested || systemTerminationRequested || updateRelaunchTerminationRequested {
            explicitQuitRequested = false
            updateRelaunchTerminationRequested = false
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

    /// SwiftUI gives the menu bar extra's popover no identifier, so the class
    /// name is the only handle. One definition, used by every caller.
    static func isMenuBarPopover(_ window: NSWindow) -> Bool {
        guard window.isVisible else { return false }
        let className = window.className.lowercased()
        return className.contains("menubar") || className.contains("popover")
    }

    private var focusTrackedWindow: NSWindow? {
        application.windows.first { window in
            let isTracked = window.identifier == SettingsWindowPresenter.windowIdentifier
            let state = focusWindowState(window)
            return isTracked && state.isKeyWindow && !state.isMiniaturized
        }
    }

    @objc private func activeSpaceDidChange() {
        handleActiveSpaceDidChange()
    }

    @objc private func trackedWindowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow {
            handleTrackedWindowInvalidation(window)
        }
        updateActivationPolicyAfterWindowChange()
    }

    @objc private func trackedWindowDidMiniaturize(_ notification: Notification) {
        if let window = notification.object as? NSWindow {
            handleTrackedWindowInvalidation(window)
        }
    }

    private func updateActivationPolicyAfterWindowChange() {
        Task { @MainActor in
            await Task.yield()
            updateActivationPolicy()
        }
    }

    private func clearFocusDeparture() {
        focusDepartureGeneration += 1
        pendingFocusedSpaceDeparture = false
        restoreFocusOnSpaceReturn = false
        departingFocusWindow = nil
    }
}

@MainActor
protocol ApplicationActivationPolicyApplying: AnyObject {
    @discardableResult
    func setActivationPolicy(_ activationPolicy: NSApplication.ActivationPolicy) -> Bool
}

extension NSApplication: ApplicationActivationPolicyApplying {}
