#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BIN_DIR="$SCRIPT_DIR"

echo "Building ScreenHero (release)..."
cd "$PROJECT_DIR"

swift build -c release

echo "Copying binaries to $BIN_DIR..."
cp "$(swift build -c release --show-bin-path)/ScreenHeroHost" "$BIN_DIR/"
cp "$(swift build -c release --show-bin-path)/ScreenHeroViewer" "$BIN_DIR/"

echo "Done!"
echo ""
echo "Binaries:"
ls -lh "$BIN_DIR/ScreenHeroHost" "$BIN_DIR/ScreenHeroViewer"
echo ""
echo "Run with:"
echo "  $BIN_DIR/ScreenHeroHost"
echo "  $BIN_DIR/ScreenHeroViewer"
