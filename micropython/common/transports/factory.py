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
