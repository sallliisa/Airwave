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
3. Select the preset for the current output from Airwave's menu.
4. Grant **System Audio Capture** permission when macOS asks. This is system-audio capture; Airwave does not request microphone access.

Each supported physical stereo output has its own persistent HRIR and EQ profile. The Settings selector shows available supported outputs, so you can configure one before it becomes the macOS default. New devices start at **None / None**; a profile saves only when you first choose an HRIR or EQ preset, not when Airwave observes the device. Processing starts automatically when the selected profile, permission, and supported output are ready. There is no audio-engine toggle. Output changes are made only in macOS; Airwave follows the current default output automatically.

Airwave never changes macOS volume. If capture, output, or permission becomes unavailable, Airwave releases its private audio objects and native audio continues unprocessed. Status and recovery guidance appear in the menu and Settings.

## Equalizer

Airwave ships no headphone curves and does not recommend any preset. Import an EqualizerAPO-style `.txt` file from **Settings → Equalizer**; files are copied into Airwave's managed `Equalizer Presets` folder. Imports add to the library but do not select a preset for any device. EQ selection is persistent per supported output, and **None** is the default for new devices. Imported presets are read-only in Airwave.

The supported v1 subset is `Preamp` plus `Filter` directives using `PK`, `LSC`, or `HSC`, each with frequency, gain, and Q. Preamp is applied exactly as written. Airwave has no limiter and does not add automatic headroom. EQ can run alone; when combined with spatial processing, the order is HRIR first, then EQ. See the upstream [Equalizer APO configuration reference](https://sourceforge.net/p/equalizerapo/wiki/Configuration%20reference/) for the source syntax.

## Device management

Open **Settings → Devices** from the General page to review saved output profiles. The top-bar selector shows currently available supported outputs plus saved profiles whose devices are unavailable; Devices manages saved profiles only. **Reset Profile** atomically returns both HRIR and EQ to **None**. **Forget Device** removes a saved profile and is available only for devices marked **Not Current**. Both actions require confirmation. Airwave never changes output selection or volume.

## Upgrading from Airwave 1.x

Airwave 2.0 is a clean break. Version 1.x used BlackHole and user-created aggregate routing; remove that old routing manually if you no longer need it. Airwave 2.0 will warn when a virtual or aggregate output remains selected, but will never change the selection for you. HRIR files remain on disk; other 1.x preferences and Launch at Login state are reset.

macOS 14 users remain on Airwave 1.x. Airwave 2.0 requires macOS 15 and must not be offered by Sparkle or Homebrew to older systems.

## Validation status

Automated lifecycle, cleanup, DSP, metadata, and invariant checks run in CI. Hardware support claims require recorded physical validation. See [release validation](docs/release-validation.md); device classes marked **NOT TESTED** are not claimed as validated.

## License and credits

Airwave is licensed under GPLv3. It is inspired by HeSuVi and supports third-party HRIR datasets from the HeSuVi HRTF Database. Airwave is independently developed and is not affiliated with HeSuVi.

For bugs and feature requests, [open a GitHub issue](https://github.com/sallliisa/Airwave/issues).
