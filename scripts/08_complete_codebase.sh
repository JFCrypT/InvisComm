#!/usr/bin/env bash

set -u

PROJECT_ROOT="/home/jfcrypt/Documents/Proyectos/InvisComm"
MICROPYTHON_DIR="${PROJECT_ROOT}/micropython"
COMMON_DIR="${MICROPYTHON_DIR}/common"
TRANSPORTS_DIR="${COMMON_DIR}/transports"
CONFIGS_DIR="${MICROPYTHON_DIR}/configs"
HOST_DIR="${PROJECT_ROOT}/host"
SCRIPTS_DIR="${PROJECT_ROOT}/scripts"

mkdir -p \
    "${COMMON_DIR}" \
    "${TRANSPORTS_DIR}" \
    "${CONFIGS_DIR}/udp/alice" \
    "${CONFIGS_DIR}/udp/bob" \
    "${CONFIGS_DIR}/uart/alice" \
    "${CONFIGS_DIR}/uart/bob" \
    "${CONFIGS_DIR}/lora/alice" \
    "${CONFIGS_DIR}/lora/bob" \
    "${HOST_DIR}" \
    "${SCRIPTS_DIR}"

###############################################################################
# Control de sesión mediante USB serie
###############################################################################

cat > "${COMMON_DIR}/usb_session_control.py" <<'PY'
import sys
import time

try:
    import select
except ImportError:
    import uselect as select


START_PREFIX = "INVISCOMM_START"


class USBSessionControlError(Exception):
    pass


def wait_for_usb_start(
    node_name,
    timeout_seconds=300,
):
    """
    Espera por USB serie una línea:

        INVISCOMM_START,<session_id>,<delay_ms>

    El host abre los puertos USB, espera READY y envía la orden
    simultáneamente a Alice y Bob.
    """

    poller = select.poll()

    poller.register(
        sys.stdin,
        select.POLLIN,
    )

    print(
        "READY,{},{},{}".format(
            node_name,
            "USB",
            time.ticks_ms(),
        )
    )

    start_ms = time.ticks_ms()
    timeout_ms = timeout_seconds * 1000

    while True:
        elapsed = time.ticks_diff(
            time.ticks_ms(),
            start_ms,
        )

        if elapsed >= timeout_ms:
            raise USBSessionControlError(
                "Timeout esperando START por USB"
            )

        events = poller.poll(200)

        if not events:
            continue

        try:
            line = sys.stdin.readline()
        except Exception:
            continue

        if not line:
            continue

        message = line.strip()
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
            "CONTROL,{},{},{}".format(
                node_name,
                session_id,
                delay_ms,
            )
        )

        return {
            "session_id": session_id,
            "delay_ms": delay_ms,
            "source": "USB",
        }
PY

###############################################################################
# Bootstrap unificado
###############################################################################

cat > "${COMMON_DIR}/app_bootstrap.py" <<'PY'
import gc
import time

from common.node_runtime import InvisCommNodeRuntime
from common.transports.factory import create_transport


def _prepare_network(config):
    if config["transport"] != "udp":
        return None

    from common.wifi_manager import connect_wifi
    from wifi_secrets import WIFI_PASSWORD, WIFI_SSID

    print("Conectando a Wi-Fi...")

    station = connect_wifi(
        ssid=WIFI_SSID,
        password=WIFI_PASSWORD,
        timeout_seconds=30,
        hostname=config["hostname"],
    )

    network_data = station.ifconfig()

    print("Wi-Fi conectado")
    print("IP:", network_data[0])
    print("Máscara:", network_data[1])
    print("Gateway:", network_data[2])

    return station


def _wait_for_session(config):
    control_mode = config.get(
        "control_mode",
        "usb",
    )

    if control_mode == "udp":
        from common.session_control import wait_for_start

        return wait_for_start(
            config["name"],
            local_port=config.get(
                "control_port",
                43000,
            ),
        )

    if control_mode == "usb":
        from common.usb_session_control import (
            wait_for_usb_start,
        )

        return wait_for_usb_start(
            config["name"],
        )

    raise ValueError(
        "Modo de control no soportado: {}".format(
            control_mode
        )
    )


