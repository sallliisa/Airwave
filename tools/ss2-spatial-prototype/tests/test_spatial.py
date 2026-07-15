from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import sys

import numpy as np
import pytest
import sofar as sf
import soundfile


TOOL_DIR = Path(__file__).parents[1]
sys.path.insert(0, str(TOOL_DIR))
import spatial  # noqa: E402

SPEC = importlib.util.spec_from_file_location("spatial_generate", TOOL_DIR / "generate.py")
assert SPEC is not None and SPEC.loader is not None
generator = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = generator
SPEC.loader.exec_module(generator)


def reference_matrix(frames: int = 4096) -> np.ndarray:
    samples = np.zeros((frames, 14), dtype=np.float64)
    for channel in range(14):
        samples[100 + channel % 2, channel] = 0.5 - 0.01 * channel
        samples[400 + 3 * channel, channel] = 0.08
        samples[750 + 5 * channel, channel] = -0.05
        samples[1500 + 7 * channel, channel] = 0.02
        samples[3000 + 11 * channel, channel] = -0.005
    return samples


def write_reference(path: Path) -> np.ndarray:
    samples = reference_matrix()
    soundfile.write(path, samples, spatial.SAMPLE_RATE, format="WAV", subtype="FLOAT")
    return samples


def make_hats_sofa(path: Path) -> None:
    positions = np.array(
        [
            [0.0, 0.0, 2.0],
            [30.0, 0.0, 2.0],
            [330.0, 0.0, 2.0],
            [90.0, 0.0, 2.0],
            [270.0, 0.0, 2.0],
            [135.0, 0.0, 2.0],
            [225.0, 0.0, 2.0],
        ]
    )
    impulses = np.zeros((7, 2, 32), dtype=np.float64)
    impulses[:, 0, 5] = 0.5
    impulses[:, 0, 12] = -0.08
    impulses[:, 1, 9] = 0.2
    impulses[:, 1, 15] = -0.03
    sofa = sf.Sofa("SimpleFreeFieldHRIR")
    sofa.GLOBAL_DatabaseName = "Fixture SS2"
    sofa.GLOBAL_ListenerShortName = "HATS fixture"
    sofa.GLOBAL_License = "CC-BY-4.0"
    sofa.Data_IR = impulses
    sofa.Data_SamplingRate = spatial.SAMPLE_RATE
    sofa.Data_Delay = np.array([[0.0, 0.0]])
    sofa.ListenerPosition = np.array([[0.0, 0.0, 0.0]])
    sofa.ListenerView = np.array([[1.0, 0.0, 0.0]])
    sofa.ListenerUp = np.array([[0.0, 0.0, 1.0]])
    sofa.ReceiverPosition = np.array([[0.0, 0.09, 0.0], [0.0, -0.09, 0.0]])
    sofa.SourcePosition = positions
    sofa.SourcePosition_Type = "spherical"
    sofa.SourcePosition_Units = "degree, degree, metre"
    sf.write_sofa(str(path), sofa)


def test_analyzer_writes_aggregate_metrics_without_samples(tmp_path: Path) -> None:
    reference = tmp_path / "reference.wav"
    write_reference(reference)
    metrics = spatial.analyze_reference(reference)
    encoded = json.dumps(metrics)

    assert metrics["schema_version"] == 2
    assert set(metrics["directions"]) == set(spatial.DIRECTION_PAIRS)
    assert metrics["reference"]["sha256"] == spatial.sha256_file(reference)
    assert '"samples"' not in encoded


def test_analyzer_rejects_wrong_channels_and_nonfinite_audio(tmp_path: Path) -> None:
    stereo = tmp_path / "stereo.wav"
    soundfile.write(stereo, np.ones((32, 2)), spatial.SAMPLE_RATE, subtype="FLOAT")
    with pytest.raises(spatial.PrototypeError, match="14-channel"):
        spatial.analyze_reference(stereo)

    with pytest.raises(spatial.PrototypeError, match="NaN or infinite"):
        spatial.direction_metrics(
            np.full((32, 14), np.nan), spatial.SAMPLE_RATE, 0, 1
        )


