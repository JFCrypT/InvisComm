from common.app_config import (
    ALPHABET,
    KEP_SHARED_KEY,
    NODE_A_ID,
    NODE_A_NAME,
    NODE_B_ID,
    NODE_B_NAME,
)


ALICE_BASE = {
    "name": NODE_A_NAME,
    "hostname": "inviscomm-alice",
    "node_id": NODE_A_ID,
    "peer_id": NODE_B_ID,
    "shared_key": KEP_SHARED_KEY,
    "alphabet": ALPHABET,
    "startup_message": (
        "Attack from the northern front"
    ),
}


BOB_BASE = {
    "name": NODE_B_NAME,
    "hostname": "inviscomm-bob",
    "node_id": NODE_B_ID,
    "peer_id": NODE_A_ID,
    "shared_key": KEP_SHARED_KEY,
    "alphabet": ALPHABET,
    "startup_message": (
        "Received. The attack will begin at 12:00"
    ),
}
