#!/usr/bin/env bash

set -u

PROJECT_ROOT="/home/jfcrypt/Documents/Proyectos/InvisComm"
MICROPYTHON_DIR="${PROJECT_ROOT}/micropython"
COMMON_DIR="${MICROPYTHON_DIR}/common"
TRANSPORTS_DIR="${COMMON_DIR}/transports"
CONFIGS_DIR="${MICROPYTHON_DIR}/configs"

PORT_A="/dev/ttyUSB0"
PORT_B="/dev/ttyUSB1"

TRANSPORT="${1:-}"

if [ -z "${TRANSPORT}" ]; then
    echo "Uso:"
    echo "bash scripts/deploy_transport.sh udp"
    echo "bash scripts/deploy_transport.sh uart"
    echo "bash scripts/deploy_transport.sh lora"
    return 1 2>/dev/null || true
fi

case "${TRANSPORT}" in
    udp|uart|lora)
        ;;
    *)
        echo "ERROR: transporte inválido"
        return 1 2>/dev/null || true
        ;;
esac

cd "${PROJECT_ROOT}" || {
    echo "ERROR: no se pudo abrir el proyecto"
    return 1 2>/dev/null || true
}

source .venv-micropython/bin/activate

deploy_node() {
    local port="$1"
    local node_role="$2"
    local status=0

    echo
    echo "========================================"
    echo "DESPLIEGUE ${node_role} / ${TRANSPORT}"
    echo "========================================"

    mpremote connect "${port}" exec \
'import os
for path in ("common", "common/transports"):
    try:
        os.mkdir(path)
    except OSError:
        pass' || status=1

    for file in \
        "${COMMON_DIR}/__init__.py" \
        "${COMMON_DIR}/app_config.py" \
        "${COMMON_DIR}/app_bootstrap.py" \
        "${COMMON_DIR}/deterministic_prng.py" \
        "${COMMON_DIR}/experiment_defaults.py" \
        "${COMMON_DIR}/frame.py" \
        "${COMMON_DIR}/inviscomm_engine.py" \
        "${COMMON_DIR}/node_runtime.py" \
        "${COMMON_DIR}/session_control.py" \
        "${COMMON_DIR}/telemetry.py" \
        "${COMMON_DIR}/usb_session_control.py" \
        "${COMMON_DIR}/wifi_manager.py"
    do
        mpremote connect "${port}" fs cp \
            "${file}" \
            ":common/$(basename "${file}")" \
            || status=1
    done

    for file in \
        "${TRANSPORTS_DIR}/__init__.py" \
        "${TRANSPORTS_DIR}/base.py" \
        "${TRANSPORTS_DIR}/factory.py" \
        "${TRANSPORTS_DIR}/uart_transport.py" \
        "${TRANSPORTS_DIR}/udp_transport.py" \
        "${TRANSPORTS_DIR}/sx127x.py" \
        "${TRANSPORTS_DIR}/lora_transport.py"
    do
        mpremote connect "${port}" fs cp \
            "${file}" \
            ":common/transports/$(basename "${file}")" \
            || status=1
    done

    mpremote connect "${port}" fs cp \
        "${CONFIGS_DIR}/${TRANSPORT}/${node_role}/node_config.py" \
        :node_config.py \
        || status=1

    mpremote connect "${port}" fs cp \
        "${MICROPYTHON_DIR}/main.py" \
        :main.py \
        || status=1

    if [ "${TRANSPORT}" = "udp" ]; then
        if [ ! -f "${MICROPYTHON_DIR}/secrets/wifi_secrets.py" ]; then
            echo "ERROR: falta wifi_secrets.py"
            status=1
        else
            mpremote connect "${port}" fs cp \
                "${MICROPYTHON_DIR}/secrets/wifi_secrets.py" \
                :wifi_secrets.py \
                || status=1
        fi
    fi

    if [ "${status}" -eq 0 ]; then
        echo "PASS: ${node_role}"
    else
        echo "FAIL: ${node_role}"
    fi

    return "${status}"
}

STATUS_A=0
STATUS_B=0

deploy_node "${PORT_A}" alice || STATUS_A=1
deploy_node "${PORT_B}" bob || STATUS_B=1

mpremote connect "${PORT_A}" reset || STATUS_A=1
sleep 1
mpremote connect "${PORT_B}" reset || STATUS_B=1

echo
echo "========================================"
echo "RESUMEN"
echo "========================================"
echo "Transporte: ${TRANSPORT}"
echo "Alice: ${STATUS_A}"
echo "Bob: ${STATUS_B}"

if [ "${STATUS_A}" -eq 0 ] \
    && [ "${STATUS_B}" -eq 0 ]; then
    echo "RESULTADO GENERAL: PASS"
else
    echo "RESULTADO GENERAL: FAIL"
fi

echo
echo "Los nodos quedaron esperando START."
echo "La terminal permanece abierta."