def test_minimum_phase_preserves_energy_and_third_octave_magnitude() -> None:
    impulse = np.zeros(384)
    impulse[20] = 0.7
    impulse[28] = -0.25
    impulse[51] = 0.1
    result = spatial.minimum_phase_ir(impulse)
    source_db = spatial.third_octave_magnitude_db(impulse, spatial.SAMPLE_RATE)
    result_db = spatial.third_octave_magnitude_db(result, spatial.SAMPLE_RATE)
    difference = result_db - source_db
    difference -= np.mean(difference)

    assert np.linalg.norm(result) == pytest.approx(np.linalg.norm(impulse), rel=1e-10)
    assert np.max(np.abs(difference)) < 0.01


def test_aligned_minimum_phase_aligns_every_ear_pair() -> None:
    samples = np.zeros((384, 14))
    for channel in range(14):
        samples[10 + channel * 2, channel] = 0.5
        samples[90 + channel, channel] = -0.1
    output = spatial.aligned_minimum_phase(samples)

    for left, right in spatial.DIRECTION_PAIRS.values():
        assert np.argmax(np.abs(output[:, left])) == 128
        assert np.argmax(np.abs(output[:, right])) == 128


def test_allpass_fit_is_deterministic_and_meets_decay_target() -> None:
    pair = np.zeros((spatial.OUTPUT_FRAMES, 2))
    pair[128, 0] = 0.8
    pair[128, 1] = 0.3
    for delay, amplitude in ((8, -0.2), (21, 0.12), (57, -0.07), (101, 0.03)):
        pair[128 + delay, 0] = amplitude
        pair[128 + delay, 1] = amplitude * 0.4
    target = np.array([0.08, 0.075, 0.045, 0.006])
    first, first_parameters = spatial.fit_allpass_pair(pair, target, 0.6, 1.0, "seed")
    second, second_parameters = spatial.fit_allpass_pair(pair, target, 0.6, 1.0, "seed")
    measured = spatial._late_ratios_for_pair(first, spatial.SAMPLE_RATE)

    np.testing.assert_array_equal(first, second)
    assert first_parameters == second_parameters
    assert np.max(np.abs(measured - target)) <= 0.01


def test_diffuse_tail_is_deterministic_without_periodic_ringing() -> None:
    pair = np.zeros((spatial.OUTPUT_FRAMES, 2))
    pair[100, 0] = 0.8
    pair[104, 1] = 0.5
    target = np.array([0.08, 0.075, 0.045, 0.005])

    first, first_parameters = spatial.fit_diffuse_pair(
        pair, target, 0.6, 1.0, "diffuse-seed"
    )
    second, second_parameters = spatial.fit_diffuse_pair(
        pair, target, 0.6, 1.0, "diffuse-seed"
    )

    np.testing.assert_array_equal(first, second)
    assert first_parameters == second_parameters
    tail = first[340:, 0]
    correlation = np.correlate(tail, tail, mode="full")[len(tail) - 1 :]
    correlation /= correlation[0]
    assert np.max(np.abs(correlation[48:960])) < 0.12


def test_diffuse_synthesis_preserves_direct_interaural_waveforms() -> None:
    base = np.zeros((spatial.OUTPUT_FRAMES, 14))
    for left, right in spatial.DIRECTION_PAIRS.values():
        base[80, left] = 0.6
        base[87, left] = -0.2
        base[92, right] = 0.3
        base[103, right] = 0.1
    metrics = {
        "directions": {
            speaker: {
                "late_energy_ratios": {"5": 0.08, "10": 0.07, "20": 0.04, "50": 0.005},
                "zero_lag_interaural_correlation": 0.6,
            }
            for speaker in spatial.DIRECTION_PAIRS
        }
    }

    output, _ = spatial.synthesize_diffuse_variant(base, metrics, 1.0, "phase-seed")
    direct_end = 80 + round(0.005 * spatial.SAMPLE_RATE)
    gain = output[80, 0] / base[80, 0]
    residual = output[:direct_end] - base[:direct_end] * gain
    assert np.linalg.norm(residual) / np.linalg.norm(base[:direct_end] * gain) < 0.01
    for left, right in spatial.DIRECTION_PAIRS.values():
        source_itd = np.argmax(np.abs(base[:, right])) - np.argmax(np.abs(base[:, left]))
        output_itd = np.argmax(np.abs(output[:, right])) - np.argmax(np.abs(output[:, left]))
        assert output_itd == source_itd


