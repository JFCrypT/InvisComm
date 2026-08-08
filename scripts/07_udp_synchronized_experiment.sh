#!/usr/bin/env bash

set -u

PROJECT_ROOT="/home/jfcrypt/Documents/Proyectos/InvisComm"
MICROPYTHON_DIR="${PROJECT_ROOT}/micropython"
COMMON_DIR="${MICROPYTHON_DIR}/common"
NODE_A_DIR="${MICROPYTHON_DIR}/node_a"
NODE_B_DIR="${MICROPYTHON_DIR}/node_b"
HOST_DIR="${PROJECT_ROOT}/host"

ESP32_A_PORT="/dev/ttyUSB0"
ESP32_B_PORT="/dev/ttyUSB1"

cd "${PROJECT_ROOT}" || {
    echo "ERROR: no se pudo abrir el proyecto"
    return 1 2>/dev/null || true
}

source .venv-micropython/bin/activate

mkdir -p "${HOST_DIR}"

###############################################################################
# Protocolo de sincronización
###############################################################################

cat > "${COMMON_DIR}/session_control.py" <<'PY'
import socket
import time


CONTROL_PORT = 43000
START_PREFIX = "INVISCOMM_START"


class SessionControlError(Exception):
    pass


def wait_for_start(
    node_name,
    local_port=CONTROL_PORT,
    timeout_seconds=300,
):
    """
    Espera una orden:

        INVISCOMM_START,<session_id>,<delay_ms>
    """

    control_socket = socket.socket(
        socket.AF_INET,
        socket.SOCK_DGRAM,
    )

    try:
        control_socket.setsockopt(
            socket.SOL_SOCKET,
            socket.SO_REUSEADDR,
            1,
        )
    except Exception:
        pass

    control_socket.bind(
        ("0.0.0.0", local_port)
    )

    control_socket.settimeout(1.0)

    print(
        "READY,{},{},{}".format(
            node_name,
            local_port,
            time.ticks_ms(),
        )
    )

    start_ms = time.ticks_ms()
    timeout_ms = timeout_seconds * 1000

    while True:
        if time.ticks_diff(
            time.ticks_ms(),
            start_ms,
        ) >= timeout_ms:
            control_socket.close()

            raise SessionControlError(
                "Timeout esperando orden START"
            )

        try:
            payload, source = (
                control_socket.recvfrom(128)
            )
        except OSError:
            continue

        try:
            message = payload.decode(
                "utf-8"
            ).strip()
        except Exception:
            continue

        fields = message.split(",")

        if len(fields) != 3:
            continue

        if fields[0] != START_PREFIX:
            continue

        session_id = fields[1]

        try:
            delay_ms = int(fields[2])
        except ValueError:
            continue

        if delay_ms < 0 or delay_ms > 30000:
            continue

        print(
            "CONTROL,{},{},{},{}".format(
                node_name,
                session_id,
                delay_ms,
                source[0],
            )
        )

        control_socket.close()

        return {
            "session_id": session_id,
            "delay_ms": delay_ms,
            "source": source,
        }
PY

###############################################################################
# Bootstrap sincronizado
###############################################################################

cat > "${COMMON_DIR}/app_bootstrap.py" <<'PY'
import gc
import time

from common.node_runtime import InvisCommNodeRuntime
from common.session_control import wait_for_start
from common.transports.factory import create_transport
from common.wifi_manager import connect_wifi


