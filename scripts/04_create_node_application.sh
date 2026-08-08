#!/usr/bin/env bash

set -u

PROJECT_ROOT="/home/jfcrypt/Documents/Proyectos/InvisComm"
MICROPYTHON_DIR="${PROJECT_ROOT}/micropython"
COMMON_DIR="${MICROPYTHON_DIR}/common"
TRANSPORTS_DIR="${COMMON_DIR}/transports"
TESTS_DIR="${MICROPYTHON_DIR}/tests"
NODE_A_DIR="${MICROPYTHON_DIR}/node_a"
NODE_B_DIR="${MICROPYTHON_DIR}/node_b"

ESP32_A_PORT="/dev/ttyUSB0"
ESP32_B_PORT="/dev/ttyUSB1"

cd "${PROJECT_ROOT}" || {
    echo "ERROR: no se pudo entrar a ${PROJECT_ROOT}"
    return 1 2>/dev/null || true
}

mkdir -p \
    "${COMMON_DIR}" \
    "${TRANSPORTS_DIR}" \
    "${TESTS_DIR}" \
    "${NODE_A_DIR}" \
    "${NODE_B_DIR}"

touch "${COMMON_DIR}/__init__.py"
touch "${TRANSPORTS_DIR}/__init__.py"
touch "${NODE_A_DIR}/__init__.py"
touch "${NODE_B_DIR}/__init__.py"

###############################################################################
# Configuración común
###############################################################################

cat > "${COMMON_DIR}/app_config.py" <<'PY'
ALPHABET = (
    "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    "abcdefghijklmnopqrstuvwxyz"
    "0123456789"
    " "
    ".,;:!?()-_@*+=/"
)

KEP_SHARED_KEY = 202603

TX_INTERVAL_MS = 300
RX_POLL_INTERVAL_MS = 10

NODE_A_ID = 1
NODE_B_ID = 2

NODE_A_NAME = "Alice"
NODE_B_NAME = "Bob"

DIRECTION_A_TO_B = "A-->B"
DIRECTION_B_TO_A = "B-->A"
PY

###############################################################################
# Transporte dúplex de prueba
###############################################################################

cat > "${TRANSPORTS_DIR}/duplex_memory_transport.py" <<'PY'
from common.transports.base import Transport


class _MemoryEndpoint(Transport):
    def __init__(self, incoming_queue, outgoing_queue, endpoint_name):
        self._incoming_queue = incoming_queue
        self._outgoing_queue = outgoing_queue
        self._endpoint_name = endpoint_name
        self._sent_packets = 0
        self._received_packets = 0
        self._closed = False

    def send(self, payload):
        if self._closed:
            raise RuntimeError("El endpoint está cerrado")

        if not isinstance(payload, (bytes, bytearray)):
            raise TypeError("El payload debe ser bytes")

        self._outgoing_queue.append(bytes(payload))
        self._sent_packets += 1
        return True

    def receive(self):
        if self._closed or not self._incoming_queue:
            return None

        self._received_packets += 1
        return self._incoming_queue.pop(0)

    def close(self):
        self._closed = True

    def metadata(self):
        return {
            "endpoint": self._endpoint_name,
            "sent_packets": self._sent_packets,
            "received_packets": self._received_packets,
            "queued_packets": len(self._incoming_queue),
        }


def create_duplex_memory_link():
    """
    Crea dos extremos conectados:

        endpoint_a.send() -> endpoint_b.receive()
        endpoint_b.send() -> endpoint_a.receive()
    """
    queue_a_to_b = []
    queue_b_to_a = []

    endpoint_a = _MemoryEndpoint(
        incoming_queue=queue_b_to_a,
        outgoing_queue=queue_a_to_b,
        endpoint_name="memory-A",
    )

    endpoint_b = _MemoryEndpoint(
        incoming_queue=queue_a_to_b,
        outgoing_queue=queue_b_to_a,
        endpoint_name="memory-B",
    )

    return endpoint_a, endpoint_b
PY

###############################################################################
# Runtime completo del nodo
###############################################################################

cat > "${COMMON_DIR}/node_runtime.py" <<'PY'
import gc
import time

