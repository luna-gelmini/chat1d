#!/usr/bin/env python3
import argparse
import base64
import hashlib
import os
import pathlib
import socket
import subprocess
import sys
import tempfile
import threading
import time
from typing import Optional


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).decode("ascii").rstrip("=")


def backend_cmd(repo_root: pathlib.Path, *args: str) -> str:
    backend = os.environ.get("CHAT1_CRYPTO_BACKEND", str(repo_root / "tools" / "chat1_crypto_backend.py"))
    out = subprocess.check_output(["python3", backend, *args], cwd=str(repo_root))
    return out.decode("utf-8").strip()


def backend_public_from_seed(repo_root: pathlib.Path, seed_hex: str) -> str:
    with tempfile.NamedTemporaryFile(delete=False) as tf:
        out_path = tf.name
    try:
        backend = os.environ.get("CHAT1_CRYPTO_BACKEND", str(repo_root / "tools" / "chat1_crypto_backend.py"))
        subprocess.check_call(["python3", backend, "public-from-seed", seed_hex, out_path], cwd=str(repo_root))
        return pathlib.Path(out_path).read_text(encoding="utf-8").strip()
    finally:
        try:
            os.unlink(out_path)
        except FileNotFoundError:
            pass


def backend_sign(repo_root: pathlib.Path, seed_hex: str, message_bytes: bytes) -> str:
    with tempfile.NamedTemporaryFile(delete=False) as msgf:
        msgf.write(message_bytes)
        msg_path = msgf.name
    with tempfile.NamedTemporaryFile(delete=False) as outf:
        out_path = outf.name
    try:
        backend = os.environ.get("CHAT1_CRYPTO_BACKEND", str(repo_root / "tools" / "chat1_crypto_backend.py"))
        subprocess.check_call(["python3", backend, "sign", seed_hex, msg_path, out_path], cwd=str(repo_root))
        return pathlib.Path(out_path).read_text(encoding="utf-8").strip()
    finally:
        for p in (msg_path, out_path):
            try:
                os.unlink(p)
            except FileNotFoundError:
                pass


def _ts_short(ts_ms: str) -> str:
    try:
        t = int(ts_ms) / 1000.0
        return time.strftime("%H:%M:%S", time.localtime(t))
    except Exception:
        return "--:--:--"


def _c(text: str, color: str, enable: bool) -> str:
    if not enable:
        return text
    codes = {
        "dim": "2",
        "green": "32",
        "yellow": "33",
        "cyan": "36",
        "red": "31",
        "magenta": "35",
    }
    return f"\x1b[{codes[color]}m{text}\x1b[0m"


def format_incoming(line: str, *, raw: bool, show_pong: bool, color: bool) -> str:
    if raw:
        return line.rstrip("\n")
    parts = line.rstrip("\n").split("\t")
    if not parts:
        return line.rstrip("\n")
    verb = parts[0]
    if verb == "HELLO" and len(parts) >= 4:
        return _c(f"● connected server={parts[1]} proto={parts[2]} status={parts[3]}", "green", color)
    if verb == "MSG" and len(parts) >= 7:
        room, msg_id, author, ts_ms, body_b64 = parts[1], parts[2], parts[3], parts[4], parts[5]
        try:
            body = base64.urlsafe_b64decode(body_b64 + "=" * ((4 - len(body_b64) % 4) % 4)).decode("utf-8", "replace")
        except Exception:
            body = "<decode-failed>"
        who = author[:12] + ".."
        stamp = _c(_ts_short(ts_ms), "dim", color)
        room_tag = _c(f"#{room}", "cyan", color)
        who_tag = _c(who, "magenta", color)
        meta = _c(f"{msg_id[:10]}..", "dim", color)
        return f"{stamp} {room_tag} <{who_tag}> {body} {meta}"
    if verb == "ATTACH" and len(parts) >= 10:
        room, _mid, author, ts_ms, cid, bl, mime, name = parts[1], parts[2], parts[3], parts[4], parts[5], parts[6], parts[7], parts[8]
        who = author[:12] + ".."
        stamp = _c(_ts_short(ts_ms), "dim", color)
        room_tag = _c(f"#{room}", "cyan", color)
        who_tag = _c(who, "magenta", color)
        short_cid = cid[:12] + ".."
        return f"{stamp} {room_tag} <{who_tag}> [attach {short_cid} {bl} bytes {mime} {name}]"
    if verb == "ERR" and len(parts) >= 3:
        return _c(f"✖ error {parts[1]}: {parts[2]}", "red", color)
    if verb == "PONG":
        if not show_pong:
            return ""
        nonce = parts[1] if len(parts) >= 2 else "-"
        return _c(f"↔ pong {nonce}", "dim", color)
    if verb == "PING":
        nonce = parts[1] if len(parts) >= 2 else "-"
        return _c(f"↔ ping {nonce}", "dim", color)
    return _c(f"[raw] {line.rstrip()}", "yellow", color)


