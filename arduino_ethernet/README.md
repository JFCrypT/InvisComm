# InvisComm — Arduino UNO + Ethernet

Porte experimental de la variante **UDP/Ethernet** de InvisComm para **dos Arduino Uno con Ethernet Shield W5100/W5500**, desarrollado para complementar las pruebas ESP32 por Wi-Fi y LoRa.

## Importante sobre compatibilidad

Este paquete conserva la interfaz experimental de la versión ESP32: espacio de coordenadas `0..1023`, tramas binarias de 12 bytes, CRC-16/CCITT-FALSE, motores TX/RX separados, tráfico `Info/Noise`, sincronización estricta de posiciones y telemetría `TEL,...` compatible con `InvisComm_02_Analisis.ipynb`.

La documentación disponible del proyecto confirma que la versión ESP32 usa un PRNG determinístico basado en SHA-256, pero no expone los cuerpos exactos de `deterministic_prng.py` e `inviscomm_engine.py`. Por eso este porte implementa una realización C++ determinística y de bajo consumo de RAM basada en SHA-256, diseñada para el Uno, pero **debe considerarse funcionalmente compatible, no todavía bit-a-bit equivalente a las coordenadas MicroPython**. Alice y Bob Arduino sí son completamente simétricos entre sí.

## Hardware

- 2 × Arduino Uno.
- 2 × Ethernet Shield clásico W5100 o W5500.
- 2 × cables USB.
- 2 × cables Ethernet.
- Router o switch conectado a una red con DHCP.

Montar cada Ethernet Shield directamente sobre su Arduino Uno. No se requieren cables Dupont entre shield y Arduino.

Conectar ambos shields por Ethernet al mismo router/switch. El código obtiene IP por DHCP y usa UDP broadcast para no requerir IPs fijas.

## Dónde colocar este proyecto

Descomprimir la carpeta `arduino_ethernet` dentro del repositorio InvisComm:

```text
InvisComm/
├── micropython/
├── host/
├── scripts/
├── arduino_ethernet/   ← esta carpeta
└── ...
```

Luego:

```bash
cd ~/Documents/Proyectos/InvisComm/arduino_ethernet
```

## Instalar dependencias de host

```bash
python3 -m venv .venv
source .venv/bin/activate
python -m pip install --upgrade pip
python -m pip install pyserial
```

PlatformIO debe estar disponible:

```bash
pio --version
pio device list
```

## Compilar ambos Arduino

```bash
pio run
```

O por separado:

```bash
pio run -e uno_alice
pio run -e uno_bob
```

Validación integral:

```bash
bash scripts/validate.sh
```

## Identificar puertos USB

Los Arduino Uno suelen aparecer como `/dev/ttyACM0`, `/dev/ttyACM1` o, según el conversor USB, `/dev/ttyUSB*`.

```bash
pio device list
```

## Cargar Alice

Ejemplo:

```bash
pio run -e uno_alice -t upload --upload-port /dev/ttyACM0
```

## Cargar Bob

Ejemplo:

```bash
pio run -e uno_bob -t upload --upload-port /dev/ttyACM1
```

## Verificar arranque manualmente

```bash
pio device monitor -p /dev/ttyACM0 -b 115200
```

Debe aparecer:

```text
Nodo: Alice
Transporte: UDP/Ethernet
Inicializando Ethernet por DHCP...
Ethernet conectado - IP: ...
READY,Alice,USB,...
```

Bob muestra lo mismo con `Nodo: Bob`.

Cerrar los monitores antes del experimento para liberar los puertos.

## Ejecutar experimento Ethernet

Activar el entorno Python:

```bash
cd ~/Documents/Proyectos/InvisComm/arduino_ethernet
source .venv/bin/activate
```

Crear carpeta de salida y ejecutar:

```bash
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
python -u host/run_ethernet_experiment.py \
  --port-a /dev/ttyACM0 \
  --port-b /dev/ttyACM1 \
  --duration 60 \
  --output-dir "telemetry/ethernet_${TIMESTAMP}"
```

Al abrir ambos puertos serie, normalmente los Uno se reinician automáticamente. El programa espera `READY` de ambos, envía el mismo `START` por USB y comienza la captura.

## Archivos generados

```text
telemetry/ethernet_YYYYMMDD_HHMMSS/
├── serial_raw.log
├── telemetria_extendida.csv
└── telemetria.csv
```

`telemetria.csv` conserva exactamente:

```text
timestamp,direction,encrypted_coord,type
```

Por eso puede copiarse junto a `InvisComm_02_Analisis.ipynb` y ejecutar la notebook completa.

## Semántica UDP

No se agregaron ACK, retransmisiones ni mecanismos de confiabilidad. Es **UDP puro sobre Ethernet**, para que la prueba sea comparable con UDP/Wi-Fi. Si una trama se pierde o llega fuera de orden, el runtime informa `Pérdida o desorden` y detiene la sesión para evitar evolucionar estados divergentes.

## Trama binaria

La trama conserva 12 bytes:

```text
0      magic = 'I'
1      version = 1
2      sender
3      flags
4..7   position (uint32, big-endian)
8..9   coordinate (uint16, big-endian)
10..11 CRC-16/CCITT-FALSE
```

## Pines del Ethernet Shield en Arduino Uno

El shield usa SPI del Uno internamente:

```text
D10 → CS Ethernet
D11 → MOSI
D12 → MISO
D13 → SCK
D4  → CS microSD (se mantiene desactivado en HIGH)
```

No conectar dispositivos adicionales a esos pines durante la prueba.

## Parámetros experimentales

```text
Shared key experimental: 202603
Intervalo TX:             300 ms
Puerto Alice:             UDP 42001
Puerto Bob:               UDP 42002
Destino:                  255.255.255.255 broadcast
Serial/telemetría:        115200 baud
```

## Resultado esperado

Durante una sesión sana se observan líneas como:

```text
TEL,0,3.300,A-->B,312,Info,Alice
RX,Bob,0,312,'A',...
```

El capturador termina distinguiendo:

```text
CAPTURA: PASS|FAIL
SESIÓN: PASS|FAIL
```

`CAPTURA: PASS` significa que se obtuvieron datos de ambas direcciones. `SESIÓN: PASS` requiere además no haber detectado errores de runtime.
