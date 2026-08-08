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