def start_node(config):
    print()
    print("========================================")
    print("InvisComm ESP32")
    print("========================================")
    print("Nodo:", config["name"])
    print("Transporte:", config["transport"])
    print("Control:", config["control_mode"])

    _prepare_network(config)

    print("Memoria libre:", gc.mem_free())

    session = _wait_for_session(config)

    print(
        "Sesión recibida:",
        session["session_id"],
    )

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
        initial_tx_delay_ms=config.get(
            "initial_tx_delay_ms",
            config["tx_interval_ms"],
        ),
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
# Ajuste del runtime: primer TX configurable y telemetría de recepción
###############################################################################

python - "${COMMON_DIR}/node_runtime.py" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")

old_signature = '''        telemetry_enabled=True,
        strict_position=True,
    ):
'''

new_signature = '''        telemetry_enabled=True,
        strict_position=True,
        initial_tx_delay_ms=None,
    ):
'''

if old_signature in text:
    text = text.replace(
        old_signature,
        new_signature,
        1,
    )

assignment = '''        self.strict_position = strict_position
'''

replacement = '''        self.strict_position = strict_position

        if initial_tx_delay_ms is None:
            initial_tx_delay_ms = tx_interval_ms

        self.initial_tx_delay_ms = initial_tx_delay_ms
'''

if assignment in text and (
    "self.initial_tx_delay_ms"
    not in text
):
    text = text.replace(
        assignment,
        replacement,
        1,
    )

old_next = '''        self._next_tx_ms = time.ticks_add(
            self._last_tx_ms,
            self.tx_interval_ms,
        )
'''

new_next = '''        self._next_tx_ms = time.ticks_add(
            self._last_tx_ms,
            self.initial_tx_delay_ms,
        )
'''

if old_next in text:
    text = text.replace(
        old_next,
        new_next,
        1,
    )

old_rx = '''        self.stats["rx_valid"] += 1

        print(
            "RX,{},{},{},{},{}".format(
                self.name,
                received_position,
                decoded_frame["coordinate"],
                repr(character),
                decode_time_us,
            )
        )
'''

new_rx = '''        self.stats["rx_valid"] += 1

        metadata = self.transport.metadata()

        rssi = metadata.get("rssi", "")
        snr = metadata.get("snr", "")
        radio_crc = metadata.get("crc_valid", "")

        print(
            "RX,{},{},{},{},{},{},{},{}".format(
                self.name,
                received_position,
                decoded_frame["coordinate"],
                repr(character),
                decode_time_us,
                rssi,
                snr,
                radio_crc,
            )
        )
'''

if old_rx in text:
    text = text.replace(
        old_rx,
        new_rx,
        1,
    )

path.write_text(
    text,
    encoding="utf-8",
)
PY

###############################################################################
# main.py genérico
###############################################################################

cat > "${MICROPYTHON_DIR}/main.py" <<'PY'
from common.app_bootstrap import start_node
from node_config import CONFIG


start_node(CONFIG)
PY

###############################################################################
# Configuración base compartida
###############################################################################

cat > "${COMMON_DIR}/experiment_defaults.py" <<'PY'
from common.app_config import (
    ALPHABET,
    KEP_SHARED_KEY,
    NODE_A_ID,
    NODE_A_NAME,
    NODE_B_ID,
    NODE_B_NAME,
)


ALICE_BASE = {
    "name": NODE_A_NAME,
    "hostname": "inviscomm-alice",
    "node_id": NODE_A_ID,
    "peer_id": NODE_B_ID,
    "shared_key": KEP_SHARED_KEY,
    "alphabet": ALPHABET,
    "startup_message": (
        "Attack from the northern front"
    ),
}


BOB_BASE = {
    "name": NODE_B_NAME,
    "hostname": "inviscomm-bob",
    "node_id": NODE_B_ID,
    "peer_id": NODE_A_ID,
    "shared_key": KEP_SHARED_KEY,
    "alphabet": ALPHABET,
    "startup_message": (
        "Received. The attack will begin at 12:00"
    ),
}
PY

