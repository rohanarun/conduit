#!/bin/sh
# Install conduit: curl -fsSL https://raw.githubusercontent.com/rohanarun/conduit/main/install.sh | sh
set -eu
DEST=${CONDUIT_INSTALL_DIR:-/usr/local/bin}
URL=https://raw.githubusercontent.com/rohanarun/conduit/main/conduit
tmp=$(mktemp)
curl -fsSL "$URL" -o "$tmp"
chmod +x "$tmp"
if [ -w "$DEST" ]; then mv "$tmp" "$DEST/conduit"; else sudo mv "$tmp" "$DEST/conduit"; fi
echo "installed conduit to $DEST/conduit — try: conduit --help"
