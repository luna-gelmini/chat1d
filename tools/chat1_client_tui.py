#!/usr/bin/env python3
import argparse
import base64
import curses
import hashlib
import os
import pathlib
import socket
import subprocess
import tempfile
import threading
import time
from dataclasses import dataclass
from typing import List, Optional, Tuple


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).decode("ascii").rstrip("=")


def decode_b64url_text(value: str) -> str:
    try:
        padded = value + "=" * ((4 - len(value) % 4) % 4)
        return base64.urlsafe_b64decode(padded).decode("utf-8", "replace")
    except Exception:
        return "<decode-failed>"


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


def canonical_msg_bytes(room: str, author_id: str, ts_ms: str, body_b64: str) -> bytes:
    return f"msg\n{room}\n{author_id}\n{ts_ms}\n{body_b64}\n".encode("utf-8")


def ts_hms(ts_ms: str) -> str:
    try:
        return time.strftime("%H:%M:%S", time.localtime(int(ts_ms) / 1000.0))
    except Exception:
        return "--:--:--"


@dataclass
class EventLine:
    kind: str
    text: str
    room: Optional[str] = None
    mention: bool = False


class ChatClientState:
    def __init__(self) -> None:
        self.events: List[EventLine] = []
        self.lock = threading.Lock()
        self.connected = False
        self.current_room: Optional[str] = None
        self.server_name = "?"
        self.last_error: Optional[str] = None
        self.stop_evt = threading.Event()
        self.unread: dict[str, int] = {}
        self.nick_by_author: dict[str, str] = {}
        self.known_rooms: set[str] = set()
        self.my_nick: str = "me"

    def push(self, kind: str, text: str, room: Optional[str] = None, mention: bool = False) -> None:
        with self.lock:
            self.events.append(EventLine(kind=kind, text=text, room=room, mention=mention))
            if room:
                self.known_rooms.add(room)
                if room != self.current_room and kind == "msg":
                    self.unread[room] = self.unread.get(room, 0) + 1
            if len(self.events) > 5000:
                self.events = self.events[-5000:]

    def snapshot(self) -> List[EventLine]:
        with self.lock:
            return list(self.events)

    def rooms_snapshot(self) -> List[Tuple[str, int]]:
        with self.lock:
            rooms = sorted(self.known_rooms)
            return [(r, self.unread.get(r, 0)) for r in rooms]

    def clear_unread(self, room: Optional[str]) -> None:
        if not room:
            return
        with self.lock:
            self.unread[room] = 0


