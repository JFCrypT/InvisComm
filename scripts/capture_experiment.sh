#!/usr/bin/env bash

set -u

PROJECT_ROOT="/home/jfcrypt/Documents/Proyectos/InvisComm"
OUTPUT_FILE="/home/jfcrypt/Downloads/salida.txt"

cd "${PROJECT_ROOT}" || {
    echo "ERROR: no se pudo abrir el proyecto"
    return 1 2>/dev/null || true
}

source .venv-micropython/bin/activate

TRANSPORT="${1:-}"
DURATION="${2:-60}"

if [ -z "${TRANSPORT}" ]; then
    echo "Uso:"
    echo "bash scripts/capture_experiment.sh uart 60"
    echo "bash scripts/capture_experiment.sh udp 60"
    echo "bash scripts/capture_experiment.sh lora 60"
    return 1 2>/dev/null || true
fi

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
EXPERIMENT_DIR="telemetry/${TRANSPORT}_${TIMESTAMP}"

mkdir -p "${EXPERIMENT_DIR}"

run_capture() {
    echo "========================================"
    echo "CAPTURA INVISCOMM"
    echo "========================================"
    echo "Transporte: ${TRANSPORT}"
    echo "Duración: ${DURATION} segundos"
    echo "Directorio: ${EXPERIMENT_DIR}"
    echo

    python host/capture_telemetry.py \
        --port-a /dev/ttyUSB0 \
        --port-b /dev/ttyUSB1 \
        --baudrate 115200 \
        --duration "${DURATION}" \
        --transport "${TRANSPORT}" \
        --output "${EXPERIMENT_DIR}/telemetria_extendida.csv" \
        --raw-log "${EXPERIMENT_DIR}/serial_raw.log"

    CAPTURE_STATUS=$?

    python host/normalize_telemetry.py \
        "${EXPERIMENT_DIR}/telemetria_extendida.csv" \
        "${EXPERIMENT_DIR}/telemetria.csv"

    NORMALIZE_STATUS=$?

    echo
    echo "========================================"
    echo "RESUMEN"
    echo "========================================"
    echo "Captura: ${CAPTURE_STATUS}"
    echo "Normalización: ${NORMALIZE_STATUS}"
    echo "CSV extendido:"
    echo "${EXPERIMENT_DIR}/telemetria_extendida.csv"
    echo "CSV compatible:"
    echo "${EXPERIMENT_DIR}/telemetria.csv"

    if [ "${CAPTURE_STATUS}" -eq 0 ] \
        && [ "${NORMALIZE_STATUS}" -eq 0 ]; then
        echo "RESULTADO GENERAL: PASS"
    else
        echo "RESULTADO GENERAL: FAIL"
    fi

    echo
    echo "La terminal permanece abierta."
}

run_capture 2>&1 | tee "${OUTPUT_FILE}"
