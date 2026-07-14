# Plan 009: Build coordinator off production path

Status: DONE

Add pure UID preference/effective selection policy, mandatory route generation
provenance, `AudioRouteIdentity`, and `DeviceSelectionCoordinator`. Coordinator
accepts immutable snapshots, preserves preferences through fallback/reconnect,
filters virtual outputs before policy resolution, and only emits a route effect
when route identity changes. It is intentionally not wired into legacy runtime
until hardware gates pass.

Verification:

- Same inventory identity across generations emits one apply effect.
- Same UID with new live ID emits one replacement effect without preference write.
- Missing preferred output selects eligible physical fallback and reconnects.
- Full suite passes with 26 executed tests.
