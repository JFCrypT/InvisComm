#!/usr/bin/env python3

from __future__ import annotations

import argparse
import csv
import queue
import socket
import threading
import time
from dataclasses import dataclass
from pathlib import Path

import serial

from capture_telemetry import (
    CSV_COLUMNS,
    TelemetryParseError,
    parse_telemetry_line,
)


@dataclass(frozen=True)
class Source:
    port: str
    expected_node: str


class Reader(threading.Thread):
    def __init__(
        self,
        source: Source,
        baudrate: int,
        output_queue: queue.Queue,
        stop_event: threading.Event,
    ) -> None:
        super().__init__(
            daemon=True,
            name="reader-" + source.expected_node,
        )

        self.source = source
        self.baudrate = baudrate
        self.output_queue = output_queue
        self.stop_event = stop_event
        self.error: Exception | None = None
        self.device: serial.Serial | None = None

    def run(self) -> None:
        try:
            with serial.Serial(
                self.source.port,
                self.baudrate,
                timeout=0.2,
                write_timeout=2.0,
            ) as device:
                self.device = device

                while not self.stop_event.is_set():
                    raw = device.readline()

                    if not raw:
                        continue

                    line = raw.decode(
                        "utf-8",
                        errors="replace",
                    ).rstrip("\r\n")

                    self.output_queue.put(
                        (
                            self.source,
                            time.time(),
                            line,
                        )
                    )

        except Exception as error:
            self.error = error
            self.stop_event.set()

    def send_line(self, line: str) -> None:
        if self.device is None:
            raise RuntimeError(
                "Puerto no disponible: "
                + self.source.port
            )

        self.device.write(
            (line + "\r\n").encode("utf-8")
        )

        self.device.flush()


def send_udp_start(
    broadcast_address: str,
    control_port: int,
    payload: bytes,
) -> None:
    with socket.socket(
        socket.AF_INET,
        socket.SOCK_DGRAM,
    ) as control:
        control.setsockopt(
            socket.SOL_SOCKET,
            socket.SO_BROADCAST,
            1,
        )

        for _ in range(10):
            control.sendto(
                payload,
                (
                    broadcast_address,
                    control_port,
                ),
            )

            time.sleep(0.1)


