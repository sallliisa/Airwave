"""Clean-room spatial metrics and deterministic SS2 prototype synthesis."""

from __future__ import annotations

import hashlib
import json
import math
from pathlib import Path
from typing import Dict, Iterable, List, Sequence, Tuple

import numpy as np
import soundfile


SAMPLE_RATE = 48_000
OUTPUT_FRAMES = 8_192
CHECKPOINTS_MS: Tuple[int, ...] = (5, 10, 20, 50)
THIRD_OCTAVE_CENTERS: Tuple[float, ...] = tuple(
    1000.0 * (2.0 ** (index / 3.0)) for index in range(-15, 13)
)

# Values are always (left-ear track, right-ear track).
DIRECTION_PAIRS: Dict[str, Tuple[int, int]] = {
    "FL": (0, 1),
    "FR": (8, 7),
    "SL": (2, 3),
    "SR": (10, 9),
    "BL": (4, 5),
    "BR": (12, 11),
    "FC": (6, 13),
}

VARIANTS: Tuple[Tuple[str, str, bool, float], ...] = (
    ("A_tail_only", "Original HATS timing plus full target ambience", False, 1.0),
    ("B_minphase_only", "Aligned minimum-phase HATS without ambience", True, 0.0),
    ("C_minphase_low_space", "Aligned HATS plus half target ambience", True, 0.5),
    ("D_minphase_target_space", "Aligned HATS plus full target ambience", True, 1.0),
)


class PrototypeError(RuntimeError):
    """Raised when a prototype cannot be analyzed or synthesized safely."""


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _validate_matrix(samples: np.ndarray, channels: int = 14) -> np.ndarray:
    array = np.asarray(samples, dtype=np.float64)
    if array.ndim != 2 or array.shape[0] == 0 or array.shape[1] != channels:
        raise PrototypeError(f"Expected a non-empty {channels}-channel matrix")
    if not np.all(np.isfinite(array)):
        raise PrototypeError("Audio contains NaN or infinite samples")
    if not np.any(array):
        raise PrototypeError("Audio contains no impulse energy")
    return array


def _safe_correlation(left: np.ndarray, right: np.ndarray) -> float:
    denominator = float(np.linalg.norm(left) * np.linalg.norm(right))
    if denominator <= 1e-15:
        return 0.0
    return float(np.dot(left, right) / denominator)


def _band_energies(samples: np.ndarray, sample_rate: int) -> List[float]:
    if samples.size == 0 or not np.any(samples):
        return [0.0 for _ in THIRD_OCTAVE_CENTERS]
    fft_size = max(16_384, 1 << (samples.size - 1).bit_length())
    spectrum = np.fft.rfft(samples, fft_size)
    power = np.abs(spectrum) ** 2
    frequencies = np.fft.rfftfreq(fft_size, 1.0 / sample_rate)
    values: List[float] = []
    for center in THIRD_OCTAVE_CENTERS:
        lower = center / (2.0 ** (1.0 / 6.0))
        upper = center * (2.0 ** (1.0 / 6.0))
        selected = power[(frequencies >= lower) & (frequencies < upper)]
        values.append(float(np.mean(selected)) if selected.size else 0.0)
    total = sum(values)
    if total <= 1e-30:
        return [0.0 for _ in values]
    return [value / total for value in values]


def direction_metrics(
    samples: np.ndarray,
    sample_rate: int,
    left_index: int,
    right_index: int,
) -> dict:
    array = _validate_matrix(samples)
    left = array[:, left_index]
    right = array[:, right_index]
    left_peak = int(np.argmax(np.abs(left)))
    right_peak = int(np.argmax(np.abs(right)))
    anchor = min(left_peak, right_peak)
    left_energy = float(np.linalg.norm(left))
    right_energy = float(np.linalg.norm(right))
    pair_energy_squared = left_energy**2 + right_energy**2
    if pair_energy_squared <= 1e-30:
        raise PrototypeError("Direction contains no usable energy")

    late_ratios: Dict[str, float] = {}
    for milliseconds in CHECKPOINTS_MS:
        cutoff = min(array.shape[0], anchor + round(sample_rate * milliseconds / 1000.0))
        late_energy = float(np.sum(left[cutoff:] ** 2) + np.sum(right[cutoff:] ** 2))
        late_ratios[str(milliseconds)] = late_energy / pair_energy_squared

    tail_start = min(array.shape[0], anchor + round(sample_rate * 0.005))
    tail = np.concatenate((left[tail_start:], right[tail_start:]))
    centers = np.asarray(THIRD_OCTAVE_CENTERS)
    audible = (centers >= 80.0) & (centers <= 16_000.0)
    normalized_responses = []
    for channel in (left, right):
        response = third_octave_magnitude_db(channel, sample_rate)
        response -= float(np.mean(response[audible]))
        normalized_responses.append([float(value) for value in response])
    return {
        "left_right_level_db": 20.0 * math.log10(left_energy / right_energy),
        "peak_itd_samples_right_minus_left": right_peak - left_peak,
        "zero_lag_interaural_correlation": _safe_correlation(left, right),
        "late_energy_ratios": late_ratios,
        "late_field_third_octave_energy": _band_energies(tail, sample_rate),
        "normalized_third_octave_magnitude_db": {
            "left": normalized_responses[0],
            "right": normalized_responses[1],
        },
    }


