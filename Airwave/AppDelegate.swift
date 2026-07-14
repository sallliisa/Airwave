//
//  AppDelegate.swift
//  Airwave
//
//  Created by gamer on 22/11/25.
//

import AppKit

@MainActor
enum SettingsWindowPresenter {
    static let windowIdentifier = NSUserInterfaceItemIdentifier("com.southneuhof.Airwave.settings")

    static func register(_ window: NSWindow) {
        window.identifier = windowIdentifier
        window.collectionBehavior.insert(.moveToActiveSpace)
    }

    static func presentExistingWindow() {
        presentExistingWindow(retriesRemaining: 4)
    }

    private static func presentExistingWindow(retriesRemaining: Int) {
        if let window = NSApp.windows.first(where: {
            $0.identifier == windowIdentifier || $0.title == "Settings"
        }) {
            present(window)
            return
        }

        guard retriesRemaining > 0 else { return }
        Task { @MainActor in
            await Task.yield()
            presentExistingWindow(retriesRemaining: retriesRemaining - 1)
        }
    }

    static func present(_ window: NSWindow) {
        register(window)
        window.hidesOnDeactivate = false

        if window.isMiniaturized {
            window.deminiaturize(nil)
        }

        NSRunningApplication.current.activate(options: [
            .activateIgnoringOtherApps,
            .activateAllWindows
        ])
        NSApp.activate(ignoringOtherApps: true)
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)

        // Activation of an accessory/menu-bar app can complete on the next run-loop turn.
        // Repeat the ordering after activation settles without changing the window level.
        Task { @MainActor in
            await Task.yield()
            guard window.isVisible else { return }
            NSRunningApplication.current.activate(options: [
                .activateIgnoringOtherApps,
                .activateAllWindows
            ])
            NSApp.activate(ignoringOtherApps: true)
            window.orderFrontRegardless()
            window.makeKeyAndOrderFront(nil)
        }

        // The menu-bar popover may finish dismissing after the first activation pass.
        // Re-assert focus once that dismissal has completed.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard window.isVisible else { return }
            NSRunningApplication.current.activate(options: [
                .activateIgnoringOtherApps,
                .activateAllWindows
            ])
            NSApp.activate(ignoringOtherApps: true)
            window.orderFrontRegardless()
            window.makeKeyAndOrderFront(nil)
        }
    }
}

@MainActor
enum OnboardingWindowPresenter {
    static let windowIdentifier = NSUserInterfaceItemIdentifier("com.southneuhof.Airwave.onboarding")

    static func register(_ window: NSWindow) {
        window.identifier = windowIdentifier
        window.collectionBehavior.insert(.moveToActiveSpace)
    }

    static func presentExistingWindow() {
        presentExistingWindow(retriesRemaining: 5)
    }

    private static func presentExistingWindow(retriesRemaining: Int) {
        if let window = NSApp.windows.first(where: {
            $0.identifier == windowIdentifier || $0.title == "Set up Airwave"
        }) {
            present(window)
            return
        }

        guard retriesRemaining > 0 else { return }
        Task { @MainActor in
            await Task.yield()
            presentExistingWindow(retriesRemaining: retriesRemaining - 1)
        }
    }

    static func present(_ window: NSWindow) {
        register(window)
        window.hidesOnDeactivate = false

        if window.isMiniaturized {
            window.deminiaturize(nil)
        }

        NSRunningApplication.current.activate(options: [
            .activateIgnoringOtherApps,
            .activateAllWindows
        ])
        NSApp.activate(ignoringOtherApps: true)
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)

        Task { @MainActor in
            await Task.yield()
            guard window.isVisible else { return }
            NSRunningApplication.current.activate(options: [
                .activateIgnoringOtherApps,
                .activateAllWindows
            ])
            NSApp.activate(ignoringOtherApps: true)
            window.orderFrontRegardless()
            window.makeKeyAndOrderFront(nil)
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard window.isVisible else { return }
            NSRunningApplication.current.activate(options: [
                .activateIgnoringOtherApps,
                .activateAllWindows
            ])
            NSApp.activate(ignoringOtherApps: true)
            window.orderFrontRegardless()
            window.makeKeyAndOrderFront(nil)
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    private var signalSources: [DispatchSourceSignal] = []
    private var terminationHandled = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !RuntimeEnvironment.isTestHost else { return }
        // Safety check: Restore system audio if app crashed while on BlackHole
        checkAndRestoreSystemAudio()
        
        // Setup signal handlers to catch Xcode stop/termination
        setupSignalHandlers()
    }
    
    /// Setup signal handlers to catch termination from Xcode or system
    private func setupSignalHandlers() {
        let signals: [Int32] = [SIGTERM, SIGINT, SIGQUIT]
        for signalValue in signals {
            signal(signalValue, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalValue, queue: .main)
            source.setEventHandler { [weak self] in
                self?.handleTermination(signal: signalValue)
            }
            source.resume()
            signalSources.append(source)
        }
    }
    
    /// Handle termination - restore system audio with volume matching
    private func handleTermination(signal: Int32? = nil) {
        guard !terminationHandled else { return }
        terminationHandled = true

        if let signalValue = signal {
            Logger.log("[AppDelegate] Caught signal \(signalValue) - restoring audio before exit")
        }

        let audioManager = AudioGraphManager.shared
        if audioManager.isRunning {
            Logger.log("[AppDelegate] Stopping audio engine before termination")
            audioManager.stop()
        }

        if signal != nil {
            NSApp.terminate(nil)
        }
    }
    
    /// Check if system audio is on BlackHole but engine is off, and restore if needed
    /// This handles the case where the app crashed while the engine was running
    private func checkAndRestoreSystemAudio() {
        let deviceManager = AudioDeviceManager.shared
        let audioManager = AudioGraphManager.shared
        
        // Get current system default output
        guard let currentOutput = deviceManager.getSystemDefaultOutputDevice() else {
            return
        }
        
        // Check if system is currently on BlackHole
        let isOnBlackHole = VirtualAudioDriver.isBlackHole(deviceName: currentOutput.name)
        
        // Check if audio engine is NOT running
        let engineNotRunning = !audioManager.isRunning
        
        // If on BlackHole but engine is off, restore saved device
        if isOnBlackHole && engineNotRunning {
            Logger.log("[AppDelegate] Detected BlackHole system output with engine off - attempting recovery")
            let restored = deviceManager.restoreSavedOutputDevice()
            
            if restored {
                Logger.log("[AppDelegate] ✅ System audio restored after detected crash")
            } else {
                Logger.log("[AppDelegate] ⚠️ Could not restore system audio - no saved device found")
            }
        }
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        // If audio engine is running, stop it (which will restore system audio)
        handleTermination()
    }
}