class WireClient:
    def __init__(self, host: str, port: int, seed_hex: str, name: str, nonce: str, ping_interval: int, room: Optional[str], show_ping_events: bool):
        self.host = host
        self.port = port
        self.seed_hex = seed_hex
        self.name = name
        self.nonce = nonce
        self.ping_interval = ping_interval
        self.initial_room = room
        self.repo_root = pathlib.Path(__file__).resolve().parent.parent
        self.sock: Optional[socket.socket] = None
        self.state = ChatClientState()
        self.author_id = ""
        self.pubkey_b64 = ""
        self.command_words = ["/help", "/join", "/sub", "/part", "/unsub", "/room", "/msg", "/me", "/ping", "/bye", "/quit", "/nick", "/whois"]
        self.show_ping_events = show_ping_events

    def connect(self) -> None:
        self.pubkey_b64 = backend_public_from_seed(self.repo_root, self.seed_hex)
        raw_pub = base64.urlsafe_b64decode(self.pubkey_b64 + "=")
        self.author_id = hashlib.sha256(raw_pub).hexdigest()
        self.sock = socket.create_connection((self.host, self.port), timeout=5.0)
        self.sock.settimeout(None)
        self.state.connected = True
        self.state.my_nick = self.name
        self.send_line(f"HELLO\t{self.name}\t1\t{self.nonce}\t{self.pubkey_b64}")
        if self.initial_room:
            self.send_line(f"SUB\t{self.initial_room}")
            self.state.current_room = self.initial_room
            self.state.clear_unread(self.initial_room)
        self.state.nick_by_author[self.author_id] = self.name
        self.state.push("sys", f"connected to {self.host}:{self.port}")

    def send_line(self, line: str) -> None:
        if not self.sock:
            return
        self.sock.sendall((line + "\n").encode("utf-8"))

    def close(self) -> None:
        self.state.stop_evt.set()
        if self.sock:
            try:
                self.sock.close()
            except Exception:
                pass
            self.sock = None
        self.state.connected = False

    def recv_thread(self) -> None:
        assert self.sock is not None
        f = self.sock.makefile("r", encoding="utf-8", newline="\n")
        try:
            while not self.state.stop_evt.is_set():
                line = f.readline()
                if line == "":
                    self.state.push("err", "server closed connection")
                    self.state.stop_evt.set()
                    return
                self.handle_incoming(line.rstrip("\n"))
        except Exception as exc:
            self.state.push("err", f"recv error: {exc}")
            self.state.stop_evt.set()
        finally:
            try:
                f.close()
            except Exception:
                pass

    def ping_thread(self) -> None:
        if self.ping_interval <= 0:
            return
        while not self.state.stop_evt.is_set():
            time.sleep(self.ping_interval)
            if self.state.stop_evt.is_set():
                return
            nonce = str(int(time.time()))
            try:
                self.send_line(f"PING\t{nonce}")
            except Exception:
                self.state.stop_evt.set()
                return

    def handle_incoming(self, line: str) -> None:
        parts = line.split("\t")
        verb = parts[0] if parts else ""
        if verb == "HELLO" and len(parts) >= 4:
            self.state.server_name = parts[1]
            self.state.push("sys", f"HELLO {parts[1]} proto={parts[2]} status={parts[3]}")
            return
        if verb == "MSG" and len(parts) >= 7:
            room, msg_id, author, ts_ms, body_b64 = parts[1], parts[2], parts[3], parts[4], parts[5]
            body = decode_b64url_text(body_b64)
            if author == self.author_id:
                who = "you"
            else:
                who = self.state.nick_by_author.get(author, author[:12] + "..")
            mention = f"@{self.name}" in body or f"@{self.state.my_nick}" in body
            self.state.push("msg", f"{ts_hms(ts_ms)} #{room} <{who}> {body}  {msg_id[:10]}..", room=room, mention=mention)
            return
        if verb == "ERR" and len(parts) >= 3:
            msg = f"{parts[1]}: {parts[2]}"
            self.state.last_error = msg
            self.state.push("err", msg)
            return
        if verb == "PONG" and len(parts) >= 2:
            if self.show_ping_events:
                self.state.push("debug", f"pong {parts[1]}")
            return
        if verb == "PING" and len(parts) >= 2:
            if self.show_ping_events:
                self.state.push("debug", f"ping {parts[1]}")
            return
        self.state.push("debug", line)

    def send_chat(self, room: str, text: str) -> None:
        body_b64 = b64url(text.encode("utf-8"))
        ts_ms = str(int(time.time() * 1000))
        canonical = canonical_msg_bytes(room, self.author_id, ts_ms, body_b64)
        msg_id = hashlib.sha256(canonical).hexdigest()
        sig_b64 = backend_sign(self.repo_root, self.seed_hex, canonical)
        self.send_line(f"MSG\t{room}\t{msg_id}\t{self.author_id}\t{ts_ms}\t{body_b64}\t{sig_b64}")

    def handle_command(self, line: str) -> Tuple[bool, Optional[str]]:
        line = line.strip()
        if not line:
            return True, None
        if line == "/quit":
            try:
                self.send_line("BYE\tquit")
            except Exception:
                pass
            return False, None
        if line == "/help":
            return True, "commands: /join /part /room /msg /me /nick /whois /ping /bye /quit"
        if line.startswith("/nick "):
            nick = line.split(maxsplit=1)[1].strip()
            if not nick:
                return True, "usage: /nick <name>"
            self.state.my_nick = nick
            self.state.nick_by_author[self.author_id] = nick
            return True, f"nick set to {nick}"
        if line.startswith("/whois "):
            who = line.split(maxsplit=1)[1].strip()
            for aid, nick in self.state.nick_by_author.items():
                if nick == who or aid.startswith(who):
                    return True, f"{nick} -> {aid}"
            return True, f"no mapping for {who}"
        if line.startswith("/join ") or line.startswith("/sub "):
            room = line.split(maxsplit=1)[1].strip()
            self.send_line(f"SUB\t{room}")
            self.state.current_room = room
            self.state.clear_unread(room)
            return True, f"joined #{room}"
        if line.startswith("/part ") or line.startswith("/unsub "):
            room = line.split(maxsplit=1)[1].strip()
            self.send_line(f"UNSUB\t{room}")
            if self.state.current_room == room:
                self.state.current_room = None
            return True, f"left #{room}"
        if line.startswith("/room "):
            room = line.split(maxsplit=1)[1].strip()
            self.state.current_room = room
            self.state.clear_unread(room)
            return True, f"default room -> #{room}"
        if line.startswith("/ping"):
            parts = line.split(maxsplit=1)
            nonce = parts[1] if len(parts) == 2 else str(int(time.time()))
            self.send_line(f"PING\t{nonce}")
            return True, f"ping {nonce}"
        if line.startswith("/bye"):
            parts = line.split(maxsplit=1)
            reason = parts[1] if len(parts) == 2 else "bye"
            self.send_line(f"BYE\t{reason}")
            return False, None
        if line.startswith("/msg "):
            parts = line.split(maxsplit=2)
            if len(parts) < 3:
                return True, "usage: /msg <room> <text>"
            self.send_chat(parts[1], parts[2])
            return True, None
        if line.startswith("/me "):
            if not self.state.current_room:
                return True, "no room. use /join <room>"
            text = line.split(maxsplit=1)[1]
            self.send_chat(self.state.current_room, f"* {self.name} {text}")
            return True, None
        if line.startswith("/"):
            return True, "unknown command. /help"
        if not self.state.current_room:
            return True, "no room. use /join <room> or /msg <room> <text>"
        self.send_chat(self.state.current_room, line)
        return True, None


