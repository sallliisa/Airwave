# Airwave 3 release rehearsal

The release workflow selects the `Airwave3` scheme for 3.x. The archive contains one `Airwave.app` with the existing bundle ID, macOS 15 minimum, and Intel and Apple silicon slices. It embeds the Spatial and Equalizer Audio Units. The workflow signs the ZIP for Airwave's existing Sparkle feed and updates the existing Homebrew cask.

## Build and check a local candidate

1. Use full Xcode. Run the `Airwave3` and `Airwave3UI` scheme tests in Debug, then clean. Airwave 3 CI runs on pushes and pull requests targeting the v3 branches.
2. Archive the `Airwave3` scheme for generic macOS in Release with `ARCHS="arm64 x86_64"`. Set the version and build number on the archive command so the app and both extensions carry the same release metadata.
3. Package the app with `ditto -c -k --sequesterRsrc --keepParent`. Run `scripts/verify-release-audio-unit.sh Airwave_v3.0.0.zip 3.0.0 3000000 --package-only` to verify signatures, component identifiers, executable slices, and the bundled preset files.
4. In an isolated macOS test environment, run the same verifier without `--package-only` to register and validate both Audio Units from the packaged app.

## Rehearse the upgrade in an isolated test environment

1. Install the public Airwave 2.2.0 release. Configure saved profiles for connected and offline outputs. Use a custom HRIR, an EQ config with an included file or impulse response, and a nondefault stereo pair on a supported interface. Record the existing menu bar and login choices.
2. Test the Sparkle upgrade using the candidate archive in a private feed. Check that the new app opens the existing device chains, that Spatial precedes EQ where both were configured, and that permissions and login items behave as expected. Open **Controls** for each built-in effect and check its preset picker for assigned and unassigned presets. Repeat launch to check that the imported chains and presets survive subsequent edits.
3. Play the same source on the same output before and after updating. Check Bluetooth, a multichannel interface, the saved left/right pair, routing-only mode, and bypass. Reopen a DAW session saved with Airwave Spatial and compare its preset and playback.
4. Test a clean install and a Homebrew upgrade. Check the app icon, bundled Spatial and EQ presets, and both plug-in editors.

Airwave 3 imports valid Airwave 2 presets into the Audio Units' personal presets and leaves the source files in place. Each effect instance keeps a copy of its assigned preset. If an assigned preset cannot be opened, its effect stays bypassed until the user chooses a replacement in **Controls**. The other effects and devices keep their imported settings.
