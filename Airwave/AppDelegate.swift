import AppKit

@MainActor
enum SettingsWindowPresenter {
    static let windowIdentifier = NSUserInterfaceItemIdentifier("com.southneuhof.Airwave.settings")

    static func register(_ window: NSWindow) {
        window.identifier = windowIdentifier
        window.collectionBehavior.insert(.moveToActiveSpace)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Logger.log("[AppDelegate] Airwave safe shell launched")
    }

    func applicationWillTerminate(_ notification: Notification) {
        Logger.log("[AppDelegate] Airwave safe shell terminating")
    }
}
