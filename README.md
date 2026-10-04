# chat1d

A small room-based chat system built around a line-oriented wire protocol called **CHAT/1**. Messages are signed with Ed25519 by the sender, appended to an fdatasync'd log on the server before they are fanned out, and replayed on request so a client can catch up on a room's history.

The repository contains:

| Part | Language | What it is |
|---|---|---|
| `csrc/`, `fsrc/`, `include/` | C11 + Fortran | `chat1d`, the server. C handles sockets, TLS, parsing, signatures, the durable log and fan-out; Fortran implements the in-memory room store, the ingest engine and log replay, called from C through `bind(C)` interfaces. |
| `zig/` | Zig (0.16) | Two clients: `chat1-client`, a terminal UI built on libvaxis (with a `--plain` line mode), and `chat1-gui`, a raylib desktop client with Windows-98-style widgets. |
| `src/`, `test/` | Fortran (fpm) | `fortran-chat`, a standalone CHAT/1 parser/encoder package with test vectors. |
| `tools/` | Python 3 (standard library only) | Reference CLI and curses clients, a pure-Python Ed25519/SHA-256 backend, an HTTP blob store for attachments, benchmark probes. |
| `scripts/` | Bash | `chat1-tui` and `chat1-gui` launchers that build and run the Zig clients with environment defaults. |

