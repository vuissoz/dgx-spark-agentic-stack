#!/usr/bin/env python3
"""Tiny TCP forwarder for publishing loopback-bound services in-container."""

from __future__ import annotations

import argparse
import asyncio
import logging
import time
from dataclasses import dataclass, field


LOGGER = logging.getLogger("tcp-forward")


def escape_label(value: str) -> str:
    return value.replace("\\", "\\\\").replace("\n", "\\n").replace('"', '\\"')


def format_labels(labels: dict[str, str]) -> str:
    rendered = ",".join(f'{key}="{escape_label(value)}"' for key, value in sorted(labels.items()))
    return f"{{{rendered}}}"


@dataclass(slots=True)
class ForwarderMetrics:
    forwarder: str
    listen_host: str
    listen_port: int
    target_host: str
    target_port: int
    started_monotonic: float = field(default_factory=time.monotonic)
    accepted_connections_total: int = 0
    target_connect_errors_total: int = 0
    active_connections: int = 0
    client_to_target_bytes_total: int = 0
    target_to_client_bytes_total: int = 0

    def base_labels(self) -> dict[str, str]:
        return {
            "forwarder": self.forwarder,
            "listen_host": self.listen_host,
            "listen_port": str(self.listen_port),
            "target_host": self.target_host,
            "target_port": str(self.target_port),
        }

    def render_prometheus(self) -> str:
        base = self.base_labels()
        lines = [
            "# HELP agentic_tcp_forwarder_info Static metadata for the TCP forwarder.",
            "# TYPE agentic_tcp_forwarder_info gauge",
            f"agentic_tcp_forwarder_info{format_labels(base)} 1",
            "# HELP agentic_tcp_forwarder_uptime_seconds TCP forwarder uptime in seconds.",
            "# TYPE agentic_tcp_forwarder_uptime_seconds gauge",
            f"agentic_tcp_forwarder_uptime_seconds{format_labels(base)} {time.monotonic() - self.started_monotonic:.6f}",
            "# HELP agentic_tcp_forwarder_connections_total TCP forwarder connection attempts by outcome.",
            "# TYPE agentic_tcp_forwarder_connections_total counter",
            (
                "agentic_tcp_forwarder_connections_total"
                f"{format_labels({**base, 'result': 'accepted'})} {self.accepted_connections_total}"
            ),
            (
                "agentic_tcp_forwarder_connections_total"
                f"{format_labels({**base, 'result': 'target_connect_error'})} {self.target_connect_errors_total}"
            ),
            "# HELP agentic_tcp_forwarder_active_connections Current active TCP forwarder connections.",
            "# TYPE agentic_tcp_forwarder_active_connections gauge",
            f"agentic_tcp_forwarder_active_connections{format_labels(base)} {self.active_connections}",
            "# HELP agentic_tcp_forwarder_bytes_total TCP forwarder proxied bytes by direction.",
            "# TYPE agentic_tcp_forwarder_bytes_total counter",
            (
                "agentic_tcp_forwarder_bytes_total"
                f"{format_labels({**base, 'direction': 'client_to_target'})} {self.client_to_target_bytes_total}"
            ),
            (
                "agentic_tcp_forwarder_bytes_total"
                f"{format_labels({**base, 'direction': 'target_to_client'})} {self.target_to_client_bytes_total}"
            ),
            "",
        ]
        return "\n".join(lines)


async def write_http_response(
    writer: asyncio.StreamWriter,
    status_line: str,
    body: bytes,
    content_type: str,
) -> None:
    headers = [
        f"HTTP/1.1 {status_line}",
        f"Content-Type: {content_type}",
        f"Content-Length: {len(body)}",
        "Connection: close",
        "",
        "",
    ]
    writer.write("\r\n".join(headers).encode("ascii") + body)
    await writer.drain()
    writer.close()
    await writer.wait_closed()


