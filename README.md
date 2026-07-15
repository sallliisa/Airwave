# Airwave 2.0

Airwave applies system-wide stereo HRIR convolution on macOS without changing the default output device or its volume. Version 2 uses Core Audio process taps: macOS remains the only authority for output selection and volume.

## Requirements

- macOS 15 Sequoia or later
- A physical stereo output supported by macOS
- A HeSuVi-compatible 7- or 14-channel HRIR WAV preset
- System Audio Capture permission

BlackHole, public aggregate devices, and other virtual routing software are neither required nor supported. If macOS currently uses one as its output, Airwave stays in native passthrough and asks you to choose a physical stereo output in System Settings.

## Install

Download Airwave from [GitHub Releases](https://github.com/sallliisa/Airwave/releases), or install the Homebrew cask after its 2.0 checksum is published.

Airwave is currently distributed without Apple notarization. On first launch, macOS may require **System Settings → Privacy & Security → Open Anyway**.

## Set up

1. Open Airwave and choose **Manage HRIR Files**.
2. Copy a compatible stereo HRIR WAV file into the presets folder.
3. Select the preset from Airwave's menu.
4. Grant **System Audio Capture** permission when macOS asks. This is system-audio capture; Airwave does not request microphone access.

Processing starts automatically when a preset, permission, and supported output are ready. There is no audio-engine toggle. Output changes are made only in macOS; Airwave follows the current default output automatically.

Airwave never changes macOS volume. If capture, output, or permission becomes unavailable, Airwave releases its private audio objects and native audio continues unprocessed. Status and recovery guidance appear in the menu and Settings.

## Upgrading from Airwave 1.x

Airwave 2.0 is a clean break. Version 1.x used BlackHole and user-created aggregate routing; remove that old routing manually if you no longer need it. Airwave 2.0 will warn when a virtual or aggregate output remains selected, but will never change the selection for you. HRIR files remain on disk; other 1.x preferences and Launch at Login state are reset.

macOS 14 users remain on Airwave 1.x. Airwave 2.0 requires macOS 15 and must not be offered by Sparkle or Homebrew to older systems.

## Validation status

Automated lifecycle, cleanup, DSP, metadata, and invariant checks run in CI. Hardware support claims require recorded physical validation. See [release validation](docs/release-validation.md); device classes marked **NOT TESTED** are not claimed as validated.

## License and credits

Airwave is licensed under GPLv3. It is inspired by HeSuVi and supports third-party HRIR datasets from the HeSuVi HRTF Database. Airwave is independently developed and is not affiliated with HeSuVi.

For bugs and feature requests, [open a GitHub issue](https://github.com/sallliisa/Airwave/issues).