###############################################################################
# UDP
###############################################################################

cat > "${CONFIGS_DIR}/udp/alice/node_config.py" <<'PY'
from common.experiment_defaults import ALICE_BASE


CONFIG = dict(ALICE_BASE)

CONFIG.update({
    "transport": "udp",
    "control_mode": "udp",
    "control_port": 43000,

    "tx_interval_ms": 300,
    "initial_tx_delay_ms": 300,

    "local_ip": "0.0.0.0",
    "local_port": 42001,
    "remote_ip": "255.255.255.255",
    "remote_port": 42002,
})
PY

cat > "${CONFIGS_DIR}/udp/bob/node_config.py" <<'PY'
from common.experiment_defaults import BOB_BASE


CONFIG = dict(BOB_BASE)

CONFIG.update({
    "transport": "udp",
    "control_mode": "udp",
    "control_port": 43000,

    "tx_interval_ms": 300,
    "initial_tx_delay_ms": 300,

    "local_ip": "0.0.0.0",
    "local_port": 42002,
    "remote_ip": "255.255.255.255",
    "remote_port": 42001,
})
PY

###############################################################################
# UART
###############################################################################

cat > "${CONFIGS_DIR}/uart/alice/node_config.py" <<'PY'
from common.experiment_defaults import ALICE_BASE


CONFIG = dict(ALICE_BASE)

CONFIG.update({
    "transport": "uart",
    "control_mode": "usb",

    "tx_interval_ms": 1000,
    "initial_tx_delay_ms": 500,

    "uart_id": 2,
    "uart_baudrate": 115200,
    "uart_tx_pin": 17,
    "uart_rx_pin": 16,
})
PY

cat > "${CONFIGS_DIR}/uart/bob/node_config.py" <<'PY'
from common.experiment_defaults import BOB_BASE


CONFIG = dict(BOB_BASE)

CONFIG.update({
    "transport": "uart",
    "control_mode": "usb",

    "tx_interval_ms": 1000,
    "initial_tx_delay_ms": 500,

    "uart_id": 2,
    "uart_baudrate": 115200,
    "uart_tx_pin": 17,
    "uart_rx_pin": 16,
})
PY

###############################################################################
# LoRa
###############################################################################

cat > "${CONFIGS_DIR}/lora/alice/node_config.py" <<'PY'
from common.experiment_defaults import ALICE_BASE


CONFIG = dict(ALICE_BASE)

CONFIG.update({
    "transport": "lora",
    "control_mode": "usb",

    # Mayor intervalo para evitar colisiones y permitir
    # cifrado, recepción y decodificación.
    "tx_interval_ms": 1500,
    "initial_tx_delay_ms": 500,

    "lora_spi_id": 2,
    "lora_sck_pin": 18,
    "lora_mosi_pin": 23,
    "lora_miso_pin": 19,
    "lora_cs_pin": 5,
    "lora_reset_pin": 14,
    "lora_dio0_pin": 26,

    "lora_frequency": 433000000,
    "lora_tx_power": 10,
    "lora_spreading_factor": 7,
    "lora_bandwidth": 125000,
    "lora_coding_rate": 5,
    "lora_preamble_length": 8,
    "lora_sync_word": 0x42,
})
PY

cat > "${CONFIGS_DIR}/lora/bob/node_config.py" <<'PY'
from common.experiment_defaults import BOB_BASE


CONFIG = dict(BOB_BASE)

CONFIG.update({
    "transport": "lora",
    "control_mode": "usb",

    "tx_interval_ms": 1500,

    # Bob transmite desplazado 750 ms respecto de Alice.
    "initial_tx_delay_ms": 1250,

    "lora_spi_id": 2,
    "lora_sck_pin": 18,
    "lora_mosi_pin": 23,
    "lora_cs_pin": 5,
    "lora_reset_pin": 14,
    "lora_dio0_pin": 26,

    "lora_frequency": 433000000,
    "lora_tx_power": 10,
    "lora_spreading_factor": 7,
    "lora_bandwidth": 125000,
    "lora_coding_rate": 5,
    "lora_preamble_length": 8,
    "lora_sync_word": 0x42,
})
PY

