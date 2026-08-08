#!/usr/bin/env bash
set -u
OUT="${HOME}/Downloads/salida.txt"
run_all(){
  local a=0 b=0
  echo "================================================"
  echo "InvisComm Arduino UNO Ethernet - validación"
  echo "================================================"
  pio run -e uno_alice || a=1
  pio run -e uno_bob || b=1
  echo
  echo "RESUMEN"
  echo "uno_alice: $a"
  echo "uno_bob:   $b"
  if [ "$a" -eq 0 ] && [ "$b" -eq 0 ]; then echo "RESULTADO GENERAL: PASS"; else echo "RESULTADO GENERAL: FAIL"; fi
  echo "La terminal permanece abierta."
}
run_all 2>&1 | tee "$OUT"