from common.deterministic_prng import DeterministicPRNG
from common.frame import (
    NODE_A,
    NODE_B,
    FrameError,
    decode_frame,
    encode_frame,
)
from common.inviscomm_engine import InvisCommEngine
from common.telemetry import (
    DIRECTION_A_TO_B,
    DIRECTION_B_TO_A,
    TYPE_INFO,
    TYPE_NOISE,
    Telemetry,
)


class NodeRuntimeError(Exception):
    pass


class InvisCommNodeRuntime:
    """
    Runtime de un nodo InvisComm.

    Cada nodo mantiene:
      - un motor TX;
      - un motor RX;
      - posición TX independiente;
      - posición RX independiente;
      - cola de caracteres para transmitir;
      - buffer histórico de todos los caracteres recibidos.

    El receptor decodifica ciegamente tanto información como ruido,
    igual que la implementación Python de referencia.
    """

    def __init__(
        self,
        name,
        node_id,
        peer_id,
        shared_key,
        alphabet,
        transport,
        tx_interval_ms=300,
        telemetry_enabled=True,
        strict_position=True,
    ):
        if node_id not in (NODE_A, NODE_B):
            raise ValueError("node_id inválido")

        if peer_id not in (NODE_A, NODE_B):
            raise ValueError("peer_id inválido")

        if node_id == peer_id:
            raise ValueError("node_id y peer_id no pueden coincidir")

        self.name = name
        self.node_id = node_id
        self.peer_id = peer_id
        self.shared_key = shared_key
        self.alphabet = alphabet
        self.transport = transport
        self.tx_interval_ms = tx_interval_ms
        self.telemetry_enabled = telemetry_enabled
        self.strict_position = strict_position

        self.tx_engine = InvisCommEngine(
            shared_key,
            alphabet,
        )

        self.rx_engine = InvisCommEngine(
            shared_key,
            alphabet,
        )

        self.position_tx = 0
        self.position_rx = 0

        self._message_queue = []
        self.received_chars = []

        self._noise_prng = DeterministicPRNG(
            "{}:{}:noise".format(
                shared_key,
                node_id,
            )
        )

        self._last_tx_ms = time.ticks_ms()
        self._running = False

        self.telemetry = Telemetry(name)

        self.stats = {
            "tx_total": 0,
            "tx_info": 0,
            "tx_noise": 0,
            "rx_total": 0,
            "rx_valid": 0,
            "rx_invalid": 0,
            "rx_duplicates": 0,
            "rx_out_of_order": 0,
            "rx_missing": 0,
            "decode_errors": 0,
        }

    def _tx_direction(self):
        if self.node_id == NODE_A:
            return DIRECTION_A_TO_B

        return DIRECTION_B_TO_A

    def load_message(self, message):
        if not isinstance(message, str):
            raise TypeError("El mensaje debe ser str")

        for character in message:
            if character not in self.alphabet:
                raise ValueError(
                    "Caracter no soportado: {!r}".format(
                        character
                    )
                )

        self._message_queue.extend(message)

    def pending_message_characters(self):
        return len(self._message_queue)

    def _next_transmit_character(self):
        if self._message_queue:
            character = self._message_queue.pop(0)
            return character, TYPE_INFO

        index = self._noise_prng.randbelow(
            len(self.alphabet)
        )

        return self.alphabet[index], TYPE_NOISE

    def transmit_once(self):
        """
        Genera y transmite exactamente una coordenada.
        """
        character, frame_type = (
            self._next_transmit_character()
        )

        encode_start_us = time.ticks_us()

        coordinate = self.tx_engine.encode_symbol(
            character,
            self.position_tx,
        )

        encode_time_us = time.ticks_diff(
            time.ticks_us(),
            encode_start_us,
        )

        frame = encode_frame(
            sender=self.node_id,
            position=self.position_tx,
            coordinate=coordinate,
        )

        send_start_us = time.ticks_us()
        result = self.transport.send(frame)
        send_time_us = time.ticks_diff(
            time.ticks_us(),
            send_start_us,
        )

        if not result:
            raise NodeRuntimeError(
                "El transporte no confirmó el envío"
            )

        self.stats["tx_total"] += 1

        if frame_type == TYPE_INFO:
            self.stats["tx_info"] += 1
        else:
            self.stats["tx_noise"] += 1

        if self.telemetry_enabled:
            self.telemetry.emit(
                self._tx_direction(),
                coordinate,
                frame_type,
            )

            print(
                "PERF,{},{},{},{},{},{}".format(
                    self.name,
                    self.transport.name(),
                    self.position_tx,
                    encode_time_us,
                    send_time_us,
                    gc.mem_free(),
                )
            )

        transmitted = {
            "position": self.position_tx,
            "character": character,
            "coordinate": coordinate,
            "type": frame_type,
            "frame": frame,
            "encode_time_us": encode_time_us,
            "send_time_us": send_time_us,
        }

        self.position_tx += 1
        self._last_tx_ms = time.ticks_ms()

        return transmitted

    def transmit_if_due(self):
        elapsed_ms = time.ticks_diff(
            time.ticks_ms(),
            self._last_tx_ms,
        )

        if elapsed_ms < self.tx_interval_ms:
            return None

        return self.transmit_once()

    def _validate_position(self, received_position):
        expected = self.position_rx

        if received_position == expected:
            return True

        if received_position < expected:
            self.stats["rx_duplicates"] += 1

            if self.strict_position:
                raise NodeRuntimeError(
                    "Trama duplicada o antigua: "
                    "recibida={}, esperada={}".format(
                        received_position,
                        expected,
                    )
                )

            return False

        missing = received_position - expected

        self.stats["rx_missing"] += missing
        self.stats["rx_out_of_order"] += 1

        raise NodeRuntimeError(
            "Pérdida o desorden: "
            "recibida={}, esperada={}, faltantes={}".format(
                received_position,
                expected,
                missing,
            )
        )

    def receive_once(self):
        """
        Procesa como máximo una trama.

        Retorna:
            dict: si procesó una trama;
            None: si no había datos.
        """
        raw_frame = self.transport.receive()

        if raw_frame is None:
            return None

        self.stats["rx_total"] += 1

        try:
            decoded_frame = decode_frame(raw_frame)
        except FrameError as error:
            self.stats["rx_invalid"] += 1
            raise NodeRuntimeError(
                "Trama física inválida: {}".format(error)
            )

        if decoded_frame["sender"] != self.peer_id:
            self.stats["rx_invalid"] += 1
            raise NodeRuntimeError(
                "Emisor inesperado: {}".format(
                    decoded_frame["sender"]
                )
            )

        received_position = decoded_frame["position"]

        if not self._validate_position(
            received_position
        ):
            return None

        decode_start_us = time.ticks_us()

        try:
            character = self.rx_engine.decode_coordinate(
                decoded_frame["coordinate"],
                self.position_rx,
            )
        except Exception as error:
            self.stats["decode_errors"] += 1
            raise NodeRuntimeError(
                "No se pudo decodificar posición {}: {}".format(
                    self.position_rx,
                    error,
                )
            )

        decode_time_us = time.ticks_diff(
            time.ticks_us(),
            decode_start_us,
        )

        self.received_chars.append(character)
        self.position_rx += 1

        self.stats["rx_valid"] += 1

        return {
            "position": received_position,
            "coordinate": decoded_frame["coordinate"],
            "character": character,
            "decode_time_us": decode_time_us,
            "transport_metadata": self.transport.metadata(),
        }

    def drain_receive(self, maximum_packets=32):
        processed = []

        for _ in range(maximum_packets):
            item = self.receive_once()

            if item is None:
                break

            processed.append(item)

        return processed

    def received_text(self, start=0, length=None):
        if length is None:
            return "".join(
                self.received_chars[start:]
            )

        end = start + length

        return "".join(
            self.received_chars[start:end]
        )

    def run_forever(self):
        self._running = True

        print(
            "LOG,{},{},Runtime iniciado con transporte {}".format(
                self.name,
                "INFO",
                self.transport.name(),
            )
        )

        while self._running:
            try:
                self.transmit_if_due()
                self.drain_receive()
                time.sleep_ms(10)
            except Exception as error:
                print(
                    "LOG,{},{},{}".format(
                        self.name,
                        "ERROR",
                        error,
                    )
                )

                self._running = False
                raise

    def stop(self):
        self._running = False

        try:
            self.transport.close()
        except Exception:
            pass

    def state_snapshot(self):
        return {
            "name": self.name,
            "node_id": self.node_id,
            "peer_id": self.peer_id,
            "position_tx": self.position_tx,
            "position_rx": self.position_rx,
            "pending_message_characters": len(
                self._message_queue
            ),
            "received_characters": len(
                self.received_chars
            ),
            "tx_engine": self.tx_engine.state_snapshot(),
            "rx_engine": self.rx_engine.state_snapshot(),
            "stats": dict(self.stats),
        }
