#!/usr/bin/env bash

set -u

PROJECT_ROOT="/home/jfcrypt/Documents/Proyectos/InvisComm"
MICROPYTHON_DIR="${PROJECT_ROOT}/micropython"
COMMON_DIR="${MICROPYTHON_DIR}/common"
TRANSPORTS_DIR="${COMMON_DIR}/transports"
NODE_A_DIR="${MICROPYTHON_DIR}/node_a"
NODE_B_DIR="${MICROPYTHON_DIR}/node_b"
SECRETS_DIR="${MICROPYTHON_DIR}/secrets"

ESP32_A_PORT="/dev/ttyUSB0"
ESP32_B_PORT="/dev/ttyUSB1"

OUTPUT_FILE="/home/jfcrypt/Downloads/salida.txt"

cd "${PROJECT_ROOT}" || {
    echo "ERROR: no se pudo abrir ${PROJECT_ROOT}"
    return 1 2>/dev/null || true
}

source .venv-micropython/bin/activate

mkdir -p \
    "${SECRETS_DIR}" \
    "${NODE_A_DIR}" \
    "${NODE_B_DIR}"

###############################################################################
# Credenciales Wi-Fi
###############################################################################

echo "========================================"
echo "CONFIGURACIÓN WI-FI"
echo "========================================"

read -r -p "SSID Wi-Fi: " WIFI_SSID
read -r -s -p "Contraseña Wi-Fi: " WIFI_PASSWORD
echo

if [ -z "${WIFI_SSID}" ]; then
    echo "ERROR: el SSID no puede estar vacío."
    return 1 2>/dev/null || true
fi

python - "${WIFI_SSID}" "${WIFI_PASSWORD}" "${SECRETS_DIR}/wifi_secrets.py" <<'PY'
import pathlib
import sys

ssid = sys.argv[1]
password = sys.argv[2]
output = pathlib.Path(sys.argv[3])

output.write_text(
    "WIFI_SSID = {!r}\n"
    "WIFI_PASSWORD = {!r}\n".format(
        ssid,
        password,
    ),
    encoding="utf-8",
)
PY

if ! grep -qxF "micropython/secrets/wifi_secrets.py" .gitignore 2>/dev/null; then
    printf '\n# Local Wi-Fi credentials\nmicropython/secrets/wifi_secrets.py\n' \
        >> .gitignore
fi

###############################################################################
# Transporte UDP con broadcast
###############################################################################

cat > "${TRANSPORTS_DIR}/udp_transport.py" <<'PY'
import socket

from common.frame import FRAME_SIZE
from common.transports.base import Transport, TransportError


class UDPTransport(Transport):
    """
    Transporte UDP no bloqueante.

    Soporta unicast y broadcast. Para el laboratorio se emplea
    255.255.255.255, evitando configurar manualmente las IP de los nodos.
    """

    def __init__(
        self,
        local_ip,
        local_port,
        remote_ip,
        remote_port,
    ):
        self._local_address = (
            local_ip,
            local_port,
        )

        self._remote_address = (
            remote_ip,
            remote_port,
        )

        self._socket = socket.socket(
            socket.AF_INET,
            socket.SOCK_DGRAM,
        )

        try:
            self._socket.setsockopt(
                socket.SOL_SOCKET,
                socket.SO_REUSEADDR,
                1,
            )
        except Exception:
            pass

        if remote_ip.endswith(".255") or remote_ip == "255.255.255.255":
            try:
                self._socket.setsockopt(
                    socket.SOL_SOCKET,
                    socket.SO_BROADCAST,
                    1,
                )
            except Exception:
                # Algunas compilaciones MicroPython permiten broadcast
                # sin exponer explícitamente SO_BROADCAST.
                pass

        self._socket.bind(self._local_address)
        self._socket.setblocking(False)

        self._last_remote_address = None
        self._sent_packets = 0
        self._received_packets = 0
        self._invalid_length_packets = 0

    def send(self, payload):
        if not isinstance(payload, (bytes, bytearray)):
            raise TypeError("El payload UDP debe ser bytes")

        if len(payload) != FRAME_SIZE:
            raise TransportError(
                "UDP esperaba {} bytes y recibió {}".format(
                    FRAME_SIZE,
                    len(payload),
                )
            )

        sent = self._socket.sendto(
            payload,
            self._remote_address,
        )

        if sent != len(payload):
            raise TransportError(
                "UDP envió {} de {} bytes".format(
                    sent,
                    len(payload),
                )
            )

        self._sent_packets += 1
        return True

    def receive(self):
        try:
            data, address = self._socket.recvfrom(256)
        except OSError:
            return None

        if len(data) != FRAME_SIZE:
            self._invalid_length_packets += 1
            return None

        self._last_remote_address = address
        self._received_packets += 1
        return bytes(data)

    def close(self):
        try:
            self._socket.close()
        except Exception:
            pass

    def metadata(self):
        return {
            "local_address": self._local_address,
            "remote_address": self._remote_address,
            "last_remote_address": self._last_remote_address,
            "sent_packets": self._sent_packets,
            "received_packets": self._received_packets,
            "invalid_length_packets": self._invalid_length_packets,
        }
