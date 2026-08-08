from machine import Pin, UART

from common.frame import FRAME_SIZE, MAGIC
from common.transports.base import Transport, TransportError


class UARTTransport(Transport):
    """
    Transporte UART dúplex para ESP32.

    Conexión:
        A TX GPIO17 -> B RX GPIO16
        A RX GPIO16 <- B TX GPIO17
        A GND        -  B GND
    """

    def __init__(
        self,
        uart_id=2,
        baudrate=115200,
        tx_pin=17,
        rx_pin=16,
        rx_buffer_size=512,
    ):
        self._uart = UART(
            uart_id,
            baudrate=baudrate,
            bits=8,
            parity=None,
            stop=1,
            tx=Pin(tx_pin),
            rx=Pin(rx_pin),
            timeout=0,
            timeout_char=0,
            rxbuf=rx_buffer_size,
        )

        self._rx_buffer = bytearray()
        self._sent_packets = 0
        self._received_packets = 0
        self._discarded_bytes = 0

    def send(self, payload):
        if not isinstance(payload, (bytes, bytearray)):
            raise TypeError("El payload UART debe ser bytes")

        if len(payload) != FRAME_SIZE:
            raise TransportError(
                "UART esperaba {} bytes y recibió {}".format(
                    FRAME_SIZE,
                    len(payload),
                )
            )

        written = self._uart.write(payload)

        if written != len(payload):
            raise TransportError(
                "UART escribió {} de {} bytes".format(
                    written,
                    len(payload),
                )
            )

        self._sent_packets += 1
        return True

    def _read_available(self):
        available = self._uart.any()

        if available:
            data = self._uart.read(available)

            if data:
                self._rx_buffer.extend(data)

    def _resynchronize(self):
        """
        Descarta bytes hasta encontrar MAGIC.
        """
        while self._rx_buffer and self._rx_buffer[0] != MAGIC:
            del self._rx_buffer[0]
            self._discarded_bytes += 1

    def receive(self):
        self._read_available()
        self._resynchronize()

        if len(self._rx_buffer) < FRAME_SIZE:
            return None

        packet = bytes(self._rx_buffer[:FRAME_SIZE])
        del self._rx_buffer[:FRAME_SIZE]

        self._received_packets += 1
        return packet

    def close(self):
        self._uart.deinit()
        self._rx_buffer = bytearray()

    def metadata(self):
        return {
            "sent_packets": self._sent_packets,
            "received_packets": self._received_packets,
            "discarded_bytes": self._discarded_bytes,
            "buffered_bytes": len(self._rx_buffer),
        }