def draw_ui(stdscr: "curses._CursesWindow", client: WireClient, input_buf: str, scroll: int) -> None:
    stdscr.erase()
    h, w = stdscr.getmaxyx()
    side_w = 28 if w >= 90 else 0
    main_w = w - side_w
    events_h = max(3, h - 4)

    status = "connected" if client.state.connected else "disconnected"
    room = client.state.current_room or "-"
    header = f" chat1 tui  server:{client.host}:{client.port}  user:{client.name}  room:{room}  status:{status} "
    stdscr.addnstr(0, 0, header.ljust(w), w, curses.A_REVERSE)

    events = client.state.snapshot()
    visible = events[-(events_h + scroll): len(events) - scroll if scroll > 0 else None]
    visible = visible[-events_h:]
    y = 1
    for ev in visible:
        attr = curses.A_NORMAL
        if ev.kind == "err":
            attr = curses.color_pair(1)
        elif ev.kind == "sys":
            attr = curses.color_pair(2)
        elif ev.kind == "msg":
            attr = curses.color_pair(3)
            if ev.mention:
                attr = curses.color_pair(5) | curses.A_BOLD
        elif ev.kind == "debug":
            attr = curses.color_pair(4)
        stdscr.addnstr(y, 0, ev.text, main_w - 1, attr)
        y += 1

    if side_w > 0:
        x0 = w - side_w
        stdscr.vline(1, x0 - 1, ord("|"), h - 3)
        stdscr.addnstr(1, x0, " rooms ".ljust(side_w), side_w, curses.A_BOLD)
        rooms = client.state.rooms_snapshot()
        ry = 2
        for room, unread in rooms[: max(0, h - 5)]:
            marker = "*" if room == (client.state.current_room or "") else " "
            badge = f" ({unread})" if unread > 0 else ""
            line = f"{marker} #{room}{badge}"
            stdscr.addnstr(ry, x0, line.ljust(side_w), side_w, curses.color_pair(2) if unread > 0 else curses.A_NORMAL)
            ry += 1

    stdscr.hline(h - 2, 0, ord("-"), w)
    prompt_room = client.state.current_room or "-"
    prompt = f"{prompt_room}> {input_buf}"
    stdscr.addnstr(h - 1, 0, prompt, main_w - 1)
    stdscr.move(h - 1, min(main_w - 1, len(prompt)))
    stdscr.refresh()


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="CHAT/1 TUI client")
    p.add_argument("--host", default="127.0.0.1")
    p.add_argument("--port", type=int, default=7000)
    p.add_argument("--name", default="cli")
    p.add_argument("--nonce", default="nonce")
    p.add_argument("--seed", required=True, help="32-byte seed hex for ed25519 signing")
    p.add_argument("--room", default=None, help="auto-subscribe room")
    p.add_argument("--ping-interval", type=int, default=30, help="keepalive ping seconds (0 disables)")
    p.add_argument("--show-ping-events", action="store_true", help="show ping/pong debug lines in event pane")
    return p.parse_args()


