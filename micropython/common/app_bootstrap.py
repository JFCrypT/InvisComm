import gc
import time

from common.node_runtime import InvisCommNodeRuntime
from common.transports.factory import create_transport


def _prepare_network(config):
    if config["transport"] != "udp":
        return None

    from common.wifi_manager import connect_wifi
    from wifi_secrets import WIFI_PASSWORD, WIFI_SSID

    print("Conectando a Wi-Fi...")

    station = connect_wifi(
        ssid=WIFI_SSID,
        password=WIFI_PASSWORD,
        timeout_seconds=30,
        hostname=config["hostname"],
    )

    network_data = station.ifconfig()

    print("Wi-Fi conectado")
    print("IP:", network_data[0])
    print("Máscara:", network_data[1])
    print("Gateway:", network_data[2])

    return station


def _wait_for_session(config):
    control_mode = config.get(
        "control_mode",
        "usb",
    )

    if control_mode == "udp":
        from common.session_control import wait_for_start

        return wait_for_start(
            config["name"],
            local_port=config.get(
                "control_port",
                43000,
            ),
        )

    if control_mode == "usb":
        from common.usb_session_control import (
            wait_for_usb_start,
        )

        return wait_for_usb_start(
            config["name"],
        )

    raise ValueError(
        "Modo de control no soportado: {}".format(
            control_mode
        )
    )


def start_node(config):
    print()
    print("========================================")
    print("InvisComm ESP32")
    print("========================================")
    print("Nodo:", config["name"])
    print("Transporte:", config["transport"])
    print("Control:", config["control_mode"])

    _prepare_network(config)

    print("Memoria libre:", gc.mem_free())

    session = _wait_for_session(config)

    print(
        "Sesión recibida:",
        session["session_id"],
    )

    transport = create_transport(config)

    node = InvisCommNodeRuntime(
        name=config["name"],
        node_id=config["node_id"],
        peer_id=config["peer_id"],
        shared_key=config["shared_key"],
        alphabet=config["alphabet"],
        transport=transport,
        tx_interval_ms=config["tx_interval_ms"],
        telemetry_enabled=True,
        strict_position=True,
        initial_tx_delay_ms=config.get(
            "initial_tx_delay_ms",
            config["tx_interval_ms"],
        ),
    )

    startup_message = config.get(
        "startup_message",
        "",
    )

    if startup_message:
        node.load_message(startup_message)

        print(
            "Mensaje inicial cargado:",
            startup_message,
        )

    delay_ms = session["delay_ms"]

    print(
        "Inicio sincronizado en {} ms".format(
            delay_ms
        )
    )

    time.sleep_ms(delay_ms)

    print(
        "START,{},{}".format(
            config["name"],
            session["session_id"],
        )
    )

    node.run_forever()