PY

###############################################################################
# Configuración Alice
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
    "node_id": NODE_A_ID,
    "peer_id": NODE_B_ID,
    "shared_key": KEP_SHARED_KEY,
    "alphabet": ALPHABET,
    "tx_interval_ms": TX_INTERVAL_MS,

    # Cambiar a "uart", "udp" o "lora" al ejecutar
    # cada experimento físico.
    "transport": "loopback",

    "uart_id": 2,
    "uart_baudrate": 115200,
    "uart_tx_pin": 17,
    "uart_rx_pin": 16,

    "local_ip": "0.0.0.0",
    "local_port": 42001,
    "remote_ip": "192.168.1.102",
    "remote_port": 42002,

    "lora_spi_id": 2,
    "lora_sck_pin": 18,
    "lora_mosi_pin": 23,
    "lora_miso_pin": 19,
    "lora_cs_pin": 5,
    "lora_reset_pin": 14,
    "lora_dio0_pin": 26,

    # Confirmar la frecuencia impresa en los Ra-02.
    "lora_frequency": 433000000,
    "lora_tx_power": 10,
    "lora_spreading_factor": 7,
    "lora_bandwidth": 125000,
    "lora_coding_rate": 5,
    "lora_preamble_length": 8,
    "lora_sync_word": 0x42,
}
PY

