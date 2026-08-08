import gc

from common.frame import (
    FRAME_SIZE,
    FrameError,
    NODE_A,
    decode_frame,
    encode_frame,
)
from common.telemetry import (
    DIRECTION_A_TO_B,
    TYPE_INFO,
    Telemetry,
)
from common.transports.loopback_transport import LoopbackTransport


def assert_equal(actual, expected, description):
    if actual != expected:
        raise AssertionError(
            "{}: actual={!r}, esperado={!r}".format(
                description,
                actual,
                expected,
            )
        )


print()
print("================================================")
print("InvisComm ESP32 - prueba de trama y transporte")
print("================================================")
print("Memoria libre inicial:", gc.mem_free(), "bytes")

position = 123456
coordinate = 865

encoded = encode_frame(
    sender=NODE_A,
    position=position,
    coordinate=coordinate,
)

assert_equal(
    len(encoded),
    FRAME_SIZE,
    "Longitud de la trama",
)

transport = LoopbackTransport()
transport.send(encoded)

received_bytes = transport.receive()

if received_bytes is None:
    raise AssertionError("Loopback no devolvió la trama")

decoded = decode_frame(received_bytes)

assert_equal(
    decoded["sender"],
    NODE_A,
    "Nodo emisor",
)

assert_equal(
    decoded["position"],
    position,
    "Posición",
)

assert_equal(
    decoded["coordinate"],
    coordinate,
    "Coordenada",
)

# Comprobar detección de corrupción.
corrupted = bytearray(encoded)
corrupted[8] ^= 0x01

crc_detected = False

try:
    decode_frame(corrupted)
except FrameError:
    crc_detected = True

assert_equal(
    crc_detected,
    True,
    "Detección de corrupción mediante CRC",
)

telemetry = Telemetry("ESP32-A")

telemetry.emit(
    DIRECTION_A_TO_B,
    coordinate,
    TYPE_INFO,
)

print("Tamaño de trama:", FRAME_SIZE, "bytes")
print("Trama codificada:", encoded)
print("Trama decodificada:", decoded)
print("Corrupción detectada:", crc_detected)
print("Memoria libre final:", gc.mem_free(), "bytes")
print()
print("RESULTADO: PASS")
print("Trama, CRC, telemetría y transporte validados.")
print("================================================")
