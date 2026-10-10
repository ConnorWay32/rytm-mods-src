#!/usr/bin/env bash
# Rebuild the Ghidra project from the stock image and apply re/symbols.toml.
# The project is a build artifact - regenerate it, never commit it.
#
# IMAGE=bootstrap imports the bootstrap section instead, at its own load base.
set -euo pipefail
cd "$(dirname "$0")/../.."

GHIDRA="${GHIDRA:-$HOME/Downloads/ghidra_12.1.2_PUBLIC}"
IMAGE="${IMAGE:-mainos}"
PROJ="build/ghidra"

case "$IMAGE" in
  mainos)    BIN="build/stock_mainos.bin";    BASE=0x40000400 ;;
  bootstrap) BIN="build/stock_bootstrap.bin"; BASE=0x07020000 ;;
  *) echo "IMAGE must be mainos or bootstrap (got $IMAGE)"; exit 1 ;;
esac

[ -f "$BIN" ] || { echo "run 'make build' first to extract $BIN"; exit 1; }
[ -d "$GHIDRA" ] || { echo "set GHIDRA to your Ghidra install (got $GHIDRA)"; exit 1; }

# Gatekeeper quarantines the decompiler if Ghidra was unzipped from Downloads.
# Import and analysis still work without this; only decompilation fails.
xattr -d com.apple.quarantine \
  "$GHIDRA/Ghidra/Features/Decompiler/os/mac_arm_64/decompile" \
  "$GHIDRA/Ghidra/Features/Decompiler/os/mac_arm_64/sleigh" 2>/dev/null || true

.venv/bin/python tools/symbols.py

mkdir -p "$PROJ"
"$GHIDRA/support/analyzeHeadless" "$PROJ" AR2 \
  -import "$BIN" \
  -processor 68000:BE:32:Coldfire \
  -loader BinaryLoader -loader-baseAddr $BASE \
  -analysisTimeoutPerFile 7200 \
  -scriptPath re/ghidra/scripts -postScript ApplySymbols.java

echo "project at $PROJ; re-run scripts with:"
echo "  \$GHIDRA/support/analyzeHeadless $PROJ AR2 -process $(basename "$BIN") -noanalysis \\"
echo "      -scriptPath re/ghidra/scripts -postScript <Script>.java"
