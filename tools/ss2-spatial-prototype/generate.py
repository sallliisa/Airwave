#!/usr/bin/env python3
"""Generate clean-room spatial variants from SS2 and aggregate metrics only."""

from __future__ import annotations

import argparse
import importlib.util
import json
from pathlib import Path
import shutil
import sys
from typing import Sequence

import numpy as np
import soundfile

from spatial import (
    DIRECTION_PAIRS,
    OUTPUT_FRAMES,
    PrototypeError,
    SAMPLE_RATE,
    VARIANTS,
    canonicalize_wav_metadata,
    direction_metrics,
    front_stereo_energy,
    load_metrics,
    maximum_tonal_deviation_db,
    maximum_reference_tone_error_db,
    pad_to_frames,
    condition_base_to_reference,
    sha256_file,
    synthesize_diffuse_variant,
    synthesize_variant,
    write_json,
)


TOOL_DIR = Path(__file__).resolve().parent
CONVERTER_PATH = TOOL_DIR.parent / "ss2-to-hesuvi" / "convert.py"
SEED_VERSION = "ss2-spatial-prototype-v1"
V2_VARIANTS = (
    ("V2_D_tone50", "D spatial model with 50% forum++ coarse tone match", 0.5),
    ("V2_D_tone75", "D spatial model with 75% forum++ coarse tone match", 0.75),
    ("V2_D_tone100", "D spatial model with full forum++ coarse tone match", 1.0),
)
V3_VARIANT = (
    "V3_phase_diffuse_tone100",
    "Original HATS interaural phase with full coarse tone/ILD match and dense diffuse ambience",
)


def _load_converter():
    specification = importlib.util.spec_from_file_location("ss2_converter", CONVERTER_PATH)
    if specification is None or specification.loader is None:
        raise PrototypeError(f"Cannot load SS2 converter from {CONVERTER_PATH}")
    module = importlib.util.module_from_spec(specification)
    sys.modules[specification.name] = module
    specification.loader.exec_module(module)
    return module


def _base_from_sofa(source: Path):
    if source.name != "HATS051123_1_processed.sofa":
        raise PrototypeError("This prototype is locked to HATS051123_1_processed.sofa")
    converter = _load_converter()
    data = converter.read_ss2_sofa(source)
    if data.sample_rate != SAMPLE_RATE:
        raise PrototypeError(f"Prototype requires {SAMPLE_RATE} Hz SS2 input")
    if "CC-BY-4.0" not in data.license_name:
        raise PrototypeError(f"Expected CC-BY-4.0 SS2 source, got {data.license_name!r}")
    selections = converter.select_directions(data, 5.0)
    raw, delays = converter.build_output(data, selections)
    calibrated, _, gain = converter.calibrate_loudness(
        raw, converter.DEFAULT_LOUDNESS_REFERENCE
    )
    return data, selections, delays, calibrated.astype(np.float64), gain


def _output_metrics(samples: np.ndarray) -> dict:
    return {
        speaker: direction_metrics(samples, SAMPLE_RATE, *indices)
        for speaker, indices in DIRECTION_PAIRS.items()
    }


def _validate_candidate(
    *,
    name: str,
    base: np.ndarray,
    candidate: np.ndarray,
    metrics: dict,
    minimum_phase: bool,
    ambience_intensity: float,
    tonal_deviation: float,
    match_reference_ild: bool = False,
    tonal_guard_db: float = 0.25,
    late_energy_guard: float = 0.01,
) -> dict:
    if candidate.shape != (OUTPUT_FRAMES, 14):
        raise PrototypeError(f"{name} has invalid shape {candidate.shape}")
    if not np.all(np.isfinite(candidate)) or float(np.max(np.abs(candidate))) >= 1.0:
        raise PrototypeError(f"{name} is non-finite or reaches a peak of 1.0")
    source_energy = front_stereo_energy(pad_to_frames(base))
    output_energy = front_stereo_energy(candidate)
    if not np.isclose(source_energy, output_energy, rtol=1e-7, atol=1e-8):
        raise PrototypeError(f"{name} front-stereo energy differs from HATS")
    if tonal_deviation > tonal_guard_db + 1e-9:
        raise PrototypeError(
            f"{name} tonal deviation {tonal_deviation:.6f} dB exceeds "
            f"{tonal_guard_db:.2f} dB"
        )

    actual = _output_metrics(candidate)
    base_metrics = _output_metrics(pad_to_frames(base))
    for speaker in DIRECTION_PAIRS:
        actual_itd = int(actual[speaker]["peak_itd_samples_right_minus_left"])
        if minimum_phase:
            if abs(actual_itd) > 1:
                raise PrototypeError(f"{name}/{speaker} peak ITD is not aligned")
        else:
            base_itd = int(base_metrics[speaker]["peak_itd_samples_right_minus_left"])
            if abs(actual_itd - base_itd) > 1:
                raise PrototypeError(f"{name}/{speaker} changed HATS peak ITD")
        for checkpoint in (5, 10, 20, 50):
            expected = (
                float(metrics["directions"][speaker]["late_energy_ratios"][str(checkpoint)])
                * ambience_intensity
            )
            measured = float(actual[speaker]["late_energy_ratios"][str(checkpoint)])
            if abs(measured - expected) > late_energy_guard + 1e-9:
                raise PrototypeError(
                    f"{name}/{speaker} {checkpoint} ms late-energy error exceeds "
                    "one percentage point"
                )
        if match_reference_ild:
            expected_ild = float(metrics["directions"][speaker]["left_right_level_db"])
            measured_ild = float(actual[speaker]["left_right_level_db"])
            if abs(measured_ild - expected_ild) > 0.25:
                raise PrototypeError(f"{name}/{speaker} ILD differs by more than 0.25 dB")
    return actual


