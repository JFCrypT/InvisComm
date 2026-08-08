from common.experiment_defaults import BOB_BASE


CONFIG = dict(BOB_BASE)

CONFIG.update({
    "transport": "uart",
    "control_mode": "usb",

    "tx_interval_ms": 1000,
    "initial_tx_delay_ms": 500,

    "uart_id": 2,
    "uart_baudrate": 115200,
    "uart_tx_pin": 17,
    "uart_rx_pin": 16,
})
