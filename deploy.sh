#!/usr/bin/env sh

#!/bin/bash
set -e
HOST="$1"
REMOTE_DIR="~/src/remote-agent"

if [ -z "$HOST" ]; then echo "Usage: $0 <host>"; exit 1; fi

echo "Syncing source code to $HOST..."
# Create remote dir
ssh "$HOST" "mkdir -p $REMOTE_DIR/src"
# Copy config and source
scp Cargo.toml "$HOST:$REMOTE_DIR/"
scp src/main.rs "$HOST:$REMOTE_DIR/src/"

echo "Building on remote (ensures Linux compatibility)..."
ssh "$HOST" "cd $REMOTE_DIR && ~/.cargo/bin/cargo build --release"

echo "Installing to ~/.local/bin..."
ssh "$HOST" "mkdir -p ~/.local/bin && mv $REMOTE_DIR/target/release/emacs-remote-agent ~/.local/bin/remote-agent"

echo "Done! Agent is ready on $HOST."