###############################################################################
# Ejecutor genérico
###############################################################################

cat > "${HOST_DIR}/run_experiment.py" <<'PY'
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
        self.device: serial.Serial | None = None

    def run(self) -> None:
        try:
            with serial.Serial(
                self.source.port,
                self.baudrate,
                timeout=0.2,
                write_timeout=2.0,
            ) as device:
                self.device = device

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

    def send_line(self, line: str) -> None:
        if self.device is None:
            raise RuntimeError(
                "Puerto no disponible: "
                + self.source.port
            )

        self.device.write(
            (line + "\r\n").encode("utf-8")
        )

        self.device.flush()


def send_udp_start(
    broadcast_address: str,
    control_port: int,
    payload: bytes,
) -> None:
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
        "--transport",
        required=True,
        choices=("udp", "uart", "lora"),
    )

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

    ready_deadline = time.time() + 90.0

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

    command = (
        "INVISCOMM_START,"
        + session_id
        + ","
        + str(args.start_delay_ms)
    )

    if args.transport == "udp":
        send_udp_start(
            args.broadcast,
            args.control_port,
            command.encode("utf-8"),
        )
    else:
        for reader in readers:
            reader.send_line(command)

    print("START enviado:", session_id)
    print(
        "Capturando durante",
        args.duration,
        "segundos",
    )

    experiment_start = time.time()
    deadline = (
        experiment_start
        + args.duration
        + args.start_delay_ms / 1000.0
    )

    rows: list[dict[str, object]] = []
    tracebacks = 0
    runtime_errors = 0

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

            if "Traceback" in line:
                tracebacks += 1

            if ",ERROR," in line:
                runtime_errors += 1

            if not line.startswith("TEL,"):
                continue

            try:
                record = parse_telemetry_line(
                    line,
                    port=source.port,
                    host_timestamp=timestamp,
                    experiment_start=experiment_start,
                    transport=args.transport,
                )
            except TelemetryParseError:
                continue

            row = record.to_row()

            writer.writerow(row)
            extended_file.flush()

            rows.append(row)

            if len(rows) % 20 == 0:
                print("Registros:", len(rows))

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
    print("Transporte:", args.transport)
    print("Registros:", len(rows))
    print("Direcciones:", sorted(directions))
    print("Tramas Info:", info_count)
    print("Errores runtime:", runtime_errors)
    print("Tracebacks:", tracebacks)
    print("CSV:", compatible_path)

    capture_ok = (
        len(rows) > 0
        and directions == {"A-->B", "B-->A"}
        and info_count > 0
    )

    session_ok = (
        capture_ok
        and runtime_errors == 0
        and tracebacks == 0
    )

    print(
        "CAPTURA:",
        "PASS" if capture_ok else "FAIL",
    )

    print(
        "SESIÓN:",
        "PASS" if session_ok else "FAIL",
    )

    if capture_ok:
        return 0

    return 2


if __name__ == "__main__":
    raise SystemExit(main())
PY

chmod +x "${HOST_DIR}/run_experiment.py"

###############################################################################
# Despliegue por transporte
###############################################################################

cat > "${SCRIPTS_DIR}/deploy_transport.sh" <<'BASH_DEPLOY'
#!/usr/bin/env bash

set -u

PROJECT_ROOT="/home/jfcrypt/Documents/Proyectos/InvisComm"
MICROPYTHON_DIR="${PROJECT_ROOT}/micropython"
COMMON_DIR="${MICROPYTHON_DIR}/common"
TRANSPORTS_DIR="${COMMON_DIR}/transports"
CONFIGS_DIR="${MICROPYTHON_DIR}/configs"

PORT_A="/dev/ttyUSB0"
PORT_B="/dev/ttyUSB1"

TRANSPORT="${1:-}"

