import gc

try:
    import hashlib
except ImportError:
    import uhashlib as hashlib

from common.deterministic_prng import DeterministicPRNG


DEFAULT_CONFIG = {
    "hash_primes": (131, 17, 19, 23),
    "lcg_multiplier": 1103515245,
    "lcg_increment": 12345,
    "diffusion_primes": (31, 37, 41, 43),
    "modulo": 1000003,
}


class InvisCommEngine:
    """
    Port MicroPython del núcleo InvisComm.

    Mantiene:
    - espacio virtual de 1024 coordenadas;
    - superposición de cuatro coordenadas;
    - estados M1, M2, M3 y H;
    - evolución de fase por símbolo;
    - motores TX y RX determinísticos e independientes.
    """

    SPACE_SIZE = 1024
    SUPERPOSITION_SIZE = 4

    def __init__(self, kep_shared_key, alphabet, config=None):
        if not alphabet:
            raise ValueError("El alfabeto no puede estar vacío")

        if len(alphabet) > self.SPACE_SIZE // self.SUPERPOSITION_SIZE:
            raise ValueError("El alfabeto es demasiado grande")

        self.alphabet = alphabet
        self.config = config if config is not None else DEFAULT_CONFIG
        self.phase = 0

        key_bytes = str(kep_shared_key).encode("utf-8")
        master_hash = hashlib.sha256(key_bytes).digest()
        modulo = self.config["modulo"]

        self.M1 = int.from_bytes(master_hash[0:4], "big") % modulo
        self.M2 = int.from_bytes(master_hash[4:8], "big") % modulo
        self.M3 = int.from_bytes(master_hash[8:12], "big") % modulo
        self.H = int.from_bytes(master_hash[12:16], "big") % modulo

        self.active_objects = None
        self.phi = None
        self.sigma = None

        self._build_phase_structures()

    def _rng(self, tag):
        phase_state = "{}:{}:{}:{}:{}".format(
            self.M1,
            self.M2,
            self.M3,
            self.H,
            self.phase,
        )

        seed = "{}:{}".format(phase_state, tag)
        return DeterministicPRNG(seed)

    def _build_phase_structures(self):
        virtual_space = list(range(self.SPACE_SIZE))

        active_rng = self._rng("active")
        self.active_objects = active_rng.sample(
            virtual_space,
            len(self.alphabet),
        )

        self.phi = {}
        for index, character in enumerate(self.alphabet):
            self.phi[character] = self.active_objects[index]

        used = set(self.active_objects)
        passive_pool = [
            coordinate
            for coordinate in virtual_space
            if coordinate not in used
        ]

        sigma_rng = self._rng("sigma")
        sigma_rng.shuffle(passive_pool)

        self.sigma = {}
        cursor = 0

        for active_object in self.active_objects:
            coordinates = [active_object]

            for _ in range(self.SUPERPOSITION_SIZE - 1):
                coordinates.append(passive_pool[cursor])
                cursor += 1

            sigma_rng.shuffle(coordinates)
            self.sigma[active_object] = coordinates

        del virtual_space
        del passive_pool
        del used
        gc.collect()

    def _psi(self, active_object, position):
        coordinates = self.sigma[active_object]
        rng = self._rng(
            "psi:{}:{}".format(active_object, position)
        )

        return coordinates[rng.randbelow(len(coordinates))]

    def _event_from_symbol(self, symbol, coordinate, position):
        primes = self.config["hash_primes"]
        modulo = self.config["modulo"]

        return (
            ord(symbol) * primes[0]
            + coordinate * primes[1]
            + position * primes[2]
            + self.phase * primes[3]
        ) % modulo

    def _advance_phase(self, event):
        old_M1 = self.M1
        old_M2 = self.M2
        old_M3 = self.M3
        old_H = self.H

        modulo = self.config["modulo"]

        entropy_trace = (
            old_M2 ^ old_M3 ^ event
        ) % modulo

        new_H = (
            old_H * self.config["lcg_multiplier"]
            + entropy_trace
            + self.config["lcg_increment"]
        ) % modulo

        diffusion = self.config["diffusion_primes"]

        new_M3 = (
            old_M1 * diffusion[0]
            + old_M2 * diffusion[1]
            + old_M3 * diffusion[2]
            + new_H * diffusion[3]
            + event
        ) % modulo

        self.M1 = old_M2
        self.M2 = old_M3
        self.M3 = new_M3
        self.H = new_H
        self.phase += 1

        self._build_phase_structures()

    def get_coordinate(self, character, position):
        if character not in self.phi:
            raise ValueError(
                "Caracter no soportado: {!r}".format(character)
            )

        active_object = self.phi[character]
        return self._psi(active_object, position)

    def encode_symbol(self, character, position):
        coordinate = self.get_coordinate(character, position)

        event = self._event_from_symbol(
            character,
            coordinate,
            position,
        )

        self._advance_phase(event)
        return coordinate

    def decode_coordinate(self, coordinate, position):
        if coordinate < 0 or coordinate >= self.SPACE_SIZE:
            raise ValueError("Coordenada fuera del espacio virtual")

        for character in self.alphabet:
            active_object = self.phi[character]

            if coordinate == self._psi(active_object, position):
                event = self._event_from_symbol(
                    character,
                    coordinate,
                    position,
                )

                self._advance_phase(event)
                return character

        raise ValueError(
            "Desincronización crítica o coordenada corrupta"
        )

    def state_snapshot(self):
        return {
            "phase": self.phase,
            "M1": self.M1,
            "M2": self.M2,
            "M3": self.M3,
            "H": self.H,
        }
