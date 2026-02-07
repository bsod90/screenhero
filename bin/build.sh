#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BIN_DIR="$SCRIPT_DIR"

echo "Building ScreenHero (release)..."
cd "$PROJECT_DIR"

swift build -c release

BIN_PATH="$(swift build -c release --show-bin-path)"

echo "Copying binaries..."
cp "$BIN_PATH/ScreenHeroHost" "$BIN_DIR/"
cp "$BIN_PATH/ScreenHeroViewer" "$BIN_DIR/"
cp "$BIN_PATH/ScreenHeroHost" "$PROJECT_DIR/"
cp "$BIN_PATH/ScreenHeroViewer" "$PROJECT_DIR/"

# Remove quarantine attribute to avoid Gatekeeper issues
xattr -cr "$BIN_DIR/ScreenHeroHost" "$BIN_DIR/ScreenHeroViewer" 2>/dev/null || true
xattr -cr "$PROJECT_DIR/ScreenHeroHost" "$PROJECT_DIR/ScreenHeroViewer" 2>/dev/null || true

echo "Done!"
echo ""
echo "Binaries:"
ls -lh "$BIN_DIR/ScreenHeroHost" "$BIN_DIR/ScreenHeroViewer"
echo ""
echo "Usage:"
echo "  Host:   ./bin/ScreenHeroHost --help"
echo "  Viewer: ./bin/ScreenHeroViewer --help"
