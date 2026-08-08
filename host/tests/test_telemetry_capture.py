#!/usr/bin/env python3

from __future__ import annotations

import csv
import subprocess
import sys
import tempfile
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[2]
HOST_DIR = PROJECT_ROOT / "host"

sys.path.insert(
    0,
    str(HOST_DIR),
)

from capture_telemetry import (  # noqa: E402
    TelemetryParseError,
    parse_telemetry_line,
)


def assert_equal(
    actual: object,
    expected: object,
    description: str,
) -> None:
    if actual != expected:
        raise AssertionError(
            f"{description}: "
            f"actual={actual!r}, "
            f"esperado={expected!r}"
        )


record = parse_telemetry_line(
    (
        "TEL,7,2.100,"
        "A-->B,865,Info,Alice"
    ),
    port="/dev/ttyUSB0",
    host_timestamp=1002.5,
    experiment_start=1000.0,
    transport="uart",
)

assert_equal(
    record.timestamp,
    2.5,
    "Timestamp común",
)

assert_equal(
    record.direction,
    "A-->B",
    "Dirección",
)

assert_equal(
    record.encrypted_coord,
    865,
    "Coordenada",
)

assert_equal(
    record.frame_type,
    "Info",
    "Tipo",
)

invalid_detected = False

try:
    parse_telemetry_line(
        "TEL,0,0.0,X,500,Noise,Alice",
        port="/dev/ttyUSB0",
        host_timestamp=1.0,
        experiment_start=0.0,
        transport="uart",
    )
except TelemetryParseError:
    invalid_detected = True

assert_equal(
    invalid_detected,
    True,
    "Detección de línea inválida",
)

with tempfile.TemporaryDirectory() as temporary:
    temporary_path = Path(temporary)

    extended_csv = (
        temporary_path / "extended.csv"
    )

    normalized_csv = (
        temporary_path / "normalized.csv"
    )

    with extended_csv.open(
        "w",
        newline="",
        encoding="utf-8",
    ) as file:
        writer = csv.DictWriter(
            file,
            fieldnames=(
                "timestamp",
                "direction",
                "encrypted_coord",
                "type",
                "node",
            ),
        )

        writer.writeheader()

        writer.writerow({
            "timestamp": "2.0",
            "direction": "B-->A",
            "encrypted_coord": "200",
            "type": "Noise",
            "node": "Bob",
        })

        writer.writerow({
            "timestamp": "1.0",
            "direction": "A-->B",
            "encrypted_coord": "100",
            "type": "Info",
            "node": "Alice",
        })

    result = subprocess.run(
        (
            sys.executable,
            str(
                HOST_DIR
                / "normalize_telemetry.py"
            ),
            str(extended_csv),
            str(normalized_csv),
        ),
        check=False,
        capture_output=True,
        text=True,
    )

    assert_equal(
        result.returncode,
        0,
        "Normalizador",
    )

    with normalized_csv.open(
        newline="",
        encoding="utf-8",
    ) as file:
        rows = list(csv.DictReader(file))

    assert_equal(
        len(rows),
        2,
        "Cantidad de filas",
    )

    assert_equal(
        rows[0]["timestamp"],
        "1.0",
        "Orden temporal",
    )

    assert_equal(
        tuple(rows[0].keys()),
        (
            "timestamp",
            "direction",
            "encrypted_coord",
            "type",
        ),
        "Encabezado compatible",
    )

print("Parser de telemetría: PASS")
print("Detección de errores: PASS")
print("Normalización: PASS")
print("Compatibilidad de columnas: PASS")
print("RESULTADO: PASS")