async def handle_metrics_client(
    reader: asyncio.StreamReader,
    writer: asyncio.StreamWriter,
    metrics: ForwarderMetrics,
) -> None:
    try:
        request_line = await reader.readline()
        if not request_line:
            writer.close()
            await writer.wait_closed()
            return

        try:
            method, path, _ = request_line.decode("ascii", errors="replace").strip().split()
        except ValueError:
            await write_http_response(writer, "400 Bad Request", b"bad request\n", "text/plain; charset=utf-8")
            return

        while True:
            header_line = await reader.readline()
            if not header_line or header_line in {b"\r\n", b"\n"}:
                break

        if method != "GET":
            await write_http_response(
                writer,
                "405 Method Not Allowed",
                b"method not allowed\n",
                "text/plain; charset=utf-8",
            )
            return

        if path == "/healthz":
            await write_http_response(writer, "200 OK", b"ok\n", "text/plain; charset=utf-8")
            return

        if path != "/metrics":
            await write_http_response(writer, "404 Not Found", b"not found\n", "text/plain; charset=utf-8")
            return

        payload = metrics.render_prometheus().encode("utf-8")
        await write_http_response(
            writer,
            "200 OK",
            payload,
            "text/plain; version=0.0.4; charset=utf-8",
        )
    except Exception as exc:  # noqa: BLE001
        LOGGER.warning("metrics request failed: %s", exc)
        writer.close()
        await writer.wait_closed()


async def pipe(
    reader: asyncio.StreamReader,
    writer: asyncio.StreamWriter,
    metrics: ForwarderMetrics,
    direction: str,
) -> None:
    try:
        while True:
            chunk = await reader.read(65536)
            if not chunk:
                break
            if direction == "client_to_target":
                metrics.client_to_target_bytes_total += len(chunk)
            else:
                metrics.target_to_client_bytes_total += len(chunk)
            writer.write(chunk)
            await writer.drain()
    finally:
        writer.close()
        await writer.wait_closed()


async def handle_client(
    client_reader: asyncio.StreamReader,
    client_writer: asyncio.StreamWriter,
    metrics: ForwarderMetrics,
    target_host: str,
    target_port: int,
) -> None:
    metrics.accepted_connections_total += 1
    metrics.active_connections += 1
    try:
        target_reader, target_writer = await asyncio.open_connection(target_host, target_port)
    except Exception as exc:  # noqa: BLE001
        metrics.target_connect_errors_total += 1
        LOGGER.warning("target connection failed: %s", exc)
        client_writer.close()
        await client_writer.wait_closed()
        metrics.active_connections -= 1
        return

    try:
        await asyncio.gather(
            pipe(client_reader, target_writer, metrics, "client_to_target"),
            pipe(target_reader, client_writer, metrics, "target_to_client"),
        )
    finally:
        metrics.active_connections -= 1


async def run(
    listen_host: str,
    listen_port: int,
    target_host: str,
    target_port: int,
    metrics_host: str | None,
    metrics_port: int | None,
    forwarder_name: str,
) -> None:
    metrics = ForwarderMetrics(
        forwarder=forwarder_name,
        listen_host=listen_host,
        listen_port=listen_port,
        target_host=target_host,
        target_port=target_port,
    )
    server = await asyncio.start_server(
        lambda r, w: handle_client(r, w, metrics, target_host, target_port),
        listen_host,
        listen_port,
    )
    metrics_server = None
    addrs = ", ".join(str(sock.getsockname()) for sock in (server.sockets or []))
    LOGGER.info("forwarding %s -> %s:%s", addrs, target_host, target_port)
    if metrics_host and metrics_port:
        metrics_server = await asyncio.start_server(
            lambda r, w: handle_metrics_client(r, w, metrics),
            metrics_host,
            metrics_port,
        )
        metrics_addrs = ", ".join(str(sock.getsockname()) for sock in (metrics_server.sockets or []))
        LOGGER.info("serving forwarder metrics on %s", metrics_addrs)

    try:
        async with server:
            if metrics_server is None:
                await server.serve_forever()
            async with metrics_server:
                await asyncio.gather(server.serve_forever(), metrics_server.serve_forever())
    finally:
        if metrics_server is not None:
            metrics_server.close()
            await metrics_server.wait_closed()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Forward TCP traffic to a target endpoint.")
    parser.add_argument("--listen-host", required=True)
    parser.add_argument("--listen-port", required=True, type=int)
    parser.add_argument("--target-host", required=True)
    parser.add_argument("--target-port", required=True, type=int)
    parser.add_argument("--metrics-host")
    parser.add_argument("--metrics-port", type=int)
    parser.add_argument("--forwarder-name", default="tcp-forwarder")
    return parser.parse_args()


def main() -> int:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    args = parse_args()
    asyncio.run(
        run(
            args.listen_host,
            args.listen_port,
            args.target_host,
            args.target_port,
            args.metrics_host,
            args.metrics_port,
            args.forwarder_name,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
