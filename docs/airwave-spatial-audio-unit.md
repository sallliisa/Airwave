# Use the Airwave Spatial Audio Unit

Use Airwave Spatial to add headphone spatialization to stereo audio in a host that supports AUv3 effects. You need Airwave 2.2.0 or later, macOS 15 or later, and stereo headphones. The host sends audio to the plugin and routes the output to your headphones.

## Install and add the effect

1. Install `Airwave.app` in Applications. [Airwave installation instructions](../README.md#installation)
2. Open Airwave once so macOS can register the Audio Unit. You can then quit Airwave and use the plugin in your host.
3. Open your host. If it was already running, rescan its Audio Units or restart it.
4. Add **Airwave Spatial** to a stereo track to process that track, or to the stereo output effects chain to process the mix. Some hosts list it as **Spatial** under **Airwave**.
5. Play stereo audio through the effects chain. Open the plugin and toggle **Bypass** to compare the original stereo signal with the spatial effect.

## Try it in REAPER

1. Open a project with a stereo audio item and choose **View > Master Track**.
2. Click **FX** on the master track. If the FX browser is closed, click **Add**.
3. Search for `Spatial` and add **AU: Spatial (Airwave)**.
4. Play the project. Select **Neutral** in the **HRIR preset** menu and toggle **Bypass** while you listen.

For headphone monitoring that stays out of exported mixes, put the effect in **View > Monitoring FX**. For headphone EQ, add **ReaEQ** after Airwave Spatial in the same chain. [REAPER User Guide](https://dlx.reaper.fm/userguide/html/)

## Use your own HRIR

1. Open the plugin and choose **HRIR preset > Import WAV…**.
2. Choose a HeSuVi head-related impulse response (HRIR) WAV with 7 or 14 channels and up to 0.5 seconds of audio. For a sample file, download [StageSH1.0.wav](../assets/hrtf/StageSH1.0.wav).
3. Confirm that the menu shows the imported file name. Save your project to keep the WAV and **Bypass** setting with that plugin instance in hosts that save Audio Unit state.

Select **Neutral** to return to the bundled preset. Reimport your WAV when you want to switch back.

## Verify latency and CPU

From the Airwave checkout on macOS with Xcode installed, run `scripts/verify-spatial-render.sh`. To check an imported preset too, pass its WAV path as the first argument.

The verifier renders impulses through the optimized Audio Unit and compares each input-to-ear response with the preset WAV across varying callback sizes. It checks for zero added frames, immediate dry bypass, and the resampled response at 44.1 kHz for 48 kHz presets. Neutral's left-to-left response first reaches 1% of its peak at frame 163 (3.40 ms at 48 kHz). That timing is part of the recorded filter.

For 64-, 128-, and 512-frame callbacks, the verifier reports process CPU time as a percentage of one core per second of audio, plus the 99th-percentile and longest callback durations. Repeat on the same Mac under comparable load. These measurements cover the in-process Audio Unit. To measure the whole playback route, send an impulse through the host and record a wired output loopback on a synchronized input, then compare effect-enabled and bypassed captures at the same device buffer size.

## Troubleshoot

- **The effect is missing.** Check that your host supports AUv3 effects. Open Airwave from Applications, then restart the host and look for **Spatial** under **Airwave**.
- **Playback sounds the same.** Check that the host is playing through the stereo chain that contains Airwave Spatial. Enable the effect in the host and clear **Bypass** in the plugin.
- **The WAV import fails.** Check the channel count and duration, then try the sample WAV above to confirm that import works in your host.
