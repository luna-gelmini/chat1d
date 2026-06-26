#!/usr/bin/env python3
from __future__ import annotations

import argparse
import socket
import statistics
import sys
import time
from typing import List


def build_pub_frame(seq: int, room: str, body: str) -> bytes:
    """Build a minimal newline-framed CHAT/1 PUB-shaped probe frame.

    The byte shape here is intentionally cheap to generate; the real
    parser path will reject if the server enforces full CHAT/1
    framing. The harness still exercises socket write throughput.
    """
    payload = f"PUB\t{room}\t{seq}\t{body}\n"
    return payload.encode("utf-8")


def percentiles(samples: List[float], pcts=(50.0, 95.0, 99.0)) -> dict:
    if not samples:
        return {f"p{int(p)}": 0.0 for p in pcts}
    sorted_samples = sorted(samples)
    out = {}
    for p in pcts:
        idx = min(
            len(sorted_samples) - 1, int(round((p / 100.0) * (len(sorted_samples) - 1)))
        )
        out[f"p{int(p)}"] = sorted_samples[idx]
    return out


def run_connection(
    host: str, port: int, messages: int, room: str, body: str
) -> List[float]:
    latencies: List[float] = []
    sock = socket.create_connection((host, port), timeout=5.0)
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
    parser = argparse.ArgumentParser(description="chat1d localhost microbenchmark")
    parser.add_argument("--host", default="127.0.0.1", help="server host")
    parser.add_argument("--port", type=int, default=7000, help="server port")
    parser.add_argument(
        "--connections", type=int, default=100, help="parallel TCP connections"
    )
    parser.add_argument(
        "--messages", type=int, default=10_000, help="messages per connection"
    )
    parser.add_argument("--room", default="#bench", help="target room id")
    parser.add_argument("--body", default="x" * 64, help="message body filler")
    parser.add_argument(
        "--dry-run", action="store_true", help="print plan, do not open sockets"
    )
    args = parser.parse_args()

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
    print(
        f"done elapsed_s={elapsed:.3f} msgs={total_msgs} msgs_per_s={total_msgs / elapsed:.0f} "
        f"mean_us={mean_us:.1f} p50_us={pcts['p50']:.1f} p95_us={pcts['p95']:.1f} p99_us={pcts['p99']:.1f}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
