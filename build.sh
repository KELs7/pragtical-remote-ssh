#!/usr/bin/env bash

# remote-plugin v0.5.0

# Exit immediately if any compilation step fails
set -e

PLATFORM="unix"
NIM_ARGS="-d:danger --mm:orc --threads:on"
SERVER_OUT="built-binaries/ubuntu-24/x86_64/headless-server"

# Parse arguments for Windows compilation
for arg in "$@"; do
  if [ "$arg" == "--windows" ] || [ "$arg" == "windows" ]; then
    PLATFORM="windows"
    # Configures Nim to cross-compile to 64-bit Windows via MinGW
    NIM_ARGS="-d:danger --mm:orc --threads:on -d:mingw --cpu:amd64"
    SERVER_OUT="headless-server.exe"
  fi
done

echo "========================================================="
echo " Building Workspace Toolchain (Target Platform: $PLATFORM)"
echo "========================================================="

# Compile the remote headless server
echo "-> Compiling headless server..."
nim c $NIM_ARGS -o:"$SERVER_OUT" remote-headless-server/main.nim

echo "========================================================="
echo " Build Completed Successfully!"
echo "---------------------------------------------------------"
echo " Headless Server: ./$SERVER_OUT"
echo "========================================================="
