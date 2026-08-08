import socket
import time


CONTROL_PORT = 43000
START_PREFIX = "INVISCOMM_START"


class SessionControlError(Exception):
    pass


def wait_for_start(
    node_name,
    local_port=CONTROL_PORT,
    timeout_seconds=300,
):
    """
    Espera una orden:

        INVISCOMM_START,<session_id>,<delay_ms>
    """

    control_socket = socket.socket(
        socket.AF_INET,
        socket.SOCK_DGRAM,
    )

    try:
        control_socket.setsockopt(
            socket.SOL_SOCKET,
            socket.SO_REUSEADDR,
            1,
        )
    except Exception:
        pass

    control_socket.bind(
        ("0.0.0.0", local_port)
    )

    control_socket.settimeout(1.0)

    print(
        "READY,{},{},{}".format(
            node_name,
            local_port,
            time.ticks_ms(),
        )
    )

    start_ms = time.ticks_ms()
    timeout_ms = timeout_seconds * 1000

    while True:
        if time.ticks_diff(
            time.ticks_ms(),
            start_ms,
        ) >= timeout_ms:
            control_socket.close()

            raise SessionControlError(
                "Timeout esperando orden START"
            )

        try:
            payload, source = (
                control_socket.recvfrom(128)
            )
        except OSError:
            continue

        try:
            message = payload.decode(
                "utf-8"
            ).strip()
        except Exception:
            continue

        fields = message.split(",")

        if len(fields) != 3:
            continue

        if fields[0] != START_PREFIX:
            continue

        session_id = fields[1]

        try:
            delay_ms = int(fields[2])
        except ValueError:
            continue

        if delay_ms < 0 or delay_ms > 30000:
            continue

        print(
            "CONTROL,{},{},{},{}".format(
                node_name,
                session_id,
                delay_ms,
                source[0],
            )
        )

        control_socket.close()

        return {
            "session_id": session_id,
            "delay_ms": delay_ms,
            "source": source,
        }
