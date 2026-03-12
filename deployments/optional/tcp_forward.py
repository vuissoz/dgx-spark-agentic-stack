#!/usr/bin/env python3
"""Tiny TCP forwarder for publishing loopback-bound services in-container."""

from __future__ import annotations

import argparse
import asyncio
import logging


LOGGER = logging.getLogger("tcp-forward")


async def pipe(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
    try:
        while True:
            chunk = await reader.read(65536)
            if not chunk:
                break
            writer.write(chunk)
            await writer.drain()
    finally:
        writer.close()
        await writer.wait_closed()


async def handle_client(
    client_reader: asyncio.StreamReader,
    client_writer: asyncio.StreamWriter,
    target_host: str,
    target_port: int,
) -> None:
    try:
        target_reader, target_writer = await asyncio.open_connection(target_host, target_port)
    except Exception as exc:  # noqa: BLE001
        LOGGER.warning("target connection failed: %s", exc)
        client_writer.close()
        await client_writer.wait_closed()
        return

    await asyncio.gather(
        pipe(client_reader, target_writer),
        pipe(target_reader, client_writer),
    )


async def run(listen_host: str, listen_port: int, target_host: str, target_port: int) -> None:
    server = await asyncio.start_server(
        lambda r, w: handle_client(r, w, target_host, target_port),
        listen_host,
        listen_port,
    )
    addrs = ", ".join(str(sock.getsockname()) for sock in (server.sockets or []))
    LOGGER.info("forwarding %s -> %s:%s", addrs, target_host, target_port)
    async with server:
        await server.serve_forever()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Forward TCP traffic to a target endpoint.")
    parser.add_argument("--listen-host", required=True)
    parser.add_argument("--listen-port", required=True, type=int)
    parser.add_argument("--target-host", required=True)
    parser.add_argument("--target-port", required=True, type=int)
    return parser.parse_args()


def main() -> int:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    args = parse_args()
    asyncio.run(run(args.listen_host, args.listen_port, args.target_host, args.target_port))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