def main() -> int:
    parser = argparse.ArgumentParser()

    parser.add_argument(
        "--transport",
        required=True,
        choices=("udp", "uart", "lora"),
    )

    parser.add_argument(
        "--port-a",
        default="/dev/ttyUSB0",
    )

    parser.add_argument(
        "--port-b",
        default="/dev/ttyUSB1",
    )

    parser.add_argument(
        "--baudrate",
        type=int,
        default=115200,
    )

    parser.add_argument(
        "--duration",
        type=float,
        default=60.0,
    )

    parser.add_argument(
        "--broadcast",
        default="192.168.100.255",
    )

    parser.add_argument(
        "--control-port",
        type=int,
        default=43000,
    )

    parser.add_argument(
        "--start-delay-ms",
        type=int,
        default=3000,
    )

    parser.add_argument(
        "--output-dir",
        type=Path,
        required=True,
    )

    args = parser.parse_args()

    args.output_dir.mkdir(
        parents=True,
        exist_ok=True,
    )

    extended_path = (
        args.output_dir
        / "telemetria_extendida.csv"
    )

    compatible_path = (
        args.output_dir
        / "telemetria.csv"
    )

    raw_path = (
        args.output_dir
        / "serial_raw.log"
    )

    stop_event = threading.Event()
    events: queue.Queue = queue.Queue()

    readers = (
        Reader(
            Source(args.port_a, "Alice"),
            args.baudrate,
            events,
            stop_event,
        ),
        Reader(
            Source(args.port_b, "Bob"),
            args.baudrate,
            events,
            stop_event,
        ),
    )

    for reader in readers:
        reader.start()

    ready_nodes: set[str] = set()

    print("Esperando READY de Alice y Bob...")

    ready_deadline = time.time() + 90.0

    while (
        ready_nodes != {"Alice", "Bob"}
        and time.time() < ready_deadline
        and not stop_event.is_set()
    ):
        try:
            source, timestamp, line = (
                events.get(timeout=0.5)
            )
        except queue.Empty:
            continue

        if line.startswith("READY,"):
            fields = line.split(",")

            if len(fields) >= 2:
                ready_nodes.add(fields[1])
                print("READY:", fields[1])

    if ready_nodes != {"Alice", "Bob"}:
        stop_event.set()

        print(
            "ERROR: no se recibieron ambos READY:",
            sorted(ready_nodes),
        )

        return 1

    session_id = time.strftime(
        "%Y%m%d_%H%M%S"
    )

    command = (
        "INVISCOMM_START,"
        + session_id
        + ","
        + str(args.start_delay_ms)
    )

    if args.transport == "udp":
        send_udp_start(
            args.broadcast,
            args.control_port,
            command.encode("utf-8"),
        )
    else:
        for reader in readers:
            reader.send_line(command)

    print("START enviado:", session_id)
    print(
        "Capturando durante",
        args.duration,
        "segundos",
    )

    experiment_start = time.time()
    deadline = (
        experiment_start
        + args.duration
        + args.start_delay_ms / 1000.0
    )

    rows: list[dict[str, object]] = []
    tracebacks = 0
    runtime_errors = 0

    with raw_path.open(
        "w",
        encoding="utf-8",
        buffering=1,
    ) as raw_file, extended_path.open(
        "w",
        newline="",
        encoding="utf-8",
    ) as extended_file:
        writer = csv.DictWriter(
            extended_file,
            fieldnames=CSV_COLUMNS,
        )

        writer.writeheader()

        while (
            time.time() < deadline
            and not stop_event.is_set()
        ):
            try:
                source, timestamp, line = (
                    events.get(timeout=0.2)
                )
            except queue.Empty:
                continue

            raw_file.write(
                "{:.6f},{},{},{}\n".format(
                    timestamp,
                    source.port,
                    source.expected_node,
                    line,
                )
            )

            if "Traceback" in line:
                tracebacks += 1

            if ",ERROR," in line:
                runtime_errors += 1

            if not line.startswith("TEL,"):
                continue

            try:
                record = parse_telemetry_line(
                    line,
                    port=source.port,
                    host_timestamp=timestamp,
                    experiment_start=experiment_start,
                    transport=args.transport,
                )
            except TelemetryParseError:
                continue

            row = record.to_row()

            writer.writerow(row)
            extended_file.flush()

            rows.append(row)

            if len(rows) % 20 == 0:
                print("Registros:", len(rows))

    stop_event.set()

    for reader in readers:
        reader.join(timeout=2.0)

    rows.sort(
        key=lambda row: float(
            row["timestamp"]
        )
    )

    with compatible_path.open(
        "w",
        newline="",
        encoding="utf-8",
    ) as compatible_file:
        writer = csv.DictWriter(
            compatible_file,
            fieldnames=(
                "timestamp",
                "direction",
                "encrypted_coord",
                "type",
            ),
        )

        writer.writeheader()

        for row in rows:
            writer.writerow({
                "timestamp": row["timestamp"],
                "direction": row["direction"],
                "encrypted_coord": row[
                    "encrypted_coord"
                ],
                "type": row["type"],
            })

    directions = {
        str(row["direction"])
        for row in rows
    }

    info_count = sum(
        1
        for row in rows
        if row["type"] == "Info"
    )

    print()
    print("========================================")
    print("RESUMEN")
    print("========================================")
    print("Transporte:", args.transport)
    print("Registros:", len(rows))
    print("Direcciones:", sorted(directions))
    print("Tramas Info:", info_count)
    print("Errores runtime:", runtime_errors)
    print("Tracebacks:", tracebacks)
    print("CSV:", compatible_path)

    capture_ok = (
        len(rows) > 0
        and directions == {"A-->B", "B-->A"}
        and info_count > 0
    )

    session_ok = (
        capture_ok
        and runtime_errors == 0
        and tracebacks == 0
    )

    print(
        "CAPTURA:",
        "PASS" if capture_ok else "FAIL",
    )

    print(
        "SESIÓN:",
        "PASS" if session_ok else "FAIL",
    )

    if capture_ok:
        return 0

    return 2


if __name__ == "__main__":
    raise SystemExit(main())
