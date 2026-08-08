from common.experiment_defaults import BOB_BASE


CONFIG = dict(BOB_BASE)

CONFIG.update({
    "transport": "lora",
    "control_mode": "usb",

    "tx_interval_ms": 1500,

    # Bob transmite desplazado 750 ms respecto de Alice.
    "initial_tx_delay_ms": 1250,

    "lora_spi_id": 2,
    "lora_sck_pin": 18,
    "lora_mosi_pin": 23,
    "lora_cs_pin": 5,
    "lora_reset_pin": 14,
    "lora_dio0_pin": 26,

    "lora_frequency": 433000000,
    "lora_tx_power": 10,
    "lora_spreading_factor": 7,
    "lora_bandwidth": 125000,
    "lora_coding_rate": 5,
    "lora_preamble_length": 8,
    "lora_sync_word": 0x42,
})
