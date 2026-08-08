from common.app_config import (
    ALPHABET,
    KEP_SHARED_KEY,
    NODE_A_ID,
    NODE_B_ID,
    NODE_B_NAME,
    TX_INTERVAL_MS,
)


CONFIG = {
    "name": NODE_B_NAME,
    "hostname": "inviscomm-bob",
    "node_id": NODE_B_ID,
    "peer_id": NODE_A_ID,
    "shared_key": KEP_SHARED_KEY,
    "alphabet": ALPHABET,
    "tx_interval_ms": TX_INTERVAL_MS,

    "transport": "udp",
    "control_port": 43000,

    "local_ip": "0.0.0.0",
    "local_port": 42002,
    "remote_ip": "255.255.255.255",
    "remote_port": 42001,

    "startup_delay_ms": 15000,
    "startup_message": (
        "Received. The attack will begin at 12:00"
    ),
}