if [ -z "${TRANSPORT}" ]; then
    echo "Uso:"
    echo "bash scripts/deploy_transport.sh udp"
    echo "bash scripts/deploy_transport.sh uart"
    echo "bash scripts/deploy_transport.sh lora"
    return 1 2>/dev/null || true
fi

case "${TRANSPORT}" in
    udp|uart|lora)
        ;;
    *)
        echo "ERROR: transporte inválido"
        return 1 2>/dev/null || true
        ;;
esac

cd "${PROJECT_ROOT}" || {
    echo "ERROR: no se pudo abrir el proyecto"
    return 1 2>/dev/null || true
}

source .venv-micropython/bin/activate

deploy_node() {
    local port="$1"
    local node_role="$2"
    local status=0

    echo
    echo "========================================"
    echo "DESPLIEGUE ${node_role} / ${TRANSPORT}"
    echo "========================================"

    mpremote connect "${port}" exec \
'import os
for path in ("common", "common/transports"):
    try:
        os.mkdir(path)
    except OSError:
        pass' || status=1

    for file in \
        "${COMMON_DIR}/__init__.py" \
        "${COMMON_DIR}/app_config.py" \
        "${COMMON_DIR}/app_bootstrap.py" \
        "${COMMON_DIR}/deterministic_prng.py" \
        "${COMMON_DIR}/experiment_defaults.py" \
        "${COMMON_DIR}/frame.py" \
        "${COMMON_DIR}/inviscomm_engine.py" \
        "${COMMON_DIR}/node_runtime.py" \
        "${COMMON_DIR}/session_control.py" \
        "${COMMON_DIR}/telemetry.py" \
        "${COMMON_DIR}/usb_session_control.py" \
        "${COMMON_DIR}/wifi_manager.py"
    do
        mpremote connect "${port}" fs cp \
            "${file}" \
            ":common/$(basename "${file}")" \
            || status=1
    done

    for file in \
        "${TRANSPORTS_DIR}/__init__.py" \
        "${TRANSPORTS_DIR}/base.py" \
        "${TRANSPORTS_DIR}/factory.py" \
        "${TRANSPORTS_DIR}/uart_transport.py" \
        "${TRANSPORTS_DIR}/udp_transport.py" \
        "${TRANSPORTS_DIR}/sx127x.py" \
        "${TRANSPORTS_DIR}/lora_transport.py"
    do
        mpremote connect "${port}" fs cp \
            "${file}" \
            ":common/transports/$(basename "${file}")" \
            || status=1
    done

    mpremote connect "${port}" fs cp \
        "${CONFIGS_DIR}/${TRANSPORT}/${node_role}/node_config.py" \
        :node_config.py \
        || status=1

    mpremote connect "${port}" fs cp \
        "${MICROPYTHON_DIR}/main.py" \
        :main.py \
        || status=1

    if [ "${TRANSPORT}" = "udp" ]; then
        if [ ! -f "${MICROPYTHON_DIR}/secrets/wifi_secrets.py" ]; then
            echo "ERROR: falta wifi_secrets.py"
            status=1
        else
            mpremote connect "${port}" fs cp \
                "${MICROPYTHON_DIR}/secrets/wifi_secrets.py" \
                :wifi_secrets.py \
                || status=1
        fi
    fi

    if [ "${status}" -eq 0 ]; then
        echo "PASS: ${node_role}"
    else
        echo "FAIL: ${node_role}"
    fi

    return "${status}"
}

STATUS_A=0
STATUS_B=0

deploy_node "${PORT_A}" alice || STATUS_A=1
deploy_node "${PORT_B}" bob || STATUS_B=1

mpremote connect "${PORT_A}" reset || STATUS_A=1
sleep 1
mpremote connect "${PORT_B}" reset || STATUS_B=1

echo
echo "========================================"
echo "RESUMEN"
echo "========================================"
echo "Transporte: ${TRANSPORT}"
echo "Alice: ${STATUS_A}"
echo "Bob: ${STATUS_B}"

if [ "${STATUS_A}" -eq 0 ] \
    && [ "${STATUS_B}" -eq 0 ]; then
    echo "RESULTADO GENERAL: PASS"