Status: a working prototype with tests for the server internals. See [Limitations](#limitations) before deploying it anywhere.

## How it works

### The CHAT/1 protocol

- One frame per line (`\n`-terminated, at most 65,535 bytes), fields separated by tabs. The first field is the verb.
- Verbs understood by the server: `HELLO`, `SUB`, `UNSUB`, `MSG`, `ATTACH`, `WANT`, `PING`, `BYE`; the server answers with `PONG`, `HAVE`/`END` (history replay), `ERR`, and informational `LIST`/`ROOM` frames.
- `HELLO` carries the protocol version, a node id, the client's Ed25519 public key (base64url, 43 chars) and a mode. The server derives the author id as the SHA-256 of the public key.
- `MSG` carries room, message id (SHA-256 hex), author id, timestamp in milliseconds, a base64url body of at most 4,096 bytes and the sender's Ed25519 signature (86 base64url chars). The server verifies the signature with OpenSSL before accepting the message.
- `ATTACH` announces an attachment by content id (SHA-256 of the bytes), MIME type and file name. The bytes themselves are not sent through the chat server: clients `PUT` and `GET` them from a separate HTTP blob store addressed by content id (`tools/blob_serve.py`), using `CHAT1_FETCH_TEMPLATE` to build the URL.
- `WANT <room> <since-msg-id|->` asks for a replay of the room's log; the server streams `HAVE` frames and finishes with `END`.

Sample frames used by the tests live in `test/fixtures/`.

### Server (`chat1d`)

- `csrc/main.c` reads `CHAT1_PORT` (default 7000) and `CHAT1_SHARD_INDEX`, initialises TLS, the key table, presence and the Fortran room engine, binds `0.0.0.0` and enters the serve loop.
- Without TLS the loop is `epoll`-based and non-blocking (`csrc/server_loop.c`); when `CHAT1_TLS_CERT` and `CHAT1_TLS_KEY` are both set, the server accepts TLS connections through OpenSSL and serves each connection on its own thread.
- Each room is owned by a shard, chosen by an FNV-1a hash of the room id modulo `CHAT1_SHARD_COUNT` (default 4). A shard only replays history for rooms it owns; for other rooms it answers `END` immediately. Forwarding batches between shard processes is **not implemented** (`csrc/ipc_router.c` returns `CHAT1_ROUTE_ERR_UNIMPLEMENTED`).
- Every accepted `MSG`/`ATTACH` is appended to `/tmp/chat1-shard-<n>.log` with `fdatasync` *before* fan-out to subscribers (`csrc/durable_log.c`; the ordering is covered by `tests_c/test_durable_before_fanout.c`).
- Capacities are compile-time constants in `include/chat1_server_config.h`: 8,192 connections per shard, 1,024 queued frames per connection, 65,536 room-store events and a 64 MiB body arena.
- Structured logging goes to stderr as `ts=… level=… event=…` lines.

### Fortran parts

- `fsrc/chat1_room_store.f90` keeps an append-only in-memory store (timestamps, body offsets, a body arena); `fsrc/chat1_room_engine.f90` exposes `chat1_engine_ingest_batch` and `chat1_room_engine_init_c` to C with `bind(C)`; `fsrc/chat1_replay.f90` reads a log file back into the engine.
- `src/*.f90` is a separate fpm package (`fortran-chat`): frame parsing/encoding, base64url, hex helpers and signature checks. Its crypto routines shell out to `tools/chat1_crypto_backend.py` with `execute_command_line`, so Python 3 must be on the `PATH` when you run `fpm test`.

### Clients

- `chat1-client` (Zig, libvaxis): room sidebar, member list, transcript with image previews through the Kitty graphics protocol (Kitty, Ghostty, WezTerm; text works in any terminal), Ctrl+V to paste an image as an attachment. `--plain` switches to a line-oriented stdin/stdout mode.
- `chat1-gui` (Zig, raylib): the same features in a desktop window, with an embedded DejaVu Sans Mono font and a start screen for the nickname.
- Identity: an Ed25519 seed (64 hex characters) in `~/.chat1d/seed` (`%USERPROFILE%\.chat1d\seed` on Windows), or `--seed <hex>` / `--identity <path>`. `--init-identity` creates a new random seed (`--force` to overwrite).
- Commands inside the clients: `/join <room>`, `/part <room>`, `/room <room>`, `/msg <room> <text>`, `/me <text>`, `/nick <name>`, `/ping [nonce]`, `/bye [reason]`, `/quit`.
- `tools/chat1_client.py` and `tools/chat1_client_tui.py` are the Python reference clients (`--host`, `--port`, `--name`, `--seed`, `--room`, …) and use the same pure-Python crypto backend.
- All bundled clients connect over plain TCP.

## Building

Requirements for the server: a C11 compiler, `gfortran`, `pkg-config` and the OpenSSL development package; Linux (the server uses `epoll`). The Makefile also looks for OpenSSL under `/nix/store` so it works inside a Nix shell.

```
make server          # build/bin/chat1d
make client          # zig/zig-out/bin/chat1-client  (needs Zig >= 0.16.0)
make gui             # zig/zig-out/bin/chat1-gui     (wraps the build in nix-shell with X11/GL libs; on other systems run `cd zig && zig build` with those libraries installed)
make blob-server     # python3 tools/blob_serve.py on 127.0.0.1:8090
```

The Zig build defaults to `ReleaseSmall`; `build.zig` notes that Debug builds may crash on Zig 0.16. Dependencies (libvaxis, raylib-zig) are pinned in `zig/build.zig.zon` and fetched by `zig build`.

## Running

```
# terminal 1: server (plain TCP)
make server && CHAT1_PORT=7000 ./build/bin/chat1d

# terminal 2: blob store for attachments (optional)
make blob-server

# terminal 3: a client
./scripts/chat1-tui                  # builds if needed, then starts the TUI
./scripts/chat1-gui                  # desktop client
./zig/zig-out/bin/chat1-client --init-identity   # first run: create ~/.chat1d/seed
```

TLS: set both `CHAT1_TLS_CERT` and `CHAT1_TLS_KEY` (PEM paths). Setting only one is an error; setting neither keeps plain TCP.

### Environment variables

| Variable | Used by | Meaning (default) |
|---|---|---|
| `CHAT1_PORT` | server, scripts | Listen/connect port (7000) |
| `CHAT1_SHARD_INDEX` | server | This process's shard number (0) |
| `CHAT1_SHARD_COUNT` | server | Number of shards used for room ownership (4) |
| `CHAT1_TLS_CERT`, `CHAT1_TLS_KEY` | server | PEM certificate and key; both or neither |
| `CHAT1_HOST`, `CHAT1_NAME`, `CHAT1_ROOM` | scripts | Client defaults (127.0.0.1, `$USER`, none) |
| `CHAT1_FETCH_TEMPLATE` | clients, `fetch_blob.py` | URL template for attachments (`http://127.0.0.1:8090/%s`) |
| `CHAT1_BLOB_HOST`, `CHAT1_BLOB_PORT`, `CHAT1_BLOB_DIR` | `blob_serve.py` | Blob store bind address and directory (127.0.0.1, 8090, `tools/.blob-store`) |
| `CHAT1_CRYPTO_BACKEND` | Python clients, Fortran library | Path to the crypto backend script |

## Tests

Server and engine tests are individual Make targets, each building and running one binary:

```
make test-parse-frame test-wire-parse test-frame-reader test-sub-table \
     test-connection-table test-shard-hash test-durable-log \
     test-durable-before-fanout test-log-want-replay test-engine-ingest \
     test-replay test-serve-smoke test-broadcast test-err-paths test-tls-smoke
```

The Fortran protocol package has its own suite: `fpm test` (runs `test/test_chat1_wire.f90`, which needs `python3`).

`tools/bench_local.py` and `tools/bench_lan.py` open many TCP connections and time socket writes; as their docstrings say, they send `PUB`-shaped probe frames that the real parser rejects, so they measure write throughput, not end-to-end protocol latency.

## Repository layout

```
csrc/        server: main, listener, epoll/threaded serve loops, TLS wrapper, frame reader,
             wire parser, connection table, subscription table, presence, auth keys,
             durable log, fan-out, shard hashing, (stub) IPC router
fsrc/        Fortran room store, ingest engine, log replay (linked into chat1d)
include/     chat1_ffi.h (C/Fortran contract) and chat1_server_config.h (capacities)
tests_c/     C tests;  tests_f/  Fortran tests;  test/  fpm tests + protocol fixtures
src/         fpm package "fortran-chat" (parser, encoder, base64url, crypto shim)
zig/         chat1-client (TUI) and chat1-gui (raylib); build.zig, build.zig.zon
tools/       Python reference clients, crypto backend, blob store, fetch helper, benchmarks
scripts/     chat1-tui, chat1-gui launchers
Makefile, fpm.toml
```

## Limitations

- Multi-shard deployments are incomplete: cross-shard routing is a stub, and each shard process answers `END` for rooms it does not own.
- Logs are written under `/tmp`, which many systems clear on reboot; the path is hardcoded in `csrc/durable_log.c`.
- Message bodies are stored and relayed as the sender sent them: signatures give authenticity, not confidentiality. Enable TLS for transport encryption; there is no end-to-end encryption.
- The bundled clients speak plain TCP only.
- The Fortran package's crypto depends on an external Python process.
- Linux-only server; the Zig GUI build target has been exercised through `nix-shell`.

## License

No license file is included yet. `fpm.toml` declares MIT for the Fortran package; add a `LICENSE` file to make that effective for the whole repository.
