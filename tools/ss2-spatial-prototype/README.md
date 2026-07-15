# SS2 clean-room spatial prototypes

This experimental personal-use tool measures only aggregate spatial traits from
an unknown 14-channel reference, then synthesizes new presets from the
CC-BY-4.0 SS2 `HATS051123_1` measurements. The generator cannot read the
reference WAV and never copies samples, phase, or reflection taps.

The stored metrics are direction-level ILD, peak ITD, zero-lag interaural
correlation, normalized per-ear third-octave magnitude, third-octave late-field
energy, and cumulative late energy at 5, 10, 20, and 50 ms. They contain no
reference samples or phase. The generated ambience comes from deterministic
all-pass networks and receives only coarse checkpoint-envelope fitting.

From the repository root:

```bash
.venv/bin/python tools/ss2-spatial-prototype/analyze.py \
  HRIRs/sample/forum++.wav \
  --output build/ss2-spatial-prototypes/forumpp.metrics.json

.venv/bin/python tools/ss2-spatial-prototype/generate.py \
  HRIRs/HRIRs_mannequins/HATS051123_1_processed.sofa \
  --reference-metrics build/ss2-spatial-prototypes/forumpp.metrics.json \
  --output-dir build/ss2-spatial-prototypes/candidates \
  --install-dir "$HOME/Library/Containers/com.southneuhof.Airwave/Data/Library/Application Support/Airwave/presets"
```

Existing files require `--force`. Outputs are 14-channel, 48 kHz, Float32 WAVs
with 8,192 frames. Listen in this order: unmodified HATS control,
`B_minphase_only`, `A_tail_only`, `C_minphase_low_space`, then
`D_minphase_target_space`.

For the second listening round, the spatial topology and seed are locked to D.
Three candidates progressively apply the reference's broad per-ear tonal
envelope and direction-level ILD while preserving each HATS channel's energy:

```bash
.venv/bin/python tools/ss2-spatial-prototype/generate.py \
  HRIRs/HRIRs_mannequins/HATS051123_1_processed.sofa \
  --reference-metrics build/ss2-spatial-prototypes/forumpp.metrics.json \
  --output-dir build/ss2-spatial-prototypes/v2-candidates \
  --install-dir "$HOME/Library/Containers/com.southneuhof.Airwave/Data/Library/Application Support/Airwave/presets" \
  --v2-tone-matching
```

Listen in this order: original `D_minphase_target_space`, `V2_D_tone50`,
`V2_D_tone75`, then `V2_D_tone100`. These apply 50%, 75%, and 100% of the
coarse tone correction. V2 permits at most 0.35 dB of additional third-octave
change from the fixed spatial synthesis and 1.25 percentage points of
late-energy fitting error.

V3 addresses the two defects found during V2 listening: independent
minimum-phase reconstruction collapsed interaural timing, and sparse all-pass
feedback produced a pitched metallic tail. V3 retains the original HATS phase
and timing, uses the full coarse tone/ILD match, and synthesizes a deterministic
dense velvet-noise tail with no feedback loop:

```bash
.venv/bin/python tools/ss2-spatial-prototype/generate.py \
  HRIRs/HRIRs_mannequins/HATS051123_1_processed.sofa \
  --reference-metrics build/ss2-spatial-prototypes/forumpp.metrics.json \
  --output-dir build/ss2-spatial-prototypes/v3-candidates \
  --install-dir "$HOME/Library/Containers/com.southneuhof.Airwave/Data/Library/Application Support/Airwave/presets" \
  --v3-diffuse
```

The V3 preset is `HATS051123_1_V3_phase_diffuse_tone100.wav`. Its tail begins
after 5 ms, uses 25%-density deterministic velvet noise with a 45 ms decay,
and receives one final broad causal tone correction. The generator verifies
source-rate Float32 output, HATS peak ITD retention, reference ILD, decay
checkpoints, equal front-stereo energy, and reproducibility.

These prototypes and their unknown reference are not licensed for inclusion in
Airwave. A future public preset requires a separate provenance, licensing,
similarity, and listening review.
