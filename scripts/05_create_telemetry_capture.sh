#!/usr/bin/env bash

set -u

PROJECT_ROOT="/home/jfcrypt/Documents/Proyectos/InvisComm"
HOST_DIR="${PROJECT_ROOT}/host"
TESTS_DIR="${PROJECT_ROOT}/host/tests"
OUTPUT_DIR="${PROJECT_ROOT}/telemetry"

mkdir -p \
    "${HOST_DIR}" \
    "${TESTS_DIR}" \
    "${OUTPUT_DIR}"

###############################################################################
# Capturador simultáneo de telemetría
###############################################################################

cat > "${HOST_DIR}/capture_telemetry.py" <<'PY'
#!/usr/bin/env python3

from __future__ import annotations

import argparse
import csv
import queue
import signal
import sys
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from typing import TextIO

import serial


CSV_COLUMNS = (
    "timestamp",
    "direction",
    "encrypted_coord",
    "type",
    "node",
    "sequence",
    "device_timestamp",
    "host_timestamp",
    "port",
    "transport",
)


@dataclass(frozen=True)
class SerialSource:
    port: str
    node: str


@dataclass
class TelemetryRecord:
    timestamp: float
    direction: str
    encrypted_coord: int
    frame_type: str
    node: str
    sequence: int
    device_timestamp: float
    host_timestamp: float
    port: str
    transport: str

    def to_row(self) -> dict[str, object]:
        return {
            "timestamp": self.timestamp,
            "direction": self.direction,
            "encrypted_coord": self.encrypted_coord,
            "type": self.frame_type,
            "node": self.node,
            "sequence": self.sequence,
            "device_timestamp": self.device_timestamp,
            "host_timestamp": self.host_timestamp,
            "port": self.port,
            "transport": self.transport,
        }


class TelemetryParseError(ValueError):
    pass


def parse_telemetry_line(
    line: str,
    *,
    port: str,
    host_timestamp: float,
    experiment_start: float,
    transport: str,
) -> TelemetryRecord:
    """
    Formato emitido por el ESP32:

        TEL,sequence,timestamp,direction,encrypted_coord,type,node
    """

    stripped = line.strip()

    if not stripped.startswith("TEL,"):
        raise TelemetryParseError("La línea no es telemetría")

    fields = stripped.split(",")

    if len(fields) != 7:
        raise TelemetryParseError(
            f"Cantidad inválida de campos: {len(fields)}"
        )

    _, sequence, device_timestamp, direction, coordinate, frame_type, node = fields

    if direction not in ("A-->B", "B-->A"):
        raise TelemetryParseError(
            f"Dirección inválida: {direction!r}"
        )

    if frame_type not in ("Info", "Noise"):
        raise TelemetryParseError(
            f"Tipo inválido: {frame_type!r}"
        )

    try:
        sequence_value = int(sequence)
        device_timestamp_value = float(device_timestamp)
        coordinate_value = int(coordinate)
    except ValueError as error:
        raise TelemetryParseError(
            f"Campo numérico inválido: {error}"
        ) from error

    if not 0 <= coordinate_value <= 1023:
        raise TelemetryParseError(
            f"Coordenada fuera de rango: {coordinate_value}"
        )

    # Tiempo común para ambos dispositivos, medido por la computadora.
    common_timestamp = host_timestamp - experiment_start

    return TelemetryRecord(
        timestamp=common_timestamp,
        direction=direction,
        encrypted_coord=coordinate_value,
        frame_type=frame_type,
        node=node,
        sequence=sequence_value,
        device_timestamp=device_timestamp_value,
        host_timestamp=host_timestamp,
        port=port,
        transport=transport,
    )


class SerialReader(threading.Thread):
    def __init__(
        self,
        source: SerialSource,
        baudrate: int,
        output_queue: queue.Queue[tuple[SerialSource, float, str]],
        stop_event: threading.Event,
        log_file: TextIO,
    ) -> None:
        super().__init__(
            name=f"reader-{source.node}",
            daemon=True,
        )

        self.source = source
        self.baudrate = baudrate
        self.output_queue = output_queue
        self.stop_event = stop_event
        self.log_file = log_file
        self.error: Exception | None = None

    def run(self) -> None:
        try:
            with serial.Serial(
                self.source.port,
                self.baudrate,
                timeout=0.2,
            ) as device:
                while not self.stop_event.is_set():
                    raw_line = device.readline()

                    if not raw_line:
                        continue

                    host_timestamp = time.time()

                    line = raw_line.decode(
                        "utf-8",
                        errors="replace",
                    ).rstrip("\r\n")

                    self.log_file.write(
                        f"{host_timestamp:.6f},"
                        f"{self.source.port},"
                        f"{self.source.node},"
                        f"{line}\n"
                    )
                    self.log_file.flush()

                    self.output_queue.put(
                        (
                            self.source,
                            host_timestamp,
                            line,
                        )
                    )

        except Exception as error:
            self.error = error
            self.stop_event.set()


