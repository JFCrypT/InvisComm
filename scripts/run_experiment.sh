#!/usr/bin/env bash

set -u

PROJECT_ROOT="/home/jfcrypt/Documents/Proyectos/InvisComm"

TRANSPORT="${1:-}"
DURATION="${2:-60}"

if [ -z "${TRANSPORT}" ]; then
    echo "Uso:"
    echo "bash scripts/run_experiment.sh udp 60"
    echo "bash scripts/run_experiment.sh uart 60"
    echo "bash scripts/run_experiment.sh lora 120"
    return 1 2>/dev/null || true
fi

cd "${PROJECT_ROOT}" || {
    echo "ERROR: no se pudo abrir el proyecto"
    return 1 2>/dev/null || true
}

source .venv-micropython/bin/activate

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
OUTPUT_DIR="telemetry/${TRANSPORT}_${TIMESTAMP}"

COMMAND=(
    python -u host/run_experiment.py
    --transport "${TRANSPORT}"
    --duration "${DURATION}"
    --output-dir "${OUTPUT_DIR}"
)

if [ "${TRANSPORT}" = "udp" ]; then
    COMMAND+=(
        --broadcast 192.168.100.255
    )
fi

"${COMMAND[@]}" \
    2>&1 | tee /home/jfcrypt/Downloads/salida.txt

echo
echo "Directorio del experimento:"
echo "${PROJECT_ROOT}/${OUTPUT_DIR}"
echo
echo "La terminal permanece abierta."
