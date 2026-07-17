import Foundation
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif
#if canImport(SwiftUI)
import SwiftUI
#endif
#if canImport(DeveloperToolsSupport)
import DeveloperToolsSupport
#endif

#if SWIFT_PACKAGE
private let resourceBundle = Foundation.Bundle.module
#else
private class ResourceBundleClass {}
private let resourceBundle = Foundation.Bundle(for: ResourceBundleClass.self)
#endif

// MARK: - Color Symbols -

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
extension DeveloperToolsSupport.ColorResource {

}

// MARK: - Image Symbols -

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
extension DeveloperToolsSupport.ImageResource {

    /// The "AirwaveIcon" asset catalog image resource.
    static let airwaveIcon = DeveloperToolsSupport.ImageResource(name: "AirwaveIcon", bundle: resourceBundle)

    /// The "AirwaveMark" asset catalog image resource.
    static let airwaveMark = DeveloperToolsSupport.ImageResource(name: "AirwaveMark", bundle: resourceBundle)

    /// The "MenuBarIcon" asset catalog image resource.
    static let menuBarIcon = DeveloperToolsSupport.ImageResource(name: "MenuBarIcon", bundle: resourceBundle)

    /// The "MenuBarIcon.filled" asset catalog image resource.
    static let menuBarIconFilled = DeveloperToolsSupport.ImageResource(name: "MenuBarIcon.filled", bundle: resourceBundle)

    /// The "MenuBarIcon.warning" asset catalog image resource.
    static let menuBarIconWarning = DeveloperToolsSupport.ImageResource(name: "MenuBarIcon.warning", bundle: resourceBundle)

}

// MARK: - Color Symbol Extensions -

#if canImport(AppKit)
@available(macOS 14.0, *)
@available(macCatalyst, unavailable)
extension AppKit.NSColor {

}
#endif

#if canImport(UIKit)
@available(iOS 17.0, tvOS 17.0, *)
@available(watchOS, unavailable)
extension UIKit.UIColor {

}
#endif

#if canImport(SwiftUI)
@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
extension SwiftUI.Color {

}

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
extension SwiftUI.ShapeStyle where Self == SwiftUI.Color {

}
#endif

// MARK: - Image Symbol Extensions -

#if canImport(AppKit)
@available(macOS 14.0, *)
@available(macCatalyst, unavailable)
extension AppKit.NSImage {

    /// The "AirwaveIcon" asset catalog image.
    static var airwaveIcon: AppKit.NSImage {
#if !targetEnvironment(macCatalyst)
        .init(resource: .airwaveIcon)
#else
        .init()
#endif
    }

    /// The "AirwaveMark" asset catalog image.
    static var airwaveMark: AppKit.NSImage {
#if !targetEnvironment(macCatalyst)
        .init(resource: .airwaveMark)
#else
        .init()
#endif
    }

    /// The "MenuBarIcon" asset catalog image.
    static var menuBarIcon: AppKit.NSImage {
#if !targetEnvironment(macCatalyst)
        .init(resource: .menuBarIcon)
#else
        .init()
#endif
    }

    /// The "MenuBarIcon.filled" asset catalog image.
    static var menuBarIconFilled: AppKit.NSImage {
#if !targetEnvironment(macCatalyst)
        .init(resource: .menuBarIconFilled)
#else
        .init()
#endif
    }

    /// The "MenuBarIcon.warning" asset catalog image.
    static var menuBarIconWarning: AppKit.NSImage {
#if !targetEnvironment(macCatalyst)
        .init(resource: .menuBarIconWarning)
#else
        .init()
#endif
    }

}
#endif

#if canImport(UIKit)
@available(iOS 17.0, tvOS 17.0, *)
@available(watchOS, unavailable)
extension UIKit.UIImage {

    /// The "AirwaveIcon" asset catalog image.
    static var airwaveIcon: UIKit.UIImage {
#if !os(watchOS)
        .init(resource: .airwaveIcon)
#else
        .init()
#endif
    }