def analyze_reference(path: Path) -> dict:
    try:
        info = soundfile.info(str(path))
        samples, sample_rate = soundfile.read(
            str(path), dtype="float64", always_2d=True
        )
    except (OSError, RuntimeError) as error:
        raise PrototypeError(f"Cannot read reference WAV: {error}") from error
    if info.format != "WAV" or info.channels != 14:
        raise PrototypeError("Reference must be a 14-channel WAV")
    if sample_rate != SAMPLE_RATE:
        raise PrototypeError(f"Reference must use {SAMPLE_RATE} Hz")
    array = _validate_matrix(samples)
    return {
        "schema_version": 2,
        "clean_room_boundary": (
            "Aggregate direction metrics only; no samples, phase, reflection taps, "
            "or fine frequency response are stored."
        ),
        "reference": {
            "name": path.name,
            "sha256": sha256_file(path),
            "sample_rate_hz": sample_rate,
            "frames": int(array.shape[0]),
            "channels": 14,
        },
        "third_octave_centers_hz": list(THIRD_OCTAVE_CENTERS),
        "directions": {
            speaker: direction_metrics(array, sample_rate, *indices)
            for speaker, indices in DIRECTION_PAIRS.items()
        },
    }


def load_metrics(path: Path) -> dict:
    try:
        metrics = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise PrototypeError(f"Cannot read reference metrics: {error}") from error
    if metrics.get("schema_version") != 2:
        raise PrototypeError("Unsupported reference metrics schema")
    reference = metrics.get("reference", {})
    if reference.get("sample_rate_hz") != SAMPLE_RATE or reference.get("channels") != 14:
        raise PrototypeError("Reference metrics must describe 14 channels at 48000 Hz")
    directions = metrics.get("directions")
    if not isinstance(directions, dict) or set(directions) != set(DIRECTION_PAIRS):
        raise PrototypeError("Reference metrics have an invalid direction set")
    for speaker, values in directions.items():
        ratios = values.get("late_energy_ratios", {})
        if set(ratios) != {str(value) for value in CHECKPOINTS_MS}:
            raise PrototypeError(f"{speaker} has invalid late-energy checkpoints")
        numbers = [float(ratios[str(value)]) for value in CHECKPOINTS_MS]
        numbers.extend(
            [
                float(values.get("left_right_level_db")),
                float(values.get("peak_itd_samples_right_minus_left")),
                float(values.get("zero_lag_interaural_correlation")),
            ]
        )
        if not np.all(np.isfinite(numbers)) or any(value < 0 or value >= 1 for value in numbers[:4]):
            raise PrototypeError(f"{speaker} contains invalid aggregate metrics")
        correlation = float(values["zero_lag_interaural_correlation"])
        bands = np.asarray(values.get("late_field_third_octave_energy", []), dtype=np.float64)
        if correlation < -1 or correlation > 1:
            raise PrototypeError(f"{speaker} contains invalid interaural correlation")
        if (
            bands.size != len(THIRD_OCTAVE_CENTERS)
            or not np.all(np.isfinite(bands))
            or np.any(bands < 0)
        ):
            raise PrototypeError(f"{speaker} contains invalid late-field bands")
        responses = values.get("normalized_third_octave_magnitude_db", {})
        for ear in ("left", "right"):
            response = np.asarray(responses.get(ear, []), dtype=np.float64)
            if response.size != len(THIRD_OCTAVE_CENTERS) or not np.all(
                np.isfinite(response)
            ):
                raise PrototypeError(f"{speaker} contains invalid {ear}-ear tone metrics")
    return metrics


def pad_to_frames(samples: np.ndarray, frames: int = OUTPUT_FRAMES) -> np.ndarray:
    array = _validate_matrix(samples)
    if array.shape[0] > frames:
        raise PrototypeError(f"Input has {array.shape[0]} frames, above output limit {frames}")
    output = np.zeros((frames, 14), dtype=np.float64)
    output[: array.shape[0]] = array
    return output