def start_node(
    config,
    wifi_ssid,
    wifi_password,
):
    print()
    print("========================================")
    print("InvisComm ESP32")
    print("========================================")
    print("Nodo:", config["name"])
    print("Transporte:", config["transport"])
    print("Conectando a Wi-Fi...")

    station = connect_wifi(
        ssid=wifi_ssid,
        password=wifi_password,
        timeout_seconds=30,
        hostname=config["hostname"],
    )

    network_data = station.ifconfig()

    print("Wi-Fi conectado")
    print("IP:", network_data[0])
    print("Máscara:", network_data[1])
    print("Gateway:", network_data[2])
    print("Memoria libre:", gc.mem_free())

    session = wait_for_start(
        config["name"],
        local_port=config.get(
            "control_port",
            43000,
        ),
    )

    print(
        "Sesión recibida:",
        session["session_id"],
    )

    # Los motores se construyen después de START.
    # Ambos nodos comienzan entonces desde fase y posición cero.
    transport = create_transport(config)

    node = InvisCommNodeRuntime(
        name=config["name"],
        node_id=config["node_id"],
        peer_id=config["peer_id"],
        shared_key=config["shared_key"],
        alphabet=config["alphabet"],
        transport=transport,
        tx_interval_ms=config["tx_interval_ms"],
        telemetry_enabled=True,
        strict_position=True,
    )

    startup_message = config.get(
        "startup_message",
        "",
    )

    if startup_message:
        node.load_message(startup_message)

        print(
            "Mensaje inicial cargado:",
            startup_message,
        )

    delay_ms = session["delay_ms"]

    print(
        "Inicio sincronizado en {} ms".format(
            delay_ms
        )
    )

    time.sleep_ms(delay_ms)

    print(
        "START,{},{}".format(
            config["name"],
            session["session_id"],
        )
    )

    node.run_forever()
PY

###############################################################################
# Planificación sin sumar otros 300 ms al tiempo de cálculo
###############################################################################

python - "${COMMON_DIR}/node_runtime.py" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")

text = text.replace(
    "        self._last_tx_ms = time.ticks_ms()\n",
    "        self._last_tx_ms = time.ticks_ms()\n"
    "        self._next_tx_ms = time.ticks_add(\n"
    "            self._last_tx_ms,\n"
    "            self.tx_interval_ms,\n"
    "        )\n",
    1,
)

old_method = '''    def transmit_if_due(self):
        elapsed_ms = time.ticks_diff(
            time.ticks_ms(),
            self._last_tx_ms,
        )

        if elapsed_ms < self.tx_interval_ms:
            return None

        return self.transmit_once()
'''

new_method = '''    def transmit_if_due(self):
        now_ms = time.ticks_ms()

        if time.ticks_diff(
            now_ms,
            self._next_tx_ms,
        ) < 0:
            return None

        # La próxima fecha se calcula respecto de la anterior,
        # no respecto del final de la codificación.
        self._next_tx_ms = time.ticks_add(
            self._next_tx_ms,
            self.tx_interval_ms,
        )

        return self.transmit_once()
'''

if old_method in text:
    text = text.replace(
        old_method,
        new_method,
        1,
    )
elif "self._next_tx_ms" not in text:
    raise SystemExit(
        "ERROR: no se pudo modificar transmit_if_due"
    )

path.write_text(
    text,
    encoding="utf-8",
)
PY

###############################################################################
# Agregar puerto de control a las configuraciones
###############################################################################

python - \
    "${NODE_A_DIR}/node_config.py" \
    "${NODE_B_DIR}/node_config.py" <<'PY'
from pathlib import Path
import sys

for filename in sys.argv[1:]:
    path = Path(filename)
    text = path.read_text(encoding="utf-8")

    if '"control_port"' not in text:
        text = text.replace(
            '    "transport": "udp",\n',
            '    "transport": "udp",\n'
            '    "control_port": 43000,\n',
            1,
        )

    path.write_text(
        text,
        encoding="utf-8",
    )
PY

###############################################################################
# Ejecutor coordinado de experimento UDP
###############################################################################

cat > "${HOST_DIR}/run_udp_experiment.py" <<'PY'
#!/usr/bin/env python3

from __future__ import annotations

import argparse
import csv
import queue
import socket
import threading
import time
from dataclasses import dataclass
from pathlib import Path

import serial

from capture_telemetry import (
    CSV_COLUMNS,
    TelemetryParseError,
    parse_telemetry_line,
)


@dataclass(frozen=True)
class Source:
    port: str
    expected_node: str


class Reader(threading.Thread):
    def __init__(
        self,
        source: Source,
        baudrate: int,
        output_queue: queue.Queue,
        stop_event: threading.Event,
    ) -> None:
        super().__init__(
            daemon=True,
            name="reader-" + source.expected_node,
        )

        self.source = source
        self.baudrate = baudrate
        self.output_queue = output_queue
        self.stop_event = stop_event
        self.error: Exception | None = None

    def run(self) -> None:
        try:
            with serial.Serial(
                self.source.port,
                self.baudrate,
                timeout=0.2,
            ) as device:
                while not self.stop_event.is_set():
                    raw = device.readline()

                    if not raw:
                        continue

                    line = raw.decode(
                        "utf-8",
                        errors="replace",
                    ).rstrip("\r\n")

                    self.output_queue.put(
                        (
                            self.source,
                            time.time(),
                            line,
                        )
                    )

        except Exception as error:
            self.error = error
            self.stop_event.set()


