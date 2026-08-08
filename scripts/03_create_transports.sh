#!/usr/bin/env bash

set -u

PROJECT_ROOT="/home/jfcrypt/Documents/Proyectos/InvisComm"
TRANSPORTS_DIR="${PROJECT_ROOT}/micropython/common/transports"
COMMON_DIR="${PROJECT_ROOT}/micropython/common"
TESTS_DIR="${PROJECT_ROOT}/micropython/tests"

ESP32_A_PORT="/dev/ttyUSB0"
ESP32_B_PORT="/dev/ttyUSB1"

cd "${PROJECT_ROOT}" || {
    echo "ERROR: no se pudo entrar a ${PROJECT_ROOT}"
    return 1 2>/dev/null || true
}

mkdir -p \
    "${TRANSPORTS_DIR}" \
    "${TESTS_DIR}"

touch "${COMMON_DIR}/__init__.py"
touch "${TRANSPORTS_DIR}/__init__.py"

###############################################################################
# Base transport
###############################################################################

cat > "${TRANSPORTS_DIR}/base.py" <<'PY'
class TransportError(Exception):
    pass


class Transport:
    """
    Interfaz común para UART, UDP/IP y LoRa.
    """

    def send(self, payload):
        raise NotImplementedError

    def receive(self):
        """
        Retorna:
            bytes: cuando existe una trama completa;
            None: cuando no hay datos disponibles.
        """
        raise NotImplementedError

    def close(self):
        pass

    def name(self):
        return self.__class__.__name__

    def metadata(self):
        """
        Información adicional del último paquete recibido.

        Ejemplos:
            RSSI y SNR para LoRa;
            dirección IP para UDP.
        """
        return {}
PY

###############################################################################
# UART transport
###############################################################################

cat > "${TRANSPORTS_DIR}/uart_transport.py" <<'PY'
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
PY

###############################################################################
# UDP transport
###############################################################################

cat > "${TRANSPORTS_DIR}/udp_transport.py" <<'PY'
import socket

from common.frame import FRAME_SIZE
from common.transports.base import Transport, TransportError


