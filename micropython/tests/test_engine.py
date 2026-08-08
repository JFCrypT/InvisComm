import gc

from common.inviscomm_engine import InvisCommEngine


ALPHABET = (
    "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    "abcdefghijklmnopqrstuvwxyz"
    "0123456789"
    " "
    ".,;:!?()-_@*+=/"
)

SHARED_KEY = 202603
TEST_MESSAGE = "Attack from the northern front"


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
print("InvisComm ESP32 - prueba local del motor")
print("================================================")
print("Memoria libre inicial:", gc.mem_free(), "bytes")

tx_engine = InvisCommEngine(SHARED_KEY, ALPHABET)
rx_engine = InvisCommEngine(SHARED_KEY, ALPHABET)

decoded_characters = []
coordinates = []

for position, character in enumerate(TEST_MESSAGE):
    coordinate = tx_engine.encode_symbol(character, position)
    decoded = rx_engine.decode_coordinate(coordinate, position)

    coordinates.append(coordinate)
    decoded_characters.append(decoded)

    assert_equal(
        decoded,
        character,
        "Símbolo en posición {}".format(position),
    )

decoded_message = "".join(decoded_characters)

assert_equal(
    decoded_message,
    TEST_MESSAGE,
    "Mensaje completo",
)

assert_equal(
    tx_engine.state_snapshot(),
    rx_engine.state_snapshot(),
    "Estado TX/RX",
)

print("Mensaje original:   ", TEST_MESSAGE)
print("Mensaje recuperado: ", decoded_message)
print("Primeras coordenadas:", coordinates[:10])
print("Estado final:       ", tx_engine.state_snapshot())
print("Memoria libre final:", gc.mem_free(), "bytes")
print()
print("RESULTADO: PASS")
print("El motor TX y RX permaneció sincronizado.")
print("================================================")
