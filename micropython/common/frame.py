try:
    import struct
except ImportError:
    import ustruct as struct


MAGIC = 0x49
VERSION = 0x01

NODE_A = 0x01
NODE_B = 0x02

FLAG_NONE = 0x00

FRAME_FORMAT_WITHOUT_CRC = ">BBBBIH"
FRAME_FORMAT = ">BBBBIHH"

FRAME_SIZE = struct.calcsize(FRAME_FORMAT)


class FrameError(Exception):
    pass


def crc16_ccitt(data, initial=0xFFFF):
    """
    CRC-16/CCITT-FALSE:
    poly=0x1021, init=0xFFFF, refin=false, refout=false.
    """
    crc = initial

    for byte in data:
        crc ^= byte << 8

        for _ in range(8):
            if crc & 0x8000:
                crc = ((crc << 1) ^ 0x1021) & 0xFFFF
            else:
                crc = (crc << 1) & 0xFFFF

    return crc


def encode_frame(sender, position, coordinate, flags=FLAG_NONE):
    if sender not in (NODE_A, NODE_B):
        raise ValueError("Identificador de nodo inválido")

    if position < 0 or position > 0xFFFFFFFF:
        raise ValueError("Posición fuera de rango")

    if coordinate < 0 or coordinate > 1023:
        raise ValueError("Coordenada fuera del espacio InvisComm")

    body = struct.pack(
        FRAME_FORMAT_WITHOUT_CRC,
        MAGIC,
        VERSION,
        sender,
        flags,
        position,
        coordinate,
    )

    checksum = crc16_ccitt(body)

    return body + struct.pack(">H", checksum)


def decode_frame(data):
    if not isinstance(data, (bytes, bytearray)):
        raise FrameError("La trama debe ser bytes")

    if len(data) != FRAME_SIZE:
        raise FrameError(
            "Longitud inválida: {} bytes; esperados: {}".format(
                len(data),
                FRAME_SIZE,
            )
        )

    (
        magic,
        version,
        sender,
        flags,
        position,
        coordinate,
        received_crc,
    ) = struct.unpack(FRAME_FORMAT, data)

    if magic != MAGIC:
        raise FrameError("Cabecera MAGIC inválida")

    if version != VERSION:
        raise FrameError("Versión de trama no soportada")

    if sender not in (NODE_A, NODE_B):
        raise FrameError("Identificador de nodo inválido")

    if coordinate > 1023:
        raise FrameError("Coordenada fuera del espacio InvisComm")

    calculated_crc = crc16_ccitt(data[:-2])

    if received_crc != calculated_crc:
        raise FrameError(
            "CRC inválido: recibido=0x{:04X}, calculado=0x{:04X}".format(
                received_crc,
                calculated_crc,
            )
        )

    return {
        "sender": sender,
        "flags": flags,
        "position": position,
        "coordinate": coordinate,
    }
