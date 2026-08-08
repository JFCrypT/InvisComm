try:
    import hashlib
except ImportError:
    import uhashlib as hashlib


class DeterministicPRNG:
    """
    PRNG determinístico basado en SHA-256.

    Se utiliza en lugar de random.Random de CPython, cuya inicialización
    con cadenas no está garantizada de forma compatible en MicroPython.

    Dos motores que reciban la misma semilla producen exactamente
    la misma secuencia.
    """

    def __init__(self, seed):
        if isinstance(seed, str):
            seed = seed.encode("utf-8")

        self._seed = seed
        self._counter = 0
        self._buffer = b""

    def _next_block(self):
        counter_bytes = self._counter.to_bytes(8, "big")
        self._counter += 1

        digest = hashlib.sha256(self._seed + counter_bytes).digest()
        self._buffer += digest

    def random_bytes(self, length):
        while len(self._buffer) < length:
            self._next_block()

        result = self._buffer[:length]
        self._buffer = self._buffer[length:]
        return result

    def randbelow(self, upper_bound):
        if upper_bound <= 0:
            raise ValueError("upper_bound debe ser positivo")

        # Rechazo para evitar sesgo modular.
        limit = (0x100000000 // upper_bound) * upper_bound

        while True:
            value = int.from_bytes(self.random_bytes(4), "big")

            if value < limit:
                return value % upper_bound

    def shuffle(self, values):
        for index in range(len(values) - 1, 0, -1):
            selected = self.randbelow(index + 1)
            values[index], values[selected] = values[selected], values[index]

    def sample(self, population, sample_size):
        if sample_size < 0 or sample_size > len(population):
            raise ValueError("Tamaño de muestra inválido")

        values = list(population)

        for index in range(sample_size):
            selected = index + self.randbelow(len(values) - index)
            values[index], values[selected] = values[selected], values[index]

        return values[:sample_size]