###############################################################################
# Configuración Bob
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
    "node_id": NODE_B_ID,
    "peer_id": NODE_A_ID,
    "shared_key": KEP_SHARED_KEY,
    "alphabet": ALPHABET,
    "tx_interval_ms": TX_INTERVAL_MS,

    "transport": "loopback",

    "uart_id": 2,
    "uart_baudrate": 115200,
    "uart_tx_pin": 17,
    "uart_rx_pin": 16,

    "local_ip": "0.0.0.0",
    "local_port": 42002,
    "remote_ip": "192.168.1.101",
    "remote_port": 42001,

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
}
PY

###############################################################################
# main.py común para cada nodo
###############################################################################

cat > "${NODE_A_DIR}/main.py" <<'PY'
from common.node_runtime import InvisCommNodeRuntime
from common.transports.factory import create_transport
from node_config import CONFIG


transport = create_transport(CONFIG)

node = InvisCommNodeRuntime(
    name=CONFIG["name"],
    node_id=CONFIG["node_id"],
    peer_id=CONFIG["peer_id"],
    shared_key=CONFIG["shared_key"],
    alphabet=CONFIG["alphabet"],
    transport=transport,
    tx_interval_ms=CONFIG["tx_interval_ms"],
)

print("InvisComm MicroPython")
print("Nodo:", CONFIG["name"])
print("Transporte:", CONFIG["transport"])

node.run_forever()
PY

cp "${NODE_A_DIR}/main.py" "${NODE_B_DIR}/main.py"

###############################################################################
# Prueba integral de Alice y Bob
###############################################################################

cat > "${TESTS_DIR}/test_bidirectional_nodes.py" <<'PY'
import gc

from common.app_config import (
    ALPHABET,
    KEP_SHARED_KEY,
    NODE_A_ID,
    NODE_A_NAME,
    NODE_B_ID,
    NODE_B_NAME,
)
from common.node_runtime import InvisCommNodeRuntime
from common.transports.duplex_memory_transport import (
    create_duplex_memory_link,
)


MESSAGE_A_TO_B = "Attack from the northern front"
MESSAGE_B_TO_A = "Received. The attack will begin at 12:00"

