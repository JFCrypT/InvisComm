# InvisComm ESP32

Implementación experimental y porteo de **InvisComm** a dos placas ESP32 con MicroPython y tres variantes de transporte:

- **UDP sobre Wi-Fi**, como equivalente IP del prototipo Docker.
- **UART**, como línea base cableada y determinística.
- **LoRa**, mediante módulos Ra-02/SX1278, como transporte inalámbrico principal.

El núcleo de InvisComm es independiente del transporte. Alice y Bob mantienen motores separados de transmisión y recepción, generan tráfico `Info` y `Noise`, emiten telemetría por USB y permiten analizar el comportamiento real del canal sobre hardware.

> [!IMPORTANT]
> El port para ESP32 conserva la lógica funcional de InvisComm, pero sustituye `random.Random` de CPython por un PRNG determinístico basado en SHA-256. Por ello, las coordenadas concretas no tienen por qué coincidir con las de la notebook original, aunque Alice y Bob sí generan secuencias idénticas entre sí cuando parten del mismo estado.

---

## Contenido

- [1. Requisitos](#1-requisitos)
- [2. Estructura del proyecto](#2-estructura-del-proyecto)
- [3. Preparación del entorno](#3-preparación-del-entorno)
- [4. Comandos básicos para ESP32](#4-comandos-básicos-para-esp32)
- [5. Instalación de MicroPython](#5-instalación-de-micropython)
- [6. Generación y validación del código](#6-generación-y-validación-del-código)
- [7. Asignación de puertos USB](#7-asignación-de-puertos-usb)
- [8. Ejecución UDP sobre Wi-Fi](#8-ejecución-udp-sobre-wi-fi)
- [9. Ejecución UART](#9-ejecución-uart)
- [10. Ejecución LoRa](#10-ejecución-lora)
- [11. Telemetría](#11-telemetría)
- [12. Análisis con la notebook](#12-análisis-con-la-notebook)
- [13. Comandos PlatformIO](#13-comandos-platformio)
- [14. Solución de problemas](#14-solución-de-problemas)
- [15. Estado experimental](#15-estado-experimental)

---

## 1. Requisitos

### Hardware

- 2 × ESP32 genérico con interfaz CP2102 USB-UART.
- 2 × cables USB de datos.
- Para UART:
  - 3 × cables Dupont hembra-hembra.
- Para LoRa:
  - 2 × módulos Ra-02/SX1278.
  - 2 × antenas compatibles con la frecuencia de los módulos.
  - cables Dupont o protoboard.
- Red Wi-Fi local para la variante UDP.

### Software

- Linux.
- Python 3.
- `venv`.
- `esptool`.
- `mpremote`.
- `pyserial`.
- PlatformIO CLI, opcional para pruebas nativas y detección de dispositivos.
- VS Code, opcional.
- Jupyter Notebook o JupyterLab para ejecutar `InvisComm_02_Analisis.ipynb`.

---

## 2. Estructura del proyecto

Ruta usada durante el desarrollo:

```text
~/Documents/Proyectos/InvisComm
```

Estructura principal:

```text
InvisComm/
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

Los scripts `03` a `07` documentan la construcción incremental. Para una instalación actual, el punto de entrada principal es:

```bash
bash scripts/08_complete_codebase.sh
```

---

## 3. Preparación del entorno

Entrar al proyecto:

```bash
cd "~/Documents/Proyectos/InvisComm"
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
cd "~/Documents/Proyectos/InvisComm"
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

En el laboratorio se observó:

```text
/dev/ttyUSB0 → Alice → LOCATION=1-2.4
/dev/ttyUSB1 → Bob   → LOCATION=1-2.1
```

Esta asignación puede cambiar al desconectar o reiniciar el equipo. Verificarla antes de cada experimento.

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

## 6. Generación y validación del código

Generar la versión completa de la base de código:

```bash
cd "~/Documents/Proyectos/InvisComm"
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

La configuración por defecto de los scripts es:

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
cd "~/Documents/Proyectos/InvisComm"
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

UDP no garantiza entrega ni orden. Una pérdida puede desincronizar los motores de InvisComm. Ese comportamiento forma parte del resultado experimental y debe conservarse en `serial_raw.log`.

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
cd "~/Documents/Proyectos/InvisComm"
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
cd "~/Documents/Proyectos/InvisComm"
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

## 11. Telemetría

Cada experimento crea una carpeta:

```text
telemetry/<transporte>_YYYYMMDD_HHMMSS/
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

Conserva toda la evidencia:

- mensajes de inicio;
- `READY` y `START`;
- líneas `TEL`;
- métricas `PERF`;
- recepción `RX`;
- RSSI/SNR para LoRa;
- errores;
- tracebacks.

### Buscar el último CSV

```bash
find "~/Documents/Proyectos/InvisComm/telemetry" \
  -type f -name "telemetria.csv" \
  -printf '%T@ %p\n' \
  | sort -nr \
  | head -n 1
```

---

## 12. Análisis con la notebook

La notebook consume:

```text
telemetria.csv
```

con estas columnas:

```text
timestamp,direction,encrypted_coord,type
```

Preparar una captura para el análisis:

```bash
python host/prepare_analysis.py \
  --experiment-dir "telemetry/udp_YYYYMMDD_HHMMSS" \
  --analysis-dir "/ruta/de/InvisComm_02_Analisis"
```

El script:

1. respalda el `telemetria.csv` anterior;
2. copia el nuevo CSV como `telemetria.csv`;
3. conserva `telemetria_extendida.csv` y `serial_raw.log` dentro de `evidence/`.

Después, abrir:

```text
InvisComm_02_Analisis.ipynb
```

Y ejecutar todas las celdas:

```text
Kernel → Restart Kernel and Run All Cells
```

Guardar los resultados de la última celda para el informe experimental.

---

## 13. Comandos PlatformIO

PlatformIO se utilizó inicialmente para validar ambas placas con firmware Arduino/C++. El desarrollo actual usa MicroPython.

### Ver versión

```bash
pio --version
```

### Listar dispositivos

```bash
pio device list
```

### Compilar todos los entornos

```bash
pio run
```

### Compilar un entorno

```bash
pio run -e esp32_a
pio run -e esp32_b
```

### Subir firmware nativo

```bash
pio run -e esp32_a -t upload
pio run -e esp32_b -t upload
```

### Especificar puerto manualmente

```bash
pio run -e esp32_a -t upload --upload-port /dev/ttyUSB0
pio run -e esp32_b -t upload --upload-port /dev/ttyUSB1
```

### Abrir monitor serie

```bash
pio device monitor -p /dev/ttyUSB0 -b 115200
pio device monitor -p /dev/ttyUSB1 -b 115200
```

Salir del monitor:

```text
Ctrl+C
```

> [!WARNING]
> `pio run -t upload` sobrescribe MicroPython con firmware nativo. Después será necesario volver a grabar el archivo `.bin` de MicroPython mediante `esptool`.

---

## 14. Solución de problemas

### `python` o `mpremote` no existen después de activar el entorno

El entorno virtual fue movido y conserva rutas antiguas. Recrearlo:

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

### El coordinador no recibe `READY`

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

### Caracteres ilegibles en el monitor

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

El resultado final separa:

```text
CAPTURA: PASS|FAIL
SESIÓN: PASS|FAIL
```

---

## 15. Estado experimental

Validado hasta el momento:

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
- detección experimental de pérdida y desincronización sobre UDP.

Pendiente de validación física:

- UART entre ambos ESP32.
- LoRa con ambos módulos Ra-02/SX1278.
- análisis comparativo final UDP, UART y LoRa.

---

## Flujo rápido

### UDP

```bash
cd "~/Documents/Proyectos/InvisComm"
source .venv-micropython/bin/activate

bash scripts/deploy_transport.sh udp
bash scripts/run_experiment.sh udp 60
```

Cuando aparezca `Esperando READY...`, presionar `EN` en ambas placas.

### UART

```bash
cd "~/Documents/Proyectos/InvisComm"
source .venv-micropython/bin/activate

bash scripts/deploy_transport.sh uart
bash scripts/run_experiment.sh uart 60
```

Cuando aparezca `Esperando READY...`, presionar `EN` en ambas placas.

### LoRa

```bash
cd "~/Documents/Proyectos/InvisComm"
source .venv-micropython/bin/activate

bash scripts/deploy_transport.sh lora
bash scripts/run_experiment.sh lora 120
```

Cuando aparezca `Esperando READY...`, presionar `EN` en ambas placas.

### Preparar análisis

```bash
python host/prepare_analysis.py \
  --experiment-dir "telemetry/<transporte>_YYYYMMDD_HHMMSS" \
  --analysis-dir "/ruta/de/InvisComm_02_Analisis"
```

---

## 16. Autores

**Vladyslav Solovei**  
Autor intelectual de InvisComm y de la propuesta conceptual original del canal.

**Jorge Kamlofsky**  
Director del trabajo y responsable de la supervisión académica y técnica del desarrollo experimental.

**José Federico Castro Tramontina**  
Desarrollo y porteo de InvisComm a ESP32, implementación en MicroPython, integración de transportes UDP/Wi-Fi, UART y LoRa, instrumentación, telemetría y validación experimental.