def test_load_metrics_rejects_malformed_schema(tmp_path: Path) -> None:
    path = tmp_path / "metrics.json"
    path.write_text('{"schema_version": 99}', encoding="utf-8")
    with pytest.raises(spatial.PrototypeError, match="schema"):
        spatial.load_metrics(path)


def test_reference_conditioning_reduces_coarse_tone_error_and_matches_ild(
    tmp_path: Path,
) -> None:
    reference = reference_matrix()
    reference_path = tmp_path / "reference.wav"
    soundfile.write(reference_path, reference, spatial.SAMPLE_RATE, subtype="FLOAT")
    metrics = spatial.analyze_reference(reference_path)
    colored = np.zeros_like(reference)
    for channel in range(14):
        colored[:, channel] = np.convolve(
            reference[:, channel], np.array([1.0, -0.75]), mode="full"
        )[: len(reference)]

    before = spatial.maximum_reference_tone_error_db(colored, metrics)
    conditioned = spatial.condition_base_to_reference(colored, metrics, 1.0)
    after = spatial.maximum_reference_tone_error_db(conditioned, metrics)

    assert after < before
    for direction, target in metrics["directions"].items():
        left, right = spatial.DIRECTION_PAIRS[direction]
        measured = spatial.direction_metrics(
            conditioned, spatial.SAMPLE_RATE, left, right
        )
        assert measured["left_right_level_db"] == pytest.approx(
            target["left_right_level_db"], abs=0.25
        )


def test_generation_and_manifest_are_reproducible(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    reference = tmp_path / "reference.wav"
    write_reference(reference)
    metrics_path = tmp_path / "metrics.json"
    spatial.write_json(metrics_path, spatial.analyze_reference(reference))
    sofa_path = tmp_path / "HATS051123_1_processed.sofa"
    make_hats_sofa(sofa_path)
    output_dir = tmp_path / "output"
    install_dir = tmp_path / "installed"
    monkeypatch.setattr(
        generator,
        "VARIANTS",
        (("B_minphase_only", "fixture", True, 0.0),),
    )

    [output] = generator.generate(
        sofa_path, metrics_path, output_dir, install_dir, force=False
    )
    manifest_path = output.with_suffix(".wav.json")
    first_wav = output.read_bytes()
    first_manifest = manifest_path.read_bytes()
    generator.generate(sofa_path, metrics_path, output_dir, install_dir, force=True)

    assert output.read_bytes() == first_wav
    assert manifest_path.read_bytes() == first_manifest
    assert (install_dir / output.name).read_bytes() == first_wav
    info = soundfile.info(output)
    assert (info.channels, info.samplerate, info.frames, info.subtype) == (
        14,
        spatial.SAMPLE_RATE,
        spatial.OUTPUT_FRAMES,
        "FLOAT",
    )


def test_v3_generation_records_diffuse_phase_preserving_model(
    tmp_path: Path,
) -> None:
    reference = tmp_path / "reference.wav"
    write_reference(reference)
    metrics_path = tmp_path / "metrics.json"
    spatial.write_json(metrics_path, spatial.analyze_reference(reference))
    sofa_path = tmp_path / "HATS051123_1_processed.sofa"
    make_hats_sofa(sofa_path)

    [output] = generator.generate(
        sofa_path,
        metrics_path,
        tmp_path / "output",
        None,
        force=False,
        v3_diffuse=True,
    )
    manifest = json.loads(output.with_suffix(".wav.json").read_text())

    assert output.name == "HATS051123_1_V3_phase_diffuse_tone100.wav"
    assert manifest["variant"]["minimum_phase"] is False
    assert manifest["variant"]["tail_model"] == "dense-velvet-noise"
