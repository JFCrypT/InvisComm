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
