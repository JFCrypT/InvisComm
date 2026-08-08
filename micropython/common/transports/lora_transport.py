from machine import Pin, SPI

from common.frame import FRAME_SIZE
from common.transports.base import Transport, TransportError
from common.transports.sx127x import SX127x


class LoRaTransport(Transport):
    """
    Transporte para Ra-02/SX1278 mediante SPI.
    """

    def __init__(
        self,
        spi_id=2,
        sck_pin=18,
        mosi_pin=23,
        miso_pin=19,
        cs_pin=5,
        reset_pin=14,
        dio0_pin=26,
        frequency=433000000,
        tx_power=10,
        spreading_factor=7,
        bandwidth=125000,
        coding_rate=5,
        preamble_length=8,
        sync_word=0x42,
    ):
        self._spi = SPI(
            spi_id,
            baudrate=8000000,
            polarity=0,
            phase=0,
            sck=Pin(sck_pin),
            mosi=Pin(mosi_pin),
            miso=Pin(miso_pin),
        )

        self._radio = SX127x(
            spi=self._spi,
            cs_pin=cs_pin,
            reset_pin=reset_pin,
            dio0_pin=dio0_pin,
            frequency=frequency,
            tx_power=tx_power,
            spreading_factor=spreading_factor,
            bandwidth=bandwidth,
            coding_rate=coding_rate,
            preamble_length=preamble_length,
            sync_word=sync_word,
            crc=True,
        )

        self._sent_packets = 0
        self._received_packets = 0
        self._invalid_length_packets = 0

    def send(self, payload):
        if not isinstance(payload, (bytes, bytearray)):
            raise TypeError("El payload LoRa debe ser bytes")

        if len(payload) != FRAME_SIZE:
            raise TransportError(
                "LoRa esperaba {} bytes y recibió {}".format(
                    FRAME_SIZE,
                    len(payload),
                )
            )

        result = self._radio.send(payload)

        if result:
            self._sent_packets += 1

        return result

    def receive(self):
        payload = self._radio.receive()

        if payload is None:
            return None

        if len(payload) != FRAME_SIZE:
            self._invalid_length_packets += 1
            return None

        self._received_packets += 1
        return payload

    def close(self):
        try:
            self._radio.sleep()
        except Exception:
            pass

        try:
            self._spi.deinit()
        except Exception:
            pass

    def metadata(self):
        metadata = self._radio.metadata()
        metadata["sent_packets"] = self._sent_packets
        metadata["received_packets"] = self._received_packets
        metadata[
            "invalid_length_packets"
        ] = self._invalid_length_packets
        return metadata