NOISE_BEFORE = 8
NOISE_BETWEEN = 6
NOISE_AFTER = 8


def assert_equal(actual, expected, description):
    if actual != expected:
        raise AssertionError(
            "{}: actual={!r}, esperado={!r}".format(
                description,
                actual,
                expected,
            )
        )


def exchange_once(alice, bob):
    alice.transmit_once()
    bob.transmit_once()

    bob_packets = bob.drain_receive()
    alice_packets = alice.drain_receive()

    assert_equal(
        len(bob_packets),
        1,
        "Bob debía recibir una trama",
    )

    assert_equal(
        len(alice_packets),
        1,
        "Alice debía recibir una trama",
    )


print()
print("================================================")
print("InvisComm ESP32 - prueba bidireccional completa")
print("================================================")
print("Memoria libre inicial:", gc.mem_free(), "bytes")

transport_a, transport_b = create_duplex_memory_link()

alice = InvisCommNodeRuntime(
    name=NODE_A_NAME,
    node_id=NODE_A_ID,
    peer_id=NODE_B_ID,
    shared_key=KEP_SHARED_KEY,
    alphabet=ALPHABET,
    transport=transport_a,
    telemetry_enabled=False,
)

bob = InvisCommNodeRuntime(
    name=NODE_B_NAME,
    node_id=NODE_B_ID,
    peer_id=NODE_A_ID,
    shared_key=KEP_SHARED_KEY,
    alphabet=ALPHABET,
    transport=transport_b,
    telemetry_enabled=False,
)

# Tráfico inicial de ruido.
for _ in range(NOISE_BEFORE):
    exchange_once(alice, bob)

bob_start_index = len(bob.received_chars)
alice.load_message(MESSAGE_A_TO_B)

for _ in range(len(MESSAGE_A_TO_B)):
    exchange_once(alice, bob)

recovered_by_bob = bob.received_text(
    bob_start_index,
    len(MESSAGE_A_TO_B),
)

# Standby con ruido.
for _ in range(NOISE_BETWEEN):
    exchange_once(alice, bob)

alice_start_index = len(alice.received_chars)
bob.load_message(MESSAGE_B_TO_A)

for _ in range(len(MESSAGE_B_TO_A)):
    exchange_once(alice, bob)

recovered_by_alice = alice.received_text(
    alice_start_index,
    len(MESSAGE_B_TO_A),
)

# Tráfico final de ruido.
for _ in range(NOISE_AFTER):
    exchange_once(alice, bob)

assert_equal(
    recovered_by_bob,
    MESSAGE_A_TO_B,
    "Mensaje recuperado por Bob",
)

assert_equal(
    recovered_by_alice,
    MESSAGE_B_TO_A,
    "Mensaje recuperado por Alice",
)

assert_equal(
    alice.position_tx,
    bob.position_rx,
    "Sincronización A TX / B RX",
)

assert_equal(
    bob.position_tx,
    alice.position_rx,
    "Sincronización B TX / A RX",
)

assert_equal(
    alice.tx_engine.state_snapshot(),
    bob.rx_engine.state_snapshot(),
    "Estado motor Alice TX / Bob RX",
)

assert_equal(
    bob.tx_engine.state_snapshot(),
    alice.rx_engine.state_snapshot(),
    "Estado motor Bob TX / Alice RX",
)

print("Alice envió:      ", MESSAGE_A_TO_B)
print("Bob recuperó:     ", recovered_by_bob)
print()
print("Bob envió:        ", MESSAGE_B_TO_A)
print("Alice recuperó:   ", recovered_by_alice)
print()
print("Posición A TX:", alice.position_tx)
print("Posición B RX:", bob.position_rx)
print("Posición B TX:", bob.position_tx)
print("Posición A RX:", alice.position_rx)
print()
print("Estadísticas Alice:", alice.stats)
print("Estadísticas Bob:  ", bob.stats)
print("Memoria libre final:", gc.mem_free(), "bytes")
print()
print("RESULTADO: PASS")
print("Comunicación bidireccional InvisComm validada.")
print("================================================")
PY

###############################################################################
# Validación sintáctica local
###############################################################################

echo
echo "================================================"
echo "VALIDACIÓN SINTÁCTICA LOCAL"
echo "================================================"

