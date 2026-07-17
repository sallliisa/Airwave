#import <Foundation/Foundation.h>

#if __has_attribute(swift_private)
#define AC_SWIFT_PRIVATE __attribute__((swift_private))
#else
#define AC_SWIFT_PRIVATE
#endif

/// The "AirwaveIcon" asset catalog image resource.
static NSString * const ACImageNameAirwaveIcon AC_SWIFT_PRIVATE = @"AirwaveIcon";

/// The "AirwaveMark" asset catalog image resource.
static NSString * const ACImageNameAirwaveMark AC_SWIFT_PRIVATE = @"AirwaveMark";

/// The "MenuBarIcon" asset catalog image resource.
static NSString * const ACImageNameMenuBarIcon AC_SWIFT_PRIVATE = @"MenuBarIcon";

/// The "MenuBarIcon.filled" asset catalog image resource.
static NSString * const ACImageNameMenuBarIconFilled AC_SWIFT_PRIVATE = @"MenuBarIcon.filled";

/// The "MenuBarIcon.warning" asset catalog image resource.
static NSString * const ACImageNameMenuBarIconWarning AC_SWIFT_PRIVATE = @"MenuBarIcon.warning";

#undef AC_SWIFT_PRIVATE
