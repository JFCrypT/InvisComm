class TransportError(Exception):
    pass


class Transport:
    """
    Interfaz común para UART, UDP/IP y LoRa.
    """

    def send(self, payload):
        raise NotImplementedError

    def receive(self):
        """
        Retorna:
            bytes: cuando existe una trama completa;
            None: cuando no hay datos disponibles.
        """
        raise NotImplementedError

    def close(self):
        pass

    def name(self):
        return self.__class__.__name__

    def metadata(self):
        """
        Información adicional del último paquete recibido.

        Ejemplos:
            RSSI y SNR para LoRa;
            dirección IP para UDP.
        """
        return {}
