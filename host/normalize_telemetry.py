#!/usr/bin/env python3

from __future__ import annotations

import argparse
import csv
from pathlib import Path


REQUIRED_COLUMNS = (
    "timestamp",
    "direction",
    "encrypted_coord",
    "type",
)


def main() -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Normaliza telemetría de ESP32 al formato "
            "mínimo esperado por la notebook."
        )
    )

    parser.add_argument(
        "input",
        type=Path,
    )

    parser.add_argument(
        "output",
        type=Path,
    )

    args = parser.parse_args()

    with args.input.open(
        newline="",
        encoding="utf-8",
    ) as source_file:
        reader = csv.DictReader(source_file)

        if reader.fieldnames is None:
            raise ValueError(
                "El archivo no tiene encabezado"
            )

        missing = [
            column
            for column in REQUIRED_COLUMNS
            if column not in reader.fieldnames
        ]

        if missing:
            raise ValueError(
                "Faltan columnas: {}".format(
                    ", ".join(missing)
                )
            )

        rows = list(reader)

    rows.sort(
        key=lambda row: float(row["timestamp"])
    )

    args.output.parent.mkdir(
        parents=True,
        exist_ok=True,
    )

    with args.output.open(
        "w",
        newline="",
        encoding="utf-8",
    ) as destination_file:
        writer = csv.DictWriter(
            destination_file,
            fieldnames=REQUIRED_COLUMNS,
        )

        writer.writeheader()

        for row in rows:
            writer.writerow({
                "timestamp": row["timestamp"],
                "direction": row["direction"],
                "encrypted_coord": row[
                    "encrypted_coord"
                ],
                "type": row["type"],
            })

    print(f"Registros normalizados: {len(rows)}")
    print(f"Archivo generado: {args.output}")
    print("RESULTADO: PASS")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