def _manifest(
    *,
    data,
    selections,
    delays: Sequence[float],
    base: np.ndarray,
    candidate: np.ndarray,
    variant_name: str,
    description: str,
    use_minimum_phase: bool,
    ambience_intensity: float,
    parameters: dict,
    metrics_path: Path,
    metrics: dict,
    output_path: Path,
    output_hash: str,
    tonal_deviation: float,
    loudness_gain: float,
    tone_match_strength: float,
    reference_tone_error: float,
    tail_model: str = "cascaded-allpass",
) -> dict:
    return {
        "schema_version": 1,
        "personal_use_only": True,
        "clean_room_method": {
            "reference_access": "Generator reads aggregate JSON only, never reference audio.",
            "direct_field": "SS2 HATS051123_1 measured samples",
            "spatial_layer": tail_model,
            "seed_version": SEED_VERSION,
        },
        "source": {
            "name": data.source_path.name,
            "sha256": data.source_hash,
            "database": data.database_name,
            "listener": data.listener_short_name,
            "license": data.license_name,
            "sample_rate_hz": data.sample_rate,
            "ir_frames": int(data.impulse_responses.shape[2]),
            "base_loudness_gain": loudness_gain,
        },
        "aggregate_reference": {
            "metrics_name": metrics_path.name,
            "metrics_sha256": sha256_file(metrics_path),
            "reference_name": metrics["reference"]["name"],
            "reference_sha256": metrics["reference"]["sha256"],
            "contains_reference_samples": False,
        },
        "variant": {
            "name": variant_name,
            "description": description,
            "minimum_phase": use_minimum_phase,
            "ambience_intensity": ambience_intensity,
            "tone_match_strength": tone_match_strength,
            "reference_ild_matching": tone_match_strength > 0,
            "tail_model": tail_model,
            "parameters": parameters,
        },
        "directions": [
            {
                "speaker": speaker,
                "measurement_index": selection.measurement_index,
                "target_azimuth_deg": selection.target_azimuth_deg,
                "actual_azimuth_deg": selection.actual_azimuth_deg,
                "actual_elevation_deg": selection.actual_elevation_deg,
                "angular_error_deg": selection.angular_error_deg,
            }
            for speaker, selection in selections.items()
        ],
        "channel_map": [
            {
                "index": index,
                "speaker": speaker,
                "ear": ear,
                "source_delay_samples": float(delays[index]),
            }
            for index, (speaker, ear) in enumerate(_load_converter().CHANNEL_LAYOUT)
        ],
        "validation": {
            "base_front_stereo_energy": front_stereo_energy(pad_to_frames(base)),
            "output_front_stereo_energy": front_stereo_energy(candidate),
            "maximum_third_octave_deviation_db": tonal_deviation,
            "maximum_reference_tone_error_db": reference_tone_error,
            "peak": float(np.max(np.abs(candidate))),
            "directions": _output_metrics(candidate),
        },
        "output": {
            "name": output_path.name,
            "sha256": output_hash,
            "sample_rate_hz": SAMPLE_RATE,
            "frames": OUTPUT_FRAMES,
            "channels": 14,
            "wav_subtype": "FLOAT",
        },
    }


