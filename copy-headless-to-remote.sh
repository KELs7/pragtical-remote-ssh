#!/usr/bin/env sh
HOST="<HOST NAME>" # from your config file

ssh $HOST "mkdir -p ~/.pragtical/bin"
scp built-binaries/ubuntu-24/x86_64/headless-server $HOST:~/.pragtical/bin
