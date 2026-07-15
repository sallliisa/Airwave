#!/usr/bin/env python3
"""Reduce an unknown 14-channel reference to clean-room spatial statistics."""

from __future__ import annotations

import argparse
from pathlib import Path
import sys

from spatial import PrototypeError, analyze_reference, write_json


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("reference", type=Path, help="Local 14-channel reference WAV")
    parser.add_argument("--output", required=True, type=Path, help="Aggregate metrics JSON")
    args = parser.parse_args()
    try:
        metrics = analyze_reference(args.reference.resolve())
        write_json(args.output.resolve(), metrics)
        print(f"Wrote aggregate-only metrics to {args.output.resolve()}")
        return 0
    except (PrototypeError, OSError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