python -m py_compile \
    "${COMMON_DIR}/app_config.py" \
    "${COMMON_DIR}/node_runtime.py" \
    "${TRANSPORTS_DIR}/duplex_memory_transport.py" \
    "${NODE_A_DIR}/node_config.py" \
    "${NODE_A_DIR}/main.py" \
    "${NODE_B_DIR}/node_config.py" \
    "${NODE_B_DIR}/main.py" \
    "${TESTS_DIR}/test_bidirectional_nodes.py"

LOCAL_STATUS=$?

if [ "${LOCAL_STATUS}" -eq 0 ]; then
    echo "PASS: sintaxis local"
else
    echo "FAIL: sintaxis local"
fi

###############################################################################
# Despliegue y prueba por ESP32
###############################################################################

deploy_and_test() {
    local port="$1"
    local node_name="$2"
    local node_source_dir="$3"

    local status=0

    echo
    echo "================================================"
    echo "DESPLIEGUE EN ${node_name} (${port})"
    echo "================================================"

    mpremote connect "${port}" exec \
'import os
for path in ("common", "common/transports", "node"):
    try:
        os.mkdir(path)
    except OSError:
        pass
print("Directorios preparados")' || status=1

    for file in \
        "${COMMON_DIR}/__init__.py" \
        "${COMMON_DIR}/app_config.py" \
        "${COMMON_DIR}/deterministic_prng.py" \
        "${COMMON_DIR}/frame.py" \
        "${COMMON_DIR}/inviscomm_engine.py" \
        "${COMMON_DIR}/telemetry.py" \
        "${COMMON_DIR}/node_runtime.py"
    do
        mpremote connect "${port}" \
            fs cp "${file}" \
            ":common/$(basename "${file}")" || status=1
    done

    for file in \
        "${TRANSPORTS_DIR}/__init__.py" \
        "${TRANSPORTS_DIR}/base.py" \
        "${TRANSPORTS_DIR}/duplex_memory_transport.py" \
        "${TRANSPORTS_DIR}/factory.py" \
        "${TRANSPORTS_DIR}/loopback_transport.py" \
        "${TRANSPORTS_DIR}/uart_transport.py" \
        "${TRANSPORTS_DIR}/udp_transport.py" \
        "${TRANSPORTS_DIR}/sx127x.py" \
        "${TRANSPORTS_DIR}/lora_transport.py"
    do
        mpremote connect "${port}" \
            fs cp "${file}" \
            ":common/transports/$(basename "${file}")" || status=1
    done

    mpremote connect "${port}" \
        fs cp "${node_source_dir}/node_config.py" \
        :node/node_config.py || status=1

    mpremote connect "${port}" \
        fs cp "${node_source_dir}/main.py" \
        :node/main.py || status=1

    mpremote connect "${port}" \
        run "${TESTS_DIR}/test_bidirectional_nodes.py" || status=1

    if [ "${status}" -eq 0 ]; then
        echo "PASS: ${node_name}"
    else
        echo "FAIL: ${node_name}"
    fi

    return "${status}"
}

A_STATUS=0
B_STATUS=0

deploy_and_test \
    "${ESP32_A_PORT}" \
    "ESP32 A" \
    "${NODE_A_DIR}" || A_STATUS=1

deploy_and_test \
    "${ESP32_B_PORT}" \
    "ESP32 B" \
    "${NODE_B_DIR}" || B_STATUS=1

echo
echo "================================================"
echo "RESUMEN FINAL"
echo "================================================"
echo "Sintaxis local: ${LOCAL_STATUS}"
echo "ESP32 A: ${A_STATUS}"
echo "ESP32 B: ${B_STATUS}"

if [ "${LOCAL_STATUS}" -eq 0 ] \
    && [ "${A_STATUS}" -eq 0 ] \
    && [ "${B_STATUS}" -eq 0 ]; then
    echo "RESULTADO GENERAL: PASS"
else
    echo "RESULTADO GENERAL: FAIL"
fi

echo
echo "Los main.py definitivos quedaron en :node/main.py."
echo "No fueron instalados todavía como :main.py."
echo "La terminal permanece abierta."
