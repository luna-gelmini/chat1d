CC := cc
FC := gfortran
PKG_CONFIG ?= pkg-config
OPENSSL_PKGCONFIG_DIR := $(firstword $(wildcard /nix/store/*-openssl-*-dev/lib/pkgconfig))
OPENSSL_CFLAGS := $(shell PKG_CONFIG_PATH="$(OPENSSL_PKGCONFIG_DIR):$(PKG_CONFIG_PATH)" $(PKG_CONFIG) --cflags openssl 2>/dev/null)
CFLAGS := -std=c11 -O2 -Wall -Wextra -Iinclude $(OPENSSL_CFLAGS)
FFLAGS := -O2 -Wall -Wextra -Jbuild/mod
OPENSSL_LIBS := $(shell PKG_CONFIG_PATH="$(OPENSSL_PKGCONFIG_DIR):$(PKG_CONFIG_PATH)" $(PKG_CONFIG) --libs openssl 2>/dev/null)
LDLIBS := $(OPENSSL_LIBS)
THREAD_LIBS := -lpthread

BUILD_DIR := build
BIN_DIR := $(BUILD_DIR)/bin
OBJ_DIR := $(BUILD_DIR)/obj
MOD_DIR := $(BUILD_DIR)/mod

C_SRCS := csrc/main.c csrc/shard_process.c csrc/ipc_router.c csrc/connection_table.c csrc/fanout_send.c csrc/durable_log.c csrc/listener.c csrc/tls_wrap.c csrc/frame_ingress.c csrc/chat1_wire_parse.c csrc/chat1_frame_reader.c csrc/server_loop.c csrc/chat1_sub_table.c csrc/chat1_auth_keys.c csrc/chat1_room_presence.c
F_SRCS := fsrc/chat1_room_store.f90 fsrc/chat1_room_engine.f90 fsrc/chat1_replay.f90
C_OBJS := $(patsubst %.c,$(OBJ_DIR)/%.o,$(C_SRCS))
F_OBJS := $(patsubst %.f90,$(OBJ_DIR)/%.o,$(F_SRCS))

TEST_SHARD_HASH := $(BIN_DIR)/test_shard_hash
TEST_CONNECTION_TABLE := $(BIN_DIR)/test_connection_table
TEST_DURABLE_LOG := $(BIN_DIR)/test_durable_log
TEST_DURABLE_BEFORE_FANOUT := $(BIN_DIR)/test_durable_before_fanout
TEST_TLS_SMOKE := $(BIN_DIR)/test_tls_smoke
TEST_REPLAY := $(BIN_DIR)/test_replay
TEST_WIRE_PARSE := $(BIN_DIR)/test_wire_parse
TEST_FRAME_READER := $(BIN_DIR)/test_frame_reader
TEST_ENGINE_INGEST := $(BIN_DIR)/test_engine_ingest
TEST_SERVE_SMOKE := $(BIN_DIR)/test_serve_smoke
TEST_PARSE_FRAME := $(BIN_DIR)/test_parse_frame
TEST_SUB_TABLE := $(BIN_DIR)/test_sub_table
TEST_BROADCAST := $(BIN_DIR)/test_broadcast
TEST_ERR_PATHS := $(BIN_DIR)/test_err_paths
TEST_LOG_WANT_REPLAY := $(BIN_DIR)/test_log_want_replay

ZIG_DIR := zig
CLIENT_BIN := $(ZIG_DIR)/zig-out/bin/chat1-client

.PHONY: all server client gui tui blob-server test-shard-hash test-connection-table test-durable-log test-durable-before-fanout test-tls-smoke test-replay test-wire-parse test-frame-reader test-engine-ingest test-serve-smoke test-parse-frame test-sub-table test-broadcast test-err-paths test-log-want-replay clean

all: server

client:
	cd $(ZIG_DIR) && zig build

GUI_BIN := $(ZIG_DIR)/zig-out/bin/chat1-gui
GUI_NIX_PKGS := libx11 libxcursor libxi libxrandr libxinerama libGL

gui:
	nix-shell -p $(GUI_NIX_PKGS) --run "cd $(ZIG_DIR) && zig build"
	@test -x $(GUI_BIN)

tui: client
	./scripts/chat1-tui

blob-server:
	python3 tools/blob_serve.py

server: $(BIN_DIR)/chat1d

test-shard-hash: $(TEST_SHARD_HASH)
	$(TEST_SHARD_HASH)

test-connection-table: $(TEST_CONNECTION_TABLE)
	$(TEST_CONNECTION_TABLE)

test-durable-log: $(TEST_DURABLE_LOG)
	$(TEST_DURABLE_LOG)

test-durable-before-fanout: $(TEST_DURABLE_BEFORE_FANOUT)
	$(TEST_DURABLE_BEFORE_FANOUT)

test-tls-smoke: $(TEST_TLS_SMOKE)
	$(TEST_TLS_SMOKE)

test-replay: $(TEST_REPLAY)
	$(TEST_REPLAY)

test-wire-parse: $(TEST_WIRE_PARSE)
	$(TEST_WIRE_PARSE)

test-frame-reader: $(TEST_FRAME_READER)
	$(TEST_FRAME_READER)

test-engine-ingest: $(TEST_ENGINE_INGEST)
	$(TEST_ENGINE_INGEST)

test-serve-smoke: $(TEST_SERVE_SMOKE)
	$(TEST_SERVE_SMOKE)

test-err-paths: $(TEST_ERR_PATHS)
	$(TEST_ERR_PATHS)

test-log-want-replay: $(TEST_LOG_WANT_REPLAY)
	$(TEST_LOG_WANT_REPLAY)

$(BIN_DIR)/chat1d: $(C_OBJS) $(F_OBJS)
	@mkdir -p $(BIN_DIR)
	$(FC) -o $@ $(C_OBJS) $(F_OBJS) $(LDLIBS) $(THREAD_LIBS)

$(TEST_SHARD_HASH): tests_c/test_shard_hash.c csrc/shard_process.c csrc/ipc_router.c csrc/frame_ingress.c csrc/durable_log.c csrc/fanout_send.c csrc/chat1_sub_table.c csrc/connection_table.c include/chat1_ffi.h
	@mkdir -p $(BIN_DIR)
	$(CC) $(CFLAGS) tests_c/test_shard_hash.c csrc/shard_process.c csrc/ipc_router.c csrc/frame_ingress.c csrc/durable_log.c csrc/fanout_send.c csrc/chat1_sub_table.c csrc/connection_table.c -o $@ $(THREAD_LIBS)

$(TEST_CONNECTION_TABLE): tests_c/test_connection_table.c csrc/connection_table.c csrc/fanout_send.c csrc/chat1_sub_table.c include/chat1_ffi.h include/chat1_server_config.h
	@mkdir -p $(BIN_DIR)
	$(CC) $(CFLAGS) tests_c/test_connection_table.c csrc/connection_table.c csrc/fanout_send.c csrc/chat1_sub_table.c -o $@ $(THREAD_LIBS)

$(TEST_DURABLE_LOG): tests_c/test_durable_log.c csrc/durable_log.c include/chat1_ffi.h
	@mkdir -p $(BIN_DIR)
	$(CC) $(CFLAGS) tests_c/test_durable_log.c csrc/durable_log.c -o $@

$(TEST_DURABLE_BEFORE_FANOUT): tests_c/test_durable_before_fanout.c csrc/shard_process.c csrc/frame_ingress.c csrc/durable_log.c csrc/chat1_wire_parse.c include/chat1_ffi.h
	@mkdir -p $(BIN_DIR)
	$(CC) $(CFLAGS) tests_c/test_durable_before_fanout.c csrc/shard_process.c csrc/frame_ingress.c csrc/durable_log.c csrc/chat1_wire_parse.c -o $@

$(TEST_TLS_SMOKE): tests_c/test_tls_smoke.c csrc/tls_wrap.c
	@mkdir -p $(BIN_DIR)
	$(CC) $(CFLAGS) tests_c/test_tls_smoke.c csrc/tls_wrap.c -o $@ $(LDLIBS)

$(TEST_REPLAY): tests_f/test_replay.f90 fsrc/chat1_room_store.f90 fsrc/chat1_room_engine.f90 fsrc/chat1_replay.f90
	@mkdir -p $(BIN_DIR) $(MOD_DIR)
	$(FC) $(FFLAGS) fsrc/chat1_room_store.f90 fsrc/chat1_room_engine.f90 fsrc/chat1_replay.f90 tests_f/test_replay.f90 -o $@

$(TEST_WIRE_PARSE): tests_c/test_wire_parse.c csrc/chat1_wire_parse.c include/chat1_ffi.h
	@mkdir -p $(BIN_DIR)
	$(CC) $(CFLAGS) tests_c/test_wire_parse.c csrc/chat1_wire_parse.c -o $@

$(TEST_FRAME_READER): tests_c/test_frame_reader.c csrc/chat1_frame_reader.c csrc/chat1_wire_parse.c include/chat1_ffi.h
	@mkdir -p $(BIN_DIR)
	$(CC) $(CFLAGS) tests_c/test_frame_reader.c csrc/chat1_frame_reader.c csrc/chat1_wire_parse.c -o $@

$(TEST_ENGINE_INGEST): tests_f/test_engine_ingest.f90 fsrc/chat1_room_store.f90 fsrc/chat1_room_engine.f90
	@mkdir -p $(BIN_DIR) $(MOD_DIR)
	$(FC) $(FFLAGS) fsrc/chat1_room_store.f90 fsrc/chat1_room_engine.f90 tests_f/test_engine_ingest.f90 -o $@

$(TEST_SERVE_SMOKE): tests_c/test_serve_smoke.c csrc/server_loop.c csrc/chat1_room_presence.c csrc/tls_wrap.c csrc/chat1_auth_keys.c csrc/shard_process.c csrc/ipc_router.c csrc/frame_ingress.c csrc/durable_log.c csrc/fanout_send.c csrc/chat1_wire_parse.c csrc/chat1_frame_reader.c csrc/connection_table.c csrc/chat1_sub_table.c $(F_SRCS) include/chat1_ffi.h
	@mkdir -p $(BIN_DIR) $(MOD_DIR) $(OBJ_DIR)
	$(CC) $(CFLAGS) -c tests_c/test_serve_smoke.c -o $(OBJ_DIR)/test_serve_smoke.o
	$(CC) $(CFLAGS) -c csrc/server_loop.c -o $(OBJ_DIR)/server_loop_smoke.o
	$(CC) $(CFLAGS) -c csrc/chat1_room_presence.c -o $(OBJ_DIR)/chat1_room_presence_smoke.o
	$(CC) $(CFLAGS) -c csrc/tls_wrap.c -o $(OBJ_DIR)/tls_wrap_smoke.o
	$(CC) $(CFLAGS) -c csrc/chat1_auth_keys.c -o $(OBJ_DIR)/chat1_auth_keys_smoke.o
	$(CC) $(CFLAGS) -c csrc/shard_process.c -o $(OBJ_DIR)/shard_process_smoke.o
	$(CC) $(CFLAGS) -c csrc/ipc_router.c -o $(OBJ_DIR)/ipc_router_smoke.o
	$(CC) $(CFLAGS) -c csrc/frame_ingress.c -o $(OBJ_DIR)/frame_ingress_smoke.o
	$(CC) $(CFLAGS) -c csrc/durable_log.c -o $(OBJ_DIR)/durable_log_smoke.o
	$(CC) $(CFLAGS) -c csrc/fanout_send.c -o $(OBJ_DIR)/fanout_send_smoke.o
	$(CC) $(CFLAGS) -c csrc/chat1_wire_parse.c -o $(OBJ_DIR)/chat1_wire_parse_smoke.o
	$(CC) $(CFLAGS) -c csrc/chat1_frame_reader.c -o $(OBJ_DIR)/chat1_frame_reader_smoke.o
	$(CC) $(CFLAGS) -c csrc/connection_table.c -o $(OBJ_DIR)/connection_table_smoke.o
	$(CC) $(CFLAGS) -c csrc/chat1_sub_table.c -o $(OBJ_DIR)/chat1_sub_table_smoke.o
	$(FC) $(FFLAGS) -c fsrc/chat1_room_store.f90 -o $(OBJ_DIR)/chat1_room_store_smoke.o
	$(FC) $(FFLAGS) -c fsrc/chat1_room_engine.f90 -o $(OBJ_DIR)/chat1_room_engine_smoke.o
	$(FC) $(FFLAGS) -c fsrc/chat1_replay.f90 -o $(OBJ_DIR)/chat1_replay_smoke.o
	$(FC) -o $@ $(OBJ_DIR)/test_serve_smoke.o $(OBJ_DIR)/server_loop_smoke.o $(OBJ_DIR)/chat1_room_presence_smoke.o $(OBJ_DIR)/tls_wrap_smoke.o $(OBJ_DIR)/chat1_auth_keys_smoke.o $(OBJ_DIR)/shard_process_smoke.o $(OBJ_DIR)/ipc_router_smoke.o $(OBJ_DIR)/frame_ingress_smoke.o $(OBJ_DIR)/durable_log_smoke.o $(OBJ_DIR)/fanout_send_smoke.o $(OBJ_DIR)/chat1_wire_parse_smoke.o $(OBJ_DIR)/chat1_frame_reader_smoke.o $(OBJ_DIR)/connection_table_smoke.o $(OBJ_DIR)/chat1_sub_table_smoke.o $(OBJ_DIR)/chat1_room_store_smoke.o $(OBJ_DIR)/chat1_room_engine_smoke.o $(OBJ_DIR)/chat1_replay_smoke.o $(THREAD_LIBS) $(LDLIBS)

$(TEST_PARSE_FRAME): tests_c/test_parse_frame.c csrc/chat1_wire_parse.c include/chat1_ffi.h
	@mkdir -p $(BIN_DIR)
	$(CC) $(CFLAGS) tests_c/test_parse_frame.c csrc/chat1_wire_parse.c -o $@

test-parse-frame: $(TEST_PARSE_FRAME)
	$(TEST_PARSE_FRAME)

$(TEST_LOG_WANT_REPLAY): tests_c/test_log_want_replay.c csrc/durable_log.c csrc/chat1_wire_parse.c include/chat1_ffi.h
	@mkdir -p $(BIN_DIR)
	$(CC) $(CFLAGS) tests_c/test_log_want_replay.c csrc/durable_log.c csrc/chat1_wire_parse.c -o $@

$(TEST_SUB_TABLE): tests_c/test_sub_table.c csrc/chat1_sub_table.c include/chat1_ffi.h
	@mkdir -p $(BIN_DIR)
	$(CC) $(CFLAGS) tests_c/test_sub_table.c csrc/chat1_sub_table.c -o $@ $(THREAD_LIBS)

test-sub-table: $(TEST_SUB_TABLE)
	$(TEST_SUB_TABLE)

$(TEST_BROADCAST): tests_c/test_broadcast.c csrc/server_loop.c csrc/chat1_room_presence.c csrc/tls_wrap.c csrc/chat1_auth_keys.c csrc/shard_process.c csrc/ipc_router.c csrc/frame_ingress.c csrc/durable_log.c csrc/fanout_send.c csrc/chat1_wire_parse.c csrc/chat1_frame_reader.c csrc/connection_table.c csrc/chat1_sub_table.c $(F_SRCS) include/chat1_ffi.h
	@mkdir -p $(BIN_DIR) $(MOD_DIR) $(OBJ_DIR)
	$(CC) $(CFLAGS) -c tests_c/test_broadcast.c -o $(OBJ_DIR)/test_broadcast.o
	$(CC) $(CFLAGS) -c csrc/server_loop.c -o $(OBJ_DIR)/server_loop_bc.o
	$(CC) $(CFLAGS) -c csrc/chat1_room_presence.c -o $(OBJ_DIR)/chat1_room_presence_bc.o
	$(CC) $(CFLAGS) -c csrc/tls_wrap.c -o $(OBJ_DIR)/tls_wrap_bc.o
	$(CC) $(CFLAGS) -c csrc/chat1_auth_keys.c -o $(OBJ_DIR)/chat1_auth_keys_bc.o
	$(CC) $(CFLAGS) -c csrc/shard_process.c -o $(OBJ_DIR)/shard_process_bc.o
	$(CC) $(CFLAGS) -c csrc/ipc_router.c -o $(OBJ_DIR)/ipc_router_bc.o
	$(CC) $(CFLAGS) -c csrc/frame_ingress.c -o $(OBJ_DIR)/frame_ingress_bc.o
	$(CC) $(CFLAGS) -c csrc/durable_log.c -o $(OBJ_DIR)/durable_log_bc.o
	$(CC) $(CFLAGS) -c csrc/fanout_send.c -o $(OBJ_DIR)/fanout_send_bc.o
	$(CC) $(CFLAGS) -c csrc/chat1_wire_parse.c -o $(OBJ_DIR)/chat1_wire_parse_bc.o
	$(CC) $(CFLAGS) -c csrc/chat1_frame_reader.c -o $(OBJ_DIR)/chat1_frame_reader_bc.o
	$(CC) $(CFLAGS) -c csrc/connection_table.c -o $(OBJ_DIR)/connection_table_bc.o
	$(CC) $(CFLAGS) -c csrc/chat1_sub_table.c -o $(OBJ_DIR)/chat1_sub_table_bc.o
	$(FC) $(FFLAGS) -c fsrc/chat1_room_store.f90 -o $(OBJ_DIR)/chat1_room_store_bc.o
	$(FC) $(FFLAGS) -c fsrc/chat1_room_engine.f90 -o $(OBJ_DIR)/chat1_room_engine_bc.o
	$(FC) $(FFLAGS) -c fsrc/chat1_replay.f90 -o $(OBJ_DIR)/chat1_replay_bc.o
	$(FC) -o $@ $(OBJ_DIR)/test_broadcast.o $(OBJ_DIR)/server_loop_bc.o $(OBJ_DIR)/chat1_room_presence_bc.o $(OBJ_DIR)/tls_wrap_bc.o $(OBJ_DIR)/chat1_auth_keys_bc.o $(OBJ_DIR)/shard_process_bc.o $(OBJ_DIR)/ipc_router_bc.o $(OBJ_DIR)/frame_ingress_bc.o $(OBJ_DIR)/durable_log_bc.o $(OBJ_DIR)/fanout_send_bc.o $(OBJ_DIR)/chat1_wire_parse_bc.o $(OBJ_DIR)/chat1_frame_reader_bc.o $(OBJ_DIR)/connection_table_bc.o $(OBJ_DIR)/chat1_sub_table_bc.o $(OBJ_DIR)/chat1_room_store_bc.o $(OBJ_DIR)/chat1_room_engine_bc.o $(OBJ_DIR)/chat1_replay_bc.o $(THREAD_LIBS) $(LDLIBS)

test-broadcast: $(TEST_BROADCAST)
	$(TEST_BROADCAST)

$(TEST_ERR_PATHS): tests_c/test_err_paths.c csrc/server_loop.c csrc/chat1_room_presence.c csrc/tls_wrap.c csrc/chat1_auth_keys.c csrc/shard_process.c csrc/ipc_router.c csrc/frame_ingress.c csrc/durable_log.c csrc/fanout_send.c csrc/chat1_wire_parse.c csrc/chat1_frame_reader.c csrc/connection_table.c csrc/chat1_sub_table.c $(F_SRCS) include/chat1_ffi.h
	@mkdir -p $(BIN_DIR) $(MOD_DIR) $(OBJ_DIR)
	$(CC) $(CFLAGS) -c tests_c/test_err_paths.c -o $(OBJ_DIR)/test_err_paths.o
	$(CC) $(CFLAGS) -c csrc/server_loop.c -o $(OBJ_DIR)/server_loop_err.o
	$(CC) $(CFLAGS) -c csrc/chat1_room_presence.c -o $(OBJ_DIR)/chat1_room_presence_err.o
	$(CC) $(CFLAGS) -c csrc/tls_wrap.c -o $(OBJ_DIR)/tls_wrap_err.o
	$(CC) $(CFLAGS) -c csrc/chat1_auth_keys.c -o $(OBJ_DIR)/chat1_auth_keys_err.o
	$(CC) $(CFLAGS) -c csrc/shard_process.c -o $(OBJ_DIR)/shard_process_err.o
	$(CC) $(CFLAGS) -c csrc/ipc_router.c -o $(OBJ_DIR)/ipc_router_err.o
	$(CC) $(CFLAGS) -c csrc/frame_ingress.c -o $(OBJ_DIR)/frame_ingress_err.o
	$(CC) $(CFLAGS) -c csrc/durable_log.c -o $(OBJ_DIR)/durable_log_err.o
	$(CC) $(CFLAGS) -c csrc/fanout_send.c -o $(OBJ_DIR)/fanout_send_err.o
	$(CC) $(CFLAGS) -c csrc/chat1_wire_parse.c -o $(OBJ_DIR)/chat1_wire_parse_err.o
	$(CC) $(CFLAGS) -c csrc/chat1_frame_reader.c -o $(OBJ_DIR)/chat1_frame_reader_err.o
	$(CC) $(CFLAGS) -c csrc/connection_table.c -o $(OBJ_DIR)/connection_table_err.o
	$(CC) $(CFLAGS) -c csrc/chat1_sub_table.c -o $(OBJ_DIR)/chat1_sub_table_err.o
	$(FC) $(FFLAGS) -c fsrc/chat1_room_store.f90 -o $(OBJ_DIR)/chat1_room_store_err.o
	$(FC) $(FFLAGS) -c fsrc/chat1_room_engine.f90 -o $(OBJ_DIR)/chat1_room_engine_err.o
	$(FC) $(FFLAGS) -c fsrc/chat1_replay.f90 -o $(OBJ_DIR)/chat1_replay_err.o
	$(FC) -o $@ $(OBJ_DIR)/test_err_paths.o $(OBJ_DIR)/server_loop_err.o $(OBJ_DIR)/chat1_room_presence_err.o $(OBJ_DIR)/tls_wrap_err.o $(OBJ_DIR)/chat1_auth_keys_err.o $(OBJ_DIR)/shard_process_err.o $(OBJ_DIR)/ipc_router_err.o $(OBJ_DIR)/frame_ingress_err.o $(OBJ_DIR)/durable_log_err.o $(OBJ_DIR)/fanout_send_err.o $(OBJ_DIR)/chat1_wire_parse_err.o $(OBJ_DIR)/chat1_frame_reader_err.o $(OBJ_DIR)/connection_table_err.o $(OBJ_DIR)/chat1_sub_table_err.o $(OBJ_DIR)/chat1_room_store_err.o $(OBJ_DIR)/chat1_room_engine_err.o $(OBJ_DIR)/chat1_replay_err.o $(THREAD_LIBS) $(LDLIBS)

$(OBJ_DIR)/%.o: %.c
	@mkdir -p $(dir $@) $(MOD_DIR)
	$(CC) $(CFLAGS) -c $< -o $@

$(OBJ_DIR)/%.o: %.f90
	@mkdir -p $(dir $@) $(MOD_DIR)
	$(FC) $(FFLAGS) -c $< -o $@

clean:
	rm -rf $(BIN_DIR) $(OBJ_DIR) $(MOD_DIR)
