# InvisComm

Implementación experimental y porteo de **InvisComm** a plataformas embebidas para evaluar el comportamiento del canal sobre distintos medios y transportes de comunicación.

Actualmente el proyecto incluye dos familias de implementación:

- **ESP32 + MicroPython**
  - **UDP sobre Wi-Fi**, como transporte IP inalámbrico.
  - **UART**, como línea base cableada y determinística.
  - **LoRa**, mediante módulos Ra-02/SX1278.
- **Arduino Uno + C++/Arduino Framework**
  - **UDP sobre Ethernet**, mediante Ethernet Shield compatible con la biblioteca `Ethernet`.

El núcleo de InvisComm se mantiene desacoplado del transporte. Alice y Bob mantienen motores separados de transmisión y recepción, generan tráfico `Info` y `Noise`, emiten telemetría por USB y permiten analizar experimentalmente el comportamiento del canal sobre hardware real.

> [!IMPORTANT]
> El port para ESP32 conserva la lógica funcional de InvisComm, pero sustituye `random.Random` de CPython por un PRNG determinístico basado en SHA-256. Por ello, las coordenadas concretas no tienen por qué coincidir con las de la notebook original, aunque Alice y Bob sí generan secuencias idénticas entre sí cuando parten del mismo estado.
>
> La implementación para Arduino Uno fue portada a C++ con restricciones de memoria propias del ATmega328P y conserva el mismo esquema experimental: motores independientes, coordenadas del espacio virtual, tramas, telemetría y transporte UDP sin agregar mecanismos de confiabilidad ajenos al protocolo.

---

## Contenido