def generate(
    source: Path,
    metrics_path: Path,
    output_dir: Path,
    install_dir: Path | None,
    force: bool,
    v2_tone_matching: bool = False,
    v3_diffuse: bool = False,
) -> list[Path]:
    metrics = load_metrics(metrics_path)
    data, selections, delays, base, loudness_gain = _base_from_sofa(source)
    output_dir.mkdir(parents=True, exist_ok=True)
    if install_dir is not None:
        install_dir.mkdir(parents=True, exist_ok=True)

    outputs: list[Path] = []
    if v2_tone_matching and v3_diffuse:
        raise PrototypeError("Choose only one experimental generation mode")
    if v3_diffuse:
        variant_specs = [(V3_VARIANT[0], V3_VARIANT[1], False, 1.0, 1.0)]
    elif v2_tone_matching:
        variant_specs = [
            (name, description, True, 1.0, strength)
            for name, description, strength in V2_VARIANTS
        ]
    else:
        variant_specs = [
            (name, description, minimum_phase, intensity, 0.0)
            for name, description, minimum_phase, intensity in VARIANTS
        ]

    for variant_name, description, minimum_phase, intensity, tone_strength in variant_specs:
        output_path = output_dir / f"HATS051123_1_{variant_name}.wav"
        manifest_path = output_path.with_suffix(".wav.json")
        install_path = install_dir / output_path.name if install_dir is not None else None
        conflicts = [path for path in (output_path, manifest_path, install_path) if path and path.exists()]
        if conflicts and not force:
            raise PrototypeError(f"Output exists (use --force): {conflicts[0]}")

        conditioned_base = (
            condition_base_to_reference(base, metrics, tone_strength)
            if tone_strength > 0
            else base
        )
        # V2 deliberately keeps D's deterministic spatial topology constant;
        # only the broad tonal conditioning strength changes between candidates.
        seed_variant = "D_minphase_target_space" if v2_tone_matching else variant_name
        seed = f"{SEED_VERSION}:{data.source_hash}:{seed_variant}"
        if v3_diffuse:
            candidate, parameters = synthesize_diffuse_variant(
                conditioned_base, metrics, intensity, seed
            )
            # The diffuse addition is intentionally time-domain and may tilt
            # broad magnitude slightly. Correct that tilt once without
            # reconstructing or aligning the HATS interaural phase.
            candidate = condition_base_to_reference(candidate, metrics, 1.0).astype(
                np.float32
            )
            tail_model = "dense-velvet-noise"
        else:
            candidate, parameters = synthesize_variant(
                conditioned_base,
                metrics,
                use_minimum_phase=minimum_phase,
                ambience_intensity=intensity,
                seed_prefix=seed,
            )
            tail_model = "cascaded-allpass"
        tonal_deviation = maximum_tonal_deviation_db(
            pad_to_frames(conditioned_base), candidate
        )
        reference_tone_error = maximum_reference_tone_error_db(candidate, metrics)
        _validate_candidate(
            name=variant_name,
            base=conditioned_base,
            candidate=candidate,
            metrics=metrics,
            minimum_phase=minimum_phase,
            ambience_intensity=intensity,
            tonal_deviation=tonal_deviation,
            match_reference_ild=tone_strength > 0,
            tonal_guard_db=2.0 if v3_diffuse else 0.35 if tone_strength > 0 else 0.25,
            late_energy_guard=0.0125 if tone_strength > 0 else 0.01,
        )
        soundfile.write(
            str(output_path), candidate, SAMPLE_RATE, format="WAV", subtype="FLOAT"
        )
        canonicalize_wav_metadata(output_path)
        decoded, decoded_rate = soundfile.read(
            str(output_path), dtype="float32", always_2d=True
        )
        if decoded_rate != SAMPLE_RATE or not np.array_equal(decoded, candidate):
            raise PrototypeError(f"Float32 round-trip validation failed: {output_path}")
        output_hash = sha256_file(output_path)
        manifest = _manifest(
            data=data,
            selections=selections,
            delays=delays,
            base=conditioned_base,
            candidate=candidate,
            variant_name=variant_name,
            description=description,
            use_minimum_phase=minimum_phase,
            ambience_intensity=intensity,
            parameters=parameters,
            metrics_path=metrics_path,
            metrics=metrics,
            output_path=output_path,
            output_hash=output_hash,
            tonal_deviation=tonal_deviation,
            loudness_gain=loudness_gain,
            tone_match_strength=tone_strength,
            reference_tone_error=reference_tone_error,
            tail_model=tail_model,
        )
        write_json(manifest_path, manifest)
        if install_path is not None:
            shutil.copy2(output_path, install_path)
        outputs.append(output_path)
    return outputs


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path, help="HATS051123_1 SS2 SOFA file")
    parser.add_argument("--reference-metrics", required=True, type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument("--install-dir", type=Path)
    parser.add_argument("--force", action="store_true")
    parser.add_argument(
        "--v2-tone-matching",
        action="store_true",
        help="Generate D-spatial 50/75/100%% coarse tone and ILD matched variants",
    )
    parser.add_argument(
        "--v3-diffuse",
        action="store_true",
        help="Generate phase-preserving tone100 with non-periodic diffuse ambience",
    )
    args = parser.parse_args()
    try:
        outputs = generate(
            args.source.resolve(),
            args.reference_metrics.resolve(),
            args.output_dir.resolve(),
            args.install_dir.resolve() if args.install_dir else None,
            args.force,
            args.v2_tone_matching,
            args.v3_diffuse,
        )
        for output in outputs:
            print(output)
        print(f"Generated {len(outputs)} clean-room personal-use prototypes")
        return 0
    except (PrototypeError, OSError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