else
    echo "RESULTADO GENERAL: FAIL"
fi

echo
echo "Los nodos quedaron esperando START."
echo "La terminal permanece abierta."
BASH_DEPLOY

chmod +x "${SCRIPTS_DIR}/deploy_transport.sh"

###############################################################################
# Ejecución genérica
###############################################################################

cat > "${SCRIPTS_DIR}/run_experiment.sh" <<'BASH_RUN'
#!/usr/bin/env bash

set -u

PROJECT_ROOT="/home/jfcrypt/Documents/Proyectos/InvisComm"

TRANSPORT="${1:-}"
DURATION="${2:-60}"

if [ -z "${TRANSPORT}" ]; then
    echo "Uso:"
    echo "bash scripts/run_experiment.sh udp 60"
    echo "bash scripts/run_experiment.sh uart 60"
    echo "bash scripts/run_experiment.sh lora 120"
    return 1 2>/dev/null || true
fi

cd "${PROJECT_ROOT}" || {
    echo "ERROR: no se pudo abrir el proyecto"
    return 1 2>/dev/null || true
}

source .venv-micropython/bin/activate

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
OUTPUT_DIR="telemetry/${TRANSPORT}_${TIMESTAMP}"

COMMAND=(
    python -u host/run_experiment.py
    --transport "${TRANSPORT}"
    --duration "${DURATION}"
    --output-dir "${OUTPUT_DIR}"
)

if [ "${TRANSPORT}" = "udp" ]; then
    COMMAND+=(
        --broadcast 192.168.100.255
    )
fi

"${COMMAND[@]}" \
    2>&1 | tee /home/jfcrypt/Downloads/salida.txt

echo
echo "Directorio del experimento:"
echo "${PROJECT_ROOT}/${OUTPUT_DIR}"
echo
echo "La terminal permanece abierta."
BASH_RUN

chmod +x "${SCRIPTS_DIR}/run_experiment.sh"

###############################################################################
# Preparación del CSV para la notebook
###############################################################################

cat > "${HOST_DIR}/prepare_analysis.py" <<'PY'
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
PY

chmod +x "${HOST_DIR}/prepare_analysis.py"

###############################################################################
# Validación sintáctica integral
###############################################################################

STATUS=0

echo
echo "========================================"
echo "VALIDACIÓN SINTÁCTICA INTEGRAL"
echo "========================================"

python -m py_compile \
    "${COMMON_DIR}/app_bootstrap.py" \
    "${COMMON_DIR}/experiment_defaults.py" \
    "${COMMON_DIR}/node_runtime.py" \
    "${COMMON_DIR}/usb_session_control.py" \
    "${MICROPYTHON_DIR}/main.py" \
    "${CONFIGS_DIR}/udp/alice/node_config.py" \
    "${CONFIGS_DIR}/udp/bob/node_config.py" \
    "${CONFIGS_DIR}/uart/alice/node_config.py" \
    "${CONFIGS_DIR}/uart/bob/node_config.py" \
    "${CONFIGS_DIR}/lora/alice/node_config.py" \
    "${CONFIGS_DIR}/lora/bob/node_config.py" \
    "${HOST_DIR}/run_experiment.py" \
    "${HOST_DIR}/prepare_analysis.py" \
    || STATUS=1

echo
echo "========================================"
echo "ARCHIVOS PRINCIPALES"
echo "========================================"

find \
    "${CONFIGS_DIR}" \
    "${HOST_DIR}" \
    "${SCRIPTS_DIR}" \
    -maxdepth 4 \
    -type f \
    | sort

echo
echo "========================================"
echo "RESUMEN FINAL"
echo "========================================"
echo "Sintaxis: ${STATUS}"

if [ "${STATUS}" -eq 0 ]; then
    echo "RESULTADO GENERAL: PASS"
else
    echo "RESULTADO GENERAL: FAIL"
fi

echo
echo "Código completo generado."
echo "No se activó ningún transporte físico."
echo "La terminal permanece abierta."
