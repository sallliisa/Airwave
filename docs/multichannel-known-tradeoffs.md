# Multichannel capture — known trade-offs

Written 2026-08-23 when plan 022 (`plans/022-multichannel-capture.md`) was
drafted. The maintainer chose **automatic engagement** (no settings toggle)
for multichannel devices, accepting these consequences for now. Revisit after
the first hardware validation session.

## 1. Surround speakers go silent while Airwave runs on a multichannel device

Airwave's replacement-output architecture mutes native playback and writes
processed audio back to device channels 1–2. On an AVR/HDMI receiver, channels
3+ (surrounds) receive nothing while Airwave is engaged: the user plugged in
headphones for spatial audio but their speaker rig goes quiet rather than
passthrough.

- Why accepted: auto-engagement keeps Airwave set-and-forget; a toggle was
  judged as UI + persisted-state scope not justified before hardware
  validation exists.
- Future options: an opt-in "multichannel processing" toggle per device
  profile; passthrough-hold semantics extended to wide pipelines so teardown
  restores full speaker playback promptly on preset None.
- Trigger to revisit: first hardware validation, or any user report of
  "speakers stopped working with Airwave."

## 2. LFE is omitted from the fold-down

`StereoDownmixGains` maps LFE → (0.0, 0.0): sub/LFE content is dropped rather
than folded into front channels. Rationale: headphone binaural has no LFE
position in HeSuVi-style maps (LFE folds to center there), and folding LFE at
equal power into FC would muddy dialogue anchoring and risk boom on bass-heavy
content.

- Consequence: movies with heavy .1 content lose rumble weight through
  Airwave that they have without it.
- Future options: fold LFE into FL/FR at a low gain (e.g. −6 dB), or into FC;
  make it part of the toggle decision above.
- Trigger to revisit: hardware listening pass; any "bass is missing" report
  tied to multichannel sources.

## 3. Count-based layout fallback can misorder exotic devices

When `kAudioDevicePropertyChannelLayout` labels are missing/unrecognized, the
layout comes from `InputLayout.detect(channelCount:)`, which assumes standard
WAV/Media order. Devices whose stream order differs produce mirrored/reordered
spatialization (front/back swap, side/rear swap).

- Mitigations already in plan: prefer channel labels when present; manual
  checklist step 2 captures logged labels on misorder.
- Trigger to revisit: any misorder report → consider a per-device layout
  override (deferred follow-up).
