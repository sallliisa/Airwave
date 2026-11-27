import AppKit
import ServiceManagement
import XCTest
@testable import Airwave3

@MainActor
final class AppLifecycleTests: XCTestCase {
    func testLoginEventsLeaveTheWindowClosedBeforeAndAfterSetup() throws {
        let launch = event(kAEOpenApplication)
        launch.setParam(NSAppleEventDescriptor(boolean: true), forKeyword: AEKeyword(keyAELaunchedAsLogInItem))
        let itemLaunch = try XCTUnwrap(HostOpenIntent(event: launch, sender: nil))
        let loginWindowReopen = try XCTUnwrap(
            HostOpenIntent(event: event(kAEReopenApplication), sender: "com.apple.loginwindow")
        )

        for setupComplete in [false, true] {
            var route = HostLaunchRouting()
            XCTAssertNil(route.receive(itemLaunch, setupComplete: setupComplete))
            XCTAssertNil(route.finishLaunching(setupComplete: setupComplete))
            XCTAssertNil(route.receive(loginWindowReopen, setupComplete: setupComplete))
        }
    }

    func testManualColdOpenAndReopenPresentTheCorrectPage() throws {
        let finderLaunch = try XCTUnwrap(
            HostOpenIntent(event: event(kAEOpenApplication), sender: "com.apple.finder")
        )
        let spotlightReopen = try XCTUnwrap(
            HostOpenIntent(event: event(kAEReopenApplication), sender: "com.apple.Spotlight")
        )

        var route = HostLaunchRouting()
        XCTAssertNil(route.receive(finderLaunch, setupComplete: false))
        XCTAssertEqual(route.finishLaunching(setupComplete: false), .setup)
        XCTAssertEqual(route.receive(spotlightReopen, setupComplete: false), .setup)
        XCTAssertEqual(route.receive(spotlightReopen, setupComplete: true), .effects)
    }

    func testSetupCheckpointResumesAndCompletedSetupCanBeRevisited() throws {
        try withDefaults { defaults in
            let shell = ShellModel(defaults: defaults, loginItem: LoginItemStub())
            XCTAssertFalse(shell.setupCompleted)
            XCTAssertFalse(shell.showsMenuBar)
            shell.setupCheckpoint = "effect"
            shell.setMenuBarVisible(true)

            let reopened = ShellModel(defaults: defaults, loginItem: LoginItemStub())
            reopened.showEffects()
            XCTAssertEqual(reopened.page, .setup)
            XCTAssertEqual(reopened.setupCheckpoint, "effect")
            XCTAssertTrue(reopened.showsMenuBar)

            reopened.finishSetup()
            let completed = ShellModel(defaults: defaults, loginItem: LoginItemStub())
            XCTAssertTrue(completed.setupCompleted)
            XCTAssertEqual(completed.page, .effects)
            completed.page = .settings
            completed.showSetup()
            XCTAssertEqual(completed.page, .setup)
            XCTAssertEqual(completed.setupCheckpoint, "welcome")
            completed.returnFromSetup()
            XCTAssertEqual(completed.page, .settings)
        }
    }

    func testLoginIsEnabledOnFirstRunAndRemainsOffIfTheUserDisablesIt() throws {
        try withDefaults { defaults in
            let service = LoginItemStub()
            let shell = ShellModel(defaults: defaults, loginItem: service)
            shell.applyInitialLoginPreference()
            XCTAssertEqual(service.status, .enabled)
            XCTAssertTrue(shell.launchesAtLogin)

            shell.setLaunchAtLogin(false)
            XCTAssertEqual(service.status, .notRegistered)

            let reopened = ShellModel(defaults: defaults, loginItem: service)
            reopened.applyInitialLoginPreference()
            XCTAssertFalse(reopened.launchesAtLogin)
            XCTAssertEqual(service.status, .notRegistered)
        }
    }

    func testFirstRunRetriesLoginRegistrationAfterServiceFailure() throws {
        try withDefaults { defaults in
            let service = LoginItemStub()
            service.registrationError = CocoaError(.fileWriteNoPermission)
            let shell = ShellModel(defaults: defaults, loginItem: service)
            shell.applyInitialLoginPreference()
            XCTAssertFalse(shell.launchesAtLogin)
            XCTAssertNotNil(shell.loginItemError)

            service.registrationError = nil
            shell.applyInitialLoginPreference()
            XCTAssertTrue(shell.launchesAtLogin)
            XCTAssertNil(shell.loginItemError)
        }
    }