- [1. Requisitos](#1-requisitos)
- [2. Estructura del proyecto](#2-estructura-del-proyecto)
- [3. Preparación del entorno ESP32](#3-preparación-del-entorno-esp32)
- [4. Comandos básicos para ESP32](#4-comandos-básicos-para-esp32)
- [5. Instalación de MicroPython](#5-instalación-de-micropython)
- [6. Generación y validación del código ESP32](#6-generación-y-validación-del-código-esp32)
- [7. Asignación de puertos USB](#7-asignación-de-puertos-usb)
- [8. Ejecución UDP sobre Wi-Fi](#8-ejecución-udp-sobre-wi-fi)
- [9. Ejecución UART](#9-ejecución-uart)
- [10. Ejecución LoRa](#10-ejecución-lora)
- [11. Arduino Uno + UDP sobre Ethernet](#11-arduino-uno--udp-sobre-ethernet)
- [12. Telemetría](#12-telemetría)
- [13. Análisis con la notebook](#13-análisis-con-la-notebook)
- [14. Comandos PlatformIO](#14-comandos-platformio)
- [15. Solución de problemas](#15-solución-de-problemas)
- [16. Estado experimental](#16-estado-experimental)
- [17. Flujo rápido](#17-flujo-rápido)
- [18. Autores](#18-autores)

---

## 1. Requisitos

### Hardware

#### ESP32

- 2 × ESP32 genérico con interfaz CP2102 USB-UART.
- 2 × cables USB de datos.
- Para UART:
  - 3 × cables Dupont hembra-hembra.
- Para LoRa:
  - 2 × módulos Ra-02/SX1278.
  - 2 × antenas compatibles con la frecuencia de los módulos.
  - cables Dupont o protoboard.
- Red Wi-Fi local para la variante UDP.

#### Arduino Ethernet

- 2 × Arduino Uno compatibles con ATmega328P.
- 2 × Ethernet Shield compatibles con la biblioteca `Ethernet`.
- 2 × cables USB de datos.
- 2 × cables Ethernet.
- Router o switch Ethernet con DHCP disponible.

### Software

- Linux.
- Python 3.
- `venv`.
- `esptool`.
- `mpremote`.
- `pyserial`.
- PlatformIO CLI.
- VS Code, opcional.
- Jupyter Notebook o JupyterLab para ejecutar `InvisComm_02_Analisis.ipynb`.
- Para el análisis:
  - `pandas`.
  - `numpy`.
  - `matplotlib`.
  - `scipy`.
  - otras dependencias que requiera la notebook original.

---

## 2. Estructura del proyecto

Ruta usada durante el desarrollo:

```text
~/Documents/Proyectos/InvisComm
```

Estructura principal:

```text
InvisComm/
├── arduino_ethernet/
│   ├── host/
│   │   └── run_ethernet_experiment.py
│   ├── include/
│   ├── scripts/
│   │   └── validate.sh
│   ├── src/
│   │   ├── inviscomm/
│   │   ├── transports/
│   │   └── main.cpp
│   ├── telemetry/
│   └── platformio.ini
├── firmware/
│   └── ESP32_GENERIC-20260406-v1.28.0.bin
├── host/
│   ├── capture_telemetry.py
│   ├── normalize_telemetry.py
│   ├── prepare_analysis.py
│   ├── run_experiment.py
│   └── run_udp_experiment.py
├── micropython/
│   ├── common/
│   │   ├── app_bootstrap.py
│   │   ├── app_config.py
│   │   ├── deterministic_prng.py
│   │   ├── experiment_defaults.py
│   │   ├── frame.py
│   │   ├── inviscomm_engine.py
│   │   ├── node_runtime.py
│   │   ├── session_control.py
│   │   ├── telemetry.py
│   │   ├── usb_session_control.py
│   │   ├── wifi_manager.py
│   │   └── transports/
│   │       ├── base.py
│   │       ├── factory.py
│   │       ├── uart_transport.py
│   │       ├── udp_transport.py
│   │       ├── sx127x.py
│   │       └── lora_transport.py
│   ├── configs/
│   │   ├── udp/{alice,bob}/node_config.py
│   │   ├── uart/{alice,bob}/node_config.py
│   │   └── lora/{alice,bob}/node_config.py
│   ├── main.py
│   ├── node_a/
│   ├── node_b/
│   ├── secrets/
│   │   └── wifi_secrets.py
│   └── tests/
├── scripts/
│   ├── 03_create_transports.sh
│   ├── 04_create_node_application.sh
│   ├── 05_create_telemetry_capture.sh
│   ├── 06_prepare_udp_experiment.sh
│   ├── 07_udp_synchronized_experiment.sh
│   ├── 08_complete_codebase.sh
│   ├── capture_experiment.sh
│   ├── deploy_transport.sh
│   └── run_experiment.sh
├── telemetry/
├── platformio.ini
└── README.md
```

Los scripts `03` a `07` documentan la construcción incremental de la variante ESP32/MicroPython. Para una instalación actual del código ESP32, el punto de entrada principal es:

```bash
bash scripts/08_complete_codebase.sh
```

La implementación Arduino Uno/Ethernet se mantiene aislada dentro de:

```text
arduino_ethernet/
```

y se compila con su propio `platformio.ini`.

---

## 3. Preparación del entorno ESP32

Entrar al proyecto:

```bash
cd ~/Documents/Proyectos/InvisComm
```

Crear un entorno virtual nuevo:

```bash
python3 -m venv .venv-micropython
source .venv-micropython/bin/activate
```

Actualizar `pip` e instalar herramientas:

```bash
python -m pip install --upgrade pip
python -m pip install esptool mpremote pyserial
```

Para ejecutar la notebook de análisis desde el mismo entorno:

```bash
python -m pip install pandas numpy matplotlib scipy jupyter ipykernel
```

Verificar:

```bash
which python
which mpremote
python -m esptool version
mpremote --version
```

Las rutas deberían comenzar con:

```text
~/Documents/Proyectos/InvisComm/.venv-micropython/bin/
```

Activar el entorno en una sesión posterior:

```bash
cd ~/Documents/Proyectos/InvisComm
source .venv-micropython/bin/activate
```

Salir del entorno:

```bash
deactivate
```

### Permisos del puerto serie

Agregar el usuario al grupo `dialout`:

```bash
sudo usermod -aG dialout "$USER"
```

Cerrar sesión y volver a entrar para que el cambio tenga efecto.

---

## 4. Comandos básicos para ESP32

### Listar dispositivos serie

Con PlatformIO:

```bash
pio device list
```

Con el sistema:

```bash
ls -l /dev/ttyUSB*
ls -l /dev/serial/by-id/
```

Ver identificadores USB:

```bash
udevadm info --query=property --name=/dev/ttyUSB0
udevadm info --query=property --name=/dev/ttyUSB1
```

Durante el desarrollo se observó una asignación equivalente a:

```text
/dev/ttyUSB0 → Alice
/dev/ttyUSB1 → Bob
```

La asignación puede cambiar al desconectar o reiniciar el equipo. Verificarla antes de cada experimento.

### Abrir el REPL de MicroPython

Alice:

```bash
mpremote connect /dev/ttyUSB0 repl
```

Bob:

```bash
mpremote connect /dev/ttyUSB1 repl
```

Reinicio suave dentro del REPL:

```text
Ctrl+D
```

Interrumpir el programa y volver a `>>>`:

```text
Ctrl+C
```

Salir de `mpremote repl`:

```text
Ctrl+X
```

En algunos entornos VS Code captura `Ctrl+]`; por eso se recomienda `Ctrl+X` o cerrar la terminal con el icono de papelera.

### Reiniciar una placa

```bash
mpremote connect /dev/ttyUSB0 reset
mpremote connect /dev/ttyUSB1 reset
```

### Ejecutar un archivo temporalmente

```bash
mpremote connect /dev/ttyUSB0 run micropython/tests/test_engine.py
```

### Copiar un archivo al ESP32

```bash
mpremote connect /dev/ttyUSB0 fs cp archivo.py :archivo.py
```

### Listar archivos del ESP32

```bash
mpremote connect /dev/ttyUSB0 fs ls :
mpremote connect /dev/ttyUSB0 fs ls :common
mpremote connect /dev/ttyUSB0 fs ls :common/transports
```

### Eliminar un archivo del ESP32

```bash
mpremote connect /dev/ttyUSB0 fs rm :main.py
```

### Ejecutar código directo

```bash
mpremote connect /dev/ttyUSB0 exec "import os; print(os.listdir())"
```

### Ver estado Wi-Fi

```bash
mpremote connect /dev/ttyUSB0 exec \
'import network; w=network.WLAN(network.STA_IF); print(w.isconnected()); print(w.ifconfig())'
```

```bash
mpremote connect /dev/ttyUSB1 exec \
'import network; w=network.WLAN(network.STA_IF); print(w.isconnected()); print(w.ifconfig())'
```

---

## 5. Instalación de MicroPython

Firmware usado:

```text
firmware/ESP32_GENERIC-20260406-v1.28.0.bin
```

> [!WARNING]
> Los siguientes comandos borran completamente el firmware anterior de la placa.

### Alice

Borrar la flash:

```bash
python -m esptool \
  --chip esp32 \
  --port /dev/ttyUSB0 \
  erase-flash
```

Grabar MicroPython:

```bash
python -m esptool \
  --chip esp32 \
  --port /dev/ttyUSB0 \
  --baud 460800 \
  write-flash \
  0x1000 \
  firmware/ESP32_GENERIC-20260406-v1.28.0.bin
```

Verificar:

```bash
mpremote connect /dev/ttyUSB0 repl
```

Salida esperada:

```text
MicroPython v1.28.0 on 2026-04-06; Generic ESP32 module with ESP32
Type "help()" for more information.
>>>
```

### Bob

```bash
python -m esptool \
  --chip esp32 \
  --port /dev/ttyUSB1 \
  erase-flash
```

```bash
python -m esptool \
  --chip esp32 \
  --port /dev/ttyUSB1 \
  --baud 460800 \
  write-flash \
  0x1000 \
  firmware/ESP32_GENERIC-20260406-v1.28.0.bin
```

```bash
mpremote connect /dev/ttyUSB1 repl
```

Si `esptool` queda en `Connecting...`, mantener presionado `BOOT`, ejecutar el comando y soltarlo cuando se detecte el chip.

---

## 6. Generación y validación del código ESP32

Generar la versión completa de la base de código:

```bash
cd ~/Documents/Proyectos/InvisComm
source .venv-micropython/bin/activate

bash scripts/08_complete_codebase.sh \
  2>&1 | tee ~/Downloads/salida.txt
```

Resultado esperado:

```text
Sintaxis: 0
RESULTADO GENERAL: PASS
Código completo generado.
No se activó ningún transporte físico.
```

### Validaciones incrementales disponibles

Transportes:

```bash
bash scripts/03_create_transports.sh \
  2>&1 | tee ~/Downloads/salida.txt
```

Aplicación Alice/Bob:

```bash
bash scripts/04_create_node_application.sh \
  2>&1 | tee ~/Downloads/salida.txt
```

Captura de telemetría:

```bash
bash scripts/05_create_telemetry_capture.sh \
  2>&1 | tee ~/Downloads/salida.txt
```

Prueba directa del motor:

```bash
mpremote connect /dev/ttyUSB0 run micropython/tests/test_engine.py
mpremote connect /dev/ttyUSB1 run micropython/tests/test_engine.py
```

Prueba de trama, CRC y loopback:

```bash
mpremote connect /dev/ttyUSB0 run micropython/tests/test_frame_transport.py
mpremote connect /dev/ttyUSB1 run micropython/tests/test_frame_transport.py
```

Prueba bidireccional simulada:

```bash
mpremote connect /dev/ttyUSB0 run micropython/tests/test_bidirectional_nodes.py
mpremote connect /dev/ttyUSB1 run micropython/tests/test_bidirectional_nodes.py
```

---

## 7. Asignación de puertos USB

Antes de desplegar o ejecutar un experimento:

```bash
pio device list
```

La configuración por defecto de los scripts ESP32 es:

```text
Alice → /dev/ttyUSB0
Bob   → /dev/ttyUSB1
```

Si cambiaron, editar:

```text
scripts/deploy_transport.sh
scripts/run_experiment.sh
```

O ejecutar directamente `host/run_experiment.py` indicando:

```bash
python -u host/run_experiment.py \
  --transport udp \
  --port-a /dev/ttyUSB1 \
  --port-b /dev/ttyUSB0 \
  --duration 60 \
  --output-dir telemetry/udp_prueba
```

Los Arduino Uno con conversor CH340 también pueden aparecer como `/dev/ttyUSB0` y `/dev/ttyUSB1`; por lo tanto, verificar siempre qué dispositivos están conectados antes de cargar firmware o iniciar una captura.

---

## 8. Ejecución UDP sobre Wi-Fi

### 8.1 Configurar las credenciales

El archivo debe existir en:

```text
micropython/secrets/wifi_secrets.py
```

Contenido:

```python
WIFI_SSID = "NOMBRE_DE_RED"
WIFI_PASSWORD = "CONTRASEÑA"
```

No versionar este archivo. Debe estar incluido en `.gitignore`:

```text
micropython/secrets/wifi_secrets.py
```

También puede recrearse mediante:

```bash
bash scripts/06_prepare_udp_experiment.sh
```

### 8.2 Desplegar UDP

```bash
cd ~/Documents/Proyectos/InvisComm
source .venv-micropython/bin/activate

bash scripts/deploy_transport.sh udp \
  2>&1 | tee ~/Downloads/salida.txt
```

El despliegue copia la configuración UDP de Alice y Bob, instala `main.py` y reinicia ambas placas.

### 8.3 Iniciar el experimento

Ejecutar primero el coordinador:

```bash
bash scripts/run_experiment.sh udp 60
```

Debe mostrar:

```text
Esperando READY de Alice y Bob...
```

En ese momento, presionar físicamente una vez el botón `EN` de Alice y una vez el botón `EN` de Bob.

Los ESP32 imprimen `READY` una sola vez después del arranque. Por eso el coordinador debe estar escuchando antes de reiniciarlos.

Salida esperada:

```text
READY: Alice
READY: Bob
START enviado: ...
Registros: ...
```

### 8.4 Uso directo del ejecutor UDP sincronizado

```bash
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"

python -u host/run_udp_experiment.py \
  --duration 60 \
  --broadcast 192.168.100.255 \
  --output-dir "telemetry/udp_${TIMESTAMP}" \
  2>&1 | tee ~/Downloads/salida.txt
```

Modificar la dirección de broadcast si la red no es `192.168.100.0/24`.

Ejemplos:

```text
192.168.1.0/24   → 192.168.1.255
192.168.0.0/24   → 192.168.0.255
192.168.100.0/24 → 192.168.100.255
```

### 8.5 Interpretación del resultado UDP

El capturador separa:

```text
CAPTURA: PASS|FAIL
SESIÓN: PASS|FAIL
```

- `CAPTURA: PASS` significa que se generó el CSV con ambas direcciones y tramas de información.
- `SESIÓN: PASS` significa además que no aparecieron errores de runtime ni tracebacks.

UDP no es orientado a conexión y no garantiza entrega ni orden. Una pérdida puede desincronizar los motores de InvisComm. Ese comportamiento forma parte del resultado experimental y debe conservarse en `serial_raw.log`.

---

## 9. Ejecución UART

### 9.1 Cableado

Con las placas apagadas:

| ESP32 Alice | ESP32 Bob | Función |
|---|---|---|
| GPIO 17 | GPIO 16 | Alice TX → Bob RX |
| GPIO 16 | GPIO 17 | Alice RX ← Bob TX |
| GND | GND | Referencia común |

Esquema:

```text
Alice GPIO17 (TX2) ─────> Bob GPIO16 (RX2)
Alice GPIO16 (RX2) <───── Bob GPIO17 (TX2)
Alice GND          ────── Bob GND
```

No unir `3V3`, `VIN` ni `5V`. Cada ESP32 se alimenta por su propio USB.

### 9.2 Desplegar UART

```bash
cd ~/Documents/Proyectos/InvisComm
source .venv-micropython/bin/activate

bash scripts/deploy_transport.sh uart \
  2>&1 | tee ~/Downloads/salida.txt
```

### 9.3 Ejecutar UART

```bash
bash scripts/run_experiment.sh uart 60
```

Cuando aparezca:

```text
Esperando READY de Alice y Bob...
```

presionar `EN` en ambas placas.

El control de sesión se realiza por USB. El tráfico InvisComm real circula por UART2, GPIO 16/17.

Salida esperada:

```text
READY: Alice
READY: Bob
START enviado: ...
CAPTURA: PASS
SESIÓN: PASS
```

---

## 10. Ejecución LoRa

### 10.1 Advertencias

> [!CAUTION]
> No transmitir con un módulo LoRa sin antena conectada. Puede dañarse la etapa de RF.

> [!IMPORTANT]
> Confirmar la frecuencia impresa en el módulo. La configuración actual usa `433000000` Hz.

### 10.2 Cableado Ra-02/SX1278

Configuración usada por el código:

| Ra-02/SX1278 | ESP32 | Función |
|---|---:|---|
| VCC | 3V3 | Alimentación 3,3 V |
| GND | GND | Masa |
| SCK | GPIO 18 | SPI clock |
| MISO | GPIO 19 | SPI MISO |
| MOSI | GPIO 23 | SPI MOSI |
| NSS/CS | GPIO 5 | Chip select |
| RESET | GPIO 14 | Reset del radio |
| DIO0 | GPIO 26 | Interrupción RX/TX |

La misma conexión se repite en Alice y Bob.

No alimentar el Ra-02 con 5 V.

### 10.3 Parámetros LoRa actuales

```text
Frecuencia:       433 MHz
Potencia TX:      10 dBm
Spreading factor: 7
Bandwidth:        125 kHz
Coding rate:      4/5
Preamble:         8 símbolos
Sync word:        0x42
CRC de radio:     habilitado
```

Alice transmite inicialmente a los 500 ms y Bob a los 1250 ms para reducir colisiones.

### 10.4 Desplegar LoRa

Con los módulos ya conectados y las antenas instaladas:

```bash
cd ~/Documents/Proyectos/InvisComm
source .venv-micropython/bin/activate

bash scripts/deploy_transport.sh lora \
  2>&1 | tee ~/Downloads/salida.txt
```

### 10.5 Ejecutar LoRa

```bash
bash scripts/run_experiment.sh lora 120
```

Cuando aparezca:

```text
Esperando READY de Alice y Bob...
```

presionar `EN` en ambas placas.

La captura LoRa dura normalmente más que UART o UDP porque el intervalo configurado es de 1500 ms.

La salida `RX` incluye metadatos del radio:

```text
RX,node,position,coordinate,character,decode_us,rssi,snr,crc_valid
```

Estos datos quedan preservados en `serial_raw.log`.

---

## 11. Arduino Uno + UDP sobre Ethernet

La variante Ethernet utiliza dos Arduino Uno, cada uno con su Ethernet Shield, ejecutando una implementación C++ específica para ATmega328P.

La arquitectura experimental es:

```text
Arduino Uno Alice + Ethernet Shield ── UDP/Ethernet ── Arduino Uno Bob + Ethernet Shield
```

No se agregan ACK, retransmisiones ni una capa de confiabilidad propia. La prueba conserva UDP como protocolo no orientado a conexión para poder comparar su comportamiento sobre Ethernet con la variante UDP/Wi-Fi.

### 11.1 Entrar al proyecto

```bash
cd ~/Documents/Proyectos/InvisComm/arduino_ethernet
```

### 11.2 Compilar ambos nodos

```bash
pio run
```

Entornos disponibles:

```text
uno_alice
uno_bob
```

También puede utilizarse la validación integral:

```bash
bash scripts/validate.sh
```

La salida se guarda en:

```text
~/Downloads/salida.txt
```

### 11.3 Verificar los puertos USB

```bash
pio device list
```

Los Arduino Uno compatibles con CH340 pueden aparecer como:

```text
/dev/ttyUSB0
/dev/ttyUSB1
```

### 11.4 Cargar Alice

Ejemplo:

```bash
pio run -e uno_alice -t upload --upload-port /dev/ttyUSB0
```

El resultado esperado incluye:

```text
avrdude: ... bytes of flash written
avrdude: ... bytes of flash verified
SUCCESS
```

### 11.5 Cargar Bob

Ejemplo:

```bash
pio run -e uno_bob -t upload --upload-port /dev/ttyUSB1
```

### 11.6 Verificar Ethernet y DHCP

Alice:

```bash
pio device monitor -p /dev/ttyUSB0 -b 115200
```

Salida esperada:

```text
========================================
InvisComm Arduino UNO Ethernet
========================================
Nodo: Alice
Transporte: UDP/Ethernet
Inicializando Ethernet por DHCP...
Ethernet conectado - IP: ...
READY,Alice,USB,...
```

Bob:

```bash
pio device monitor -p /dev/ttyUSB1 -b 115200
```

Salida esperada:

```text
========================================
InvisComm Arduino UNO Ethernet
========================================
Nodo: Bob
Transporte: UDP/Ethernet
Inicializando Ethernet por DHCP...
Ethernet conectado - IP: ...
READY,Bob,USB,...
```

Cerrar los monitores antes de iniciar la captura, ya que el coordinador necesita abrir ambos puertos serie.

### 11.7 Preparar Python para la captura

Desde `arduino_ethernet/`:

```bash
python3 -m venv .venv
source .venv/bin/activate
python -m pip install --upgrade pip
python -m pip install pyserial
```

En sesiones posteriores:

```bash
source .venv/bin/activate
```

### 11.8 Ejecutar el experimento Ethernet

```bash
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"

python -u host/run_ethernet_experiment.py \
  --port-a /dev/ttyUSB0 \
  --port-b /dev/ttyUSB1 \
  --duration 60 \
  --output-dir "telemetry/ethernet_${TIMESTAMP}"
```

El coordinador espera:

```text
READY: Alice
READY: Bob
```

y luego inicia automáticamente la sesión sincronizada.

### 11.9 Resultado esperado

```text
CAPTURA: PASS
SESIÓN: PASS
```

`CAPTURA: PASS` valida que se obtuvo telemetría de ambos sentidos.

`SESIÓN: PASS` indica además que la ejecución no registró errores de runtime o desincronización durante la ventana observada.

### 11.10 Recursos del Arduino Uno

La compilación validada utilizó aproximadamente:

```text
Alice:
RAM:   ~37 %
Flash: ~66 %

Bob:
RAM:   ~37 %
Flash: ~66 %
```

Esto deja margen operativo dentro de los 2 KiB de SRAM y 32 KiB de flash del ATmega328P.

---

## 12. Telemetría

Cada experimento ESP32 crea una carpeta:

```text
telemetry/<transporte>_YYYYMMDD_HHMMSS/
```

Los experimentos Arduino Ethernet crean:

```text
arduino_ethernet/telemetry/ethernet_YYYYMMDD_HHMMSS/
```

Ejemplo:

```text
telemetry/lora_20260807_030000/
├── serial_raw.log
├── telemetria_extendida.csv
└── telemetria.csv
```

### `telemetria.csv`

Formato compatible con la notebook original:

```text
timestamp,direction,encrypted_coord,type
```

### `telemetria_extendida.csv`

Incluye información auxiliar:

```text
timestamp
source/direction
encrypted_coord
type
node
sequence
device_timestamp
host_timestamp
port
transport
```

### `serial_raw.log`

Conserva toda la evidencia disponible, incluyendo:

- mensajes de inicio;
- `READY` y `START`;
- líneas `TEL`;
- métricas `PERF` cuando están disponibles;
- recepción `RX`;
- RSSI/SNR para LoRa;
- errores;
- tracebacks o mensajes de diagnóstico.

### Buscar el último CSV ESP32

```bash
find ~/Documents/Proyectos/InvisComm/telemetry \
  -type f -name "telemetria.csv" \
  -printf '%T@ %p\n' \
  | sort -nr \
  | head -n 1
```

### Buscar el último CSV Ethernet

```bash
find ~/Documents/Proyectos/InvisComm/arduino_ethernet/telemetry \
  -type f -name "telemetria.csv" \
  -printf '%T@ %p\n' \
  | sort -nr \
  | head -n 1
```

> [!IMPORTANT]
> Las carpetas de telemetría contienen resultados experimentales y se excluyen del repositorio mediante `.gitignore`.

---

## 13. Análisis con la notebook

La notebook consume:

```text
telemetria.csv
```

con estas columnas:

```text
timestamp,direction,encrypted_coord,type
```

El mismo formato se utiliza para:

- ESP32 + UDP/Wi-Fi.
- ESP32 + UART.
- ESP32 + LoRa.
- Arduino Uno + UDP/Ethernet.

Esto permite utilizar una única metodología de análisis para todas las variantes.

### Preparar una captura ESP32

```bash
python host/prepare_analysis.py \
  --experiment-dir "telemetry/udp_YYYYMMDD_HHMMSS" \
  --analysis-dir "/ruta/de/InvisComm_02_Analisis"
```

El script:

1. respalda el `telemetria.csv` anterior;
2. copia el nuevo CSV como `telemetria.csv`;
3. conserva `telemetria_extendida.csv` y `serial_raw.log` dentro de `evidence/`.

### Analizar una captura Ethernet

Puede copiarse directamente:

```bash
cp \
  arduino_ethernet/telemetry/ethernet_YYYYMMDD_HHMMSS/telemetria.csv \
  /ruta/de/InvisComm_02_Analisis/telemetria.csv
```

Después, abrir:

```text
InvisComm_02_Analisis.ipynb
```

y ejecutar todas las celdas:

```text
Kernel → Restart Kernel and Run All Cells
```

El análisis original permite estudiar, entre otras propiedades:

- indistinguibilidad estadística entre tráfico `Info` y `Noise`;
- entropía del canal;
- neutralidad temporal entre sentidos;
- comportamiento de las coordenadas emitidas.

> [!NOTE]
> La notebook analiza principalmente la telemetría emitida. Para evaluar pérdida, desorden, recepción o desincronización de una sesión debe revisarse también `serial_raw.log`.

---

## 14. Comandos PlatformIO

PlatformIO se utiliza para compilar y cargar la implementación Arduino Uno/Ethernet y también fue utilizado durante la validación inicial de los ESP32.

### Ver versión

```bash
pio --version
```

### Listar dispositivos

```bash
pio device list
```

### Compilar todos los entornos del proyecto actual

```bash
pio run
```

### Compilar un entorno específico

```bash
pio run -e NOMBRE_ENTORNO
```

Ejemplos disponibles:

```text
esp32_a
esp32_b
uno_alice
uno_bob
```

### Compilar y subir firmware

```bash
pio run -e NOMBRE_ENTORNO -t upload
```

### Especificar puerto manualmente

```bash
pio run -e NOMBRE_ENTORNO -t upload --upload-port /dev/ttyUSB0
```

### Abrir monitor serie

```bash
pio device monitor -p /dev/ttyUSB0 -b 115200
```

### Limpiar la compilación

```bash
pio run -t clean
```

### Ver información detallada

```bash
pio run -v
```

### Inspeccionar el proyecto y uso de recursos

```bash
pio project inspect
```

> [!WARNING]
> En un ESP32 configurado con MicroPython, `pio run -t upload` puede sobrescribir MicroPython con firmware nativo. Después será necesario volver a grabar el archivo `.bin` de MicroPython mediante `esptool`.

---

## 15. Solución de problemas

### `python` o `mpremote` no existen después de activar el entorno

El entorno virtual pudo haber sido movido y conservar rutas antiguas. Recrearlo:

```bash
deactivate 2>/dev/null || true
rm -rf .venv-micropython

python3 -m venv .venv-micropython
source .venv-micropython/bin/activate

python -m pip install --upgrade pip
python -m pip install esptool mpremote pyserial
```

### Puerto ocupado

```bash
ps aux | grep -E "mpremote|pio device monitor" | grep -v grep
```

Cerrar lectores serie:

```bash
pkill -f "mpremote.*repl" 2>/dev/null || true
pkill -f "pio device monitor" 2>/dev/null || true
```

### El coordinador ESP32 no recibe `READY`

`READY` se imprime una sola vez durante el arranque.

Secuencia correcta:

1. ejecutar `scripts/run_experiment.sh`;
2. esperar `Esperando READY...`;
3. presionar `EN` en Alice;
4. presionar `EN` en Bob;
5. esperar `READY: Alice` y `READY: Bob`.

No abrir `mpremote repl` mientras el coordinador usa los puertos.

### El coordinador parece no mostrar nada

Ejecutar Python sin búfer:

```bash
python -u host/run_experiment.py ...
```

Los scripts finales ya utilizan `python -u`.

### Caracteres ilegibles en el monitor ESP32

Pueden aparecer durante reinicios o por datos acumulados. Verificar que el baudrate sea `115200` y reiniciar suavemente con `Ctrl+D`.

### `ImportError: no module named common.transports.base`

Verificar que `base.py` exista tanto en la computadora como en el ESP32:

```bash
ls -l micropython/common/transports/base.py
mpremote connect /dev/ttyUSB0 fs ls :common/transports
```

### LoRa no detectado

El controlador verifica `REG_VERSION`. Si aparece:

```text
SX127x no detectado
```

revisar:

- alimentación a 3,3 V;
- GND común;
- SCK, MISO y MOSI;
- CS/NSS;
- RESET;
- módulo y frecuencia correctos.

### Pérdida o desorden

Ejemplo:

```text
NodeRuntimeError: Pérdida o desorden: recibida=21, esperada=20, faltantes=1
```

La implementación actual detecta la pérdida y detiene el runtime para evitar avanzar con estados incorrectos. En UDP o LoRa, este comportamiento forma parte del análisis experimental del canal.

### El CSV indica `PASS` pero un nodo se detuvo

Revisar siempre:

```text
serial_raw.log
```

El resultado final puede separar:

```text
CAPTURA: PASS|FAIL
SESIÓN: PASS|FAIL
```

### Arduino Uno: error `programmer is out of sync`

Si la escritura o verificación mediante `avrdude` falla:

1. verificar que ningún monitor serie esté usando el puerto;
2. desconectar y reconectar el USB del Arduino;
3. comprobar nuevamente el puerto con `pio device list`;
4. repetir la carga.

Ejemplo:

```bash
pio run -e uno_bob -t upload --upload-port /dev/ttyUSB1
```

La carga queda validada cuando `avrdude` informa que la flash fue escrita y verificada y PlatformIO termina con `SUCCESS`.

### Arduino Uno: Ethernet no obtiene IP

Verificar:

- Ethernet Shield correctamente insertado;
- cable Ethernet;
- enlace físico en el switch/router;
- DHCP habilitado;
- alimentación estable;
- que el shield sea compatible con la biblioteca `Ethernet`.

La validación práctica es que el monitor serie muestre:

```text
Ethernet conectado - IP: ...
```

El color exacto de los LED del shield puede variar entre revisiones o fabricantes; la obtención de una IP y la comunicación real son criterios más útiles que el color del indicador.

---

## 16. Estado experimental

Validado hasta el momento:

### ESP32

- MicroPython 1.28.0 en ambos ESP32.
- Núcleo InvisComm en ambos dispositivos.
- PRNG determinístico basado en SHA-256.
- Tramas binarias de 12 bytes.
- CRC-16/CCITT-FALSE.
- motores TX/RX sincronizados en pruebas locales.
- transporte loopback.
- comunicación bidireccional simulada.
- captura simultánea de telemetría.
- ejecución real UDP/Wi-Fi.
- análisis estadístico de una captura UDP/Wi-Fi.
- detección experimental de pérdida y desincronización sobre UDP/Wi-Fi.

### Arduino Uno + Ethernet

- Porte C++ para ATmega328P.
- compilación de `uno_alice`: `SUCCESS`.
- compilación de `uno_bob`: `SUCCESS`.
- carga y verificación de firmware en Alice: `SUCCESS`.
- carga y verificación de firmware en Bob: `SUCCESS`.
- inicialización Ethernet por DHCP en Alice.
- inicialización Ethernet por DHCP en Bob.
- dirección IP obtenida por ambos nodos.
- memoria de programa y SRAM dentro de los límites del Arduino Uno.

Pendiente de validación física completa:

- sesión InvisComm UDP/Ethernet entre ambos Arduino Uno;
- generación y análisis de telemetría Ethernet;
- UART entre ambos ESP32;
- LoRa con ambos módulos Ra-02/SX1278;
- análisis comparativo final entre UDP/Wi-Fi, UDP/Ethernet, UART y LoRa.

---

## 17. Flujo rápido

### ESP32 — UDP/Wi-Fi

```bash
cd ~/Documents/Proyectos/InvisComm
source .venv-micropython/bin/activate

bash scripts/deploy_transport.sh udp
bash scripts/run_experiment.sh udp 60
```

Cuando aparezca `Esperando READY...`, presionar `EN` en ambas placas.

### ESP32 — UART

```bash
cd ~/Documents/Proyectos/InvisComm
source .venv-micropython/bin/activate

bash scripts/deploy_transport.sh uart
bash scripts/run_experiment.sh uart 60
```

Cuando aparezca `Esperando READY...`, presionar `EN` en ambas placas.

### ESP32 — LoRa

```bash
cd ~/Documents/Proyectos/InvisComm
source .venv-micropython/bin/activate

bash scripts/deploy_transport.sh lora
bash scripts/run_experiment.sh lora 120
```

Cuando aparezca `Esperando READY...`, presionar `EN` en ambas placas.

### Arduino Uno — UDP/Ethernet

```bash
cd ~/Documents/Proyectos/InvisComm/arduino_ethernet

pio run

pio run -e uno_alice -t upload --upload-port /dev/ttyUSB0
pio run -e uno_bob -t upload --upload-port /dev/ttyUSB1

python3 -m venv .venv
source .venv/bin/activate
python -m pip install pyserial

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"

python -u host/run_ethernet_experiment.py \
  --port-a /dev/ttyUSB0 \
  --port-b /dev/ttyUSB1 \
  --duration 60 \
  --output-dir "telemetry/ethernet_${TIMESTAMP}"
```

### Preparar análisis ESP32

```bash
python host/prepare_analysis.py \
  --experiment-dir "telemetry/<transporte>_YYYYMMDD_HHMMSS" \
  --analysis-dir "/ruta/de/InvisComm_02_Analisis"
```

### Preparar análisis Ethernet

```bash
cp \
  arduino_ethernet/telemetry/ethernet_YYYYMMDD_HHMMSS/telemetria.csv \
  /ruta/de/InvisComm_02_Analisis/telemetria.csv
```

---

## 18. Autores

**Vladyslav Solovei**  
Autor intelectual de InvisComm y de la propuesta conceptual original del canal.

**Jorge Kamlofsky**  
Director del trabajo y responsable de la supervisión académica y técnica del desarrollo experimental.

**José Federico Castro Tramontina**  
Desarrollo y porteo experimental de InvisComm a plataformas embebidas, incluyendo ESP32/MicroPython y Arduino Uno/C++, integración de transportes UDP/Wi-Fi, UDP/Ethernet, UART y LoRa, instrumentación, telemetría y validación experimental.