def build_argument_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "Captura telemetría simultánea de Alice y Bob "
            "desde dos puertos serie."
        )
    )

    parser.add_argument(
        "--port-a",
        default="/dev/ttyUSB0",
        help="Puerto serie de Alice",
    )

    parser.add_argument(
        "--port-b",
        default="/dev/ttyUSB1",
        help="Puerto serie de Bob",
    )

    parser.add_argument(
        "--baudrate",
        type=int,
        default=115200,
    )

    parser.add_argument(
        "--duration",
        type=float,
        default=60.0,
        help=(
            "Duración de la captura en segundos. "
            "Usar 0 para detener manualmente con Ctrl+C."
        ),
    )

    parser.add_argument(
        "--transport",
        choices=("loopback", "uart", "udp", "lora"),
        required=True,
    )

    parser.add_argument(
        "--output",
        type=Path,
        default=Path("telemetry/telemetria.csv"),
    )

    parser.add_argument(
        "--raw-log",
        type=Path,
        default=Path("telemetry/serial_raw.log"),
    )

    return parser


def main() -> int:
    parser = build_argument_parser()
    args = parser.parse_args()

    args.output.parent.mkdir(
        parents=True,
        exist_ok=True,
    )

    args.raw_log.parent.mkdir(
        parents=True,
        exist_ok=True,
    )

    stop_event = threading.Event()
    records_queue: queue.Queue[
        tuple[SerialSource, float, str]
    ] = queue.Queue()

    def request_stop(
        _signum: int,
        _frame: object,
    ) -> None:
        stop_event.set()

    signal.signal(
        signal.SIGINT,
        request_stop,
    )

    signal.signal(
        signal.SIGTERM,
        request_stop,
    )

    experiment_start = time.time()

    valid_records = 0
    ignored_lines = 0
    invalid_telemetry_lines = 0

    with args.raw_log.open(
        "w",
        encoding="utf-8",
        buffering=1,
    ) as raw_log, args.output.open(
        "w",
        newline="",
        encoding="utf-8",
    ) as csv_file:
        writer = csv.DictWriter(
            csv_file,
            fieldnames=CSV_COLUMNS,
        )

        writer.writeheader()
        csv_file.flush()

        readers = (
            SerialReader(
                SerialSource(args.port_a, "Alice"),
                args.baudrate,
                records_queue,
                stop_event,
                raw_log,
            ),
            SerialReader(
                SerialSource(args.port_b, "Bob"),
                args.baudrate,
                records_queue,
                stop_event,
                raw_log,
            ),
        )

        for reader in readers:
            reader.start()

        print("Captura iniciada")
        print(f"Alice: {args.port_a}")
        print(f"Bob:   {args.port_b}")
        print(f"Transporte: {args.transport}")
        print(f"CSV: {args.output}")
        print(f"Log bruto: {args.raw_log}")

        if args.duration > 0:
            print(
                f"Duración: {args.duration:.1f} segundos"
            )
        else:
            print("Duración: hasta Ctrl+C")

        deadline = (
            experiment_start + args.duration
            if args.duration > 0
            else None
        )

        while not stop_event.is_set():
            if (
                deadline is not None
                and time.time() >= deadline
            ):
                stop_event.set()
                break

            try:
                source, host_timestamp, line = (
                    records_queue.get(timeout=0.2)
                )
            except queue.Empty:
                continue

            if not line.startswith("TEL,"):
                ignored_lines += 1
                continue

            try:
                record = parse_telemetry_line(
                    line,
                    port=source.port,
                    host_timestamp=host_timestamp,
                    experiment_start=experiment_start,
                    transport=args.transport,
                )
            except TelemetryParseError as error:
                invalid_telemetry_lines += 1
                print(
                    "Telemetría inválida "
                    f"en {source.port}: {error}",
                    file=sys.stderr,
                )
                continue

            writer.writerow(record.to_row())
            csv_file.flush()

            valid_records += 1

            if valid_records % 20 == 0:
                print(
                    f"Registros capturados: {valid_records}"
                )

        stop_event.set()

        for reader in readers:
            reader.join(timeout=2.0)

        reader_errors = [
            (
                reader.source.node,
                reader.source.port,
                reader.error,
            )
            for reader in readers
            if reader.error is not None
        ]

    print()
    print("========================================")
    print("RESUMEN DE CAPTURA")
    print("========================================")
    print(f"Registros válidos: {valid_records}")
    print(f"Líneas ignoradas: {ignored_lines}")
    print(
        "Telemetría inválida: "
        f"{invalid_telemetry_lines}"
    )
    print(f"Errores de lectores: {len(reader_errors)}")
    print(f"Archivo CSV: {args.output}")
    print(f"Log bruto: {args.raw_log}")

    for node, port, error in reader_errors:
        print(
            f"ERROR {node} ({port}): {error}",
            file=sys.stderr,
        )

    if reader_errors:
        return 1

    if valid_records == 0:
        print(
            "ADVERTENCIA: no se capturó telemetría.",
            file=sys.stderr,
        )
        return 2

    print("RESULTADO: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
PY

###############################################################################
# Normalizador para archivos capturados previamente
###############################################################################

cat > "${HOST_DIR}/normalize_telemetry.py" <<'PY'
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
PY

###############################################################################
# Pruebas del parser y normalizador
###############################################################################

cat > "${TESTS_DIR}/test_telemetry_capture.py" <<'PY'
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
PY

###############################################################################
# Script de ejecución de captura
###############################################################################

cat > "${PROJECT_ROOT}/scripts/capture_experiment.sh" <<'BASH_CAPTURE'
#!/usr/bin/env bash

set -u

PROJECT_ROOT="/home/jfcrypt/Documents/Proyectos/InvisComm"
OUTPUT_FILE="/home/jfcrypt/Downloads/salida.txt"

cd "${PROJECT_ROOT}" || {
    echo "ERROR: no se pudo abrir el proyecto"
    return 1 2>/dev/null || true
}

source .venv-micropython/bin/activate

TRANSPORT="${1:-}"
DURATION="${2:-60}"

if [ -z "${TRANSPORT}" ]; then
    echo "Uso:"
    echo "bash scripts/capture_experiment.sh uart 60"
    echo "bash scripts/capture_experiment.sh udp 60"
    echo "bash scripts/capture_experiment.sh lora 60"
    return 1 2>/dev/null || true
fi

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
EXPERIMENT_DIR="telemetry/${TRANSPORT}_${TIMESTAMP}"

mkdir -p "${EXPERIMENT_DIR}"

run_capture() {
    echo "========================================"
    echo "CAPTURA INVISCOMM"
    echo "========================================"
    echo "Transporte: ${TRANSPORT}"
    echo "Duración: ${DURATION} segundos"
    echo "Directorio: ${EXPERIMENT_DIR}"
    echo

    python host/capture_telemetry.py \
        --port-a /dev/ttyUSB0 \
        --port-b /dev/ttyUSB1 \
        --baudrate 115200 \
        --duration "${DURATION}" \
        --transport "${TRANSPORT}" \
        --output "${EXPERIMENT_DIR}/telemetria_extendida.csv" \
        --raw-log "${EXPERIMENT_DIR}/serial_raw.log"

    CAPTURE_STATUS=$?

    python host/normalize_telemetry.py \
        "${EXPERIMENT_DIR}/telemetria_extendida.csv" \
        "${EXPERIMENT_DIR}/telemetria.csv"

    NORMALIZE_STATUS=$?

    echo
    echo "========================================"
    echo "RESUMEN"
    echo "========================================"
    echo "Captura: ${CAPTURE_STATUS}"
    echo "Normalización: ${NORMALIZE_STATUS}"
    echo "CSV extendido:"
    echo "${EXPERIMENT_DIR}/telemetria_extendida.csv"
    echo "CSV compatible:"
    echo "${EXPERIMENT_DIR}/telemetria.csv"

    if [ "${CAPTURE_STATUS}" -eq 0 ] \
        && [ "${NORMALIZE_STATUS}" -eq 0 ]; then
        echo "RESULTADO GENERAL: PASS"
    else
        echo "RESULTADO GENERAL: FAIL"
    fi

    echo
    echo "La terminal permanece abierta."
}

run_capture 2>&1 | tee "${OUTPUT_FILE}"
BASH_CAPTURE

chmod +x \
    "${HOST_DIR}/capture_telemetry.py" \
    "${HOST_DIR}/normalize_telemetry.py" \
    "${PROJECT_ROOT}/scripts/capture_experiment.sh"

###############################################################################
# Validación
###############################################################################

echo
echo "========================================"
echo "VALIDACIÓN SINTÁCTICA"
echo "========================================"

STATUS_SYNTAX=0
STATUS_TESTS=0

python -m py_compile \
    "${HOST_DIR}/capture_telemetry.py" \
    "${HOST_DIR}/normalize_telemetry.py" \
    "${TESTS_DIR}/test_telemetry_capture.py" \
    || STATUS_SYNTAX=1

if [ "${STATUS_SYNTAX}" -eq 0 ]; then
    echo "PASS: sintaxis"
else
    echo "FAIL: sintaxis"
fi

echo
echo "========================================"
echo "PRUEBAS"
echo "========================================"

python "${TESTS_DIR}/test_telemetry_capture.py" \
    || STATUS_TESTS=1

echo
echo "========================================"
echo "RESUMEN FINAL"
echo "========================================"
echo "Sintaxis: ${STATUS_SYNTAX}"
echo "Pruebas: ${STATUS_TESTS}"

if [ "${STATUS_SYNTAX}" -eq 0 ] \
    && [ "${STATUS_TESTS}" -eq 0 ]; then
    echo "RESULTADO GENERAL: PASS"
else
    echo "RESULTADO GENERAL: FAIL"
fi

echo
echo "La terminal permanece abierta."
