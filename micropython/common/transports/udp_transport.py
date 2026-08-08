import socket

from common.frame import FRAME_SIZE
from common.transports.base import Transport, TransportError


class UDPTransport(Transport):
    """
    Transporte UDP no bloqueante.

    Soporta unicast y broadcast. Para el laboratorio se emplea
    255.255.255.255, evitando configurar manualmente las IP de los nodos.
    """

    def __init__(
        self,
        local_ip,
        local_port,
        remote_ip,
        remote_port,
    ):
        self._local_address = (
            local_ip,
            local_port,
        )

        self._remote_address = (
            remote_ip,
            remote_port,
        )

        self._socket = socket.socket(
            socket.AF_INET,
            socket.SOCK_DGRAM,
        )

        try:
            self._socket.setsockopt(
                socket.SOL_SOCKET,
                socket.SO_REUSEADDR,
                1,
            )
        except Exception:
            pass

        if remote_ip.endswith(".255") or remote_ip == "255.255.255.255":
            try:
                self._socket.setsockopt(
                    socket.SOL_SOCKET,
                    socket.SO_BROADCAST,
                    1,
                )
            except Exception:
                # Algunas compilaciones MicroPython permiten broadcast
                # sin exponer explícitamente SO_BROADCAST.
                pass

        self._socket.bind(self._local_address)
        self._socket.setblocking(False)

        self._last_remote_address = None
        self._sent_packets = 0
        self._received_packets = 0
        self._invalid_length_packets = 0

    def send(self, payload):
        if not isinstance(payload, (bytes, bytearray)):
            raise TypeError("El payload UDP debe ser bytes")

        if len(payload) != FRAME_SIZE:
            raise TransportError(
                "UDP esperaba {} bytes y recibió {}".format(
                    FRAME_SIZE,
                    len(payload),
                )
            )

        sent = self._socket.sendto(
            payload,
            self._remote_address,
        )

        if sent != len(payload):
            raise TransportError(
                "UDP envió {} de {} bytes".format(
                    sent,
                    len(payload),
                )
            )

        self._sent_packets += 1
        return True

    def receive(self):
        try:
            data, address = self._socket.recvfrom(256)
        except OSError:
            return None

        if len(data) != FRAME_SIZE:
            self._invalid_length_packets += 1
            return None

        self._last_remote_address = address
        self._received_packets += 1
        return bytes(data)

    def close(self):
        try:
            self._socket.close()
        except Exception:
            pass

    def metadata(self):
        return {
            "local_address": self._local_address,
            "remote_address": self._remote_address,
            "last_remote_address": self._last_remote_address,
            "sent_packets": self._sent_packets,
            "received_packets": self._received_packets,
            "invalid_length_packets": self._invalid_length_packets,
        }
