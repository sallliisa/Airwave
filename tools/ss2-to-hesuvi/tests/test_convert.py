from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import subprocess
import sys

from netCDF4 import Dataset
import numpy as np
import pytest
import sofar as sf
import soundfile


MODULE_PATH = Path(__file__).parents[1] / "convert.py"
SPEC = importlib.util.spec_from_file_location("ss2_convert", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
converter = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = converter
SPEC.loader.exec_module(converter)


BASE_POSITIONS = np.array(
    [
        [0.0, 0.0, 2.0],
        [30.0, 0.0, 2.0],
        [330.0, 0.0, 2.0],
        [90.0, 0.0, 2.0],
        [270.0, 0.0, 2.0],
        [132.0, 0.0, 2.0],
        [222.0, 0.0, 2.0],
    ],
    dtype=np.float64,
)


def make_sofa(
    path: Path,
    *,
    positions: np.ndarray = BASE_POSITIONS,
    receiver_positions: np.ndarray | None = None,
    delays: np.ndarray | None = None,
    cartesian: bool = False,
    sample_rate: float = 48_000.0,
) -> np.ndarray:
    positions = np.asarray(positions, dtype=np.float64)
    measurements = positions.shape[0]
    frames = 16
    impulses = np.zeros((measurements, 2, frames), dtype=np.float64)
    for measurement in range(measurements):
        impulses[measurement, 0, 2] = (measurement + 1) * 0.1
        impulses[measurement, 1, 5] = -(measurement + 1) * 0.01

    sofa = sf.Sofa("SimpleFreeFieldHRIR")
    sofa.GLOBAL_DatabaseName = "Fixture SS2"
    sofa.GLOBAL_ListenerShortName = "fixture"
    sofa.GLOBAL_License = "CC-BY-4.0"
    sofa.Data_IR = impulses
    sofa.Data_SamplingRate = sample_rate
    sofa.Data_Delay = np.array([[0.0, 0.0]]) if delays is None else delays
    sofa.ListenerPosition = np.array([[0.0, 0.0, 0.0]])
    sofa.ListenerView = np.array([[1.0, 0.0, 0.0]])
    sofa.ListenerUp = np.array([[0.0, 0.0, 1.0]])
    sofa.ReceiverPosition = (
        np.array([[0.0, 0.09, 0.0], [0.0, -0.09, 0.0]])
        if receiver_positions is None
        else receiver_positions
    )
    if cartesian:
        azimuth = np.deg2rad(positions[:, 0])
        elevation = np.deg2rad(positions[:, 1])
        radius = positions[:, 2]
        sofa.SourcePosition = np.column_stack(
            (
                radius * np.cos(elevation) * np.cos(azimuth),
                radius * np.cos(elevation) * np.sin(azimuth),
                radius * np.sin(elevation),
            )
        )
        sofa.SourcePosition_Type = "cartesian"
        sofa.SourcePosition_Units = "metre"
    else:
        sofa.SourcePosition = positions
        sofa.SourcePosition_Type = "spherical"
        sofa.SourcePosition_Units = "degree, degree, metre"
    sf.write_sofa(str(path), sofa)
    return impulses


def convert_fixture(tmp_path: Path, **kwargs):
    source = tmp_path / "source.sofa"
    impulses = make_sofa(source, **kwargs)
    output_root = tmp_path / "output"
    output, manifest = converter.convert_file(
        source,
        source,
        output_root,
        max_error_deg=5.0,
        force=False,
        validate=True,
    )
    return impulses, output, manifest


def test_reads_metadata_and_selects_expected_directions(tmp_path: Path) -> None:
    source = tmp_path / "source.sofa"
    make_sofa(source)
    data = converter.read_ss2_sofa(source)
    selections = converter.select_directions(data, 5.0)

    assert data.sample_rate == 48_000
    assert data.left_receiver == 0
    assert data.right_receiver == 1
    assert selections["FL"].measurement_index == 1
    assert selections["FR"].measurement_index == 2
    assert selections["BL"].measurement_index == 5
    assert selections["BR"].measurement_index == 6
    assert selections["BL"].angular_error_deg == pytest.approx(3.0)
    assert selections["BR"].angular_error_deg == pytest.approx(3.0)


def test_cartesian_source_coordinates_match_spherical_selection(tmp_path: Path) -> None:
    source = tmp_path / "source.sofa"
    make_sofa(source, cartesian=True)
    selections = converter.select_directions(converter.read_ss2_sofa(source), 5.0)
    assert {key: value.measurement_index for key, value in selections.items()} == {
        "FC": 0,
        "FL": 1,
        "FR": 2,
        "SL": 3,
        "SR": 4,
        "BL": 5,
        "BR": 6,
    }


def test_receiver_order_comes_from_positions(tmp_path: Path) -> None:
    source = tmp_path / "source.sofa"
    make_sofa(
        source,
        receiver_positions=np.array([[0.0, -0.09, 0.0], [0.0, 0.09, 0.0]]),
    )
    data = converter.read_ss2_sofa(source)
    assert (data.left_receiver, data.right_receiver) == (1, 0)


def test_ambiguous_receiver_positions_fail(tmp_path: Path) -> None:
    source = tmp_path / "source.sofa"
    make_sofa(
        source,
        receiver_positions=np.array([[0.0, 0.09, 0.0], [0.0, 0.08, 0.0]]),
    )
    with pytest.raises(converter.ConversionError, match="one left and one right"):
        converter.read_ss2_sofa(source)


def test_nearest_tie_uses_lowest_measurement_index(tmp_path: Path) -> None:
    positions = np.vstack((BASE_POSITIONS, [[133.0, 0.0, 2.0], [137.0, 0.0, 2.0]]))
    source = tmp_path / "source.sofa"
    make_sofa(source, positions=positions)
    selection = converter.select_directions(converter.read_ss2_sofa(source), 5.0)["BL"]
    assert selection.measurement_index == 7
    assert selection.actual_azimuth_deg == pytest.approx(133.0)


def test_angular_limit_rejects_sparse_grid(tmp_path: Path) -> None:
    source = tmp_path / "source.sofa"
    make_sofa(source)
    with pytest.raises(converter.ConversionError, match="above 2.000000° limit"):
        converter.select_directions(converter.read_ss2_sofa(source), 2.0)


def test_configurable_front_azimuth_selects_wider_measurements(tmp_path: Path) -> None:
    positions = np.vstack((BASE_POSITIONS, [[60.0, 0.0, 2.0], [300.0, 0.0, 2.0]]))
    source = tmp_path / "source.sofa"
    make_sofa(source, positions=positions)
    data = converter.read_ss2_sofa(source)
    selections = converter.select_target_directions(
        data, 5.0, converter.target_azimuths(60.0)
    )

    assert selections["FL"].measurement_index == 7
    assert selections["FR"].measurement_index == 8
    assert selections["FL"].target_azimuth_deg == 60.0
    assert selections["FR"].target_azimuth_deg == -60.0


@pytest.mark.parametrize("angle", [0.0, -30.0, 90.1, np.nan])
def test_invalid_front_azimuth_fails(angle: float) -> None:
    with pytest.raises(converter.ConversionError, match="Front azimuth"):
        converter.target_azimuths(angle)


def test_channel_order_preserves_independent_ear_samples(tmp_path: Path) -> None:
    impulses, output_path, manifest = convert_fixture(tmp_path)
    output, sample_rate = soundfile.read(output_path, dtype="float32", always_2d=True)
    measurement = {item["speaker"]: item["measurement_index"] for item in manifest["directions"]}
    gain = manifest["loudness_calibration"]["linear_gain"]

    assert sample_rate == 48_000
    assert output.shape == (16, 14)
    for channel, (speaker, ear) in enumerate(converter.CHANNEL_LAYOUT):
        receiver = 0 if ear == "left" else 1
        np.testing.assert_allclose(
            output[:, channel],
            (impulses[measurement[speaker], receiver] * gain).astype(np.float32),
            rtol=2e-7,
            atol=0,
        )
    # Direct and cross-ear impulses retain distinct level and timing.
    assert output[2, 0] == pytest.approx(0.2 * gain)
    assert output[5, 1] == pytest.approx(-0.02 * gain)
    assert output[2, 0] / output[5, 1] == pytest.approx(-10.0)


def test_loudness_calibration_matches_reference_with_one_global_gain(tmp_path: Path) -> None:
    _, output_path, manifest = convert_fixture(tmp_path)
    output, _ = soundfile.read(output_path, dtype="float64", always_2d=True)
    calibration = manifest["loudness_calibration"]

    assert converter.front_stereo_binaural_energy(output) == pytest.approx(
        converter.DEFAULT_LOUDNESS_TARGET, rel=1e-7
    )
    assert calibration["method"] == "global_gain_to_reference_front_stereo_binaural_l2_energy"
    assert calibration["reference"]["sha256"] == converter.DEFAULT_REFERENCE_SHA256
    assert calibration["linear_gain"] > 0


def test_custom_loudness_reference_is_measured_and_recorded(tmp_path: Path) -> None:
    reference_path = tmp_path / "reference.wav"
    reference = np.zeros((32, 14), dtype=np.float32)
    reference[3, :] = np.linspace(0.1, 1.4, 14)
    soundfile.write(reference_path, reference, 48_000, subtype="FLOAT")
    measured = converter.read_loudness_reference(reference_path)

    source = tmp_path / "source.sofa"
    make_sofa(source)
    output_path, manifest = converter.convert_file(
        source,
        source,
        tmp_path / "output",
        max_error_deg=5.0,
        force=False,
        validate=True,
        loudness_reference=measured,
    )
    output, _ = soundfile.read(output_path, dtype="float64", always_2d=True)

    assert converter.front_stereo_binaural_energy(output) == pytest.approx(
        converter.front_stereo_binaural_energy(reference), rel=1e-7
    )
    assert manifest["loudness_calibration"]["reference"]["sha256"] == converter.sha256_file(
        reference_path
    )


def test_integer_delays_are_materialized_without_sample_changes() -> None:
    left = np.array([1.0, 0.5], dtype=np.float64)
    right = np.array([0.25, -0.5], dtype=np.float64)
    output = converter.materialize_delays([left, right], [2.0, 0.0])
    np.testing.assert_array_equal(output[:, 0], [0.0, 0.0, 1.0, 0.5])
    np.testing.assert_array_equal(output[:, 1], [0.25, -0.5, 0.0, 0.0])


def test_fractional_delays_preserve_relative_group_delay() -> None:
    impulse = np.array([1.0])
    output = converter.materialize_delays([impulse, impulse], [0.25, 1.75])

    indices = np.arange(output.shape[0], dtype=np.float64)
    centers = [
        float(np.sum(indices * output[:, channel]) / np.sum(output[:, channel]))
        for channel in range(2)
    ]
    assert centers[1] - centers[0] == pytest.approx(1.5, abs=0.03)
    assert np.sum(output[:, 0]) == pytest.approx(1.0, abs=1e-6)
    assert np.sum(output[:, 1]) == pytest.approx(1.0, abs=1e-6)


def test_output_is_float32_source_rate_and_manifest_is_reproducible(tmp_path: Path) -> None:
    _, output_path, manifest = convert_fixture(tmp_path)
    info = soundfile.info(output_path)
    manifest_path = output_path.with_suffix(".wav.json")
    first_manifest = manifest_path.read_bytes()

    converter.convert_file(
        tmp_path / "source.sofa",
        tmp_path / "source.sofa",
        tmp_path / "output",
        max_error_deg=5.0,
        force=True,
        validate=True,
    )

    assert info.subtype == "FLOAT"
    assert info.channels == 14
    assert info.samplerate == 48_000
    assert manifest["output"]["sha256"] == converter.sha256_file(output_path)
    assert manifest_path.read_bytes() == first_manifest


def test_existing_output_requires_force(tmp_path: Path) -> None:
    convert_fixture(tmp_path)
    with pytest.raises(converter.ConversionError, match="use --force"):
        converter.convert_file(
            tmp_path / "source.sofa",
            tmp_path / "source.sofa",
            tmp_path / "output",
            max_error_deg=5.0,
            force=False,
            validate=False,
        )


def test_non_ss2_convention_fails(tmp_path: Path) -> None:
    source = tmp_path / "source.sofa"
    make_sofa(source)
    with Dataset(source, "r+") as dataset:
        dataset.setncattr("SOFAConventions", "GeneralFIR")
    with pytest.raises(converter.ConversionError, match="Expected SimpleFreeFieldHRIR"):
        converter.read_ss2_sofa(source)


def test_nan_samples_fail(tmp_path: Path) -> None:
    source = tmp_path / "source.sofa"
    make_sofa(source)
    with Dataset(source, "r+") as dataset:
        dataset.variables["Data.IR"][0, 0, 0] = np.nan
    with pytest.raises(converter.ConversionError, match="NaN or infinite"):
        converter.read_ss2_sofa(source)


def test_recursive_cli_preserves_relative_directories(tmp_path: Path) -> None:
    source_root = tmp_path / "input"
    first = source_root / "people" / "a.sofa"
    second = source_root / "mannequins" / "b.sofa"
    first.parent.mkdir(parents=True)
    second.parent.mkdir(parents=True)
    make_sofa(first)
    make_sofa(second)
    output_root = tmp_path / "output"

    result = subprocess.run(
        [
            sys.executable,
            str(MODULE_PATH),
            str(source_root),
            "--output-dir",
            str(output_root),
            "--validate",
        ],
        check=False,
        capture_output=True,
        text=True,
    )

    assert result.returncode == 0, result.stderr
    assert (output_root / "people" / "a.wav").is_file()
    assert (output_root / "mannequins" / "b.wav").is_file()
    assert len(list(output_root.rglob("*.wav.json"))) == 2
    assert "Converted 2 SOFA file(s)" in result.stdout


def test_manifest_contains_required_provenance(tmp_path: Path) -> None:
    _, output_path, _ = convert_fixture(tmp_path)
    manifest = json.loads(output_path.with_suffix(".wav.json").read_text())
    assert manifest["schema_version"] == 2
    assert manifest["source"]["license"] == "CC-BY-4.0"
    assert manifest["source"]["database"] == "Fixture SS2"
    assert len(manifest["directions"]) == 7
    assert len(manifest["channel_map"]) == 14
