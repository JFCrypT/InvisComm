import time


TYPE_INFO = "Info"
TYPE_NOISE = "Noise"

DIRECTION_A_TO_B = "A-->B"
DIRECTION_B_TO_A = "B-->A"


class Telemetry:
    def __init__(self, node_name):
        self.node_name = node_name
        self.start_ms = time.ticks_ms()
        self.sequence = 0

    def elapsed_seconds(self):
        elapsed_ms = time.ticks_diff(
            time.ticks_ms(),
            self.start_ms,
        )

        return elapsed_ms / 1000.0

    def emit(self, direction, coordinate, frame_type):
        if direction not in (
            DIRECTION_A_TO_B,
            DIRECTION_B_TO_A,
        ):
            raise ValueError("Dirección de telemetría inválida")

        if frame_type not in (
            TYPE_INFO,
            TYPE_NOISE,
        ):
            raise ValueError("Tipo de trama inválido")

        if coordinate < 0 or coordinate > 1023:
            raise ValueError("Coordenada fuera de rango")

        timestamp = self.elapsed_seconds()

        # Formato:
        # TEL,sequence,timestamp,direction,encrypted_coord,type,node
        print(
            "TEL,{},{:.3f},{},{},{},{}".format(
                self.sequence,
                timestamp,
                direction,
                coordinate,
                frame_type,
                self.node_name,
            )
        )

        self.sequence += 1

    def diagnostic(self, level, message):
        print(
            "LOG,{},{},{}".format(
                self.node_name,
                level,
                message,
            )
        )
