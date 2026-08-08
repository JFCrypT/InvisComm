from common.transports.base import Transport


class _MemoryEndpoint(Transport):
    def __init__(self, incoming_queue, outgoing_queue, endpoint_name):
        self._incoming_queue = incoming_queue
        self._outgoing_queue = outgoing_queue
        self._endpoint_name = endpoint_name
        self._sent_packets = 0
        self._received_packets = 0
        self._closed = False

    def send(self, payload):
        if self._closed:
            raise RuntimeError("El endpoint está cerrado")

        if not isinstance(payload, (bytes, bytearray)):
            raise TypeError("El payload debe ser bytes")

        self._outgoing_queue.append(bytes(payload))
        self._sent_packets += 1
        return True

    def receive(self):
        if self._closed or not self._incoming_queue:
            return None

        self._received_packets += 1
        return self._incoming_queue.pop(0)

    def close(self):
        self._closed = True

    def metadata(self):
        return {
            "endpoint": self._endpoint_name,
            "sent_packets": self._sent_packets,
            "received_packets": self._received_packets,
            "queued_packets": len(self._incoming_queue),
        }


def create_duplex_memory_link():
    """
    Crea dos extremos conectados:

        endpoint_a.send() -> endpoint_b.receive()
        endpoint_b.send() -> endpoint_a.receive()
    """
    queue_a_to_b = []
    queue_b_to_a = []

    endpoint_a = _MemoryEndpoint(
        incoming_queue=queue_b_to_a,
        outgoing_queue=queue_a_to_b,
        endpoint_name="memory-A",
    )

    endpoint_b = _MemoryEndpoint(
        incoming_queue=queue_a_to_b,
        outgoing_queue=queue_b_to_a,
        endpoint_name="memory-B",
    )

    return endpoint_a, endpoint_b
