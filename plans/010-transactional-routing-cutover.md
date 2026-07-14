# Plan 010: Cut over to transactional routing

Status: BLOCKED — operator hardware smoke matrix required

`AudioRouteTransitionPlanner` now specifies no-op, internal-stop/apply/restart,
and stop/restore/clear effect ordering. Wire this planner and coordinator into
`AudioGraphManager`, `MenuBarViewModel`, and `SettingsView` only after manual
validation on supported devices.

Required manual gates:

1. Auto-start switches physical output to capture device once and remains stable
   for 30 seconds.
2. Settings open/close produces no route/default-output effect.
3. Preferred output disconnect performs one eligible fallback; reconnect returns
   once to preferred UID without persistence mutation.
4. Rapid unplug/replug and aggregate changes produce no stale route or loop.
5. Stop/quit restores physical output exactly once.

Do not flip production routing until every gate passes. Keep legacy path as the
one-release escape hatch during cutover.