def send_start(
    broadcast_address: str,
    control_port: int,
    session_id: str,
    delay_ms: int,
) -> None:
    payload = (
        "INVISCOMM_START,"
        + session_id
        + ","
        + str(delay_ms)
    ).encode("utf-8")

    with socket.socket(
        socket.AF_INET,
        socket.SOCK_DGRAM,
    ) as control:
        control.setsockopt(
            socket.SOL_SOCKET,
            socket.SO_BROADCAST,
            1,
        )

        for _ in range(10):
            control.sendto(
                payload,
                (
                    broadcast_address,
                    control_port,
                ),
            )

            time.sleep(0.1)


def main() -> int:
    parser = argparse.ArgumentParser()

    parser.add_argument(
        "--port-a",
        default="/dev/ttyUSB0",
    )

    parser.add_argument(
        "--port-b",
        default="/dev/ttyUSB1",
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
    )

    parser.add_argument(
        "--broadcast",
        default="192.168.100.255",
    )

    parser.add_argument(
        "--control-port",
        type=int,
        default=43000,
    )

    parser.add_argument(
        "--start-delay-ms",
        type=int,
        default=3000,
    )

    parser.add_argument(
        "--output-dir",
        type=Path,
        required=True,
    )

    args = parser.parse_args()

    args.output_dir.mkdir(
        parents=True,
        exist_ok=True,
    )

    extended_path = (
        args.output_dir
        / "telemetria_extendida.csv"
    )

    compatible_path = (
        args.output_dir
        / "telemetria.csv"
    )

    raw_path = (
        args.output_dir
        / "serial_raw.log"
    )

    stop_event = threading.Event()
    events: queue.Queue = queue.Queue()

    readers = (
        Reader(
            Source(args.port_a, "Alice"),
            args.baudrate,
            events,
            stop_event,
        ),
        Reader(
            Source(args.port_b, "Bob"),
            args.baudrate,
            events,
            stop_event,
        ),
    )

    for reader in readers:
        reader.start()

    ready_nodes: set[str] = set()

    print("Esperando READY de Alice y Bob...")

    ready_deadline = time.time() + 60.0

    buffered_lines: list[
        tuple[Source, float, str]
    ] = []

    while (
        ready_nodes != {"Alice", "Bob"}
        and time.time() < ready_deadline
        and not stop_event.is_set()
    ):
        try:
            source, timestamp, line = (
                events.get(timeout=0.5)
            )
        except queue.Empty:
            continue

        buffered_lines.append(
            (source, timestamp, line)
        )

        if line.startswith("READY,"):
            fields = line.split(",")

            if len(fields) >= 2:
                ready_nodes.add(fields[1])
                print("READY:", fields[1])

    if ready_nodes != {"Alice", "Bob"}:
        stop_event.set()

        print(
            "ERROR: no se recibieron ambos READY:",
            sorted(ready_nodes),
        )

        return 1

    session_id = time.strftime(
        "%Y%m%d_%H%M%S"
    )

    experiment_start = time.time()

    send_start(
        args.broadcast,
        args.control_port,
        session_id,
        args.start_delay_ms,
    )

    print("START enviado:", session_id)
    print(
        "Capturando durante",
        args.duration,
        "segundos",
    )

    valid_records = 0
    rows: list[dict[str, object]] = []

    with raw_path.open(
        "w",
        encoding="utf-8",
        buffering=1,
    ) as raw_file, extended_path.open(
        "w",
        newline="",
        encoding="utf-8",
    ) as extended_file:
        writer = csv.DictWriter(
            extended_file,
            fieldnames=CSV_COLUMNS,
        )

        writer.writeheader()

        deadline = (
            experiment_start
            + args.duration
            + args.start_delay_ms / 1000.0
        )

        while (
            time.time() < deadline
            and not stop_event.is_set()
        ):
            try:
                source, timestamp, line = (
                    events.get(timeout=0.2)
                )
            except queue.Empty:
                continue

            raw_file.write(
                "{:.6f},{},{},{}\n".format(
                    timestamp,
                    source.port,
                    source.expected_node,
                    line,
                )
            )

            if not line.startswith("TEL,"):
                continue

            try:
                record = parse_telemetry_line(
                    line,
                    port=source.port,
                    host_timestamp=timestamp,
                    experiment_start=experiment_start,
                    transport="udp",
                )
            except TelemetryParseError:
                continue

            row = record.to_row()
            writer.writerow(row)
            extended_file.flush()

            rows.append(row)
            valid_records += 1

            if valid_records % 20 == 0:
                print(
                    "Registros:",
                    valid_records,
                )

    stop_event.set()

    for reader in readers:
        reader.join(timeout=2.0)

    rows.sort(
        key=lambda row: float(
            row["timestamp"]
        )
    )

    with compatible_path.open(
        "w",
        newline="",
        encoding="utf-8",
    ) as compatible_file:
        writer = csv.DictWriter(
            compatible_file,
            fieldnames=(
                "timestamp",
                "direction",
                "encrypted_coord",
                "type",
            ),
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

    directions = {
        str(row["direction"])
        for row in rows
    }

    info_count = sum(
        1
        for row in rows
        if row["type"] == "Info"
    )

    print()
    print("========================================")
    print("RESUMEN")
    print("========================================")
    print("Registros:", valid_records)
    print("Direcciones:", sorted(directions))
    print("Tramas Info:", info_count)
    print("CSV:", compatible_path)

    if (
        valid_records > 0
        and directions == {"A-->B", "B-->A"}
        and info_count > 0
    ):
        print("RESULTADO GENERAL: PASS")
        return 0

    print("RESULTADO GENERAL: FAIL")
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
PY

chmod +x "${HOST_DIR}/run_udp_experiment.py"

###############################################################################
# Validación y despliegue
###############################################################################

STATUS_SYNTAX=0
STATUS_A=0
STATUS_B=0

python -m py_compile \
    "${COMMON_DIR}/session_control.py" \
    "${COMMON_DIR}/app_bootstrap.py" \
    "${COMMON_DIR}/node_runtime.py" \
    "${HOST_DIR}/run_udp_experiment.py" \
    || STATUS_SYNTAX=1

deploy() {
    local port="$1"
    local node_dir="$2"

    local status=0

    for file in \
        "${COMMON_DIR}/session_control.py" \
        "${COMMON_DIR}/app_bootstrap.py" \
        "${COMMON_DIR}/node_runtime.py"
    do
        mpremote connect "${port}" fs cp \
            "${file}" \
            ":common/$(basename "${file}")" \
            || status=1
    done

    mpremote connect "${port}" fs cp \
        "${node_dir}/node_config.py" \
        :node_config.py \
        || status=1

    mpremote connect "${port}" fs cp \
        "${node_dir}/main.py" \
        :main.py \
        || status=1

    return "${status}"
}

deploy "${ESP32_A_PORT}" "${NODE_A_DIR}" \
    || STATUS_A=1

deploy "${ESP32_B_PORT}" "${NODE_B_DIR}" \
    || STATUS_B=1

mpremote connect "${ESP32_A_PORT}" reset \
    || STATUS_A=1

sleep 1

mpremote connect "${ESP32_B_PORT}" reset \
    || STATUS_B=1

echo
echo "========================================"
echo "RESUMEN DEL DESPLIEGUE"
echo "========================================"
echo "Sintaxis: ${STATUS_SYNTAX}"
echo "Alice: ${STATUS_A}"
echo "Bob: ${STATUS_B}"

if [ "${STATUS_SYNTAX}" -eq 0 ] \
    && [ "${STATUS_A}" -eq 0 ] \
    && [ "${STATUS_B}" -eq 0 ]; then
    echo "RESULTADO GENERAL: PASS"
else
    echo "RESULTADO GENERAL: FAIL"
fi

echo
echo "Los nodos quedaron esperando READY/START."
echo "La terminal permanece abierta."