def run_tui(stdscr: "curses._CursesWindow", client: WireClient) -> int:
    curses.curs_set(1)
    stdscr.nodelay(True)
    stdscr.timeout(80)
    curses.start_color()
    curses.use_default_colors()
    curses.init_pair(1, curses.COLOR_RED, -1)
    curses.init_pair(2, curses.COLOR_CYAN, -1)
    curses.init_pair(3, curses.COLOR_GREEN, -1)
    curses.init_pair(4, curses.COLOR_YELLOW, -1)
    curses.init_pair(5, curses.COLOR_MAGENTA, -1)

    input_buf = ""
    scroll = 0
    history: List[str] = []
    hist_idx = -1
    while not client.state.stop_evt.is_set():
        draw_ui(stdscr, client, input_buf, scroll)
        ch = stdscr.getch()
        if ch == -1:
            continue
        if ch in (10, 13):
            line = input_buf
            input_buf = ""
            if line.strip():
                history.append(line)
                if len(history) > 200:
                    history = history[-200:]
            hist_idx = -1
            keep, note = client.handle_command(line)
            if note:
                client.state.push("sys", note)
            if not keep:
                break
            scroll = 0
            continue
        if ch in (27,):
            break
        if ch in (curses.KEY_BACKSPACE, 127, 8):
            if input_buf:
                input_buf = input_buf[:-1]
            continue
        if ch == curses.KEY_UP:
            if input_buf:
                scroll = min(scroll + 1, 2000)
            else:
                if history:
                    if hist_idx < len(history) - 1:
                        hist_idx += 1
                    input_buf = history[-1 - hist_idx]
            continue
        if ch == curses.KEY_DOWN:
            if input_buf:
                scroll = max(0, scroll - 1)
            else:
                if hist_idx > 0:
                    hist_idx -= 1
                    input_buf = history[-1 - hist_idx]
                else:
                    hist_idx = -1
                    input_buf = ""
            continue
        if ch == 9:
            candidates = client.command_words + [f"#{r}" for r, _ in client.state.rooms_snapshot()]
            if input_buf.startswith("/"):
                parts = input_buf.split()
                token = parts[-1] if parts else input_buf
                matches = [c for c in candidates if c.startswith(token)]
                if len(matches) == 1:
                    if len(parts) <= 1:
                        input_buf = matches[0] + (" " if matches[0].startswith("/") else "")
                    else:
                        parts[-1] = matches[0]
                        input_buf = " ".join(parts)
                elif len(matches) > 1:
                    client.state.push("sys", "completions: " + ", ".join(matches[:8]))
            continue
        if 32 <= ch <= 126:
            input_buf += chr(ch)
    return 0


def main() -> int:
    args = parse_args()
    if len(args.seed) != 64:
        print("seed must be 64 hex chars")
        return 1

    client = WireClient(
        host=args.host,
        port=args.port,
        seed_hex=args.seed,
        name=args.name,
        nonce=args.nonce,
        ping_interval=args.ping_interval,
        room=args.room,
        show_ping_events=args.show_ping_events,
    )
    try:
        client.connect()
    except Exception as exc:
        print(f"connect/setup failed: {exc}")
        return 1

    rt = threading.Thread(target=client.recv_thread, daemon=True)
    rt.start()
    pt = threading.Thread(target=client.ping_thread, daemon=True)
    pt.start()

    try:
        return curses.wrapper(lambda stdscr: run_tui(stdscr, client))
    finally:
        client.close()


if __name__ == "__main__":
    raise SystemExit(main())

