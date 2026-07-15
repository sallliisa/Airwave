#!/usr/bin/env python3
"""Convert SS2 SimpleFreeFieldHRIR SOFA files to Airwave/HeSuVi WAVs."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
from dataclasses import dataclass
from pathlib import Path
import sys
from typing import Dict, List, Sequence, Tuple

import numpy as np
import sofar as sf
import soundfile as soundfile


TARGET_AZIMUTHS: Dict[str, float] = {
    "FC": 0.0,
    "FL": 30.0,
    "FR": -30.0,
    "SL": 90.0,
    "SR": -90.0,
    "BL": 135.0,
    "BR": -135.0,
}

# Airwave/HeSuVi order. Ear names refer to headphone output ears, not speaker side.
CHANNEL_LAYOUT: Tuple[Tuple[str, str], ...] = (
    ("FL", "left"),
    ("FL", "right"),
    ("SL", "left"),
    ("SL", "right"),
    ("BL", "left"),
    ("BL", "right"),
    ("FC", "left"),
    ("FR", "right"),
    ("FR", "left"),
    ("SR", "right"),
    ("SR", "left"),
    ("BR", "right"),
    ("BR", "left"),
    ("FC", "right"),
)

FRACTIONAL_DELAY_TAPS = 65
EPSILON = 1e-9

# Mean FL/FR binaural L2 energy measured from the known-good Airwave preset
# dht.wav. These are the four HRIR tracks used by Airwave's stereo render path.
# A single gain is applied to the complete 14-channel matrix, so interaural and
# directional level differences remain unchanged.
DEFAULT_LOUDNESS_TARGET = 1.0163817234826116
DEFAULT_REFERENCE_SHA256 = (
    "76d51aad60700c4376031e6f3f44b9caa1a6980448b4c16926cf816969287c11"
)
DEFAULT_REFERENCE_SAMPLE_RATE = 48_000


class ConversionError(RuntimeError):
    """Raised when conversion cannot preserve the SOFA data safely."""


@dataclass(frozen=True)
class DirectionSelection:
    speaker: str
    target_azimuth_deg: float
    measurement_index: int
    actual_azimuth_deg: float
    actual_elevation_deg: float
    angular_error_deg: float


@dataclass(frozen=True)
class LoudnessReference:
    name: str
    sha256: str
    sample_rate: int
    front_stereo_binaural_energy: float


@dataclass
class SofaData:
    source_path: Path
    source_hash: str
    listener_short_name: str
    database_name: str
    license_name: str
    sample_rate: int
    impulse_responses: np.ndarray
    delays: np.ndarray
    source_vectors: np.ndarray
    source_azimuths: np.ndarray
    source_elevations: np.ndarray
    left_receiver: int
    right_receiver: int


DEFAULT_LOUDNESS_REFERENCE = LoudnessReference(
    name="dht.wav",
    sha256=DEFAULT_REFERENCE_SHA256,
    sample_rate=DEFAULT_REFERENCE_SAMPLE_RATE,
    front_stereo_binaural_energy=DEFAULT_LOUDNESS_TARGET,
)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def front_stereo_binaural_energy(samples: np.ndarray) -> float:
    array = np.asarray(samples, dtype=np.float64)
    if array.ndim != 2 or array.shape[0] == 0 or array.shape[1] != 14:
        raise ConversionError("Loudness data must be a non-empty 14-channel matrix")
    if not np.all(np.isfinite(array)):
        raise ConversionError("Loudness data contains NaN or infinite samples")
    channel_energies = np.linalg.norm(array, axis=0)
    # FL is tracks 0/1. FR is tracks 8/7 in HeSuVi's asymmetric order.
    speaker_energies = (
        math.hypot(channel_energies[0], channel_energies[1]),
        math.hypot(channel_energies[8], channel_energies[7]),
    )
    result = float(np.mean(speaker_energies))
    if not np.isfinite(result) or result <= EPSILON:
        raise ConversionError("Loudness data has no usable impulse energy")
    return result


def read_loudness_reference(path: Path) -> LoudnessReference:
    try:
        samples, sample_rate = soundfile.read(
            str(path), dtype="float64", always_2d=True
        )
    except (OSError, RuntimeError) as error:
        raise ConversionError(f"Cannot read loudness reference WAV: {error}") from error
    return LoudnessReference(
        name=path.name,
        sha256=sha256_file(path),
        sample_rate=int(sample_rate),
        front_stereo_binaural_energy=front_stereo_binaural_energy(samples),
    )


def calibrate_loudness(
    samples: np.ndarray, reference: LoudnessReference
) -> Tuple[np.ndarray, float, float]:
    source_energy = front_stereo_binaural_energy(samples)
    target_energy = reference.front_stereo_binaural_energy
    if not np.isfinite(target_energy) or target_energy <= EPSILON:
        raise ConversionError("Loudness reference target must be positive and finite")
    gain = target_energy / source_energy
    output = (np.asarray(samples, dtype=np.float64) * gain).astype(np.float32)
    if not np.all(np.isfinite(output)):
        raise ConversionError("Loudness calibration produced non-finite samples")
    return output, source_energy, gain


def _as_rows(value: object, columns: int, name: str) -> np.ndarray:
    array = np.asarray(value, dtype=np.float64).squeeze()
    if array.ndim == 1:
        if array.size != columns:
            raise ConversionError(f"{name} must contain {columns} coordinates")
        return array.reshape(1, columns)
    if array.ndim == 2 and array.shape[1] == columns:
        return array
    if array.ndim == 2 and array.shape[0] == columns:
        return array.T
    raise ConversionError(f"Unsupported {name} shape: {array.shape}")


def _single_row(value: object, name: str) -> np.ndarray:
    rows = _as_rows(value, 3, name)
    if rows.shape[0] != 1:
        if not np.allclose(rows, rows[0], atol=EPSILON, rtol=0):
            raise ConversionError(f"Varying {name} is not supported")
    return rows[0]


def _spherical_to_cartesian(positions: np.ndarray) -> np.ndarray:
    azimuth = np.deg2rad(positions[:, 0])
    elevation = np.deg2rad(positions[:, 1])
    radius = positions[:, 2]
    return np.column_stack(
        (
            radius * np.cos(elevation) * np.cos(azimuth),
            radius * np.cos(elevation) * np.sin(azimuth),
            radius * np.sin(elevation),
        )
    )


def _listener_basis(sofa: object) -> Tuple[np.ndarray, np.ndarray, np.ndarray, np.ndarray]:
    position_type = str(getattr(sofa, "ListenerPosition_Type", "cartesian")).lower()
    if position_type != "cartesian":
        raise ConversionError(f"Unsupported ListenerPosition type: {position_type}")
    listener_position = _single_row(sofa.ListenerPosition, "ListenerPosition")
    forward = _single_row(sofa.ListenerView, "ListenerView")
    up = _single_row(sofa.ListenerUp, "ListenerUp")
    forward_norm = np.linalg.norm(forward)
    if forward_norm <= EPSILON:
        raise ConversionError("ListenerView has zero length")
    forward = forward / forward_norm
    up = up - np.dot(up, forward) * forward
    up_norm = np.linalg.norm(up)
    if up_norm <= EPSILON:
        raise ConversionError("ListenerUp is parallel to ListenerView")
    up = up / up_norm
    left = np.cross(up, forward)
    left = left / np.linalg.norm(left)
    return listener_position, forward, left, up


def _source_geometry(sofa: object) -> Tuple[np.ndarray, np.ndarray, np.ndarray]:
    listener_position, forward, left, up = _listener_basis(sofa)
    positions = _as_rows(sofa.SourcePosition, 3, "SourcePosition")
    position_type = str(sofa.SourcePosition_Type).lower()
    units = str(sofa.SourcePosition_Units).lower()
    if position_type == "spherical":
        if "degree" not in units:
            raise ConversionError(f"SourcePosition must use degrees, got: {units}")
        global_positions = _spherical_to_cartesian(positions)
    elif position_type == "cartesian":
        if "metre" not in units and "meter" not in units:
            raise ConversionError(f"SourcePosition must use metres, got: {units}")
        global_positions = positions
    else:
        raise ConversionError(f"Unsupported SourcePosition type: {position_type}")

    directions = global_positions - listener_position
    norms = np.linalg.norm(directions, axis=1)
    if np.any(norms <= EPSILON):
        raise ConversionError("SourcePosition contains a source at ListenerPosition")
    directions = directions / norms[:, np.newaxis]
    local = np.column_stack(
        (directions @ forward, directions @ left, directions @ up)
    )
    local = local / np.linalg.norm(local, axis=1)[:, np.newaxis]
    azimuths = np.rad2deg(np.arctan2(local[:, 1], local[:, 0]))
    elevations = np.rad2deg(np.arcsin(np.clip(local[:, 2], -1.0, 1.0)))
    return local, azimuths, elevations


def _receiver_indices(sofa: object) -> Tuple[int, int]:
    position_type = str(sofa.ReceiverPosition_Type).lower()
    units = str(sofa.ReceiverPosition_Units).lower()
    if position_type != "cartesian":
        raise ConversionError(f"Unsupported ReceiverPosition type: {position_type}")
    if "metre" not in units and "meter" not in units:
        raise ConversionError(f"ReceiverPosition must use metres, got: {units}")

    positions = _as_rows(sofa.ReceiverPosition, 3, "ReceiverPosition")
    if positions.shape[0] != 2:
        raise ConversionError(f"Expected two receiver positions, got {positions.shape[0]}")
    listener_position, _, left_axis, _ = _listener_basis(sofa)
    lateral = (positions - listener_position) @ left_axis
    positive = np.flatnonzero(lateral > EPSILON)
    negative = np.flatnonzero(lateral < -EPSILON)
    if positive.size != 1 or negative.size != 1:
        raise ConversionError(
            "ReceiverPosition does not identify exactly one left and one right ear"
        )
    return int(positive[0]), int(negative[0])


def _expand_delays(delays: object, measurements: int) -> np.ndarray:
    array = np.asarray(delays, dtype=np.float64)
    if array.ndim == 0:
        array = np.full((measurements, 2), float(array))
    elif array.shape == (2,):
        array = np.tile(array, (measurements, 1))
    elif array.shape == (1, 2):
        array = np.tile(array, (measurements, 1))
    elif array.shape != (measurements, 2):
        raise ConversionError(f"Unsupported Data.Delay shape: {array.shape}")
    if not np.all(np.isfinite(array)) or np.any(array < 0):
        raise ConversionError("Data.Delay must contain finite, non-negative sample delays")
    return array


def read_ss2_sofa(path: Path) -> SofaData:
    try:
        sofa = sf.read_sofa(str(path), verify=True, verbose=False)
    except Exception as error:
        raise ConversionError(f"SOFA verification failed: {error}") from error

    if str(sofa.GLOBAL_SOFAConventions) != "SimpleFreeFieldHRIR":
        raise ConversionError(
            f"Expected SimpleFreeFieldHRIR, got {sofa.GLOBAL_SOFAConventions}"
        )
    if str(sofa.GLOBAL_DataType) != "FIR":
        raise ConversionError(f"Expected FIR data, got {sofa.GLOBAL_DataType}")

    impulses = np.asarray(sofa.Data_IR, dtype=np.float64)
    if impulses.ndim != 3 or impulses.shape[1] != 2 or impulses.shape[2] == 0:
        raise ConversionError(f"Expected non-empty M x 2 x N Data.IR, got {impulses.shape}")
    if not np.all(np.isfinite(impulses)):
        raise ConversionError("Data.IR contains NaN or infinite samples")

    rates = np.asarray(sofa.Data_SamplingRate, dtype=np.float64).reshape(-1)
    if rates.size != 1 or not np.isfinite(rates[0]) or rates[0] <= 0:
        raise ConversionError("Data.SamplingRate must contain one positive finite value")
    rounded_rate = int(round(float(rates[0])))
    if not math.isclose(float(rates[0]), rounded_rate, abs_tol=1e-6):
        raise ConversionError("WAV output requires an integer source sample rate")

    vectors, azimuths, elevations = _source_geometry(sofa)
    if vectors.shape[0] != impulses.shape[0]:
        raise ConversionError("SourcePosition and Data.IR measurement counts differ")
    left_receiver, right_receiver = _receiver_indices(sofa)
    delays = _expand_delays(sofa.Data_Delay, impulses.shape[0])

    return SofaData(
        source_path=path,
        source_hash=sha256_file(path),
        listener_short_name=str(getattr(sofa, "GLOBAL_ListenerShortName", "")),
        database_name=str(getattr(sofa, "GLOBAL_DatabaseName", "")),
        license_name=str(getattr(sofa, "GLOBAL_License", "")),
        sample_rate=rounded_rate,
        impulse_responses=impulses,
        delays=delays,
        source_vectors=vectors,
        source_azimuths=azimuths,
        source_elevations=elevations,
        left_receiver=left_receiver,
        right_receiver=right_receiver,
    )


def select_directions(data: SofaData, max_error_deg: float) -> Dict[str, DirectionSelection]:
    return select_target_directions(data, max_error_deg, TARGET_AZIMUTHS)


def target_azimuths(front_azimuth_deg: float) -> Dict[str, float]:
    if (
        not np.isfinite(front_azimuth_deg)
        or front_azimuth_deg <= 0
        or front_azimuth_deg > 90
    ):
        raise ConversionError("Front azimuth must be greater than 0° and at most 90°")
    targets = dict(TARGET_AZIMUTHS)
    targets["FL"] = float(front_azimuth_deg)
    targets["FR"] = -float(front_azimuth_deg)
    return targets


def select_target_directions(
    data: SofaData,
    max_error_deg: float,
    targets: Dict[str, float],
) -> Dict[str, DirectionSelection]:
    if not np.isfinite(max_error_deg) or max_error_deg < 0:
        raise ConversionError("Maximum angular error must be finite and non-negative")
    selections: Dict[str, DirectionSelection] = {}
    for speaker, target_azimuth in targets.items():
        target_radians = math.radians(target_azimuth)
        target = np.array([math.cos(target_radians), math.sin(target_radians), 0.0])
        dots = np.clip(data.source_vectors @ target, -1.0, 1.0)
        errors = np.rad2deg(np.arccos(dots))
        best_error = float(np.min(errors))
        # np.flatnonzero preserves measurement order, making equal-distance ties deterministic.
        candidates = np.flatnonzero(np.isclose(errors, best_error, atol=1e-10, rtol=0))
        index = int(candidates[0])
        if best_error > max_error_deg + 1e-9:
            raise ConversionError(
                f"{speaker} nearest measurement is {best_error:.6f}°, "
                f"above {max_error_deg:.6f}° limit"
            )
        selections[speaker] = DirectionSelection(
            speaker=speaker,
            target_azimuth_deg=target_azimuth,
            measurement_index=index,
            actual_azimuth_deg=float(data.source_azimuths[index]),
            actual_elevation_deg=float(data.source_elevations[index]),
            angular_error_deg=best_error,
        )
    return selections


def _fractional_delay_kernel(fraction: float, taps: int = FRACTIONAL_DELAY_TAPS) -> np.ndarray:
    if taps < 3 or taps % 2 == 0:
        raise ValueError("Fractional-delay tap count must be odd and at least 3")
    half = taps // 2
    offsets = np.arange(-half, half + 1, dtype=np.float64)
    kernel = np.sinc(offsets - fraction) * np.blackman(taps)
    kernel /= np.sum(kernel)
    return kernel


def materialize_delays(channels: Sequence[np.ndarray], delays: Sequence[float]) -> np.ndarray:
    if len(channels) != len(delays) or not channels:
        raise ConversionError("Channels and delays must be non-empty and have equal length")
    arrays = [np.asarray(channel, dtype=np.float64) for channel in channels]
    if any(array.ndim != 1 or array.size == 0 for array in arrays):
        raise ConversionError("Every output channel must be a non-empty vector")
    delay_array = np.asarray(delays, dtype=np.float64)
    if not np.all(np.isfinite(delay_array)) or np.any(delay_array < 0):
        raise ConversionError("Output delays must be finite and non-negative")

    rounded = np.rint(delay_array)
    fractions = delay_array - np.floor(delay_array)
    has_fractional = bool(np.any(np.abs(delay_array - rounded) > 1e-9))
    rendered: List[np.ndarray] = []
    for samples, delay, fraction in zip(arrays, delay_array, fractions):
        integer_delay = int(math.floor(float(delay) + 1e-12))
        if has_fractional:
            # Full convolution adds the same causal group delay to every channel.
            kernel = _fractional_delay_kernel(float(fraction))
            shifted = np.convolve(samples, kernel, mode="full")
        else:
            shifted = samples.copy()
        if integer_delay:
            shifted = np.pad(shifted, (integer_delay, 0))
        rendered.append(shifted)

    frame_count = max(channel.size for channel in rendered)
    output = np.zeros((frame_count, len(rendered)), dtype=np.float32)
    for index, channel in enumerate(rendered):
        output[: channel.size, index] = channel.astype(np.float32)
    if not np.all(np.isfinite(output)):
        raise ConversionError("Delay materialization produced non-finite samples")
    return output


def build_output(
    data: SofaData, selections: Dict[str, DirectionSelection]
) -> Tuple[np.ndarray, List[float]]:
    ear_indices = {"left": data.left_receiver, "right": data.right_receiver}
    channels: List[np.ndarray] = []
    delays: List[float] = []
    for speaker, ear in CHANNEL_LAYOUT:
        measurement = selections[speaker].measurement_index
        receiver = ear_indices[ear]
        channels.append(data.impulse_responses[measurement, receiver, :])
        delays.append(float(data.delays[measurement, receiver]))
    return materialize_delays(channels, delays), delays


def _safe_relative(path: Path, root: Path) -> Path:
    if root.is_file():
        return Path(path.name)
    return path.relative_to(root)


def _manifest(
    data: SofaData,
    source_root: Path,
    output_path: Path,
    output_root: Path,
    output_hash: str,
    output_frames: int,
    selections: Dict[str, DirectionSelection],
    channel_delays: Sequence[float],
    loudness_reference: LoudnessReference,
    uncalibrated_front_stereo_binaural_energy: float,
    loudness_gain: float,
) -> dict:
    selection_list = []
    for speaker in TARGET_AZIMUTHS:
        selection = selections[speaker]
        receiver_delays = data.delays[selection.measurement_index]
        selection_list.append(
            {
                "speaker": speaker,
                "target_azimuth_deg": selection.target_azimuth_deg,
                "measurement_index": selection.measurement_index,
                "actual_azimuth_deg": round(selection.actual_azimuth_deg, 9),
                "actual_elevation_deg": round(selection.actual_elevation_deg, 9),
                "angular_error_deg": round(selection.angular_error_deg, 9),
                "source_delays_samples": {
                    "left": float(receiver_delays[data.left_receiver]),
                    "right": float(receiver_delays[data.right_receiver]),
                },
            }
        )
    return {
        "schema_version": 2,
        "source": {
            "path": _safe_relative(data.source_path, source_root).as_posix(),
            "sha256": data.source_hash,
            "sofa_convention": "SimpleFreeFieldHRIR",
            "data_type": "FIR",
            "database": data.database_name,
            "listener": data.listener_short_name,
            "license": data.license_name,
            "measurement_count": int(data.impulse_responses.shape[0]),
            "ir_frames": int(data.impulse_responses.shape[2]),
        },
        "output": {
            "path": output_path.relative_to(output_root).as_posix(),
            "sha256": output_hash,
            "sample_rate_hz": data.sample_rate,
            "frames": output_frames,
            "channels": 14,
            "wav_subtype": "FLOAT",
        },
        "receiver_indices": {"left": data.left_receiver, "right": data.right_receiver},
        "loudness_calibration": {
            "method": "global_gain_to_reference_front_stereo_binaural_l2_energy",
            "reference": {
                "name": loudness_reference.name,
                "sha256": loudness_reference.sha256,
                "sample_rate_hz": loudness_reference.sample_rate,
            },
            "uncalibrated_front_stereo_binaural_energy": uncalibrated_front_stereo_binaural_energy,
            "target_front_stereo_binaural_energy": loudness_reference.front_stereo_binaural_energy,
            "linear_gain": loudness_gain,
            "gain_db": 20.0 * math.log10(loudness_gain),
        },
        "directions": selection_list,
        "channel_map": [
            {
                "index": index,
                "speaker": speaker,
                "ear": ear,
                "delay_samples": float(channel_delays[index]),
            }
            for index, (speaker, ear) in enumerate(CHANNEL_LAYOUT)
        ],
    }


def validate_output(path: Path, expected: np.ndarray, sample_rate: int) -> None:
    info = soundfile.info(str(path))
    if info.format != "WAV" or info.subtype != "FLOAT":
        raise ConversionError(f"Output is not IEEE Float32 WAV: {info.format}/{info.subtype}")
    if info.channels != 14 or info.samplerate != sample_rate or info.frames != expected.shape[0]:
        raise ConversionError(
            "Output WAV metadata differs from generated data: "
            f"{info.channels}ch/{info.samplerate}Hz/{info.frames} frames"
        )
    actual, actual_rate = soundfile.read(str(path), dtype="float32", always_2d=True)
    if actual_rate != sample_rate or actual.shape != expected.shape:
        raise ConversionError("Decoded output shape or sample rate differs from generated data")
    if not np.array_equal(actual, expected):
        raise ConversionError("Decoded output samples differ from generated Float32 samples")


def convert_file(
    source_path: Path,
    source_root: Path,
    output_root: Path,
    max_error_deg: float,
    force: bool,
    validate: bool,
    loudness_reference: LoudnessReference = DEFAULT_LOUDNESS_REFERENCE,
    front_azimuth_deg: float = 30.0,
) -> Tuple[Path, dict]:
    data = read_ss2_sofa(source_path)
    if data.sample_rate != loudness_reference.sample_rate:
        raise ConversionError(
            f"SOFA sample rate {data.sample_rate} Hz differs from loudness reference "
            f"{loudness_reference.sample_rate} Hz"
        )
    selections = select_target_directions(
        data, max_error_deg, target_azimuths(front_azimuth_deg)
    )
    output, channel_delays = build_output(data, selections)
    output, uncalibrated_energy, loudness_gain = calibrate_loudness(
        output, loudness_reference
    )

    relative = _safe_relative(source_path, source_root).with_suffix(".wav")
    output_path = output_root / relative
    manifest_path = output_path.with_suffix(output_path.suffix + ".json")
    if not force and (output_path.exists() or manifest_path.exists()):
        raise ConversionError(f"Output already exists (use --force): {output_path}")
    output_path.parent.mkdir(parents=True, exist_ok=True)
    soundfile.write(str(output_path), output, data.sample_rate, format="WAV", subtype="FLOAT")
    if validate:
        validate_output(output_path, output, data.sample_rate)
    output_hash = sha256_file(output_path)
    manifest = _manifest(
        data,
        source_root,
        output_path,
        output_root,
        output_hash,
        output.shape[0],
        selections,
        channel_delays,
        loudness_reference,
        uncalibrated_energy,
        loudness_gain,
    )
    manifest_path.write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    return output_path, manifest


def discover_sources(source: Path) -> List[Path]:
    if source.is_file():
        if source.suffix.lower() != ".sofa":
            raise ConversionError(f"Input file must use .sofa extension: {source}")
        return [source]
    if not source.is_dir():
        raise ConversionError(f"Input path does not exist: {source}")
    files = sorted(path for path in source.rglob("*.sofa") if path.is_file())
    if not files:
        raise ConversionError(f"No .sofa files found under {source}")
    return files


def parse_args(argv: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Convert SS2 SOFA HRIRs to Airwave-compatible 14-channel Float32 WAVs."
    )
    parser.add_argument("source", type=Path, help="SOFA file or directory scanned recursively")
    parser.add_argument("--output-dir", required=True, type=Path, help="Output root directory")
    parser.add_argument(
        "--max-angular-error-deg",
        type=float,
        default=5.0,
        help="Maximum great-circle error for nearest measurements (default: 5)",
    )
    parser.add_argument(
        "--front-azimuth-deg",
        type=float,
        default=30.0,
        help=(
            "Symmetric FL/FR azimuth from straight ahead, in degrees "
            "(greater than 0 and at most 90; default: 30)"
        ),
    )
    parser.add_argument("--force", action="store_true", help="Overwrite existing WAVs/manifests")
    parser.add_argument("--validate", action="store_true", help="Decode and compare every WAV")
    parser.add_argument(
        "--loudness-reference-wav",
        type=Path,
        help=(
            "Optional known-good 14-channel WAV used to derive the loudness target; "
            "default is the reproducible target measured from dht.wav"
        ),
    )
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    source = args.source.resolve()
    output_root = args.output_dir.resolve()
    try:
        loudness_reference = (
            read_loudness_reference(args.loudness_reference_wav.resolve())
            if args.loudness_reference_wav is not None
            else DEFAULT_LOUDNESS_REFERENCE
        )
        sources = discover_sources(source)
        results = []
        for source_path in sources:
            output_path, manifest = convert_file(
                source_path=source_path,
                source_root=source,
                output_root=output_root,
                max_error_deg=args.max_angular_error_deg,
                force=args.force,
                validate=args.validate,
                loudness_reference=loudness_reference,
                front_azimuth_deg=args.front_azimuth_deg,
            )
            max_error = max(item["angular_error_deg"] for item in manifest["directions"])
            print(f"{source_path} -> {output_path} (max error {max_error:.3f}°)")
            results.append(output_path)
        print(f"Converted {len(results)} SOFA file(s) into {output_root}")
        return 0
    except (ConversionError, OSError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
