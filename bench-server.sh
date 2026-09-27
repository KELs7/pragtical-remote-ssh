#!/usr/bin/env bash

# E2E benchmarks for the headless server (no SSH).
# Launches the compiled server in a scratch dir and points bridge.lua at it,
# measuring real round-trip latencies over the loopback TCP connection.
#
# Usage: ./bench-server.sh [port]     (default port: 8089)

set -e

PORT="${1:-8089}"
SERVER_OUT="built-binaries/ubuntu-24/x86_64/headless-server"
PLUGIN_ROOT="$(cd "$(dirname "$0")" && pwd)"
WORKDIR="$(mktemp -d)"

cd "$WORKDIR"
"$PLUGIN_ROOT/$SERVER_OUT" "$PORT" > /tmp/hs_bench.log 2>&1 &
HS_PID=$!
trap 'kill $HS_PID 2>/dev/null; if [ -n "$KEEP_LOG" ]; then cp /tmp/hs_bench.log /tmp/hs_bench_kept.log; fi; rm -rf "$WORKDIR" /tmp/hs_bench.log' EXIT

sleep 0.5

mkdir -p /tmp/pragtical_test_user
PRAGTICAL_USERDIR=/tmp/pragtical_test_user \
PLUGIN_ROOT="$PLUGIN_ROOT" \
PORT="$PORT" \
  pragtical run -e 'dofile((assert(os.getenv("PLUGIN_ROOT"), "PLUGIN_ROOT not set")) .. "/tests/server_e2e_bench.lua")' 2>&1 | grep -v "^$"
