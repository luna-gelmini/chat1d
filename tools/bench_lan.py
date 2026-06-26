#!/usr/bin/env python3
from __future__ import annotations

import argparse
import socket
import statistics
import sys
import time
from typing import List

from bench_local import build_pub_frame, percentiles  # type: ignore


def run_connection(
    host: str, port: int, messages: int, room: str, body: str
) -> List[float]:
    latencies: List[float] = []
    sock = socket.create_connection((host, port), timeout=10.0)
    try:
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        for seq in range(messages):
            frame = build_pub_frame(seq, room, body)
            t0 = time.perf_counter_ns()
            sock.sendall(frame)
            latencies.append((time.perf_counter_ns() - t0) / 1000.0)
    finally:
        try:
            sock.close()
        except OSError:
            pass
    return latencies


def main() -> int:
    parser = argparse.ArgumentParser(description="chat1d LAN benchmark client")
    parser.add_argument("--host", required=True, help="server host (LAN IP)")
    parser.add_argument("--port", type=int, default=7000, help="server port")
    parser.add_argument(
        "--connections", type=int, default=500, help="parallel TCP connections"
    )
    parser.add_argument(
        "--messages", type=int, default=50_000, help="messages per connection"
    )
    parser.add_argument("--room", default="#bench-lan", help="target room id")
    parser.add_argument("--body", default="x" * 256, help="message body filler")
    parser.add_argument(
        "--dry-run", action="store_true", help="print plan, do not open sockets"
    )
    args = parser.parse_args()

    if args.host in ("127.0.0.1", "localhost", "::1"):
        print("refusing localhost target; use bench_local.py", file=sys.stderr)
        return 2

    total_msgs = args.connections * args.messages

    if args.dry_run:
        print(
            f"plan host={args.host} port={args.port} connections={args.connections} "
            f"messages={args.messages} total={total_msgs} body_bytes={len(args.body)}"
        )
        return 0

    print(
        f"start host={args.host} port={args.port} connections={args.connections} "
        f"messages={args.messages} total={total_msgs}",
        file=sys.stderr,
    )

    all_lat: List[float] = []
    t_start = time.perf_counter()
    for conn_index in range(args.connections):
        try:
            all_lat.extend(
                run_connection(
                    args.host, args.port, args.messages, args.room, args.body
                )
            )
        except OSError as exc:
            print(f"conn={conn_index} err={exc}", file=sys.stderr)
            return 1
    elapsed = time.perf_counter() - t_start

    if elapsed <= 0:
        elapsed = 1e-9

    pcts = percentiles(all_lat)
    mean_us = statistics.fmean(all_lat) if all_lat else 0.0
    bytes_sent = total_msgs * (len(args.body) + 32)
    print(
        f"done elapsed_s={elapsed:.3f} msgs={total_msgs} msgs_per_s={total_msgs / elapsed:.0f} "
        f"approx_mbps={(bytes_sent * 8) / 1e6 / elapsed:.1f} "
        f"mean_us={mean_us:.1f} p50_us={pcts['p50']:.1f} p95_us={pcts['p95']:.1f} p99_us={pcts['p99']:.1f}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
