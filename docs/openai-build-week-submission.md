# OpenAI Build Week submission draft

Use this as the source of truth while completing the Devpost form. Replace every bracketed field before submitting.

## Submission fields

- **Project name:** Airwave
- **Tagline:** Make your Mac headphones feel like speakers.
- **Track:** Apps for Your Life
- **Platform:** macOS 15 Sequoia or later
- **Repository:** https://github.com/sallliisa/Airwave
- **Download:** https://github.com/sallliisa/Airwave/releases
- **Demo video:** [PUBLIC YOUTUBE URL — REQUIRED]
- **Codex Session ID:** [PRIMARY /feedback SESSION ID — REQUIRED]

## Description

Airwave is a native macOS menu-bar app that turns ordinary stereo headphones into a wider, more speaker-like listening experience. It captures system audio, applies head-related impulse response (HRIR) convolution, and sends the processed result back through the Mac’s existing output—without replacing the user’s output device or changing system volume.

Airwave is built for people who spend their day in headphones: music listeners, developers, remote workers, and anyone who wants spatial audio without a second routing app. The first-run setup explains the permission flow, verifies capture with an audible test, and guides the user to a spatial preset. After setup, users can switch between Neutral, Room, and Stage profiles, import compatible HeSuVi HRIR WAVs, and optionally apply EqualizerAPO presets. Profiles are remembered per physical output, so different headphones keep their own settings.

The important product decision is that native macOS audio remains authoritative. Unsupported outputs, permission failures, output changes, sleep/wake, and teardown failures fall back to safe guidance or native passthrough. The real-time path is allocation-free and covered by tests for callback sizes, finite output, canary safety, crossfades, and lifecycle recovery.

## How Codex contributed

During the Build Week window, Codex was used to break the Core Audio work into explicit lifecycle contracts, implement and refactor SwiftUI and Core Audio components, generate focused XCTest coverage, and iterate on release-safety validation. The most important Codex-assisted work was:

- replacing legacy route mutation with a private process-tap pipeline that follows the current physical output;
- adding safe recovery for permission changes, output changes, sleep/wake, and failed cleanup;
- adding per-device HRIR/EQ profiles and real-time parametric EQ;
- rebuilding onboarding and settings around truthful capture states and actionable recovery;
- adding audio-safety invariant scripts and regression tests.

The dated commit history documents the Build Week work. The primary Codex thread used to build the core functionality is provided in the Devpost `/feedback` field: **[INSERT SESSION ID]**.

## Testing instructions for judges

1. Download the latest release from the Releases link above.
2. Open `Airwave.app` on macOS 15 or later and move it to Applications.
3. Connect stereo headphones and select them as the macOS output.
4. Complete the setup wizard. Allow System Audio Capture when macOS asks.
5. Choose `NeutralSH1.0`, `RoomSH1.0`, or `StageSH1.0`, then play any system audio.
6. Open Settings to switch spatial profiles, choose an EQ preset, or inspect the remembered profile for the current output.

Airwave does not request microphone access. The repository also includes the full XCTest suite and release-validation scripts.

## Demo video outline (keep under three minutes)

- **0:00–0:15 — Problem:** Headphones usually sound inside the head; system-wide spatial audio is often difficult to configure safely.
- **0:15–0:35 — Product:** Show Airwave’s menu-bar presence and explain that it follows the existing Mac output and volume.
- **0:35–1:05 — Setup:** Show the capture test and HRIR preset selection.
- **1:05–1:35 — Core demo:** Play system audio, switch Neutral → Room → Stage, and show the settings status.
- **1:35–1:55 — Personalization:** Show per-device profiles and EqualizerAPO preset selection.
- **1:55–2:20 — Safety:** Show the native output remaining selected, then briefly show recovery guidance for an unavailable/unsupported output.
- **2:20–2:50 — Build story:** Show the repository, tests, and one or two dated commits; explain how Codex helped with the audio lifecycle, tests, and product surface.

Record clean system audio or narration only. Do not include copyrighted music or third-party trademarks without permission.

## Final pre-submit checklist

- [ ] Join the hackathon on Devpost.
- [ ] Replace the demo video placeholder with a public YouTube URL.
- [ ] Replace the Codex Session ID placeholder with the exact `/feedback` Session ID.
- [ ] Confirm the repository is public and the GPLv3 license is visible.
- [ ] Confirm the release download link works on a clean macOS 15 machine.
- [ ] Verify the YouTube video is under three minutes and contains both a clear demo and the Codex/GPT-5.6 build story.
- [ ] Submit before **July 21, 2026 at 5:00 PM PDT**.