def recv_loop(sock: socket.socket, stop_evt: threading.Event, *, raw_events: bool, show_pong: bool, color: bool) -> None:
    f = sock.makefile("r", encoding="utf-8", newline="\n")
    try:
        while not stop_evt.is_set():
            line = f.readline()
            if line == "":
                print("[server closed]")
                stop_evt.set()
                return
            rendered = format_incoming(line, raw=raw_events, show_pong=show_pong, color=color)
            if rendered:
                print(rendered)
    except Exception as exc:
        print(f"[recv error] {exc}")
        stop_evt.set()
    finally:
        try:
            f.close()
        except Exception:
            pass


def send_line(sock: socket.socket, line: str) -> None:
    sock.sendall((line + "\n").encode("utf-8"))


def canonical_msg_bytes(room: str, author_id: str, ts_ms: str, body_b64: str) -> bytes:
    return f"msg\n{room}\n{author_id}\n{ts_ms}\n{body_b64}\n".encode("utf-8")


def canonical_attach_bytes(
    room: str, author_id: str, ts_ms: str, cid_hex: str, byte_len: int, mime: str, name: str
) -> bytes:
    m = mime if mime else "-"
    n = name if name else "-"
    return f"attach\n{room}\n{author_id}\n{ts_ms}\n{cid_hex}\n{byte_len}\n{m}\n{n}\n".encode("utf-8")


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="CHAT/1 client")
    p.add_argument("--host", default="127.0.0.1")
    p.add_argument("--port", type=int, default=7000)
    p.add_argument("--name", default="cli")
    p.add_argument("--nonce", default="nonce")
    p.add_argument("--seed", required=True, help="32-byte seed hex for ed25519 signing")
    p.add_argument("--room", default=None, help="auto-subscribe room on connect")
    p.add_argument("--ping-interval", type=int, default=30, help="seconds between keepalive ping (0 disables)")
    p.add_argument("--show-pong", action="store_true", help="show incoming PONG lines")
    p.add_argument("--raw-events", action="store_true", help="print raw protocol frames")
    p.add_argument("--no-color", action="store_true", help="disable ANSI colors")
    return p.parse_args()


def ping_loop(sock: socket.socket, stop_evt: threading.Event, interval: int) -> None:
    if interval <= 0:
        return
    try:
        while not stop_evt.is_set():
            time.sleep(interval)
            if stop_evt.is_set():
                break
            nonce = str(int(time.time()))
            try:
                send_line(sock, f"PING\t{nonce}")
            except Exception:
                stop_evt.set()
                return
    except Exception:
        stop_evt.set()


