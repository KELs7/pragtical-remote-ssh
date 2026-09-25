#!/usr/bin/env sh
HOST="<HOST NAME>" # from your ssh config file
USER="<USER>" #eg: root or ubuntu

ssh $HOST "mkdir -p ~/.pragtical/bin/"
scp built-binaries/ubuntu-24/x86_64/headless-server $USER@$HOST:~/.pragtical/bin/
