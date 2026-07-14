# Plan 010: Cut over to transactional routing

Status: IN PROGRESS — coordinator default; hardware soak ongoing

`AudioRouteTransitionPlanner` specifies no-op, internal-stop/apply/restart, and
stop/restore/clear effect ordering. Coordinator wiring is now production default.
Legacy routing remains available for one release with hidden launch argument
`-UseLegacyRouting`.

Run opt-in build:

```sh
xcodebuild -project Airwave.xcodeproj -scheme Airwave -configuration Debug \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
APP_PATH=$(find "$HOME/Library/Developer/Xcode/DerivedData" -path '*/Build/Products/Debug/Airwave.app' -print -quit)
open "$APP_PATH"
# Emergency escape hatch:
# open "$APP_PATH" --args -UseLegacyRouting
```

Required manual gates:

1. Auto-start switches physical output to capture device once and remains stable
   for 30 seconds.
2. Settings open/close produces no route/default-output effect.
3. Preferred output disconnect performs one eligible fallback; reconnect returns
   once to preferred UID without persistence mutation.
4. Rapid unplug/replug and aggregate changes produce no stale route or loop.
5. Stop/quit restores physical output exactly once.

Keep legacy path as one-release escape hatch during soak. Do not remove it until
hardware matrix and rapid-reconnect gates pass.