    func testSettingsWindowCloseAndOrdinaryQuitKeepTheRetainedWindow() throws {
        let delegate = HostAppDelegate()
        defer {
            _ = delegate.applicationShouldTerminate(NSApp)
            delegate.host.shutdown()
        }
        let existing = Set(NSApp.windows.map(ObjectIdentifier.init))
        delegate.openSetup()
        let first = try XCTUnwrap(NSApp.windows.first(where: {
            $0.identifier == HostWindowLifecycle.settingsID && $0.isVisible
                && !existing.contains(ObjectIdentifier($0))
        }))
        XCTAssertEqual(first.frame.width, HostWindow.contentSize.width)
        XCTAssertEqual(first.contentMinSize, HostWindow.contentSize)
        XCTAssertEqual(first.contentMaxSize, HostWindow.contentSize)
        XCTAssertFalse(first.styleMask.contains(.resizable))
        XCTAssertFalse(delegate.applicationShouldTerminateAfterLastWindowClosed(NSApp))

        first.close()
        XCTAssertFalse(first.isVisible)
        delegate.openSetup()
        XCTAssertTrue(first.isVisible)
        XCTAssertEqual(first.frame.width, HostWindow.contentSize.width)
        XCTAssertTrue(NSApp.windows.contains { $0 === first })

        XCTAssertEqual(delegate.applicationShouldTerminate(NSApp), .terminateCancel)
        XCTAssertFalse(first.isVisible)
        XCTAssertEqual(NSApp.activationPolicy(), .accessory)
        delegate.openSetup()
        XCTAssertTrue(first.isVisible)
    }

    func testPendingLoginApprovalCanBeTurnedOff() throws {
        try withDefaults { defaults in
            let service = LoginItemStub()
            service.status = .requiresApproval
            let shell = ShellModel(defaults: defaults, loginItem: service)

            XCTAssertTrue(shell.launchesAtLogin)
            XCTAssertNotNil(shell.loginItemError)
            shell.setLaunchAtLogin(false)
            XCTAssertFalse(shell.launchesAtLogin)
            XCTAssertNil(shell.loginItemError)
        }
    }

    func testOrdinaryQuitClosesWindowsAndRealQuitReasonsPermitTermination() {
        let standardQuit = event(kAEQuitApplication)
        XCTAssertFalse(HostTermination.isSystemQuit(standardQuit))
        XCTAssertEqual(HostTermination.reply(for: nil), .terminateCancel)
        XCTAssertEqual(HostTermination.reply(for: .explicit), .terminateNow)
        XCTAssertEqual(HostTermination.reply(for: .updateRelaunch), .terminateNow)

        for reason in [kAEShutDown, kAERestart, kAEReallyLogOut] {
            let systemQuit = event(kAEQuitApplication)
            systemQuit.setParam(NSAppleEventDescriptor(enumCode: OSType(reason)), forKeyword: AEKeyword(kAEQuitReason))
            XCTAssertTrue(HostTermination.isSystemQuit(systemQuit))
            XCTAssertEqual(HostTermination.reply(for: .sessionEnding), .terminateNow)
        }
    }

    func testDockFollowsWindowVisibility() {
        XCTAssertEqual(HostWindowLifecycle.activationPolicy(windowIsOpen: false), .accessory)
        XCTAssertEqual(HostWindowLifecycle.activationPolicy(windowIsOpen: true), .regular)
    }

    private func event(_ id: AEEventID) -> NSAppleEventDescriptor {
        NSAppleEventDescriptor(
            eventClass: AEEventClass(kCoreEventClass),
            eventID: id,
            targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
    }

    private func withDefaults(_ test: (UserDefaults) -> Void) throws {
        let domain = "Airwave3.LifecycleTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        test(defaults)
    }
}

@MainActor
private final class LoginItemStub: HostLoginItem {
    var status = SMAppService.Status.notRegistered
    var registrationError: Error?

    func register() throws {
        if let registrationError { throw registrationError }
        status = .enabled
    }
    func unregister() throws { status = .notRegistered }
}
