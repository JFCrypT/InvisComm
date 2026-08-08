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
