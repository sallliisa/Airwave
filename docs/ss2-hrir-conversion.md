# Convert SS2 SOFA HRIRs for Airwave

`tools/ss2-to-hesuvi/convert.py` converts Meta Reality Labs Research's Sound
Sphere 2 (SS2) `SimpleFreeFieldHRIR` SOFA files into Airwave-compatible
14-channel HeSuVi WAV presets. Generated files are build artifacts and are not
committed.

SS2 is distributed under CC-BY-4.0. Preserve its attribution when sharing a
generated preset and cite the [SS2 dataset and publication][ss2]. SOFA stores
finite impulse responses as `M × R × N`; its `Data.Delay` field is an additional
broadband delay measured in samples. See the [SOFA FIR specification][sofa].

## Dependencies and exact command

Use Python 3.9 through 3.12. The lock contains exact versions and hashes for all
direct and transitive packages: `sofar` validates and reads SOFA/netCDF data,
NumPy performs coordinate and delay processing, SoundFile writes and verifies
IEEE Float32 WAVs, and pytest runs converter tests.

From the repository root:

```bash
python3 -m venv .venv
.venv/bin/python -m pip install --require-hashes -r tools/ss2-to-hesuvi/requirements.lock
.venv/bin/python tools/ss2-to-hesuvi/convert.py \
  HRIRs \
  --output-dir build/ss2-hesuvi \
  --max-angular-error-deg 5 \
  --validate
scripts/validate-ss2-presets.sh build/ss2-hesuvi
```

The converter scans recursively and preserves relative directories. For
example,
`HRIRs/HRIRs_mannequins/KEMAR051123_1_processed.sofa` becomes
`build/ss2-hesuvi/HRIRs_mannequins/KEMAR051123_1_processed.wav` plus a
`.wav.json` manifest. Existing outputs cause failure; pass `--force` only when
intentional replacement is wanted.

The default command loudness-calibrates every preset to the combined binaural
FL/FR impulse energy measured from Airwave's known-good `dht.wav` preset (SHA-256
`76d51aad60700c4376031e6f3f44b9caa1a6980448b4c16926cf816969287c11`).
The metric is the mean of the FL and FR binaural L2 energies, using the four
HRIR tracks Airwave actually convolves for stereo playback. The measured target,
`1.0163817234826116`, is built into the converter so the
result is reproducible without distributing that reference file. To derive the
target from a local reference instead, add:

```bash
--loudness-reference-wav "/path/to/reference.wav"
```

The reference must be a finite, nonempty 14-channel WAV at the same sample
rate as the SOFA input.

## Directions and selection

SOFA's listener-local axes use positive X forward, positive Y left, and
positive Z up. Target directions stay on the horizontal plane:

| Speaker | Target azimuth |
|---|---:|
| Front center (`FC`) | 0° |
| Front left/right (`FL`, `FR`) | +30° / -30° |
| Side left/right (`SL`, `SR`) | +90° / -90° |
| Back left/right (`BL`, `BR`) | +135° / -135° |

The tool converts spherical or Cartesian source metadata into the listener's
local frame, then uses the measurement with the smallest great-circle angular
distance. Exact matches win naturally; equal-distance ties use the lowest SOFA
measurement index. Conversion fails if the closest measurement exceeds
`--max-angular-error-deg` (5° by default).

Current SS2 files contain exact measurements for 0°, ±30°, and ±90°. Their rear
measurements are 132° and 222° (-138°), both 3° from the requested direction.
Selecting measured HRIRs avoids phase smearing or changed interaural cues from
spatial interpolation.

For listening experiments, `--front-azimuth-deg ANGLE` symmetrically changes
only FL and FR from the 30° default. Values greater than 0° through 90° are
accepted and still use the nearest measured SS2 directions. Other speakers and
the HeSuVi channel layout do not change.

Receiver identity comes from `ReceiverPosition`: exactly one receiver must lie
on each side of the listener. The converter never guesses receiver order and
never creates one ear by mirroring another.

## Airwave/HeSuVi channel order

Each row is one mono HRIR track in the interleaved WAV:

| Index | HeSuVi label | Speaker → ear |
|---:|---|---|
| 0 | `L0` | FL → left |
| 1 | `L1` | FL → right |
| 2 | `SL0` | SL → left |
| 3 | `SL1` | SL → right |
| 4 | `RL0` | BL → left |
| 5 | `RL1` | BL → right |
| 6 | `C0` | FC → left |
| 7 | `R1` | FR → right |
| 8 | `R0` | FR → left |
| 9 | `SR1` | SR → right |
| 10 | `SR0` | SR → left |
| 11 | `RR1` | BR → right |
| 12 | `RR0` | BR → left |
| 13 | `C1` | FC → right |

After delay materialization, one global gain matches the FL/FR stereo binaural
energy to the `dht.wav` reference. This corrects SS2's excessive
playback gain without changing ILD, ITD, or directional level ratios; channels
and ears are never normalized independently. No resampling, leading-edge
trimming, independent ear alignment, or symmetry synthesis occurs. Apart from
the declared global gain, zero-delay SS2 sample shape and timing pass unchanged.
Integer `Data.Delay` values become leading zeros. Fractional values use the same
65-tap causal fractional-delay stage for all channels, adding a common group
delay while preserving relative delay; all channels receive equal final length.

## Manifests and validation

Every `.wav.json` manifest records:

- source-relative path and SHA-256;
- SOFA convention, database, listener, license, dimensions, and source IR size;
- output SHA-256, sample rate, frame count, Float32 subtype, and channel count;
- target and selected angles, measurement indices, angular errors, and ear delays;
- complete Airwave channel-to-speaker/ear map.
- loudness reference identity/hash, target and source energy, and linear/dB gain.

`--validate` immediately decodes each output and requires exact Float32 sample
equality with the generated matrix. The repository test suite also covers
coordinate conversion, ear detection, exact/nearest selection, deterministic
ties, angular limits, channel mapping, global loudness calibration, timing and
relative level preservation,
integer/fractional delays, malformed SOFA data, NaNs, overwrite protection, and
manifest determinism.

`scripts/validate-ss2-presets.sh` requires 44 WAVs and 44 manifests, reruns the
Python suite, then runs `SS2PresetValidationTests`. That opt-in Swift test loads
every file through Airwave's `WAVLoader`, confirms 14-channel Float32 metadata,
applies `HRIRChannelMap.hesuvi14Channel`, constructs the stereo convolution
engines, and processes an impulse with finite output.

[ss2]: https://facebookresearch.github.io/SS2_HRTF/
[sofa]: https://www.sofaconventions.org/mediawiki/index.php/SOFA_specifications
