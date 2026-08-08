import gc

from common.transports.base import Transport
from common.transports.factory import create_transport
from common.transports.loopback_transport import LoopbackTransport
from common.transports.lora_transport import LoRaTransport
from common.transports.sx127x import SX127x
from common.transports.uart_transport import UARTTransport
from common.transports.udp_transport import UDPTransport


def assert_true(condition, description):
    if not condition:
        raise AssertionError(description)


print()
print("================================================")
print("InvisComm ESP32 - validación de transportes")
print("================================================")
print("Memoria libre inicial:", gc.mem_free(), "bytes")

assert_true(
    issubclass(UARTTransport, Transport),
    "UARTTransport no hereda de Transport",
)

assert_true(
    issubclass(UDPTransport, Transport),
    "UDPTransport no hereda de Transport",
)

assert_true(
    issubclass(LoRaTransport, Transport),
    "LoRaTransport no hereda de Transport",
)

loopback = create_transport({
    "transport": "loopback",
})

assert_true(
    isinstance(loopback, LoopbackTransport),
    "Factory no creó LoopbackTransport",
)

payload = b"TRANSPORT-OK"
loopback.send(payload)

assert_true(
    loopback.receive() == payload,
    "Loopback no recuperó el payload",
)

assert_true(
    loopback.receive() is None,
    "Loopback debía quedar vacío",
)

print("UARTTransport: importado")
print("UDPTransport: importado")
print("SX127x: importado")
print("LoRaTransport: importado")
print("Transport factory: validada")
print("Loopback: validado")
print("Memoria libre final:", gc.mem_free(), "bytes")
print()
print("RESULTADO: PASS")
print("Los módulos de transporte están listos.")
print("No se activó hardware UART ni LoRa.")
print("================================================")
