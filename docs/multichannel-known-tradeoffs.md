# Multichannel capture — known trade-offs

Updated 2026-10-04 for configurable stereo output destinations. Airwave always
produces two output signals. In **Settings > Registered Devices > Configure
output…**, users can save distinct left and right destination channels for a
physical device; the pair may be reversed or nonadjacent. Airwave uses a saved
pair, otherwise a valid preferred stereo pair, otherwise channels 1–2. This
does not establish which physical jack a device channel reaches.

Capture remains automatic and separate from destination selection. A normal
stereo source is captured as stereo. Four-channel devices with duplicate
stereo-pair labels or no usable labels use a preferred stereo source pair or
channels 1–2; channel count alone does not identify quad headphones. Surround
input requires a resolvable source layout (standard order is used for
unlabeled 6/8/12-channel layouts). Unknown or mismatched surround layouts can
remain unsupported. The result is downmixed to two output signals, and LFE
content is omitted. Virtual and aggregate outputs remain unsupported. Actual
BOOM jack/source identity and listening behavior have not been validated.

## 1. Surround speakers go silent while Airwave runs on a multichannel device

Airwave's replacement-output architecture mutes native playback and writes its
stereo signal only to the selected left and right device channels. The other
device channels receive no Airwave signal while the route is active; Airwave
does not provide multichannel passthrough. The chosen pair can be any two
distinct destinations, so the exact silent channels depend on the device
assignment.

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

When `kAudioDevicePropertyChannelLayout` labels are missing for a supported
surround input, the shared fallback assumes standard WAV/Media order for
6/8/12-channel layouts. Devices whose stream order differs can produce
mirrored or reordered spatialization (front/back swap, side/rear swap).
Four-channel unlabeled or duplicate-stereo endpoints use a stereo source pair,
not a count-based quad interpretation. Airwave's configurable output channels
select destinations independently of this source-layout decision.

- Mitigations already in plan: prefer channel labels when present; manual
  checklist step 2 captures logged labels on misorder. Actual BOOM jack and
  source mapping, microphone-prefix behavior, multistream behavior, and
  listening checks remain NOT RUN without hardware evidence.
- Trigger to revisit: any misorder report → consider a per-device layout
  override (deferred follow-up).
