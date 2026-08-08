import sys
import time

try:
    import select
except ImportError:
    import uselect as select


START_PREFIX = "INVISCOMM_START"


class USBSessionControlError(Exception):
    pass


def wait_for_usb_start(
    node_name,
    timeout_seconds=300,
):
    """
    Espera por USB serie una línea:

        INVISCOMM_START,<session_id>,<delay_ms>

    El host abre los puertos USB, espera READY y envía la orden
    simultáneamente a Alice y Bob.
    """

    poller = select.poll()

    poller.register(
        sys.stdin,
        select.POLLIN,
    )

    print(
        "READY,{},{},{}".format(
            node_name,
            "USB",
            time.ticks_ms(),
        )
    )

    start_ms = time.ticks_ms()
    timeout_ms = timeout_seconds * 1000

    while True:
        elapsed = time.ticks_diff(
            time.ticks_ms(),
            start_ms,
        )

        if elapsed >= timeout_ms:
            raise USBSessionControlError(
                "Timeout esperando START por USB"
            )

        events = poller.poll(200)

        if not events:
            continue

        try:
            line = sys.stdin.readline()
        except Exception:
            continue

        if not line:
            continue

        message = line.strip()
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
            "CONTROL,{},{},{}".format(
                node_name,
                session_id,
                delay_ms,
            )
        )

        return {
            "session_id": session_id,
            "delay_ms": delay_ms,
            "source": "USB",
        }