def main() -> int:
    args = parse_args()
    repo_root = pathlib.Path(__file__).resolve().parent.parent

    if len(args.seed) != 64:
        print("seed must be 64 hex chars")
        return 1

    try:
        pubkey_b64 = backend_public_from_seed(repo_root, args.seed)
        raw_pub = base64.urlsafe_b64decode(pubkey_b64 + "=")
        author_id = hashlib.sha256(raw_pub).hexdigest()
    except Exception as exc:
        print(f"key setup failed: {exc}")
        return 1

    try:
        sock = socket.create_connection((args.host, args.port), timeout=5.0)
        sock.settimeout(None)
    except Exception as exc:
        print(f"connect failed: {exc}")
        return 1

    stop_evt = threading.Event()
    color = sys.stdout.isatty() and not args.no_color
    th = threading.Thread(
        target=recv_loop,
        args=(sock, stop_evt),
        kwargs={"raw_events": args.raw_events, "show_pong": args.show_pong, "color": color},
        daemon=True,
    )
    th.start()
    ping_th = threading.Thread(target=ping_loop, args=(sock, stop_evt, args.ping_interval), daemon=True)
    ping_th.start()

    try:
        send_line(sock, f"HELLO\t{args.name}\t1\t{args.nonce}\t{pubkey_b64}")
        if args.room:
            send_line(sock, f"SUB\t{args.room}")
        current_room: Optional[str] = args.room
    except Exception as exc:
        print(f"initial send failed: {exc}")
        stop_evt.set()
        sock.close()
        return 1

    print(_c("connected.", "green", color))
    print("commands:")
    print("  /join <room>   (alias: /sub)")
    print("  /part <room>   (alias: /unsub)")
    print("  /msg <room> <text>")
    print("  /attach <room> <cid_hex_64> <byte_len> [mime] [name]")
    print("  /me <text>     (send action to current room)")
    print("  /room <room>   (set default room for plain text)")
    print("  /ping [nonce]")
    print("  /bye [reason]")
    print("  /help")
    print("  /quit")
    if args.ping_interval > 0:
        print(f"  [auto-ping every {args.ping_interval}s]")

    try:
        while not stop_evt.is_set():
            try:
                prompt_room = current_room if current_room else "-"
                line = input(f"{prompt_room}> ").strip()
            except EOFError:
                line = "/quit"

            if not line:
                continue
            if line == "/help":
                print("commands: /join /part /room /msg /attach /me /ping /bye /quit")
                continue
            if line == "/quit":
                try:
                    send_line(sock, "BYE\tquit")
                except Exception:
                    pass
                break
            if line.startswith("/sub ") or line.startswith("/join "):
                room = line.split(maxsplit=1)[1].strip()
                send_line(sock, f"SUB\t{room}")
                current_room = room
                print(_c(f"joined #{room}", "green", color))
                continue
            if line.startswith("/unsub ") or line.startswith("/part "):
                room = line.split(maxsplit=1)[1].strip()
                send_line(sock, f"UNSUB\t{room}")
                if current_room == room:
                    current_room = None
                print(_c(f"left #{room}", "yellow", color))
                continue
            if line.startswith("/room "):
                room = line.split(maxsplit=1)[1].strip()
                current_room = room
                print(_c(f"default room -> #{room}", "cyan", color))
                continue
            if line.startswith("/ping"):
                parts = line.split(maxsplit=1)
                nonce = parts[1] if len(parts) == 2 else "n"
                send_line(sock, f"PING\t{nonce}")
                continue
            if line.startswith("/bye"):
                parts = line.split(maxsplit=1)
                reason = parts[1] if len(parts) == 2 else "bye"
                send_line(sock, f"BYE\t{reason}")
                break
            if line.startswith("/msg "):
                parts = line.split(maxsplit=2)
                if len(parts) < 3:
                    print("usage: /msg <room> <text>")
                    continue
                room = parts[1]
                text = parts[2]
                body_b64 = b64url(text.encode("utf-8"))
                ts_ms = str(int(__import__("time").time() * 1000))
                canonical = canonical_msg_bytes(room, author_id, ts_ms, body_b64)
                msg_id = hashlib.sha256(canonical).hexdigest()
                try:
                    sig_b64 = backend_sign(repo_root, args.seed, canonical)
                except Exception as exc:
                    print(f"sign failed: {exc}")
                    continue
                send_line(sock, f"MSG\t{room}\t{msg_id}\t{author_id}\t{ts_ms}\t{body_b64}\t{sig_b64}")
                continue
            if line.startswith("/attach "):
                parts = line.split()
                if len(parts) < 4:
                    print("usage: /attach <room> <cid_hex> <byte_len> [mime] [name]")
                    continue
                room, cid_hex, bl_s = parts[1], parts[2], parts[3]
                if len(cid_hex) != 64:
                    print("cid_hex must be 64 lowercase hex chars")
                    continue
                try:
                    byte_len = int(bl_s)
                except ValueError:
                    print("byte_len must be an integer")
                    continue
                mime = parts[4] if len(parts) > 4 else "-"
                name = parts[5] if len(parts) > 5 else "-"
                ts_ms = str(int(time.time() * 1000))
                canonical = canonical_attach_bytes(room, author_id, ts_ms, cid_hex, byte_len, mime, name)
                msg_id = hashlib.sha256(canonical).hexdigest()
                try:
                    sig_b64 = backend_sign(repo_root, args.seed, canonical)
                except Exception as exc:
                    print(f"sign failed: {exc}")
                    continue
                send_line(
                    sock,
                    f"ATTACH\t{room}\t{msg_id}\t{author_id}\t{ts_ms}\t{cid_hex}\t{byte_len}\t{mime}\t{name}\t{sig_b64}",
                )
                continue
            if line.startswith("/me "):
                if not current_room:
                    print("no current room. use /join <room> or /room <room>")
                    continue
                text = line.split(maxsplit=1)[1]
                body = f"* {args.name} {text}"
                body_b64 = b64url(body.encode("utf-8"))
                ts_ms = str(int(time.time() * 1000))
                canonical = canonical_msg_bytes(current_room, author_id, ts_ms, body_b64)
                msg_id = hashlib.sha256(canonical).hexdigest()
                try:
                    sig_b64 = backend_sign(repo_root, args.seed, canonical)
                except Exception as exc:
                    print(f"sign failed: {exc}")
                    continue
                send_line(sock, f"MSG\t{current_room}\t{msg_id}\t{author_id}\t{ts_ms}\t{body_b64}\t{sig_b64}")
                continue

            if not line.startswith("/"):
                if not current_room:
                    print("no current room. use /join <room> or /msg <room> <text>")
                    continue
                body_b64 = b64url(line.encode("utf-8"))
                ts_ms = str(int(time.time() * 1000))
                canonical = canonical_msg_bytes(current_room, author_id, ts_ms, body_b64)
                msg_id = hashlib.sha256(canonical).hexdigest()
                try:
                    sig_b64 = backend_sign(repo_root, args.seed, canonical)
                except Exception as exc:
                    print(f"sign failed: {exc}")
                    continue
                send_line(sock, f"MSG\t{current_room}\t{msg_id}\t{author_id}\t{ts_ms}\t{body_b64}\t{sig_b64}")
                continue

            print("unknown command")
    finally:
        stop_evt.set()
        try:
            sock.close()
        except Exception:
            pass

    return 0


if __name__ == "__main__":
    raise SystemExit(main())