PY

###############################################################################
# Bootstrap de aplicación
###############################################################################

cat > "${COMMON_DIR}/app_bootstrap.py" <<'PY'
import gc
import time

from common.node_runtime import InvisCommNodeRuntime
from common.transports.factory import create_transport
from common.wifi_manager import connect_wifi


def start_node(config, wifi_ssid, wifi_password):
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

    delay_ms = config.get(
        "startup_delay_ms",
        15000,
    )

    print(
        "Esperando {} ms para sincronizar nodos...".format(
            delay_ms
        )
    )

    time.sleep_ms(delay_ms)

    print("START,", config["name"])
    node.run_forever()
PY

###############################################################################
# Añadir salida RX al runtime
###############################################################################

python - "${COMMON_DIR}/node_runtime.py" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")

needle = '''        self.stats["rx_valid"] += 1

        return {
'''

replacement = '''        self.stats["rx_valid"] += 1

        print(
            "RX,{},{},{},{},{}".format(
                self.name,
                received_position,
                decoded_frame["coordinate"],
                repr(character),
                decode_time_us,
            )
        )

        return {
'''

if needle not in text:
    if '"RX,{},{},{},{},{}"' not in text:
        raise SystemExit(
            "ERROR: no se encontró el punto de inserción RX"
        )
else:
    text = text.replace(
        needle,
        replacement,
        1,
    )
    path.write_text(
        text,
        encoding="utf-8",
    )
PY

###############################################################################
# Configuración Alice UDP
###############################################################################

cat > "${NODE_A_DIR}/node_config.py" <<'PY'
from common.app_config import (
    ALPHABET,
    KEP_SHARED_KEY,
    NODE_A_ID,
    NODE_A_NAME,
    NODE_B_ID,
    TX_INTERVAL_MS,
)


CONFIG = {
    "name": NODE_A_NAME,
    "hostname": "inviscomm-alice",
    "node_id": NODE_A_ID,
    "peer_id": NODE_B_ID,
    "shared_key": KEP_SHARED_KEY,
    "alphabet": ALPHABET,
    "tx_interval_ms": TX_INTERVAL_MS,

    "transport": "udp",

    "local_ip": "0.0.0.0",
    "local_port": 42001,
    "remote_ip": "255.255.255.255",
    "remote_port": 42002,

    "startup_delay_ms": 15000,
    "startup_message": (
        "Attack from the northern front"
    ),
}
PY

###############################################################################
# Configuración Bob UDP
###############################################################################

cat > "${NODE_B_DIR}/node_config.py" <<'PY'
from common.app_config import (
    ALPHABET,
    KEP_SHARED_KEY,
    NODE_A_ID,
    NODE_B_ID,
    NODE_B_NAME,
    TX_INTERVAL_MS,
)


CONFIG = {
    "name": NODE_B_NAME,
    "hostname": "inviscomm-bob",
    "node_id": NODE_B_ID,
    "peer_id": NODE_A_ID,
    "shared_key": KEP_SHARED_KEY,
    "alphabet": ALPHABET,
    "tx_interval_ms": TX_INTERVAL_MS,

    "transport": "udp",

    "local_ip": "0.0.0.0",
    "local_port": 42002,
    "remote_ip": "255.255.255.255",
    "remote_port": 42001,

    "startup_delay_ms": 15000,
    "startup_message": (
        "Received. The attack will begin at 12:00"
    ),
}
PY

