# Notas del porte Arduino Uno

## Restricción principal

Arduino Uno dispone de 2 KiB de SRAM. Por esa razón el motor no construye ni almacena una tabla de 1024 coordenadas. En cada posición deriva mediante SHA-256 una permutación afín invertible sobre `Z_1024`:

`coordinate = base + symbol_index * stride (mod 1024)`

con `stride` siempre impar, por lo que es invertible. El estado `(H, M1, M2, M3, phase)` evoluciona después de cada coordenada verificada.

Esto preserva la semántica de espacio virtual variable y la sincronización estricta sin consumir 2 KiB de SRAM en tablas.

## Compatibilidad experimental

- Trama: compatible con la trama de 12 bytes del port ESP32.
- CRC: CRC-16/CCITT-FALSE.
- Telemetría: compatible con la notebook de análisis.
- Mensajes: mismos mensajes Alice/Bob usados en ESP32.
- Transporte: UDP sin confiabilidad añadida.
- PRNG/derivación: SHA-256 determinístico.

## Diferencia pendiente de validación cruzada

Los archivos fuente exactos de `micropython/common/deterministic_prng.py` y `micropython/common/inviscomm_engine.py` no estaban incluidos entre los artefactos disponibles al generar este porte. Por ello no se afirma equivalencia bit-a-bit de coordenadas entre ESP32/MicroPython y Arduino/C++. La equivalencia Alice↔Bob dentro del porte Arduino es determinística.
