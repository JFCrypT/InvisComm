from common.experiment_defaults import BOB_BASE


CONFIG = dict(BOB_BASE)

CONFIG.update({
    "transport": "udp",
    "control_mode": "udp",
    "control_port": 43000,

    "tx_interval_ms": 300,
    "initial_tx_delay_ms": 300,

    "local_ip": "0.0.0.0",
    "local_port": 42002,
    "remote_ip": "255.255.255.255",
    "remote_port": 42001,
})