###############################################################################
# main.py de cada nodo
###############################################################################

cat > "${NODE_A_DIR}/main.py" <<'PY'
from common.app_bootstrap import start_node
from node_config import CONFIG
from wifi_secrets import WIFI_PASSWORD, WIFI_SSID


start_node(
    CONFIG,
    WIFI_SSID,
    WIFI_PASSWORD,
)
PY

cp "${NODE_A_DIR}/main.py" "${NODE_B_DIR}/main.py"

###############################################################################
# Validación local
###############################################################################

STATUS_SYNTAX=0
STATUS_A=0
STATUS_B=0

echo
echo "========================================"
echo "VALIDACIÓN SINTÁCTICA"
echo "========================================"

python -m py_compile \
    "${COMMON_DIR}/app_bootstrap.py" \
    "${COMMON_DIR}/node_runtime.py" \
    "${TRANSPORTS_DIR}/udp_transport.py" \
    "${NODE_A_DIR}/node_config.py" \
    "${NODE_A_DIR}/main.py" \
    "${NODE_B_DIR}/node_config.py" \
    "${NODE_B_DIR}/main.py" \
    "${SECRETS_DIR}/wifi_secrets.py" \
    || STATUS_SYNTAX=1

if [ "${STATUS_SYNTAX}" -eq 0 ]; then
    echo "PASS: sintaxis"
else
    echo "FAIL: sintaxis"
fi

###############################################################################
# Función de despliegue
###############################################################################

deploy_node() {
    local port="$1"
    local name="$2"
    local node_dir="$3"

    local status=0

    echo
    echo "========================================"
    echo "DESPLIEGUE ${name} (${port})"
    echo "========================================"

    mpremote connect "${port}" exec \
'import os
for path in ("common", "common/transports"):
    try:
        os.mkdir(path)
    except OSError:
        pass
print("Directorios preparados")' || status=1

    for file in \
        "${COMMON_DIR}/__init__.py" \
        "${COMMON_DIR}/app_config.py" \
        "${COMMON_DIR}/app_bootstrap.py" \
        "${COMMON_DIR}/deterministic_prng.py" \
        "${COMMON_DIR}/frame.py" \
        "${COMMON_DIR}/inviscomm_engine.py" \
        "${COMMON_DIR}/node_runtime.py" \
        "${COMMON_DIR}/telemetry.py" \
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
        "${TRANSPORTS_DIR}/udp_transport.py"
    do
        mpremote connect "${port}" fs cp \
            "${file}" \
            ":common/transports/$(basename "${file}")" \
            || status=1
    done

    mpremote connect "${port}" fs cp \
        "${node_dir}/node_config.py" \
        :node_config.py \
        || status=1

    mpremote connect "${port}" fs cp \
        "${SECRETS_DIR}/wifi_secrets.py" \
        :wifi_secrets.py \
        || status=1

    # main.py se copia al final, una vez preparado todo.
    mpremote connect "${port}" fs cp \
        "${node_dir}/main.py" \
        :main.py \
        || status=1

    if [ "${status}" -eq 0 ]; then
        echo "PASS: despliegue ${name}"
    else
        echo "FAIL: despliegue ${name}"
    fi

    return "${status}"
}

deploy_node \
    "${ESP32_A_PORT}" \
    "Alice" \
    "${NODE_A_DIR}" \
    || STATUS_A=1

deploy_node \
    "${ESP32_B_PORT}" \
    "Bob" \
    "${NODE_B_DIR}" \
    || STATUS_B=1

###############################################################################
# Reinicio de ambos nodos
###############################################################################

echo
echo "========================================"
echo "REINICIO DE NODOS"
echo "========================================"

mpremote connect "${ESP32_A_PORT}" reset || STATUS_A=1
sleep 1
mpremote connect "${ESP32_B_PORT}" reset || STATUS_B=1

echo "Ambos nodos fueron reiniciados."
echo "Disponen de 15 segundos antes de comenzar a transmitir."

###############################################################################
# Resumen
###############################################################################

echo
echo "========================================"
echo "RESUMEN FINAL"
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
echo "Próximo comando:"
echo "bash scripts/capture_experiment.sh udp 60"
echo
echo "La terminal permanece abierta."
