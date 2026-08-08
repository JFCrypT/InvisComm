import gc
import time

from common.deterministic_prng import DeterministicPRNG
from common.frame import (
    NODE_A,
    NODE_B,
    FrameError,
    decode_frame,
    encode_frame,
)
from common.inviscomm_engine import InvisCommEngine
from common.telemetry import (
    DIRECTION_A_TO_B,
    DIRECTION_B_TO_A,
    TYPE_INFO,
    TYPE_NOISE,
    Telemetry,
)


class NodeRuntimeError(Exception):
    pass


class InvisCommNodeRuntime:
    """
    Runtime de un nodo InvisComm.

    Cada nodo mantiene:
      - un motor TX;
      - un motor RX;
      - posición TX independiente;
      - posición RX independiente;
      - cola de caracteres para transmitir;
      - buffer histórico de todos los caracteres recibidos.

    El receptor decodifica ciegamente tanto información como ruido,
    igual que la implementación Python de referencia.
    """

    def __init__(
        self,
        name,
        node_id,
        peer_id,
        shared_key,
        alphabet,
        transport,
        tx_interval_ms=300,
        telemetry_enabled=True,
        strict_position=True,
        initial_tx_delay_ms=None,
    ):
        if node_id not in (NODE_A, NODE_B):
            raise ValueError("node_id inválido")

        if peer_id not in (NODE_A, NODE_B):
            raise ValueError("peer_id inválido")

        if node_id == peer_id:
            raise ValueError("node_id y peer_id no pueden coincidir")

        self.name = name
        self.node_id = node_id
        self.peer_id = peer_id
        self.shared_key = shared_key
        self.alphabet = alphabet
        self.transport = transport
        self.tx_interval_ms = tx_interval_ms
        self.telemetry_enabled = telemetry_enabled
        self.strict_position = strict_position

        if initial_tx_delay_ms is None:
            initial_tx_delay_ms = tx_interval_ms

        self.initial_tx_delay_ms = initial_tx_delay_ms

        self.tx_engine = InvisCommEngine(
            shared_key,
            alphabet,
        )

        self.rx_engine = InvisCommEngine(
            shared_key,
            alphabet,
        )

        self.position_tx = 0
        self.position_rx = 0

        self._message_queue = []
        self.received_chars = []

        self._noise_prng = DeterministicPRNG(
            "{}:{}:noise".format(
                shared_key,
                node_id,
            )
        )

        self._last_tx_ms = time.ticks_ms()
        self._next_tx_ms = time.ticks_add(
            self._last_tx_ms,
            self.initial_tx_delay_ms,
        )
        self._running = False

        self.telemetry = Telemetry(name)

        self.stats = {
            "tx_total": 0,
            "tx_info": 0,
            "tx_noise": 0,
            "rx_total": 0,
            "rx_valid": 0,
            "rx_invalid": 0,
            "rx_duplicates": 0,
            "rx_out_of_order": 0,
            "rx_missing": 0,
            "decode_errors": 0,
        }

    def _tx_direction(self):
        if self.node_id == NODE_A:
            return DIRECTION_A_TO_B

        return DIRECTION_B_TO_A

    def load_message(self, message):
        if not isinstance(message, str):
            raise TypeError("El mensaje debe ser str")

        for character in message:
            if character not in self.alphabet:
                raise ValueError(
                    "Caracter no soportado: {!r}".format(
                        character
                    )
                )

        self._message_queue.extend(message)

    def pending_message_characters(self):
        return len(self._message_queue)

    def _next_transmit_character(self):
        if self._message_queue:
            character = self._message_queue.pop(0)
            return character, TYPE_INFO

        index = self._noise_prng.randbelow(
            len(self.alphabet)
        )

        return self.alphabet[index], TYPE_NOISE

    def transmit_once(self):
        """
        Genera y transmite exactamente una coordenada.
        """
        character, frame_type = (
            self._next_transmit_character()
        )

        encode_start_us = time.ticks_us()

        coordinate = self.tx_engine.encode_symbol(
            character,
            self.position_tx,
        )

        encode_time_us = time.ticks_diff(
            time.ticks_us(),
            encode_start_us,
        )

        frame = encode_frame(
            sender=self.node_id,
            position=self.position_tx,
            coordinate=coordinate,
        )

        send_start_us = time.ticks_us()
        result = self.transport.send(frame)
        send_time_us = time.ticks_diff(
            time.ticks_us(),
            send_start_us,
        )

        if not result:
            raise NodeRuntimeError(
                "El transporte no confirmó el envío"
            )

        self.stats["tx_total"] += 1

        if frame_type == TYPE_INFO:
            self.stats["tx_info"] += 1
        else:
            self.stats["tx_noise"] += 1

        if self.telemetry_enabled:
            self.telemetry.emit(
                self._tx_direction(),
                coordinate,
                frame_type,
            )

            print(
                "PERF,{},{},{},{},{},{}".format(
                    self.name,
                    self.transport.name(),
                    self.position_tx,
                    encode_time_us,
                    send_time_us,
                    gc.mem_free(),
                )
            )

        transmitted = {
            "position": self.position_tx,
            "character": character,
            "coordinate": coordinate,
            "type": frame_type,
            "frame": frame,
            "encode_time_us": encode_time_us,
            "send_time_us": send_time_us,
        }

        self.position_tx += 1
        self._last_tx_ms = time.ticks_ms()

        return transmitted

    def transmit_if_due(self):
        now_ms = time.ticks_ms()

        if time.ticks_diff(
            now_ms,
            self._next_tx_ms,
        ) < 0:
            return None

        # La próxima fecha se calcula respecto de la anterior,
        # no respecto del final de la codificación.
        self._next_tx_ms = time.ticks_add(
            self._next_tx_ms,
            self.tx_interval_ms,
        )

        return self.transmit_once()

    def _validate_position(self, received_position):
        expected = self.position_rx

        if received_position == expected:
            return True

        if received_position < expected:
            self.stats["rx_duplicates"] += 1

            if self.strict_position:
                raise NodeRuntimeError(
                    "Trama duplicada o antigua: "
                    "recibida={}, esperada={}".format(
                        received_position,
                        expected,
                    )
                )

            return False

        missing = received_position - expected

        self.stats["rx_missing"] += missing
        self.stats["rx_out_of_order"] += 1

        raise NodeRuntimeError(
            "Pérdida o desorden: "
            "recibida={}, esperada={}, faltantes={}".format(
                received_position,
                expected,
                missing,
            )
        )

    def receive_once(self):
        """
        Procesa como máximo una trama.

        Retorna:
            dict: si procesó una trama;
            None: si no había datos.
        """
        raw_frame = self.transport.receive()

        if raw_frame is None:
            return None

        self.stats["rx_total"] += 1

        try:
            decoded_frame = decode_frame(raw_frame)
        except FrameError as error:
            self.stats["rx_invalid"] += 1
            raise NodeRuntimeError(
                "Trama física inválida: {}".format(error)
            )

        if decoded_frame["sender"] != self.peer_id:
            self.stats["rx_invalid"] += 1
            raise NodeRuntimeError(
                "Emisor inesperado: {}".format(
                    decoded_frame["sender"]
                )
            )

        received_position = decoded_frame["position"]

        if not self._validate_position(
            received_position
        ):
            return None

        decode_start_us = time.ticks_us()

        try:
            character = self.rx_engine.decode_coordinate(
                decoded_frame["coordinate"],
                self.position_rx,
            )
        except Exception as error:
            self.stats["decode_errors"] += 1
            raise NodeRuntimeError(
                "No se pudo decodificar posición {}: {}".format(
                    self.position_rx,
                    error,
                )
            )

        decode_time_us = time.ticks_diff(
            time.ticks_us(),
            decode_start_us,
        )

        self.received_chars.append(character)
        self.position_rx += 1

        self.stats["rx_valid"] += 1

        metadata = self.transport.metadata()

        rssi = metadata.get("rssi", "")
        snr = metadata.get("snr", "")
        radio_crc = metadata.get("crc_valid", "")

        print(
            "RX,{},{},{},{},{},{},{},{}".format(
                self.name,
                received_position,
                decoded_frame["coordinate"],
                repr(character),
                decode_time_us,
                rssi,
                snr,
                radio_crc,
            )
        )

        return {
            "position": received_position,
            "coordinate": decoded_frame["coordinate"],
            "character": character,
            "decode_time_us": decode_time_us,
            "transport_metadata": self.transport.metadata(),
        }

    def drain_receive(self, maximum_packets=32):
        processed = []

        for _ in range(maximum_packets):
            item = self.receive_once()

            if item is None:
                break

            processed.append(item)

        return processed

    def received_text(self, start=0, length=None):
        if length is None:
            return "".join(
                self.received_chars[start:]
            )

        end = start + length

        return "".join(
            self.received_chars[start:end]
        )

    def run_forever(self):
        self._running = True

        print(
            "LOG,{},{},Runtime iniciado con transporte {}".format(
                self.name,
                "INFO",
                self.transport.name(),
            )
        )

        while self._running:
            try:
                self.transmit_if_due()
                self.drain_receive()
                time.sleep_ms(10)
            except Exception as error:
                print(
                    "LOG,{},{},{}".format(
                        self.name,
                        "ERROR",
                        error,
                    )
                )

                self._running = False
                raise

    def stop(self):
        self._running = False

        try:
            self.transport.close()
        except Exception:
            pass

    def state_snapshot(self):
        return {
            "name": self.name,
            "node_id": self.node_id,
            "peer_id": self.peer_id,
            "position_tx": self.position_tx,
            "position_rx": self.position_rx,
            "pending_message_characters": len(
                self._message_queue
            ),
            "received_characters": len(
                self.received_chars
            ),
            "tx_engine": self.tx_engine.state_snapshot(),
            "rx_engine": self.rx_engine.state_snapshot(),
            "stats": dict(self.stats),
        }