class UDPTransport(Transport):
    """
    Transporte UDP no bloqueante.

    La conexión Wi-Fi se realiza por separado antes de construir
    esta instancia.
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

        self._socket.setsockopt(
            socket.SOL_SOCKET,
            socket.SO_REUSEADDR,
            1,
        )

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
# Wi-Fi helper
###############################################################################

cat > "${COMMON_DIR}/wifi_manager.py" <<'PY'
import time

import network


class WiFiError(Exception):
    pass


def connect_wifi(
    ssid,
    password,
    timeout_seconds=20,
    hostname=None,
):
    station = network.WLAN(network.STA_IF)

    if hostname:
        try:
            network.hostname(hostname)
        except Exception:
            pass

    station.active(True)

    if station.isconnected():
        return station

    station.connect(ssid, password)

    start_ms = time.ticks_ms()
    timeout_ms = timeout_seconds * 1000

    while not station.isconnected():
        elapsed = time.ticks_diff(
            time.ticks_ms(),
            start_ms,
        )

        if elapsed >= timeout_ms:
            station.disconnect()
            raise WiFiError(
                "No se pudo conectar a la red Wi-Fi"
            )

        time.sleep_ms(200)

    return station


def disconnect_wifi(station):
    if station is None:
        return

    try:
        station.disconnect()
    except Exception:
        pass

    try:
        station.active(False)
    except Exception:
        pass
PY

###############################################################################
# SX127x driver
###############################################################################

cat > "${TRANSPORTS_DIR}/sx127x.py" <<'PY'
import time

from machine import Pin


class SX127xError(Exception):
    pass


class SX127x:
    """
    Controlador mínimo para SX1276/SX1278/Ra-02 en modo LoRa.

    No implementa LoRaWAN.
    """

    REG_FIFO = 0x00
    REG_OP_MODE = 0x01
    REG_FRF_MSB = 0x06
    REG_FRF_MID = 0x07
    REG_FRF_LSB = 0x08
    REG_PA_CONFIG = 0x09
    REG_LNA = 0x0C
    REG_FIFO_ADDR_PTR = 0x0D
    REG_FIFO_TX_BASE_ADDR = 0x0E
    REG_FIFO_RX_BASE_ADDR = 0x0F
    REG_FIFO_RX_CURRENT_ADDR = 0x10
    REG_IRQ_FLAGS = 0x12
    REG_RX_NB_BYTES = 0x13
    REG_PKT_SNR_VALUE = 0x19
    REG_PKT_RSSI_VALUE = 0x1A
    REG_MODEM_CONFIG_1 = 0x1D
    REG_MODEM_CONFIG_2 = 0x1E
    REG_PREAMBLE_MSB = 0x20
    REG_PREAMBLE_LSB = 0x21
    REG_PAYLOAD_LENGTH = 0x22
    REG_MODEM_CONFIG_3 = 0x26
    REG_SYNC_WORD = 0x39
    REG_VERSION = 0x42
    REG_PA_DAC = 0x4D

    MODE_LONG_RANGE_MODE = 0x80
    MODE_SLEEP = 0x00
    MODE_STANDBY = 0x01
    MODE_TX = 0x03
    MODE_RX_CONTINUOUS = 0x05

    IRQ_RX_DONE_MASK = 0x40
    IRQ_PAYLOAD_CRC_ERROR_MASK = 0x20
    IRQ_TX_DONE_MASK = 0x08

    PA_BOOST = 0x80

    EXPECTED_VERSIONS = (
        0x12,
        0x22,
    )

    def __init__(
        self,
        spi,
        cs_pin,
        reset_pin,
        dio0_pin,
        frequency=433000000,
        tx_power=10,
        spreading_factor=7,
        bandwidth=125000,
        coding_rate=5,
        preamble_length=8,
        sync_word=0x42,
        crc=True,
    ):
        self._spi = spi
        self._cs = Pin(
            cs_pin,
            Pin.OUT,
            value=1,
        )

        self._reset = Pin(
            reset_pin,
            Pin.OUT,
            value=1,
        )

        self._dio0 = Pin(
            dio0_pin,
            Pin.IN,
        )

        self._frequency = frequency
        self._last_rssi = None
        self._last_snr = None
        self._last_crc_valid = None

        self._hardware_reset()

        version = self._read_register(
            self.REG_VERSION
        )

        if version not in self.EXPECTED_VERSIONS:
            raise SX127xError(
                "SX127x no detectado. REG_VERSION=0x{:02X}".format(
                    version
                )
            )

        self.sleep()
        self._write_register(
            self.REG_OP_MODE,
            self.MODE_LONG_RANGE_MODE | self.MODE_SLEEP,
        )

        time.sleep_ms(10)

        self.set_frequency(frequency)
        self.set_tx_power(tx_power)
        self.set_spreading_factor(spreading_factor)
        self.set_signal_bandwidth(bandwidth)
        self.set_coding_rate(coding_rate)
        self.set_preamble_length(preamble_length)
        self.set_sync_word(sync_word)
        self.set_crc(crc)

        self._write_register(
            self.REG_FIFO_TX_BASE_ADDR,
            0x00,
        )

        self._write_register(
            self.REG_FIFO_RX_BASE_ADDR,
            0x00,
        )

        lna = self._read_register(self.REG_LNA)
        self._write_register(
            self.REG_LNA,
            lna | 0x03,
        )

        self._write_register(
            self.REG_MODEM_CONFIG_3,
            0x04,
        )

        self.standby()
        self.receive_continuous()

    def _hardware_reset(self):
        self._reset.value(0)
        time.sleep_ms(10)
        self._reset.value(1)
        time.sleep_ms(10)

    def _select(self):
        self._cs.value(0)

    def _deselect(self):
        self._cs.value(1)

    def _read_register(self, address):
        self._select()

        try:
            self._spi.write(
                bytes((address & 0x7F,))
            )

            result = self._spi.read(1)
            return result[0]
        finally:
            self._deselect()

    def _write_register(self, address, value):
        self._select()

        try:
            self._spi.write(
                bytes((
                    address | 0x80,
                    value & 0xFF,
                ))
            )
        finally:
            self._deselect()

    def _write_fifo(self, payload):
        self._select()

        try:
            self._spi.write(
                bytes((self.REG_FIFO | 0x80,))
            )

            self._spi.write(payload)
        finally:
            self._deselect()

    def _read_fifo(self, length):
        self._select()

        try:
            self._spi.write(
                bytes((self.REG_FIFO & 0x7F,))
            )

            return self._spi.read(length)
        finally:
            self._deselect()

    def sleep(self):
        self._write_register(
            self.REG_OP_MODE,
            self.MODE_LONG_RANGE_MODE | self.MODE_SLEEP,
        )

    def standby(self):
        self._write_register(
            self.REG_OP_MODE,
            self.MODE_LONG_RANGE_MODE | self.MODE_STANDBY,
        )

    def receive_continuous(self):
        self._write_register(
            self.REG_OP_MODE,
            self.MODE_LONG_RANGE_MODE
            | self.MODE_RX_CONTINUOUS,
        )

    def set_frequency(self, frequency):
        self._frequency = frequency

        frf = int(
            (frequency << 19) / 32000000
        )

        self._write_register(
            self.REG_FRF_MSB,
            (frf >> 16) & 0xFF,
        )

        self._write_register(
            self.REG_FRF_MID,
            (frf >> 8) & 0xFF,
        )

        self._write_register(
            self.REG_FRF_LSB,
            frf & 0xFF,
        )

    def set_tx_power(self, level):
        if level < 2:
            level = 2

        if level > 20:
            level = 20

        if level > 17:
            self._write_register(
                self.REG_PA_DAC,
                0x87,
            )

            level -= 3
        else:
            self._write_register(
                self.REG_PA_DAC,
                0x84,
            )

        self._write_register(
            self.REG_PA_CONFIG,
            self.PA_BOOST | (level - 2),
        )

    def set_spreading_factor(self, spreading_factor):
        if spreading_factor < 6:
            spreading_factor = 6

        if spreading_factor > 12:
            spreading_factor = 12

        config_2 = self._read_register(
            self.REG_MODEM_CONFIG_2
        )

        config_2 = (
            config_2 & 0x0F
        ) | (
            spreading_factor << 4
        )

        self._write_register(
            self.REG_MODEM_CONFIG_2,
            config_2,
        )

    def set_signal_bandwidth(self, bandwidth):
        bandwidth_values = (
            7800,
            10400,
            15600,
            20800,
            31250,
            41700,
            62500,
            125000,
            250000,
            500000,
        )

        bandwidth_index = 0

        for index, value in enumerate(
            bandwidth_values
        ):
            bandwidth_index = index

            if bandwidth <= value:
                break

        config_1 = self._read_register(
            self.REG_MODEM_CONFIG_1
        )

        config_1 = (
            config_1 & 0x0F
        ) | (
            bandwidth_index << 4
        )

        self._write_register(
            self.REG_MODEM_CONFIG_1,
            config_1,
        )

    def set_coding_rate(self, denominator):
        if denominator < 5:
            denominator = 5

        if denominator > 8:
            denominator = 8

        coding_rate = denominator - 4

        config_1 = self._read_register(
            self.REG_MODEM_CONFIG_1
        )

        config_1 = (
            config_1 & 0xF1
        ) | (
            coding_rate << 1
        )

        self._write_register(
            self.REG_MODEM_CONFIG_1,
            config_1,
        )

    def set_preamble_length(self, length):
        self._write_register(
            self.REG_PREAMBLE_MSB,
            (length >> 8) & 0xFF,
        )

        self._write_register(
            self.REG_PREAMBLE_LSB,
            length & 0xFF,
        )

    def set_sync_word(self, sync_word):
        self._write_register(
            self.REG_SYNC_WORD,
            sync_word,
        )

    def set_crc(self, enabled):
        config_2 = self._read_register(
            self.REG_MODEM_CONFIG_2
        )

        if enabled:
            config_2 |= 0x04
        else:
            config_2 &= 0xFB

        self._write_register(
            self.REG_MODEM_CONFIG_2,
            config_2,
        )

    def send(self, payload, timeout_ms=3000):
        if not isinstance(payload, (bytes, bytearray)):
            raise TypeError(
                "El payload LoRa debe ser bytes"
            )

        if len(payload) > 255:
            raise ValueError(
                "El payload LoRa supera 255 bytes"
            )

        self.standby()

        self._write_register(
            self.REG_IRQ_FLAGS,
            0xFF,
        )

        self._write_register(
            self.REG_FIFO_ADDR_PTR,
            0x00,
        )

        self._write_fifo(payload)

        self._write_register(
            self.REG_PAYLOAD_LENGTH,
            len(payload),
        )

        self._write_register(
            self.REG_OP_MODE,
            self.MODE_LONG_RANGE_MODE | self.MODE_TX,
        )

        start_ms = time.ticks_ms()

        while True:
            irq_flags = self._read_register(
                self.REG_IRQ_FLAGS
            )

            if irq_flags & self.IRQ_TX_DONE_MASK:
                self._write_register(
                    self.REG_IRQ_FLAGS,
                    self.IRQ_TX_DONE_MASK,
                )

                self.receive_continuous()
                return True

            if time.ticks_diff(
                time.ticks_ms(),
                start_ms,
            ) >= timeout_ms:
                self.receive_continuous()

                raise SX127xError(
                    "Timeout durante transmisión LoRa"
                )

            time.sleep_ms(2)

    def receive(self):
        irq_flags = self._read_register(
            self.REG_IRQ_FLAGS
        )

        if not (
            irq_flags & self.IRQ_RX_DONE_MASK
        ):
            return None

        self._write_register(
            self.REG_IRQ_FLAGS,
            irq_flags,
        )

        crc_error = bool(
            irq_flags
            & self.IRQ_PAYLOAD_CRC_ERROR_MASK
        )

        self._last_crc_valid = not crc_error

        if crc_error:
            return None

        current_address = self._read_register(
            self.REG_FIFO_RX_CURRENT_ADDR
        )

        self._write_register(
            self.REG_FIFO_ADDR_PTR,
            current_address,
        )

        packet_length = self._read_register(
            self.REG_RX_NB_BYTES
        )

        payload = self._read_fifo(packet_length)

        raw_snr = self._read_register(
            self.REG_PKT_SNR_VALUE
        )

        if raw_snr & 0x80:
            raw_snr -= 256

        self._last_snr = raw_snr / 4.0

        raw_rssi = self._read_register(
            self.REG_PKT_RSSI_VALUE
        )

        frequency_offset = (
            -164
            if self._frequency < 525000000
            else -157
        )

        self._last_rssi = frequency_offset + raw_rssi
        return bytes(payload)

    def metadata(self):
        return {
            "frequency": self._frequency,
            "rssi": self._last_rssi,
            "snr": self._last_snr,
            "crc_valid": self._last_crc_valid,
        }
PY

###############################################################################
# LoRa transport wrapper
###############################################################################

cat > "${TRANSPORTS_DIR}/lora_transport.py" <<'PY'
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
PY

###############################################################################
# Transport factory
###############################################################################

cat > "${TRANSPORTS_DIR}/factory.py" <<'PY'
from common.transports.base import TransportError


def create_transport(config):
    transport_name = config["transport"].lower()

    if transport_name == "uart":
        from common.transports.uart_transport import UARTTransport

        return UARTTransport(
            uart_id=config.get("uart_id", 2),
            baudrate=config.get(
                "uart_baudrate",
                115200,
            ),
            tx_pin=config.get("uart_tx_pin", 17),
            rx_pin=config.get("uart_rx_pin", 16),
        )

    if transport_name == "udp":
        from common.transports.udp_transport import UDPTransport

        return UDPTransport(
            local_ip=config["local_ip"],
            local_port=config["local_port"],
            remote_ip=config["remote_ip"],
            remote_port=config["remote_port"],
        )

    if transport_name == "lora":
        from common.transports.lora_transport import LoRaTransport

        return LoRaTransport(
            spi_id=config.get("lora_spi_id", 2),
            sck_pin=config.get("lora_sck_pin", 18),
            mosi_pin=config.get("lora_mosi_pin", 23),
            miso_pin=config.get("lora_miso_pin", 19),
            cs_pin=config.get("lora_cs_pin", 5),
            reset_pin=config.get(
                "lora_reset_pin",
                14,
            ),
            dio0_pin=config.get(
                "lora_dio0_pin",
                26,
            ),
            frequency=config.get(
                "lora_frequency",
                433000000,
            ),
            tx_power=config.get(
                "lora_tx_power",
                10,
            ),
            spreading_factor=config.get(
                "lora_spreading_factor",
                7,
            ),
            bandwidth=config.get(
                "lora_bandwidth",
                125000,
            ),
            coding_rate=config.get(
                "lora_coding_rate",
                5,
            ),
            preamble_length=config.get(
                "lora_preamble_length",
                8,
            ),
            sync_word=config.get(
                "lora_sync_word",
                0x42,
            ),
        )

    if transport_name == "loopback":
        from common.transports.loopback_transport import (
            LoopbackTransport,
        )

        return LoopbackTransport()

    raise TransportError(
        "Transporte no soportado: {}".format(
            transport_name
        )
    )
PY

###############################################################################
# Import and factory test
###############################################################################

cat > "${TESTS_DIR}/test_transport_modules.py" <<'PY'
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
PY

###############################################################################
# Local verification
###############################################################################

echo
echo "================================================"
echo "ARCHIVOS CREADOS"
echo "================================================"

find "${COMMON_DIR}" "${TESTS_DIR}" \
    -maxdepth 3 \
    -type f \
    -print \
    | sort

echo
echo "================================================"
echo "VALIDACIÓN SINTÁCTICA LOCAL"
echo "================================================"

python -m py_compile \
    "${TRANSPORTS_DIR}/base.py" \
    "${TRANSPORTS_DIR}/uart_transport.py" \
    "${TRANSPORTS_DIR}/udp_transport.py" \
    "${COMMON_DIR}/wifi_manager.py" \
    "${TRANSPORTS_DIR}/sx127x.py" \
    "${TRANSPORTS_DIR}/lora_transport.py" \
    "${TRANSPORTS_DIR}/factory.py" \
    "${TESTS_DIR}/test_transport_modules.py"

LOCAL_STATUS=$?

if [ "${LOCAL_STATUS}" -eq 0 ]; then
    echo "PASS: sintaxis Python válida"
else
    echo "FAIL: error de sintaxis"
fi

###############################################################################
# Deployment function
###############################################################################

deploy_to_esp32() {
    local port="$1"
    local node_name="$2"

    echo
    echo "================================================"
    echo "DESPLIEGUE EN ${node_name} (${port})"
    echo "================================================"

    mpremote connect "${port}" exec \
'import os
for path in ("common", "common/transports"):
    try:
        os.mkdir(path)
    except OSError:
        pass
print("Directorios preparados")'

    local command_status=$?

    for file in \
        "${COMMON_DIR}/__init__.py" \
        "${COMMON_DIR}/frame.py" \
        "${COMMON_DIR}/telemetry.py" \
        "${COMMON_DIR}/wifi_manager.py"
    do
        destination=":common/$(basename "${file}")"

        mpremote connect "${port}" \
            fs cp "${file}" "${destination}"

        if [ "$?" -ne 0 ]; then
            command_status=1
        fi
    done

    for file in \
        "${TRANSPORTS_DIR}/__init__.py" \
        "${TRANSPORTS_DIR}/base.py" \
        "${TRANSPORTS_DIR}/loopback_transport.py" \
        "${TRANSPORTS_DIR}/uart_transport.py" \
        "${TRANSPORTS_DIR}/udp_transport.py" \
        "${TRANSPORTS_DIR}/sx127x.py" \
        "${TRANSPORTS_DIR}/lora_transport.py" \
        "${TRANSPORTS_DIR}/factory.py"
    do
        destination=":common/transports/$(basename "${file}")"

        mpremote connect "${port}" \
            fs cp "${file}" "${destination}"

        if [ "$?" -ne 0 ]; then
            command_status=1
        fi
    done

    mpremote connect "${port}" \
        fs ls :common/transports

    mpremote connect "${port}" \
        run "${TESTS_DIR}/test_transport_modules.py"

    if [ "$?" -ne 0 ]; then
        command_status=1
    fi

    if [ "${command_status}" -eq 0 ]; then
        echo "PASS: ${node_name}"
    else
        echo "FAIL: ${node_name}"
    fi

    return "${command_status}"
}

A_STATUS=0
B_STATUS=0

deploy_to_esp32 "${ESP32_A_PORT}" "ESP32 A" || A_STATUS=1
deploy_to_esp32 "${ESP32_B_PORT}" "ESP32 B" || B_STATUS=1

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
echo "El script terminó. La terminal permanece abierta."
