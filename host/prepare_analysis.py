#!/usr/bin/env python3

from __future__ import annotations

import argparse
import shutil
import time
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser()

    parser.add_argument(
        "--experiment-dir",
        type=Path,
        required=True,
    )

    parser.add_argument(
        "--analysis-dir",
        type=Path,
        required=True,
    )

    args = parser.parse_args()

    source_csv = (
        args.experiment_dir
        / "telemetria.csv"
    )

    if not source_csv.exists():
        raise FileNotFoundError(
            source_csv
        )

    args.analysis_dir.mkdir(
        parents=True,
        exist_ok=True,
    )

    destination_csv = (
        args.analysis_dir
        / "telemetria.csv"
    )

    if destination_csv.exists():
        timestamp = time.strftime(
            "%Y%m%d_%H%M%S"
        )

        backup = (
            args.analysis_dir
            / (
                "telemetria_backup_"
                + timestamp
                + ".csv"
            )
        )

        shutil.copy2(
            destination_csv,
            backup,
        )

        print("Respaldo:", backup)

    shutil.copy2(
        source_csv,
        destination_csv,
    )

    evidence_dir = (
        args.analysis_dir
        / "evidence"
        / args.experiment_dir.name
    )

    evidence_dir.mkdir(
        parents=True,
        exist_ok=True,
    )

    for filename in (
        "telemetria.csv",
        "telemetria_extendida.csv",
        "serial_raw.log",
    ):
        source = (
            args.experiment_dir
            / filename
        )

        if source.exists():
            shutil.copy2(
                source,
                evidence_dir / filename,
            )

    print("CSV de análisis:", destination_csv)
    print("Evidencia:", evidence_dir)
    print("RESULTADO: PASS")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