def minimum_phase_ir(samples: np.ndarray, output_frames: int = OUTPUT_FRAMES) -> np.ndarray:
    vector = np.asarray(samples, dtype=np.float64)
    if vector.ndim != 1 or vector.size == 0 or not np.all(np.isfinite(vector)):
        raise PrototypeError("Minimum-phase input must be one finite impulse")
    fft_size = 1
    while fft_size < max(output_frames * 2, vector.size * 8):
        fft_size *= 2
    magnitude = np.maximum(np.abs(np.fft.fft(vector, fft_size)), 1e-12)
    cepstrum = np.fft.ifft(np.log(magnitude)).real
    minimum_cepstrum = np.zeros(fft_size, dtype=np.float64)
    minimum_cepstrum[0] = cepstrum[0]
    minimum_cepstrum[1 : fft_size // 2] = 2.0 * cepstrum[1 : fft_size // 2]
    minimum_cepstrum[fft_size // 2] = cepstrum[fft_size // 2]
    result = np.fft.ifft(np.exp(np.fft.fft(minimum_cepstrum))).real[:output_frames]
    source_energy = float(np.linalg.norm(vector))
    result_energy = float(np.linalg.norm(result))
    if result_energy <= 1e-15:
        raise PrototypeError("Minimum-phase reconstruction produced no energy")
    return result * (source_energy / result_energy)


def aligned_minimum_phase(samples: np.ndarray, peak_frame: int = 128) -> np.ndarray:
    array = _validate_matrix(samples)
    output = np.zeros((OUTPUT_FRAMES, 14), dtype=np.float64)
    for left_index, right_index in DIRECTION_PAIRS.values():
        for channel in (left_index, right_index):
            reconstructed = minimum_phase_ir(array[:, channel])
            peak = int(np.argmax(np.abs(reconstructed)))
            shift = peak_frame - peak
            if shift < 0:
                raise PrototypeError("Minimum-phase peak exceeds causal alignment frame")
            available = OUTPUT_FRAMES - shift
            output[shift:, channel] = reconstructed[:available]
    return output


def allpass_filter(samples: np.ndarray, delay: int, coefficient: float) -> np.ndarray:
    vector = np.asarray(samples, dtype=np.float64)
    if vector.ndim != 1 or delay <= 0 or not 0.0 < coefficient < 1.0:
        raise PrototypeError("Invalid all-pass section")
    output = np.zeros_like(vector)
    for index in range(vector.size):
        value = -coefficient * vector[index]
        if index >= delay:
            value += vector[index - delay] + coefficient * output[index - delay]
        output[index] = value
    return output


def allpass_cascade(
    samples: np.ndarray, delays: Sequence[int], coefficients: Sequence[float]
) -> np.ndarray:
    if len(delays) != len(coefficients) or not delays:
        raise PrototypeError("All-pass delays and coefficients must have equal nonzero length")
    output = np.asarray(samples, dtype=np.float64)
    for delay, coefficient in zip(delays, coefficients):
        output = allpass_filter(output, int(delay), float(coefficient))
    return output


def _deterministic_delays(seed: str, shared_count: int, ear: int) -> List[int]:
    bases = (251, 383, 557, 811)
    digest = hashlib.sha256(f"{seed}:{ear}".encode("utf-8")).digest()
    delays: List[int] = []
    for index, base in enumerate(bases):
        source_ear = 0 if index < shared_count else ear
        byte = hashlib.sha256(f"{seed}:{source_ear}:{index}".encode("utf-8")).digest()[0]
        jitter = 2 * (byte % 24) + 1
        delays.append(base + jitter)
    return delays


def _late_ratios_for_pair(pair: np.ndarray, sample_rate: int) -> np.ndarray:
    left_peak = int(np.argmax(np.abs(pair[:, 0])))
    right_peak = int(np.argmax(np.abs(pair[:, 1])))
    anchor = min(left_peak, right_peak)
    total = float(np.sum(pair**2))
    result = []
    for milliseconds in CHECKPOINTS_MS:
        cutoff = min(pair.shape[0], anchor + round(sample_rate * milliseconds / 1000.0))
        result.append(float(np.sum(pair[cutoff:] ** 2) / total))
    return np.asarray(result)


def _project_vector_magnitude(reference: np.ndarray, candidate: np.ndarray) -> np.ndarray:
    # Alternate between the SS2 magnitude and finite causal time support. A
    # single projection leaves interpolation ripple after truncation.
    fft_size = OUTPUT_FRAMES * 4
    target_magnitude = np.abs(np.fft.rfft(reference, fft_size))
    work = np.zeros(fft_size, dtype=np.float64)
    work[:OUTPUT_FRAMES] = candidate
    for _ in range(12):
        phase = np.angle(np.fft.rfft(work, fft_size))
        reconstructed = np.fft.irfft(
            target_magnitude * np.exp(1j * phase), fft_size
        )
        work.fill(0.0)
        work[:OUTPUT_FRAMES] = reconstructed[:OUTPUT_FRAMES]
    reconstructed = work[:OUTPUT_FRAMES]
    source_energy = float(np.linalg.norm(reference))
    output_energy = float(np.linalg.norm(reconstructed))
    if output_energy <= 1e-15:
        raise PrototypeError("Magnitude projection produced no energy")
    return reconstructed * (source_energy / output_energy)


def _allpass_tail_template(
    frames: int,
    anchor: int,
    delays: Sequence[int],
    coefficients: Sequence[float],
) -> np.ndarray:
    impulse = np.zeros(frames, dtype=np.float64)
    impulse[anchor] = 1.0
    template = allpass_cascade(impulse, delays, coefficients)
    tail_start = min(frames, anchor + round(SAMPLE_RATE * 0.005))
    template[:tail_start] = 0.0
    return template


def _cumulative_to_intervals(cumulative: np.ndarray) -> np.ndarray:
    return np.asarray(
        (
            max(0.0, cumulative[0] - cumulative[1]),
            max(0.0, cumulative[1] - cumulative[2]),
            max(0.0, cumulative[2] - cumulative[3]),
            max(0.0, cumulative[3]),
        ),
        dtype=np.float64,
    )


def _pair_with_shaped_tail(
    pair: np.ndarray,
    templates: Tuple[np.ndarray, np.ndarray],
    cumulative_targets: np.ndarray,
) -> np.ndarray:
    left_peak = int(np.argmax(np.abs(pair[:, 0])))
    right_peak = int(np.argmax(np.abs(pair[:, 1])))
    anchor = min(left_peak, right_peak)
    boundaries = [
        min(pair.shape[0], anchor + round(SAMPLE_RATE * value / 1000.0))
        for value in CHECKPOINTS_MS
    ]
    windows = list(zip(boundaries, boundaries[1:] + [pair.shape[0]]))
    pair_energy = float(np.sum(pair**2))
    channel_weights = np.sum(pair**2, axis=0) / pair_energy
    desired_intervals = _cumulative_to_intervals(cumulative_targets) * pair_energy
    output = pair.copy()
    for channel in range(2):
        tail = np.zeros(pair.shape[0], dtype=np.float64)
        for interval, (start, end) in enumerate(windows):
            segment = templates[channel][start:end]
            energy = float(np.sum(segment**2))
            desired = float(desired_intervals[interval] * channel_weights[channel])
            if energy > 1e-30 and desired > 0:
                tail[start:end] = segment * math.sqrt(desired / energy)
        output[:, channel] += tail
        output[:, channel] = _project_vector_magnitude(
            pair[:, channel], output[:, channel]
        )
    return output


def _enforce_pair_late_ratios(
    pair: np.ndarray, cumulative_targets: np.ndarray, strength: float = 0.2
) -> np.ndarray:
    """Apply a final coarse envelope correction at declared checkpoints."""
    output = pair.copy()
    anchor = min(
        int(np.argmax(np.abs(output[:, 0]))),
        int(np.argmax(np.abs(output[:, 1]))),
    )
    boundaries = [
        min(output.shape[0], anchor + round(SAMPLE_RATE * value / 1000.0))
        for value in CHECKPOINTS_MS
    ]
    windows = list(zip(boundaries, boundaries[1:] + [output.shape[0]]))
    early_energy = float(np.sum(output[: boundaries[0]] ** 2))
    target_total = early_energy / max(1e-12, 1.0 - float(cumulative_targets[0]))
    target_intervals = _cumulative_to_intervals(cumulative_targets) * target_total
    for (start, end), desired in zip(windows, target_intervals):
        actual = float(np.sum(output[start:end] ** 2))
        if actual > 1e-30:
            exact_scale = math.sqrt(float(desired) / actual)
            output[start:end] *= exact_scale**strength
    return output


def fit_allpass_pair(
    pair: np.ndarray,
    target_late_ratios: Sequence[float],
    target_correlation: float,
    intensity: float,
    seed: str,
) -> Tuple[np.ndarray, dict]:
    if intensity <= 0:
        return pair.copy(), {"wetness": 0.0, "delays": [[], []], "coefficients": []}
    target = np.asarray(target_late_ratios, dtype=np.float64) * intensity
    shared_count = 4 if target_correlation >= 0.8 else 2 if target_correlation >= 0.45 else 1
    delays = (
        _deterministic_delays(seed, shared_count, 0),
        _deterministic_delays(seed, shared_count, 1),
    )
    # Short-decay all-pass sections; interval fitting supplies the amount of
    # ambience while these coefficients keep residual energy below 100 ms.
    coefficients = (0.55, 0.65, 0.75, 0.82)
    anchor = min(
        int(np.argmax(np.abs(pair[:, 0]))),
        int(np.argmax(np.abs(pair[:, 1]))),
    )
    templates = (
        _allpass_tail_template(pair.shape[0], anchor, delays[0], coefficients),
        _allpass_tail_template(pair.shape[0], anchor, delays[1], coefficients),
    )
    best_key = (math.inf, math.inf)
    best_output: np.ndarray | None = None
    best_prefit = target.copy()
    prefit = target.copy()

    def evaluate(values: np.ndarray) -> Tuple[Tuple[float, float], np.ndarray, np.ndarray]:
        candidate = _pair_with_shaped_tail(pair, templates, values)
        measured = _late_ratios_for_pair(candidate, SAMPLE_RATE)
        error = measured - target
        return (float(np.max(np.abs(error))), float(np.mean(error**2))), candidate, measured

    for _ in range(12):
        key, candidate, measured = evaluate(prefit)
        if key < best_key:
            best_key = key
            best_output = candidate
            best_prefit = prefit.copy()
        target_intervals = _cumulative_to_intervals(target)
        measured_intervals = _cumulative_to_intervals(measured)
        prefit_intervals = _cumulative_to_intervals(prefit)
        prefit_intervals *= target_intervals / np.maximum(measured_intervals, 1e-7)
        prefit_intervals = np.clip(prefit_intervals, 0.0, 0.75)
        prefit = np.cumsum(prefit_intervals[::-1])[::-1]
        if prefit[0] > 0.75:
            prefit *= 0.75 / prefit[0]

    # Deterministic coordinate refinement minimizes the declared worst
    # checkpoint error rather than allowing one time window to dominate MSE.
    intervals = _cumulative_to_intervals(best_prefit)
    for step in (0.5, 0.25, 0.1, 0.05, 0.02):
        for interval in range(4):
            starting = intervals.copy()
            for factor in (1.0 - step, 1.0 + step):
                proposal_intervals = starting.copy()
                proposal_intervals[interval] = max(
                    1e-8, proposal_intervals[interval] * factor
                )
                proposal = np.cumsum(proposal_intervals[::-1])[::-1]
                if proposal[0] > 0.75:
                    proposal *= 0.75 / proposal[0]
                key, candidate, _ = evaluate(proposal)
                if key < best_key:
                    best_key = key
                    best_output = candidate
                    best_prefit = proposal
                    intervals = _cumulative_to_intervals(proposal)
    assert best_output is not None
    correction_strength = 0.26 if best_key[0] > 0.012 else 0.21 if best_key[0] > 0.01 else 0.2
    best_output = _enforce_pair_late_ratios(
        best_output, target, strength=correction_strength
    )
    final_measured = _late_ratios_for_pair(best_output, SAMPLE_RATE)
    final_error = final_measured - target
    best_key = (
        float(np.max(np.abs(final_error))),
        float(np.mean(final_error**2)),
    )
    return best_output, {
        "wetness": intensity,
        "delays": [list(delays[0]), list(delays[1])],
        "coefficients": list(coefficients),
        "prefit_late_energy_ratios": [float(value) for value in best_prefit],
        "target_late_energy_ratios": [float(value) for value in target],
        "actual_late_energy_ratios": [
            float(value) for value in final_measured
        ],
        "actual_zero_lag_interaural_correlation": _safe_correlation(
            best_output[:, 0], best_output[:, 1]
        ),
        "fit_max_checkpoint_error": best_key[0],
        "fit_mean_squared_error": best_key[1],
    }


def _diffuse_noise(frames: int, seed: str) -> np.ndarray:
    seed_value = int.from_bytes(hashlib.sha256(seed.encode("utf-8")).digest()[:8], "little")
    rng = np.random.default_rng(seed_value)
    noise = rng.standard_normal(frames)
    # Dense velvet noise avoids audible periodic recurrences while leaving
    # enough zeros to keep convolution inexpensive and transient-like.
    noise[rng.random(frames) > 0.25] = 0.0
    time = np.arange(frames, dtype=np.float64) / SAMPLE_RATE
    noise *= np.exp(-time / 0.045)
    norm = float(np.linalg.norm(noise))
    if norm <= 1e-15:
        raise PrototypeError("Diffuse tail generator produced no energy")
    return noise / norm


def fit_diffuse_pair(
    pair: np.ndarray,
    target_late_ratios: Sequence[float],
    target_correlation: float,
    intensity: float,
    seed: str,
) -> Tuple[np.ndarray, dict]:
    source = np.asarray(pair, dtype=np.float64)
    if source.ndim != 2 or source.shape[1] != 2:
        raise PrototypeError("Diffuse synthesis requires a two-channel pair")
    target = np.asarray(target_late_ratios, dtype=np.float64) * intensity
    if intensity <= 0:
        return source.copy(), {"model": "dense-velvet-noise", "wetness": 0.0}

    anchor = min(
        int(np.argmax(np.abs(source[:, 0]))),
        int(np.argmax(np.abs(source[:, 1]))),
    )
    tail_start = min(source.shape[0], anchor + round(SAMPLE_RATE * 0.005))
    excitation_frames = source.shape[0] - tail_start
    shared = _diffuse_noise(excitation_frames, f"{seed}:shared")
    independent = (
        _diffuse_noise(excitation_frames, f"{seed}:left"),
        _diffuse_noise(excitation_frames, f"{seed}:right"),
    )
    correlation = float(np.clip(target_correlation, 0.0, 1.0))
    shared_gain = math.sqrt(correlation)
    independent_gain = math.sqrt(1.0 - correlation)
    templates = []
    for channel in range(2):
        excitation = shared_gain * shared + independent_gain * independent[channel]
        shaped = np.convolve(source[:, channel], excitation, mode="full")
        template = np.zeros(source.shape[0], dtype=np.float64)
        available = source.shape[0] - tail_start
        template[tail_start:] = shaped[:available]
        templates.append(template)

    boundaries = [
        min(source.shape[0], anchor + round(SAMPLE_RATE * value / 1000.0))
        for value in CHECKPOINTS_MS
    ]
    windows = list(zip(boundaries, boundaries[1:] + [source.shape[0]]))
    early_energy = float(np.sum(source[: boundaries[0]] ** 2))
    target_total = early_energy / max(1e-12, 1.0 - float(target[0]))
    desired_intervals = _cumulative_to_intervals(target) * target_total
    channel_weights = np.sum(source**2, axis=0)
    channel_weights /= float(np.sum(channel_weights))
    output = source.copy()
    for channel in range(2):
        for interval, (start, end) in enumerate(windows):
            segment = templates[channel][start:end]
            template_energy = float(np.sum(segment**2))
            existing_energy = float(np.sum(source[start:end, channel] ** 2))
            desired = float(desired_intervals[interval] * channel_weights[channel])
            additional = max(0.0, desired - existing_energy)
            if template_energy > 1e-30 and additional > 0:
                output[start:end, channel] += segment * math.sqrt(
                    additional / template_energy
                )

    measured = _late_ratios_for_pair(output, SAMPLE_RATE)
    return output, {
        "model": "dense-velvet-noise",
        "wetness": intensity,
        "density": 0.25,
        "decay_seconds": 0.045,
        "target_correlation": target_correlation,
        "target_late_energy_ratios": [float(value) for value in target],
        "actual_late_energy_ratios": [float(value) for value in measured],
        "fit_max_checkpoint_error": float(np.max(np.abs(measured - target))),
    }


def front_stereo_energy(samples: np.ndarray) -> float:
    array = _validate_matrix(samples)
    energies = np.linalg.norm(array, axis=0)
    return float(
        np.mean(
            (
                math.hypot(energies[0], energies[1]),
                math.hypot(energies[8], energies[7]),
            )
        )
    )


def project_magnitude(reference: np.ndarray, candidate: np.ndarray) -> np.ndarray:
    """Keep candidate phase while restoring the SS2 magnitude response."""
    source = _validate_matrix(reference)
    output = _validate_matrix(candidate)
    projected = np.zeros((OUTPUT_FRAMES, 14), dtype=np.float64)
    for channel in range(14):
        projected[:, channel] = _project_vector_magnitude(
            source[:, channel], output[:, channel]
        )
    return projected


def synthesize_variant(
    base: np.ndarray,
    metrics: dict,
    use_minimum_phase: bool,
    ambience_intensity: float,
    seed_prefix: str,
) -> Tuple[np.ndarray, dict]:
    padded = pad_to_frames(base)
    direct = aligned_minimum_phase(padded) if use_minimum_phase else padded.copy()
    output = direct.copy()
    parameters: Dict[str, dict] = {}
    if ambience_intensity > 0:
        for speaker, (left_index, right_index) in DIRECTION_PAIRS.items():
            values = metrics["directions"][speaker]
            target = [
                float(values["late_energy_ratios"][str(milliseconds)])
                for milliseconds in CHECKPOINTS_MS
            ]
            pair, fit = fit_allpass_pair(
                direct[:, [left_index, right_index]],
                target,
                float(values["zero_lag_interaural_correlation"]),
                ambience_intensity,
                f"{seed_prefix}:{speaker}",
            )
            output[:, left_index] = pair[:, 0]
            output[:, right_index] = pair[:, 1]
            parameters[speaker] = fit

    target_energy = front_stereo_energy(padded)
    actual_energy = front_stereo_energy(output)
    output *= target_energy / actual_energy
    if not np.all(np.isfinite(output)) or np.max(np.abs(output)) >= 1.0:
        raise PrototypeError("Prototype output is non-finite or reaches a peak of 1.0")
    return output.astype(np.float32), parameters


def synthesize_diffuse_variant(
    base: np.ndarray,
    metrics: dict,
    ambience_intensity: float,
    seed_prefix: str,
) -> Tuple[np.ndarray, dict]:
    padded = pad_to_frames(base)
    output = padded.copy()
    parameters: Dict[str, dict] = {}
    for speaker, (left_index, right_index) in DIRECTION_PAIRS.items():
        values = metrics["directions"][speaker]
        target = [
            float(values["late_energy_ratios"][str(milliseconds)])
            for milliseconds in CHECKPOINTS_MS
        ]
        pair, fit = fit_diffuse_pair(
            padded[:, [left_index, right_index]],
            target,
            float(values["zero_lag_interaural_correlation"]),
            ambience_intensity,
            f"{seed_prefix}:{speaker}",
        )
        output[:, left_index] = pair[:, 0]
        output[:, right_index] = pair[:, 1]
        parameters[speaker] = fit

    output *= front_stereo_energy(padded) / front_stereo_energy(output)
    if not np.all(np.isfinite(output)) or np.max(np.abs(output)) >= 1.0:
        raise PrototypeError("Diffuse prototype is non-finite or reaches a peak of 1.0")
    return output.astype(np.float32), parameters


def third_octave_magnitude_db(samples: np.ndarray, sample_rate: int) -> np.ndarray:
    vector = np.asarray(samples, dtype=np.float64)
    fft_size = 16_384
    frequencies = np.fft.rfftfreq(fft_size, 1.0 / sample_rate)
    magnitude = np.abs(np.fft.rfft(vector, fft_size))
    values = []
    for center in THIRD_OCTAVE_CENTERS:
        lower = center / (2.0 ** (1.0 / 6.0))
        upper = center * (2.0 ** (1.0 / 6.0))
        selected = magnitude[(frequencies >= lower) & (frequencies < upper)]
        values.append(float(np.sqrt(np.mean(selected**2))) if selected.size else 0.0)
    return 20.0 * np.log10(np.maximum(values, 1e-12))


def maximum_tonal_deviation_db(base: np.ndarray, candidate: np.ndarray) -> float:
    source = _validate_matrix(base)
    output = _validate_matrix(candidate)
    maximum = 0.0
    centers = np.asarray(THIRD_OCTAVE_CENTERS)
    selected = (centers >= 80.0) & (centers <= 16_000.0)
    for channel in range(14):
        base_db = third_octave_magnitude_db(source[:, channel], SAMPLE_RATE)[selected]
        output_db = third_octave_magnitude_db(output[:, channel], SAMPLE_RATE)[selected]
        difference = output_db - base_db
        difference -= float(np.mean(difference))
        maximum = max(maximum, float(np.max(np.abs(difference))))
    return maximum


def _minimum_phase_spectrum(magnitude: np.ndarray, fft_size: int) -> np.ndarray:
    log_magnitude = np.log(np.maximum(np.asarray(magnitude, dtype=np.float64), 1e-8))
    cepstrum = np.fft.irfft(log_magnitude, fft_size)
    minimum_cepstrum = np.zeros(fft_size, dtype=np.float64)
    minimum_cepstrum[0] = cepstrum[0]
    minimum_cepstrum[1 : fft_size // 2] = 2.0 * cepstrum[1 : fft_size // 2]
    minimum_cepstrum[fft_size // 2] = cepstrum[fft_size // 2]
    return np.exp(np.fft.rfft(minimum_cepstrum, fft_size))


def match_direction_levels(samples: np.ndarray, metrics: dict) -> np.ndarray:
    output = _validate_matrix(samples).copy()
    for speaker, (left_index, right_index) in DIRECTION_PAIRS.items():
        left_energy = float(np.linalg.norm(output[:, left_index]))
        right_energy = float(np.linalg.norm(output[:, right_index]))
        pair_energy = math.hypot(left_energy, right_energy)
        ratio = 10.0 ** (
            float(metrics["directions"][speaker]["left_right_level_db"]) / 20.0
        )
        target_right = pair_energy / math.sqrt(1.0 + ratio**2)
        target_left = ratio * target_right
        output[:, left_index] *= target_left / left_energy
        output[:, right_index] *= target_right / right_energy
    return output


def condition_base_to_reference(
    base: np.ndarray, metrics: dict, tone_strength: float
) -> np.ndarray:
    if not np.isfinite(tone_strength) or tone_strength < 0 or tone_strength > 1:
        raise PrototypeError("Tone-match strength must be between 0 and 1")
    source = pad_to_frames(base)
    output = np.zeros_like(source)
    fft_size = OUTPUT_FRAMES * 4
    frequencies = np.fft.rfftfreq(fft_size, 1.0 / SAMPLE_RATE)
    centers = np.asarray(THIRD_OCTAVE_CENTERS)
    log_centers = np.log2(centers)
    channel_targets: Dict[int, np.ndarray] = {}
    for speaker, (left_index, right_index) in DIRECTION_PAIRS.items():
        values = metrics["directions"][speaker]["normalized_third_octave_magnitude_db"]
        channel_targets[left_index] = np.asarray(values["left"], dtype=np.float64)
        channel_targets[right_index] = np.asarray(values["right"], dtype=np.float64)

    audible = (centers >= 80.0) & (centers <= 16_000.0)
    for channel in range(14):
        current = third_octave_magnitude_db(source[:, channel], SAMPLE_RATE)
        current -= float(np.mean(current[audible]))
        correction_db = (channel_targets[channel] - current) * tone_strength
        correction_db = np.clip(correction_db, -12.0, 12.0)
        interpolation_points = np.log2(np.maximum(frequencies, centers[0]))
        interpolated_db = np.interp(
            interpolation_points,
            log_centers,
            correction_db,
            left=float(correction_db[0]),
            right=float(correction_db[-1]),
        )
        magnitude = 10.0 ** (interpolated_db / 20.0)
        equalizer = _minimum_phase_spectrum(magnitude, fft_size)
        transformed = np.fft.irfft(
            np.fft.rfft(source[:, channel], fft_size) * equalizer, fft_size
        )[:OUTPUT_FRAMES]
        transformed_energy = float(np.linalg.norm(transformed))
        source_energy = float(np.linalg.norm(source[:, channel]))
        if transformed_energy <= 1e-15:
            raise PrototypeError("Tone conditioning produced no energy")
        output[:, channel] = transformed * (source_energy / transformed_energy)
    return match_direction_levels(output, metrics)


def maximum_reference_tone_error_db(samples: np.ndarray, metrics: dict) -> float:
    array = _validate_matrix(samples)
    centers = np.asarray(THIRD_OCTAVE_CENTERS)
    audible = (centers >= 80.0) & (centers <= 16_000.0)
    maximum = 0.0
    for speaker, (left_index, right_index) in DIRECTION_PAIRS.items():
        values = metrics["directions"][speaker]["normalized_third_octave_magnitude_db"]
        for channel, ear in ((left_index, "left"), (right_index, "right")):
            actual = third_octave_magnitude_db(array[:, channel], SAMPLE_RATE)
            actual -= float(np.mean(actual[audible]))
            target = np.asarray(values[ear], dtype=np.float64)
            maximum = max(maximum, float(np.max(np.abs(actual[audible] - target[audible]))))
    return maximum


def write_json(path: Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def canonicalize_wav_metadata(path: Path) -> None:
    """Zero libsndfile's wall-clock PEAK timestamp for reproducible Float WAVs."""
    data = bytearray(path.read_bytes())
    if len(data) < 12 or data[:4] != b"RIFF" or data[8:12] != b"WAVE":
        raise PrototypeError("Cannot canonicalize non-RIFF WAV output")
    offset = 12
    while offset + 8 <= len(data):
        chunk_name = bytes(data[offset : offset + 4])
        chunk_size = int.from_bytes(data[offset + 4 : offset + 8], "little")
        payload = offset + 8
        if chunk_name == b"PEAK" and chunk_size >= 8:
            data[payload + 4 : payload + 8] = b"\0\0\0\0"
        offset = payload + chunk_size + (chunk_size % 2)
    path.write_bytes(data)
