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

    def run(self) -> None:
        try:
            with serial.Serial(
                self.source.port,
                self.baudrate,
                timeout=0.2,
            ) as device:
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


def send_start(
    broadcast_address: str,
    control_port: int,
    session_id: str,
    delay_ms: int,
) -> None:
    payload = (
        "INVISCOMM_START,"
        + session_id
        + ","
        + str(delay_ms)
    ).encode("utf-8")

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

    ready_deadline = time.time() + 60.0

    buffered_lines: list[
        tuple[Source, float, str]
    ] = []

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

        buffered_lines.append(
            (source, timestamp, line)
        )

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

    experiment_start = time.time()

    send_start(
        args.broadcast,
        args.control_port,
        session_id,
        args.start_delay_ms,
    )

    print("START enviado:", session_id)
    print(
        "Capturando durante",
        args.duration,
        "segundos",
    )

    valid_records = 0
    rows: list[dict[str, object]] = []

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

        deadline = (
            experiment_start
            + args.duration
            + args.start_delay_ms / 1000.0
        )

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

            if not line.startswith("TEL,"):
                continue

            try:
                record = parse_telemetry_line(
                    line,
                    port=source.port,
                    host_timestamp=timestamp,
                    experiment_start=experiment_start,
                    transport="udp",
                )
            except TelemetryParseError:
                continue

            row = record.to_row()
            writer.writerow(row)
            extended_file.flush()

            rows.append(row)
            valid_records += 1

            if valid_records % 20 == 0:
                print(
                    "Registros:",
                    valid_records,
                )

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
    print("Registros:", valid_records)
    print("Direcciones:", sorted(directions))
    print("Tramas Info:", info_count)
    print("CSV:", compatible_path)

    if (
        valid_records > 0
        and directions == {"A-->B", "B-->A"}
        and info_count > 0
    ):
        print("RESULTADO GENERAL: PASS")
        return 0

    print("RESULTADO GENERAL: FAIL")
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
