from common.transports.base import Transport


class LoopbackTransport(Transport):
    def __init__(self):
        self._queue = []

    def send(self, payload):
        if not isinstance(payload, (bytes, bytearray)):
            raise TypeError("El payload debe ser bytes")

        self._queue.append(bytes(payload))
        return True

    def receive(self):
        if not self._queue:
            return None

        return self._queue.pop(0)

    def close(self):
        self._queue = []