    /// The "AirwaveMark" asset catalog image.
    static var airwaveMark: UIKit.UIImage {
#if !os(watchOS)
        .init(resource: .airwaveMark)
#else
        .init()
#endif
    }

    /// The "MenuBarIcon" asset catalog image.
    static var menuBarIcon: UIKit.UIImage {
#if !os(watchOS)
        .init(resource: .menuBarIcon)
#else
        .init()
#endif
    }

    /// The "MenuBarIcon.filled" asset catalog image.
    static var menuBarIconFilled: UIKit.UIImage {
#if !os(watchOS)
        .init(resource: .menuBarIconFilled)
#else
        .init()
#endif
    }

    /// The "MenuBarIcon.warning" asset catalog image.
    static var menuBarIconWarning: UIKit.UIImage {
#if !os(watchOS)
        .init(resource: .menuBarIconWarning)
#else
        .init()
#endif
    }

}
#endif

// MARK: - Thinnable Asset Support -

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
@available(watchOS, unavailable)
extension DeveloperToolsSupport.ColorResource {

    private init?(thinnableName: Swift.String, bundle: Foundation.Bundle) {
#if canImport(AppKit) && os(macOS)
        if AppKit.NSColor(named: NSColor.Name(thinnableName), bundle: bundle) != nil {
            self.init(name: thinnableName, bundle: bundle)
        } else {
            return nil
        }
#elseif canImport(UIKit) && !os(watchOS)
        if UIKit.UIColor(named: thinnableName, in: bundle, compatibleWith: nil) != nil {
            self.init(name: thinnableName, bundle: bundle)
        } else {
            return nil
        }
#else
        return nil
#endif
    }

}

#if canImport(UIKit)
@available(iOS 17.0, tvOS 17.0, *)
@available(watchOS, unavailable)
extension UIKit.UIColor {

    private convenience init?(thinnableResource: DeveloperToolsSupport.ColorResource?) {
#if !os(watchOS)
        if let resource = thinnableResource {
            self.init(resource: resource)
        } else {
            return nil
        }
#else
        return nil
#endif
    }

}
#endif

#if canImport(SwiftUI)
@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
extension SwiftUI.Color {

    private init?(thinnableResource: DeveloperToolsSupport.ColorResource?) {
        if let resource = thinnableResource {
            self.init(resource)
        } else {
            return nil
        }
    }

}

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
extension SwiftUI.ShapeStyle where Self == SwiftUI.Color {

    private init?(thinnableResource: DeveloperToolsSupport.ColorResource?) {
        if let resource = thinnableResource {
            self.init(resource)
        } else {
            return nil
        }
    }

}
#endif

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
@available(watchOS, unavailable)
extension DeveloperToolsSupport.ImageResource {

    private init?(thinnableName: Swift.String, bundle: Foundation.Bundle) {
#if canImport(AppKit) && os(macOS)
        if bundle.image(forResource: NSImage.Name(thinnableName)) != nil {
            self.init(name: thinnableName, bundle: bundle)
        } else {
            return nil
        }
#elseif canImport(UIKit) && !os(watchOS)
        if UIKit.UIImage(named: thinnableName, in: bundle, compatibleWith: nil) != nil {
            self.init(name: thinnableName, bundle: bundle)
        } else {
            return nil
        }
#else
        return nil
#endif
    }

}

#if canImport(AppKit)
@available(macOS 14.0, *)
@available(macCatalyst, unavailable)
extension AppKit.NSImage {

    private convenience init?(thinnableResource: DeveloperToolsSupport.ImageResource?) {
#if !targetEnvironment(macCatalyst)
        if let resource = thinnableResource {
            self.init(resource: resource)
        } else {
            return nil
        }
#else
        return nil
#endif
    }

}
#endif

#if canImport(UIKit)
@available(iOS 17.0, tvOS 17.0, *)
@available(watchOS, unavailable)
extension UIKit.UIImage {

    private convenience init?(thinnableResource: DeveloperToolsSupport.ImageResource?) {
#if !os(watchOS)
        if let resource = thinnableResource {
            self.init(resource: resource)
        } else {
            return nil
        }
#else
        return nil
#endif
    }

}
#endif

