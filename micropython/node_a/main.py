from common.app_bootstrap import start_node
from node_config import CONFIG
from wifi_secrets import WIFI_PASSWORD, WIFI_SSID


start_node(
    CONFIG,
    WIFI_SSID,
    WIFI_PASSWORD,
)
